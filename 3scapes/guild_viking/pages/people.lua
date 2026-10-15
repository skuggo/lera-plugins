-- People page: LEGACY's draw_page5
-- (/home/simon/code/3s_scripts_old/lua/guild_viking.lua:9748-10663). Pure
-- builder: lines(width) -> array of ANSI strings, reading state.lua's S and
-- page_opts.lua only.
--
-- Section order/gates, read from the source top to bottom:
--   Settlers (show_people_settlers, 9832-10152) -- population/tax/water,
--     edict, housing, upkeep, jobs, six settler_* metric bars, sentiment,
--     a NESTED Designations subsection (show_people_designations AND
--     (#settler_roles > 0 OR settler_commoner > 0), 9902-9967), flourishing,
--     community net/mood mult, civic buildings, stock levels, consumption,
--     supply/pop tick timers, actions, projects, and a "no settlers yet"
--     fallback when settlers == 0.
--   Biome Patrol (10154-10160) -- UNGATED: no page_opts key at all in
--     LEGACY, shown whenever state.patrol.count > 0. Source wins over the
--     task brief's landmark list, which didn't name this section.
--   Garrison (show_people_garrison, 10163-10342) -- stationed/free/total,
--     def power, the named-hirdmadr table (state.hird_list), and a
--     Varangian Guards subsection that is UNCONDITIONAL on its own (always
--     drawn once the Garrison gate is open -- LEGACY's `end -- show_people_
--     garrison` comment lands AFTER it, at 10342).
--   Incoming Raids (show_people_raids, 10345-10389).
--   Thralls (show_people_thralls AND (state.thralls > 0 OR
--     state.thrall_follower_level > 0), 10392-10497) -- held/working counts,
--     a per-building assignment table, and a NESTED Companion subsection
--     (show_people_thrall_companion AND thrall_follower_level > 0).
--   Missions (show_people_missions, 10500-10661) -- mission/errand period
--     counters, the accepted-missions list, and the newbie errand.
--
-- Disclosed simplifications (Global Constraints: content fidelity, not
-- pixel fidelity):
--   - Metric bars (settler_mood/housing_quality/sustenance/emp_score/
--     security/dignity) and the Designations role bars reuse
--     `pagelib.pct_color`'s 5-tier gradient instead of LEGACY's bespoke
--     2-cutoff 3-tier one (>=70/>=40/else) -- same polarity (green=good,
--     red=bad), coarser/finer banding, matching city_common.lua's precedent
--     for dur/mat coloring.
--   - Settler Projects' status text/color (Awaiting mats / Finalizing... /
--     time remaining) mirrors pages/builds.lua's `construction_status`
--     convention verbatim rather than LEGACY's own (inconsistent-with-its-
--     neighbors) hex choices, so the same semantic state reads the same way
--     on both pages.
--   - The "Run There" button on each mission/errand row (10538-10558,
--     10609-10631) IS ported (Task 6), through window.lua's new page-level
--     pointer seam (see that module's header comment) -- superseding a
--     stage-2 disposition that dropped it as "no pane equivalent yet".
--     `has_sufficient_goods` (MAIN 4817-4839, verbatim below) gates the
--     MISSION button's enabled/disabled appearance exactly as LEGACY gates
--     its hotspot registration; the errand button has no such gate (LEGACY
--     hard-codes `can_travel = true` for it, MAIN 10608) so it always
--     renders enabled. See the "Missions" section below for the full
--     hotspot -> port table, verbatim command strings, and the BGR
--     workbook for both button appearances.
--   - Known limitation (pre-existing structure, not introduced by Task 6):
--     `/vik pop people` opens this page through popups.lua's
--     `popups.open_page`, which wraps `mod.lines` with `on_pointer = nil`
--     (popups.lua's own `open_page`, its "no on_pointer -- a pane page has
--     none of its own" comment). The Run There buttons still RENDER there
--     (their text rows are unconditional, per `M.lines` above) but are not
--     clickable in that detached view -- only window.lua's own pane
--     dispatch (the "Task 6 seam") consumes a page's second `lines(width)`
--     return value at all.
--   - `want_goods`/mat_detail are Lua tables iterated with `pairs()` in
--     LEGACY too (so LEGACY's own on-screen order isn't guaranteed either);
--     this port sorts keys for deterministic, testable output.
--   - MUSHclient colors in this source range are 0xBBGGRR (guild_viking.lua
--     line 301); every mapping below was decoded byte-by-byte (not read as
--     literal RRGGBB) before choosing a pagelib.C entry -- e.g. 0x0000CC
--     decodes to R=CC,G=00,B=00 (red), not blue.
local pagelib = require("pagelib")
local state = require("state")
local page_opts = require("page_opts")
local cc = require("pages.city_common")
local pathfinding = require("pathfinding")
local map = require("popups.map")

local S = state.S
local C = pagelib.C

local M = {}

-- ---------------------------------------------------------------------------
-- Shared helpers -- own local copy per page module (matches pages/builds.lua's
-- own local BLDG_NAMES/bldg_display, per that page's self-containment note).
-- ---------------------------------------------------------------------------

local BLDG_NAMES = {
  warehouse = "Warehouse", trading_post = "Trading Post", dock = "Dock",
  courier_post = "Courier Post", beacon = "Beacon", shadow_house = "Shadow-House",
  training_yard = "Training Yard", lumber_yard = "Lumber Yard", smithy = "Smithy",
  tannery = "Tannery", fishery = "Fishery", farm = "Farm", apiary = "Apiary",
  longhouse = "Longhouse", garrison = "Garrison", palisade = "Palisade",
  watchtower = "Watchtower", mead_hall = "Mead Hall", thrall_pen = "Thrall Pen",
  muster_ground = "Muster Ground", settler_plots = "Settler Plots", well = "Well", matbur = "Matbur",
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

local function sorted_keys(t)
  local keys = {}
  for k, _ in pairs(t or {}) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

-- ---------------------------------------------------------------------------
-- Settlers (guild_viking.lua:9832-10152, gated show_people_settlers)
-- ---------------------------------------------------------------------------

-- Ported from LEGACY's inline tax_label (guild_viking.lua:9762-9765).
local TAX_LABELS = { [0] = "No Tax", [1] = "Light", [2] = "Moderate", [3] = "Heavy", [4] = "Crushing" }
local function tax_label(v)
  return TAX_LABELS[v] or ("Level " .. tostring(v or 0))
end

-- Ported from LEGACY's inline edict_label (guild_viking.lua:9766-9769).
local EDICT_LABELS = {
  feast = "Festival Feast", workdrive = "Work Drive",
  levy = "Emergency Levy", open_gates = "Open Gates",
}
local function edict_label(id)
  if EDICT_LABELS[id] then return EDICT_LABELS[id] end
  if id and id ~= "" then return bldg_display(id) end
  return "None"
end

local function stock_total(good)
  local total = 0
  for _, rec in ipairs(S.wstock or {}) do
    if rec.good == good then total = total + (tonumber(rec.amount) or 0) end
  end
  return total
end

-- Ported from LEGACY's draw_metric_bar (guild_viking.lua:9822-9830): a
-- label + text bar + percent. Color reuses pagelib.pct_color's 5-tier
-- gradient in place of LEGACY's bespoke >=70/>=40/else 3-tier one -- see
-- the module header's disclosed-simplifications note.
local function metric_bar_line(width, label, pct)
  local p = math.max(0, math.min(100, tonumber(pct) or 0))
  return pagelib.trunc(string.format("%-14s%s %d%%",
    label .. ":", pagelib.bar(20, p, 100, pagelib.pct_color(p, 100)), p), width)
end

-- ---- Designations (guild_viking.lua:9901-9967, nested inside Settlers, ---
-- gated show_people_designations AND (#settler_roles > 0 OR
-- settler_commoner > 0)) ------------------------------------------------

-- Proper-case role effect codes matching the in-game vsettler display
-- (guild_viking.lua:9913-9917).
local ROLE_EFF_LABEL = {
  smidir = "Bld", verkamenn = "Raw", handverkarar = "Ref",
  kaupmenn = "Sel", boendr = "Food", leidangr = "Def",
  vitkar = "Wrd", hasetar = "Voy",
}
-- Which effects are a percentage (guild_viking.lua:9919-9920).
local ROLE_EFF_PCT = {
  smidir = true, verkamenn = true, handverkarar = true, kaupmenn = true, hasetar = true,
}
-- Builders and Rowers give a cost/time REDUCTION; every other role a gain
-- (guild_viking.lua:9921-9923).
local ROLE_EFF_NEG = { smidir = true, hasetar = true }

local function role_row(width, label, pct, tgt, eff_text, eff_color, muted)
  local p = math.max(0, math.min(100, tonumber(pct) or 0))
  local bar_color = muted and C.dim or pagelib.pct_color(p, 100)
  local out = string.format("%s%-11s%s %s %d%%",
    muted and C.dim or C.white, label, pagelib.RESET, pagelib.bar(14, p, 100, bar_color), p)
  if tgt and tgt ~= p then
    local rising = tgt > p
    out = out .. string.format(" %s%s%d%%%s",
      rising and C.bright_green or C.cyan, rising and ">>" or "<<", tgt, pagelib.RESET)
  end
  if eff_text and eff_text ~= "" then
    out = out .. "  " .. (eff_color or C.dim) .. eff_text .. pagelib.RESET
  end
  return pagelib.trunc(out, width)
end

local function designations_lines(add, width)
  add(pagelib.header(width, "Designations"))
  if S.settler_identity and S.settler_identity ~= "" then
    add(pagelib.kv(width, "Identity:", S.settler_identity, C.yellow))
  end
  for _, r in ipairs(S.settler_roles or {}) do
    if (r.cur or 0) > 0 or (r.tgt or 0) > 0 then
      local eff_text, eff_color = "", C.dim
      if (r.bonus or 0) > 0 then
        local neg = ROLE_EFF_NEG[r.key]
        local pct_suffix = ROLE_EFF_PCT[r.key] and "%" or ""
        eff_text = string.format("%s%d%s %s", neg and "-" or "+", r.bonus, pct_suffix,
          ROLE_EFF_LABEL[r.key] or "")
        -- LEGACY's own legend text (below) calls the reduction color "red";
        -- its literal hex (0xCC5555) actually decodes blue -- the legend's
        -- documented intent wins per the module header's BGR note.
        eff_color = neg and C.red or C.bright_green
      end
      add(role_row(width, r.label, r.cur or 0, r.tgt, eff_text, eff_color, false))
    end
  end
  if (S.settler_commoner or 0) > 0 then
    add(role_row(width, "Commoners", S.settler_commoner, nil, "idle", C.dim, true))
  end
  add(pagelib.trunc(C.dim .. "green +gain    red -cost/time" .. pagelib.RESET, width))
end

-- ---- Settler Projects (guild_viking.lua:10064-10146) ---------------------

-- Mirrors pages/builds.lua's construction_status convention (Awaiting mats /
-- Finalizing... / time remaining) -- see the module header's disclosed
-- simplification note.
local function project_status(pr)
  local sl = pr.secs_left or -1
  if sl < 0 then
    if (pr.mats_total or 0) > 0 then
      return string.format("Mats %d/%d", pr.mats_done or 0, pr.mats_total or 0),
        pagelib.pct_color(pr.mats_done or 0, pr.mats_total or 1)
    end
    return "Awaiting mats", C.yellow
  elseif sl == 0 then
    return "Finalizing...", C.bright_green
  else
    return cc.fmt_time(sl), C.white
  end
end

local function projects_lines(add, width)
  for _, pr in ipairs(S.settler_projects or {}) do
    local name = bldg_display(pr.id or "")
    local label
    if pr.kind == "housing_upgrade" then
      label = string.format("%s T%d -> T%d", name, pr.from_tier or 0, pr.to_tier or 0)
    else
      label = string.format("%s T%d", name, pr.to_tier or 0)
    end
    local status_text, status_color = project_status(pr)
    add(pagelib.trunc(string.format("%s%s%s  %s%s%s",
      C.white, label, pagelib.RESET, status_color, status_text, pagelib.RESET), width))

    if (pr.daler or 0) > 0 then
      add(pagelib.trunc("  " .. C.yellow .. "Cost: " .. pr.daler .. " daler" .. pagelib.RESET, width))
    end

    if pr.mat_detail and next(pr.mat_detail) then
      for _, gname in ipairs(sorted_keys(pr.mat_detail)) do
        local mg = pr.mat_detail[gname]
        local color = pagelib.pct_color(mg.have or 0, mg.need or 1)
        add(pagelib.trunc(string.format("    %s%-12s%s %d/%d %s",
          cc.good_color(gname), cc.good_label(gname), pagelib.RESET,
          mg.have or 0, mg.need or 0, pagelib.bar(12, mg.have or 0, mg.need or 1, color)), width))
      end
    elseif (pr.secs_left or -1) < 0 and (pr.mats_total or 0) > 0 then
      add(pagelib.trunc("    " .. pagelib.bar(width - 6, pr.mats_done or 0, pr.mats_total or 1,
        pagelib.pct_color(pr.mats_done or 0, pr.mats_total or 1)), width))
    end
  end
end

local function settlers_lines(add, width)
  add(pagelib.header(width, "Settlers"))
  add(pagelib.trunc(string.format("Population: %s   Tax: %s   Water: %s",
    pagelib.fmt_num(S.settlers), tax_label(S.settler_tax), pagelib.fmt_num(S.city_water)), width))

  do
    local edict_val, edict_color = "Ready", C.dim
    if (S.settler_edict or "") ~= "" and (S.settler_edict_left or 0) > 0 then
      edict_val = edict_label(S.settler_edict) .. " (" .. cc.fmt_time(S.settler_edict_left) .. ")"
      edict_color = C.yellow
    elseif (S.settler_edict_cd or 0) > 0 then
      edict_val = "Cooldown " .. cc.fmt_time(S.settler_edict_cd)
      edict_color = C.yellow
    end
    add(pagelib.kv(width, "Edict:", edict_val, edict_color))
  end

  add(pagelib.trunc(string.format("Housing: %s cap   Plots: %s   Avg Tier: %s",
    pagelib.fmt_num(S.settler_housing_cap), pagelib.fmt_num(S.settler_housing_plots),
    string.format("%.2f", (S.settler_housing_avg or 0) / 100)), width))

  do
    local hpt = S.settler_housing_plot_tiers or {}
    -- Tier 5 counts here for the same reason it counts in Plots: above:
    -- write_shplots owns t1..t5 (GMCP's record carries h5), and SETTLERX's
    -- housing_plots sums every tier. Stopping at t4 both under-reports the row
    -- and, for a city whose plots are all tier 5, suppresses it entirely.
    local total = (hpt.t1 or 0) + (hpt.t2 or 0) + (hpt.t3 or 0) + (hpt.t4 or 0)
                  + (hpt.t5 or 0)
    if total > 0 then
      local parts = {}
      if (hpt.t1 or 0) > 0 then parts[#parts + 1] = "T1:" .. hpt.t1 end
      if (hpt.t2 or 0) > 0 then parts[#parts + 1] = "T2:" .. hpt.t2 end
      if (hpt.t3 or 0) > 0 then parts[#parts + 1] = "T3:" .. hpt.t3 end
      if (hpt.t4 or 0) > 0 then parts[#parts + 1] = "T4:" .. hpt.t4 end
      if (hpt.t5 or 0) > 0 then parts[#parts + 1] = "T5:" .. hpt.t5 end
      add(pagelib.kv(width, "Plot Tiers:", table.concat(parts, "  ")))
    end
  end

  add(pagelib.trunc(string.format("Housing Upkeep: %s/tick   Community Upkeep: %s/tick",
    pagelib.fmt_num(S.settler_housing_upkeep), pagelib.fmt_num(S.settler_community_upkeep)), width))

  add(pagelib.trunc(string.format("Jobs: %s   Employed: %s   Market Staffed: %s",
    pagelib.fmt_num(S.settler_jobs), pagelib.fmt_num(S.settler_employed),
    pagelib.fmt_num(S.settler_market_staffed)), width))

  add(metric_bar_line(width, "Mood", S.settler_mood))
  add(metric_bar_line(width, "  Housing", S.settler_housing_quality))
  add(metric_bar_line(width, "  Sustenance", S.settler_sustenance))
  add(metric_bar_line(width, "  Employment", S.settler_emp_score))
  add(metric_bar_line(width, "  Security", S.settler_security))
  add(metric_bar_line(width, "  Dignity", S.settler_dignity))

  do
    local sent = tonumber(S.settler_sentiment) or 0
    if sent ~= 0 then
      local sc = sent > 0 and C.bright_green or C.red
      add(pagelib.kv(width, "  Sentiment:", (sent > 0 and "+" or "") .. sent .. " (decaying)", sc))
    end
  end

  if page_opts.get("show_people_designations")
      and (#(S.settler_roles or {}) > 0 or (S.settler_commoner or 0) > 0) then
    designations_lines(add, width)
  end

  add(pagelib.kv(width, "Flourishing:", (S.settler_flourishing or 0) > 0 and "Yes" or "No",
    (S.settler_flourishing or 0) > 0 and C.bright_green or C.dim))

  do
    local net = tonumber(S.settler_community_net) or 0
    local net_str = (net >= 0 and "+" or "") .. pagelib.fmt_num(net) .. "/tick"
    local mult_str = string.format("x%.2f", (tonumber(S.settler_mult_pct) or 100) / 100)
    add(pagelib.trunc(string.format("%sCommunity Net:%s %s%s%s   Mood Mult: %s",
      C.dim, pagelib.RESET, net >= 0 and C.bright_green or C.red, net_str, pagelib.RESET, mult_str), width))
  end

  do
    local cb = S.settler_community_buildings or {}
    local parts = {}
    for _, cid in ipairs(sorted_keys(cb)) do
      local tier = cb[cid] or 0
      if tier > 0 then parts[#parts + 1] = bldg_display(cid) .. " T" .. tier end
    end
    if #parts > 0 then
      add(pagelib.kv(width, "Civic Buildings:", table.concat(parts, ", ")))
    end
  end

  add(pagelib.trunc(string.format(
    "Grain: %s   Fish: %s   %sBread:%s %s   %sSalted Fish:%s %s   Mead: %s",
    pagelib.fmt_num(stock_total("grain")), pagelib.fmt_num(stock_total("fish")),
    C.yellow, pagelib.RESET, pagelib.fmt_num(stock_total("bread")),
    C.bright_cyan, pagelib.RESET, pagelib.fmt_num(stock_total("salted_fish")),
    pagelib.fmt_num(stock_total("mead"))), width))

  do
    local spoils = stock_total("spoils")
    add(pagelib.kv(width, "Spoils:", pagelib.fmt_num(spoils), spoils > 0 and C.bright_red or C.dim))
  end

  do
    local cons = S.settler_consumption or {}
    local parts = {}
    for _, good in ipairs(sorted_keys(cons)) do
      local amt = cons[good] or 0
      if amt > 0 then
        parts[#parts + 1] = cc.good_color(good) .. cc.good_label(good) .. pagelib.RESET .. ":-" .. amt
      end
    end
    if #parts > 0 then
      add(pagelib.trunc(C.dim .. "Consumption/tick: " .. pagelib.RESET .. table.concat(parts, ", "), width))
    end
  end

  do
    local sup, pop = S.settler_supply_next or 0, S.settler_pop_next or 0
    if sup > 0 or pop > 0 then
      local parts = {}
      if sup > 0 then parts[#parts + 1] = pagelib.kv(width, "Supply Tick:", cc.fmt_time(sup), C.yellow) end
      if pop > 0 then parts[#parts + 1] = pagelib.kv(width, "Pop Tick:", cc.fmt_time(pop), C.yellow) end
      -- Each kv() call already pads/truncates to width on its own; combine
      -- as one row by re-truncating just the visible text, matching LEGACY's
      -- single inline row (9969-9971 in-source: draw_inline_pairs).
      if #parts == 2 then
        add(pagelib.trunc(string.format("Supply Tick: %s%s%s   Pop Tick: %s%s%s",
          C.yellow, cc.fmt_time(sup), pagelib.RESET, C.yellow, cc.fmt_time(pop), pagelib.RESET), width))
      else
        add(parts[1])
      end
    end
  end

  if #(S.settler_actions or {}) > 0 then
    local parts = {}
    for _, act in ipairs(S.settler_actions) do
      parts[#parts + 1] = act.name .. " " .. cc.fmt_time(act.secs)
    end
    add(pagelib.kv(width, "Actions:", table.concat(parts, ", "), C.yellow))
  end

  if #(S.settler_projects or {}) > 0 then
    projects_lines(add, width)
  end

  if (S.settlers or 0) == 0 then
    add(pagelib.trunc(C.dim .. "No settlers yet; housing and community still update here." .. pagelib.RESET, width))
  end
end

-- ---------------------------------------------------------------------------
-- Biome Patrol (guild_viking.lua:10154-10160) -- UNGATED, no page_opts key.
-- Shown whenever state.patrol.count > 0.
-- ---------------------------------------------------------------------------

local function patrol_lines(add, width)
  if not (S.patrol and (S.patrol.count or 0) > 0) then return end
  add(pagelib.header(width, "Biome Patrol"))
  add(pagelib.kv(width, "Hirdmadrs:", S.patrol.count))
  local time_str = (S.patrol.remaining or 0) > 0 and cc.fmt_time(S.patrol.remaining) or "Complete"
  add(pagelib.kv(width, "Time:", time_str))
end

-- ---------------------------------------------------------------------------
-- Garrison (guild_viking.lua:10163-10342, gated show_people_garrison) --
-- overview counters, the named-hirdmadr table, and an unconditional
-- Varangian Guards subsection.
-- ---------------------------------------------------------------------------

local LOY_LABELS = { [1] = "Wavering", [2] = "Uneasy", [3] = "Steady", [4] = "Loyal", [5] = "Devoted" }
local HIRD_STATUS_LABELS = {
  personal_guard = "Guard", garrison = "Garrison", city_pool = "Pool", wounded = "Wounded",
}
local HIRD_STATUS_COLORS = {
  personal_guard = C.bright_green, garrison = C.yellow, city_pool = C.dim, wounded = C.red,
}
local HIRD_MODE_LABELS = { neutral = "Neutral", offensive = "Offensive", defensive = "Defensive" }
local HIRD_MODE_COLORS = { neutral = C.white, offensive = C.red, defensive = C.cyan }

-- Ported from LEGACY's pip_bar (guild_viking.lua:10217-10225): val is 1-10,
-- mapped to 1-5 pips.
local function pip_bar(val, max_pips)
  local pips = math.floor(((val or 0) + 1) / 2)
  if pips < 1 then pips = 1 end
  if pips > max_pips then pips = max_pips end
  local s = "["
  for i = 1, max_pips do s = s .. (i <= pips and "*" or "-") end
  return s .. "]"
end

-- Fixed-width fields (name 14, loyalty/status 8, age 7, mode 9 -- the
-- widest label in each set) so every row lines up and none of the fixed
-- vocabulary (e.g. "Offensive", "Garrison") is ever truncated at width 80;
-- total visible width is 14+7+1+7+1+8+1+7+1+4+8+1+8+1+9 = 78, with room to
-- spare for the optional gear tag.
local function hird_row(width, hm)
  local is_champ = (hm.champ or 0) ~= 0
  local name_color = is_champ and C.bright_cyan or C.bright_green
  local display_name = (hm.name or "?") .. (is_champ and " [C]" or "")
  local loy = LOY_LABELS[hm.loyalty] or "Steady"
  local age_label = (hm.age_phase == "veteran") and "Veteran"
    or (hm.age_phase == "elder") and "Elder" or "Young"
  local age_color = (hm.age_phase == "veteran") and C.white
    or (hm.age_phase == "elder") and C.cyan or C.bright_green
  local status_label = HIRD_STATUS_LABELS[hm.status] or (hm.status or "?")
  local status_color = HIRD_STATUS_COLORS[hm.status] or C.dim
  local mode_key = (hm.mode == "offensive" or hm.mode == "defensive") and hm.mode or "neutral"
  local gear = ((hm.wpn or 0) > 0 or (hm.arm or 0) > 0)
    and string.format(" %sW%d/A%d%s", C.magenta, hm.wpn or 0, hm.arm or 0, pagelib.RESET) or ""
  return pagelib.trunc(string.format(
    "%s%-14s%s %s %s %-8s %s%-7s%s Lv%-2d%s  %s%-8s%s %s%-9s%s",
    name_color, display_name, pagelib.RESET, pip_bar(hm.atk, 5), pip_bar(hm.def, 5), loy,
    age_color, age_label, pagelib.RESET, hm.level or 0, gear,
    status_color, status_label, pagelib.RESET,
    HIRD_MODE_COLORS[mode_key], HIRD_MODE_LABELS[mode_key], pagelib.RESET), width)
end

local function varangian_lines(add, width)
  add(pagelib.header(width, "Varangian Guards"))
  if #(S.varang_out or {}) > 0 then
    add(pagelib.trunc("Dispatched:", width))
    for _, vc in ipairs(S.varang_out) do
      add(pagelib.trunc(string.format("  %s%s%s  %d men  %s left",
        C.yellow, vc.name or "?", pagelib.RESET, vc.count or 0, cc.fmt_time(vc.expires_in)), width))
    end
  else
    add(pagelib.trunc(C.dim .. "None dispatched." .. pagelib.RESET, width))
  end
  if #(S.varang_in or {}) > 0 then
    add(pagelib.trunc("Received:", width))
    for _, vc in ipairs(S.varang_in) do
      add(pagelib.trunc(string.format("  %s%s%s  %d men  %s left",
        C.bright_green, vc.name or "?", pagelib.RESET, vc.count or 0, cc.fmt_time(vc.expires_in)), width))
    end
  else
    add(pagelib.trunc(C.dim .. "None received." .. pagelib.RESET, width))
  end
end

local function garrison_lines(add, width)
  add(pagelib.header(width, "Garrison"))
  local total_hird = (S.garrison_stationed or 0) + (S.garrison_free or 0)
  if total_hird == 0 and #(S.hird_list or {}) == 0 then
    add(pagelib.trunc(C.dim .. "No hirdmadrs" .. pagelib.RESET, width))
  else
    if total_hird > 0 then
      local at_cap = (S.garrison_cap or 0) > 0 and (S.garrison_stationed or 0) >= S.garrison_cap
      local cap_str = (S.garrison_cap or 0) > 0
        and string.format("%d / %d", S.garrison_stationed or 0, S.garrison_cap)
        or tostring(S.garrison_stationed or 0)
      add(pagelib.trunc(string.format("Stationed: %s%s%s   Free: %d   Total: %d",
        at_cap and C.bright_red or C.dim, cap_str, pagelib.RESET,
        S.garrison_free or 0, total_hird), width))
      if (S.garrison_defpower or 0) > 0 then
        add(pagelib.kv(width, "Def power:", S.garrison_defpower, C.bright_green))
      end
    end
    if #(S.hird_list or {}) > 0 then
      for _, hm in ipairs(S.hird_list) do add(hird_row(width, hm)) end
    end
  end
  varangian_lines(add, width)
end

-- ---------------------------------------------------------------------------
-- Incoming Raids (guild_viking.lua:10345-10389, gated show_people_raids)
-- ---------------------------------------------------------------------------

-- Ported from LEGACY's inline arrival-time formatting (guild_viking.lua:
-- 10352-10364) -- distinct thresholds/format from cc.fmt_time.
local function raid_arrival_text(secs)
  if secs == 0 then return "Imminent!" end
  if secs < 60 then return secs .. "s" end
  if secs < 3600 then return string.format("%dm %ds", math.floor(secs / 60), secs % 60) end
  return string.format("%dh %dm", math.floor(secs / 3600), math.floor((secs % 3600) / 60))
end

local function raids_lines(add, width)
  add(pagelib.header(width, "Incoming Raids"))
  local raid_in = S.raid_in or -1
  if raid_in < 0 then
    add(pagelib.trunc(C.dim .. "No raid currently scheduled." .. pagelib.RESET, width))
    return
  end
  add(pagelib.kv(width, "Arrives in:", raid_arrival_text(raid_in),
    raid_in < 300 and C.bright_red or C.yellow))

  local parts = {}
  if (S.raid_faction or "") ~= "" then
    parts[#parts + 1] = "Faction: " .. C.bright_red .. S.raid_faction .. pagelib.RESET
  end
  if (S.raid_strength or 0) > 0 then
    local str_color = (S.raid_strength or 0) > (S.garrison_defpower or 0) and C.bright_red or C.bright_green
    parts[#parts + 1] = "Strength: " .. str_color .. S.raid_strength .. pagelib.RESET
  end
  if #parts > 0 then
    add(pagelib.trunc(table.concat(parts, "   "), width))
  end
end

-- ---------------------------------------------------------------------------
-- Thralls (guild_viking.lua:10391-10497, gated show_people_thralls AND
-- (state.thralls > 0 OR state.thrall_follower_level > 0))
-- ---------------------------------------------------------------------------

local THRALL_BLDG_ORDER = {
  "longhouse", "warehouse", "farm", "apiary", "tannery", "fishery", "lumber_yard",
  "mine", "smithy", "watchtower", "palisade", "salting_house", "bakehouse",
  "furriers_lodge", "smelter", "matbur",
}
local THRALL_BLDG_LABELS = {
  longhouse = "Longhouse", warehouse = "Warehouse", farm = "Farm", apiary = "Apiary",
  tannery = "Tannery", fishery = "Fishery", lumber_yard = "Lumber Yard", mine = "Mine",
  smithy = "Smithy", watchtower = "Watchtower", palisade = "Palisade",
  salting_house = "Salting House", bakehouse = "Bakehouse",
  furriers_lodge = "Furrier's Lodge", smelter = "Smelter", matbur = "Matbur",
}

local COMPANION_STATUS_LABELS = {
  following = "Following", staying = "Staying", dismissed = "Dismissed",
  away = "Away", none = "Away",
}
local COMPANION_STATUS_COLORS = {
  following = C.bright_green, staying = C.yellow, dismissed = C.red,
  away = C.dim, none = C.dim,
}

local function companion_lines(add, width)
  local name = (S.thrall_follower_name and S.thrall_follower_name ~= "") and S.thrall_follower_name or "Thrall"
  name = (name:gsub("^%l", string.upper))
  local status = S.thrall_follower_status or "none"
  add(pagelib.trunc(string.format("  Companion: %s%s%s  Lv%d   %s%s%s",
    C.bright_green, name, pagelib.RESET, S.thrall_follower_level or 0,
    COMPANION_STATUS_COLORS[status] or C.dim, COMPANION_STATUS_LABELS[status] or "Away", pagelib.RESET),
    width))

  local xp_text = (S.thrall_follower_xp_cap or 0) > 0
    and string.format("XP: %d/%d", S.thrall_follower_xp or 0, S.thrall_follower_xp_cap)
    or "XP: MAX"
  local carry_text = string.format("Carry: %d/%d",
    S.thrall_follower_carry_used or 0, S.thrall_follower_carry_cap or 0)
  add(pagelib.trunc("    " .. xp_text .. "   " .. carry_text, width))

  local xp_cap = (S.thrall_follower_xp_cap or 0) > 0 and S.thrall_follower_xp_cap or 1
  add(pagelib.trunc("    Level: " .. pagelib.bar(width - 12, S.thrall_follower_xp or 0, xp_cap, C.bright_green),
    width))
end

local function thralls_lines(add, width)
  add(pagelib.header(width, "Thralls"))

  local assigned_total = 0
  for _, bid in ipairs(THRALL_BLDG_ORDER) do
    assigned_total = assigned_total + ((S.thrall_assignments or {})[bid] or 0)
  end

  if assigned_total > 0 then
    add(pagelib.trunc(string.format("Held: %d   Working: %d", S.thralls or 0, assigned_total), width))
    local rows = {}
    for _, bid in ipairs(THRALL_BLDG_ORDER) do
      local n = (S.thrall_assignments or {})[bid] or 0
      if n > 0 then rows[#rows + 1] = string.format("%s: %d", THRALL_BLDG_LABELS[bid], n) end
    end
    local half = math.floor(width / 2)
    for i = 1, #rows, 2 do
      local left = pagelib.trunc("  " .. rows[i], half)
      local right = rows[i + 1] and ("  " .. rows[i + 1]) or ""
      add(pagelib.trunc(left .. right, width))
    end
  else
    add(pagelib.kv(width, "Held:", S.thralls or 0))
  end

  if (S.thrall_follower_level or 0) > 0 and page_opts.get("show_people_thrall_companion") then
    companion_lines(add, width)
  end
end

-- ---------------------------------------------------------------------------
-- Missions (guild_viking.lua:10500-10661, gated show_people_missions)
--
-- Task 6: mission/errand "Run There" buttons, ported through window.lua's
-- new page-level pointer seam (that module's header comment). Hotspot ->
-- port table (LEGACY line -> where it lives now):
--
--   mission_run_<id> hotspot     MAIN 10538-10558   mission_lines' button
--     (WindowAddHotspot, enabled                     row + the target
--      branch only)                                   appended to
--                                                       `targets` below,
--                                                       gated the SAME way
--                                                       on has_sufficient_
--                                                       goods(m.want_goods)
--   viking_mission_run_click     MAIN 12080-12143   mission_run_click(id)
--   errand_run_<id> hotspot      MAIN 10609-10631   errand_lines' button
--     (WindowAddHotspot,                              row + target -- LEGACY
--      unconditional: can_travel                       hard-codes
--      is hard-coded true)                              can_travel=true, so
--                                                        this target is
--                                                        always appended,
--                                                        never gated
--   viking_errand_run_click      MAIN 12144-12233   errand_run_click(id)
--   viking_errand_return_and_    MAIN 12234-12331   errand_return_and_
--     submit                                          submit(id) -- reuses
--                                                       popups/map.lua's
--                                                       M.poi_menu_items()
--                                                       and M.travel_to()
--                                                       (Task 5 machinery),
--                                                       per that call's
--                                                       12289/12309 in
--                                                       LEGACY -- see below
--   has_sufficient_goods         MAIN 4817-4839     has_sufficient_goods
--     (verbatim)                                       (this file, below)
--
-- BGR workbook (0xBBGGRR, per this module's header note) for the button's
-- two text colors (MAIN 10541/10548 mission, 10614/10621 errand -- both
-- button families share the same literal pair):
--   enabled  0xCCFFCC -> B=CC,G=FF,R=CC -> R=CC,G=FF,B=CC: pale green
--     -> nearest pagelib.C entry: C.bright_green
--   disabled 0x888888 -> B=88,G=88,R=88 -> R=88,G=88,B=88: mid gray
--     -> nearest pagelib.C entry: C.dim
-- (WindowRectOp's fill/border colors, 0x444444/0x666666 enabled and
-- 0x333333/0x555555 disabled, have no text-mode equivalent -- dropped, same
-- "content fidelity not pixel fidelity" convention as this module's other
-- disclosed simplifications.)
--
-- Row/button placement is a disclosed adaptation, not a pixel port: LEGACY
-- right-aligns the button before the expiry time on row 1 (pixel layout
-- this text pane cannot reproduce at arbitrary widths -- a long label could
-- push the button off a truncated row entirely, an ambiguity a fixed pixel
-- canvas never has). This port gives the button ITS OWN row, 2-space
-- indented, directly under the [id]/label/expiry row -- deterministic
-- column math for the pointer seam regardless of label length, and never
-- truncated away except at a pathologically narrow width (guarded below:
-- no target is recorded unless the full "[Run There]" span fits).
--
-- "Both fetched states" ambiguity (resolved): LEGACY's own comment at MAIN
-- 10610 ("enable if not fetched... OR if fetched...") describes a two-state
-- errand button that the CODE never implements -- `can_travel` is hard-coded
-- `true` (10608) with no read of any "fetched" flag anywhere in state.errand
-- (grep-confirmed), so there is only one live appearance/behavior for this
-- button, not two. Verbatim discipline ports the executable branch, not the
-- aspirational comment; the two states this port actually exercises (and
-- tests) are `e.target_town` present vs blank -- errand_run_click's real
-- branch (MAIN 12148-12151 dispatches only when target_town is non-empty;
-- the else is a dropped ColourNote, no-op).
-- ---------------------------------------------------------------------------

-- Check if player has sufficient goods for a mission -- MAIN 4817-4839,
-- ported verbatim (same stock-lookup-then-per-good-compare shape; no goods
-- required -> true).
local function has_sufficient_goods(want_goods)
  if not want_goods or type(want_goods) ~= "table" or not next(want_goods) then
    return true
  end
  local stock_lookup = {}
  for _, item in ipairs(S.wstock or {}) do
    if item.good and item.amount then
      stock_lookup[item.good] = (stock_lookup[item.good] or 0) + item.amount
    end
  end
  for good, needed_qty in pairs(want_goods) do
    local have_qty = stock_lookup[good] or 0
    if have_qty < needed_qty then
      return false
    end
  end
  return true
end

-- viking_errand_return_and_submit (MAIN 12234-12331). Called only from
-- errand_run_click below, itself only reachable once e.target_town's travel
-- (if any) has already been dispatched -- see that function's ordering.
-- ColourNote status/diagnostic lines throughout are dropped (display-only,
-- same convention as every pointer handler in this plugin); every guard
-- and branch that gated a SEND is kept.
local function errand_return_and_submit(errand_id)
  local e = S.errand
  if not e or e.id ~= errand_id then return end -- "Errand data lost during travel"

  local origin_town_name = e.origin_town or ""
  if origin_town_name == "" then
    -- Fallback (MAIN 12251-12268): capital towns first, then lineage towns,
    -- in state.vmap_pois' own iteration order (NOT the sorted menu order) --
    -- take the first match, or abort if there are none at all.
    local capital_towns, lineage_towns = {}, {}
    for _, poi in ipairs(S.vmap_pois or {}) do
      if poi.type == "capital" then
        capital_towns[#capital_towns + 1] = poi
      elseif poi.type == "lineage" then
        lineage_towns[#lineage_towns + 1] = poi
      end
    end
    local towns_to_try = {}
    for _, t in ipairs(capital_towns) do towns_to_try[#towns_to_try + 1] = t end
    for _, t in ipairs(lineage_towns) do towns_to_try[#towns_to_try + 1] = t end
    if #towns_to_try > 0 then
      origin_town_name = towns_to_try[1].name
    else
      return -- "Origin town not recorded - cannot return automatically"
    end
  end

  -- viking_show_poi_menu's own guards (MAIN 11789-11814), reused via
  -- popups/map.lua's M.poi_menu_items() (Task 5 machinery -- same sorted
  -- item list viking_show_poi_menu built, not re-derived here).
  if (S.vmap_px or -1) < 0 then return end -- "you are not on the map"
  local items = map.poi_menu_items()
  if #items == 0 then return end -- "No locations available to travel to"

  -- town_index search (MAIN 12293-12299) + the visible-index arithmetic
  -- (MAIN 12308-12309): vmap_poi_scroll was just reset to 0 by
  -- viking_show_poi_menu, so visible_index == town_index == actual_idx --
  -- items[town_index] IS the resolved pick, with no scroll offset to add.
  local town_index = nil
  for i, poi in ipairs(items) do
    if poi.name == origin_town_name then
      town_index = i
      break
    end
  end
  if not town_index then return end -- "Cannot find <town> in travel menu"

  -- viking_poi_menu_pick -> viking_poi_menu_travel (MAIN 12330-12341,
  -- 12343-12369), reused via popups/map.lua's M.travel_to() (Task 5
  -- machinery -- same bfs+send dispatch, not re-implemented here). Note
  -- this fires regardless of travel_to's own outcome (no route / already
  -- there / real travel) -- LEGACY's own code runs the two Sends below
  -- unconditionally after the pick, verbatim.
  map.travel_to(items[town_index])

  mud.send("enter")
  mud.send("vmission newbie submit")
end

-- viking_mission_run_click (MAIN 12080-12143). `mission_id` is re-resolved
-- against S.missions at CLICK time (not the `m` table captured when the
-- button was drawn), matching LEGACY's own re-lookup by id -- a mission
-- that expired/was removed between render and click is silently a no-op,
-- exactly as LEGACY's "if not mission then return true end" is.
local function mission_run_click(mission_id)
  local mission = nil
  for _, m in ipairs(S.missions or {}) do
    if m.id == mission_id then mission = m; break end
  end
  if not mission then return end

  local town_name = mission.target_town
  if not town_name or town_name == "" then return end -- "Cannot determine mission target town"

  local town_coords = nil
  for _, poi in ipairs(S.vmap_pois or {}) do
    if poi.name == town_name then town_coords = poi; break end
  end
  if not town_coords then return end -- "Cannot find coordinates for town"

  if (S.vmap_px or -1) < 0 then return end -- "Player position unknown"

  local path = pathfinding.bfs(S.vmap_px, S.vmap_py, town_coords.x, town_coords.y)
  if not path then
    return -- "No passable route to <town>" -- no send at all
  elseif #path == 0 then
    mud.send("enter")
    mud.send("vmission fulfill " .. mission_id)
  else
    for _, dir in ipairs(path) do mud.send(dir) end
    mud.send("enter")
    -- LEGACY prints "After entering, use: vmission fulfill <id>" here as a
    -- hint (ColourNote) -- it never actually Sends the fulfill command in
    -- this branch, only in the #path==0 ("already there") branch above.
    -- Dropped message, but the asymmetry in what gets SENT is preserved.
  end
end

-- viking_errand_run_click (MAIN 12144-12233). `errand_id` is re-resolved
-- against S.errand at CLICK time, matching LEGACY's own guard.
local function errand_run_click(errand_id)
  local e = S.errand
  if not e or e.id ~= errand_id then return end -- "Errand not found"

  if not (e.target_town and e.target_town ~= "") then
    return -- "Cannot determine errand target town"
  end

  local town_coords = nil
  for _, poi in ipairs(S.vmap_pois or {}) do
    if poi.name == e.target_town then town_coords = poi; break end
  end
  if not town_coords then return end -- "Cannot find coordinates for town"

  if (S.vmap_px or -1) < 0 then return end -- "Player position unknown"

  local path = pathfinding.bfs(S.vmap_px, S.vmap_py, town_coords.x, town_coords.y)
  if not path then
    return -- "No passable route to <town>" -- no send, no continuation
  elseif #path == 0 then
    mud.send("enter")
    mud.send("vmission newbie fetch")
    mud.send("leave")
    errand_return_and_submit(errand_id)
  else
    for _, dir in ipairs(path) do mud.send(dir) end
    mud.send("enter")
    mud.send("vmission newbie fetch")
    mud.send("leave")
    errand_return_and_submit(errand_id)
  end
end

local function mission_town_text(origin, target)
  if (origin or "") ~= "" and (target or "") ~= "" then
    return origin .. " -> " .. target
  elseif (target or "") ~= "" then
    return "-> " .. target
  end
  return "(any town)"
end

local function mission_lines(add, width, m, targets)
  local exp_str = (m.expires_in or 0) > 0 and cc.fmt_time(m.expires_in) or "Expired"
  local exp_color = (m.expires_in or 0) < 3600 and C.bright_red or C.dim
  add(pagelib.trunc(string.format("[%s] %s  %s%s%s",
    tostring(m.id or 0), m.label or "", exp_color, exp_str, pagelib.RESET), width))

  local enabled = has_sufficient_goods(m.want_goods)
  local btn_text, btn_w = pagelib.button("Run There", enabled and C.bright_green or C.dim)
  local btn_row = add(pagelib.trunc("  " .. btn_text, width))
  local col_start, col_end = 2, 2 + btn_w
  if enabled and col_end <= width then
    local mission_id = m.id
    targets[#targets + 1] = {
      row = btn_row, col_start = col_start, col_end = col_end,
      action = function() mission_run_click(mission_id) end,
    }
  end

  local reward_parts = {}
  if (m.reward or 0) > 0 then
    reward_parts[#reward_parts + 1] = C.bright_cyan .. "+" .. m.reward .. " daler" .. pagelib.RESET
  end
  if (m.reward_rep or 0) > 0 then
    reward_parts[#reward_parts + 1] = C.yellow .. "+" .. m.reward_rep .. " rep" .. pagelib.RESET
  end
  add(pagelib.trunc("  " .. mission_town_text(m.origin_town, m.target_town) ..
    (#reward_parts > 0 and ("   " .. table.concat(reward_parts, "  ")) or ""), width))

  for _, g in ipairs(sorted_keys(m.want_goods)) do
    local q = m.want_goods[g]
    add(pagelib.trunc("    " .. cc.good_color(g) .. "Need " .. q .. " " .. cc.good_label(g) .. pagelib.RESET,
      width))
  end
end

local function errand_lines(add, width, e, targets)
  local exp_str = (e.expires_in or 0) > 0 and cc.fmt_time(e.expires_in) or "Expired"
  local exp_color = (e.expires_in or 0) < 3600 and C.bright_red or C.dim
  add(pagelib.trunc(string.format("[%s] Errand: %s  %s%s%s",
    tostring(e.id or 0), e.label or "", exp_color, exp_str, pagelib.RESET), width))

  -- can_travel is hard-coded true in LEGACY (MAIN 10608) -- always the
  -- enabled appearance, always a recorded target (see the module-section
  -- comment's "both fetched states" note above).
  local btn_text, btn_w = pagelib.button("Run There", C.bright_green)
  local btn_row = add(pagelib.trunc("  " .. btn_text, width))
  local col_start, col_end = 2, 2 + btn_w
  if col_end <= width then
    local errand_id = e.id
    targets[#targets + 1] = {
      row = btn_row, col_start = col_start, col_end = col_end,
      action = function() errand_run_click(errand_id) end,
    }
  end

  local reward_str = ""
  if (e.reward_good or "") ~= "" and (e.reward_qty or 0) > 0 then
    reward_str = cc.good_color(e.reward_good) .. "+" .. e.reward_qty .. " " .. cc.good_label(e.reward_good) ..
      pagelib.RESET
  elseif (e.reward or 0) > 0 then
    reward_str = C.bright_cyan .. "+" .. e.reward .. " daler" .. pagelib.RESET
  end
  add(pagelib.trunc("  " .. mission_town_text(e.origin_town, e.target_town) ..
    (reward_str ~= "" and ("   " .. reward_str) or ""), width))
end

local function missions_lines(add, width, targets)
  local has_missions = #(S.missions or {}) > 0 or S.errand ~= nil
  local reg_left = S.mission_reg_left or -1
  local new_left = S.mission_new_left or -1
  local has_timers = reg_left >= 0 or new_left >= 0
  if not (has_missions or has_timers) then return end

  add(pagelib.header(width, "Missions"))

  if has_timers then
    local parts = {}
    if reg_left >= 0 then
      parts[#parts + 1] = "Missions left: " .. (reg_left == 0 and C.bright_red or C.white) ..
        reg_left .. pagelib.RESET
    end
    if new_left >= 0 then
      parts[#parts + 1] = "Errands left: " .. (new_left == 0 and C.bright_red or C.white) ..
        new_left .. pagelib.RESET
    end
    add(pagelib.trunc(table.concat(parts, "   "), width))
  end

  if not has_missions then
    add(pagelib.trunc(C.dim .. "No active missions" .. pagelib.RESET, width))
  end

  for _, m in ipairs(S.missions or {}) do
    mission_lines(add, width, m, targets)
  end

  if S.errand then
    errand_lines(add, width, S.errand, targets)
  end
end

-- ---------------------------------------------------------------------------

function M.lines(width)
  width = width or 80
  local lines = {}
  local targets = {}
  local function add(s) lines[#lines + 1] = s; return #lines end

  if page_opts.get("show_people_settlers") then
    settlers_lines(add, width)
  end

  patrol_lines(add, width)

  if page_opts.get("show_people_garrison") then
    garrison_lines(add, width)
  end

  if page_opts.get("show_people_raids") then
    raids_lines(add, width)
  end

  if page_opts.get("show_people_thralls")
      and ((S.thralls or 0) > 0 or (S.thrall_follower_level or 0) > 0) then
    thralls_lines(add, width)
  end

  if page_opts.get("show_people_missions") then
    missions_lines(add, width, targets)
  end

  return lines, targets
end

return M
