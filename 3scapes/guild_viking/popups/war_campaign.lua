-- Campaign Map popup content (rendered by popups/war.lua's composite when
-- no battle is active -- see that module's mode-condition comment): LEGACY
-- guild_viking.lua's `viking_window.draw_campaign_map` (13620-14016) plus
-- the click-to-move handler region above it (`viking_camp_send_next`/
-- `viking_camp_advance_queue`/`viking_campaign_click`, 13512-13618). ASCII
-- (text-view) branch only -- `page_opts.show_war_ascii` gates LEGACY's own
-- pixel Wang-tile/icon rendering vs. its plain in-game-text glyph fallback,
-- and (unlike City Plan's `show_city_plan_icons`, which defaults OFF, text
-- being the LEGACY default) this opt defaults OFF too but in the OPPOSITE
-- sense -- OFF here means the GRAPHICAL branch is LEGACY's default, not
-- text. It makes no difference to this port: pixel/PNG rendering can never
-- be expressed in an ANSI grid, so the ascii branch's glyph/colour pairs
-- are the only ones ever reachable here, regardless of the opt's value --
-- same "opt has nothing left to gate" disclosure pages/war.lua's own header
-- comment already makes for this exact key.
--
-- `viking_camp_selected`/`viking_camp_queue` (LEGACY 13362-13363, globals)
-- are recreated below as MODULE-LOCALS `selected`/`queue` -- the carry-note
-- flagged since stage 1 (handlers/kingdom.lua's WMEND comment: "the
-- viking_camp_selected/viking_camp_queue resets... out of scope for stage
-- 1's headless protocol layer") lands here. `lines()` stays pure (reads
-- only S.war_map/page_opts, per the plan's Global Constraints); only
-- `on_pointer` ever assigns `selected`/`queue`.
--
-- DEAD-CODE FINDING (verified by grepping the whole LEGACY tree): the
-- "sent" flag and the two functions that would drain a queued path over
-- time -- `viking_camp_send_next` (13517-13524) and
-- `viking_camp_advance_queue` (13526-13553) -- are defined but NEVER
-- CALLED anywhere in LEGACY (no timer, no trigger, no other function
-- references either name). The queue's only LIVE behaviour is what
-- `viking_campaign_click` (13555-13618) does directly and synchronously:
-- every destination click appends a waypoint AND sends
-- "vcampaign queue <id> <sq>" immediately, in the same click -- there is no
-- deferred/staged send, no "sent" bookkeeping, and no live drain. This
-- module ports exactly that live behaviour; the dead functions are not
-- ported (nothing they do is ever reachable). WMEND's own
-- "server queue now the source of truth" reset of the client-side echo
-- (guild_viking.lua:2026, dropped from handlers/kingdom.lua per stage 1)
-- has no module-local hook to land on here either (`lines()` must stay
-- pure and cannot self-clear on a state change with no pointer event) --
-- but this is invisible in practice: the whole campaign section (including
-- any stale selection highlight) only ever renders while
-- `S.war_map.active`, and `viking_campaign_click`'s own
-- "is the selected id still in wm.units?" validation (ported verbatim
-- below) already self-heals a stale `selected`/`queue` pair the moment the
-- player's next click needs it to matter, exactly matching LEGACY's own
-- validation -- LEGACY does not proactively re-validate outside of a click
-- either.
--
-- Grid: `col_headers`/`row_headers` are deliberately OMITTED (unlike
-- LEGACY, which draws column letters/row numbers as separate pixel text
-- above/beside the grid) -- same simplification popups/cityplan.lua and
-- popups/map.lua already make (hover text carries the cell name instead).
-- This also sidesteps a latent maplib sizing mismatch: `row_header_width`
-- is sized from the 0-based row COUNT (`dim - 1`'s digit count), but this
-- grid's cell names use 1-based row numbers (to match `vcampaign`'s own
-- "A1" convention) -- the two digit counts disagree exactly at a
-- power-of-ten row count (e.g. dim=10), which would truncate the header.
-- Skipping headers avoids the bug entirely; hover/queue-status text below
-- the grid already gives the exact "A1"-style cell name.
local pagelib = require("pagelib")
local maplib = require("maplib")
local details = require("popups.hover_details")
local state = require("state")
local cc = require("pages.city_common")
local track = require("popups.pointer_track").tracker()

local S = state.S
local C = pagelib.C
local RESET = pagelib.RESET

local M = {}
M.title = "Campaign Map"

-- viking_camp_selected / viking_camp_queue, recreated as module-locals (see
-- header comment). `selected` = { c=, r=, id= } | nil. `queue` = array of
-- { c=, r=, sq= }, in order, the moves queued for `selected.id` since it
-- was selected.
local selected = nil
local queue = {}

-- Module-local hover/info line, same pattern as every other board popup.
local hover = ""

-- ---------------------------------------------------------------------------
-- CAMP_GLYPH (guild_viking.lua:13646-13652's ASCII branch), ported verbatim
-- as glyph/colour pairs. BGR decode workbook (0xBBGGRR):
--   . 0x808080 -> R=80,G=80,B=80 grey        -> C.dim
--   f 0x33CC33 -> R=33,G=CC,B=33 green       -> C.green
--   H 0xFFFFFF -> white                       -> C.white
--   w 0xFFFF00 -> R=00,G=FF,B=FF cyan; LEGACY's own ascii-comment block
--       (13641-13644) tags this "@hicyan"    -> C.bright_cyan
--   r 0x808080 -> grey (rock; CAMP_NAME/CAMP_TCOL never map to "r" from
--       real terrain data, so this is unreachable in practice, same as
--       LEGACY -- ported anyway for completeness) -> C.dim
-- ---------------------------------------------------------------------------
local CAMP_GLYPH = {
  ["."] = { glyph = ".", color = C.dim },
  f     = { glyph = "f", color = C.green },
  H     = { glyph = "^", color = C.white },
  w     = { glyph = "~", color = C.bright_cyan },
  r     = { glyph = "#", color = C.dim },
}
local CAMP_GLYPH_DEFAULT = CAMP_GLYPH["."]

-- CAMP_NAME (guild_viking.lua:13640), ported verbatim as the hover-tooltip
-- terrain vocabulary.
local CAMP_NAME = { ["."] = "plain", f = "woods", H = "hills", w = "water" }

-- Unit-marker ascii colours (guild_viking.lua:13856-13869's ascii branch):
--   A (host, you)  0x00FF00 -> R=00,G=FF,B=00 green, "@higreen" -> C.bright_green
--   F (ally)       0xFFFF00 -> cyan (same literal/tag as CAMP_GLYPH.w)     -> C.bright_cyan
--   * (objective)  0x00FFFF -> R=FF,G=FF,B=00 yellow, "@yellow" (not "hi") -> C.yellow
--   P1 (landmark, taken)    0x808080 grey                                  -> C.dim
--   P* (landmark, waystone) 0xFFFFFF white                                 -> C.white
--   else (enemy army, glyph = its own id string) 0x3333FF -> R=FF,G=33,B=33
--       red, "@hired" (hi red)                                             -> C.bright_red
-- glyph = "w" for every landmark (LEGACY sets `glyph = "w"` unconditionally
-- for a "P*" id before the ascii/non-ascii branch even splits, 13850-13851).
local function unit_cell(u)
  if u.id == "A" then return { glyph = "A", color = C.bright_green } end
  if u.id == "F" then return { glyph = "F", color = C.bright_cyan } end
  -- Your own detachments (campaign.h's war_map_split): green like the host,
  -- because they are the host, just not all of it.
  if u.kind == "detach" then
    return { glyph = tostring(u.id), color = C.green }
  end
  if u.id == "*" then return { glyph = "*", color = C.yellow } end
  if type(u.id) == "string" and u.id:sub(1, 1) == "P" then
    return { glyph = "w", color = (u.id == "P1") and C.dim or C.white }
  end
  -- Foes 10 and up draw as a, b, c... exactly as the in-game board does
  -- (campaign.h:1673). Rendering the raw id put a two-character glyph into a
  -- one-character cell, where it truncated to its first digit -- so foe 10
  -- appeared on the map as another "1".
  local n = tonumber(u.id)
  if n and n > 9 then
    return { glyph = string.char(87 + n), color = C.bright_red }
  end
  return { glyph = tostring(u.id), color = C.bright_red }
end

local function terrain_cell(rows, c, r)
  local row = rows[r + 1] or ""
  local ch = row:sub(c + 1, c + 1)
  if ch == "" then ch = "." end
  local t = CAMP_GLYPH[ch] or CAMP_GLYPH_DEFAULT
  return { glyph = t.glyph, color = t.color }
end

-- Ported from guild_viking.lua:13724-13734/13896-13898: `sel_c`/`sel_r`
-- track the CURRENT position of the selected stack (re-derived from
-- wm.units every render, since it may have moved), falling back to the
-- player's own host position when the selected id isn't found -- but the
-- fallback only matters visually because the highlight draw itself is
-- gated on `selected` being truthy, exactly like LEGACY's `DrawRect` gate.
-- Axis labels, matching the in-game board exactly: letters across the top
-- (A, B, C...) and 1-based row numbers down the side, which is also how
-- 'vcampaign' names a square ("C4"). The grid was rendered without them, so the
-- pane showed a field of glyphs with no way to read a coordinate off it.
local function col_letter(c) return string.char(65 + c) end
local function row_number(r) return tostring(r + 1) end

local GRID_OPTS = { col_headers = true, row_headers = true,
                    col_label = col_letter, row_label = row_number }

local function make_grid(wm)
  local dim = wm.dim or #(wm.rows or {})
  local rows = wm.rows or {}
  local tiles = require("tiles")
  -- Not `enabled and board(...)`: `and` keeps only the first return value,
  -- and the third (ground) is what keeps a rock cell from going black.
  local tile, ground
  if tiles.enabled("campaign") then
    local _
    tile, _, ground = tiles.board("campaign", rows, dim, dim)
  end
  local ov, wks = {}, {}
  local you_c, you_r = -1, -1
  local sel_c, sel_r = -1, -1
  for _, u in ipairs(wm.units or {}) do
    if u.id == "u" then
      wks[(u.c or 0) .. "," .. (u.r or 0)] = true
    else
      ov[(u.c or 0) .. "," .. (u.r or 0)] = u
      if u.id == "A" then you_c, you_r = u.c or 0, u.r or 0 end
      if selected and u.id == selected.id then sel_c, sel_r = u.c or 0, u.r or 0 end
    end
  end
  if sel_c < 0 then sel_c, sel_r = you_c, you_r end

  return {
    w = dim, h = dim,
    -- The terrain under an overlay marker, so maplib can draw the ground
    -- first and let a marker with a transparent backdrop sit on it.
    -- `ground`, not `tile`: they differ exactly where a terrain tile is itself
    -- a transparent sprite (rock), which needs real ground drawn beneath it.
    under = ground and function(c, r) return ground(c, r) end or nil,
    image = tile and function(c, r)
      local key = c .. "," .. r
      local u = ov[key]
      if u then
        if u.id == "A" then return tiles.city("camp_host_you"), true end
        if u.id == "F" or u.kind == "ally" then return tiles.city("camp_ally_you"), true end
        if tonumber(u.id) then return tiles.city("camp_foe_foe"), true end
        -- The objective marker and the waystone landmarks used to fall through
        -- to nil, which draws no image at all -- so on a tiled board they were
        -- the two cells still showing their raw glyph ("*" and "w", the latter
        -- reading as water because w is also the terrain glyph for it).
        if u.id == "*" then return tiles.city("camp_objective"), true end
        if type(u.id) == "string" and u.id:sub(1, 1) == "P" then
          return tiles.city(u.id == "P1" and "camp_landmark_taken"
                                          or "camp_landmark"), true
        end
        -- A detachment is one of yours, so it wears your colours; kingdom.lua
        -- passes its own server id through, which is neither numeric nor one of
        -- the fixed letters above.
        if u.kind == "detach" then return tiles.city("camp_host_you"), true end
        -- Anything else: fall through to the terrain rather than to nil. nil
        -- used to mean "draw nothing at all", which left the cell showing the
        -- renderer's black clear colour -- a new overlay kind on the server
        -- should look like plain ground here, not like a hole.
        return tile(c, r)
      end
      if wks[key] then return tiles.city("camp_dugout"), true end
      return tile(c, r)
    end,
    cell = function(c, r)
      local key = c .. "," .. r
      local cell
      local u = ov[key]
      if u then
        cell = unit_cell(u)
      elseif wks[key] then
        cell = { glyph = "u", color = C.white } -- dugout marker (13809)
      else
        cell = terrain_cell(rows, c, r)
      end
      if selected and sel_c == c and sel_r == r then
        cell.sel = true
      end
      return cell
    end,
  }
end

-- march_eta_text (guild_viking.lua:13988-13992), ported verbatim.
local function march_eta_text(secs)
  secs = secs or 0
  if secs >= 3600 then
    return string.format("%dh%02dm", math.floor(secs / 3600), math.floor((secs % 3600) / 60))
  elseif secs >= 60 then
    return string.format("%dm", math.floor(secs / 60))
  end
  return string.format("%ds", secs)
end

local function hint_text(wm)
  if wm.pending and wm.pending ~= 0 then
    return "A battle awaits -- 'vcampaign fight'"
  elseif (wm.march_eta or 0) > 0 then
    return "On the march -- next tile in " .. march_eta_text(wm.march_eta)
  end
  return "Holding -- 'vcampaign move <sq>'"
end

-- Disclosed lera addition: LEGACY draws the queued path as coloured lines
-- and cell borders directly on the grid (13956-13980); this text port
-- surfaces the same information (which stack is selected, and its queued
-- waypoints in order) as one status line instead, since maplib has no path
-- overlay primitive.
--
-- The SOURCE of that path list is ported verbatim from LEGACY's own
-- fallback, not just the local echo: `local qpath = (viking_camp_selected
-- and viking_camp_selected.id and wm.queues and
-- wm.queues[viking_camp_selected.id]) or (viking_camp_selected and
-- viking_camp_queue or {})` (13957-13959) -- the SERVER-echoed queue
-- (`wm.queues[id]`, fed by the WMQ handler and committed at WMEND) wins
-- whenever present, and the local click-echo (`queue`) is only a
-- fallback for the brief window before the server round-trips a fresh
-- WMQ/WMEND. Reading only the local echo (as this function used to)
-- would show a stale, ever-growing waypoint list instead of the
-- server-truth queue actually draining as the host arrives at each tile.
local function queue_status_line(wm)
  if not selected then return nil end
  local qpath = (wm.queues and wm.queues[selected.id]) or queue
  if #qpath == 0 then
    return C.cyan .. "Selected " .. selected.id ..
      " -- click a cell to queue a move, its own tile to hold & clear" .. RESET
  end
  local parts = {}
  for _, q in ipairs(qpath) do parts[#parts + 1] = q.sq end
  return C.cyan .. "Queued for " .. selected.id .. ": " .. table.concat(parts, " -> ") .. RESET
end

-- Pre-grid lines (header + the no-data/waiting short-circuit), shared by
-- lines()/geometry()/grid_line_offset() so the three can never drift apart
-- -- same discipline every other board popup follows.
local function pre_grid_lines(width)
  local wm = S.war_map
  if not (wm and wm.active) then
    return { pagelib.header(width, "Campaign Map") }, false
  end
  local hdr = string.format("War Campaign: %s  --  turn %d", wm.town or "?", wm.turn or 0)
  if wm.mode == "defense" and (wm.works_budget or 0) > 0 then
    hdr = hdr .. string.format("  (works %d)", wm.works_budget)
  end
  local out = { pagelib.header(width, hdr) }
  local dim = wm.dim or #(wm.rows or {})
  if dim < 1 or #(wm.rows or {}) < 1 then
    out[#out + 1] = pagelib.trunc(C.dim .. "(waiting for map data...)" .. RESET, width)
    return out, false
  end
  return out, true
end

-- The board alone, with none of this popup's framing. pages/war.lua renders
-- it inline rather than telling the reader to open a popup to see their own
-- battle; sharing make_grid() keeps the two views from drifting, which is the
-- whole reason this is exported instead of copied.
--
-- Returns the lines and their rendered width, so a caller can decline to draw
-- a board wider than its pane instead of overflowing it.
function M.grid_lines()
  local wm = S.war_map
  if not wm or #(wm.rows or {}) < 1 then return nil, 0 end
  local grid = make_grid(wm)
  return maplib.render(grid, GRID_OPTS), maplib.geometry(grid, GRID_OPTS).width
end

function M.tile_grid(width)
  local wm = S.war_map
  if not wm or not wm.active then return {}, nil end
  local grid = make_grid(wm)
  return maplib.render(grid, GRID_OPTS, width), maplib.geometry(grid, GRID_OPTS, width)
end

local hover_text
function M.lines(width)
  local out, has_grid = pre_grid_lines(width)
  if not has_grid then return out end

  local wm = S.war_map
  for _, l in ipairs(maplib.render(make_grid(wm), GRID_OPTS, width)) do out[#out + 1] = l end
  details.append_grid(out, hover, width, wm.dim or #(wm.rows or {}), wm.dim or #(wm.rows or {}),
    function(c, r) return hover_text(wm, c, r) end)
  out[#out + 1] = pagelib.trunc(C.yellow .. hint_text(wm) .. RESET, width)

  local up = wm.upkeep
  if up and (up.food or 0) > 0 then
    -- Same colouring as pages/war.lua's copy of this line: each good in the
    -- shared cc.good_color(), daler in yellow.
    local function _good(n, g)
      return string.format("%s%d %s%s", cc.good_color(g), n or 0, g, RESET)
    end
    out[#out + 1] = pagelib.trunc(string.format("%sUpkeep/tile:%s %s  %s  %s  %s  %s%dd%s",
      C.dim, RESET,
      _good(up.food, "food"), _good(up.mead, "mead"),
      _good(up.tools, "tools"), _good(up.iron, "iron"),
      C.yellow, up.daler or 0, RESET), width)
  end

  local sp = wm.spoils
  if sp and ((sp.daler or 0) > 0 or (sp.deeds or 0) > 0) then
    out[#out + 1] = pagelib.trunc(string.format(
      "%sSpoils if you win:%s %s%d daler%s, %s%d renown%s  %s(%d deed%s)%s",
      C.dim, RESET,
      C.yellow, sp.daler or 0, RESET,
      C.bright_cyan, sp.renown or 0, RESET,
      C.green, sp.deeds or 0, (sp.deeds == 1) and "" or "s", RESET), width)
  end

  local qline = queue_status_line(wm)
  if qline then out[#out + 1] = pagelib.trunc(qline, width) end

  return out
end

-- geometry()/grid_line_offset(): the ctx.cell_from_xy contract popups.lua
-- documents. nil/unreachable whenever the grid isn't the thing on screen.
function M.geometry(width)
  local _, has_grid = pre_grid_lines(width)
  if not has_grid then return nil end
  return maplib.geometry(make_grid(S.war_map), GRID_OPTS, width)
end

function M.grid_line_offset(width)
  local out = pre_grid_lines(width)
  return #out
end

-- viking_chart_tooltip-style flattened hover text, mirroring LEGACY's own
-- bcamp_* tooltip construction (13901-13935) one-for-one, "\r\n" collapsed
-- to "  " like every other module's hover line.
hover_text = function(wm, c, r)
  local row = (wm.rows or {})[r + 1] or ""
  local terr_ch = row:sub(c + 1, c + 1)
  if terr_ch == "" then terr_ch = "." end

  local u, dugout
  for _, uu in ipairs(wm.units or {}) do
    if uu.c == c and uu.r == r then
      if uu.id == "u" then dugout = true else u = uu end
    end
  end

  local sq = string.char(65 + c) .. tostring(r + 1)
  local tip = sq .. "  " .. (CAMP_NAME[terr_ch] or "plain")
  if dugout then tip = tip .. "  dugout" end

  if u then
    if u.name and u.name ~= "" then tip = tip .. "  Name: " .. u.name end
    if u.size ~= nil then tip = tip .. "  " .. tostring(u.size) .. " men" end
    if u.owner and u.owner ~= "" then tip = tip .. "  Owner: " .. u.owner end
    if u.f and u.f ~= "" then tip = tip .. "  facing " .. u.f end
    if u.id == "A" then
      tip = tip .. "  host (you)"
    elseif u.id == "F" or u.kind == "ally" then
      tip = tip .. "  ally"
    elseif u.kind == "detach" then
      tip = tip .. "  detachment (yours)"
    elseif u.id == "*" then
      tip = tip .. "  objective"
    elseif type(u.id) == "string" and u.id:sub(1, 1) == "P" then
      tip = tip .. "  landmark" .. ((u.id == "P1") and " (taken)" or " (waystone)")
    else
      tip = tip .. "  enemy army" .. ((u.id ~= nil and u.id ~= "") and (" " .. tostring(u.id)) or "")
      local you
      for _, uu in ipairs(wm.units or {}) do if uu.id == "A" then you = uu; break end end
      if you and you.f and you.f ~= "" then
        local dx, dy = c - (you.c or 0), r - (you.r or 0)
        local fx, fy = 0, 0
        if you.f == "N" then fy = -1
        elseif you.f == "S" then fy = 1
        elseif you.f == "E" then fx = 1
        else fx = -1 end
        local dot = dx * fx + dy * fy
        if dot > 0 then tip = tip .. "  front of you"
        elseif dot < 0 then tip = tip .. "  REAR of you"
        else tip = tip .. "  flank of you" end
      end
    end
  end

  if u and (u.id == "A" or u.id == "F") then
    tip = tip .. "  -- Click: select this host"
  elseif selected then
    tip = tip .. "  -- Click: move selected host here"
  else
    tip = tip .. "  -- Click: select a host first"
  end
  return tip
end

-- viking_campaign_click (guild_viking.lua:13555-13618), ported verbatim.
local function on_click(wm, c, r)
  if not wm.units then
    selected = nil
    queue = {}
    return
  end

  if selected then
    local still = false
    for _, u in ipairs(wm.units) do
      if u.id == selected.id then still = true; break end
    end
    if not still then selected = nil; queue = {} end
  end

  local unit
  for _, u in ipairs(wm.units) do
    if u.c == c and u.r == r and (u.id == "A" or u.id == "F") then unit = u; break end
  end

  local sel_u
  if selected then
    for _, u in ipairs(wm.units) do
      if u.id == selected.id then sel_u = u; break end
    end
  end

  local sq = string.char(65 + c) .. tostring(r + 1)

  if not selected then
    if unit then
      selected = { c = c, r = r, id = unit.id }
    end
    -- else: "Click a host first" -- LEGACY's ColourNote is display-only,
    -- dropped (same convention every handler in this plugin follows).
  else
    if sel_u and sel_u.c == c and sel_u.r == r then
      selected = nil
      queue = {}
      mud.send("vcampaign hold")
    else
      queue[#queue + 1] = { c = c, r = r, sq = sq }
      mud.send("vcampaign queue " .. selected.id .. " " .. sq)
    end
  end
end

-- viking_campaign_click's hotspot (13936-13938) wires ONLY a MouseUp
-- callback -- no MouseOver/MouseDown at all, unlike popups/cityplan.lua's
-- cpt_* hotspots (which wire viking_cityplan_down). CORRECTED (fix round 2,
-- Critical #1): registering no MouseDown handler in MUSHclient does not
-- mean the mousedown is left unconsumed -- the miniwin runtime still
-- captures it internally so the matching MouseUp can be delivered to the
-- SAME hotspot. lera's popup layer (scripts/default/popup.lua) has no such
-- internal capture: a down must return `true` for the popup to hold the
-- pointer at all, or the eventual "up" is never dispatched here to begin
-- with (swallowed one layer up, in popup.lua's own capture bookkeeping) --
-- which is exactly what made this whole click-to-move flow unreachable end
-- to end despite `on_click` itself being correct in isolation. The down
-- case below therefore consumes (returns true) and records which cell it
-- hit via `track` (popups/pointer_track.lua); "up" only invokes `on_click`
-- when its own cell matches that record -- the "hotspot that took the
-- mousedown gets the mouseup" rule, reproduced despite the popup layer's
-- coarser button-only capture (see pointer_track.lua's header comment for
-- why this also defuses a cross-target drag and the war composite's
-- mid-drag mode-flip race). Every non-left mouse-up still does nothing at
-- all in LEGACY (the early `bit.band(flags, hotspot_got_lh_mouse) == 0 ->
-- return` guard at the very top of viking_campaign_click) -- ported as
-- "still consume the cell, but take no action", the same "consume without
-- acting" convention popups/cityplan.lua's own on_pointer already uses for
-- its non-actionable branches.
function M.on_pointer(ev, ctx)
  if not ctx.cell_from_xy then return nil end
  local wm = S.war_map
  if not (wm and wm.active) then return nil end
  local dim = wm.dim or #(wm.rows or {})
  if dim < 1 or #(wm.rows or {}) < 1 then return nil end

  if ev.kind == "cancel" then
    track.clear()
    return nil
  end

  if ev.kind == "move" then
    local c, r = ctx.cell_from_xy(ev.x, ev.y)
    if not c then
      -- Fix round 2, Minor: clear a stale hover line on an off-grid move
      -- rather than leaving the last on-grid cell's tooltip showing.
      if hover ~= "" then hover = ""; ui.dirty() end
      return nil
    end
    hover = hover_text(wm, c, r)
    ui.dirty()
    return nil
  end

  if ev.kind == "down" then
    local c, r = ctx.cell_from_xy(ev.x, ev.y)
    if not c then return nil end
    track.record({ kind = "cell", c = c, r = r })
    hover = hover_text(wm, c, r)
    ui.dirty()
    return true
  end

  if ev.kind == "up" then
    local c, r = ctx.cell_from_xy(ev.x, ev.y)
    if not c then
      -- Fix round 3: clear the tracker here too, matching cityplan.lua/
      -- sea.lua/war_battle.lua's own off-grid-up early return and
      -- pointer_track.lua's own documented contract -- an off-grid release
      -- still ends the gesture, so the next down must start fresh rather
      -- than comparing against a stale record.
      track.clear()
      return nil
    end
    if ev.button == "left" and track.matches({ kind = "cell", c = c, r = r }) then
      on_click(wm, c, r)
    end
    hover = hover_text(wm, c, r)
    ui.dirty()
    track.clear()
    return true
  end

  return nil
end

-- Called by popups.lua's registry when this popup closes (fix round 2,
-- Minor: "clear hover on close"), so a stale tooltip from wherever the
-- pointer last was doesn't show immediately on the next open, before any
-- fresh move/down arrives. `selected`/`queue` are deliberately NOT cleared
-- here -- they mirror LEGACY's own viking_camp_selected/viking_camp_queue,
-- which persist across the window being shown/hidden, not just this popup
-- being open.
function M.reset()
  hover = ""
end

return M
