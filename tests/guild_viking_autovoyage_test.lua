-- guild_viking autovoyage.lua unit tests (stage 4 Task 7: the auto-voyage
-- router). Ported verbatim from LEGACY guild_viking.lua:3576-4343 and
-- 11437-11541. Run from the lera-plugins repo root with LERA_ROOT pointing
-- at a built Lera checkout.
package.path = "3scapes/guild_viking/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
  if ok then
    print("CASE " .. name .. ": PASS")
  else
    failures = failures + 1
    print("CASE " .. name .. ": FAIL" .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

-- ---- lera API stubs (same shape as guild_viking_autotrader_test.lua) ------
ui = { dirty = function() end }
lera = { time = function() return 1000 end, version = function() return "test" end }
local mud_connected = true
local sent = {}
mud = {
  send = function(cmd) sent[#sent + 1] = cmd end,
  connected = function() return mud_connected end,
}
local stored = nil
store = {
  load = function() end,
  get = function() return stored end,
  set = function(d) stored = d end,
  save = function() end,
}
local printed = {}
buffer = {
  color_print = function(...)
    local args = { ... }
    local parts = {}
    for i = 3, #args, 3 do
      parts[#parts + 1] = tostring(args[i])
    end
    printed[#printed + 1] = table.concat(parts)
  end,
}
-- M.open_menu's require("menu") stub -- same shape as guild_viking_test.lua's
-- preamble.
local last_menu_open = nil
package.loaded["menu"] = {
  open = function(opts) last_menu_open = opts end,
  close = function() last_menu_open = nil end,
  is_open = function() return last_menu_open ~= nil end,
}
local function menu_item_labels(opts)
  local out = {}
  for _, it in ipairs(opts.items or {}) do out[#out + 1] = it.label end
  return out
end

local protocol = require("protocol")
-- init.lua's RESERVED set: the module-level convention fields, not MIP keys.
local RESERVED_KEYS = { _market_seam = true, _patterns = true, _gmcp = true,
                        _retired_keys = true, _retired_patterns = true }
local S = require("state").S
local voyage = require("handlers.voyage")
for key, fn in pairs(voyage._gmcp or {}) do
  protocol.gmcp_handler(key, fn)
end

local page_opts = require("page_opts")
local av = require("autovoyage")

-- ---------------------------------------------------------------------------
-- Wire-fixture helpers. Every field that arrives over the wire (voyage
-- status, chart rows, sailed tiles, ships, offers, fleet renown) is built
-- through protocol.ingest with the REAL handlers in handlers/voyage.lua --
-- never poked into S directly. S.autovoyage is the one documented exception
-- (plugin-local automation settings, exactly like S.autotrade in
-- guild_viking_autotrader_test.lua): it is reset with a plain `S.autovoyage
-- = nil` between cases below.
-- ---------------------------------------------------------------------------

-- handlers/voyage.lua's M.VOYAGE field order (27 pipe-delimited fields).
local VOYAGE_FIELDS = {
  "state", "ship_id", "ship_name", "contract_name", "contract_type", "danger",
  "x", "y", "width", "height", "hull", "morale", "supplies", "stress",
  "crew_alive", "crew_max", "steps", "next_move", "threat_name", "threat_level",
  "threat_pressure", "paused_type", "weather_key", "captain", "identity",
  "crew_traits", "ship_traits",
}
local function set_voyage(overrides)
  local f = {
    state = "sailed", ship_id = 1, ship_name = "Ship1", contract_name = "c",
    contract_type = "raid", danger = 0, x = 0, y = 0, width = 0,
    height = 0, hull = 100, morale = 100, supplies = 100, stress = 0,
    crew_alive = 1, crew_max = 1, steps = 0, next_move = 0,
    threat_name = "", threat_level = 0, threat_pressure = 0, paused_type = "",
    weather_key = "", captain = "", identity = "", crew_traits = "", ship_traits = "",
  }
  for k, v in pairs(overrides or {}) do f[k] = v end
  -- Guild.Voyage's record names five of these differently, and its trait
  -- lists travel as their own keys.
  local function split(str)
    local out = {}
    for t in tostring(str or ""):gmatch("[^,]+") do out[#out + 1] = t end
    return out
  end
  protocol.on_gmcp("Guild.Voyage", {
    guild = "viking",
    voyage = {
      state = f.state, ship_id = tonumber(f.ship_id), ship_name = f.ship_name,
      contract_name = f.contract_name, contract_type = f.contract_type,
      danger = tonumber(f.danger), x = tonumber(f.x), y = tonumber(f.y),
      width = tonumber(f.width), height = tonumber(f.height),
      hull = tonumber(f.hull), morale = tonumber(f.morale),
      supplies = tonumber(f.supplies), hull_stress = tonumber(f.stress),
      crew_alive = tonumber(f.crew_alive), crew_max = tonumber(f.crew_max),
      steps_sailed = tonumber(f.steps), next_move_in = tonumber(f.next_move),
      threat_name = f.threat_name, threat_level = tonumber(f.threat_level),
      threat_pressure = tonumber(f.threat_pressure),
      paused_type = f.paused_type, weather_key = f.weather_key,
      captain_style = f.captain, ship_identity = f.identity,
    },
    voyage_crew_traits = split(f.crew_traits),
    voyage_ship_traits = split(f.ship_traits),
  })
end
-- An empty record is how the server says "no active voyage", the same thing
-- MIP's empty VOYAGE value said.
local function clear_voyage()
  protocol.on_gmcp("Guild.Voyage", { guild = "viking", voyage = {} })
end

-- Guild.Voyage's longship record; its trait lists travel as their own keys,
-- foreign-keyed by ship id.
local function longship_entry(overrides)
  local f = { sid = 1, name = "Ship1", tier = 3, state = "docked", target = "",
              ret = 0, crew = 0, hired = 0, safe = 0, identity = "",
              captain = "", crew_traits = "", ship_traits = "", saga_title = "",
              saga_raids = 0 }
  for k, v in pairs(overrides or {}) do f[k] = v end
  return { id = tonumber(f.sid), name = f.name, tier = tonumber(f.tier),
           state = f.state, target = f.target, secs = tonumber(f.ret),
           crew = tonumber(f.crew), hired_crew = tonumber(f.hired),
           safe = tonumber(f.safe), voyage_identity = f.identity,
           captain_style = f.captain, saga_title = f.saga_title,
           saga_raids = tonumber(f.saga_raids),
           _crew_traits = f.crew_traits, _ship_traits = f.ship_traits }
end
local function set_longships(entries)
  local ships, crew, shiptr = {}, {}, {}
  for _, e in ipairs(entries) do
    local rec = {}
    for k, v in pairs(e) do
      if k ~= "_crew_traits" and k ~= "_ship_traits" then rec[k] = v end
    end
    ships[#ships + 1] = rec
    for t in tostring(e._crew_traits or ""):gmatch("[^,]+") do
      crew[#crew + 1] = { id = rec.id, trait = t }
    end
    for t in tostring(e._ship_traits or ""):gmatch("[^,]+") do
      shiptr[#shiptr + 1] = { id = rec.id, trait = t }
    end
  end
  protocol.on_gmcp("Guild.Voyage", { guild = "viking", longship = ships,
    longship_crew_traits = crew, longship_ship_traits = shiptr })
end

-- MIP packed the ship name and the offer list into one value; they are
-- separate keys here. `fit` is `fit_code` on the wire.
local function set_offers(ship, offers)
  local list = {}
  for _, o in ipairs(offers) do
    list[#list + 1] = { index = o.index, type = o.type or "",
                        name = o.name or "", danger = o.danger or 0,
                        difficulty = o.difficulty or "", fit_code = o.fit or 3 }
  end
  protocol.on_gmcp("Guild.Voyage", { guild = "viking", voffers_ship = ship,
                                     voffers = list })
end

-- Guild.Voyage's Sea Chart: a width/height/mode record plus its rows, where
-- MIP sent VCHH and a numbered VCR%02d burst.
local function set_chart(width, height, mode, rows)
  protocol.on_gmcp("Guild.Voyage", { guild = "viking",
    voyage_chart = { width = width, height = height,
                     chart_mode = mode or "explore" },
    voyage_chart_rows = rows or {} })
end

-- Each element is the same "x,y" key MIP joined with ';'.
local function set_sailed(pairs_xy)
  local coords = {}
  for _, xy in ipairs(pairs_xy) do coords[#coords + 1] = xy[1] .. "," .. xy[2] end
  protocol.on_gmcp("Guild.Voyage", { guild = "viking", vsailed = coords })
end

local function set_wait(paused_type, options)
  protocol.on_gmcp("Guild.Voyage", { guild = "viking",
    voyage_wait = paused_type, vresolve = options })
end

local function reset_all()
  S.autovoyage = nil
  S.voyage_status = nil
  S.voyage_chart_width = 0
  S.voyage_chart_height = 0
  S.voyage_chart_rows = {}
  S.voyage_sailed = nil
  S.voyage_longships = {}
  S.ships = {}
  S.voyage_offers = nil
  S.voyage_wait = ""
  S.voyage_resolve_options = {}
  S.voyage_queue = {}
  S.mip_voyage_seen = false
  S.fleet_renown = 0
  mud_connected = true
  sent = {}
  printed = {}
  page_opts.set("auto_voyage", false)
  page_opts.set("av_verbose", false)
end

-- =============================================================================
-- Pure functions
-- =============================================================================

reset_all()

-- ---- av_key / av_label / av_cell / av_skip (LEGACY:3665-3683) -------------
check("key: \"x,y\" format", av.key(3, 7) == "3,7")
check("label: A1 for (0,0)", av.label(0, 0) == "A1")
check("label: E3 for (2,4)", av.label(2, 4) == "E3")

set_chart(3, 1, "explore", { "..X" })
check("cell: reads a charted symbol", av.cell(2, 0) == "X")
check("cell: out-of-range column returns '#'", av.cell(5, 0) == "#")
check("cell: out-of-range row returns '#'", av.cell(0, 5) == "#")

local a = av.settings()
a.visited = { ["1,1"] = true }
a.avoid = { ["2,2"] = true }
local skip = av.skip(a)
check("skip: unions visited and avoid", skip["1,1"] == true and skip["2,2"] == true and skip["9,9"] == nil)

-- ---- av_settings default/backfill guard (LEGACY:3592-3612) -----------------
S.autovoyage = nil
local a1 = av.settings()
check("settings: fully-absent defaults",
      a1.risk == "balanced" and a1.ship == "" and a1.last == 0 and a1.worked == 0
      and a1.allow_abyssal == false and a1.diff_min == 1 and a1.diff_max == 99
      and type(a1.log) == "table" and #a1.log == 0
      and a1.mission_prio[1] == "raid" and a1.mission_prio[5] == "hunt")
S.autovoyage = { risk = "max" }   -- partial table, missing most knobs
local a2 = av.settings()
check("settings: partial-table backfill preserves existing field", a2.risk == "max")
check("settings: partial-table backfill fills in missing knobs",
      a2.allow_abyssal == false and type(a2.visited) == "table" and type(a2.avoid) == "table"
      and a2.stuck == 0 and a2.diff_min == 1 and a2.diff_max == 99
      and a2.mission_prio[1] == "raid")
S.autovoyage = nil

-- ---- av_nearest (LEGACY:3688-3712) -----------------------------------------
S.autovoyage = nil
set_chart(5, 1, "explore", { "..X.I" })   -- X at (2,0), I at (4,0)
check("nearest: closer POI wins", av.nearest({ X = true, I = true }, 0, 0).x == 2)
check("nearest: excluded cell is skipped",
      av.nearest({ X = true, I = true }, 0, 0, { ["2,0"] = true }).x == 4)
check("nearest: no match returns nil", av.nearest({ Z = true }, 0, 0) == nil)

-- Tie-break (LEGACY:3690-3707): two candidates equidistant from the ship by
-- Chebyshev distance must break the tie toward the one nearer the chart's
-- CENTRE, not scan order. Width 9 (centre x = (9-1)/2 = 4), ship at x=2:
--   X at (0,0): Chebyshev dist |0-2|=2, centre dist |0-4|=4
--   I at (4,0): Chebyshev dist |4-2|=2, centre dist |4-4|=0
-- Distances tie (2 == 2); I's centre distance (0) is smaller, so I must win
-- -- if the tie-break were absent (or scanned left-to-right unconditionally)
-- X (the first match encountered) would win instead.
set_chart(9, 1, "explore", { "X...I...." })
check("nearest: centre-distance tie-break picks I (cdist 0) over X (cdist 4)",
      av.nearest({ X = true, I = true }, 2, 0).x == 4)

-- Fix round 1, I-7: every fixture above uses a single-row chart, where
-- Chebyshev (math.max(|dx|,|dy|)) and Manhattan (|dx|+|dy|) distance always
-- agree (dy is always 0), so a mutation swapping one for the other would
-- survive undetected. LEGACY's own comment above av_nearest calls this
-- "Manhattan" (LEGACY:3690's own wording) but the CODE is Chebyshev
-- (LEGACY:3703's `math.max`, ported verbatim as M.nearest's `math.max`
-- above) -- kept exactly as LEGACY wrote it, comment included; this case
-- pins the actual (Chebyshev) behavior against a Manhattan mutation
-- without touching that comment.
--   Ship at (0,0). X at (3,3): Chebyshev = max(3,3) = 3, Manhattan = 3+3 = 6.
--   I at (1,4):    Chebyshev = max(1,4) = 4, Manhattan = 1+4 = 5.
-- Chebyshev ranks X closer (3 < 4); Manhattan would rank I closer (5 < 6)
-- -- the two metrics disagree outright, no tie-break involved.
S.autovoyage = nil
set_chart(4, 5, "explore", { "....", "....", "....", "...X", ".I.." })
check("nearest: Chebyshev (not Manhattan) distance picks X over I",
      av.nearest({ X = true, I = true }, 0, 0).x == 3 and av.nearest({ X = true, I = true }, 0, 0).y == 3)

-- ---- av_step / av_path_steps (LEGACY:3721-3887) ----------------------------

-- 1) Straight line, no hazards: first step is due east, path length 4.
S.autovoyage = nil
set_chart(5, 1, "explore", { "....." })
check("step: straight line first step is (1,0) -> \"A2\"", av.step(0, 0, 4, 0) == "A2")
check("path_steps: straight line, 4 steps", av.path_steps(0, 0, 4, 0) == 4)
check("step: cx==tx,cy==ty returns nil", av.step(2, 0, 2, 0) == nil)
check("path_steps: cx==tx,cy==ty returns 0", av.path_steps(2, 0, 2, 0) == 0)

-- 2) Per-risk-profile hazard cost, on a 1-row grid so no diagonal detour is
--    possible -- isolates the hazard_cost multiplier itself (LEGACY:3726,
--    3851: safe=10x, balanced=3x, max=1x). Grid ".T." (T is AV_HAZARD).
--    Cost from (0,0) to (2,0) = hazard_cost(T) + 1 (plain step); path_steps
--    rounds via math.floor(cost + 0.5).
set_chart(3, 1, "explore", { ".T." })
S.autovoyage = nil; a = av.settings(); a.risk = "balanced"
check("step: balanced risk still routes straight through the only path -> \"A2\"",
      av.step(0, 0, 2, 0) == "A2")
check("path_steps: balanced hazard cost 3 -> 3+1=4", av.path_steps(0, 0, 2, 0) == 4)
a.risk = "safe"
check("path_steps: safe hazard cost 10 -> 10+1=11", av.path_steps(0, 0, 2, 0) == 11)
a.risk = "max"
check("path_steps: max hazard cost 1 -> 1+1=2 (treated as ordinary)", av.path_steps(0, 0, 2, 0) == 2)

-- 3) Hazard-forced detour: with two hazards blocking the direct row, a
--    diagonal route through the clean row below is cheaper and is chosen.
--    Grid (balanced, hazard_cost=3):
--      row0: ".TT."
--      row1: "...."
--    Direct: (0,0)->(1,0)[3]->(2,0)[3]->(3,0)[1] = 7.
--    Diagonal detour: (0,0)->(1,1)[1]->(2,1)[1]->(3,0)[1] = 3.
--    3 < 7, unambiguous (no tie), so the diagonal detour must win.
S.autovoyage = nil; a = av.settings(); a.risk = "balanced"
set_chart(4, 2, "explore", { ".TT.", "...." })
check("step: hazard-forced detour takes the diagonal -> \"B2\" (1,1)", av.step(0, 0, 3, 0) == "B2")
check("path_steps: detour cost 3, not the direct 7", av.path_steps(0, 0, 3, 0) == 3)

-- 4) Sailed-tile ~15% discount (LEGACY:3770-3773, 3878-3880): every
--    destination cell marked sailed gets step_cost/1.15. On a plain 5-step
--    straight line (cost 1 each, no hazards), marking every destination
--    cell sailed drops the total from 5 to floor(5/1.15 + 0.5) = floor(4.848) = 4.
S.autovoyage = nil; a = av.settings(); a.risk = "balanced"
set_chart(6, 1, "explore", { "......" })
S.voyage_sailed = nil
check("path_steps: unsailed straight line, 5 steps", av.path_steps(0, 0, 5, 0) == 5)
set_sailed({ {1,0}, {2,0}, {3,0}, {4,0}, {5,0} })
check("path_steps: all-sailed straight line, 5/1.15 rounds to 4", av.path_steps(0, 0, 5, 0) == 4)
S.voyage_sailed = nil

-- 5) Unreachable target: chart declares width 2 but a row is 3 chars wide,
--    so the POI at column 2 exists for av_nearest's raw-row-length scan but
--    falls outside av_step's own w=2 Dijkstra grid -- av_step can never
--    reach it and returns nil, exactly LEGACY's own w/h-vs-row-length split
--    (av_nearest scans #rows/#row directly; av_step loops 0..w-1/0..h-1).
S.autovoyage = nil; a = av.settings()
set_chart(2, 1, "explore", { "..X" })
check("nearest: still finds the POI past the declared width (raw row scan)",
      av.nearest({ X = true }, 0, 0) and av.nearest({ X = true }, 0, 0).x == 2)
check("step: same target is unreachable through the declared (narrower) grid",
      av.step(0, 0, 2, 0) == nil)
check("path_steps: same, nil", av.path_steps(0, 0, 2, 0) == nil)

-- 6) Fix round 1, I-4: M.step's OWN hazard_cost multiplier (LEGACY:272,
--    inside M.step -- a hand-duplicate of the same line in M.path_steps,
--    LEGACY:400, exactly the kind of transcription slip a verbatim port
--    can introduce) was never covered by a fixture where mutating it
--    changes the FIRST STEP av.step() returns, as opposed to just the
--    total cost av.path_steps() reports. Every earlier `step` case above
--    either has no alternative route (".T.") or a detour so much cheaper
--    (3 vs 7) that no single-multiplier mutation could flip it.
--
--    This fixture forces a real trade-off: a hazard column 7 rows deep
--    (rows 0-6, column 1) with its only safe crossing at row 7, target one
--    step past the column.
--      direct (cross at row 0): hazard_cost(safe=10) + 1 plain step = 11.
--      detour (down to the row-7 gap and back): every other cell in the
--        grid is plain, so cost == Chebyshev distance exactly --
--        Chebyshev((0,0),(1,7)) + Chebyshev((1,7),(2,0)) = 7 + 7 = 14.
--    11 < 14: the direct route wins with the real safe multiplier (10), so
--    the first step is due east ("A2"). Mutating M.step's own hazard_cost
--    10 -> 20 (the exact mutant the review named) makes the direct route
--    20 + 1 = 21 > 14, so the detour wins instead -- first step becomes due
--    south ("B1"). Hand-verified against a real run of both the unmutated
--    and (temporarily) mutated module before being committed here.
S.autovoyage = nil; a = av.settings(); a.risk = "safe"
set_chart(3, 8, "explore", { ".T.", ".T.", ".T.", ".T.", ".T.", ".T.", ".T.", "..." })
check("step: safe risk (hazard_cost=10) -- direct route through the hazard column wins -> \"A2\"",
      av.step(0, 0, 2, 0) == "A2")
check("path_steps: matches the direct route's cost (10+1=11)", av.path_steps(0, 0, 2, 0) == 11)

-- 7) Fix round 1, I-5: AV_SEVERE's double cost (LEGACY:3586-3588, "V" costs
--    hazard_cost*2, not hazard_cost*1 like an ordinary hazard) was untested
--    in BOTH functions -- no fixture used a "V" cell at all.
--
--    7a) The plain arithmetic, via path_steps (mirrors test 2's ".T." case
--    exactly, but with "V"): balanced hazard_cost=3, severe=3*2=6, so cost
--    from (0,0) to (2,0) across one "V" cell = 6 + 1 (plain) = 7 -- NOT 4
--    (which is what a "V" mistakenly treated as an ordinary hazard, or
--    dropped from AV_SEVERE, would give).
S.autovoyage = nil; a = av.settings(); a.risk = "balanced"
set_chart(3, 1, "explore", { ".V." })
check("path_steps: severe cell costs hazard_cost*2, not *1 (balanced: 3*2+1=7)",
      av.path_steps(0, 0, 2, 0) == 7)

--    7b) The route-choice sensitivity, via step -- same "forced trade-off"
--    shape as test 6, but only 3 rows deep (rows 0-2 hazard "V", row 3
--    open) since severe's multiplier is bigger per cell:
--      direct (cross at row 0): severe(balanced: 3*2=6) + 1 plain = 7.
--      detour (down to the row-3 gap and back): Chebyshev((0,0),(1,3)) +
--        Chebyshev((1,3),(2,0)) = 3 + 3 = 6.
--    7 > 6: the DETOUR wins with the real doubling -- first step is due
--    south ("B1"). If AV_SEVERE's doubling were dropped (severe treated as
--    an ordinary hazard, cost 3 instead of 6), direct becomes 3 + 1 = 4 < 6
--    and the direct route wins instead -- first step becomes due east
--    ("A2"). Hand-verified against a real run of both the unmutated and
--    (temporarily) mutated module before being committed here.
S.autovoyage = nil; a = av.settings(); a.risk = "balanced"
set_chart(3, 4, "explore", { ".V.", ".V.", ".V.", "..." })
check("step: severe doubling makes the detour cheaper than crossing -> \"B1\"",
      av.step(0, 0, 2, 0) == "B1")
