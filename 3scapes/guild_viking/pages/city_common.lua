-- Shared formatting helpers, originally for pages/city.lua and
-- pages/trade.lua -- the two modes of LEGACY's draw_page2(y, mode)
-- (/home/simon/code/3s_scripts_old/lua/guild_viking.lua:7573-9114) -- and now
-- also required by pages/farm.lua and pages/builds.lua (Task 5), which need
-- the same fmt_time/good_label/good_color/cap_first helpers LEGACY defines
-- once at file scope.
--
-- This module exists because several page modules need the same small set
-- of formatting helpers LEGACY defined once at file scope, not because
-- draw_page2 shares SECTION BUILDERS between its city and trade branches --
-- it doesn't; every section in the source is drawn from exactly one of the
-- three mode-gated blocks (see the task report's classification table).
-- Pure module: no ui.*/state access, same contract as pagelib.
local pagelib = require("pagelib")
local C = pagelib.C

local M = {}

-- Ported from LEGACY's fmt_time (guild_viking.lua:7431-7448). Identical to
-- the private copy in pages/stats.lua; duplicated rather than factored into
-- pagelib because pagelib is Task 1's frozen interface list and this is the
-- one pair of pages that happens to need it too.
function M.fmt_time(secs)
  secs = secs or 0
  if secs <= 0 then return "ready" end
  if secs < 60 then return secs .. "s" end
  if secs < 86400 then
    if secs < 3600 then
      local m = math.floor(secs / 60)
      local s = secs % 60
      return s > 0 and (m .. "m" .. s .. "s") or (m .. "m")
    end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    return m > 0 and (h .. "h" .. m .. "m") or (h .. "h")
  end
  local d = math.floor(secs / 86400)
  local h = math.floor((secs % 86400) / 3600)
  return h > 0 and (d .. "d" .. h .. "h") or (d .. "d")
end

-- Ported from LEGACY's GOOD_LABELS/good_label (guild_viking.lua:7504-7520):
-- proper display names, falling back to a title-cased id (memoized, same as
-- LEGACY) for anything not listed.
local GOOD_LABELS = {
  timber = "Timber", ore = "Ore", iron = "Iron", furs = "Furs", fish = "Fish",
  grain = "Grain", mead = "Mead", sunstone = "Sunstone", runestones = "Runestones",
  spoils = "Spoils", salted_fish = "Salted Fish", bread = "Bread",
  fine_furs = "Fine Furs", tools = "Tools", gemstones = "Gemstones",
  honey = "Honey", weapons = "Weapons", armour = "Armour", finery = "Finery",
  food = "Food", water = "Water",
}
function M.good_label(g)
  if not g then return "" end
  local label = GOOD_LABELS[g]
  if label then return label end
  label = (tostring(g):gsub("_", " "):gsub("%S+", function(w)
    return w:sub(1, 1):upper() .. w:sub(2):lower() end))
  GOOD_LABELS[g] = label
  return label
end

-- Ported from LEGACY's GOOD_COLORS (guild_viking.lua:7477-7500), mapped by
-- intent from BGR hex onto pagelib's ANSI 16-color table -- per the plan's
-- Global Constraints, exact hex fidelity is NOT required.
--
-- Final-review BGR decode workbook (guild_viking.lua:301, 0xBBGGRR):
--   finery 0x44DDFF -> R=FF/G=DD/B=44 -> gold, mapped to yellow (nearest
--     pagelib.C hue) -- was guessed at bright_cyan by variable-name alone.
-- Ported from LEGACY's GOOD_COLORS (guild_viking.lua:8542), but ALLOCATED
-- rather than transcribed. Two reasons the literal hex values could not be
-- used: pagelib's ANSI table has 15 colours for 32 goods, and LEGACY itself
-- was ambiguous (beef and mutton shared 0x4444AA, and seven goods sat in one
-- yellow band) which made the Warehouse unreadable at a glance.
--
-- Allocation rule: each good keeps its hue family, and within a family the
-- shades are spread so no colour carries more than three goods. The six meats
-- are guaranteed mutually distinct -- they are the set most often read side by
-- side in the Warehouse and livestock lists.
--
-- If you add a good, pick the free shade in its hue family; do not collapse it
-- onto a neighbour just because the hex looked close in LEGACY.
local GOOD_COLORS = {
  -- Raw goods
  timber = C.green,
  ore = C.dim,
  iron = C.cyan,
  grain = C.yellow,
  furs = C.red,
  fish = C.bright_cyan,
  mead = C.magenta,
  sunstone = C.bright_yellow,
  runestones = C.white,
  spoils = C.red,
  honey = C.bright_yellow,
  -- Refined goods
  salted_fish = C.bright_blue,
  bread = C.yellow,
  fine_furs = C.bright_red,
  tools = C.dim,
  gemstones = C.bright_magenta,
  weapons = C.bright_white,
  armour = C.bright_cyan,
  finery = C.bright_yellow,
  -- Husbandry / animal products (mutually distinct)
  wool = C.bright_blue,
  eggs = C.bright_white,
  milk = C.white,
  cheese = C.yellow,
  cloth = C.cyan,
  pork = C.bright_red,
  beef = C.red,
  mutton = C.magenta,
  horsemeat = C.bright_magenta,
  poultry = C.bright_white,
  smoked_meat = C.dim,
  -- Generic
  food = C.bright_green,
  water = C.blue,
}
function M.good_color(g)
  return GOOD_COLORS[g] or C.white
end

-- Ported from LEGACY's cart_refit_label (guild_viking.lua:244-248).
function M.cart_refit_label(refit)
  if refit == "speed" then return "Raider" end
  if refit == "heavy" then return "Freighter" end
  return "Standard"
end

-- Cart tier names, ported from the identical inline tables repeated in
-- LEGACY's Carts and Idle Carts blocks (guild_viking.lua:7951-7952,
-- 8003-8004). Colors approximate LEGACY's "higher tier looks fancier" intent
-- (grey -> white -> yellow -> cyan -> bright cyan) rather than its literal
-- BGR values.
M.CART_TIER_NAMES = { [1] = "Basic", [2] = "Reinforced", [3] = "Heavy", [4] = "Armored", [5] = "War-cart" }
-- The ladder reads the same for anything tiered 1-5, so housing plots take
-- it too rather than inventing a second five-colour scale for the same idea.
local TIER_ANSI = { [1] = C.dim, [2] = C.white, [3] = C.yellow, [4] = C.cyan, [5] = C.bright_cyan }
function M.tier_color(tier)
  return TIER_ANSI[tier] or C.dim
