-- Per-page context menu, ported from LEGACY guild_viking.lua:11040-11148
-- (PAGE_MENUS), 11165-11209 (viking_show_page_menu) and 11211-11250
-- (viking_page_menu_pick). This is the fifth and last of LEGACY's menu
-- families (the other four -- autotrader settings, auto-raid settings + its
-- target picker, auto-voyage settings -- shipped in stage 4); it is what
-- viking_base_15_page_and_automation_menus was still missing.
--
-- RETARGETED TRIGGER (behavioral change, disclosed): LEGACY opened this from
-- a RIGHT-CLICK anywhere on its plugin window (the hotspot at 11151-11163
-- covering the whole page body). lera has no per-plugin window chrome, so the
-- trigger is a right-click in the surface that renders the page: the pane
-- (window.lua) for the twelve pane pages, and the Map / Sea popups for
-- LEGACY's pages 7 and 10, which are popups here rather than pane pages. The
-- menu itself is lera's input-line menu (require("menu")) instead of a
-- bespoke miniwindow -- content fidelity, not pixel fidelity, the same ruling
-- the four automation menus already ship under.
--
-- Keyed by lera page key rather than LEGACY's numeric page index. The mapping
-- is asserted in tests/guild_viking_page_menu_test.lua rather than left
-- implicit: LEGACY 1,2,3,4,5,6,8,9,11,12,13,14 are the twelve pane pages in
-- window.PAGES order; LEGACY 7 is the Map popup and LEGACY 10 the Sea popup.
--
-- TWO DELIBERATE OMISSIONS from LEGACY's lists:
--   * "Change Font" (LEGACY:11174, appended to EVERY page menu) -- it retuned
--     that plugin window's own font. lera's font is global and
--     composition-level (gui.font_size / gui.set_font), so a plugin page menu
--     has nothing to retune. Portal chrome, dropped like the rest of it.
--   * show_city_plan_icons remains omitted: city-plan graphics are not
--     ported here. Map, Sea and War image controls are available in GUI mode
--     through tiles.lua; TTY/headless sessions always render ASCII.
--
-- Per-item COLOUR is lost (LEGACY:11191-11196 coloured action rows 0xCCCCFF
-- and dimmed OFF toggles to 0x888888): require("menu") rows are plain labels.
-- Same forced adaptation already disclosed for all four automation menus.
-- LEGACY's "[+] " / "[ ] " / ">  " prefixes are byte-faithful.
--
-- Requires ONLY page_opts at the top level, deliberately: window.lua requires
-- this module, persist.lua requires window.lua, and the action rows reach the
-- three automation modules (which themselves reach persist) and popups/map --
-- so every one of those is a lazy, function-body require, the same idiom
-- autoraid.lua/autovoyage.lua/popups.lua already use to keep this graph
-- acyclic.
local page_opts = require("page_opts")

local M = {}

