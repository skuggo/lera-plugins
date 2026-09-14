-- Territory Map popup (/vik map): LEGACY guild_viking.lua's draw_page7
-- (12377-12755), TEXT-VIEW branch only (LEGACY's own `show_map_icons=false`
-- default -- the Wang-tile / building-icon branch is a graphical rendering
-- of the exact same cells and is NOT ported, per the plan's "PNG tiles and
-- pixel hotspots do not carry over" ruling). VMAP_SYM_COL (10990-11015) and
-- VMAP_TYPE_LABEL (11018-11029) below are ported verbatim.
--
-- Interaction fidelity: draw_page7's ONLY hotspot family is
-- "vmp_<col>_<row>" (guild_viking.lua:12639-12655), and every one of them
-- is registered via WindowAddHotspot with all five callback slots
-- ("", "", "", "", "") empty -- a pure hover tooltip, no click behavior at
-- all EVEN WHEN IT FIRES. And it does not fire in the branch this module
-- ports: creation is gated by `vmap_allow_hotspots = icons and cell_w >= 7
-- and (gw*gh <= 4096)` (guild_viking.lua:12514, checked at the registration
-- site 12638), where `icons` requires `page_opts.show_map_icons` (12422) --
-- the graphical Wang-tile branch this task deliberately does NOT port (see
-- above). In the TEXT-VIEW branch (icons=false, our target), LEGACY fires
-- ZERO "vmp_*" hotspots on this page: there is no click behavior riding on
-- THAT family to port, in either branch.
--
-- The module-local `hover` info line below (updated from on_pointer through
-- the ctx.cell_from_xy contract, see popups.lua's header comment) is
-- therefore a LERA ADDITION as far as "vmp_*" goes, not a port of a live
-- LEGACY interaction -- exactly the same category as the edge-wall overlay
-- this module used to draw and no longer does (see the compact-rendering
-- note further down). It gives the text view a hover affordance
-- analogous to what the icon view's tooltip WOULD have shown had this task
-- ported that branch, using the tooltip's own text format/vocabulary
-- (still ported verbatim: VMAP_TIP_TERR/VMAP_TIP_SYM below, and the
-- "(%d,%d)  %s" format string, guild_viking.lua:12652).
--
-- Task 5 (POI travel menu) IS a genuinely live LEGACY interaction, just not
-- one reached through "vmp_*". Its only live attach point is the generic
-- per-page right-click context menu -- PAGE_MENUS[7]'s "Travel to..." item
-- (guild_viking.lua:11092-11096) -> viking_page_menu_pick's "travel" branch
-- (11211, 11216) -> viking_show_poi_menu (11789-11814) -- chrome stage 2/3
-- dropped entirely (lera has no generic per-page right-click menu; see
-- autotrader/tick.lua's header comment for the identical precedent with
-- viking_show_atrade_menu, including its own explicit "assign the dropped
-- trigger to something else" ruling). viking_vmap_any_mouseup/mousedown
-- (11822-11841) are NOT that attach point and are NOT ported: grep confirms
-- neither is ever registered as a WindowAddHotspot callback anywhere in
-- guild_viking.lua -- dead code, same class of finding as
-- viking_resolve_poi_at below.
--
-- Retargeted trigger (disclosed adaptation, per the task brief): since the
-- page-context chrome is gone, a LEFT down on a POI/town cell (a cell
-- poi_lookup() resolves -- i.e. a rendered town glyph) is this port's
-- trigger instead of a right-click anywhere on the page. The down is
-- consumed and recorded via popups/pointer_track.lua (a module-local
-- tracker, same discipline popups/cityplan.lua/sea.lua/war_*.lua already
-- use -- see the "Pointer" section below for why THIS module now needs
-- one, where it used to need none). The matching up opens the SAME menu
-- content viking_show_poi_menu built: the list is NOT filtered to the
-- clicked POI -- it lists every travelable location, exactly what LEGACY's
-- own right-click-anywhere trigger showed.
--
-- Hotspot / attach-point -> port table:
--   LEGACY vmp_<col>_<row>         guild_viking.lua   on_pointer move/down
--     (hover only, no click;         :12639-12655       hover (unchanged,
--      unchanged)                                        this task didn't
--                                                         touch it)
--   PAGE_MENUS[7] "Travel to..."   :11092-11096       dropped chrome;
--     -> viking_page_menu_pick      :11211, 11216        retargeted onto a
--     -> viking_show_poi_menu       :11789-11814          left-click on a
--                                                          POI/town cell
--                                                          (see above)
--   viking_draw_poi_menu's         :11913-12048       require("menu")
--     "poi_pick_<n>" hotspots       :11977                (its own
--     + poi_scroll_up/down/         :12038-12070          windowing
--       thumb_drag/scroll_wheel     :12057-12068          replaces the
--                                                          bespoke miniwin
--                                                          popup+scrollbar
--                                                          -- same upgrade
--                                                          precedent as
--                                                          cityplan's and
--                                                          sea's own menu
--                                                          ports)
--   viking_poi_menu_pick           :12332-12341       menu's on_select ->
--                                                        travel_to(poi)
--   viking_poi_menu_travel         :12343-12369       travel_to(poi):
--                                                        pathfinding.bfs +
--                                                        mud.send loop
--   viking_vmap_any_mouseup/       :11822-11841       NOT ported: dead
--     mousedown                                         code, never
--                                                        registered
--                                                        (grep-confirmed)
--
-- ColourNote status messages ("you are not on the map" / "No locations
-- available to travel to" / "No passable route to X" / "Already at X" /
-- "Traveling to X (n steps)") ARE ported, through `status()` below. They
-- were originally dropped as "display-only", per the convention every other
-- pointer handler in this plugin follows (popups/war_campaign.lua's "Click a
-- host first" note). That was wrong here, and reverting it is a deliberate
-- deviation from that convention rather than an oversight:
--
-- Every other dropped note in this plugin annotates a gesture whose outcome
-- is visible anyway -- war_campaign's "Click a host first" accompanies a
-- click that plainly did not select anything. These five annotate a MENU
-- that does not appear, or a picked destination that sends nothing. With the
-- note dropped, "Travel to..." is indistinguishable from a broken menu item:
-- the two guards in open_poi_menu below are the ONLY reason it can no-op,
-- and neither is discoverable from the screen. Reported as a real bug from
-- live play; the guard LOGIC was correct and tested all along, and only the
-- silence was the defect.
--
-- No pacing to port (review round 1 correction -- the original version of
-- this note claimed LEGACY paced sends and disclosed dropping that; the
-- premise was false). viking_poi_menu_travel's loop (MAIN 12358-12365)
-- reads:
--   for i, dir in ipairs(path) do
--     Send(dir)
--     if i < #path then DoAfterSpecial(0.5, "", sendto.execute) end
--   end
-- DoAfterSpecial registers a one-shot timer and returns immediately -- it
-- cannot block the running Lua loop (MUSHclient has no such API); the
-- SAME file proves this elsewhere: guild.events' MIP-batch throttle
-- (MAIN 2672, 2947) re-arms `DoAfterSpecial(0.1, "guild.events.
-- process_mip_batches()", 12)` from inside a live event handler, and
-- autostepper.lua's watchdog (1533, re-armed from 1540) reschedules
-- itself every tick via `DoAfterSpecial(2, "autostepper_watchdog_tick()",
-- sendto.script)` -- neither is expressible if the call blocked. So in
-- LEGACY every `Send(dir)` already fires back-to-back, with no wait
-- between them at all; the `DoAfterSpecial(0.5, "", sendto.execute)`
-- calls (one per step except the last, `#path - 1` total) each just
-- queue an EMPTY command ("") to fire ~0.5s later -- a side effect, not a
-- pacing mechanism, and one this port does not reproduce: this loop
-- sends only the real direction strings, nothing else. This also matches
-- pathfinding.lua's own documented consumption contract (a plain
-- `for _, dir in ipairs(path) do send(dir) end` loop, no timer involved).
--
-- Title text ("Travel to...", the label of the PAGE_MENUS[7] item that
-- used to open this) is a small disclosed addition: LEGACY's own
-- viking_draw_poi_menu popup has no title bar at all (border + item rows
-- only); require("menu")'s box always has one.
--
-- Per-item colour is FORCED-dropped, not a choice: viking_draw_poi_menu
-- colours each row by POI type (`type_col`, MAIN 11960-11971, fallback
-- 0xFFFF99) via a raw WindowText colour argument, but require("menu")'s
-- item spec (scripts/default/menu.lua's normalize_items) carries only
-- label/value/search -- there is no per-item colour slot to plug a BGR
-- decode into. Every menu item therefore renders in the menu's own single
-- colour regardless of POI type.
--
-- draw_page7 also builds `vmap_poi_locations` (guild_viking.lua:12695-
-- 12728) with a comment claiming a "right-click lookup", but its only
-- would-be reader, `viking_resolve_poi_at` (guild_viking.lua:11770), is
-- never called anywhere in the file -- dead code, confirmed by grep -- so
-- the town list below gets no click handler either: there is nothing live
-- to port there regardless of branch.
--
-- Content decision worth disclosing: VMAP_SYM_COL's keys split cleanly into
-- TERRAIN glyphs (t/h/A/f/p/W/r/=/c/./+) and POI/player glyphs
-- (X/M/L/P/S/T/R/F/*/?) -- two disjoint sets. draw_page7 draws a single
-- glyph per cell straight from `state.vmap_rows`, which means the server's
-- feed already embeds POI/player letters into the row string at the right
-- position. This module instead treats `S.vmap_rows` as TERRAIN ONLY and
-- composites `S.vmap_pois` and the player position as two separate overlay
-- passes on top (player wins when both coincide) -- deliberately more
-- defensive than "trust the row string for everything," and an explicit
-- reading of the task brief's three separate bullets (grid / POI overlay /
-- player marker) rather than one combined glyph source.
--
-- Disposition of the plan's "pointer drag pans, wheel zooms where legacy
-- zoomed" (design doc, Stage 3): "pan" here is the popup wrapper's own
-- scroller (popups.lua's `wrap()`, wheel-driven, same as every other board
-- popup) -- there is no drag-to-pan gesture; Task 5's own click (see below)
-- is a plain down+up on one cell, not a drag. "Zoom" never applies:
-- LEGACY's zoom is pixel/icon-branch `cell_w` machinery (the graphical
-- Wang-tile rendering this task does not port, same ruling as every other
-- popup's show_*_icons disclosure) with no text-grid equivalent -- there
-- is nothing here for a zoom gesture to do.
-- Task 6 addendum: `M.poi_menu_items` and `M.travel_to` are exported below
-- (next to their local definitions) so pages/people.lua's errand "Run
-- There" button can reuse viking_show_poi_menu's item list/sort and
-- viking_poi_menu_travel's bfs+send dispatch verbatim -- see
-- viking_errand_return_and_submit (MAIN 12234-12331), which calls exactly
-- those two operations (12289 viking_show_poi_menu(), 12309
-- viking_poi_menu_pick -> viking_poi_menu_travel()) -- instead of
-- pages/people.lua re-deriving the sorted town list or re-running bfs
-- itself. No behavior here changed for THIS module's own on_pointer path;
-- the exports are additive.
local pagelib = require("pagelib")
local maplib = require("maplib")
local state = require("state")
local page_opts = require("page_opts")
local pathfinding = require("pathfinding")
local track = require("popups.pointer_track").tracker()

local S = state.S
local C = pagelib.C
local RESET = pagelib.RESET

-- ---------------------------------------------------------------------------
-- VMAP_SYM_COL (guild_viking.lua:10990-11015), ported verbatim as the
-- symbol -> hex comment pairs; decoded into pagelib.C below.
--
-- BGR decode workbook (byte order 0xBBGGRR: leftmost byte = Blue, middle =
-- Green, rightmost = Red -- same convention as pages/city.lua's,
-- pages/goods.lua's and pages/army.lua's workbooks; this table's own header
-- comment explicitly says "BGR color table"). pagelib.C has ten hues where
-- LEGACY's territory palette effectively uses more, so several literals
-- fold onto the nearest available entry -- the same "orange folds to red"
-- precedent earlier pages set.
--
--   X 0xFFFFFF -> R=FF,G=FF,B=FF  white                -> C.white
--   M 0x0000DD -> R=DD,G=00,B=00  strong red            -> C.bright_red
--   L 0x0055FF -> R=FF,G=55,B=00  red-leaning orange    -> C.red (folded)
--   P 0x00DDFF -> R=FF,G=DD,B=00  yellow-leaning amber  -> C.yellow
--   S 0xFF00FF -> R=FF,G=00,B=FF  magenta               -> C.magenta
--   T 0x00FF66 -> R=66,G=FF,B=00  bright green          -> C.bright_green
--   R 0x8888BB -> R=BB,G=88,B=88  muted slate           -> C.dim (folded)
--   F 0x33BB33 -> R=33,G=BB,B=33  green                 -> C.green
--   * 0x00EEFF -> R=FF,G=EE,B=00  yellow -- see KEEP AND DISCLOSE below
--   ? 0xDDDDFF -> R=FF,G=DD,B=DD  pale pink/lavender    -> C.white (folded)
--   W 0xAA3300 -> R=00,G=33,B=AA  dark blue             -> C.cyan (folded;
--       pagelib.C has no blue)
--   r 0xDDDD44 -> R=44,G=DD,B=DD  light cyan            -> C.bright_cyan
--   = 0x00CCCC -> R=CC,G=CC,B=00  yellow                -> C.yellow
--   t 0x555555 -> R=55,G=55,B=55  dark gray             -> C.dim
--   h 0x00CCCC -> R=CC,G=CC,B=00  yellow (same literal as bridge)
--   A 0x0000CC -> R=CC,G=00,B=00  red                   -> C.red
--   f 0x009900 -> R=00,G=99,B=00  medium green          -> C.green
--   p 0x00CC00 -> R=00,G=CC,B=00  bright green          -> C.bright_green
--   c 0x884400 -> R=00,G=44,B=88  dark blue (same fold as W)
--   . 0x222222 -> R=22,G=22,B=22  near-black            -> C.dim
--   + 0x222222 -> R=22,G=22,B=22  near-black (same literal as road/empty)
--
-- KEEP AND DISCLOSE: "*" (mentor)'s own LEGACY inline comment says "cyan",
-- but the table's own header explicitly declares 0xBBGGRR, and 0x00EEFF
-- decodes to R=FF,G=EE,B=00 -- squarely yellow, not cyan. Treated as an
-- author-comment slip against the table's own declared convention (same
-- class of finding as pages/city.lua's raid-lost-color note) and decoded
-- mechanically: C.yellow.
--
-- Fallback: LEGACY's own default for an unmapped char is `0xFF00FF` (line
-- 12552, `VMAP_SYM_COL[ch] or 0xFF00FF`), which decodes to magenta -- so the
-- fallback below is C.magenta, not an arbitrary choice.
local VMAP_COLOR = {
  X = C.white, M = C.bright_red, L = C.red, P = C.yellow, S = C.magenta,
  T = C.bright_green, R = C.dim, F = C.green, ["*"] = C.yellow, ["?"] = C.white,
  W = C.cyan, r = C.bright_cyan, ["="] = C.yellow, t = C.dim, h = C.yellow,
  A = C.red, f = C.green, p = C.bright_green, c = C.cyan, ["."] = C.dim,
  ["+"] = C.dim,
}
local VMAP_COLOR_FALLBACK = C.magenta

-- Type -> label (guild_viking.lua:11018-11029), ported verbatim.
local VMAP_TYPE_LABEL = {
  capital    = "Capital",
  lineage    = "Lineage",
  player     = "Settlement",
  seer       = "Seer",
  blot       = "Blot",
  ruins      = "Ruins",
  farm       = "Farm",
  mentor_ber = "Mentor",
  mentor_see = "Mentor",
  mentor_jarl= "Mentor",
}

-- Reverse (symbol-keyed) map for VMAP_TYPE_LABEL's types. LEGACY never
-- needed this table itself (draw_page7 reads the symbol straight off
-- state.vmap_rows -- see the module doc comment above); it is a derived
-- table this port needs because it overlays POIs by type onto a
-- terrain-only grid.
local POI_TYPE_SYM = {
  capital = "M", lineage = "L", player = "P", seer = "S", blot = "T",
  ruins = "R", farm = "F",
  mentor_ber = "*", mentor_see = "*", mentor_jarl = "*",
}

-- Legend entries (guild_viking.lua:12406-12413), ported verbatim (glyph +
-- label text unchanged; color resolved through VMAP_COLOR above instead of
-- the raw hex, same as the grid itself).
local LEGEND = {
  { sym = "t", lbl = "Tund" }, { sym = "h", lbl = "Hill" }, { sym = "A", lbl = "Mtn" },
  { sym = "f", lbl = "Frst" }, { sym = "p", lbl = "Plns" }, { sym = "W", lbl = "Watr" },
  { sym = "=", lbl = "Brg" },  { sym = "+", lbl = "Road" },
  { sym = "M", lbl = "Cap" },  { sym = "L", lbl = "Lin" },  { sym = "P", lbl = "Set" },
  { sym = "X", lbl = "You" },  { sym = "S", lbl = "Seer" }, { sym = "T", lbl = "Blot" },
  { sym = "R", lbl = "Ruin" }, { sym = "F", lbl = "Farm" }, { sym = "*", lbl = "Ment" },
}

-- Hover-tooltip vocabulary (guild_viking.lua:12500-12505), ported verbatim.
local VMAP_TIP_TERR = {
  t = "Tundra", h = "Hills", A = "Mountains", f = "Forest",
  p = "Plains", ["."] = "Plains", W = "Open water", r = "River", c = "Coast",
  ["="] = "Bridge", ["+"] = "Road",
}
local VMAP_TIP_SYM = {
  M = "Capital", L = "Lineage hall", P = "Settlement",
  S = "Seer hut", T = "Blot grove", R = "Ruins", F = "Farm", ["*"] = "Mentor",
  X = "You", ["?"] = "Unknown settlement",
}

-- vmap_display_name (guild_viking.lua:11031-11034), ported verbatim.
local function display_name(name)
  if not name or name == "" then return "" end
  return (name:gsub("^%l", string.upper))
end

-- Town-list POI types (guild_viking.lua:12670-12672), sort order
-- (12676-12684) and column abbreviation/color (12697-12706), ported
-- verbatim (all ten types happen to be exactly VMAP_TYPE_LABEL's keys).
local TOWN_SORT_ORDER = {
  capital = 1, seer = 2, blot = 2, ruins = 2, farm = 2,
  mentor_ber = 2, mentor_see = 2, mentor_jarl = 2,
  lineage = 3, player = 4,
}
local TOWN_SHORT = {
  capital = "Cap", lineage = "Lin", player = "Set",
  seer = "Seer", blot = "Blot", ruins = "Ruin",
  farm = "Farm", mentor_ber = "Mentor", mentor_see = "Mentor", mentor_jarl = "Mentor",
}

local M = {}
M.title = "Territory Map"

-- LEGACY's ColourNote("white", "", ...), in this plugin's own goldenrod
-- convention (the colour popups.lua and init.lua already use for every
-- "Viking: ..." line -- LEGACY's literal white is its note colour for
-- everything, not a choice about these messages).
--
-- The "[vmap] " prefix is part of each message rather than added here,
-- because LEGACY is not consistent about it: "Already at X" carries no
-- prefix while its three siblings do (11792, 11813, 12347, 12353, 12355,
-- 12357). Ported verbatim, quirk included -- see the call sites.
local function status(fmt, ...)
  buffer.color_print(nil, "DAA520",
    select("#", ...) > 0 and string.format(fmt, ...) or fmt)
end

-- What state the territory-map data is actually in. Two places explain
-- themselves from this -- the no-data pane in M.lines and the travel guards'
-- reason line below -- so the predicate lives here once. `vmap_seen` and
-- `vmap_w` mean subtly different things (a frame that ARRIVED saying the
-- grid is empty is not a frame that never came) and getting the two
-- explanations to disagree about that would be worse than giving neither.
local function map_data_state()
  if not S.vmap_seen then return "no_frame" end
  if (S.vmap_w or 0) == 0 then return "no_grid" end
  return "have_grid"
end

-- Why the player has no position on the map. LEGACY said only that travel
-- was unavailable, which is the least useful half: "you are not on the map"
-- reads as a statement about the player when two of its three causes are not
-- about them at all. Reported as a real question from live play -- the guard
-- had fired and there was no way to tell which cause it was.
--
-- Only ever consulted when vmap_px < 0. Stepping OFF the grid mid-session
-- does not land here: the server keeps sending the last known coordinates
-- with `active = 0`, so px stays >= 0 and the header line says "(last
-- known)" instead (see pre_grid_lines).
local function position_unknown_reason()
  local st = map_data_state()
  if st == "no_frame" then
    return "no Guild.Map frame received (check /vik source)"
  elseif st == "no_grid" then
    return "the guild has no biome grid"
  end
  return "the map has arrived, but with no position for you on it"
end

-- Module-local hover/info line (a lera addition, not a port of a live
-- LEGACY interaction -- see the module doc comment above). Declared here,
-- ahead of every function that reads or writes it, so it is a proper
-- upvalue rather than an accidental global.
local hover = ""

-- ---------------------------------------------------------------------------
-- Grid construction
-- ---------------------------------------------------------------------------

-- state.lua's vmap_rows is 1-INDEXED Lua storage for a 0-based wire row
-- (handlers/voyage.lua's vmr_row stores at [ridx + 1] for wire row ridx,
-- LEGACY 2571-2573, locked by guild_viking_voyage_test.lua:304-306) --
-- maplib's `r` here is the 0-based grid row, so the read is [r + 1].
local function terrain_glyph(r, c)
  local row = S.vmap_rows[r + 1] or ""
  local ch = row:sub(c + 1, c + 1)
  if ch == "" then ch = "." end
  return ch
end

-- { y*w+x -> poi } lookup (mirrors draw_page7's own `poi_at`,
-- guild_viking.lua:12506-12513).
local function poi_lookup()
  local at = {}
  local w = S.vmap_w or 0
  for _, poi in ipairs(S.vmap_pois or {}) do
    if poi.x ~= nil and poi.y ~= nil and poi.x >= 0 and poi.y >= 0 then
      at[poi.y * w + poi.x] = poi
    end
  end
  return at
end

local function is_player_cell(c, r)
  return (S.vmap_px or -1) >= 0 and S.vmap_px == c and S.vmap_py == r
end

local function make_grid(poi_at)
  local w, h = S.vmap_w or 0, S.vmap_h or 0
  return {
    w = w, h = h,
    cell = function(c, r)
      if is_player_cell(c, r) then
        return { glyph = "X", color = VMAP_COLOR.X }
      end
      local poi = poi_at[r * w + c]
      if poi then
        local sym = POI_TYPE_SYM[poi.type] or "?"
        return { glyph = sym, color = VMAP_COLOR[sym] or VMAP_COLOR_FALLBACK }
      end
      local ch = terrain_glyph(r, c)
      return { glyph = ch, color = VMAP_COLOR[ch] or VMAP_COLOR_FALLBACK }
    end,
  }
end

-- Compact rendering: one character per cell, no wall overlays.
--
-- This board used to render at maplib's wide 3-char pitch with the edge-wall
-- overlay on top: `S.vmap_east_edges`/`S.vmap_south_edges` (passability
-- strings, "0" = blocked) drove maplib's `east_edge`/`south_edge` hooks, so
-- a blocked east edge drew "|" in the pitch's third column and a blocked
-- south edge drew "__" on an interleaved row below every cell row. That
-- overlay was never part of the map LEGACY draws -- it was a lera addition,
-- the same category as the hover line (see the module doc comment above) --
-- and between the padding it needed and the blank edge row under every cell
-- row it cost the terrain grid roughly three times its width and twice its
-- height while the terrain itself is what the board is for. Both are gone:
-- the grid renders exactly `vmap_w` characters per row and `vmap_h` rows.
--
-- The edge data itself is untouched and still functionally live: handlers/
-- voyage.lua decodes and stores it, and pathfinding.lua's BFS reads both
-- planes, so this module's own POI travel menu still routes around walls.
-- They simply are not drawn any more -- nothing in this file reads them.
local GRID_OPTS = { compact = true }

-- ---------------------------------------------------------------------------
-- Pre-grid lines (header + position + legend) -- shared by lines(),
-- geometry() and grid_line_offset() so the three can never drift apart.
-- ---------------------------------------------------------------------------

local function legend_entries()
  local out = {}
  for _, e in ipairs(LEGEND) do
    out[#out + 1] = { glyph = e.sym, color = VMAP_COLOR[e.sym], label = e.lbl }
  end
  return out
end

local function pre_grid_lines(width)
  local out = { pagelib.header(width, "Territory Map") }
  if (S.vmap_px or -1) >= 0 then
    -- Guild.Map's `active` distinguishes "the player is standing here" from
    -- "this is where we last saw them" -- the server keeps sending the last
    -- known coordinates once they step off the biome grid, and without the
    -- distinction the marker claims a position they left some time ago.
    local pos = string.format("(%d, %d)", S.vmap_px, S.vmap_py)
    if S.vmap_active == 0 then pos = pos .. " (last known)" end
    out[#out + 1] = pagelib.kv(width, "Position:", pos)
  end
  for _, l in ipairs(maplib.legend(width, legend_entries())) do
    out[#out + 1] = l
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Town list (guild_viking.lua:12666-12750, gated show_map_towns). LEGACY
-- lays this out as a fixed-pixel 2-column scrolling area; ported here as a
-- 2-up text flow with the same sort order, abbreviation and per-type color.
-- ---------------------------------------------------------------------------

local function town_entry_text(poi)
  local prefix = (TOWN_SHORT[poi.type] or "?") .. " "
  local name = display_name(poi.name or "")
  if poi.owner and poi.owner ~= "" then
    name = name .. " (" .. display_name(poi.owner) .. ")"
  end
  local sym = POI_TYPE_SYM[poi.type]
  local color = (sym and VMAP_COLOR[sym]) or C.white
  return C.dim .. prefix .. RESET .. color .. name .. RESET
end

local function town_lines(width)
  local entries = {}
  for _, poi in ipairs(S.vmap_pois or {}) do
    if TOWN_SORT_ORDER[poi.type] then entries[#entries + 1] = poi end
  end
  if #entries == 0 then return {} end

  table.sort(entries, function(a, b)
    local oa = TOWN_SORT_ORDER[a.type] or 99
    local ob = TOWN_SORT_ORDER[b.type] or 99
    if oa ~= ob then return oa < ob end
    return display_name(a.name or ""):lower() < display_name(b.name or ""):lower()
  end)

  local out = { pagelib.header(width, "Map Locations") }
  local half = math.floor(width / 2)
  local col_w = { half, math.max(0, width - half - 1) }
  local i = 1
  while i <= #entries do
    local left = pagelib.trunc(town_entry_text(entries[i]), col_w[1])
    local right = ""
    if entries[i + 1] then
      right = pagelib.trunc(town_entry_text(entries[i + 1]), col_w[2])
    end
    out[#out + 1] = left .. " " .. right
    i = i + 2
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Public renderer contract (popups.lua)
-- ---------------------------------------------------------------------------

function M.lines(width)
  local out = pre_grid_lines(width)

  -- The old text here read "enable with: vtoggle mip_map". That advice is not
  -- merely stale but misleading: the territory map comes from Guild.Map, and
  -- the mudlib states outright that the panel is "NOT gated on any MIP
  -- vtoggle -- GMCP gating is subscription only", so the toggle it named
  -- cannot affect this pane at all.
  --
  -- The two ways this pane can be empty have different causes and only one of
  -- them is the client's, so they are reported separately.
  if (S.vmap_w or 0) == 0 then
    -- map_data_state() cannot answer "have_grid" here (this branch IS
    -- vmap_w == 0), so the two cases below are exhaustive.
    local msg
    if map_data_state() == "no_grid" then
      -- A frame arrived and said the grid is 0 wide. _v_map() returns its
      -- empty structure when the biome daemon is missing, the world is
      -- regenerating, the guild has no settlements yet, or the grid is
      -- unconfigured -- all world state, none of it fixable here.
      msg = "No territory map yet - the guild has no biome grid"
    else
      msg = "No data - no Guild.Map frame received (check /vik source)"
    end
    out[#out + 1] = pagelib.trunc(C.dim .. msg .. RESET, width)
    return out
  end

  local poi_at = poi_lookup()
  local grid = make_grid(poi_at)
  for _, l in ipairs(maplib.render(grid, GRID_OPTS)) do
    out[#out + 1] = l
  end

  out[#out + 1] = hover ~= "" and pagelib.trunc(hover, width) or ""

  if page_opts.get("show_map_towns") then
    for _, l in ipairs(town_lines(width)) do out[#out + 1] = l end
  end

  return out
end

-- geometry()/grid_line_offset(): the ctx.cell_from_xy contract popups.lua
-- documents. nil when there is no grid to hit-test (no-data fallback).
function M.geometry(width)
  if (S.vmap_w or 0) == 0 then return nil end
  local grid = make_grid(poi_lookup())
  return maplib.geometry(grid, GRID_OPTS)
end

function M.grid_line_offset(width)
  return #pre_grid_lines(width)
end

-- ---------------------------------------------------------------------------
-- Pointer: hover (unchanged) plus, as of Task 5, a genuinely live click --
-- see the module doc comment's "Task 5" section above for why this module
-- now needs its own down-target tracker (popups/pointer_track.lua), unlike
-- before. A LEFT down on a POI/town cell records the cell via the tracker
-- and consumes; the matching up, when its own cell still matches the
-- recorded one (fail-closed: no match, including no recorded down at all,
-- means no action), opens the travel menu. Every other down (non-POI cell,
-- or a non-left button) is unconsumed, exactly as before.
-- ---------------------------------------------------------------------------

local function cell_tip(poi_at, c, r)
  local tip
  if is_player_cell(c, r) then
    tip = VMAP_TIP_SYM.X
  else
    local poi = poi_at[r * (S.vmap_w or 0) + c]
    if poi then
      tip = (VMAP_TYPE_LABEL[poi.type] or "Location") .. ": " .. display_name(poi.name or "?")
      if poi.owner and poi.owner ~= "" then
        tip = tip .. "  Owner: " .. display_name(poi.owner)
      end
    else
      local ch = terrain_glyph(r, c)
      tip = VMAP_TIP_SYM[ch] or VMAP_TIP_TERR[ch] or "Terrain"
    end
  end
  return string.format("(%d,%d)  %s", c, r, tip)
end

local function poi_at_cell(poi_at, c, r)
  return poi_at[r * (S.vmap_w or 0) + c]
end

-- viking_show_poi_menu's item list (guild_viking.lua:11796-11803): every
-- POI with a valid position (x, y >= 0), sorted by TOWN_SORT_ORDER's
-- type/name order (guild_viking.lua:11804-11810, the SAME table
-- town_lines above uses for its own sort -- but note the FILTER here is
-- different: viking_show_poi_menu gates on coordinate validity only, not
-- on TOWN_SORT_ORDER membership, so an unlisted type still appears (sorted
-- last, `oa/ob or 99`) rather than being dropped the way town_lines drops
-- it).
local function poi_menu_items()
  local items = {}
  for _, poi in ipairs(S.vmap_pois or {}) do
    if poi.x and poi.y and poi.x >= 0 and poi.y >= 0 then
      items[#items + 1] = poi
    end
  end
  table.sort(items, function(a, b)
    local oa = TOWN_SORT_ORDER[a.type] or 99
    local ob = TOWN_SORT_ORDER[b.type] or 99
    if oa ~= ob then return oa < ob end
    return display_name(a.name or ""):lower() < display_name(b.name or ""):lower()
  end)
  return items
end

-- Exported (Task 6): pages/people.lua's errand-return button reuses this
-- EXACT item list/sort -- viking_errand_return_and_submit (MAIN 12289) calls
-- viking_show_poi_menu(), whose item-building/sort is this same function --
-- rather than re-deriving the town list and its TOWN_SORT_ORDER tie-break.
M.poi_menu_items = poi_menu_items

-- viking_draw_poi_menu's per-item label (guild_viking.lua:11970-11976:
-- `"%s  Travel to %s (%d,%d)"`), ported verbatim. Its own local
-- `type_short` table is identical to TOWN_SHORT above except for the
-- fallback ("POI" here vs TOWN_SHORT's "?" fallback used by
-- town_entry_text) -- both are LEGACY's own literal choices, kept as-is.
local function poi_menu_label(poi)
  local prefix = TOWN_SHORT[poi.type] or "POI"
  return string.format("%s  Travel to %s (%d,%d)", prefix, display_name(poi.name), poi.x, poi.y)
end

-- viking_poi_menu_pick + viking_poi_menu_travel (guild_viking.lua:
-- 12332-12369): resolves the path at PICK time (not at menu-open time, so
-- a player-position update that lands while the menu is open is honored),
-- then dispatches it. ColourNote status messages are dropped -- see the
-- module doc comment's disclosure above; every guard below still runs.
-- Disclosure: this is a pointer-driven send (a menu pick, not typed input),
-- and it can dispatch a whole PATH of commands, not just one. `deadmans`
-- resets its idle timer only from `on_input`, never from pointer input, so
-- a player who is past `deadmans`' block_time when they click a POI has
-- every command in the path silently swallowed by its on_send governance,
-- not just the first (see plugins/README.md's automation section).
local function travel_to(poi)
  -- viking_poi_menu_travel's four ColourNotes (12347-12357), verbatim. Two
  -- LEGACY quirks are reproduced rather than tidied: the name is the RAW
  -- wire name (`vmap_poi_selected.name`, so lowercase -- the display-cased
  -- form appears only in the menu LABEL, which goes through
  -- vmap_display_name), and "Already at" is the one line with no "[vmap] "
  -- prefix. Also verbatim: "(1 steps)" -- the count is interpolated with no
  -- plural handling.
  local name = poi.name
  if (S.vmap_px or -1) < 0 then
    status("[vmap] Player position unknown")
    status("[vmap]   %s", position_unknown_reason())
    return
  end
  local path = pathfinding.bfs(S.vmap_px, S.vmap_py, poi.x, poi.y)
  if not path then
    status("[vmap] No passable route to %s", name)
    return
  end
  if #path == 0 then
    status("Already at %s", name)
    return
  end
  status("[vmap] Traveling to %s (%d steps)", name, #path)
  for _, dir in ipairs(path) do
    require("util").send(dir, "vmap travel")
  end
end

-- Exported (Task 6): pages/people.lua's errand-return button reuses this
-- EXACT travel dispatch -- viking_errand_return_and_submit's simulated pick
-- (MAIN 12309, viking_poi_menu_pick(0, "poi_pick_" .. visible_index)) ends
-- up calling viking_poi_menu_travel() on the resolved POI, which is this
-- function -- rather than re-implementing the bfs+send-loop a second time.
M.travel_to = travel_to

-- viking_show_poi_menu (guild_viking.lua:11789-11814), retargeted onto
-- this port's own trigger -- see the module doc comment's "Retargeted
-- trigger" section above. The `state.vmap_px < 0` guard (11791-11794) and
-- the empty-list guard (11809-11812) are both ported, and BOTH are live.
-- (An earlier version of this note called the empty-list guard unreachable
-- because a POI cell had just been clicked. That is true of the POI-cell
-- click alone, but this function is exported -- page_menu.lua's "Travel
-- to..." row and pages/people.lua's errand button both call it with no
-- click behind them, so either guard can fire with nothing on screen to
-- explain it. Hence the messages.)
local function open_poi_menu()
  -- These two guards are the only way "Travel to..." can open nothing, so
  -- each says which one it was -- see the module doc comment's note on why
  -- this module reports its no-ops where its siblings stay quiet.
  if (S.vmap_px or -1) < 0 then
    status("[vmap] Travel unavailable: you are not on the map.")
    status("[vmap]   %s", position_unknown_reason())
    return
  end
  local pois = poi_menu_items()
  if #pois == 0 then
    status("[vmap] No locations available to travel to.")
    return
  end
  local items = {}
  for _, poi in ipairs(pois) do
    items[#items + 1] = { label = poi_menu_label(poi), value = poi }
  end
  require("menu").open({
    items = items,
    title = "Travel to...",
    on_select = function(value)
      if type(value) == "table" then travel_to(value) end
    end,
  })
end

-- Exported for page_menu.lua's "Travel to..." action row (LEGACY:11216-11221,
-- where the page menu's travel item called viking_show_poi_menu directly).
M.open_poi_menu = open_poi_menu

function M.on_pointer(ev, ctx)
  if not ctx.cell_from_xy then return nil end

  if ev.kind == "cancel" then
    track.clear()
    return nil
  end

  if ev.kind ~= "move" and ev.kind ~= "down" and ev.kind ~= "up" then return nil end

  local c, r = ctx.cell_from_xy(ev.x, ev.y)
  if not c then
    -- Fix round 2, Minor: clear a stale hover line on an off-grid MOVE
    -- only -- not "down", which stays a pure no-op (never touches hover),
    -- matching this module's own existing "out-of-grid click leaves the
    -- hover line unchanged" contract. An off-grid "up" has nothing to
    -- match against, so it just clears the tracker.
    if ev.kind == "move" and hover ~= "" then hover = ""; ui.dirty() end
    if ev.kind == "up" then track.clear() end
    return nil
  end

  local poi_at = poi_lookup()

  if ev.kind == "move" then
    hover = cell_tip(poi_at, c, r)
    ui.dirty()
    return nil
  end

  -- RIGHT-click anywhere on the grid: this page's context menu (page_menu.lua
  -- -- LEGACY's PAGE_MENUS[7], whose right-click hotspot covered the whole
  -- page body). Same record-on-down / match-on-up discipline as the POI path
  -- below, and deliberately NOT gated on landing on a POI: LEGACY's page-body
  -- hotspot did not care what was under the cursor.
  if ev.button == "right" then
    if ev.kind == "down" then
      track.record({ kind = "pagemenu" })
      return true
    end
    if ev.kind == "up" then
      local ok = track.matches({ kind = "pagemenu" })
      track.clear()
      if ok then
        require("page_menu").open("map")
        return true
      end
      return nil
    end
    return nil
  end

  if ev.kind == "down" then
    hover = cell_tip(poi_at, c, r)
    ui.dirty()
    if ev.button ~= "left" then return nil end
    if not poi_at_cell(poi_at, c, r) then return nil end
    track.record({ kind = "cell", c = c, r = r })
    return true
  end

  -- ev.kind == "up"
  local matched = poi_at_cell(poi_at, c, r) ~= nil and track.matches({ kind = "cell", c = c, r = r })
  track.clear()
  if matched then
    open_poi_menu()
    return true
  end
  return nil
end

-- Called by popups.lua's registry when this popup closes (fix round 2,
-- Minor: "clear hover on close"). The down-target tracker needs no
-- separate clearing here: popup.lua synthesizes a "cancel" to any
-- module holding a live capture before this runs (scripts/default/
-- popup.lua's finish()), and on_pointer's "cancel" branch above already
-- clears it.
function M.reset()
  hover = ""
end

return M
