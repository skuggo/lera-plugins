-- guild_viking pane page unit tests: Task 4's pages/city.lua and
-- pages/trade.lua (both modes of LEGACY's draw_page2(y, mode),
-- guild_viking.lua:7573-9114). Run from the lera-plugins repo root with
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

-- ---- lera API stubs ---------------------------------------------------------
ui = { dirty = function() end }
lera = { render_pass = function() return "local" end }

local pagelib = require("pagelib")
local state = require("state")
local page_opts = require("page_opts")
local city_page = require("pages.city")
local trade_page = require("pages.trade")

-- Stage 4 Task 8: pages/city.lua's Raids section now calls autoraid.lua's
-- real M.max_ships() (LEGACY's ar_max_ships()) instead of showing the raw
-- configured ship count uncapped -- wire the BUILDINGS/SHIPS handlers so the
-- dock-tier/held-ship fixture below routes through protocol.ingest with the
-- real handlers, not a direct S.buildings/S.ships poke.
local protocol = require("protocol")
-- init.lua's RESERVED set: the module-level convention fields, not MIP keys.
local RESERVED_KEYS = { _market_seam = true, _patterns = true, _gmcp = true,
                        _retired_keys = true, _retired_patterns = true }
local city_handlers = require("handlers.city")
for key, fn in pairs(city_handlers._gmcp or {}) do
  protocol.gmcp_handler(key, fn)
end
local voyage_handlers = require("handlers.voyage")
for key, fn in pairs(voyage_handlers._gmcp or {}) do
  protocol.gmcp_handler(key, fn)
end

local S = state.S

-- Fixtures are seeded through the production GMCP path -- protocol.on_gmcp ->
-- the handler modules' _gmcp writers -- since that is the only transport these
-- keys still have. The MIP wire strings these calls used to build are gone
-- along with their decoders.
local function gm(pkg, payload)
  payload.guild = "viking"
  protocol.on_gmcp(pkg, payload)
end
local WIDTH = 80

local function joined(lines)
  return table.concat(lines, "\n")
end

local function find_line(lines, needle)
  for i, l in ipairs(lines) do
    if l:find(needle, 1, true) then return i end
  end
  return nil
end

local function set_all(opts_table, val)
  for _, k in ipairs(opts_table) do page_opts.set(k, val) end
end

-- ---- seed CITY-mode state ----------------------------------------------------
S.daler = 54321
S.god_power_name, S.god_power_next = "Odin's Fury", 125

S.voyage_longships = {}
S.ships = { { name = "Ravager", tier = 2, state = "raiding", target = "Vestergotland",
              return_in = 90, crew = 8, ship_id = nil, convoy = 0, durability = 100 } }
S.ship_upgrades = {}

S.raidlog = { { ship = "Ravager", target = "vestergotland", daler = 150,
                goods = { { good = "furs", qty = 12 } }, thralls = 2, lost = false } }

S.buildings = { warehouse = 3, dock = 2 }
S.wstock = { { good = "timber", amount = 200, freshness_pct = 100 } }
S.next_tick_in = 45
S.production = { timber = 25, ore = 10 }
S.upkeep = { roster = 50, community = 20, throne = 10, roads = 5, forts = 5, total = 90 }
S.routes = { hold = { name = "Hold", road_tier = 2, fort_tier = 1,
                       road_maint = 80, fort_maint = 60, road_name = "", fort_name = "" } }
S.route_upkeep = 12
S.route_builds = {}
S.monuments = { "Saga of the North Wind" }
S.monument_cap = 5

-- ---- seed TRADE-mode state ---------------------------------------------------
S.dispatch_cd = 0
S.carts = { { mode = "buy", good = "furs", village = "Vestergotland", return_in = 120,
              amount = 50, halfway_in = 0, quality_pct = 100, cart_id = 3, tier = 2,
              durability = 90, cap = 200, escort = 1, refit = "standard", legs = {} } }
S.idle_carts = { { cart_id = 7, tier = 1, durability = 100, cap = 150, refit = "standard" } }
S.cart_upgrades = { { cart_id = 3, target_tier = 3, secs_left = -1, mats_total = 10,
                       mats_done = 4, mats = { { good = "timber", done = 4, need = 10 } },
                       target_refit = "", job_type = "upgrade" } }
S.courier = { tier = 2, runs = { { good = "fish", village = "Imaird", return_in = 60,
                                    amount = 20, cost = 100, fee = 5 } } }
S.spy = { tier = 1, mode = "sabotage", village = "Holmgard", secs = 300, sab_pct = 10,
          sab_secs = 500, cd_secs = 0, scouts = { { city = "Uppsala", amb = 15, secs = 200 } } }
S.train = { tier = 1, name = "Erik", stat = "combat", trained = 2, secs = 400 }
S.heat = { 10, 80, 5 }
S.grudges = { { town = "Birka", secs = 3600 } }
S.trade_queue = { { mode = "sell", good = "mead", village = "Lejre", amount = 30, escort = 2 } }
S.market_orders = { { id = 1, buyer = "olaf", good = "iron", remaining = 15, price = 8, age_secs = 60 } }
S.incoming_fills = { { good = "honey", amount = 25, arrives_in = 90, seller = "astrid" } }

-- All show_city_*/show_trade opts on, per the ported defaults.
for _, k in ipairs({
  "show_city_ships", "show_city_carts", "show_city_market", "show_city_warehouse",
  "show_city_production", "show_city_buildings", "show_city_monuments",
  "show_city_raidlog", "show_city_plan", "show_city_couriers", "show_city_spies",
  "show_city_training", "show_city_heat",
}) do
  page_opts.set(k, true)
end

-- =============================================================================
-- CITY page
-- =============================================================================
local city_lines = city_page.lines(WIDTH)
check("city.lines() returns a non-empty array", #city_lines > 5, #city_lines)
local city_all = joined(city_lines)

check("Daler line present with fmt_num'd value",
      city_all:find(pagelib.fmt_num(S.daler), 1, true) ~= nil)
check("Active God header present", find_line(city_lines, "Active God") ~= nil)
check("Active God shows the god name", city_all:find("Odin's Fury", 1, true) ~= nil)

check("Longships header present", find_line(city_lines, "Longships") ~= nil)
check("a ship row shows the seeded ship name (Ravager)",
      city_all:find("Ravager", 1, true) ~= nil)

-- ---- Longship row: colour AND column alignment ------------------------------
-- The colours are new (LEGACY drew these fields plain), and every one of them
-- wraps an already-padded field -- an escape inside a "%-12s" would have the
-- padding count escape bytes and the columns would drift apart row by row.
-- So this checks both halves: the hue is present, and two rows whose names
-- differ in length still put Crew: in the same column.
do
  local strip = function(t) return (t:gsub("\27%[[%d;]*m", "")) end
  gm("Guild.Fleet", { ships = {
    { name = "Vasa", tier = 2, state = "raiding", target = "Imaird", secs = 8400,
      crew = 8, held = 0, durability = 100, saga_title = "the Legendary",
      saga_raids = 327 },
    { name = "Enigheten", tier = 2, state = "raiding", target = "Imaird", secs = 8400,
      crew = 8, held = 0, durability = 100 },
  } })
  local fleet = city_page.lines(WIDTH)
  local short_row, long_row, saga_row
  for _, l in ipairs(fleet) do
    local plain = strip(l)
    if plain:find("^Vasa ") then short_row = l end
    if plain:find("^Enigheten ") then long_row = l end
    if plain:find("the Legendary", 1, true) then saga_row = l end
  end
  check("ships: both rows rendered", short_row ~= nil and long_row ~= nil, joined(fleet))
  if short_row and long_row then
    check("ships: Crew: stacks despite differing name lengths",
          strip(short_row):find("Crew:", 1, true) == strip(long_row):find("Crew:", 1, true),
          strip(short_row) .. "\n" .. strip(long_row))
    check("ships: the name carries a colour", short_row:find(pagelib.C.bright_white, 1, true) ~= nil,
          short_row)
    check("ships: the raid target carries the same yellow an Auto-Raid target does",
          short_row:find(pagelib.C.yellow .. "Imaird", 1, true) ~= nil, short_row)
  end
  check("ships: the saga title is coloured and its raid count is not",
        saga_row ~= nil and saga_row:find(pagelib.C.magenta .. "the Legendary", 1, true) ~= nil
        and saga_row:find(pagelib.C.dim .. "(327 raids)", 1, true) ~= nil, saga_row)
  -- A docked ship must not show a stale target.
  gm("Guild.Fleet", { ships = { { name = "Vasa", tier = 2, state = "docked",
    target = "Imaird", secs = 0, crew = 8, held = 0, durability = 100 } } })
  local docked = joined(city_page.lines(WIDTH))
  check("ships: a docked ship shows no target", strip(docked):find("-> Imaird", 1, true) == nil,
        strip(docked))
  gm("Guild.Fleet", { ships = { { name = "Ravager", tier = 2, state = "raiding",
    target = "Vestergotland", secs = 90, crew = 8, held = 0, durability = 100 } } })
end

check("Raids header present", find_line(city_lines, "Raids") ~= nil)
check("raid log row shows the seeded daler gain (+150d)",
      city_all:find("150", 1, true) ~= nil)

-- ---- Auto-Raid ship cap: the page now shows the REAL ar_max_ships() cap
-- (stage 4 Task 8's autoraid.lua), not the raw configured value uncapped
-- (stage 2's disclosed placeholder, now corrected). Dock tier 3 -> DOCK_FLEET
-- cap 6; two ships, one held (Wolf), leaves 1 non-held (Ravager2) -- 1 < 6,
-- so the cap clamps down to 1. Configuring 5 ships must therefore display
-- "1 Ships", not "5 Ships".
gm("Guild.City", { buildings = { { id = "dock", tier = 3 },
                                 { id = "warehouse", tier = 3 } } })
gm("Guild.Fleet", { ships = {
  { name = "Ravager2", tier = 2, state = "docked", target = "", secs = 0,
    crew = 8, held = 0, durability = 100 },
  { name = "Wolf", tier = 2, state = "docked", target = "", secs = 0,
    crew = 8, held = 1, durability = 100 },
} })
S.autoraid = { convoy = false, ships = 5, target = "", last = 0 }
local capped_lines = city_page.lines(WIDTH)
local capped_all = joined(capped_lines)
check("Raids: ship count is capped to the REAL ar_max_ships() (1), not the configured 5",
      capped_all:find("1 Ships", 1, true) ~= nil and capped_all:find("5 Ships", 1, true) == nil,
      capped_all)
-- Restore the shared CITY-mode fixture for every later check in this file.
gm("Guild.City", { buildings = { { id = "dock", tier = 2 },
                                 { id = "warehouse", tier = 3 } } })
gm("Guild.Fleet", { ships = { { name = "Ravager", tier = 2, state = "raiding",
  target = "Vestergotland", secs = 90, crew = 8, held = 0,
  durability = 100 } } })
S.autoraid = nil

-- "Warehouse  [" (not just "Warehouse") avoids matching the "Warehouse T3"
-- building entry the Buildings section lists separately.
check("Warehouse header present", find_line(city_lines, "Warehouse  [") ~= nil)
check("wstock row shows the seeded good (Timber)", city_all:find("Timber", 1, true) ~= nil)

check("Production header present", find_line(city_lines, "Production / Tick") ~= nil)
check("production row shows timber output (+25)", city_all:find("+25", 1, true) ~= nil)

check("Buildings header present", find_line(city_lines, "Buildings") ~= nil)
check("buildings row shows Warehouse T3", city_all:find("Warehouse T3", 1, true) ~= nil)
check("Upkeep / Tick header present", find_line(city_lines, "Upkeep / Tick") ~= nil)
check("upkeep total shown (90)", city_all:find("90", 1, true) ~= nil)

check("Trade Routes header present", find_line(city_lines, "Trade Routes") ~= nil)
check("route row shows the seeded village (Hold)", city_all:find("Hold", 1, true) ~= nil)

check("Runic Monuments header present", find_line(city_lines, "Runic Monuments") ~= nil)
check("monument row shows the seeded inscription",
      city_all:find("Saga of the North Wind", 1, true) ~= nil)

-- The City page renders the plan inline now (popups.cityplan.inline_lines)
-- rather than printing a pointer to /vik cityplan.
check("city plan section present inline",
      city_all:find("City Plan", 1, true) ~= nil)
check("city page no longer points at the cityplan popup",
      city_all:find("City plan: /vik cityplan", 1, true) == nil)

-- ---- city page: mode separation (no trade-only headers) --------------------
local trade_only_headers = {
  "Carts", "Couriers", "Spies", "Training", "Lineage Heat", "Reprisal Grudges",
  "Trade Queue", "Market Orders", "Incoming Fills",
}
for _, h in ipairs(trade_only_headers) do
  check("city.lines() does not contain trade-only header '" .. h .. "'",
        find_line(city_lines, h) == nil, city_all)
end

-- ---- city page: opt gates ---------------------------------------------------
page_opts.set("show_city_ships", false)
check("Longships hidden when show_city_ships is off",
      find_line(city_page.lines(WIDTH), "Longships") == nil)
page_opts.set("show_city_ships", true)

page_opts.set("show_city_raidlog", false)
check("Raids hidden when show_city_raidlog is off",
      find_line(city_page.lines(WIDTH), "Raids") == nil)
page_opts.set("show_city_raidlog", true)

page_opts.set("show_city_warehouse", false)
check("Warehouse hidden when show_city_warehouse is off",
      find_line(city_page.lines(WIDTH), "Warehouse  [") == nil)
page_opts.set("show_city_warehouse", true)

page_opts.set("show_city_production", false)
check("Production hidden when show_city_production is off",
      find_line(city_page.lines(WIDTH), "Production / Tick") == nil)
page_opts.set("show_city_production", true)

page_opts.set("show_city_buildings", false)
do
  local l = city_page.lines(WIDTH)
  check("Buildings hidden when show_city_buildings is off", find_line(l, "Buildings") == nil)
  check("Upkeep / Tick also hidden (shares the show_city_buildings gate)",
        find_line(l, "Upkeep / Tick") == nil)
end
page_opts.set("show_city_buildings", true)

page_opts.set("show_city_monuments", false)
check("Runic Monuments hidden when show_city_monuments is off",
      find_line(city_page.lines(WIDTH), "Runic Monuments") == nil)
page_opts.set("show_city_monuments", true)

page_opts.set("show_city_plan", false)
check("city plan placeholder hidden when show_city_plan is off",
      find_line(city_page.lines(WIDTH), "City plan:") == nil)
page_opts.set("show_city_plan", true)

-- Trade Routes has NO page_opts gate in LEGACY (guild_viking.lua:8642) --
-- unconditional on data presence only.
S.routes = {}
check("Trade Routes disappears once state.routes is empty (no opt controls it)",
      find_line(city_page.lines(WIDTH), "Trade Routes") == nil)
S.routes = { hold = { name = "Hold", road_tier = 2, fort_tier = 1,
                       road_maint = 80, fort_maint = 60, road_name = "", fort_name = "" } }

-- ---- city page: width discipline --------------------------------------------
do
  local width_ok, widest = true, nil
  for _, l in ipairs(city_page.lines(WIDTH)) do
    local vw = pagelib.visible_width(l)
    if vw > WIDTH then width_ok = false; widest = vw end
  end
  check("every city row's visible width is <= the requested width", width_ok, widest)
end

-- =============================================================================
-- TRADE page
-- =============================================================================
local trade_lines = trade_page.lines(WIDTH)
check("trade.lines() returns a non-empty array", #trade_lines > 5, #trade_lines)
local trade_all = joined(trade_lines)

check("Carts header present", find_line(trade_lines, "Carts") ~= nil)
check("a cart row shows the seeded cart id/village",
      trade_all:find("Vestergotland", 1, true) ~= nil)

check("Couriers header present", find_line(trade_lines, "Couriers") ~= nil)
check("a courier row shows the seeded village (Imaird)",
      trade_all:find("Imaird", 1, true) ~= nil)

check("Spies header present", find_line(trade_lines, "Spies") ~= nil)
check("a spy row shows the seeded village (Holmgard)",
      trade_all:find("Holmgard", 1, true) ~= nil)

check("Training header present", find_line(trade_lines, "Training") ~= nil)
check("training row shows the seeded name (Erik)",
      trade_all:find("Erik", 1, true) ~= nil)

check("Lineage Heat header present", find_line(trade_lines, "Lineage Heat") ~= nil)
check("Reprisal Grudges header present", find_line(trade_lines, "Reprisal Grudges") ~= nil)
check("a grudge row shows the seeded town (Birka)",
      trade_all:find("Birka", 1, true) ~= nil)

check("Trade Queue header present", find_line(trade_lines, "Trade Queue") ~= nil)
check("trade queue row shows the seeded village (Lejre)",
      trade_all:find("Lejre", 1, true) ~= nil)

check("Market Orders header present", find_line(trade_lines, "Market Orders") ~= nil)
check("a market order row shows the seeded buyer (Olaf)",
      trade_all:find("Olaf", 1, true) ~= nil)

check("Incoming Fills header present", find_line(trade_lines, "Incoming Fills") ~= nil)
check("an incoming fill row shows the seeded seller (Astrid)",
      trade_all:find("Astrid", 1, true) ~= nil)

-- ---- trade page: mode separation (no city-only headers) --------------------
local city_only_headers = {
  "Active God", "Longships", "Raids", "Warehouse", "Production / Tick",
  "Buildings", "Upkeep / Tick", "Trade Routes", "Runic Monuments",
}
for _, h in ipairs(city_only_headers) do
  check("trade.lines() does not contain city-only header '" .. h .. "'",
        find_line(trade_lines, h) == nil, trade_all)
end
check("trade.lines() does not contain the Daler line",
      trade_all:find(pagelib.fmt_num(S.daler), 1, true) == nil)
check("trade.lines() does not contain the city plan placeholder",
      trade_all:find("City plan:", 1, true) == nil)

-- ---- trade page: opt gates ---------------------------------------------------
page_opts.set("show_city_market", false)
do
  local l = trade_page.lines(WIDTH)
  check("Market Orders hidden when show_city_market is off", find_line(l, "Market Orders") == nil)
  check("Incoming Fills also hidden (shares the show_city_market gate)",
        find_line(l, "Incoming Fills") == nil)
end
page_opts.set("show_city_market", true)

page_opts.set("show_city_couriers", false)
do
  local l = trade_page.lines(WIDTH)
  check("Couriers hidden when show_city_couriers is off", find_line(l, "Couriers") == nil)
  check("Carts still shown (independent gate)", find_line(l, "Carts") ~= nil)
end
page_opts.set("show_city_couriers", true)

page_opts.set("show_city_spies", false)
check("Spies hidden when show_city_spies is off",
      find_line(trade_page.lines(WIDTH), "Spies") == nil)
page_opts.set("show_city_spies", true)

page_opts.set("show_city_training", false)
check("Training hidden when show_city_training is off",
      find_line(trade_page.lines(WIDTH), "Training") == nil)
page_opts.set("show_city_training", true)

page_opts.set("show_city_heat", false)
do
  local l = trade_page.lines(WIDTH)
  check("Lineage Heat hidden when show_city_heat is off", find_line(l, "Lineage Heat") == nil)
  check("Reprisal Grudges also hidden (shares the show_city_heat gate)",
        find_line(l, "Reprisal Grudges") == nil)
end
page_opts.set("show_city_heat", true)

-- LEGACY quirk (guild_viking.lua:7835-8248): Couriers, Spies, Training,
-- Lineage Heat, Reprisal Grudges and Trade Queue are all nested INSIDE the
-- show_city_carts `if` block, so turning Carts off hides all six even
-- though each has its own opt. Preserved faithfully -- see the task report.
page_opts.set("show_city_carts", false)
do
  local l = trade_page.lines(WIDTH)
  check("Carts hidden when show_city_carts is off", find_line(l, "Carts") == nil)
  check("Couriers also hidden (nested inside show_city_carts in LEGACY)",
        find_line(l, "Couriers") == nil)
  check("Spies also hidden (nested inside show_city_carts in LEGACY)",
        find_line(l, "Spies") == nil)
  check("Training also hidden (nested inside show_city_carts in LEGACY)",
        find_line(l, "Training") == nil)
  check("Lineage Heat also hidden (nested inside show_city_carts in LEGACY)",
        find_line(l, "Lineage Heat") == nil)
  check("Reprisal Grudges also hidden (nested inside show_city_carts in LEGACY)",
        find_line(l, "Reprisal Grudges") == nil)
  check("Trade Queue also hidden (nested inside show_city_carts in LEGACY)",
        find_line(l, "Trade Queue") == nil)
  check("Market Orders NOT hidden (its own top-level gate, unaffected)",
        find_line(l, "Market Orders") ~= nil)
end
page_opts.set("show_city_carts", true)

-- ---- trade page: width discipline --------------------------------------------
do
  local width_ok, widest = true, nil
  for _, l in ipairs(trade_page.lines(WIDTH)) do
    local vw = pagelib.visible_width(l)
    if vw > WIDTH then width_ok = false; widest = vw end
  end
  check("every trade row's visible width is <= the requested width", width_ok, widest)
end

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING PAGES2 TESTS PASSED")
