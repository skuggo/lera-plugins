-- /merc rendering. Named command_ui rather than command because `command` is a
-- sandbox whitelist name that resolves to the registry API.

local M = {}

local state = require("state")
local protocol = require("protocol")

local command_id = nil
local api = nil

local function line(text) buffer.color_print(nil, nil, text) end
local function head(text) buffer.color_print(nil, "FFAA00", text) end
local function warn(text) buffer.color_print(nil, 1, text) end

-- Progress bars, ported from mercenary_stats.xml's DrawBar (:438-449). LEGACY
-- drew a filled rectangle; the text equivalent is a two-tone run, which
-- buffer.color_print supports directly -- it takes REPEATED (bg, fg, text)
-- triplets, so the filled and empty halves land on one line rather than two.
--
-- Colours are LEGACY's, decoded from MUSHclient BGR (0xBBGGRR) to the RRGGBB
-- strings color_print wants:
--   COLOR_PL 0x00FFFF -> R=FF G=FF B=00 -> yellow "FFFF00"
--   COLOR_IL 0xFFFF00 -> R=00 G=FF B=FF -> cyan   "00FFFF"
local BAR_W = 20
local DIM = "444444"

local function bar_cells(cur, max)
  if not max or max <= 0 then return 0 end
  local n = math.floor((cur / max) * BAR_W)
  if n < 0 then n = 0 end
  if n > BAR_W then n = BAR_W end
  return n
end

