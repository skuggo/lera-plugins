-- Explore mode: the impure half of the explorer.
--
-- Owns position, exit ingestion and the area profile. The map it drives is
-- pure (explore/map.lua); everything that touches the outside world is here.
--
-- Position is dead reckoned because it has to be: the areas this exists for
-- report no room identity at all. A no-explorer virtual room has none --
-- explorer_d collapses such a VR path at its ':' before asking the explorer DB
-- -- so every room in the area shares one Room.Info num: 0 when the DB holds no
-- row for this character, and a single constant for every room when it does
-- (60494 was captured in the Chaos Sea). Exit destinations answer the same way,
-- which makes them self-references: the portal room's sole exit reads that
-- room's own num. Either way nothing in the protocol says which room we are
-- standing in.

local map_mod = require("explore.map")

local M = {}

local ri = nil            -- roominfo module (or a stand-in, in tests)
local active = false
local profile = nil
local map = nil
local policy = "clear"

local last_exits = {}     -- exit list from the most recent accepted frame
local last_name = nil     -- room name from the most recent accepted frame
local pending_dirs = {}   -- emitted directions, consumed by confirmed entries
local layer_corrections = 0  -- times the room name overrode a reckoned z
local desync_count = 0       -- times contradicted topology forced a map reset

-- M.leave()'s walk back to the origin. nil means no leave is in progress;
-- once armed it is an array of directions (possibly already empty, once the
-- last one has been popped) -- see next_step() and stop_reason() below for
-- why the empty-but-armed state has to be distinguishable from nil.
local pending_leave_path = nil
local stop_reason_val = "exhausted"  -- "exhausted" | "at origin"

-- Narration goes out through the stepper's logger once init.lua has handed one
-- over (it owns the colour palette; there is no second copy of it here), and
-- through a plain tagged print otherwise -- which is what keeps this module
-- usable, and testable, on its own. The second argument names the KIND of
-- line, never a colour, for the same reason.
local emit = nil

function M.set_logger(fn)
  emit = (type(fn) == "function") and fn or nil
end

local function log(msg, kind)
  if emit then return emit(msg, kind) end
  print("[autostepper] " .. msg)
end

function M.attach(roominfo)
  ri = roominfo
end

function M.active()
  return active
end

function M.policy()
  return policy
end

function M.set_policy(name)
  if name ~= "clear" and name ~= "dive" then return false end
  policy = name
  return true
end

-- Drop the exits the profile says are not ours to walk. 'out' leaves the maze
-- entirely; walking it would take the explorer out of the area it is mapping.
-- (map.lua drops anything with no delta as well, so this is the profile's
-- chance to exclude a direction that IS walkable.)
local function filter_exits(exits)
  local out = {}
  local excluded = (profile and profile.exclude_exits) or {}
  for _, dir in ipairs(exits or {}) do
    if not excluded[dir] then out[#out + 1] = dir end
  end
  return out
end

function M.start(prof, initial_policy)
  if not prof then return false end
  profile = prof
  -- Always a fresh map. A re-entered area is a NEW maze instance -- the
  -- mudlib generates one per run -- so anything retained from a PRIOR run
  -- would be contradicted topology from the first frame onward. That is what
  -- keeps an explicitly named "/step explore <area>" fresh even when a
  -- paused run's map is retained. M.resume() is the separate path that
  -- deliberately keeps the map instead of calling this.
  map = map_mod.new({ vertical = prof and prof.vertical })
  policy = initial_policy or prof.default_policy or "clear"
  active = true
  pending_dirs = {}
  pending_leave_path = nil
  stop_reason_val = "exhausted"
  last_exits = {}
  last_name = nil
  layer_corrections = 0
  desync_count = 0

  -- Seed from the room we are already standing in. The entry room's Room.Info
  -- arrives when the player WALKS INTO the area, which is before the explore
  -- command runs, and the server never resends an identical payload -- so a
  -- mode that waits for the next frame records its origin with no exits, BFS
  -- finds no frontier, and the run ends on its first decision. This is also
  -- exactly the suppression case (6.2): "no frame arrived" means the exits are
  -- the ones already known, never that the room has none.
  local info = ri and ri.info and ri.info()
  if type(info) == "table" then
    last_exits = filter_exits(info.exits)
    last_name = info.room
  end
  return true
end

-- Pause: a half-emitted move and a partly-walked leave route must not
-- survive it, since the player may move by hand before resuming -- but the
-- map, profile and last-known room are kept, so M.resume() can pick the run
-- back up without remapping from scratch. M.discard() is the real teardown.
function M.stop()
  active = false
  pending_dirs = {}
  pending_leave_path = nil
end

-- The real teardown: nils the map and profile along with everything else, so
-- nothing is left for M.resume() to pick up. Called from M.on_unload and
-- from on_arrival when in_area reports the player has left the area -- the
-- one place a retained map would actually be wrong to hand back later.
function M.discard()
  active = false
  profile = nil
  map = nil
  pending_dirs = {}
  pending_leave_path = nil
  last_exits = {}
  last_name = nil
end

-- True when a paused run's map and profile are held (M.stop() left them
-- behind) but no run is currently active -- distinguishes "paused with a
-- map" from "never started" for callers like /step status and /step explore.
function M.retained()
  return (not active) and map ~= nil and profile ~= nil