-- LEGACY:11040-11148, verbatim per page (minus the two omissions above), in
-- LEGACY's own row order. `key` rows are page_opts toggles; `action` rows open
-- another menu.
local PAGE_MENUS = {
  -- LEGACY [1]
  stats = {
    { key = "show_stats_xp",    label = "Show Saga XP" },
    { key = "show_stats_buffs", label = "Show Buffs" },
  },
  -- LEGACY [2] (show_city_plan_icons omitted)
  city = {
    { key = "show_city_ships",       label = "Show Longships" },
    { key = "show_city_carts",       label = "Show Carts" },
    { key = "show_city_market",      label = "Show Market" },
    { key = "show_city_warehouse",   label = "Show Warehouse" },
    { key = "show_city_production",  label = "Show Production" },
    { key = "show_city_buildings",   label = "Show Buildings" },
    { key = "show_city_monuments",   label = "Show Monuments" },
    { key = "show_city_plan",        label = "Show City Plan" },
    { key = "show_city_plan_legend", label = "Show City Plan Legend" },
    { key = "show_city_raidlog",     label = "Show Raid Log" },
    { key = "show_city_couriers",    label = "Show Couriers" },
    { key = "show_city_spies",       label = "Show Spies" },
    { key = "show_city_training",    label = "Show Training" },
    { key = "show_city_heat",        label = "Show Lineage Heat" },
    { action = "araid_config",       label = "Auto-Raid settings..." },
  },
  -- LEGACY [3]
  farm = {
    { key = "show_farm_weather", label = "Show Weather" },
    { key = "show_farm_plots",   label = "Show Farm" },
    { key = "show_farm_blot",    label = "Show Blot Grove" },
  },
  -- lera-only (not in LEGACY): the livestock page (Task 2). No LEGACY page
  -- index of its own -- Guild.Livestock's herds/queue/feed/pending/find/
  -- market/needs sections lived in LEGACY's City miniwindow (see
  -- pages/livestock.lua's header for the exact line ranges), gated here
  -- under their own page instead since this port gives them a dedicated tab.
  stock = {
    { key = "show_stock_herds",   label = "Show My Herds" },
    { key = "show_stock_queue",   label = "Show Butchery Queue" },
    { key = "show_stock_feed",    label = "Show Feed" },
    { key = "show_stock_pending", label = "Show Pending Deliveries" },
    { key = "show_stock_find",    label = "Show Livestock Find" },
    { key = "show_stock_market",  label = "Show Market" },
    { key = "show_stock_needs",   label = "Show Pens" },
    -- LEGACY:12625-12626, the two Auto-Herd rows, verbatim. LEGACY carried
    -- them on its City page because every livestock section lived in the City
    -- miniwindow; this port gave those sections their own page, so the rows
    -- follow their content here rather than sitting on a City page that shows
    -- no livestock at all. Same convention as auto_trade on goods/trade and
    -- auto_voyage on sea. Auto-Herd is the one automation that SPENDS the
    -- player's daler, so having no menu presence at all made it the least
    -- visible of the four rather than the most.
    { key = "auto_herd",          label = "Auto-Herd (husbandry)" },
    { action = "aherd_config",    label = "Auto-Herd settings..." },
  },
  -- LEGACY [4]
  builds = {
    { key = "show_builds_construction", label = "Show Construction" },
    { key = "show_builds_upgrades",     label = "Show Ship Upgrades" },
    { key = "show_builds_damage",       label = "Show Damage" },
    { key = "show_builds_staff",        label = "Show Hired Folk" },
  },
  -- LEGACY [5]
  people = {
    { key = "show_people_settlers",         label = "Show Settlers" },
    { key = "show_people_designations",     label = "Show Designations" },
    { key = "show_people_garrison",         label = "Show Garrison" },
    { key = "show_people_raids",            label = "Show Raids" },
    { key = "show_people_thralls",          label = "Show Thralls" },
    { key = "show_people_thrall_companion", label = "Show Thrall Companion" },
    { key = "show_people_missions",         label = "Show Missions" },
  },
  -- LEGACY [6]
  goods = {
    { key = "show_goods_cycle",   label = "Show Demand Cycle" },
    { key = "show_goods_movers",  label = "Show Market Movers" },
    { key = "show_goods_refined", label = "Show Refined Goods" },
    { key = "show_goods_prices",  label = "Show Town Prices" },
    { key = "show_goods_atlog",   label = "Show Auto-Trade Log" },
    { key = "auto_trade",         label = "Auto-Trade (arbitrage)" },
    { action = "atrade_config",   label = "Auto-Trade settings..." },
  },
  -- LEGACY [7] -- shared by the Map tab and popup
  map = {
    { key = "show_map_icons", label = "Images (off = ASCII)", graphical = true },
    { key = "show_map_towns", label = "Show Locations List" },
    { action = "travel",      label = "Travel to..." },
  },
  -- LEGACY [8]
  bonds = {
    { key = "show_bonds_list", label = "Show Bonds List" },
  },
  -- LEGACY [9]
  ranks = {
    { key = "show_ranks_standings",   label = "Show Lineage Standings" },
    { key = "show_ranks_village_rep", label = "Show Village Reputation" },
  },
  -- LEGACY [10] -- shared by the Sea tab and popup
  sea = {
    { key = "show_sea_chart_icons", label = "Images (off = ASCII)", graphical = true },
    { key = "show_sea_voyage",       label = "Show Voyage" },
    { key = "show_sea_chart",        label = "Show Chart" },
    { key = "show_sea_chart_legend", label = "Show Chart Legend" },
    { key = "show_sea_queue",        label = "Show Queue" },
    { key = "show_sea_saga",         label = "Show Saga" },
    { key = "show_sea_memory",       label = "Show Crew Memory" },
    { key = "show_sea_boons",        label = "Show Boons" },
    { key = "show_sea_spoils",       label = "Show Spoils" },
    { key = "show_sea_goods",        label = "Show Goods" },
    { key = "show_sea_aids",         label = "Show Aids" },
    { key = "show_sea_runes",        label = "Show Runes" },
    { key = "show_sea_relics",       label = "Show Relics" },
    { key = "show_sea_curios",       label = "Show Curios" },
    { key = "confirm_chart_click",   label = "Confirm Chart Clicks" },
    { key = "auto_voyage",           label = "Auto-Voyage (autopilot)" },
    { action = "avoyage_config",     label = "Auto-Voyage settings..." },
  },
  -- LEGACY [11]
  court = {
    { key = "show_court_consort",  label = "Show Consort" },
    { key = "show_court_children", label = "Show Children" },
  },
  -- LEGACY [12]
  army = {
    { key = "show_army_levy",  label = "Show Levy" },
    { key = "show_army_units", label = "Show Units" },
    { key = "show_army_siege", label = "Show Siege Park" },
  },
  -- LEGACY [13]
  war = {
    { key = "show_war_battle",    label = "Show Battle" },
    { key = "show_war_ascii",     label = "ASCII Map (off = images)", graphical = true },
    { key = "show_war_council",   label = "Show War Council" },
    { key = "show_war_campaigns", label = "Show Campaigns" },
    { key = "show_war_houses",    label = "Show Great Houses" },
    -- Auto-War belongs on this page for the same reason Auto-Herd sits on
    -- livestock: the automation follows its content. It was the one
    -- automation of the five with no menu presence at all, so the engine in
    -- autowar.lua could not be switched on from the client -- LEGACY's own
    -- awar menu was a MUSHclient miniwindow and never got ported.
    { key = "auto_battle",        label = "Auto-War (campaign + battle)" },
    { action = "awar_config",     label = "Auto-War settings..." },
    { action = "war_saga",        label = "Recent war/battle log (15)" },
    { action = "war_saga_full",   label = "Full war/battle log..." },
  },
  -- LEGACY [14]
  trade = {
    { key = "show_city_carts",      label = "Show Carts" },
    { key = "show_city_market",     label = "Show Market" },
    { key = "show_city_warehouse",  label = "Show Warehouse" },
    { key = "show_city_production", label = "Show Production" },
    { key = "show_goods_atlog",     label = "Show Auto-Trade Log" },
    { key = "auto_trade",           label = "Auto-Trade (arbitrage)" },
    { action = "atrade_config",     label = "Auto-Trade settings..." },
  },
}

