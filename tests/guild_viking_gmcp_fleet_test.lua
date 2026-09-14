-- guild_viking Guild.Fleet writers (ships, supg, raidlog, rtargets) unit
-- tests. Run from the lera-plugins repo root with LERA_ROOT pointing at a
-- built Lera checkout.
--
-- Every expected value below is written out literally rather than derived by
-- calling the decoder, and each one names the state field its consumer reads.
-- Transport-equivalence assertions alone would not catch the failure this
-- plugin has actually shipped twice: two sources agreeing on a shape the
-- consumer cannot read.
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
for _, name in ipairs({ "handlers.voyage", "handlers.city", "handlers.kingdom" }) do
  local mod = require(name)
  for key, fn in pairs(mod._gmcp or {}) do
    protocol.gmcp_handler(key, fn)
  end
end

local function fleet(payload)
  payload.guild = "viking"
  protocol.on_gmcp("Guild.Fleet", payload)
end

-- ---- ships -----------------------------------------------------------------
-- Field names come from _v_ships() in the mudlib's client.h; `secs`, `id` and
-- `held` are the three that are not called what the client calls them.
fleet({ ships = {
  { name = "Ormen", tier = 2, state = "sailing", target = "Havn", secs = 300,
    id = 7, crew = 4, convoy = 1, convoy_size = 3, convoy_bonus = 15,
    saga_title = "Saga of Ormen", saga_raids = 6, held = 1, durability = 80 },
  { name = "Naglfar", tier = 1, state = "docked", target = "", secs = 0,
    id = 8, crew = 0, convoy = 0, convoy_size = 0, convoy_bonus = 0,
    saga_title = "", saga_raids = 0, held = 0, durability = 100 },
} })
check("ships count", #S.ships == 2, #S.ships)
local sh = S.ships[1]
check("ships scalar fields", sh.name == "Ormen" and sh.tier == 2
      and sh.state == "sailing" and sh.target == "Havn" and sh.crew == 4
      and sh.convoy == 1 and sh.convoy_size == 3 and sh.convoy_bonus == 15
      and sh.saga_title == "Saga of Ormen" and sh.saga_raids == 6
      and sh.durability == 80)
-- The three renames, asserted by name so a swapped pair cannot pass.
check("ships secs lands on return_in", sh.return_in == 300, sh.return_in)
check("ships id lands on ship_id", sh.ship_id == 7, sh.ship_id)
check("ships held becomes a boolean", sh.held == true and S.ships[2].held == false)

-- popups/sea_common.lua gates its reroll list on `(sh.ship_id or 0) > 0`, and
-- autoraid.lua/pages/city.lua key ships by `sh.ship_id or ("name:" .. name)`.
-- 0 is truthy in Lua, so an id of 0 must stay 0 rather than becoming nil, or
-- those two disagree about whether the ship is addressable.
fleet({ ships = { { name = "Skid", id = 0 } } })
check("a zero ship_id stays 0 rather than folding to nil",
      S.ships[1].ship_id == 0, tostring(S.ships[1].ship_id))

-- Defaults, for a record the server trimmed to the fields that had values.
fleet({ ships = { { name = "Bare" } } })
check("ships defaults match the MIP handler's",
      S.ships[1].tier == 1 and S.ships[1].state == "docked"
      and S.ships[1].target == "" and S.ships[1].return_in == 0
      and S.ships[1].durability == 100 and S.ships[1].held == false
      and S.ships[1].ship_id == nil)

-- The 20-ship cap is a display bound the Fleet page relies on, not a wire
-- limit, so it has to survive a transport that no longer chunks.
local many = {}
for i = 1, 30 do many[i] = { name = "S" .. i, id = i } end
fleet({ ships = many })
check("ships cap at 20 survives the transport change", #S.ships == 20, #S.ships)

-- ---- supg ------------------------------------------------------------------
-- `detail` is the one non-scalar field: the server builds the same
-- comma-joined "good:done/need" string for both transports.
fleet({ supg = {
  { name = "Ormen", tier = 3, secs = 900, mats = 40, done = 25,
    detail = "timber:10/20,iron:15/15,mead:0/5" },
} })
local up = S.ship_upgrades[1]
check("supg scalar fields", up.name == "Ormen" and up.tier == 3
      and up.secs_left == 900 and up.mats_total == 40 and up.mats_done == 25)
check("supg detail parses into per-good rows", #up.mats == 3
      and up.mats[1].good == "timber" and up.mats[1].done == 10 and up.mats[1].need == 20
      and up.mats[3].good == "mead" and up.mats[3].done == 0 and up.mats[3].need == 5)
fleet({ supg = { { name = "NoMats", detail = "" } } })
check("supg with no detail yields an empty mats list",
      #S.ship_upgrades[1].mats == 0 and S.ship_upgrades[1].tier == 1)

-- ---- raidlog + raidlog_goods ----------------------------------------------
-- A raid entry's goods breakdown is a mapping, which a record used as a
-- container element may not hold, so the server flattens it to its own array
-- foreign-keyed by `idx`. Rejoining the two is the writer's whole purpose.
fleet({
  raidlog = {
    { idx = 0, ship = "Ormen", target = "Havn", daler = 500, thralls = 2, lost = 0 },
    { idx = 1, ship = "Naglfar", target = "Uppsala", daler = 0, thralls = 0, lost = 1 },
  },
  raidlog_goods = {
    { idx = 0, good = "timber", amount = 12 },
    { idx = 0, good = "iron", amount = 3 },
    { idx = 1, good = "mead", amount = 7 },
  },
})
check("raidlog count", #S.raidlog == 2, #S.raidlog)
check("raidlog scalar fields", S.raidlog[1].ship == "Ormen"
      and S.raidlog[1].target == "Havn" and S.raidlog[1].daler == 500
      and S.raidlog[1].thralls == 2)
check("raidlog lost becomes a boolean",
      S.raidlog[1].lost == false and S.raidlog[2].lost == true)
-- The foreign key has to land each goods row on its own entry; a writer that
-- ignored `idx` and appended in arrival order would put mead on entry 1.
check("raidlog_goods rejoin on idx, in append order",
      #S.raidlog[1].goods == 2 and S.raidlog[1].goods[1].good == "timber"
      and S.raidlog[1].goods[1].qty == 12 and S.raidlog[1].goods[2].good == "iron"
      and #S.raidlog[2].goods == 1 and S.raidlog[2].goods[1].good == "mead"
      and S.raidlog[2].goods[1].qty == 7)

-- The case above cannot actually distinguish a foreign-key join from a
-- positional one, because a full push numbers entries 0..n-1 and `idx` then
-- equals the array position. This one separates them: indices that are not
-- array positions, and goods listed in an order that does not match either.
-- A writer appending goods in arrival order puts amber on Alpha here.
fleet({
  raidlog = {
    { idx = 5, ship = "Alpha", target = "A" },
    { idx = 9, ship = "Beta", target = "B" },
  },
  raidlog_goods = {
    { idx = 9, good = "amber", amount = 1 },
    { idx = 5, good = "fur", amount = 2 },
  },
})
check("goods join on idx, not on array position",
      #S.raidlog[1].goods == 1 and S.raidlog[1].goods[1].good == "fur"
      and #S.raidlog[2].goods == 1 and S.raidlog[2].goods[1].good == "amber",
      (S.raidlog[1].goods[1] or {}).good)

-- With `idx` absent the array position is the only thing left to join on,
-- which is the documented fallback.
fleet({
  raidlog = { { ship = "First" }, { ship = "Second" } },
  raidlog_goods = { { idx = 1, good = "salt", amount = 4 } },
})
check("a record with no idx falls back to its array position",
      #S.raidlog[1].goods == 0 and #S.raidlog[2].goods == 1
      and S.raidlog[2].goods[1].good == "salt")

-- A raid that brought nothing back produces no goods rows at all, so the
-- goods half is legitimately absent rather than empty.
fleet({ raidlog = { { idx = 0, ship = "Empty", target = "Nowhere" } } })
check("raidlog with no goods half yields empty breakdowns",
      #S.raidlog == 1 and #S.raidlog[1].goods == 0)

local rl_many = {}
for i = 1, 30 do rl_many[i] = { idx = i - 1, ship = "R" .. i } end
fleet({ raidlog = rl_many })
check("raidlog cap at 20", #S.raidlog == 20, #S.raidlog)

-- ---- rtargets_lineage + rtargets_historical --------------------------------
-- Each element is the same "name:good1:good2" string MIP sent; the mudlib
-- reads them the same way (explode(hold, ":")[0] in war.h).
fleet({
  rtargets_lineage = { "Uppsala:timber:iron", "Havn:mead:" },
  rtargets_historical = { "Jorvik:cloth:salt", "Bare" },
})
check("rtargets lineage group", #S.raid_targets_lin == 2
      and S.raid_targets_lin[1].name == "Uppsala"
      and S.raid_targets_lin[1].g1 == "timber"
      and S.raid_targets_lin[1].g2 == "iron")
-- An empty good field becomes nil, not "" -- autoraid.lua tests these for
-- presence.
check("an empty good field becomes nil", S.raid_targets_lin[2].name == "Havn"
      and S.raid_targets_lin[2].g1 == "mead"
      and S.raid_targets_lin[2].g2 == nil)
check("rtargets historical group", #S.raid_targets_hist == 2
      and S.raid_targets_hist[1].name == "Jorvik"
      and S.raid_targets_hist[1].g2 == "salt")
-- An element with no colons at all is the whole name.
check("a bare entry is taken as the name", S.raid_targets_hist[2].name == "Bare"
      and S.raid_targets_hist[2].g1 == nil)
check("the flat name list is lineage then historical",
      table.concat(S.raid_targets, ",") == "Uppsala,Havn,Jorvik,Bare",
      table.concat(S.raid_targets, ","))

-- Frames are deltas, and these are two independent keys: one arriving alone
-- must not empty the other group, nor drop its names from the flat list. This
-- is the case a writer that rebuilt both halves from one frame gets wrong.
fleet({ rtargets_lineage = { "Birka:fur:amber" } })
check("a lineage-only delta replaces only that group",
      #S.raid_targets_lin == 1 and S.raid_targets_lin[1].name == "Birka"
      and #S.raid_targets_hist == 2)
check("the flat list is rebuilt from stored halves, not just the arriving one",
      table.concat(S.raid_targets, ",") == "Birka,Jorvik,Bare",
      table.concat(S.raid_targets, ","))

-- ---- envelope --------------------------------------------------------------
-- A frame from another guild must never reach a writer.
protocol.on_gmcp("Guild.Fleet", { guild = "berserker", ships = { { name = "Foreign" } } })
check("a foreign guild's frame is dropped",
      S.ships[1].name ~= "Foreign", S.ships[1].name)

if failures > 0 then
  print("FAILURES: " .. failures)
  os.exit(1)
end
print("ALL GUILD_VIKING GMCP FLEET TESTS PASSED")
