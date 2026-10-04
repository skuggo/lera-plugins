-- Sea Chart popup (/vik sea): the FULL LEGACY sub-view -- LEGACY
-- guild_viking.lua's draw_page11 (14674-15297) in its entirety, TEXT-VIEW
-- branch only (LEGACY's own `show_sea_chart_icons=false` default -- the
-- Wang-tile chart-icon branch is a graphical rendering of the exact same
-- cells and is NOT ported, same ruling as popups/map.lua's
-- show_map_icons). draw_page10 (13213-13228) contributes only the
-- mip_voyage_seen no-data gate (ported into popups/sea_common.lua and used
-- by both this module and popups/voyage.lua).
--
-- Split ruling (plan, binding): /vik sea is the FULL sub-view (chart +
-- every section); /vik voyage (popups/voyage.lua) renders only the
-- voyage-status subset (status/queue/saga/memory, no chart) for a compact
-- live view. sea_common.lua holds the section builders both modules share
-- (no-data gate, no-voyage/reroll fallback, Voyage Status fields +
-- Awaiting Resolution + Identity/Traits/Crew, Queue, Saga, Crew Memory);
-- this module adds the chart + its legend (show_sea_chart /
-- show_sea_chart_legend) and every "Secured *" loot section, none of which
-- voyage.lua includes.
--
-- Section classification (source order, guild_viking.lua line anchors):
--   mip_voyage_seen gate           13213-13220 (draw_page10; ported into
--                                   sea_common.mip_gate_lines)
--   show_sea_voyage (whole-page)   13222-13224 (draw_page10 delegates to
--                                   draw_page11 ONLY when this is true --
--                                   the single gate for everything below)
--   no-voyage + reroll fallback    14962-14995 (sea_common.no_voyage_lines)
--   Voyage Status fields           14996-15015 (sea_common.status_lines)
--   Awaiting Resolution            15034-15095 (sea_common.status_lines)
--   Identity/Traits/Crew           15113-15121 (sea_common.status_lines)
--   Chart (show_sea_chart)         14762-14961 (this module: draw_chart)
--     Legend (show_sea_chart_legend) 14934-14961
--   Queue (show_sea_queue)         15207-15229 (sea_common.queue_lines)
--   Saga (show_sea_saga)           15231-15242 (sea_common.saga_lines)
--   Crew Memory (show_sea_memory)  15244-15254 (sea_common.memory_lines)
--   Active Boons (show_sea_boons)  15256-15260 (this module: boons_lines)
--   Secured Spoils (show_sea_spoils) 15262-15267 (this module: spoils_lines)
--   Secured Reagents (unconditional  15269-15272 (this module:
--     once voyage_reagents > 0)        reagents_lines -- no page_opts gate
--                                       in LEGACY, ported the same way)
--   Secured Goods (show_sea_goods) 15274-15290 (this module: goods_lines)
--   Secured Aids (show_sea_aids)   15292-15308 (this module: aids_lines)
--   Secured Runes (show_sea_runes) 15310-15318 (this module: runes_lines)
--   Secured Relics (show_sea_relics) 15320-15326 (this module: relics_lines)
--   Secured Curios (show_sea_curios) 15328-15332 (this module: curios_lines)
--
-- Interaction fidelity -- every WindowAddHotspot in 14674-15297:
--   ch_<coord> (chart cell, ~14939-14947): the ONLY grid-shaped hotspot on
--     this page, and the only one that fires in the text-view branch
--     regardless of show_sea_chart_icons (its registration is NOT nested
--     inside that toggle, unlike the icon/DrawImageClip rendering choice
--     right above it) -- ported live below: mouse-down consumes (matches
--     viking_voyage_chart_down returning true with no action, LEGACY
--     13068-13070) and updates the hover line; mouse-up sends
--     "vvoyage queue <coord>" (matches viking_voyage_chart_click's Send,
--     LEGACY 13074-13100) via ctx.cell_from_xy, same pattern as
--     popups/map.lua's hover line. The confirm-before-send modal
--     (page_opts.confirm_chart_click, default TRUE -> utils.msgbox, LEGACY
--     13082-13094) IS ported: since lera has no native modal, mouse-up opens
--     a 2-item require("menu") ("Queue course to <coord> (<node>)" / "Cancel")
--     when the opt is on, and sends immediately (as before this fix round)
--     only when the opt is off -- see M.on_pointer below. One disclosed lera
--     liberty: the hover line ALSO updates on mouse-down here, not just
--     move. LEGACY's hover is the OS-native hotspot tooltip (the `Tooltip`
--     argument to WindowAddHotspot), which needs no help from a click to
--     already be showing; this port's hover is a rendered text line with no
--     such native assist, so refreshing it on down as well as move keeps a
--     touch/click-only interaction (no preceding hover move event) from
--     landing on stale hover text.
--   btn_reroll_<ship_id> (14989-14994), btn_resolve_<i> (15060-15069),
--   btn_voyage_end (15079-15090), btn_clr_queue (15214-15220): pixel
--     rectangle buttons, none shaped like a grid cell -- popups.lua's
--     ctx.cell_from_xy (backed by maplib.geometry) cannot hit-test them.
--     LIVE via a different mechanism: sea_common.lua's M.actions() ports
--     each button's own visibility condition and command verbatim; both
--     this module and popups/voyage.lua render one "[Actions]" summary line
--     in the voyage-status section and hit-test THAT single line with the
--     new ctx.line_from_y (popups.lua), opening require("menu") with
--     whichever of the four commands currently apply. Each command's exact
--     text is ALSO rendered as plain text at its point of origin (the
--     no-voyage reroll hint, the Awaiting Resolution options, the harbor
--     hint) so it stays legible without opening the menu.
local pagelib = require("pagelib")
local maplib = require("maplib")
local details = require("popups.hover_details")
local state = require("state")
local page_opts = require("page_opts")
local common = require("popups.sea_common")
local cc = require("pages.city_common")
local track = require("popups.pointer_track").tracker()

