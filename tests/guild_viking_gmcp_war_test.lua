-- guild_viking Guild.War (battle board) and Guild.Kingdom's campaign war-map
-- writers. Run from the lera-plugins repo root with LERA_ROOT pointing at a
-- built Lera checkout.
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
local gmcp_map = require("gmcp_map")
local S = require("state").S

local RESERVED = RESERVED_KEYS
for _, name in ipairs({ "handlers.trade", "handlers.kingdom", "handlers.voyage",
                        "handlers.city" }) do
  local mod = require(name)
  for key, fn in pairs(mod._gmcp or {}) do
    protocol.gmcp_handler(key, fn)
  end
end

local function war(payload)
  payload.guild = "viking"
  protocol.on_gmcp("Guild.War", payload)
end
local function kd(payload)
  payload.guild = "viking"
  protocol.on_gmcp("Guild.Kingdom", payload)
end
local function map_frame(payload)
  payload.guild = "viking"
  protocol.on_gmcp("Guild.Map", payload)
end

-- ---- whole-package routing -------------------------------------------------
-- Guild.War's payload uses `w`, `h`, `active` and `terrain` -- the same names
-- Guild.Map uses for the territory map. The key map is one flat table keyed by
-- GMCP key name, so routed through it a battle's grid would overwrite the
-- territory map. Guild.War is dispatched as a whole package instead.
check("Guild.War resolves to a whole-package key",
      gmcp_map.package_key("Guild.War") == "BATTLE")
check("Guild.TradeGoods resolves to a whole-package key",
      gmcp_map.package_key("Guild.TradeGoods") == "TGOODS")
check("the match is case-insensitive on the sub-package",
      gmcp_map.package_key("guild.war") == "BATTLE")
check("ordinary packages are not whole-package routed",
      gmcp_map.package_key("Guild.Map") == nil
      and gmcp_map.package_key("Guild.Kingdom") == nil
      and gmcp_map.package_key("Char.Combat") == nil)

-- Seed a territory map, then send a battle whose grid is a different size and
-- shape. This is the regression the whole-package route exists for.
map_frame({
  w = 5, h = 2, active = 1, pos = { x = 1, y = 1 },
  enc = { terrain = "glyph", east = "glyph", south = "glyph" },
  terrain = { "ppppp", "fffff" },
})
war({ active = 1, phase = "deploy", turn = 1, war_points = 12, mode = "field",
      target = "Jorvik", budget = 100, spent = 20, w = 3, h = 2, dz = 1,
      terrain = { "...", "^^^" }, works = { "   ", "d  " }, wall_tier = 2,
      wall_hp = { "999" }, units = {}, reserve = {} })
check("a battle frame leaves the territory map untouched",
      S.vmap_w == 5 and S.vmap_h == 2 and S.vmap_rows[1] == "ppppp",
      tostring(S.vmap_w) .. "/" .. tostring(S.vmap_rows[1]))

-- ---- battle ----------------------------------------------------------------
check("battle scalars", S.battle ~= nil and S.battle.phase == "deploy"
      and S.battle.turn == 1 and S.battle.mode == "field"
      and S.battle.target == "Jorvik" and S.battle.budget == 100
      and S.battle.spent == 20 and S.battle.dz == 1)
check("battle w/h land on width/height",
      S.battle.width == 3 and S.battle.height == 2)
-- MIP sent one flat string per grid and the client sliced it into rows itself.
-- Rows are rows here; the flat form is still built because the Battle Board's
-- tooltip path indexes it directly.
check("terrain arrives as rows and is also kept flat",
      #S.battle.terrain_rows == 2 and S.battle.terrain_rows[2] == "^^^"
      and S.battle.terrain == "...^^^")
