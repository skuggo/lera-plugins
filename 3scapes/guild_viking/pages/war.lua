-- War page: LEGACY's draw_page_war
-- (/home/simon/code/3s_scripts_old/lua/guild_viking.lua:14061-14669) plus the
-- two helper functions it calls, `draw_campaign_map` (13620-14016) and
-- `draw_prison_panel` (14020-14058). Pure builder: lines(width) -> array of
-- ANSI strings, reading state.lua's S and page_opts.lua only. TEXTUAL
-- OVERVIEW ONLY, per the task brief: every pixel-grid render (the campaign
-- march map AND the tactical battle board) collapses to ONE placeholder
-- line each, at the exact point LEGACY draws the grid -- everything else
-- LEGACY draws around those grids (headers, hints, upkeep, spoils, command
-- budget, unit rosters, war status, campaigns, diplomacy) is ported as text.
--
-- Section order/gates, read from the source top to bottom:
--   Campaign Map (UNGATED -- state.war_map and state.war_map.active,
--     13620-14016) -- header (town/turn[/works budget]); the grid itself
--     (dropped, see below); a status hint (battle awaits / marching ETA /
--     holding); per-tile upkeep; spoils-if-you-win.
--   War Captives (UNGATED -- data-gated on state.prison/state.siege having
--     anything to show, 14020-14058) -- held/cap header, a pending-judgement
--     line, the captive roster, and kin held by the foe. The siege park is
--     the Army page's, not this one's.
--     Persists even with no active campaign (LEGACY's own comment).
--   Battle (show_war_battle, 14084-14603) -- deploy/turn header; the tactical
--     grid (dropped); command budget + Fraegd (war points); either the
--     deploy-phase reserve/deployed rosters or the turn-phase your-host/enemy
--     rosters; "No battle underway" when state.battle is nil. The running
--     Fraegd total is NOT here: it is the page's first line (below), since
--     it outlives any one battle.
--   War Council (show_war_council, 14606-14624) -- an incoming-threat line
--     or "no power marches," then the held-claims list or "no claims held."
--   Campaigns (show_war_campaigns AND state.war.campaigns non-empty,
--     14626-14647) -- one row per campaign (town + a defense-pct bar).
--   Great Houses (show_war_houses, 14649-14667) -- state.diplomacy's
--     allies/foes lists, or "no houses committed."
--
-- DISCREPANCY vs. the task brief, disclosed up front: the brief's landmark
-- list mentioned "grudges summary if present." Grepped `grudge` across the
-- whole LEGACY file (same check Task 7 ran for the ranks page): `state.
-- grudges` ("Reprisal Grudges") is drawn inside `draw_page2`'s city/heat
-- block, already ported to `pages/trade.lua` under `show_city_heat` (Task
-- 4). It is not reachable from `draw_page_war`, `draw_campaign_map`, or
-- `draw_prison_panel` -- confirmed by reading all three in full. Not ported
-- here; already ported at its actual source location.
--
-- Dropped grid/hotspot surfaces (stage 3's list, everything under the two
-- placeholder lines below):
--   - Campaign map: the whole Wang-tile terrain grid, the terrain/unit
--     legend rows, the queued-move path line/highlights, the per-cell
--     "bcamp_<c>_<r>" hotspots (click-to-select-army / click-to-queue-move),
--     and the `viking_camp_selected`/`viking_camp_queue` click-to-move
--     globals that drive them.
--   - Tactical battle board: the terrain/works grid itself, the unit-glyph
--     legend rows (M/B/H/S/K/A/R/L/G), the "same letter" duplicate-ordinal
--     roll call, the terrain-tile legend, the per-cell "bcell_<coord>"
--     hotspots (click-to-select-unit / click-to-move / right-click deploy
--     menu) and `state.battle_cell_info`/`state.battle_selected`, and the
--     three clickable action buttons (Begin Battle/Advance Turn/Abandon,
--     "bbtn_begin"/"bbtn_go"/"bbtn_abandon") together with
--     `state.battle_buttons`.
--   - `page_opts.show_war_ascii` (tiles-vs-ASCII-glyphs rendering mode) has
--     no effect on this port: it only ever changed how the now-dropped grids
--     were drawn, so it is unused here -- not a missing gate, just an opt
--     with nothing left to gate.
--
-- BGR color decoding (guild_viking.lua line 301, 0xBBGGRR): every literal
-- below decoded byte-by-byte before choosing a pagelib.C entry.
--   - Campaign hint 0x55AAAA -> (R=AA,G=AA,B=55) a muted yellow-olive;
--     pagelib.C has no olive -> mapped to C.yellow (nearest warm-neutral).
--   - Campaign upkeep-per-tile 0x8888BB -> (R=BB,G=88,B=88) a muted rose-red
--     -> mapped to C.red (nearest available hue; this is informational, not
--     an alarm, but pagelib.C has no separate muted-red).
--   - Campaign spoils-if-win 0x40C0A0 -> (R=A0,G=C0,B=40) yellow-green ->
--     mapped to C.green (G-dominant channel wins).
--   - Prison "awaiting judgement" 0x33CCFF -> (R=FF,G=CC,B=33) gold ->
--     C.yellow. Kin-held-by-foe 0x5555DD -> (R=DD,G=55,B=55) brick red ->
--     C.red. Siege engines 0x66AAEE -> (R=EE,G=AA,B=66) tan/orange ->
--     C.yellow (nearest; no orange in pagelib.C). Roster rows 0xCCCCCC ->
--     light grey -> C.white (matches ranks.lua's own-lineage-grey
--     precedent).
--   - "In reserve"/"Deployed" section labels 0x00CCFF -> (R=FF,G=CC,B=00)
--     gold -> C.yellow. Deployed/reserved unit lines 0x40FF40 -> bright
--     green -> C.bright_green. "Led by"/"pts"/"Position" labels 0x999999 ->
--     grey -> C.dim; the leader NAME/position VALUE 0xEEEEEE -> near-white
--     -> C.white. Command budget label 0x00CCCC -> (R=CC,G=CC,B=00) yellow
--     -> C.yellow. Fraegd (war points) label 0xFFCC44 -> (R=44,G=CC,B=FF)
--     light blue -> C.bright_cyan.
--   - Your-host header 0x00CCFF -> gold -> C.yellow; your-host unit name
--     0x40FF40 -> bright green -> C.bright_green. Enemy header 0x4040FF ->
--     (R=FF,G=40,B=40) red -> C.bright_red; enemy unit name 0x6060FF ->
--     (R=FF,G=60,B=60) a lighter red -> C.red (one shade down from the
--     header, same relationship, no separate "light red" in pagelib.C).
--   - Morale color (`mor_col`): >=66 0x40FF40 bright green -> C.bright_green;
--     >=33 0x00CCCC -> DECODES to (R=CC,G=CC,B=00) YELLOW, not cyan despite
--     the hex looking cyan-shaped at a glance -- flagged explicitly because
--     it is easy to misread; else 0x4040FF -> red -> C.bright_red. Three
--     tiers preserved exactly: green/yellow/red.
--   - War Council incoming-threat 0x4444FF -> (R=FF,G=44,B=44) red ->
--     C.bright_red (matches the "under threat" alarm intent, no
--     discrepancy). "No power marches"/"No claims held" 0x888888 -> grey ->
--     C.dim. Claim rows 0xEEEEEE -> near-white -> C.white.
--   - Campaigns: town label 0xEEEEEE -> C.white; pct readout 0xCCCCCC ->
--     C.white; trailing hint 0x888888 -> C.dim. Defense-pct bar has THREE
--     source tiers (pct>66 0x4444CC red, pct>33 0x2299CC orange, else
--     0x33AA33 green) but pagelib.C has no orange; folding the middle tier
--     into C.red (pagelib.pct_color's usual precedent) would collapse two
--     of the three tiers into the same color and lose the distinction this
--     bar exists to show. Disclosed departure: middle tier mapped to
--     C.yellow instead, preserving three visually distinct tiers
--     (red/yellow/green) even though the literal decode is red/orange/green.
--   - Great Houses: allies "marches with you" 0x44CC44 -> green -> C.green;
--     foes "marches against you" 0x4444FF -> red -> C.bright_red (matches
--     ranks.lua's Hostile/Feud precedent: enemy = red, no discrepancy).
--     "No houses committed" 0x888888 -> C.dim.
local pagelib = require("pagelib")
local state = require("state")
local page_opts = require("page_opts")
local cc = require("pages.city_common")

local S = state.S
local C = pagelib.C

local M = {}

-- ---------------------------------------------------------------------------
-- Campaign Map (guild_viking.lua:13620-14016, UNGATED -- war_map.active)
-- ---------------------------------------------------------------------------

-- Ported from LEGACY's inline march-ETA formatter (guild_viking.lua:
-- 13988-13992) -- distinct convention from cc.fmt_time (zero-padded minutes,
-- no seconds component once minutes are shown).
local function march_eta_text(secs)
  secs = secs or 0
  if secs >= 3600 then
    return string.format("%dh%02dm", math.floor(secs / 3600), math.floor((secs % 3600) / 60))
  elseif secs >= 60 then
    return string.format("%dm", math.floor(secs / 60))
  end
  return string.format("%ds", secs)
end

-- The MUD's own foe-glyph rule (campaign.h:1673): ids 1-9 render as digits,
-- 10 and up as a, b, c... A numeric id past 9 is two characters wide and
-- would be truncated to its first digit in a one-char map cell, colliding
-- with the foe of that digit.
local function foe_glyph(id)
  local n = tonumber(id)
  if not n then return tostring(id) end
  if n <= 9 then return tostring(n) end
  return string.char(87 + n)
end

local function campaign_map_lines(add, width, wm)
  local hdr = string.format("War Campaign: %s  --  turn %d", wm.town or "?", wm.turn or 0)
  if wm.mode == "defense" and (wm.works_budget or 0) > 0 then
    hdr = hdr .. string.format("  (works %d)", wm.works_budget)
  end
  add(pagelib.header(width, hdr))

  local dim = wm.dim or #(wm.rows or {})
  if dim < 1 or #(wm.rows or {}) < 1 then
    -- Say WHICH half is missing. "waiting for map data" was the same line for
    -- a campaign that had only just opened and for one whose terrain never
    -- arrived, and the two want different reactions from the reader.
    if #(wm.rows or {}) < 1 then
      add(pagelib.trunc(C.dim .. "(no terrain yet -- the map has not been drawn)"
          .. pagelib.RESET, width))
    else
      add(pagelib.trunc(C.dim .. "(waiting for map data...)" .. pagelib.RESET, width))
    end
    return
  end

  add(nil, "popups.war_campaign")

  -- The legend the text board prints under the map. Without it the pane showed
  -- a grid of glyphs and nothing that said what any of them were, what the war
  -- was for, or how it was going.
  do
    local foes, detach = {}, {}
    local host, ally, objective
    for _, u in ipairs(wm.units or {}) do
      if u.id == "A" then host = u
      elseif u.id == "*" then objective = u
      elseif u.kind == "ally" then ally = u
      elseif u.kind == "detach" then detach[#detach + 1] = u
      elseif u.kind == "foe" or (u.id and u.id ~= "" and u.id:sub(1, 1) ~= "P") then
        foes[#foes + 1] = u
      end
    end
    -- Numeric order, not string order: sorting the ids as text put 10 and 13
    -- between 1 and 2. The glyph follows the MUD's own rule (campaign.h:1673)
    -- -- 1-9 stay digits, 10+ become a, b, c... -- so the legend and the map
    -- agree, and a two-digit id can never be squeezed into a one-char cell.
    table.sort(foes, function(a, b)
      return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
    end)

    local goal
    if wm.mode == "offense" then
      goal = "storm " .. (wm.town or "?") .. " to take it"
    else
      goal = "throw the invader back from " .. (wm.town or "?")
    end
    add(pagelib.trunc(string.format(
      "%sObjective:%s break all %s%d%s enemy %s, then %s.",
      C.bright_cyan, pagelib.RESET, C.yellow, #foes, pagelib.RESET,
      (#foes == 1) and "army" or "armies", goal), width))
    add(pagelib.trunc(string.format("%sBattles won this campaign:%s %s%d%s",
      C.dim, pagelib.RESET, C.bright_green, wm.battles_won or 0, pagelib.RESET), width))

    if host then
      local objtxt = objective and ("   " .. C.yellow .. "*" .. pagelib.RESET
        .. C.dim .. " objective" .. pagelib.RESET) or ""
      add(pagelib.trunc(string.format("%sA%s %sYour host%s %s(%d)%s%s",
        C.bright_green, pagelib.RESET, C.bright_green, pagelib.RESET,
        C.yellow, host.size or 0, pagelib.RESET, objtxt), width))
    end
    for _, d in ipairs(detach) do
      add(pagelib.trunc(string.format("%s%s%s %sYour detachment%s %s(%d)%s",
        C.green, tostring(d.id), pagelib.RESET, C.green, pagelib.RESET,
        C.yellow, d.size or 0, pagelib.RESET), width))
    end
    if ally then
      add(pagelib.trunc(string.format("%s%s%s %sAlly%s %s(%d)%s",
        C.bright_cyan, tostring(ally.id), pagelib.RESET,
        C.bright_cyan, pagelib.RESET,
        C.yellow, ally.size or 0, pagelib.RESET), width))
    end
    -- Sizes line up in their own column so the roster can be read down rather
    -- than picked out of each sentence; the widest name sets the gutter.
    local name_w = 0
    for _, f in ipairs(foes) do
      local n = #cc.pcase((f.name and f.name ~= "") and f.name or "enemy army")
      if n > name_w then name_w = n end
    end
    if name_w > width - 14 then name_w = width - 14 end
    if name_w < 1 then name_w = 1 end

    for _, f in ipairs(foes) do
      local extra = ""
      if (f.shaken or 0) > 0 then
        extra = extra .. string.format(" %s[shaken x%d]%s", C.yellow, f.shaken, pagelib.RESET)
      end
      if objective and f.c == objective.c and f.r == objective.r then
        extra = extra .. string.format(" %s[objective]%s", C.bright_cyan, pagelib.RESET)
      end
      local nm = cc.pcase((f.name and f.name ~= "") and f.name or "enemy army")
      -- A holding ("the old fort at...", "the village of...") is a different
      -- kind of problem from a field army -- it sits still and has to be
      -- stormed -- so it reads in a different colour.
      local is_place = nm:sub(1, 4) == "the "
      add(pagelib.trunc(string.format("%s%s%s %s%s%s %s(%d)%s%s",
        C.bright_red, foe_glyph(f.id), pagelib.RESET,
        is_place and C.dim or C.white,
        nm .. string.rep(" ", math.max(0, name_w - #nm)), pagelib.RESET,
        C.yellow, f.size or 0, pagelib.RESET, extra), width))
    end
  end

  local hint
  if wm.pending and wm.pending ~= 0 then
    hint = "A battle awaits -- 'vcampaign fight'"
  elseif (wm.march_eta or 0) > 0 then
    hint = "On the march -- next tile in " .. march_eta_text(wm.march_eta)
  else
    hint = "Holding -- 'vcampaign move <sq>'"
  end
  add(pagelib.trunc(C.yellow .. hint .. pagelib.RESET, width))

  local up = wm.upkeep
  if up and (up.food or 0) > 0 then
    -- Each good in its own colour, the same cc.good_color() the goods and
    -- city pages use, so a commodity reads the same everywhere in the plugin.
    -- Daler is yellow, as it is on every other page.
    local function _good(n, g)
      return string.format("%s%d %s%s", cc.good_color(g), n or 0, g, pagelib.RESET)
    end
    add(pagelib.trunc(string.format("%sUpkeep/tile:%s %s  %s  %s  %s  %s%dd%s",
      C.dim, pagelib.RESET,
      _good(up.food, "food"), _good(up.mead, "mead"),
      _good(up.tools, "tools"), _good(up.iron, "iron"),
      C.yellow, up.daler or 0, pagelib.RESET), width))
  end

  local sp = wm.spoils
  if sp and ((sp.daler or 0) > 0 or (sp.deeds or 0) > 0) then
    add(pagelib.trunc(string.format(
      "%sSpoils if you win:%s %s%d daler%s, %s%d renown%s  %s(%d deed%s)%s",
      C.dim, pagelib.RESET,
      C.yellow, sp.daler or 0, pagelib.RESET,
      C.bright_cyan, sp.renown or 0, pagelib.RESET,
      C.green, sp.deeds or 0, (sp.deeds == 1) and "" or "s", pagelib.RESET), width))
  end
end

-- ---------------------------------------------------------------------------
-- War Captives (guild_viking.lua:14020-14058, UNGATED -- data-gated)
-- ---------------------------------------------------------------------------

-- Captive roster column widths. The name column is the only one that can
-- overflow, so its text is cut one short (ROSTER_NAME_W - 1) and a literal
-- space appended -- see the comment in the loop.
local ROSTER_ID_W, ROSTER_NAME_W = 5, 30
local ROSTER_SIZE_W, ROSTER_RANK_W, ROSTER_RANSOM_W = 6, 6, 9

local function prison_lines(add, width)
  local pr = S.prison
  -- Captives only. The siege park used to render here as well as on the Army
  -- page, which draws it in full (engines held, the forge queue with per-engine
  -- clocks, and the materials bill) -- the same three things this section was
  -- repeating. Gating on the park too meant a player with engines but no
  -- captives got an empty "War Captives  (0/0 held)" header, so that goes with
  -- it.
  local have_prison = pr and ((pr.held or 0) > 0 or (pr.kin or 0) > 0 or pr.pending or (pr.cap or 0) > 0)
  if not have_prison then return end

  add(pagelib.header(width, string.format("War Captives  (%d/%d held)", pr.held or 0, pr.cap or 0)))

  if pr.pending then
    add(pagelib.trunc(string.format(
      "%sAwaiting judgement: %s  (%d%s)  -- 'vprison take' / 'vprison kill'%s",
      C.yellow, pr.pend_name or "?", pr.pend_size or 0,
      pr.pend_cmd and ", commander" or "", pagelib.RESET), width))
  end

  -- Captive roster as fixed columns with a header. trunc() pads to EXACTLY
  -- the width it is given, so a name that fills its column leaves no gap and
  -- the size field abuts it ("the village of Haugnesx6" -- that name is
  -- exactly 22 cells). Every text cell is therefore truncated one short and
  -- given an explicit separator space. Names are title-cased, the rank reads
  -- "Cmdr" in its own column rather than as a trailing ", cmdr" that pushed
  -- the ransom around, and the ransom is right-aligned and comma-grouped so
  -- the figures stack.
  if #(pr.roster or {}) > 0 then
    add(pagelib.trunc("  " .. C.dim
      .. pagelib.trunc("#", ROSTER_ID_W)
      .. pagelib.trunc("Captive", ROSTER_NAME_W)
      .. pagelib.trunc("Size", ROSTER_SIZE_W)
      .. pagelib.trunc("Rank", ROSTER_RANK_W)
      .. "Ransom" .. pagelib.RESET, width))
  end
  for _, p in ipairs(pr.roster or {}) do
    local ransom = pagelib.fmt_num(p.val or 0) .. "d"
    add(pagelib.trunc(
      "  "
      .. C.dim .. pagelib.trunc(tostring(p.id or 0) .. ")", ROSTER_ID_W) .. pagelib.RESET
      .. (p.cmd and C.yellow or C.white)
      .. pagelib.trunc(cc.tcase(p.name or "?"), ROSTER_NAME_W - 1) .. pagelib.RESET .. " "
      .. C.dim .. pagelib.trunc("x" .. tostring(p.size or 0), ROSTER_SIZE_W) .. pagelib.RESET
      .. (p.cmd and (C.yellow .. pagelib.trunc("Cmdr", ROSTER_RANK_W) .. pagelib.RESET)
                 or string.rep(" ", ROSTER_RANK_W))
      .. C.bright_green .. pagelib.rjust(ransom, ROSTER_RANSOM_W) .. pagelib.RESET, width))
  end

  if (pr.kin or 0) > 0 then
    add(pagelib.trunc(string.format(
      "%sOur kin held by the foe: %d  -- 'vprison recover' / 'vprison exchange'%s",
      C.red, pr.kin, pagelib.RESET), width))
  end

end

-- ---------------------------------------------------------------------------
-- Battle (guild_viking.lua:14084-14603, gated show_war_battle)
-- ---------------------------------------------------------------------------

local function unit_line(width, size, label, color)
  return pagelib.trunc(string.format("  %s%dx %s%s", color, size or 0, cc.tcase(label or "?"),
    pagelib.RESET), width)
end

local function led_by_line(width, leader)
  return pagelib.trunc(string.format("    %sLed by %s%s%s", C.dim, C.white, leader, pagelib.RESET), width)
end

local function deploy_lines(add, width, b)
  local reserve = b.reserve or {}
  if #reserve > 0 then
    add(pagelib.trunc(C.yellow .. "In reserve  (vbattle deploy <id> <sq>)" .. pagelib.RESET, width))
    for _, u in ipairs(reserve) do
      add(pagelib.trunc(string.format("  %s[%d] %dx %s%s",
        C.bright_green, u.uid or 0, u.size or 0, cc.tcase(u.label or "?"), pagelib.RESET), width))
      add(pagelib.trunc(string.format("    %s%d pts%s", C.dim, u.cost or 0, pagelib.RESET), width))
      if u.leader then add(led_by_line(width, u.leader)) end
    end
  else
    add(pagelib.trunc(C.dim .. "All committed -- 'vbattle begin' to join." .. pagelib.RESET, width))
  end

  local placed = 0
  for _, u in ipairs(b.units or {}) do
    if u.side == "you" then
      if placed == 0 then
        add(pagelib.trunc(C.yellow .. "Deployed" .. pagelib.RESET, width))
      end
      placed = placed + 1
      add(unit_line(width, u.size, u.label, C.bright_green))
      add(pagelib.trunc(string.format("    %sPosition %s%s%s", C.dim, C.white, u.coord or "?",
        pagelib.RESET), width))
      if u.leader then add(led_by_line(width, u.leader)) end
    end
  end
end

-- Ported from LEGACY's mor_col (guild_viking.lua:14571-14573). The middle
-- tier's literal hex (0x00CCCC) decodes to YELLOW, not cyan -- see the
-- module header's flagged BGR note.
local function mor_col(m)
  m = m or 0
  if m >= 66 then return C.bright_green end
  if m >= 33 then return C.yellow end
  return C.bright_red
end

local function turn_side_lines(add, width, b, is_you, header, hcol, ncol)
  local shown = false
  for _, u in ipairs(b.units or {}) do
    if (u.side == "you") == is_you then
      if not shown then
        add(pagelib.trunc(hcol .. header .. pagelib.RESET, width))
        shown = true
      end
      add(unit_line(width, u.size, u.label, ncol))
      add(pagelib.trunc(string.format("    %sPosition %s%s%s   %sMorale %s%d%s",
        C.dim, C.white, u.coord or "?", pagelib.RESET,
        C.dim, mor_col(u.morale), u.morale or 0, pagelib.RESET), width))
      if u.leader then add(led_by_line(width, u.leader)) end
    end
  end
end

local function battle_lines(add, width)
  local b = S.battle
  if not b then
    add(pagelib.trunc(C.dim .. "No battle underway." .. pagelib.RESET, width))
    return
  end

  local deploying = (b.phase == "deploy")
  local mode_lbl = (b.mode or "field"):gsub("siege_attack", "siege"):gsub("siege_defend", "defence")
  if deploying then
    add(pagelib.header(width, string.format("Deploying vs %s  (%s)", b.target or "?", mode_lbl)))
  else
    add(pagelib.header(width, string.format("Battle vs %s  --  turn %d", b.target or "?", b.turn or 0)))
  end

  add(nil, "popups.war_battle")

  add(pagelib.trunc(string.format("%sCommand %d/%d%s",
    C.yellow, b.spent or 0, b.budget or 0, pagelib.RESET), width))

  if deploying then
    deploy_lines(add, width, b)
  else
    turn_side_lines(add, width, b, true, "Your host", C.yellow, C.bright_green)
    turn_side_lines(add, width, b, false, "Enemy", C.bright_red, C.red)
  end
end

-- ---------------------------------------------------------------------------
-- War Council (guild_viking.lua:14606-14624, gated show_war_council)
-- ---------------------------------------------------------------------------

local function council_lines(add, width)
  add(pagelib.header(width, "War Council"))
  local w = S.war
  if w and w.incoming then
    add(pagelib.trunc(string.format("%sUNDER THREAT: %s marches (host ~%d%%, ~%dd to answer)%s",
      C.bright_red, w.incoming.town, w.incoming.strength or 100, w.incoming.days or 0, pagelib.RESET),
      width))
  else
    add(pagelib.trunc(C.dim .. "No power marches on you." .. pagelib.RESET, width))
  end

  if w and w.claims and #w.claims > 0 then
    for _, c in ipairs(w.claims) do
      add(pagelib.trunc(string.format("%sClaim on %s  (lapses ~%dd)%s",
        C.white, c.town, c.days or 0, pagelib.RESET), width))
    end
  else
    add(pagelib.trunc(C.dim .. "No claims held (vwar fabricate <town>)." .. pagelib.RESET, width))
  end
end

-- ---------------------------------------------------------------------------
-- Campaigns (guild_viking.lua:14626-14647, gated show_war_campaigns)
-- ---------------------------------------------------------------------------

local function campaign_defense_color(pct)
  if pct > 66 then return C.red end
  -- Middle tier ("orange" in LEGACY) mapped to yellow, not red, to keep all
  -- three tiers visually distinct -- see the module header's disclosed note.
  if pct > 33 then return C.yellow end
  return C.green
end

local function campaigns_lines(add, width, w)
  add(pagelib.header(width, "Campaigns"))
  for _, c in ipairs(w.campaigns) do
    local mx = (c.max and c.max > 0) and c.max or 100
    local pct = math.floor((c.defense or 0) * 100 / mx)
    if pct < 0 then pct = 0 elseif pct > 100 then pct = 100 end
    -- pct readout (0xCCCCCC, grey either byte order) wrapped in C.white --
    -- see the module header's Campaigns workbook bullet, which already
    -- documented this as C.white; the code had left it unwrapped/plain.
    add(pagelib.trunc(string.format("%s%-16s%s %s %s%d%%%s",
      C.white, c.town, pagelib.RESET, pagelib.bar(20, pct, 100, campaign_defense_color(pct)),
      C.white, pct, pagelib.RESET), width))
  end
  add(pagelib.trunc(C.dim .. "Win sieges to break defence, then take the town." .. pagelib.RESET, width))
end

-- ---------------------------------------------------------------------------
-- Great Houses (guild_viking.lua:14649-14667, gated show_war_houses)
-- ---------------------------------------------------------------------------

local function houses_lines(add, width)
  add(pagelib.header(width, "Great Houses"))
  local dp = S.diplomacy
  local shown = 0
  if dp then
    for _, hh in ipairs(dp.allies or {}) do
      add(pagelib.trunc(string.format("%s%s (%d) marches with you%s",
        C.green, hh.house, hh.standing or 0, pagelib.RESET), width))
      shown = shown + 1
    end
    for _, hh in ipairs(dp.foes or {}) do
      add(pagelib.trunc(string.format("%s%s (%d) marches against you%s",
        C.bright_red, hh.house, hh.standing or 0, pagelib.RESET), width))
      shown = shown + 1
    end
  end
  if shown == 0 then
    add(pagelib.trunc(C.dim .. "No houses committed either way." .. pagelib.RESET, width))
  end
end

-- ---------------------------------------------------------------------------

function M.lines(width)
  width = width or 80
  local lines = {}
  local boards = {}
  local function add(s, board_name)
    if board_name then
      local mod = require(board_name)
      local rows, geom = mod.tile_grid(width)
      if geom and geom.width <= width then
        boards[#boards + 1] = { geometry=geom, offset=#lines, mod=mod }
        for _, row in ipairs(rows) do lines[#lines + 1] = row end
      else
        lines[#lines + 1] = pagelib.trunc("Map too wide -- /vik war", width)
      end
    else
      lines[#lines + 1] = s
    end
  end

  -- Fraegd first, before any section: it is a running total that
  -- handlers/kingdom.lua writes from every Guild.War frame, active or not,
  -- so it belongs in one fixed place rather than buried in whichever
  -- section happens to be showing.
  add(pagelib.trunc(string.format("%sFraegd: %d%s",
    C.bright_cyan, S.war_points or 0, pagelib.RESET), width))

  local wm = S.war_map
  if wm and wm.active then
    campaign_map_lines(add, width, wm)
  end

  prison_lines(add, width)

  if page_opts.get("show_war_battle") then
    battle_lines(add, width)
  end

  if page_opts.get("show_war_council") then
    council_lines(add, width)
  end

  local w = S.war
  if page_opts.get("show_war_campaigns") and w and w.campaigns and #w.campaigns > 0 then
    campaigns_lines(add, width, w)
  end

  if page_opts.get("show_war_houses") then
    houses_lines(add, width)
  end

  return lines, nil, boards
end

return M
