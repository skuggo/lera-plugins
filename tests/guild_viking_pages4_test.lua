-- guild_viking pane page unit tests: Task 8's pages/goods.lua (LEGACY's
-- draw_page6, guild_viking.lua:10703-10984) plus the Part-A market.lua
-- computations it consumes; Task 9 appends pages/army.lua (draw_page_army,
-- 13305-13351) and pages/war.lua (draw_page_war, 14061-14669, plus its
-- draw_campaign_map/draw_prison_panel helpers). Run from the lera-plugins
-- repo root with LERA_ROOT pointing at a built Lera checkout.
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
local goods_page = require("pages.goods")

local S = state.S
local C = pagelib.C
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

-- Finds a row whose ANSI-stripped, trailing-space-trimmed text is EXACTLY
-- `text` -- used for the price-section's lineage header row, which is just
-- the town name alone (find_line's substring match would otherwise hit the
-- SAME town name embedded inside an earlier Market Movers row).
local function find_exact(lines, text)
  for i, l in ipairs(lines) do
    local stripped = l:gsub("\27%[[%d;]*m", ""):gsub("%s+$", "")
    if stripped == text then return i end
  end
  return nil
end

-- Strips ANSI SGR escapes from a joined string -- used where a label and its
-- value are adjacent in the SOURCE text but separated by a color-switch
-- escape in the rendered text (e.g. "Position " in one color, the coord in
-- another), so a plain substring search across the boundary needs the
-- escape gone first.
local function strip_ansi(s)
  return (s:gsub("\27%[[%d;]*m", ""))
end

local function check_width(lines, label)
  local width_ok, widest = true, nil
  for _, l in ipairs(lines) do
    local vw = pagelib.visible_width(l)
    if vw > WIDTH then width_ok = false; widest = vw end
  end
  check(label .. ": every row's visible width is <= the requested width", width_ok, widest)
end

-- =============================================================================
-- pages/goods.lua (Task 8) -- LEGACY draw_page6 (guild_viking.lua:10703-10984)
-- =============================================================================

-- ---- No-data early exit (LEGACY:10725-10730, UNGATED) -----------------------
-- With state.trade_goods completely empty, only the demand-cycle line (if
-- gated on) and a "Trade Goods"/"No data" fallback render -- Market Movers,
-- Refined Goods, Auto-Trade status and price rows are ALL skipped.
S.trade_goods = {}
S.demand_cycle = "Spring Growth"
S.demand_cycle_in = 0
page_opts.set("show_goods_cycle", true)
page_opts.set("show_goods_movers", true)
page_opts.set("show_goods_prices", true)

local nodata_lines = goods_page.lines(WIDTH)
local nodata_all = joined(nodata_lines)
check("goods: 'Trade Goods' no-data header present when trade_goods is empty",
      find_line(nodata_lines, "Trade Goods") ~= nil, nodata_all)
-- The empty state no longer names a toggle to enable: prices arrive with the
-- guild's own reports, so the message says "not yet", not "switch this on".
check("goods: no-data message says the prices have not arrived yet",
      nodata_all:find("town prices arrive", 1, true) ~= nil, nodata_all)
check("goods: Market Movers is skipped entirely when trade_goods is empty",
      find_line(nodata_lines, "Market Movers") == nil, nodata_all)
check("goods: demand cycle line still renders before the no-data exit",
      find_line(nodata_lines, "Demand cycle") ~= nil, nodata_all)
check("goods: demand cycle names the season (Spring Growth)",
      nodata_all:find("Spring Growth", 1, true) ~= nil, nodata_all)

page_opts.set("show_goods_cycle", false)
local nodata_no_cycle = goods_page.lines(WIDTH)
check("goods: demand cycle line disappears when show_goods_cycle is off",
      find_line(nodata_no_cycle, "Demand cycle") == nil)
check("goods: no-data header stays when only the cycle opt is off",
      find_line(nodata_no_cycle, "Trade Goods") ~= nil)
page_opts.set("show_goods_cycle", true)

-- ---- Seed real trade_goods data for the rest of the page --------------------
-- lin0 supplies iron cheaply (score -3 <= -1 gate) and lin1 demands it highly
-- (score 3 >= 2 gate): margin 45, qty = min(supply 100, floor(demand 100*0.8))
-- = 80, profit = 3600 -- same hand-computed fixture shape as the trade-test
-- market.lua cases, reused here so the PAGE's rendering of the SAME numbers
-- can be asserted (rank, town names, buy/sell price, profit, margin).
S.trade_goods = {
  [0] = { iron = { score = -3, supply = 100, demand = 0, buy = 5, sell = 0 } },
  [1] = { iron = { score = 2, supply = 0, demand = 100, buy = 0, sell = 50 } },
}
S.wstock_by_good = {}
S.blocks = {}
S.autotrade.show_n = 6

