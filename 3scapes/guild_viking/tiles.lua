-- PNG selection ported from Telegram's guild_viking (2).lua. Coordinates
-- here are always screen order (north is row - 1), including battle boards.
local opts = require("page_opts")
local M = {}
local cache = {}
local city = "images/viking_cityplan/"
local voyage = "images/viking_voyage/"
local terrains = {
  map = { f="woods", h="hill", W="river", r="river", c="coast",
    ["="]="bridge", A="mountain", t="tundra", p="plain", ["."]="plain",
    ["+"]="road", ["^"]="mountain", ["~"]="river" },
  campaign = { f="woods", H="hill", ["^"]="hill", w="river", W="wall",
    M="moat", G="gate", x="choke", A="mountain", t="tundra", ["+"]="road",
    c="coast", B="bridge", ["."]="plain", r="rock" },
  battle = { ["^"]="hill", ["*"]="woods", ["="]="river", w="moat",
    ["#"]="wall", x="choke", ["."]="plain" },
  sea = { O="sea", ["~"]="sea", M="mist", B="stormbelt", ["="]="crosscurrent",
    D="deadwater", C="ice", V="maelstrom", A="aurora", ["#"]="unrevealed" },
}
local features = { S="ship", ["+"]="queued", [">"]="destination", I="island",
  ["?"]="unknown", H="harbor", W="wreck", T="storm", F="fog", X="objective",
  ["*"]="resolved", Y="resolved_harbor" }
local priority = { sea=1, unrevealed=2, mist=3, stormbelt=4, crosscurrent=5,
  deadwater=6, ice=7, maelstrom=8, aurora=9 }
local water = { river=true, coast=true, bridge=true }
local directions = { {0,-1,1}, {1,0,2}, {0,1,4}, {-1,0,8} }

function M.available()
  return lera and lera.display and lera.display() == "gui"
    and ui and type(ui.image_load) == "function" and type(ui.image) == "function"
    or false
end

function M.enabled(kind)
  if not M.available() then return false end
  if kind == "map" then return opts.get("show_map_icons") end
  if kind == "sea" then return opts.get("show_sea_chart_icons") end
  return not opts.get("show_war_ascii")
end

-- Pixel metrics are optional in older hosts/tests. Monospace cells normally
-- have a 1:2 width:height ratio; native GUI dimensions refine that estimate.
function M.cell_aspect()
  if gui and gui.size and ui and ui.size
      and (not lera.render_pass or lera.render_pass() ~= "remote") then
    local pw, ph = gui.size()
    local cols, rows = ui.size()
    if pw and ph and cols and rows and cols > 0 and rows > 0 then
      local cw, ch = math.floor(pw / cols), math.floor(ph / rows)
      if cw > 0 and ch > 0 then return ch / cw end
    end
  end
  return 2
end

local function bin4(n)
  local s = ""
  for i = 3, 0, -1 do s = s .. tostring(math.floor(n / 2^i) % 2) end
  return s
end

