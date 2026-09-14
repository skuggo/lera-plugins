-- Builds page: LEGACY's draw_page4
-- (/home/simon/code/3s_scripts_old/lua/guild_viking.lua:9426-9746). Pure
-- builder: lines(width) -> array of ANSI strings, reading state.lua's S and
-- page_opts.lua only.
--
-- Section order/gates, read from the source (NOT the task brief's landmark
-- list -- see the task report): Construction (show_builds_construction,
-- state.pending_builds), Ship Upgrades (show_builds_upgrades AND
-- #state.ship_upgrades > 0, state.ship_upgrades), Damage (show_builds_damage
-- AND #state.bdmg > 0, state.bdmg), Hired Folk/Staff (show_builds_staff AND
-- #state.staff_list > 0, state.staff_list).
--
-- DISCREPANCY vs the brief: the brief's "upgrades" landmark named
-- cart_upgrades/ship_upgrades/route_builds together. draw_page4 (9426-9746)
-- only ever reads state.ship_upgrades -- cart_upgrades is drawn by
-- pages/trade.lua's Carts section (draw_page2's logistics block) and
-- route_builds by pages/city.lua's Trade Routes section (draw_page2's
-- settlement-after block), both already ported in Task 4. Source wins: this
-- page's Ship Upgrades section covers ship_upgrades only.
local pagelib = require("pagelib")
local state = require("state")
local page_opts = require("page_opts")
local cc = require("pages.city_common")

local S = state.S
local C = pagelib.C

local M = {}

-- ---------------------------------------------------------------------------
-- Building display-name lookup (guild_viking.lua:9375-9421) -- own local
-- copy, matching pages/city.lua's own local BLDG_LABELS: LEGACY defines this
-- once at file scope and every page function references it, but our page
-- modules are self-contained per the plan's page-purity/module-per-page
-- structure.
-- ---------------------------------------------------------------------------

local BLDG_NAMES = {
  warehouse = "Warehouse", trading_post = "Trading Post", dock = "Dock",
  courier_post = "Courier Post", beacon = "Beacon", shadow_house = "Shadow-House",
  training_yard = "Training Yard", lumber_yard = "Lumber Yard", smithy = "Smithy",
  tannery = "Tannery", fishery = "Fishery", farm = "Farm", apiary = "Apiary",
  longhouse = "Longhouse", garrison = "Garrison", palisade = "Palisade",
  watchtower = "Watchtower", mead_hall = "Mead Hall", thrall_pen = "Thrall Pen",
  muster_ground = "Muster Ground", settler_plots = "Settler Plots", well = "Well",
  mead_cellar = "Mead Cellar", salting_house = "Salting House", bakehouse = "Bakehouse",
  furriers_lodge = "Furrier's Lodge", mine = "Mine", smelter = "Smelter",
  weaponry = "Weaponry", armoury = "Armoury", goldsmith = "Goldsmith's Hall",
  skald_hall = "Skald's Hall", moat = "Moat", castle = "Castle",
  throne_room = "Throne Room", hiring_hall = "Hiring Hall", herbyrgi = "Levy Grounds",
  siege_workshop = "Siege Workshop", prison = "Prison",
}

local function bldg_display(id)
  if BLDG_NAMES[id] then return BLDG_NAMES[id] end
  return (tostring(id or ""):gsub("_", " "):gsub("(%a)([%w_']*)", function(a, b)
    return a:upper() .. b
  end))
end

-- One material row: good name/color, done/need counts, a 12-cell progress
-- bar -- identical layout to pages/trade.lua's own mat_row (same LEGACY
-- pattern repeated at guild_viking.lua:9496-9510/9569-9580, "used by page 2,
-- 4, 5" per the shared mat_pct_color comment at 7548). pagelib.pct_color
-- approximates LEGACY's 10-step MAT_GRAD (7550-7568), same as city_common's
-- cc.mat_color.
--
-- This also folds two things LEGACY draws separately -- its own fixed-color
-- qty number and a two-tone (filled-run/empty-run) progress bar -- into one
-- pct_color-driven run: the qty here is plain/uncolored, and the single
-- `color` value (pagelib.pct_color(done, need)) drives only the bar's fill,
-- so the done/need RATIO is carried entirely by the bar rather than split
-- across a separately-colored number and a ratio-independent bar tone.
-- Content fidelity over pixel fidelity, same precedent as the
-- veterancy-bar note in pages/army.lua.
-- The good name was %-padded but the done/need ratio was not, so the progress
-- bars slid with the number of digits -- "12/40" and "1200/4000" pushed the
-- bar to different columns on consecutive rows of the same project.
local MAT_GOOD_W  = 13
local MAT_RATIO_W = 12   -- "12000/15000"

