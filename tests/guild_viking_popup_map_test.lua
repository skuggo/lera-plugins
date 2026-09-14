-- guild_viking /vik map (Territory Map popup) unit tests. Run from the
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
local function printed_has(text)
  for _, line in ipairs(printed) do
    if line:find(text, 1, true) then return true end
  end
  return false
end

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

-- ---- menu.lua facade stub (identical shape to
-- guild_viking_popup_dispatch_test.lua's) -- Task 5's POI travel menu opens
-- through require("menu"); map.lua requires "menu" lazily (only from
-- open_poi_menu), so this just needs to be in place before the first click
-- that reaches it, same as popups/cityplan.lua's own test coverage.
local last_menu_open = nil
package.loaded["menu"] = {
  open = function(opts) last_menu_open = opts end,
  close = function() last_menu_open = nil end,
  is_open = function() return last_menu_open ~= nil end,
}
local function menu_item_values(opts)
  local out = {}
  for _, it in ipairs(opts.items or {}) do out[#out + 1] = it end
  return out
end

local pagelib = require("pagelib")
local maplib = require("maplib")
local state = require("state")
local page_opts = require("page_opts")
local popups = require("popups")
local map = require("popups.map")

-- ---- real ingestion pipeline (protocol.ingest -> handlers.voyage), the SAME
-- registration guild_viking_voyage_test.lua does, so vmap fixtures are
-- driven through production code rather than poked into S by hand -- see
-- seed_vmap below for why this matters.
local protocol = require("protocol")
-- init.lua's RESERVED set: the module-level convention fields, not MIP keys.
local RESERVED_KEYS = { _market_seam = true, _patterns = true, _gmcp = true,
                        _retired_keys = true, _retired_patterns = true }
local voyage = require("handlers.voyage")
local RESERVED = RESERVED_KEYS
for key, fn in pairs(voyage._gmcp or {}) do
  protocol.gmcp_handler(key, fn)
end

local S = state.S
local C, RESET = pagelib.C, pagelib.RESET

-- BGR-decode workbook cross-check: same nearest-hue mapping map.lua's own
-- header comment documents (0xBBGGRR: leftmost=Blue, middle=Green,
-- rightmost=Red), re-derived here independently so a test typo in map.lua's
-- table can't also typo the same way in the test.
local EXPECT_COLOR = {
  p = C.bright_green, -- 0x00CC00 -> R=00,G=CC,B=00
  h = C.yellow,        -- 0x00CCCC -> R=CC,G=CC,B=00
  ["."] = C.dim,        -- 0x222222 -> R=22,G=22,B=22
  A = C.red,            -- 0x0000CC -> R=CC,G=00,B=00
  f = C.green,          -- 0x009900 -> R=00,G=99,B=00
  W = C.cyan,           -- 0xAA3300 -> R=00,G=33,B=AA (no blue in pagelib.C)
  M = C.bright_red,     -- 0x0000DD -> R=DD,G=00,B=00
  X = C.white,          -- 0xFFFFFF
}

-- Seeds the vmap through the real Guild.Map pipeline (protocol.on_gmcp ->
-- handlers.voyage's composite writer), never by poking S directly. `rows`/
-- `east_edges`/`south_edges` are plain 1-based Lua arrays in wire order
-- (rows[1] is wire row 0), which is also the layout the planes arrive in, so
-- there is no index translation left to get wrong. Only the keys a caller
-- actually supplies are sent: Guild.Map frames are deltas, and a key absent
-- from a frame means unchanged.
--
-- `enc` says "glyph" so the rows travel as written. The packed encodings the
-- server normally uses are the codec's own subject
-- (guild_viking_gmcp_grid_test.lua) and the writer's
-- (guild_viking_voyage_test.lua); a fixture here is about what the map
-- CONTAINS, not how it was encoded.
local function seed_vmap(t)
  local frame = {
    guild = "viking", w = t.w, h = t.h, active = 1,
    pos = { x = t.px or -1, y = t.py or -1 },
    enc = { terrain = "glyph", east = "glyph", south = "glyph" },
  }
  if t.rows then frame.terrain = t.rows end
  if t.east_edges then frame.east = t.east_edges end
  if t.south_edges then frame.south = t.south_edges end
  if t.pois then
    local landmarks = {}
    for _, p in ipairs(t.pois) do
      landmarks[#landmarks + 1] =
        { type = p.type, name = p.name, x = p.x, y = p.y, owner = p.owner or "" }
    end
    frame.landmarks = landmarks
  end
  protocol.on_gmcp("Guild.Map", frame)
end

local function reset_vmap()
  S.vmap_w, S.vmap_h = 0, 0
  S.vmap_px, S.vmap_py = -1, -1
  S.vmap_rows = {}
  S.vmap_east_edges = {}
  S.vmap_south_edges = {}
  S.vmap_pois = {}
  S.vmap_pois_keys = {}
end

-- =============================================================================
-- no-data fallback
-- =============================================================================
reset_vmap()
page_opts.set("show_map_towns", true)
-- The two ways this pane can be empty are reported separately, because they
-- have different causes and only one of them is the client's. The text used to
-- read "enable with: vtoggle mip_map" in both cases, which the mudlib says
-- outright cannot help: Guild.Map is "NOT gated on any MIP vtoggle -- GMCP
-- gating is subscription only".
local function nodata_text()
  for _, l in ipairs(map.lines(76)) do
    if l:find("No data", 1, true) or l:find("No territory map", 1, true) then
      return l
    end
  end
  return nil
end

S.vmap_seen = false
check("with no frame received, the pane says so and points at /vik source",
  (nodata_text() or ""):find("no Guild.Map frame received", 1, true) ~= nil,
  nodata_text())

-- A frame that arrived carrying w = 0 is the guild having no biome grid --
-- _v_map()'s empty structure -- not a missing frame.
S.vmap_seen = true
check("with a frame received but no grid, the pane blames world state",
  (nodata_text() or ""):find("no biome grid", 1, true) ~= nil,
  nodata_text())
check("neither message advises the MIP toggle any more",
  (nodata_text() or ""):find("vtoggle", 1, true) == nil, nodata_text())
S.vmap_seen = false
local nodata_lines = map.lines(76)
check("no-data fallback has a Territory Map header",
  nodata_lines[1]:find("Territory Map", 1, true) ~= nil, nodata_lines[1])

-- =============================================================================
-- grid: seeded rows render exact glyph/color fields (BGR workbook)
-- =============================================================================
reset_vmap()
seed_vmap({ w = 3, h = 2, rows = { "ph.", "AfW" } })
check("VMR00 landed at the real 1-indexed storage position",
  S.vmap_rows[1] == "ph." and S.vmap_rows[2] == "AfW",
  tostring(S.vmap_rows[1]) .. "/" .. tostring(S.vmap_rows[2]))

local width = 76
local offset = map.grid_line_offset(width)
local lines = map.lines(width)

-- Compact rendering (maplib `compact`): one visible char per cell, so a row
-- is exactly vmap_w chars wide with no inter-cell padding and no east-edge
-- slot. Each field is just its colored glyph.
local function field(sym)
  return EXPECT_COLOR[sym] .. sym .. RESET
end

local row0 = field("p") .. field("h") .. field(".")
local row1 = field("A") .. field("f") .. field("W")

check("grid row0 (p/h/.) renders exact glyph+color fields, wire row 0 (VMR00)",
  lines[offset + 1] == row0, lines[offset + 1])
check("grid row1 (A/f/W) renders exact glyph+color fields, wire row 1 (VMR01)",
  lines[offset + 2] == row1, lines[offset + 2])

-- =============================================================================
-- POI overlay overrides terrain glyph/color
-- =============================================================================
reset_vmap()
seed_vmap({
  w = 3, h = 2, rows = { "ph.", "AfW" },
  pois = { { type = "capital", name = "uppsala", x = 1, y = 0, owner = "" } },
})

offset = map.grid_line_offset(width)
lines = map.lines(width)
local row0_poi = field("p") .. field("M") .. field(".")
check("POI at (1,0) overrides the terrain glyph/color with its symbol",
  lines[offset + 1] == row0_poi, lines[offset + 1])

-- =============================================================================
-- player position marker overrides both terrain and a co-located POI
-- =============================================================================
reset_vmap()
seed_vmap({
  w = 3, h = 2, px = 2, py = 1, rows = { "ph.", "AfW" },
  pois = { { type = "ruins", name = "old fort", x = 2, y = 1, owner = "" } },
})

offset = map.grid_line_offset(width)
lines = map.lines(width)
local row1_player = field("A") .. field("f") .. field("X")
check("player position (2,1) wins over a co-located POI and terrain",
  lines[offset + 2] == row1_player, lines[offset + 2])

local pos_line_found = false
for _, l in ipairs(lines) do
  if l:find("%(2, 1%)") then pos_line_found = true end
end
check("header shows the player's position", pos_line_found)

-- =============================================================================
-- east/south edge data is stored but NOT drawn
--
-- This board renders compact (one char per cell). The edge-wall overlay it
-- used to draw -- "|" in a third pitch column for a blocked east edge, "__"
-- on an interleaved row below every cell row for a blocked south edge -- is
-- gone, so the grid is exactly vmap_w chars by vmap_h lines regardless of
-- what edge data arrived. The state fields are still decoded and stored
-- (handlers/voyage.lua's job, locked by its own tests); this asserts nothing
-- here consumes them into the rendered grid.
-- =============================================================================
reset_vmap()
seed_vmap({
  w = 2, h = 2, rows = { "pp", "pp" },
  east_edges = { "01" },  -- wire row 0: col0 wall, col1 clear
  south_edges = { "10" }, -- wire row 0: col0 clear, col1 wall
})
check("MEE00/MES00 landed at the real 1-indexed storage position",
  S.vmap_east_edges[1] == "01" and S.vmap_south_edges[1] == "10")

offset = map.grid_line_offset(width)
lines = map.lines(width)
local plain_row = field("p") .. field("p")
check("east-edge data present: row0 is the two glyphs alone, no '|' wall",
  lines[offset + 1] == plain_row, lines[offset + 1])
check("south-edge data present: row1 is the next CELL row, not an interleaved "
  .. "'__' edge row",
  lines[offset + 2] == plain_row, lines[offset + 2])
-- The height check is what a resurrected south-edge overlay would break
-- first: it doubles the grid section from h lines to 2h.
check("south-edge data present: the grid section is still exactly h lines",
  #lines == offset + S.vmap_h + 1, #lines)

-- ...and identically with no edge data at all, so the two cases are
-- indistinguishable in the output.
reset_vmap()
seed_vmap({ w = 2, h = 2, rows = { "pp", "pp" } })
offset = map.grid_line_offset(width)
lines = map.lines(width)
check("with no edge data at all, the grid section is exactly h lines",
  #lines == offset + S.vmap_h + 1, #lines)
check("grid row0 with no edge data is identical to the with-edge-data render",
  lines[offset + 1] == plain_row, lines[offset + 1])
check("grid row1 with no edge data is identical to the with-edge-data render",
  lines[offset + 2] == plain_row, lines[offset + 2])

-- =============================================================================
-- towns list + show_map_towns gate
-- =============================================================================
reset_vmap()
seed_vmap({
  w = 3, h = 2, rows = { "...", "..." },
  pois = {
    { type = "capital", name = "asgard", x = 0, y = 0, owner = "" },
    { type = "farm", name = "hearthstead", x = 1, y = 0, owner = "bjorn" },
  },
})

page_opts.set("show_map_towns", true)
lines = map.lines(width)
local towns_header_found, asgard_found, hearthstead_found = false, false, false
for _, l in ipairs(lines) do
  if l:find("Map Locations", 1, true) then towns_header_found = true end
  if l:find("Asgard", 1, true) then asgard_found = true end
  if l:find("Hearthstead", 1, true) and l:find("Bjorn", 1, true) then
    hearthstead_found = true
  end
end
check("towns list header present when gated on", towns_header_found)
check("towns list shows a capitalized POI name", asgard_found)
check("towns list shows owner in parens for an owned POI", hearthstead_found)

page_opts.set("show_map_towns", false)
lines = map.lines(width)
towns_header_found = false
for _, l in ipairs(lines) do
  if l:find("Map Locations", 1, true) then towns_header_found = true end
end
check("towns list hidden when show_map_towns is off", not towns_header_found)
page_opts.set("show_map_towns", true)

-- =============================================================================
-- width discipline at popup-inner 76 cols
-- =============================================================================
reset_vmap()
local wide_rows = {}
for r = 0, 3 do
  local chars = {}
  for c = 0, 7 do chars[#chars + 1] = ({ "p", "h", "A", "f", "W", ".", "+", "=" })[(c + r) % 8 + 1] end
  wide_rows[r + 1] = table.concat(chars) -- 1-based wire order: wide_rows[1] = wire row 0
end
seed_vmap({
  w = 8, h = 4, rows = wide_rows,
  pois = {
    { type = "capital", name = "asgard", x = 0, y = 0, owner = "" },
    { type = "lineage", name = "midgard hall", x = 1, y = 1, owner = "" },
  },
})
lines = map.lines(76)
local over_width = 0
for _, l in ipairs(lines) do
  if pagelib.visible_width(l) > 76 then over_width = over_width + 1 end
end
check("no rendered line exceeds 76 visible columns", over_width == 0, over_width)

-- =============================================================================
-- pointer: hover info line (direct unit test with a stubbed ctx)
-- =============================================================================
reset_vmap()
seed_vmap({
  w = 3, h = 2, rows = { "ph.", "AfW" },
  pois = { { type = "seer", name = "vala", x = 1, y = 0, owner = "ivar" } },
})

local function fixed_ctx(c, r)
  return { cell_from_xy = function() return c, r end,
           close = function() end }
end

send_calls = {}
local ok_move = map.on_pointer({ kind = "move", x = 0, y = 0, inside = true }, fixed_ctx(0, 1))
check("on_pointer(move) over terrain does not consume the event", ok_move == nil or ok_move == false)
lines = map.lines(width)
local hover_terrain_found = false
for _, l in ipairs(lines) do
  if l:find("%(0,1%)") and l:find("Mountains", 1, true) then hover_terrain_found = true end
end
check("hover over terrain cell (0,1) shows its terrain label (wire row 1, VMR01 = 'AfW')",
  hover_terrain_found)
check("hovering never sends anything to the MUD", #send_calls == 0)

map.on_pointer({ kind = "move", x = 0, y = 0, inside = true }, fixed_ctx(1, 0))
lines = map.lines(width)
local hover_poi_found = false
for _, l in ipairs(lines) do
  if l:find("%(1,0%)") and l:find("Seer", 1, true) and l:find("Vala", 1, true)
     and l:find("Owner", 1, true) and l:find("Ivar", 1, true) then
    hover_poi_found = true
  end
end
check("hover over a POI cell shows its type/name/owner", hover_poi_found)

S.vmap_px, S.vmap_py = 2, 1
map.on_pointer({ kind = "move", x = 0, y = 0, inside = true }, fixed_ctx(2, 1))
lines = map.lines(width)
local hover_player_found = false
for _, l in ipairs(lines) do
  if l:find("%(2,1%)") and l:find("You", 1, true) then hover_player_found = true end
end
check("hover over the player's own cell shows 'You'", hover_player_found)

-- out-of-grid click no-ops: hover text must be unchanged
local before_lines = map.lines(width)
local before_hover
for _, l in ipairs(before_lines) do
  if l:find("You", 1, true) then before_hover = l end
end
local ok_oob = map.on_pointer({ kind = "down", x = -5, y = -5, inside = false },
  { cell_from_xy = function() return nil end, close = function() end })
check("out-of-grid click returns a non-true, non-blocking result", ok_oob ~= true)
lines = map.lines(width)
local after_hover
for _, l in ipairs(lines) do
  if l:find("You", 1, true) then after_hover = l end
end
check("out-of-grid click leaves the hover line unchanged", after_hover == before_hover)
check("out-of-grid click never sends anything to the MUD", #send_calls == 0)

-- =============================================================================
-- per-module smoke, non-POI cell (fix round 2, Important #1's "apply
-- uniformly" audit, updated for Task 5): a down+move+up sequence on a
-- TERRAIN cell (no POI there -- (0,1) is 'A', mountains, per the fixture
-- above) must still behave exactly like a bare move: no crash, no
-- consumption, no send, no menu. Task 5 gives POI/town cells a real click
-- action (tested below); this pins that a non-POI cell is unaffected.
-- =============================================================================
send_calls = {}
last_menu_open = nil
local ok_down_same = map.on_pointer({ kind = "down", x = 0, y = 0, inside = true, button = "left" },
  fixed_ctx(0, 1))
check("down on a non-POI cell does not consume",
  ok_down_same == nil or ok_down_same == false)
map.on_pointer({ kind = "move", x = 0, y = 0, inside = true }, fixed_ctx(0, 1))
local ok_up_same = map.on_pointer({ kind = "up", x = 0, y = 0, inside = true, button = "left" },
  fixed_ctx(0, 1))
check("a subsequent up on the SAME non-POI cell does not consume either",
  ok_up_same == nil or ok_up_same == false)
check("down+move+up on a non-POI cell never sends anything", #send_calls == 0)
check("down+move+up on a non-POI cell never opens the travel menu", last_menu_open == nil)

-- =============================================================================
-- Task 5: POI travel menu -- item list and per-item conditions
-- (viking_show_poi_menu, guild_viking.lua:11789-11814). Player at (0,0);
-- one POI with a KNOWN path (reachable "asgard" at (2,0), the pathfinding
-- suite's own Case 1 straight-line grid) and one with NO known path
-- (unreachable "helheim" behind water at (2,0) on a second, disconnected
-- row -- see the water-fixture grid below); plus a POI with an invalid
-- position (x = -1) that viking_show_poi_menu's own filter excludes.
-- =============================================================================
reset_vmap()
seed_vmap({
  w = 3, h = 1,
  rows = { "ppp" },
  east_edges = { "111" },
  px = 0, py = 0,
  pois = {
    { type = "capital", name = "asgard", x = 2, y = 0, owner = "" },
    { type = "ruins", name = "lost cave", x = -1, y = -1, owner = "" },
  },
})

local poi_at_2_0 = { kind = "down", x = 0, y = 0, inside = true, button = "left" }
local up_at_2_0 = { kind = "up", x = 0, y = 0, inside = true, button = "left" }
send_calls, last_menu_open = {}, nil
check("left down on the POI cell (2,0) consumes",
  map.on_pointer(poi_at_2_0, fixed_ctx(2, 0)) == true)
check("down on a POI cell never sends", #send_calls == 0)
map.on_pointer(up_at_2_0, fixed_ctx(2, 0))
check("matching up opens the travel menu", last_menu_open ~= nil)
check("travel menu title is 'Travel to...'",
  last_menu_open and last_menu_open.title == "Travel to...", last_menu_open and last_menu_open.title)

local items = last_menu_open and menu_item_values(last_menu_open) or {}
check("menu excludes the POI with an invalid position (x = -1)", #items == 1, #items)
check("menu's one item is asgard, labeled per viking_draw_poi_menu's format",
  items[1] and items[1].label == "Cap  Travel to Asgard (2,0)", items[1] and items[1].label)
check("menu item's value carries the POI record itself (for on_select's travel_to)",
  items[1] and items[1].value and items[1].value.name == "asgard")

-- =============================================================================
-- Task 5: travel branch -- EXACT movement sends for a reachable target,
-- via the real on_select callback the menu captured above (mirrors
-- pathfinding_test.lua's Case 1: (0,0) -> (2,0) on a clear row = exactly
-- {"east", "east"}).
-- =============================================================================
send_calls = {}
last_menu_open.on_select(items[1].value)
check("reachable target: EXACTLY two sends, in order, 'east' then 'east'",
  #send_calls == 2 and send_calls[1] == "east" and send_calls[2] == "east",
  table.concat(send_calls, ","))

-- =============================================================================
-- Task 5: travel branch -- a POI with NO known path sends nothing
-- (mirrors pathfinding_test.lua's Case 4: water blocks the only route).
-- =============================================================================
reset_vmap()
seed_vmap({
  w = 3, h = 1,
  rows = { "pWp" },
  east_edges = { "111" },
  px = 0, py = 0,
  pois = { { type = "ruins", name = "helheim", x = 2, y = 0, owner = "" } },
})
send_calls, last_menu_open = {}, nil
map.on_pointer(poi_at_2_0, fixed_ctx(2, 0))
map.on_pointer(up_at_2_0, fixed_ctx(2, 0))
check("unreachable target's menu still opens", last_menu_open ~= nil)
local unreachable_items = last_menu_open and menu_item_values(last_menu_open) or {}
check("unreachable target: exactly one item (helheim)", #unreachable_items == 1)
send_calls = {}
last_menu_open.on_select(unreachable_items[1].value)
check("unreachable target: no passable route -> nothing sent", #send_calls == 0)

-- Already-at-target: player standing on the POI's own cell -> #path == 0,
-- still nothing sent (mirrors pathfinding_test.lua's Case 5).
reset_vmap()
seed_vmap({
  w = 3, h = 1,
  rows = { "ppp" },
  east_edges = { "111" },
  px = 2, py = 0,
  pois = { { type = "capital", name = "asgard", x = 2, y = 0, owner = "" } },
})
send_calls, last_menu_open = {}, nil
map.on_pointer(poi_at_2_0, fixed_ctx(2, 0))
map.on_pointer(up_at_2_0, fixed_ctx(2, 0))
check("already-at-target: menu still opens (player position is known)", last_menu_open ~= nil)
local already_items = last_menu_open and menu_item_values(last_menu_open) or {}
check("already-at-target: exactly one item (asgard)", #already_items == 1)
send_calls = {}
last_menu_open.on_select(already_items[1].value)
check("already at target: #path == 0 -> nothing sent", #send_calls == 0)

-- =============================================================================
-- Status messages: every silent early return in the travel flow says why
--
-- These five were LEGACY ColourNotes the port originally dropped as
-- "display-only". They are not: "Travel to..." opening no menu, or a picked
-- destination sending nothing, is indistinguishable from a broken menu
-- without them. The guard LOGIC is already covered above; these check that
-- each guard is also REPORTED.
-- =============================================================================

-- open_poi_menu, guard 1: player position unknown (px < 0) -> no menu, and
-- a message saying so. Mutant it kills: a silent `return`, which is exactly
-- what this looked like from the outside.
reset_vmap()
seed_vmap({
  w = 3, h = 1, rows = { "ppp" }, east_edges = { "111" },
  pois = { { type = "capital", name = "asgard", x = 2, y = 0, owner = "" } },
})
check("fixture premise: player position is unknown", (S.vmap_px or -1) < 0, S.vmap_px)
printed, last_menu_open = {}, nil
map.open_poi_menu()
check("unknown player position: no travel menu opens", last_menu_open == nil)
check("unknown player position: says you are not on the map",
  printed_has("[vmap] Travel unavailable: you are not on the map."), table.concat(printed, " | "))

-- The position guard says WHY, not just that travel is unavailable. Three
-- causes are distinguishable from state alone, and they are the same three
-- the no-data pane above already separates -- deliberately worded to agree
-- with it, since a player who reads one will read the other.
--
-- Cause 1: no Guild.Map frame has arrived at all, which is the only one the
-- player can act on (subscription/negotiation, via /vik source).
reset_vmap()
S.vmap_seen = false
printed, last_menu_open = {}, nil
map.open_poi_menu()
check("no frame: no menu", last_menu_open == nil)
check("no frame: still says travel is unavailable (LEGACY's own line)",
  printed_has("[vmap] Travel unavailable: you are not on the map."),
  table.concat(printed, " | "))
check("no frame: explains that no Guild.Map frame arrived, and points at /vik source",
  printed_has("no Guild.Map frame received") and printed_has("/vik source"),
  table.concat(printed, " | "))

-- Cause 2: a frame arrived and reported no grid -- world state, not the
-- client's and not the player's.
reset_vmap()
S.vmap_seen = true
printed, last_menu_open = {}, nil
map.open_poi_menu()
check("frame but no grid: no menu", last_menu_open == nil)
check("frame but no grid: blames the missing biome grid",
  printed_has("no biome grid"), table.concat(printed, " | "))
check("frame but no grid: does NOT blame a missing frame",
  not printed_has("no Guild.Map frame received"), table.concat(printed, " | "))

-- Cause 3: the grid exists, but no position was ever reported for this
-- player -- they are genuinely off the biome grid. This is the case the bug
-- report came from, and the one the other two must not be confused with.
reset_vmap()
seed_vmap({
  w = 3, h = 1, rows = { "ppp" }, east_edges = { "111" },
  pois = { { type = "capital", name = "asgard", x = 2, y = 0, owner = "" } },
})
check("fixture premise: grid present, frame seen, position still unknown",
  (S.vmap_w or 0) > 0 and S.vmap_seen and (S.vmap_px or -1) < 0,
  string.format("w=%s seen=%s px=%s", S.vmap_w, tostring(S.vmap_seen), S.vmap_px))
printed, last_menu_open = {}, nil
map.open_poi_menu()
check("off the grid: no menu", last_menu_open == nil)
check("off the grid: says the map has no position for you",
  printed_has("no position for you on it"), table.concat(printed, " | "))
check("off the grid: blames neither a missing frame nor a missing grid",
  not printed_has("no Guild.Map frame received") and not printed_has("no biome grid"),
  table.concat(printed, " | "))

-- travel_to's own position guard explains too -- pages/people.lua's "Run
-- There" buttons reach it with no menu in the picture at all.
reset_vmap()
S.vmap_seen = false
printed, send_calls = {}, {}
map.travel_to({ name = "asgard", x = 2, y = 0 })
check("travel_to with no frame: sends nothing", #send_calls == 0)
check("travel_to with no frame: explains why, not just that the position is unknown",
  printed_has("[vmap] Player position unknown")
    and printed_has("no Guild.Map frame received"),
  table.concat(printed, " | "))

-- open_poi_menu, guard 2: position known, but no POI has a valid coordinate
-- -> no menu, and a different message. The POI below is deliberately at
-- (-1,-1), so this exercises the empty-LIST guard rather than an empty
-- vmap_pois: the list is filtered, not absent.
reset_vmap()
seed_vmap({
  w = 3, h = 1, rows = { "ppp" }, east_edges = { "111" },
  px = 0, py = 0,
  pois = { { type = "ruins", name = "lost cave", x = -1, y = -1, owner = "" } },
})
printed, last_menu_open = {}, nil
map.open_poi_menu()
check("no travellable locations: no travel menu opens", last_menu_open == nil)
check("no travellable locations: says there are none",
  printed_has("[vmap] No locations available to travel to."), table.concat(printed, " | "))
check("no travellable locations: does NOT claim the position is unknown "
  .. "(the two guards must be distinguishable)",
  not printed_has("[vmap] Travel unavailable: you are not on the map."), table.concat(printed, " | "))

-- travel_to's three outcomes, driven through the exported function so the
-- message is checked at its source rather than through a menu pick.
reset_vmap()
seed_vmap({
  w = 3, h = 1, rows = { "pWp" }, east_edges = { "111" },
  px = 0, py = 0,
  pois = { { type = "ruins", name = "helheim", x = 2, y = 0, owner = "" } },
})
printed, send_calls = {}, {}
map.travel_to(S.vmap_pois[1])
check("no route: still sends nothing", #send_calls == 0)
check("no route: names the unreachable destination",
  printed_has("[vmap] No passable route to helheim"), table.concat(printed, " | "))

reset_vmap()
seed_vmap({
  w = 3, h = 1, rows = { "ppp" }, east_edges = { "111" },
  px = 2, py = 0,
  pois = { { type = "capital", name = "asgard", x = 2, y = 0, owner = "" } },
})
printed, send_calls = {}, {}
map.travel_to(S.vmap_pois[1])
check("already there: still sends nothing", #send_calls == 0)
check("already there: says so, naming the destination",
  printed_has("Already at asgard"), table.concat(printed, " | "))

reset_vmap()
seed_vmap({
  w = 3, h = 1, rows = { "ppp" }, east_edges = { "111" },
  px = 0, py = 0,
  pois = { { type = "capital", name = "asgard", x = 2, y = 0, owner = "" } },
})
printed, send_calls = {}, {}
map.travel_to(S.vmap_pois[1])
check("reachable: sends the path", #send_calls == 2, #send_calls)
check("reachable: reports the destination and the step count",
  printed_has("[vmap] Traveling to asgard (2 steps)"), table.concat(printed, " | "))

-- travel_to's own position guard, reachable only by calling it directly
-- (pages/people.lua's errand button does exactly that).
reset_vmap()
seed_vmap({
  w = 3, h = 1, rows = { "ppp" }, east_edges = { "111" },
  pois = { { type = "capital", name = "asgard", x = 2, y = 0, owner = "" } },
})
printed, send_calls = {}, {}
map.travel_to(S.vmap_pois[1])
check("travel_to with an unknown position: sends nothing", #send_calls == 0)
check("travel_to with an unknown position: says the position is unknown",
  printed_has("[vmap] Player position unknown"), table.concat(printed, " | "))

-- =============================================================================
-- Task 5: a click on a non-POI cell sends nothing and never opens the menu
-- (the down itself is unconsumed, matching the per-module smoke case
-- above -- repeated here with a fresh grid that actually HAS pois
-- elsewhere, so this is a genuine "wrong cell" check, not just "no pois
-- at all").
-- =============================================================================
reset_vmap()
seed_vmap({
  w = 3, h = 1,
  rows = { "ppp" },
  east_edges = { "111" },
  px = 0, py = 0,
  pois = { { type = "capital", name = "asgard", x = 2, y = 0, owner = "" } },
})
send_calls, last_menu_open = {}, nil
local ok_nonpoi_down = map.on_pointer({ kind = "down", x = 0, y = 0, inside = true, button = "left" },
  fixed_ctx(1, 0))
check("down on a non-POI cell (1,0) does not consume", ok_nonpoi_down ~= true)
map.on_pointer({ kind = "up", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(1, 0))
check("non-POI cell click never opens the menu", last_menu_open == nil)
check("non-POI cell click never sends", #send_calls == 0)

-- =============================================================================
-- Task 5: fail-closed tracker case, driven directly at the module level
-- (the REAL popup.lua dispatch-layer version of this lives in
-- guild_viking_popup_dispatch_test.lua) -- down on the POI cell (2,0),
-- up on a DIFFERENT cell (1,0, non-POI) must not open the menu or send.
-- =============================================================================
send_calls, last_menu_open = {}, nil
map.on_pointer(poi_at_2_0, fixed_ctx(2, 0))
map.on_pointer({ kind = "up", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(1, 0))
check("fail-closed: down on POI, up elsewhere -> menu never opens", last_menu_open == nil)
check("fail-closed: down on POI, up elsewhere -> nothing sent", #send_calls == 0)

-- A "cancel" (popup closing mid-drag) clears the tracker too: a down on
-- the POI followed by cancel, then an up on that SAME cell (simulating a
-- fresh, unrelated gesture the tracker must not still "remember"), must
-- not open the menu either.
send_calls, last_menu_open = {}, nil
map.on_pointer(poi_at_2_0, fixed_ctx(2, 0))
map.on_pointer({ kind = "cancel" }, fixed_ctx(2, 0))
map.on_pointer(up_at_2_0, fixed_ctx(2, 0))
check("cancel clears the tracker: a later up on the same cell still does not open the menu",
  last_menu_open == nil)
check("cancel clears the tracker: nothing sent either", #send_calls == 0)

-- =============================================================================
-- ctx.cell_from_xy wiring through the real popups.lua wrapper (stubbed
-- wm.popup) -- the contract Tasks 4-6 reuse.
-- =============================================================================
reset_vmap()
seed_vmap({ w = 2, h = 3, rows = { "pp", "hh", "AA" } })

is_open_flag = false
opens = {}
close_count = 0
check("popups.toggle('map') opens (map self-registers in popups.lua)",
  popups.toggle("map") == true)
local renderer = opens[#opens].renderer
check("wrapper exposes on_pointer for the map module",
  type(renderer.on_pointer) == "function")

-- Prime last_width/last_count via a real render pass. Rect height (6) is
-- deliberately SHORTER than the full content (pre-grid + 3 grid rows + 1
-- hover line = 7 lines here) so scroll(1) below actually moves the
-- scroller's offset instead of clamping back to 0 (max offset = 7-6 = 1) --
-- and tall enough that grid row 2 is still on-screen both before and after
-- that one-line scroll.
local rect_h = 6
reset_drawn()
renderer.render(make_rect(0, 0, width, rect_h), { title = "Territory Map" })

local pre_offset = map.grid_line_offset(width)
-- wrapper_y for grid row r (0-based, no south edges => 1 line per row) at
-- zero scroll: wrapper_y = pre_offset + r (see popups.lua's ctx.cell_from_xy
-- doc comment: gy = y + scroll_offset - grid_line_offset). Grid row 2 is
-- wire row 2 (VMR02 = "AA", "Mountains").
local wrapper_y_row2 = pre_offset + 2
check("row 2 is within the visible rect at zero scroll", wrapper_y_row2 < rect_h,
  wrapper_y_row2)
renderer.on_pointer({ kind = "move", x = 0, y = wrapper_y_row2, inside = true })
lines = map.lines(width)
local wired_hover_found = false
for _, l in ipairs(lines) do
  if l:find("%(0,2%)") and l:find("Mountains", 1, true) then wired_hover_found = true end
end
check("wrapper's ctx.cell_from_xy maps wrapper-local (x, y) to grid cell (0,2) at zero scroll",
  wired_hover_found)

-- Now scroll the wrapper down by 1 (well within its clamp: 7 total lines,
-- 5-row rect -> max offset 2) and re-check the SAME target cell (0,2) at
-- its NEW wrapper-local y (one row higher on screen), confirming the
-- offset math tracks scroll.
renderer.scroll(1)
reset_drawn()
renderer.render(make_rect(0, 0, width, rect_h), { title = "Territory Map" })
local wrapper_y_row2_scrolled = wrapper_y_row2 - 1
renderer.on_pointer({ kind = "move", x = 0, y = wrapper_y_row2_scrolled, inside = true })
lines = map.lines(width)
wired_hover_found = false
for _, l in ipairs(lines) do
  if l:find("%(0,2%)") and l:find("Mountains", 1, true) then wired_hover_found = true end
end
check("wrapper's ctx.cell_from_xy still maps to (0,2) after scrolling by 1",
  wired_hover_found)

-- an out-of-grid wrapper coordinate (well past the grid's bottom) resolves
-- to nil and does not touch mud.send
send_calls = {}
local ok_wired_oob = renderer.on_pointer({ kind = "down", x = 0, y = 1000, inside = false })
check("an out-of-grid wrapper coordinate does not send to the MUD", #send_calls == 0)

if is_open_flag then package.loaded["wm"].popup.close() end

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING POPUP MAP TESTS PASSED")