local S = state.S
local C = pagelib.C
local RESET = pagelib.RESET

local M = {}
-- Preserve the chart's native two-row character aspect for PNG cells. The
-- popup remains scrollable when the surrounding Sea sections do not fit.
M.image_limit = 1
M.title = "Sea Chart"

-- Module-local hover/info line for the chart, same pattern as
-- popups/map.lua's `hover` upvalue.
local hover = ""

-- ---------------------------------------------------------------------------
-- Chart colors (chart_cols, guild_viking.lua:14691-14713) -- BGR decode
-- workbook (0xBBGGRR: leftmost=Blue, middle=Green, rightmost=Red), folded
-- onto pagelib.C's ten hues per the same "no blue -> cyan" / nearest-hue
-- convention popups/map.lua's own workbook sets. Fallback for an unmapped
-- sym (LEGACY: `chart_cols[sym] or 0xEEEEEE`) is white.
--
--   # 0x555555 -> R=55,G=55,B=55 gray            -> C.dim
--   O 0xFF8844 -> R=44,G=88,B=FF blue            -> C.cyan (folded)
--   ~ 0xFF8844 -> same literal as O               -> C.cyan
--   I 0x55AA55 -> R=55,G=AA,B=55 green           -> C.green
--   ? 0xCCCC00 -> R=00,G=CC,B=CC cyan            -> C.cyan
--   H 0x55CCFF -> R=FF,G=CC,B=55 gold/orange     -> C.yellow
--   W 0x6666CC -> R=CC,G=66,B=66 muted red       -> C.red
--   T 0x4444FF -> R=FF,G=44,B=44 red             -> C.bright_red
--   F 0xEEEEEE -> near-white                     -> C.white
--   X 0xCC33CC -> R=CC,G=33,B=CC magenta         -> C.magenta
--   M 0xCCCCCC -> light gray                      -> C.white
--   B 0x3333CC -> R=CC,G=33,B=33 red             -> C.red
--   = 0xCCCC00 -> same literal as ?                -> C.cyan
--   D 0x444444 -> R=44,G=44,B=44 dark gray       -> C.dim
--   S 0xEEEEEE -> same literal as F                -> C.white
--   + 0x33CC33 -> R=33,G=CC,B=33 green           -> C.green
--   > 0xCC33CC -> same literal as X                -> C.magenta
--   * 0xFFFFFF -> white                            -> C.white
--   Y 0xFFFF00 -> R=00,G=FF,B=FF bright cyan     -> C.bright_cyan
--   V 0x2222AA -> R=AA,G=22,B=22 dark red        -> C.red
--   C 0xEEEEFF -> R=FF,G=EE,B=EE pale/near-white -> C.white
--   A 0xFF66CC -> R=CC,G=66,B=FF magenta/purple  -> C.magenta
-- Sailed-tile override (LEGACY 14899, applied to every sym except "S"):
-- 0xFF00FF -> exact magenta -> C.magenta.
-- ---------------------------------------------------------------------------
local CHART_COLOR = {
  ["#"] = C.dim, O = C.cyan, ["~"] = C.cyan, I = C.green, ["?"] = C.cyan,
  H = C.yellow, W = C.red, T = C.bright_red, F = C.white, X = C.magenta,
  M = C.white, B = C.red, ["="] = C.cyan, D = C.dim, S = C.white,
  ["+"] = C.green, [">"] = C.magenta, ["*"] = C.white, Y = C.bright_cyan,
  V = C.red, C = C.white, A = C.magenta,
}
local CHART_COLOR_FALLBACK = C.white
local SAILED_COLOR = C.magenta