end

-- Resume a paused run in place. Refuses (and changes nothing) unless a map
-- and profile are retained, and unless the room the player is standing in
-- RIGHT NOW -- read fresh from roominfo, never the retained last_name, which
-- is where they were when the run stopped -- is still within the profile's
-- area. That check is the whole point: it is what makes resuming safe where
-- the old "stop discards everything" guard used to be the only defense.
-- Only sets `active`; the caller re-asks the MUD (the same Room.Refresh a
-- start sends) so the reckoning re-anchors on the current room rather than
-- trusting where it left off.
function M.resume()
  if active or not map or not profile then return false end
  if not profile.in_area then return false end
  local info = ri and ri.info and ri.info()
  local current = type(info) == "table" and info.room or nil
  if not current or not profile.in_area(current) then return false end
  -- Only sets `active`. pending_dir and pending_leave_path are M.stop()'s
  -- job -- not repeated here -- so a stale one surviving a stop stays
  -- observable through a resume rather than being silently mopped up here.
  active = true
  return true
end

-- Reset the map and start over from a fresh origin. Works whether the run is
-- active or merely retained (paused) -- and leaves that state exactly as it
-- found it, since resetting a stopped run must not start the player walking.
-- A desynced map is worse than no map: every later decision is made against
-- coordinates that do not correspond to rooms.
function M.reset(reason)
  if not map then return end
  map = map_mod.new({ vertical = profile and profile.vertical })
  pending_dirs = {}
  -- A pending leave path names directions in the OLD map's coordinate frame;
  -- left set across a reset, next_step() would keep walking it against a map
  -- that no longer has those rooms recorded, oblivious to the fresh origin.
  pending_leave_path = nil
  if reason then
    log("explore: map reset (" .. reason .. ")", "warn")
  end
end

-- Called for every accepted Room.Info frame.
function M.on_frame(info)
  if not active or not info then return end
  last_exits = filter_exits(info.exits)
  last_name = info.room
end