local movers_lines = goods_page.lines(WIDTH)
local movers_all = joined(movers_lines)

check("goods: Market Movers header present with real trade_goods data",
      find_line(movers_lines, "Market Movers") ~= nil, movers_all)
check("goods: mover row shows Iron (good label)", movers_all:find("Iron", 1, true) ~= nil, movers_all)
-- Town names: LIN_NAMES[0]="Midgard" (no " Hold" suffix to strip),
-- LIN_NAMES[1]="Lodbrok's Hold" -> shortened to "Lodbrok's".
check("goods: mover row names buy town Midgard and sell town Lodbrok's",
      movers_all:find("Midgard", 1, true) ~= nil and movers_all:find("Lodbrok's", 1, true) ~= nil,
      movers_all)
check("goods: mover row shows buy price 5 and sell price 50",
      movers_all:find(" 5 ", 1, true) ~= nil or movers_all:find("5\27", 1, true) ~= nil, movers_all)
check("goods: mover row shows profit +3600d", movers_all:find("+3600d", 1, true) ~= nil, movers_all)
check("goods: mover row shows margin (45/u)", movers_all:find("(45/u)", 1, true) ~= nil, movers_all)

page_opts.set("show_goods_movers", false)
local no_movers = goods_page.lines(WIDTH)
check("goods: Market Movers header disappears when show_goods_movers is off",
      find_line(no_movers, "Market Movers") == nil)
page_opts.set("show_goods_movers", true)

-- ---- LOAD-BEARING QUIRK: show_goods_movers==false also hides Refined Goods
-- and the Auto-Trade status block (LEGACY's build_mover_rows returns an
-- EMPTY row list before either is ever reached, guild_viking.lua:3378).
S.wstock_by_good = { mead = { amount = 20 } }
S.blocks = {}
S.trade_goods[0].mead = { score = 2, supply = 0, demand = 10, buy = 0, sell = 40 }
page_opts.set("auto_trade", true)
S.autotrade.status = "cooldown"

do
  local with_movers = goods_page.lines(WIDTH)
  check("goods: Refined Goods present when show_goods_movers is on",
        find_line(with_movers, "Refined Goods") ~= nil, joined(with_movers))
  check("goods: Auto-Trade status line present when show_goods_movers is on",
        find_line(with_movers, "Auto-Trade") ~= nil, joined(with_movers))

  page_opts.set("show_goods_movers", false)
  local without_movers = goods_page.lines(WIDTH)
  check("goods: Refined Goods ALSO disappears when show_goods_movers is off",
        find_line(without_movers, "Refined Goods") == nil, joined(without_movers))
  check("goods: Auto-Trade status ALSO disappears when show_goods_movers is off",
        find_line(without_movers, "Auto-Trade") == nil, joined(without_movers))
  page_opts.set("show_goods_movers", true)
end

-- ---- Column alignment ------------------------------------------------------
-- The point of a fixed-cell row is that rows with DIFFERENT digit counts put
-- their later columns in the SAME screen column, so assertions here compare
-- two rows against each other rather than against a literal layout -- a
-- literal would have to be rewritten on every width tweak and would not
-- actually test alignment.
--
-- Two refined rows are seeded whose unit prices differ in digit count (a
-- two-digit price against a three-digit one) and whose stock differs likewise,
-- since those were the two fields that used to shove the Demand column
-- sideways. One row has stock and one has none, which is the other case that
-- used to move it.
do
  local strip = function(t) return (t:gsub("\27%[[%d;]*m", "")) end
  S.wstock_by_good = { mead = { amount = 1365 }, gemstones = { amount = 0 } }
  S.blocks = {}
  S.trade_goods[0].mead      = { score = 2, supply = 0, demand = 118, buy = 0, sell = 71 }
  S.trade_goods[0].gemstones = { score = 2, supply = 0, demand = 152, buy = 0, sell = 264 }

  local lines = goods_page.lines(WIDTH)
  local mead, gems
  for _, l in ipairs(lines) do
    local plain = strip(l)
    if plain:find("Mead", 1, true) and plain:find("/u", 1, true) then mead = plain end
    if plain:find("Gemstones", 1, true) and plain:find("/u", 1, true) then gems = plain end
  end
  check("goods: both refined rows rendered", mead ~= nil and gems ~= nil, joined(lines))
  if mead and gems then
    -- "71/u" against "264/u": the unit price is right-aligned, so the slash
    -- lands in the same column despite the extra digit.
    check("goods: refined unit price is right-aligned on the digits",
          mead:find("/u", 1, true) == gems:find("/u", 1, true),
          mead:find("/u", 1, true) .. " vs " .. gems:find("/u", 1, true))
    -- The Demand column stacks across "have 1365 (~Nd)" and "no stock", which
    -- is the misalignment that started this.
    check("goods: Demand starts in the same column with and without stock",
          mead:find("Demand:", 1, true) == gems:find("Demand:", 1, true),
          mead .. "\n" .. gems)
  end
