-- guild_viking Guild.Kingdom writers unit tests. Run from the lera-plugins
-- repo root with LERA_ROOT pointing at a built Lera checkout.
--
-- The campaign war-map cluster (BATTLE and the WM* keys) is not covered here;
-- it has no GMCP writer yet.
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

local function kd(payload)
  payload.guild = "viking"
  protocol.on_gmcp("Guild.Kingdom", payload)
end

-- ---- grudges ---------------------------------------------------------------
kd({ grudges = { { town = "Jorvik", secs = 600 }, { town = "Birka", secs = 30 } } })
check("grudges", #S.grudges == 2 and S.grudges[1].town == "Jorvik"
      and S.grudges[1].secs == 600 and S.grudges[2].town == "Birka")

-- ---- standings / vrep ------------------------------------------------------
-- Both are keyed by lineage id, which the record calls `lin`; the id is the
-- table key rather than a field.
kd({ standings = { { lin = 4, name = "House Ulf", score = 120,
                     label = "Respected", own = 1 },
                   { lin = 7, name = "House Kel", score = -30,
                     label = "Hostile", own = 0 } } })
check("standings are keyed by lineage id",
      S.standings[4] ~= nil and S.standings[7] ~= nil)
check("standings fields", S.standings[4].name == "House Ulf"
      and S.standings[4].score == 120 and S.standings[4].label == "Respected")
-- `own` arrives as 0/1 where the client stores a boolean, and 0 is truthy in
-- Lua, so a naive assignment would make every house your own.
check("own becomes a boolean, and a zero is false",
      S.standings[4].is_own == true and S.standings[7].is_own == false)

kd({ vrep = { { lin = 2, name = "Havn", rep = 45, rank = 3,
                start_at = 40, next_at = 60 } } })
check("vrep is keyed by lineage id and carries its fields",
      S.village_rep[2] ~= nil and S.village_rep[2].name == "Havn"
      and S.village_rep[2].rep == 45 and S.village_rep[2].rank == 3
      and S.village_rep[2].start_at == 40 and S.village_rep[2].next_at == 60)

-- ---- diplo -----------------------------------------------------------------
-- One flat list on the wire, two lists in state, split on each row's `side`.
-- "you" is the ally side -- the mudlib's own serializer makes the same test.
kd({ diplo = { { name = "House Ulf", standing = 30, side = "you" },
               { name = "House Kel", standing = -20, side = "foe" },
               { name = "House Sig", standing = 10, side = "you" } } })
check("allies are the rows whose side is 'you'",
      S.diplomacy ~= nil and #S.diplomacy.allies == 2
      and S.diplomacy.allies[1].house == "House Ulf"
      and S.diplomacy.allies[1].standing == 30
      and S.diplomacy.allies[2].house == "House Sig")
check("everything else is a foe", #S.diplomacy.foes == 1
      and S.diplomacy.foes[1].house == "House Kel"
      and S.diplomacy.foes[1].standing == -20)
-- The Court page tests S.diplomacy for presence to decide whether to draw the
-- section at all, so an empty list must be nil rather than two empty tables.
kd({ diplo = {} })
check("an empty diplo list becomes nil, not an empty pair",
      S.diplomacy == nil)

-- ---- army ------------------------------------------------------------------
-- Each unit's trait list is a container a record may not hold, so it is
-- flattened out and foreign-keyed by uid. The rows are given out of order and
-- interleaved.
kd({
  army = { conscripts = 40, cap = 60, levy_rate = 5, unit_cap = 8, unit_count = 3 },
  army_units = {
    { uid = 11, type = "hird", size = 20, vet = 2, ready = 1, leader = "Bjorn" },
    { uid = 12, type = "levy", size = 30, vet = 0, ready = 0, leader = "-" },
  },
  army_traits = {
    { uid = 12, trait = "green" },
    { uid = 11, trait = "seasoned" },
    { uid = 11, trait = "loyal" },
  },
})
check("army units", #S.army.units == 2 and S.army.units[1].uid == 11
      and S.army.units[1].type == "hird" and S.army.units[1].size == 20
      and S.army.units[1].vet == 2 and S.army.units[1].leader == "Bjorn")