check("path_steps: matches the detour's cost (6), not the direct 7", av.path_steps(0, 0, 2, 0) == 6)

-- 8) Fix round 1, M-1: symbol-set membership. Every earlier fixture only
--    ever used "T", "H", and "X" -- proving nothing about the OTHER
--    entries LEGACY:3585-3590 lists, or its one deliberate EXCLUSION.
S.autovoyage = nil; a = av.settings(); a.risk = "balanced"
-- "C" (ice floes) is a hazard, same cost as "T": balanced 3+1=4.
set_chart(3, 1, "explore", { ".C." })
check("path_steps: \"C\" (ice floes) is a hazard (balanced 3+1=4)", av.path_steps(0, 0, 2, 0) == 4)
-- "A" (aurora calm) is deliberately NOT a hazard -- LEGACY's own comment
-- calls this out as intentional (a boon, not a hazard). Cost must be the
-- plain 1+1=2, not 3+1=4.
set_chart(3, 1, "explore", { ".A." })
check("path_steps: \"A\" (aurora calm) is deliberately excluded from AV_HAZARD (cost 1+1=2)",
      av.path_steps(0, 0, 2, 0) == 2)
-- "?" (unknown node) is a POI target, same as "X"/"I" -- exercised through
-- av.goal (which calls av.nearest(AV_POI, ...) internally), NOT by handing
-- av.nearest a hand-built set: av.nearest takes its symbol set as a plain
-- PARAMETER, so a check that builds its own {["?"]=true} set would prove
-- nothing about whether AV_POI itself contains "?". No harbor here, so if
-- "?" is not recognized as a POI, "nothing left to visit" fires and goal
-- is "end"; if it is, goal is "explore".
S.autovoyage = nil; a = av.settings(); a.risk = "balanced"
set_chart(3, 1, "explore", { "..?" })
check("goal: \"?\" (unknown node) counts as a POI via AV_POI -- explore, not end",
      av.goal(a, { x = 0, y = 0, hull = 100, morale = 100, supplies = 100, danger = 0 }) == "explore")

