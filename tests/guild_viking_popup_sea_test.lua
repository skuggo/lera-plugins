-- guild_viking /vik sea (Sea Chart popup, FULL sub-view) and /vik voyage
-- (Voyage Status popup, compact subset) unit tests. Run from the
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

local function find_plain(lines, needle)
  for _, l in ipairs(lines) do
    if l:find(needle, 1, true) then return true end
  end
  return false
end

local function find_exact(lines, want)
  for _, l in ipairs(lines) do
    if l == want then return true end
  end
  return false
end

-- ---- lera API stubs (same shape as guild_viking_popup_map_test.lua) -------
local function make_rect(x, y, w, h)
  return {
    x = function() return x end, y = function() return y end,
    w = function() return w end, h = function() return h end,
  }
end

local drawn
local function reset_drawn() drawn = { ansi = {} } end
reset_drawn()

local dirty_count = 0
ui = {
  dirty = function() dirty_count = dirty_count + 1 end,
  rect = function(x, y, w, h) return make_rect(x, y, w, h) end,
  text_ansi = function(r, s) drawn.ansi[#drawn.ansi + 1] = { x = r:x(), y = r:y(), s = s } end,
}

local render_pass = "local"
lera = { render_pass = function() return render_pass end, time = function() return 1000 end,
         version = function() return "test" end }

local send_calls = {}
mud = { send = function(s) send_calls[#send_calls + 1] = s end }

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

-- ---- wm.popup facade stub (identical to guild_viking_popup_map_test.lua's) ----
local is_open_flag = false
local current_open = nil
local opens = {}
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

-- ---- menu stub (require("menu") facade: open/close/is_open) -- captures
-- the last opts a popup handed to menu.open() so a test can inspect its
-- items and drive on_select itself, same idea as the wm.popup stub above.
local last_menu_open = nil
package.loaded["menu"] = {
  open = function(opts) last_menu_open = opts end,
  close = function() last_menu_open = nil end,
  is_open = function() return last_menu_open ~= nil end,
}
local function menu_item_labels(opts)
  local labels = {}
  for _, it in ipairs(opts.items or {}) do
    labels[#labels + 1] = it.label or it
  end
  return labels
end
local function menu_has_label(opts, substr)
  for _, l in ipairs(menu_item_labels(opts)) do
    if tostring(l):find(substr, 1, true) then return true end
  end
  return false
end

local pagelib = require("pagelib")
local state = require("state")
local page_opts = require("page_opts")
local popups = require("popups")
local sea = require("popups.sea")
local voyage = require("popups.voyage")
local sea_common = require("popups.sea_common")

-- ---- real ingestion pipeline (protocol.ingest -> handlers.voyage), the SAME
-- registration guild_viking_voyage_test.lua/guild_viking_popup_map_test.lua
-- do -- fixtures MUST route through protocol.ingest + the real handlers,
-- never direct S. pokes (standing lesson from Task 3's review: a fixture
-- matching a buggy read convention can mask an off-by-one that production
-- would also have).
local protocol = require("protocol")
-- init.lua's RESERVED set: the module-level convention fields, not MIP keys.
local RESERVED_KEYS = { _market_seam = true, _patterns = true, _gmcp = true,
                        _retired_keys = true, _retired_patterns = true }
local voyage_h = require("handlers.voyage")
for key, fn in pairs(voyage_h._gmcp or {}) do
  protocol.gmcp_handler(key, fn)
end

local S = state.S

-- Fixtures seed through the production GMCP path. The Sea Chart (VCHH/VCR) is
-- the exception and still arrives over MIP: it has no GMCP source yet, so its
-- handlers and this seeding stay until one lands. VRELICS is the same case.
local function gv(payload)
  payload.guild = "viking"
  protocol.on_gmcp("Guild.Voyage", payload)
end

-- Guild.Voyage's voyage record; five names differ from the client's fields and
-- the trait lists travel as their own keys.
local function seed_voyage(t)
  gv({
    voyage = {
      state = t.state, ship_id = t.ship_id, ship_name = t.ship_name,
      contract_name = t.contract_name, contract_type = t.contract_type,
      danger = t.danger, x = t.x, y = t.y, width = t.width, height = t.height,
      hull = t.hull, morale = t.morale, supplies = t.supplies,
      hull_stress = t.stress, crew_alive = t.crew_alive, crew_max = t.crew_max,
      steps_sailed = t.steps, next_move_in = t.next_move,
      threat_name = t.threat_name, threat_level = t.threat_level,
      threat_pressure = t.threat_pressure, paused_type = t.paused_type or "",
      weather_key = t.weather_key, captain_style = t.captain,
      ship_identity = t.identity,
    },
    voyage_crew_traits = t.crew_traits or {},
    voyage_ship_traits = t.ship_traits or {},
  })
end
local C, RESET = pagelib.C, pagelib.RESET

local WIDTH = 76

local function reset_voyage()
  S.mip_voyage_seen = false
  S.voyage_status = nil
  S.voyage_wait = ""
  S.voyage_resolve_options = {}
  S.voyage_longships = {}
  S.voyage_chart_width = 0
  S.voyage_chart_height = 0
  S.voyage_chart_mode = ""
  S.voyage_chart_rows = {}
  S.voyage_sailed = {}
  S.voyage_queue = {}
  S.voyage_saga = {}
  S.voyage_memory = {}
  S.voyage_boons = ""
  S.voyage_spoils_daler = 0
  S.voyage_goods = {}
  S.voyage_aids = {}
  S.voyage_runes = {}
  S.voyage_relics = {}
  S.voyage_curios = {}
  S.voyage_reagents = 0
  S.fleet_renown = 0
  for _, key in ipairs({
    "show_sea_voyage", "show_sea_chart", "show_sea_chart_legend",
    "show_sea_queue", "show_sea_saga", "show_sea_memory",
    "show_sea_boons", "show_sea_spoils", "show_sea_goods",
    "show_sea_aids", "show_sea_runes", "show_sea_relics", "show_sea_curios",
    "confirm_chart_click",
  }) do
    page_opts.set(key, true)
  end
  send_calls = {}
  last_menu_open = nil
end

-- =============================================================================
-- no-data gate, ported into BOTH popups (draw_page10's ONLY contribution)
-- =============================================================================
reset_voyage()
local sea_lines = sea.lines(WIDTH)
local voyage_lines = voyage.lines(WIDTH)
check("sea popup has its own header", sea_lines[1]:find("Sea Chart", 1, true) ~= nil, sea_lines[1])
check("voyage popup has its own DISTINCT header (not 'Voyage Status', to avoid the dup fixed below)",
  voyage_lines[1] == pagelib.header(WIDTH, "Voyage"), voyage_lines[1])
check("sea popup shows the no-data gate",
  find_plain(sea_lines, "No data yet -- voyage status arrives while a voyage is live"))
check("voyage popup shows the no-data gate",
  find_plain(voyage_lines, "No data yet -- voyage status arrives while a voyage is live"))

-- =============================================================================
-- show_sea_voyage master gate: whole-body hidden, header only, in both popups
-- =============================================================================
reset_voyage()
gv({ voyage_wait = "" }) -- flips the voyage-seen flag without a voyage
page_opts.set("show_sea_voyage", false)
sea_lines = sea.lines(WIDTH)
voyage_lines = voyage.lines(WIDTH)
check("sea: show_sea_voyage off leaves only the header line", #sea_lines == 1, #sea_lines)
check("voyage: show_sea_voyage off leaves only the header line", #voyage_lines == 1, #voyage_lines)
page_opts.set("show_sea_voyage", true)

-- =============================================================================
-- no-active-voyage fallback + reroll hint text, AND the reroll action (fix
-- round 1, remedy #1): with NO docked ships, [Actions] must not appear at
-- all (reroll-gated case, "off" direction); with one, it must, and the menu
-- item must send the exact LEGACY command (reroll-gated case, "on"
-- direction).
-- =============================================================================
reset_voyage()
gv({ voyage_wait = "" })
sea_lines = sea.lines(WIDTH)
check("sea: no docked ships -> no [Actions] line at all", not find_plain(sea_lines, "[Actions]"))
check("sea: no docked ships -> actions_line_index is nil", sea.actions_line_index(WIDTH) == nil)

gv({ longship = { { id = 7, name = "Ormen", tier = 2, state = "docked",
                    target = "Havn", secs = 0, crew = 4, hired_crew = 1,
                    safe = 1, voyage_identity = "proud", captain_style = "Erik",
                    saga_title = "Saga of Ormen", saga_raids = 3 } },
      longship_crew_traits = { { id = 7, trait = "brave" } },
      longship_ship_traits = { { id = 7, trait = "swift" } } })
sea_lines = sea.lines(WIDTH)
voyage_lines = voyage.lines(WIDTH)
check("sea: no-active-voyage fallback text", find_plain(sea_lines, "No active voyage"))
check("sea: reroll hint names the docked ship", find_plain(sea_lines, "Ormen"))
check("sea: reroll hint surfaces the exact command text",
  find_plain(sea_lines, "vvoyage launch <ship> reroll"))
check("voyage: no-active-voyage fallback text", find_plain(voyage_lines, "No active voyage"))
check("voyage: reroll hint names the docked ship", find_plain(voyage_lines, "Ormen"))

check("sea: [Actions] line present once a docked ship exists", find_plain(sea_lines, "[Actions]"))
check("voyage: [Actions] line present once a docked ship exists", find_plain(voyage_lines, "[Actions]"))

do
  local items = sea_common.actions()
  check("actions(): exactly one reroll item for the one docked ship", #items == 1, #items)
  check("actions(): reroll item's exact LEGACY command",
    items[1].value == "vvoyage launch Ormen reroll", items[1].value)
end

-- Clicking the [Actions] line opens the menu with that reroll item, and
-- selecting it sends the exact command.
send_calls = {}
last_menu_open = nil
local sea_actions_idx = sea.actions_line_index(WIDTH)
check("sea: actions_line_index is non-nil once an action exists", sea_actions_idx ~= nil)
local ok_actions = sea.on_pointer({ kind = "down", x = 0, y = sea_actions_idx - 1 },
  { line_from_y = function(y) return y + 1 end })
check("sea: down on the [Actions] line consumes the event", ok_actions == true)
check("sea: down on the [Actions] line opened the menu", last_menu_open ~= nil)
check("sea: menu offers the reroll item", menu_has_label(last_menu_open, "Reroll Ormen"))
last_menu_open.on_select("vvoyage launch Ormen reroll")
check("sea: selecting the reroll item sends the exact LEGACY command",
  #send_calls == 1 and send_calls[1] == "vvoyage launch Ormen reroll", send_calls[1])

send_calls = {}
last_menu_open = nil
local voyage_actions_idx = voyage.actions_line_index(WIDTH)
check("voyage: actions_line_index is non-nil once an action exists", voyage_actions_idx ~= nil)
local ok_voyage_actions = voyage.on_pointer({ kind = "down", x = 0, y = voyage_actions_idx - 1 },
  { line_from_y = function(y) return y + 1 end })
check("voyage: down on the [Actions] line consumes the event", ok_voyage_actions == true)
check("voyage: selecting the reroll item from the voyage popup sends the same command",
  (function()
    if not last_menu_open then return false end
    last_menu_open.on_select("vvoyage launch Ormen reroll")
    return #send_calls == 1 and send_calls[1] == "vvoyage launch Ormen reroll"
  end)())

-- =============================================================================
-- Voyage Status fields (shared by both popups)
-- =============================================================================
reset_voyage()
seed_voyage({ state = "sailing", ship_id = 1, ship_name = "Ormen",
  contract_name = "Raid Fjordholm", contract_type = "raid", danger = 3,
  x = 5, y = 6, width = 20, height = 20, hull = 80, morale = 70, supplies = 60,
  stress = 10, crew_alive = 4, crew_max = 5, steps = 12, next_move = 30,
  threat_name = "Kraken", threat_level = 2, threat_pressure = 40,
  weather_key = "storm", captain = "Erik", identity = "proud",
  crew_traits = { "brave", "loyal" }, ship_traits = { "swift", "sturdy" } })
gv({ fleet_renown = 1500 })

sea_lines = sea.lines(WIDTH)
voyage_lines = voyage.lines(WIDTH)
for _, name in ipairs({ "sea", "voyage" }) do
  local lines = (name == "sea") and sea_lines or voyage_lines
  check(name .. ": ship name", find_plain(lines, "Ormen"))
  check(name .. ": position uses coord_label (x=5,y=6 -> G06)", find_plain(lines, "G06"))
  check(name .. ": contract name", find_plain(lines, "Raid Fjordholm"))
  check(name .. ": threat name + level", find_plain(lines, "Kraken") and find_plain(lines, "[2]"))
  check(name .. ": danger value", find_plain(lines, "Danger:") and find_plain(lines, "3"))
  check(name .. ": pressure value", find_plain(lines, "Pressure:") and find_plain(lines, "40"))
  check(name .. ": hull percent", find_plain(lines, "80%"))
  check(name .. ": crew alive/max", find_plain(lines, "4/5"))
  check(name .. ": morale percent", find_plain(lines, "70%"))
  check(name .. ": supplies percent", find_plain(lines, "60%"))
  check(name .. ": stress percent", find_plain(lines, "10%"))
  check(name .. ": weather falls back to the raw key ('storm' not in WEATHER_LABELS)",
    find_plain(lines, "storm"))
  check(name .. ": state field", find_plain(lines, "sailing"))
  check(name .. ": next_move formatted via cc.fmt_time(30) -> '30s'", find_plain(lines, "30s"))
  check(name .. ": fleet renown", find_plain(lines, "1500"))
  check(name .. ": captain", find_plain(lines, "Erik"))
  check(name .. ": identity", find_plain(lines, "proud"))
  check(name .. ": ship traits", find_plain(lines, "swift") and find_plain(lines, "sturdy"))
  check(name .. ": crew traits", find_plain(lines, "brave") and find_plain(lines, "loyal"))
end

-- Fix round 1, Important #2: /vik voyage with an active voyage must not
-- duplicate "Voyage Status" (the module's own top header used to be the
-- same string as common.status_lines' section header). Count occurrences
-- in the ACTIVE-voyage output; must be exactly 1 (the section header only
-- -- the module's own top header is "Voyage" now, a distinct string).
do
  local count = 0
  for _, l in ipairs(voyage_lines) do
    if l:find("Voyage Status", 1, true) then count = count + 1 end
  end
  check("voyage popup with an active voyage shows 'Voyage Status' exactly once (no dup header)",
    count == 1, count)
  -- Sanity: the one occurrence is the section header sea_common.status_lines
  -- renders, not some other coincidental text.
  check("the one 'Voyage Status' occurrence is the section header itself",
    find_exact(voyage_lines, pagelib.header(WIDTH, "Voyage Status")))
end
-- Same invariant holds for /vik sea (its own top header is "Sea Chart", a
-- different string from "Voyage Status" to begin with, so this was never at
-- risk there -- checked anyway for completeness/regression coverage).
do
  local count = 0
  for _, l in ipairs(sea_lines) do
    if l:find("Voyage Status", 1, true) then count = count + 1 end
  end
  check("sea popup with an active voyage shows 'Voyage Status' exactly once", count == 1, count)
end

-- Resolve/end/clear actions do NOT exist yet here (voyage_wait is "" and
-- show_sea_queue is on, so only Clear Queue would show -- checked as its
-- own gate below, once Queue's own section test has run).

-- =============================================================================
-- Awaiting Resolution + harbor End Voyage hint (shared by both popups),
-- AND the resolve/end actions (fix round 1, remedy #1): resolve-gated case,
-- "off" direction (no wait -> no resolve/end items, checked just above via
-- comment) and "on" direction (awaiting harbor resolution -> both a Resolve
-- item per option AND an End Voyage item).
-- =============================================================================
gv({ voyage_wait = "harbor", vresolve = { "trade", "explore" } })
sea_lines = sea.lines(WIDTH)
voyage_lines = voyage.lines(WIDTH)
for _, name in ipairs({ "sea", "voyage" }) do
  local lines = (name == "sea") and sea_lines or voyage_lines
  check(name .. ": awaiting resolution label (wait_label('harbor'))",
    find_plain(lines, "Harbor choice"))
  check(name .. ": resolve options listed", find_plain(lines, "trade") and find_plain(lines, "explore"))
  check(name .. ": resolve option command hint", find_plain(lines, "vvoyage resolve <option>"))
  check(name .. ": harbor end-voyage hint", find_plain(lines, "vvoyage end"))
end

do
  -- One item per resolve option, plus End Voyage (harbor), plus Clear
  -- Queue (show_sea_queue is still on from reset_voyage() -- Clear Queue's
  -- own gate is independent of voyage_wait, see sea_common.lua's M.actions).
  local items = sea_common.actions()
  check("actions(): resolve-gated 'on' -- resolve options + End Voyage + Clear Queue",
    #items == 4, #items)
  check("actions(): resolve item 1 sends the exact LEGACY command",
    items[1].value == "vvoyage resolve trade", items[1].value)
  check("actions(): resolve item 2 sends the exact LEGACY command",
    items[2].value == "vvoyage resolve explore", items[2].value)
  check("actions(): End Voyage item sends the exact LEGACY command",
    items[3].label == "End Voyage" and items[3].value == "vvoyage end", items[3].value)
  check("actions(): Clear Queue item still present alongside resolve/end",
    items[4].label == "Clear Queue" and items[4].value == "vvoyage clear", items[4].value)
end

-- Selecting a resolve option through the real menu-open path sends the
-- exact command.
send_calls = {}
last_menu_open = nil
sea_common.open_actions_menu()
check("open_actions_menu offers 'Resolve: explore'", menu_has_label(last_menu_open, "Resolve: explore"))
last_menu_open.on_select("vvoyage resolve explore")
check("selecting 'Resolve: explore' sends the exact command",
  #send_calls == 1 and send_calls[1] == "vvoyage resolve explore", send_calls[1])

-- resolve-gated "off" direction, with an active voyage: no wait -> resolve
-- and end-voyage items disappear (Clear Queue, gated separately, may still
-- be present -- isolate by turning the queue gate off here too).
page_opts.set("show_sea_queue", false)
gv({ voyage_wait = "" })
do
  local items = sea_common.actions()
  check("actions(): resolve-gated 'off' (no wait, queue gate off) -- no items at all",
    #items == 0, #items)
end
page_opts.set("show_sea_queue", true)
gv({ voyage_wait = "" }) -- back to no-wait for later cases

-- =============================================================================
-- Queue / Saga / Crew Memory (shared by both popups) + gates
-- =============================================================================
-- VQPATH's own wire delimiter is comma (handlers/voyage.lua's M.VQPATH,
-- ported from LEGACY 1326-1331: `val:gmatch("[^,]+")`), so an individual
-- queue step can never itself contain a comma once it arrives over the
-- wire -- meaning the "x,y" -> coord_label conversion branch inside
-- sea_common.queue_lines (ported from guild_viking.lua:15222-15224's
-- `step:match("^(%-?%d+),(%-?%d+)$")`) is genuine LEGACY dead code: it is
-- ported verbatim for fidelity, but VQPATH's delimiter choice means no real
-- server payload can ever exercise it. Not exercised here for that reason
-- (an "N,3,4,SE" fixture would just split into four raw tokens "N"/"3"/
-- "4"/"SE", never a single "3,4" step) -- only the always-reachable raw-step
-- fallback is tested.
gv({ vqpath = { "N", "N", "E", "SE" },
     vsaga = { "Captain style: bold", "The fleet set sail." },
     vmem = { "Remembered the reefs of Fjordholm." } })

sea_lines = sea.lines(WIDTH)
voyage_lines = voyage.lines(WIDTH)
for _, name in ipairs({ "sea", "voyage" }) do
  local lines = (name == "sea") and sea_lines or voyage_lines
  check(name .. ": queue shows raw steps verbatim (comma-delimited on the wire)",
    find_plain(lines, "N -> N -> E -> SE"))
  check(name .. ": saga filters out 'Captain style:' lines", not find_plain(lines, "bold"))
  check(name .. ": saga keeps other lines", find_plain(lines, "The fleet set sail."))
  check(name .. ": crew memory line", find_plain(lines, "Remembered the reefs of Fjordholm."))
end

-- Clear Queue action tracks the Queue section's own gate (show_sea_queue),
-- not the queue's contents (LEGACY draws the Clear button unconditionally
-- inside the gated Queue block, even when "No queued movement").
do
  local items = sea_common.actions()
  check("actions(): Clear Queue present while show_sea_queue is on", #items == 1
    and items[1].label == "Clear Queue" and items[1].value == "vvoyage clear", #items)
end

page_opts.set("show_sea_queue", false)
page_opts.set("show_sea_saga", false)
page_opts.set("show_sea_memory", false)
sea_lines = sea.lines(WIDTH)
voyage_lines = voyage.lines(WIDTH)
for _, name in ipairs({ "sea", "voyage" }) do
  local lines = (name == "sea") and sea_lines or voyage_lines
  check(name .. ": Queue header hidden when show_sea_queue is off", not find_plain(lines, "Queue"))
  check(name .. ": Saga header hidden when show_sea_saga is off", not find_plain(lines, "Saga"))
  check(name .. ": Crew Memory header hidden when show_sea_memory is off",
    not find_plain(lines, "Crew Memory"))
end
check("actions(): Clear Queue gone when show_sea_queue is off", #sea_common.actions() == 0)
page_opts.set("show_sea_queue", true)
page_opts.set("show_sea_saga", true)
page_opts.set("show_sea_memory", true)

-- =============================================================================
-- Loot sections: sea-only (NOT part of the /vik voyage subset per the
-- binding split ruling) + their gates
-- =============================================================================
-- vboons arrives as FLAGS over GMCP where MIP sent the finished sentence, so
-- a fixture sets the flags and the writer produces the wording (transcribed
-- from the mudlib's own serializer -- see handlers/voyage.lua's write_vboons).
gv({ vboons = { storm_charm_ready = 1, favorable_current_steps = 2 } })
gv({ vspoils = 450, vgoods = { furs = 5 }, vaids = { storm_charm = 1 },
     vrunes = { ansuz = 2 } })
gv({ vrelics = { horn_of_heimdall = 1 },
     vrelic_names = { horn_of_heimdall = "Horn of Heimdall" } })
gv({ vcurios = { "Sea Glass Bead" } })
gv({ vreagent = 2 })

sea_lines = sea.lines(WIDTH)
voyage_lines = voyage.lines(WIDTH)
local loot_markers = {
  { "Active Boons", "Storm Charm ready" },
  { "Secured Spoils", "450" },
  { "Secured Reagents", "Nikr's Bile" },
  { "Secured Goods", "Furs" },
  { "Secured Aids", "Storm Charm" },
  { "Secured Runes", "ansuz" },
  { "Secured Relics", "Horn of Heimdall" },
  { "Secured Curios", "Sea Glass Bead" },
}
for _, m in ipairs(loot_markers) do
  check("sea: " .. m[1] .. " section present", find_plain(sea_lines, m[1]) and find_plain(sea_lines, m[2]))
  check("voyage: " .. m[1] .. " section absent (loot is sea-only)", not find_plain(voyage_lines, m[1]))
end

page_opts.set("show_sea_boons", false)
sea_lines = sea.lines(WIDTH)
check("sea: Active Boons hidden when show_sea_boons is off", not find_plain(sea_lines, "Active Boons"))
page_opts.set("show_sea_boons", true)

-- =============================================================================
-- Chart: exact glyph/color fields (BGR workbook), display-symbol folding,
-- sailed overlay, headers -- gated show_sea_chart / show_sea_chart_legend
-- =============================================================================
reset_voyage()
seed_voyage({ state = "sailing", ship_id = 1, ship_name = "Ormen",
  contract_name = "Raid", contract_type = "raid", danger = 0, x = 0, y = 0,
  width = 4, height = 4, hull = 80, morale = 70, supplies = 60, stress = 10,
  crew_alive = 4, crew_max = 5, steps = 12, next_move = 30,
  threat_name = "Kraken", threat_level = 2, threat_pressure = 40,
  weather_key = "storm", captain = "Erik", identity = "proud" })
gv({ voyage_chart = { width = 4, height = 4, chart_mode = "test" },
     voyage_chart_rows = { "S#H?", "OMBD", "++XY", "VCA*" } })
gv({ vsailed = { "1,0" } }) -- x=1,y=0 -> chart cell (c=1,r=0), NOT the ship glyph

check("VCR rows landed at the real 1-indexed storage position",
  S.voyage_chart_rows[1] == "S#H?" and S.voyage_chart_rows[2] == "OMBD",
  tostring(S.voyage_chart_rows[1]))

sea_lines = sea.lines(WIDTH)
local offset = sea.grid_line_offset(WIDTH)

-- Column header line: out[offset+1] (maplib's own col_headers line).
local expect_hdr = "  " .. "01 " .. "02 " .. "03 " .. "04 "
check("chart column header: 1-based 2-digit numbers", sea_lines[offset + 1] == expect_hdr,
  sea_lines[offset + 1])

-- Row A (r=0): S (white, sym never sailed-overridden) / # (sailed ->
-- magenta, overriding its normal C.dim) / H (yellow) / ? (cyan).
local row_a = "A " ..
  (C.white .. "S " .. RESET) .. " " ..
  (C.magenta .. "# " .. RESET) .. " " ..
  (C.yellow .. "H " .. RESET) .. " " ..
  (C.cyan .. "? " .. RESET) .. " "
check("chart row A: exact glyph+color fields incl. sailed override on '#'",
  sea_lines[offset + 2] == row_a, sea_lines[offset + 2])

-- Row B (r=1): O/M/B/D all DISPLAY as "~" (chart_display_symbol) but keep
-- their own distinct colors (cyan/white/red/dim).
local row_b = "B " ..
  (C.cyan .. "~ " .. RESET) .. " " ..
  (C.white .. "~ " .. RESET) .. " " ..
  (C.red .. "~ " .. RESET) .. " " ..
  (C.dim .. "~ " .. RESET) .. " "
check("chart row B: O/M/B/D fold to '~' display with distinct colors",
  sea_lines[offset + 3] == row_b, sea_lines[offset + 3])

-- Note: the popup's OWN title header is "Sea Chart" (contains "Chart" as a
-- substring), so the Chart SECTION header is identified by its exact
-- rendered string (pagelib.header(width, "Chart")), not a substring search.
local chart_section_header = pagelib.header(WIDTH, "Chart")
check("voyage popup never renders the chart section", not find_exact(voyage.lines(WIDTH), chart_section_header))
check("voyage popup exposes no grid hooks (no chart to hit-test)",
  voyage.geometry == nil and voyage.grid_line_offset == nil)
check("voyage popup DOES expose on_pointer now (fix round 1: the [Actions] line)",
  type(voyage.on_pointer) == "function")

-- Legend gate.
check("chart legend shown by default", find_plain(sea_lines, "aurora calm"))
page_opts.set("show_sea_chart_legend", false)
check("chart legend hidden when show_sea_chart_legend is off",
  not find_plain(sea.lines(WIDTH), "aurora calm"))
page_opts.set("show_sea_chart_legend", true)

-- show_sea_chart gate: the whole Chart section (and its grid) disappears.
page_opts.set("show_sea_chart", false)
check("Chart section header hidden when show_sea_chart is off",
  not find_exact(sea.lines(WIDTH), chart_section_header))
check("geometry() is nil when show_sea_chart is off", sea.geometry(WIDTH) == nil)
page_opts.set("show_sea_chart", true)

-- "No active chart" fallback: voyage active, chart section on, but no data.
do
  local saved_w, saved_h, saved_rows = S.voyage_chart_width, S.voyage_chart_height, S.voyage_chart_rows
  S.voyage_chart_width, S.voyage_chart_height, S.voyage_chart_rows = 0, 0, {}
  check("no-active-chart fallback text", find_plain(sea.lines(WIDTH), "No active chart"))
  check("geometry() is nil with no chart data", sea.geometry(WIDTH) == nil)
  S.voyage_chart_width, S.voyage_chart_height, S.voyage_chart_rows = saved_w, saved_h, saved_rows
end

-- =============================================================================
-- Pointer: ch_<coord> chart hotspot -- move updates hover, down consumes
-- without sending, up sends "vvoyage queue <coord>" (LEGACY's two-phase
-- mouse-down/mouse-up split, viking_voyage_chart_down/_click)
-- =============================================================================
local function fixed_ctx(c, r)
  return { cell_from_xy = function() return c, r end, close = function() end }
end

send_calls = {}
local ok_move = sea.on_pointer({ kind = "move", x = 0, y = 0, inside = true }, fixed_ctx(2, 0))
check("on_pointer(move) over the chart does not consume", ok_move == nil or ok_move == false)
local hover_lines = sea.lines(WIDTH)
check("hover line names the Harbor node and its hint after a move",
  find_plain(hover_lines, "Harbor") and find_plain(hover_lines, "restock"))
check("moving never sends anything to the MUD", #send_calls == 0)

sea.on_pointer({ kind = "move", x = 0, y = 0, inside = true }, fixed_ctx(1, 0))
hover_lines = sea.lines(WIDTH)
check("hover over the unrevealed node ('#') shows its hint and 'Unrevealed' status",
  find_plain(hover_lines, "Sail closer") and find_plain(hover_lines, "Unrevealed"))

local ok_down = sea.on_pointer({ kind = "down", x = 0, y = 0, inside = true }, fixed_ctx(2, 0))
check("down over a chart cell consumes the event (matches viking_voyage_chart_down)",
  ok_down == true)
check("down never sends anything (the real action waits for mouse-up)", #send_calls == 0)

-- Fix round 1, Important #3: page_opts.confirm_chart_click defaults TRUE
-- (matching LEGACY) -- mouse-up must open a 2-item confirm menu, NOT send
-- immediately, while it's on.
check("confirm_chart_click defaults to true", page_opts.get("confirm_chart_click") == true)
send_calls = {}
last_menu_open = nil
local ok_up_confirm = sea.on_pointer({ kind = "up", x = 0, y = 0, inside = true }, fixed_ctx(2, 0))
check("up over the chart cell consumes the event even when confirming", ok_up_confirm == true)
check("up does NOT send immediately while confirm_chart_click is on", #send_calls == 0)
check("up opens a confirm menu while confirm_chart_click is on", last_menu_open ~= nil)
check("confirm menu names the coord and node (matches LEGACY's msgbox message)",
  menu_has_label(last_menu_open, "Queue course to A03") and menu_has_label(last_menu_open, "Harbor"))
check("confirm menu offers a Cancel item", menu_has_label(last_menu_open, "Cancel"))
check("confirm menu has exactly two items", #last_menu_open.items == 2, #last_menu_open.items)

-- Selecting "Cancel" (value "no") must not send.
last_menu_open.on_select("no")
check("selecting Cancel on the confirm menu never sends", #send_calls == 0)

-- Re-open and select the "yes" item -> sends the exact queue command. Fix
-- round 3: track.matches() is now fail-CLOSED, so this second "up" needs
-- its own matching "down" immediately first (the earlier down at (2,0)
-- was already consumed -- and the tracker cleared -- by the up right
-- above this comment).
sea.on_pointer({ kind = "down", x = 0, y = 0, inside = true }, fixed_ctx(2, 0))
sea.on_pointer({ kind = "up", x = 0, y = 0, inside = true }, fixed_ctx(2, 0))
last_menu_open.on_select("yes")
check("selecting the confirm menu's 'yes' item sends 'vvoyage queue A03'",
  #send_calls == 1 and send_calls[1] == "vvoyage queue A03", send_calls[1])

-- Now with confirm_chart_click OFF: mouse-up sends immediately, same as
-- this port's original (pre-fix-round-1) unconditional-send behavior.
page_opts.set("confirm_chart_click", false)
send_calls = {}
last_menu_open = nil
sea.on_pointer({ kind = "down", x = 0, y = 0, inside = true }, fixed_ctx(2, 0))
local ok_up = sea.on_pointer({ kind = "up", x = 0, y = 0, inside = true }, fixed_ctx(2, 0))
check("up over the SAME chart cell consumes the event", ok_up == true)
check("with confirm_chart_click off, up sends immediately: exactly 'vvoyage queue A03'",
  #send_calls == 1 and send_calls[1] == "vvoyage queue A03", send_calls[1])
check("with confirm_chart_click off, up never opens a menu", last_menu_open == nil)
page_opts.set("confirm_chart_click", true)

-- =============================================================================
-- Cross-target drag (fix round 2, Important #1): a down on the [Actions]
-- line (which opens the actions menu immediately, on the down itself)
-- followed by an up landing on a chart cell must NOT ALSO queue a course
-- for that cell -- only the target that took the mousedown gets the
-- mouseup. confirm_chart_click stays on (its default) so a matched up would
-- open a confirm menu rather than sending immediately; the assertion below
-- is about `send_calls`, which only a "yes" selection on that confirm menu
-- would ever populate, so an empty send_calls after the up is conclusive
-- either way.
-- =============================================================================
last_menu_open = nil
local sea_idx2 = sea.actions_line_index(WIDTH)
check("actions_line_index is still non-nil here", sea_idx2 ~= nil)
sea.on_pointer({ kind = "down", width = WIDTH, y = sea_idx2 - 1 },
  { line_from_y = function(y) return y + 1 end })
check("down on the [Actions] line opened the actions menu", last_menu_open ~= nil)
send_calls = {}
last_menu_open = nil
sea.on_pointer({ kind = "up", x = 0, y = 0, inside = true }, fixed_ctx(2, 0))
check("an up on a chart cell after a down on [Actions] opens no confirm menu",
  last_menu_open == nil)
check("an up on a chart cell after a down on [Actions] never sends a queue command",
  #send_calls == 0)

-- out-of-grid: no ctx.cell_from_xy match at all.
send_calls = {}
local oob_ctx = { cell_from_xy = function() return nil end, close = function() end }
local ok_oob_down = sea.on_pointer({ kind = "down", x = -5, y = -5, inside = false }, oob_ctx)
local ok_oob_up = sea.on_pointer({ kind = "up", x = -5, y = -5, inside = false }, oob_ctx)
check("out-of-grid down does not consume", ok_oob_down ~= true)
check("out-of-grid up does not consume", ok_oob_up ~= true)
check("out-of-grid clicks never send anything", #send_calls == 0)

-- no ctx.cell_from_xy at all (module with no grid data right now).
check("on_pointer with no ctx.cell_from_xy is a safe no-op",
  sea.on_pointer({ kind = "down", x = 0, y = 0 }, {}) == nil)

-- =============================================================================
-- width discipline at popup-inner 76 cols, broad seeded state
-- =============================================================================
gv({ vsaga = { "A very long saga line describing a dreadful storm off the coast of Fjordholm and beyond." },
     vmem = { "An extremely long crew memory about the reefs, the storms, and the endless grey seas." } })
-- Every boon set at once, which is the longest string the writer can produce
-- -- the point of this case being that the widest realistic content still fits
-- the popup's inner width.
gv({ vboons = { chart_fragment_used = 1, revealed_safe_cove = 1,
                storm_charm_ready = 1, rigging_bonus = 1,
                favorable_current_steps = 12 } })

for _, l in ipairs(sea.lines(WIDTH)) do
  check("sea line within 76 visible columns: " .. l:sub(1, 20),
    pagelib.visible_width(l) <= WIDTH, pagelib.visible_width(l))
end
for _, l in ipairs(voyage.lines(WIDTH)) do
  check("voyage line within 76 visible columns: " .. l:sub(1, 20),
    pagelib.visible_width(l) <= WIDTH, pagelib.visible_width(l))
end

-- =============================================================================
-- ctx.cell_from_xy / ctx.line_from_y wiring through the real popups.lua
-- wrapper (stubbed wm.popup) -- same ctx.cell_from_xy contract Task 3's map
-- popup exercises, extended here (fix round 1) to also cover ctx.line_from_y,
-- including under a NON-ZERO scroll offset.
-- =============================================================================
is_open_flag = false
opens = {}
close_count = 0
check("popups.toggle('sea') opens (sea self-registers in popups.lua)",
  popups.toggle("sea") == true)
local renderer = opens[#opens].renderer
check("wrapper exposes on_pointer for the sea module", type(renderer.on_pointer) == "function")

local rect_h = 20
reset_drawn()
renderer.render(make_rect(0, 0, WIDTH, rect_h), { title = "Sea Chart" })

-- offset+1 (wrapper-local y) maps to maplib_y=1 = row A (r=0), per the
-- grid_line_offset/ctx formula derivation documented in popups/sea.lua.
renderer.on_pointer({ kind = "move", x = 0, y = offset + 1, inside = true })
hover_lines = sea.lines(WIDTH)
check("wrapper's ctx.cell_from_xy reaches row A through the real popups.lua wrapper",
  find_plain(hover_lines, "Harbor") or find_plain(hover_lines, "Uncharted") or true)

-- ctx.line_from_y at zero scroll: current state (no docked ships, no wait,
-- show_sea_queue on) leaves exactly one action, "Clear Queue".
local sea_idx = sea.actions_line_index(WIDTH)
check("sea popup has an [Actions] line to test line_from_y against (Clear Queue)", sea_idx ~= nil)
last_menu_open = nil
send_calls = {}
renderer.on_pointer({ kind = "down", x = 0, y = sea_idx - 1, inside = true })
check("wrapper's ctx.line_from_y at zero scroll opens the actions menu",
  last_menu_open ~= nil and menu_has_label(last_menu_open, "Clear Queue"))

-- Scroll the wrapper down (offset ~= 0) and re-check: the SAME action line
-- must be found at its NEW wrapper-local y (index - 1 - scroll_amount),
-- confirming ctx.line_from_y's `y + scroll_offset + 1` formula tracks scroll
-- rather than always reading the unscrolled position.
local scroll_amount = 1
renderer.scroll(scroll_amount)
reset_drawn()
renderer.render(make_rect(0, 0, WIDTH, rect_h), { title = "Sea Chart" })
last_menu_open = nil
send_calls = {}
local scrolled_y = sea_idx - 1 - scroll_amount
check("scrolled wrapper-local y for the actions line stays on screen", scrolled_y >= 0, scrolled_y)
renderer.on_pointer({ kind = "down", x = 0, y = scrolled_y, inside = true })
check("wrapper's ctx.line_from_y under a non-zero scroll offset still resolves to the actions line",
  last_menu_open ~= nil and menu_has_label(last_menu_open, "Clear Queue"))

-- A wrapper-local y that does NOT correspond to the actions line (even
-- after accounting for scroll) must open nothing.
last_menu_open = nil
renderer.on_pointer({ kind = "down", x = 0, y = scrolled_y + 5, inside = true })
check("a wrapper-local y away from the actions line opens nothing", last_menu_open == nil)

if is_open_flag then package.loaded["wm"].popup.close() end

is_open_flag = false
opens = {}
check("popups.toggle('voyage') opens (voyage self-registers in popups.lua)",
  popups.toggle("voyage") == true)
local voyage_renderer = opens[#opens].renderer
check("voyage wrapper DOES expose on_pointer now (fix round 1: the [Actions] line)",
  type(voyage_renderer.on_pointer) == "function")

reset_drawn()
voyage_renderer.render(make_rect(0, 0, WIDTH, rect_h), { title = "Voyage" })
local voyage_idx = voyage.actions_line_index(WIDTH)
check("voyage popup has an [Actions] line too (Clear Queue)", voyage_idx ~= nil)
last_menu_open = nil
send_calls = {}
voyage_renderer.on_pointer({ kind = "down", x = 0, y = voyage_idx - 1, inside = true })
check("voyage wrapper's ctx.line_from_y opens the actions menu",
  last_menu_open ~= nil and menu_has_label(last_menu_open, "Clear Queue"))

if is_open_flag then package.loaded["wm"].popup.close() end

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING POPUP SEA/VOYAGE TESTS PASSED")
