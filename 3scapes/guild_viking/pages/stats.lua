-- Stats page: LEGACY's inline "---- Page 1: Stats ----" block
-- (/home/simon/code/3s_scripts_old/lua/guild_viking.lua:7137-7394). Pure
-- builder: lines(width) -> array of ANSI strings, reading state.lua's S and
-- page_opts.lua only (no ui.* calls, no mutation, per the plan's page-purity
-- constraint).
--
-- Section order mirrors the LEGACY draw order top-to-bottom: daler, the
-- "Change" delta box (HP/Threk/Seid/Vig/Rad/Fury bars), Ledung, Chain/BSDepth,
-- the active-god quick view, Saga XP (gated show_stats_xp), then Active
-- Effects/STFX (gated show_stats_buffs). One section beyond that literal
-- window -- an Enemy block (en5/ens/rndz/estatus_pct/mob_name_full) -- is
-- added per the stage-2 task brief: LEGACY only ever printed those fields to
-- the scrolling console (guild_viking.lua:655-657, 881-886), never into the
-- Page 1 window itself, but the pane is the natural home for that summary
-- now that it exists, and the fields are already tracked in state.lua.
--
-- A second lera-only section, Automation (gated show_stats_automation,
-- default true), is appended at the very end (Task 9, stage 4's integration
-- pass): a compact on/off + last-action line per client-side automation
-- (auto-trade/auto-raid/auto-voyage). LEGACY has no such pane section --
-- its own three settings mini-windows show configuration, not a running
-- status summary, and this port's /vik status command is the fuller
-- counterpart. Same "disclosed lera addition" disposition as the Enemy
-- block above. Pure read: no ui.* calls, no state mutation, no mud.send --
-- see this file's own module comment at the top for the page-purity
-- constraint this section is held to exactly like every other one here.
local pagelib = require("pagelib")
local state = require("state")
local page_opts = require("page_opts")
local combat = require("combat")

local S = state.S
local C = pagelib.C

local M = {}

-- Ported from LEGACY's fmt_time (guild_viking.lua:7431-7448): used here only
-- for the god-power "Next:" readout.
local function fmt_time(secs)
  secs = secs or 0
  if secs <= 0 then return "ready" end
  if secs < 60 then return secs .. "s" end
  if secs < 86400 then
    if secs < 3600 then
      local m = math.floor(secs / 60)
      local s = secs % 60
      return s > 0 and (m .. "m" .. s .. "s") or (m .. "m")
    end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    return m > 0 and (h .. "h" .. m .. "m") or (h .. "h")
  end
  local d = math.floor(secs / 86400)
  local h = math.floor((secs % 86400) / 3600)
  return h > 0 and (d .. "d" .. h .. "h") or (d .. "d")
end

-- Ported from LEGACY's inline session-elapsed formatting
-- (guild_viking.lua:7292-7301): distinct from fmt_time above (different
-- thresholds/format -- "Session: Xs"/"Session: XmYs"/"Session: XhYm").
local function fmt_session(elapsed)
  if elapsed < 60 then
    return string.format("Session: %ds", elapsed)
  elseif elapsed < 3600 then
    local m, s = math.floor(elapsed / 60), elapsed % 60
    return s > 0 and string.format("Session: %dm%ds", m, s) or string.format("Session: %dm", m)
  end
  local h = math.floor(elapsed / 3600)
  local m = math.floor((elapsed % 3600) / 60)
  return m > 0 and string.format("Session: %dh%dm", h, m) or string.format("Session: %dh", h)
end

-- BGR decode workbook (guild_viking.lua:301, 0xBBGGRR -- leftmost byte =
-- Blue, middle = Green, rightmost = Red; same convention/precedent as
-- pages/goods.lua's commit 9b6b7b6 workbook and pages/army.lua's comment):
--   0x4444FF (delta_text loss, below)      -> R=FF/G=44/B=44 -> red
--   0x00CCCC (Daler, line ~97)             -> R=CC/G=CC/B=00 -> yellow
--   0x0088FF (Fury bar fill, line ~121)    -> R=FF/G=88/B=00 -> orange, folded
--                                              to red (pagelib.pct_color's own
--                                              orange-tier precedent)
--   0x4488FF (Ledung bar fill, line ~133)  -> R=FF/G=88/B=44 -> orange, folded
--                                              to red (same precedent)
-- Each was previously mapped by variable-name guess (cyan/bright_cyan) rather
-- than decoded; corrected below.

-- LEGACY 7172-7176 (delta_text): "+N"/"-N" after a bar row; green for a
-- gain, red for a loss (0x4444FF, see the workbook above), nothing when
-- unchanged.
local function delta_text(val)
  if not val or val == 0 then return "" end
  local color = val > 0 and C.bright_green or C.red
  return " " .. color .. string.format("%+d", val) .. pagelib.RESET
