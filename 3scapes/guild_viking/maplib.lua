-- maplib: pure grid renderer + hit-tester shared by every guild_viking board
-- popup (territory map, sea chart, city plan, campaign map, battle board).
-- No lera API calls, no state access -- render() and geometry() take only
-- `grid`/`opts` and pagelib for ANSI primitives.
--
-- GEOMETRY (the one thing every consumer must agree on):
--
-- Horizontal: each grid column occupies a fixed pitch, `L.pitch` wide,
-- made of a glyph field followed (in wide mode only) by an east-edge slot.
-- The glyph field holds `cell.glyph` left-justified and space-padded, or
-- truncated, to exactly `L.glyph_width` visible chars.
--
-- WIDE mode (the default) uses a 3-char pitch:
--   [glyph field: 2 chars][east-edge slot: 1 char]
-- so a 1-char glyph like "A" widens to "A " and a 2-char glyph like "DD"
-- fills the field exactly. The east-edge slot is always reserved (even for
-- the grid's last column) so the pitch never depends on whether
-- `opts.east_edge` was supplied; it renders "|" when `opts.east_edge(c, r)`
-- is truthy for that cell, otherwise a space. This deviates from the plan's
-- "2-char pitch" suggestion deliberately: with glyphs allowed up to 2
-- chars, a fixed 2-char glyph FIELD (not 1) is what keeps the pitch
-- constant regardless of glyph content, so cell_at's column arithmetic
-- never has to special-case glyph width.
--
-- COMPACT mode (`opts.compact = true`) uses a 1-char pitch: the glyph field
-- alone, no east-edge slot and no edge rows, so the board renders exactly
-- one character per cell and `w` characters per row. `opts.east_edge` and
-- `opts.south_edge` are IGNORED entirely under `compact` -- there is no
-- between-cells column or row left to draw a wall in, and a compact caller
-- is asking for the raw glyph grid, not for wall overlays. A glyph longer
-- than one char truncates to its first char, which is a real (if unlikely)
-- data loss: `popups/cityplan.lua`'s building glyphs come straight off the
-- wire (`tostring(b.glyph or "?")`) and `popups/war_battle.lua`'s
-- duplicate-unit ordinal is `tostring(u.ord)`, so a two-character value
-- from either would lose its second char. Both are single characters in
-- practice; the two boards that can genuinely carry a 2-char glyph
-- (`popups/war_campaign.lua`'s enemy army ids) or need a 2-char header
-- label (`popups/sea.lua`'s A01..P16 chart) stay in wide mode for exactly
-- that reason.
--
-- Vertical: each grid row is one rendered line. In wide mode, when
-- `opts.south_edge` is supplied (as a function -- presence alone opts in,
-- independent of what it returns for any given cell), an extra "edge row"
-- is interleaved directly below every cell row: each column renders "__"
-- when `opts.south_edge(c, r)` is truthy, else "  ", with the east-edge
-- slot always blank (south and east walls are drawn as independent slots,
-- never merged into a corner glyph). Without `opts.south_edge`, no edge
-- rows exist at all -- vertical space is expensive in a popup, so it is
-- opt-in, unlike the always-reserved horizontal east slot.
--
-- Headers: `opts.col_headers` prepends one header line with 0-based column
-- numbers (each left-justified/truncated into the same `glyph_width`
-- glyph-field width, followed in wide mode by a blank east-slot -- headers
-- never show edges).
-- `opts.row_headers` prepends, to every line the grid body occupies (cell
-- rows AND edge rows), a row-header field `row_header_width` chars wide
-- (sized to fit the largest row index, minimum 1) plus one separator space;
-- edge rows render that field blank. When both headers are on,
-- `opts.origin_label` (if given) is truncated/padded into the corner cell
-- formed by the header line's row-header field; it is ignored otherwise
-- (there is no corner without both headers).
--
-- `opts.col_label(c)`/`opts.row_label(r)`: optional formatters overriding
-- the header text for column `c` / row `r` (default `tostring`), added for
-- the sea chart's nautical A01..P16 coordinate scheme (letters for rows,
-- 1-based 2-digit numbers for columns) -- every OTHER consumer (map.lua's
-- 0-based numeric headers, this file's own tests) omits them and sees
-- byte-identical output to before this existed. `row_header_width` is still
-- sized from the numeric row COUNT, not from the label text -- a
-- single-character letter label always fits inside that width with room to
-- spare for any grid this file is used on (capped at 16 rows today), so no
-- consumer needs a wider reservation than the existing sizing already gives
-- it.
--
-- `row_header_width` is measured from what `row_label` actually renders --
-- every row is asked, widest wins -- so any labelling scheme fits. This used
-- to be `#tostring(h - 1)`, the 0-based row count's own digit width, which is
-- right for the default label by construction but truncates a 1-based numeric
-- label exactly at a power-of-ten row count (at `h == 10` it sized the field
-- to one digit and then rendered "10" into it). That is why
-- `popups/war_campaign.lua` and `popups/war_battle.lua` originally omitted
-- row headers; they no longer need to.
--
-- Selection: `cell.sel` wraps the glyph field in reverse video ("\27[7m"
-- .. field .. "\27[27m"), matching window.lua/menu.lua's existing reverse-
-- video idiom elsewhere in this plugin (toggle, not a full SGR reset, so it
-- composes with `cell.color`: color is set before the reverse toggle turns
-- on, and reset only after the toggle turns back off).
--
-- `layout(grid, opts)` computes every position (pitches, header offsets,
-- total width/height) exactly once; `render()` and `geometry()` both build
-- on it, so cell_at's arithmetic and the glyph placement it inverts can
-- never drift apart.
--
-- geom.cell_at(x, y) takes 0-based coordinates relative to the FIRST
-- rendered line of render()'s own output (line 0 is the header line when
-- `col_headers` is set, otherwise the first cell row) and returns the
-- (c, r) grid cell whose glyph field that position falls inside, or nil for
-- a header line/row, a row-header/separator column, an east-edge slot, an
-- edge row, or anything out of bounds. (Under `compact` there are no
-- east-edge slots and no edge rows, so those two nil cases cannot arise.)
local pagelib = require("pagelib")

local RESET = pagelib.RESET
local REV_ON = "\27[7m"
local REV_OFF = "\27[27m"
local image_row_limit = 2
local measured_rows = 0


-- Every position/size fact both render() and geometry() need, computed once.
local function layout(grid, opts, available_width)
  local w, h = grid.w or 0, grid.h or 0
  local row_headers = opts.row_headers and true or false
  local col_headers = opts.col_headers and true or false

  local row_header_width = 0
  if row_headers then
    -- Sized from what row_label ACTUALLY renders, widest row wins. It used to
    -- be sized from the 0-based row count (`#tostring(h - 1)`), which matched
    -- the default label by construction but silently truncated any other
    -- scheme at a power-of-ten row count: a 1-based numeric label on a
    -- 10-row grid sized the field to 1 char and then rendered "10" into it.
    -- That is why war_campaign.lua and war_battle.lua omitted row headers
    -- entirely rather than show a broken axis.
    local label = opts.row_label or tostring
    for r = 0, (h > 0 and (h - 1) or 0) do
      local n = #tostring(label(r))
      if n > row_header_width then row_header_width = n end
    end
    if row_header_width < 1 then row_header_width = 1 end
  end

  -- Compact drops the east slot and the edge rows together: both are
  -- between-cells space, and a 1-char pitch has none to give them.
  local compact = opts.compact and true or false
  local glyph_width = compact and 1 or 2
  local pitch = compact and 1 or 3

  local prefix_width = row_headers and (row_header_width + 1) or 0
  local image_mode, image_height = false, 1
  if grid.image and w > 0 then
    local budget = math.floor(((available_width or (prefix_width + w * 4)) - prefix_width) / w)
    local cell_aspect = require("tiles").cell_aspect()
    -- Choose a compact square in character-cell units, at most two rows.
    -- A wide board must not silently disable the user's PNG preference.
    -- Keep the minimum tile size and clip at the viewport instead.
    image_mode, pitch, glyph_width = true, 2, 2
    local max_cols = math.max(2, math.min(budget, grid.image_max_cols or 4))
    local min_cols = math.min(max_cols, math.max(2, opts.image_min_cols or 2))
    for rows = 1, image_row_limit do
      local cols = opts.image_cols or math.max(min_cols,
        math.floor(rows * cell_aspect + 0.5))
      if cols <= max_cols then
        image_mode, pitch, glyph_width, image_height = true, cols, cols, rows
      end
    end
    compact = true
  end

  local edge_rows = (not compact) and opts.south_edge ~= nil
  local body_lines_per_row = edge_rows and 2 or 1
  if image_mode then body_lines_per_row = image_height end
  local col_header_lines = col_headers and 1 or 0

  local body_width = w * pitch
  local total_width = prefix_width + body_width
  local total_height = col_header_lines + h * body_lines_per_row

  return {
    grid = grid,
    w = w, h = h,
    row_headers = row_headers,
    col_headers = col_headers,
    row_header_width = row_header_width,
    prefix_width = prefix_width,
    compact = compact,
    glyph_width = glyph_width,
    pitch = pitch,
    image_mode = image_mode,
    image_height = image_height,
    edge_rows = edge_rows,
    body_lines_per_row = body_lines_per_row,
    col_header_lines = col_header_lines,
    total_width = total_width,
    total_height = total_height,
    -- Carried verbatim; under `compact` nothing calls them, because the
    -- slots they would draw into do not exist (see build_cell_line's and
    -- edge_rows' own compact gates).
    east_edge = opts.east_edge,
    south_edge = opts.south_edge,
    origin_label = opts.origin_label,
    col_label = opts.col_label or tostring,
    row_label = opts.row_label or tostring,
  }
end

-- A cell's glyph field, `gw` visible chars wide, with color/selection
-- escapes wrapped around it. `cell` may be nil (empty space).
local function glyph_field(cell, gw)
  if not cell then return string.rep(" ", gw) end
  -- A present-but-empty glyph ("") needs no special case: it takes the
  -- padding branch below and pads out to a full blank field, exactly like a
  -- nil cell. That is load-bearing -- a zero-width field would shorten the
  -- row and desynchronize every column to its right from cell_at -- so the
  -- padding must stay width-derived rather than a hardcoded single space.
  local g = cell.glyph or " "
  local text
  if #g >= gw then
    text = g:sub(1, gw)
  else
    text = g .. string.rep(" ", gw - #g)
  end

  local pre, post = "", ""
  if cell.color then pre = pre .. cell.color end
  if cell.sel then pre = pre .. REV_ON end
  if cell.sel then post = post .. REV_OFF end
  if cell.color then post = post .. RESET end

  if pre == "" and post == "" then
    return text
  end
  return pre .. text .. post
end

local function build_header_line(L)
  local parts = {}
  if L.row_headers then
    if L.origin_label then
      parts[#parts + 1] = pagelib.trunc(L.origin_label, L.row_header_width)
    else
      parts[#parts + 1] = string.rep(" ", L.row_header_width)
    end
    parts[#parts + 1] = " "
  end
  for c = 0, L.w - 1 do
    local label = tostring(L.col_label(c))
    -- At minimum zoom show alternate coordinates instead of "01020304".
    local stride = L.image_mode and math.ceil((#label + 1) / L.pitch) or 1
    parts[#parts + 1] = pagelib.trunc(c % stride == 0 and label or "", L.glyph_width)
    if not L.compact then parts[#parts + 1] = " " end
  end
  return table.concat(parts)
end

local function build_cell_line(L, r, subrow)
  subrow = subrow or 0
  local parts = {}
  if L.row_headers then
    parts[#parts + 1] = pagelib.trunc(subrow == 0 and L.row_label(r) or "", L.row_header_width)
    parts[#parts + 1] = " "
  end
  local grid = L.grid
  for c = 0, L.w - 1 do
    local cell = grid.cell(c, r)
    parts[#parts + 1] = glyph_field(cell, L.glyph_width)
    if not L.compact then
      local has_edge = L.east_edge and L.east_edge(c, r)
      parts[#parts + 1] = has_edge and "|" or " "
    end
  end
  return table.concat(parts)
end

local function build_edge_line(L, r)
  local parts = {}
  if L.row_headers then
    parts[#parts + 1] = string.rep(" ", L.row_header_width)
    parts[#parts + 1] = " "
  end
  for c = 0, L.w - 1 do
    local has_edge = L.south_edge and L.south_edge(c, r)
    parts[#parts + 1] = has_edge and "__" or "  "
    parts[#parts + 1] = " "
  end
  return table.concat(parts)
end

-- Inverts build_header_line/build_cell_line/build_edge_line's placement:
-- given a position on render()'s output, which cell (if any) is under it.
local function cell_at(L, x, y)
  if y < 0 or x < 0 then return nil end
  if y < L.col_header_lines then return nil end

  local gy = y - L.col_header_lines
  local group = math.floor(gy / L.body_lines_per_row)
  if group < 0 or group >= L.h then return nil end
  local line_in_group = gy % L.body_lines_per_row
  if line_in_group ~= 0 and not L.image_mode then return nil end
  local r = group

  local bx
  if L.row_headers then
    if x <= L.row_header_width then return nil end -- header field or separator
    bx = x - (L.row_header_width + 1)
  else
    bx = x
  end
  if bx < 0 then return nil end

  local c = math.floor(bx / L.pitch)
  if c >= L.w then return nil end
  -- The east-edge slot is the pitch's last column, and only wide mode has
  -- one (compact's pitch is 1, so this can never fire there).
  if bx % L.pitch == L.pitch - 1 and L.pitch > L.glyph_width then return nil end

  return c, r
end

local maplib = {}

-- Scope sizing to one render/pointer pass; other panes and remote viewers
-- must not change the geometry of an already painted local map.
function maplib.with_limit(limit, build)
  local previous = image_row_limit
  image_row_limit = limit
  local ok, a, b, c = pcall(build)
  image_row_limit = previous
  if not ok then error(a, 0) end
  return a, b, c
end

function maplib.fit(height, build, forced_limit)
  if forced_limit then
    local limit = math.max(1, math.min(image_row_limit, forced_limit))
    local a, b, c = maplib.with_limit(limit, build)
    return a, b, c, limit
  end
  measured_rows = 0
  local a, b, c = maplib.with_limit(1, build)
  local rows = measured_rows
  local limit = rows > 0 and math.max(1, math.min(2,
    math.floor(1 + (height - #a) / rows))) or 1
  if limit > 1 then a, b, c = maplib.with_limit(limit, build) end
  return a, b, c, limit
end

function maplib.render(grid, opts, available_width)
  opts = opts or {}
  local L = layout(grid, opts, available_width)
  if L.image_mode then measured_rows = measured_rows + L.h end
  local lines = {}

  if L.col_headers then
    lines[#lines + 1] = build_header_line(L)
  end
  for r = 0, L.h - 1 do
    lines[#lines + 1] = build_cell_line(L, r)
    if L.image_mode then
      for subrow = 1, L.body_lines_per_row - 1 do
        lines[#lines + 1] = build_cell_line(L, r, subrow)
      end
    end
    if L.edge_rows then
      lines[#lines + 1] = build_edge_line(L, r)
    end
  end

  return lines
end

function maplib.geometry(grid, opts, available_width)
  opts = opts or {}
  local L = layout(grid, opts, available_width)
  local images = {}
  if L.image_mode then
    for r = 0, L.h - 1 do
      for c = 0, L.w - 1 do
        local path, overlay = grid.image(c, r)
        -- Until the host supports text over PNGs, selection uses its
        -- reverse-video glyph in place, never an extra row between tiles.
        local cell = grid.cell(c, r)
        if cell and cell.sel then path = nil end
        -- The GROUND is drawn whenever the grid can name it, even when there is
        -- no marker to put on top -- `path` being nil is not a reason to leave
        -- a hole. Two cases reach here with path == nil on a tiled board and
        -- both showed the renderer's black clear colour before:
        --   * the SELECTED cell, blanked two lines above so its reverse-video
        --     glyph can be read -- which on a tiled board meant a black square
        --     following your own host around the campaign map;
        --   * a cell whose overlay id the board does not recognise. The
        --     campaign grid returns nil for anything that is not host/ally/
        --     foe/objective/landmark, and a detachment marker is exactly that.
        local ground = grid.under and grid.under(c, r) or nil
        if path or ground then
          local x = L.prefix_width + c * L.pitch
          local y = L.col_header_lines + r * L.body_lines_per_row
          -- A unit marker is a marker, not a tile: it says WHO is standing
          -- there, and the ground it stands on is the terrain underneath.
          -- Markers are drawn with transparent backdrops, so the board emits
          -- the terrain first and lets the marker composite over it -- which
          -- is why grids flag their overlays and expose `under`.
          -- Any image supplied by a terrain-backed grid is composited over
          -- that terrain. Do not make correctness depend on each individual
          -- marker remembering the overlay flag; transparent PNG pixels must
          -- never expose the renderer's clear color.
          -- Only when it differs from the marker: a grid whose own image IS
          -- the terrain (every cell with no marker on it) would otherwise emit
          -- that tile twice at the same spot -- two draws per empty cell, and
          -- a geometry twice the size it should be.
          if ground and ground ~= path then images[#images + 1] = {
            x = x, y = y, w = L.pitch, h = L.image_height, path = ground,
          } end
          if path then images[#images + 1] = {
            x = x, y = y, w = L.pitch, h = L.image_height, path = path,
          } end
        end
      end
    end
  end
  return {
    images = images,
    width = L.total_width,
    height = L.total_height,
    cell_at = function(x, y) return cell_at(L, x, y) end,
  }
end

-- Flows `entries` (each { glyph =, color =, label = }) left to right,
-- wrapping to a new line before exceeding `width`. Each entry renders as
-- its (optionally colored) glyph, a space, then its label; entries within a
-- line are joined by two spaces. Every entry carries its own reset, so a
-- color never bleeds into the next entry or the separator. A single entry
-- wider than `width` on its own is placed anyway, alone on its line, rather
-- than being truncated -- legend labels are caller-authored text, not
-- board content subject to a hard width budget.
function maplib.legend(width, entries)
  local SEP = "  "
  local lines = {}
  local cur_parts, cur_width = {}, 0

  for _, e in ipairs(entries) do
    local glyph = e.glyph or ""
    local text
    if e.color then
      text = e.color .. glyph .. RESET .. " " .. (e.label or "")
    else
      text = glyph .. " " .. (e.label or "")
    end
    local text_w = pagelib.visible_width(text)

    if #cur_parts == 0 then
      cur_parts, cur_width = { text }, text_w
    elseif cur_width + #SEP + text_w <= width then
      cur_parts[#cur_parts + 1] = text
      cur_width = cur_width + #SEP + text_w
    else
      lines[#lines + 1] = table.concat(cur_parts, SEP)
      cur_parts, cur_width = { text }, text_w
    end
  end
  if #cur_parts > 0 then
    lines[#lines + 1] = table.concat(cur_parts, SEP)
  end

  return lines
end

return maplib