-- chart_display_symbol (guild_viking.lua:14717-14721), ported verbatim:
-- open-sea/mist/stormbelt/deadwater all display as a plain "~" (their
-- distinct colors above still differ).
local function chart_display_symbol(sym)
  if sym == "O" or sym == "M" or sym == "B" or sym == "D" then return "~" end
  return sym
end

-- VIKING_CHART_NODES (guild_viking.lua:13023-13043) + viking_chart_node_name
-- (13045-13048)/viking_chart_tooltip (13051-13061), ported verbatim as the
-- hover-tip vocabulary. LEGACY's tooltip is multi-line ("\r\n"-joined); this
-- module flattens it to one line (same "hover info line" convention
-- popups/map.lua's module doc discloses) joined with two spaces.
local CHART_NODES = {
  S = { name = "Your ship" },
  ["+"] = { name = "Queued path" },
  [">"] = { name = "Queued destination" },
  ["#"] = { name = "Unrevealed", hint = "Sail closer or use a chart fragment" },
  O = { name = "Open sea" },
  I = { name = "Island" },
  ["?"] = { name = "Unknown waters" },
  H = { name = "Harbor", hint = "Safe cove - restock supplies" },
  W = { name = "Wreck", hint = "Salvage - better rune & relic chance" },
  T = { name = "Storm", hint = "Hazard - may damage the hull" },
  F = { name = "Fog", hint = "Obscured waters" },
  X = { name = "Objective", hint = "The voyage goal" },
  ["*"] = { name = "Resolved node" },
  Y = { name = "Resolved harbor" },
  M = { name = "Mist", hint = "Reduced visibility" },
  B = { name = "Stormbelt", hint = "Rough seas" },
  ["="] = { name = "Crosscurrent", hint = "Drift hazard" },
  D = { name = "Deadwater", hint = "Becalmed - slow going" },
}

-- Legend entries (guild_viking.lua:14934-14960's five draw_legend_parts
-- calls), flattened into one list for maplib.legend to flow -- same
-- simplification popups/map.lua's LEGEND table already applies (maplib
-- flows/wraps its own way rather than preserving LEGACY's fixed row
-- groups). "~" repeats with different colors/labels (sea/mist/stormbelt/
-- deadwater) -- ported as four separate entries, exactly like LEGACY draws
-- them.
local LEGEND = {
  { sym = "S", lbl = "ship" }, { sym = "+", lbl = "queued path" },
  { sym = ">", lbl = "queued destination" }, { sym = "#", lbl = "unrevealed" },
  { sym = "~", lbl = "sea", color = CHART_COLOR.O },
  { sym = "I", lbl = "island" }, { sym = "?", lbl = "unknown" },
  { sym = "H", lbl = "harbor" }, { sym = "W", lbl = "wreck" },
  { sym = "T", lbl = "storm" }, { sym = "F", lbl = "fog" },
  { sym = "X", lbl = "objective" }, { sym = "*", lbl = "resolved node" },
  { sym = "Y", lbl = "resolved harbor" },
  { sym = "~", lbl = "mist", color = CHART_COLOR.M },
  { sym = "~", lbl = "stormbelt", color = CHART_COLOR.B },
  { sym = "=", lbl = "crosscurrent" },
  { sym = "~", lbl = "deadwater", color = CHART_COLOR.D },
  { sym = "V", lbl = "maelstrom" }, { sym = "C", lbl = "ice floes" },
  { sym = "A", lbl = "aurora calm" },
}

