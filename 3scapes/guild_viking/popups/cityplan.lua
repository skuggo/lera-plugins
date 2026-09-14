-- City Plan popup (/vik cityplan): LEGACY guild_viking.lua's City Plan
-- section inside draw_page2's city mode (8758-9109), TEXT-VIEW branch only
-- (LEGACY's own `show_city_plan_icons=false` default -- the graphical
-- building/terrain icon and Wang-tile branch is a graphical rendering of
-- the exact same cells and is NOT ported, same ruling as popups/map.lua's
-- show_map_icons and popups/sea.lua's show_sea_chart_icons). PAL (building
-- colour classes, 8771-8781) and tile_spec (terrain glyph/colour, 8784-8793)
-- are ported verbatim below as CITYPLAN_PAL / TILE.
--
-- Data source: CPLAN/CPP/CPT%02d/CPB/CPU/CPEND (handlers/city.lua,
-- guild_viking.lua 1850-1912), committed to S.city_plan on a complete
-- CPEND burst -- same double-buffer pattern as VMAP/WMAP. S.city_plan.rows
-- is 1-INDEXED Lua storage for a 0-based wire row (handlers/city.lua's
-- cpt_row stores at rows[ridx + 1] for wire row ridx, CPLAN 1869/1874) --
-- maplib's `r` here is the 0-based grid row, so every row read below is
-- `rows[r + 1]`, same convention popups/map.lua's terrain_glyph and
-- popups/sea.lua's chart_row already use.
--
-- Interaction fidelity: draw_page2 registers exactly one hotspot family on
-- the interior dim x dim sub-square, "cpt_<ix>_<iy>" (guild_viking.lua
-- 9024-9030), with NO icon/text-view gating at all -- unlike
-- popups/map.lua's vmp_* (icon-only) hotspots, these fire in the TEXT-VIEW
-- branch too, so this is a genuinely live interaction, not a lera
-- addition. viking_cityplan_down (13192-13194) unconditionally returns
-- true (consumes every mouse-down on a plot, matching this module's
-- on_pointer "down" case below). viking_cityplan_click (13196-13210) only
-- acts on a RIGHT-click (`bit.band(flags, miniwin.hotspot_got_rh_mouse)`):
-- a left click just closes any open tile menu and consumes; a right click
-- opens viking_show_cityplan_menu (13117-13148), whose item set/commands
-- are ported verbatim below into open_context_menu -- occupied plot: one
-- "Lift <name>" item (`vplan lift <id>`); empty plot: one "Place  <name>"
-- item per unplaced building (`vplan place <id> <cell>`, sorted by
-- name/id), or "Nothing left to place" when none are unplaced; both cases
-- append a "Cancel" item. LEGACY's "Nothing left to place"/"Cancel" rows
-- are pure decoration with no attached hotspot at all (a click there does
-- literally nothing); this port gives them a real, working Cancel via
-- require("menu")'s own Escape/Ctrl+G and a no-op on_select for a
-- non-string value -- the sanctioned menu-pattern upgrade the plan already
-- credits to popups/sea.lua's confirm-menu port.
--
-- The hover/info line (module-local `hover`, same pattern as
-- popups/map.lua and popups/sea.lua) flattens the hotspot's native
-- "<cell>  <name>\r\nRight-click: ..." tooltip text (9020-9022) to one
-- line, exactly as those modules' own hover lines flatten LEGACY's
-- multi-line tooltips.
--
-- Dropped-with-reason: the castle keep's Wang-mask icon selection
-- (8865-8890, `cconn`/mask/`viking_window.castle_icons`) is icon-only
-- bookkeeping this port never reaches -- the TEXT-VIEW fallback it computes
-- alongside (border cells draw the keep wall "#", interior courtyard cells
-- draw blank, 8891-8899) is what's ported below. Multi-tile building
-- variant slicing (tl/tr/bl/br, 8905-8915) only ever picks among icon
-- assets, so it is dropped the same way. The per-frame debug diagnostic
-- line (9066-9080: framed grid size/row completeness plus "icons X/48"
-- icon-load counters) is dropped as an icon-branch/debug artifact, not
-- part of the four footer lines (status/perks/mood/coast) the brief scopes
-- this module to. It once also carried `cp.dbg`'s "dropped: got N/M rows"
-- text, so an incomplete CPEND burst could not be silently invisible; the
-- plan arrives whole over Guild.City now, so that condition and its line are
-- both gone (see footer_lines below).
local pagelib = require("pagelib")
local maplib = require("maplib")
local state = require("state")
local page_opts = require("page_opts")
local track = require("popups.pointer_track").tracker()

