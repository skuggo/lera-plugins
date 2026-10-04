-- guild_viking livestock page builder tests. Run from the lera-plugins repo
-- root with LERA_ROOT pointing at a built Lera checkout.
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

local S = require("state").S
local page_opts = require("page_opts")
local page = require("pages.livestock")
-- The page is a pure builder over `state` and `page_opts` (the spec's own
-- constraint). Its Feed section shares two figures with the Auto-Herd feed
-- guard, and it used to reach them by requiring autoherd -- so loading ANY
-- page loaded the whole spending planner. They live in market.lua now.
check("requiring the livestock page does not load the spending planner",
      package.loaded["autoherd"] == nil)

local function joined(width)
  return table.concat(page.lines(width or 80), "\n")
end

-- Colour-stripped view of the page. The Feed cases below assert on phrases
-- that span more than one colour run ("Covers: 8 ticks"), which no raw-string
-- search can match -- pagelib emits a reset between the label and the value.
local function plain(width)
  return (joined(width):gsub("\027%[[%d;]*m", ""))
end

-- Empty state: the page must still build, and must offer the discoverability
-- hint rather than LEGACY's obsolete "enable vtoggle mip_livestock" (GMCP
-- always sends these keys, so that hint would be a lie).
S.herds, S.lmarket, S.lneeds = {}, {}, {}
S.bqueue, S.lpending = {}, {}
S.lfind = { posts = {}, offers = {}, auctions = {} }
S.lfeed = { grain = 0, water = 0, head = 0 }
local empty = joined(80)
check("empty page builds", type(page.lines(80)) == "table")
check("empty page hints at vlivestock market",
      empty:find("vlivestock market", 1, true) ~= nil)
check("empty page does not mention mip_livestock",
      empty:find("mip_livestock", 1, true) == nil)

-- With a herd, the species label appears and head/cap is rendered.
S.buildings = { sheepfold = 2 }   -- tier 2 -> cap 14
S.herds = {
  sheepfold = { bldg = "sheepfold", head = 9, quality = 61, gen = 3,
                sterile = 0, hard = 40, fert = 55, yield = 70, vigor = 66,
                con = 50, breed = "nordic", hv = 1, trait = "prolific",
                age_ticks = 12 },
}
local withherd = joined(80)
check("herd shows its species label", withherd:find("Sheep", 1, true) ~= nil)
check("herd shows head against cap", withherd:find("9", 1, true) ~= nil
      and withherd:find("14", 1, true) ~= nil)
check("herd trait is named, not printed raw",
      withherd:find("Prolific", 1, true) ~= nil)

check("positive herd age is displayed", plain(100):find("Age:12", 1, true) ~= nil)
S.herds.sheepfold.age_ticks = 0
check("newborn average age is explicitly zero", plain(100):find("Age:0", 1, true) ~= nil)
S.herds.sheepfold.age_ticks = nil
check("missing age is unknown, not newborn", plain(100):find("Age:?", 1, true) ~= nil)
S.herds.sheepfold.age_ticks = 12

-- A section toggled off must vanish entirely.
page_opts.set("show_stock_herds", false)
check("herds section respects its toggle",
      joined(80):find("Sheep", 1, true) == nil)
page_opts.set("show_stock_herds", true)

-- Narrow width must not error and must not exceed the width.
local narrow = page.lines(40)
check("narrow width builds", type(narrow) == "table" and #narrow > 0)
local overlong = false
for _, l in ipairs(narrow) do
  if #(l:gsub("\027%[[%d;]*m", "")) > 40 then overlong = true end
end
check("no visible line exceeds the width", not overlong)

-- ---- Feed section (husbandry Task 4 fix round) -----------------------------
-- The old rendering divided the server's per-tick grain NEED (S.lfeed.grain,
-- from query_livestock_feed_needs) by a client re-derivation of the same
-- need (ceil(head / 8)) and labelled the quotient "Covers: N ticks" -- a
-- starvation runway it had no data for. The runway now comes from WAREHOUSE
-- grain stock, read through the same market.wh_amount_of the Auto-Herd feed
-- guard uses, and is omitted entirely when the WSTOCK feed has not arrived.
S.lfeed = { grain = 2, water = 2, head = 14 }
S.wstock, S.wstock_by_good = nil, nil
local feed_nowh = plain(80)
check("feed shows the server's per-tick figures as per-tick",
      feed_nowh:find("Per tick:", 1, true) ~= nil
        and feed_nowh:find("2 grain", 1, true) ~= nil
        and feed_nowh:find("2 water", 1, true) ~= nil, feed_nowh)
