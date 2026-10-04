-- autostepper explore/mode.lua unit tests. Run from the lera-plugins repo root
-- with LERA_ROOT pointing at a built Lera checkout.
--
-- The frames below are the real ones captured walking three rooms of the Chaos
-- Sea on layer one at 'risky' difficulty. Two things they prove and this suite
-- pins: every room reports num 0, so position can only come from dead
-- reckoning; and the server suppresses an identical payload, which is why the
-- capture's second room has no Room.Contents at all while the entry room --
-- also empty -- does send one.
package.path = "3scapes/autostepper/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
  if ok then
    print("CASE " .. name .. ": PASS")
  else
    failures = failures + 1
    print("CASE " .. name .. ": FAIL" .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

local printed = {}
local print_real = print
local function quiet(fn, ...)
  print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    printed[#printed + 1] = table.concat(parts, " ")
  end
  local ok, err = pcall(fn, ...)
  print = print_real
  if not ok then error(err, 0) end
end

local mode = require("explore.mode")

-- ---- the captured frames -----------------------------------------------------
local CAPTURE = {
  { num = 0, area = "Unknown", name = "Layer one of the Sea of Chaos",
    exits = { "e", "s", "w", "out" } },
  { num = 0, area = "Unknown", name = "Layer one of the Sea of Chaos",
    exits = { "e", "s", "w" } },
  { num = 0, area = "Unknown", name = "Layer one of the Sea of Chaos",
    exits = { "e", "w" } },
}

-- ---- a minimal area profile --------------------------------------------------
local WORDS = { one = 0, two = 1, three = 2 }
local profile = {
  name = "test",
  exclude_exits = { out = true, enter = true, ["in"] = true },
  dive_dirs = { "d" },
  defer_dirs = { "u" },
  default_policy = "clear",
  in_area = function(name)
    return type(name) == "string" and name:lower():find("sea of chaos", 1, true) ~= nil
  end,
  layer_of = function(name)
    local word = type(name) == "string"
      and name:lower():match("^layer%s+(%a+)%s+of the sea of chaos")
    return word and WORDS[word] or nil
  end,
  complete = function() return false end,
}

local ri_info = { room = "", room_id = nil, exits = {} }
local fake_roominfo = { info = function() return ri_info end }
mode.attach(fake_roominfo)

local function frame(f)
  ri_info = { room = f.name, room_id = nil, exits = f.exits }
  mode.on_frame(ri_info)
end

-- ---- start and first room ----------------------------------------------------
quiet(function() mode.start(profile, "clear") end)
check("start activates the mode", mode.active() == true)

frame(CAPTURE[1])
quiet(mode.on_arrival)
local st = mode.stats()
check("the entry room is recorded", st.rooms == 1, tostring(st.rooms))
check("position starts at the origin",
  st.x == 0 and st.y == 0 and st.z == 0, st.x .. "," .. st.y .. "," .. st.z)
check("the layer is read from the room name", st.layer == 0, tostring(st.layer))

-- 'out' is excluded by the profile, so it can never be proposed.
local step = mode.next_step()
check("next_step returns exactly one direction",
  step and #step.commands == 1, step and #step.commands)
check("next_step never proposes an excluded exit",
  step and step.raw ~= "out", step and step.raw)
check("next_step raw matches its command",
  step and step.raw == step.commands[1], step and step.raw)

-- ---- movement and suppression ------------------------------------------------
-- Walk the direction next_step chose, then deliver the second captured frame.
local first_dir = step.raw
frame(CAPTURE[2])
quiet(mode.on_arrival)
st = mode.stats()
check("arriving records a second room", st.rooms == 2, tostring(st.rooms))
check("position advanced by exactly one step",
  (st.x ~= 0) or (st.y ~= 0), st.x .. "," .. st.y)

-- Now the suppression case: take another step and deliver NO frame at all.
-- Suppression means the payload was identical, so this room's exits are the
-- previous room's -- which must be recorded as fact, not treated as an empty
-- room with no exits and therefore no frontier.
local before = mode.stats().rooms
step = mode.next_step()
check("a step is still available before the suppressed move", step ~= nil)
quiet(mode.on_arrival)
st = mode.stats()
check("a suppressed frame still records the room", st.rooms == before + 1,
  tostring(st.rooms))
check("frontier survives a suppressed frame", mode.next_step() ~= nil)

-- ---- stop --------------------------------------------------------------------
mode.stop()
check("stop deactivates the mode", mode.active() == false)
check("next_step is nil when inactive", mode.next_step() == nil)

-- ---- policy ------------------------------------------------------------------
quiet(function() mode.start(profile, "clear") end)
check("policy defaults to what start was given", mode.policy() == "clear",
  mode.policy())
mode.set_policy("dive")
check("set_policy switches policy", mode.policy() == "dive", mode.policy())
mode.set_policy("nonsense")
check("an unknown policy is refused and clear is kept",
  mode.policy() == "dive", mode.policy())
mode.stop()

-- ---- exclude_exits protects a walkable compass direction ---------------------
-- The premise behind an earlier mutant here -- "'out' is the first
-- compass-ordered frontier" -- does not hold: map.lua already drops 'out' on
-- its own (it has no DELTA entry and DIR_ORDER never lists it), independent
-- of mode.lua's filter_exits. filter_exits is load-bearing only for a
-- direction the lattice DOES support, which exclude_exits is documented to
-- accept: any exit name, compass directions included. 'n' is walkable (it has
-- both a DELTA and a DIR_ORDER entry) and ranks first in compass order, so a
-- profile that excludes it is the direct, documented case this guards.
local excl_profile = {
  name = "test-exclude-n",
  exclude_exits = { out = true, enter = true, ["in"] = true, n = true },
  dive_dirs = { "d" },
  defer_dirs = { "u" },
  default_policy = "clear",
  in_area = profile.in_area,
  layer_of = profile.layer_of,
  complete = function() return false end,
}

quiet(function() mode.start(excl_profile, "clear") end)
frame({ name = "Layer one of the Sea of Chaos",
        exits = { "n", "e", "s", "w", "out" } })
quiet(mode.on_arrival)

local ex1 = mode.next_step()
check("next_step never proposes an excluded compass exit",
  ex1 and ex1.raw ~= "n", ex1 and ex1.raw)
check("the excluded direction is skipped outright -- 'e' is chosen instead",
  ex1 and ex1.raw == "e", ex1 and ex1.raw)

-- Walk the direction next_step actually proposed and confirm the coordinate
-- 'n' would have produced -- (0,1,0), one step north of the origin -- was
-- never reached. Position only ever moves along what next_step proposes and
-- on_arrival commits, so this is the direct, observable form of "the room
-- north of the origin was never recorded."
frame({ name = "Layer one of the Sea of Chaos", exits = { "w" } })
quiet(mode.on_arrival)
local ex_st = mode.stats()
check("the coordinate north of the origin is never reached",
  not (ex_st.x == 0 and ex_st.y == 1),
  ex_st.x .. "," .. ex_st.y)
mode.stop()

-- ---- start seeds itself from the room we are standing in ---------------------
-- On the real path the entry room's Room.Info arrives when the player WALKS
-- INTO the area, which is before explore mode is started, and the server never
-- resends an identical payload -- so there may be no further frame at all. A
-- mode that waits for one records its origin with no exits, finds no frontier,
-- and ends the run on its first decision: the whole feature, dead. Note that no
-- frame is delivered anywhere in this section; start() has to read roominfo.
ri_info = { room = "Layer one of the Sea of Chaos", room_id = nil,
            exits = { "e", "s", "w", "out" } }
quiet(function() mode.start(profile, "clear") end)
quiet(mode.on_arrival)
local seed_st = mode.stats()
check("the seeded origin records exactly one room", seed_st.rooms == 1,
  tostring(seed_st.rooms))
check("start seeds the origin's exits from roominfo, so a frontier exists",
  mode.next_step() ~= nil, "no frontier")
check("start seeds the room name from roominfo, so the layer is known",
  seed_st.layer == 0, tostring(seed_st.layer))
mode.stop()

-- The seeded exits go through the same exclusion filter a delivered frame does.
-- 'n' is walkable and ranks first in compass order, so a profile excluding it
-- is the case that distinguishes a filtered seed from a raw one.
ri_info = { room = "Layer one of the Sea of Chaos", room_id = nil,
            exits = { "n", "e" } }
quiet(function() mode.start(excl_profile, "clear") end)
quiet(mode.on_arrival)
local seed_ex = mode.next_step()
check("a seeded exit the profile excludes is never proposed",
  seed_ex and seed_ex.raw == "e", seed_ex and seed_ex.raw)
mode.stop()

-- ---- the area profile defaults the policy ------------------------------------
-- Spec 5.3: the policy is defaulted by the area profile and only overridden by
-- the user, so started with no policy of its own the mode must take the
-- profile's. Every other case in this suite passes an explicit policy, which
-- leaves this branch unexercised and the profile field silently ignorable.
local dive_default = {
  name = "test-dive-default",
  exclude_exits = { out = true },
  dive_dirs = { "d" },
  defer_dirs = { "u" },
  default_policy = "dive",
  in_area = profile.in_area,
  layer_of = profile.layer_of,
  complete = function() return false end,
}
quiet(function() mode.start(dive_default, nil) end)
check("with no policy given, the profile's default_policy is used",
  mode.policy() == "dive", mode.policy())
mode.stop()

-- ---- next_step over a multi-hop route -----------------------------------------
-- The three-room capture above never forced this: every frontier in it was
-- adjacent to the current room, so the underlying path was always length 1
-- and 'commands = path' was indistinguishable from 'commands = { dir }'.
-- Force the distinguishing case by walking into a dead end, so the nearest
-- remaining frontier is reachable only by backtracking through an
-- already-visited room first.
local hop_profile = {
  name = "test-multihop",
  exclude_exits = { out = true, enter = true, ["in"] = true },
  dive_dirs = { "d" },
  defer_dirs = { "u" },
  default_policy = "clear",
  -- Always true, not profile.in_area: this section's room names ("Room A",
  -- "Room B (dead end)") are deliberately not sea rooms -- area membership is
  -- incidental to what this section tests (multi-hop routing), and the real
  -- in_area predicate would deactivate the mode on the very first arrival.
  in_area = function() return true end,
  -- A real layer, not nil: this section only walks 'e'/'n'/'s', so z stays
  -- reckoned at 0 throughout and a constant-0 layer never disagrees with it
  -- (no correction ever fires here). Layer is incidental to what this section
  -- tests (multi-hop routing) -- an always-nil layer_of used to make this the
  -- first place a mutated (guard-dropped) layer check reached a nil layer,
  -- which crashed inside the topology check's map:room() before the actual
  -- "unparseable layer" test ever got to run.
  layer_of = function() return 0 end,
  complete = function() return false end,
}

quiet(function() mode.start(hop_profile, "clear") end)
-- Room A has two exits so a frontier remains after the first is exhausted.
frame({ name = "Room A", exits = { "e", "n" } })
quiet(mode.on_arrival)

-- 'n' ranks before 'e' in compass order, so it is the first hop taken.
local hop1 = mode.next_step()
check("first hop heads to the compass-first frontier ('n')",
  hop1 and hop1.raw == "n", hop1 and hop1.raw)

-- Room B is a dead end: its only exit leads back to the already-visited
-- room A. The remaining frontier -- A's still-unexplored 'e' exit -- is now
-- two hops from where we're standing: south back to A, then east. The first
-- hop back ('s') is deliberately a different direction than the eventual
-- frontier ('e'), so raw and the frontier direction can't be confused.
frame({ name = "Room B (dead end)", exits = { "s" } })
quiet(mode.on_arrival)

local hop2 = mode.next_step()
check("next_step returns the entire route to the next unexplored room",
  hop2 and table.concat(hop2.commands, ",") == "s,e")
check("raw describes the whole frontier speedwalk", hop2 and hop2.raw == "s e")
check("an outstanding route cannot be replaced by another frontier plan", mode.next_step() == nil)
hop2.commands[2] = "n" -- Returning commands must not expose the retained arrival queue.
frame({ name = "Room A", exits = { "e", "n" } })
quiet(mode.on_arrival)
local transit = mode.stats()
check("first speedwalk entry commits only the first direction", transit.x == 0 and transit.y == 0)
check("the intermediate room keeps its coordinate identity", mode.room_key() == "xyz:0,0,0")
frame({ name = "Room C", exits = { "w" } })
quiet(mode.on_arrival)
local destination = mode.stats()
check("second speedwalk entry commits its own copy of the retained direction", destination.x == 1 and destination.y == 0)
mode.stop()

-- ---- z is read from the room name, not dead-reckoned -------------------------
-- Every z/layer assertion above sits at the origin room, where pending_dirs is
-- empty, map:move never runs, and dead reckoning (z stays 0) and the
-- name-derived layer (also 0 for "Layer one...") are indistinguishable. No
-- fixture above ever takes a "d" or "u" step, so the layer-override block in
-- on_arrival -- the entire reason this module reads z from the room name
-- instead of the vertical delta -- has never actually been exercised.
--
-- The maze's set_level_exit_pairs((["down":"up"])) makes "down" the level-UP
-- direction, so a "d" step must INCREASE z. Dead reckoning alone would give
-- z = -1 here; only the name-derived layer gives the correct z = 1 -- that
-- is what discriminates a correct implementation from one that either
-- skips the override or gets its sign backwards.
quiet(function() mode.start(profile, "clear") end)
frame({ name = "Layer one of the Sea of Chaos", exits = { "d" } })
quiet(mode.on_arrival)

local before_corrections = mode.stats().layer_corrections
local vstep = mode.next_step()
check("the only exit -- 'd' -- is the one taken", vstep and vstep.raw == "d",
  vstep and vstep.raw)

frame({ name = "Layer two of the Sea of Chaos", exits = { "u" } })
quiet(mode.on_arrival)
local vst = mode.stats()
check("z is read from the room name, not the vertical delta -- a 'd' step still increases z",
  vst.z == 1, tostring(vst.z))
check("layer_corrections increments when the name overrides dead reckoning",
  vst.layer_corrections == before_corrections + 1, tostring(vst.layer_corrections))
mode.stop()

-- ---- the room name is the authority for z ------------------------------------
-- Not a desync: the profile reads an absolute layer out of the room name, so a
-- reckoned z that differs is corrected, not disputed. The area this exists for
-- inverts up/down (its level-exit override makes "down" increase z), which is
-- exactly why the vertical delta is never trusted.
quiet(function() mode.start(profile, "clear") end)
frame(CAPTURE[1])
quiet(mode.on_arrival)
local before_desyncs = mode.desyncs()
step = mode.next_step()
check("a step is available on layer one", step ~= nil)

-- Arrive somewhere naming layer two while we reckoned z = 0.
frame({ num = 0, area = "Unknown", name = "Layer two of the Sea of Chaos",
        exits = { "e", "w" } })
quiet(mode.on_arrival)
st = mode.stats()
check("z is taken from the room name", st.z == 1, tostring(st.z))
check("a layer correction is not a desync",
  mode.desyncs() == before_desyncs, tostring(mode.desyncs()))
check("the correction is counted", st.layer_corrections >= 1,
  tostring(st.layer_corrections))
check("the map is NOT reset by a layer correction", st.rooms >= 2,
  tostring(st.rooms))

-- An unparseable name leaves the reckoned z alone rather than zeroing it.
-- Still a sea room (in_area must stay true, or the area-exit check added for
-- Task 12 deactivates the mode before this reaches the layer_of assertion at
-- all) -- just not one layer_of's pattern can parse a word out of.
local z_before = mode.stats().z
before_desyncs = mode.desyncs()
frame({ num = 0, area = "Unknown", name = "Somewhere in the Sea of Chaos, unparseable",
        exits = { "e", "w" } })
quiet(mode.on_arrival)
check("an unparseable layer leaves z as reckoned",
  mode.stats().z == z_before, tostring(mode.stats().z))
check("an unparseable layer is not a desync",
  mode.desyncs() == before_desyncs, tostring(mode.desyncs()))
mode.stop()

-- ---- a string layer must not corrupt the map -----------------------------------
-- A profile whose layer_of returns a STRING must leave the position reckoned
-- and record exactly one room -- not a second one keyed on the garbage
-- string. This is the only case in the suite that distinguishes the
-- type(layer) == "number" guard from a nil-only check (layer ~= nil and
-- layer ~= z): a nil-only check passes every OTHER case here, including
-- Mutant 2 above, so without this case a maintainer narrowing the guard to
-- "handles the nil I've seen" would ship a guard that lets a string sail
-- straight through to map:set_position and map.lua's key(), producing a
-- garbage coordinate like "0,0,layer two" with no crash and no diagnostic.
local string_layer_profile = {
  name = "test-string-layer",
  exclude_exits = { out = true, enter = true, ["in"] = true },
  dive_dirs = { "d" },
  defer_dirs = { "u" },
  default_policy = "clear",
  in_area = function() return true end,
  layer_of = function() return "layer two" end,  -- deliberately not a number
  complete = function() return false end,
}

quiet(function() mode.start(string_layer_profile, "clear") end)
frame({ name = "Room X", exits = { "e", "w" } })
quiet(mode.on_arrival)
local sl_st = mode.stats()
check("a string layer leaves z as reckoned", sl_st.z == 0, tostring(sl_st.z))
check("a string layer is not counted as a correction",
  sl_st.layer_corrections == 0, tostring(sl_st.layer_corrections))
check("a string layer records exactly one room", sl_st.rooms == 1,
  tostring(sl_st.rooms))

-- A second arrival at the same reckoned coordinate must land on the SAME
-- room, not fork a second one keyed on the garbage string -- that is the
-- observable shape of the corruption this case guards against.
frame({ name = "Room X", exits = { "e", "w" } })
quiet(mode.on_arrival)
check("a second arrival at the same coordinate does not fork a room",
  mode.stats().rooms == 1, tostring(mode.stats().rooms))
mode.stop()

-- ---- desync: contradicted topology -------------------------------------------
-- The maze is generated once per run and each room's coordinates are baked into
-- its file name, so a coordinate's exits cannot legitimately change. If they
-- do, we are not where we think we are.
quiet(function() mode.start(profile, "clear") end)
frame({ num = 0, area = "Unknown", name = "Layer one of the Sea of Chaos",
        exits = { "e", "w" } })
quiet(mode.on_arrival)
step = mode.next_step()
local out_dir = step.raw

-- Walk out and back, so we return to the origin coordinate...
frame({ num = 0, area = "Unknown", name = "Layer one of the Sea of Chaos",
        exits = { "e", "w" } })
quiet(mode.on_arrival)
before_desyncs = mode.desyncs()

-- ...and now claim the origin has a completely different exit set.
mode.debug_set_position(0, 0, 0)
frame({ num = 0, area = "Unknown", name = "Layer one of the Sea of Chaos",
        exits = { "n", "s" } })
quiet(mode.on_arrival)
check("contradicted topology is detected",
  mode.desyncs() == before_desyncs + 1, tostring(mode.desyncs()))
check("the map is reset after a topology desync",
  mode.stats().rooms == 1, tostring(mode.stats().rooms))

-- Re-recording an identical exit set is not a contradiction.
before_desyncs = mode.desyncs()
mode.debug_set_position(0, 0, 0)
frame({ num = 0, area = "Unknown", name = "Layer one of the Sea of Chaos",
        exits = { "n", "s" } })
quiet(mode.on_arrival)
check("an identical re-record is not a desync",
  mode.desyncs() == before_desyncs, tostring(mode.desyncs()))
mode.stop()

-- ---- a desync reset keeps the layer ------------------------------------------
-- The room name names the layer we are standing on, so a reset that files this
-- room at z = 0 while the name says layer two leaves an orphan node whose
-- coordinates can collide with genuine layer-one rooms -- and the next arrival's
-- layer correction jumps z, so the room just recorded is never reached again.
quiet(function() mode.start(profile, "clear") end)
frame({ num = 0, area = "Unknown", name = "Layer two of the Sea of Chaos",
        exits = { "e", "w" } })
quiet(mode.on_arrival)
check("the layer-two origin is recorded at z = 1", mode.stats().z == 1,
  tostring(mode.stats().z))

-- Return to that coordinate and contradict its exits.
before_desyncs = mode.desyncs()
mode.debug_set_position(0, 0, 1)
frame({ num = 0, area = "Unknown", name = "Layer two of the Sea of Chaos",
        exits = { "n", "s" } })
quiet(mode.on_arrival)
check("the contradiction on layer two is detected",
  mode.desyncs() == before_desyncs + 1, tostring(mode.desyncs()))
local rst = mode.stats()
check("the map is reset", rst.rooms == 1, tostring(rst.rooms))
check("the fresh origin keeps the layer the room name gives it", rst.z == 1,
  tostring(rst.z))

-- And the room really was filed there, not at z = 0: arriving at (0,0,1) again
-- with the same exits finds it rather than forking a second node.
mode.debug_set_position(0, 0, 1)
frame({ num = 0, area = "Unknown", name = "Layer two of the Sea of Chaos",
        exits = { "n", "s" } })
quiet(mode.on_arrival)
check("the post-reset room was filed on the layer, so a revisit finds it",
  mode.stats().rooms == 1, tostring(mode.stats().rooms))
mode.stop()

-- ---- reset drops the outstanding direction -----------------------------------
-- reset() is public: the area-entry reset and the farm loop both call it
-- between an emitted move and its arrival. A direction left pending is
-- committed by the very next on_arrival, so the fresh origin immediately walks
-- off itself and every coordinate after it is offset by one room.
quiet(function() mode.start(profile, "clear") end)
frame({ num = 0, area = "Unknown", name = "Layer one of the Sea of Chaos",
        exits = { "n", "e" } })
quiet(mode.on_arrival)
local pend = mode.next_step()
check("a direction is outstanding before the reset", pend ~= nil,
  tostring(pend))
quiet(function() mode.reset("test") end)
frame({ num = 0, area = "Unknown", name = "Layer one of the Sea of Chaos",
        exits = { "n", "e" } })
quiet(mode.on_arrival)
local pst = mode.stats()
check("the arrival after a reset lands on the fresh origin, not one step off it",
  pst.x == 0 and pst.y == 0, pst.x .. "," .. pst.y)
check("the fresh origin holds exactly one room", pst.rooms == 1,
  tostring(pst.rooms))
mode.stop()

-- ---- area entry and exit -----------------------------------------------------
-- Entering the area is what resets the map and sets the origin. Legacy needed a
-- separate location trigger and an explicit '-cs clear' for this.
quiet(function() mode.start(profile, "clear") end)
frame(CAPTURE[1])
quiet(mode.on_arrival)
step = mode.next_step()
frame(CAPTURE[2])
quiet(mode.on_arrival)
check("two rooms mapped before leaving", mode.stats().rooms == 2,
  tostring(mode.stats().rooms))

-- Step out into the wider world.
step = mode.next_step()
frame({ num = 412, area = "Town", name = "A dusty crossroads", exits = { "n", "s" } })
quiet(mode.on_arrival)
check("leaving the area deactivates the mode", mode.active() == false,
  tostring(mode.active()))
check("an outside room is not mapped into the area map",
  mode.stats().rooms == 0, tostring(mode.stats().rooms))

-- Re-entering starts a clean run: a new maze instance is a different lattice,
-- so anything retained would be contradicted topology from the first frame on.
quiet(function() mode.start(profile, "clear") end)
frame(CAPTURE[1])
quiet(mode.on_arrival)
check("re-entering starts from one room", mode.stats().rooms == 1,
  tostring(mode.stats().rooms))
local rx, ry, rz = mode.stats().x, mode.stats().y, mode.stats().z
check("re-entering starts at the origin", rx == 0 and ry == 0 and rz == 0,
  rx .. "," .. ry .. "," .. rz)

-- M.start's fresh map must not depend on M.stop() having run first. Every
-- path above reaches a fresh start through M.stop() (explicit, or the
-- in_area check's internal call), which already nils map on its own -- so
-- none of them can tell "M.start always resets the map" apart from "the map
-- happened to already be nil". Call start() again directly, with no stop()
-- in between, while the map still holds the two rooms recorded above.
step = mode.next_step()
frame(CAPTURE[2])
quiet(mode.on_arrival)
check("a second room is mapped before the direct re-start",
  mode.stats().rooms == 2, tostring(mode.stats().rooms))
quiet(function() mode.start(profile, "clear") end)
check("starting again without an intervening stop still gives a fresh map",
  mode.stats().rooms == 0, tostring(mode.stats().rooms))
mode.stop()

-- ---- M.leave: walking back to the origin --------------------------------------
-- Reuses hop_profile (in_area always true, layer_of a constant 0) so area
-- membership and layer correction stay incidental to what this section
-- tests: leave's refusal cases and next_step's pending-path precedence.

quiet(function() mode.start(hop_profile, "clear") end)
check("stop_reason defaults to exhausted before any leave",
  mode.stop_reason() == "exhausted", mode.stop_reason())
mode.stop()

-- Refuses when explore mode is not active.
check("leave refuses when explore mode is not active", mode.leave() == false)

-- ---- narration goes through the stepper's logger when one is handed over ----
-- init.lua owns the colour palette, so this module names the KIND of line it
-- is emitting and lets the logger colour it. Two properties: an installed
-- logger receives both the message and its kind, and a module with no logger
-- still narrates on its own through a plain tagged print -- which is what the
-- rest of this suite relies on.
local sent_to_logger = {}
mode.set_logger(function(msg, kind)
  sent_to_logger[#sent_to_logger + 1] = { msg = msg, kind = kind }
end)
check("a refusal reaches an installed logger instead of print",
  mode.leave() == false and #sent_to_logger == 1,
  tostring(#sent_to_logger))
check("the logger is told the message",
  sent_to_logger[1] and sent_to_logger[1].msg:find("leave refused", 1, true) ~= nil,
  sent_to_logger[1] and sent_to_logger[1].msg)
check("the logger is told the kind, not a colour",
  sent_to_logger[1] and sent_to_logger[1].kind == "warn",
  sent_to_logger[1] and tostring(sent_to_logger[1].kind))

mode.set_logger(nil)
local before_printed = #printed
quiet(function() mode.leave() end)
check("with no logger the module falls back to a tagged print",
  #printed == before_printed + 1 and
    printed[#printed]:find("[autostepper] ", 1, true) == 1,
  printed[#printed])
check("a non-function logger is refused rather than called",
  (function()
     mode.set_logger("not a function")
     local n = #printed
     quiet(function() mode.leave() end)
     return #printed == n + 1
   end)(), printed[#printed])

-- Refuses when already at the origin: the origin is recorded (path_to's
-- target-recorded check passes) and we are standing on it, so path_to
-- returns the empty array, not nil -- the "already there" case, not
-- "cannot get there".
quiet(function() mode.start(hop_profile, "clear") end)
frame({ name = "Leave Origin", exits = { "e" } })
quiet(mode.on_arrival)
check("the origin is recorded before testing the already-there refusal",
  mode.stats().rooms == 1, tostring(mode.stats().rooms))
check("leave refuses when already at the origin", mode.leave() == false)

-- Refuses when the origin is unreachable: a second, disconnected room (no
-- exits of its own, and nothing else's exit points at it) with no recorded
-- path back to (0,0,0) -- the shape a desync reset can leave behind.
mode.debug_set_position(9, 9, 0)
frame({ name = "Nowhere near the origin", exits = {} })
quiet(mode.on_arrival)
check("a second, disconnected room is recorded",
  mode.stats().rooms == 2, tostring(mode.stats().rooms))
check("leave refuses when the origin is unreachable", mode.leave() == false)
mode.stop()

-- A pending leave path takes precedence over frontier selection, drains one
-- direction per call, and completing it reports "at origin" rather than a
-- further step. A THREE-room corridor, not two: a one-hop leave path cannot
-- distinguish "return one direction" from "return the whole remaining path"
-- -- both look identical when there is only one direction to return.
quiet(function() mode.start(hop_profile, "clear") end)
frame({ name = "Room A", exits = { "e" } })
quiet(mode.on_arrival)
step = mode.next_step()
check("the only frontier from the origin is 'e'", step and step.raw == "e",
  step and step.raw)
frame({ name = "Room B", exits = { "w", "e" } })
quiet(mode.on_arrival)
check("two rooms are recorded so far", mode.stats().rooms == 2,
  tostring(mode.stats().rooms))

step = mode.next_step()
check("the next frontier from Room B is 'e'", step and step.raw == "e",
  step and step.raw)
frame({ name = "Room C", exits = { "w", "n" } })
quiet(mode.on_arrival)
check("three rooms are recorded before leaving",
  mode.stats().rooms == 3, tostring(mode.stats().rooms))

local leave_ok = mode.leave()
check("leave succeeds when the origin is reachable", leave_ok == true,
  tostring(leave_ok))

-- 'n' is ALSO a frontier from here (Room C's other exit, into unvisited
-- (2,1,0)) and would be the compass-first choice if leave were not
-- consulted first -- 'w', the leave path's first hop, is what must win.
local leave_step1 = mode.next_step()
check("a pending leave path takes precedence over frontier selection",
  leave_step1 and leave_step1.raw == "w", leave_step1 and leave_step1.raw)
check("next_step returns exactly one direction while a leave is pending",
  leave_step1 and #leave_step1.commands == 1,
  leave_step1 and leave_step1.commands and #leave_step1.commands)

-- Arrival still runs the normal commit -- pending_dir is honoured exactly
-- like any other step -- landing on Room B, one hop from the origin, not
-- all the way home yet.
frame({ name = "Room B", exits = { "w", "e" } })
quiet(mode.on_arrival)
local mid_st = mode.stats()
check("the first leave hop lands one room short of the origin",
  mid_st.x == 1 and mid_st.y == 0 and mid_st.z == 0,
  mid_st.x .. "," .. mid_st.y .. "," .. mid_st.z)

local leave_step2 = mode.next_step()
check("the second leave hop is also 'w'",
  leave_step2 and leave_step2.raw == "w", leave_step2 and leave_step2.raw)
check("next_step still returns exactly one direction on the final hop",
  leave_step2 and #leave_step2.commands == 1,
  leave_step2 and leave_step2.commands and #leave_step2.commands)

frame({ name = "Room A", exits = { "e" } })
quiet(mode.on_arrival)
local back_st = mode.stats()
check("the walk back lands exactly on the origin",
  back_st.x == 0 and back_st.y == 0 and back_st.z == 0,
  back_st.x .. "," .. back_st.y .. "," .. back_st.z)

check("completing the leave path reports nil, not a further step",
  mode.next_step() == nil)
check("completing the leave path reports stop_reason 'at origin'",
  mode.stop_reason() == "at origin", mode.stop_reason())
mode.stop()

-- reset discards a pending leave path: armed but not yet drained, then
-- reset() runs. The fresh map has zero rooms, so if the path really was
-- discarded, next_step() falls through to frontier search on that empty map
-- and finds nothing -- nil. Left set (the mutant), next_step() would instead
-- return the stale leave direction ('w'), oblivious to the map having just
-- been wiped out from under it.
quiet(function() mode.start(hop_profile, "clear") end)
frame({ name = "Room A", exits = { "e" } })
quiet(mode.on_arrival)
step = mode.next_step()
frame({ name = "Room B", exits = { "w", "n" } })
quiet(mode.on_arrival)
check("leave arms a pending path before the reset", mode.leave() == true)
quiet(function() mode.reset("test") end)
local after_reset_step = mode.next_step()
check("reset discards a pending leave path",
  after_reset_step == nil, tostring(after_reset_step))
mode.stop()

-- ---- stop pauses, discard tears down, resume picks a paused run back up ----
-- Task PR: stopping used to throw the map away outright (M.stop nilled map
-- and profile), so there was no way to pause a run and resume it. M.stop()
-- now PAUSES -- keeps map, profile, last_exits, last_name; clears active,
-- pending_dir and pending_leave_path -- and M.discard() is the real teardown.
quiet(function() mode.start(profile, "clear") end)
frame(CAPTURE[1])
quiet(mode.on_arrival)
step = mode.next_step()
frame(CAPTURE[2])
quiet(mode.on_arrival)
check("two rooms are mapped before stopping", mode.stats().rooms == 2,
  tostring(mode.stats().rooms))

mode.stop()
check("-! keeps the map: rooms mapped is unchanged after a stop",
  mode.stats().rooms == 2, tostring(mode.stats().rooms))
check("stop leaves a retained map and profile", mode.retained() == true)
check("a paused run still reports its area profile, not nil",
  mode.profile() == profile, tostring(mode.profile()))
check("next_step is nil while paused", mode.next_step() == nil)

-- resume() must read the CURRENT room from roominfo, not the retained
-- last_name: the run paused while last_name was a sea room (the frame
-- above), but the player has since walked out by hand.
ri_info = { room = "A dusty crossroads", room_id = nil, exits = {} }
check("resume refuses when the CURRENT room is outside the area",
  mode.resume() == false)
check("a refused resume leaves the mode inactive", mode.active() == false)
check("a refused resume keeps the map retained for a later try",
  mode.retained() == true and mode.stats().rooms == 2,
  tostring(mode.stats().rooms))

-- Walk back inside by hand (no frame is delivered -- the run is paused, so
-- nothing would record one) and resume again.
ri_info = { room = "Layer one of the Sea of Chaos", room_id = nil, exits = {} }
check("resume succeeds once the current room is back in the area",
  mode.resume() == true)
check("resume reactivates the mode", mode.active() == true)
check("resume does not reset the map", mode.stats().rooms == 2,
  tostring(mode.stats().rooms))
mode.stop()

-- The opposite direction of the same property, so a mutant that reads
-- in_area(last_name) instead of the current room cannot pass by accident:
-- stopped with last_name OUTSIDE the area, but currently standing back
-- inside it. on_frame() only requires the mode to be active, not in_area, so
-- last_name can be set to a non-sea room without on_arrival ever running (no
-- on_arrival call here means the leave-area gate never fires and the run
-- stays active until the explicit stop below).
quiet(function() mode.start(profile, "clear") end)
frame({ name = "A dusty crossroads", exits = { "n" } })
mode.stop()
ri_info = { room = "Layer one of the Sea of Chaos", room_id = nil, exits = {} }
check("resume reads the CURRENT room, not the stale last_name",
  mode.resume() == true)
mode.stop()

-- resume refuses outright once nothing is retained.
mode.discard()
check("discard clears the map", mode.stats().rooms == 0,
  tostring(mode.stats().rooms))
check("a discarded run reports no profile", mode.profile() == nil,
  tostring(mode.profile()))
check("discard clears retained()", mode.retained() == false)
check("resume refuses with nothing retained", mode.resume() == false)

-- resume refuses while a run is already active -- nothing to resume.
quiet(function() mode.start(profile, "clear") end)
frame(CAPTURE[1])
quiet(mode.on_arrival)
check("resume refuses while already active", mode.resume() == false)
mode.stop()
mode.discard()

-- ---- a pending leave path does not survive a stop ---------------------------
-- M.resume() deliberately does not re-clear pending_dir/pending_leave_path --
-- that is M.stop()'s job -- so if a stop ever left one behind, a resume would
-- hand it straight back to next_step() instead of falling through to
-- frontier search.
quiet(function() mode.start(hop_profile, "clear") end)
frame({ name = "Room A", exits = { "e" } })
quiet(mode.on_arrival)
step = mode.next_step()
frame({ name = "Room B", exits = { "w", "n" } })
quiet(mode.on_arrival)
check("leave arms a pending path before the stop", mode.leave() == true)
mode.stop()
check("resume succeeds back into the same room", mode.resume() == true)
local after_stop_step = mode.next_step()
check("a pending leave path does not survive a stop -- frontier search runs instead",
  after_stop_step and after_stop_step.raw == "n",
  after_stop_step and after_stop_step.raw)
mode.stop()
mode.discard()

-- ---- reset works while paused, and leaves the run stopped -------------------
quiet(function() mode.start(profile, "clear") end)
frame(CAPTURE[1])
quiet(mode.on_arrival)
step = mode.next_step()
frame(CAPTURE[2])
quiet(mode.on_arrival)
check("two rooms are mapped before a paused reset", mode.stats().rooms == 2,
  tostring(mode.stats().rooms))
mode.stop()
quiet(function() mode.reset("paused reset") end)
check("reset works on a paused (retained) map", mode.stats().rooms == 0,
  tostring(mode.stats().rooms))
check("reset while paused leaves the run stopped, not started",
  mode.active() == false)
mode.discard()

-- reset while running leaves the run running.
quiet(function() mode.start(profile, "clear") end)
frame(CAPTURE[1])
quiet(mode.on_arrival)
check("one room is mapped before a running reset", mode.stats().rooms == 1,
  tostring(mode.stats().rooms))
quiet(function() mode.reset("running reset") end)
check("reset while running leaves the run active", mode.active() == true)
check("reset while running still gives a fresh map", mode.stats().rooms == 0,
  tostring(mode.stats().rooms))
mode.stop()
mode.discard()

-- ---- an arrival outside the area discards, not merely deactivates ----------
-- Task 12's in_area check was already covered for deactivation; this pins
-- that it is a full teardown now, so a later resume has nothing to work with.
quiet(function() mode.start(profile, "clear") end)
frame(CAPTURE[1])
quiet(mode.on_arrival)
step = mode.next_step()
frame({ num = 412, area = "Town", name = "A dusty crossroads", exits = { "n" } })
quiet(mode.on_arrival)
check("leaving the area deactivates the mode", mode.active() == false)
check("an arrival outside the area discards the map, not just pauses it",
  mode.retained() == false, tostring(mode.retained()))
check("a later resume finds nothing to resume", mode.resume() == false)

-- ---- Task V: the area declares its vertical geometry -------------------------
-- Root cause, from sea.log (the owner's `/log start` capture, line ~5300 on):
-- 'd' increases the layer in this area (set_level_exit_pairs makes "down" the
-- level-UP direction), but map.lua's DELTA used the ordinary lattice
-- convention for every area. A vertical exit's destination therefore never
-- matched a recorded coordinate, so it stayed a frontier forever, and the
-- explorer ping-ponged between two rooms once the horizontal frontier ran out:
--   trace: view reseeded xyz:8,6,1 -> xyz:8,6,2 / Step: u
--   trace: view reseeded xyz:8,6,2 -> xyz:8,6,1 / Step: d
-- A profile that declares M.vertical (areas/chaossea.lua) is how the area
-- fixes this for map.lua, which has no way to know its own convention.
local vertical_profile = {
  name = "test-vertical",
  exclude_exits = { out = true, enter = true, ["in"] = true },
  dive_dirs = { "d" },
  defer_dirs = { "u" },
  default_policy = "clear",
  vertical = { d = 1, u = -1 },
  in_area = profile.in_area,
  layer_of = profile.layer_of,
  complete = function() return false end,
}

-- The regression test that matters: the owner's shape in miniature. Two
-- rooms at the same x,y on adjacent layers, joined by d/u, with layer_of
-- supplying z exactly as the real profile does. A step cap keeps a
-- regression here a red case rather than a hung suite -- verified for real
-- below, not just asserted: with M.new ignoring opts.vertical, this loop
-- does not terminate within the cap (both "d" and "u" stay permanent
-- frontiers, exactly as in the capture), which is how this case was
-- confirmed to actually kill that mutant rather than passing by accident.
quiet(function() mode.start(vertical_profile, "clear") end)
frame({ name = "Layer two of the Sea of Chaos", exits = { "d" } })
quiet(mode.on_arrival)
check("the first room (layer two) is recorded", mode.stats().rooms == 1,
  tostring(mode.stats().rooms))

local STEP_CAP = 6
local terminated = false
for _ = 1, STEP_CAP do
  local s = mode.next_step()
  if not s then
    terminated = true
    break
  end
  if s.raw == "d" then
    frame({ name = "Layer three of the Sea of Chaos", exits = { "u" } })
  else
    frame({ name = "Layer two of the Sea of Chaos", exits = { "d" } })
  end
  quiet(mode.on_arrival)
end
check("the owner's loop terminates within " .. STEP_CAP ..
  " steps -- reports exhausted rather than stepping forever",
  terminated, "still stepping after " .. STEP_CAP .. " calls")
check("both rooms are mapped, and only both -- the map stopped growing",
  mode.stats().rooms == 2, tostring(mode.stats().rooms))
check("the run stops with stop_reason 'exhausted', not a completed leave",
  mode.stop_reason() == "exhausted", mode.stop_reason())
check("no spurious desync was raised along the way -- u/d stayed walkable "
  .. "in the topology check throughout",
  mode.desyncs() == 0, tostring(mode.desyncs()))
mode.stop()
mode.discard()

-- The direction pinned against the capture, named explicitly so a future
-- reader cannot re-derive the sign from first principles and get it wrong a
-- third time (this is the second time it was gotten wrong: once in
-- map.lua's DELTA, once more nearly shipped in the frontier prediction this
-- task fixes). From "Layer two" (z=1), stepping 'd' must arrive at "Layer
-- three" (z=2) -- sea.log's xyz:8,6,1 -> xyz:8,6,2.
quiet(function() mode.start(vertical_profile, "clear") end)
frame({ name = "Layer two of the Sea of Chaos", exits = { "d" } })
quiet(mode.on_arrival)
check("pinned to sea.log: standing on layer two (z=1)", mode.stats().z == 1,
  tostring(mode.stats().z))
local pin_step = mode.next_step()
check("the only exit -- 'd' -- is the one taken", pin_step and pin_step.raw == "d",
  pin_step and pin_step.raw)
frame({ name = "Layer three of the Sea of Chaos", exits = { "u" } })
quiet(mode.on_arrival)
check("pinned to sea.log: stepping 'd' from layer two arrives at layer three (z=2)",
  mode.stats().z == 2, tostring(mode.stats().z))
mode.stop()
mode.discard()

-- ---- the tripwire speaks: every correction reaches the capture, only the
-- first reaches the screen ------------------------------------------------
-- Before this task the layer-correction override fired on EVERY vertical
-- move, completely silently -- which is how the inverted-delta bug survived
-- undetected in the first place. It still fires (the safety net is not
-- removed), but now LOUDLY: lera.log() every time, and a screen line only
-- the first time per run, since an unconditional print would be the same
-- flood that hid the bug in the owner's capture.
local logged = {}
_G.lera = { log = function(msg) logged[#logged + 1] = msg end }
local screen_logged = {}
mode.set_logger(function(msg, kind)
  screen_logged[#screen_logged + 1] = { msg = msg, kind = kind }
end)

quiet(function() mode.start(vertical_profile, "clear") end)
-- The origin's reckoned z (0) already disagrees with "Layer two" (z = 1), so
-- this first arrival alone forces a correction.
frame({ name = "Layer two of the Sea of Chaos", exits = { "d" } })
quiet(mode.on_arrival)
check("a correction is counted", mode.stats().layer_corrections == 1,
  tostring(mode.stats().layer_corrections))
check("the correction reaches lera.log", #logged == 1, tostring(#logged))
check("lera.log's message names the reckoned z, the name's layer, and the room",
  logged[1] and logged[1]:find("z=0", 1, true) ~= nil
    and logged[1]:find("layer 1", 1, true) ~= nil
    and logged[1]:find("Layer two of the Sea of Chaos", 1, true) ~= nil,
  logged[1])
check("the first correction also reaches the screen", #screen_logged == 1,
  tostring(#screen_logged))

-- Force a second correction: jump the reckoned position somewhere never
-- recorded (so there is no prior exit set to contradict -- no desync) that
-- disagrees with the next frame's named layer.
mode.debug_set_position(50, 50, 0)
frame({ name = "Layer three of the Sea of Chaos", exits = { "u" } })
quiet(mode.on_arrival)
check("a second correction is counted", mode.stats().layer_corrections == 2,
  tostring(mode.stats().layer_corrections))
check("the second correction also reaches lera.log", #logged == 2, tostring(#logged))
check("the second correction does NOT reach the screen -- only the first per run",
  #screen_logged == 1, tostring(#screen_logged))

-- A nil from next_step() is only exhaustion when stop_reason() says so. Asked
-- again before the emitted move has arrived, it must say the move is in
-- flight -- reported as exhaustion, that nil ends a run with rooms left.
do
  quiet(function() mode.start(profile, "clear") end)
  frame({ name = "Layer one of the Sea of Chaos", exits = { "e", "w" } })
  quiet(mode.on_arrival)
  local first = mode.next_step()
  local again = mode.next_step()
  check("a step with a move in flight is not exhaustion",
    first ~= nil and again == nil and mode.stop_reason() == "in flight",
    tostring(mode.stop_reason()))
  frame({ name = "Layer one of the Sea of Chaos", exits = { "w" } })
  quiet(mode.on_arrival)
  check("once the move lands the frontier is offered again",
    mode.next_step() ~= nil)
  mode.stop()
  check("a stopped mode's nil is not exhaustion",
    mode.next_step() == nil and mode.stop_reason() == "inactive")
end

mode.stop()
mode.discard()
mode.set_logger(nil)
_G.lera = nil

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("ALL PASS")