end

-- ---- Refined Goods own gate (nested inside show_goods_movers) --------------
page_opts.set("show_goods_refined", false)
local no_refined = goods_page.lines(WIDTH)
check("goods: Refined Goods disappears when show_goods_refined is off (movers stays)",
      find_line(no_refined, "Refined Goods") == nil and find_line(no_refined, "Market Movers") ~= nil,
      joined(no_refined))
page_opts.set("show_goods_refined", true)

-- ---- Auto-Trade status block: ON/off, Idle, Last run, controls placeholder -
local at_lines = goods_page.lines(WIDTH)
local at_all = joined(at_lines)
check("goods: Auto-Trade shows ON when page_opts.auto_trade is true",
      at_all:find("ON", 1, true) ~= nil, at_all)
check("goods: Idle status line shown (cooldown)", at_all:find("cooldown", 1, true) ~= nil, at_all)
check("goods: Auto-trade controls line points at /vik trader (stage 4 Task 3)",
      at_all:find("Auto%-trade controls: /vik trader") ~= nil, at_all)

page_opts.set("auto_trade", false)
local at_off_lines = goods_page.lines(WIDTH)
local at_off_all = joined(at_off_lines)
check("goods: Auto-Trade shows off when page_opts.auto_trade is false",
      at_off_all:find("off", 1, true) ~= nil, at_off_all)
check("goods: Idle status hidden when auto_trade is off",
      at_off_all:find("cooldown", 1, true) == nil, at_off_all)
page_opts.set("auto_trade", true)

-- Last run: last_jobs preferred over last_msg fallback.
S.autotrade.last_jobs = {
  { mode = "buy", qty = 10, good = "iron", btown_lin = 0, stown_lin = 1, profit = 200, margin = 5 },
}
local jobs_lines = goods_page.lines(WIDTH)
local jobs_all = joined(jobs_lines)
check("goods: Last run job line shows buy 10x Iron -> Lodbrok's +200d (5/u)",
      jobs_all:find("Iron", 1, true) ~= nil and jobs_all:find("Lodbrok's", 1, true) ~= nil
      and jobs_all:find("+200d", 1, true) ~= nil and jobs_all:find("(5/u)", 1, true) ~= nil, jobs_all)

S.autotrade.last_jobs = nil
S.autotrade.last_msg = "sell 4x Mead -> Midgard; buy 2x Furs -> Lodbrok's"
local msg_lines = goods_page.lines(WIDTH)
local msg_all = joined(msg_lines)
check("goods: last_msg fallback splits on ';' into two '- ' lines",
      msg_all:find("sell 4x Mead %-> Midgard", 1) ~= nil
      and msg_all:find("buy 2x Furs %-> Lodbrok's", 1) ~= nil, msg_all)
S.autotrade.last_msg = ""

-- ---- Auto-Trade Log (show_goods_atlog, nested in the same movers block) ----
S.autotrade.log = {
  { t = "10:00", jobs = { { mode = "sell", qty = 3, good = "mead", stown_lin = 0, profit = 90, margin = 30 } } },
}
page_opts.set("show_goods_atlog", true)
local atlog_lines = goods_page.lines(WIDTH)
check("goods: Auto-Trade Log header present when show_goods_atlog is on and log is non-empty",
      find_line(atlog_lines, "Auto-Trade Log:") ~= nil, joined(atlog_lines))

page_opts.set("show_goods_atlog", false)
local no_atlog_lines = goods_page.lines(WIDTH)
check("goods: Auto-Trade Log header disappears when show_goods_atlog is off",
      find_line(no_atlog_lines, "Auto-Trade Log:") == nil, joined(no_atlog_lines))
