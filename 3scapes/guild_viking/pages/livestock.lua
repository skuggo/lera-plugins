-- Livestock page: Guild.Livestock display (Task 2 of the Viking husbandry
-- plan). Pure builder: lines(width) -> array of ANSI strings, reading
-- state.lua's S and page_opts.lua only, modelled on pages/farm.lua (gated
-- sections, mirrored server constants, pagelib for colour) and pages/city.lua
-- (a longer multi-section page's own structure).
--
-- PROVENANCE, verified by grep against
-- /home/simon/code/3s_scripts_old/lua/guild_viking.lua before writing (the
-- previous task's citations were 540-590 lines off from guessing; every
-- range below was re-checked against the actual file, not assumed):
--   * My Herds        -- guild_viking.lua:9818-9900. The empty-state hint
--     (9818-9825) and the grouped-by-species render (9827-9899), which is
--     immediately followed by the next section's comment at 9900.
--   * Market          -- guild_viking.lua:10100-10176 (the
--     `show_city_livestock` block). NOTE the end line: 10173 is the
--     "H=Hardiness..." legend row, three lines short of the block's actual
--     closing `end` at 10176. Both bounds were located, not estimated.
-- Three more sections also have a LEGACY precedent, found during the same
-- sweep and cited here for the same reason -- verify, don't assume:
--   * Pending Deliveries -- guild_viking.lua:9900-9916 ("Incoming (en
--     route)"), reused here under this task's own section name/gate.
--   * Butchery Queue     -- guild_viking.lua:9919-9941.
--   * Livestock Find     -- guild_viking.lua:10030-10098 (postings + offers
--     only -- LEGACY's LFIND had no auctions sub-array; the Auctions block
--     below is new, matching Task 1's S.lfind.auctions).
-- Feed and Needs have NO LEGACY panel precedent: Feed never existed as a
-- panel section at all (Guild.Livestock's feed/grain/water accounting is
-- GMCP-only), and Needs is explicitly commented OUT of LEGACY's miniwindow
-- ("-- (Livestock Needs section intentionally not shown in the
-- miniwindow.)", guild_viking.lua:10178).
--
-- LEGACY's own My-Herds empty-state hint reads "No livestock yet - buy via
-- 'vlivestock market'  (feed: vtoggle mip_livestock)" (guild_viking.lua:
-- 9821-9822). The "(feed: vtoggle mip_livestock)" half is dropped here,
-- deliberately: Guild.Livestock is a GMCP package, so its keys always arrive
-- once the server sends them -- there is no MIP toggle left to enable, and
-- that half of the hint would be a lie. The "vlivestock market" naming
-- survives because it is still true: that command is how a player buys
-- their first animals.
--
-- Static species/breed/cap/trait tables below mirror the server's own
-- constants: BLDG_* ids and the HERD_CAP_* tier tables from
-- 3s/players/viking/world/trade_goods.h:262-266,1050-1054 (indexed 1..5
-- directly here, dropping trade_goods.h's leading tier-0 zero, matching
-- LEGACY's own HERD_CAP shape at guild_viking.lua:9832-9835 -- an unknown
-- tier then naturally misses the table instead of needing a clamp);
-- HERD_CAP and LIVESTOCK_FEED_PER_HEAD both live in market.lua now, one
-- definition each, shared with autoherd.lua; species/breed display
-- names from 3s/players/viking/world/livestock_daemon.c:20-115, mirrored
-- into LEGACY's own SP_LABEL/SP_DISP/BR_DISP tables at guild_viking.lua:
-- 9830 (SP_LABEL), 9902/9926/10033/10105 (SP_DISP's four occurrences),
-- 10107-10113 (BR_DISP); lineage/town names from LIN_NAMES (guild_viking.lua:
-- 12229-12244 -- forward-declared empty at 3540, populated at 12229 --
-- duplicated locally the same way pages/goods.lua's own copy is, rather than
-- reaching across page modules); and trait display names from
-- livestock_daemon.c:132-138, mirrored into LEGACY's own VK_LTRAIT_NAME
-- (guild_viking.lua:4816-4818).
local pagelib = require("pagelib")
local state = require("state")
local page_opts = require("page_opts")
local cc = require("pages.city_common")
-- The Feed section's two numbers, and the tier-cap table, come from the same
-- code the Auto-Herd feed guard uses -- market.M.wh_amount_of/M.wh_known,
-- market.M.feed_draw and market.M.HERD_CAP -- so a page and a planner cannot
-- disagree about whether the animals are fed or how big a building is.
-- market.lua requires only state, so this is a leaf require and closes no
-- load-time cycle through window.lua -> pages.livestock. It is deliberately
-- market.lua and NOT autoherd.lua: requiring the planner from here made
-- loading any page pull in the whole spending module.
local market = require("market")

local S = state.S
local C = pagelib.C

local M = {}

-- ---------------------------------------------------------------------------
-- Shared static tables (see the provenance comment above for sources)
-- ---------------------------------------------------------------------------

-- Herds are keyed by building id; iterated in this fixed order
-- (guild_viking.lua:9827, vlivestock.c:486).
local SP_ORDER = { "sheepfold", "byre", "stable", "piggery", "henhouse" }
local SP_LABEL = { sheepfold = "Sheep", byre = "Cattle", stable = "Horses",
                   piggery = "Pigs", henhouse = "Hens" }
-- Species header colours: LEGACY's SP_COL (guild_viking.lua:9828) in BGR
-- (sheepfold 0xAADD88 light-green, byre 0x66BBFF pale-blue, stable
-- 0x66DDBB teal, piggery 0xCC99FF light-purple, henhouse 0x66DDDD cyan) --
-- mapped by nearest available pagelib.C hue, not decoded to exact RGB.
local SP_ANSI = { sheepfold = C.green, byre = C.cyan, stable = C.bright_cyan,
                  piggery = C.magenta, henhouse = C.bright_cyan }

-- Butchery queue / pending / find / market rows carry a "species" field
-- (sheep/chicken/pig/cow/horse) rather than a building id -- LEGACY's own
-- separate SP_DISP table (guild_viking.lua:9901,9926,10033,10104), plural
-- and "Hens"-vs-"Chickens" inconsistency with SP_LABEL above kept
-- byte-faithful rather than reconciled.
local SP_DISP = { sheep = "Sheep", chicken = "Chickens", pig = "Pigs",
                  cow = "Cattle", horse = "Horses" }
-- Species colours for those same species-keyed rows -- LEGACY's own SP_COL2
-- (guild_viking.lua:10265), mirroring SP_ANSI above (which is keyed by
-- building id) under species ids instead, mapped to the same pagelib.C hues.
local SP_ANSI2 = { sheep = C.green, cow = C.cyan, horse = C.bright_cyan,
                   pig = C.magenta, chicken = C.bright_cyan }

local BR_DISP = {
  spelsau = "Spelsau", soay = "Soay", manx = "Manx Loaghtan",
  icelandic_sheep = "Icelandic", landnam = "Landnamshoena",
  gammelsvensk = "Gammelsvensk", orust = "Orust",
  norse_landrace = "Norse Landrace", jutland_black = "Jutland Black",
  wild_boar_cross = "Wild Boar Cross", fjord_cattle = "Fjord Cattle",
  doela = "Doela", icelandic_cattle = "Icelandic Settlement",
  fjord = "Fjord Horse", gotland_russ = "Gotland Russ",
  icelandic_horse = "Icelandic",
}
-- Fallback for a breed id not in BR_DISP: title-case every word, matching
-- LEGACY's own _breed_name fallback (guild_viking.lua:9843-9847) exactly --
-- cc.cap_first only capitalises the string's first letter, which is right
-- for a species/good id (one word) but wrong here now that a future breed
-- could add a second word (unreachable today: BR_DISP already covers every
-- breed livestock_daemon.c's _breed_defs defines).
local function breed_name(b)
  if not b or b == "" then return "Unknown" end
  if BR_DISP[b] then return BR_DISP[b] end
  return (b:gsub("_", " "):gsub("(%a)(%w*)", function(a, c) return a:upper() .. c end))
end

-- The page's read of market.M.HERD_CAP: DELIBERATELY unclamped, unlike
-- autoherd.lua's cap_for. A building with no known tier (S.buildings[bldg] is
-- nil) or a tier the table doesn't cover simply misses, and returning nil is
-- how every caller here knows to show head alone rather than invent a cap.
-- The planner clamps instead, because a buy must never be sized against a nil
-- cap; the divergence is intentional and belongs at these two call sites, not
-- in two copies of the table.
local function herd_cap(bldg)
  local tier = S.buildings and S.buildings[bldg]
  local caps = market.HERD_CAP[bldg]
  if tier and caps then return caps[tier] end
  return nil
end

local LIN_NAMES = {
  [0] = "Midgard", [1] = "Lodbrok's Hold", [2] = "Eiriksson Hold", [3] = "Ui Imair Hold",
  [4] = "Rurikid Hold", [5] = "Harfagre Hold", [6] = "Yngling Hold", [7] = "Skallagrim Hold",
  [8] = "Stenkil Hold", [9] = "Sverker Hold", [10] = "Eric's Hold", [11] = "Munso Hold",
  [12] = "Skjoldung Hold", [13] = "Sigurdsson Hold",
}

local LTRAIT_NAME = { prolific = "Prolific", hardy = "Hardy",
                      bountiful = "Bountiful", purebred = "Purebred" }
-- Trait colours: LEGACY's VK_TRAIT_COL (guild_viking.lua:4809-4813) in BGR
-- (prolific 0xCC88FF -> RGB FF88CC pink, hardy 0x66CC66 -> RGB 66CC66
-- green, bountiful 0x33CCFF -> RGB FFCC33 gold, purebred 0xFF8855 -> RGB
-- 5588FF blue) -- mapped to the nearest pagelib.C hue (no pink or blue in
-- that table), same "content fidelity, not hex fidelity" convention as
-- pages/city_common.lua's GOOD_COLORS.
local TRAIT_ANSI = { prolific = C.magenta, hardy = C.green,
                     bountiful = C.yellow, purebred = C.cyan }
local function trait_label(t)
  if not t then return nil end
  return LTRAIT_NAME[t] or cc.cap_first(t)
end
local function trait_tag(t)
  if not t then return "" end
  return string.format("  %s{%s}%s", TRAIT_ANSI[t] or C.dim, trait_label(t), pagelib.RESET)
end

-- ---------------------------------------------------------------------------
-- My Herds (guild_viking.lua:9818-9900, gated show_stock_herds)
-- ---------------------------------------------------------------------------

local function herd_head_row(width, bldg, herd)
  local label = SP_LABEL[bldg] or cc.cap_first(bldg)
  local cap = herd.management and herd.management.cap or herd_cap(bldg)
    if herd.management_present and not herd.management then cap = nil end
  local hc = cap and string.format("%d/%d", herd.head or 0, cap) or tostring(herd.head or 0)
  return pagelib.trunc(string.format("%s%-10s%s %s%s%s",
    SP_ANSI[bldg] or C.white, label, pagelib.RESET, C.yellow, hc, pagelib.RESET), width)
end

-- Stat letter colours: LEGACY's C_H/C_F/C_Y/C_V/C_C (guild_viking.lua:
-- 9840-9844) in BGR -- H green, F magenta, Y yellow, V cyan, C "brown"
-- (0x0000AA -> RGB AA0000, a dark red); pagelib has no brown so C reuses
-- red, the same fallback pages/city_common.lua's GOOD_COLORS already uses
-- for its own brown-ish entries (e.g. furs).
local function herd_stats_row(width, herd)
  local raw = string.format(
    herd.management and "%sH:%.2f%s %sF:%.2f%s %sY:%.2f%s %sV:%.2f%s %sC:%.2f%s  Gen:%.2f"
          or "%sH:%d%s %sF:%d%s %sY:%d%s %sV:%d%s %sC:%d%s  Gen:%d",
    C.green, herd.hard or 0, pagelib.RESET,
    C.magenta, herd.fert or 0, pagelib.RESET,
    C.yellow, herd.yield or 0, pagelib.RESET,
    C.cyan, herd.vigor or 0, pagelib.RESET,
    C.red, herd.con or 0, pagelib.RESET,
    herd.gen or 0)
  if (herd.hv or 0) > 0 then
    raw = raw .. string.format("  %s+HV:%d%s", C.bright_green, herd.hv, pagelib.RESET)
  end
  if herd.age_ticks ~= nil then
    raw = raw .. string.format(herd.management and "  Age:%.2f" or "  Age:%d", herd.age_ticks)
  else
    raw = raw .. "  Age:?"
  end
  raw = raw .. trait_tag(herd.trait)
  return pagelib.trunc(raw, width)
end

-- The management row under each herd. Every field here is a number you act
-- on, and reading it as one grey run meant scanning it word by word: pen
-- space that has run out is the difference between a herd that grows and one
-- that does not, and a pending head is work already paid for. So the labels
-- stay dim and the values carry the meaning -- a count that is zero is dim
-- too, because "nothing to see" is most of the time.
local function count_cell(label, n, colour)
  local value = (n or 0) > 0 and (colour .. n .. pagelib.RESET)
                             or (C.dim .. "0" .. pagelib.RESET)
  return C.dim .. label .. ":" .. pagelib.RESET .. value
end

local function management_row(mg)
  -- Free pen space is the one field whose ZERO is the alarming state: a full
  -- pen silently stops the herd growing, so it is called out rather than
  -- dimmed away.
  local free = (mg.free or 0) > 0
    and (C.green .. mg.free .. pagelib.RESET)
    or (C.bright_red .. "0" .. pagelib.RESET)
  local auto = mg.auto_slaughter == 1
    and (C.yellow .. "on" .. pagelib.RESET)
    or (C.dim .. "off" .. pagelib.RESET)
  return table.concat({
    C.dim .. "Penfree:" .. pagelib.RESET .. free,
    count_cell("Pending", mg.pending, C.cyan),
    count_cell("Protected", mg.protected, C.bright_cyan),
    C.dim .. "Auto-cull:" .. pagelib.RESET .. auto,
  }, "  ")
end

local function herds_lines(add, width)
  add(pagelib.header(width, "My Herds"))
  if not S.herds or next(S.herds) == nil then
    add(pagelib.trunc(C.dim .. "No livestock yet - buy via 'vlivestock market'" .. pagelib.RESET, width))
    return
  end
  for _, bldg in ipairs(SP_ORDER) do
    local herd = S.herds[bldg]
    if herd and (herd.head or 0) > 0 then
      add(herd_head_row(width, bldg, herd))
      add(herd_stats_row(width, herd))
      local mg = herd.management
      if mg then
        add(pagelib.trunc(management_row(mg), width))
      elseif herd.management_present then
        add(pagelib.trunc("Management:? (invalid metadata; auto-buy paused)", width))
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Butchery queue (guild_viking.lua:9919-9941, gated show_stock_queue)
-- ---------------------------------------------------------------------------

local function queue_lines(add, width)
  add(pagelib.header(width, string.format("Butchery Queue  (%d/%d slots)",
    S.bqueue_used or 0, S.bqueue_max or 0)))
  if not S.bqueue or #S.bqueue == 0 then
    add(pagelib.trunc(C.dim .. "Empty" .. pagelib.RESET, width))
    return
  end
  local rows = {}
  for _, e in ipairs(S.bqueue) do
    rows[#rows + 1] = {
      SP_DISP[e.species] or cc.cap_first(e.species or "?"),
      cc.good_label(e.meat),
      "x" .. tostring(e.qty or 0),
      cc.fmt_time(e.secs),
    }
  end
  for _, l in ipairs(pagelib.columns(width, {
    { title = "Species", w = 10 }, { title = "Meat", w = 10 },
    { title = "Qty", w = 5 }, { title = "Ready", w = "*" },
  }, rows)) do add(l) end
end

-- ---------------------------------------------------------------------------
-- Feed (no LEGACY panel precedent -- see header comment; gated show_stock_feed)
-- ---------------------------------------------------------------------------

-- A CORRECTION worth keeping the history of, because the old output looked
-- entirely plausible. This section used to render:
--     Grain: 2   Water: 2   Head: 14
--     Draw: 2 grain/tick   Covers: 0 ticks
-- where "Draw" was a client re-derivation of ceil(head / 8) and "Covers" was
-- floor(f.grain / draw) -- i.e. one per-tick NEED divided by another per-tick
-- need, labelled as a starvation runway. S.lfeed is not a stock: the server's
-- _v_lfeed() (3s/players/viking/obj/include/client.h:4202) fills grain/water
-- from query_livestock_feed_needs() (query.h:2464), which sums grain NEEDED
-- PER TICK, and vlivestock.c:609 renders those same numbers as "Feed per
-- tick: %d grain + %d water (%d head)". So the old "Covers" figure was
-- always 1 for a single building and never told the player anything true
-- about whether their animals would starve -- worse than showing nothing.
--
-- Now: the server's own per-tick figures are shown as the per-tick
-- requirement they are (no re-derivation -- market.M.feed_draw returns
-- S.lfeed.grain when it is present, and only falls back to LEGACY's
-- ceil(head / 8) before the LFEED key has arrived), and "Covers" is
-- warehouse grain STOCK divided by that per-tick need, read through the same
-- market.M.wh_amount_of the Auto-Herd feed guard uses. When the WSTOCK feed
-- has not arrived (market.wh_known() false) the Covers line is OMITTED
-- rather than printing a 0-tick runway this page cannot know.
local function feed_lines(add, width)
  add(pagelib.header(width, "Feed"))
  local f = S.lfeed or {}
  local head = tonumber(f.head) or 0
  if head <= 0 then
    add(pagelib.trunc(C.dim .. "No head to feed" .. pagelib.RESET, width))
    return
  end
  local draw = market.feed_draw(head)
  add(pagelib.trunc(string.format(
    "%sPer tick:%s %s%d grain%s %s+%s %s%d water%s   %sHead:%s %d",
    C.dim, pagelib.RESET, C.yellow, draw, pagelib.RESET,
    C.dim, pagelib.RESET, C.cyan, tonumber(f.water) or 0, pagelib.RESET,
    C.dim, pagelib.RESET, head), width))
  if market.wh_known() and draw > 0 then
    local stock = market.wh_amount_of("grain")
    local ticks = math.floor(stock / draw)
    -- Colour by how much runway is left, not a flat cyan. "Covers: 0 ticks"
    -- means the herd is about to go unfed, which is the single most
    -- actionable line on this page and previously read the same as a healthy
    -- 40. Zero also gets a plain-English tail -- a reader should not have to
    -- infer starvation from a 0.
    local cov_col = C.bright_green
    if ticks <= 0 then cov_col = C.bright_red
    elseif ticks < 5 then cov_col = C.red
    elseif ticks < 20 then cov_col = C.yellow end
    add(pagelib.trunc(string.format(
      "%sCovers:%s %s%d tick%s%s %s(%d grain in the warehouse)%s%s",
      C.dim, pagelib.RESET, cov_col, ticks, ticks == 1 and "" or "s",
      pagelib.RESET, C.dim, stock, pagelib.RESET,
      ticks <= 0 and (" " .. C.bright_red .. "-- the herd will not be fed"
                      .. pagelib.RESET) or ""), width))
  end
end

-- ---------------------------------------------------------------------------
-- Pending deliveries (guild_viking.lua:9900-9916, gated show_stock_pending)
-- ---------------------------------------------------------------------------

local function pending_lines(add, width)
  add(pagelib.header(width, "Pending Deliveries"))
  if not S.lpending or #S.lpending == 0 then
    add(pagelib.trunc(C.dim .. "None" .. pagelib.RESET, width))
    return
  end
  -- pagelib.columns pads each cell with pagelib.trunc, which is ANSI-aware,
  -- so cells can carry colour without breaking the column widths.
  --
  -- SP_ANSI2 (species) and SP_ANSI (destination building) already existed and
  -- were simply unused here, so a wall of identical grey rows was the only
  -- thing distinguishing a sheep delivery from a horse one. Arrival time gets
  -- a freshness gradient -- the next thing to land should be the thing that
  -- catches the eye.
  local function eta_color(secs)
    secs = secs or 0
    if secs <= 300 then return C.bright_green end   -- within 5 minutes
    if secs <= 1800 then return C.green end         -- within half an hour
    if secs <= 7200 then return C.yellow end        -- within two hours
    return C.dim
  end

  local rows = {}
  for _, p in ipairs(S.lpending) do
    local scol = SP_ANSI2[p.species] or C.white
    local bcol = SP_ANSI[p.bldg] or C.white
    rows[#rows + 1] = {
      scol .. (SP_DISP[p.species] or cc.cap_first(p.species or "?")) .. pagelib.RESET,
      C.dim .. breed_name(p.breed) .. pagelib.RESET,
      C.white .. "x" .. tostring(p.count or 0) .. pagelib.RESET,
      bcol .. cc.cap_first((p.bldg or ""):gsub("_", " ")) .. pagelib.RESET,
      eta_color(p.secs) .. cc.fmt_time(p.secs) .. pagelib.RESET,
    }
  end
  -- "To" widened 8 -> 9 so "Sheepfold" stops rendering as "Sheepfol"; the
  -- Arrives column is "*" and simply absorbs the extra column.
  for _, l in ipairs(pagelib.columns(width, {
    { title = "Species", w = 8 }, { title = "Breed", w = 12 },
    { title = "Count", w = 5 }, { title = "To", w = 9 },
    { title = "Arrives", w = "*" },
  }, rows)) do add(l) end
end

-- ---------------------------------------------------------------------------
-- Livestock Find (guild_viking.lua:10030-10098, gated show_stock_find)
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Column helpers for the listing blocks below.
--
-- string.format("%-14s") only PADS: a value wider than its column runs
-- straight through the next field, and every column after it on that row
-- loses its alignment ("Icelandic Settlement" is 20 characters against a
-- 14-wide breed column). pagelib.trunc pads AND truncates, and counts
-- visible cells rather than bytes, so a cell can carry colour.
-- ---------------------------------------------------------------------------
local function cell(text, w) return pagelib.trunc(tostring(text or ""), w) end

-- Size a column to the longest value it will actually show, clamped: one long
-- name should not be able to eat the row, and a short list should still line
-- up on a sensible minimum rather than hugging its widest entry.
local function fit_width(values, min_w, max_w)
  local w = min_w
  for _, v in ipairs(values) do
    local n = #tostring(v or "")
    if n > w then w = n end
  end
  if w > max_w then w = max_w end
  return w
end

local function find_lines(add, width)
  add(pagelib.header(width, "Livestock Find"))
  local lf = S.lfind or {}
  local posts, offers, auctions = lf.posts or {}, lf.offers or {}, lf.auctions or {}
  if #posts == 0 and #offers == 0 and #auctions == 0 then
    add(pagelib.trunc(C.dim .. "No postings, offers, or auctions - use 'vfind livestock post'" .. pagelib.RESET, width))
    return
  end

  if #posts > 0 then
    add(pagelib.trunc(C.dim .. "Posts" .. pagelib.RESET, width))
    for _, p in ipairs(posts) do
      local wants = p.trait and ("  wants " .. trait_label(p.trait)) or ""
      local state_tag = (p.state and p.state ~= "open") and ("  [" .. p.state .. "]") or ""
      add(pagelib.trunc(string.format("#%-3d %-10s Q%d+  max %dd  (%s T%d)%s%s",
        p.id or 0, SP_DISP[p.species] or p.species or "?", p.min_quality or 0,
        p.max_price or 0, p.bldg or "?", p.tier or 0, wants, state_tag), width))
    end
  end

  if #offers > 0 then
    add(pagelib.trunc(C.dim .. "Offers" .. pagelib.RESET, width))
    local breeds, prices = {}, {}
    for _, o in ipairs(offers) do
      breeds[#breeds + 1] = breed_name(o.breed)
      prices[#prices + 1] = (o.price or 0) .. "d"
    end
    local offer_bw = fit_width(breeds, 12, 20)
    local offer_pw = fit_width(prices, 5, 9)
    for _, o in ipairs(offers) do
      add(pagelib.trunc(table.concat({
        "#" .. cell(o.id or 0, 3),
        cell((o.count or 0) .. "x", 4),
        cell(breed_name(o.breed), offer_bw),
        "Q" .. cell(o.quality or 0, 2),
        pagelib.rjust((o.price or 0) .. "d", offer_pw),
        cc.fmt_time(o.secs) .. trait_tag(o.trait),
      }, " "), width))
      -- LEGACY draws this row in one flat dim colour (0x888888), unlike the
      -- per-letter rainbow used for My Herds and Market -- kept byte-faithful
      -- rather than upgraded to match those.
      add(pagelib.trunc(string.format("   %sH:%d F:%d Y:%d V:%d C:%d%s",
        C.dim, o.hard or 0, o.fert or 0, o.yield or 0, o.vigor or 0, o.con or 0,
        pagelib.RESET), width))
    end
  end

  if #auctions > 0 then
    add(pagelib.trunc(C.dim .. "Auctions" .. pagelib.RESET, width))
    local breeds, prices = {}, {}
    for _, a in ipairs(auctions) do
      breeds[#breeds + 1] = breed_name(a.breed)
      prices[#prices + 1] = math.max(a.reserve or 0, a.my_bid or 0) .. "d"
    end
    local auc_bw = fit_width(breeds, 12, 20)
    local auc_pw = fit_width(prices, 5, 9)
    for _, a in ipairs(auctions) do
      add(pagelib.trunc(table.concat({
        "#" .. cell(a.id or 0, 3),
        cell(SP_DISP[a.species] or a.species or "?", 10),
        cell(breed_name(a.breed), auc_bw),
        "Q" .. cell(a.quality or 0, 2),
        "reserve " .. pagelib.rjust((a.reserve or 0) .. "d", auc_pw),
        "bid " .. pagelib.rjust((a.my_bid or 0) .. "d", auc_pw),
        cc.fmt_time(a.secs) .. trait_tag(a.trait),
      }, " "), width))
    end
  end
end

-- ---------------------------------------------------------------------------
-- Market (guild_viking.lua:10100-10176, gated show_stock_market)
-- ---------------------------------------------------------------------------

local function market_lines(add, width)
  add(pagelib.header(width, "Market"))
  local lins = {}
  for lin in pairs(S.lmarket or {}) do lins[#lins + 1] = lin end
  table.sort(lins)
  if #lins == 0 then
    add(pagelib.trunc(C.dim .. "No listings" .. pagelib.RESET, width))
    return
  end
  -- One set of column widths for the WHOLE market, not per settlement: the
  -- listings read as one table down the page, so a breed that is wide under
  -- one hold has to move the column under every other hold too.
  local breeds, prices = {}, {}
  for _, lin in ipairs(lins) do
    for _, m in ipairs(S.lmarket[lin] or {}) do
      breeds[#breeds + 1] = breed_name(m.breed)
      prices[#prices + 1] = (m.price or 0) .. "d"
    end
  end
  local bw = fit_width(breeds, 12, 20)
  local pw = fit_width(prices, 5, 9)

  for _, lin in ipairs(lins) do
    local listings = S.lmarket[lin]
    if listings and #listings > 0 then
      add(pagelib.trunc(C.yellow .. (LIN_NAMES[lin] or ("Lineage " .. lin)) .. pagelib.RESET, width))
      for _, m in ipairs(listings) do
        add(pagelib.trunc(table.concat({
          C.dim .. "#" .. cell((m.idx or 0) + 1, 3) .. pagelib.RESET,
          (SP_ANSI2[m.species] or C.white) .. cell(SP_DISP[m.species] or m.species or "?", 10) .. pagelib.RESET,
          C.green .. cell(breed_name(m.breed), bw) .. pagelib.RESET,
          cell("x" .. (m.count or 0), 4),
          pagelib.rjust((m.price or 0) .. "d", pw) .. trait_tag(m.trait),
        }, " "), width))
        add(pagelib.trunc(string.format(
          "   %sH:%d%s %sF:%d%s %sY:%d%s %sV:%d%s %sC:%d%s",
          C.green, m.hard or 0, pagelib.RESET,
          C.magenta, m.fert or 0, pagelib.RESET,
          C.yellow, m.yield or 0, pagelib.RESET,
          C.cyan, m.vigor or 0, pagelib.RESET,
          C.red, m.con or 0, pagelib.RESET), width))
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Pens: every built livestock building, at cap or not (LEGACY explicitly
-- omits this from its miniwindow -- guild_viking.lua:10178; gated
-- show_stock_needs, whose key keeps its original name so a saved profile is
-- not silently reset by the rename)
-- ---------------------------------------------------------------------------

local function needs_lines(add, width)
  add(pagelib.header(width, "Pens"))
  if not S.lneeds or #S.lneeds == 0 then
    -- No rows now means no livestock BUILDING, not "nothing needed".
    add(pagelib.trunc(C.dim .. "No livestock buildings" .. pagelib.RESET, width))
    return
  end
  -- Every BUILT pen is listed, at cap or not. The server used to drop fully
  -- stocked species here, which made a pen at cap indistinguishable from a
  -- pen that had been wiped out -- both simply had no row. A roster answers
  -- "where are my pigs"; a filtered list cannot.
  --
  -- The shortfall is spelled out rather than left to be subtracted from
  -- "71/80", and a pen at cap says so, so the rows that want attention are
  -- the ones that stand out.
  local rows = {}
  for _, n in ipairs(S.lneeds) do
    local cur, cap = n.current or 0, n.cap or 0
    local short = cap - cur
    rows[#rows + 1] = {
      SP_DISP[n.species] or cc.cap_first(n.species or "?"),
      pagelib.pct_color(cur, cap > 0 and cap or 100) .. cur .. "/" .. cap .. pagelib.RESET,
      (short > 0) and (C.yellow .. "-" .. short .. pagelib.RESET)
        or (C.bright_green .. "full" .. pagelib.RESET),
    }
  end
  for _, l in ipairs(pagelib.columns(width, {
    { title = "Species", w = 12 }, { title = "Stock", w = 14 },
    { title = "Short", w = "*" },
  }, rows)) do add(l) end
end

function M.lines(width)
  width = width or 80
  local lines = {}
  local function add(s) lines[#lines + 1] = s end

  if page_opts.get("show_stock_herds") then herds_lines(add, width) end
  if page_opts.get("show_stock_queue") then queue_lines(add, width) end
  if page_opts.get("show_stock_feed") then feed_lines(add, width) end
  if page_opts.get("show_stock_pending") then pending_lines(add, width) end
  if page_opts.get("show_stock_find") then find_lines(add, width) end
  if page_opts.get("show_stock_market") then market_lines(add, width) end
  if page_opts.get("show_stock_needs") then needs_lines(add, width) end

  return lines
end

return M
