-- Per-page display toggles for the stage-2 pane (right-click show/hide menus
-- in LEGACY, `/vik set <opt> on|off|toggle` here). Ported VERBATIM from
-- LEGACY's PAGE_OPT_DEFAULTS
-- (/home/simon/code/3s_scripts_old/lua/guild_viking.lua:250-289), comments
-- preserved. Stage-2 pages (stats/city/farm/builds/people/goods/bonds/ranks/
-- court/army/war/trade) consume the show_* keys below; the map/sea/auto_*
-- keys are unused until stages 3/4 but stay ported now since they live in
-- the same source table.
local page_opts = {}

page_opts.defaults = {
  show_stats_xp=true, show_stats_buffs=true,
  show_city_ships=true, show_city_carts=true, show_city_market=true,
  show_city_warehouse=true, show_city_production=true, show_city_buildings=true,
  show_city_monuments=true, show_city_raidlog=true, auto_raid=false,
  show_city_plan=true, show_city_plan_legend=true,
  show_city_plan_icons=false,   -- graphical building/terrain icons (WIP, off by default)
  show_city_couriers=true, show_city_spies=true, show_city_training=true, show_city_heat=true,
  show_farm_weather=true, show_farm_plots=true, show_farm_blot=true,
  show_stock_herds=true, show_stock_queue=true, show_stock_feed=true,
  show_stock_pending=true, show_stock_find=true, show_stock_market=true,
  show_stock_needs=true,
  auto_herd=false,   -- on/off for the client-side auto-husbandry planner
                     -- (Task 4); added here now, like auto_trade/auto_raid/
                     -- auto_voyage before it, since it authorises spending
                     -- and must default off.
  show_builds_construction=true, show_builds_upgrades=true,
  show_builds_damage=true, show_builds_staff=true,
  show_people_settlers=true, show_people_garrison=true, show_people_raids=true,
  show_people_designations=true,
  show_people_thralls=true, show_people_thrall_companion=true, show_people_missions=true,
  show_goods_cycle=true,
  show_goods_movers=true,
  show_goods_refined=true,
  show_goods_prices=true,
  show_goods_atlog=false,
  auto_trade=false,   -- on/off for the client arbitrage trader (was missing here,
                      -- so it never saved/loaded via the popt_ loop below)
  auto_battle=false,  -- on/off for the client-side Auto-War command runner
  auto_voyage=false,  -- on/off for the client-side auto-voyager
  av_verbose=false,   -- echo each auto-voyage action to the main window
  show_map_towns=true,
  show_map_icons=false,   -- Territory Map as City-Plan-style Wang tiles + POI icons
  show_sea_voyage=true,
  show_sea_chart=true,
  show_sea_chart_legend=true,
  show_sea_chart_icons=false,  -- graphical sea-chart tiles (same style as City Plan icons, off by default)
  show_sea_queue=true, show_sea_saga=true, show_sea_memory=true,
  show_sea_boons=true, show_sea_spoils=true, show_sea_goods=true,
  show_sea_aids=true, show_sea_runes=true, show_sea_relics=true, show_sea_curios=true,
  confirm_chart_click=true,
  show_bonds_list=true,
  show_ranks_standings=true, show_ranks_village_rep=true,
  show_court_consort=true, show_court_children=true,
  show_army_levy=true, show_army_units=true, show_army_siege=true,
  show_war_battle=true, show_war_council=true, show_war_campaigns=true, show_war_houses=true,
  show_war_ascii=false,   -- War tab maps in plain ASCII like the in-game vcampaign/vbattle
                          -- text view (same glyphs + colours), instead of tiles/icons

  -- lera-only (not in LEGACY): gates the Stats page's Automation section
  -- (pages/stats.lua, Task 9) -- an on/off + last-action summary for the
  -- three client-side automations (auto-trade/auto-raid/auto-voyage).
  -- LEGACY has no such pane section; its closest analogs are the three
  -- separate settings mini-windows and this port's own /vik status command.
  -- Default true (visible).
  show_stats_automation = true,
}

local values = {}
for k, v in pairs(page_opts.defaults) do values[k] = v end

function page_opts.get(key)
  return values[key]
end

-- Returns false (and makes no change) for a key not in the defaults table;
-- every successful set coerces to a boolean and marks ui.dirty().
function page_opts.set(key, on)
  if page_opts.defaults[key] == nil then return false end
  values[key] = not not on
  ui.dirty()
  return true
end

-- Sorted array of { key = ..., value = ... }, for `/vik opts` and
-- persistence.
function page_opts.all()
  local out = {}
  for k, v in pairs(values) do
    out[#out + 1] = { key = k, value = v }
  end
  table.sort(out, function(a, b) return a.key < b.key end)
  return out
end

return page_opts