local function mat_row(width, mg)
  local color = pagelib.pct_color(mg.done or 0, mg.need or 1)
  local ratio = string.format("%d/%d", mg.done or 0, mg.need or 0)
  return pagelib.trunc("  "
    .. pagelib.trunc(cc.good_color(mg.good) .. cc.good_label(mg.good)
                     .. pagelib.RESET, MAT_GOOD_W)
    .. pagelib.trunc(C.white .. ratio .. pagelib.RESET, MAT_RATIO_W)
    .. pagelib.bar(12, mg.done or 0, mg.need or 1, color), width)
end

-- ---------------------------------------------------------------------------
-- Construction (guild_viking.lua:9432-9520, gated show_builds_construction)
-- ---------------------------------------------------------------------------

local function construction_status(pb)
  local cas = pb.complete_at_secs or -1
  if cas < 0 then
    if (pb.mats_total or 0) > 0 then
      return string.format("Mats %d/%d", pb.mats_done or 0, pb.mats_total or 0),
        pagelib.pct_color(pb.mats_done or 0, pb.mats_total or 1)
    end
    return "Awaiting mats", C.cyan
  elseif cas == 0 then
    return "Finalizing...", C.bright_green
  else
    return cc.fmt_time(cas), C.white
  end
end

local function construction_lines(add, width)
  add(pagelib.header(width, "Construction"))
  local list = S.pending_builds or {}
  if #list == 0 then
    add(pagelib.trunc(C.dim .. "No active projects" .. pagelib.RESET, width))
    return
  end
  for _, pb in ipairs(list) do
    local status_text, status_color = construction_status(pb)
    -- Tier gets its own column too: "T1" and "T10" are different widths, so
    -- the status text moved between rows.
    add(pagelib.trunc(
      pagelib.trunc(C.white .. bldg_display(pb.bldg_id) .. pagelib.RESET, 18)
      .. pagelib.trunc(C.dim .. "T" .. tostring(pb.tier or 1) .. pagelib.RESET, 5)
      .. status_color .. status_text .. pagelib.RESET, width))

    if pb.mats and #pb.mats > 0 then
      -- Time-to-completion bar, only while the build clock is running and
      -- the total duration is known (guild_viking.lua:9483-9491).
      local cas = pb.complete_at_secs or -1
      if cas > 0 and (pb.total_build_secs or 0) > 0 then
        local elapsed = pb.total_build_secs - cas
        local pct = math.floor(elapsed / pb.total_build_secs * 100 + 0.5)
        add(pagelib.trunc(pagelib.bar(width - 6, elapsed, pb.total_build_secs, C.bright_cyan)
          .. " " .. pct .. "%", width))
      end
      for _, mg in ipairs(pb.mats) do
        add(mat_row(width, mg))
      end
    elseif (pb.complete_at_secs or -1) < 0 and (pb.mats_total or 0) > 0 then
      -- Fallback: no per-good detail, an aggregate mats bar
      -- (guild_viking.lua:9512-9517).
      add(pagelib.trunc(
        pagelib.bar(width - 4, pb.mats_done or 0, pb.mats_total or 1,
          pagelib.pct_color(pb.mats_done or 0, pb.mats_total or 1)), width))
    end
  end
end

-- ---------------------------------------------------------------------------
-- Ship Upgrades (guild_viking.lua:9522-9589, gated show_builds_upgrades AND
-- a non-empty list -- unlike Construction, LEGACY prints nothing at all when
-- there are no ship upgrades, not even a section header)
-- ---------------------------------------------------------------------------

