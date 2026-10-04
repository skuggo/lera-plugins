-- Autostepper Plugin for Lera
-- Automatically walks routes, checking rooms and killing targets
-- Requires: speedwalk, roominfo plugins

local M = {}
M.name = "autostepper"
M.version = "1.0"
M.priority = 40  -- After roominfo (10), before speedwalk (50)

--------------------------------------------------------------------------------
-- Dependencies
--------------------------------------------------------------------------------

-- Output colours. buffer.color_print takes (bg, fg, text) triplets with fg as
-- nil, a 0-255 palette index or "RRGGBB" (src/lua/api_buffer.c:461) -- the same
-- call every other plugin in this tree prints its replies with
-- (guild_viking/autotrader/tick.lua, mercenary/command_ui.lua). The red is
-- autotrader's, deliberately: a hard stop should look the same wherever it
-- comes from.
--
-- The TAG is one fixed colour on every line, so the stepper's own narration is
-- findable in a busy combat scroll. The MESSAGE colour says what kind of line
-- it is -- the distinction worth having at a glance is "it moved" vs "it
-- attacked" vs "something needs me" -- and ordinary narration is left at nil,
-- the buffer's default foreground: repainting every line would make the
-- colours mean nothing.
--
-- Loudness is the organising idea, not prettiness: a step is the line the
-- stepper emits most, so it is the quietest thing on the list, and the eye
-- should be pulled by the rare lines instead. Headings are violet rather than
-- a second amber -- next to COLOR_WARN one more gold would have read as "look
-- at this" when it only means "a report starts here".
local COLOR_TAG   = "5FAFD7"   -- steel blue: the [autostepper] tag, always
local COLOR_INFO  = nil        -- ordinary narration: the default foreground
local COLOR_HEAD  = "CE93D8"   -- violet: report headings (Status:, Commands:)
local COLOR_RUN   = "9CCC65"   -- green: start, stop, complete, mode changes
local COLOR_STEP  = "9E9E9E"   -- grey: movement, the routine line
local COLOR_FIGHT = "FF8A65"   -- coral: attacking
local COLOR_WARN  = "FFC107"   -- amber: a guess, a refusal, something to see
local COLOR_ERROR = "FF4444"   -- red: the run cannot go on (autotrader's red)
local COLOR_TRACE = "78909C"   -- slate: /step trace, off by default

-- The last HISTORY_MAX log and trace lines, kept whether or not tracing is on,
-- so an exhaustion dump can say what led up to it after the fact.
local HISTORY_MAX = 120
local history = {}

local function remember(msg)
  history[#history + 1] = string.format("%9.1f %s",
    (lera and lera.time and lera.time()) or 0, tostring(msg))
  if #history > HISTORY_MAX then table.remove(history, 1) end
end

local function log(msg, color)
  remember(msg)
  buffer.color_print(nil, COLOR_TAG, "[autostepper] ",
                     nil, color or COLOR_INFO, tostring(msg))
end

-- Narration from a module that does not own the palette: explore/mode.lua
-- names the KIND of line it is emitting and this maps it, so the colours have
-- exactly one definition and retuning them stays a one-block edit.
local COLOR_BY_KIND = {
  run = COLOR_RUN, step = COLOR_STEP, fight = COLOR_FIGHT,
  warn = COLOR_WARN, error = COLOR_ERROR, head = COLOR_HEAD,
}

local function log_kind(msg, kind)
  log(msg, kind and COLOR_BY_KIND[kind] or COLOR_INFO)
end

-- /step trace exposes room frames, refreshes, and movement decisions.
local tracing = false

local function trace(msg)
  if not tracing then remember("trace: " .. msg); return end
  log("trace: " .. msg, COLOR_TRACE)
end

local sw = nil      -- speedwalk plugin (set in on_load)
local ri = nil      -- roominfo plugin (set in on_load)
local explore = require("explore.mode")

-- Hand the explore module our logger, so its narration wears the same tag and
-- the same palette. Guarded because debug_set_explore installs partial
-- stand-ins; a module given no logger falls back to a plain tagged print.
local function wire_explore_logger()
  if explore and explore.set_logger then explore.set_logger(log_kind) end
end
wire_explore_logger()

-- Area profiles, by name. A profile is data plus four predicates; no engine
-- logic lives in one.
local AREAS = {
  chaossea = "areas.chaossea",
}
local area_cache = {}

local function load_area(name)
  if area_cache[name] then return area_cache[name] end
  local path = AREAS[name]
  if not path then return nil end
  local ok, mod = pcall(require, path)
  if not ok then
    log("area '" .. name .. "' failed to load: " .. tostring(mod), COLOR_ERROR)
    return nil
  end
  area_cache[name] = mod
  return mod
end

-- Test seam: swap the explore module for a stand-in.
function M.debug_set_explore(stub)
  explore = stub or require("explore.mode")
  wire_explore_logger()
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local state = "idle"    -- idle, stepping, fighting
local enabled = false   -- Is autostepper active?
local movement_trigger_ids = {}
local no_target_trigger_id = nil  -- Trigger ID for "There is no X here."
local failed_attacks = 0  -- count of attacks whose keyword never resolved
-- Post-combat refresh waits that exhausted their attempts, shown in /step status.
local unanswered_refreshes = 0

-- Which source do_step() takes steps from: "explore" or "route". Fixed once,
-- in M.start, and never re-derived from explore.active() per step. Deciding
-- it fresh every step meant that the moment explore mode deactivated itself
-- mid-run (the in_area check leaving the area, say), the very next do_step()
-- would take the route branch and call sw.take_step() -- walking a stored
-- speedwalk path from wherever the player now stands, outside the area.
local run_mode = nil
local route_commands = {} -- Unsent commands in the current speedwalk segment
local step_dispatch = nil -- Commands sent and entries acknowledged in this step

-- Chaos Sea farm mode keeps starting fresh instances only after the current
-- explore run reaches the profile's completion room. It is deliberately
-- configured independently of starting or stopping an explore run.
local chaossea_farm = {
  enabled = false,
  level = 0,
  difficulty = "risky",
  restart_timer = nil,
}

local restart_chaossea

local function cancel_farm_restart()
  if chaossea_farm.restart_timer then
    timer.cancel(chaossea_farm.restart_timer)
    chaossea_farm.restart_timer = nil
  end
end

local cask_announced = false -- Kept across pause/resume; reset for a fresh sea.
local pushn = nil

local function get_push_notify()
  local current = plugin and plugin.get("push_notify")
  if current ~= pushn then
    pushn = current
    if pushn and pushn.register_channel then
      -- Separate channels let discovery and restart arrive close together.
      pushn.register_channel("chaossea_cask")
      pushn.register_channel("chaossea_farm")
      pushn.register_channel("explore_exhausted")
    end
  end
  return pushn
end

local function push_event(channel, message)
  local sink = get_push_notify()
  if sink and sink.notify then sink.notify(channel, message) end
end

-- Only a complete Room.Contents list acknowledges entry. Room.Info supplies
-- exits and Room.Map supplies display data; neither proves the occupants are
-- known. A timeout stops the run without inventing a successful move.
local ARRIVAL_TIMEOUT_MS = 5000
local arrival_timer = nil
local arrival_kind = nil  -- "refresh" (start), "setup", or "move"
local movement_failure = nil
local frames_seen = 0
local frames_at_step = 0
local room_info_sub = nil
local room_frame_sub = nil

-- Per-room view, seeded on arrival and replaced by post-combat refreshes.
-- Failed keyword attempts are still removed locally by the existing recovery
-- handler; they must not cause a repeated attack against the same missing id.
local room_key = nil        -- identity of the room the view below describes
local room_monsters = {}    -- monster names still believed to be standing
local room_players = {}     -- player names seen on arrival
local current_target = nil  -- monster do_attack() is working on
local current_target_keyword = nil  -- target actually sent to the MUD

-- Char.Combat is the sole combat-end signal. Starting/resuming cannot switch
-- to guessing while the next combat snapshot is in flight.
local combat_gmcp_sub = nil     -- gmcp handler id, removed on unload
local room_contents_sub = nil   -- roominfo.on_room_contents id, removed on unload

-- After combat ends, ask for the actual remaining occupants. Allow delayed
-- replies and retry dropped requests, but never infer a kill from silence.
local REFRESH_TIMEOUT_MS = 3000
local REFRESH_MAX_ATTEMPTS = 3
local awaiting_refresh = false   -- stays true across retries until answered/stopped
local refresh_timeout_id = nil

-- Configuration
local config = {
  attack_cmd = "kill",        -- Command prefix for attacking (kill <target>)
  auto_attack = true,         -- Attack valid targets automatically
  step_on_player = true,      -- Take step if player in room (don't fight)
  step_on_no_monster = true,  -- Take step if no monsters
  targets_only = false,       -- Only kill monsters in target list (-> mode)
  -- nil until the user picks one with "/step set dive on|off". It must stay
  -- nil: the AREA PROFILE defaults the policy (spec 5.3), and a value here
  -- is passed to explore.start unconditionally, which would make the
  -- profile's own default_policy unreachable dead config.
  explore_policy = nil,      -- "clear" | "dive"; see explore/map.lua
}

-- Full display names only: fold case and whitespace, never patterns/substrings.
local ignored_monsters = {}
local function normalize_mob_name(name)
  if type(name) ~= "string" or name:find("[%z\1-\8\11\12\14-\31\127]") then return nil end
  local normalized = name:lower():gsub("%s+", " "):match("^%s*(.-)%s*$")
  if normalized ~= "" then return normalized end
end

local function load_mobignore()
  ignored_monsters = {}
  if not store then return end
  store.load()
  local data = store.get()
  local names = type(data) == "table" and data.ignored_monsters
  if type(names) ~= "table" then return end
  for name, value in pairs(names) do
    local normalized = normalize_mob_name(name)
    if value == true and normalized then ignored_monsters[normalized] = true end
  end
end

local function save_mobignore()
  if store then
    local data = store.get()
    if type(data) ~= "table" then data = {} end
    local names = {}
    for name in pairs(ignored_monsters) do names[name] = true end
    data.ignored_monsters = names
    if store.set(data) and store.save() then return end
  end
  log("Mob ignore changed in memory, but could not save it for this profile", COLOR_WARN)
end

local function dispatch_mobignore(rest)
  local action, name = rest:match("^(%S*)%s*(.-)%s*$")
  action = action:lower()
  local normalized = normalize_mob_name(name)
  if (action == "add" or action == "remove") and normalized then
    if action == "add" then
      if ignored_monsters[normalized] then
        log("Already ignoring mob: " .. normalized)
        return
      end
      ignored_monsters[normalized] = true
      log("Ignoring mob: " .. normalized)
    else
      if not ignored_monsters[normalized] then
        log("Mob not in ignore list: " .. normalized)
        return
      end
      ignored_monsters[normalized] = nil
      log("Removed ignored mob: " .. normalized)
    end
    save_mobignore()
  elseif (action == "list" or action == "") and name == "" then
    local names = {}
    for n in pairs(ignored_monsters) do names[#names + 1] = n end
    table.sort(names)
    log("Ignored mobs (exact normalized display names): " .. #names)
    for _, n in ipairs(names) do log("  " .. n) end
  elseif action == "clear" and name == "" then
    ignored_monsters = {}
    save_mobignore()
    log("Mob ignore list cleared")
  else
    log("Usage: /step mobignore add|remove <name> | list | clear", COLOR_WARN)
  end
end

-- Callbacks
local on_step_callbacks = {}      -- Called when a step is taken
local on_attack_callbacks = {}    -- Called when attacking
local on_complete_callbacks = {}  -- Called when route complete
local on_skip_callbacks = {}      -- Called when skipping a monster

--------------------------------------------------------------------------------
-- Internal Functions
--------------------------------------------------------------------------------

local function notify(callbacks, ...)
  for _, cb in ipairs(callbacks) do
    local ok, err = pcall(cb, ...)
    if not ok then
      log("Callback error: " .. tostring(err), COLOR_ERROR)
    end
  end
end

local function copy_names(list)
  local out = {}
  for i, n in ipairs(list or {}) do out[i] = n end
  return out
end

-- roominfo's identity for the room we are standing in. Falls back to the room
-- name, and then to a constant, so an unsynced roominfo seeds the view once
-- rather than on every decision.
local function roominfo_room_key()
  -- While exploring, the coordinate is the only usable identity. roominfo's is
  -- not: an area with no room ids reports nil, and its name is the same for a
  -- whole layer, so the key would never change and the local monster view would
  -- never reseed between rooms.
  if explore and explore.active() then
    local key = explore.room_key()
    if key then return key end
  end
  if not ri then return "?" end
  local rid = ri.room_id and ri.room_id()
  if rid then return "id:" .. tostring(rid) end
  local name = ri.room and ri.room()
  if name and name ~= "" then return "name:" .. name end
  return "?"
end

-- Reseed the local view when roominfo says we are somewhere new. Reading
-- roominfo here rather than from its on_room_change callback is deliberate:
-- Room.Info fires that notification before the new room's Room.Contents has
-- been handled, so a callback would seed the previous room's occupants.
local function sync_room_view()
  local key = roominfo_room_key()
  if key == room_key then
    trace("view kept (key " .. tostring(key) .. ", " .. #room_monsters
          .. " tracked)")
    return
  end
  local was = room_key
  room_key = key
  room_monsters = copy_names(ri and ri.monsters and ri.monsters())
  room_players = copy_names(ri and ri.players and ri.players())
  current_target = nil
  current_target_keyword = nil
  trace("view reseeded " .. tostring(was) .. " -> " .. tostring(key)
        .. " (" .. #room_monsters .. " monsters, " .. #room_players
        .. " players from roominfo)")
end

-- Strike one occurrence of a finished target from the local view.
local function forget_monster(name)
  if not name then return end
  for i, n in ipairs(room_monsters) do
    if n == name then
      table.remove(room_monsters, i)
      return
    end
  end
end

local process_room  -- room callbacks call it; it calls do_step
local complete_arrival

local function cancel_refresh_wait()
  if refresh_timeout_id then
    timer.cancel(refresh_timeout_id)
    refresh_timeout_id = nil
  end
  awaiting_refresh = false
end

-- The keyword guess in do_attack() is exactly that -- a guess -- and can fail
-- to resolve: "kill <keyword>" against a monster whose vocabulary does not
-- include it answers "There is no <keyword> here." and starts no fight, so
-- with nothing watching for that answer the run would wait forever for a
-- combat-end signal that can never arrive.
--
-- The pattern also matches missing items and "There is no reason to '...'
-- here." command errors, including while fighting. Require the exact keyword
-- sent by do_attack(), as well as the fighting state with no refresh pending.
-- While awaiting_refresh the fight has ended; a missing-target line cannot
-- answer the outstanding room contents request.
--
-- Legacy had this trigger, but its handler only counted failures in its
-- multi-target "dimhall" mode and did nothing for a single failed attack --
-- this recovery rule is a design decision here, not a port.
--
-- Termination: every firing removes one entry from the finite local view via
-- forget_monster(), so a room is always resolved in a bounded number of
-- attempts. A later Room.Refresh (only ever sent after a SUCCESSFUL fight)
-- can re-seed a monster that previously failed, costing one wasted attempt
-- per refresh, but the sequence still terminates because refreshes are
-- themselves bounded by successful fights. Without the prune here, the next
-- decision would pick the same monster, send the same failing keyword, and
-- fail identically forever.
local function on_attack_no_target(_, name)
  if state ~= "fighting" or awaiting_refresh then return end
  if not current_target_keyword or name ~= current_target_keyword then return end
  cancel_refresh_wait()  -- defensive; the gate above means there should be none
  forget_monster(current_target)
  current_target = nil
  current_target_keyword = nil
  state = "idle"
  failed_attacks = failed_attacks + 1
  log("Attack did not resolve: \"" .. tostring(name) .. "\"", COLOR_WARN)
  process_room()
end

-- The answer arrived: reseed the local view from roominfo UNCONDITIONALLY,
-- ignoring the room key. The room has not changed -- we are asking about the
-- room we are already standing in -- and the whole point of the refresh is to
-- replace the local view with the server's own answer, so the normal
-- "only reseed on a new room" gate must not apply here.
local function reseed_and_decide()
  cancel_refresh_wait()
  room_monsters = copy_names(ri and ri.monsters and ri.monsters())
  room_players = copy_names(ri and ri.players and ri.players())
  current_target = nil
  current_target_keyword = nil
  state = "idle"
  process_room()
end

-- Arm every attempt before sending, including retries: a synchronous reply
-- must cancel this timer before it can interrupt a subsequent move or fight.
local function request_combat_refresh(attempt)
  refresh_timeout_id = timer.after(REFRESH_TIMEOUT_MS, function()
    refresh_timeout_id = nil
    if not enabled or not awaiting_refresh then return end
    if attempt < REFRESH_MAX_ATTEMPTS then
      log("Room.Refresh still unanswered; retrying (" .. (attempt + 1)
          .. "/" .. REFRESH_MAX_ATTEMPTS .. ")", COLOR_WARN)
      request_combat_refresh(attempt + 1)
      return
    end
    unanswered_refreshes = unanswered_refreshes + 1
    log("Room.Refresh went unanswered after " .. REFRESH_MAX_ATTEMPTS
        .. " attempts; stopping without discarding the target", COLOR_WARN)
    M.stop()
  end)
  trace("Room.Refresh attempt " .. attempt .. "/" .. REFRESH_MAX_ATTEMPTS
        .. "; awaiting the answer")
  if not gmcp.send("Room.Refresh", { packages = { "Room.Contents" } }) then
    log("Room.Refresh could not be sent; stopping without discarding the target",
        COLOR_WARN)
    M.stop()
  end
end

-- Keep the same wait active across retries so duplicate combat-end frames
-- and unrelated no-target text cannot start a second decision.
local function handle_combat_end()
  if state ~= "fighting" or awaiting_refresh then return end
  awaiting_refresh = true
  request_combat_refresh(1)
end

-- gmcp.on("Char.Combat", cb): an absent attacker ends the current fight.
local function on_char_combat(_, data)
  if type(data) ~= "table" then return end
  local attacker = data.attacker
  local has_attacker = attacker ~= nil and attacker ~= ""
  if has_attacker then return end
  handle_combat_end()
end

-- Room entry lists are marked by the server. Refresh/subscription snapshots
-- are not arrivals, even when they land while a movement is outstanding.
local function on_room_contents_frame(info)
  -- An entry the stepper did not ask for -- wimpy, a mob moving the player,
  -- a direction typed by hand mid-run or while paused -- moves the player
  -- without a committed step, so the explore map's dead-reckoned position is
  -- now wrong. Maze rooms mostly share their neighbours' exits, so the
  -- contradiction check rarely catches it; instead the offset makes unvisited
  -- rooms land on recorded coordinates, and the run ends "exhausted" with rooms
  -- left. The position cannot be recovered in an area without room ids, so the
  -- map is dropped here and the next start or resume maps afresh.
  local unasked = info and info.entry and not (enabled and state == "stepping")
  if unasked and explore and explore.profile and explore.profile() then
    explore.reset("moved without a step; position unknown")
    if enabled then
      log("Moved outside the stepper; stopping", COLOR_WARN)
      M.stop()
      return
    end
  end
  if not enabled then return end
  if awaiting_refresh then
    if info and info.entry then
      log("Room changed during combat; stopping", COLOR_WARN)
      M.stop()
      return
    end
    trace("refresh answered")
    reseed_and_decide()
    return
  end
  if state ~= "stepping" then return end
  if arrival_kind ~= "refresh" and not (info and info.entry) then
    trace("contents refresh ignored while awaiting room entry")
    return
  end
  if arrival_kind == "setup" then
    local prof = explore and explore.profile and explore.profile()
    if not (prof and prof.in_area and ri and prof.in_area(ri.room())) then return end
  end
  complete_arrival()
end

local function cancel_arrival()
  if arrival_timer then timer.cancel(arrival_timer) end
  arrival_timer = nil
  arrival_kind = nil
  movement_failure = nil
end

local begin_arrival_wait

complete_arrival = function()
  if not enabled or state ~= "stepping" then return end
  local dispatch = step_dispatch
  if dispatch and dispatch.explore_batch then
    if dispatch.arrived >= dispatch.sent then
      log("Unexpected entry during frontier speedwalk; stopping", COLOR_WARN)
      M.stop()
      return
    end
    local desyncs = explore.desyncs()
    local corrections = explore.stats().layer_corrections
    explore.on_arrival()
    if not explore.active() or explore.desyncs() ~= desyncs
        or explore.stats().layer_corrections ~= corrections then
      log("Frontier speedwalk no longer matches the map; stopping", COLOR_WARN)
      M.stop()
      return
    end
    dispatch.arrived = dispatch.arrived + 1
    trace("frontier speedwalk entry " .. dispatch.arrived .. "/" .. dispatch.total)
    if dispatch.arrived < dispatch.total then
      begin_arrival_wait("move")
      return
    end
  elseif explore and explore.active() then
    explore.on_arrival()
  end
  step_dispatch = nil
  cancel_arrival()
  state = "idle"
  trace("arrival committed by Room.Contents; "
        .. (frames_seen - frames_at_step) .. " frame(s) since the step")
  process_room()
end

-- Room.Info updates exits independently; Contents commits the arrival later.
local function on_room_info_frame()
  if explore and explore.active() and explore.on_frame and ri and ri.info then
    explore.on_frame(ri.info())
  end
end

local function on_room_frame_arrival()
  frames_seen = frames_seen + 1
  trace("frame #" .. frames_seen .. " (state " .. state .. ", "
        .. tostring(ri and ri.monster_count and ri.monster_count())
        .. " monsters in roominfo)")
end

begin_arrival_wait = function(kind)
  cancel_arrival()
  state = "stepping"
  arrival_kind = kind
  frames_at_step = frames_seen
  arrival_timer = timer.after(ARRIVAL_TIMEOUT_MS, function()
    arrival_timer = nil
    log(movement_failure and ("Movement blocked: " .. movement_failure .. "; stopping")
        or "Room entry went unanswered; stopping at the last confirmed position",
        COLOR_WARN)
    M.stop()
  end)
end

local function on_movement_failure(line)
  if not enabled or state ~= "stepping" or arrival_kind ~= "move" then return end
  movement_failure = tostring(line)
  if step_dispatch and step_dispatch.explore_batch then
    -- Later queued commands may succeed even if this one failed: their entries
    -- cannot be assigned safely to the original path, including wizard warnings.
    log("Movement reported blocked during frontier speedwalk; stopping", COLOR_WARN)
    M.stop()
    return
  end
  -- A Chaossea blocker prints the warning even for a wizard allowed to pass.
  -- Keep the pending direction until entry confirms movement or the watchdog
  -- stops it. A text response never commits or rolls back coordinates.
  trace("movement reported blocked; awaiting entry confirmation")
end

local function request_room_refresh()
  return gmcp.send("Room.Refresh", { packages = { "Room.Info", "Room.Contents" } })
end

-- Attempt to resume a paused, retained explore run in place -- shared by
-- bare "/step explore" and the "-."/"->" shorthands. Refuses (and changes
-- nothing) unless explore.retained() says a map and profile are held AND
-- explore.resume() itself agrees the room the player is standing in now is
-- still inside the profile's area; either way the caller falls back to
-- starting fresh. Logging lives here so both callers say "Resuming" rather
-- than "Starting".
local function try_resume_explore()
  if not (explore and explore.retained and explore.retained() and explore.resume) then
    return false
  end
  explore.attach(ri)
  if not explore.resume() then return false end
  local rooms = (explore.stats and explore.stats().rooms) or 0
  log("Resuming explore (" .. rooms .. " rooms)", COLOR_RUN)
  return true
end

-- The target vocabulary in force: a speedwalk place carries its own list, and
-- an explore run -- which has no place -- uses the area profile's. Same shape
-- and same meaning either way, so everything below reads one list and does not
-- care which supplied it.
--
-- The profile is asked FIRST, and the order is load-bearing -- but only
-- WITHIN an explore run. M.start skips the place/load_steps path entirely for
-- an explore run, so speedwalk's target list is whatever an earlier route run
-- happened to leave behind -- a stale "gremlin" would otherwise be sent at
-- every mob in the sea, and it is the profile that describes the ground
-- actually being walked.
--
-- The other half, now that M.stop() pauses instead of discarding: a paused
-- explore run's profile is retained, so it must not reach a route run at
-- all, or the sequence "explore the sea, -!, .someplace, -." would run the
-- route with the sea's vocabulary -- the same stale-target defect the
-- paragraph above exists to prevent, just pointing the other way. Gated on
-- run_mode, not explore.active(): run_mode is fixed once per run in M.start
-- for exactly this reason (see its declaration), and re-deriving "is this an
-- explore run" from explore.active() here would reopen the same
-- per-step-drift hole that fixing run_mode was for.
local function vocabulary()
  if run_mode ~= "explore" then
    local place = (sw and sw.get_targets and sw.get_targets()) or {}
    return place
  end
  -- Guarded rather than assumed: the explore stand-in in the unit tests is a
  -- partial table, and an area profile need not declare targets at all.
  local prof = explore and explore.profile and explore.profile()
  local area = prof and prof.targets
  if type(area) == "table" and #area > 0 then return area end
  local place = (sw and sw.get_targets and sw.get_targets()) or {}
  if #place > 0 then return place end
  return {}
end

-- The first vocabulary entry that appears in a monster's display name, in its
-- authored case -- speedwalk's match_target rule, applied to whichever list is
-- in force. Used for BOTH the targets-only validity decision and the command,
-- so "-> in the sea attacks nothing" and "kill sends a word the mob does not
-- answer to" cannot come apart again.
local function match_vocabulary(monster)
  if type(monster) ~= "string" then return nil end
  local lower = monster:lower()
  for _, entry in ipairs(vocabulary()) do
    local trimmed = tostring(entry):match("^%s*(.-)%s*$")
    if trimmed ~= "" and lower:find(trimmed:lower(), 1, true) then
      return trimmed
    end
  end
  return nil
end

-- Words that begin a trailing clause rather than continue the noun phrase. Cut
-- there and the head noun is the last word before it: "a whirling monstrosity
-- with three heads" -> monstrosity, "an amalgamation of death" -> amalgamation.
-- ("in" and "and" need the bracket form; they are Lua keywords.)
local PHRASE_STOP = {
  of = true, with = true, ["in"] = true, on = true, at = true, from = true,
  ["and"] = true, that = true, who = true, which = true,
  wearing = true, holding = true, carrying = true, wielding = true,
  covered = true, standing = true, sitting = true, lying = true,
}

-- Last resort, when there is no vocabulary at all: the head noun of the
-- display name. A monster does not answer to its short -- Room.Contents
-- carries capitalize(no_ansi(short())) (room/room.c:722-734) while
-- obj/monster.c:538 id() matches only the name, an alias, or the race -- so
-- sending the short verbatim answers "There is no <the whole short> here." and
-- starts no fight. The head noun IS an id by mudlib convention, because
-- set_alias is conventionally seeded with the noun words of the name
-- (example/mobs/chaos_corr.c:115). Still a guess; just one that can resolve.
local function head_noun(display)
  if type(display) ~= "string" then return nil end
  -- A wizard-only entry is query_cap_name() .. " (invis)" (room/room.c:718);
  -- the parenthetical is no part of any id.
  local phrase = display:gsub("%s*%b()%s*$", "")
  local words = {}
  for word in phrase:lower():gmatch("[%a'%-]+") do
    if PHRASE_STOP[word] then break end
    words[#words + 1] = word
  end
  if #words > 1 and
     (words[1] == "a" or words[1] == "an" or words[1] == "the") then
    table.remove(words, 1)
  end
  -- Nothing usable (an all-punctuation short, or a name that is one stop word)
  -- leaves the caller to send what it has rather than an empty command.
  return words[#words]
end

-- current_target stays the DISPLAY name (see the comment on its declaration):
-- forget_monster() strikes names out of room_monsters, which is seeded from
-- Room.Contents display names, not from the keyword vocabulary. What actually
-- goes out on the wire is resolved separately, below.
local function do_attack(monster)
  state = "fighting"
  current_target = monster

  -- 1. A vocabulary keyword that appears in this monster's name wins outright.
  -- 2. Otherwise, in attack-anything mode with a non-empty vocabulary, guess
  --    the first entry -- legacy's "unparsed" case: the list is the area's
  --    monster vocabulary, so it usually resolves, but it IS a guess.
  -- 3. Otherwise (targets-only with no match, or no vocabulary at all), the
  --    head noun of the display name. Never the display name itself: that is
  --    the one string the mob is guaranteed not to answer to.
  local send_target = match_vocabulary(monster)
  if not send_target then
    local targets = (not config.targets_only) and vocabulary() or {}
    if #targets > 0 then
      send_target = targets[1]
      log("No target keyword matched \"" .. monster .. "\"; guessing \""
          .. send_target .. "\"", COLOR_WARN)
    else
      send_target = head_noun(monster) or monster
    end
  end

  current_target_keyword = send_target
  local cmd = config.attack_cmd .. " " .. send_target
  log("Attacking: " .. monster, COLOR_FIGHT)
  notify(on_attack_callbacks, monster, cmd)
  mud.send(cmd)
end

-- These route commands do not move the player. Other custom commands may
-- move (for example enter portal), so require entry before sending another.
local PREPARATION_COMMANDS = { open = true, close = true, unlock = true,
  lock = true, look = true, glance = true }

local function is_preparation(cmd)
  return PREPARATION_COMMANDS[tostring(cmd):lower():match("^%s*(%S+)")] == true
end

-- Exhaustion reports. A plugin has no io and no os.getenv in Lera's sandbox,
-- so they go through the plugin store, alongside the mob-ignore list: the last
-- DUMP_KEEP reports, newest last, in the profile's .storage/autostepper.json.
local DUMP_KEEP = 5

local function write_explore_dump(why)
  local lines = {}
  local function add(s) lines[#lines + 1] = s end
  add(os.date("%Y-%m-%d %H:%M:%S") .. "  " .. tostring(why))
  local prof = explore and explore.profile and explore.profile()
  add("area: " .. tostring(prof and prof.name) .. "  run_mode: "
      .. tostring(run_mode) .. "  state: " .. tostring(state))
  if ri then
    add("roominfo room: " .. tostring(ri.room and ri.room()))
    add("roominfo exits: " .. tostring(ri.exits_string and ri.exits_string()))
    local mobs = ri.monsters and ri.monsters() or {}
    add("roominfo monsters: " .. table.concat(copy_names(mobs), ", "))
  end
  add("-- map")
  for _, l in ipairs(explore and explore.dump_lines and explore.dump_lines() or {}) do
    add(l)
  end
  add("-- last " .. #history .. " log/trace lines (seconds since client start)")
  for _, l in ipairs(history) do add(l) end

  -- A diagnostic must never be what breaks a run: any failure here is logged
  -- and swallowed.
  local ok, saved = pcall(function()
    if not (store and store.get and store.set and store.save) then return false end
    local data = store.get()
    if type(data) ~= "table" then data = {} end
    local dumps = type(data.explore_dumps) == "table" and data.explore_dumps or {}
    dumps[#dumps + 1] = lines
    while #dumps > DUMP_KEEP do table.remove(dumps, 1) end
    data.explore_dumps = dumps
    return store.set(data) and store.save()
  end)
  if ok and saved then
    local dir = store.path and store.path()
    log("Map dump saved to " .. (dir and (dir .. "/autostepper.json") or "the plugin store")
        .. " (explore_dumps, newest last)", COLOR_WARN)
    return true
  end
  log("Could not save the explore dump" .. (ok and "" or (": " .. tostring(saved))),
      COLOR_WARN)
  return false
end

local function do_step(monsters)
  local step
  local notify_step = true
  local moves = true
  if run_mode == "explore" then
    if not (explore and explore.active()) then
      -- The mode deactivated itself mid-run -- today that means it saw the
      -- room name leave the area (§6.6). The RUN is over. Falling through to
      -- sw.take_step() here would walk a stored speedwalk path from wherever
      -- we now stand, which is exactly what the exhaustion branch below
      -- refuses to do, reached by a different door.
      log("Explore mode ended; stopping", COLOR_RUN)
      enabled = false
      state = "idle"
      cancel_arrival()
      notify(on_complete_callbacks)
      return false
    end
    -- Completion belongs to the cleared room, before frontier selection.
    -- The cask can be reached while other branches remain unexplored. Use
    -- process_room's filtered mobs so profile ignores apply to completion too.
    local prof = explore.profile and explore.profile()
    local at_completion = #monsters == 0 and prof and prof.name == "chaossea"
      and prof.complete and ri and ri.items
      and prof.complete({ items = ri.items() })
    if at_completion and ri.contents_truncated and ri.contents_truncated() then
      -- A dropped inventory entry could be a living boss. Stop without
      -- claiming completion or scheduling another farm instance.
      log("Cask/portal contents are truncated; stopping without confirming completion",
          COLOR_WARN)
      M.stop()
      return false
    end
    if not at_completion then step = explore.next_step() end
    if not step then
      -- Reached the completion room, exhausted the map, or finished leaving.
      -- None may fall through to a stored speedwalk path in this maze.
      local reason = (explore.stop_reason and explore.stop_reason()) or "exhausted"
      if at_completion then
        log("Chaos Sea complete: cask/portal reached", COLOR_RUN)
      elseif reason == "at origin" then
        log("Explored: back at the origin", COLOR_RUN)
      elseif reason == "in flight" then
        log("Asked for a step while a move is still unconfirmed; stopping "
            .. "(the map is NOT exhausted -- please report this)", COLOR_WARN)
      elseif reason == "inactive" then
        log("Explore map unavailable; stopping (not exhausted)", COLOR_WARN)
      else
        log("Explored: no unvisited exits remain", COLOR_RUN)
      end
      if not at_completion and (reason == "exhausted" or reason == "in flight") then
        write_explore_dump("explore stopped: " .. reason)
      end
      enabled = false
      state = "idle"
      cancel_arrival()
      if chaossea_farm.enabled and at_completion then
        log("Chaos Sea farm: completion reached; preparing the next instance",
            COLOR_RUN)
        if explore.stop then explore.stop() end
        chaossea_farm.restart_timer = timer.after(1000, function()
          chaossea_farm.restart_timer = nil
          if chaossea_farm.enabled then
            restart_chaossea()
          end
        end)
        return false
      end
      -- Exhaustion ends the RUN, not just the stepping (6.5). Left active, the
      -- next "-." would re-enter explore mode, instantly re-exhaust the same
      -- map and never reach route mode at all.
      if explore.stop then explore.stop() end
      if not at_completion and reason == "exhausted" then
        push_event("explore_exhausted",
          "Autostepper: exploration stopped; no unvisited exits remain.")
      end
      notify(on_complete_callbacks)
      return false
    end
  else
    if #route_commands == 0 then
      step = sw.take_step()
      if step then route_commands = copy_names(step.commands) end
    else
      step = { raw = route_commands[1] }
      notify_step = false
    end
    if step then
      -- Send preparation plus exactly one possible movement. Retain the rest
      -- across arrivals and fights, including expanded routes such as 2n.
      local commands = {}
      moves = false
      while #route_commands > 0 do
        local cmd = table.remove(route_commands, 1)
        commands[#commands + 1] = cmd
        if not is_preparation(cmd) then moves = true; break end
      end
      step = { raw = step.raw, commands = commands }
    end
    if not step then
      log("Route complete!", COLOR_RUN)
      enabled = false
      state = "idle"
      cancel_arrival()
      notify(on_complete_callbacks)
      return false
    end
  end

  local dispatch = {
    total = #step.commands, sent = 0, arrived = 0,
    explore_batch = run_mode == "explore" and #step.commands > 1,
  }
  step_dispatch = dispatch
  if moves then begin_arrival_wait("move") end
  log("Step: " .. step.raw, COLOR_STEP)
  if notify_step then
    notify(on_step_callbacks, step.raw, sw and sw.step_info and sw.step_info())
  end

  for _, cmd in ipairs(step.commands) do
    -- Callbacks and test transports can stop or complete a step synchronously.
    if not enabled or step_dispatch ~= dispatch then return false end
    dispatch.sent = dispatch.sent + 1
    mud.send(cmd)
  end
  if not enabled or step_dispatch ~= dispatch then return false end
  if not moves then return do_step(monsters) end

  return true
end

function process_room()
  if not ri then
    log("Error: roominfo plugin not available", COLOR_ERROR)
    M.stop()
    return
  end

  -- Announce discovery before fighting the boss, once per fresh explore run.
  local prof = run_mode == "explore" and explore and explore.profile()
  if not cask_announced and prof and prof.name == "chaossea" and prof.cask_found
      and ri.items and prof.cask_found({ items = ri.items() }) then
    cask_announced = true
    push_event("chaossea_cask", "Chaos Sea: cask found in " .. (ri.room() or "unknown room"))
  end

  -- Decisions use the arrival or post-combat snapshot already committed.
  sync_room_view()
  trace("deciding in state " .. state .. " (run_mode "
        .. tostring(run_mode) .. ")")
  local players = room_players
  -- Keep the authoritative local view intact: edits take effect at the next
  -- decision, and removing an ignore must not lose a still-present monster.
  local monsters = {}
  for _, monster in ipairs(room_monsters) do
    if not ignored_monsters[normalize_mob_name(monster) or ""] then
      monsters[#monsters + 1] = monster
    end
  end
  local room = ri.room() or "unknown"

  -- Check if player in room
  if #players > 0 and config.step_on_player then
    log("Player in room (" .. room .. "), stepping...", COLOR_STEP)
    do_step(monsters)
    return
  end

  -- Check if no monsters
  if #monsters == 0 and config.step_on_no_monster then
    log("No monsters in room (" .. room .. "), stepping...", COLOR_STEP)
    do_step(monsters)
    return
  end

  -- Monsters present - decide whether to attack
  if #monsters > 0 then
    if config.targets_only then
      -- Only attack monsters in target list
      for _, monster in ipairs(monsters) do
        if match_vocabulary(monster) then
          if config.auto_attack then
            do_attack(monster)
            return
          else
            log("Valid target found but auto_attack disabled: " .. monster,
                COLOR_WARN)
          end
        end
      end
      -- No valid targets - skip and step
      log("Monster not in target list (" .. monsters[1] .. "), stepping...",
          COLOR_STEP)
      notify(on_skip_callbacks, monsters[1], room)
      do_step(monsters)
      return
    else
      -- Attack any monster (first one)
      if config.auto_attack then
        do_attack(monsters[1])
        return
      else
        log("Monster found but auto_attack disabled: " .. monsters[1],
            COLOR_WARN)
      end
    end
  end

  -- Fallback - just step
  do_step(monsters)
end

--------------------------------------------------------------------------------
-- Aliases
--------------------------------------------------------------------------------

local alias_ids = {}  -- Store alias IDs for the movement shorthands
local command_id = nil

-- require("command") is optional: a profile that never required 'commands' has
-- no registry, and the "-" shorthands still work.
local command
do
  local ok, mod = pcall(require, "command")
  if ok then command = mod end
end

local function show_help()
  log("Commands:", COLOR_HEAD)
  log("  -.                     - Start/resume stepping, kill any mob")
  log("  ->                     - Start/resume stepping, only kill targets")
  log("  -!                     - Stop stepping")
  log("  /step status           - Show farm settings, restart/wait state and travel progress")
  log("  /step trace [on|off]   - Log room frames, refreshes and decisions")
  log("  /step dump             - Save the explore map and recent history (last 5 kept)")
  log("                           to .storage/autostepper.json; automatic when exploring ends 'exhausted'")
  log("  /step mobignore add|remove <name> | list | clear")
  log("                           Exact full name, case/whitespace normalized; saved per profile")
  log("  /step explore [area]   - Start explore mode in an area (default: chaossea)")
  log("  /step explore off      - Stop explore mode")
  log("  /step explore reset    - Reset here; stops and discards an outstanding frontier speedwalk")
  log("  /step explore leave    - Walk back to the run's origin, fighting on the way;")
  log("                           wait for the current route to arrive; the last step out is yours")
  log("  /step chaossea farm <level> <difficulty> - Configure farming without starting")
  log("                           difficulty: risky, alarming or deadly")
  log("  /step chaossea farm off - Disable farming without stopping exploration")
  log("  /step set attack [on|off] - Toggle auto-attack")
  log("  /step set kill [cmd]      - Set/show attack command prefix")
  log("  /step set dive [on|off]   - Toggle explore dive policy")
  log("  /step set config       - Show configuration")
  log("Exploration speedwalks the full route through known rooms to the next unexplored room.")
  log("Each entry updates position; combat and exploration decisions wait for the destination.")
  log("Stops after five seconds without an entry. No prompt setup needed; /step trace on for details.")
  log("Interrupted frontier speedwalks discard the map; wait for queued moves before restarting.")
  log("Combat refreshes wait three seconds per attempt, with two retries before stopping.")
  log("Stop the active run before starting another. Resume a paused run with -.")
  log("Start in the current Sea with /step explore [chaossea]; farm config sends no setup commands.")
  log("Stop cancels pending restarts but keeps farm settings; farm off disables repeats.")
  log("Chaos Sea stops at the cask/portal after clearing non-ignored mobs; configured farm then restarts.")
  log("Farm restarts wait through the portal lobby for confirmed entry into the new maze.")
  log("Push alerts: /pushn toggle chaossea_cask and /pushn toggle chaossea_farm (default off).")
  log("Cask alerts fire on discovery, before combat; farm alerts fire when setup commands are sent.")
  log("/pushn toggle explore_exhausted alerts when exploration runs out of reachable unvisited rooms (default off).")
end

-- The movement shorthands stay raw aliases: "-", "-.", "->" and "-!" are input
-- syntax, not slash tokens the command registry can express. Everything
-- word-shaped moved to /step.
local function register_aliases()
  -- "-" - show help
  alias_ids[#alias_ids + 1] = alias.add("^-$", function()
    show_help()
    return nil
  end)

  -- "-." - start stepping, kill any mob
  alias_ids[#alias_ids + 1] = alias.add("^-\\.$", function()
    M.start(false)
    return nil
  end)

  -- "->" - start stepping, only kill targets
  alias_ids[#alias_ids + 1] = alias.add("^->$", function()
    M.start(true)
    return nil
  end)

  -- "-!" - stop stepping
  alias_ids[#alias_ids + 1] = alias.add("^-!$", function()
    M.stop()
    return nil
  end)
end

local function unregister_aliases()
  for _, id in ipairs(alias_ids) do
    if id then alias.remove(id) end
  end
  alias_ids = {}
end

--------------------------------------------------------------------------------
-- Command
--------------------------------------------------------------------------------

local function show_farm_status()
  log("  Chaos Sea farm: " .. (chaossea_farm.enabled and "on" or "off"))
  log(string.format("  Farm settings: level %d, %s", chaossea_farm.level, chaossea_farm.difficulty))
  local restart = "none"
  if chaossea_farm.enabled and chaossea_farm.restart_timer then
    restart = "scheduled"
  elseif chaossea_farm.enabled and enabled and run_mode == "explore" then
    restart = arrival_kind == "setup" and "waiting for maze entry" or "after cask"
  end
  log("  Farm restart: " .. restart)
end

local function waiting_for()
  if awaiting_refresh then return "combat contents refresh" end
  if arrival_kind == "setup" then return "maze entry" end
  if arrival_kind == "move" then return "room entry" end
  if arrival_kind == "refresh" then return "initial room contents" end
  if state == "fighting" then return "combat end" end
  if chaossea_farm.enabled and chaossea_farm.restart_timer then return "farm restart" end
  return "nothing"
end

local function show_config()
  log("Configuration:", COLOR_HEAD)
  log("  attack_cmd: " .. config.attack_cmd)
  log("  auto_attack: " .. tostring(config.auto_attack))
  log("  targets_only: " .. tostring(config.targets_only))
  log("  explore_policy: " .. (config.explore_policy or "profile default"))
  show_farm_status()
end

-- "set" takes a key and an optional value; with no value each key reports what
-- it currently holds, which is what the bare "-set <key>" aliases used to do.
local function dispatch_set(rest)
  local key, value = rest:match("^(%S*)%s*(.-)%s*$")
  key = key:lower()

  if key == "" or key == "help" then
    show_help()
  elseif key == "status" then
    M.status()
  elseif key == "config" then
    show_config()
  elseif key == "attack" then
    if value == "" then
      log("Auto-attack: " .. (config.auto_attack and "on" or "off"))
    elseif value == "on" or value == "off" then
      config.auto_attack = (value == "on")
      log("Auto-attack " .. (config.auto_attack and "enabled" or "disabled"))
    else
      log("Usage: /step set attack [on|off]", COLOR_WARN)
    end
  elseif key == "kill" then
    if value == "" then
      log("Attack command: " .. config.attack_cmd)
    else
      config.attack_cmd = value
      log("Attack command set: " .. config.attack_cmd)
    end
  elseif key == "dive" then
    if value == "" then
      -- Report what is in EFFECT, which is the live run's policy while one is
      -- running and the config only once the user has set it. Before that the
      -- honest answer is that the area profile decides -- printing "off" there
      -- would claim a setting nothing holds.
      local effective = nil
      if explore and explore.active() and explore.policy then
        effective = explore.policy()
      else
        effective = config.explore_policy
      end
      if effective then
        log("dive: " .. (effective == "dive" and "on" or "off"))
      else
        log("dive: profile default")
      end
    elseif value == "on" or value == "off" then
      config.explore_policy = (value == "on") and "dive" or "clear"
      if explore and explore.active() then explore.set_policy(config.explore_policy) end
      log("dive: " .. (config.explore_policy == "dive" and "on" or "off"))
    else
      log("Usage: /step set dive [on|off]", COLOR_WARN)
    end
  else
    log("Unknown setting: " .. key, COLOR_WARN)
    show_help()
  end
end

local function dispatch(args)
  local sub, rest = tostring(args or ""):match("^%s*(%S*)%s*(.-)%s*$")
  sub = sub:lower()

  if sub == "" or sub == "help" then
    show_help()
  elseif sub == "set" then
    dispatch_set(rest)
  elseif sub == "mobignore" then
    dispatch_mobignore(rest)
  elseif sub == "status" then
    M.status()
  elseif sub == "trace" then
    local arg = rest:match("^(%S*)"):lower()
    if arg == "on" then
      tracing = true
      log("Trace on: every frame, refresh and decision is logged.",
          COLOR_RUN)
    elseif arg == "off" then
      tracing = false
      log("Trace off", COLOR_RUN)
    elseif arg == "" then
      log("trace: " .. (tracing and "on" or "off"))
    else
      log("Usage: /step trace [on|off]", COLOR_WARN)
    end
  elseif sub == "dump" then
    write_explore_dump("requested with /step dump")
  elseif sub == "start" then
    M.start(false)
  elseif sub == "targets" then
    M.start(true)
  elseif sub == "stop" then
    M.stop()
  elseif sub == "chaossea" then
    if rest:match("^farm%s+off$") then
      M.chaossea_farm_off()
    else
      local level, difficulty = rest:match("^farm%s+(%d+)%s+(%a+)$")
      M.chaossea_farm_config(level, difficulty)
    end
  elseif sub == "explore" then
    local arg = rest:match("^(%S*)")
    if arg == "off" then
      M.explore_stop()
    elseif arg == "reset" then
      M.explore_reset()
    elseif arg == "leave" then
      M.explore_leave()
    elseif arg ~= "" then
      -- Naming an area is a statement of intent: always start fresh, even
      -- with a paused run's map retained.
      if M.explore_start(arg) then M.start(config.targets_only) end
    else
      -- No area named: resume a retained, in-area run when possible; only
      -- fall back to starting fresh (in the default area) when it is not.
      if try_resume_explore() then
        M.start(config.targets_only)
      elseif M.explore_start("chaossea") then
        M.start(config.targets_only)
      end
    end
  else
    log("Unknown subcommand: " .. sub, COLOR_WARN)
    show_help()
  end
end

local function register_command()
  if not command then return end
  local id, err = command.register({
    name = "/step",
    aliases = { "/autostepper" },
    usage = "/step [start|targets|stop|explore [area]|explore off|explore reset|"
      .. "explore leave|chaossea farm <level> <difficulty>|chaossea farm off|"
      .. "mobignore add|remove <name>|mobignore list|mobignore clear|"
      .. "status|trace [on|off]|set <key> [value]]",
    summary = "Automatic speedwalk stepping with optional combat",
    description = "Walks a stored step path one room at a time, optionally "
      .. "attacking on the way. Or, with 'explore [area]', maps an "
      .. "unmapped area, speedwalking the full shortest route through known rooms to "
      .. "the next unexplored room. Each entry updates position; combat and exploration "
      .. "decisions wait for the destination. 'chaossea farm <level> <difficulty>' configures "
      .. "repeats without starting, moving or notifying. Both arguments are required; "
      .. "difficulty is risky, alarming or deadly. Start in the current Sea with "
      .. "'explore [chaossea]'. Stops cancel pending restarts but keep the configuration; "
      .. "'chaossea farm off' disables repeats without stopping exploration. "
      .. "Chaos Sea stops at the cask/portal after "
      .. "clearing non-ignored mobs; farm mode then starts the next instance, waiting "
      .. "through the portal lobby for confirmed entry into the new maze. "
      .. "Push channels 'chaossea_cask' (discovery, before combat) and 'chaossea_farm' "
      .. "(each automatic restart), plus 'explore_exhausted' (no reachable unvisited rooms), "
      .. "default off; enable them with "
      .. "'/pushn toggle <channel>'. Existing push grace and rate limits apply. Otherwise "
      .. "exploration stops once every reachable exit leads somewhere already "
      .. "mapped. 'explore off' stops it early, "
      .. "'explore reset' resets the map to a fresh origin at the current room and "
      .. "re-asks the MUD (during a frontier speedwalk it stops and discards the map). "
      .. "'explore leave' refuses while a route is outstanding; otherwise it walks the "
      .. "shortest recorded route back to the run's origin, fighting anything met on "
      .. "the way -- this does NOT leave the area itself, since the explorer never "
      .. "walks an excluded exit, so the final step out is still the player's own. "
      .. "'mobignore add|remove <name>', "
      .. "'mobignore list' and 'mobignore clear' manage a per-profile saved ignore list. "
      .. "Names match the entire GMCP display name after lowercasing, trimming and "
      .. "collapsing whitespace; punctuation and articles are literal. Ignored mobs "
      .. "are neither attacked nor counted in route/explore/farm decisions. "
      .. "Changes apply on the next room decision, not by cancelling a current fight. "
      .. "Complete entry contents track each move; no prompt setup is needed. "
      .. "Stops after five seconds without an entry. Interrupted or blocked frontier "
      .. "speedwalks discard the map; wait for already queued moves to finish before restarting. "
      .. "'status' shows farm on/off, level, difficulty, restart and wait state, "
      .. "attack settings and frontier travel progress. 'set config' also shows farm settings. "
      .. "Use 'trace on' to inspect arrivals and combat decisions. Stop an active "
      .. "run before starting another. The shorthands are '-.' to start/resume "
      .. "on any mob, '->' to start/resume on targets only, "
      .. "'-!' to stop, and '-' for help. Settings: status, config, attack, "
      .. "kill, dive.",
    accepts_args = true,
    handler = dispatch,
  })
  if id then
    command_id = id
  else
    log("command registration failed: " .. tostring(err), COLOR_ERROR)
  end
end

local function unregister_command()
  -- The loader drops a plugin's commands on unload; unregistering here keeps a
  -- manual reload from colliding with its own leftover record.
  if command and command_id then
    pcall(command.unregister, command_id)
    command_id = nil
  end
end

--------------------------------------------------------------------------------
-- Plugin Hooks
--------------------------------------------------------------------------------

function M.on_load()
  load_mobignore()
  -- Try to get dependencies
  sw = plugin.get("speedwalk")
  ri = plugin.get("roominfo")

  if not sw then
    log("Warning: speedwalk plugin not loaded", COLOR_WARN)
  end
  if not ri then
    log("Warning: roominfo plugin not loaded", COLOR_WARN)
  end

  if ri and ri.on_room_info then
    room_info_sub = ri.on_room_info(on_room_info_frame)
  end
  if ri and ri.on_room_contents then
    room_contents_sub = ri.on_room_contents(on_room_contents_frame)
  end
  if ri and ri.on_room_frame then
    room_frame_sub = ri.on_room_frame(on_room_frame_arrival)
  end
  if gmcp and gmcp.on then
    combat_gmcp_sub = gmcp.on("Char.Combat", on_char_combat)
  end

  -- Text failures are advisory; only GMCP can confirm entry or combat end.
  if trigger and trigger.add then
    no_target_trigger_id = trigger.add("^There is no (.*?) here\\.$", on_attack_no_target)
    for _, pattern in ipairs({
      "^.* blocks your way!$", "^The .* bars your way!$",
      "^You can't go that way\\.$", "^You cannot go that way\\.$",
    }) do
      movement_trigger_ids[#movement_trigger_ids + 1] = trigger.add(pattern, on_movement_failure)
    end
  end

  -- Register the movement shorthands and the /step command
  register_aliases()
  register_command()

  log("Loaded (use /step help for commands)", COLOR_RUN)
end

function M.on_setup()
  get_push_notify()
end

function M.on_unload()
  pushn = nil
  unregister_aliases()
  unregister_command()

  if room_info_sub and ri and ri.off_room_info then
    ri.off_room_info(room_info_sub)
  end
  room_info_sub = nil

  if room_contents_sub and ri and ri.off_room_contents then
    ri.off_room_contents(room_contents_sub)
  end
  room_contents_sub = nil

  if room_frame_sub and ri and ri.off_room_frame then
    ri.off_room_frame(room_frame_sub)
  end
  room_frame_sub = nil

  if combat_gmcp_sub and gmcp and gmcp.remove then
    gmcp.remove(combat_gmcp_sub)
  end
  combat_gmcp_sub = nil

  if no_target_trigger_id and trigger and trigger.remove then
    trigger.remove(no_target_trigger_id)
  end
  no_target_trigger_id = nil
  for _, id in ipairs(movement_trigger_ids) do trigger.remove(id) end
  movement_trigger_ids = {}

  M.stop()
  -- Unlike an ordinary stop, unloading the plugin is real teardown: there is
  -- no later "-." to hand a retained map back to once this instance is gone.
  if explore and explore.discard then explore.discard() end
  log("Unloaded", COLOR_RUN)
end

-- A disconnected run cannot confirm any pending move or fight.
function M.on_disconnect()
  M.stop()
end

-- A re-dive invalidates a retained map. Pause/resume keeps the map across a
-- stop, guarded by profile.in_area(<current room>) -- but that guard cannot
-- tell one Chaos Sea instance from the next: a fresh sea reuses every room
-- name, so resuming into a NEW sea reckons against the OLD sea's map until
-- contradicted topology eventually forces a reset. The client is the one
-- asking for the new instance, though, so watching commands on their way out
-- turns "might be a different instance" into "is one".
--
-- The patterns come from the area profile (M.instance_reset), never
-- hardcoded here: explore mode is area-agnostic by design, and the Chaos Sea
-- is meant to be data only. Read with explore.profile(), not vocabulary() --
-- a re-dive normally happens while the stepper is stopped, and vocabulary()
-- is gated on run_mode == "explore"; explore.profile() answers from the
-- retained profile, which is exactly why it stays ungated.
--
-- Residual: a re-dive the client never sees -- typed in another session, or
-- sent by an alias through some other path -- still slips through. The
-- topology-contradiction reset in explore/mode.lua remains the backstop
-- there. The real fix is a maze_id in Room.Info, which the owner has
-- deferred.
local function check_instance_reset(text)
  if type(text) ~= "string" then return end
  local prof = explore and explore.profile and explore.profile()
  local patterns = prof and prof.instance_reset
  if type(patterns) ~= "table" then return end
  local held = explore and ((explore.retained and explore.retained())
    or (explore.active and explore.active()))
  if not held then return end
  local trimmed = text:match("^%s*(.-)%s*$"):lower()
  for _, pattern in ipairs(patterns) do
    if trimmed:find(pattern) then
      log("explore: \"" .. trimmed .. "\" starts a new instance; discarding the retained map",
          COLOR_RUN)
      if step_dispatch and step_dispatch.explore_batch then M.stop() end
      explore.discard()
      return
    end
  end
end

-- Both are filter hooks and must return their text unchanged -- returning nil
-- or false here would silently eat the very command (setsea, unsetsea, enter
-- sea) the player or a script just issued.
function M.on_input(text)
  check_instance_reset(text)
  return text
end

function M.on_send(text)
  check_instance_reset(text)
  return text
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Start autostepping at current place
-- targets_only: if true, only kill monsters in target list; if false, kill any monster
function M.start(targets_only, from_entry)
  if enabled then
    log("Already running; stop before starting another run", COLOR_WARN)
    return false
  end
  if not sw then
    sw = plugin.get("speedwalk")
    if not sw then
      log("Error: speedwalk plugin required", COLOR_ERROR)
      return false
    end
  end

  if not ri then
    ri = plugin.get("roominfo")
    if not ri then
      log("Error: roominfo plugin required", COLOR_ERROR)
      return false
    end
  end

  local exploring = explore and explore.active()
  -- "-." / "->" call straight in here with no area named -- resuming a
  -- retained, in-area run is what makes the plain gesture pick a paused
  -- explore run back up instead of falling through to route mode.
  if not exploring then
    exploring = try_resume_explore()
  end
  -- Fixed once, here, for the whole run -- see the run_mode declaration for
  -- why do_step() must not re-derive this from explore.active() per step.
  run_mode = exploring and "explore" or "route"

  if not exploring then
    local place = sw.get_current_place()
    if not place then
      log("Error: current place not set (use .set <place>)", COLOR_ERROR)
      return false
    end

    if not sw.load_steps() then
      log("Error: no steps configured for place '" .. place .. "'", COLOR_ERROR)
      log("Use speedwalk.configure_place('" .. place .. "', 'n|s|e|w', 'target1,target2')")
      return false
    end

    local info = sw.step_info()
    local targets = sw.get_targets()
    config.targets_only = targets_only or false
    local mode_label = config.targets_only and "targets only" or "any mob"
    log("Starting at '" .. place .. "': " .. info.total .. " steps ("
        .. mode_label .. ")", COLOR_RUN)
    if config.targets_only and #targets > 0 then
      log("Targets: " .. table.concat(targets, ", "))
    end
  else
    config.targets_only = targets_only or false
    log("Starting explore run (" .. (explore.stats().policy or "clear") .. ")",
        COLOR_RUN)
  end

  cancel_farm_restart()
  enabled = true
  route_commands = {}
  state = "idle"
  -- Forget any stale view so the room we are standing in is seeded afresh.
  room_key = nil
  current_target = nil
  current_target_keyword = nil
  cancel_refresh_wait()

  -- Setup commands can pass through other rooms before entering the new sea.
  -- Only that final entry starts exploration; a refresh could still describe
  -- the previous instance while the command queue is being processed.
  begin_arrival_wait(from_entry and "setup" or "refresh")
  if not from_entry and not request_room_refresh() then
    log("Room.Refresh could not be sent; stopping", COLOR_WARN)
    M.stop()
    return false
  end

  return true
end

-- Stop autostepping
function M.stop()
  cancel_farm_restart()
  if enabled then
    log("Stopped", COLOR_RUN)
  end
  cancel_arrival()
  cancel_refresh_wait()
  enabled = false
  state = "idle"
  run_mode = nil
  route_commands = {}
  current_target = nil
  current_target_keyword = nil
  if step_dispatch and step_dispatch.explore_batch then
    -- Already transmitted commands may still move the player after this stop.
    log("Interrupted frontier speedwalk; discarding the map. Wait for queued moves before restarting.", COLOR_WARN)
    explore.discard()
  end
  step_dispatch = nil
  -- explore.stop() PAUSES rather than discards: it is dead reckoned, so what
  -- used to be guarded against here -- the next "-." resuming that reckoning,
  -- and the combat that goes with it, wherever the player is now standing
  -- after walking out of the area -- is now explore.resume()'s job, which
  -- checks the CURRENT room against the area before letting a resume
  -- through. Pausing keeps the map and profile so that check has something
  -- to resume back into.
  if explore and explore.active() and explore.stop then explore.stop() end
end

function M.explore_start(area_name)
  if enabled then
    log("Already running; stop before starting another run", COLOR_WARN)
    return false
  end
  local prof = load_area(area_name)
  if not prof then
    log("Unknown area '" .. tostring(area_name) .. "'", COLOR_WARN)
    return false
  end
  explore.attach(ri)
  if not explore.start(prof, config.explore_policy) then
    log("Explore mode failed to start", COLOR_ERROR)
    return false
  end
  cask_announced = false
  log("Explore mode active: " .. prof.name, COLOR_RUN)
  return true
end

-- Configuration applies to the next completed Sea, including a restart that
-- is already scheduled. It never sends commands or changes the current run.
function M.chaossea_farm_config(level, difficulty)
  level = tonumber(level)
  if not level or level < 0 or level > 9007199254740991 or level ~= math.floor(level)
      or (difficulty ~= "risky" and difficulty ~= "alarming" and difficulty ~= "deadly") then
    log("Usage: /step chaossea farm <level> <risky|alarming|deadly> | /step chaossea farm off", COLOR_WARN)
    return false
  end
  chaossea_farm.enabled = true
  chaossea_farm.level = level
  chaossea_farm.difficulty = difficulty
  log(string.format("Chaos Sea farm configured: level %d, %s. Start/resume with /step explore.",
    level, difficulty), COLOR_RUN)
  return true
end

function M.chaossea_farm_off()
  chaossea_farm.enabled = false
  cancel_farm_restart()
  log("Chaos Sea farm off", COLOR_RUN)
  return true
end

-- Only a cleared completion room schedules the setup sequence. Its final
-- maze entry, rather than a refresh of the old instance, begins the new run.
restart_chaossea = function()
  local prof = load_area("chaossea")
  if not prof or type(prof.restart) ~= "function" then
    log("Chaos Sea setup is unavailable", COLOR_ERROR)
    return false
  end
  local level, difficulty = chaossea_farm.level, chaossea_farm.difficulty
  local commands = prof.restart({ level = level, difficulty = difficulty })
  local setup_sent = true
  for _, cmd in ipairs(commands) do
    if mud.send(cmd) == false then setup_sent = false end
  end
  log(string.format("Chaos Sea setup sent (level %d, %s)", level, difficulty), COLOR_RUN)
  if setup_sent then
    push_event("chaossea_farm", string.format("Chaos Sea farm: starting a new sea (level %d, %s)",
      level, difficulty))
  end
  if not M.explore_start("chaossea") then return false end
  return M.start(config.targets_only, true)
end

function M.explore_stop()
  if explore and explore.active() then
    explore.stop()
    log("Explore mode off", COLOR_RUN)
  end
  M.stop()
end

-- Reset the explore map to a fresh origin at the current room, mid-run:
-- mid-run is exactly when the map turns out to be wrong (a desync reset that
-- lands on the wrong layer, a frame missed before the plugin loaded). Keeps
-- the run going -- this corrects the map, it does not stop the stepper.
--
-- After mode.reset() discards the old map, the SAME Room.Refresh Item 1
-- sends on start re-asks the MUD, so the fresh origin is recorded from an
-- answer rather than the cache reset just discarded. No extra wiring is
-- needed for that answer to land: on_room_info_frame's explore.on_frame()
-- call is unconditional (fires whether or not a step is outstanding), and
-- this run's own next arrival -- in flight already, or the next step ahead --
-- commits the refreshed exits via explore.on_arrival() as it always does.
function M.explore_reset()
  if step_dispatch and step_dispatch.explore_batch then
    M.stop()
    return true
  end
  -- Works whether the run is active or merely retained (paused): resetting a
  -- stopped run must not start the player walking, so mode.reset() itself
  -- leaves `active` exactly as it found it -- this only checks that a map
  -- exists to reset in the first place.
  local has_map = explore and ((explore.active and explore.active())
    or (explore.retained and explore.retained()))
  if not has_map then
    log("No explore map to reset", COLOR_WARN)
    return false
  end
  explore.reset("manual reset")
  request_room_refresh()
  log("Explore map reset; re-asking the MUD for the current room", COLOR_RUN)
  return true
end

-- Walk back to the run's origin -- the room the explorer started in, which
-- for the target area is the entry room. Delegates entirely to mode.lua's
-- M.leave(): it arms a pending path (via Map:path_to) that next_step()
-- drains one direction per step, ahead of frontier selection, and reports
-- and changes nothing when explore mode is inactive, the origin is
-- unreachable, or it is already reached. Arrival still runs process_room()
-- exactly like any other step, so a monster met on the way out is still
-- fought -- leaving is not a reason to stop fighting.
--
-- Reaching the origin does not leave the area: the explorer never walks an
-- excluded exit (e.g. 'out' in the Chaos Sea), so the last step out remains
-- the player's own.
function M.explore_leave()
  if not (explore and explore.leave) then return false end
  return explore.leave()
end

-- Check if running
function M.is_running()
  return enabled
end

-- Get current state
function M.get_state()
  return state
end

-- Show status
function M.status()
  log("Status:", COLOR_HEAD)
  log("  Running: " .. (enabled and "yes" or "no"))
  log("  State: " .. state)
  log("  Waiting for: " .. waiting_for())
  log("  Auto-attack: " .. (config.auto_attack and "on" or "off"))
  log("  Attack command: " .. config.attack_cmd)
  show_farm_status()
  if step_dispatch and step_dispatch.explore_batch then
    log("  Frontier travel: " .. step_dispatch.arrived .. "/" .. step_dispatch.total .. " rooms")
  end
  log("  Mode: " .. (config.targets_only and "targets only (->)" or "any mob (-.)"))
  -- A climbing count is the actionable diagnostic: it means the target list
  -- does not match the area, which the user can fix and nothing else says.
  log("  Failed attacks (this session): " .. failed_attacks)
  -- Count exhausted refresh waits once; individual retries are logged above.
  log("  Unanswered refreshes (this session): " .. unanswered_refreshes)
  log("  Trace: " .. (tracing and "on" or "off"))

  local exploring = explore and explore.active()
  local retained = explore and explore.retained and explore.retained()
  if exploring then
    local s = explore.stats()
    log("  Explore: " .. (s.policy or "clear") .. ", " .. s.rooms .. " rooms, "
        .. "at " .. s.x .. "," .. s.y .. "," .. s.z
        .. (s.layer and (" (layer " .. s.layer .. ")") or ""))
    log("  Desyncs: " .. tostring(explore.desyncs and explore.desyncs() or 0))
  elseif retained then
    local s = explore.stats()
    log("  Explore: paused, " .. (s.policy or "clear") .. ", " .. s.rooms .. " rooms retained, "
        .. "at " .. s.x .. "," .. s.y .. "," .. s.z
        .. (s.layer and (" (layer " .. s.layer .. ")") or ""))
  end

  if sw and (run_mode == "route" or (not exploring and not retained)) then
    local info = sw.step_info()
    log("  Steps: " .. info.current .. "/" .. info.total ..
        " (" .. info.remaining .. " remaining)")
  end

  if ri then
    local room = ri.room()
    log("  Room: " .. (room or "(unknown)"))
    log("  Players: " .. ri.player_count())
    -- Two numbers, deliberately: roominfo's is the entry-time snapshot, which
    -- never shrinks while we stand here, and the tracked one is what the
    -- stepping decisions are actually made from.
    log("  Monsters: " .. ri.monster_count() .. " on entry, "
        .. #room_monsters .. " tracked")
    log("  Target: " .. (current_target or "(none)"))
  end
end

-- The per-room monster view stepping decisions are made from. Unlike
-- roominfo.monsters(), it shrinks as targets are finished.
function M.tracked_monsters()
  return copy_names(room_monsters)
end

-- Configuration setters
function M.set_attack_cmd(cmd)
  config.attack_cmd = cmd
end

function M.set_auto_attack(enabled)
  config.auto_attack = enabled
end

-- Register callbacks
function M.on_step(callback)
  table.insert(on_step_callbacks, callback)
end

function M.on_attack(callback)
  table.insert(on_attack_callbacks, callback)
end

function M.on_complete(callback)
  table.insert(on_complete_callbacks, callback)
end

function M.on_skip(callback)
  table.insert(on_skip_callbacks, callback)
end

return M