-- Called once the arrival has been committed by the step cycle. Everything
-- position-related happens here and nowhere else.
function M.on_arrival()
  if not active then return end

  -- Left the area: discard rather than dead-reckon the outside world into a
  -- map of somewhere else, and rather than merely pausing -- a map of an
  -- area the player is no longer in is not something a later resume should
  -- be handed back. There is no location event to hang this on -- the room
  -- name is the only signal the protocol carries in an area with no room ids.
  if profile and profile.in_area and last_name and not profile.in_area(last_name) then
    log("explore: left " .. profile.name .. ", explore mode off", "run")
    M.discard()
    return
  end

  if #pending_dirs > 0 then
    map:move(table.remove(pending_dirs, 1))
  end

  -- z is read from the room name, not dead-reckoned, whenever the profile can
  -- read one. The area this exists for inverts up/down relative to the ordinary
  -- lattice convention -- its level-exit override makes "down" increase z -- so
  -- trusting the vertical delta would collide every layer onto its neighbour.
  -- x and y stay dead-reckoned, which composes correctly because the maze's
  -- level exit preserves them (nx = x; ny = y). This is a correction, never a
  -- dispute: the room name is the authority for z, so a disagreement here is
  -- not evidence of a desync.
  local x, y, z = map:position()
  if profile and profile.layer_of and last_name then
    local layer = profile.layer_of(last_name)
    if type(layer) == "number" and layer ~= z then
      layer_corrections = layer_corrections + 1
      -- With the area's vertical convention declared (see areas/chaossea.lua),
      -- this should now never fire -- the reckoned z and the name's layer
      -- should already agree. It stays as the safety net, but it used to fire
      -- on EVERY vertical move, silently, which is how the inverted-delta bug
      -- survived: nobody noticed because nothing said so. So it speaks now --
      -- every correction reaches the session capture, and the first one in a
      -- run also reaches the screen, since an unconditional print would be the
      -- same flood that hid the original bug.
      local msg = "explore: layer correction -- reckoned z=" .. z .. ", "
        .. tostring(last_name) .. " is layer " .. layer
      -- Guarded: mode.lua runs under plain LuaJIT in the unit tests, where
      -- there is no lera table at all.
      if lera and lera.log then lera.log(msg) end
      if layer_corrections == 1 then log(msg, "warn") end
      map:set_position(x, y, layer)
      z = layer
    end
  end

  -- Tripwire, and it earns its place: if the check above is ever broken, this is
  -- what turns a corrupted position into an observable, logged refusal instead
  -- of an unhandled error deep in map.lua. It logs rather than returning
  -- silently, because every other defensive path in this function says why.
  if type(z) ~= "number" then
    log("explore: refusing a non-numeric layer; position left as reckoned",
        "warn")
    return
  end

  -- The desync proof: the lattice is generated once per run and each room's
  -- coordinates are baked into its own file name, so a coordinate's exits
  -- cannot legitimately change. If they have, we are not where we think we
  -- are (a blocked move, a teleport, a forced relocation) -- and a desynced
  -- map is worse than no map, since every later decision is made against
  -- coordinates that do not correspond to rooms.
  local prior = map:room(x, y, z)
  if prior then
    local arriving = {}
    for _, dir in ipairs(last_exits) do
      if map_mod.DELTA[dir] then arriving[dir] = true end
    end
    if not map_mod.same_exits(prior.exits, arriving) then
      desync_count = desync_count + 1
      M.reset("exits at " .. x .. "," .. y .. "," .. z .. " contradict the map")
      -- The fresh origin keeps the layer, because the room name still names it.
      -- Filing this room at z = 0 while standing on layer two puts it where
      -- genuine layer-one rooms live, and the next arrival's layer correction
      -- jumps z away from it -- an orphan node that can collide, and a cascade
      -- of further resets at every layer boundary.
      if profile and profile.layer_of and last_name then
        local layer = profile.layer_of(last_name)
        if type(layer) == "number" then map:set_position(0, 0, layer) end
      end
      map:record(last_exits)
      return
    end
  end

  -- last_exits is used whether or not a frame arrived for this room. When one
  -- did not, the server suppressed an identical payload, which MEANS this
  -- room's name, area and exits equal the previous frame's -- so recording them
  -- is recording fact, not papering over a gap. Treating a suppressed frame as
  -- an empty room would erase the room's frontier instead.
  map:record(last_exits)
end