-- One character per cell. This board draws no column/row headers and never
-- populates maplib's east/south edge hooks, so at maplib's wide 3-char pitch
-- two of every three columns were padding and a reserved wall slot -- on a
-- plan whose grid is the plan's own dimension plus a margin on each side,
-- that is most of the popup's width spent on nothing. `compact` drops both.
--
-- The one cost (see maplib's COMPACT note): a glyph longer than one char
-- truncates to its first. A building's glyph is wire data --
-- `tostring(b.glyph or "?")` in handlers/city.lua -- so a two-character
-- glyph from the mudlib would lose its second char. Every glyph it sends
-- today is a single character.
local GRID_OPTS = { compact = true }

local S = state.S
local C = pagelib.C
local RESET = pagelib.RESET

local M = {}
M.title = "City Plan"

-- Module-local hover/info line, same pattern as popups/map.lua and
-- popups/sea.lua.
local hover = ""

-- ---------------------------------------------------------------------------
-- CITYPLAN_PAL (guild_viking.lua:8771-8781, "PAL" locally), ported verbatim
-- as the symbol -> hex comment pairs; decoded into pagelib.C below.
--
-- BGR decode workbook (byte order 0xBBGGRR: leftmost byte = Blue, middle =
-- Green, rightmost = Red -- the table's own header comment says "Colours
-- are BGR (0xBBGGRR), matching the rest of the client", same convention as
-- popups/map.lua's/popups/sea.lua's workbooks). pagelib.C has ten hues;
-- literals with no available hue fold to the nearest one, same "no blue ->
-- cyan" precedent popups/map.lua's workbook sets.
--
--   p 0x44CC44 -> R=44,G=CC,B=44  green            -> C.green
--   i 0x3333CC -> R=CC,G=33,B=33  red              -> C.red
--   k 0x999999 -> R=99,G=99,B=99  grey             -> C.dim
--   t 0x22CCEE -> R=EE,G=CC,B=22  gold/yellow      -> C.yellow  (comment: gold)
--   c 0xCC33CC -> R=CC,G=33,B=CC  magenta          -> C.magenta (comment: magenta)
--   h 0x00DDEE -> R=EE,G=DD,B=00  yellow           -> C.yellow  (comment: yellow)
--   T 0xFFFFFF -> R=FF,G=FF,B=FF  white            -> C.white   (comment: white)
--   e 0xDDCC33 -> R=33,G=CC,B=DD  cyan             -> C.cyan    (comment: cyan)
--   v 0xE0A050 -> R=50,G=A0,B=E0  light blue       -> C.cyan (folded; pagelib.C
--       has no blue) (comment: light blue -- matches the decode)
-- ---------------------------------------------------------------------------
local CITYPLAN_PAL = {
  p = C.green, i = C.red, k = C.dim, t = C.yellow, c = C.magenta, h = C.yellow,
  T = C.white, e = C.cyan, v = C.cyan,
}
local CITYPLAN_PAL_FALLBACK = CITYPLAN_PAL.e -- LEGACY: `PAL[occ.pal] or PAL.e`

-- ---------------------------------------------------------------------------
-- tile_spec (guild_viking.lua:8784-8793), ported verbatim as (glyph, gcol)
-- pairs -- `bg` (the pixel rectangle fill) is dropped, same "foreground
-- glyph colour only" convention every other board popup in this plugin
-- follows (there is no ANSI background-fill equivalent in a text grid).
-- BGR decode (same workbook as above):
--
--   W wall   gcol=0x888888 -> grey                    -> C.dim
--   G gate   gcol=0x33CCFF -> R=FF,G=CC,B=33 yellow    -> C.yellow
--   M moat   gcol=0xCC6622 -> R=22,G=66,B=CC blue      -> C.cyan (folded)
--   B bridge gcol=0x3A7AAA -> R=AA,G=7A,B=3A orange    -> C.red (folded,
--       same "orange folds to red" precedent popups/map.lua sets)
--   c coast  gcol=0xDDCC33 -> R=33,G=CC,B=DD cyan      -> C.cyan
--   w river  gcol=0xCC8844 -> R=44,G=88,B=CC blue      -> C.cyan (folded)
--   f woods  gcol=0x509050 -> R=50,G=90,B=50 green     -> C.green
--   H/^ hill gcol=0x9A9A9A -> grey                     -> C.dim
--   # rock   gcol=0x4488AA -> R=AA,G=88,B=44 orange    -> C.red (folded)
--   . plain (default/unknown) gcol=0x4A5050 -> R=50,G=50,B=4A near-neutral
--       grey -> C.dim
--
-- Two same-glyph-different-colour pairs are LEGACY's own choice, ported
-- verbatim, not a porting defect: "#" is both rock (red-folded) and, via a
-- separate char "W", the wall glyph (dim); "~" is both coast (cyan) and,
-- via a separate char "M", the moat glyph (also cyan here, so the two are
-- visually identical -- unlike the "#" pair, which differ by colour).
-- ---------------------------------------------------------------------------
local TILE = {
  W = { glyph = "#", color = C.dim },
  G = { glyph = "+", color = C.yellow },
  M = { glyph = "~", color = C.cyan },
  B = { glyph = "=", color = C.red },
  c = { glyph = "~", color = C.cyan },
  w = { glyph = "w", color = C.cyan },
  f = { glyph = "f", color = C.green },
  H = { glyph = "^", color = C.dim },
  ["^"] = { glyph = "^", color = C.dim },
  ["#"] = { glyph = "#", color = C.red },
}
local TILE_DEFAULT = { glyph = ".", color = C.dim }

-- TNAME (guild_viking.lua:8886-8888), ported verbatim as the hover-tooltip
-- terrain vocabulary.
local TNAME = {
  ["."] = "Plain", f = "Woods", ["^"] = "Hill", H = "Hill", c = "Coast",
  w = "River", ["#"] = "Rock", W = "Wall", M = "Moat", G = "Gate", B = "Bridge",
}

-- Legend entries (guild_viking.lua:9083-9105's three legend_row calls),
-- ported verbatim as glyph/label/colour triples. Group 1 (building roles)
-- shows NO glyph in LEGACY -- just a colour-swatched word ("produce",
-- "industry", ...); this port adds the PAL key letter as maplib.legend's
-- glyph field (a disclosed lera addition, consistent with the grid's own
-- PAL-keyed overlay glyphs) since maplib.legend's shared contract requires
-- one. Group 1 also omits PAL's own "e"/"v" keys (beacon/civic) -- LEGACY's
-- own choice, ported as-is (9083-9089 lists only 7 of PAL's 9 entries).
local LEGEND_ROLES = {
  { sym = "p", lbl = "produce" }, { sym = "i", lbl = "industry" },
  { sym = "k", lbl = "grim" }, { sym = "t", lbl = "trade" },
  { sym = "c", lbl = "culture" }, { sym = "h", lbl = "homes" },
  { sym = "T", lbl = "throne" },
}
-- Group 2/3 colours are SEPARATE literals from tile_spec's gcol in LEGACY
-- (not reused), yet decode to the same hue class in every case except
-- "plain": legend's 0x8A8A80 (R=80,G=8A,B=8A, near-neutral grey) vs
-- tile_spec's 0x4A5050 for the actual glyph -- both fold to C.dim, so the
-- mismatch is invisible in our ten-hue palette even though it is a real
-- LEGACY-internal inconsistency between the swatch and the glyph it
-- represents, ported verbatim rather than "fixed".
local LEGEND_TERRAIN = {
  { sym = ".", lbl = "plain", color = C.dim },
  { sym = "f", lbl = "woods", color = C.green },
  { sym = "^", lbl = "hill", color = C.dim },
  { sym = "~", lbl = "coast", color = C.cyan },
  { sym = "w", lbl = "river", color = C.cyan },
  { sym = "#", lbl = "rock", color = C.red },
}
local LEGEND_FRAME = {
  { sym = "#", lbl = "wall", color = C.dim },
  { sym = "~", lbl = "moat", color = C.cyan },
  { sym = "+", lbl = "gate", color = C.yellow },
  { sym = "=", lbl = "bridge", color = C.red },
}

local function legend_entries()
  local out = {}
  for _, e in ipairs(LEGEND_ROLES) do
    out[#out + 1] = { glyph = e.sym, color = CITYPLAN_PAL[e.sym], label = e.lbl }
  end
  for _, e in ipairs(LEGEND_TERRAIN) do
    out[#out + 1] = { glyph = e.sym, color = e.color, label = e.lbl }
  end
  for _, e in ipairs(LEGEND_FRAME) do
    out[#out + 1] = { glyph = e.sym, color = e.color, label = e.lbl }
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Grid geometry. Draws EXACTLY the framed rows the server sent (gw = widest
-- row received, gh = #rows received), matching LEGACY's own "never
-- phantom/short rows" comment (8794-8795); when no rows have arrived at all
-- (gh or gw == 0), LEGACY falls back to a synthetic (dim + 6)-square blank
-- grid (8798-8800) -- ported verbatim, though in practice a committed
-- S.city_plan always has got == expected > 0 rows (CPEND only commits on
-- that match), so this fallback is normally unreachable, same as in LEGACY.
-- `margin = cp.margin or floor((gh - dim) / 2)` (8801) is likewise ported
-- verbatim even though handlers/city.lua's CPLAN parser always supplies a
-- numeric margin (default 3), making the `or` fallback dead in practice
-- here exactly as it is in LEGACY.
-- ---------------------------------------------------------------------------
local function plan_geometry(cp)
  local rows = cp.rows or {}
  local dim = cp.dim or 12
  local gh, gw = #rows, 0
  for _, r in ipairs(rows) do if #r > gw then gw = #r end end
  if gh == 0 or gw == 0 then
    gh, gw = dim + 6, dim + 6
  end
  local margin = cp.margin or math.floor((gh - dim) / 2)
  return gw, gh, margin, dim
end

-- Placed-building overlay (guild_viking.lua:8815-8827's `_lay_bld`/overlay):
-- castle laid first, then every other building on top (so a keep-gated
-- building placed inside the castle's own footprint overwrites those
-- cells and renders as itself, not as castle wall/courtyard) -- keyed
-- directly by 0-based full-grid (r, c), since `b.x + ox + margin` here is
-- exactly LEGACY's `cx - 1` (cx being LEGACY's 1-based full-grid column).
local function build_overlay(cp, margin)
  local overlay = {}
  local function lay(b)
    local bw, bh = b.w or 1, b.h or 1
    for oy = 0, bh - 1 do
      for ox = 0, bw - 1 do
        local r = (b.y or 0) + oy + margin
        local c = (b.x or 0) + ox + margin
        overlay[r] = overlay[r] or {}
        overlay[r][c] = b
      end
    end
  end
  for _, b in ipairs(cp.blds or {}) do if b.id == "castle" then lay(b) end end
  for _, b in ipairs(cp.blds or {}) do if b.id ~= "castle" then lay(b) end end
  return overlay
end

local function plot_at(cp, margin, c, r)
  local overlay = build_overlay(cp, margin)
  return overlay[r] and overlay[r][c]
end

-- Castle keep rendering (guild_viking.lua:8865-8899's TEXT-VIEW fallback:
-- border cells draw the keep wall, everything else inside the footprint is
-- an open courtyard). `occ` here is always the castle building record
-- itself (occ.id == "castle").
local function castle_cell(occ, margin, c, r)
  local bw, bh = occ.w or 1, occ.h or 1
  local x0, y0 = (occ.x or 0) + margin, (occ.y or 0) + margin
  local border = c == x0 or c == x0 + bw - 1 or r == y0 or r == y0 + bh - 1
  if border then return { glyph = "#", color = C.dim } end
  -- Open courtyard. Returns nil so make_grid() falls through to the terrain
  -- cell underneath, which is what the MUD's own vplan does: its castle
  -- overlay paints the keep wall and leaves the interior showing the ground
  -- ('.', or whatever terrain is there). LEGACY drew a hard blank here, and
  -- carrying that over left a hole in the middle of the plan that did not
  -- match the game -- rows F/G/H of a walled city came out empty where the
  -- MUD shows plain ground.
  return nil
end

local function terrain_cell(cp, c, r)
  local rows = cp.rows or {}
  local row = rows[r + 1] or ""
  local ch = row:sub(c + 1, c + 1)
  if ch == "" then ch = "." end
  local t = TILE[ch] or TILE_DEFAULT
  return { glyph = t.glyph, color = t.color }, ch
end

local function make_grid(cp)
  local gw, gh, margin = plan_geometry(cp)
  local overlay = build_overlay(cp, margin)
  return {
    w = gw, h = gh,
    cell = function(c, r)
      local occ = overlay[r] and overlay[r][c]
      if occ and occ.id == "castle" then
        -- nil = open courtyard: show the ground under it, as the MUD does.
        local cc = castle_cell(occ, margin, c, r)
        if cc then return cc end
        return (terrain_cell(cp, c, r))
      elseif occ then
        return { glyph = occ.glyph or "?", color = CITYPLAN_PAL[occ.pal] or CITYPLAN_PAL_FALLBACK }
      end
      return (terrain_cell(cp, c, r))
    end,
  }
end

-- ---------------------------------------------------------------------------
-- Footer (guild_viking.lua:9032-9057): status (Unplanned, when
-- `not cp.enabled`) or perks + mood (when enabled), then coast/placed --
-- always shown.
--
-- This used to end with `cp.dbg`'s "dropped: got N/M rows" warning, so an
-- incomplete grid could not look silently authoritative. That was a MIP
-- concern: the plan arrived as a CPT%02d burst and a dropped chunk was
-- indistinguishable from a short grid, so CPEND compared a promised row count
-- and stamped cp.dbg when it did not match. A Guild.City frame carries the
-- plan whole, nothing sets cp.dbg any more, and the warning is gone with the
-- burst that motivated it.
-- ---------------------------------------------------------------------------
local COAST_NAME = { "North", "East", "South", "West" }

local function footer_lines(width, cp)
  local out = {}
  if not cp.enabled then
    out[#out + 1] = pagelib.trunc(C.dim .. "Unplanned - enable in-game: vplan enable" .. RESET, width)
  else
    if cp.perks and cp.perks ~= "" then
      out[#out + 1] = pagelib.trunc(C.green .. "Perks: " .. cp.perks .. RESET, width)
    end
    local md = cp.mood or 0
    if md ~= 0 then
      local mc = md < 0 and C.red or C.green
      out[#out + 1] = pagelib.trunc(mc .. string.format("Zoning/heart mood: %+d", md) .. RESET, width)
    end
  end
  out[#out + 1] = pagelib.trunc(C.cyan .. string.format(
    "Coast: %s   Placed %d/%d (rank cap)",
    COAST_NAME[cp.coast] or "?", cp.placed or 0, cp.cap or 0) .. RESET, width)
  return out
end

-- ---------------------------------------------------------------------------
-- Pre-grid lines (header, plus the opt-off/no-data short-circuits) --
-- shared by lines()/geometry()/grid_line_offset() so the three can never
-- drift apart, same discipline popups/map.lua's pre_grid_lines and
-- popups/sea.lua's pre_chart_lines follow.
--
-- LEGACY's `page_opts.show_city_plan and state.city_plan and
-- state.city_plan.dim` gate (8759) draws NOTHING at all (not even a
-- header) when false -- but this is now a dedicated popup rather than an
-- embedded page section, so (like popups/sea.lua's pre_chart_lines always
-- emitting its own header before checking mip_voyage_seen/show_sea_voyage)
-- this module always emits a "City Plan" header first. The opt-off case
-- then matches popups/sea.lua's own show_sea_voyage-off precedent exactly:
-- header only, no further content, no message. The no-data case (opt on,
-- but S.city_plan.dim never arrived) is where this module adds its own
-- hint line -- a lera addition, disclosed, in the same spirit as
-- popups/map.lua's "vtoggle mip_map" hint -- since there is no MIP-style
-- toggle gating this feed, the hint instead points at the in-game command
-- that populates it.
-- ---------------------------------------------------------------------------
local function pre_grid_lines(width)
  local out = { pagelib.header(width, "City Plan") }
  if not page_opts.get("show_city_plan") then
    return out, false
  end
  local cp = S.city_plan
  if not (cp and cp.dim) then
    out[#out + 1] = pagelib.trunc(C.dim .. "No data - view it in-game: vplan" .. RESET, width)
    return out, false
  end
  return out, true
end

-- Inline rendering for the City page (pages/city.lua). Same grid, footer and
-- legend as the popup, minus the two things that only make sense in a popup:
-- the hover line (there is no pointer tracking on a page) and the blank line
-- that reserves room for it.
--
-- Deliberately shares make_grid()/footer_lines()/legend_entries() rather than
-- reimplementing them on the page: the palette, the tile table and the
-- castle/overlay precedence are all LEGACY-derived and documented above, and
-- a second copy would drift from this one.
function M.inline_lines(width)
  local out, has_grid = pre_grid_lines(width)
  if not has_grid then return out end

  local cp = S.city_plan

  -- Rendered in the SHAPE the game's own `vplan` uses (cmd/vplan.c:226-240),
  -- not maplib's packed one-char-per-cell grid. In game each cell is two
  -- columns wide -- glyph then a space -- with a numeric ruler over the
  -- interior columns and a letter down the interior rows, which is what makes
  -- the plan readable and what "vplan place <bldg> <cell>" refers to (B7, K12).
  -- maplib.render packs glyphs with no separator and no labels, so the page
  -- looked cramped and nothing like the in-game view.
  --
  -- The popup keeps maplib.render: it has pointer tracking, so a cell is
  -- identified by clicking rather than by reading a label off the axis.
  local grid = make_grid(cp)
  local gw, gh, margin = plan_geometry(cp)
  local dim = cp.dim or 12

  local ruler = "  "
  for c = 0, gw - 1 do
    local ic = c - margin
    ruler = ruler .. ((ic >= 0 and ic < dim)
      and string.format("%-2d", ic + 1) or "  ")
  end
  out[#out + 1] = pagelib.trunc(C.white .. ruler .. RESET, width)
  out[#out + 1] = ""

  for r = 0, gh - 1 do
    local ir = r - margin
    local line = (ir >= 0 and ir < dim)
      and (C.white .. string.char(65 + ir) .. RESET .. " ") or "  "
    for c = 0, gw - 1 do
      local cell = grid.cell(c, r)
      line = line .. (cell.color or C.dim) .. (cell.glyph or ".") .. RESET .. " "
    end
    out[#out + 1] = pagelib.trunc(line, width)
  end

  for _, l in ipairs(footer_lines(width, cp)) do out[#out + 1] = l end
  if page_opts.get("show_city_plan_legend") then
    for _, l in ipairs(maplib.legend(width, legend_entries())) do out[#out + 1] = l end
  end
  return out
end

function M.lines(width)
  local out, has_grid = pre_grid_lines(width)
  if not has_grid then return out end

  local cp = S.city_plan
  for _, l in ipairs(maplib.render(make_grid(cp), GRID_OPTS)) do out[#out + 1] = l end
  out[#out + 1] = hover ~= "" and pagelib.trunc(hover, width) or ""
  for _, l in ipairs(footer_lines(width, cp)) do out[#out + 1] = l end
  if page_opts.get("show_city_plan_legend") then
    for _, l in ipairs(maplib.legend(width, legend_entries())) do out[#out + 1] = l end
  end
  return out
end

-- geometry()/grid_line_offset(): the ctx.cell_from_xy contract popups.lua
-- documents. nil/unreachable whenever the grid isn't the thing actually on
-- screen -- opt off or no data yet.
function M.geometry(width)
  local _, has_grid = pre_grid_lines(width)
  if not has_grid then return nil end
  return maplib.geometry(make_grid(S.city_plan), GRID_OPTS)
end

function M.grid_line_offset(width)
  local out = pre_grid_lines(width)
  return #out
end

-- ---------------------------------------------------------------------------
-- Interaction: cpt_<ix>_<iy> plot hotspots (guild_viking.lua:9024-9030),
-- interior-only (`ix,iy` inside [0, dim)) -- a click outside the interior
-- (on the wall/moat/gate/bridge border) has no LEGACY hotspot at all, so
-- this port passes it through unconsumed (nil), same as popups/map.lua's
-- and popups/sea.lua's out-of-grid handling.
-- ---------------------------------------------------------------------------

-- cellname (guild_viking.lua:9017: `string.char(65 + iy) .. tostring(ix + 1)`
-- -- row letter, then a 1-based, non-zero-padded column number).
local function cellname(ix, iy)
  return string.char(65 + iy) .. tostring(ix + 1)
end

-- viking_cityplan_click's tooltip text (9020-9022), flattened to one line
-- (same convention as popups/map.lua's cell_tip / popups/sea.lua's
-- chart_hover_text).
local function hover_text(cp, c, r, ix, iy, occ)
  local cell = cellname(ix, iy)
  if occ then
    return cell .. "  " .. (occ.name or occ.id) .. "  -  Right-click: lift or replace"
  end
  local _, ch = terrain_cell(cp, c, r)
  return cell .. "  " .. (TNAME[ch] or "Ground") .. "  -  Right-click: place a building"
end

-- Resolves a wrapper-local (x, y) to (c, r, ix, iy) when it lands on the
-- interior dim x dim sub-square, or nil when it does not (border cell, or
-- entirely outside the grid).
local function locate(cp, ctx, x, y)
  local c, r = ctx.cell_from_xy(x, y)
  if not c then return nil end
  local _, _, margin, dim = plan_geometry(cp)
  local ix, iy = c - margin, r - margin
  if ix < 0 or ix >= dim or iy < 0 or iy >= dim then return nil end
  return c, r, ix, iy
end

-- unplaced list (CPU, sorted by name/id) -- guild_viking.lua:13129-13132.
local function unplaced_sorted(cp)
  local up = {}
  for _, b in ipairs(cp.unplaced or {}) do up[#up + 1] = b end
  table.sort(up, function(a, b) return (a.name or a.id) < (b.name or b.id) end)
  return up
end

-- viking_show_cityplan_menu (guild_viking.lua:13117-13148), ported
-- verbatim as item label/value pairs. `value` is the exact command string
-- for an actionable row, or `false` for a decorative one ("Nothing left to
-- place", "Cancel") -- on_select below only ever mud.send()s a string.
local function open_context_menu(cp, cell, occ)
  local items = {}
  if occ then
    items[#items + 1] = { label = "Lift " .. (occ.name or occ.id),
      value = "vplan lift " .. occ.id }
  else
    local up = unplaced_sorted(cp)
    if #up == 0 then
      items[#items + 1] = { label = "Nothing left to place", value = false }
    else
      for _, b in ipairs(up) do
        items[#items + 1] = { label = "Place  " .. (b.name or b.id),
          value = "vplan place " .. b.id .. " " .. cell }
      end
    end
  end
  items[#items + 1] = { label = "Cancel", value = false }

  require("menu").open({
    items = items,
    title = cell .. "  " .. (occ and (occ.name or occ.id) or "empty tile"),
    on_select = function(value)
      if type(value) == "string" then mud.send(value) end
    end,
  })
end

-- Mirrors viking_cityplan_down (always consumes) / viking_cityplan_click
-- (right-click opens the tile menu; anything else just closes any open
-- menu and consumes) -- plus the hover-line update on move/down, same
-- pattern as popups/map.lua's and popups/sea.lua's on_pointer.
--
-- Down-target recording (fix round 2, Important #1, via
-- popups/pointer_track.lua): a down over a plot records its (c, r); the
-- right-click context menu (whose item set and title are keyed to the
-- SPECIFIC plot clicked) only opens when the up's plot matches -- a drag
-- from one plot's down to a different plot's up must not open the wrong
-- plot's menu. The left-click "close any open menu" branch has no such
-- per-plot content, so it stays unconditional -- there is nothing for a
-- cross-target drag to get wrong there.
function M.on_pointer(ev, ctx)
  if not ctx.cell_from_xy then return nil end
  local cp = S.city_plan
  if not (cp and cp.dim) then return nil end
  local _, _, margin = plan_geometry(cp)

  if ev.kind == "cancel" then
    track.clear()
    return nil
  end

  if ev.kind == "move" then
    local c, r, ix, iy = locate(cp, ctx, ev.x, ev.y)
    if not c then
      -- Fix round 2, Minor: clear a stale hover line on an off-grid move.
      if hover ~= "" then hover = ""; ui.dirty() end
      return nil
    end
    hover = hover_text(cp, c, r, ix, iy, plot_at(cp, margin, c, r))
    ui.dirty()
    return nil
  end

  if ev.kind == "down" then
    local c, r, ix, iy = locate(cp, ctx, ev.x, ev.y)
    if not c then return nil end
    track.record({ kind = "cell", c = c, r = r })
    hover = hover_text(cp, c, r, ix, iy, plot_at(cp, margin, c, r))
    ui.dirty()
    return true
  end

  if ev.kind == "up" then
    local c, r, ix, iy = locate(cp, ctx, ev.x, ev.y)
    if not c then
      track.clear()
      return nil
    end
    if ev.button == "right" then
      if track.matches({ kind = "cell", c = c, r = r }) then
        local occ = plot_at(cp, margin, c, r)
        open_context_menu(cp, cellname(ix, iy), occ)
      end
    else
      require("menu").close()
    end
    track.clear()
    return true
  end

  return nil
end

-- Called by popups.lua's registry when this popup closes (fix round 2,
-- Minor: "clear hover on close").
function M.reset()
  hover = ""
end

return M