-- Menu titles: the page's own name, so the box says what it controls.
local TITLES = {
  stats = "Stats", city = "City", farm = "Farm", stock = "Stock", builds = "Builds",
  people = "People", goods = "Goods", map = "Map", bonds = "Bonds",
  ranks = "Ranks", sea = "Sea", court = "Court", army = "Army",
  war = "War", trade = "Trade",
}

-- LEGACY:11190-11199. `search` is the bare label so typing "saga" matches a
-- row whose visible label starts with a checkbox prefix.
function M.items(page_key)
  local spec = PAGE_MENUS[page_key]
  if not spec then return nil end
  local items = {}
  for _, it in ipairs(spec) do
    if not it.graphical or require("tiles").available() then
    local label, value
    if it.action then
      label = ">  " .. it.label
      value = "action:" .. it.action
    else
      label = (page_opts.get(it.key) and "[+] " or "[ ] ") .. it.label
      value = "key:" .. it.key
    end
    items[#items + 1] = { label = label, value = value, search = it.label }
    end
  end
  return items
end

-- LEGACY:11216-11239. Each action row opens an already-ported menu;
-- require("menu")'s own "opening a menu cancels the open one" contract
-- reproduces LEGACY's explicit viking_close_page_menu() + show call.
local function dispatch_action(action)
  -- The four *_config rows open automation menus that ship only in the
  -- private plugin repo. open_auto() is a no-op in the public base, where the
  -- rows are not offered in the first place (see automation_available below).
  local function open_auto(name)
    local mod = require("util").optional_require(name)
    if mod then mod.open_menu() end
  end
  if action == "atrade_config" then
    open_auto("autotrader.tick")
  elseif action == "araid_config" then
    open_auto("autoraid")
  elseif action == "avoyage_config" then
    open_auto("autovoyage")
  elseif action == "aherd_config" then
    open_auto("autoherd")
  elseif action == "awar_config" then
    open_auto("autowar")
  elseif action == "war_saga" then
    -- The last 15 beats, straight to the output -- a glance, not a session
    -- in a popup. saga.h keeps 40, and "Full war/battle log..." below opens
    -- the scrolling view of all of them.
    local sg = require("popups.war_saga")
    local n = 0
    for _, cat in ipairs({ "war", "battle" }) do
      local rows = sg.entries(cat, 15)
      if #rows > 0 then
        ColourNote("orange", "", "[Viking] " .. (cat == "war" and "War" or "Battle")
          .. " saga, last " .. #rows .. ":")
        for _, r in ipairs(rows) do
          ColourNote("darkorange", "", "  " .. (r.text or ""))
        end
        n = n + #rows
      end
    end
    if n == 0 then ColourNote("orange", "", "[Viking] No deeds recorded yet.") end
  elseif action == "war_saga_full" then
    require("popups").toggle("war_saga")
  elseif action == "travel" then
    require("popups.map").open_poi_menu()
  end
end

-- LEGACY:11243-11247 for the toggle branch: flip, persist immediately, redraw.
-- The one deviation is the reopen -- LEGACY closed the menu after every
-- toggle, which on the sixteen-row Sea page meant a right-click per change.
-- Reopening keeps the list up so several rows can be flipped, and (the real
-- win of lera's input-line menu) typed-filtered in a row.
function M.pick(page_key, value)
  if type(value) ~= "string" then return end
  local kind, rest = value:match("^(%a+):(.+)$")
  if kind == "key" then
    if (rest == "show_map_icons" or rest == "show_sea_chart_icons"
        or rest == "show_war_ascii") and not require("tiles").available() then return end
    if page_opts.get(rest) == nil then return end
    page_opts.set(rest, not page_opts.get(rest))
    require("persist").save()
    ui.dirty()
    M.open(page_key)
  elseif kind == "action" then
    dispatch_action(rest)
  end
end

-- LEGACY:11165-11209. The empty-list guard (11177) is ported even though
-- PAGE_MENUS has no empty page: porting the function, not cleaning it up.
function M.open(page_key)
  local items = M.items(page_key)
  if not items or #items == 0 then return end
  require("menu").open({
    items = items,
    title = TITLES[page_key] or page_key,
    on_select = function(value) M.pick(page_key, value) end,
  })
end

-- True when this page has a context menu at all -- lets a caller decide
-- whether to consume a right-click before opening anything.
function M.has_menu(page_key)
  return PAGE_MENUS[page_key] ~= nil
end

return M
