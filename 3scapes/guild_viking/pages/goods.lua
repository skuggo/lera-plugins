-- Goods page: LEGACY's draw_page6 (/home/simon/code/3s_scripts_old/lua/
-- guild_viking.lua:10703-10984 -- the function BODY; the wider 10703-12376
-- span the task brief names also covers unrelated page-menu/popup-menu
-- handlers for the whole detached window, not draw_page6 itself -- see the
-- task report). Pure builder: lines(width) -> array of ANSI strings, reading
-- state.lua's S, page_opts.lua, and market.lua (Task 8's Part A verbatim
-- ports) only.
--
-- Section order/gates, read from the source top to bottom:
--   Demand cycle (show_goods_cycle, 10711-10723) -- season/cycle name,
--     colored by intent, plus time-to-next-shift when known.
--   EARLY EXIT (10725-10730, UNGATED): if state.trade_goods is completely
--     empty, draw ONLY a "Trade Goods" header + "No data -- enable with:
--     vtoggle mip_trade_goods" and stop (LEGACY's em dash character is
--     deliberately substituted with "--" here, matching this file's own
--     comment convention). Market Movers, Refined Goods, the
--     Auto-Trade status block and the price rows below are ALL skipped in
--     that case, regardless of their own opts, because draw_page6 itself
--     returns before build_mover_rows or the price-row loop ever runs.
--   Market Movers block (show_goods_movers; rows built by LEGACY's
--     build_mover_rows, :3376-3484) -- LOAD-BEARING QUIRK: build_mover_rows
--     returns an EMPTY row list immediately when show_goods_movers is false
--     (:3378), before ever reaching the Refined Goods or Auto-Trade
--     sections below -- so turning Market Movers off also hides Refined
--     Goods and the whole Auto-Trade status/log block, regardless of THEIR
--     own opts. Preserved faithfully; same disposition as pages/trade.lua's
--     Carts-nesting quirk. Within this block:
--       - Market Movers header + rows (market.compute_market_movers(),
--         sliced to state.autotrade.show_n or 6): rank, good, buy town +
--         price, sell town + price, profit, margin, and a HOT tag
--         (market.mover_is_hot) when the sell price sits in the top third
--         of its recorded range.
--       - "Gathering data" fallback when compute_market_movers() is empty.
--       - Refined Goods sub-section (show_goods_refined, nested; only drawn
--         when market.compute_refined_sells() is non-empty): rank, good,
--         sell town, unit price, stock+realisable value or "no stock",
--         demand, and a blocked-stock note.
--       - Auto-Trade status block (UNCONDITIONAL once the movers gate is
--         open -- NOT gated by show_goods_atlog): ON/off
--         (page_opts.auto_trade), Margin/Reserve/Carts, optional Pack/
--         Use-stock tags; an "Idle: <status>" line when on and a status is
--         set; "Last run:" job lines from state.autotrade.last_jobs (or a
--         ';'-split fallback parse of last_msg for older saved sessions).
--       - Auto-Trade Log (show_goods_atlog, nested in the same block, only
--         when state.autotrade.log is non-empty): the last 12 entries.
--       - Auto-trade controls placeholder (stage 4; see below).
--   Price rows (show_goods_prices, :10763-10774's rows loop) -- one header +
--     goods table per lineage present in state.trade_goods, in lineage-id
--     order: good name, affinity marker, buy/sell price with trend arrows
--     (market.price_trend), supply, demand.
--
-- Disclosed simplifications / dropped surfaces (Global Constraints: content
-- fidelity, not pixel fidelity):
--   - The bespoke pixel scrollbar (_g6_max_scroll, g6_scroll/g6_dragging,
--     the hotspot drag handlers, the scrollbar draw block at :10940-10982)
--     is NOT ported -- window.lua's top-scroller owns scrolling uniformly
--     for every stage-2 page.
--   - The pixel-column multi-good-per-row packing (`cols`, sized from
--     WindowTextWidth measurements so several goods can share one visual
--     row side by side) collapses to ONE ROW PER GOOD: a text pane has no
--     equivalent to measuring pixel text widths to pack columns, and one
--     row per good is easier to scan in a narrow terminal pane besides.
--   - The Phase-4 sell-price range mini-bar (drawn only when the pixel
--     layout happened to collapse to a single column AND history exists,
--     :10924-10938) is dropped: it is a second, purely graphical rendering
--     of the same min/max-relative position the trend arrow (^ / v / =)
--     already conveys in text.
--   - `vrep_header`/`vrep_entry` row kinds are handled in draw_page6's row
--     switch (:10847-10866) but NOTHING in draw_page6 ever appends a row of
--     that kind -- dead code, almost certainly copy-pasted from
--     draw_page9's Village Trade Reputation renderer (already ported at
--     pages/ranks.lua). Not ported here; source (what actually executes)
--     wins per the plan's Global Constraints.
--   - Stage 4 Task 3: the right-click "Auto-Trade Options" popup menu
--     (viking_show_atrade_menu, guild_viking.lua:11321) that let a player
--     toggle Auto-Trade/Pack/Use-stock and cycle Margin/Reserve/Carts/Shown
--     became a require("menu") menu opened by bare `/vik trader`
--     (autotrader/tick.lua). The line under the Auto-Trade block that used
--     to read "Auto-trade controls: stage 4" now points at that command.
--   - MUSHclient colors in this source range are 0xBBGGRR (guild_viking.lua
--     line 301); every mapping below was decoded byte-by-byte first.
--     AFF_COLOR's polarity is disclosed explicitly where it matters (see
--     the comment above it); price_trend's GOOD_COL/BAD_COL are mapped by
--     documented NAME/intent rather than literal decode, same precedent as
--     pages/people.lua's Designations legend note (BAD_COL's literal decode
--     is blue, not red -- the name "BAD_COL", used everywhere as "this
--     trend is unfavorable", wins).
local pagelib = require("pagelib")
local state = require("state")
local page_opts = require("page_opts")
local market = require("market")
local cc = require("pages.city_common")

