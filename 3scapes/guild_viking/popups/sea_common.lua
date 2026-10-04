-- Shared section builders for popups/sea.lua (/vik sea, full sub-view) and
-- popups/voyage.lua (/vik voyage, the compact voyage-status subset) --
-- LEGACY guild_viking.lua's draw_page11 (14674-15297), the parts common to
-- BOTH popups per the plan's binding split ruling: the no-data gate (ported
-- from draw_page10, 13213-13228, the ONLY thing draw_page10 itself
-- contributes -- everything else it does is delegate to draw_page11), the
-- no-active-voyage fallback, the Voyage Status fields + Awaiting Resolution
-- + Identity/Traits/Crew block, and the Queue/Saga/Crew Memory sections.
-- sea.lua adds the chart (maplib) + legend + the Secured-* loot sections on
-- top of these; voyage.lua uses exactly this module and nothing else.
--
-- Pure module, same contract as pagelib/city_common: reads state.lua's S and
-- page_opts.lua only, no ui.*/mud.* calls, no mutation.
local pagelib = require("pagelib")
local state = require("state")
local page_opts = require("page_opts")
local cc = require("pages.city_common")

local S = state.S
local C = pagelib.C
local RESET = pagelib.RESET

local M = {}

-- ---------------------------------------------------------------------------
-- coord_label (guild_viking.lua:14713-14715), ported verbatim. Used both for
-- the Position field and for queue-step coordinates -- the SAME function
-- LEGACY shares between them. Distinct from the chart's own ch_<coord>
-- hotspot-id scheme (popups/sea.lua's chart_coord): that one is 1-based
-- ("A01"); this one is 0-based on the column (per its own "(x or 0) + 1").
function M.coord_label(x, yv)
  return string.format("%c%02d", 65 + (yv or 0), (x or 0) + 1)
end

-- weather_labels (guild_viking.lua:14683-14691), ported verbatim.
local WEATHER_LABELS = {
  mist_bank = "Mist Bank", stormbelt = "Stormbelt", crosscurrent = "Crosscurrent",
  deadwater = "Deadwater", maelstrom = "Maelstrom", ice_floes = "Ice Floes",
  aurora = "Aurora Calm",
}
function M.weather_label(key)
  key = key or ""
  if key == "" then return "Calm" end
  return WEATHER_LABELS[key] or key
end

-- wait_label (guild_viking.lua:14975-14984), ported verbatim.
local WAIT_LABELS = {
  objective = "Objective choice", wreck = "Wreck choice", harbor = "Harbor choice",
  island = "Island choice", storm = "Storm choice", fog = "Fog choice",
  unknown = "Unknown node choice",
}
function M.wait_label(raw)
  raw = tostring(raw or "")
  if raw == "" then return "" end
  return WAIT_LABELS[raw] or (raw:gsub("_", " "):gsub("^%l", string.upper))
end

-- ---------------------------------------------------------------------------
-- No-data gate (draw_page10, guild_viking.lua:13213-13228 -- the ONLY thing
-- that function contributes to this port; its delegation to draw_page11 is
-- what THIS module + sea.lua/voyage.lua's own gating already reproduce).
-- 0x666666 (guild_viking.lua:13216) -> R=66,G=66,B=66, mid-gray -> C.dim.
-- ---------------------------------------------------------------------------
function M.mip_gate_lines(width)
  return { pagelib.trunc(C.dim .. "No data yet -- voyage status arrives while a voyage is live" .. RESET, width) }
end

-- ---------------------------------------------------------------------------
-- No-active-voyage fallback + reroll-contracts hint (guild_viking.lua:
-- 14962-14995). The reroll buttons themselves (btn_reroll_<ship_id> ->
-- "vvoyage launch <ship> reroll") are pixel-rectangle hotspots with no grid
-- to hang a click on under this popup's ctx.cell_from_xy-only contract
-- (popups.lua exposes grid-cell hit-testing, not line/column hit-testing for
-- arbitrary text buttons). They ARE live in this port, just not as a
-- per-ship click here: M.actions()/M.open_actions_menu() below expose them
-- (and the other three standalone button hotspots on this page -- resolve/
-- end/clear) through one clickable "[Actions]" line, using ctx.line_from_y
-- instead of a grid cell. The exact command text is ALSO rendered here as
-- plain text (so the option stays legible even without opening the menu).
-- 0x666666 -> C.dim (see above); ship-name label color 0xFFDD88
-- (guild_viking.lua:14993) -> R=88,G=DD,B=FF, light blue -> C.bright_cyan
-- (pagelib.C has no blue).
-- ---------------------------------------------------------------------------
function M.no_voyage_lines(width)
  local out = { pagelib.trunc(C.dim .. "No active voyage" .. RESET, width) }
  local docked = {}
  for _, sh in ipairs(S.voyage_longships or {}) do
    if (sh.state or "") == "docked" and (sh.ship_id or 0) > 0 then
      docked[#docked + 1] = sh
    end
  end
  if #docked > 0 then
    out[#out + 1] = pagelib.trunc(
      C.dim .. "Reroll contracts (5000 daler): vvoyage launch <ship> reroll" .. RESET, width)
    local names = {}
    for _, sh in ipairs(docked) do
      names[#names + 1] = C.bright_cyan .. sh.name .. RESET
    end
    out[#out + 1] = pagelib.trunc(table.concat(names, ", "), width)
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Voyage Status fields (guild_viking.lua:14996-15015's draw_pair calls) as
-- two-up key/value lines -- same halving technique popups/map.lua's
-- town_lines uses for its 2-column flow. Colors: BGR decode workbook
-- (0xBBGGRR) below; pagelib.C has ten hues, several LEGACY literals fold
-- onto the nearest one (same "no blue -> cyan" / "orange-ish -> yellow"
-- precedent popups/map.lua's own workbook sets).
--
--   Position 0xAAAAAA -> R=AA,G=AA,B=AA gray            -> C.dim
--   Contract 0xCCCC66 -> R=66,G=CC,B=CC teal            -> C.cyan
--   Threat   0xEEEEEE -> R=EE,G=EE,B=EE near-white      -> C.white
--   Danger   0xCC8844 -> R=44,G=88,B=CC medium blue     -> C.cyan (folded)
--   Pressure 0x4444FF -> R=FF,G=44,B=44 red             -> C.bright_red
--   Hull     0x44CC44 -> R=44,G=CC,B=44 green           -> C.green
--   Crew     0xEEEEEE -> white                          -> C.white
--   Morale   0x00CCCC -> R=CC,G=CC,B=00 yellow          -> C.yellow
--   Supplies 0xCCBB88 -> R=88,G=BB,B=CC light blue/cyan -> C.cyan (folded)
--   Stress   0x4444FF -> red (same literal as Pressure) -> C.bright_red
--   Weather  0xAAAAAA -> gray (same literal as Position)-> C.dim
--   State    0xEEEEEE -> white                          -> C.white
--   Next     0xEEEEEE -> white                          -> C.white
--   Renown   0x88CCFF -> R=FF,G=CC,B=88 gold/orange     -> C.yellow
--   Captain  0xEEEEEE -> white                          -> C.white
--
-- Awaiting-Resolution value color 0xFFBB44 (guild_viking.lua:15055)
-- -> R=44,G=BB,B=FF sky blue -> C.bright_cyan (folded). Identity/State
-- 0xEEEEEE -> C.white; Traits/Crew 0xBBBBBB (guild_viking.lua:15116-15121)
-- -> C.dim. "Crew" is used as the label TWICE (once for crew_alive/crew_max,
-- once for crew_traits) -- a LEGACY quirk (draw_full("Crew", ...),
-- guild_viking.lua:15121), ported verbatim rather than renamed.
-- ---------------------------------------------------------------------------
local function pair_line(width, l1, v1, c1, l2, v2, c2)
  local half = math.floor(width / 2)
  local w2 = math.max(0, width - half - 1)
  return pagelib.kv(half, l1, v1, c1) .. " " .. pagelib.kv(w2, l2, v2, c2)
end

function M.status_lines(width)
  local v = S.voyage_status
  local out = { pagelib.header(width, "Voyage Status") }

  out[#out + 1] = pair_line(width,
    "Ship:", (v.ship_name ~= "" and v.ship_name) or "Unknown", C.white,
    "Position:", M.coord_label(v.x, v.y), C.dim)
  out[#out + 1] = pair_line(width,
    "Contract:", (v.contract_name ~= "" and v.contract_name) or "Open sea", C.cyan,
    "Threat:", ((v.threat_name ~= "" and v.threat_name) or "Open sea")
      .. " [" .. tostring(v.threat_level or 0) .. "]", C.white)
  out[#out + 1] = pair_line(width,
    "Danger:", tostring(v.danger or 0), C.cyan,
    "Pressure:", tostring(v.threat_pressure or 0), C.bright_red)
  out[#out + 1] = pair_line(width,
    "Hull:", tostring(v.hull or 0) .. "%", C.green,
    "Crew:", string.format("%d/%d", v.crew_alive or 0, v.crew_max or 0), C.white)
  out[#out + 1] = pair_line(width,
    "Morale:", tostring(v.morale or 0) .. "%", C.yellow,
    "Supplies:", tostring(v.supplies or 0) .. "%", C.cyan)
  out[#out + 1] = pair_line(width,
    "Stress:", tostring(v.stress or 0) .. "%", C.bright_red,
    "Weather:", M.weather_label(v.weather_key), C.dim)
  out[#out + 1] = pair_line(width,
    "State:", (v.state ~= "" and v.state) or "-", C.white,
    "Next:", (v.next_move or 0) > 0 and cc.fmt_time(v.next_move) or "waiting", C.white)
  out[#out + 1] = pair_line(width,
    "Fleet Renown:", tostring(S.fleet_renown or 0), C.yellow,
    "Captain:", (v.captain ~= "" and v.captain) or "-", C.white)

  -- Awaiting Resolution (guild_viking.lua:15034-15095). The resolve/end
  -- buttons are, again, pixel hotspots with no grid to hang a click on --
  -- live via M.actions()/M.open_actions_menu() below (the "[Actions]" line
  -- instead of a per-button hotspot); their exact command text is ALSO
  -- surfaced here so a player can read (or type) it without opening the menu.
  local wait_txt = M.wait_label(S.voyage_wait)
  if wait_txt ~= "" then
    out[#out + 1] = pagelib.kv(width, "Awaiting Resolution:", wait_txt, C.bright_cyan)
    if #(S.voyage_resolve_options or {}) > 0 then
      out[#out + 1] = pagelib.kv(width, "Options:",
        table.concat(S.voyage_resolve_options, ", ") .. "  (vvoyage resolve <option>)", C.bright_cyan)
    end
    if S.voyage_wait == "harbor" then
      out[#out + 1] = pagelib.trunc(
        C.dim .. "Harbor: End Voyage available (vvoyage end)" .. RESET, width)
    end
  end

  if v.identity ~= "" then
    out[#out + 1] = pagelib.kv(width, "Identity:", v.identity, C.white)
  end
  if #(v.ship_traits or {}) > 0 then
    out[#out + 1] = pagelib.kv(width, "Traits:", table.concat(v.ship_traits, ", "), C.dim)
  end
  if #(v.crew_traits or {}) > 0 then
    out[#out + 1] = pagelib.kv(width, "Crew:", table.concat(v.crew_traits, ", "), C.dim)
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Queue (guild_viking.lua:15207-15229, gated show_sea_queue). The Clear
-- button (btn_clr_queue -> "vvoyage clear") is a pixel hotspot, live via
-- M.actions()/M.open_actions_menu() below, same as the others above.
--
-- The "x,y" -> coord_label conversion branch below (guild_viking.lua:
-- 15222-15224) is ported verbatim but is DEAD CODE in practice: VQPATH's
-- own wire delimiter is comma (handlers/voyage.lua's M.VQPATH, ported from
-- LEGACY 1326-1331), so an individual step can never itself contain a
-- comma once split off the wire -- the pattern below can never match a
-- real payload. Kept anyway since LEGACY has it and it is harmless (the
-- `else` fallback -- render the raw step -- is what every real step takes).
-- ---------------------------------------------------------------------------
function M.queue_lines(width)
  local out = { pagelib.header(width, "Queue") }
  local q = S.voyage_queue or {}
  if #q == 0 then
    out[#out + 1] = pagelib.trunc(C.dim .. "No queued movement" .. RESET, width)
  else
    local parts = {}
    for _, step in ipairs(q) do
      local qx, qy = step:match("^(%-?%d+),(%-?%d+)$")
      if qx and qy then
        parts[#parts + 1] = M.coord_label(tonumber(qx), tonumber(qy))
      else
        parts[#parts + 1] = step
      end
    end
    out[#out + 1] = pagelib.trunc(C.white .. table.concat(parts, " -> ") .. RESET, width)
  end
  return out
end

-- One prose sentence, wrapped to the pane under a bullet. wrap_parts breaks
-- BETWEEN parts and never splits an escape sequence, so the words go in as
-- parts with a plain space between them.
local function wrap_prose(width, bullet, text)
  local out = {}
  local indent = string.rep(" ", #bullet + 1)
  local prefix = bullet .. " "
  local limit = width - #indent
  if limit < 8 then limit = 8 end
  local line = ""
  local function flush()
    if line == "" then return end
    out[#out + 1] = pagelib.trunc(C.dim .. prefix .. line .. RESET, width)
    prefix = indent
    line = ""
  end
  for word in tostring(text):gmatch("%S+") do
    -- A word longer than the pane can only be broken mid-word; trunc would
    -- silently eat the rest of the sentence with it.
    while #word > limit do
      flush()
      out[#out + 1] = pagelib.trunc(C.dim .. prefix .. word:sub(1, limit) .. RESET, width)
      prefix = indent
      word = word:sub(limit + 1)
    end
    if line == "" then line = word
    elseif #line + 1 + #word > limit then flush(); line = word
    else line = line .. " " .. word end
  end
  flush()
  return out
end

-- ---------------------------------------------------------------------------
-- Saga (guild_viking.lua:15231-15242, gated show_sea_saga). "Captain style:"
-- entries are filtered out verbatim (guild_viking.lua:15239); the "No recent
-- saga lines" fallback checks the RAW count (#voyage_saga == 0), same as
-- LEGACY -- a saga list containing only filtered entries renders a header
-- with zero body lines rather than falling back to the "No recent" text,
-- matching LEGACY's exact (if slightly odd) branching. 0xBBBBBB -> C.dim.
-- ---------------------------------------------------------------------------
function M.saga_lines(width)
  local out = { pagelib.header(width, "Saga") }
  local saga = S.voyage_saga or {}
  if #saga == 0 then
    out[#out + 1] = pagelib.trunc(C.dim .. "No recent saga lines" .. RESET, width)
  else
    for _, line in ipairs(saga) do
      if not tostring(line):match("^Captain style:%s") then
        -- Saga lines are prose, not labels: truncating one to the pane width
        -- cut the sentence off mid-word. Wrap it instead, hanging under the
        -- bullet so the block still reads as one entry per dash.
        for _, row in ipairs(wrap_prose(width, "-", tostring(line))) do
          out[#out + 1] = row
        end
      end
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Crew Memory (guild_viking.lua:15244-15254, gated show_sea_memory).
-- 0xAAAAAA -> C.dim (same fold as Saga's 0xBBBBBB).
-- ---------------------------------------------------------------------------
function M.memory_lines(width)
  local out = { pagelib.header(width, "Crew Memory") }
  local mem = S.voyage_memory or {}
  if #mem == 0 then
    out[#out + 1] = pagelib.trunc(C.dim .. "No crew memories yet" .. RESET, width)
  else
    for _, line in ipairs(mem) do
      for _, row in ipairs(wrap_prose(width, "-", tostring(line))) do
        out[#out + 1] = row
      end
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- [Actions] line: the fix-round-1 remedy for the four standalone button
-- hotspots neither popup could hit-test through maplib's grid-only
-- ctx.cell_from_xy (reroll 14989-14994, resolve 15060-15069, end voyage
-- 15079-15090, clear queue 15214-15220). Each item's VISIBILITY condition
-- below is ported verbatim from its own LEGACY button's drawing condition
-- (not just "does the command exist"); popups/sea.lua and popups/voyage.lua
-- both call M.actions()/M.actions_line()/M.open_actions_menu() so the two
-- popups can never disagree about what's clickable right now.
-- ---------------------------------------------------------------------------
function M.actions()
  local items = {}
  if not S.voyage_status then
    -- Reroll (14962-14995): one item per DOCKED ship with a ship_id,
    -- shown ONLY while there is no active voyage (this whole branch is the
    -- no-active-voyage fallback).
    for _, sh in ipairs(S.voyage_longships or {}) do
      if (sh.state or "") == "docked" and (sh.ship_id or 0) > 0 then
        items[#items + 1] = {
          label = "Reroll " .. sh.name .. " contracts (5000 daler)",
          value = "vvoyage launch " .. sh.name .. " reroll",
        }
      end
    end
    return items
  end

  -- Resolve (15034-15069): one item per resolve option, shown only while
  -- awaiting a resolution (voyage_wait non-empty).
  if M.wait_label(S.voyage_wait) ~= "" then
    for _, opt in ipairs(S.voyage_resolve_options or {}) do
      items[#items + 1] = { label = "Resolve: " .. opt, value = "vvoyage resolve " .. opt }
    end
    -- End Voyage (15071-15090): shown at a harbor node -- LEGACY's own
    -- `_at_harbor` condition -- regardless of whether any resolve options
    -- are ALSO on offer (`#resolve_options > 0 or _at_harbor`).
    if S.voyage_wait == "harbor" then
      items[#items + 1] = { label = "End Voyage", value = "vvoyage end" }
    end
  end

  -- Clear Queue (15207-15220): drawn as part of the Queue section itself,
  -- so it shares that section's own gate (show_sea_queue) and is offered
  -- regardless of whether the queue currently holds anything (LEGACY draws
  -- the button unconditionally inside the gated Queue block).
  if page_opts.get("show_sea_queue") then
    items[#items + 1] = { label = "Clear Queue", value = "vvoyage clear" }
  end
  return items
end

-- Single-line summary + click target for M.actions() above. Returns {} (no
-- line at all, not a dead click target with nothing behind it) when there
-- is nothing to act on right now.
function M.actions_line(width)
  local items = M.actions()
  if #items == 0 then return {} end
  return {
    pagelib.trunc(
      C.bright_cyan .. "[Actions] " .. #items .. " available - click to open" .. RESET, width),
  }
end

-- Opens the [Actions] menu and sends the exact LEGACY command for whichever
-- item is selected -- shared by popups/sea.lua and popups/voyage.lua's
-- on_pointer. `items` already has the { label =, value = } shape
-- require("menu") wants (value defaults its own `search` to `label`).
-- No-op (never opens an empty menu) when there is nothing to act on.
function M.open_actions_menu()
  local items = M.actions()
  if #items == 0 then return false end
  require("menu").open({
    items = items,
    title = "Voyage Actions",
    -- Guarded: a menu item whose value never got built would otherwise
    -- reach the MUD as a bare prompt line.
    on_select = function(value) require("util").send(value, "sea popup") end,
  })
  return true
end

return M