check("goods: controls line still present when atlog is off",
      joined(no_atlog_lines):find("Auto%-trade controls: /vik trader") ~= nil)
page_opts.set("show_goods_atlog", true)

-- ---- Price rows (show_goods_prices) + trend arrows via market.price_trend --
-- Build a known price_history for lin0/iron so the trend arrow is
-- deterministic: two samples, buy 5 and 15 (bavg=10); current buy=5 is well
-- below avg-thr (thr = max(1, 10*0.04)=1) -> "v" (down), which is GOOD for a
-- buy price per market.price_trend's lower_is_good=true semantics.
S.price_history = { [0] = { iron = { { t = 1, b = 5, s = 40 }, { t = 2, b = 15, s = 60 } } } }

local price_lines = goods_page.lines(WIDTH)
local price_all = joined(price_lines)
local midgard_header_idx = find_exact(price_lines, "Midgard")
check("goods: price rows header names the lineage (Midgard) as its own row",
      midgard_header_idx ~= nil, price_all)

-- The FIRST "Iron" after the price-section's own Midgard header row is the
-- price row (an earlier "Iron" also appears inside the Market Movers row).
local iron_row_idx = nil
if midgard_header_idx then
  for i = midgard_header_idx + 1, #price_lines do
    if price_lines[i]:find("Iron", 1, true) then iron_row_idx = i; break end
  end
