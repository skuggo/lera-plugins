-- guild_viking pane page unit tests: Task 3's pages/stats.lua (also hosts
-- Farm/Builds from Task 5, per the plan's shared-harness note). Run from the
-- lera-plugins repo root with LERA_ROOT pointing at a built Lera checkout.
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
-- pages/stats.lua is pure (no ui.* calls), but it requires combat.lua, whose
-- trigger functions (never invoked here) call ui.dirty() -- stub it anyway
-- so a future accidental call fails loudly as a stub-missing error, not
-- silently.
ui = { dirty = function() end }
lera = { render_pass = function() return "local" end }

local pagelib = require("pagelib")
local state = require("state")
local page_opts = require("page_opts")
local combat = require("combat")
local cc = require("pages.city_common")
local stats_page = require("pages.stats")
local farm_page = require("pages.farm")
local builds_page = require("pages.builds")

local S = state.S

-- ---- seed state with known values -------------------------------------------
S.daler = 12345
S.hp, S.mhp, S.hp_delta = 350, 500, 5
S.threk, S.mthrek, S.threk_delta = 10, 50, -2
S.seid, S.mseid, S.seid_delta = 80, 100, 0
S.vig, S.mvig, S.vig_delta = 40, 80, 0
S.rad, S.mrad, S.rad_delta = 20, 40, 0
S.fury = "[***-------]"
S.ldng, S.mldng, S.lrst = 3, 4, 10
S.chain, S.bsdepth = 7, 2
S.god_power_name, S.god_power_next = "", 0

S.vis, S.vis_gain, S.vis_session = 100, 5, 20
S.kap, S.kap_gain, S.kap_session = 200, 3, 15
S.soe, S.soe_gain, S.soe_session = 50, 0, 5
S.aud, S.aud_gain, S.aud_session = 10, 1, 2
S.xp_session_start = os.time() - 65   -- 1m5s elapsed

S.en5, S.ens, S.rndz = "Wolf", "low", 3
S.mob_name_full, S.estatus_pct, S.combat = "Grey Wolf", 42, true

S.stfx = { { name = "ein", val = "54", cat = "Def" } }

page_opts.set("show_stats_xp", true)
page_opts.set("show_stats_buffs", true)

local WIDTH = 80

local function joined(lines)
  return table.concat(lines, "\n")
end

-- Returns the 1-based line index of the first line containing `needle`
-- (plain substring, ANSI escapes included but not interfering since needle
-- itself has none), or nil.
local function find_line(lines, needle)
  for i, l in ipairs(lines) do
    if l:find(needle, 1, true) then return i end
  end
  return nil
end

