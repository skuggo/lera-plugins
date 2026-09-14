-- guild_viking autoraid.lua unit tests (stage 4 Task 8: the auto-raider).
-- Ported verbatim from LEGACY guild_viking.lua:4137-4303 and
-- 11386-11434/11544-11667. Run from the lera-plugins repo root with
-- LERA_ROOT pointing at a built Lera checkout.
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

-- ---- lera API stubs (same shape as guild_viking_autovoyage_test.lua) ------
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
-- M.open_menu/M.open_target_menu's require("menu") stub -- same shape as
-- guild_viking_autovoyage_test.lua's own preamble.
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
local kingdom = require("handlers.kingdom")
for key, fn in pairs(kingdom._gmcp or {}) do
  protocol.gmcp_handler(key, fn)
end
local city = require("handlers.city")
for key, fn in pairs(city._gmcp or {}) do
  protocol.gmcp_handler(key, fn)
end

local page_opts = require("page_opts")
local ar = require("autoraid")

-- ---------------------------------------------------------------------------
-- Wire-fixture helpers. Every field that arrives over the wire (buildings,
-- ships, longships, raid targets) is built through protocol.ingest with the
-- REAL handlers in handlers/city.lua, handlers/voyage.lua and
-- handlers/kingdom.lua -- never poked into S directly. S.autoraid is the one
-- documented exception (plugin-local automation settings, exactly like
-- S.autotrade/S.autovoyage in the other two suites): it is reset with a
-- plain `S.autoraid = nil` between cases below, and its `target`/`ships`/
-- `convoy`/`last` fields are set directly through ar.settings() for the same
-- reason.
-- ---------------------------------------------------------------------------

-- handlers/voyage.lua's M.SHIPS field order (14 pipe-delimited fields):
-- Fixtures are seeded through the production GMCP path. The builders below
-- still take the same override keys the wire-string versions took, so no call
-- site changes; only the shape they produce does.
local function gm(pkg, payload)
  payload.guild = "viking"
  protocol.on_gmcp(pkg, payload)
end

-- Guild.Fleet's ship record. `ret` -> secs and `sid` -> id are the two
-- override names that differ from the payload's own.
local function ship_entry(overrides)
  local f = { name = "Ship1", tier = 2, state = "docked", target = "", ret = 0,
              sid = nil, crew = 8, convoy = 0, convoy_size = 0, convoy_bonus = 0,
              saga_title = "", saga_raids = 0, held = 0, durability = 100 }
  for k, v in pairs(overrides or {}) do f[k] = v end
  return { name = f.name, tier = tonumber(f.tier), state = f.state,
           target = f.target, secs = tonumber(f.ret), id = tonumber(f.sid),
           crew = tonumber(f.crew), convoy = tonumber(f.convoy),
           convoy_size = tonumber(f.convoy_size),
           convoy_bonus = tonumber(f.convoy_bonus),
           saga_title = f.saga_title, saga_raids = tonumber(f.saga_raids),
           held = tonumber(f.held), durability = tonumber(f.durability) }
end
local function set_ships(entries)
  gm("Guild.Fleet", { ships = entries })
end

-- Guild.Voyage's longship record. Its crew/ship trait lists travel as their
-- own keys, foreign-keyed by ship id, so the builder returns the record and
-- the setter gathers the traits out of it.
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
  gm("Guild.Voyage", { longship = ships, longship_crew_traits = crew,
                       longship_ship_traits = shiptr })
end

local function set_dock(tier)
  gm("Guild.City", { buildings = { { id = "dock", tier = tonumber(tier) } } })
end

-- A raid target is still the "name:good1:good2" string it always was; the
-- server sends the same strings in two arrays where MIP joined them with '|'.
local function target_entry(name, g1, g2)
  return name .. ":" .. (g1 or "") .. ":" .. (g2 or "")
end
local function set_targets(lin, hist)
  gm("Guild.Fleet", { rtargets_lineage = lin or {},
                      rtargets_historical = hist or {} })
end

local function reset_all()
  S.autoraid = nil
  S.buildings = {}
  S.ships = {}
  S.voyage_longships = {}
  S.raid_targets = nil
  S.raid_targets_lin = nil
  S.raid_targets_hist = nil
  S.heat = nil
  mud_connected = true
  sent = {}
  printed = {}
  last_menu_open = nil
  page_opts.set("auto_raid", false)
  page_opts.set("show_city_raidlog", true)
end

-- =============================================================================
-- ar_merged_ships / ar_available_ships (LEGACY:4150-4207)
-- =============================================================================
reset_all()
set_ships({ ship_entry({ name = "A", state = "docked", held = "0" }),
            ship_entry({ name = "B", state = "docked", held = "1" }),
            ship_entry({ name = "C", state = "raiding", held = "0" }) })
