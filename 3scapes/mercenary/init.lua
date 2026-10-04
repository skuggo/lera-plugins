-- Mercenary plugin.
--
-- Reads the Merc.* GMCP namespace (five sub-packages, mudlib commit e28438b8d,
-- documented in doc/lfun/protocol_gmcp_merc). The MIP MRC handler this plugin
-- used to carry is gone: every one of its 23 fields has a GMCP counterpart
-- built from the same expression in mercenary_base.c, and GMCP additionally
-- guards a divide by zero on the target's max hp and falls back to "Edged" for
-- an unset damage type, both of which MIP gets wrong.

local M = {}
M.name = "mercenary"
M.version = "2.0"
M.priority = 50

local protocol = require("protocol")
local state = require("state")
local commands = require("command_ui")

local config = {
  auto_use_enabled = false,
  auto_use_ability = "none",
  auto_use_stamina_threshold = 80,
  auto_use_ap_threshold = 80,
  auto_use_cooldown_seconds = 4,
}

local valid_abilities = {
  "none", "bandage", "mend", "sustain", "fortify", "amplify",
  "critical", "frenzy", "rend", "combo", "aegis", "hamstring",
  "intervene", "cover",
}

local auto_use_last_time = 0

-- ---- helpers ---------------------------------------------------------------

local function get_percent_color(current, max)
  local amount = (current or 0) / (max or 100)
  if amount > 0.9 then return "19ff25"
  elseif amount > 0.75 then return "1e7523"
  elseif amount > 0.5 then return "f2e935"
  elseif amount > 0.25 then return "ab0000"
  else return "ff0000" end
end

local function format_number(num)
  if not num or num == 0 then return "0" end
  if num >= 1000000 then return string.format("%.1fM", num / 1000000) end
  if num >= 1000 then return string.format("%.1fK", num / 1000) end
  return tostring(num)
end

local function check_auto_use()
  if not config.auto_use_enabled or config.auto_use_ability == "none" then return end

  local s = state.get()
  -- A dormant mercenary cannot act. query_attack() is cleared on collapse so
  -- the target test below would catch it anyway, but relying on that couples
  -- this to a detail of the mudlib's dormancy path.
  if s.is_dormant then return end
  if not s.target or s.target == "None" or s.target == "" then return end

  local now = lera.time()
  if now - auto_use_last_time < config.auto_use_cooldown_seconds then return end

  if s.stamina_percent >= config.auto_use_stamina_threshold and
     s.ap_percent >= config.auto_use_ap_threshold then
    mud.send("merc use " .. config.auto_use_ability)
    auto_use_last_time = now
  end
end

-- ---- public API ------------------------------------------------------------

function M.get_stats() return state.snapshot() end
function M.has_data() return state.has_data() end

function M.merc_name() return state.get().name end

function M.hp() local s = state.get(); return s.hp_current, s.hp_max, s.hp_percent end
function M.hp_delta() return state.get().hp_delta end
function M.stamina() local s = state.get(); return s.stamina_current, s.stamina_max, s.stamina_percent end
function M.stamina_regen() return state.get().stamina_regen end
function M.stamina_delta() return state.get().stamina_delta end
function M.ap() local s = state.get(); return s.ap_current, s.ap_max, s.ap_percent end
function M.ap_regen() return state.get().ap_regen end
function M.ap_delta() return state.get().ap_delta end

function M.pl() local s = state.get(); return s.pl_level, s.pl_xp, s.pl_needed end
function M.pl_rate() return state.get().pl_xp_per_hour end
function M.il() local s = state.get(); return s.il_level, s.il_xp, s.il_needed end
function M.il_rate() return state.get().il_xp_per_hour end

function M.cost() return state.get().cost end
function M.damage_type() return state.get().damage_type end
function M.following() return state.get().following end
function M.fund() return state.get().fund end
function M.spent() return state.get().spent end
function M.target() local s = state.get(); return s.target, s.target_pct end
function M.abilities() return state.get().abilities end

function M.skills()
  local snap = state.snapshot()
  return snap.skills, snap.skills_meta
end

function M.talents()
  local snap = state.snapshot()
  return snap.talents, snap.talents_meta
end