check("feed no longer labels a client re-derivation 'Draw'",
      feed_nowh:find("Draw:", 1, true) == nil)
check("no warehouse data -> the Covers line is omitted, not zeroed",
      feed_nowh:find("Covers", 1, true) == nil, feed_nowh)

-- Warehouse received: 99 grain against a 2/tick draw is 49 ticks.
S.wstock_by_good = { grain = { good = "grain", amount = 99 } }
S.wstock = { { good = "grain", amount = 99 } }
local feed_wh = plain(80)
check("warehouse stock drives the Covers figure",
      feed_wh:find("Covers: 49 ticks", 1, true) ~= nil, feed_wh)
check("the Covers line names the stock it divided",
      feed_wh:find("99 grain in the warehouse", 1, true) ~= nil, feed_wh)

-- Singular, and the array fallback (by_good present but missing the good).
S.wstock_by_good = {}
S.wstock = { { good = "grain", amount = 2 } }
check("Covers reads the wstock array when by_good lacks the good",
      plain(80):find("Covers: 1 tick ", 1, true) ~= nil, plain(80))

-- A received-but-empty warehouse is a true 0, not the old fabricated one.
S.wstock_by_good = {}
S.wstock = {}
check("an empty warehouse that HAS been received reports 0 ticks",
      plain(80):find("Covers: 0 ticks (0 grain in the warehouse)", 1, true)
        ~= nil, plain(80))

-- The page and the planner must answer both questions from the same code.
local mk = require("market")
S.wstock_by_good = { grain = { good = "grain", amount = 40 } }
S.wstock = { { good = "grain", amount = 40 } }
check("page and planner read the same warehouse figure",
      mk.wh_amount_of("grain") == 40)
check("page and planner read the same per-tick draw",
      mk.feed_draw(14) == 2, mk.feed_draw(14))
-- The server's own figure wins over the ceil(head / 8) fallback...
S.lfeed = { grain = 5, water = 5, head = 14 }
check("the server's per-tick figure is preferred over ceil(head / 8)",
      mk.feed_draw(14) == 5, mk.feed_draw(14))
check("the page shows that same preferred figure",
      plain(80):find("Per tick: 5 grain", 1, true) ~= nil, plain(80))
check("Covers uses the preferred figure too (40 / 5 = 8)",
      plain(80):find("Covers: 8 ticks", 1, true) ~= nil, plain(80))
-- ...and the fallback only applies before the LFEED key has arrived.
S.lfeed = {}
check("with no LFEED key the draw falls back to ceil(head / 8)",
      mk.feed_draw(14) == 2, mk.feed_draw(14))
check("with no LFEED key the Feed section says there is no head",
      plain(80):find("No head to feed", 1, true) ~= nil)

-- The section still respects its own toggle.
S.lfeed = { grain = 2, water = 2, head = 14 }
page_opts.set("show_stock_feed", false)
check("feed section respects its toggle",
      plain(80):find("Per tick:", 1, true) == nil)
page_opts.set("show_stock_feed", true)

require("handlers.livestock")._gmcp.HERDS({ { bldg = "stable", head = 9,
  management = "20;2;9;9;0;0;4050;825;5001,5025,5100,5200,5300,5400" } })
local compact = plain(140)
check("management cap overrides mirrored tier", compact:find("9/20", 1, true) ~= nil)
check("fractional herd stats and generation visible", compact:find("H:50.01", 1, true)
  and compact:find("Gen:8.25", 1, true))