local function upgrade_status(su)
  local sl = su.secs_left or -1
  if sl < 0 then
    if (su.mats_total or 0) > 0 then
      return string.format("Mats %d/%d", su.mats_done or 0, su.mats_total or 0),
        pagelib.pct_color(su.mats_done or 0, su.mats_total or 1)
    end
    return "Awaiting mats", C.cyan
  elseif sl == 0 then
    return "Finalizing...", C.bright_green
  else
    return cc.fmt_time(sl), C.white
  end
end

local function upgrades_lines(add, width)
  local list = S.ship_upgrades or {}
  if #list == 0 then return end
  add(pagelib.header(width, "Ship Upgrades"))
  for _, su in ipairs(list) do
    local tier_name = cc.SHIP_TIER_NAMES[su.tier] or ("T" .. tostring(su.tier))
    local status_text, status_color = upgrade_status(su)
    add(pagelib.trunc(string.format("%s%-14s%s -> %s  %s%s%s",
      C.white, su.name or "?", pagelib.RESET, tier_name,
      status_color, status_text, pagelib.RESET), width))

    if su.mats and #su.mats > 0 then
      for _, mg in ipairs(su.mats) do
        add(mat_row(width, mg))
      end
    elseif (su.secs_left or -1) < 0 and (su.mats_total or 0) > 0 then
      add(pagelib.trunc(
        pagelib.bar(width - 4, su.mats_done or 0, su.mats_total or 1,
          pagelib.pct_color(su.mats_done or 0, su.mats_total or 1)), width))
    end
  end
end

-- ---------------------------------------------------------------------------
-- Damage (guild_viking.lua:9591-9606, gated show_builds_damage AND a
-- non-empty list -- same "no header when empty" pattern as Ship Upgrades)
-- ---------------------------------------------------------------------------

local function damage_color(pct)
  if pct >= 60 then return C.bright_red end
  if pct >= 30 then return C.yellow end
  return C.bright_green
end

local function damage_lines(add, width)
  local list = S.bdmg or {}
  if #list == 0 then return end
  add(pagelib.header(width, "Damage"))
  for _, bd in ipairs(list) do
    local pct = bd.pct or 0
    add(pagelib.trunc(string.format("%s%-16s%s %s %d%%",
      C.white, bldg_display(bd.bldg_id), pagelib.RESET,
      pagelib.bar(12, pct, 100, damage_color(pct)), pct), width))
  end
end

-- ---------------------------------------------------------------------------
-- Hired Folk / Staff (guild_viking.lua:9608-9744, gated show_builds_staff
-- AND a non-empty list)
-- ---------------------------------------------------------------------------

local LOYALTY_LABELS = { "Wavering", "Uneasy", "Steady", "Loyal", "Devoted" }
local TRAIT_LABELS = {
  sea_dog = "Sea Dog", iron_will = "Iron Will", silver_tongue = "Silver Tongue",
  taskmaster = "Taskmaster", old_salt = "Old Salt", iron_grip = "Iron Grip",
  berserker = "Berserker", hoarder = "Hoarder", skald_bard = "Skald-Bard",
  longstrider = "Longstrider",
}
local STAT_ORDER = { "combat", "trade", "craft", "sea", "wild", "land", "charm" }
local STAT_ABBREV = { combat = "Cbt", trade = "Trd", craft = "Cft", sea = "Sea",
  wild = "Wld", land = "Lnd", charm = "Chm" }
local STAT_LABEL_ANSI = {
  combat = C.cyan, trade = C.green, craft = C.bright_cyan,
  sea = C.cyan, wild = C.green, land = C.yellow, charm = C.magenta,
}