function M.abilities_list()
  local inner = state.get().abilities:match("%[(.+)%]")
  if not inner then return {} end
  local list = {}
  for ability in inner:gmatch("[^,]+") do
    list[#list + 1] = ability:match("^%s*(.-)%s*$")
  end
  return list
end

function M.get_color(current, max) return get_percent_color(current, max) end
function M.target_color() return get_percent_color(state.get().target_pct, 100) end
function M.format_number(num) return format_number(num) end

function M.pl_time_to_level()
  local s = state.get()
  if s.pl_level >= s.pl_max_level then return nil end
  if s.pl_xp_per_hour <= 0 then return nil end
  return (s.pl_needed - s.pl_xp) / s.pl_xp_per_hour
end

function M.il_time_to_level()
  local s = state.get()
  if s.il_level >= s.il_max_level then return nil end
  if s.il_xp_per_hour <= 0 then return nil end
  return (s.il_needed - s.il_xp) / s.il_xp_per_hour
end

function M.reset_xp_tracking() state.reset_xp_tracking() end

function M.tracking_duration()
  local s = state.get()
  if s.tracking_start_time == 0 then return 0 end
  return lera.time() - s.tracking_start_time
end

-- ---- auto-use configuration ------------------------------------------------

function M.auto_use_enabled() return config.auto_use_enabled end
function M.set_auto_use_enabled(enabled) config.auto_use_enabled = enabled end
function M.toggle_auto_use()
  config.auto_use_enabled = not config.auto_use_enabled
  return config.auto_use_enabled
end
function M.auto_use_ability() return config.auto_use_ability end

function M.set_auto_use_ability(ability)
  for _, valid in ipairs(valid_abilities) do
    if ability == valid then
      config.auto_use_ability = ability
      return true
    end
  end
  return false
end

function M.list_auto_use_abilities() return valid_abilities end
function M.auto_use_stamina_threshold() return config.auto_use_stamina_threshold end

function M.set_auto_use_stamina_threshold(threshold)
  if threshold >= 0 and threshold <= 100 then
    config.auto_use_stamina_threshold = threshold
    return true
  end
  return false
end

function M.auto_use_ap_threshold() return config.auto_use_ap_threshold end

function M.set_auto_use_ap_threshold(threshold)
  if threshold >= 0 and threshold <= 100 then
    config.auto_use_ap_threshold = threshold
    return true
  end
  return false
end

function M.auto_use_cooldown() return config.auto_use_cooldown_seconds end

function M.set_auto_use_cooldown(seconds)
  if seconds >= 0 then
    config.auto_use_cooldown_seconds = seconds
    return true
  end
  return false
end

function M.get_auto_use_config()
  return {
    enabled = config.auto_use_enabled,
    ability = config.auto_use_ability,
    stamina_threshold = config.auto_use_stamina_threshold,
    ap_threshold = config.auto_use_ap_threshold,
    cooldown_seconds = config.auto_use_cooldown_seconds,
  }
end

-- ---- diagnostics for /merc status ------------------------------------------

function M.protocol_status()
  return {
    merc = protocol.merc_name(),
    counters = protocol.counters(),
    seen = {
      Vitals = protocol.seen("Vitals"), Info = protocol.seen("Info"),
      Stats = protocol.seen("Stats"), Skills = protocol.seen("Skills"),
      Talents = protocol.seen("Talents"),
    },
  }
end

-- ---- lifecycle -------------------------------------------------------------

function M.on_load()
  store.load()
  local data = store.get()
  if data then
    if data.auto_use_enabled ~= nil then config.auto_use_enabled = data.auto_use_enabled end
    if data.auto_use_ability then M.set_auto_use_ability(data.auto_use_ability) end
    if data.auto_use_stamina_threshold then
      config.auto_use_stamina_threshold = data.auto_use_stamina_threshold
    end
    if data.auto_use_ap_threshold then
      config.auto_use_ap_threshold = data.auto_use_ap_threshold
    end
    if data.auto_use_cooldown_seconds then config.auto_use_cooldown_seconds = data.auto_use_cooldown_seconds end
  end
  -- No output gags. The MUD's three-line status bar used to be hidden here
  -- by triggers, which kept breaking as fmt_lib wrapped the bar mid-token
  -- (and again whenever an ability suffix moved the wrap). The bar has an
  -- in-game switch -- 'merc sethpbar off' -- so a player who has the GMCP
  -- pane simply turns the text off at the source.

  protocol.on_apply(function(sub, mirror, merc, switched)
    state.apply(sub, mirror, merc, switched)
    -- Vitals is the per-tick package and carries every field the thresholds
    -- read, so this is the same cadence auto-use had under MIP.
    if sub == "Vitals" then check_auto_use() end
  end)
  protocol.subscribe()
  commands.install(M)
end

function M.on_disconnect()
  -- The server clears its whole namespace cache on disconnect
  -- (gmcp_clear_core_state), so retained mirrors would no longer be congruent
  -- with it. Both sides start clean and the next connection re-snapshots.
  protocol.reset_connection()
  state.reset()
end

function M.on_unload()
  commands.uninstall()
  protocol.unsubscribe()
  store.set({
    auto_use_enabled = config.auto_use_enabled,
    auto_use_ability = config.auto_use_ability,
    auto_use_stamina_threshold = config.auto_use_stamina_threshold,
    auto_use_ap_threshold = config.auto_use_ap_threshold,
    auto_use_cooldown_seconds = config.auto_use_cooldown_seconds,
  })
  store.save()
end

return M