check("unit ready becomes a boolean, and a zero is false",
      S.army.units[1].ready == true and S.army.units[2].ready == false)
check("traits group on their own unit", #S.army.units[1].traits == 2
      and S.army.units[1].traits[1] == "seasoned"
      and #S.army.units[2].traits == 1
      and S.army.units[2].traits[1] == "green")
check("conscripts", S.army.conscripts == 40)
-- pages/army.lua renders exactly one header from these two -- "Units (used /
-- cap)" -- so they are the unit count and the unit cap, NOT the conscript cap
-- and (as the MIP handler has been supplying) the levy rate. Fixing that is
-- the point of this pair of assertions: `cap` here is 8 and not 60, and `used`
-- is 3 and not 5.
check("used is the unit count, not the levy rate", S.army.used == 3, S.army.used)
check("cap is the unit cap, not the conscript cap", S.army.cap == 8, S.army.cap)

-- ---- dynasty ---------------------------------------------------------------
kd({
  dynasty_realm = "Nordheim", dynasty_house = "House Ulf",
  dynasty_heir = "Sigrid", dynasty_living = 4, dynasty_cap = 6,
  dynasty_spouse = { name = "Astrid", house = "House Kel", age = 32, rank = 2 },
  dynasty_children = {
    { name = "Sigrid", gender = "female", age = 19, adult = 1,
      trait = "clever", role = "steward", sch_kind = "letters" },
    { name = "Kol", gender = "male", age = 7, adult = 0, trait = "bold",
      role = "-" },
  },
  dynasty_schooling = { { name = "Sigrid", kind = "letters", path = "runes",
                          tier = 2, pct = 40, tutor = 1 } },
})
local d = S.dynasty
check("dynasty scalars", d.realm == "Nordheim" and d.house == "House Ulf"
      and d.heir == "Sigrid" and d.living == 4 and d.cap == 6)
check("dynasty spouse", d.spouse ~= nil and d.spouse.name == "Astrid"
      and d.spouse.house == "House Kel" and d.spouse.age == 32
      and d.spouse.rank == 2)
check("dynasty children", #d.children == 2 and d.children[1].name == "Sigrid"
      and d.children[1].gender == "female" and d.children[1].age == 19
      and d.children[1].trait == "clever")
check("adult becomes a boolean, and a zero is false",
      d.children[1].adult == true and d.children[2].adult == false)
-- "-" is the server's "no role" placeholder; the Court page tests role for
-- presence.
check("a role of '-' becomes nil", d.children[1].role == "steward"
      and d.children[2].role == nil)
-- Eight independent keys over a delta transport: a frame carrying one must not
-- drop the rest of the record.
kd({ dynasty_living = 5 })
check("a single-key dynasty delta keeps the rest of the record",
      S.dynasty.living == 5 and S.dynasty.realm == "Nordheim"
      and S.dynasty.heir == "Sigrid" and #S.dynasty.children == 2
      and S.dynasty.spouse ~= nil)
-- An empty heir is "none".
kd({ dynasty_heir = "" })
check("an empty heir becomes nil", S.dynasty.heir == nil)

-- ---- war -------------------------------------------------------------------
kd({
  war_cb = { { town = "Jorvik", days = 3 } },
  war_camp = { { town = "Birka", defense = 40, max = 100 } },
  war_incoming = { town = "Uppsala", days = 2, strength = 150 },
})
check("war claims", S.war ~= nil and #S.war.claims == 1
      and S.war.claims[1].town == "Jorvik" and S.war.claims[1].days == 3)
check("war campaigns", #S.war.campaigns == 1
      and S.war.campaigns[1].town == "Birka"
      and S.war.campaigns[1].defense == 40 and S.war.campaigns[1].max == 100)
