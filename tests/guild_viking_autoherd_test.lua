-- guild_viking Auto-Herd tests. Run from the lera-plugins repo root with
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

ui = { dirty = function() end }
lera = { time = function() return 1000 end }
-- Notes are recorded, not discarded: the warn-dedupe case below counts them.
local notes = {}
buffer = { color_print = function(_, _, text) notes[#notes + 1] = text end }
local function count_notes(needle)
  local n = 0
  for _, t in ipairs(notes) do
    if t:find(needle, 1, true) then n = n + 1 end
  end
  return n
end
-- Task 4 adds M.tick(), which gates on mud.connected() and sends through
-- mud.send() -- the same two-function stub guild_viking_autoraid_test.lua
-- carries for the identical reason. `sent` is captured by the closure, so
-- reassigning it below (sent = {}) resets the recorder in place.
local mud_connected = true
local sent = {}
mud = {
  send = function(cmd) sent[#sent + 1] = cmd end,
  connected = function() return mud_connected end,
}
-- Task-3-brief correction #2 (beyond the page_opts.auto_herd fix): the
-- brief's own test content omits a `store` stub. autoherd.lua's M.config
-- persists through the same mechanism autoraid.lua uses -- M.config calls a
-- local save() that requires("persist").save(), and persist.lua's M.save()
-- calls store.set()/store.save() unconditionally. Without this stub the
-- very first ah.config() call below errors ("attempt to index a nil value
-- (global 'store')"). guild_viking_autoraid_test.lua already carries this
-- exact stub for the identical reason -- mirrored verbatim here rather than
-- inventing a new shape.
local stored = nil
store = {
  load = function() end,
  get = function() return stored end,
  set = function(d) stored = d end,
  save = function() end,
}

local S = require("state").S
local page_opts = require("page_opts")
local ah = require("autoherd")

-- ---- defaults --------------------------------------------------------------
-- LEGACY's defaults are preserved deliberately, including the three spending
-- actions defaulting ON: the master page_opts.auto_herd toggle is the gate.
local s = ah.settings()
check("goal default", s.goal == "yield")
check("reserve default", s.reserve == 2000)
check("keep default", s.keep == 4)
check("gen_refresh default", s.gen_refresh == 0)
check("age_refresh default", s.age_refresh == 40)
check("restock on by default", s.restock == true)
check("crossbreed on by default", s.crossbreed == true)
check("buy_quality on by default", s.buy_quality == true)
check("feed_guard on by default", s.feed_guard == true)
check("feed_ticks default", s.feed_ticks == 4)
check("quality_margin default", s.quality_margin == 5)
check("trait_pref default", s.trait_pref == "any")
-- Task-3-brief correction #1 (explicitly given): page_opts keeps its values
-- in a private closure, so page_opts.auto_herd is nil -- page_opts.get(key)
-- is the only correct read API (page_opts.set(key, v) the only write API),
-- matching every existing page/test in this plugin.
check("master toggle off by default", page_opts.get("auto_herd") == false)
check("interval is 20s", ah.AH_INTERVAL == 20)

-- ---- config surface --------------------------------------------------------
ah.config("reserve 500")
check("config reserve", ah.settings().reserve == 500)
ah.config("cross off")
check("config cross off", ah.settings().crossbreed == false)
ah.config("goal balanced")
check("config goal", ah.settings().goal == "balanced")
ah.config("trait hardy")
check("config trait", ah.settings().trait_pref == "hardy")
ah.config("bldg byre target 10")
check("config per-building target",
      ah.settings().buildings.byre and ah.settings().buildings.byre.target == 10)
ah.config("bldg byre off")
check("config per-building disable",
      ah.settings().buildings.byre.enabled == false)

-- An unknown directive must not silently succeed.
local before = ah.settings().reserve
ah.config("nonsense 12")
check("unknown config directive leaves settings alone",
      ah.settings().reserve == before)

-- ---- menu ------------------------------------------------------------------
local items = ah.menu_items()
check("menu lists items", type(items) == "table" and #items > 0)
local ids = {}
for _, it in ipairs(items) do if it.id then ids[it.id] = true end end
check("menu exposes the four action toggles",
      ids.feed and ids.restock and ids.cross and ids.quality)

-- Review-round fix 4: S.buildings is {} up to this point (state.lua's own
-- default), so owns() has been false for all five buildings throughout the
-- run above -- the per-building rows and the "_none" fallback they gate
-- were previously untested. Assert both states explicitly.
check("no buildings owned: the fallback row appears", ids._none == true)
check("no buildings owned: no per-building row appears",
      not (ids.bldg_sheepfold or ids.bldg_henhouse or ids.bldg_piggery
           or ids.bldg_byre or ids.bldg_stable))

S.buildings = { sheepfold = 2, byre = 1 }
local items2 = ah.menu_items()
local ids2 = {}
for _, it in ipairs(items2) do if it.id then ids2[it.id] = true end end
check("owning sheepfold+byre: their rows appear",
      ids2.bldg_sheepfold and ids2.bldg_byre)
check("owning sheepfold+byre: an unowned building produces no row",
      not (ids2.bldg_henhouse or ids2.bldg_piggery or ids2.bldg_stable))
check("owning any building: the fallback row vanishes", ids2._none == nil)

-- LEGACY:614-645's per-building row content: head against cap, `tgt` and
-- `keep`. `keep` is settable through `/vik herd bldg <name> keep <n>` and was
-- previously unreadable anywhere in the UI, and head-against-cap is what says
-- whether a target is even reachable.
local function bldg_label(items_arr, b)
  for _, it in ipairs(items_arr) do
    if it.id == ("bldg_" .. b) then return it.label end
  end
  return nil
end
S.herds = { sheepfold = { bldg = "sheepfold", head = 4, gen = 0, sterile = 0,
                          hard = 1, fert = 1, yield = 1, vigor = 1, con = 1,
                          breed = "nordic", hv = 0, age_ticks = 1 } }
ah.config("bldg sheepfold keep 6")
local row = bldg_label(ah.menu_items(), "sheepfold")
check("the per-building row shows head against the tier cap",
      row and row:find("4/14", 1, true) ~= nil, row)
check("the per-building row shows the target", row and row:find("tgt:auto", 1, true) ~= nil, row)
check("the per-building row shows keep", row and row:find("keep:6", 1, true) ~= nil, row)
ah.config("bldg sheepfold target 9")
row = bldg_label(ah.menu_items(), "sheepfold")
check("an explicit target replaces 'auto' in the row",
      row and row:find("tgt:9", 1, true) ~= nil, row)
ah.config("bldg sheepfold off")
row = bldg_label(ah.menu_items(), "sheepfold")
check("a disabled building's row reads OFF, as LEGACY's did",
      row and row:find("OFF", 1, true) ~= nil, row)
ah.config("bldg sheepfold on")
ah.config("bldg sheepfold target 0")
S.autoherd = nil
ah.settings()
S.herds = {}

-- status_line()'s "owned: ..." branch (only reachable when owns(b) is true
-- for at least one building) is exercised the same way -- via M.config's
-- blank/"status" directive -- so it isn't left at zero coverage either.
-- note() is a stub, so this only asserts the call does not error.
local ok_status = pcall(ah.config, "status")
check("config status with an owned building does not error", ok_status)

-- ---- planner ---------------------------------------------------------------
-- Reset to defaults for the planner cases.
S.autoherd = nil
local s2 = ah.settings()
S.daler = 100000
S.lpending = {}

-- No owned husbandry building: the planner must refuse, with a reason.
S.buildings = {}
S.herds = {}
local act, why = ah.plan()
check("no buildings -> no action", act == nil)
check("no buildings -> reason given", type(why) == "string" and #why > 0)

-- Owned but disabled: still no action.
S.buildings = { sheepfold = 2 }
ah.config("bldg sheepfold off")
act = ah.plan()
check("disabled building -> no action", act == nil)
ah.config("bldg sheepfold on")

-- Empty owned building with restock on and an affordable listing -> one buy.
S.herds = {}
S.lmarket = {
  [1] = { { lin = 1, idx = 0, species = "sheep", breed = "nordic", count = 1,
            price = 400, hard = 30, fert = 40, yield = 50, vigor = 45,
            con = 35, trait = "0" } },
}
act = ah.plan()
check("restock plans a buy", act ~= nil and act.kind == "buy")
check("buy command shape and 1-based id",
      act and act.cmd == "vlivestock buy lodbrok 1",
      act and act.cmd)

-- Below reserve: nothing may be bought.
S.daler = 100
act = ah.plan()
check("below reserve -> no buy", act == nil or act.kind ~= "buy")
S.daler = 100000

-- At building cap: no restock buy.
S.herds = {
  sheepfold = { bldg = "sheepfold", head = 14, quality = 61, gen = 1,
                sterile = 0, hard = 40, fert = 55, yield = 70, vigor = 66,
                con = 50, breed = "nordic", hv = 1, trait = nil,
                age_ticks = 1 },
}
act = ah.plan()
check("at cap -> no restock buy", act == nil or act.kind ~= "buy")

-- Feed shortfall with feed_guard on: a warning, never a command.
S.lfeed = { grain = 0, water = 0, head = 14 }
act = ah.plan()
check("feed shortfall warns", act ~= nil and act.kind == "warn")
check("a warning carries no command", act and act.cmd == nil)

-- The planner never emits more than one action per cycle.
check("plan returns a single action, not a list",
      act == nil or act.kind ~= nil)

-- Slaughter must never be emitted, under any settings.
S.lfeed = { grain = 9999, water = 9999, head = 1 }
for _ = 1, 5 do
  local a = ah.plan()
  check("never emits slaughter",
        a == nil or a.cmd == nil or a.cmd:find("slaughter", 1, true) == nil)
end

-- ---- feed guard: the source of the grain figure ----------------------------
-- Added beyond the brief. The brief said to compare the herds' per-tick draw
-- against S.lfeed.grain, but S.lfeed.grain is itself a per-tick NEED (the
-- server's _v_lfeed(), client.h:4202, fills it from
-- query_livestock_feed_needs(), query.h:2464, and vlivestock.c:608 renders
-- it as "Feed per tick: N grain"). Comparing a need against need *
-- feed_ticks is true for every positive head, which would make the feed
-- guard fire forever. LEGACY:233 compares the WAREHOUSE stock, which is what
-- this port does -- assert that a stocked warehouse actually clears the
-- warning, since S.lfeed.grain stays 0 throughout.
S.autoherd = nil
ah.settings()
S.daler = 100000
S.lpending = {}
S.buildings = { sheepfold = 2 }
S.herds = {
  sheepfold = { bldg = "sheepfold", head = 14, gen = 1, sterile = 0,
                hard = 40, fert = 55, yield = 70, vigor = 66, con = 50,
                breed = "nordic", hv = 1, age_ticks = 1 },
}
S.lfeed = { grain = 0, water = 0, head = 14 }
S.wstock, S.wstock_by_good = nil, nil
act = ah.plan()
check("empty warehouse -> feed guard warns", act ~= nil and act.kind == "warn")
S.wstock_by_good = { grain = { good = "grain", amount = 9999 } }
S.wstock = { { good = "grain", amount = 9999 } }
act, why = ah.plan()
check("stocked warehouse -> feed guard silent (herd at cap, so still no buy)",
      act == nil, act and act.why)
check("stocked warehouse -> a reason is still returned",
      type(why) == "string" and #why > 0)

-- ---- crossbreed: the generation threshold ----------------------------------
-- Added beyond the brief. LEGACY's planner reads `herd.generation`
-- (husbandry.lua:298); handlers/livestock.lua stores that field as `gen`,
-- the key the server's _v_herds() builder emits. A literal port reads nil,
-- falls back to 0, and `0 >= thresh` is false for every positive threshold,
-- so crossbreed would silently never fire on generation -- it would still
-- fire on sterility and age, so the module would look alive with half this
-- branch dead. These two cases pin the generation path on its own: quality
-- buy-ins are off and the age threshold is 0 (off), so a buy here can only
-- have come from the generation comparison.
S.autoherd = nil
ah.settings()
ah.config("quality off")
ah.config("age 0")
S.daler = 100000
S.lpending = {}
S.buildings = { sheepfold = 2 }         -- tier 2 -> cap 14
S.lfeed = { grain = 0, water = 0, head = 4 }
S.wstock_by_good = { grain = { good = "grain", amount = 9999 } }
S.wstock = { { good = "grain", amount = 9999 } }
-- Two listings: the same breed as the herd, and a different one. Crossbreed
-- must pick the DIFFERENT breed (idx 1 -> wire id 2). The fresh lot now
-- matches herd stats: the old inferior fixture would fail the no-loss gate,
-- obscuring these tests' generation/sterility/age trigger checks.
S.lmarket = {
  [1] = {
    { lin = 1, idx = 0, species = "sheep", breed = "nordic", count = 1,
      price = 400, hard = 99, fert = 99, yield = 99, vigor = 99, con = 99 },
    { lin = 1, idx = 1, species = "sheep", breed = "highland", count = 1,
      price = 400, hard = 40, fert = 55, yield = 70, vigor = 66, con = 50 },
  },
}
-- head 4 == the restock floor (keep = 4), so restock cannot fire; con 50
-- makes the auto (gen_refresh = 0) threshold floor(50/20) + 5 = 7.
local function set_herd(gen)
  S.herds = {
    sheepfold = { bldg = "sheepfold", head = 4, quality = 60, gen = gen,
                  sterile = 0, hard = 40, fert = 55, yield = 70, vigor = 66,
                  con = 50, breed = "nordic", breeds = { "nordic" }, hv = 0, age_ticks = 1 },
  }
end

set_herd(0)
act = ah.plan()
check("generation under the auto threshold -> no crossbreed buy",
      act == nil or act.kind ~= "buy", act and act.cmd)

set_herd(8)
act = ah.plan()
check("generation over the auto threshold -> a crossbreed buy",
      act ~= nil and act.kind == "buy", act and act.why)
check("crossbreed prefers a different breed (idx 1 -> 1-based id 2)",
      act and act.cmd == "vlivestock buy lodbrok 2", act and act.cmd)

-- An explicit gen threshold overrides the Con-derived one, and 0 means
-- "auto via Con" -- not "always fire" and not "never fire".
ah.config("gen 20")
set_herd(8)
act = ah.plan()
check("an explicit gen threshold above the herd's gen blocks the buy",
      act == nil or act.kind ~= "buy", act and act.cmd)
ah.config("gen auto")
act = ah.plan()
check("gen auto restores the Con-derived threshold and the buy returns",
      act ~= nil and act.kind == "buy", act and act.why)

-- The other two crossbreed triggers, each isolated: generation stays under
-- the threshold in all three cases below, so only sterility or age can be
-- responsible for a buy.
set_herd(0)
S.herds.sheepfold.sterile = 2
act = ah.plan()
check("a sterile head triggers a crossbreed with gen under the threshold",
      act ~= nil and act.kind == "buy", act and act.why)

set_herd(0)
S.herds.sheepfold.age_ticks = 50
act = ah.plan()
check("age alone does not trigger while age_refresh is 0 (off)",
      act == nil or act.kind ~= "buy", act and act.cmd)
ah.config("age 40")                       -- LEGACY's own default
act = ah.plan()
check("age at or over age_refresh triggers a crossbreed",
      act ~= nil and act.kind == "buy", act and act.why)
ah.config("age 0")

-- Restore the fixture the pending-delivery cases below expect.
set_herd(8)

-- ---- pending deliveries block a re-buy -------------------------------------
-- Added beyond the brief (LEGACY:131's whole purpose: "so the planner
-- doesn't keep re-buying while deliveries are on the road"). Deleting the
-- `+ pending_head(b)` from any branch is otherwise invisible -- no case in
-- the brief ever puts anything in S.lpending.
--
-- Crossbreed first, reusing the fixture above (gen 8 over the Con threshold
-- 7, cap 14, head 4): 10 head already in transit fills the building, so the
-- buy that fired a moment ago must not fire now.
S.lpending = { { bldg = "sheepfold", species = "sheep", breed = "nordic",
                 count = 10, secs = 300 } }
act = ah.plan()
check("crossbreed: deliveries in transit fill the cap -> no buy",
      act == nil or act.kind ~= "buy", act and act.cmd)
S.lpending = { { bldg = "byre", species = "cow", breed = "nordic",
                 count = 10, secs = 300 } }
act = ah.plan()
check("crossbreed: a delivery to a DIFFERENT building does not block it",
      act ~= nil and act.kind == "buy", act and act.why)

-- Restock next: an empty building whose breeding floor is already on the
-- road must not be stocked twice.
S.herds = {}
ah.config("gen auto")
S.lpending = { { bldg = "sheepfold", species = "sheep", breed = "nordic",
                 count = 4, secs = 300 } }
act = ah.plan()
check("restock: a delivery already covering the floor -> no buy",
      act == nil or act.kind ~= "buy", act and act.cmd)
S.lpending = {}
act = ah.plan()
check("restock: with nothing in transit the same state buys",
      act ~= nil and act.kind == "buy", act and act.why)

-- ---- the reserve is the only brake -----------------------------------------
-- Added beyond the brief. The brief's own "below reserve" case uses
-- daler = 100 against a 2000 reserve, which is so far under that dropping
-- the `- reserve` term entirely still leaves budget = 100 < the 400 price --
-- the case passes either way. These pin the actual boundary, since `reserve`
-- is documented in this module's header as the ONLY thing stopping the
-- planner spending every daler above it.
S.autoherd = nil
ah.settings()                             -- reserve back to its 2000 default
S.lpending = {}
S.herds = {}
S.buildings = { sheepfold = 2 }
S.lfeed = { grain = 0, water = 0, head = 0 }
S.wstock_by_good = { grain = { good = "grain", amount = 9999 } }
S.wstock = { { good = "grain", amount = 9999 } }
S.lmarket = {
  [1] = { { lin = 1, idx = 0, species = "sheep", breed = "nordic", count = 1,
            price = 400, hard = 30, fert = 40, yield = 50, vigor = 45,
            con = 35 } },
}
S.daler = 2399                            -- reserve 2000 -> budget 399 < 400
act = ah.plan()
check("one daler short of reserve + price -> no buy",
      act == nil or act.kind ~= "buy", act and act.cmd)
S.daler = 2400                            -- budget exactly 400
act = ah.plan()
check("reserve + price exactly -> the buy is allowed",
      act ~= nil and act.kind == "buy", act and act.why)

-- ---- the server's precondition is the lot total, i.e. the record's price ---
-- The record's `price` is ALREADY the lot total (livestock_daemon.c:310 stores
-- `price * count`, bulk discount included), and `buy_cmd` passes no count, so
-- do_buy buys the whole lot and charges exactly that figure.
--
-- This case exists because the line has been wrong in BOTH directions. It was
-- once `price * count`, which matched a server-side bug where do_buy's gate
-- read `total_cost = price * buy_count` -- an already-multiplied total times
-- the lot size. That bug is fixed (do_buy derives a per-head unit first), so
-- the gate is `price`.
--
-- Keep `count = 3` here: every other fixture uses count = 1, the one value
-- where price and price * count agree, which is exactly why gating on the
-- wrong figure once shipped green. The "covers it exactly" case below fails
-- if anyone reintroduces the multiply.
S.autoherd = nil
ah.settings()                             -- reserve back to its 2000 default
S.lpending = {}
S.herds = {}
S.buildings = { sheepfold = 2 }
S.lfeed = { grain = 0, water = 0, head = 0 }
S.wstock_by_good = { grain = { good = "grain", amount = 9999 } }
S.wstock = { { good = "grain", amount = 9999 } }
S.lmarket = {
  [1] = { { lin = 1, idx = 0, species = "sheep", breed = "nordic", count = 3,
            price = 400, hard = 30, fert = 40, yield = 50, vigor = 45,
            con = 35 } },
}
S.daler = 2399                            -- budget 399, one under the lot total
act = ah.plan()
check("one daler short of the lot total -> no buy",
      act == nil or act.kind ~= "buy", act and act.cmd)
S.daler = 2400                            -- budget exactly 400
act = ah.plan()
check("a 3-animal lot whose total the budget covers exactly -> buy allowed",
      act ~= nil and act.kind == "buy", act and act.why)
check("the note quotes the lot total, not the total times the lot size",
      act and act.why and act.why:find("400d", 1, true) ~= nil
        and act.why:find("1200d", 1, true) == nil, act and act.why)
S.daler = 100000

-- ---- quality buy-in: the margin, and its own cap check ---------------------
-- Added beyond the brief, which never exercises branch 4 at all. Crossbreed
-- and restock are both silenced here (cross off; head == the keep floor), so
-- any buy below can only be a quality buy-in. Goal is the default "yield"
-- (weights hard 1, fert 1, yield 4, vigor 1, con 2), so the herd below
-- scores 40 + 55 + 280 + 66 + 100 = 541 and the default margin of 5 puts the
-- acceptance floor at 546.
S.autoherd = nil
ah.settings()
ah.config("cross off")
S.daler = 100000
S.lpending = {}
S.buildings = { sheepfold = 2 }
S.lfeed = { grain = 0, water = 0, head = 4 }
S.herds = {
  sheepfold = { bldg = "sheepfold", head = 4, quality = 60, gen = 0,
                sterile = 0, hard = 40, fert = 55, yield = 70, vigor = 66,
                con = 50, breed = "nordic", hv = 0, age_ticks = 1 },
}
-- Scores 40 + 55 + 284 + 66 + 100 = 545, one under the floor.
S.lmarket = {
  [1] = { { lin = 1, idx = 0, species = "sheep", breed = "nordic", count = 1,
            price = 400, hard = 40, fert = 55, yield = 71, vigor = 66,
            con = 50 } },
}
act = ah.plan()
check("a listing one point under the quality margin -> no buy",
      act == nil or act.kind ~= "buy", act and act.cmd)
-- Scores 40 + 55 + 320 + 66 + 100 = 581, clear of the floor.
S.lmarket[1][1].yield = 80
act = ah.plan()
check("a listing clear of the quality margin -> a buy",
      act ~= nil and act.kind == "buy", act and act.why)
check("the quality buy uses the one command form",
      act and act.cmd == "vlivestock buy lodbrok 1", act and act.cmd)
-- The quality branch runs its own cap/pending check too.
S.lpending = { { bldg = "sheepfold", species = "sheep", breed = "nordic",
                 count = 10, secs = 300 } }
act = ah.plan()
check("quality buy: deliveries in transit fill the cap -> no buy",
      act == nil or act.kind ~= "buy", act and act.cmd)
S.lpending = {}

-- ---- quality eligibility is independent of trait rank and rounding --------
do
  local herd = S.herds.sheepfold
  local listing = S.lmarket[1][1]
  listing.trait = "bountiful"
  listing.yield = 60
  act = ah.plan()
  check("inferior trait lot cannot pass raw quality margin", act == nil)
  listing.yield = 71
  act = ah.plan()
  check("trait bonus cannot bridge raw margin", act == nil)
  listing.yield = 72 -- raw +8, but floor((70*4 + 72)/5) remains 70
  act, why = ah.plan()
  check("raw improvement lost to integer averaging is not bought", act == nil)
  check("no beneficial option reason is actionable",
        why and why:find("rounded stat gain", 1, true) ~= nil, why)
  listing.hard, listing.yield = 41, 71 -- raw +5 exactly, rounded gain still zero
    act = ah.plan()
    check("exact raw margin still needs a rounded gain", act == nil)
    listing.hard, listing.yield = 36, 72 -- raw +4 below margin, regardless of trait
    act = ah.plan()
    check("weighted tradeoff below margin is rejected", act == nil)
    listing.hard, listing.yield = 35, 73 -- raw +7, but hard falls and yield stays flat
    act = ah.plan()
    check("rounding each stat rejects a net herd loss despite raw gain", act == nil)
    listing.hard, listing.yield = 40, 72
    listing.count = 4 -- floor((70*4 + 72*4)/8) == 71
  act = ah.plan()
  check("larger lot with visible rounded improvement is bought", act and act.kind == "buy")
  listing.count = 20
  herd.head = 13 -- only one space: don't predict averaging all 20 animals
  act = ah.plan()
  check("quality prediction uses available pen space", act == nil)
  herd.head = 4
  listing.count, listing.yield = 1, 80
  local better = { lin = 1, idx = 1, species = "sheep", breed = "highland",
    count = 1, price = 400, hard = 40, fert = 55, yield = 90, vigor = 66, con = 50 }
  S.lmarket[1][2] = better
  act = ah.plan()
  check("traitless herd prefers eligible trait lot", act and act.idx == 0)
  herd.trait = "hardy"
  act = ah.plan()
  check("existing trait cannot be replaced so better raw lot wins", act and act.idx == 1)
  herd.trait = "bountiful"
  act = ah.plan()
  check("matching existing trait also gets no ranking bonus", act and act.idx == 1)
  herd.trait = nil
  S.lpending = { { bldg = "sheepfold", breed = "nordic", count = 1 } }
  act, why = ah.plan()
  check("quality waits for a small pending lot even with spare room", act == nil)
  check("pending wait reason", why and why:find("deliveries", 1, true) ~= nil, why)
  S.lpending = {}
  S.herds = {}
  listing.yield = 30
  act = ah.plan()
  check("empty restock retains trait preference", act and act.idx == 0)
  S.lpending = { { bldg = "sheepfold", breed = "nordic", count = 1 } }
  act = ah.plan()
  check("restock waits even when pending lot is below breeding floor", act == nil)
  S.lpending = {}
end

-- ---- crossbreed requires complete first-introduction history ---------------
do
  S.autoherd = nil
  local settings = ah.settings()
  settings.restock, settings.buy_quality, settings.age_refresh = false, false, 0
  set_herd(8)
  S.lmarket = { [1] = {
    { lin = 1, idx = 0, species = "sheep", breed = "highland", count = 1,
      price = 400, hard = 40, fert = 55, yield = 90, vigor = 66, con = 50 },
    { lin = 1, idx = 1, species = "sheep", breed = "island", count = 1,
      price = 400, hard = 40, fert = 55, yield = 80, vigor = 66, con = 50 },
  } }
  local herd = S.herds.sheepfold
  herd.breeds = { "nordic", "highland" }
  act = ah.plan()
  check("crossbreed excludes previously introduced non-primary breed", act and act.idx == 1)
  local fresh = S.lmarket[1][2]
  fresh.trait, fresh.yield = "bountiful", 60
  act, why = ah.plan()
  check("verified new blood with a trait cannot justify predicted stat loss", act == nil)
  check("crossbreed no-option reason explains no-loss gate",
        why and why:find("without rounded stat loss", 1, true) ~= nil, why)
  fresh.hard, fresh.yield = 35, 73 -- raw +7, rounded hard -1 and yield unchanged
  act = ah.plan()
  check("crossbreed rejects raw improvement that rounds to a herd loss", act == nil)
  fresh.hard, fresh.yield = 40, 70
  act = ah.plan()
  check("verified first cross permits identical stats with zero raw gain",
        act and act.idx == 1 and act.why:find("crossbreed", 1, true) ~= nil)
  fresh.yield = 72 -- raw +8, rounded score unchanged for this one-head lot
  act = ah.plan()
  check("verified first cross permits unchanged rounded score", act and act.idx == 1)
  fresh.trait, fresh.yield = nil, 80
  herd.breeds = { "nordic", "highland", "island" }
  act = ah.plan()
  check("all breeds already known means no hybrid purchase", act == nil)
  herd.breeds = nil
  for _, hv in ipairs({ 0, 3 }) do
    herd.hv = hv
    act = ah.plan()
    check("unknown breed history cannot prove novelty at hv=" .. hv, act == nil)
    settings.buy_quality = true
    act = ah.plan()
    check("unknown history falls back to quality at hv=" .. hv,
          act and act.why:find("quality buy", 1, true) ~= nil)
    settings.buy_quality = false
  end
  herd.breeds = { "nordic" }
  S.lpending = { { bldg = "sheepfold", breed = "highland", count = 1 } }
  act = ah.plan()
  check("small pending injection blocks repeated bloodline spend", act == nil)
  S.lpending = {}
  herd.head = 14
  act, why = ah.plan()
  check("full pens explicitly report no room", act == nil and why:find("pens full", 1, true) ~= nil, why)
  check("planning does not change purchase toggles or reserve",
        settings.restock == false and settings.buy_quality == false
          and settings.crossbreed == true and settings.reserve == 2000)
end

-- ---- three narrower guards -------------------------------------------------
-- All three added beyond the brief, each because deleting the line it covers
-- otherwise changes nothing observable (found by mutating this file's
-- planner, not by guessing -- see the task-4 report's mutant table).

-- (a) The building cap wins over an over-ambitious per-building target.
-- `head < desired AND head < cap` looks redundant, because `desired` is
-- min(cap, keep) when no target is set -- it is reachable only through an
-- explicit target above the cap, which is exactly the case that would
-- otherwise buy animals a building cannot house.
S.autoherd = nil
ah.settings()
S.daler = 100000
S.lpending = {}
S.buildings = { sheepfold = 2 }           -- cap 14
S.lfeed = { grain = 0, water = 0, head = 14 }
S.wstock_by_good = { grain = { good = "grain", amount = 9999 } }
S.wstock = { { good = "grain", amount = 9999 } }
S.lmarket = {
  [1] = { { lin = 1, idx = 0, species = "sheep", breed = "nordic", count = 1,
            price = 400, hard = 30, fert = 40, yield = 50, vigor = 45,
            con = 35 } },
}
S.herds = {
  sheepfold = { bldg = "sheepfold", head = 14, quality = 60, gen = 0,
                sterile = 0, hard = 40, fert = 55, yield = 70, vigor = 66,
                con = 50, breed = "nordic", hv = 0, age_ticks = 1 },
}
ah.config("bldg sheepfold target 20")     -- above the tier-2 cap of 14
act = ah.plan()
check("a per-building target above the cap does not buy past the cap",
      act == nil or act.kind ~= "buy", act and act.cmd)
ah.config("bldg sheepfold target 0")

-- (b) The feed draw is per-head-batch (ceil(head / 8)), not per head. With
-- 8 head and a 4-tick buffer the need is 4 grain, so 4 in the warehouse is
-- exactly enough and must NOT warn. (The market is emptied so no branch can
-- return a buy and mask the result.)
S.autoherd = nil
ah.settings()
S.daler = 100000
S.lpending = {}
S.lmarket = {}
S.lfeed = { grain = 0, water = 0, head = 8 }
S.wstock_by_good = { grain = { good = "grain", amount = 4 } }
S.wstock = { { good = "grain", amount = 4 } }
S.herds = {
  sheepfold = { bldg = "sheepfold", head = 8, quality = 60, gen = 0,
                sterile = 0, hard = 40, fert = 55, yield = 70, vigor = 66,
                con = 50, breed = "nordic", hv = 0, age_ticks = 1 },
}
act, why = ah.plan()
check("8 head with 4 grain and a 4-tick buffer does not warn",
      act == nil, act and act.why)
S.wstock_by_good = { grain = { good = "grain", amount = 3 } }
S.wstock = { { good = "grain", amount = 3 } }
act = ah.plan()
check("8 head with 3 grain does warn", act ~= nil and act.kind == "warn")
-- ...and once the server HAS sent its own per-tick figure, that figure wins
-- over the ceil(head / 8) fallback (it accounts for the fesetr feed-saving
-- skill and the per-building minimum, neither of which a client can see).
-- 5 grain/tick over a 4-tick buffer needs 20: 19 in the warehouse warns, 20
-- does not. Under the fallback the need would be 4 and both would go silent,
-- which is exactly the drift this shares its implementation with
-- pages/livestock.lua to prevent.
S.lfeed = { grain = 5, water = 5, head = 8 }
S.wstock_by_good = { grain = { good = "grain", amount = 19 } }
S.wstock = { { good = "grain", amount = 19 } }
act = ah.plan()
check("the server's per-tick figure drives the buffer (19 < 5 * 4)",
      act ~= nil and act.kind == "warn", act and act.why)
S.wstock_by_good = { grain = { good = "grain", amount = 20 } }
S.wstock = { { good = "grain", amount = 20 } }
act = ah.plan()
check("the server's per-tick figure drives the buffer (20 >= 5 * 4)",
      act == nil, act and act.why)

-- (c) A listing whose lineage id has no token yields no command at all,
-- rather than a half-built one. lin 99 is not in the server's lmap.
S.autoherd = nil
ah.settings()
S.daler = 100000
S.lpending = {}
S.herds = {}
S.lfeed = { grain = 0, water = 0, head = 0 }
S.wstock_by_good = { grain = { good = "grain", amount = 9999 } }
S.wstock = { { good = "grain", amount = 9999 } }
S.lmarket = {
  [99] = { { lin = 99, idx = 0, species = "sheep", breed = "nordic",
             count = 1, price = 400, hard = 30, fert = 40, yield = 50,
             vigor = 45, con = 35 } },
}
act = ah.plan()
check("an unknown lineage id produces no command",
      act == nil or act.kind ~= "buy", act and act.cmd)

-- ---- tick gate -------------------------------------------------------------
-- Added beyond the brief, deliberately. LEGACY's own gate (husbandry.lua:387)
-- is a bare `page_opts.auto_herd` read, which is PERMANENTLY nil here
-- (page_opts keeps its values in a private closure), so a literal port makes
-- M.tick() return early forever -- Auto-Herd would never run even with the
-- toggle on, and every planner case above would still pass. Nothing else in
-- this plan's tests would catch that, so both states are asserted here: with
-- the toggle off, many ticks over rich state must send nothing; with it on,
-- that same state must actually plan and send.
S.autoherd = nil
ah.settings()
S.daler = 100000
S.lpending = {}
S.herds = {}
S.buildings = { sheepfold = 2 }
S.lfeed = { grain = 0, water = 0, head = 0 }
S.wstock_by_good = { grain = { good = "grain", amount = 9999 } }
S.wstock = { { good = "grain", amount = 9999 } }
S.lmarket = {
  [1] = { { lin = 1, idx = 0, species = "sheep", breed = "nordic", count = 1,
            price = 400, hard = 30, fert = 40, yield = 50, vigor = 45,
            con = 35, trait = "0" } },
}

check("tick-gate setup: the master toggle is still off",
      page_opts.get("auto_herd") == false)
sent = {}
for _ = 1, 5 do ah.tick() end
check("tick with the master toggle OFF sends nothing", #sent == 0, #sent)

-- Not-connected gate, proven to block on its own before the toggle is
-- credited with anything.
mud_connected = false
page_opts.set("auto_herd", true)
ah.tick()
check("tick with the toggle on but not connected sends nothing", #sent == 0, #sent)
mud_connected = true

-- The Guild.Livestock arrival gate the spec's Corrections-to-LEGACY table
-- mandates ("Gate on `Guild.Livestock` having arrived", replacing LEGACY's
-- mip_livestock gate). Guild.City and Guild.Livestock are separate
-- slow-cadence panels in a round-robin, so City routinely lands first and the
-- S.buildings gate below is satisfied while every herd still reads empty --
-- the planner would then believe every building is empty and stock all five.
-- The fixture here is the one that buys three lines down, so only the gate can
-- account for the silence.
S.livestock_seen = false
ah.tick()
check("tick before Guild.Livestock has arrived sends nothing", #sent == 0, #sent)
check("tick before Guild.Livestock has arrived says why",
      (ah.settings().status or ""):find("livestock", 1, true) ~= nil,
      ah.settings().status)
S.livestock_seen = true

-- The reconnect settling hold. init.lua's M.on_connect sets S.at_hold_until
-- on every connect and state.reset_connection() deliberately PRESERVES guild
-- data, so S.herds/S.lmarket/S.buildings/S.daler all survive a disconnect and
-- the first tick after reconnect would otherwise plan against last session's
-- market pool -- at an index the server has since rebuilt, buying a different
-- animal than the one it scored. The fixture below is the same one that buys
-- two lines down, so only the hold can be responsible for the silence.
S.at_hold_until = os.time() + 60
ah.tick()
check("tick inside the reconnect settling hold sends nothing", #sent == 0, #sent)
check("tick inside the settling hold says why",
      (ah.settings().status or ""):find("settling", 1, true) ~= nil,
      ah.settings().status)
-- An ELAPSED hold (a real past timestamp, not nil) must not block anything:
-- the toggle-ON case immediately below runs with this set and is the
-- assertion that it does not.
S.at_hold_until = os.time() - 1

-- The toggle ON, all else unchanged: the planner must actually run and act.
ah.tick()
check("tick with the master toggle ON plans and sends exactly one command",
      #sent == 1, #sent)
check("tick sends the one command form the planner builds",
      sent[1] == "vlivestock buy lodbrok 1", sent[1])
check("tick never sends slaughter",
      sent[1] and sent[1]:find("slaughter", 1, true) == nil)

-- Flipping it back off must stop it again.
S.at_hold_until = nil
page_opts.set("auto_herd", false)
sent = {}
for _ = 1, 5 do ah.tick() end
check("flipping the master toggle back OFF stops sends", #sent == 0, #sent)

-- ---- the confirm-timeout retry loop ---------------------------------------
-- A buy the server refuses (already purchased, or -- before the lot-total fix
-- above -- unaffordable) changes NO state, so the phase machine waits out its
-- confirm timeout, cools down, replans, picks the same listing and repeats
-- forever. Nothing in the client ever noticed. The timeout transition now
-- evicts the attempted listing from S.lmarket and refuses to re-emit an
-- identical command on the next cycle.
S.autoherd = nil
ah.settings()
page_opts.set("auto_herd", true)
S.livestock_seen = true
S.at_hold_until = nil
mud_connected = true
S.daler = 100000
S.lpending = {}
S.herds = {}
S.buildings = { sheepfold = 2 }
S.lfeed = { grain = 0, water = 0, head = 0 }
S.wstock_by_good = { grain = { good = "grain", amount = 9999 } }
S.wstock = { { good = "grain", amount = 9999 } }
local function one_listing()
  return {
    [1] = { { lin = 1, idx = 0, species = "sheep", breed = "nordic",
              count = 1, price = 400, hard = 30, fert = 40, yield = 50,
              vigor = 45, con = 35 } },
  }
end
S.lmarket = one_listing()
sent = {}
ah.tick()
check("retry-loop setup: the first tick sends the buy", #sent == 1, #sent)

-- The server refused: no herd, no daler and no market change, so the state
-- signature is unchanged and the confirm deadline expires. os.time is stubbed
-- rather than slept on, the same idiom guild_viking_test.lua's hold-window
-- case uses.
local real_time = os.time
os.time = function() return real_time() + 100 end
ah.tick()
check("confirm timeout evicts the attempted listing from S.lmarket",
      #(S.lmarket[1] or {}) == 0, S.lmarket[1] and #S.lmarket[1])

sent = {}
os.time = function() return real_time() + 200 end
ah.tick()
check("after the eviction there is nothing left to re-buy", #sent == 0, sent[1])

-- Even when the server resends the identical listing, the refused command is
-- not repeated on the very next cycle -- that is what caps the loop for a
-- refusal the eviction cannot explain (an unaffordable lot, say).
S.lmarket = one_listing()
os.time = function() return real_time() + 300 end
ah.tick()
check("a re-arrived identical listing is not bought again immediately",
      #sent == 0, sent[1])

-- The refusal is one-shot, not a permanent blacklist: a listing that really
-- is back on the market must eventually be buyable again.
os.time = function() return real_time() + 400 end
ah.tick()
check("the refusal is one-shot, not a permanent blacklist", #sent == 1, #sent)
os.time = real_time
page_opts.set("auto_herd", false)

-- ---- the warn note is deduped on unchanged text ---------------------------
-- The status a warn carries (a grain shortfall, say) persists until the player
-- acts on it, and the note fired on every AH_INTERVAL cycle -- a red line
-- every 20 seconds, forever, which trains a player to ignore the colour.
-- LEGACY printed nothing here at all unless `debug`.
S.autoherd = nil
ah.settings()
page_opts.set("auto_herd", true)
S.livestock_seen = true
S.at_hold_until = nil
mud_connected = true
S.daler = 100000
S.lpending = {}
S.lmarket = {}                 -- nothing to buy, so only the warn can fire
S.buildings = { sheepfold = 2 }
S.herds = {
  sheepfold = { bldg = "sheepfold", head = 8, quality = 60, gen = 0,
                sterile = 0, hard = 40, fert = 55, yield = 70, vigor = 66,
                con = 50, breed = "nordic", hv = 0, age_ticks = 1 },
}
S.lfeed = { grain = 0, water = 0, head = 8 }
S.wstock_by_good = { grain = { good = "grain", amount = 0 } }
S.wstock = { { good = "grain", amount = 0 } }
local warn_base = os.time()
local warn_real_time = os.time
notes = {}
for i = 1, 6 do
  os.time = function() return warn_base + i * 25 end
  ah.tick()
end
check("an unchanged warn prints once, not once per cycle",
      count_notes("feed low") == 1, count_notes("feed low"))

-- A CHANGE in the shortfall is still worth a line.
S.wstock_by_good = { grain = { good = "grain", amount = 1 } }
S.wstock = { { good = "grain", amount = 1 } }
notes = {}
for i = 7, 9 do
  os.time = function() return warn_base + i * 25 end
  ah.tick()
end
check("a changed warn prints again, once",
      count_notes("feed low") == 1, count_notes("feed low"))
os.time = warn_real_time
page_opts.set("auto_herd", false)

-- Exercise the compact wire through the real writer, not hand-made planner state.
local writer = require("handlers.livestock")._gmcp
local fingerprint = string.rep("a", 32)
local function compact_fixture(head, cap, pending, gen, stat)
  S.autoherd = nil
  local cfg = ah.settings()
  cfg.feed_guard, cfg.restock, cfg.crossbreed = false, false, false
  cfg.goal, cfg.quality_margin = "balanced", 5
  S.buildings, S.lpending, S.daler = { stable = 1 }, {}, 2250
  writer.HERDS({ { bldg = "stable", head = head, breed = "nordic", breeds = "nordic",
    management = string.format("%d;%d;%d;%d;0;0;4050;%d;%s", cap, pending,
      cap - head - pending, head, gen, stat or "5000,5000,5000,5000,5000,5000") } })
  writer.LMARKET({ lmarket_1 = { { lin = 1, idx = 2, species = "horse", breed = "nordic",
    count = 8, available = 7, unit_price = 100, price = 800, token = fingerprint,
    hard = 51, fert = 51, yield = 51, vigor = 51, con = 51 } } }, true)
end
compact_fixture(98, 110, 0, 800)
act = ah.plan()
check("fractional quality gain buys exact reserve-limited protected count", act
  and act.cmd == "vlivestock buy lodbrok 3 2 " .. fingerprint, act and act.cmd)
check("exact partial cost respects reserve", act and act.why:find("200d", 1, true))
S.daler = 2100
act = ah.plan()
check("one hundredth gains accumulate despite whole-point truncation", act
  and act.cmd == "vlivestock buy lodbrok 3 1 " .. fingerprint)
S.daler = 2099
act = ah.plan()
check("reserve cannot afford even one protected horse", not act or act.kind ~= "buy")
compact_fixture(98, 99, 0, 800)
S.daler = 9999
act = ah.plan()
check("authoritative penfree limits count not tier cap", act
  and act.cmd == "vlivestock buy lodbrok 3 1 " .. fingerprint)
compact_fixture(98, 110, 1, 800)
act = ah.plan()
check("management pending pauses even without LPENDING", not act or act.kind ~= "buy")
compact_fixture(98, 98, 0, 800)
act = ah.plan()
check("full protected horse pen never buys or slaughters", not act or act.kind ~= "buy")
compact_fixture(98, 110, 0, 800)
S.lmarket[1][1].token = nil
act = ah.plan()
check("missing fingerprint never downgrades new offer", not act or act.kind ~= "buy")
compact_fixture(98, 110, 0, 800)
S.daler = 3000 -- the legacy whole lot is affordable, so only the schema guard blocks it
writer.LMARKET({ lmarket_1 = { { lin = 1, idx = 2, species = "horse", breed = "nordic",
  count = 8, price = 800, hard = 51, fert = 51, yield = 51, vigor = 51, con = 51 } } }, true)
check("budget-omitted offer has no optional metadata", not S.lmarket[1][1].metadata_present)
act = ah.plan()
check("management forbids legacy fallback when all offer metadata is omitted",
  not act or act.kind ~= "buy", act and act.cmd)
compact_fixture(0, 10, 0, 0)
ah.settings().restock, ah.settings().buy_quality = true, false
writer.HERDS({ { bldg = "stable", head = 0, breed = "", breeds = "",
  management = "10;0;10;0;0;0;0;0;0,0,0,0,0,0" } })
check("compact empty pen retains zero head and management", S.herds.stable.head == 0
  and S.herds.stable.management and S.herds.stable.management.free == 10)
check("compact empty breed string is known empty history",
  type(S.herds.stable.breeds) == "table" and #S.herds.stable.breeds == 0)
act = ah.plan()
check("compact empty pen stocks with reserve-limited count and token", act
  and act.kind == "buy" and act.cmd == "vlivestock buy lodbrok 3 2 " .. fingerprint,
  act and act.cmd)
check("compact empty pen stock uses exact partial cost", act and act.why:find("stock horse", 1, true)
  and act.why:find("200d", 1, true))
compact_fixture(98, 110, 0, 800)
S.herds.stable.management = nil
act = ah.plan()
check("malformed management blocks automation", not act or act.kind ~= "buy")
compact_fixture(98, 110, 0, 800)
S.herds = {}
ah.settings().restock = true
act = ah.plan()
check("omitted herd management cannot authorize protected stock", not act or act.kind ~= "buy")
compact_fixture(98, 110, 0, 800)
ah.settings().crossbreed, ah.settings().buy_quality = true, false
for _, stat in ipairs({ "hard", "fert", "yield", "vigor", "con" }) do S.lmarket[1][1][stat] = 50 end
act = ah.plan()
check("known breed qualifies for proportional generation relief", act and act.kind == "buy")
S.lmarket[1][1].hard = 49
act = ah.plan()
check("generation relief cannot excuse stat degradation", not act or act.kind ~= "buy")
compact_fixture(98, 110, 0, 800)
S.lmarket[1][1].quote = { accepted = 7, before_gen_x100 = 800,
  before_stats = S.herds.stable.management.stats, after_stats = { hard = 10000 } }
for _, stat in ipairs({ "hard", "fert", "yield", "vigor", "con" }) do S.lmarket[1][1][stat] = 50 end
act = ah.plan()
check("advisory quote cannot invent reserve-limited quality gains", not act or act.kind ~= "buy")
compact_fixture(1000, 1010, 0, 800)
act = ah.plan()
check("sub-hundredth truncated gain does not justify quality buy", not act or act.kind ~= "buy")
compact_fixture(98, 110, 0, 800)
ah.settings().quality_margin = 6
act = ah.plan()
check("fractional gain still requires raw margin", not act or act.kind ~= "buy")

-- Replacement integration uses the real planner/executor, not a proposed-action stub.
local replacement = require("herd_replace")
local persist = require("persist")
local original_save = persist.save
local replacement_now = real_time() + 10000
os.time = function() return replacement_now end
local saves, fail_save = 0, false
persist.save = function()
  saves = saves + 1
  if fail_save then error("test disk failure") end
end
local function replacement_fixture()
  package.loaded.autoherd = nil
  ah = require("autoherd")
  S.autoherd = nil
  local settings = ah.settings()
  settings.reserve, settings.feed_guard = 200, false
  S.buildings = { sheepfold = 1 }
  S.daler, S.livestock_seen, S.at_hold_until = 1000, true, nil
  S.herd_connection_epoch = 1
  S.herd_observed = {}
  for _, key in ipairs({ "herds", "pending", "bqueue", "daler", "prices" }) do
    S.herd_observed[key] = { at = replacement_now, seq = 1 }
  end
  S.herds = { sheepfold = { head = 20, _received_at = replacement_now,
    management = { cap = 20, pending = 0, free = 0, protected = 4, cullable = 16,
      auto_slaughter = 0, stats = { hard = 5000, fert = 5000, yield = 5000, vigor = 5000, con = 5000 } } } }
  S.lmarket = { [1] = { { lin = 1, idx = 0, species = "sheep", breed = "nordic",
    count = 5, available = 5, unit_price = 10, price = 50, token = string.rep("a", 32),
    hard = 90, fert = 90, yield = 90, vigor = 90, con = 90, _received_at = replacement_now } } }
  S.lpending, S.bqueue, S.bqueue_used, S.bqueue_max = {}, {}, 0, 4
  S.trade_goods = { [1] = { mutton = { sell = 100, demand = 100, _received_at = replacement_now },
    wool = { sell = 100, demand = 100, _received_at = replacement_now } } }
  page_opts.set("auto_herd", true)
  mud_connected, fail_save, sent, saves = true, false, {}, 0
  mud.send = function(cmd)
    check("replacement persisted before send", saves > 0 and replacement.busy(settings.replace)
      and settings.replace.daily.spent == 20)
    sent[#sent + 1] = cmd
    saves = 0
  end
  ah.config("model sheepfold output 1")
  ah.config("replace overhead 0")
  return settings.replace
end
do
  local original_trade, original_gmcp = package.loaded["handlers.trade"], gmcp
  local status, requests = {}, 0
  package.loaded["handlers.trade"] = { _tgoods_status = function() return status end }
  gmcp = { enabled = function() return true end, send = function() requests = requests + 1 end }
  local function diagnostic_case(name, receipt, stream, expected)
    replacement_fixture()
    S.herd_observed.prices = receipt and { at = receipt, seq = 1 } or nil
    status = stream
    status.connection_epoch = S.herd_connection_epoch
    local before_saves, before_notes = saves, #notes
    for _, command in ipairs({ "forecast", "replace preview" }) do ah.config(command) end
    local lines, matched = 0, 0
    for i = before_notes + 1, #notes do
      if notes[i]:find("price stream:", 1, true) then
        lines = lines + 1
        if notes[i] == "  price stream: " .. expected then matched = matched + 1 end
        check(name .. " bounded one line", #notes[i] < 240 and not notes[i]:find("\n", 1, true))
      end
    end
    check(name, lines == 2 and matched == 2)
    ah.replacement_preview()
    check(name .. " read only", saves == before_saves and #sent == 0 and requests == 0
      and status == stream and (not receipt or S.herd_observed.prices.at == receipt))
  end
  diagnostic_case("first grid progress", nil, { received = 3, expected = 12, complete = false, ever_complete = false },
    "3/12 lineages; waiting for first complete grid")
  diagnostic_case("unknown grid waits for cycle", nil, { received = 0, complete = false },
    "0/? lineages; waiting for first complete grid; waiting for server's next cycle (300s)")
  diagnostic_case("previous complete while receiving", replacement_now - 601,
    { received = 4, expected = 12, complete = false, ever_complete = true, last_complete_at = replacement_now - 601 },
    "last complete grid 601s ago; receiving 4/12")
  diagnostic_case("completed stale grid age", replacement_now - 900,
    { received = 12, expected = 12, complete = true, last_complete_at = replacement_now - 900 },
    "last complete grid 900s ago")
  diagnostic_case("reload retains observed proof", replacement_now - 700,
    { received = 2, expected = 12, complete = false, ever_complete = false },
    "last complete grid 700s ago; receiving 2/12")
  diagnostic_case("legacy observed proof", replacement_now - 800,
    { received = 0, complete = false, ever_complete = false },
    "last complete grid 800s ago; receiving 0/?; waiting for server's next cycle (300s)")
  package.loaded["handlers.trade"] = {}
  replacement_fixture()
  S.herd_observed.prices = nil
  check("trade stub without accessor does not crash", pcall(ah.config, "forecast"))
  package.loaded["handlers.trade"], gmcp = original_trade, original_gmcp
end

do
  local requests, enabled, mode = 0, true, "ok"
  gmcp = {
    enabled = function() return enabled end,
    send = function(pkg, data)
      requests = requests + 1
      check("refresh sends only Guild Add", pkg == "Core.Supports.Add" and #data == 1 and data[1] == "Guild 1")
      if mode == "throw" then error("sender failed") end
      return mode == "ok"
    end,
  }
  replacement_fixture()
  S.autoherd = nil
  local before_saves = saves
  local sender = gmcp.send
  gmcp.send = nil; ah.config("refresh")
  check("refresh missing sender", requests == 0)
  gmcp.send = sender
  enabled = false; ah.config("refresh")
  check("refresh GMCP disabled", requests == 0)
  enabled, mud_connected = true, false; ah.config("refresh")
  check("refresh disconnected", requests == 0)
  mud_connected, S.livestock_seen = true, false
  S.herds, S.lmarket, S.lpending, S.herd_observed = {}, {}, {}, {}
  check("automatic refresh requires current Viking evidence", ah.refresh(true) == false and requests == 0)
  local master = page_opts.get("auto_herd")
  ah.config("refresh")
  check("manual refresh bootstraps missing livestock after reload", requests == 1 and not S.livestock_seen
    and next(S.herds) == nil and next(S.lmarket) == nil and next(S.herd_observed) == nil)
  ah.config("refresh")
  check("refresh request is debounced and read-only", requests == 1 and S.autoherd == nil
    and saves == before_saves and #sent == 0 and page_opts.get("auto_herd") == master
    and next(S.herd_observed) == nil)
  replacement_now = replacement_now + 59; ah.config("refresh")
  check("refresh waits at least sixty seconds", requests == 1)
  replacement_now = replacement_now + 1; mode = "throw"
  check("refresh thrown sender caught", pcall(ah.config, "refresh"))
  ah.config("refresh")
  check("failed attempt also debounced", requests == 2)
  replacement_now = replacement_now + 60; mode = "false"
  check("refresh false sender rejected", ah.refresh() == false and requests == 3)
  mode = "ok"

  local opts = replacement_fixture()
  opts.enabled = true
  S.herd_observed.daler.at = replacement_now - 181
  local stale_at = S.herd_observed.daler.at
  before_saves = saves
  requests = 0
  ah.config("forecast"); ah.config("replace preview"); ah.replacement_preview()
  check("stale previews never refresh", requests == 0 and saves == before_saves)
  check("stale preview explains refresh and grid wait", count_notes("Use /vik herd refresh") > 0
    and count_notes("~5 minutes") > 0)
  ah.tick()
  check("authorized stale idle requests without spending or promoting receipt", requests == 1
    and #sent == 0 and saves == before_saves and S.herd_observed.daler.at == stale_at
    and replacement.status(opts).phase == "idle")
  replacement_now = replacement_now + 119; ah.tick()
  check("automatic refresh bounded to 120 seconds", requests == 1)
  replacement_now = replacement_now + 21; ah.tick()
  check("unchanged stale data can request again", requests == 2)
  -- Simulate a full receipt with unchanged values, as cache invalidation permits.
  replacement_now = replacement_now + 21
  for _, receipt in pairs(S.herd_observed) do receipt.at = replacement_now; receipt.seq = receipt.seq + 1 end
  S.herds.sheepfold._received_at = replacement_now
  S.lmarket[1][1]._received_at = replacement_now
  for _, row in pairs(S.trade_goods[1]) do row._received_at = replacement_now end
  ah.tick()
  check("actual fresh receipts recover replacement", #sent == 1 and replacement.busy(opts))
  replacement_now = replacement_now + 120; ah.tick()
  check("busy job never automatically refreshes", requests == 2)
  replacement.cancel(opts, "test halt"); ah.tick()
  check("halted job never automatically refreshes", requests == 2)
  local marker, enabled_before = opts.in_flight, opts.enabled
  before_saves = saves
  ah.config("refresh")
  check("manual refresh cannot reset a halt or authorize actions", opts.in_flight == marker
    and opts.enabled == enabled_before and saves == before_saves and #sent == 1)
  for _, gate in ipairs({ "master", "replacement", "pending", "queue", "settling" }) do
    opts = replacement_fixture(); opts.enabled = true
    S.herd_observed.daler.at = replacement_now - 181
    if gate == "master" then page_opts.set("auto_herd", false)
    elseif gate == "replacement" then opts.enabled = false
    elseif gate == "pending" then S.lpending = { { bldg = "sheepfold", count = 1 } }
    elseif gate == "queue" then S.bqueue_used = 1
    else S.at_hold_until = replacement_now + 60 end
    local before = requests
    ah.tick()
    check("automatic refresh blocked by " .. gate, requests == before and #sent == 0)
  end
  gmcp = nil
end
do
  local opts = replacement_fixture()
  opts.enabled = true
  S.herds.sheepfold.head = 19
  S.herds.sheepfold.management.free = 1
  S.herds.sheepfold.management.cullable = 15
  S.lmarket = {}
  local saved_before, notes_before = saves, count_notes("sheepfold: pen not full: head 19/cap 20")
  local plan, reason, details = ah.replacement_preview()
  check("preview API forwards bounded rejection details", not plan and reason == "no eligible modeled replacement under current limits"
    and #details == 1 and details[1].building == "sheepfold")
  check("API diagnostics are silent", count_notes("sheepfold: pen not full: head 19/cap 20") == notes_before)
  ah.config("forecast"); ah.config("replace preview")
  check("both explicit CLI previews print actual pen gate", count_notes("sheepfold: pen not full: head 19/cap 20") == notes_before + 2)
  check("rejected CLI preview neither sends nor saves", saves == saved_before and #sent == 0
    and opts.enabled and not replacement.busy(opts) and opts.daily == nil)
  notes_before = count_notes("sheepfold: pen not full: head 19/cap 20")
  ah.tick()
  check("idle tick does not print preview rejection details", count_notes("sheepfold: pen not full: head 19/cap 20") == notes_before)
end
-- Feed gates only the start of replacement, before any reservation or marker.
do
  local function stock(n)
    S.wstock_by_good = { grain = { good = "grain", amount = n } }
    S.wstock = { { good = "grain", amount = n } }
  end
  local function copy(t)
    if type(t) ~= "table" then return t end
    local r = {}; for k, v in pairs(t) do r[k] = copy(v) end; return r
  end
  local function equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not equal(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
  end
  local opts = replacement_fixture()
  opts.enabled, opts.cooldown = true, 0
  local settings = ah.settings()
  settings.feed_guard, settings.feed_ticks = true, 4
  S.lfeed = { grain = 33, water = 0, head = 20 }
  stock(107)
  local ordinary = ah.plan()
  check("feed 107/33 with 132 buffer warns in ordinary planner", ordinary and ordinary.kind == "warn"
    and ordinary.why == "feed low: 107 grain, herds need 33/tick (132 buffer) - stock grain!")
  local saved_before, notes_before = saves, #notes
  local before = copy({ settings = S.autoherd, herds = S.herds, feed = S.lfeed, stock = S.wstock_by_good })
  local plan, reason, details, feed = ah.replacement_preview()
  check("feed preview preserves useful candidate and adds separate warning", plan and reason == "ready" and #details == 0
    and feed == ordinary.why and #notes == notes_before)
  ah.config("forecast"); ah.config("replace preview")
  check("explicit previews show candidate and execution feed blocker", count_notes("new replacement execution blocked:") == 2
    and count_notes("preview ONLY:") >= 2)
  check("feed preview is read-only", equal(before, { settings = S.autoherd, herds = S.herds, feed = S.lfeed, stock = S.wstock_by_good })
    and saves == saved_before and #sent == 0)
  S.herds.sheepfold.management.auto_slaughter = 1
  local rejected, _, rejected_details, rejected_feed = ah.replacement_preview()
  ah.config("forecast")
  check("feed context does not hide candidate rejection details", not rejected and #rejected_details == 1
    and rejected_details[1].reason:find("auto_slaughter", 1, true) and rejected_feed == ordinary.why
    and count_notes("sheepfold: server auto_slaughter") > 0)
  S.herds.sheepfold.management.auto_slaughter = 0
  notes_before = count_notes("feed low:")
  for i = 1, 3 do
    ah.tick()
    replacement_now = replacement_now + ah.AH_INTERVAL
  end
  check("low feed never sends or reserves new replacement", #sent == 0 and opts.daily == nil
    and opts.in_flight == nil and saves == saved_before and opts.enabled)
  check("replacement shortage reuses ordinary warning dedupe", count_notes("feed low:") == notes_before + 1)
  stock(108); ah.tick()
  check("changed feed shortage warns once", count_notes("feed low:") == notes_before + 2 and #sent == 0)
  stock(132); ah.tick()
  check("feed recovery preserves planning interval throttle", #sent == 0)
  replacement_now = replacement_now + ah.AH_INTERVAL
  ah.tick()
  check("exact 132 buffer permits one persisted cull", #sent == 1
    and sent[1] == "vlivestock slaughter sheepfold 2 worst" and replacement.busy(opts)
    and opts.daily.spent == 20 and opts.daily.culled == 2)

  stock(107)
  ah.tick()
  check("low feed waiting cull neither halts nor repeats", #sent == 1 and replacement.status(opts).phase == "await_cull")
  replacement_now = replacement_now + 1
  S.herds.sheepfold.head, S.herds.sheepfold.management.free = 18, 2
  S.herds.sheepfold.management.cullable = 14
  S.herds.sheepfold._received_at = replacement_now
  S.herd_observed.herds = { at = replacement_now, seq = 2 }
  S.bqueue, S.bqueue_used = { { slot = 1, species = "sheep", meat = "mutton", qty = 24 } }, 1
  S.herd_observed.bqueue = { at = replacement_now, seq = 2 }
  ah.tick()
  check("low feed permits confirmed cull guarded buy", #sent == 2
    and sent[2] == "vlivestock buy lodbrok 1 2 " .. string.rep("a", 32)
    and replacement.status(opts).phase == "await_pending")
  S.lpending = { { bldg = "sheepfold", breed = "nordic", species = "sheep", count = 2, secs = 10800 } }
  S.herd_observed.pending = { at = replacement_now, seq = 2 }
  ah.tick()
  check("low feed permits pending confirmation without commands", #sent == 2 and replacement.status(opts).phase == "await_delivery")
  S.lpending = {}
  S.herd_observed.pending = { at = replacement_now, seq = 3 }
  S.herd_observed.herds = { at = replacement_now, seq = 3 }
  S.herds.sheepfold.head, S.herds.sheepfold.management.free = 20, 0
  S.herds.sheepfold.management.cullable = 16
  ah.tick()
  check("low feed permits delivery confirmation", #sent == 2 and replacement.status(opts).phase == "cooldown")
  ah.tick()
  check("low feed permits cooldown completion without another cull", #sent == 2 and not replacement.busy(opts))
  check("completed herd still has a viable candidate", ah.replacement_preview() ~= nil)
  ah.tick()
  check("low feed gates next job after completion", #sent == 2 and not replacement.busy(opts)
    and opts.daily.spent == 20 and opts.daily.culled == 2)

  opts = replacement_fixture(); opts.enabled = true
  settings = ah.settings(); settings.feed_guard, settings.feed_ticks = false, 7
  stock(0)
  local _, _, _, off_warning = ah.replacement_preview()
  ah.tick()
  check("explicit feed off permits replacement without changing settings", #sent == 1
    and not settings.feed_guard and settings.feed_ticks == 7 and off_warning == nil)

  opts = replacement_fixture(); opts.enabled = true
  settings = ah.settings(); settings.feed_guard, settings.feed_ticks = true, 5
  stock(132); ah.tick()
  check("replacement respects custom feed_ticks", #sent == 0 and opts.daily == nil and settings.feed_ticks == 5
    and settings.status:find("165 buffer", 1, true))
  stock(165); replacement_now = replacement_now + ah.AH_INTERVAL; ah.tick()
  check("custom feed buffer equality allows replacement", #sent == 1 and settings.feed_ticks == 5)

  opts = replacement_fixture(); opts.enabled = true
  settings = ah.settings(); settings.feed_guard, settings.feed_ticks = true, 0
  stock(32); ah.tick()
  check("replacement shares minimum one feed tick", #sent == 0 and settings.feed_ticks == 0)
  stock(33); replacement_now = replacement_now + ah.AH_INTERVAL; ah.tick()
  check("minimum feed tick equality allows without rewriting zero", #sent == 1 and settings.feed_ticks == 0)

  opts = replacement_fixture(); opts.enabled = true
  settings = ah.settings(); settings.feed_guard = true
  S.lfeed = { grain = 0, water = 0, head = 0 }
  stock(11); ah.tick()
  check("replacement shares owned head fallback ceil20over8 times4", #sent == 0
    and settings.status:find("3/tick (12 buffer)", 1, true))
  stock(12); S.wstock_by_good = {}
  replacement_now = replacement_now + ah.AH_INTERVAL; ah.tick()
  check("replacement shares warehouse array fallback", #sent == 1)
end
local ro = replacement_fixture()
local saved_settings = S.autoherd
S.autoherd = nil
local pure_saves = saves
ah.config("forecast"); ah.config("replace preview"); ah.replacement_preview()
check("forecast before settings initialization is read-only", S.autoherd == nil and saves == pure_saves and #sent == 0)
S.autoherd = saved_settings
local manual_models, manual_overhead = ro.models, ro.overhead
ro.models, ro.overhead, ro.enabled = {}, nil, true
S.production = { wool = 1 }
S.herd_observed.production = { at = replacement_now, seq = 1 }
local observed_preview = ah.replacement_preview()
check("context derives fresh production without missing-model setup", observed_preview
  and observed_preview.forecast_input.production_per_tick == 1
  and observed_preview.forecast_input.scaled_share == nil)
ah.config("forecast")
ah.tick()
check("saved enabled with preview still lacks execution acknowledgement", #sent == 0
  and ro.overhead == nil and next(ro.models) == nil)
S.herd_observed.production = nil
S.herd_connection_epoch = 2
check("reset production receipt rejects cached output", ah.replacement_preview() == nil)
ro.models, ro.overhead, ro.enabled = manual_models, manual_overhead, false
S.herd_connection_epoch = 1
check("replacement defaults safe off", ro.enabled == false and ro.models.sheepfold.production_per_tick == 1)
for _, toggles in ipairs({ { false, false }, { true, false }, { false, true } }) do
  page_opts.set("auto_herd", toggles[1])
  ro.enabled = toggles[2]
  local saved_before, notes_before = saves, count_notes("preview ONLY:")
  local daily_before = ro.daily
  local preview = ah.replacement_preview()
  ah.config("forecast"); ah.config("replace preview")
  check("preview works with master=" .. tostring(toggles[1]) .. " replace=" .. tostring(toggles[2]),
    preview and preview.cost == 20 and preview.forecast.net_low == 80
      and count_notes("preview ONLY:") == notes_before + 2)
  check("preview preserves toggles and state without saves or sends",
    page_opts.get("auto_herd") == toggles[1] and ro.enabled == toggles[2]
      and ah.settings().replace == ro and ro.daily == daily_before
      and not replacement.busy(ro) and saves == saved_before and #sent == 0)
  ah.tick()
  check("preview never authorizes a later cull", #sent == 0)
end
page_opts.set("auto_herd", true)
ah.config("forecast"); ah.config("replace on"); ah.config("replace preview"); ah.config("replace status")
check("configuration and preview send nothing", #sent == 0 and not replacement.busy(ro))
local proposal = ah.replacement_preview()
check("real replacement preview has cost and profit", proposal and proposal.cost == 20 and proposal.forecast.net_low == 80)
check("replacement context preserves raw records", ah.replacement_context().herds == S.herds
  and ah.replacement_context().observed == S.herd_observed)
S.trade_goods[1].wool = { sell = 100, demand = 100 }
check("replacement quote cannot inherit old timestamp", ah.replacement_context().prices.wool.at == nil
  and ah.replacement_preview() == nil)
S.trade_goods[1].wool._received_at = replacement_now - 181
ah.tick()
check("stale selected price sends nothing", #sent == 0)
ro = replacement_fixture(); ah.config("replace on")
page_opts.set("auto_herd", false); ah.tick()
check("master off sends nothing", #sent == 0)
page_opts.set("auto_herd", true); ah.tick()
check("real replacement starts one cull", #sent == 1 and sent[1] == "vlivestock slaughter sheepfold 2 worst")
check("settings retains job identity", ah.settings().replace == ro and replacement.status(ro).phase == "await_cull")
ah.tick()
check("waiting replacement never repeats", #sent == 1)
ah.config("replace reset")
check("active reset rejected", replacement.busy(ro))
replacement_now = replacement_now + 1
S.herds.sheepfold.head = 18
S.herds.sheepfold.management.free = 2
S.herds.sheepfold.management.cullable = 14
S.herds.sheepfold._received_at = replacement_now
S.herd_observed.herds = { at = replacement_now, seq = 2 }
S.bqueue, S.bqueue_used = { { slot = 1, species = "sheep", meat = "mutton", qty = 24 } }, 1
S.herd_observed.bqueue = { at = replacement_now, seq = 2 }
ah.tick()
check("confirmed cull sends guarded buy", #sent == 2 and sent[2] == "vlivestock buy lodbrok 1 2 " .. string.rep("a", 32))
S.lpending = { { bldg = "sheepfold", breed = "nordic", species = "sheep", count = 2, secs = 10800 } }
S.herd_observed.pending = { at = replacement_now, seq = 2 }
ah.tick()
check("pending receipt persists delivery phase without send", replacement.status(ro).phase == "await_delivery" and #sent == 2)
S.lpending = {}
S.herd_observed.pending = { at = replacement_now, seq = 3 }
S.herd_observed.herds = { at = replacement_now, seq = 3 }
S.herds.sheepfold.head, S.herds.sheepfold.management.free = 20, 0
S.herds.sheepfold.management.cullable = 16
ah.tick()
check("delivery receipt enters cooldown without sends", replacement.status(ro).phase == "cooldown" and #sent == 2)
page_opts.set("auto_herd", false); ah.tick()
check("master off retains persisted halt", replacement.status(ro).phase == "halted" and saves > 0)
page_opts.set("auto_herd", true); replacement_now = replacement_now + 1000; ah.tick()
check("halt blocks all normal autoherd", #sent == 2)
ah.config("replace reset")
check("explicit reset disables and retains budget", not replacement.busy(ro) and not ro.enabled and ro.daily.spent == 20)
ro = replacement_fixture(); ah.config("replace on"); ah.tick()
mud_connected = false; ah.tick()
check("disconnect halts before early return", replacement.status(ro).phase == "halted" and #sent == 1 and saves > 0)
ro = replacement_fixture(); ah.config("replace on")
mud.send = function() error("test send failure") end
check("send exception halts without crash", pcall(ah.tick) and replacement.status(ro).phase == "halted")
ro = replacement_fixture(); ah.config("replace on"); fail_save = true
local tick_ok = pcall(ah.tick)
check("persistence exception fails closed without crash or send", tick_ok and #sent == 0 and replacement.status(ro).phase == "halted")
fail_save = false; replacement_now = replacement_now + 1000; ah.tick()
check("persistence failure stays blocked", #sent == 0)
ro = replacement_fixture(); ah.config("replace on")
persist.save = function() return false, "disk full" end
check("false save result fails closed", pcall(ah.tick) and #sent == 0 and replacement.status(ro).phase == "halted")
persist.save = function() saves = saves + 1 end
ro = replacement_fixture(); ah.config("replace on"); ah.tick()
S.herds.sheepfold.head, S.herds.sheepfold.management.free = 18, 2
S.herds.sheepfold.management.cullable = 14
S.herd_observed.herds.seq, S.herd_observed.bqueue.seq = 2, 2
S.bqueue, S.bqueue_used = { { slot = 1, species = "sheep", meat = "mutton", qty = 24 } }, 1
persist.save = function() return nil, "disk full" end
check("buy marker save error blocks guarded buy", pcall(ah.tick) and #sent == 1
  and replacement.status(ro).phase == "halted")
persist.save = function() saves = saves + 1 end
ah.tick()
check("recovered persistence never retries blocked buy", #sent == 1)

ro = replacement_fixture()
local halt_snapshot, attempts = nil, 0
persist.save = function()
  attempts = attempts + 1
  if attempts == 1 then error("transient configuration save failure") end
  halt_snapshot = ah.snapshot()
end
ah.config("replace overhead 1")
check("idle save failure creates durable halt", #sent == 0 and attempts == 2
  and halt_snapshot.autoherd.replace.in_flight.phase == "halted"
  and replacement.status(ro).phase == "halted")
-- Make ordinary restocking viable so the halt, rather than a full pen, blocks it.
S.herds = {}
mud.send = function(cmd) sent[#sent + 1] = cmd end
check("ordinary buy is viable during persistence halt", ah.plan() ~= nil and ah.plan().kind == "buy")
persist.save = function() saves = saves + 1 end
ah.tick(); ah.config("replace on"); ah.tick()
check("idle save failure blocks ordinary sends and reenable", #sent == 0 and not ro.enabled)
ah.restore(halt_snapshot); ah.tick()
check("persisted idle halt blocks sends after restore", #sent == 0
  and replacement.status(ah.settings().replace).phase == "halted")
persist.save = function() return false, "reset save failure" end
ah.config("replace reset"); ah.tick()
check("failed reset save stays halted", #sent == 0
  and replacement.status(ah.settings().replace).phase == "halted")
persist.save = function() saves = saves + 1 end
ah.config("replace reset"); ah.tick()
check("successful explicit reset permits ordinary buys", #sent == 1
  and not ah.settings().replace.enabled)
ro = replacement_fixture()
ah.restore({ autoherd = { replace = { enabled = true, in_flight = { phase = "await_pending" } } } })
check("restored in-flight becomes halted and saved once", replacement.status(ah.settings().replace).phase == "halted" and saves > 0)
local saved_count = saves
ah.settings(); ah.settings()
check("recovery does not resave on each settings read", saves == saved_count)
ro = replacement_fixture()
ah.config("replace minprofit -12.5"); ah.config("model sheepfold share 0.25")
ah.config("replace horizon 10"); ah.config("replace gap 2")
check("signed profit and fractional share accepted", ro.min_profit == -12.5 and ro.models.sheepfold.scaled_share == 0.25)
ah.config("replace maxcost 1e309"); ah.config("replace gap 11"); ah.config("model sheepfold share 2")
check("invalid finite bounds rejected", ro.max_cost == 500 and ro.gap_ticks == 2 and ro.models.sheepfold.scaled_share == 0.25)
-- Exercise the real persistence wrapper: native store failures are booleans,
-- not the exceptions/return values injected into persist.save above.
persist.save = original_save
do
  local original_set, original_store_save = store.set, store.save
  for _, succeeds in ipairs({ true, "legacy nil" }) do
    local set_calls, save_calls = 0, 0
    store.set = function(data)
      set_calls = set_calls + 1
      stored = data
      if succeeds == true then return true end
    end
    store.save = function()
      save_calls = save_calls + 1
      if succeeds == true then return true end
    end
    local ok, result = pcall(persist.save)
    check("real persist accepts " .. tostring(succeeds) .. " storage success and returns nil",
      ok and result == nil and set_calls == 1 and save_calls == 1)
    ro = replacement_fixture(); ah.config("replace on")
    mud.send = function(cmd) sent[#sent + 1] = cmd end
    ah.tick()
    check("real persist permits cull after " .. tostring(succeeds) .. " storage success",
      #sent == 1 and sent[1] == "vlivestock slaughter sheepfold 2 worst")
  end
  for _, failed_operation in ipairs({ "set", "save" }) do
    store.set, store.save = original_set, original_store_save
    ro = replacement_fixture(); ah.config("replace on")
    check("real persist failure fixture has viable replacement: " .. failed_operation,
      ah.replacement_preview() ~= nil)
    local set_calls, save_calls = 0, 0
    store.set = function(data)
      set_calls = set_calls + 1
      if failed_operation == "set" then return false end
      stored = data
      return true
    end
    store.save = function()
      save_calls = save_calls + 1
      return false
    end
    local ok, err = pcall(persist.save)
    check("real persist throws descriptive store." .. failed_operation .. " failure",
      not ok and tostring(err):find("store." .. failed_operation .. " failed", 1, true))
    set_calls, save_calls = 0, 0
    mud.send = function(cmd) sent[#sent + 1] = cmd end
    check("real store." .. failed_operation .. " false halts with zero sends",
      pcall(ah.tick) and #sent == 0 and replacement.status(ro).phase == "halted"
        and ah.settings().status:find("store." .. failed_operation .. " failed", 1, true))
    check("real store." .. failed_operation .. " failure attempts best-effort halt save",
      set_calls == 2 and save_calls == (failed_operation == "set" and 0 or 2))
    store.set, store.save = original_set, original_store_save
    replacement_now = replacement_now + 1000
    ah.tick()
    check("real store." .. failed_operation .. " recovery never resumes sends without reset",
      #sent == 0 and replacement.status(ro).phase == "halted")
  end
  store.set, store.save = original_set, original_store_save
end
persist.save, os.time = original_save, real_time

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("all autoherd cases passed")