end
check("goods: an Iron price row exists under the Midgard header", iron_row_idx ~= nil, price_all)
if iron_row_idx then
  local row = price_lines[iron_row_idx]
  check("goods: Iron price row shows the down-trend arrow 'v' for buy (5, well below avg 10)",
        row:find("v", 1, true) ~= nil, row)
  check("goods: Iron price row shows Supply/Demand values",
        row:find("Sup:", 1, true) ~= nil and row:find("Dem:", 1, true) ~= nil, row)

  -- Fix round 1: the "B:"/"S:" LABELS carry their own FIXED color (magenta/
  -- yellow, decoded from LEGACY's 0xAA88FF/0x88CCFF), while the VALUE + its
  -- trend arrow together carry the TREND color (market.price_trend's bc/sc)
  -- -- two independent signals, matching LEGACY's two separate WindowText
  -- calls (guild_viking.lua:10904-10909) rather than one merged color.
  -- buy: avg=10 (samples 5,15), cur=5 well below avg-thr(9) -> "v", and
  -- lower_is_good=true for buy -> GOOD_COL -> bright_green.
  local expected_buy_label = C.magenta .. "B:" .. pagelib.RESET
  local expected_buy_value = C.bright_green .. string.format("%4d", 5) .. "v" .. pagelib.RESET
  check("goods: 'B:' label is fixed magenta", row:find(expected_buy_label, 1, true) ~= nil, row)
  check("goods: buy value+arrow is trend-colored bright_green (down is GOOD for buy)",
        row:find(expected_buy_value, 1, true) ~= nil, row)

  -- sell: avg=50 (samples 40,60), CURRENT sell (from the trade_goods
  -- fixture, not price_history) is 0 -- well below avg-thr(48) -> "v", and
  -- lower_is_good=false for sell -> BAD_COL -> bright_red (a different
  -- trend color than the buy value above, demonstrating independence).
  local expected_sell_label = C.yellow .. "S:" .. pagelib.RESET
  local expected_sell_value = C.bright_red .. string.format("%4d", 0) .. "v" .. pagelib.RESET
  check("goods: 'S:' label is fixed yellow", row:find(expected_sell_label, 1, true) ~= nil, row)
  check("goods: sell value+arrow is trend-colored bright_red (down is BAD for sell)",
        row:find(expected_sell_value, 1, true) ~= nil, row)
end

page_opts.set("show_goods_prices", false)
local no_prices = goods_page.lines(WIDTH)
check("goods: price rows disappear when show_goods_prices is off",
      find_line(no_prices, "Sup:") == nil, joined(no_prices))
page_opts.set("show_goods_prices", true)

-- ---- width discipline (every gate on, everything rendering at once) --------
check_width(goods_page.lines(WIDTH), "goods")

-- =============================================================================
-- pages/army.lua (Task 9) -- LEGACY draw_page_army (guild_viking.lua:13305-13351)
-- =============================================================================

local army_page = require("pages.army")

-- ---- No-army fallback (13308-13312, UNGATED) --------------------------------
S.army = nil
local no_army_lines = army_page.lines(WIDTH)
check("army: 'No army data' fallback when state.army is nil",
      find_line(no_army_lines, "No army data") ~= nil, joined(no_army_lines))
check("army: no-army fallback names the command that populates it",
      joined(no_army_lines):find("run 'varmy'", 1, true) ~= nil, joined(no_army_lines))

-- ---- Levy + Units (13313-13350) ---------------------------------------------
S.army = {
  conscripts = 42, cap = 10, used = 6,
  units = {
    { uid = 1, type = "skirmishers", size = 12, vet = 55, ready = true,
      leader = "Ivar", traits = { "Blooded", "Scarred" } },
    { uid = 2, type = "huscarls", size = 8, vet = 0, ready = false,
      leader = nil, traits = {} },
  },
}
page_opts.set("show_army_levy", true)
page_opts.set("show_army_units", true)

local army_lines = army_page.lines(WIDTH)
local army_all = joined(army_lines)
check("army: Levy header shows conscript count",
      army_all:find("Levy", 1, true) ~= nil and army_all:find("42 conscripts", 1, true) ~= nil, army_all)
check("army: Units header shows used/cap", army_all:find("Units", 1, true) ~= nil and
      army_all:find("(6 / 10)", 1, true) ~= nil, army_all)
-- The unit rows are laid out in fixed columns now, so type/size and
-- "led by"/leader are no longer adjacent -- padding and colour resets sit
-- between them. Collapse runs of whitespace (and strip ANSI) before matching,
-- which keeps these assertions about FIELD ORDER rather than exact spacing.
local army_flat = strip_ansi(army_all):gsub("%s+", " ")
-- Unit types are title-cased for display now ("shieldwall" -> "Shieldwall"),
-- so these assert the rendered label rather than the raw wire value.
check("army: unit 1 shows type and size", army_flat:find("Skirmishers x12", 1, true) ~= nil, army_flat)
check("army: unit 1 status is 'ready'", army_all:find("ready", 1, true) ~= nil, army_all)
check("army: unit 1 leader is named", army_flat:find("led by Ivar", 1, true) ~= nil, army_flat)
check("army: unit 1 veterancy bar shows 55%", army_all:find("55%", 1, true) ~= nil, army_all)
check("army: unit 1 traits line names both traits",
      army_all:find("Blooded", 1, true) ~= nil and army_all:find("Scarred", 1, true) ~= nil, army_all)
check("army: unit 2 status is 'training' (no leader -> '-')",
      army_flat:find("Huscarls x8", 1, true) ~= nil and
      army_flat:find("training", 1, true) ~= nil and
      army_flat:find("led by -", 1, true) ~= nil, army_flat)

-- ---- Gate off -----------------------------------------------------------------
page_opts.set("show_army_levy", false)
local no_levy = army_page.lines(WIDTH)
check("army: Levy section absent when show_army_levy is off",
      find_line(no_levy, "Levy") == nil, joined(no_levy))
page_opts.set("show_army_levy", true)

page_opts.set("show_army_units", false)
local no_units = army_page.lines(WIDTH)
check("army: Units section absent when show_army_units is off",
      find_line(no_units, "Units") == nil, joined(no_units))
page_opts.set("show_army_units", true)

-- ---- Empty units list fallback ----------------------------------------------
S.army.units = {}
local empty_units = army_page.lines(WIDTH)
check("army: '(no units ...)' fallback when the unit list is empty",
      joined(empty_units):find("no units", 1, true) ~= nil, joined(empty_units))

-- ---- width discipline --------------------------------------------------------
S.army.units = {
  { uid = 1, type = "skirmishers", size = 12, vet = 55, ready = true,
    leader = "Ivar", traits = { "Blooded", "Scarred" } },
}
check_width(army_page.lines(WIDTH), "army")

-- =============================================================================
-- pages/war.lua (Task 9) -- LEGACY draw_page_war (guild_viking.lua:14061-14669)
-- =============================================================================

local war_page = require("pages.war")

page_opts.set("show_war_battle", true)
page_opts.set("show_war_council", true)
page_opts.set("show_war_campaigns", true)
page_opts.set("show_war_houses", true)

-- ---- Campaign Map (13620-14016, UNGATED -- war_map.active) ------------------

S.war_map = {
  active = true, dim = 5, turn = 3, mode = "offense", pending = 0,
  town = "Jorvik", works_budget = 0, march_eta = 125,
  rows = { ".....", ".....", ".....", ".....", "....." },
  upkeep = { food = 10, mead = 5, tools = 2, iron = 1, daler = 3 },
  spoils = { daler = 500, renown = 20, deeds = 2 },
}
S.prison = nil
S.siege = nil
S.battle = nil
S.war = nil
S.diplomacy = nil

local camp_lines = war_page.lines(WIDTH)
local camp_all = joined(camp_lines)
check("war: campaign map header names the town and turn",
      camp_all:find("War Campaign: Jorvik", 1, true) ~= nil and
      camp_all:find("turn 3", 1, true) ~= nil, camp_all)
check("war: campaign map grid collapses to the placeholder line",
      find_line(camp_lines, "Battle map: /vik war") ~= nil, camp_all)
check("war: campaign map march-ETA hint (125s -> '2m')",
      camp_all:find("On the march -- next tile in 2m", 1, true) ~= nil, camp_all)
check("war: campaign map upkeep/tile line",
      camp_all:find("Upkeep/tile: 10 food  5 mead  2 tools  1 iron  3d", 1, true) ~= nil, camp_all)
check("war: campaign map spoils-if-win line",
      camp_all:find("Spoils if you win: 500 daler, 20 renown  (2 deeds)", 1, true) ~= nil, camp_all)

S.war_map.pending = 1
local camp_pending = joined(war_page.lines(WIDTH))
check("war: campaign map hint is 'battle awaits' when pending is set",
      camp_pending:find("A battle awaits", 1, true) ~= nil, camp_pending)
S.war_map.pending = 0

S.war_map.march_eta = 0
local camp_holding = joined(war_page.lines(WIDTH))
check("war: campaign map hint is 'Holding' with no pending battle and no march ETA",
      camp_holding:find("Holding -- 'vcampaign move", 1, true) ~= nil, camp_holding)
S.war_map.march_eta = 125

S.war_map.dim = 0
S.war_map.rows = {}
local camp_waiting = joined(war_page.lines(WIDTH))
check("war: campaign map shows '(waiting for map data...)' with no rows yet",
      camp_waiting:find("waiting for map data", 1, true) ~= nil, camp_waiting)
S.war_map.dim = 5
S.war_map.rows = { ".....", ".....", ".....", ".....", "....." }

S.war_map.active = false
local camp_inactive = joined(war_page.lines(WIDTH))
check("war: campaign map section absent entirely when war_map.active is false",
      camp_inactive:find("War Campaign", 1, true) == nil, camp_inactive)
S.war_map.active = true

-- ---- War Captives (14020-14058, UNGATED -- data-gated) ----------------------

S.prison = {
  held = 2, cap = 5, kin = 1, pending = true,
  pend_name = "Ragnar", pend_size = 8, pend_cmd = true,
  roster = { { id = 1, name = "Thrall A", size = 3, cmd = false, val = 50 } },
}
S.siege = { engines = 2, cap = 4 }

local prison_lines_out = war_page.lines(WIDTH)
local prison_all = joined(prison_lines_out)
check("war: War Captives header shows held/cap",
      prison_all:find("War Captives  (2/5 held)", 1, true) ~= nil, prison_all)
check("war: pending-judgement line names the captive and 'commander'",
      prison_all:find("Awaiting judgement: Ragnar  (8, commander)", 1, true) ~= nil, prison_all)
-- The captive roster is laid out in fixed columns now, so the fields are no
-- longer adjacent and the size reads "x3" rather than "(3)". Match against an
-- ANSI-stripped, whitespace-collapsed copy so this still asserts field ORDER
-- without pinning the spacing.
local prison_flat = strip_ansi(prison_all):gsub("%s+", " ")
check("war: roster row shows id/name/size/ransom",
      prison_flat:find("1) Thrall A x3 ransom 50d", 1, true) ~= nil, prison_flat)
check("war: kin-held-by-foe line", prison_all:find("Our kin held by the foe: 1", 1, true) ~= nil, prison_all)
check("war: siege engines line", prison_all:find("Siege engines: 2/4", 1, true) ~= nil, prison_all)

S.prison = nil
S.siege = nil
local no_prison = war_page.lines(WIDTH)
check("war: War Captives section absent entirely with no prison/siege data",
      find_line(no_prison, "War Captives") == nil, joined(no_prison))

-- ---- Battle (14084-14603, gated show_war_battle) ----------------------------

S.battle = {
  phase = "deploy", target = "Jorvik", mode = "field", turn = 1,
  budget = 100, spent = 40, war_points = 15,
  reserve = { { uid = 5, size = 10, cost = 20, leader = "Bjorn", label = "skirmishers" } },
  units = { { side = "you", label = "huscarls", size = 8, coord = "C3", leader = "Ivar" } },
}
S.war_points = 15

local deploy_lines_out = war_page.lines(WIDTH)
local deploy_all = joined(deploy_lines_out)
-- Several rows switch color mid-label (e.g. "Position " in one color, the
-- coord in another), so a plain substring search across that boundary needs
-- the escapes gone first -- same idiom as find_exact above.
local deploy_stripped = strip_ansi(deploy_all)
check("war: battle header (deploying)",
      deploy_all:find("Deploying vs Jorvik  (field)", 1, true) ~= nil, deploy_all)
check("war: battle grid collapses to the placeholder line",
      find_line(deploy_lines_out, "Battle map: /vik war") ~= nil, deploy_all)
check("war: command budget + Fraegd line",
      deploy_all:find("Command 40/100", 1, true) ~= nil and
      deploy_all:find("Fraegd 15", 1, true) ~= nil, deploy_all)
check("war: 'In reserve' roster row names id/size/label/cost/leader",
      deploy_all:find("In reserve", 1, true) ~= nil and
      deploy_all:find("[5] 10x Skirmishers", 1, true) ~= nil and
      deploy_all:find("20 pts", 1, true) ~= nil and
      deploy_stripped:find("Led by Bjorn", 1, true) ~= nil, deploy_all)
check("war: 'Deployed' roster row names size/label/position/leader",
      deploy_all:find("Deployed", 1, true) ~= nil and
      deploy_all:find("8x Huscarls", 1, true) ~= nil and
      deploy_stripped:find("Position C3", 1, true) ~= nil and
      deploy_stripped:find("Led by Ivar", 1, true) ~= nil, deploy_all)

S.battle = {
  phase = "turn", target = "Jorvik", mode = "siege_attack", turn = 3,
  budget = 100, spent = 60, war_points = 30,
  units = {
    { side = "you", label = "huscarls", size = 8, coord = "C3", morale = 80, leader = "Ivar" },
    { side = "foe", label = "foe_raiders", size = 10, coord = "D4", morale = 20 },
  },
}
local turn_lines_out = war_page.lines(WIDTH)
local turn_all = joined(turn_lines_out)
local turn_stripped = strip_ansi(turn_all)
check("war: battle header (turn phase, no mode label)",
      turn_all:find("Battle vs Jorvik  --  turn 3", 1, true) ~= nil, turn_all)
check("war: 'Your host' roster row with position and morale",
      turn_all:find("Your host", 1, true) ~= nil and
      turn_all:find("8x Huscarls", 1, true) ~= nil and
      turn_stripped:find("Position C3", 1, true) ~= nil and
      turn_stripped:find("Morale 80", 1, true) ~= nil and
      turn_stripped:find("Led by Ivar", 1, true) ~= nil, turn_all)
check("war: 'Enemy' roster row with position and morale (no leader)",
      turn_all:find("Enemy", 1, true) ~= nil and
      turn_all:find("10x Foe_Raiders", 1, true) ~= nil and
      turn_stripped:find("Position D4", 1, true) ~= nil and
      turn_stripped:find("Morale 20", 1, true) ~= nil, turn_all)

S.battle = nil
local no_battle = joined(war_page.lines(WIDTH))
check("war: 'No battle underway.' when state.battle is nil",
      no_battle:find("No battle underway.", 1, true) ~= nil, no_battle)

S.battle = { phase = "turn", target = "Jorvik", turn = 1, budget = 10, spent = 0, units = {} }
page_opts.set("show_war_battle", false)
local no_battle_section = joined(war_page.lines(WIDTH))
check("war: whole Battle section absent when show_war_battle is off",
      no_battle_section:find("Command", 1, true) == nil, no_battle_section)
page_opts.set("show_war_battle", true)
S.battle = nil

-- ---- War Council (14606-14624, gated show_war_council) ---------------------

S.war = {
  incoming = { town = "Kaupang", strength = 120, days = 3 },
  claims = { { town = "Hedeby", days = 10 } },
}
local council_all = joined(war_page.lines(WIDTH))
check("war: War Council header", council_all:find("War Council", 1, true) ~= nil, council_all)
check("war: incoming-threat line",
      council_all:find("UNDER THREAT: Kaupang marches (host ~120%, ~3d to answer)", 1, true) ~= nil,
      council_all)
check("war: claim row", council_all:find("Claim on Hedeby  (lapses ~10d)", 1, true) ~= nil, council_all)

S.war.incoming = nil
local no_incoming = joined(war_page.lines(WIDTH))
check("war: 'No power marches on you.' when there is no incoming threat",
      no_incoming:find("No power marches on you.", 1, true) ~= nil, no_incoming)

S.war.claims = {}
local no_claims = joined(war_page.lines(WIDTH))
check("war: 'No claims held' when the claims list is empty",
      no_claims:find("No claims held (vwar fabricate", 1, true) ~= nil, no_claims)

page_opts.set("show_war_council", false)
local no_council = joined(war_page.lines(WIDTH))
check("war: War Council section absent when show_war_council is off",
      no_council:find("War Council", 1, true) == nil, no_council)
page_opts.set("show_war_council", true)

-- ---- Campaigns (14626-14647, gated show_war_campaigns AND non-empty) -------

S.war.campaigns = { { town = "Hedeby", defense = 40, max = 100 } }
local campaigns_all = joined(war_page.lines(WIDTH))
check("war: Campaigns header + row", campaigns_all:find("Campaigns", 1, true) ~= nil and
      campaigns_all:find("Hedeby", 1, true) ~= nil and campaigns_all:find("40%", 1, true) ~= nil,
      campaigns_all)
check("war: Campaigns trailing hint",
      campaigns_all:find("Win sieges to break defence, then take the town.", 1, true) ~= nil,
      campaigns_all)

S.war.campaigns = {}
local no_campaigns = joined(war_page.lines(WIDTH))
check("war: Campaigns section absent entirely when the campaign list is empty",
      no_campaigns:find("Campaigns", 1, true) == nil, no_campaigns)

S.war.campaigns = { { town = "Hedeby", defense = 40, max = 100 } }
page_opts.set("show_war_campaigns", false)
local no_campaigns_gate = joined(war_page.lines(WIDTH))
check("war: Campaigns section absent when show_war_campaigns is off (data present)",
      no_campaigns_gate:find("Campaigns", 1, true) == nil, no_campaigns_gate)
page_opts.set("show_war_campaigns", true)

-- ---- Great Houses (14649-14667, gated show_war_houses) ----------------------

S.diplomacy = {
  allies = { { house = "Ivarsson", standing = 5 } },
  foes = { { house = "Ragnarsson", standing = -3 } },
}
local houses_all = joined(war_page.lines(WIDTH))
check("war: Great Houses header", houses_all:find("Great Houses", 1, true) ~= nil, houses_all)
check("war: ally line", houses_all:find("Ivarsson (5) marches with you", 1, true) ~= nil, houses_all)
check("war: foe line", houses_all:find("Ragnarsson (-3) marches against you", 1, true) ~= nil, houses_all)

S.diplomacy = nil
local no_houses = joined(war_page.lines(WIDTH))
check("war: 'No houses committed either way.' when state.diplomacy is nil",
      no_houses:find("No houses committed either way.", 1, true) ~= nil, no_houses)

page_opts.set("show_war_houses", false)
local no_houses_gate = joined(war_page.lines(WIDTH))
check("war: Great Houses section absent when show_war_houses is off",
      no_houses_gate:find("Great Houses", 1, true) == nil, no_houses_gate)
page_opts.set("show_war_houses", true)

-- ---- width discipline (every gate on, everything rendering at once) --------
S.war.incoming = { town = "Kaupang", strength = 120, days = 3 }
S.war.claims = { { town = "Hedeby", days = 10 } }
S.war.campaigns = { { town = "Hedeby", defense = 40, max = 100 } }
S.diplomacy = {
  allies = { { house = "Ivarsson", standing = 5 } },
  foes = { { house = "Ragnarsson", standing = -3 } },
}
S.battle = {
  phase = "turn", target = "Jorvik", mode = "field", turn = 3,
  budget = 100, spent = 60, war_points = 30,
  units = {
    { side = "you", label = "huscarls", size = 8, coord = "C3", morale = 80, leader = "Ivar" },
    { side = "foe", label = "foe_raiders", size = 10, coord = "D4", morale = 20 },
  },
}
check_width(war_page.lines(WIDTH), "war")

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING PAGES4 TESTS PASSED")
