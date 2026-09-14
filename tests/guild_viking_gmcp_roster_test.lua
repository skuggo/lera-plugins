-- guild_viking Guild.Roster writers unit tests. Run from the lera-plugins
-- repo root with LERA_ROOT pointing at a built Lera checkout.
--
-- Expected values are written out literally rather than derived by calling the
-- decoder, and each names the state field its consumer reads. The renames are
-- asserted individually: a swapped pair of same-typed fields is precisely what
-- a transport-equivalence assertion cannot see.
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
buffer = { color_print = function() end }

local protocol = require("protocol")
-- init.lua's RESERVED set: the module-level convention fields, not MIP keys.
local RESERVED_KEYS = { _market_seam = true, _patterns = true, _gmcp = true,
                        _retired_keys = true, _retired_patterns = true }
local S = require("state").S

local RESERVED = RESERVED_KEYS
for _, name in ipairs({ "handlers.trade", "handlers.kingdom", "handlers.voyage",
                        "handlers.city" }) do
  local mod = require(name)
  for key, fn in pairs(mod._gmcp or {}) do
    protocol.gmcp_handler(key, fn)
  end
end

local function roster(payload)
  payload.guild = "viking"
  protocol.on_gmcp("Guild.Roster", payload)
end

-- ---- staff -----------------------------------------------------------------
-- `stats` is a comma-joined string in a fixed order on both transports; the
-- server builds exactly one such string and MIP embeds it, so the parse is the
-- same. The order is combat,trade,craft,sea,wild,land,charm.
roster({ staff = {
  { id = 3, name = "Ingrid", assigned = "smithy", stat = "craft",
    stats = "10,20,30,40,50,60,70", trait = "diligent", loyalty = 5,
    age = "young", arrive = 1234, best_stat = "charm" },
} })
local st = S.staff_list[1]
check("staff count", #S.staff_list == 1, #S.staff_list)
-- Three renames, each asserted on its own.
check("staff assigned lands on assigned_to", st.assigned_to == "smithy", st.assigned_to)
check("staff stat lands on stat_key", st.stat_key == "craft", st.stat_key)
check("staff arrive lands on arrive_at", st.arrive_at == 1234, st.arrive_at)
check("staff scalar fields", st.name == "Ingrid" and st.trait == "diligent"
      and st.loyalty == 5 and st.age == "young")
-- The stat string is positional, so a decoder that mapped it to the wrong
-- names would still produce seven numbers. Each is named here.
check("staff stats map to their names in order",
      st.stats.combat == 10 and st.stats.trade == 20 and st.stats.craft == 30
      and st.stats.sea == 40 and st.stats.wild == 50 and st.stats.land == 60
      and st.stats.charm == 70)
roster({ staff = { { name = "Bare" } } })
check("staff defaults match the MIP handler's",
      S.staff_list[1].assigned_to == "0" and S.staff_list[1].stat_key == ""
      and S.staff_list[1].trait == "0" and S.staff_list[1].loyalty == 3
      and S.staff_list[1].age == "veteran" and S.staff_list[1].arrive_at == 0)
local many = {}
for i = 1, 60 do many[i] = { name = "S" .. i } end
roster({ staff = many })
check("staff cap at 50", #S.staff_list == 50, #S.staff_list)

-- ---- bonds -----------------------------------------------------------------
roster({ bonds = { { a = 3, b = 7, ticks = 12, tier = 2 } } })
check("bonds a/b land on id_a/id_b", S.bonds_list[1].id_a == 3
      and S.bonds_list[1].id_b == 7 and S.bonds_list[1].ticks == 12
      and S.bonds_list[1].tier == 2)

-- ---- train -----------------------------------------------------------------
roster({ train = { tier = 2, name = "Ingrid", stat = "combat", trained = 3, secs = 60 } })
check("train fields", S.train.tier == 2 and S.train.name == "Ingrid"
      and S.train.stat == "combat" and S.train.trained == 3 and S.train.secs == 60)

-- ---- courier + courier_tier ------------------------------------------------
-- MIP packed the tier and the run list into one '!'-separated value; GMCP
-- sends the tier as its own key.
roster({
  courier_tier = 3,
  courier = { { good = "timber", village = "Havn", secs = 120, amount = 40,
                cost = 10, fee = 5 } },
})
check("courier tier arrives from its own key", S.courier.tier == 3)
check("courier run secs lands on return_in", S.courier.runs[1].return_in == 120)
check("courier run fields", S.courier.runs[1].good == "timber"
      and S.courier.runs[1].village == "Havn" and S.courier.runs[1].amount == 40
      and S.courier.runs[1].cost == 10 and S.courier.runs[1].fee == 5)
-- The two halves are independent keys over a delta transport: a tier change
-- alone must not clear the runs.
roster({ courier_tier = 4 })
check("a tier-only courier delta leaves the runs standing",
      S.courier.tier == 4 and #S.courier.runs == 1)

-- ---- spy + spy_scouts ------------------------------------------------------
roster({
  spy = { tier = 2, mode = "watch", village = "Uppsala", secs = 90,
          sabpct = 35, sabsecs = 45, cdsecs = 300, sablin = 7 },
  spy_scouts = { { name = "Jorvik", amb = 2, secs = 30 } },
})
check("spy scalar fields", S.spy.tier == 2 and S.spy.mode == "watch"
      and S.spy.village == "Uppsala" and S.spy.secs == 90)
-- Three renames that all carry integers, so only naming them individually can
-- catch a swap.
check("spy sabpct lands on sab_pct", S.spy.sab_pct == 35, S.spy.sab_pct)
check("spy sabsecs lands on sab_secs", S.spy.sab_secs == 45, S.spy.sab_secs)
check("spy cdsecs lands on cd_secs", S.spy.cd_secs == 300, S.spy.cd_secs)
-- The scout record's field is `name`; the client has always called it `city`.
check("a scout's name lands on city", S.spy.scouts[1].city == "Jorvik"
      and S.spy.scouts[1].amb == 2 and S.spy.scouts[1].secs == 30)
roster({ spy = { tier = 3, mode = "sabotage" } })
check("a spy-only delta leaves the scouts standing",
      S.spy.tier == 3 and #S.spy.scouts == 1)

-- ---- vfind (four keys) -----------------------------------------------------
roster({
  vfind_hall = { tier = 2, max_finds = 4 },
  vfind_posts = { { id = 1, stat = "sea", min_skill = 30, max_wage = 50,
                    trait = "bold", state = "open" } },
  vfind_offers = { { id = 5, name = "Sven", wage = 40, haggles = 1, secs = 600,
                     stat = "sea", trait = "bold", age = "young", post_id = 1,
                     upkeep = 3 } },
  vfind_auctions = { { id = 9, name = "Astrid", reserve = 100, my_bid = 120,
                       secs = 900, stat = "trade", skill = 55, trait = "shrewd",
                       age = "veteran", part = 2 } },
})
check("vfind hall tier", S.vfind.tier == 2)
check("vfind posting fields", S.vfind.postings[1].id == 1
      and S.vfind.postings[1].stat == "sea" and S.vfind.postings[1].min_skill == 30
      and S.vfind.postings[1].max_wage == 50 and S.vfind.postings[1].trait == "bold"
      and S.vfind.postings[1].state == "open")
-- `secs` becomes expires_in on an offer but closes_in on an auction. Same
-- source field name, two different destinations, so both are pinned.
check("an offer's secs lands on expires_in", S.vfind.offers[1].expires_in == 600
      and S.vfind.offers[1].name == "Sven" and S.vfind.offers[1].wage == 40
      and S.vfind.offers[1].haggles == 1)
check("an auction's secs lands on closes_in", S.vfind.auctions[1].closes_in == 900
      and S.vfind.auctions[1].name == "Astrid"
      and S.vfind.auctions[1].reserve == 100 and S.vfind.auctions[1].my_bid == 120)
-- The server sends the three lists only when the hall exists, so a
-- hall-carrying delta with no lists must not empty them.
roster({ vfind_hall = { tier = 3 } })
check("a hall-only vfind delta leaves the lists standing",
      S.vfind.tier == 3 and #S.vfind.postings == 1 and #S.vfind.offers == 1
      and #S.vfind.auctions == 1)

-- ---- hird ------------------------------------------------------------------
roster({ hird = {
  { id = 11, name = "Bjorn", status = "ready", level = 4, atk = 12, def = 9,
    loyalty = 5, hired = 900, age = "prime", mode = "offensive", champ = 1,
    wpn = 2, arm = 3 },
  { id = 12, name = "Gunnar", mode = "lounging" },
} })
check("hird count", #S.hird_list == 2, #S.hird_list)
check("hird hired lands on hired_at", S.hird_list[1].hired_at == 900)
check("hird age lands on age_phase", S.hird_list[1].age_phase == "prime")
check("hird scalar fields", S.hird_list[1].name == "Bjorn"
      and S.hird_list[1].status == "ready" and S.hird_list[1].level == 4
      and S.hird_list[1].atk == 12 and S.hird_list[1].def == 9
      and S.hird_list[1].champ == 1 and S.hird_list[1].wpn == 2
      and S.hird_list[1].arm == 3)
-- MIP normalised anything outside the two real modes to "neutral"; an
-- unfamiliar mode must not reach the pages verbatim.
check("hird mode is normalised", S.hird_list[1].mode == "offensive"
      and S.hird_list[2].mode == "neutral", S.hird_list[2].mode)
-- `id` keys the lookup rather than being stored on the record.
check("hird_by_id is keyed by id", S.hird_by_id[11] == S.hird_list[1]
      and S.hird_by_id[12] == S.hird_list[2] and S.hird_list[1].id == nil)
check("hird defaults", S.hird_list[2].level == 1 and S.hird_list[2].atk == 1
      and S.hird_list[2].def == 1 and S.hird_list[2].loyalty == 3
      and S.hird_list[2].age_phase == "young")

-- ---- thralls ---------------------------------------------------------------
-- MIP sent these positionally against a building order the client had to keep
-- in step with the server's; GMCP keys them by name.
roster({ thralls = { total = 25, longhouse = 4, warehouse = 3, farm = 2,
                     smithy = 6, skald_hall = 1 } })
check("thralls total", S.thralls == 25)
check("thralls land on their own buildings by name",
      S.thrall_assignments.longhouse == 4 and S.thrall_assignments.warehouse == 3
      and S.thrall_assignments.farm == 2 and S.thrall_assignments.smithy == 6
      and S.thrall_assignments.skald_hall == 1)
-- A building the frame did not mention is 0, not absent -- pages index the
-- table directly.
check("an unmentioned building is 0 rather than nil",
      S.thrall_assignments.apiary == 0 and S.thrall_assignments.goldsmith == 0)
check("the two shorthand fields track the table",
      S.thralls_longhouse == 4 and S.thralls_warehouse == 3)

-- ---- thrall_follower -------------------------------------------------------
roster({ thrall_follower = { level = 3, name = "Kol", xp = 40, xp_cap = 100,
                             carry_used = 5, carry_cap = 12, state = "following" } })
check("thrall follower fields", S.thrall_follower_level == 3
      and S.thrall_follower_name == "Kol" and S.thrall_follower_xp == 40
      and S.thrall_follower_xp_cap == 100 and S.thrall_follower_carry_used == 5
      and S.thrall_follower_carry_cap == 12)
check("thrall follower state lands on status",
      S.thrall_follower_status == "following", S.thrall_follower_status)

-- ---- varang ----------------------------------------------------------------
roster({
  varang_out = { { name = "Havn", count = 3, secs = 600 } },
  varang_in  = { { name = "Jorvik", count = 1, secs = 300 },
                 { name = "Birka", count = 2, secs = 450 } },
})
check("varang secs lands on expires_in", S.varang_out[1].expires_in == 600
      and S.varang_out[1].name == "Havn" and S.varang_out[1].count == 3)
check("varang in group", #S.varang_in == 2 and S.varang_in[2].name == "Birka"
      and S.varang_in[2].expires_in == 450)
-- Two independent keys over a delta transport.
roster({ varang_out = { { name = "Uppsala", count = 1, secs = 60 } } })
check("an out-only varang delta leaves the in group standing",
      #S.varang_out == 1 and S.varang_out[1].name == "Uppsala"
      and #S.varang_in == 2)

-- ---- unmapped keys ---------------------------------------------------------
-- gneeds and rneeds have no MIP counterpart and no consumer, so they must stay
-- counted rather than being routed somewhere plausible. The server is still
-- growing these payloads, so an unrecognised key must never be fatal.
local before = protocol.gmcp_stats().unknown["gneeds"] or 0
roster({ gneeds = { hird_count = 4 }, rneeds = {}, some_future_key = 1 })
local after = protocol.gmcp_stats().unknown
check("an unmapped key is counted under its own GMCP name, not applied",
      (after["gneeds"] or 0) > before and after["rneeds"] ~= nil
      and after["some_future_key"] ~= nil)

if failures > 0 then
  print("FAILURES: " .. failures)
  os.exit(1)
end
print("ALL GUILD_VIKING GMCP ROSTER TESTS PASSED")
