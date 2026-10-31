-- guild_viking City Plan pictures (show_city_plan_icons): tile choice, the
-- keep ring, building art and its text fallback, GUI gating, the menu row,
-- and the City page's image board. Every path the board names must be a
-- real PNG: the image_load stub below opens the file and checks its magic.
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

local root = "3scapes/guild_viking/"
local mode = "gui"
local function rect(x, y, w, h)
  return { x = function() return x end, y = function() return y end,
    w = function() return w end, h = function() return h end }
end
local missing = {}
ui = {
  dirty = function() end, rect = rect, text_ansi = function() end,
  image_load = function(path)
    local f = io.open(root .. path, "rb")
    if not f then missing[#missing + 1] = path; return nil end
    local ok = f:read(8) == "\137PNG\r\n\26\n"
    f:close()
    if not ok then missing[#missing + 1] = path end
    return ok and path or nil
  end,
  image = function() end,
}
lera = { display = function() return mode end, render_pass = function() return "local" end,
  time = function() return 1000 end, version = function() return "test" end }
mud = { send = function() end }

local tiles = require("tiles")
local opts = require("page_opts")
local S = require("state").S
local cityplan = require("popups.cityplan")

local function ends(s, suffix)
  return type(s) == "string" and s:sub(-#suffix) == suffix
end

-- ---- terrain -------------------------------------------------------------
do
  local img, ground = tiles.city_board({ ".f.", "fff", ".f." }, 3, 3, 1)
  check("woods joins all four neighbours", ends(img(1, 1), "woods_wang_1111.png"), img(1, 1))
  check("plain is plain", ends(img(0, 0), "/plain.png"), img(0, 0))
  img, ground = tiles.city_board({ "#" }, 1, 1, 1)
  check("rock is the sprite", ends(img(0, 0), "/rock.png"), img(0, 0))
  check("rock stands on plain", ends(ground(0, 0), "/plain.png"), ground(0, 0))
  for side, letter in ipairs({ "n", "e", "s", "w" }) do
    img = tiles.city_board({ "cc" }, 2, 1, side)
    check("coast faces the sea side " .. letter, ends(img(0, 0), "coast_wang_" .. letter .. "_0010.png"),
      img(0, 0))
  end
  img = tiles.city_board({ "Mc" }, 2, 1, 4)
  check("moat runs into the coast", ends(img(0, 0), "moat_wang_0010.png"), img(0, 0))
  img = tiles.city_board({ ".G.", "MBM" }, 3, 2, 1)
  check("bridge deck points at the gate", ends(img(1, 1), "bridge_wang_n_1010.png"), img(1, 1))
  check("missing row cell is plain", ends(tiles.city_board({}, 2, 2, 1)(1, 1), "/plain.png"))
end

-- ---- buildings -----------------------------------------------------------
do
  local hall = { id = "mead_hall", x = 0, y = 0, w = 2, h = 2 }
  local q = {}
  for oy = 0, 1 do for ox = 0, 1 do q[#q + 1] = tiles.city_building(hall, ox, oy) end end
  check("2x2 hall is cut in quarters", ends(q[1], "mead_hall_2x2_tl.png")
    and ends(q[2], "mead_hall_2x2_tr.png") and ends(q[3], "mead_hall_2x2_bl.png")
    and ends(q[4], "mead_hall_2x2_br.png"), table.concat(q, " "))
  check("a small building shows its art",
    ends(tiles.city_building({ id = "smithy" }, 0, 0), "/smithy.png"))
  check("a building without art has none", tiles.city_building({ id = "sheepfold" }, 0, 0) == nil)
end

-- ---- the whole board -----------------------------------------------------
local function seed()
  -- 10x10 grid, margin 2, dim 6. A 4x4 castle at interior (0,0) with a
  -- throne room inside it, a smithy, and a sheepfold (no art).
  local rows = {}
  for r = 1, 10 do rows[r] = ".........." end
  rows[1] = "cccccccccc"
  rows[2] = "MMMMBMMMMM"
  rows[3] = "WWWWGWWWWW"
  rows[10] = "ff##ff..ff"
  S.city_plan = {
    rows = rows, dim = 6, margin = 2, coast = 1, enabled = true, placed = 4, cap = 9,
    blds = {
      { id = "castle", x = 0, y = 0, w = 4, h = 4, glyph = "C", pal = "T", name = "Castle" },
      { id = "throne_room", x = 1, y = 1, w = 1, h = 1, glyph = "T", pal = "T", name = "Throne" },
      { id = "smithy", x = 5, y = 0, w = 1, h = 1, glyph = "K", pal = "i", name = "Smithy" },
      { id = "sheepfold", x = 5, y = 5, w = 1, h = 1, glyph = "s", pal = "p", name = "Sheepfold" },
    },
  }
  opts.set("show_city_plan", true)
  opts.set("show_city_plan_legend", true)
end

local function images_at(geom)
  local at = {}
  for _, t in ipairs(geom.images) do
    at[t.x .. "," .. t.y] = at[t.x .. "," .. t.y] or {}
    table.insert(at[t.x .. "," .. t.y], t.path)
  end
  return at
end

seed()
opts.set("show_city_plan_icons", true)
do
  local geom = cityplan.geometry(80)
  check("pictures on: the board has images", geom and #geom.images > 0)
  local pitch = geom.width / 10
  local tall = geom.height / 10
  local at = images_at(geom)
  local function cell(c, r) return at[(c * pitch) .. "," .. (r * tall)] or {} end
  local function has(c, r, suffix)
    for _, p in ipairs(cell(c, r)) do if ends(p, suffix) then return true end end
    return false
  end
  -- Castle footprint is grid (2..5, 2..5). Its NW corner joins E and S.
  check("keep corner joins east and south", has(2, 2, "castle_wang_0110.png"))
  check("keep courtyard joins all round", has(4, 4, "castle_wang_1111.png"))
  check("throne room inside the keep is itself", has(3, 3, "/throne_room.png"))
  check("the keep cell next to the throne still joins it", has(3, 2, "castle_wang_1110.png"))
  check("smithy shows its art", has(7, 2, "/smithy.png"))
  check("buildings stand on ground", #cell(7, 2) == 2)
  check("sheepfold keeps its text glyph", #cell(7, 7) == 0)
  local coast = cell(0, 0)[1] or ""
  check("coast row faces north", coast:find("coast_wang_n_", 1, true) ~= nil, coast)
  for _, t in ipairs(geom.images) do tiles.draw(rect(0, 0, 1, 1), t.path) end
  check("every named PNG exists", #missing == 0, table.concat(missing, " "))
  local found = false
  for _, l in ipairs(cityplan.lines(80)) do if l:find("s", 1, true) then found = true end end
  check("lines still carry the glyphs", found)
end

-- ---- gating --------------------------------------------------------------
opts.set("show_city_plan_icons", false)
check("pictures off: no images", #cityplan.geometry(80).images == 0)
opts.set("show_city_plan_icons", true)
mode = "tty"
check("tty: no images even when on", #cityplan.geometry(80).images == 0)
local menus = require("page_menu")
local function has_option(page, key)
  for _, item in ipairs(menus.items(page) or {}) do
    if item.value == "key:" .. key then return true end
  end
  return false
end
check("tty: the toggle is not listed", not has_option("city", "show_city_plan_icons"))
mode = "gui"
check("gui: the toggle is on the City menu", has_option("city", "show_city_plan_icons"))

-- ---- the City page -------------------------------------------------------
do
  local page = require("pages.city")
  local lines, _, boards = page.lines(80)
  check("City page hands over one board", boards and #boards == 1, boards and #boards)
  local b = boards[1]
  check("the board sits on the plan rows", b and lines[b.offset + 1] ~= nil)
  opts.set("show_city_plan_icons", false)
  lines, _, boards = page.lines(80)
  check("pictures off: the page uses the text plan", boards and #boards == 0)
  local ruler = false
  for _, l in ipairs(lines) do if l:find("1 2 3", 1, true) then ruler = true end end
  check("pictures off: the ruler is back", ruler)
  opts.set("show_city_plan_icons", true)
  check("too narrow: falls back to text", select(3, page.lines(8)) and #select(3, page.lines(8)) == 0)
end

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("ALL GUILD_VIKING CITYPLAN ICONS TESTS PASSED")