end
function M.cart_tier_color(tier)
  return M.tier_color(tier)
end

-- Max horses per cart tier -- ported from world/trade_goods.h's
-- CART_MAX_HORSES_T1..T5 (1/2/3/4/6). A pure function of tier, unlike cap
-- (which also folds in Kartfar skill and per-cart cargo multipliers), so
-- there's no need for the server to send it over GMCP -- tier is already
-- part of every cart record.
M.CART_MAX_HORSES = { [1] = 1, [2] = 2, [3] = 3, [4] = 4, [5] = 6 }

-- Ported from LEGACY's CREW_MAX / SHIP_TIER_NAMES (guild_viking.lua:7542-7545).
M.CREW_MAX = { [1] = 5, [2] = 10, [3] = 20, [4] = 35, [5] = 60 }
M.SHIP_TIER_NAMES = { [1] = "Longship", [2] = "Dragonship", [3] = "Drakkar", [4] = "Skeid", [5] = "Busse" }

-- Durability/quality-by-percent and mats-done/needed color: LEGACY has two
-- separate gradients here (a 3-tier one for hull/cart durability at
-- guild_viking.lua:7754/8009/etc, and a 10-step MAT_GRAD for material
-- progress at 7550-7568). Both are "higher ratio = greener" with no other
-- difference in intent, so both reuse pagelib's 5-tier pct_color -- same
-- polarity, coarser banding, no hex fidelity required.
M.dur_color = pagelib.pct_color
M.mat_color = pagelib.pct_color

-- Perishable-goods quality/freshness banding -- ported from the IDENTICAL
-- threshold sets LEGACY repeats twice: once for cart cargo quality_pct
-- (guild_viking.lua:7894-7943, sell-mode carts) and once for warehouse
-- wstock freshness_pct (guild_viking.lua:8388-8408). Both use the same four
-- cutoffs (100/90/78/62) and the same two label sets (mead ages UP:
-- aged/well-aged/maturing/young/green; everything else ages DOWN:
-- fresh/slightly stale/stale/old/very old) -- folded into one helper here.
local PERISHABLES = { fish = true, mead = true, grain = true, honey = true }
function M.is_perishable(good)
  return PERISHABLES[good] == true
end

function M.quality_label(good, pct)
  pct = pct or 100
  if good == "mead" then
    if pct >= 100 then return "aged", C.magenta end
    if pct >= 90 then return "well-aged", C.magenta end
    if pct >= 78 then return "maturing", C.magenta end
    if pct >= 62 then return "young", C.magenta end
    return "green", C.green
  end
  -- 0x00FFFF ("slightly stale") -> R=FF/G=FF/B=00 -> yellow, not cyan --
  -- this now shares C.yellow with the "stale" tier just below (its own
  -- literal decodes to yellow too); the decode wins over keeping the two
  -- tiers visually distinct, per the sweep's ruling.
  if pct >= 100 then return "fresh", C.bright_green end
  if pct >= 90 then return "slightly stale", C.yellow end
  if pct >= 78 then return "stale", C.yellow end
  if pct >= 62 then return "old", C.red end
  return "very old", C.bright_red
end

-- Title-case each word -- ported from the Raids-section-local `tcase`
-- helper (guild_viking.lua:7775-7777), used for raid/target town names.
-- Proper case for a PLACE name. tcase() capitalises every word, which reads
-- wrong on the war board's names ("The Old Fort At Kaldheim"); the small
-- connecting words stay lower unless they open the name.
local PCASE_SMALL = { ["of"] = true, ["at"] = true, ["the"] = true,
                      ["in"] = true, ["on"] = true, ["and"] = true,
                      ["by"] = true, ["under"] = true }
function M.pcase(s)
  local first = true
  return (tostring(s or ""):gsub("(%a)([%w']*)", function(a, b)
    local word = (a .. b):lower()
    if not first and PCASE_SMALL[word] then first = false; return word end
    first = false
    return a:upper() .. b:lower()
  end))
end

function M.tcase(s)
  return (tostring(s or ""):gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b:lower() end))
end

-- Capitalize just the first letter -- ported from draw_page2's own
-- module-level `cap_first` helper (guild_viking.lua:7580-7583), used by the
-- Market Orders / Incoming Fills sections for buyer/seller/good names.
function M.cap_first(s)
  s = tostring(s or "")
  return (s:gsub("^%l", string.upper))
end

return M