local function legend_entries()
  local out = {}
  for _, e in ipairs(LEGEND) do
    out[#out + 1] = { glyph = e.sym, color = e.color or CHART_COLOR[e.sym], label = e.lbl }
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Chart grid construction. voyage_chart_rows is 1-INDEXED Lua storage for a
-- 0-based wire row (handlers/voyage.lua's vcr_row stores at [ridx + 1] for
-- wire row ridx, LEGACY 1322-1325) -- maplib's `r` here is the 0-based grid
-- row, so the read is [r + 1], same convention as popups/map.lua's
-- terrain_glyph. voyage_sailed is keyed [y + 1][x + 1] for 0-based wire
-- (x, y) (handlers/voyage.lua's VSAILED, LEGACY 1397+), which is exactly
-- [r + 1][c + 1] here too.
-- ---------------------------------------------------------------------------
local function chart_row(r)
  return S.voyage_chart_rows[r + 1] or ""
end

local function chart_sym(c, r)
  return chart_row(r):sub(c + 1, c + 1)
end

local function is_sailed(c, r)
  local row = S.voyage_sailed and S.voyage_sailed[r + 1]
  return row ~= nil and row[c + 1] == true
end

local function chart_available()
  return (S.voyage_chart_width or 0) > 0 and (S.voyage_chart_height or 0) > 0
    and #(S.voyage_chart_rows or {}) > 0
end

local function make_chart_grid()
  local w, h = S.voyage_chart_width or 0, S.voyage_chart_height or 0
  local tiles = require("tiles")
  local tile, base = tiles.enabled("sea")
    and tiles.board("sea", S.voyage_chart_rows, w, h)
  return {
    w = w, h = h,
    under = base,
    image = tile and function(c, r)
      return tile(c, r), chart_sym(c, r) ~= "S" and is_sailed(c, r)
    end,
    cell = function(c, r)
      local sym = chart_sym(c, r)
      if sym == "" then return nil end
      local color = CHART_COLOR[sym] or CHART_COLOR_FALLBACK
      if sym ~= "S" and is_sailed(c, r) then color = SAILED_COLOR end
      return { glyph = chart_display_symbol(sym), color = color }
    end,
  }
end

-- A01..P16 nautical labels (guild_viking.lua:13151-13157's precomputed
-- _chart_coords, reproduced as maplib row/col label functions rather than a
-- precomputed table -- both o(1) per cell, and maplib.geometry/render need
-- functions, not a table, at this hook). Row letters: string.char(65 + r)
-- (A for r=0). Column numbers: 1-based 2-digit ("01"..).
local function chart_row_label(r) return string.char(65 + r) end
local function chart_col_label(c) return string.format("%02d", c + 1) end
local function chart_coord(c, r) return chart_row_label(r) .. chart_col_label(c) end

local function chart_grid_opts()
  return { col_headers = true, row_headers = true,
           col_label = chart_col_label, row_label = chart_row_label,
           -- The voyage chart is only 16 columns wide. Keep its PNG cells
           -- large enough to match the readable in-game text chart even
           -- when the page height permits only one image row per cell.
           image_cols = 2, image_min_cols = 2, image_max_cols = 2 }
end

-- viking_chart_tooltip (guild_viking.lua:13051-13061), ported verbatim as
-- content, flattened to one line (see CHART_NODES's comment above).
local function chart_hover_text(c, r)
  local sym = chart_sym(c, r)
  local node = CHART_NODES[sym]
  local parts = { chart_coord(c, r) .. "  " .. ((node and node.name) or "Uncharted") }
  if node and node.hint then parts[#parts + 1] = node.hint end
  if is_sailed(c, r) then parts[#parts + 1] = "Sailed" end
  local status = (sym == "#") and "Unrevealed" or "Revealed"
  local danger = (S.voyage_status and S.voyage_status.danger) or 0
  if danger > 0 then
    parts[#parts + 1] = "Danger " .. danger .. "  -  " .. status
  else
    parts[#parts + 1] = status
  end
  return table.concat(parts, "  ")
end

-- Chart section (guild_viking.lua:14762-14961): header, grid-or-"no active
-- chart", hover line, legend (gated show_sea_chart_legend).
local function chart_lines(width)
  local out = { pagelib.header(width, "Chart") }
  if not chart_available() then
    out[#out + 1] = pagelib.trunc(C.dim .. "No active chart" .. RESET, width)
    return out
  end
  for _, l in ipairs(maplib.render(make_chart_grid(), chart_grid_opts(), width)) do
    out[#out + 1] = l
  end
  details.append_grid(out, hover, width, S.voyage_chart_width or 0, S.voyage_chart_height or 0,
    chart_hover_text)
  if page_opts.get("show_sea_chart_legend") then
    for _, l in ipairs(maplib.legend(width, legend_entries())) do out[#out + 1] = l end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Secured-* loot sections (guild_viking.lua:15256-15332). None of these are
-- part of the /vik voyage subset per the plan's binding split ruling.
-- ---------------------------------------------------------------------------

-- Active Boons (15256-15260, gated show_sea_boons). 0xAAAAAA -> C.dim.
local function boons_lines(width)
  if not S.voyage_boons or S.voyage_boons == "" then return {} end
  return {
    pagelib.header(width, "Active Boons"),
    pagelib.trunc(C.dim .. S.voyage_boons .. RESET, width),
  }
end

-- Secured Spoils (15262-15267, gated show_sea_spoils, only when > 0).
-- 0x00CCCC -> R=CC,G=CC,B=00 -> C.yellow.
local function spoils_lines(width)
  if (S.voyage_spoils_daler or 0) <= 0 then return {} end
  return {
    pagelib.header(width, "Secured Spoils"),
    pagelib.kv(width, "Daler:", pagelib.fmt_num(S.voyage_spoils_daler), C.yellow),
  }
end

-- Secured Reagents (15269-15272; NO page_opts gate in LEGACY -- unconditional
-- once voyage_reagents > 0, ported the same way). 0xFF55FF -> exact magenta.
local function reagents_lines(width)
  if (S.voyage_reagents or 0) <= 0 then return {} end
  return {
    pagelib.header(width, "Secured Reagents"),
    pagelib.kv(width, "Nikr's Bile:", "x" .. tostring(S.voyage_reagents), C.magenta),
  }
end

-- Secured Goods (15274-15290, gated show_sea_goods). Reuses
-- pages/city_common's good_label/good_color -- GOOD_COLORS/good_label are
-- ONE shared LEGACY table across city and voyage goods (guild_viking.lua:
-- 7477-7523), not two separate tables, so this is the same port, not a
-- coincidental match.
local function goods_lines(width)
  local goods = S.voyage_goods or {}
  if #goods == 0 then return {} end
  local parts = {}
  for i, item in ipairs(goods) do
    local text = cc.good_color(item.name) .. cc.good_label(item.name) .. RESET
      .. " x" .. tostring(item.count)
    if i < #goods then text = text .. "," end
    parts[#parts + 1] = text
  end
  return { pagelib.header(width, "Secured Goods"), pagelib.trunc(table.concat(parts, " "), width) }
end

-- AID_TIERS / format_aid_name (guild_viking.lua:7523-7538), ported verbatim
-- -- voyage-aid rarity is not shared with any city table (unlike goods).
local AID_TIERS = {
  storm_charm = "super rare", safe_cove_rumor = "ultra rare",
  deepwater_rigging_note = "ultra rare", chart_fragment = "rare",
  favorable_current_note = "rare", deepwater_rigging = "rare",
  whale_oil_lamp = "rare", seal_pelt_blanket = "common", salted_herring = "common",
}
local function format_aid_name(raw)
  if not raw or #raw == 0 then return "Unknown Aid" end
  return (raw:gsub("_", " "):gsub("%S+", function(w)
    return w:sub(1, 1):upper() .. w:sub(2):lower()
  end))
end
-- AID_TIER_COLORS (guild_viking.lua:15250-15255) -- BGR decode matches the
-- table's own inline comments exactly (no author-comment slip here, unlike
-- popups/map.lua's "*" finding): super rare 0x00CCCC -> yellow (comment
-- says "gold/yellow", matches); ultra rare 0xFF55FF -> magenta (matches);
-- rare 0xCCCC00 -> cyan (matches); common 0xAAAAAA -> gray -> C.dim.
local AID_TIER_COLORS = {
  ["super rare"] = C.yellow, ["ultra rare"] = C.magenta, rare = C.cyan, common = C.dim,
}

-- Secured Aids (15292-15308, gated show_sea_aids).
local function aids_lines(width)
  local aids = S.voyage_aids or {}
  if #aids == 0 then return {} end
  local out = { pagelib.header(width, "Secured Aids") }
  for _, item in ipairs(aids) do
    local tier = AID_TIERS[item.name] or "rare"
    local text = format_aid_name(item.name) .. " [" .. tier .. "] x" .. tostring(item.count)
    out[#out + 1] = pagelib.trunc((AID_TIER_COLORS[tier] or C.dim) .. text .. RESET, width)
  end
  return out
end

-- Secured Runes (15310-15318, gated show_sea_runes). 0x66CCFF ->
-- R=FF,G=CC,B=66 -- gold/orange -> C.yellow.
local function runes_lines(width)
  local runes = S.voyage_runes or {}
  if #runes == 0 then return {} end
  local parts = {}
  for _, item in ipairs(runes) do
    parts[#parts + 1] = item.name .. " x" .. tostring(item.count)
  end
  return {
    pagelib.header(width, "Secured Runes"),
    pagelib.trunc(C.yellow .. table.concat(parts, ", ") .. RESET, width),
  }
end

-- Secured Relics (15320-15326, gated show_sea_relics). 0xCCAAFF ->
-- R=FF,G=AA,B=CC pink/magenta -> C.magenta.
local function relics_lines(width)
  local relics = S.voyage_relics or {}
  if #relics == 0 then return {} end
  local out = { pagelib.header(width, "Secured Relics") }
  for _, line in ipairs(relics) do
    out[#out + 1] = pagelib.trunc(C.magenta .. "- " .. RESET .. C.magenta .. tostring(line) .. RESET, width)
  end
  return out
end

-- Secured Curios (15328-15332, gated show_sea_curios). 0xFFAA66 ->
-- R=66,G=AA,B=FF blue -> C.cyan (folded).
local function curios_lines(width)
  local curios = S.voyage_curios or {}
  if #curios == 0 then return {} end
  return {
    pagelib.header(width, "Secured Curios"),
    pagelib.trunc(C.cyan .. table.concat(curios, ", ") .. RESET, width),
  }
end

-- ---------------------------------------------------------------------------
-- Assembly. pre_chart_lines is shared by lines()/grid_line_offset() (and
-- geometry(), transitively via the same three-gate re-check) so they can
-- never drift -- same discipline popups/map.lua's pre_grid_lines follows.
--
-- Second return value: the 1-based index of the "[Actions]" line within the
-- returned array, or nil when M.actions() has nothing to offer right now
-- (see sea_common.lua). M.actions_line_index(width) below is the same
-- "pure function of width" shape M.grid_line_offset uses, kept in lockstep
-- with `out` by construction (both come out of this one function) so the
-- rendered line and the hit-test index can never drift apart -- exactly the
-- discipline the ctx.cell_from_xy contract already requires of
-- geometry()/grid_line_offset().
-- ---------------------------------------------------------------------------
local function pre_chart_lines(width)
  local out = { pagelib.header(width, "Sea Chart") }
  if not S.mip_voyage_seen then
    for _, l in ipairs(common.mip_gate_lines(width)) do out[#out + 1] = l end
    return out, nil
  end
  if not page_opts.get("show_sea_voyage") then return out, nil end
  if not S.voyage_status then
    for _, l in ipairs(common.no_voyage_lines(width)) do out[#out + 1] = l end
  else
    for _, l in ipairs(common.status_lines(width)) do out[#out + 1] = l end
  end

  local actions_idx = nil
  local action_lines = common.actions_line(width)
  if #action_lines > 0 then
    for _, l in ipairs(action_lines) do out[#out + 1] = l end
    actions_idx = #out
  end
  return out, actions_idx
end

-- True once pre_chart_lines has reached the "voyage is active" branch --
-- the only state in which the chart/queue/saga/memory/loot sections apply.
local function voyage_active()
  return S.mip_voyage_seen and page_opts.get("show_sea_voyage") and S.voyage_status ~= nil
end

function M.lines(width)
  local out = pre_chart_lines(width)
  if not voyage_active() then return out end

  if page_opts.get("show_sea_chart") then
    for _, l in ipairs(chart_lines(width)) do out[#out + 1] = l end
  end
  if page_opts.get("show_sea_queue") then
    for _, l in ipairs(common.queue_lines(width)) do out[#out + 1] = l end
  end
  if page_opts.get("show_sea_saga") then
    for _, l in ipairs(common.saga_lines(width)) do out[#out + 1] = l end
  end
  if page_opts.get("show_sea_memory") then
    for _, l in ipairs(common.memory_lines(width)) do out[#out + 1] = l end
  end
  if page_opts.get("show_sea_boons") then
    for _, l in ipairs(boons_lines(width)) do out[#out + 1] = l end
  end
  if page_opts.get("show_sea_spoils") then
    for _, l in ipairs(spoils_lines(width)) do out[#out + 1] = l end
  end
  for _, l in ipairs(reagents_lines(width)) do out[#out + 1] = l end
  if page_opts.get("show_sea_goods") then
    for _, l in ipairs(goods_lines(width)) do out[#out + 1] = l end
  end
  if page_opts.get("show_sea_aids") then
    for _, l in ipairs(aids_lines(width)) do out[#out + 1] = l end
  end
  if page_opts.get("show_sea_runes") then
    for _, l in ipairs(runes_lines(width)) do out[#out + 1] = l end
  end
  if page_opts.get("show_sea_relics") then
    for _, l in ipairs(relics_lines(width)) do out[#out + 1] = l end
  end
  if page_opts.get("show_sea_curios") then
    for _, l in ipairs(curios_lines(width)) do out[#out + 1] = l end
  end
  return out
end

-- chart_lines() always emits exactly one section-header line ("Chart",
-- pagelib.header) before delegating to maplib.render -- see chart_lines()
-- above -- so whenever the chart is actually the thing on screen, the true
-- offset is pre_chart_lines' own count PLUS that one line, not just
-- pre_chart_lines' count by itself.
function M.grid_line_offset(width)
  local n = #pre_chart_lines(width)
  if voyage_active() and page_opts.get("show_sea_chart") then
    n = n + 1
  end
  return n
end

-- geometry()/grid_line_offset(): the ctx.cell_from_xy contract popups.lua
-- documents. nil whenever the chart isn't the thing actually on screen --
-- gate off, no voyage, or no chart data yet.
function M.geometry(width)
  if not voyage_active() or not page_opts.get("show_sea_chart") or not chart_available() then
    return nil
  end
  return maplib.geometry(make_chart_grid(), chart_grid_opts(), width)
end

-- Absolute 1-based line index of the "[Actions]" line (pre_chart_lines'
-- second return value), or nil when there's nothing to act on right now.
-- Unlike grid_line_offset, nothing this module renders BEFORE the actions
-- line ever reflows by width in this design (pagelib.trunc/kv/pair_line
-- always emit exactly one output line regardless of width; only the
-- LEGEND, which sits AFTER the actions line, ever wraps) -- so the index
-- returned here IS genuinely width-invariant in practice (confirmed on
-- review during fix round 2, alongside popups/war_battle.lua's own actions
-- line, which is NOT -- see that module's actions_line_index comment for
-- the contrasting case and the exact indices that differ there). Verified
-- by this module's test asserting the same index at two very different
-- widths. on_pointer below still threads the pointer event's own
-- `ev.width` through for defense in depth / uniformity with the other
-- action-line modules rather than relying on this invariance holding
-- forever; ACTIONS_PROBE_WIDTH remains the fallback for a caller with no
-- width to hand.
local ACTIONS_PROBE_WIDTH = 76
function M.actions_line_index(width)
  local _, idx = pre_chart_lines(width or ACTIONS_PROBE_WIDTH)
  return idx
end

-- Pointer: the "[Actions]" line (reroll/resolve/end/clear, see
-- sea_common.lua) is checked first via ctx.line_from_y, since it sits
-- above the chart and a click there has nothing to do with the grid. The
-- chart itself mirrors LEGACY's two-phase ch_<coord> hotspot (mouse-down
-- consumes with no action, matching viking_voyage_chart_down; mouse-up
-- sends the queue command -- behind a confirm menu when
-- page_opts.confirm_chart_click is on, matching viking_voyage_chart_click's
-- utils.msgbox guard -- LEGACY 13074-13100) plus a hover-line update on
-- move (and on down -- see this module's header comment for why), same
-- convention as popups/map.lua's on_pointer.
-- Down-target recording (fix round 2, Important #1, via
-- popups/pointer_track.lua): a down on the [Actions] line records
-- { kind = "actions" }; a down on a chart cell records { kind = "cell",
-- c=, r= }. "up" only queues a course when its own cell matches the
-- recorded target -- a down on [Actions] followed by a drag that releases
-- over the chart must not ALSO queue a course for whatever cell the
-- release landed on.
function M.on_pointer(ev, ctx)
  if ev.kind == "cancel" then
    track.clear()
    return nil
  end

  -- RIGHT-click anywhere in this popup: the page context menu (page_menu.lua
  -- -- LEGACY's PAGE_MENUS[10], whose right-click hotspot covered the whole
  -- page body). Checked BEFORE the [Actions] line below, so right-click means
  -- the same thing everywhere in the popup rather than depending on which row
  -- it landed on. Note this narrows the [Actions] line, which until now fired
  -- on a down of ANY button (it never checked `ev.button`): it is left-click
  -- (and middle) from here on. Deliberate -- LEGACY reserved right-click for
  -- this menu on every page.
  if ev.button == "right" then
    if ev.kind == "down" then
      track.record({ kind = "pagemenu" })
      return true
    end
    if ev.kind == "up" then
      local ok = track.matches({ kind = "pagemenu" })
      track.clear()
      if ok then
        require("page_menu").open("sea")
        return true
      end
      return nil
    end
    return nil
  end

  if ev.kind == "down" and ctx.line_from_y then
    local idx = M.actions_line_index(ev.width)
    if idx and ctx.line_from_y(ev.y) == idx then
      track.record({ kind = "actions" })
      common.open_actions_menu()
      return true
    end
  end

  if not ctx.cell_from_xy then return nil end

  if ev.kind == "move" then
    local c, r = ctx.cell_from_xy(ev.x, ev.y)
    if c then
      hover = chart_hover_text(c, r)
      ui.dirty()
    elseif hover ~= "" then
      -- Fix round 2, Minor: clear a stale hover line on an off-grid move.
      hover = ""
      ui.dirty()
    end
    return nil
  end

  if ev.kind == "down" then
    local c, r = ctx.cell_from_xy(ev.x, ev.y)
    if not c then return nil end
    track.record({ kind = "cell", c = c, r = r })
    hover = chart_hover_text(c, r)
    ui.dirty()
    return true
  end

  if ev.kind == "up" then
    local c, r = ctx.cell_from_xy(ev.x, ev.y)
    if not c then
      track.clear()
      return nil
    end
    local acted = track.matches({ kind = "cell", c = c, r = r })
    track.clear()
    if not acted then return true end
    local coord = chart_coord(c, r)
    if page_opts.get("confirm_chart_click") then
      local node = CHART_NODES[chart_sym(c, r)]
      local what = " (" .. ((node and node.name) or "Uncharted") .. ")"
      require("menu").open({
        items = {
          { label = "Queue course to " .. coord .. what, value = "yes" },
          { label = "Cancel", value = "no" },
        },
        title = "Plot Voyage Course",
        on_select = function(value)
          if value == "yes" then mud.send("vvoyage queue " .. coord) end
        end,
      })
    else
      mud.send("vvoyage queue " .. coord)
    end
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