local S = state.S
local C = pagelib.C

local M = {}

-- ---------------------------------------------------------------------------
-- Town names (guild_viking.lua:10668-10677, LIN_NAMES) and the "strip the
-- redundant Hold suffix" helper (mover_town_short, guild_viking.lua:
-- 3282-3284) used by the Movers/Refined/Auto-Trade sections.
-- ---------------------------------------------------------------------------

local LIN_NAMES = {
  [0] = "Midgard", [1] = "Lodbrok's Hold", [2] = "Eiriksson Hold", [3] = "Ui Imair Hold",
  [4] = "Rurikid Hold", [5] = "Harfagre Hold", [6] = "Yngling Hold", [7] = "Skallagrim Hold",
  [8] = "Stenkil Hold", [9] = "Sverker Hold", [10] = "Eric's Hold", [11] = "Munso Hold",
  [12] = "Skjoldung Hold", [13] = "Sigurdsson Hold",
}

local function town_short(lin)
  local name = LIN_NAMES[lin] or ("Lin" .. tostring(lin or "?"))
  return (name:gsub("%s+Hold$", ""))
end

-- ---------------------------------------------------------------------------
-- Demand cycle (guild_viking.lua:10711-10723, gated show_goods_cycle)
-- ---------------------------------------------------------------------------

-- Ported from LEGACY's demand_cycle_color intent (market.demand_cycle_color
-- holds the literal hex; this maps by season keyword rather than re-decoding
-- the hex here, since the by-name mapping is clearer than round-tripping
-- through market.lua's opaque return value). Decoded BGR: spring 0x88DD44 ->
-- R68/G221/B136 (green-lean); summer 0x44CCDD -> R221/G204/B68 (warm,
-- R~=G/low-B = yellow); autumn/fall 0x4488DD -> R221/G136/B68 (R>>G, low-B =
-- orange, nearest available is red); winter 0xCCCCCC -> even grey; calm/
-- default 0xCCCC00 -> R0/G204/B204 (cyan).
local DEMAND_CYCLE_ANSI = {
  spring = C.bright_green, summer = C.yellow, autumn = C.red, fall = C.red, winter = C.white,
}
local function demand_cycle_ansi(name)
  local s = string.lower(name or "")
  for key, col in pairs(DEMAND_CYCLE_ANSI) do
    if string.find(s, key, 1, true) then return col end
  end
  return C.cyan -- calm / unknown default