check("merged_ships: returns every SHIPS entry", #ar.merged_ships() == 3)
check("available_ships: only docked AND not-held ships qualify",
      (function()
        local avail = ar.available_ships()
        return #avail == 1 and avail[1].name == "A"
      end)())

-- Merge dedup: a ship present in BOTH LONGSHIP and SHIPS is one entry, and
-- the SHIPS-side held flag is preserved so a reserved ship cannot be raided.
reset_all()
set_longships({ longship_entry({ sid = "1", name = "Drakkar", state = "docked" }) })
set_ships({ ship_entry({ name = "Drakkar", state = "docked", held = "1" }),
            ship_entry({ name = "Solo", state = "docked", held = "1" }) })
check("merged_ships: dedups by name across LONGSHIP+SHIPS (2 entries, not 3)",
      #ar.merged_ships() == 2)
check("available_ships: Drakkar's SHIPS-side held=1 is preserved by the merge",
      (function()
        local avail = ar.available_ships()
        for _, sh in ipairs(avail) do if sh.name == "Drakkar" then return false end end
        return true
      end)())
check("available_ships: Solo (SHIPS-only, held=1 intact) is correctly excluded",
      (function()
        local avail = ar.available_ships()
        for _, sh in ipairs(avail) do if sh.name == "Solo" then return false end end
        return true
      end)())

-- =============================================================================
-- ar_max_ships (LEGACY:4209-4224) -- two hand-computed cases, one dock-
-- limited (the DOCK_FLEET cap wins), one ship-count-limited (nonheld wins).
-- =============================================================================

-- Case A (ship-count-limited): dock tier 4 -> DOCK_FLEET[4] = 8. 3 ships
-- owned, 1 held -> nonheld = 2. nonheld(2) < cap(8), so cap clamps down to
-- the non-held ship count: max_ships() = 2.
reset_all()
set_dock(4)
set_ships({ ship_entry({ name = "A", held = "0" }),
            ship_entry({ name = "B", held = "0" }),
            ship_entry({ name = "C", held = "1" }) })
check("max_ships: Case A (ship-count-limited) -- dock T4 cap 8, nonheld 2 -> 2",
      ar.max_ships() == 2, ar.max_ships())

-- Case B (dock-limited): dock tier 2 -> DOCK_FLEET[2] = 4. 6 ships owned, 0
-- held -> nonheld = 6. nonheld(6) >= cap(4), so the clamp does NOT apply and
-- the dock cap wins: max_ships() = 4.
reset_all()
set_dock(2)
set_ships({ ship_entry({ name = "A" }), ship_entry({ name = "B" }), ship_entry({ name = "C" }),
            ship_entry({ name = "D" }), ship_entry({ name = "E" }), ship_entry({ name = "F" }) })
check("max_ships: Case B (dock-limited) -- dock T2 cap 4, nonheld 6 (>= cap) -> 4",
      ar.max_ships() == 4, ar.max_ships())

-- Boundary: dock tier with no buildings at all defaults to tier 1 (cap 2),
-- and a fleet of zero ships (nonheld 0) does NOT trigger the clamp
-- (`nonheld >= 1` fails), so the plain dock cap of 2 stands.
reset_all()
check("max_ships: no buildings/ships at all -- dock defaults to tier 1, cap 2",
      ar.max_ships() == 2, ar.max_ships())

-- Boundary regression, nonheld == cap exactly (dock T2 -> cap 4; 4 ships
-- owned, 0 held -> nonheld = 4): documents the value at this exact boundary
-- (4). HONESTY NOTE (found by attempting the obvious mutation, `<` -> `<=`
-- on LEGACY:4221's `nonheld < cap`): this specific boundary provably CANNOT
-- discriminate `<` from `<=` -- when nonheld == cap, clamping sets
-- `cap = nonheld`, which equals the pre-clamp cap already, so both operators
-- produce the identical return value for every input. `<` vs `<=` at this
-- exact comparison is therefore observationally dead -- no max_ships() test
-- can distinguish them. Kept as a plain regression pin, not a discriminating
-- case (see the task report's mutant table).
reset_all()
set_dock(2)
set_ships({ ship_entry({ name = "A" }), ship_entry({ name = "B" }),
            ship_entry({ name = "C" }), ship_entry({ name = "D" }) })
check("max_ships: boundary regression -- nonheld(4) == cap(4) exactly -> 4",
      ar.max_ships() == 4, ar.max_ships())

print(string.format("\n%d failures so far (pure functions)", failures))

-- =============================================================================
-- auto_raid_tick (LEGACY:4226-4266) -- the gate list and the send branches.
-- =============================================================================

-- Keeps the AR_INTERVAL gate open across successive calls, without a real
-- sleep -- plugin-local automation state (S.autoraid.last), the same
-- documented direct-poke exception used throughout this file.
local function open_interval()
  ar.settings().last = os.time() - 1000
end

-- Canonical "would send" arrangement: on, connected, one idle docked ship,
-- a target set, interval open, default settings (ships=2, convoy=false).
-- Every gate test below builds this THEN blocks exactly one condition, so
-- the paired "un-block it" assertion proves the gate alone was the reason
-- nothing sent.
local function arrange_would_send()
  reset_all()
  page_opts.set("auto_raid", true)
  mud_connected = true
  set_ships({ ship_entry({ name = "Drakkar1", state = "docked" }) })
  ar.settings().target = "Uppsala"
  open_interval()
end

-- ---- Gate 1: page_opts.get("auto_raid") off (the shipped default) --------
arrange_would_send()
page_opts.set("auto_raid", false)   -- override: put the gate back to its default
for i = 1, 5 do ar.tick() end
check("tick/gate 1 (off by default): many ticks over rich state send nothing", #sent == 0)
page_opts.set("auto_raid", true)
ar.tick()
check("tick/gate 1: flipping auto_raid on (all else unchanged) sends exactly once",
      #sent == 1 and sent[1] == "vlongship raid Drakkar1 Uppsala", sent[1])

-- ---- Gate 2: not connected -------------------------------------------------
arrange_would_send()
mud_connected = false
ar.tick()
check("tick/gate 2 (not connected): blocks alone", #sent == 0)
mud_connected = true
ar.tick()
check("tick/gate 2: reconnecting (all else unchanged) sends exactly once",
      #sent == 1 and sent[1] == "vlongship raid Drakkar1 Uppsala", sent[1])

-- ---- Gate 3: ar.target nil/empty ------------------------------------------
arrange_would_send()
ar.settings().target = ""
ar.tick()
check("tick/gate 3 (empty target): blocks alone", #sent == 0)
ar.settings().target = "Uppsala"
ar.tick()
check("tick/gate 3: setting a target (all else unchanged) sends exactly once",
      #sent == 1 and sent[1] == "vlongship raid Drakkar1 Uppsala", sent[1])

-- ---- Gate 4: AR_INTERVAL (20s) boundary, both directions ------------------
arrange_would_send()
ar.settings().last = os.time() - 19
ar.tick()
check("tick/gate 4 (AR_INTERVAL): 19s elapsed does not open the gate", #sent == 0)
ar.settings().last = os.time() - 20
ar.tick()
check("tick/gate 4 (AR_INTERVAL): 20s elapsed opens the gate -- exact send",
      #sent == 1 and sent[1] == "vlongship raid Drakkar1 Uppsala", sent[1])

-- ar.last is updated to `now` only once the gate actually opens (LEGACY:4233
-- runs after the interval check, not before) -- pin that ordering, not just
-- the "still blocks" symptom. Capture the expected value BEFORE calling
-- tick() rather than recomputing os.time() at assertion time, to avoid a
-- one-second race across the two separate os.time() calls.
arrange_would_send()
local last_before = os.time() - 19
ar.settings().last = last_before
ar.tick()
check("tick/gate 4: ar.last is UNCHANGED while the interval gate itself blocks",
      ar.settings().last == last_before, ar.settings().last)

-- ---- Gate 5: no available ships -------------------------------------------
-- NOTE (this gate and every one below it): `ar.last = now` (LEGACY:4233)
-- runs BEFORE this gate is even checked, so the FIRST (blocking) tick()
-- call already consumes the open interval -- open_interval() must be called
-- again before the "unblock" tick, or the interval gate (already proven
-- separately above) would be the thing blocking the second call instead.
--
-- HONESTY NOTE, found via mutation testing (not assumed): unlike every other
-- gate in this file, deleting `if #avail == 0 then return end` from the
-- module does NOT make this test's "blocks" assertion fail -- confirmed by
-- actually deleting it and re-running (module header carries the same
-- disclosure). With avail == 0, n = math.min(0, target_n) always computes to
-- 0, and the solo branch's OWN `n < 1` return catches it identically a few
-- lines later. So this case genuinely cannot be isolated to "gate 5 ALONE" --
-- it is real, verbatim, reachable-in-normal-flow code (this test still
-- pins its coverage), but no fixture can make its removal alone visible.
reset_all()
page_opts.set("auto_raid", true)
ar.settings().target = "Uppsala"
open_interval()
ar.tick()
check("tick/gate 5 (no available ships): sends nothing", #sent == 0)
set_ships({ ship_entry({ name = "Drakkar1", state = "docked" }) })
open_interval()
ar.tick()
check("tick/gate 5: a docked ship appearing (all else unchanged) sends exactly once",
      #sent == 1 and sent[1] == "vlongship raid Drakkar1 Uppsala", sent[1])

-- ---- Gate 6: target_n < 1 (ar.ships explicitly 0) --------------------------
-- Same honesty note as gate 5 above (confirmed by mutation): target_n < 1
-- forces `ar.convoy and target_n >= 2` to fail regardless of ar.convoy, so
-- control always lands in the solo branch, where n = math.min(avail,
-- target_n) <= 0 hits that branch's own `n < 1` return. Deleting this gate
-- alone changes nothing observable either.
arrange_would_send()
ar.settings().ships = 0
ar.tick()
check("tick/gate 6 (ships=0 -> target_n<1): sends nothing", #sent == 0)
ar.settings().ships = 2
open_interval()
ar.tick()
check("tick/gate 6: restoring ships=2 (all else unchanged) sends exactly once",
      #sent == 1 and sent[1] == "vlongship raid Drakkar1 Uppsala", sent[1])
-- Fix round 1, M-5: n=1 (singular "ship", no trailing "s"), convoy=false.
check("tick/gate 6: note text -- singular \"ship\", no convoy suffix",
      printed[1] == "[Auto-Raid] sent 1 ship to Uppsala", printed[1])

-- ---- Gate 7: convoy wait-for-full-set (non-"all" want) ---------------------
-- Dock T3 -> DOCK_FLEET cap 6. 4 padding ships (state "raiding": owned but
-- never available) keep `owned` at 6 throughout, so the ship-count clamp in
-- ar_max_ships (nonheld < cap) never kicks in and mx stays fixed at 6 --
-- otherwise, with only the 2-3 docked ships actually owned, the OWNED-COUNT
-- clamp itself would shrink mx below target_n and this would test gate 6 a
-- second time instead of gate 7. target_n = min(ships=3, mx=6) = 3; with
-- only 2 of the 6 owned ships docked, a convoy of 3 must wait.
reset_all()
page_opts.set("auto_raid", true)
set_dock(3)
local function padding(n, prefix)
  local out = {}
  for i = 1, n do out[#out + 1] = ship_entry({ name = prefix .. i, state = "raiding" }) end
  return out
end
local pad4 = padding(4, "Pad")
set_ships({ ship_entry({ name = "S1", state = "docked" }), ship_entry({ name = "S2", state = "docked" }),
            pad4[1], pad4[2], pad4[3], pad4[4] })
check("tick/gate 7 setup: mx stays at the dock cap (6), unaffected by the "
      .. "owned-ship-count clamp", ar.max_ships() == 6, ar.max_ships())
ar.settings().target = "Uppsala"
ar.settings().convoy = true
ar.settings().ships = 3
open_interval()
ar.tick()
check("tick/gate 7 (convoy wait-for-full, 2 of 3 docked): blocks alone", #sent == 0)
set_ships({ ship_entry({ name = "S1", state = "docked" }), ship_entry({ name = "S2", state = "docked" }),
            ship_entry({ name = "S3", state = "docked" }), pad4[1], pad4[2], pad4[3] })
open_interval()
ar.tick()
check("tick/gate 7: the 3rd ship docking (all else unchanged) sends the exact convoy command",
      #sent == 1 and sent[1] == "vlongship convoy 3 Uppsala", sent[1])

-- ---- Gate 8: convoy minimum of 2 (only reachable via ships="all", since a
-- fixed count already waited for the full set at gate 7) ---------------------
-- Dock T1 -> DOCK_FLEET cap 2. A single padding ship ("Reserve", not held,
-- never docked) keeps owned at 2 even before the 2nd real ship arrives, so
-- mx is fixed at 2 throughout (2 owned ships never triggers the nonheld<cap
-- clamp: 2 is not < 2). ships="all" means target_n = mx = 2 and the
-- wait-for-full check is skipped outright (LEGACY:4248's own `want ~= "all"`
-- guard) -- with only 1 ship docked, n = min(1,2) = 1 < 2, so the convoy
-- still can't sail.
reset_all()
page_opts.set("auto_raid", true)
set_dock(1)
set_ships({ ship_entry({ name = "S1", state = "docked" }), ship_entry({ name = "Reserve", state = "raiding" }) })
check("tick/gate 8 setup: mx stays at the dock cap (2)", ar.max_ships() == 2, ar.max_ships())
ar.settings().target = "Uppsala"
ar.settings().convoy = true
ar.settings().ships = "all"
open_interval()
ar.tick()
check("tick/gate 8 (convoy n<2 via ships=\"all\", 1 docked): blocks alone", #sent == 0)
set_ships({ ship_entry({ name = "S1", state = "docked" }), ship_entry({ name = "S2", state = "docked" }) })
open_interval()
ar.tick()
check("tick/gate 8: a 2nd ship docking (all else unchanged) sends the exact convoy command",
      #sent == 1 and sent[1] == "vlongship convoy 2 Uppsala", sent[1])

-- ---- Branch: solo dispatch sends ONE command PER available ship, up to
-- target_n. ar_merged_ships builds its result via `for _, sh in pairs(merged)
-- do ... end` (LEGACY:4195, ported verbatim) over a table keyed by a
-- synthesized "name:<ship>" string, so WHICH ships land in the first
-- target_n slots is Lua hash-order, not insertion order -- a genuine LEGACY
-- property, not a bug here. target_n == the full available count below, so
-- there is no "which subset" ambiguity: every command should be sent
-- exactly once each, order notwithstanding. ------------------------------
reset_all()
page_opts.set("auto_raid", true)
set_dock(3)   -- cap 6; well above the 3 ships below either way
set_ships({ ship_entry({ name = "Alpha", state = "docked" }),
            ship_entry({ name = "Beta", state = "docked" }),
            ship_entry({ name = "Gamma", state = "docked" }) })
ar.settings().target = "Birka"
ar.settings().convoy = false
ar.settings().ships = 3
open_interval()
ar.tick()
do
  local got = { sent[1], sent[2], sent[3] }
  table.sort(got)
  local want = { "vlongship raid Alpha Birka", "vlongship raid Beta Birka", "vlongship raid Gamma Birka" }
  table.sort(want)
  check("tick/branch: solo dispatch sends exactly target_n (3) commands, one per ship "
        .. "(order unspecified -- see comment above)",
        #sent == 3 and got[1] == want[1] and got[2] == want[2] and got[3] == want[3],
        table.concat(sent, "|"))
end
check("tick/branch: last_dispatch recorded (n, target, convoy=false)",
      ar.settings().last_dispatch.n == 3 and ar.settings().last_dispatch.target == "Birka"
        and ar.settings().last_dispatch.convoy == false)
-- Fix round 1, M-5: LEGACY:4264-4265's user-facing note was never asserted.
-- n=3 (plural "ships"), convoy=false (no " (convoy)" suffix).
check("tick/branch: note text -- plural \"ships\", no convoy suffix",
      printed[1] == "[Auto-Raid] sent 3 ships to Birka", printed[1])

-- ---- Branch: "ships all" solo mode sends up to the dock/fleet cap, a
-- STRICT SUBSET (2 of 3 owned+docked ships) this time -- dock T1 -> cap 2,
-- and 3 owned ships (all docked, none held) leaves nonheld=3 >= cap(2), so
-- the clamp does not apply and mx stays fixed at 2. want="all" -> target_n =
-- mx = 2 < avail (3), so WHICH 2 of the 3 ships get a command is Lua
-- hash-order (see the comment on the previous branch test) -- assert the
-- cap (exactly 2 sent), the exact command TEMPLATE per send, and that the
-- two chosen ships are distinct members of the known fleet, rather than a
-- specific pair. ------------------------------------------------------------
reset_all()
page_opts.set("auto_raid", true)
set_dock(1)   -- cap 2
set_ships({ ship_entry({ name = "One", state = "docked" }),
            ship_entry({ name = "Two", state = "docked" }),
            ship_entry({ name = "Three", state = "docked" }) })
check("tick/branch setup: mx is the dock cap (2), not the owned count (3)",
      ar.max_ships() == 2, ar.max_ships())
ar.settings().target = "Birka"
ar.settings().convoy = false
ar.settings().ships = "all"
open_interval()
ar.tick()
do
  local fleet = { One = true, Two = true, Three = true }
  local chosen = {}
  local all_match = true
  for _, cmd in ipairs(sent) do
    -- Fix round 1, M-9: guard the nil case explicitly -- `chosen[name] =
    -- true` with name == nil ("table index is nil") would ABORT the whole
    -- suite mid-file rather than fail this one case cleanly, hiding every
    -- test below it (including the entire config/menu section) during
    -- exactly the mutation runs this suite exists to support.
    local name = cmd:match("^vlongship raid (%a+) Birka$")
    if not name or not fleet[name] or chosen[name] then
      all_match = false
    else
      chosen[name] = true
    end
  end
  check("tick/branch: ships=\"all\" solo -- exactly 2 commands, each a distinct known ship, "
        .. "capped to dock tier 1's fleet cap (2), not all 3",
        #sent == 2 and all_match, table.concat(sent, "|"))
end

-- ---- Branch: convoy sails once the full requested count is docked --------
-- Fix round 1, M-8(a): dock T2 gives DOCK_FLEET[2] = 4, but the comment
-- previously said "cap 4" without accounting for the owned-ship-count
-- clamp -- 2 ships owned, 0 held -> nonheld = 2 < 4, so mx actually clamps
-- down to 2 here, not 4. target_n = min(ships=2, mx=2) = 2 either way, so
-- the expectation below is unaffected -- only the comment was wrong.
reset_all()
page_opts.set("auto_raid", true)
set_dock(2)   -- DOCK_FLEET[2]=4, but nonheld=2 clamps mx down to 2 (see above)
set_ships({ ship_entry({ name = "S1", state = "docked" }), ship_entry({ name = "S2", state = "docked" }) })
ar.settings().target = "Uppsala"
ar.settings().convoy = true
ar.settings().ships = 2
open_interval()
ar.tick()
check("tick/branch: convoy of exactly the requested count -- exact command",
      #sent == 1 and sent[1] == "vlongship convoy 2 Uppsala", sent[1])
check("tick/branch: last_dispatch records convoy=true", ar.settings().last_dispatch.convoy == true)
-- Fix round 1, M-5: n=2 (plural "ships"), convoy=true (" (convoy)" suffix).
check("tick/branch: note text -- plural \"ships\" AND the convoy suffix",
      printed[1] == "[Auto-Raid] sent 2 ships to Uppsala (convoy)", printed[1])

-- =============================================================================
-- Rotate mode: ar.mode == "rotate" picks a lineage-city target by heat
-- instead of using ar.target, gated the same as fixed mode otherwise.
-- S.heat is 1-based by lineage id (client.h's _v_heat()); poked directly
-- here, same documented direct-poke exception as S.autoraid itself (this
-- suite has no reason to round-trip the real HEAD/HEAT wire handler just to
-- seed a read-only fixture that pick_rotate_target only ever reads).
-- =============================================================================

-- ---- rotate mode with no target set still sends (target only gates fixed
-- mode) -----------------------------------------------------------------
reset_all()
page_opts.set("auto_raid", true)
set_ships({ ship_entry({ name = "Drakkar1", state = "docked" }) })
ar.settings().mode = "rotate"
-- All 13 seeded: an unseeded lineage reads 0 via pick_rotate_target's own
-- `or 0` fallback and would win as "coldest", so a partial fixture would
-- test the fallback rather than the heat ordering.
S.heat = { 50, 10, 30, 60, 70, 80, 90, 55, 65, 75, 85, 95, 45 }
open_interval()
ar.tick()
check("tick/rotate: empty ar.target does not block rotate mode",
      #sent == 1, table.concat(sent, "|"))
check("tick/rotate: picks the lowest-heat town (lineage 2 = Eiriksby)",
      sent[1] == "vlongship raid Drakkar1 Eiriksby", sent[1])
check("tick/rotate: records last_rotate for next tick's exclusion",
      ar.settings().last_rotate == "Eiriksby", ar.settings().last_rotate)

-- ---- rotate mode excludes the immediately-previous pick when a
-- within-band alternative exists ----------------------------------------
reset_all()
page_opts.set("auto_raid", true)
set_ships({ ship_entry({ name = "Drakkar1", state = "docked" }) })
ar.settings().mode = "rotate"
ar.settings().last_rotate = "Eiriksby"
-- Lineages 2 (Eiriksby) and 3 (Imaird) tie at the minimum heat (10); every
-- other town sits far outside AR_ROTATE_HEAT_BAND (5) of that minimum. With
-- Eiriksby excluded as the last pick, Imaird is the only one left in the
-- pool, so the pick is deterministic despite the random tie-break.
S.heat = { 50, 10, 10, 60, 70, 80, 90, 55, 65, 75, 85, 95, 45 }
open_interval()
ar.tick()
check("tick/rotate: excludes the immediately-previous pick from a tied pool",
      sent[1] == "vlongship raid Drakkar1 Imaird", sent[1])

-- ---- rotate mode still allows repeating the previous pick when it is the
-- ONLY town within the heat band (no alternative exists) -----------------
reset_all()
page_opts.set("auto_raid", true)
set_ships({ ship_entry({ name = "Drakkar1", state = "docked" }) })
ar.settings().mode = "rotate"
ar.settings().last_rotate = "Eiriksby"
S.heat = { 90, 10, 90, 90, 90, 90, 90, 90, 90, 90, 90, 90, 90 }
open_interval()
ar.tick()
check("tick/rotate: repeats the previous pick when it is the only one in band",
      sent[1] == "vlongship raid Drakkar1 Eiriksby", sent[1])

-- ---- fixed mode is unaffected: ar.target still gates, ar.mode defaults
-- to "fixed" -------------------------------------------------------------
reset_all()
page_opts.set("auto_raid", true)
set_ships({ ship_entry({ name = "Drakkar1", state = "docked" }) })
check("rotate: ar.mode defaults to \"fixed\"", ar.settings().mode == "fixed")
ar.settings().target = ""
open_interval()
ar.tick()
check("tick/rotate: fixed mode with empty target still blocks (unchanged gate)",
      #sent == 0)

print(string.format("\n%d failures so far (tick)", failures))

-- =============================================================================
-- ar_config / vk_araid_handler -> M.config (LEGACY:4269-4297). Every reply
-- string asserted byte-exact.
-- =============================================================================
reset_all()

printed = {}
ar.config("on")
check("config/on: exact ON reply", printed[1] == "[Auto-Raid] ON.", printed[1])
check("config/on: flag flipped", page_opts.get("auto_raid") == true)
check("config/on: trailing status line",
      printed[2] == "[Auto-Raid] ON | mode fixed | ships 2 | convoy no | target (none)", printed[2])
-- Persistence-on-toggle: OnPluginSaveState() (LEGACY:4289) is an IMMEDIATE
-- persist.save() -- prove the store snapshot reflects the flip right away,
-- not merely that the in-memory flag flipped.
check("config/on: persists IMMEDIATELY (store snapshot reflects the flip without "
      .. "a separate /vik save)", stored ~= nil and stored.page_opts and stored.page_opts.auto_raid == true)

printed = {}
ar.config("off")
check("config/off: exact OFF reply", printed[1] == "[Auto-Raid] OFF.", printed[1])
check("config/off: flag flipped", page_opts.get("auto_raid") == false)
check("config/off: persists immediately too", stored.page_opts.auto_raid == false)

printed = {}
ar.config("convoy on")
check("config/convoy on: exact reply", printed[1] == "[Auto-Raid] convoy ON.", printed[1])
check("config/convoy on: flag set", ar.settings().convoy == true)
printed = {}
ar.config("convoy off")
check("config/convoy off: exact reply", printed[1] == "[Auto-Raid] convoy OFF.", printed[1])
check("config/convoy off: flag cleared", ar.settings().convoy == false)

printed = {}
ar.config("all")
check("config/all: exact reply", printed[1] == "[Auto-Raid] ships = all.", printed[1])
check("config/all: ships set to the string \"all\"", ar.settings().ships == "all")

printed = {}
ar.config("ships 3")
check("config/ships <n>: no dedicated reply line (falls straight to the status line)",
      #printed == 1, table.concat(printed, "|"))
check("config/ships <n>: ships set numerically", ar.settings().ships == 3)

-- "ships all" (non-digit) is NOT valid grammar -- only the bare "all" keyword
-- sets ar.ships = "all" (LEGACY:4278 vs. the digit-only match at 4280-4281).
-- Verbatim LEGACY quirk, not a lera bug.
printed = {}
ar.settings().ships = 2
ar.config("ships all")
check("config/\"ships all\": digit-only grammar rejects it -- falls through to the usage error",
      printed[1] == "[Auto-Raid] usage: araid on|off | convoy on|off | ships <n>|all | target <name> | mode fixed|rotate",
      printed[1])
check("config/\"ships all\": no state disturbed", ar.settings().ships == 2)

printed = {}
ar.config("target Uppsala")
check("config/target <name>: exact reply", printed[1] == "[Auto-Raid] target = Uppsala", printed[1])
check("config/target <name>: target set", ar.settings().target == "Uppsala")

printed = {}
local ok_bad = pcall(ar.config, "bogus")
check("config/bogus: does not error", ok_bad)
check("config/bogus: exact usage message, no trailing status line",
      #printed == 1 and printed[1] == "[Auto-Raid] usage: araid on|off | convoy on|off | "
        .. "ships <n>|all | target <name> | mode fixed|rotate", printed[1])

printed = {}
ar.config("status")
check("config/status: falls through to the trailing status line, no usage error",
      #printed == 1 and printed[1]:find("^%[Auto%-Raid%]") ~= nil, printed[1])

printed = {}
ar.config("")
check("config/bare (direct call): also falls through to the trailing status line -- "
      .. "the menu-opening behavior lives one level up, in M.raid_command",
      #printed == 1 and printed[1]:find("^%[Auto%-Raid%]") ~= nil, printed[1])

page_opts.set("auto_raid", false)   -- restore default for later tests

-- =============================================================================
-- M.raid_command: bare opens the menu; non-bare goes through M.config.
-- =============================================================================
reset_all()
last_menu_open = nil
ar.raid_command("")
check("raid_command bare: opens a menu", last_menu_open ~= nil)
check("raid_command bare: menu title", last_menu_open and last_menu_open.title == "Auto-Raid Settings")

printed = {}
ar.raid_command("on")
check("raid_command non-bare: reaches M.config", page_opts.get("auto_raid") == true
      and printed[1] == "[Auto-Raid] ON.")
page_opts.set("auto_raid", false)

-- =============================================================================
-- The settings menu (LEGACY:11397-11434, 11544-11575) and target picker
-- (LEGACY:11579-11667).
-- =============================================================================
reset_all()
last_menu_open = nil
ar.raid_command("")
check("menu: 6 items, LEGACY's araid_menu_build order plus the Mode entry",
      last_menu_open and #last_menu_open.items == 6, last_menu_open and #last_menu_open.items)
if last_menu_open then
  local labels = menu_item_labels(last_menu_open)
  check("menu: item labels reflect default settings (dock defaults to tier 1, cap 2)",
        labels[1] == "Auto-Raid: off" and labels[2] == "Convoy: no"
          and labels[3] == "Ships to send (max 2): 2" and labels[4] == "Mode: fixed"
          and labels[5] == "Target: (pick)" and labels[6] == "Show raid log: yes",
        table.concat(labels, "|"))
end

-- Selecting "on" toggles, saves immediately, and reopens the menu in place.
-- Fix round 1, I-1: clear the leftover `stored` snapshot from the earlier
-- `raid_command("on")` call (line 592) FIRST -- that call already left
-- stored.page_opts.auto_raid == true, and this menu action also flips
-- auto_raid to true, so without clearing, the assertion below would pass
-- even with menu_pick's own save() call deleted (confirmed by mutation).
stored = nil
last_menu_open.on_select("on")
check("menu: selecting 'on' flips auto_raid", page_opts.get("auto_raid") == true)
check("menu: selecting 'on' persists immediately", stored ~= nil and stored.page_opts.auto_raid == true)
check("menu: reopens itself in place", last_menu_open ~= nil)
if last_menu_open then
  check("menu: reopened item reflects the new ON state",
        menu_item_labels(last_menu_open)[1] == "Auto-Raid: ON")
end

-- Convoy toggle.
last_menu_open.on_select("convoy")
check("menu: convoy toggles on", ar.settings().convoy == true)
last_menu_open.on_select("convoy")
check("menu: convoy toggles off", ar.settings().convoy == false)

-- Log toggle.
last_menu_open.on_select("log")
check("menu: log toggles show_city_raidlog off", page_opts.get("show_city_raidlog") == false)
page_opts.set("show_city_raidlog", true)

-- Ships cycling (LEGACY:11545-11551): 1 -> 2 -> ... -> cap -> "all" -> 1.
-- Dock defaults to tier 1 here (cap 2).
ar.settings().ships = 1
last_menu_open.on_select("ships")
check("menu: ships cycles 1 -> 2 (dock T1 cap)", ar.settings().ships == 2)
last_menu_open.on_select("ships")
check("menu: ships cycles at the cap -> \"all\"", ar.settings().ships == "all")
last_menu_open.on_select("ships")
check("menu: ships cycles from \"all\" back to 1", ar.settings().ships == 1)

-- Target picker: empty target list prints LEGACY's exact message and
-- reopens the settings menu instead of opening a broken empty picker.
set_targets({}, {})
printed = {}
last_menu_open.on_select("target")
check("menu/target (empty list): exact message",
      printed[1] == "[Auto-Raid] No target list yet - wait for a city update.", printed[1])
check("menu/target (empty list): reopens the settings menu",
      last_menu_open ~= nil and last_menu_open.title == "Auto-Raid Settings")

-- Target picker: populated list -- LEGACY quirk (ported verbatim, see module
-- header): opening the picker and picking a target do NOT call
-- persist.save() the way every other menu item does.
set_targets({ target_entry("Uppsala", "furs", "iron") }, { target_entry("Birka") })
stored = nil   -- clear so we can prove the picker path does not touch it
last_menu_open.on_select("target")
check("menu/target (populated): opens the target picker, not the settings menu",
      last_menu_open ~= nil and last_menu_open.title == "Pick Raid Target")
check("menu/target: opening the picker does NOT persist (LEGACY quirk, ported verbatim)",
      stored == nil)
if last_menu_open then
  local labels = menu_item_labels(last_menu_open)
  -- Fix round 1, I-3: the goods text ("name good1 good2", LEGACY's own
  -- cell()-closure field order) is restored -- Uppsala was seeded with
  -- g1="furs"/g2="iron" -> good_label("furs")="Furs", good_label("iron")=
  -- "Iron"; Birka was seeded with no goods at all, so its label is the bare
  -- name (target_label appends nothing when e.g1/e.g2 are both nil).
  check("menu/target: lineage/historical groups with header rows AND goods text",
        labels[1] == "Lineage Cities:" and labels[2] == "  Uppsala Furs Iron"
          and labels[3] == "Other Targets:" and labels[4] == "  Birka",
        table.concat(labels, "|"))
end
printed = {}
last_menu_open.on_select("lin_1")
check("menu/target: picking a lineage entry sets the target -- exact reply",
      printed[1] == "[Auto-Raid] target = Uppsala (mode = fixed)", printed[1])
check("menu/target: target actually set", ar.settings().target == "Uppsala")
check("menu/target: picking an explicit target forces mode back to fixed",
      ar.settings().mode == "fixed")
check("menu/target: picking does NOT persist either (LEGACY quirk, ported verbatim)",
      stored == nil)
check("menu/target: reopens the settings menu afterward",
      last_menu_open ~= nil and last_menu_open.title == "Auto-Raid Settings")

page_opts.set("auto_raid", false)   -- restore default
S.autoraid = nil
last_menu_open = nil

print(string.format("\n%d failures so far (config/menu)", failures))

os.exit(failures == 0 and 0 or 1)