-- label  value [pct%] [########------] cur/max  rate
--
-- `ratio_text` is separate from cur/max because a capped level draws a FULL
-- bar but prints "0/0" (LEGACY :599-601): the fill and the printed ratio
-- genuinely disagree there, so one pair of numbers cannot drive both.
local function bar_line(label, cur, max, hex, value_text, tail, ratio_text)
  local n = bar_cells(cur, max)
  buffer.color_print(
    nil, hex,  string.format("%-4s%12s ", label, value_text or ""),
    nil, DIM,  "[",
    nil, hex,  string.rep("#", n),
    nil, DIM,  string.rep("-", BAR_W - n) .. "] ",
    nil, hex,  ratio_text or string.format("%s/%s", tostring(cur), tostring(max)),
    nil, DIM,  tail and ("  " .. tail) or "")
end

local function fmt_seconds(secs)
  local m = math.floor(secs / 60)
  return string.format("%d:%02d", m, secs - m * 60)
end

-- Arrival times are recorded as lera.time() epochs. An epoch is not something a
-- reader can do anything with; "42s ago" answers the question /merc status is
-- being asked, which is whether a package is still arriving.
local function ago(at)
  local delta = lera.time() - at
  if delta < 0 then delta = 0 end
  if delta < 60 then return string.format("%ds ago", delta) end
  return fmt_seconds(delta) .. " ago"
end

local function show_summary()
  if not state.has_data() then
    warn("[merc] no mercenary data this connection")
    return
  end
  local s = state.get()
  head(s.name .. "  (" .. s.class .. "/" .. s.theme .. ", " .. s.status_name .. ")")
  if s.is_dormant then
    warn("DORMANT - recovering, " .. fmt_seconds(s.dormant) .. " remaining")
  elseif s.target ~= "" and s.target ~= "None" then
    line(string.format("Target: %s (%d%%)", s.target, s.target_pct))
  end
  -- HP/Stamina/AP and the two XP tracks all get bars, matching which stats
  -- LEGACY drew bars for (mercenary_stats.xml:505/521/536 and :607/646).
  bar_line("HP", s.hp_current, s.hp_max, "FF4444",
           string.format("%d%%", s.hp_percent))
  bar_line("ST", s.stamina_current, s.stamina_max, "44FF44",
           string.format("+%d", s.stamina_regen))
  bar_line("AP", s.ap_current, s.ap_max, "44AAFF",
           string.format("+%d", s.ap_regen))

  -- At max level LEGACY shows a full bar and 0/0 rather than a stale ratio
  -- (:599-601 for PL, :638-640 for IL).
  local pl_capped = s.pl_level >= s.pl_max_level
  bar_line("PL", pl_capped and 1 or s.pl_xp, pl_capped and 1 or s.pl_needed, "FFFF00",
           string.format("%d [%.1f%%]", s.pl_level,
             pl_capped and 100 or ((s.pl_needed > 0) and (s.pl_xp / s.pl_needed * 100) or 0)),
           (not pl_capped and s.pl_xp_per_hour > 0)
             and string.format("%.0f/hr", s.pl_xp_per_hour) or nil,
           pl_capped and "0/0" or nil)

  local il_capped = s.il_level >= s.il_max_level
  bar_line("IL", il_capped and 1 or s.il_xp, il_capped and 1 or s.il_needed, "00FFFF",
           string.format("%d [%.1f%%]", s.il_level,
             il_capped and 100 or ((s.il_needed > 0) and (s.il_xp / s.il_needed * 100) or 0)),
           (not il_capped and s.il_xp_per_hour > 0)
             and string.format("%.0f/hr", s.il_xp_per_hour) or nil,
           il_capped and "0/0" or nil)

  line(string.format("Effective level %d", s.eff_level))
  line(string.format("Cost %d/round  %s  %s   fund %d  spent %d (boot %d, skills %d, spec %d)",
    s.cost, s.damage_type, s.following and "following" or "not following",
    s.fund, s.spent, s.spent_boot, s.spent_skills, s.spent_spec))
  line(string.format("Session: %d rounds, %d dealt, %d taken, %d healed, %d abilities",
    s.rounds, s.dmg_out, s.dmg_in, s.healing, s.abilities_used))
  line(string.format("Lifetime: %d rounds, %d dealt, %d taken, %d healed, %d abilities",
    s.life_rounds, s.life_dmg_out, s.life_dmg_in, s.life_healing, s.life_abilities))
end

-- Skills and Talents push only on daemon registration, on allocation and on a
-- level-up; heart_beat() has no reconnect trigger. A link drop short enough
-- that neither a heart_beat nor a registration observes it delivers no slow
-- package at all until the next allocation, and there is no client-side way to
-- ask for one. Saying so beats rendering zeroes that look like real data.
local function slow_missing(sub)
  if protocol.seen(sub) then return false end
  warn("[merc] no Merc." .. sub .. " received this connection.")
  warn("       These push only on hire/summon, an allocation or a level-up.")
  return true
end

local function show_records(sub, records, meta, fields, label)
  if slow_missing(sub) then return end
  local names = {}
  for name in pairs(records) do names[#names + 1] = name end
  table.sort(names)
  if #names == 0 then
    warn("[merc] no " .. label .. " recorded")
    return
  end
  head(label .. " - " .. meta.points .. " points available, " ..
       meta.allocs .. " allocated, next costs " .. meta.next_cost)
  for _, name in ipairs(names) do
    local r = records[name]
    local parts = {}
    for _, f in ipairs(fields) do
      parts[#parts + 1] = f .. " " .. tostring(r[f] or 0)
    end
    line(string.format("  %-16s %s", name, table.concat(parts, "  ")))
  end
end

local function show_status()
  local st = api.protocol_status()
  head("Merc.* protocol status")
  line("  attributed to: " .. tostring(st.merc or "(nothing received)"))
  local c = st.counters
  line(string.format("  frames %d, applied %d", c.frames, c.applied))
  line(string.format(
    "  dropped: %d bad package, %d bad payload, %d bad attribution, %d bad page",
    c.bad_package, c.bad_payload, c.bad_attribution, c.bad_page))
  for _, sub in ipairs({ "Vitals", "Info", "Stats", "Skills", "Talents" }) do
    local at = st.seen[sub]
    line(string.format("  %-8s %s", sub,
      at and ago(at) or "not received this connection"))
  end
end

local function show_auto_use()
  local c = api.get_auto_use_config()
  head("Auto-use " .. (c.enabled and "ON" or "off"))
  line(string.format("ability=%s  stam>=%d%%  ap>=%d%%  cooldown=%ss",
    c.ability, c.stamina_threshold, c.ap_threshold, c.cooldown_seconds))
end

local function show_help()
  head("Mercenary commands")
  line("/merc                         Show mercenary summary")
  line("/merc skills | talents | status")
  line("/merc auto on|off")
  line("/merc auto ability <name>     none, bandage, mend, sustain, fortify, amplify,")
  line("                               critical, frenzy, rend, combo, aegis, hamstring,")
  line("                               intervene, cover")
  line("/merc auto stam|ap <0-100>    Set required resource percentages")
  line("/merc auto cooldown <seconds>")
  show_auto_use()
end

local function dispatch(args)
  local sub, rest = tostring(args or ""):match("^%s*(%S*)%s*(.-)%s*$")
  sub, rest = (sub or ""):lower(), rest or ""

  if sub == "" then
    show_summary()
    show_help()
  elseif sub == "skills" then
    local records, meta = api.skills()
    show_records("Skills", records, meta, { "raw", "eff" }, "Skills")
  elseif sub == "talents" then
    local records, meta = api.talents()
    show_records("Talents", records, meta, { "points", "eff", "min_level" }, "Talents")
  elseif sub == "status" then
    show_status()
  elseif sub == "auto" then
    local action, value = rest:match("^(%S*)%s*(.-)%s*$")
    action, value = (action or ""):lower(), value or ""
    if action == "" then
      show_auto_use()
    elseif action == "on" or action == "off" then
      api.set_auto_use_enabled(action == "on")
      show_auto_use()
    elseif action == "ability" then
      value = value:lower()
      if not api.set_auto_use_ability(value) then
        warn("Unknown mercenary ability: " .. (value ~= "" and value or "(none)"))
        return
      end
      show_auto_use()
    elseif action == "stam" or action == "ap" or action == "cooldown" then
      local number = tonumber(value)
      local ok
      if action == "stam" then ok = number and api.set_auto_use_stamina_threshold(number)
      elseif action == "ap" then ok = number and api.set_auto_use_ap_threshold(number)
      else ok = number and api.set_auto_use_cooldown(number) end
      if not ok then
        local range = action == "cooldown" and "a non-negative number" or "a number from 0 to 100"
        warn("/merc auto " .. action .. " requires " .. range)
        return
      end
      show_auto_use()
    else
      warn("Usage: /merc auto [on|off|ability <name>|stam <0-100>|ap <0-100>|cooldown <seconds>]")
    end
  else
    warn("Usage: /merc [skills|talents|status|auto ...]")
  end
end

function M.install(plugin_api)
  api = plugin_api
  local command = require("command")
  local id, err = command.register({
    name = "/merc",
    usage = "/merc [skills | talents | status | auto ...]",
    summary = "Mercenary state from the Merc.* GMCP namespace",
    description = "Shows the active mercenary's vitals, progression and "
      .. "economy. 'skills' lists trained skill points raw and effective, "
      .. "'talents' the ability specializations, and 'status' reports which "
      .. "Merc.* packages have arrived this connection. Omit can hide or show the three legacy status lines, and auto configures automatic ability use.",
    accepts_args = true,
    handler = function(args) dispatch(args) end,
  })
  if id then
    command_id = id
  else
    print("[mercenary] command registration failed: " .. tostring(err))
  end
end

function M.uninstall()
  if not command_id then return end
  local command = require("command")
  command.unregister(command_id)
  command_id = nil
end

return M