-- "Y" (resolved harbor) is a harbor target, same as "H" -- dropping it
-- would silently break banking at an already-resolved harbor. Same
-- reasoning: exercised through av.goal's own av.nearest(AV_HARBOR, ...)
-- call, not a hand-built set. Grid "Y.X": hull is below the balanced floor
-- (25 < 30) -- if "Y" is recognized as a harbor, av.goal's step 2 fires
-- ("repair"); if not (and no "H" exists), that branch is skipped entirely
-- (repair requires `h` truthy) and the POI ("X") still present means the
-- worked-count check falls through to "explore" instead.
S.autovoyage = nil; a = av.settings(); a.risk = "balanced"
set_chart(3, 1, "explore", { "Y.X" })
check("goal: \"Y\" (resolved harbor) counts as a harbor via AV_HARBOR -- repair, not explore",
      av.goal(a, { x = 1, y = 0, hull = 25, morale = 100, supplies = 100, danger = 0 }) == "repair")

-- =============================================================================
-- av_pick_resolve (LEGACY:3789-3817)
-- =============================================================================
S.autovoyage = nil
local vs_hurt = { hull = 10, supplies = 100, morale = 100, threat_level = 0 }
local vs_ok   = { hull = 100, supplies = 100, morale = 100, threat_level = 0 }
local vs_supl = { hull = 100, supplies = 10, morale = 100, threat_level = 0 }
local vs_thr  = { hull = 100, supplies = 100, morale = 100, threat_level = 5 }

check("pick_resolve: harbor + hull_low prefers repair",
      av.pick_resolve(vs_hurt, { "trade", "repair" }, "harbor", 30) == "repair")
check("pick_resolve: harbor + hull_ok prefers trade",
      av.pick_resolve(vs_ok, { "trade", "repair" }, "harbor", 30) == "trade")
check("pick_resolve: harbor falls back to first option when nothing matches",
      av.pick_resolve(vs_ok, { "mystery" }, "harbor", 30) == "mystery")