end

-- One HP/Threk/Seid/Vig/Rad/Fury bar row: "Label  [####----] cur/max +delta".
local function bar_row(width, label, val, max, delta, color)
  local row = string.format("%-7s%s %d/%d%s",
    label, pagelib.bar(20, val, max, color), val, max, delta_text(delta))
  return pagelib.trunc(row, width)
end

-- Grouped colors for the Active Effects section, keyed by combat.lua's
-- exported STFX_CAT_ORDER categories. See combat.lua's comment on
-- STFX_CAT_ORDER/STFX_CAT_LABELS for why the LEGACY hex colors aren't
-- reused verbatim.
local STFX_CAT_ANSI = {
  Def  = C.cyan,
  Heal = C.green,
  Off  = C.magenta,
  Pwr  = C.bright_red,
  DoT  = C.red,
}

-- Task 9 Automation section accessors. Deferred (not required at this
-- module's own top level): pages/stats.lua is itself required from
-- window.lua's OWN top-level require chain (window.lua:61, BEFORE window.lua
-- returns). autotrader.tick.lua and autovoyage.lua both require("persist")
-- at THEIR top level, and persist.lua requires("window") at ITS top level --
-- a top-level require here would re-enter window.lua while it is still
-- mid-load, the exact cycle shape autoraid.lua's own module header discloses
-- (window -> pages.city -> autoraid -> persist -> window) and mitigates the
-- same way. Calling require() from inside a function instead defers it
-- until the first actual render, long after every module has finished
-- loading.
local function trade_status()
  return require("autotrader.tick").status()
end
local function raid_settings()
  return require("autoraid").settings()
end
local function voyage_settings()
  return require("autovoyage").settings()
end
local function herd_settings()
  return require("autoherd").settings()
end