check("war incoming", S.war.incoming ~= nil
      and S.war.incoming.town == "Uppsala" and S.war.incoming.days == 2
      and S.war.incoming.strength == 150)
-- war_incoming is sent only when a war is actually inbound, so its absence
-- from a frame carrying the other two means "none".
kd({ war_cb = { { town = "Jorvik", days = 2 } }, war_camp = {} })
check("an absent war_incoming means none", S.war ~= nil
      and S.war.incoming == nil and #S.war.claims == 1)
-- The War page tests S.war for presence, so nothing at all must be nil.
kd({ war_cb = {}, war_camp = {} })
check("a war frame with nothing in it becomes nil", S.war == nil)

-- ---- Guild.State ------------------------------------------------------------
-- Only the four State keys with a MIP twin are mapped. hp, sp, points, chain,
-- gxp, tox, fx, encounter, target and ledung are written by combat.lua's
-- output-line triggers, which are protocol-independent and already the single
-- source of truth for those fields, so they stay unmapped and counted.
local function st(payload)
  payload.guild = "viking"
  protocol.on_gmcp("Guild.State", payload)
end

st({ daler = 4321 })
check("daler", S.daler == 4321)

-- MIP spent five keys on the god block; GMCP sends one record.
st({ god = { name = "Freyja", seconds_left = 120, focus = "harvest" } })
check("god name, focus and countdown all come from one record",
      S.god_power_name == "Freyja" and S.god_power_focus == "harvest"
      and S.god_power_next == 120)
check("the countdown also becomes an absolute deadline",
      S.god_power_next_at ~= nil and S.god_power_next_at >= os.time() + 119)
-- The name is validated against a fixed list, as the MIP handler validates it:
-- anything unrecognised reads as "no god power" rather than rendering verbatim.
st({ god = { name = "Cthulhu", seconds_left = 5, focus = "" } })
check("an unrecognised god name is rejected, not rendered",
      S.god_power_name == "", S.god_power_name)
-- A negative countdown is clamped rather than producing a deadline in the past.
st({ god = { name = "Thor", seconds_left = -30 } })
check("a negative countdown clamps to zero", S.god_power_next == 0)

-- -1 means "unknown" for both mission counters, which is not 0 ("none left").
st({ missions_reg = 3, missions_newbie = 0 })
check("mission counters", S.mission_reg_left == 3 and S.mission_new_left == 0)
st({ missions_reg = "x" })
check("an unreadable counter falls back to -1, not 0",
      S.mission_reg_left == -1, S.mission_reg_left)

-- The vitals groups are gathered into the VITALS composite rather than being
-- counted under their own names. This file registers no vitals handler, so
-- VITALS itself has no writer and is counted -- which is exactly what proves
-- the gathering happened: an ungathered `hp` would be counted as `hp`.
st({ hp = { cur = 100, max = 120 }, points = { vitka = 5 }, ledung = { charges = 2 } })
local unk = protocol.gmcp_stats().unknown
check("vitals groups are gathered into VITALS, not counted individually",
      unk["VITALS"] ~= nil and unk["hp"] == nil and unk["points"] == nil
        and unk["ledung"] == nil,
      table.concat({ tostring(unk["VITALS"]), tostring(unk["hp"]),
                     tostring(unk["points"]), tostring(unk["ledung"]) }, "/"))

-- ---- envelope --------------------------------------------------------------
protocol.on_gmcp("Guild.Kingdom", { guild = "berserker",
                                    grudges = { { town = "Foreign", secs = 1 } } })
check("a foreign guild's frame is dropped",
      #S.grudges == 2 and S.grudges[1].town == "Jorvik")

if failures > 0 then
  print("FAILURES: " .. failures)
  os.exit(1)
end
print("ALL GUILD_VIKING GMCP KINGDOM TESTS PASSED")