check("pick_resolve: prompt_ship always flees/evades",
      av.pick_resolve(vs_ok, { "fight", "flee" }, "prompt_ship", 30) == "flee")
check("pick_resolve: generic node, supplies low -> resupply",
      av.pick_resolve(vs_supl, { "plunder", "resupply" }, "island", 30) == "resupply")
check("pick_resolve: generic node, hull low -> repair",
      av.pick_resolve(vs_hurt, { "plunder", "repair" }, "island", 30) == "repair")
check("pick_resolve: generic node, high threat -> avoid",
      av.pick_resolve(vs_thr, { "plunder", "avoid" }, "island", 30) == "avoid")
check("pick_resolve: generic node, otherwise plunder",
      av.pick_resolve(vs_ok, { "scout", "plunder" }, "island", 30) == "plunder")

-- Fix round 1, I-8: the `supplies < 45` threshold (LEGACY:3797) was only
-- exercised at 10 (clearly low) and 100 (clearly fine) -- add the exact
-- boundary in both directions: 44 (< 45, low) and 45 (NOT < 45, not low).
check("pick_resolve: supplies at 44 (< 45) is low -- resupply",
      av.pick_resolve({ hull = 100, supplies = 44, morale = 100, threat_level = 0 },
        { "plunder", "resupply" }, "island", 30) == "resupply")
check("pick_resolve: supplies at exactly 45 is NOT low -- falls through to plunder",
      av.pick_resolve({ hull = 100, supplies = 45, morale = 100, threat_level = 0 },
        { "plunder", "resupply" }, "island", 30) == "plunder")

-- =============================================================================
-- av_has_trait / av_per_step (LEGACY:3819-3840)
-- =============================================================================
local vs_traits = { crew_traits = { "Hidden Lockers", "Bold" }, ship_traits = { "Reinforced Hull" } }
check("has_trait: case-insensitive substring match on crew_traits",
      av.has_trait(vs_traits, "hidden lockers") == true)
check("has_trait: matches ship_traits too", av.has_trait(vs_traits, "reinforced") == true)
check("has_trait: no match", av.has_trait(vs_traits, "phantom") == false)

S.fleet_renown = 0
check("per_step: danger 0, no trait/renown discount -> 1", av.per_step({ danger = 0 }) == 1)
check("per_step: danger 9 -> 1+floor(9/3)=4", av.per_step({ danger = 9 }) == 4)
check("per_step: hidden lockers trait -> -1",
      av.per_step({ danger = 9, crew_traits = { "hidden lockers" }, ship_traits = {} }) == 3)
-- Fix round 1, M-2: pin the exact 60 boundary (LEGACY:3837) in both
-- directions -- 59 must NOT discount, only 60+ does.
S.fleet_renown = 59
check("per_step: fleet_renown at 59 (< 60) does NOT discount", av.per_step({ danger = 9 }) == 4)
S.fleet_renown = 60
check("per_step: fleet_renown >= 60 -> -1", av.per_step({ danger = 9 }) == 3)
S.fleet_renown = 60
check("per_step: floors at 1, never 0 or negative",
      av.per_step({ danger = 0, crew_traits = { "hidden lockers" }, ship_traits = {} }) == 1)
S.fleet_renown = 0

-- =============================================================================
-- av_hull_floor (LEGACY:3890-3892)
-- =============================================================================
check("hull_floor: max -> 20", av.hull_floor({ risk = "max" }) == 20)
check("hull_floor: safe -> 45", av.hull_floor({ risk = "safe" }) == 45)
check("hull_floor: balanced -> 30", av.hull_floor({ risk = "balanced" }) == 30)
check("hull_floor: unknown risk defaults to 30", av.hull_floor({ risk = "???" }) == 30)

-- =============================================================================
-- av_goal (LEGACY:3898-3939) -- every branch, plus the per-risk thresholds.
-- Grid: width 3, height 1, "H.X" -- harbor at (0,0), open at (1,0), POI at
-- (2,0). Ship sits at (1,0): distance-1 from the harbor either way, so
-- path_steps(1,0 -> 0,0) = 1 with no hazards. danger=0 -> per_step=1, so
-- sup_to_harbor = steps_harbor(1) * per_step(1) = 1 for every goal test below
-- unless noted.
-- =============================================================================
S.autovoyage = nil
set_chart(3, 1, "explore", { "H.X" })

-- 1) Supplies point-of-no-return (balanced reserve=4): threshold is
--    sup <= 1 + 4 = 5.
S.autovoyage = nil; a = av.settings(); a.risk = "balanced"
check("goal: supplies at threshold (5) -> end",
      av.goal(a, { x = 1, y = 0, hull = 100, morale = 100, supplies = 5, danger = 0 }) == "end")
check("goal: supplies just above threshold (6) -> explore (POI present)",
      av.goal(a, { x = 1, y = 0, hull = 100, morale = 100, supplies = 6, danger = 0 }) == "explore")

-- 1b) Fix round 1, I-3: the other two risk-profile reserves were untested
-- (only balanced's 4 had a boundary case). safe reserve=8: threshold
-- sup <= 1 + 8 = 9. max reserve=2: threshold sup <= 1 + 2 = 3. Same grid,
-- same steps_harbor(1)*per_step(1)=1 as the balanced case above.
S.autovoyage = nil; a = av.settings(); a.risk = "safe"
check("goal: safe reserve (8) -- supplies at threshold (9) -> end",
      av.goal(a, { x = 1, y = 0, hull = 100, morale = 100, supplies = 9, danger = 0 }) == "end")
check("goal: safe reserve (8) -- supplies just above threshold (10) -> explore",
      av.goal(a, { x = 1, y = 0, hull = 100, morale = 100, supplies = 10, danger = 0 }) == "explore")
S.autovoyage = nil; a = av.settings(); a.risk = "max"
check("goal: max reserve (2) -- supplies at threshold (3) -> end",
      av.goal(a, { x = 1, y = 0, hull = 100, morale = 100, supplies = 3, danger = 0 }) == "end")
check("goal: max reserve (2) -- supplies just above threshold (4) -> explore",
      av.goal(a, { x = 1, y = 0, hull = 100, morale = 100, supplies = 4, danger = 0 }) == "explore")
S.autovoyage = nil; a = av.settings(); a.risk = "balanced"

-- 2) Hull safety: balanced floor 30. hull=25 (<30) with a harbor charted -> repair.
check("goal: hull below floor with a harbor charted -> repair",
      av.goal(a, { x = 1, y = 0, hull = 25, morale = 100, supplies = 100, danger = 0 }) == "repair")
check("goal: hull AT floor (30) is not < floor -> not repair",
      av.goal(a, { x = 1, y = 0, hull = 30, morale = 100, supplies = 100, danger = 0 }) ~= "repair")

-- 3) Morale: risk ~= max and morale < 12 -> end. max risk is exempt.
check("goal: low morale ends the voyage (balanced)",
      av.goal(a, { x = 1, y = 0, hull = 100, morale = 11, supplies = 100, danger = 0 }) == "end")
a.risk = "max"   -- av.settings() is a singleton (S.autovoyage) -- mutate in place, not a copy
check("goal: max risk is exempt from the morale check",
      av.goal(a, { x = 1, y = 0, hull = 100, morale = 5, supplies = 100, danger = 0 }) ~= "end")
a.risk = "balanced"

-- 4) Nothing left to visit -> end, regardless of risk. Grid with no POI/
--    unknown cells and a harbor.
S.autovoyage = nil
set_chart(3, 1, "explore", { "H.." })
a = av.settings(); a.risk = "max"
check("goal: no POI/unknown cell anywhere -> end even under max risk",
      av.goal(a, { x = 1, y = 0, hull = 100, morale = 100, supplies = 100, danger = 0 }) == "end")

-- 4b) Fix round 1, M-2: `steps_harbor`'s literal 8 default (LEGACY:3905,
-- used only when NO harbor is charted at all) was never pinned by value --
-- every no-harbor fixture used supplies clearly above or the "nothing
-- left" branch, never the boundary this constant itself sets. Grid with a
-- POI but NO harbor: threshold is sup <= 8*per_step(1) + reserve(4) = 12.
S.autovoyage = nil
set_chart(3, 1, "explore", { "..X" })   -- POI, no harbor at all
a = av.settings(); a.risk = "balanced"
check("goal: no harbor charted -- steps_harbor default (8): supplies at threshold (12) -> end",
      av.goal(a, { x = 0, y = 0, hull = 100, morale = 100, supplies = 12, danger = 0 }) == "end")
check("goal: no harbor charted -- supplies just above threshold (13) -> explore (POI present)",
      av.goal(a, { x = 0, y = 0, hull = 100, morale = 100, supplies = 13, danger = 0 }) == "explore")