check("fractional age visible", compact:find("Age:40.50", 1, true) ~= nil)
check("concise pen safety metadata visible", compact:find("Penfree:9  Pending:2  Protected:9  Auto-cull:off", 1, true) ~= nil)
for _, line in ipairs(page.lines(40)) do
  check("compact page stays within narrow width", #(line:gsub("\027%[[%d;]*m", "")) <= 40)
end

-- ---- Market columns --------------------------------------------------------
-- A breed name wider than its column used to shove every field after it along
-- the row ("Icelandic Settlement" is 20 characters against a 14-wide column),
-- so a market listing under one hold did not line up with the listing under
-- the next. The columns are sized to the widest value actually shown, and
-- every row is padded AND truncated to them.
do
  local w = require("handlers.livestock")._gmcp
  S.lmarket = {}
  w.LMARKET({
    lmarket_8 = {
      { lin = 8, idx = 0, species = "horse", breed = "fjord", count = 3,
        price = 2577, hard = 61, fert = 6, yield = 30, vigor = 56, con = 54 },
      { lin = 8, idx = 1, species = "cattle", breed = "icelandic_cattle", count = 1,
        price = 560, hard = 58, fert = 25, yield = 43, vigor = 66, con = 50 },
      { lin = 8, idx = 2, species = "cattle", breed = "icelandic_cattle", count = 3,
        price = 1479, hard = 44, fert = 40, yield = 69, vigor = 45, con = 38 },
    },
  })
  page_opts.set("show_stock_market", true)

  local rows = {}
  for _, line in ipairs(page.lines(120)) do
    local flat = (line:gsub("\027%[[%d;]*m", ""))
    if flat:match("^#%d") then rows[#rows + 1] = flat end
  end
  check("every market listing renders a row", #rows == 3, #rows)

  -- The count field is the one right after the breed: if the wide breed still
  -- pushed, these would not agree.
  local at = {}
  for i, row in ipairs(rows) do at[i] = row:find("x%d") end
  check("the count column starts at the same place on every row",
        at[1] and at[1] == at[2] and at[2] == at[3], table.concat({tostring(at[1]),
        tostring(at[2]), tostring(at[3])}, "/"))

  -- Prices stack on their digits rather than their first character, so a
  -- four-digit price does not shift a three-digit one.
  local ends = {}
  for i, row in ipairs(rows) do ends[i] = select(2, row:find("%d+d")) end
  check("prices right-align on the same column",
        ends[1] and ends[1] == ends[2] and ends[2] == ends[3],
        table.concat({tostring(ends[1]), tostring(ends[2]), tostring(ends[3])}, "/"))

  check("the wide breed is not cut off",
        table.concat(rows, "\n"):find("Icelandic Settlement", 1, true) ~= nil,
        rows[2])

  for _, line in ipairs(page.lines(80)) do
    check("market row stays inside the page width: " .. line:sub(1, 12),
          #(line:gsub("\027%[[%d;]*m", "")) <= 80)
  end
end

-- ---- Management row colours ------------------------------------------------
-- Penfree/Pending/Protected/Auto-cull is a row of numbers you act on, and it
-- rendered as one undifferentiated grey run. A pen with NO free space is the
-- state that silently stops a herd growing, so it is the one called out.
do
  -- free must equal cap - head - pending or the handler rejects the record.
  require("handlers.livestock")._gmcp.HERDS({ { bldg = "byre", head = 17,
    management = "20;3;0;0;0;0;4050;825;5001,5025,5100,5200,5300,5400" } })
  local line
  for _, l in ipairs(page.lines(120)) do
    if l:find("Penfree", 1, true) then line = l end
  end
  check("the management row is rendered", line ~= nil)
  if line then
    check("a full pen is called out in red",
          line:find("\027%[91mPenfree") == nil
          and line:find("Penfree:\027%[0m\027%[91m0") ~= nil, line)
    check("counts above zero are coloured, not dim",
          line:find("\027%[36m3") ~= nil, line)
    check("a zero count stays dim", line:find("\027%[90m0") ~= nil, line)
    check("the labels themselves stay dim", line:find("\027%[90mPending:") ~= nil, line)
    check("and the labels are in proper case",
          line:find("Pending:", 1, true) and line:find("Protected:", 1, true)
          and line:find("Auto-cull:", 1, true) and line:find("pending:", 1, true) == nil, line)
  end
end

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
-- ---- Pens table ------------------------------------------------------------
-- Every BUILT pen is listed, at cap or not. The server used to drop fully
-- stocked species, which made a pen at cap indistinguishable from a pen that
-- had been wiped out -- both simply had no row, and "where are my pigs" had no
-- answer. The at-cap row is the case this exists for, so it is asserted first.
do
  S.lneeds = {
    { species = "sheep", current = 71, cap = 80 },
    { species = "horses", current = 39, cap = 40 },
    { species = "pigs", current = 40, cap = 40 },
  }
  page_opts.set("show_stock_needs", true)
  local text = plain(80)
  check("pens: a species at cap is still listed", text:find("Pigs", 1, true) ~= nil, text)
  check("pens: an at-cap row reads full rather than showing a shortfall",
        text:find("40/40", 1, true) ~= nil and text:find("full", 1, true) ~= nil, text)
  check("pens: the shortfall is shown rather than left to be subtracted",
        text:find("-9", 1, true) ~= nil and text:find("-1", 1, true) ~= nil, text)
  check("pens: the section is not titled as an inventory of current/cap",
        text:find("Current/Cap", 1, true) == nil, text)
  -- An empty table now means no livestock BUILDING, not "nothing needed", and
  -- must not read as the latter.
  S.lneeds = {}
  check("pens: the empty state names the real reason",
        plain(80):find("No livestock buildings", 1, true) ~= nil, plain(80))
end

print("all livestock page cases passed")