-- BGR decode workbook (guild_viking.lua:301, 0xBBGGRR -- leftmost byte =
-- Blue, middle = Green, rightmost = Red; same convention as pages/goods.lua's
-- commit 9b6b7b6 workbook and pages/army.lua's comment):
--   0xFFCC00 ("Awaiting mats", construction_status/upgrade_status above;
--             building assignment, below)   -> R=00/G=CC/B=FF -> cyan-blue,
--             mapped to C.cyan
--   0x00CCFF (staff "Training" assignment, below) -> R=FF/G=CC/B=00 ->
--             gold, mapped to yellow (nearest pagelib.C hue)
--   0x4444FF (staff ship assignment, below)  -> R=FF/G=44/B=44 -> red
--   0x55FFFF (elder age / "En route", staff_lines below) -> R=FF/G=FF/B=55
--             -> yellow
-- Each was previously mapped by variable-name guess rather than decoded;
-- corrected below.

-- Ported from LEGACY's assignment branch (guild_viking.lua:9655-9677):
-- unassigned/training/a ship (resolved to its display name via
-- voyage_longships, falling back to state.ships)/otherwise a building id.
local function staff_assignment(sf)
  local asgn = sf.assigned_to or "0"
  if asgn == "0" or asgn == "" then
    return "Unassigned", C.dim
  elseif asgn == "training" then
    return "Training", C.yellow
  elseif asgn:sub(1, 5) == "ship_" then
    local ship_num = asgn:sub(6)
    local ships = (S.voyage_longships and #S.voyage_longships > 0) and S.voyage_longships or (S.ships or {})
    for _, sh in ipairs(ships) do
      if tostring(sh.ship_id) == ship_num then
        return sh.name, C.red
      end
    end
    return "Ship " .. ship_num, C.red
  else
    return bldg_display(asgn), C.cyan
  end
end

local function staff_lines(add, width)
  local list = S.staff_list or {}
  if #list == 0 then return end
  -- The roster is capped on the wire -- a full one does not fit a package's
  -- page budget -- so say so when it is. A partial list that reads as complete
  -- is the failure this whole mechanism exists to avoid: you would otherwise
  -- look at 28 of 64 staff and conclude the other 36 had wandered off.
  local total, shown = tonumber(S.staff_total) or 0, tonumber(S.staff_shown) or 0
  if total > 0 and shown > 0 and total > shown then
    add(pagelib.header(width, "Hired Folk (" .. shown .. " of " .. total .. ")"))
  else
    add(pagelib.header(width, "Hired Folk"))
  end
  for _, sf in ipairs(list) do
    add(pagelib.trunc(C.bright_green .. (sf.name or "?") .. pagelib.RESET, width))

    local asgn_text, asgn_color = staff_assignment(sf)
    local loy_label = LOYALTY_LABELS[tonumber(sf.loyalty) or 3] or "Steady"
    local age = sf.age or "veteran"
    local age_color = (age == "young") and C.bright_green
      or ((age == "elder") and C.yellow or C.white)
    add(pagelib.trunc(string.format("  %s%s%s  Loy:%s  Age: %s%s%s",
      asgn_color, asgn_text, pagelib.RESET, loy_label,
      age_color, cc.cap_first(age), pagelib.RESET), width))

    if sf.arrive_at and sf.arrive_at > os.time() then
      add(pagelib.trunc("  " .. C.yellow .. "En route (~" ..
        cc.fmt_time(sf.arrive_at - os.time()) .. ")" .. pagelib.RESET, width))
    end

    local trait = sf.trait or "0"
    local trait_known = trait ~= "0" and trait ~= ""
    local trait_text = trait_known and (TRAIT_LABELS[trait] or trait) or "None"
    add(pagelib.trunc("  " .. C.dim .. "Trt: " .. pagelib.RESET ..
      (trait_known and trait_text or (C.dim .. trait_text .. pagelib.RESET)), width))

    local stats = sf.stats or {}
    local skey = sf.stat_key or ""
    local parts = {}
    for _, sk in ipairs(STAT_ORDER) do
      local sv = stats[sk] or 0
      local prefix = (sk == skey) and "*" or ""
      parts[#parts + 1] = (STAT_LABEL_ANSI[sk] or C.dim) .. prefix .. STAT_ABBREV[sk] ..
        pagelib.RESET .. ":" .. sv
    end
    add(pagelib.trunc("  " .. table.concat(parts, " "), width))
  end
end

function M.lines(width)
  width = width or 80
  local lines = {}
  local function add(s) lines[#lines + 1] = s end

  if page_opts.get("show_builds_construction") then
    construction_lines(add, width)
  end

  if page_opts.get("show_builds_upgrades") then
    upgrades_lines(add, width)
  end

  if page_opts.get("show_builds_damage") then
    damage_lines(add, width)
  end

  if page_opts.get("show_builds_staff") then
    staff_lines(add, width)
  end

  return lines
end

return M
