-- guild_viking /vik cityplan (City Plan popup) unit tests. Run from the
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

-- ---- lera API stubs (same shape as guild_viking_popup_map_test.lua/
-- guild_viking_popup_sea_test.lua) -------------------------------------------
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

-- ---- wm.popup facade stub (identical to guild_viking_popups_test.lua's) ----
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

-- ---- menu stub (require("menu") facade) -- captures the last opts a popup
-- handed to menu.open() so a test can inspect its items and drive on_select
-- itself, same idea as guild_viking_popup_sea_test.lua's own menu stub.
local last_menu_open = nil
local menu_close_count = 0
package.loaded["menu"] = {
  open = function(opts) last_menu_open = opts end,
  close = function() menu_close_count = menu_close_count + 1; last_menu_open = nil end,
  is_open = function() return last_menu_open ~= nil end,
}
local function menu_item_labels(opts)
  local labels = {}
  for _, it in ipairs(opts.items or {}) do
    labels[#labels + 1] = it.label
  end
  return labels
end
local function menu_has_label(opts, substr)
  for _, l in ipairs(menu_item_labels(opts)) do
    if tostring(l):find(substr, 1, true) then return true end
  end
  return false
end
local function menu_select(opts, label_substr)
  for _, it in ipairs(opts.items or {}) do
    if tostring(it.label):find(label_substr, 1, true) then
      opts.on_select(it.value)
      return true
    end
  end
  return false
end

local pagelib = require("pagelib")
local maplib = require("maplib")
local state = require("state")
local page_opts = require("page_opts")
local popups = require("popups")
local cityplan = require("popups.cityplan")

-- ---- real ingestion pipeline (protocol.ingest -> handlers.city), the SAME
-- registration guild_viking_city_test.lua does for CPLAN/CPT/CPB/CPU/CPEND --
-- fixtures MUST route through protocol.ingest + the real handlers, never
-- direct S. pokes (standing lesson from Task 3's review).
local protocol = require("protocol")
-- init.lua's RESERVED set: the module-level convention fields, not MIP keys.
local RESERVED_KEYS = { _market_seam = true, _patterns = true, _gmcp = true,
                        _retired_keys = true, _retired_patterns = true }
local city = require("handlers.city")
for key, fn in pairs(city._gmcp or {}) do
  protocol.gmcp_handler(key, fn)
end

local S = state.S
local C, RESET = pagelib.C, pagelib.RESET
local WIDTH = 76

-- BGR-decode workbook cross-check (0xBBGGRR), re-derived independently from
-- popups/cityplan.lua's own workbook comments so a typo in the module can't
-- also typo the same way here.
local EXPECT_PAL = {
  p = C.green, i = C.red, k = C.dim, t = C.yellow, c = C.magenta, h = C.yellow,
  T = C.white, e = C.cyan, v = C.cyan,
}
local EXPECT_TILE = {
  W = { glyph = "#", color = C.dim }, G = { glyph = "+", color = C.yellow },
  M = { glyph = "~", color = C.cyan }, B = { glyph = "=", color = C.red },
  c = { glyph = "~", color = C.cyan }, w = { glyph = "w", color = C.cyan },
  f = { glyph = "f", color = C.green }, ["^"] = { glyph = "^", color = C.dim },
  ["#"] = { glyph = "#", color = C.red }, ["."] = { glyph = ".", color = C.dim },
}

local function reset_cityplan()
  S.city_plan = {}
  S.cp_pending = nil
  page_opts.set("show_city_plan", true)
  page_opts.set("show_city_plan_legend", true)
  send_calls = {}
  last_menu_open = nil
  menu_close_count = 0
end

-- Seeds a city plan through the production GMCP path. `rows` is a plain
-- 1-based Lua array in wire order, which is also the order the payload's own
-- terrain array uses -- so, unlike the CPT%02d burst this replaces, there is
-- no +1 offset to keep straight.
local function seed_cplan(t)
  local blds, unplaced = {}, {}
  for _, b in ipairs(t.blds or {}) do
    blds[#blds + 1] = { id = b.id, x = b.x, y = b.y, w = b.w or 1, h = b.h or 1,
                        pal = b.pal or "e", glyph = b.glyph or "?",
                        name = b.name or "" }
  end
  for _, u in ipairs(t.unplaced or {}) do
    unplaced[#unplaced + 1] = { id = u.id, pal = u.pal or "e",
                                glyph = u.glyph or "?", name = u.name or "" }
  end
  local payload = {
    guild = "viking",
    cityplan = {
      enabled = (t.enabled ~= false) and 1 or 0,
      dim = t.dim or 12, placed = t.placed or 0, cap = t.cap or 0,
      coast_side = t.coast or 0, moat = t.moat and 1 or 0,
      wall = t.wall and 1 or 0, gate = t.gate or 6,
      mood_delta = t.mood or 0, margin = t.margin or 0,
    },
    cityplan_terrain = t.rows or {},
    cityplan_buildings = blds,
    cityplan_placeable = unplaced,
  }
  -- Perks are sent only when there are any, so their absence means none.
  if t.perks then payload.cityplan_perks = t.perks end
  protocol.on_gmcp("Guild.City", payload)
end

-- =============================================================================
-- no-data fallback (S.city_plan.dim never arrived)
-- =============================================================================
reset_cityplan()
local nodata_lines = cityplan.lines(WIDTH)
check("no-data fallback has a City Plan header",
  nodata_lines[1] == pagelib.header(WIDTH, "City Plan"), nodata_lines[1])
check("no-data fallback shows a hint to view it in-game", find_plain(nodata_lines, "vplan"))
check("geometry() is nil with no plan data", cityplan.geometry(WIDTH) == nil)

-- =============================================================================
-- show_city_plan opt off: header only, no message (matches LEGACY's silent
-- omission and popups/sea.lua's show_sea_voyage-off precedent)
-- =============================================================================
reset_cityplan()
seed_cplan({ dim = 3, margin = 0, rows = { "...", "...", "..." } })
page_opts.set("show_city_plan", false)
local off_lines = cityplan.lines(WIDTH)
check("show_city_plan off leaves only the header line", #off_lines == 1, #off_lines)
check("geometry() is nil while show_city_plan is off", cityplan.geometry(WIDTH) == nil)
page_opts.set("show_city_plan", true)

-- =============================================================================
-- grid: terrain glyphs/colors (BGR workbook), margin = 0 so the whole grid
-- is interior
-- =============================================================================
reset_cityplan()
seed_cplan({ dim = 3, margin = 0, rows = { "Wc#", "wf.", "GB^" } })
check("CPT00 landed at the real 1-indexed storage position",
  S.city_plan.rows[1] == "Wc#" and S.city_plan.rows[2] == "wf." and S.city_plan.rows[3] == "GB^")

local offset = cityplan.grid_line_offset(WIDTH)
local lines = cityplan.lines(WIDTH)

-- Compact rendering (maplib `compact`): one visible char per cell, so a grid
-- row is exactly the grid's width in chars -- no inter-cell padding, no
-- reserved east-edge slot.
local function field(ch)
  local t = EXPECT_TILE[ch]
  return t.color .. t.glyph .. RESET
end

local row0 = field("W") .. field("c") .. field("#")
local row1 = field("w") .. field("f") .. field(".")
local row2 = field("G") .. field("B") .. field("^")

check("grid row0 (W/c/#) renders exact glyph+color fields, wire row 0 (CPT00)",
  lines[offset + 1] == row0, lines[offset + 1])
check("grid row1 (w/f/.) renders exact glyph+color fields, wire row 1 (CPT01)",
  lines[offset + 2] == row1, lines[offset + 2])
check("grid row2 (G/B/^) renders exact glyph+color fields, wire row 2 (CPT02)",
  lines[offset + 3] == row2, lines[offset + 3])

-- =============================================================================
-- grid: building overlay (PAL colour by pal key, fallback to PAL.e for an
-- unknown pal)
-- =============================================================================
reset_cityplan()
seed_cplan({
  dim = 2, margin = 0, rows = { "..", ".." },
  blds = {
    { id = "b1", x = 0, y = 0, w = 1, h = 1, pal = "p", glyph = "L", name = "Longhouse" },
    { id = "b2", x = 1, y = 1, w = 1, h = 1, pal = "zzz", glyph = "Q", name = "Oddity" },
  },
})
offset = cityplan.grid_line_offset(WIDTH)
lines = cityplan.lines(WIDTH)
local occ_row0 = EXPECT_PAL.p .. "L" .. RESET .. field(".")
local occ_row1 = field(".") .. EXPECT_PAL.e .. "Q" .. RESET
check("building at (0,0) renders its own glyph/pal colour, not terrain",
  lines[offset + 1] == occ_row0, lines[offset + 1])
check("building with an unknown pal falls back to PAL.e (cyan)",
  lines[offset + 2] == occ_row1, lines[offset + 2])

-- =============================================================================
-- grid: castle keep (border wall, blank open courtyard, keep-gated building
-- overwrites an interior courtyard cell and renders as itself)
-- =============================================================================
reset_cityplan()
seed_cplan({
  dim = 5, margin = 1, coast = 1,
  rows = {
    "WWWWWWW",
    "W.....W",
    "W.....W",
    "W.....W",
    "W.....W",
    "W.....W",
    "WWWWWWW",
  },
  blds = {
    { id = "castle", x = 0, y = 0, w = 5, h = 5, pal = "e", glyph = "?", name = "Castle" },
    { id = "throne_room", x = 2, y = 2, w = 1, h = 1, pal = "T", glyph = "K", name = "Throne Room" },
  },
})
local geom = cityplan.geometry(WIDTH)
check("geometry() is non-nil once a plan is committed", geom ~= nil)

lines = cityplan.lines(WIDTH)
offset = cityplan.grid_line_offset(WIDTH)
-- These three used to be substring searches on the row, because at the wide
-- 3-char pitch a 7-column row was 21 chars of interleaved escapes and the
-- per-cell offsets were painful to compute (`nth_field` was a stub that gave
-- up and returned the whole line). Compact rendering makes each row exactly
-- 7 visible chars, so every cell in the row is asserted at once -- which is
-- also strictly stronger: a courtyard blank is a single space, and searching
-- a row for " " would match almost anything.
--
-- The 7x7 grid is a 5x5 castle at margin (1,1) on terrain "W" border /
-- "." fill. Castle border cells are c==1, c==5, r==1 or r==5; interior cells
-- are the open courtyard, which shows the ground underneath ("." here) the
-- way the MUD's own vplan does -- LEGACY's hard blank left a hole in the
-- middle of a walled city that the game never draws; throne_room at plan
-- (2,2) lands on grid (3,3) and renders as itself.
local wall = C.dim .. "#" .. RESET   -- terrain "W" AND castle border, same spec
local courtyard = C.dim .. "." .. RESET  -- castle_cell yields, terrain shows
local throne = EXPECT_PAL.T .. "K" .. RESET

check("grid row 1 (CPT01) is all wall: terrain W, then the keep's top border",
  lines[offset + 2] == string.rep(wall, 7), lines[offset + 2])
check("grid row 2 (CPT02): terrain + border, three open courtyard cells, border + terrain",
  lines[offset + 3] == wall .. wall .. string.rep(courtyard, 3) .. wall .. wall,
  lines[offset + 3])
check("grid row 3 (CPT03): throne_room overwrites the courtyard cell at (3,3)",
  lines[offset + 4] == wall .. wall .. courtyard .. throne .. courtyard .. wall .. wall,
  lines[offset + 4])

-- =============================================================================
-- footer: unplanned status, perks, mood, coast/placed -- all four lines the
-- brief scopes this module to
-- =============================================================================
reset_cityplan()
seed_cplan({ dim = 1, margin = 0, rows = { "." }, enabled = false, coast = 3, placed = 2, cap = 5 })
lines = cityplan.lines(WIDTH)
check("disabled plan shows the Unplanned status line",
  find_plain(lines, "Unplanned - enable in-game: vplan enable"))
check("coast/placed line always renders", find_plain(lines, "Coast: South   Placed 2/5 (rank cap)"))

reset_cityplan()
seed_cplan({
  dim = 1, margin = 0, rows = { "." }, enabled = true, perks = "shrine,forge",
  mood = 3, coast = 1, placed = 4, cap = 10,
})
lines = cityplan.lines(WIDTH)
check("enabled plan shows perks", find_plain(lines, "Perks: shrine,forge"))
check("positive mood renders in green", find_plain(lines, C.green .. "Zoning/heart mood: +3" .. RESET))
check("coast North with placed/cap", find_plain(lines, "Coast: North   Placed 4/10 (rank cap)"))

reset_cityplan()
seed_cplan({ dim = 1, margin = 0, rows = { "." }, enabled = true, mood = -2, coast = 2 })
lines = cityplan.lines(WIDTH)
check("negative mood renders in red", find_plain(lines, C.red .. "Zoning/heart mood: -2" .. RESET))
check("coast East with no perks/placed shows no Perks line", not find_plain(lines, "Perks:"))

-- The two cases that used to sit here covered the CPEND row-count mismatch:
-- an incomplete CPT%02d burst kept the previous grid and stamped cp.dbg, which
-- the footer surfaced as a "dropped: got N/M rows" warning. A Guild.City frame
-- carries the plan whole, so there is no partial burst to detect, nothing sets
-- cp.dbg, and the footer no longer has that line. Both the behaviour and its
-- tests are gone rather than being reworded around a condition that can no
-- longer arise.

-- =============================================================================
-- legend gated show_city_plan_legend
-- =============================================================================
reset_cityplan()
seed_cplan({ dim = 1, margin = 0, rows = { "." } })
page_opts.set("show_city_plan_legend", true)
lines = cityplan.lines(WIDTH)
check("legend on: role group shows 'produce' in PAL.p colour",
  find_plain(lines, C.green .. "p" .. RESET .. " produce"))
check("legend on: terrain group shows 'plain'", find_plain(lines, "plain"))
check("legend on: frame group shows 'bridge'", find_plain(lines, "bridge"))

page_opts.set("show_city_plan_legend", false)
lines = cityplan.lines(WIDTH)
check("legend off: no legend content", not find_plain(lines, "produce"))
page_opts.set("show_city_plan_legend", true)

-- =============================================================================
-- width discipline at popup-inner 76 cols
-- =============================================================================
reset_cityplan()
local wide_rows = {}
for r = 0, 9 do
  local chars = {}
  for c = 0, 9 do chars[#chars + 1] = ({ "W", "c", "#", "w", "f", ".", "G", "B", "^", "." })[(c + r) % 10 + 1] end
  wide_rows[r + 1] = table.concat(chars)
end
seed_cplan({ dim = 10, margin = 0, rows = wide_rows, perks = "a long perk description string" })
lines = cityplan.lines(76)
local over_width = 0
for _, l in ipairs(lines) do
  if pagelib.visible_width(l) > 76 then over_width = over_width + 1 end
end
check("no rendered line exceeds 76 visible columns", over_width == 0, over_width)

-- =============================================================================
-- pointer: hover line + plot context menu (occupied vs empty plot item
-- sets), right-click opens, left-click closes/no-ops, out-of-grid no-ops
-- =============================================================================
local function fixed_ctx(c, r)
  return { cell_from_xy = function() return c, r end, close = function() end }
end

reset_cityplan()
seed_cplan({
  dim = 2, margin = 0, rows = { "..", ".." },
  blds = { { id = "b1", x = 0, y = 0, w = 1, h = 1, pal = "p", glyph = "L", name = "Longhouse" } },
  unplaced = {
    { id = "b2", pal = "i", glyph = "F", name = "Forge" },
    { id = "b3", pal = "v", glyph = "W", name = "Well" },
  },
})

-- hover: empty plot (1,0) -> terrain label; occupied plot (0,0) -> occupant name
local ok_move = cityplan.on_pointer({ kind = "move", x = 0, y = 0, inside = true }, fixed_ctx(1, 0))
check("on_pointer(move) does not consume", ok_move == nil or ok_move == false)
lines = cityplan.lines(WIDTH)
check("hover over empty plot (1,0) shows its cell name and terrain label",
  find_plain(lines, "A2") and find_plain(lines, "place a building"))

cityplan.on_pointer({ kind = "move", x = 0, y = 0, inside = true }, fixed_ctx(0, 0))
lines = cityplan.lines(WIDTH)
check("hover over occupied plot (0,0) shows the occupant's name",
  find_plain(lines, "A1") and find_plain(lines, "Longhouse") and find_plain(lines, "lift or replace"))
check("hovering never sends anything to the MUD", #send_calls == 0)

-- down: consumes, updates hover
local ok_down = cityplan.on_pointer({ kind = "down", x = 0, y = 0, inside = true }, fixed_ctx(0, 0))
check("down over a plot consumes the event (matches viking_cityplan_down)", ok_down == true)
check("down never sends anything (the action waits for a right-click up)", #send_calls == 0)

-- up, left button: closes any menu, consumes, no send
send_calls = {}
menu_close_count = 0
local ok_up_left = cityplan.on_pointer({ kind = "up", x = 0, y = 0, inside = true, button = "left" },
  fixed_ctx(0, 0))
check("left-up over a plot consumes the event", ok_up_left == true)
check("left-up closes any open tile menu (matches viking_cityplan_click's non-right branch)",
  menu_close_count == 1)
check("left-up never sends anything nor opens a menu", #send_calls == 0 and last_menu_open == nil)

-- up, right button, OCCUPIED plot -> "Lift <name>" + Cancel, selecting Lift
-- sends. Fix round 3: track.matches() is now fail-CLOSED, so every "up"
-- below needs its own matching "down" immediately first.
send_calls = {}
last_menu_open = nil
cityplan.on_pointer({ kind = "down", x = 0, y = 0, inside = true }, fixed_ctx(0, 0))
local ok_up_occ = cityplan.on_pointer({ kind = "up", x = 0, y = 0, inside = true, button = "right" },
  fixed_ctx(0, 0))
check("right-up over an occupied plot consumes the event", ok_up_occ == true)
check("occupied-plot menu offers exactly 2 items (Lift + Cancel)",
  last_menu_open ~= nil and #last_menu_open.items == 2, last_menu_open and #last_menu_open.items)
check("occupied-plot menu's item is 'Lift Longhouse'", menu_has_label(last_menu_open, "Lift Longhouse"))
check("occupied-plot menu offers Cancel", menu_has_label(last_menu_open, "Cancel"))
menu_select(last_menu_open, "Lift Longhouse")
check("selecting 'Lift Longhouse' sends 'vplan lift b1'",
  #send_calls == 1 and send_calls[1] == "vplan lift b1", send_calls[1])

-- up, right button, EMPTY plot -> "Place  <name>" per unplaced (sorted) + Cancel
send_calls = {}
last_menu_open = nil
cityplan.on_pointer({ kind = "down", x = 0, y = 0, inside = true }, fixed_ctx(1, 0))
local ok_up_empty = cityplan.on_pointer({ kind = "up", x = 0, y = 0, inside = true, button = "right" },
  fixed_ctx(1, 0))
check("right-up over an empty plot consumes the event", ok_up_empty == true)
check("empty-plot menu offers exactly 3 items (2 unplaced + Cancel), DIFFERENT from the occupied set",
  last_menu_open ~= nil and #last_menu_open.items == 3, last_menu_open and #last_menu_open.items)
check("empty-plot menu lists 'Place  Forge' before 'Place  Well' (sorted by name)",
  menu_item_labels(last_menu_open)[1]:find("Forge", 1, true) ~= nil
  and menu_item_labels(last_menu_open)[2]:find("Well", 1, true) ~= nil,
  table.concat(menu_item_labels(last_menu_open), " | "))
check("empty-plot menu offers Cancel", menu_has_label(last_menu_open, "Cancel"))
menu_select(last_menu_open, "Place  Forge")
check("selecting 'Place  Forge' sends 'vplan place b2 A2' (cellname for (1,0))",
  #send_calls == 1 and send_calls[1] == "vplan place b2 A2", send_calls[1])

-- Cancel / "Nothing left to place" never send.
send_calls = {}
last_menu_open = nil
cityplan.on_pointer({ kind = "down", x = 0, y = 0, inside = true }, fixed_ctx(1, 0))
cityplan.on_pointer({ kind = "up", x = 0, y = 0, inside = true, button = "right" }, fixed_ctx(1, 0))
menu_select(last_menu_open, "Cancel")
check("selecting Cancel never sends", #send_calls == 0)

-- =============================================================================
-- per-module smoke + cross-target drag (fix round 2, Important #1): a real
-- down+up pair on the SAME plot still opens that plot's own context menu;
-- a down on one plot followed by an up on a DIFFERENT plot must NOT open
-- either plot's menu (LEGACY's "hotspot that took the mousedown gets the
-- mouseup" rule).
-- =============================================================================
last_menu_open = nil
cityplan.on_pointer({ kind = "down", x = 0, y = 0, inside = true }, fixed_ctx(1, 0))
cityplan.on_pointer({ kind = "up", x = 0, y = 0, inside = true, button = "right" }, fixed_ctx(1, 0))
check("down+up on the SAME empty plot opens its own place menu",
  last_menu_open ~= nil and menu_has_label(last_menu_open, "Forge"))

last_menu_open = nil
send_calls = {}
cityplan.on_pointer({ kind = "down", x = 0, y = 0, inside = true }, fixed_ctx(0, 0))
cityplan.on_pointer({ kind = "up", x = 0, y = 0, inside = true, button = "right" }, fixed_ctx(1, 0))
check("a down on one plot followed by an up on a DIFFERENT plot opens no menu",
  last_menu_open == nil)
check("the mismatched drag never sends anything", #send_calls == 0)

-- Empty plot with NO unplaced buildings -> "Nothing left to place" + Cancel.
reset_cityplan()
seed_cplan({ dim = 1, margin = 0, rows = { "." } })
last_menu_open = nil
cityplan.on_pointer({ kind = "down", x = 0, y = 0, inside = true }, fixed_ctx(0, 0))
cityplan.on_pointer({ kind = "up", x = 0, y = 0, inside = true, button = "right" }, fixed_ctx(0, 0))
check("with no unplaced buildings, the menu offers 'Nothing left to place' + Cancel",
  last_menu_open ~= nil and #last_menu_open.items == 2
  and menu_has_label(last_menu_open, "Nothing left to place")
  and menu_has_label(last_menu_open, "Cancel"),
  last_menu_open and table.concat(menu_item_labels(last_menu_open), " | "))
send_calls = {}
menu_select(last_menu_open, "Nothing left to place")
check("selecting 'Nothing left to place' never sends", #send_calls == 0)

-- =============================================================================
-- out-of-grid click no-ops (border cell outside the interior dim x dim
-- sub-square has no LEGACY hotspot at all)
-- =============================================================================
reset_cityplan()
seed_cplan({
  dim = 1, margin = 1, rows = { "WWW", "W.W", "WWW" },
})
send_calls = {}
last_menu_open = nil
local before = cityplan.lines(WIDTH)
local ok_border_down = cityplan.on_pointer({ kind = "down", x = 0, y = 0, inside = true }, fixed_ctx(0, 0))
check("a down on a border (non-interior) cell does not consume", ok_border_down ~= true)
local ok_border_up = cityplan.on_pointer({ kind = "up", x = 0, y = 0, inside = true, button = "right" },
  fixed_ctx(0, 0))
check("an up on a border (non-interior) cell does not consume", ok_border_up ~= true)
check("a border click never opens a menu", last_menu_open == nil)
check("a border click never sends anything", #send_calls == 0)
local after = cityplan.lines(WIDTH)
check("a border click leaves the rendered lines unchanged", table.concat(before, "\n") == table.concat(after, "\n"))

-- an entirely out-of-grid ctx (cell_from_xy returns nil)
local ok_oob = cityplan.on_pointer({ kind = "down", x = -5, y = -5, inside = false },
  { cell_from_xy = function() return nil end, close = function() end })
check("an out-of-grid ctx coordinate does not consume", ok_oob ~= true)
check("on_pointer with no ctx.cell_from_xy at all is a safe no-op",
  cityplan.on_pointer({ kind = "down", x = 0, y = 0 }, {}) == nil)

-- =============================================================================
-- ctx.cell_from_xy wiring through the real popups.lua wrapper (stubbed
-- wm.popup) -- the contract Tasks 3-4 already exercise for map/sea.
-- =============================================================================
reset_cityplan()
seed_cplan({ dim = 2, margin = 0, rows = { "pp", "hh" } })

is_open_flag = false
opens = {}
close_count = 0
check("popups.toggle('cityplan') opens (cityplan self-registers in popups.lua)",
  popups.toggle("cityplan") == true)
local renderer = opens[#opens].renderer
check("wrapper exposes on_pointer for the cityplan module",
  type(renderer.on_pointer) == "function")

local rect_h = 8
reset_drawn()
renderer.render(make_rect(0, 0, WIDTH, rect_h), { title = "City Plan" })

local pre_offset = cityplan.grid_line_offset(WIDTH)
local wrapper_y_row1 = pre_offset + 1
check("row 1 is within the visible rect at zero scroll", wrapper_y_row1 < rect_h, wrapper_y_row1)
renderer.on_pointer({ kind = "move", x = 0, y = wrapper_y_row1, inside = true })
lines = cityplan.lines(WIDTH)
-- cell (0,1) -> ix=0, iy=1 -> cellname "B1" (string.char(65+iy) .. tostring(ix+1))
check("wrapper's ctx.cell_from_xy maps wrapper-local (x, y) to grid cell (0,1)",
  find_plain(lines, "B1"))

send_calls = {}
local ok_wired_oob = renderer.on_pointer({ kind = "down", x = 0, y = 1000, inside = false })
check("an out-of-grid wrapper coordinate does not send to the MUD", #send_calls == 0)

if is_open_flag then package.loaded["wm"].popup.close() end

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING POPUP CITYPLAN TESTS PASSED")
