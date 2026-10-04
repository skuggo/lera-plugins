-- guild_viking popups.lua + /vik popup-routing unit tests. Run from the
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
local function make_rect(x, y, w, h)
  return {
    x = function() return x end, y = function() return y end,
    w = function() return w end, h = function() return h end,
  }
end

local dirty_count = 0
local drawn -- { ansi = {...} }, reset per case that cares
local function reset_drawn() drawn = { ansi = {} } end
reset_drawn()

ui = {
  dirty = function() dirty_count = dirty_count + 1 end,
  rect = function(x, y, w, h) return make_rect(x, y, w, h) end,
  text_ansi = function(r, s) drawn.ansi[#drawn.ansi + 1] = { x = r:x(), y = r:y(), s = s } end,
}

local render_pass = "local"
lera = { render_pass = function() return render_pass end, time = function() return 1000 end,
         version = function() return "test" end }

-- Captures each color_print call's text segments, joined, as one entry --
-- lets the "unregistered popup"/"unregistered page" cases assert on the
-- printed message instead of just that a call happened.
local printed = {}
buffer = {
  color_print = function(...)
    local args = { ... }
    local parts = {}
    for i = 3, #args, 3 do
      parts[#parts + 1] = tostring(args[i])
    end
    printed[#printed + 1] = table.concat(parts)
  end,
}
mud = { send = function() end }
local stored = nil
store = {
  load = function() end,
  get = function() return stored end,
  set = function(d) stored = d end,
  save = function() end,
}
local mip_handlers, mip_handler_count = {}, 0
mip = {
  on = function(code, cb)
    mip_handlers[code] = cb
    mip_handler_count = mip_handler_count + 1
    return mip_handler_count
  end,
  off = function() end,
  enabled = function() return true end,
}
local gmcp_handlers, gmcp_handler_count = {}, 0
gmcp = {
  on = function(pkg, cb)
    gmcp_handlers[pkg] = cb
    gmcp_handler_count = gmcp_handler_count + 1
    return gmcp_handler_count
  end,
  remove = function() end,
  enabled = function() return false end,
}
local trigger_reg_count = 0
trigger = {
  add = function() trigger_reg_count = trigger_reg_count + 1; return trigger_reg_count end,
  remove = function() end,
}
local timer_regs = {}
timer = {
  every = function(interval, fn) timer_regs[#timer_regs + 1] = { interval = interval, fn = fn }
    return #timer_regs end,
  remove = function() end,
}
alias = {
  add = function() return 1 end,
  remove = function() end,
}
plugin = { get = function() return nil end }

-- ---- wm.popup facade stub ---------------------------------------------------
-- Sandboxed plugins reach the real popup surface through require("wm").popup
-- (CLAUDE.md "Popup Overlay"); this stub captures every open()/close() call
-- (renderer + opts) instead of loading the real scripts/default/wm.lua +
-- its own require chain (popup/menu/bind), matching the task brief's "a
-- wm.popup facade stub capturing open/close/renderer/opts".
local is_open_flag = false
local current_open = nil -- { renderer = ..., opts = ... }
local opens = {}          -- history of every open() call, in order
local close_count = 0

local function finish_popup()
  local old = current_open
  current_open = nil
  is_open_flag = false
  close_count = close_count + 1
  if old and old.opts and old.opts.on_close then old.opts.on_close() end
end

package.loaded["wm"] = {
  popup = {
    -- Mirrors scripts/default/popup.lua's real _open: an already-open popup
    -- is torn down (firing ITS on_close) before the new one is installed.
    open = function(renderer, opts)
      if is_open_flag then finish_popup() end
      current_open = { renderer = renderer, opts = opts }
      is_open_flag = true
      opens[#opens + 1] = current_open
      return true
    end,
    close = function()
      if not is_open_flag then return false end
      finish_popup()
      return true
    end,
    is_open = function() return is_open_flag end,
  },
}

-- Command registry stub: captures the /vik spec so its handler can be
-- dispatched directly later, same idiom as guild_viking_test.lua.
local registered_vik = nil
local real_require = require
require = function(name)
  if name == "command" then
    return { register = function(spec) registered_vik = spec; return 1 end,
             unregister = function() return true end,
             get = function() return nil end, list = function() return {} end }
  end
  return real_require(name)
end

-- =============================================================================
-- popups.lua: registry / toggle / wrapper mechanics (stubbed wm.popup)
-- =============================================================================
local popups = require("popups")
local window = require("window")

-- ---- register + toggle opens with the module's title and 0.9 sizing --------
local map_lines_calls = 0
local map_module = {
  title = "Territory Map",
  lines = function(w)
    map_lines_calls = map_lines_calls + 1
    local out = {}
    for i = 1, 5 do out[i] = "row " .. i end
    return out
  end,
}
popups.register("map", map_module)

check("toggle unknown-until-registered map returns true now that it's registered",
      popups.toggle("map") == true)
check("wm.popup reports open", is_open_flag == true)
check("popup opened with the module's title", opens[1].opts.title == "Territory Map")
check("popup opened at width 0.9", opens[1].opts.width == 0.9)
check("popup opened at height 0.9", opens[1].opts.height == 0.9)
check("popup renderer has a render function", type(opens[1].renderer.render) == "function")
check("popup renderer has a scroll function", type(opens[1].renderer.scroll) == "function")

-- ---- wrapper renders windowed lines into a stub rect and scrolls -----------
reset_drawn()
opens[1].renderer.render(make_rect(0, 0, 10, 3), { title = "Territory Map" })
check("wrapper called the module's lines()", map_lines_calls >= 1)
check("wrapper drew rows clamped to the rect height (3)", #drawn.ansi == 3)
check("wrapper drew row 1 first", drawn.ansi[1] and drawn.ansi[1].s:find("row 1", 1, true) ~= nil,
      drawn.ansi[1] and drawn.ansi[1].s)
check("wrapper following_tail true before scrolling",
      opens[1].renderer.following_tail() == true)

opens[1].renderer.scroll(2)
check("wrapper following_tail false after scrolling", opens[1].renderer.following_tail() == false)
reset_drawn()
opens[1].renderer.render(make_rect(0, 0, 10, 3), { title = "Territory Map" })
check("wrapper windowed to the new offset (starts at row 3)",
      drawn.ansi[1] and drawn.ansi[1].s:find("row 3", 1, true) ~= nil,
      drawn.ansi[1] and drawn.ansi[1].s)

-- remote pass must not disturb the cached count/clamp the local pass depends on
render_pass = "remote"
reset_drawn()
local ok_remote = pcall(opens[1].renderer.render, make_rect(0, 0, 4, 1), { title = "x" })
check("remote render at a different size does not error", ok_remote)
render_pass = "local"
reset_drawn()
opens[1].renderer.render(make_rect(0, 0, 10, 3), { title = "Territory Map" })
check("local render unchanged after an intervening remote render",
      drawn.ansi[1] and drawn.ansi[1].s:find("row 3", 1, true) ~= nil,
      drawn.ansi[1] and drawn.ansi[1].s)

-- ---- toggle same name closes ------------------------------------------------
check("toggle same name (map) closes", popups.toggle("map") == true)
check("wm.popup now closed", is_open_flag == false)
check("close_count incremented", close_count == 1)

-- ---- toggle other name replaces (old on_close fired) ------------------------
popups.toggle("map") -- reopen
local sea_module = { title = "Sea Chart", lines = function() return { "a", "b" } end }
popups.register("sea", sea_module)

local before_close_count = close_count
check("toggle other name (sea) opens", popups.toggle("sea") == true)
check("old (map) on_close fired during replace", close_count == before_close_count + 1)
check("now open and showing sea's title", is_open_flag == true and opens[#opens].opts.title == "Sea Chart")

check("toggle sea again closes it", popups.toggle("sea") == true)
check("closed after second toggle", is_open_flag == false)

-- ---- toggle on an unregistered name -----------------------------------------
printed = {}
check("toggle unregistered name returns false", popups.toggle("nope") == false)
check("toggle unregistered name does not open a popup", is_open_flag == false)
check("toggle unregistered name prints a friendly message",
      #printed >= 1 and printed[#printed]:find("nope", 1, true) ~= nil, printed[#printed])

-- ---- on_pointer forwarding: ctx carries close() -----------------------------
local seen_ev, seen_ctx
local pointer_module = {
  title = "Pointer Test",
  lines = function() return { "L1" } end,
  on_pointer = function(ev, ctx) seen_ev, seen_ctx = ev, ctx; return true end,
}
popups.register("voyage", pointer_module)
popups.toggle("voyage")
check("wrapper exposes on_pointer when the module has one",
      type(opens[#opens].renderer.on_pointer) == "function")
local down = { kind = "down", button = "left", x = 1, y = 0, inside = true, width = 10, height = 3 }
check("on_pointer forwards the event and returns the module's result",
      opens[#opens].renderer.on_pointer(down) == true)
check("on_pointer received the same event table", seen_ev == down)
check("ctx carries a close function", type(seen_ctx.close) == "function")
seen_ctx.close()
check("ctx.close() closed the popup", is_open_flag == false)

-- ---- open_page wraps a window.PAGES entry (no on_pointer) and scrolls ------
reset_drawn()
check("open_page('stats') returns true", popups.open_page("stats") == true)
check("open_page opened a popup", is_open_flag == true)
local stats_open = opens[#opens]
check("open_page popup titled from the page label", stats_open.opts.title == "Stats")
check("open_page popup width 0.9", stats_open.opts.width == 0.9)
check("open_page popup height 0.9", stats_open.opts.height == 0.9)
check("open_page wrapper has no on_pointer (pane pages have none)",
      stats_open.renderer.on_pointer == nil)

reset_drawn()
local ok_render, err_render = pcall(stats_open.renderer.render, make_rect(0, 0, 80, 10),
                                     { title = "Stats" })
check("open_page wrapper renders the real stats page without error", ok_render, err_render)
check("open_page wrapper drew at least one row", #drawn.ansi > 0)

local ok_scroll = pcall(function()
  stats_open.renderer.scroll(3)
  stats_open.renderer.scroll(-3)
end)
check("open_page wrapper scroll() does not error", ok_scroll)

check("open_page unknown page returns false", popups.open_page("no_such_page") == false)

if is_open_flag then package.loaded["wm"].popup.close() end
check("popup closed before moving to /vik routing tests", is_open_flag == false)

-- =============================================================================
-- placeholder strings: pages/city.lua + pages/war.lua drop " (stage 3)"
-- =============================================================================
local page_opts = require("page_opts")
local S = require("state").S

page_opts.set("show_city_plan", true)
local city_lines = window.PAGES[2].mod.lines(80) -- city
-- The City page no longer points at the popup: it renders the plan inline,
-- through popups.cityplan.inline_lines(). With no plan data loaded that is the
-- section header plus the "view it in-game" line, which is what proves the
-- section is present rather than a one-line pointer to /vik cityplan.
local city_plan_header, city_plan_nodata, stale_pointer = false, false, false
for _, l in ipairs(city_lines) do
  if l:find("City Plan", 1, true) then city_plan_header = true end
  if l:find("No data", 1, true) then city_plan_nodata = true end
  if l:find("City plan: /vik cityplan", 1, true) then stale_pointer = true end
  if l:find("(stage 3)", 1, true) then
    check("city.lua placeholder no longer says (stage 3)", false, l)
  end
end
check("city.lua renders the City Plan section inline", city_plan_header)
check("city.lua shows the no-data line when no plan has loaded", city_plan_nodata)
check("city.lua no longer points at the popup", not stale_pointer)

-- The War tab used to carry a placeholder pointing at the popup ("Battle
-- map: /vik war"). It draws the campaign board inline now, falling back to
-- a hint only when the pane is too narrow for the grid -- so the assertion
-- is that one of the two appears, not that the pointer survives.
--
-- Still gated on active data (M.lines gates campaign_map_lines on
-- S.war_map.active) -- minimal seed, same shape as
-- guild_viking_window_test.lua's Task-10 seed.
S.war_map = { active = true, dim = 1, turn = 1, mode = "offense", pending = 0,
              town = "Jorvik", works_budget = 0, march_eta = 0, rows = { "." } }
local war_lines = window.PAGES[11].mod.lines(80) -- war
check("window.PAGES[11] is the war page", window.PAGES[11].key == "war")
local war_board_found = false
for _, l in ipairs(war_lines) do
  -- Either the board itself (its header) or the narrow-pane fallback.
  if l:find("War Campaign:", 1, true)
     or l:find("too wide for this pane", 1, true) then war_board_found = true end
  if l:find("(stage 3)", 1, true) then
    check("war.lua placeholder no longer says (stage 3)", false, l)
  end
end
check("war.lua draws the campaign board inline", war_board_found)

-- =============================================================================
-- /vik dispatch: routing to popups.toggle/open_page, "page"/"pop"
-- subcommands, and the war name-collision ruling
-- =============================================================================
local M = dofile("3scapes/guild_viking/init.lua")
M.on_load()
check("vik registered", registered_vik ~= nil and registered_vik.name == "/vik")

-- popups.toggle with an unregistered name prints its own friendly message
-- and opens nothing. Task 5's probe used "war" here, banking on it being
-- the one POPUP_NAMES member still unregistered at this point in the file;
-- Task 6 gave popups.lua a REAL self-registered "war" module (see the
-- bottom of popups.lua), so requiring "popups" above now registers it
-- before this file ever reaches this line -- "war" stopped being a valid
-- probe. Fixed by testing popups.toggle directly with a permanently-fake
-- name (never a real POPUP_NAMES member, so no future task can register it
-- out from under this probe) instead of routing through /vik. The
-- complementary property the old probe also checked -- a POPUP_NAMES
-- member opens its popup rather than switching the pane, even though the
-- name is ALSO a window.PAGES key -- is covered more strongly below by the
-- registered "war" stub ("bare /vik war opened the popup, not the pane").
window.set_page("stats")
printed = {}
local ok_unregistered = popups.toggle("zz_never_registered_popup")
check("popups.toggle with an unregistered name returns false", ok_unregistered == false)
check("popups.toggle with an unregistered name opens nothing", is_open_flag == false)
check("popups.toggle with an unregistered name printed its own message",
      #printed >= 1 and printed[#printed]:find("zz_never_registered_popup", 1, true) ~= nil,
      printed[#printed])

-- Stage 1 registers no named popups yet; register a throwaway "war" module
-- directly through popups.lua (the same singleton init.lua's dispatch uses)
-- so the routing itself can be exercised ahead of Task 6's real content.
local war_popup_calls = 0
popups.register("war", {
  title = "Campaign & Battle",
  lines = function() war_popup_calls = war_popup_calls + 1; return { "x" } end,
})

window.set_page("stats")
registered_vik.handler("war", "/vik")
check("bare /vik war opened the popup, not the pane",
      is_open_flag == true and window.current_page() == "stats")
check("bare /vik war's popup is titled from the war module",
      opens[#opens].opts.title == "Campaign & Battle")
package.loaded["wm"].popup.close()
check("popup closed after bare /vik war test", is_open_flag == false)

registered_vik.handler("page war", "/vik")
check("/vik page war switches the pane to war", window.current_page() == "war")
check("/vik page war did not open a popup", is_open_flag == false)

window.set_page("stats")
registered_vik.handler("stats", "/vik")
check("bare /vik stats still switches the pane (non-colliding key)",
      window.current_page() == "stats" and is_open_flag == false)

window.set_page("stats")
registered_vik.handler("city", "/vik")
check("bare /vik city still switches the pane", window.current_page() == "city")
window.set_page("stats")

registered_vik.handler("pop goods", "/vik")
check("/vik pop goods opened a popup", is_open_flag == true)
check("/vik pop goods popup titled Goods", opens[#opens].opts.title == "Goods")
check("/vik pop goods did not touch the pane page", window.current_page() == "stats")
package.loaded["wm"].popup.close()

printed = {}
registered_vik.handler("pop no_such_page", "/vik")
check("/vik pop <unknown page> did not open a popup", is_open_flag == false)
check("/vik pop <unknown page> printed a message", #printed >= 1)

printed = {}
registered_vik.handler("page", "/vik")
check("/vik page with no key prints usage", #printed >= 1 and printed[#printed]:find("Usage", 1, true) ~= nil)

printed = {}
registered_vik.handler("pop", "/vik")
check("/vik pop with no key prints usage", #printed >= 1 and printed[#printed]:find("Usage", 1, true) ~= nil)

-- =============================================================================
-- Task 7: end-to-end popup pass -- real content, real popup-inner dimensions
-- =============================================================================
-- Earlier cases in this file install stub renderer modules under "map"/
-- "sea"/"voyage"/"war" (to exercise popups.lua's wrapper mechanics in
-- isolation from any popup's own content) -- re-register the REAL content
-- modules here. require() is cached, so this recovers the exact module
-- objects popups.lua's own self-registration installed at file-load time;
-- only the REGISTRY entries above were ever overwritten, never the modules.
popups.register("map", require("popups.map"))
popups.register("sea", require("popups.sea"))
popups.register("voyage", require("popups.voyage"))
popups.register("cityplan", require("popups.cityplan"))
popups.register("war", require("popups.war"))

local pagelib = require("pagelib")
local protocol = require("protocol")

-- menu stub (require("menu") facade: open/close/is_open), same idiom as the
-- per-popup suites -- sea/voyage/cityplan/war's on_pointer open a menu on
-- some inputs (e.g. voyage's "[Actions]" line, cityplan's right-click
-- context menu); nothing below deliberately targets those inputs, but a
-- coincidental hit must not error for want of this stub.
local last_menu_open = nil
package.loaded["menu"] = {
  open = function(opts) last_menu_open = opts end,
  close = function() last_menu_open = nil end,
  is_open = function() return last_menu_open ~= nil end,
}

-- ---- broad state slice: real content for every named popup -----------------
-- Borrowed seed shapes from the per-popup suites (production handlers via
-- protocol.ingest, never hand-poked S) -- init.lua's top-level requires,
-- already run above via `M = dofile(...)`, registered handlers.voyage/
-- handlers.city/handlers.kingdom/handlers.trade with protocol.handler, so
-- these ingests drive the real handler code, not a test-local shortcut.

-- vmap (map popup): guild_viking_popup_map_test.lua's seed_vmap shape. The
-- territory map is GMCP-only, so this one arrives as a Guild.Map frame rather
-- than through protocol.ingest; init.lua's requires above registered the
-- composite writer along with every MIP handler. Terrain rows carry no player
-- marker -- popups/map.lua draws that itself from `pos`.
protocol.on_gmcp("Guild.Map", {
  guild = "viking", w = 4, h = 4, active = 1, pos = { x = 1, y = 1 },
  enc = { terrain = "glyph", east = "glyph", south = "glyph" },
  terrain = { "ph..", "AfW.", "....", "...." },
  landmarks = { { type = "capital", name = "asgard", x = 0, y = 0, owner = "" } },
})
page_opts.set("show_map_towns", true)
-- The fixture above is the only one here that travels by GMCP, where a wrong
-- guild name or an unregistered writer drops the frame silently and leaves
-- the map popup rendering its empty-state text -- which every case below
-- would still pass against. Pinned so it cannot go quietly vacuous.
check("(fixture) the Guild.Map frame reached the writer",
      S.vmap_w == 4 and S.vmap_rows[2] == "AfW." and #S.vmap_pois == 1)

-- chart + voyage status (sea + voyage popups):
-- guild_viking_popup_sea_test.lua's VOYAGE/VCHH/VCR/VSAILED/VQPATH/VSAGA/
-- VMEM seed.
protocol.on_gmcp("Guild.Voyage", { guild = "viking",
  voyage = { state = "sailing", ship_id = 1, ship_name = "Ormen",
    contract_name = "Raid Fjordholm", contract_type = "raid", danger = 3,
    x = 5, y = 6, width = 20, height = 20, hull = 80, morale = 70,
    supplies = 60, hull_stress = 10, crew_alive = 4, crew_max = 5,
    steps_sailed = 12, next_move_in = 30, threat_name = "Kraken",
    threat_level = 2, threat_pressure = 40, paused_type = "",
    weather_key = "storm", captain_style = "Erik", ship_identity = "proud" },
  voyage_crew_traits = { "brave", "loyal" },
  voyage_ship_traits = { "swift", "sturdy" },
  fleet_renown = 1500,
  vsailed = { "1,0" },
  vqpath = { "N", "N", "E", "SE" },
  vsaga = { "Captain style: bold", "The fleet set sail." },
  vmem = { "Remembered the reefs of Fjordholm." },
})
protocol.on_gmcp("Guild.Voyage", { guild = "viking",
  voyage_chart = { width = 4, height = 4, chart_mode = "test" },
  voyage_chart_rows = { "S#H?", "OMBD", "++XY", "VCA*" } })
page_opts.set("show_sea_voyage", true)
page_opts.set("show_sea_chart", true)
page_opts.set("show_sea_queue", true)
page_opts.set("show_sea_saga", true)
page_opts.set("show_sea_memory", true)

-- city plan (cityplan popup): guild_viking_popup_cityplan_test.lua's
-- seed_cplan shape (margin defaults to 0 here, same as that helper, so
-- the grid's interior origin (0,0) is directly hit-testable).
protocol.on_gmcp("Guild.City", { guild = "viking",
  cityplan = { enabled = 1, dim = 3, placed = 1, cap = 20, coast_side = 1,
               moat = 0, wall = 0, gate = 6, mood_delta = 0, margin = 0 },
  cityplan_terrain = { "...", ".H.", "..." },
  cityplan_buildings = { { id = "hall", x = 1, y = 1, w = 1, h = 1, pal = "e",
                           glyph = "H", name = "Great Hall" } },
})
page_opts.set("show_city_plan", true)
page_opts.set("show_city_plan_legend", true)

-- war map + battle (war popup): guild_viking_popup_war_test.lua's
-- seed_wmap/seed_battle shape. Battle takes priority over the campaign map
-- once S.battle is present (popups/war.lua's active_module()), so seeding
-- both exercises that composite's real precedence, not just one branch.
protocol.on_gmcp("Guild.Kingdom", { guild = "viking",
  campaign = { active = 1, dim = 3, turn = 7, mode = "offense", pending = 0,
               town = "Jorvik", works_budget = 0, march_eta = 0 },
  campaign_terrain = { "f.w", "H..", "..." },
  campaign_units = { { kind = "host", id = "", c = 0, r = 2, size = 10,
                       flag = "N" } },
})
protocol.on_gmcp("Guild.War", { guild = "viking",
  active = 1, phase = "deploy", turn = 1, war_points = 15, mode = "field",
  target = "Fjordvik", budget = 100, spent = 20, w = 3, h = 2, dz = 1,
  terrain = { "..#", "^*w" }, works = { "v.u", "..." },
  units = { { side = "Y", label = "Huscarl Guard", size = 8, coord = "A2",
              morale = 80, type = "huscarls", leader = "", bid = 101,
              ord = 0 } },
  reserve = {},
})
page_opts.set("show_war_battle", true)

-- ---- five named popups: toggle open, render at both sizes, width
-- discipline (raw module lines), pointer smoke, wrapper scroll -------------
local NAMED_POPUPS = {
  { name = "map", mod = require("popups.map") },
  { name = "sea", mod = require("popups.sea") },
  { name = "voyage", mod = require("popups.voyage") },
  { name = "cityplan", mod = require("popups.cityplan") },
  { name = "war", mod = require("popups.war") },
}
local POPUP_SIZES = { { w = 76, h = 22 }, { w = 36, h = 10 } }

for _, entry in ipairs(NAMED_POPUPS) do
  local name, mod = entry.name, entry.mod
  for _, sz in ipairs(POPUP_SIZES) do
    local w, h = sz.w, sz.h
    local label = name .. " at " .. w .. "x" .. h

    check(label .. ": toggle opens", popups.toggle(name) == true)
    local renderer = opens[#opens].renderer

    reset_drawn()
    local ok_render = pcall(renderer.render, make_rect(0, 0, w, h), { title = mod.title })
    check(label .. ": render does not error", ok_render)
    check(label .. ": render drew at least one content row", #drawn.ansi > 0)

    -- Width discipline measured on the RAW module lines (pre-trunc) -- the
    -- honest measure. The wrapper's own render() runs every line through
    -- pagelib.trunc before drawing it, which would quietly hide a module
    -- bug that emits an over-width line; mod.lines(w) is what the module
    -- itself actually produced.
    local raw_lines = mod.lines(w)
    local over_width = 0
    for _, l in ipairs(raw_lines) do
      if pagelib.visible_width(l) > w then over_width = over_width + 1 end
    end
    check(label .. ": raw module lines respect " .. w .. " cols of width discipline",
      over_width == 0, over_width)

    -- Pointer smoke: one in-bounds down dispatches without error, one
    -- out-of-bounds no-ops. map/sea/cityplan/war are grid-based (geometry +
    -- grid_line_offset); the wrapper-local (0, grid_line_offset(w)) maps to
    -- the grid's own (0,0) origin (verified against the per-popup suites'
    -- own maplib convention), which is real seeded content for all four.
    -- voyage has no grid, only its "[Actions]" line (actions_line_index).
    local in_ev
    if mod.grid_line_offset then
      in_ev = { kind = "down", button = "left", x = 0, y = mod.grid_line_offset(w),
                inside = true, width = w, height = h }
    elseif mod.actions_line_index then
      local idx = mod.actions_line_index(w)
      in_ev = { kind = "down", button = "left", x = 0, y = (idx and idx - 1) or 0,
                inside = true, width = w, height = h }
    else
      in_ev = { kind = "down", button = "left", x = 0, y = 0, inside = true, width = w, height = h }
    end
    local ok_in = pcall(renderer.on_pointer, in_ev)
    check(label .. ": in-bounds pointer down dispatches without error", ok_in)

    local out_ev = { kind = "down", button = "left", x = w + 500, y = h + 500,
                      inside = false, width = w, height = h }
    local ok_out, result_out = pcall(renderer.on_pointer, out_ev)
    check(label .. ": out-of-bounds pointer down does not error", ok_out)
    check(label .. ": out-of-bounds pointer down no-ops (does not consume)",
      result_out ~= true, result_out)

    -- Wrapper scroll +-5 renders without error.
    local ok_scroll = pcall(function()
      renderer.scroll(5)
      renderer.render(make_rect(0, 0, w, h), { title = mod.title })
      renderer.scroll(-5)
      renderer.render(make_rect(0, 0, w, h), { title = mod.title })
    end)
    check(label .. ": wrapper scroll +-5 renders without error", ok_scroll)

    -- Single-popup invariant: toggle-close before the next size/popup.
    check(label .. ": toggle closes", popups.toggle(name) == true)
    check(label .. ": popup closed after toggle-close", is_open_flag == false)
  end
end

-- ---- /vik pop over all twelve pane pages at both sizes (render + scroll,
-- no pointer) -----------------------------------------------------------
for _, page in ipairs(window.PAGES) do
  for _, sz in ipairs(POPUP_SIZES) do
    local w, h = sz.w, sz.h
    local label = "pop " .. page.key .. " at " .. w .. "x" .. h

    check(label .. ": open_page opens", popups.open_page(page.key) == true)
    local renderer = opens[#opens].renderer

    reset_drawn()
    local ok_render = pcall(renderer.render, make_rect(0, 0, w, h), { title = page.label })
    check(label .. ": render does not error", ok_render)
    check(label .. ": render drew at least one content row", #drawn.ansi > 0)

    local ok_scroll = pcall(function()
      renderer.scroll(5)
      renderer.render(make_rect(0, 0, w, h), { title = page.label })
      renderer.scroll(-5)
      renderer.render(make_rect(0, 0, w, h), { title = page.label })
    end)
    check(label .. ": wrapper scroll +-5 renders without error", ok_scroll)

    -- Single-popup invariant: close before the next page/size (open_page
    -- always replaces whatever is open, but closing explicitly here keeps
    -- this loop's own invariant obvious rather than relying on the next
    -- iteration's open() to tear the previous one down).
    check(label .. ": popup closes", package.loaded["wm"].popup.close() == true)
  end
end
check("all twelve pages closed cleanly", is_open_flag == false)

pcall(M.on_unload)

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING POPUPS TESTS PASSED")