-- Build one terrain plane per board, not once per cell. Voyage features
-- inherit revealed neighbouring regions with the legacy priority tie-break.
function M.board(kind, rows, w, h)
  local symbols, plane = {}, {}
  local mapping = assert(terrains[kind], "unknown tile board")
  for r = 0, h - 1 do
    symbols[r], plane[r] = {}, {}
    for c = 0, w - 1 do
      local ch = (rows[r + 1] or ""):sub(c + 1, c + 1)
      symbols[r][c], plane[r][c] = ch, mapping[ch]
    end
  end
  -- Guild.Map uses the same terrain rows for landmark markers (P/M/L/S/T,
  -- etc.). Those marker glyphs intentionally have no terrain mapping, but an
  -- icon still needs a biome tile underneath it or transparent pixels reveal
  -- the renderer's black clear colour. Infer a marker cell's terrain from its
  -- mapped cardinal neighbours; fall back to plain at an isolated edge.
  --
  -- Every board with a ground layer needs this, not just the map: a campaign
  -- or battle row that is SHORTER than the grid yields "" for the cells past
  -- its end, and any glyph the board's own table does not map yields nil the
  -- same way. Those cells drew no tile at all, so a camp_* marker over one --
  -- which is ~75% transparent by design -- showed the clear colour instead of
  -- ground. That is the black background on the campaign map. "sea" is
  -- excluded: it runs its own feature pass below and its unmapped cells mean
  -- "unrevealed", which is a thing it draws rather than a hole.
  if kind ~= "sea" then
    for r = 0, h - 1 do
      for c = 0, w - 1 do
        if not plane[r][c] then
          local counts = {}
          for _, d in ipairs(directions) do
            local t = plane[r + d[2]] and plane[r + d[2]][c + d[1]]
            if t then counts[t] = (counts[t] or 0) + 1 end
          end
          local best, score = "plain", 0
          for t, n in pairs(counts) do
            if n > score then best, score = t, n end
          end
          plane[r][c] = best
        end
      end
    end
  end
  if kind == "sea" then
    for r = 0, h - 1 do
      for c = 0, w - 1 do
        if features[symbols[r][c]] then
          local counts = {}
          for _, d in ipairs(directions) do
            local t = plane[r+d[2]] and plane[r+d[2]][c+d[1]]
            if t and t ~= "unrevealed" then counts[t] = (counts[t] or 0) + 1 end
          end
          local best, score = "sea", 0
          for t, n in pairs(counts) do
            local s = n * 1000 - priority[t]
            if s > score then best, score = t, s end
          end
          plane[r][c] = best
        end
      end
    end
  end
  local function path(c, r)
    local t = plane[r] and plane[r][c]
    if not t then return nil end
    local root = kind == "sea" and voyage or city
    if kind == "sea" and features[symbols[r][c]] then
      return root .. features[symbols[r][c]] .. "_over_" .. t .. ".png"
    end
    if t == "plain" or t == "rock" then return root .. t .. ".png" end
    local function connects(x, y)
      if x < 0 or x >= w or y < 0 or y >= h then return kind == "sea" end
      local other = plane[y][x]
      if kind == "map" then return other == t or (water[t] and water[other]) end
      if kind == "sea" then return other == t end
      return symbols[y][x] == symbols[r][c]
    end
    local mask = 0
    for _, d in ipairs(directions) do
      if connects(c+d[1], r+d[2]) then mask = mask + d[3] end
    end
    -- Legacy only adds diagonal corners to an otherwise isolated cell.
    -- Never add them to an orthogonal run: that invents false junctions.
    if kind == "map" and mask == 0 then
      local bits = {}
      for _, d in ipairs({{-1,-1,1,8}, {1,-1,1,2}, {-1,1,4,8}, {1,1,4,2}}) do
        if connects(c+d[1], r+d[2]) then bits[d[3]], bits[d[4]] = true, true end
      end
      for b in pairs(bits) do mask = mask + b end
    end
    -- The legacy territory map uses the west-facing coast/bridge sets.
    if t == "coast" or t == "bridge" then t = t .. "_wang_w"
    else t = t .. "_wang" end
    return root .. t .. "_" .. bin4(mask) .. ".png"
  end
  local function base(c, r)
    local t = plane[r] and plane[r][c]
    if not t then return nil end
    local root = kind == "sea" and voyage or city
    return root .. t .. ".png"
  end
  -- What the cell STANDS on. Every Wang tile is opaque ground in its own
  -- right, but rock.png is not: it is a crag-and-ruin sprite on a transparent
  -- backdrop (over half the pixels), drawn as the cell's only image -- so
  -- every rock square on the campaign map showed the renderer's black clear
  -- colour around it. A rock sits on plain ground; the board emits that as
  -- the cell's `under` and lets maplib composite the rock over it.
  local function ground(c, r)
    local t = plane[r] and plane[r][c]
    if t == "rock" then return city .. "plain.png" end
    return path(c, r)
  end
  return path, base, ground
end

function M.city(name) return city .. name .. ".png" end

function M.draw(rect, path)
  if not path then return end
  local img = cache[path]
  if img == nil then
    img = ui.image_load(path)
    -- Numbered battle-unit sprites distinguish duplicate formations. Siege
    -- has only a shared sprite (unit_siege_you.png), so a numbered siege
    -- path from the wire must fall back instead of leaving that cell blank.
    if not img then
      local fallback = path:match("^(images/viking_cityplan/unit_.+)_([1-9])%.png$")
      if fallback then
        fallback = fallback .. ".png"
        img = cache[fallback]
        if img == nil then
          img = ui.image_load(fallback)
          cache[fallback] = img or false
        end
      end
    end
    cache[path] = img or false -- a missing asset must not cause I/O every frame
  end
  -- Layout already approximates square pixels. Fill the whole cell: contain
  -- introduces letterbox seams with fonts whose aspect ratio is not integral.
  if img then ui.image(rect, img, { fit="stretch", filter="nearest" }) end
end

-- Uses the SAME layout as text rendering and hit testing. Whole-cell clipping
-- keeps images out of tab bars, labels, and neighbouring panes when scrolled.
function M.render_geometry(geom, rect, line_offset, scroll)
  if not geom or not geom.images then return end
  for _, tile in ipairs(geom.images) do
    local x, y = tile.x, tile.y + line_offset - scroll
    local height = tile.h or 1
    if x >= 0 and y >= 0 and x + tile.w <= rect:w() and y + height <= rect:h() then
      M.draw(ui.rect(rect:x()+x, rect:y()+y, tile.w, height), tile.path)
    end
  end
end

function M.layout(mod, width, height)
  return require("maplib").fit(height, function()
    local lines, targets, boards = mod.lines(width)
    if mod.geometry and mod.grid_line_offset then
      boards = {{mod=mod, geometry=mod.geometry(width),
        offset=mod.grid_line_offset(width), full_page=true}}
    end
    return lines, targets, boards
  end, mod.image_limit)
end

function M.render(mod, rect, scroll, boards)
  if not M.available() then return end
  if boards then
    for _, board in ipairs(boards) do
      M.render_geometry(board.geometry, rect, board.offset, scroll)
    end
  elseif mod.geometry and mod.grid_line_offset then
    M.render_geometry(mod.geometry(rect:w()), rect, mod.grid_line_offset(rect:w()), scroll)
  end
end

return M
