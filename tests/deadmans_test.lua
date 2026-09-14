-- deadmans unit tests. Run from the lera-plugins repo root with LERA_ROOT
-- pointing at a built Lera checkout.
--
-- The subcommand parsing used to live in alias regexes ("^deadmans\s+warning
-- \s+(\d+)$"); it is hand-written Lua now, so the argument validation is what
-- these cases are really about.
package.path = "generic/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
  if ok then
    print("CASE " .. name .. ": PASS")
  else
    failures = failures + 1
    print("CASE " .. name .. ": FAIL" .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

-- ---- stubs ------------------------------------------------------------------
local stored_data = nil
local saves = 0
store = {
  load = function() end,
  get = function() return stored_data end,
  set = function(d) stored_data = d end,
  save = function() saves = saves + 1 end,
}

local now = 1000
lera = {
  time = function() return now end,
  dirty = function() end,
}

-- The one-second tick is where the push transitions are detected, so the test
-- has to be able to drive it by hand.
local tick_fn
timer = {
  every = function(_, fn) tick_fn = fn return 1 end,
  cancel = function() end,
}

local mud_state = "connected"
mud = {
  state = function() return mud_state end,
  send_raw = function() return true end,
}

-- Fake push_notify. Records what each channel was told, and which channels
-- were registered, so the cases can assert on both.
local pushed = {}
local push_channels = {}
local push_sink = {
  register_channel = function(name, opts)
    push_channels[name] = opts or {}
  end,
  notify = function(channel, text)
    pushed[#pushed + 1] = { channel = channel, text = text }
    return true
  end,
}
plugin = {
  get = function(name)
    if name == "push_notify" then return push_sink end
    return nil
  end,
}

local registered = {}
local unregistered = {}
local command_stub = {
  register = function(spec) registered[#registered + 1] = spec return #registered end,
  unregister = function(id) unregistered[#unregistered + 1] = id return true end,
}
local real_require = require
require = function(name)
  if name == "command" then return command_stub end
  return real_require(name)
end

-- Raw aliases must not come back: the whole surface is /deadmans now.
alias = {
  add = function() error("deadmans must not register raw aliases", 0) end,
  remove = function() end,
}

local printed = {}
local real_print = print
local capture_print = function(text) printed[#printed + 1] = tostring(text) end

print = capture_print
local dm = require("deadmans")
dm.on_load()
print = real_print

local function spec_for(name)
  for _, spec in ipairs(registered) do
    if spec.name == name then return spec end
  end
  return nil
end

local spec = spec_for("/deadmans")

-- Everything after "/deadmans", the way the registry passes it.
local function run(args)
  printed = {}
  print = capture_print
  spec.handler(args)
  print = real_print
  return table.concat(printed, "\n")
end

-- ---- registration -----------------------------------------------------------
check("registers_command", spec ~= nil)
check("takes_args", spec and spec.accepts_args == true)
check("has_summary", spec and type(spec.summary) == "string" and #spec.summary > 0)
check("usage_is_slash_form", spec and spec.usage:sub(1, 9) == "/deadmans", spec and spec.usage)

-- ---- bare and status --------------------------------------------------------
local out = run("")
check("bare_shows_status", out:find("Status", 1, true) ~= nil, out)
check("bare_shows_help", out:find("/deadmans reset", 1, true) ~= nil, out)

out = run("status")
check("status_shows_status", out:find("Status", 1, true) ~= nil, out)
check("status_omits_help", out:find("/deadmans reset", 1, true) == nil, out)

out = run("help")
check("help_shows_help", out:find("/deadmans set", 1, true) ~= nil, out)
check("help_advertises_set_not_block", out:find("/deadmans block", 1, true) == nil, out)
check("usage_advertises_set", spec and spec.usage:find("set <min>", 1, true) ~= nil, spec and spec.usage)

-- ---- whitespace and case ----------------------------------------------------
out = run("   status   ")
check("trims_whitespace", out:find("Status", 1, true) ~= nil, out)

out = run("STATUS")
check("subcommand_is_case_insensitive", out:find("Status", 1, true) ~= nil, out)

-- ---- numeric arguments ------------------------------------------------------
run("warning 5")
check("warning_sets_time", dm.get_config().warning_time == 5 * 60,
      dm.get_config().warning_time)

run("block 20")
check("block_sets_time", dm.get_config().block_time == 20 * 60,
      dm.get_config().block_time)

out = run("warning")
check("warning_without_value_prints_usage", out:find("Usage: /deadmans warning", 1, true) ~= nil, out)
check("warning_without_value_keeps_config", dm.get_config().warning_time == 5 * 60)

out = run("block abc")
check("block_rejects_non_numeric", out:find("Usage: /deadmans block", 1, true) ~= nil, out)
check("block_rejects_non_numeric_keeps_config", dm.get_config().block_time == 20 * 60)

out = run("warning 5 7")
check("warning_rejects_extra_argument", out:find("Usage: /deadmans warning", 1, true) ~= nil, out)

-- ---- "set" is the documented name for the block threshold --------------------
run("set 25")
check("set_sets_block_time", dm.get_config().block_time == 25 * 60,
      dm.get_config().block_time)
check("set_leaves_warning_alone", dm.get_config().warning_time == 5 * 60,
      dm.get_config().warning_time)

out = run("set")
check("set_without_value_prints_usage", out:find("Usage: /deadmans set", 1, true) ~= nil, out)
check("set_without_value_keeps_config", dm.get_config().block_time == 25 * 60)

out = run("set abc")
check("set_rejects_non_numeric", out:find("Usage: /deadmans set", 1, true) ~= nil, out)
check("set_rejects_non_numeric_keeps_config", dm.get_config().block_time == 25 * 60)

-- "block" stays accepted so an existing script or muscle-memory keeps working,
-- it is simply no longer what the help text names.
run("block 30")
check("block_still_accepted", dm.get_config().block_time == 30 * 60,
      dm.get_config().block_time)
run("set 25")

-- ---- a threshold change persists immediately, not only at unload ------------
stored_data = nil
saves = 0
run("set 40")
check("set_saves_immediately", saves == 1, "saves=" .. saves)
check("set_persists_block_time", stored_data and stored_data.config
      and stored_data.config.block_time == 40 * 60,
      stored_data and stored_data.config and stored_data.config.block_time)
check("set_persists_warning_time", stored_data and stored_data.config
      and stored_data.config.warning_time == 5 * 60,
      stored_data and stored_data.config and stored_data.config.warning_time)

stored_data = nil
saves = 0
run("warning 8")
check("warning_saves_immediately", saves == 1, "saves=" .. saves)
check("warning_persists_both", stored_data and stored_data.config
      and stored_data.config.warning_time == 8 * 60
      and stored_data.config.block_time == 40 * 60)

-- A rejected argument must not write anything.
stored_data = nil
saves = 0
run("set abc")
check("rejected_value_does_not_save", saves == 0 and stored_data == nil, "saves=" .. saves)

run("warning 5")
run("set 20")

-- ---- activity hooks ---------------------------------------------------------
now = 6000
dm.on_user_input("/reconnect")
check("local_command_counts_as_activity", dm.get_idle_time() == 0, dm.get_idle_time())
now = 6001
dm.on_user_input("")
check("empty_enter_counts_as_activity", dm.get_idle_time() == 0, dm.get_idle_time())

-- ---- reset ------------------------------------------------------------------
now = 5000
out = run("reset")
check("reset_reports", out:find("reset", 1, true) ~= nil, out)
check("reset_clears_idle", dm.get_idle_time() == 0, dm.get_idle_time())

-- ---- unknown ----------------------------------------------------------------
out = run("nonsense")
check("unknown_subcommand_reported", out:find("Unknown subcommand: nonsense", 1, true) ~= nil, out)
check("unknown_subcommand_shows_help", out:find("/deadmans status", 1, true) ~= nil, out)

-- ---- unload -----------------------------------------------------------------
print = capture_print
dm.on_unload()
print = real_print
check("unload_unregisters_command", #unregistered == 1, tostring(#unregistered))
check("unload_persists_config", stored_data and stored_data.config
      and stored_data.config.warning_time == 5 * 60
      and stored_data.config.block_time == 20 * 60,
      stored_data and stored_data.config and stored_data.config.block_time)

-- ---- push notifications -----------------------------------------------------
-- The overlay is only useful to someone looking at the window, which being
-- idle rules out. These cases are about the notification that goes out instead.
--
-- on_unload above dropped the sink, so re-arm the plugin the way the loader
-- does. Thresholds are whatever the command cases persisted: warning at 5m,
-- blocking at 20m. The clock is re-anchored first, because on_load stamps
-- last_user_input from it and the cases above have moved it around.
local BASE = 100000
now = BASE
print = capture_print
dm.on_load()
dm.on_setup()
print = real_print

check("push_registers_both_channels",
      push_channels.deadman_warning ~= nil and push_channels.deadman_triggered ~= nil)
-- Both HIGH, like push_notify's own disconnect alert: normal priority is
-- subject to quiet hours, which is precisely when an unattended client idles
-- out and you most need to be told.
check("push_both_channels_are_high_priority",
      push_channels.deadman_warning and push_channels.deadman_warning.priority == 1
      and push_channels.deadman_triggered and push_channels.deadman_triggered.priority == 1,
      (push_channels.deadman_warning and push_channels.deadman_warning.priority)
        .. "/" .. (push_channels.deadman_triggered and push_channels.deadman_triggered.priority))

local function idle_for(seconds)
  now = BASE + seconds
  tick_fn()
end

local function last_push()
  return pushed[#pushed]
end

pushed = {}
idle_for(4 * 60)
check("push_silent_before_the_warning", #pushed == 0, #pushed)

idle_for(5 * 60)
check("push_on_entering_warning", #pushed == 1 and last_push().channel == "deadman_warning",
      last_push() and last_push().channel)
check("warning_text_names_the_time_left",
      last_push().text:find("automation stops in", 1, true) ~= nil, last_push().text)

idle_for(5 * 60 + 240)
check("push_does_not_repeat_inside_the_interval", #pushed == 1, #pushed)

idle_for(10 * 60)
check("push_repeats_after_five_minutes", #pushed == 2
      and last_push().channel == "deadman_warning", #pushed)

-- Crossing into blocked is a state change, so it notifies at once rather than
-- waiting out the warning channel's repeat clock.
pushed = {}
idle_for(20 * 60)
check("push_on_entering_blocked", #pushed == 1
      and last_push().channel == "deadman_triggered", last_push() and last_push().channel)
check("triggered_text_says_sends_are_blocked",
      last_push().text:find("blocked", 1, true) ~= nil, last_push().text)

idle_for(20 * 60 + 60)
check("blocked_push_does_not_repeat_inside_the_interval", #pushed == 1, #pushed)
idle_for(25 * 60)
check("blocked_push_repeats_after_five_minutes", #pushed == 2, #pushed)

-- Typing ends the episode. The next idle period must notify from scratch
-- rather than inheriting this one's repeat clock.
pushed = {}
now = BASE + 25 * 60
print = capture_print
dm.on_user_input("")
print = real_print
idle_for(25 * 60 + 5 * 60)
check("push_after_resume_starts_a_fresh_warning", #pushed == 1
      and last_push().channel == "deadman_warning", #pushed)

-- Disconnected: nothing is automating, so there is nothing to warn about, and
-- push_notify has its own disconnect alert.
pushed = {}
mud_state = "disconnected"
idle_for(25 * 60 + 20 * 60)
check("push_silent_while_disconnected", #pushed == 0, #pushed)
mud_state = "connected"

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("ALL PASS")