end

local function demand_cycle_line(width)
  local name = (S.demand_cycle and S.demand_cycle ~= "") and S.demand_cycle or "Calm Season"
  local text = (S.demand_cycle_in or 0) > 0
    and (name .. "  " .. cc.fmt_time(S.demand_cycle_in))
    or name
  return pagelib.trunc(string.format("%sDemand cycle%s  %s%s%s",
    C.dim, pagelib.RESET, demand_cycle_ansi(name), text, pagelib.RESET), width)
end

-- ---------------------------------------------------------------------------
-- No-data fallback (guild_viking.lua:10725-10730, UNGATED)
-- ---------------------------------------------------------------------------

local function no_data_lines(add, width)
  add(pagelib.header(width, "Trade Goods"))
  add(pagelib.trunc(C.dim .. "No data yet -- town prices arrive as the guild reports them" .. pagelib.RESET, width))
end

-- ---------------------------------------------------------------------------
-- BGR decode workbook for Movers/Refined/Auto-Trade row colors below.
-- guild_viking.lua:301 documents "MUSHclient WindowText colors are BGR
-- (0xBBGGRR)" -- verified against its own worked example two lines later
-- (ci=0xCCCC00 for "@cyan" decodes Blue=CC,Green=CC,Red=00 -> R0/G204/B204,
-- i.e. cyan). Every literal below is decoded the same way (leftmost byte =
-- Blue, middle = Green, rightmost = Red), then mapped to the nearest
-- pagelib.C entry -- pagelib has no true blue, so a blue-leaning decode maps
-- to cyan, its nearest neighbor. Where a name and its decode disagree (e.g.
-- "off" 0x5566FF decodes to strong red, not the cyan a "cool/inactive" guess
-- would suggest), the DECODE wins, same precedent as pages/people.lua's
-- Designations legend note.
--   0xFFCC33 (rank number, both rows)      -> R51/G204/B255  -> cyan
--   0xAAAAAA (town name, mover row)        -> grey           -> white
--   0x66CCFF (mover buy price; refsell     -> R255/G204/B102 -> yellow
--             "have N")
--   0x66FF66 (mover sell price; refsell    -> R102/G255/B102 -> bright_green
--             town + unit price)
--   0x00FF88 (profit / realisable value)   -> R136/G255/B0   -> bright_green
--   0x777777 / 0x888888 (margin, "no       -> grey           -> dim
--             stock", "Demand:", "->")
--   0xFF9933 (refsell "N blocked")         -> R51/G153/B255  -> cyan
--   0x00FF00 (HOT tag)                     -> R0/G255/B0     -> bright_green
--   0x556677 (job dash "- ")               -> muted grey     -> dim
--   0xFFCC00 (job "sell " label)           -> R0/G204/B255   -> cyan
--   0x00CC66 (job "buy " label)            -> R102/G204/B0   -> green
--   0xCCCCCC / 0xAAAAAA (job qty, job buy  -> light grey     -> white
--             town tag)
-- ---------------------------------------------------------------------------

-- Market Movers (guild_viking.lua:3376-3437 build_mover_rows's movers part;
-- rendering shape from draw_mover_row, :3507-3540).
local function mover_row(width, rank, a)
  local left = string.format("%s%2d.%s %s%-12s%s",
    C.cyan, rank, pagelib.RESET, cc.good_color(a.good), cc.good_label(a.good), pagelib.RESET)
  local buy = string.format("%s%-10s%s %s%4d%s",
    C.white, town_short(a.buy_lin), pagelib.RESET, C.yellow, a.buy, pagelib.RESET)
  local sell = string.format("%s%-10s%s %s%4d%s",
    C.white, town_short(a.sell_lin), pagelib.RESET, C.bright_green, a.sell, pagelib.RESET)
  local tail = string.format("%s+%dd%s  %s(%d/u)%s",
    C.bright_green, a.profit or 0, pagelib.RESET, C.dim, a.margin or 0, pagelib.RESET)
  local hot_tag = market.mover_is_hot(a.sell, a.sell_lin, a.good)
    and ("  " .. C.bright_green .. "HOT" .. pagelib.RESET) or ""
  return pagelib.trunc(left .. " " .. buy .. C.dim .. " -> " .. pagelib.RESET .. sell .. "  " .. tail
    .. hot_tag, width)
end

-- Refined Goods (guild_viking.lua:3376-3437's refined part; rendering shape
-- from draw_refsell_row, :3544-3572).
local function refsell_row(width, rank, r)
  local left = string.format("%s%2d.%s %s%-12s%s%s -> %s%s%-10s%s %s%d/u%s",
    C.cyan, rank, pagelib.RESET, cc.good_color(r.good), cc.good_label(r.good), pagelib.RESET,
    C.dim, pagelib.RESET, C.bright_green, town_short(r.sell_lin), pagelib.RESET,
    C.bright_green, r.sell, pagelib.RESET)
  local stock
  if (r.stock or 0) > 0 then
    stock = string.format("%shave %d%s  %s(~%dd)%s",
      C.yellow, r.stock, pagelib.RESET, C.bright_green, r.value or 0, pagelib.RESET)
  else
    stock = C.dim .. "no stock" .. pagelib.RESET
  end
  local demand = string.format("%sDemand: %d%s", C.dim, r.demand or 0, pagelib.RESET)
  local blocked = (r.blocked or 0) > 0
    and string.format("  %s%d blocked%s", C.cyan, r.blocked, pagelib.RESET) or ""
  -- The good and town are already %-padded above, but stock is not, so the
  -- Demand column used to slide left and right with "have 12 (~340d)" vs
  -- "no stock". Pad it to a fixed cell so Demand stacks down the page.
  local REF_STOCK_W = 22
  return pagelib.trunc(left .. "  " .. pagelib.trunc(stock, REF_STOCK_W)
    .. demand .. blocked, width)
end

-- Auto-Trade status / log (guild_viking.lua:3376-3437's at_line part;
-- job-segment shape from at_build_job_segs, :3288-3306).
-- Fixed columns. Every field here was variable-width and concatenated with
-- literal gaps, so the source town, the arrow, the profit and the margin all
-- slid with the length of the good's name and the quantity's digits -- and
-- job_row is what BOTH "Last run:" and the Auto-Trade Log render, so neither
-- section lined up.
local JOB_VERB_W  = 5    -- "sell " / "buy "
local JOB_QTY_W   = 7    -- "1200x"
local JOB_GOOD_W  = 14   -- longest good label
local JOB_TOWN_W  = 11
local JOB_PROFIT_W = 8   -- "+12345d"

local function job_row(width, j, indent)
  local pad = string.rep(" ", indent or 4)
  local out = C.dim .. "- " .. pagelib.RESET

  out = out .. pagelib.trunc((j.mode == "sell")
    and (C.cyan .. "sell" .. pagelib.RESET)
    or (C.green .. "buy" .. pagelib.RESET), JOB_VERB_W)

  out = out .. pagelib.trunc(
    C.white .. tostring(j.qty or 0) .. "x" .. pagelib.RESET, JOB_QTY_W)

  out = out .. pagelib.trunc(
    cc.good_color(j.good) .. cc.good_label(j.good) .. pagelib.RESET, JOB_GOOD_W)

  local src
  if j.mode == "buy" and j.btown_lin then
    src = C.white .. town_short(j.btown_lin) .. pagelib.RESET
  elseif j.stock then
    src = C.dim .. "(stock)" .. pagelib.RESET
  else
    src = ""
  end
  out = out .. pagelib.trunc(src, JOB_TOWN_W)

  out = out .. C.dim .. "-> " .. pagelib.RESET
  out = out .. pagelib.trunc(
    C.bright_green .. town_short(j.stown_lin) .. pagelib.RESET, JOB_TOWN_W)

  -- Profit right-aligned so the digits stack rather than the plus signs.
  local prof = string.format("+%dd", j.profit or 0)
  out = out .. string.rep(" ", math.max(0, JOB_PROFIT_W - #prof))
    .. C.bright_green .. prof .. pagelib.RESET

  if (j.margin or 0) > 0 then
    out = out .. "  " .. C.dim .. string.format("(%d/u)", j.margin) .. pagelib.RESET
  end
  return pagelib.trunc(pad .. out, width)
end

-- BGR decode workbook for the status/log block (guild_viking.lua:3427-3478
-- "st" segments + log entries; leftmost byte = Blue, middle = Green,
-- rightmost = Red, see the workbook above):
--   0x8899AA / 0x667788 (labels: "Auto-Trade "/"Margin "/"Reserve "/
--     "Carts "/"Last run:"/"Auto-Trade Log:") -> muted neutral -> dim
--     (pagelib.kv's dim-label convention, not decoded individually: all are
--     muted greys/tans with no polarity signal of their own)
--   0x00FF66 ("ON")                        -> R102/G255/B0   -> bright_green
--   0x5566FF ("off")                       -> R255/G102/B85  -> bright_red
--   0x66CCFF (">=N" margin value)          -> R255/G204/B102 -> yellow
--   0xFFCC66 (reserve/carts value; log "N  -> R102/G204/B255 -> cyan
--     jobs" count)
--   0xFF99FF ("Pack")                      -> R255/G153/B255 -> magenta
--   0x66FF88 ("Use-stock")                 -> R136/G255/B102 -> bright_green
--   0xFFAA55 ("Idle: <status>")            -> R85/G170/B255  -> cyan
--   0x66AACC (log entry timestamp)         -> R204/G170/B102 -> yellow
--   0x99AAB8 (legacy plain-string log       -> light neutral  -> white
--     entry)
local function autotrade_status_lines(add, width)
  local at = S.autotrade or {}
  local on = page_opts.get("auto_trade")

  add("")
  local parts = {
    C.dim .. "Auto-Trade " .. pagelib.RESET .. (on and (C.bright_green .. "ON") or (C.bright_red .. "off"))
      .. pagelib.RESET,
    C.dim .. "Margin " .. pagelib.RESET .. C.yellow .. ">=" .. tostring(at.min_margin or 3)
      .. pagelib.RESET,
    C.dim .. "Reserve " .. pagelib.RESET .. C.cyan .. tostring(at.reserve or 0) .. pagelib.RESET,
    C.dim .. "Carts " .. pagelib.RESET .. C.cyan .. tostring(at.max_carts or 2) .. pagelib.RESET,
  }
  if at.pack then parts[#parts + 1] = C.magenta .. "Pack" .. pagelib.RESET end
  if at.use_stock then parts[#parts + 1] = C.bright_green .. "Use-stock" .. pagelib.RESET end
  add(pagelib.trunc(table.concat(parts, "   "), width))

  if on and at.status and at.status ~= "" then
    add(pagelib.trunc(C.cyan .. "Idle: " .. at.status .. pagelib.RESET, width))
  end

  if at.last_jobs and #at.last_jobs > 0 then
    add(pagelib.trunc(C.dim .. "Last run:" .. pagelib.RESET, width))
    for _, j in ipairs(at.last_jobs) do
      add(job_row(width, j, 4))
    end
  elseif at.last_msg and at.last_msg ~= "" then
    -- Fallback for sessions saved before structured job data existed
    -- (LEGACY:3452-3459).
    add(pagelib.trunc(C.dim .. "Last run:" .. pagelib.RESET, width))
    for job in (at.last_msg):gmatch("[^;]+") do
      job = job:gsub("^%s+", ""):gsub("%s+$", "")
      if job ~= "" then
        add(pagelib.trunc("  " .. C.white .. "- " .. job .. pagelib.RESET, width))
      end
    end
  end

  if page_opts.get("show_goods_atlog") and at.log and #at.log > 0 then
    add(pagelib.trunc(C.dim .. "Auto-Trade Log:" .. pagelib.RESET, width))
    local first = math.max(1, #at.log - 12)
    for li = first, #at.log do
      local e = at.log[li]
      if type(e) == "table" and e.jobs then
        add(pagelib.trunc(string.format("  %s%s  %s%d %s%s",
          C.yellow, e.t or "", C.cyan, #e.jobs, (#e.jobs == 1 and "job" or "jobs"),
          pagelib.RESET), width))
        for _, j in ipairs(e.jobs) do
          add(job_row(width, j, 6))
        end
      else
        -- Legacy plain-string entry from an older session (LEGACY:3477-3479).
        add(pagelib.trunc("    " .. C.white .. tostring(e) .. pagelib.RESET, width))
      end
    end
  end

  -- Stage 4 Task 3: the right-click Auto-Trade Options popup menu became a
  -- require("menu") settings menu, opened by bare `/vik trader`; `/vik
  -- trader <sub>` runs the same on/off + numeric-knob subcommands LEGACY's
  -- `atrade` alias did (autotrader/tick.lua's M.config/M.open_menu).
  add(pagelib.trunc(C.dim .. "Auto-trade controls: /vik trader" .. pagelib.RESET, width))
end

local function movers_block_lines(add, width)
  add(pagelib.header(width, "Market Movers"))
  local arb = market.compute_market_movers()
  if #arb == 0 then
    add(pagelib.trunc(
      C.dim .. "Gathering data - waiting on town prices" .. pagelib.RESET, width))
  else
    local show_n = (S.autotrade and S.autotrade.show_n) or 6
    local shown = math.min(#arb, show_n)
    for i = 1, shown do
      add(mover_row(width, i, arb[i]))
    end
  end

  if page_opts.get("show_goods_refined") then
    local rsell = market.compute_refined_sells()
    if #rsell > 0 then
      add("")
      add(pagelib.header(width, "Refined Goods"))
      for i, r in ipairs(rsell) do
        add(refsell_row(width, i, r))
      end
    end
  end

  autotrade_status_lines(add, width)
end

-- ---------------------------------------------------------------------------
-- Price rows (guild_viking.lua:10731-10763 GOOD_ORDER/header setup,
-- :10763-10774 the rows loop, gated show_goods_prices)
-- ---------------------------------------------------------------------------

local GOOD_ORDER = {
  "timber", "ore", "iron", "furs", "fish", "grain", "mead", "sunstone", "runestones",
  "spoils", "salted_fish", "bread", "fine_furs", "tools", "gemstones", "honey",
  "weapons", "armour", "finery",
}

-- Ported from LEGACY's AFF_LABEL (guild_viking.lua:10692-10702): numeric
-- affinity score (-3..3) -> a short marker (trailing pixel-alignment spaces
-- dropped; not needed in a text row).
local AFF_LABEL = { [3] = "+++", [2] = "++", [1] = "+", [0] = "", [-1] = "-", [-2] = "--", [-3] = "---" }

-- Ported from LEGACY's AFF_COLOR (guild_viking.lua:10685-10691), decoded
-- BGR: +3..+1 (demand side) decode to a green family (0x44FF44 -> R44/G255/
-- B44, etc); 0 (neutral) decodes to grey; -1..-3 (produces side) decode to a
-- RED family (0xAAAAFF -> R255/G170/B170, etc -- NOT blue, despite the "AA..
-- FF" pattern looking blue-ish at a glance). Banded coarser than LEGACY's
-- three-shades-per-side gradient (pagelib's 16-color table has no pale
-- green/pale red distinct from grey), but the demand=green / produces=red
-- POLARITY is preserved exactly.
local AFF_COLOR = {
  [3] = C.bright_green, [2] = C.green, [1] = C.green, [0] = C.dim,
  [-1] = C.red, [-2] = C.red, [-3] = C.bright_red,
}

-- price_trend's returned hex color (market.lua, ported from LEGACY's
-- GOOD_COL/BAD_COL/FLAT_COL) is mapped by NAME/intent, not literal BGR
-- decode: BAD_COL (0xFF4444) literally decodes to blue (R44/G44/B255), but
-- every call site uses it to mean "this trend is unfavorable" -- same
-- documented-intent-wins precedent as pages/people.lua's Designations
-- legend. FLAT_COL (0x999999) is decode-neutral grey either way.
local function trend_color(hex)
  if hex == 0x00FF00 then return C.bright_green end
  if hex == 0xFF4444 then return C.bright_red end
  return C.dim
end

-- "B:"/"S:" label decode (guild_viking.lua:10897,10900): 0xAA88FF ->
-- R255/G136/B170 (magenta-ish) and 0x88CCFF -> R255/G204/B136 (gold) --
-- mapped to magenta and yellow respectively. These are FIXED label colors
-- only -- LEGACY (guild_viking.lua:10904-10909) colors the VALUE and its
-- trend arrow with the trend color (bc/sc from market.price_trend), a
-- SECOND, independent signal from the fixed label color. "Sup:"/"Dem:"
-- labels (0x44AAFF/0x44CC88) and their values (0x999999, uniformly grey
-- regardless of magnitude in LEGACY) collapse to pagelib.kv's plain
-- dim-label convention rather than being decoded individually: neither
-- carries a polarity signal of its own the way the trend colors do.
local function price_row(width, good, gd, lin)
  local score = gd.score or 0
  local aff_label = AFF_LABEL[score] or ""
  local aff_color = AFF_COLOR[score] or C.dim
  local st = market.price_stats(lin, good)
  local ba, bc_hex = market.price_trend(gd.buy or 0, st and st.bavg, true)
  local sa, sc_hex = market.price_trend(gd.sell or 0, st and st.savg, false)
  local bc, sc = trend_color(bc_hex), trend_color(sc_hex)
  local good_part = string.format("%s%-12s%s %s%-3s%s",
    cc.good_color(good), cc.good_label(good), pagelib.RESET, aff_color, aff_label, pagelib.RESET)
  -- Value + arrow share ONE trend-colored span (bc/sc), matching LEGACY's
  -- two separate WindowText calls that both pass the same color.
  local buy_part = string.format("%sB:%s%s%4d%s%s",
    C.magenta, pagelib.RESET, bc, gd.buy or 0, ba, pagelib.RESET)
  local sell_part = string.format("%sS:%s%s%4d%s%s",
    C.yellow, pagelib.RESET, sc, gd.sell or 0, sa, pagelib.RESET)
  local supdem_part = string.format("Sup:%s%3d%s Dem:%s%3d%s",
    C.dim, gd.supply or 0, pagelib.RESET, C.dim, gd.demand or 0, pagelib.RESET)
  return pagelib.trunc("  " .. good_part .. " " .. buy_part .. " " .. sell_part .. " " .. supdem_part, width)
end

-- Lineage header color (guild_viking.lua:10820): 0x00CCFF decodes
-- Blue=00/Green=CC/Red=FF -> R255/G204/B0 (gold), not the cyan its hex
-- digits might suggest at a glance -- see the price-row workbook above.
local function price_rows_lines(add, width)
  for lin = 0, 13 do
    local gdata = S.trade_goods[lin]
    if gdata and next(gdata) then
      add(pagelib.trunc(C.yellow .. (LIN_NAMES[lin] or ("Lineage " .. lin)) .. pagelib.RESET, width))
      for _, good in ipairs(GOOD_ORDER) do
        local gd = gdata[good]
        if gd then
          add(price_row(width, good, gd, lin))
        end
      end
    end
  end
end

-- ---------------------------------------------------------------------------

function M.lines(width)
  width = width or 80
  local lines = {}
  local function add(s) lines[#lines + 1] = s end

  if page_opts.get("show_goods_cycle") then
    add(demand_cycle_line(width))
  end

  -- UNGATED early exit (LEGACY:10725-10730): everything below is skipped
  -- when trade_goods carries no data at all, regardless of any other opt.
  if not S.trade_goods or not next(S.trade_goods) then
    no_data_lines(add, width)
    return lines
  end

  if page_opts.get("show_goods_movers") then
    movers_block_lines(add, width)
  end

  if page_opts.get("show_goods_prices") then
    price_rows_lines(add, width)
  end

  return lines
end

return M
