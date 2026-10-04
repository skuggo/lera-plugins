-- /merc rendering. Run from the lera-plugins repo root with LERA_ROOT
-- pointing at a built Lera checkout.
package.path = "3scapes/mercenary/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
  if ok then
    print("CASE " .. name .. ": PASS")
  else
    failures = failures + 1
    print("CASE " .. name .. ": FAIL" .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

local clock = 1000
lera = { time = function() return clock end }
gmcp = { on = function() return 1 end, remove = function() return true end }

local printed = {}
buffer = {
  color_print = function(_, _, text) printed[#printed + 1] = tostring(text) end,
}

-- `command` is a sandbox whitelist name, so command_ui reaches the registry
-- through require("command"). Intercept it to capture the registered handler.
local handler
local real_require = require
require = function(name)
  if name == "command" then
    return {
      register = function(spec) handler = spec.handler; return 7 end,
      unregister = function() return true end,
    }
  end
  return real_require(name)
end

local protocol = require("protocol")
local state = require("state")
local command_ui = require("command_ui")

-- A minimal stand-in for the plugin table command_ui is installed with.
local api = {
  skills = function() local s = state.snapshot(); return s.skills, s.skills_meta end,
  talents = function() local s = state.snapshot(); return s.talents, s.talents_meta end,
  protocol_status = function()
    return { merc = protocol.merc_name(), counters = protocol.counters(),
             seen = { Vitals = protocol.seen("Vitals"), Info = protocol.seen("Info"),
                      Stats = protocol.seen("Stats"), Skills = protocol.seen("Skills"),
                      Talents = protocol.seen("Talents") } }
  end,
  get_auto_use_config = function()
    return { enabled = false, ability = "none", stamina_threshold = 80,
             ap_threshold = 80, cooldown_seconds = 4 }
  end,
  set_auto_use_enabled = function() end,
  set_auto_use_ability = function() return true end,
  set_auto_use_stamina_threshold = function() return true end,
  set_auto_use_ap_threshold = function() return true end,
  set_auto_use_cooldown = function() return true end,
}
command_ui.install(api)
protocol.on_apply(function(sub, mirror, merc, switched)
  state.apply(sub, mirror, merc, switched)
end)

local function run(args)
  printed = {}
  handler(args)
  return table.concat(printed, "\n")
end

local function reset()
  protocol.reset_connection()
  state.reset()
end

-- Kills: rendering an empty skills table as a legitimate "0 points" answer.
-- Merc.Skills pushes only on registration, allocation and level-up, and
-- heart_beat() has no reconnect trigger, so a short link drop delivers nothing
-- until the next allocation -- with no client-side way to ask for one. Zeroes
-- there are indistinguishable from a mercenary who has trained nothing.
reset()
local out = run("skills")
check("skills reports an absent package rather than zeroes",
  out:find("no Merc.Skills received", 1, true) ~= nil, out)

-- Kills: keying that message off an empty table instead of arrival. A frame
-- HAS arrived here, so real values must render.
reset()
protocol.on_gmcp("Merc.Skills", {
  merc = "kaziar", bury = { raw = 1, eff = 3 }, points = 4, allocs = 2,
  next_cost = 900,
})
out = run("skills")
check("skills renders records once a frame has arrived",
  out:find("bury", 1, true) ~= nil and out:find("eff 3", 1, true) ~= nil
    and out:find("4 points available", 1, true) ~= nil, out)

-- Kills: treating an unknown subcommand as the bare summary, which hides typos.
reset()
out = run("skils")
check("an unknown subcommand prints usage",
  out:find("Usage:", 1, true) ~= nil, out)

-- Kills: hiding available controls behind a separate help command. A bare
-- /merc must show the controls users need for auto-use.
out = run("")
check("the bare command lists Mercenary controls",
  out:find("/merc auto ability", 1, true) ~= nil
    and out:find("/merc omit", 1, true) == nil, out)

-- Kills: rendering a summary before any frame, which prints a blank mercenary.
reset()
out = run("")
check("the summary reports no data before the first frame",
  out:find("no mercenary data", 1, true) ~= nil, out)

-- Kills: formatting the countdown as raw seconds. 298 is 4:58, and the pane
-- and the command must agree.
reset()
protocol.on_gmcp("Merc.Info", { merc = "kaziar", status = 5 })
protocol.on_gmcp("Merc.Vitals", { merc = "kaziar", dormant = 298, hp = 118, hp_max = 500 })
out = run("")
check("the summary formats the dormancy countdown as m:ss",
  out:find("4:58", 1, true) ~= nil, out)

-- Kills: reporting arrival for packages that never came.
reset()
clock = 1000
protocol.on_gmcp("Merc.Vitals", { merc = "kaziar", hp = 1 })
clock = 1042
out = run("status")
check("status distinguishes received from absent packages",
  out:find("Vitals", 1, true) ~= nil and out:find("ago", 1, true) ~= nil
    and out:find("not received this connection", 1, true) ~= nil, out)

-- Kills: printing lera.time()'s raw epoch. The frame arrived at 1000 and it is
-- now 1042, so an epoch renders "1000" and the elapsed form renders "42s ago" --
-- the fixture's two numbers are deliberately unequal so the mutant is visible.
check("an arrival renders as elapsed time, not as an epoch",
  out:find("42s ago", 1, true) ~= nil and out:find("1000", 1, true) == nil, out)
clock = 1000

-- Kills: folding an undecodable payload into bad_attribution. The C layer
-- delivers absent or undecodable JSON as nil, which says nothing about the
-- frame's contents; a reader needs to tell a decode failure from a mudlib that
-- stopped stamping `merc`. One of each here, so a fold reports 2 in one column
-- and 0 in the other.
reset()
protocol.on_gmcp("Merc.Vitals", nil)
protocol.on_gmcp("Merc.Vitals", { hp = 1 })
out = run("status")
check("status reports bad payloads and bad attribution separately",
  out:find("1 bad payload", 1, true) ~= nil
    and out:find("1 bad attribution", 1, true) ~= nil, out)

require = real_require

if failures > 0 then
  print("FAILURES: " .. failures)
  os.exit(1)
end
print("mercenary_command_test: all cases passed")