-- 5) Risk-based worked-count thresholds (all other gates passing: hull/
--    supplies/morale high, a POI still present so "nothing left" doesn't
--    fire first).
S.autovoyage = nil
set_chart(3, 1, "explore", { "H.X" })
a = av.settings(); a.risk = "safe"; a.worked = 2
check("goal: safe risk, worked 2 (< 3) -> explore",
      av.goal(a, { x = 1, y = 0, hull = 100, morale = 100, supplies = 100, danger = 0 }) == "explore")
a.worked = 3
check("goal: safe risk, worked 3 (>= 3) -> end",
      av.goal(a, { x = 1, y = 0, hull = 100, morale = 100, supplies = 100, danger = 0 }) == "end")
a = av.settings(); a.risk = "balanced"; a.worked = 8
check("goal: balanced risk, worked 8 (< 9) -> explore",
      av.goal(a, { x = 1, y = 0, hull = 100, morale = 100, supplies = 100, danger = 0 }) == "explore")
a.worked = 9
check("goal: balanced risk, worked 9 (>= 9) -> end",
      av.goal(a, { x = 1, y = 0, hull = 100, morale = 100, supplies = 100, danger = 0 }) == "end")
a = av.settings(); a.risk = "max"; a.worked = 1000
check("goal: max risk never banks on worked-count alone",
      av.goal(a, { x = 1, y = 0, hull = 100, morale = 100, supplies = 100, danger = 0 }) == "explore")

-- =============================================================================
-- av_all_ships (LEGACY:3941-3955)
-- =============================================================================
S.autovoyage = nil
S.voyage_longships = {}
S.ships = {}
set_longships({ longship_entry({ sid = "1", name = "Njord" }), longship_entry({ sid = "2", name = "Ran" }) })
protocol.on_gmcp("Guild.Fleet", { guild = "viking", ships = {
  { name = "Ran", tier = 3, state = "docked", target = "", secs = 0 },
  { name = "Skidbladnir", tier = 3, state = "docked", target = "", secs = 0 },
} })
check("all_ships: merges LONGSHIP + SHIPS, deduped, in order",
      (function()
        local names = av.all_ships()
        return #names == 3 and names[1] == "Njord" and names[2] == "Ran" and names[3] == "Skidbladnir"
      end)())

-- =============================================================================
-- av_pick_offer (LEGACY:3618-3655)
-- =============================================================================
S.autovoyage = nil
a = av.settings()
check("pick_offer: empty offer list -> index 1",
      av.pick_offer(a, { list = {} }) == 1)
check("pick_offer: fit 0 (suicidal) is never picked",
      av.pick_offer(a, { list = { { index = 1, type = "raid", danger = 5, fit = 0 },
                                   { index = 2, type = "raid", danger = 5, fit = 3 } } }) == 2)
-- Fix round 1, M-2: the case above proves fit-0 loses the fit TIE-BREAK
-- against a fit-3 competitor -- it doesn't prove fit-0 is rejected
-- OUTRIGHT (`fit < 1`, LEGACY:3631). A single fit-0 offer, with no
-- competitor, must fall all the way to the bare `return 1` (fit < 1 fails
-- BOTH the eligible check and the fallback's own `fit >= 1` guard) -- never
-- its own index (9, chosen to be unmistakably not 1). A mutation loosening
-- the guard to `fit < 0` would let danger=5/fit=0 straight into the
-- eligible pool instead.
check("pick_offer: fit 0 alone (no competitor) is rejected outright -- bare fallback, not its own index",
      av.pick_offer(a, { list = { { index = 9, type = "raid", danger = 5, fit = 0 } } }) == 1)
check("pick_offer: danger >= 11 excluded unless allow_abyssal",
      av.pick_offer(a, { list = { { index = 1, type = "raid", danger = 12, fit = 3 },
                                   { index = 2, type = "raid", danger = 5, fit = 3 } } }) == 2)
a.allow_abyssal = true
check("pick_offer: danger >= 11 allowed when allow_abyssal is set",
      av.pick_offer(a, { list = { { index = 1, type = "raid", danger = 12, fit = 3 } } }) == 1)
a.allow_abyssal = false
a.diff_min, a.diff_max = 1, 10
check("pick_offer: mission-type priority -- raid (rank 1) beats hunt (rank 5) at equal danger",
      av.pick_offer(a, { list = { { index = 1, type = "hunt", danger = 5, fit = 3 },
                                   { index = 2, type = "raid", danger = 5, fit = 3 } } }) == 2)
check("pick_offer: fit tie-break -- higher fit wins at equal priority/danger",
      av.pick_offer(a, { list = { { index = 1, type = "raid", danger = 5, fit = 2 },
                                   { index = 2, type = "raid", danger = 5, fit = 3 } } }) == 2)
check("pick_offer: danger tie-break -- higher danger wins at equal priority/fit",
      av.pick_offer(a, { list = { { index = 1, type = "raid", danger = 3, fit = 3 },
                                   { index = 2, type = "raid", danger = 7, fit = 3 } } }) == 2)
check("pick_offer: nothing in [diff_min,diff_max] falls back to any non-suicidal, non-Abyssal offer",
      av.pick_offer(a, { list = { { index = 1, type = "raid", danger = 20, fit = 3 } } }) == 1)

-- Fix round 1, I-6: the Abyssal opt-in boundary (danger >= 11) and the
-- fallback pool's own non-Abyssal cap (danger <= 10) were both untested at
-- their exact boundary -- every prior case used danger=12, so a mutation
-- widening either comparison (>= 11 -> >= 12, or <= 10 -> <= 20) survived.
-- A SINGLE offer at exactly the boundary, with no competitor, makes both
-- comparisons observable through the same return value: with the real
-- code, a danger-11 offer is excluded from BOTH the eligible pool (>= 11)
-- and the fallback pool (<= 10 fails for 11), so pick_offer falls all the
-- way through to the bare `return 1` -- never the offer's own index (7,
-- chosen to be unmistakably not 1). Either named mutation lets the danger-
-- 11 offer into ONE of the two pools instead, and pick_offer would return
-- its own index (7) rather than the bare fallback (1).
S.autovoyage = nil
a = av.settings()   -- default diff_min=1, diff_max=99, allow_abyssal=false
check("pick_offer: danger exactly 11 (opt-in boundary) is excluded from BOTH pools -- bare fallback",
      av.pick_offer(a, { list = { { index = 7, type = "raid", danger = 11, fit = 3 } } }) == 1)