function M.lines(width)
  width = width or 80
  local lines = {}
  local function add(s) lines[#lines + 1] = s end

  -- ---- Daler treasury (7154-7159) -------------------------------------
  if S.daler and S.daler >= 0 then
    add(pagelib.kv(width, "Daler:", pagelib.fmt_num(S.daler), C.yellow))
  end

  -- ---- Vitals: HP/Threk/Seid/Vig/Rad/Fury bars (7161-7231) ------------
  add(pagelib.header(width, "Vitals"))
  add(bar_row(width, "HP:", S.hp, S.mhp, S.hp_delta, pagelib.pct_color(S.hp, S.mhp)))
  -- Threk is a pending-damage pool, not a resource to keep full: red while
  -- building up, green when empty (7188).
  add(bar_row(width, "Threk:", S.threk, math.max(S.mthrek, 1), S.threk_delta,
    S.threk > 0 and C.red or C.bright_green))
  add(bar_row(width, "Seid:", S.seid, math.max(S.mseid, 1), S.seid_delta,
    pagelib.pct_color(S.seid, S.mseid)))
  add(bar_row(width, "Vig:", S.vig, math.max(S.mvig, 1), S.vig_delta,
    pagelib.pct_color(S.vig, S.mvig)))
  add(bar_row(width, "Rad:", S.rad, math.max(S.mrad, 1), S.rad_delta,
    pagelib.pct_color(S.rad, S.mrad)))

  -- Fury. Two sources, and they disagree on shape.
  --
  -- Guild.State sends points.fury/mfury as integers, which is what this row
  -- actually wants, so they win when present. Otherwise fall back to LEGACY's
  -- own derivation (7223-7231) from the rendered "[***-------]" token the
  -- hp-bar trigger scrapes: count '*' against the total inner width. That
  -- fallback is lossy by construction -- it can only ever report a maximum
  -- equal to however many cells the bar was drawn with -- which is why the
  -- integers are preferred rather than merely accepted.
  --
  -- The test is `fury_max ~= nil`, not truthiness: a maximum of 0 is a real
  -- state (no fury capacity yet) and must not fall through to the string.
  do
    local fury_filled, fury_total
    if S.fury_max ~= nil then
      fury_filled, fury_total = S.fury_cur or 0, S.fury_max
    else
      local fury_raw = (S.fury and S.fury ~= "") and S.fury or "[----------]"
      local fury_inner = fury_raw:match("^%[(.-)%]$") or fury_raw
      fury_filled = select(2, fury_inner:gsub("%*", ""))
      fury_total = #fury_inner
    end
    add(bar_row(width, "Fury:", fury_filled, fury_total > 0 and fury_total or 1, nil, C.red))
  end

  -- ---- Ledung / Chain / BSDepth (7233-7256) ---------------------------
  add(pagelib.header(width, "Ledung / Chain"))
  local ldng_val
  if S.lrst and S.lrst > 0 then
    ldng_val = string.format("%d/%d (+%d%%)", S.ldng, S.mldng, S.lrst)
  else
    ldng_val = string.format("%d/%d", S.ldng, S.mldng)
  end
  add(pagelib.trunc(
    string.format("%-7s%s %s", "Ledng:", pagelib.bar(20, S.ldng, S.mldng > 0 and S.mldng or 1, C.red), ldng_val),
    width))
  add(pagelib.trunc(string.format("Chain:%d  BSDp:%d", S.chain or 0, S.bsdepth or 0), width))

  -- ---- Active god quick view (7258-7283) ------------------------------
  do
    local has_god = S.god_power_name and S.god_power_name ~= ""
    local gname = has_god and S.god_power_name or "--"
    local gtxt
    if S.god_power_next and S.god_power_next > 0 then
      gtxt = fmt_time(S.god_power_next)
    elseif has_god then
      gtxt = "now"
    else
      gtxt = "--"
    end
    add(pagelib.header(width, "God"))
    add(pagelib.trunc(string.format("God: %s   Next: %s", gname, gtxt), width))
  end

  -- ---- Saga XP (7285-7347, gated show_stats_xp) -----------------------
  if page_opts.get("show_stats_xp") then
    add(pagelib.header(width, "Saga XP"))
    if S.xp_session_start then
      local elapsed = os.time() - S.xp_session_start
      add(pagelib.trunc(fmt_session(elapsed), width))
    end

    -- One hue per track so the four are distinguishable at a glance -- the
    -- whole block rendered flat before, which made a wall of near-identical
    -- numbers. A gain is the part worth noticing, so it is the brightest
    -- thing on the row; the label carries the track's colour and the total
    -- stays white so the figure itself never fights the hue for attention.
    local half = math.floor(width / 2)
    local xp_data = {
      { label = "Vis:", val = S.vis, gain = S.vis_gain, col = C.cyan },
      { label = "Kap:", val = S.kap, gain = S.kap_gain, col = C.yellow },
      { label = "Soe:", val = S.soe, gain = S.soe_gain, col = C.magenta },
      { label = "Aud:", val = S.aud, gain = S.aud_gain, col = C.green },
    }
    for i = 1, #xp_data, 2 do
      local function cell(d)
        local s = d.col .. d.label .. pagelib.RESET
          .. C.white .. pagelib.fmt_num(d.val or 0) .. pagelib.RESET
        if d.gain and d.gain > 0 then
          s = s .. C.bright_green .. string.format(" (+%s)",
                pagelib.fmt_num(d.gain)) .. pagelib.RESET
        end
        return s
      end
      local left = pagelib.trunc(cell(xp_data[i]), half)
      local right = xp_data[i + 1] and cell(xp_data[i + 1]) or ""
      add(pagelib.trunc(left .. " " .. right, width))
    end

    add(pagelib.trunc(C.dim .. "Session gained:" .. pagelib.RESET, width))
    -- Same hues as the totals above, so a track keeps its colour between the
    -- two blocks. Session figures are themselves gains, hence bright green.
    local sess_data = {
      { label = "Vis:", val = S.vis_session, col = C.cyan },
      { label = "Kap:", val = S.kap_session, col = C.yellow },
      { label = "Soe:", val = S.soe_session, col = C.magenta },
      { label = "Aud:", val = S.aud_session, col = C.green },
    }
    local function scell(d)
      if not d then return "" end
      return d.col .. d.label .. pagelib.RESET
        .. ((d.val or 0) > 0 and C.bright_green or C.dim)
        .. pagelib.fmt_num(d.val or 0) .. pagelib.RESET
    end
    for i = 1, #sess_data, 2 do
      add(pagelib.trunc(pagelib.trunc(scell(sess_data[i]), half)
        .. " " .. scell(sess_data[i + 1]), width))
    end
  end

  -- ---- Enemy (see module comment: not a literal Page-1 window section, --
  -- added per the stage-2 brief since the fields exist and have no other --
  -- home in the pane yet) ------------------------------------------------
  add(pagelib.header(width, "Enemy"))
  local enemy_name = (S.mob_name_full and S.mob_name_full ~= "None") and S.mob_name_full
    or ((S.en5 and S.en5 ~= "None") and S.en5 or "None")
  add(pagelib.kv(width, "Target:", enemy_name, S.combat and C.bright_red or C.dim))
  -- "En:" is dropped: S.en5 is the wire's five-character truncation of the
  -- same mob the Target line above already names in full ("Growi" for "a
  -- growing mutated cur"), so it was a worse copy of the line directly above
  -- it.
  --
  -- Both remaining health figures are coloured with pagelib.pct_color, the
  -- same green-to-red ramp the rest of the pane uses for a health reading.
  -- Not inverted to "green means nearly dead": a health percentage reads as a
  -- health bar everywhere else in this plugin, and making this one alone run
  -- the other way would be a trap at a glance mid-fight.
  do
    local ens = (S.ens and S.ens ~= "") and S.ens or "-"
    -- The wire's status text is usually a percentage ("8%"); colour it on that
    -- number when there is one and leave any non-numeric status neutral.
    local ens_pct = tonumber(tostring(ens):match("^(%d+)"))
    local ens_col = ens_pct and pagelib.pct_color(ens_pct) or C.white
    local est = S.estatus_pct or 0
    add(pagelib.trunc(
      C.dim .. "Status:" .. pagelib.RESET .. ens_col .. ens .. pagelib.RESET
      .. "  " .. C.dim .. "Rounds:" .. pagelib.RESET
      .. C.white .. tostring(S.rndz or 0) .. pagelib.RESET
      .. "  " .. C.dim .. "Est:" .. pagelib.RESET
      .. pagelib.pct_color(est) .. est .. "%" .. pagelib.RESET,
      width))
  end

  -- ---- Active effects / STFX (7349-7382, gated show_stats_buffs) ------
  if S.stfx and #S.stfx > 0 and page_opts.get("show_stats_buffs") then
    add(pagelib.header(width, "Active Effects"))
    local by_cat = {}
    -- Grouping reads fx.cat directly rather than re-deriving it from
    -- combat.lua's (currently private) STFX_META -- safe only because
    -- S.stfx is rebuilt fresh from the wire by combat.lua on every FFF
    -- composite and is never persisted (see persist.lua's module comment:
    -- only price_history/source/page_opts/page survive a save/load, combat
    -- state deliberately does not). If S.stfx ever starts round-tripping
    -- through the store, re-derive cat from STFX_META (exporting it if
    -- needed) instead of trusting a stale fx.cat loaded from disk.
    for _, fx in ipairs(S.stfx) do
      local cat = fx.cat or "DoT"
      by_cat[cat] = by_cat[cat] or {}
      by_cat[cat][#by_cat[cat] + 1] = fx
    end
    for _, cat in ipairs(combat.STFX_CAT_ORDER) do
      local fxlist = by_cat[cat]
      if fxlist and #fxlist > 0 then
        local parts = {}
        for _, fx in ipairs(fxlist) do
          parts[#parts + 1] = string.format("%s:%s", fx.name, fx.val)
        end
        add(pagelib.kv(width, combat.STFX_CAT_LABELS[cat] .. ":",
          table.concat(parts, "  "), STFX_CAT_ANSI[cat]))
      end
    end
  end

  -- ---- Automation (lera-only, gated show_stats_automation) -- see the -----
  -- module comment above for the disclosure and the deferred-require note.
  if page_opts.get("show_stats_automation") then
    add(pagelib.header(width, "Automation"))

    local trade_phase, trade_pending = trade_status()
    local trade_on = page_opts.get("auto_trade")
    add(pagelib.kv(width, "Auto-Trade:",
      string.format("%s (phase=%s pending=%d)", trade_on and "ON" or "off",
        trade_phase, trade_pending),
      trade_on and C.bright_green or C.dim))

    local ar = raid_settings()
    local raid_on = page_opts.get("auto_raid")
    local raid_last = "none"
    if ar.last_dispatch then
      raid_last = string.format("%d ship%s -> %s", ar.last_dispatch.n,
        ar.last_dispatch.n == 1 and "" or "s", ar.last_dispatch.target)
    end
    add(pagelib.kv(width, "Auto-Raid:",
      string.format("%s (last: %s)", raid_on and "ON" or "off", raid_last),
      raid_on and C.bright_green or C.dim))

    local av = voyage_settings()
    local voyage_on = page_opts.get("auto_voyage")
    local voyage_last = (av.log and #av.log > 0) and av.log[#av.log] or "none"
    add(pagelib.kv(width, "Auto-Voyage:",
      string.format("%s (last: %s)", voyage_on and "ON" or "off", voyage_last),
      voyage_on and C.bright_green or C.dim))

    -- Auto-Herd, mirroring the three rows above. Its log entries are
    -- { t = "HH:MM", desc = ... } records rather than Auto-Voyage's plain
    -- strings, hence the join. It is the one automation that SPENDS the
    -- player's daler and was the one missing from both status surfaces.
    local ah = herd_settings()
    local herd_on = page_opts.get("auto_herd")
    local herd_last = "none"
    if ah.log and #ah.log > 0 then
      local e = ah.log[#ah.log]
      herd_last = tostring(e.t or "") .. " " .. tostring(e.desc or "")
    end
    add(pagelib.kv(width, "Auto-Herd:",
      string.format("%s (last: %s)", herd_on and "ON" or "off", herd_last),
      herd_on and C.bright_green or C.dim))
  end

  return lines
end

return M