-- ---- full render: every gated section on ------------------------------------
local lines = stats_page.lines(WIDTH)
check("lines() returns a non-empty array", #lines > 5, #lines)

local all = joined(lines)

-- ---- daler line, fmt_num'd -------------------------------------------------
check("daler line present with fmt_num'd value",
      all:find(pagelib.fmt_num(S.daler), 1, true) ~= nil, pagelib.fmt_num(S.daler))

-- ---- fury: prefers Guild.State's integers, falls back to the bar string ----
-- The fixture above sets only S.fury ("[***-------]"), the trigger path's
-- rendered token, so this first case is the fallback: three filled of ten.
check("fury row derives 3/10 from the trigger's bar string",
      find_line(lines, "3/10") ~= nil, all)

-- Guild.State sends points.fury/mfury as integers. Preferring them is the
-- point: with only the string, the page recovers the numbers by stripping the
-- brackets and counting asterisks, which cannot represent a maximum the bar
-- does not have room to draw.
S.fury_cur, S.fury_max = 7, 12
local fury_lines = stats_page.lines(WIDTH)
check("fury row uses the GMCP integers when present",
      find_line(fury_lines, "7/12") ~= nil, joined(fury_lines))
check("fury row ignores the stale bar string once the integers are present",
      find_line(fury_lines, "3/10") == nil, joined(fury_lines))

-- A zero maximum is a real state (no fury capacity yet) and must not be
-- mistaken for "no GMCP value", which would silently fall back to the string.
S.fury_cur, S.fury_max = 0, 0
local fury_zero = stats_page.lines(WIDTH)
check("a zero fury maximum still uses the GMCP path, not the bar string",
      find_line(fury_zero, "0/") ~= nil and find_line(fury_zero, "3/10") == nil,
      joined(fury_zero))
S.fury_cur, S.fury_max = nil, nil

-- ---- an hp row: bar glyphs AND "350/500" -----------------------------------
local hp_idx = find_line(lines, "350/500")
check("an hp row contains \"350/500\"", hp_idx ~= nil, all)
if hp_idx then
  local hp_line = lines[hp_idx]
  check("that hp row contains bar glyphs (# and -)",
        hp_line:find("#", 1, true) ~= nil and hp_line:find("%-%-") ~= nil, hp_line)
end

-- ---- Enemy line -------------------------------------------------------------
-- The fixture sets en5="Wolf" (the wire's five-char truncation) alongside
-- mob_name_full="Grey Wolf". The truncation must NOT be rendered: the Target
-- line directly above already names the same mob in full, so "En:Wolf" was a
-- worse copy of the line above it.
do
  local strip = function(t) return (t:gsub("\27%[[%d;]*m", "")) end
  local enemy_idx = find_line(lines, "Enemy")
  local status_line
  for i = (enemy_idx or 1), #lines do
    if strip(lines[i]):find("Status:", 1, true) then status_line = lines[i]; break end
  end
  check("stats: the Enemy block has a status line", status_line ~= nil, all)
  if status_line then
    local plain = strip(status_line)
    check("stats: the redundant En: truncation is gone",
          plain:find("En:", 1, true) == nil, plain)
    check("stats: status, rounds and estimate all still render",
          plain:find("Status:low", 1, true) ~= nil
          and plain:find("Rounds:3", 1, true) ~= nil
          and plain:find("Est:42%", 1, true) ~= nil, plain)
    -- 42% falls in pct_color's red tier (> 0.25, <= 0.5). Asserted by tier
    -- rather than by literal escape so the check survives a palette rename.
    check("stats: the estimate is coloured by its percentage",
          status_line:find(pagelib.C.red .. "42%", 1, true) ~= nil, status_line)
    -- "low" is not numeric, so it gets the neutral colour rather than a
    -- percentage ramp read off a string that has no number in it.
    check("stats: a non-numeric status is left neutral",
          status_line:find(pagelib.C.white .. "low", 1, true) ~= nil, status_line)
  end
end

-- ---- section headers present, in order --------------------------------------
local section_order = { "Vitals", "Ledung / Chain", "God", "Saga XP", "Enemy", "Active Effects",
                         "Automation" }
local last_idx = 0
local order_ok = true
local missing
for _, name in ipairs(section_order) do
  local idx = find_line(lines, name)
  if not idx then
    order_ok = false
    missing = name
  elseif idx <= last_idx then
    order_ok = false
    missing = name .. " (out of order)"
  else
    last_idx = idx
  end
end
check("every section header present, in order", order_ok, missing)

-- ---- enemy row shows en5 + ens ----------------------------------------------
local enemy_idx = find_line(lines, "Wolf")
check("an enemy row mentions en5 (Wolf)", enemy_idx ~= nil, all)
if enemy_idx then
  check("the same/adjacent enemy content mentions ens (low)",
        (lines[enemy_idx]:find("low", 1, true) ~= nil)
        or (lines[enemy_idx + 1] and lines[enemy_idx + 1]:find("low", 1, true) ~= nil),
        lines[enemy_idx] .. " / " .. tostring(lines[enemy_idx + 1]))
end

-- ---- saga section vanishes when show_stats_xp is off ------------------------
page_opts.set("show_stats_xp", false)
local lines_no_xp = stats_page.lines(WIDTH)
check("Saga XP header disappears when show_stats_xp is off",
      find_line(lines_no_xp, "Saga XP") == nil)
check("session-gained content disappears too",
      find_line(lines_no_xp, "Session gained") == nil)
page_opts.set("show_stats_xp", true)
local lines_xp_back = stats_page.lines(WIDTH)
check("Saga XP header reappears once the opt is back on",
      find_line(lines_xp_back, "Saga XP") ~= nil)

-- ---- stfx section vanishes when show_stats_buffs is off ---------------------
page_opts.set("show_stats_buffs", false)
local lines_no_buffs = stats_page.lines(WIDTH)
check("Active Effects header disappears when show_stats_buffs is off",
      find_line(lines_no_buffs, "Active Effects") == nil)
check("the stfx entry itself (ein:54) disappears too",
      find_line(lines_no_buffs, "ein:54") == nil)
page_opts.set("show_stats_buffs", true)
local lines_buffs_back = stats_page.lines(WIDTH)
check("Active Effects header reappears once the opt is back on",
      find_line(lines_buffs_back, "Active Effects") ~= nil)
check("the stfx entry (ein:54) reappears too",
      find_line(lines_buffs_back, "ein:54") ~= nil)

-- ---- Active Effects also vanishes with an empty stfx list, opt still on ----
local saved_stfx = S.stfx
S.stfx = {}
local lines_no_effects = stats_page.lines(WIDTH)
check("Active Effects header absent when stfx is empty (even with the opt on)",
      find_line(lines_no_effects, "Active Effects") == nil)
S.stfx = saved_stfx

-- ---- combat.lua's exported STFX category metadata is what the page uses ----
check("combat.lua exports STFX_CAT_ORDER", type(combat.STFX_CAT_ORDER) == "table"
      and #combat.STFX_CAT_ORDER == 5)
check("combat.lua exports STFX_CAT_LABELS", type(combat.STFX_CAT_LABELS) == "table"
      and combat.STFX_CAT_LABELS.Def == "Def")

-- =============================================================================
-- Automation section (Task 9, lera-only -- see pages/stats.lua's module
-- comment for the disclosure). Gated show_stats_automation, default true.
-- Pure read of autotrader.tick.status()/autoraid.settings()/
-- autovoyage.settings() via the page's own deferred-require accessors --
-- reached here only through require("autotrader.tick")/require("autoraid")/
-- require("autovoyage") directly (the same module singletons, since
-- require() caches by name), never by poking pages/stats.lua's internals.
-- =============================================================================
local autotrade_tick_page = require("autotrader.tick")
local autoraid_page = require("autoraid")
local autovoyage_page = require("autovoyage")
local autoherd_page = require("autoherd")

-- pagelib.kv colors the label and value separately (dim label, RESET, a
-- plain space, then the value's own color) -- so "Auto-Trade: off (...)" is
-- not one contiguous substring in the raw ANSI text (there is an escape
-- sequence between the colon and the space, and another between the space
-- and the value). Strip escapes and trim the row's own right-padding before
-- comparing exact content; find_line's plain substring search stays fine for
-- the label/header-only checks elsewhere in this file, where the substring
-- itself has no embedded escape.
local function strip_and_trim(s)
  return (s:gsub("\27%[[%d;]*m", ""):gsub("%s+$", ""))
end
local function find_row(lines_arr, label)
  for _, l in ipairs(lines_arr) do
    if l:find(label, 1, true) then return strip_and_trim(l) end
  end
  return nil
end

check("show_stats_automation defaults to true", page_opts.get("show_stats_automation") == true)

-- `lines` (captured above, before any of this section's toggling) already
-- reflects the all-off default: auto_trade/auto_raid/auto_voyage all false,
-- fresh idle tick state, no dispatch/log history yet.
check("Automation section: Auto-Trade row, off by default, idle/no pending",
      find_row(lines, "Auto-Trade:") == "Auto-Trade: off (phase=idle pending=0)", find_row(lines, "Auto-Trade:"))
check("Automation section: Auto-Raid row, off by default, no dispatch yet",
      find_row(lines, "Auto-Raid:") == "Auto-Raid: off (last: none)", find_row(lines, "Auto-Raid:"))
check("Automation section: Auto-Voyage row, off by default, no log yet",
      find_row(lines, "Auto-Voyage:") == "Auto-Voyage: off (last: none)", find_row(lines, "Auto-Voyage:"))
-- Auto-Herd is the only one of the four that spends the player's daler, and
-- it appeared in neither status surface -- so a user who enabled it had no
-- on-screen indication anywhere that it was running, while every non-spending
-- sibling had two.
check("Automation section: Auto-Herd row, off by default, no log yet",
      find_row(lines, "Auto-Herd:") == "Auto-Herd: off (last: none)", find_row(lines, "Auto-Herd:"))

-- Flipping page_opts flags on is reflected immediately (read at render time,
-- not cached) -- and each row picks up real state from the automation's own
-- module, not a copy: last_dispatch/log entries set through the SAME
-- singleton modules the page's deferred requires resolve to.
page_opts.set("auto_trade", true)
page_opts.set("auto_raid", true)
page_opts.set("auto_voyage", true)
page_opts.set("auto_herd", true)
autoraid_page.settings().last_dispatch = { t = "09:00", target = "Bjorn", n = 3, convoy = true }
autovoyage_page.settings().log = { "08:00 explore -> B4" }
autoherd_page.settings().log = { { t = "07:30", desc = "stock sheep into sheepfold" } }
local lines_on = stats_page.lines(WIDTH)
check("Automation section: Auto-Trade row flips to ON",
      find_row(lines_on, "Auto-Trade:") == "Auto-Trade: ON (phase=idle pending=0)",
      find_row(lines_on, "Auto-Trade:"))
check("Automation section: Auto-Raid row flips to ON and shows the last dispatch",
      find_row(lines_on, "Auto-Raid:") == "Auto-Raid: ON (last: 3 ships -> Bjorn)",
      find_row(lines_on, "Auto-Raid:"))
check("Automation section: Auto-Voyage row flips to ON and shows the last log entry",
      find_row(lines_on, "Auto-Voyage:") == "Auto-Voyage: ON (last: 08:00 explore -> B4)",
      find_row(lines_on, "Auto-Voyage:"))
check("Automation section: Auto-Herd row flips to ON and shows the last log entry",
      find_row(lines_on, "Auto-Herd:")
        == "Auto-Herd: ON (last: 07:30 stock sheep into sheepfold)",
      find_row(lines_on, "Auto-Herd:"))

page_opts.set("auto_trade", false)
page_opts.set("auto_raid", false)
page_opts.set("auto_voyage", false)
page_opts.set("auto_herd", false)
autoraid_page.settings().last_dispatch = nil
autovoyage_page.settings().log = {}
autoherd_page.settings().log = {}

-- Gate: show_stats_automation off removes the whole section, header and
-- rows alike -- and this is the one check a mutant that deletes the gate
-- (see the task report's mutant table) makes fail.
page_opts.set("show_stats_automation", false)
local lines_no_automation = stats_page.lines(WIDTH)
check("Automation header disappears when show_stats_automation is off",
      find_line(lines_no_automation, "Automation") == nil)
check("Auto-Trade row disappears too",
      find_line(lines_no_automation, "Auto-Trade:") == nil)
page_opts.set("show_stats_automation", true)
local lines_automation_back = stats_page.lines(WIDTH)
check("Automation header reappears once the opt is back on",
      find_line(lines_automation_back, "Automation") ~= nil)

-- Purity, implicitly: this harness defines no `mud` or `buffer` global at
-- all (only `ui.dirty` and `lera.render_pass`, see the top-of-file comment).
-- Every stats_page.lines() call above (including the ones just run with the
-- Automation section rendered in every flag combination) would have raised
-- an uncaught "attempt to index a nil value" error had the section called
-- mud.send or buffer.color_print -- it never did, which is the whole point
-- of a pure lines(width) builder (this file's own module comment).

-- ---- width is respected: every emitted row's visible width <= width --------
local width_ok = true
local widest
for _, l in ipairs(lines) do
  local vw = pagelib.visible_width(l)
  if vw > WIDTH then
    width_ok = false
    widest = vw
  end
end
check("every row's visible width is <= the requested width", width_ok, widest)

-- =============================================================================
-- pages/farm.lua (Task 5) -- LEGACY draw_page3 (guild_viking.lua:9115-9370)
-- =============================================================================

local C = pagelib.C

-- ---- seed farm state --------------------------------------------------------
S.season = "spring"
S.weather = "storm"
S.weather_str = 3
S.farm_wmod = 15
S.farm_plots = {
  { coord = "A1", shroom = "fly_agaric_t1", time_left = 0, fertilized = 0, wilt_left = -1 },
  { coord = "A2", shroom = "lions_mane_t2", time_left = 3600, fertilized = 1, wilt_left = -1 },
}
S.city_water = 40
S.city_fert = 25
S.blot_status = "open"
S.blot_reset_in = 3661
S.blot_filled = 4
S.blot_total = 9

page_opts.set("show_farm_weather", true)
page_opts.set("show_farm_plots", true)
page_opts.set("show_farm_blot", true)

local farm_lines = farm_page.lines(WIDTH)
local farm_all = joined(farm_lines)

check("farm: non-empty", #farm_lines > 5, #farm_lines)

-- ---- Weather section ---------------------------------------------------
check("farm: Weather header present", find_line(farm_lines, "Weather") ~= nil)
check("farm: season (Spring) present", farm_all:find("Spring", 1, true) ~= nil)
check("farm: weather type (Storm) present", farm_all:find("Storm", 1, true) ~= nil)
check("farm: weather strength (Heavy) present", farm_all:find("Heavy", 1, true) ~= nil)

page_opts.set("show_farm_weather", false)
local farm_no_weather = farm_page.lines(WIDTH)
check("farm: Weather header disappears when show_farm_weather is off",
      find_line(farm_no_weather, "Weather") == nil)
page_opts.set("show_farm_weather", true)

-- ---- Mushroom Farm section ------------------------------------------------
check("farm: Mushroom Farm header present", find_line(farm_lines, "Mushroom Farm") ~= nil)
check("farm: growth modifier row (+15%) present", farm_all:find("+15%% growth rate") ~= nil)

local a1_idx = find_line(farm_lines, "A1")
check("farm: plot row for A1 present", a1_idx ~= nil, farm_all)
if a1_idx then
  check("farm: A1 (ready, unfertilized) shows RDY",
        farm_lines[a1_idx]:find("RDY", 1, true) ~= nil, farm_lines[a1_idx])
end

local a2_idx = find_line(farm_lines, "A2")
check("farm: plot row for A2 present", a2_idx ~= nil, farm_all)
if a2_idx then
  local a2_line = farm_lines[a2_idx]
  check("farm: A2 shows the fertilized marker on its shroom name",
        a2_line:find("Lion's Mane%*") ~= nil, a2_line)
  check("farm: A2 shows its growing time (1h)", a2_line:find("1h", 1, true) ~= nil, a2_line)
end

-- (ANSI resets sit between the label and the value, so match each
-- substring independently rather than one pattern spanning both.)
local water_idx = find_line(farm_lines, "Water:")
check("farm: Water reserve value (40) present",
      water_idx ~= nil and farm_lines[water_idx]:find("40", 1, true) ~= nil, farm_all)
check("farm: Fertilizer reserve value (25) present",
      water_idx ~= nil and farm_lines[water_idx]:find("Fertilizer:", 1, true) ~= nil
      and farm_lines[water_idx]:find("25", 1, true) ~= nil, farm_all)

page_opts.set("show_farm_plots", false)
local farm_no_plots = farm_page.lines(WIDTH)
check("farm: Mushroom Farm header disappears when show_farm_plots is off",
      find_line(farm_no_plots, "Mushroom Farm") == nil)
check("farm: plot rows disappear too", find_line(farm_no_plots, "A1") == nil)
check("farm: water/fertilizer line disappears too",
      find_line(farm_no_plots, "Fertilizer:") == nil)
page_opts.set("show_farm_plots", true)

-- ---- Blot Grove section ----------------------------------------------------
check("farm: Blot Grove header present", find_line(farm_lines, "Blot Grove") ~= nil)
check("farm: blot status (open) present", farm_all:find("Status: ", 1, true) ~= nil
      and farm_all:find("open", 1, true) ~= nil)
check("farm: blot trees (4/9) present", farm_all:find("4/9", 1, true) ~= nil)

local expected_blot_bar = pagelib.bar(WIDTH, 4, 9, C.cyan)
check("farm: blot fill bar matches pagelib.bar(width, 4, 9, cyan) exactly",
      find_line(farm_lines, expected_blot_bar) ~= nil, farm_all)

check("farm: blot reset countdown (1h1m) present", farm_all:find("1h1m", 1, true) ~= nil, farm_all)

page_opts.set("show_farm_blot", false)
local farm_no_blot = farm_page.lines(WIDTH)
check("farm: Blot Grove header disappears when show_farm_blot is off",
      find_line(farm_no_blot, "Blot Grove") == nil)
page_opts.set("show_farm_blot", true)

-- ---- width discipline -------------------------------------------------------
do
  local width_ok, widest = true, nil
  for _, l in ipairs(farm_lines) do
    local vw = pagelib.visible_width(l)
    if vw > WIDTH then width_ok = false; widest = vw end
  end
  check("farm: every row's visible width is <= the requested width", width_ok, widest)
end

-- =============================================================================
-- pages/builds.lua (Task 5) -- LEGACY draw_page4 (guild_viking.lua:9426-9746)
-- =============================================================================

-- ---- seed builds state ------------------------------------------------------
S.pending_builds = {
  { bldg_id = "warehouse", tier = 2, mats_total = 10, mats_done = 3,
    complete_at_secs = -1, total_build_secs = 0,
    mats = { { good = "timber", done = 3, need = 10 } } },
}
S.ship_upgrades = {
  { name = "Ormen", tier = 3, secs_left = -1, mats_total = 5, mats_done = 2,
    mats = { { good = "iron", done = 2, need = 5 } } },
}
S.bdmg = { { bldg_id = "palisade", pct = 72 } }
S.staff_list = {
  { name = "Ragnar", assigned_to = "0", stat_key = "combat",
    stats = { combat = 10, trade = 2 }, trait = "berserker", loyalty = 4,
    age = "young", arrive_at = 0 },
}

page_opts.set("show_builds_construction", true)
page_opts.set("show_builds_upgrades", true)
page_opts.set("show_builds_damage", true)
page_opts.set("show_builds_staff", true)

local builds_lines = builds_page.lines(WIDTH)
local builds_all = joined(builds_lines)

check("builds: non-empty", #builds_lines > 5, #builds_lines)

-- ---- Construction section ---------------------------------------------------
check("builds: Construction header present", find_line(builds_lines, "Construction") ~= nil)
check("builds: pending build row names the building (Warehouse) and tier (T2)",
      builds_all:find("Warehouse", 1, true) ~= nil and builds_all:find("T2", 1, true) ~= nil,
      builds_all)
check("builds: pending build row shows aggregate mats progress (Mats 3/10)",
      builds_all:find("Mats 3/10", 1, true) ~= nil, builds_all)

-- Exact progress-bar assertion: the per-good material row for timber 3/10
-- must equal pagelib.bar's own output for that ratio, hand-composed the
-- same way pages/builds.lua's mat_row does.
local expected_mat_color = pagelib.pct_color(3, 10)
local expected_mat_bar = pagelib.bar(12, 3, 10, expected_mat_color)
-- Mirrors mat_row's CURRENT composition: fixed good and ratio columns via
-- pagelib.trunc, so the bar starts at the same column on every row regardless
-- of how many digits the ratio has.
local expected_mat_row = pagelib.trunc("  "
  .. pagelib.trunc(cc.good_color("timber") .. cc.good_label("timber")
                   .. pagelib.RESET, 13)
  .. pagelib.trunc(pagelib.C.white .. "3/10" .. pagelib.RESET, 12)
  .. expected_mat_bar, WIDTH)
check("builds: timber mat row (3/10) matches the exact pagelib.bar output",
      find_line(builds_lines, expected_mat_row) ~= nil, builds_all)
check("builds: pct_color(3,10) is the 'red' tier (0.3 is > 0.25, <= 0.5)",
      expected_mat_color == C.red, expected_mat_color)

page_opts.set("show_builds_construction", false)
local builds_no_constr = builds_page.lines(WIDTH)
check("builds: Construction header disappears when show_builds_construction is off",
      find_line(builds_no_constr, "Construction") == nil)
page_opts.set("show_builds_construction", true)

-- ---- Ship Upgrades section --------------------------------------------------
check("builds: Ship Upgrades header present", find_line(builds_lines, "Ship Upgrades") ~= nil)
check("builds: upgrade row names the ship (Ormen) and target tier (Drakkar)",
      builds_all:find("Ormen", 1, true) ~= nil and builds_all:find("Drakkar", 1, true) ~= nil,
      builds_all)
check("builds: upgrade mats row (iron 2/5) present",
      builds_all:find("[Ii]ron", 1) ~= nil and builds_all:find("2/5", 1, true) ~= nil, builds_all)

page_opts.set("show_builds_upgrades", false)
local builds_no_upg = builds_page.lines(WIDTH)
check("builds: Ship Upgrades header disappears when show_builds_upgrades is off",
      find_line(builds_no_upg, "Ship Upgrades") == nil)
page_opts.set("show_builds_upgrades", true)

-- ---- Damage section ----------------------------------------------------------
check("builds: Damage header present", find_line(builds_lines, "Damage") ~= nil)
check("builds: damage row names the building (Palisade) and pct (72%)",
      builds_all:find("Palisade", 1, true) ~= nil and builds_all:find("72%%", 1) ~= nil, builds_all)

page_opts.set("show_builds_damage", false)
local builds_no_dmg = builds_page.lines(WIDTH)
check("builds: Damage header disappears when show_builds_damage is off",
      find_line(builds_no_dmg, "Damage") == nil)
page_opts.set("show_builds_damage", true)

-- ---- Hired Folk / Staff section ----------------------------------------------
check("builds: Hired Folk header present", find_line(builds_lines, "Hired Folk") ~= nil)
check("builds: staff row names Ragnar", builds_all:find("Ragnar", 1, true) ~= nil)
check("builds: Ragnar is Unassigned", builds_all:find("Unassigned", 1, true) ~= nil)
check("builds: Ragnar's loyalty (index 4 -> Loyal) present", builds_all:find("Loyal", 1, true) ~= nil)
check("builds: Ragnar's age (Young) present", builds_all:find("Young", 1, true) ~= nil)
check("builds: Ragnar's trait (Berserker) present", builds_all:find("Berserker", 1, true) ~= nil)
-- (a RESET escape sits between "*Cbt" and ":10", so match each half
-- independently on the same row rather than one contiguous pattern.)
local stat_idx = find_line(builds_lines, "*Cbt")
check("builds: Ragnar's highlighted stat (*Cbt:10) present",
      stat_idx ~= nil and builds_lines[stat_idx]:find(":10", 1, true) ~= nil, builds_all)

page_opts.set("show_builds_staff", false)
local builds_no_staff = builds_page.lines(WIDTH)
check("builds: Hired Folk header disappears when show_builds_staff is off",
      find_line(builds_no_staff, "Hired Folk") == nil)
page_opts.set("show_builds_staff", true)

-- ---- width discipline --------------------------------------------------------
do
  local width_ok, widest = true, nil
  for _, l in ipairs(builds_lines) do
    local vw = pagelib.visible_width(l)
    if vw > WIDTH then width_ok = false; widest = vw end
  end
  check("builds: every row's visible width is <= the requested width", width_ok, widest)
end

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING PAGES1 TESTS PASSED")