-- The other side of the same boundary: danger 10 must be eligible OUTRIGHT
-- (>= 11 does not apply to it), not merely rescued by the fallback -- the
-- fallback only ever runs when the eligible pool is EMPTY (LEGACY:3639's
-- own `if #pool == 0 then`), so a single danger-10 offer alone cannot
-- distinguish "eligible directly" from "excluded, then rescued by
-- fallback" (both land it in `pool` and it wins either way). Adding a
-- second, always-eligible low-danger competitor (danger 5) makes the two
-- cases diverge: if danger-10 is eligible outright, both compete in the
-- SAME pool and the danger tie-break (highest wins) picks the danger-10
-- offer (index 7); if a mutation narrowed >= 11 to >= 10 and wrongly
-- excluded it, the eligible pool becomes non-empty from the danger-5
-- offer ALONE, the fallback branch is skipped entirely (pool isn't empty),
-- and danger-10 is never reconsidered -- the danger-5 offer (index 9)
-- wins instead.
check("pick_offer: danger exactly 10 is eligible outright, wins the danger tie-break over a "
      .. "lower-danger competitor",
      av.pick_offer(a, { list = { { index = 7, type = "raid", danger = 10, fit = 3 },
                                   { index = 9, type = "raid", danger = 5, fit = 3 } } }) == 7)

-- =============================================================================
-- av_log (LEGACY:3657-3663)
-- =============================================================================
S.autovoyage = nil
page_opts.set("av_verbose", false)
printed = {}
av.log("silent when off")
check("log: av_verbose off prints nothing", #printed == 0)
page_opts.set("av_verbose", true)
printed = {}
av.log("hello")
check("log: av_verbose on prints the exact prefix", printed[1] == "[Auto-Voyage] hello", printed[1])
check("log: entry recorded regardless of verbose",
      av.settings().log[#av.settings().log]:find("hello$") ~= nil)
S.autovoyage.log = {}
for i = 1, 31 do av.log("e" .. i) end
check("log: capped at 30 entries, oldest dropped", #av.settings().log == 30
      and av.settings().log[1]:find("e2$") ~= nil)
page_opts.set("av_verbose", false)

print(string.format("\n%d failures so far (pure functions)", failures))

-- =============================================================================
-- auto_voyage_tick (LEGACY:3957-4124) -- the gate list, the branches of the
-- state machine, and the one-action-per-tick property.
-- =============================================================================

-- Keeps the AV_INTERVAL gate open across successive calls in a multi-tick
-- scenario, without a real sleep -- this is plugin-local automation state
-- (S.autovoyage.last), the same documented direct-poke exception used
-- throughout this file.
local function open_interval()
  av.settings().last = os.time() - 1000
end

-- ---- Gate 1: page_opts.get("auto_voyage") off (the shipped default) -------
-- "OFF by default...many ticks over rich state produce zero sends": build a
-- fully eligible, richly-populated scenario (an active voyage paused at a
-- resolvable node) and drive several ticks with the flag at its default
-- (untouched) value.
reset_all()
set_chart(3, 1, "explore", { "H.X" })
set_voyage({ x = 1, y = 0, hull = 100, morale = 100, supplies = 100, danger = 0 })
set_wait("island", { "scout", "plunder" })
open_interval()
for i = 1, 5 do av.tick() end
check("tick/gate 1 (off by default): many ticks over rich state send nothing", #sent == 0)

-- ---- Gate 2: not connected -------------------------------------------------
-- Isolated with the SAME "would send" scenario gate 3 uses below (fix round
-- 1, I-1): without this, S.voyage_status stays nil and both fleet feeds stay
-- empty, so removing the mud.connected() check would land in the
-- no-active-voyage branch, find no ship, and return via the DIFFERENT "no
-- idle ship" no-op -- proving nothing about this gate at all.
reset_all()
page_opts.set("auto_voyage", true)
mud_connected = false
S.mip_voyage_seen = true
clear_voyage()
set_longships({ longship_entry({ sid = "1", name = "Njord", state = "docked" }) })
set_offers("Njord", { { index = 1, type = "raid", danger = 5, fit = 3 } })
open_interval()
av.tick()
check("tick/gate 2 (not connected): blocks alone", #sent == 0)
mud_connected = true

-- ---- Gate 3: AV_INTERVAL (8s) boundary, both directions -------------------
-- Isolated with a scenario that WOULD send once the gate opens: no active
-- voyage, one idle ship, and a matching fresh offer -> a deterministic
-- single "vvoyage launch <ship> <idx>".
reset_all()
page_opts.set("auto_voyage", true)
S.mip_voyage_seen = true
clear_voyage()
set_longships({ longship_entry({ sid = "1", name = "Njord", state = "docked" }) })
set_offers("Njord", { { index = 1, type = "raid", danger = 5, fit = 3 } })
av.settings().last = os.time() - 7
av.tick()
check("tick/gate 3 (AV_INTERVAL): 7s elapsed does not open the gate", #sent == 0)
av.settings().last = os.time() - 8
av.tick()
check("tick/gate 3 (AV_INTERVAL): 8s elapsed opens the gate", #sent == 1 and sent[1] == "vvoyage launch Njord 1", sent[1])

-- ---- Gate 4: mip_voyage_seen not yet true ----------------------------------
-- Same fix (I-2): reset_all() alone leaves S.voyage_status nil and both
-- fleet feeds empty, so without this gate the tick would land in the
-- no-active-voyage branch and return via "no idle ship" -- a different gate.
-- Build the same "would send" scenario gates 2/3 use. M.VOFFERS itself never
-- sets S.mip_voyage_seen (checked directly in handlers/voyage.lua), so
-- set_offers() -- the real wire handler -- can be used here unlike
-- set_longships()/M.LONGSHIP, which DOES set it (every other voyage.lua
-- handler that could supply a ship does too) and would defeat the
-- isolation. S.voyage_longships is therefore the one direct-`S`-poke
-- exception in this case -- plugin-local automation INPUT shape for this
-- isolation only, not a substitute for the wire-fixture rule elsewhere in
-- this file.
reset_all()
page_opts.set("auto_voyage", true)
S.mip_voyage_seen = false
S.voyage_longships = { { name = "Njord", state = "docked" } }
set_offers("Njord", { { index = 1, type = "raid", danger = 5, fit = 3 } })
av.settings().last = os.time() - 1000   -- AV_INTERVAL already open
av.tick()
check("tick/gate 4 (mip_voyage_seen false): blocks alone", #sent == 0)
-- LEGACY:3965-3967's own comment: this gate stops relaunch spam over a LIVE
-- voyage the client just hasn't heard a fresh snapshot for yet -- prove the
-- gate reopens the instant mip_voyage_seen flips true, with everything else
-- unchanged, and the send fires.
S.mip_voyage_seen = true
av.settings().last = os.time() - 1000
av.tick()
check("tick/gate 4: once mip_voyage_seen flips true, the same scenario sends",
      #sent == 1 and sent[1] == "vvoyage launch Njord 1", sent[1])

-- Fix round 1, M-2: `a.last = now` (LEGACY:3963) runs BEFORE the
-- mip_voyage_seen gate, not after -- pin that ordering directly, not just
-- its "still blocks" symptom (which a reordering wouldn't change: either
-- way nothing sends). Rebuild the mip-false scenario and confirm
-- a.last was updated to "now" even though the tick returned early.
reset_all()
page_opts.set("auto_voyage", true)
S.mip_voyage_seen = false
S.voyage_longships = { { name = "Njord", state = "docked" } }
set_offers("Njord", { { index = 1, type = "raid", danger = 5, fit = 3 } })
av.settings().last = os.time() - 1000
av.tick()
check("tick/gate 4: a.last is updated even when the LATER mip_voyage_seen gate blocks",
      os.time() - av.settings().last < 2, av.settings().last)

-- ---- Gate 5: vs.state == "sailing" -----------------------------------------
reset_all()
page_opts.set("auto_voyage", true)
set_chart(3, 1, "explore", { "H.X" })
set_voyage({ state = "sailing", x = 1, y = 0, hull = 100, morale = 100, supplies = 100, danger = 0 })
open_interval()
av.tick()
check("tick/gate 5 (sailing): blocks alone", #sent == 0)

-- ---- Gate 6: non-empty S.voyage_queue --------------------------------------
reset_all()
page_opts.set("auto_voyage", true)
set_chart(3, 1, "explore", { "H.X" })
set_voyage({ state = "idle", x = 1, y = 0, hull = 100, morale = 100, supplies = 100, danger = 0 })
protocol.on_gmcp("Guild.Voyage", { guild = "viking", vqpath = { "A2" } })
open_interval()
av.tick()
check("tick/gate 6 (queue non-empty): blocks alone", #sent == 0)

-- ---- Gate 7: vs.next_move > now --------------------------------------------
-- LEGACY compares vs.next_move directly against os.time() (an epoch
-- second-count), but the field itself is a small per-tick countdown (see
-- notify.lua's own decrement of S.voyage_status.next_move -- "seconds until
-- next move", never an absolute epoch); a MIP-derived value can therefore
-- never actually exceed os.time() in live play, making this branch
-- effectively unreachable in practice. Ported verbatim regardless (not this
-- module's place to "fix" a LEGACY oddity) -- proven live here by
-- constructing the wire value directly, the same "pin the dead branch with
-- a hand-built fixture" approach autotrader/tick.lua's header uses for its
-- own structurally-unreachable guard.
reset_all()
page_opts.set("auto_voyage", true)
set_chart(3, 1, "explore", { "H.X" })
set_voyage({ state = "idle", x = 1, y = 0, hull = 100, morale = 100, supplies = 100, danger = 0,
             next_move = tostring(os.time() + 1000000) })
open_interval()
av.tick()
check("tick/gate 7 (next_move > now): blocks alone", #sent == 0)

-- ---- Branch: no active voyage, no idle ship available ----------------------
reset_all()
page_opts.set("auto_voyage", true)
page_opts.set("av_verbose", false)
clear_voyage()
open_interval()
av.tick()
check("tick/branch: no idle ship -> no send", #sent == 0)
check("tick/branch: no idle ship -> logged",
      av.settings().log[#av.settings().log]:find("no idle ship available to launch$") ~= nil)

-- ---- Branch: no active voyage, fresh matching offers -> launch with index --
reset_all()
page_opts.set("auto_voyage", true)
clear_voyage()
set_longships({ longship_entry({ sid = "1", name = "Njord", state = "docked" }) })
set_offers("Njord", { { index = 1, type = "raid", danger = 5, fit = 3 } })
open_interval()
av.tick()
check("tick/branch: launch via fresh offers -- exact command",
      #sent == 1 and sent[1] == "vvoyage launch Njord 1", sent[1])
check("tick/branch: offers consumed after launch", S.voyage_offers == nil)
check("tick/branch: launch log -- default priority list and \"1-max\" danger band",
      av.settings().log[#av.settings().log]:find(
        "launch Njord contract 1 %(prio raid>salvage>discovery>harvest>hunt, danger 1%-max%)$") ~= nil)

-- ---- Branch: no active voyage, no offers yet -> request, rate-limited 20s --
reset_all()
page_opts.set("auto_voyage", true)
clear_voyage()
set_longships({ longship_entry({ sid = "1", name = "Njord", state = "docked" }) })
open_interval()
av.tick()
check("tick/branch: request contracts -- exact command",
      #sent == 1 and sent[1] == "vvoyage launch Njord", sent[1])
sent = {}
open_interval()
av.tick()   -- offers_req was just set to "now" -- well within the 20s window
check("tick/branch: contract request throttled within 20s", #sent == 0)
-- Fix round 1, M-2: pin the exact 20s boundary (`(now - a.offers_req) > 20`)
-- in both directions -- 20s elapsed does NOT reopen it (not strictly >),
-- 21s does.
sent = {}
av.settings().offers_req = os.time() - 20
open_interval()
av.tick()
check("tick/branch: contract request still throttled at exactly 20s", #sent == 0)
av.settings().offers_req = os.time() - 21
open_interval()
av.tick()
check("tick/branch: contract request re-sent after 20s", #sent == 1 and sent[1] == "vvoyage launch Njord")

-- ---- Branch: paused at harbor with goal == "end" -> bank and end -----------
reset_all()
page_opts.set("auto_voyage", true)
set_chart(3, 1, "explore", { "H.X" })
set_voyage({ state = "idle", x = 0, y = 0, hull = 100, morale = 100, supplies = 100, danger = 0 })
set_wait("harbor", { "trade", "repair" })
av.settings().goal = "end"
open_interval()
av.tick()
check("tick/branch: paused at harbor, goal end -> exact command",
      #sent == 1 and sent[1] == "vvoyage end", sent[1])
check("tick/branch: goal/harbor targets cleared after banking", av.settings().goal == nil)

-- ---- Branch: paused at a non-harbor node -> resolve by need ----------------
reset_all()
page_opts.set("auto_voyage", true)
set_chart(3, 1, "explore", { "H.X" })
set_voyage({ state = "idle", x = 1, y = 0, hull = 100, morale = 100, supplies = 100, danger = 0 })
set_wait("island", { "scout", "plunder" })
open_interval()
av.tick()
check("tick/branch: resolve a non-harbor node -- exact command (generic fallback: plunder)",
      #sent == 1 and sent[1] == "vvoyage resolve plunder", sent[1])
check("tick/branch: worked count incremented on a non-harbor resolve", av.settings().worked == 1)
check("tick/branch: the resolved cell is marked visited", av.settings().visited["1,0"] == true)

-- ---- Branch: exploring -- queues a step toward the nearest POI ------------
reset_all()
page_opts.set("auto_voyage", true)
set_chart(3, 1, "explore", { "H.X" })
set_voyage({ state = "idle", x = 1, y = 0, hull = 100, morale = 100, supplies = 100, danger = 0 })
open_interval()
av.tick()
check("tick/branch: explore step -- exact command (X is one hop east, label A3)",
      #sent == 1 and sent[1] == "vvoyage queue A3", sent[1])

-- ---- Branch: arrived on an explore target that did not auto-pause ---------
reset_all()
page_opts.set("auto_voyage", true)
set_chart(3, 1, "explore", { "H.X" })
set_voyage({ state = "idle", x = 2, y = 0, hull = 100, morale = 100, supplies = 100, danger = 0 })
open_interval()
av.tick()
check("tick/branch: arrived, non-end -- exact command", #sent == 1 and sent[1] == "vvoyage continue", sent[1])
check("tick/branch: arrival marks the cell visited", av.settings().visited["2,0"] == true)

-- ---- Branch: arrived at the harbor with goal == "end" -> bank -------------
reset_all()
page_opts.set("auto_voyage", true)
set_chart(3, 1, "explore", { "H.X" })
set_voyage({ state = "idle", x = 0, y = 0, hull = 100, morale = 100, supplies = 4, danger = 0 })
open_interval()
av.tick()
check("tick/branch: arrived at harbor, goal end -- exact command",
      #sent == 1 and sent[1] == "vvoyage end", sent[1])
check("tick/branch: goal cleared after banking at the harbor", av.settings().goal == nil)

-- ---- Branch: goal == "end" but no harbor charted yet -----------------------
reset_all()
page_opts.set("auto_voyage", true)
set_chart(5, 1, "explore", { "....." })   -- no harbor, no POI, no unknown cell
set_voyage({ state = "idle", x = 2, y = 0, hull = 100, morale = 100, supplies = 100, danger = 0 })
open_interval()
av.tick()
check("tick/branch: end with no charted harbor -- exact command (server rejects harmlessly)",
      #sent == 1 and sent[1] == "vvoyage end", sent[1])
check("tick/branch: goal is NOT cleared on this path (no arrival happened)", av.settings().goal == "end")

-- ---- Branch: boxed in -- target exists but is unreachable through the
-- charted grid; blacklisted immediately (not the 3-strike stuck guard --
-- see below) ----------------------------------------------------------------
reset_all()
page_opts.set("auto_voyage", true)
set_chart(2, 1, "explore", { "..X" })   -- declared width 2 excludes column 2 (the "X")
set_voyage({ state = "idle", x = 0, y = 0, hull = 100, morale = 100, supplies = 100, danger = 0 })
open_interval()
av.tick()
check("tick/branch: boxed in -- no send", #sent == 0)
check("tick/branch: boxed in -- target blacklisted immediately", av.settings().avoid["2,0"] == true)
check("tick/branch: boxed in -- logged",
      av.settings().log[#av.settings().log]:find("boxed in %(explore%); holding$") ~= nil)

-- ---- 3-strike stuck guard: a step is queued successfully but the ship
-- never actually moves (queue stays empty, position unchanged) -- after 3
-- such stuck ticks the target is blacklisted and a fresh one is picked.
-- Grid "..X..I": X at (2,0) dist 2 (nearer, picked first), I at (5,0) dist 5.
-- -----------------------------------------------------------------------------
reset_all()
page_opts.set("auto_voyage", true)
set_chart(6, 1, "explore", { "..X..I" })
set_voyage({ state = "idle", x = 0, y = 0, hull = 100, morale = 100, supplies = 100, danger = 0 })

open_interval(); sent = {}; av.tick()
check("tick/stuck 1: queues toward X, first step A2", #sent == 1 and sent[1] == "vvoyage queue A2", sent[1])
check("tick/stuck 1: not yet blacklisted, stuck counter at 0 (first sighting)",
      av.settings().avoid["2,0"] == nil and av.settings().stuck == 0)

open_interval(); sent = {}; av.tick()
check("tick/stuck 2: re-queues the same step (ship hasn't moved)",
      #sent == 1 and sent[1] == "vvoyage queue A2", sent[1])
check("tick/stuck 2: stuck counter now 1", av.settings().stuck == 1)

open_interval(); sent = {}; av.tick()
check("tick/stuck 3: re-queues again", #sent == 1 and sent[1] == "vvoyage queue A2", sent[1])
check("tick/stuck 3: stuck counter now 2", av.settings().stuck == 2)

open_interval(); sent = {}; av.tick()
check("tick/stuck 4: exactly one send even on the retarget tick", #sent == 1, sent[1])
check("tick/stuck 4: X is now blacklisted", av.settings().avoid["2,0"] == true)
check("tick/stuck 4: stuck counter reset to 0", av.settings().stuck == 0)
check("tick/stuck 4: retargeted to I (5,0), not X (2,0)", av.settings().plan_target == "5,0")
-- Two M.log calls happen in this same tick (the give-up, then the fresh
-- "explore -> A2" retarget), so the give-up line is the second-to-last
-- entry, not necessarily the last -- search the whole log rather than
-- assume position.
do
  local found = false
  for _, line in ipairs(av.settings().log) do
    if line:find("stuck near 0,0 %-%- giving up on 2,0$") then found = true end
  end
  check("tick/stuck 4: exact give-up log line", found)
end

-- ---- One action per tick: every branch above sent at most 1 command; spot-
-- check again on a state with MULTIPLE eligible-looking outcomes stacked
-- (an active, paused, resolvable node -- if the early `return` after the
-- resolve Send were ever removed, execution would fall through into the
-- "still under way" logic below it and could queue a second command).
-- -----------------------------------------------------------------------------
reset_all()
page_opts.set("auto_voyage", true)
set_chart(3, 1, "explore", { "H.X" })
set_voyage({ state = "idle", x = 1, y = 0, hull = 100, morale = 100, supplies = 100, danger = 0 })
set_wait("island", { "scout", "plunder" })
open_interval()
av.tick()
check("tick/one action per tick: exactly one send from a resolvable node", #sent == 1, #sent)

print(string.format("\n%d failures so far (tick)", failures))

-- =============================================================================
-- av_cmd / vk_avoyage_handler -> M.config (LEGACY:4306-4337). Every reply
-- string is asserted byte-exact.
-- =============================================================================
reset_all()
S.autovoyage = nil; av.settings()

printed = {}
av.config("on")
check("config/on: exact ON reply", printed[1] == "[Auto-Voyage] ON.", printed[1])
check("config/on: flag flipped", page_opts.get("auto_voyage") == true)
check("config/on: trailing status line",
      printed[2] == "[Auto-Voyage] ON | risk balanced | ship (auto)", printed[2])

printed = {}
av.config("off")
check("config/off: exact OFF reply", printed[1] == "[Auto-Voyage] OFF.", printed[1])
check("config/off: flag flipped", page_opts.get("auto_voyage") == false)

printed = {}
av.config("max")
check("config/risk: exact reply (no trailing period, unlike on/off)",
      printed[1] == "[Auto-Voyage] risk = max", printed[1])
check("config/risk: risk set", av.settings().risk == "max")

printed = {}
av.config("verbose on")
check("config/verbose on: exact reply", printed[1] == "[Auto-Voyage] verbose ON.", printed[1])
check("config/verbose on: flag set", page_opts.get("av_verbose") == true)
printed = {}
av.config("verbose off")
check("config/verbose off: exact reply", printed[1] == "[Auto-Voyage] verbose OFF.", printed[1])
check("config/verbose off: flag cleared", page_opts.get("av_verbose") == false)

printed = {}
av.config("abyssal on")
check("config/abyssal on: exact reply",
      printed[1] == "[Auto-Voyage] Abyssal (danger 11-15) contracts ENABLED. Fit your ship well.", printed[1])
check("config/abyssal on: flag set", av.settings().allow_abyssal == true)
printed = {}
av.config("abyssal off")
check("config/abyssal off: exact reply",
      printed[1] == "[Auto-Voyage] Abyssal contracts disabled (caps at danger 10).", printed[1])
check("config/abyssal off: flag cleared", av.settings().allow_abyssal == false)

-- NOTE: the "ship" keyword itself is matched against `rest` (not `low`),
-- exactly like LEGACY's own av_cmd (LEGACY:4319: `rest:match("^ship%s+")`)
-- -- so it is case-SENSITIVE (must be typed lowercase), unlike every other
-- keyword here which matches against the lowercased `low`. Verbatim LEGACY
-- quirk, not a lera bug. The ship NAME after it keeps its original case.
printed = {}
av.config("ship Ivarr")
check("config/ship <name>: exact reply, original case preserved",
      printed[1] == "[Auto-Voyage] ship = Ivarr", printed[1])
check("config/ship <name>: ship set", av.settings().ship == "Ivarr")
printed = {}
av.config("Ship Ivarr")   -- capitalized keyword does NOT match (case-sensitive)
check("config/ship <name>: capitalized keyword falls through to the usage error",
      printed[1] and printed[1]:find("^%[Auto%-Voyage%] usage:") ~= nil, printed[1])
printed = {}
av.config("auto")
check("config/auto: exact reply", printed[1] == "[Auto-Voyage] ship = (auto-pick idle)", printed[1])
check("config/auto: ship cleared", av.settings().ship == "")

printed = {}
av.settings().log = {}
av.config("log")
check("config/log (empty): exact header only, no trailing status line",
      #printed == 1 and printed[1] == "[Auto-Voyage] recent actions:", printed[1])
av.settings().log = { "12:00 launch Ship1 contract 1 (...)" }
printed = {}
av.config("log")
check("config/log (non-empty): header + one gray entry, no trailing status line",
      #printed == 2 and printed[1] == "[Auto-Voyage] recent actions:"
        and printed[2] == "  12:00 launch Ship1 contract 1 (...)", table.concat(printed, "|"))

local risk_before = av.settings().risk
printed = {}
local ok_bad = pcall(av.config, "bogus")
check("config/bogus: does not error", ok_bad)
check("config/bogus: exact usage message, no trailing status line",
      #printed == 1 and printed[1] == "[Auto-Voyage] usage: avoyage on|off | balanced|max|safe | "
        .. "abyssal on|off | ship <name>|auto | verbose on|off | log", printed[1])
check("config/bogus: no state disturbed", av.settings().risk == risk_before)

printed = {}
av.config("status")
check("config/status: falls through to the trailing status line, no usage error",
      #printed == 1 and printed[1]:find("^%[Auto%-Voyage%]") ~= nil, printed[1])

printed = {}
av.config("")
check("config/bare (direct call): also falls through to the trailing status line "
      .. "-- the menu-opening behavior lives one level up, in M.voyage_command",
      #printed == 1 and printed[1]:find("^%[Auto%-Voyage%]") ~= nil, printed[1])

page_opts.set("auto_voyage", false)   -- restore default for later tests

-- =============================================================================
-- M.voyage_command: bare opens the menu (deliberate adaptation, see module
-- header); non-bare goes through M.config.
-- =============================================================================
reset_all()
S.autovoyage = nil
last_menu_open = nil
av.voyage_command("")
check("voyage_command bare: opens a menu", last_menu_open ~= nil)
check("voyage_command bare: menu title", last_menu_open and last_menu_open.title == "Auto-Voyage Settings")
check("voyage_command bare: 13 items (7 knobs + header + 5 mission types)",
      last_menu_open and #last_menu_open.items == 13, last_menu_open and #last_menu_open.items)
if last_menu_open then
  local labels = menu_item_labels(last_menu_open)
  check("voyage_command bare: item labels reflect default settings",
        labels[1] == "Auto-Voyage: off" and labels[2] == "Risk profile: balanced"
          and labels[3] == "Min danger: 1" and labels[4] == "Max danger: any"
          and labels[5] == "Abyssal 11-15: no" and labels[6] == "Ship: (auto)"
          and labels[7] == "Verbose log: no" and labels[8] == "Mission priority (click to raise):"
          and labels[9] == "  1. Raid (top)" and labels[10] == "  2. Salvage (^ up)"
          and labels[11] == "  3. Discovery (^ up)" and labels[12] == "  4. Harvest (^ up)"
          and labels[13] == "  5. Hunt (^ up)",
        table.concat(labels, "|"))
end

printed = {}
av.voyage_command("on")
check("voyage_command non-bare: reaches M.config", page_opts.get("auto_voyage") == true
      and printed[1] == "[Auto-Voyage] ON.")
page_opts.set("auto_voyage", false)

-- Selecting "on" toggles and reopens the menu in place (LEGACY:11539).
last_menu_open = nil
av.voyage_command("")
last_menu_open.on_select("on")
check("menu: selecting 'on' flips auto_voyage", page_opts.get("auto_voyage") == true)
check("menu: reopens itself in place", last_menu_open ~= nil)
if last_menu_open then
  check("menu: reopened item reflects the new ON state",
        menu_item_labels(last_menu_open)[1] == "Auto-Voyage: ON")
end

-- Cycling risk: balanced -> max.
last_menu_open.on_select("risk")
check("menu: risk cycles balanced -> max", av.settings().risk == "max")
last_menu_open.on_select("risk")
check("menu: risk cycles max -> safe", av.settings().risk == "safe")
last_menu_open.on_select("risk")
check("menu: risk cycles safe -> balanced", av.settings().risk == "balanced")

-- Cycling min danger: 1 -> 2 (DANGER_LADDER = {1,2,3,4,5,6,8,10,12,15,20,99}).
last_menu_open.on_select("dmin")
check("menu: dmin cycles 1 -> 2", av.settings().diff_min == 2)

-- Abyssal toggle.
last_menu_open.on_select("abyssal")
check("menu: abyssal toggles on", av.settings().allow_abyssal == true)
last_menu_open.on_select("abyssal")
check("menu: abyssal toggles off", av.settings().allow_abyssal == false)

-- Verbose toggle.
last_menu_open.on_select("verbose")
check("menu: verbose toggles on", page_opts.get("av_verbose") == true)
page_opts.set("av_verbose", false)

-- Header row: no-op (menu still reopens, but no field changes).
local risk_snapshot = av.settings().risk
last_menu_open.on_select("_hdr")
check("menu: header row is a no-op", av.settings().risk == risk_snapshot)
check("menu: header row still reopens the menu", last_menu_open ~= nil)

-- Mission priority: promoting "salvage" swaps it with "raid".
check("menu: mission_prio starts raid, salvage, ...",
      av.settings().mission_prio[1] == "raid" and av.settings().mission_prio[2] == "salvage")
last_menu_open.on_select("prio_salvage")
check("menu: promoting salvage swaps it with raid",
      av.settings().mission_prio[1] == "salvage" and av.settings().mission_prio[2] == "raid")

-- Ship cycling: with one known ship, cycles "" (auto) -> "Njord" -> "" (auto).
S.autovoyage.ship = ""
S.voyage_longships = {}
set_longships({ longship_entry({ sid = "1", name = "Njord", state = "docked" }) })
last_menu_open.on_select("ship")
check("menu: ship cycles from auto to the one known ship", av.settings().ship == "Njord")
last_menu_open.on_select("ship")
check("menu: ship cycles back to auto", av.settings().ship == "")

page_opts.set("auto_voyage", false)   -- restore default
S.autovoyage = nil
last_menu_open = nil

print(string.format("\n%d failures so far (config/menu)", failures))

os.exit(failures == 0 and 0 or 1)