check("works arrives as rows",
      #S.battle.works_rows == 2 and S.battle.works_rows[2] == "d  ")
-- war_points is the running total and is set from every frame.
check("war_points is set from the frame", S.war_points == 12)

war({ active = 1, phase = "melee", w = 2, h = 1, terrain = { ".." },
      units = {
        { side = "Y", label = "Hird", size = 20, coord = "A1", morale = 80,
          type = "hird", leader = "Bjorn", bid = 3, ord = 1, g = "a" },
        { side = "Y", label = "Aid", size = 10, coord = "B1", morale = 60,
          type = "foe_hird", leader = "", bid = 0, ord = 2 },
        { side = "F", label = "Raiders", size = 30, coord = "A2", morale = 50,
          type = "foe_levy", bid = 0, ord = 0 },
      },
      reserve = { { label = "Levy", size = 15, uid = 7, cost = 40,
                    leader = "Gunnar" } } })
check("unit side Y is yours and anything else is the foe",
      S.battle.units[1].side == "you" and S.battle.units[3].side == "foe")
check("unit fields", S.battle.units[1].label == "Hird"
      and S.battle.units[1].size == 20 and S.battle.units[1].coord == "A1"
      and S.battle.units[1].morale == 80 and S.battle.units[1].leader == "Bjorn"
      and S.battle.units[1].bid == 3 and S.battle.units[1].ord == 1
      -- the per-battle letter handle rides through to the board
      and S.battle.units[1].g == "a" and S.battle.units[2].g == "")
-- The server reuses foe_hird for allied aid because it has no you-side icon of
-- its own; the client renames it so it loads the green-tinted art. Ported from
-- the MIP handler, and it applies only on your side.
check("an allied levy on your side is renamed from foe_hird",
      S.battle.units[2].utype == "ally_levy"
      and S.battle.units[1].utype == "hird")
-- An empty leader is nil, which the Battle Board tests for.
check("an empty leader becomes nil", S.battle.units[2].leader == nil)
check("reserve", #S.battle.reserve == 1 and S.battle.reserve[1].uid == 7
      and S.battle.reserve[1].cost == 40
      and S.battle.reserve[1].leader == "Gunnar")

-- The panel is sent every fast tick whether or not a battle is running, so the
-- inactive frame is what clears the board.
war({ active = 0, war_points = 30 })
check("an inactive battle frame clears the board", S.battle == nil)
check("war_points survives an inactive frame", S.war_points == 30)

-- ---- campaign war map ------------------------------------------------------
kd({
  campaign = { active = 1, dim = 4, turn = 3, mode = "offense", pending = 1,
               town = "Jorvik", works_budget = 50, march_eta = 120,
               spoils_daler = 900, spoils_wpts = 12, spoils_deeds = 2,
               upkeep_food = 10, upkeep_mead = 2, upkeep_tools = 2,
               upkeep_iron = 1, upkeep_daler = 80 },
  campaign_terrain = { "..Hf", "wwrr" },
  campaign_units = {
    { kind = "work", id = "", c = 0, r = 0, size = 0, level = 2 },
    { kind = "foe", id = "3", c = 1, r = 2, size = 40, flag = "S" },
    { kind = "objective", id = "", c = 3, r = 3 },
    { kind = "ally", id = "F", c = 2, r = 1, size = 10, flag = "N" },
    { kind = "host", id = "A", c = 0, r = 1, size = 60, flag = "E" },
  },
  campaign_queue = { { id = "A", label = "B2" }, { id = "A", label = "C3" },
                     { id = "F", label = "A1" } },
  campaign_prison = { held = 2, capacity = 5, kin = 1, pending = 1,
                      pend_name = "Ulf", pend_size = 8, pend_cmd = 0 },
  campaign_prison_roster = { { id = 4, name = "Ulf", size = 8, cmd = 1, val = 200 } },
  campaign_siege = { engines = 2, capacity = 4 },
})
local wm = S.war_map
check("campaign scalars", wm ~= nil and wm.active == true and wm.dim == 4
      and wm.turn == 3 and wm.mode == "offense" and wm.pending == 1
      and wm.town == "Jorvik" and wm.works_budget == 50
      and wm.march_eta == 120)
check("campaign terrain rows", #wm.rows == 2 and wm.rows[1] == "..Hf")
check("campaign upkeep", wm.upkeep.food == 10 and wm.upkeep.mead == 2
      and wm.upkeep.tools == 2 and wm.upkeep.iron == 1
      and wm.upkeep.daler == 80)
-- The server calls the war-points spoil `wpts`; the client record has always
-- called it renown. Same number.
check("spoils wpts lands on renown", wm.spoils.daler == 900
      and wm.spoils.renown == 12 and wm.spoils.deeds == 2)
-- Only the three overlay kinds MIP carried are consumed: host becomes "A",
-- objective becomes "*", a foe keeps its numeric id. work/poi/ally are new and
-- popups/war.lua has no cell rendering for them, so they are skipped rather
-- than fed in under ids the renderer would not recognise.
check("only the three MIP overlay kinds are consumed", #wm.units == 3,
      #wm.units)
local by_id = {}
for _, u in ipairs(wm.units) do by_id[u.id] = u end
check("host becomes A", by_id.A ~= nil and by_id.A.c == 0 and by_id.A.r == 1
      and by_id.A.size == 60 and by_id.A.f == "E")
check("objective becomes *", by_id["*"] ~= nil and by_id["*"].c == 3
      and by_id["*"].r == 3)
check("a foe keeps its numeric id", by_id["3"] ~= nil and by_id["3"].size == 40
      and by_id["3"].f == "S")
-- Queue labels are 1-based squares; the client converts them to 0-based cells.
check("queue labels convert to cells", #wm.queue == 2
      and wm.queue[1].c == 1 and wm.queue[1].r == 1 and wm.queue[1].sq == "B2"
      and wm.queue[2].c == 2 and wm.queue[2].r == 2)
check("queues are kept per unit, with A promoted to `queue`",
      wm.queues.F ~= nil and #wm.queues.F == 1 and wm.queues.F[1].c == 0
      and wm.queues.F[1].r == 0)
check("prison capacity lands on cap", S.prison ~= nil and S.prison.held == 2
      and S.prison.cap == 5 and S.prison.kin == 1)
check("prison pending flags become booleans",
      S.prison.pending == true and S.prison.pend_cmd == false
      and S.prison.pend_name == "Ulf" and S.prison.pend_size == 8)
check("prison roster", #S.prison.roster == 1 and S.prison.roster[1].id == 4
      and S.prison.roster[1].cmd == true and S.prison.roster[1].val == 200)
check("siege capacity lands on cap",
      S.siege ~= nil and S.siege.engines == 2 and S.siege.cap == 4)

-- Captives and the siege park outlive a campaign, which is why the MIP path
-- assigned them before its active check. An inactive campaign clears the map
-- and leaves those two standing.
kd({ campaign = { active = 0 },
     campaign_prison = { held = 3, capacity = 5 },
     campaign_siege = { engines = 1, capacity = 4 } })
check("an inactive campaign clears the map", S.war_map == nil)
check("captives and the siege park survive it",
      S.prison ~= nil and S.prison.held == 3 and S.siege ~= nil
      and S.siege.engines == 1)

-- ---- envelope --------------------------------------------------------------
protocol.on_gmcp("Guild.War", { guild = "berserker", active = 1, phase = "foreign" })
check("a foreign guild's battle frame is dropped", S.battle == nil)

if failures > 0 then
  print("FAILURES: " .. failures)
  os.exit(1)
end
print("ALL GUILD_VIKING GMCP WAR TESTS PASSED")