-- Walk back to the run's origin. Computed once (path_to(0, 0, 0)) and stored
-- as a pending path that next_step() drains one direction at a time; arrival
-- still runs process_room() exactly as any other step does, so a monster met
-- on the way out is still fought -- leaving is not a reason to stop fighting.
--
-- Refuses (reports and changes nothing) rather than arming a path when: not
-- active; the origin is unrecorded or unreachable through recorded rooms (a
-- desync reset can leave the map disconnected from it); or already at the
-- origin. path_to's own three-way contract supplies exactly these last two
-- distinctly, so this reads it rather than re-deriving them.
function M.leave()
  if not active or not map then
    log("explore: leave refused -- explore mode is not active", "warn")
    return false
  end
  if #pending_dirs > 0 then
    log("explore: leave refused -- wait for the current route to arrive", "warn")
    return false
  end
  local path = map:path_to(0, 0, 0)
  if path == nil then
    log("explore: leave refused -- the origin is unrecorded or unreachable",
        "warn")
    return false
  end
  if #path == 0 then
    log("explore: already at the origin")
    return false
  end
  pending_leave_path = path
  log("explore: leaving -- " .. #path .. " step(s) to the origin", "run")
  return true
end

-- Why the run last stopped supplying a step. Read once by do_step() when
-- next_step() returns nil, so it can log "back at the origin" instead of the
-- wrong "no unvisited exits remain" for a completed leave.
function M.stop_reason()
  return stop_reason_val
end

function M.next_step()
  -- These nils are not exhaustion, and must not read as it: the caller reports
  -- whatever stop_reason() says, and a stale "exhausted" here would announce
  -- an empty map while rooms remain.
  if not active or not map then
    stop_reason_val = "inactive"
    return nil
  end
  if #pending_dirs > 0 then
    stop_reason_val = "in flight"
    return nil
  end

  -- A pending leave path takes precedence over frontier selection: once
  -- M.leave() has armed one, every next_step() call drains it one direction
  -- at a time until it is empty, checking each room on the way out.
  -- The path is checked whether or not it is
  -- empty, rather than only when non-empty, because an EMPTY-but-still-armed
  -- path is what marks "the walk just finished" -- once drained, this run is
  -- over and must report so, not silently fall through to frontier search.
  if pending_leave_path then
    if #pending_leave_path == 0 then
      stop_reason_val = "at origin"
      pending_leave_path = nil
      return nil
    end
    local dir = table.remove(pending_leave_path, 1)
    pending_dirs = { dir }
    return { raw = dir, commands = { dir } }
  end

  local path = map:next_frontier({
    policy = policy,
    dive_dirs = profile and profile.dive_dirs,
    defer_dirs = profile and profile.defer_dirs,
  })
  if not path or #path == 0 then
    -- A resumed run may still hold the reason from a completed leave.
    stop_reason_val = "exhausted"
    return nil
  end
  -- BFS traverses recorded rooms only; the last direction enters the frontier.
  -- Keep our own copy so each arriving entry can commit exactly one direction.
  pending_dirs = {}
  for i, dir in ipairs(path) do pending_dirs[i] = dir end
  return { raw = table.concat(path, " "), commands = path }
end

function M.stats()
  if not map then
    return { rooms = 0, x = 0, y = 0, z = 0, layer = nil, policy = policy }
  end
  local x, y, z = map:position()
  local layer = nil
  if profile and profile.layer_of and last_name then
    layer = profile.layer_of(last_name)
  end
  return { rooms = map:count(), x = x, y = y, z = z, layer = layer,
           policy = policy, layer_corrections = layer_corrections }
end

function M.desyncs()
  return desync_count
end

-- A plain-text snapshot of the map for an exhaustion report: the position and
-- counters, what the room we stand in reports next to what the map holds for
-- it, and every recorded room with its exits. Each exit is marked by where it
-- leads -- "*" into a coordinate never recorded (frontier: an exhausted map
-- should have none), "." into a recorded room -- so a hidden branch shows up
-- as a real exit the map believes leads somewhere already seen.
function M.dump_lines()
  local out = {}
  local function add(s) out[#out + 1] = s end
  if not map then add("no map held"); return out end
  local x, y, z = map:position()
  add(string.format("position %d,%d,%d  rooms %d  policy %s  desyncs %d  "
    .. "layer corrections %d  stop reason %s", x, y, z, map:count(), policy,
    desync_count, layer_corrections, tostring(stop_reason_val)))
  add("current room name: " .. tostring(last_name))
  add("current room exits (last frame): " .. table.concat(last_exits, " "))
  local here = map:room(x, y, z)
  if here then
    local rec = {}
    for _, dir in ipairs(map_mod.DIR_ORDER) do
      if here.exits[dir] then rec[#rec + 1] = dir end
    end
    add("current room exits (map): " .. table.concat(rec, " "))
  else
    add("current room exits (map): position not recorded")
  end

  local per_layer, keys = {}, {}
  for k, room in pairs(map.rooms) do
    per_layer[room.z] = (per_layer[room.z] or 0) + 1
    keys[#keys + 1] = k
  end
  local layers = {}
  for lz, n in pairs(per_layer) do layers[#layers + 1] = lz end
  table.sort(layers)
  local parts = {}
  for _, lz in ipairs(layers) do parts[#parts + 1] = "z" .. lz .. "=" .. per_layer[lz] end
  add("rooms per layer: " .. table.concat(parts, " "))

  table.sort(keys, function(a, b)
    local ra, rb = map.rooms[a], map.rooms[b]
    if ra.z ~= rb.z then return ra.z < rb.z end
    if ra.y ~= rb.y then return ra.y > rb.y end
    return ra.x < rb.x
  end)
  add("rooms (x,y,z: exit. = into recorded room, exit* = into unrecorded):")
  for _, k in ipairs(keys) do
    local room = map.rooms[k]
    local ex = {}
    for _, dir in ipairs(map_mod.DIR_ORDER) do
      if room.exits[dir] then
        local d = map.delta[dir]
        local seen = map:visited(room.x + d[1], room.y + d[2], room.z + d[3])
        ex[#ex + 1] = dir .. (seen and "." or "*")
      end
    end
    add(string.format("  %s: %s", k, table.concat(ex, " ")))
  end
  return out
end

-- Test seam: place the tracked position directly. Production code only ever
-- moves by committing a direction it emitted.
function M.debug_set_position(x, y, z)
  if map then map:set_position(x, y, z) end
end

-- The profile the current or paused run holds, or nil once neither a run nor
-- a retained map exists. Lifetime follows the MAP, not `active`: the stepper
-- reads this for the area's target vocabulary, and a paused run inside the
-- area still has to answer with its own targets rather than nil -- falling
-- through to vocabulary()'s speedwalk fallback would send a stale place's
-- targets at a mob in an area they have nothing to do with. M.discard() is
-- what clears it; M.stop() (pause) deliberately does not.
function M.profile()
  return profile
end

function M.room_key()
  if not active or not map then return nil end
  local x, y, z = map:position()
  return "xyz:" .. x .. "," .. y .. "," .. z
end

return M
