-- xp_monitor unit tests. Run from the lera-plugins repo root.
--
-- The plugin is fed by the MUD's Char.XP GMCP package and no longer scrapes
-- the `xp` command's output, so these drive it by dispatching frames to the
-- handler it registered with gmcp.on().
package.path = "3scapes/?.lua;generic/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
  if ok then print("CASE " .. name .. ": PASS")
  else failures = failures + 1; print("CASE " .. name .. ": FAIL" .. (detail and (" - " .. tostring(detail)) or "")) end
end

-- ---- stubs ------------------------------------------------------------------
local stored = nil
store = { load = function() end, get = function() return stored end,
          set = function(d) stored = d end, save = function() end }

local handlers, removed = {}, {}
gmcp = {
  on = function(pkg, fn) handlers[pkg] = fn; return pkg end,
  remove = function(id) removed[#removed + 1] = id; return true end,
  enabled = function() return true end,
}

ui = { dirty = function() end, rect = function() end, text_ansi = function() end }

local died_cb
local kill_plugin = {
  on_monster_died = function(fn) died_cb = fn; return "listener" end,
  remove_kill_listener = function() died_cb = nil; return true end,
}
plugin = { get = function(name) return name == "kill_trigger" and kill_plugin or nil end }

local registered_command
package.loaded["command"] = {
  register = function(spec) registered_command = spec; return "cmd" end,
  unregister = function() return true end,
}
package.loaded["wm"] = { popup = { is_open = function() return false end,
                                   open = function() end, close = function() end } }
mud = { send = function() end }
local trigger_adds = 0
trigger = { add = function() trigger_adds = trigger_adds + 1; return trigger_adds end,
            remove = function() end }

-- ---- load -------------------------------------------------------------------
local xp = require("xp_monitor")
xp.on_load()

check("subscribes to Char.XP", handlers["Char.XP"] ~= nil)
check("registers no triggers", trigger_adds == 0, trigger_adds)
check("command is /xp", registered_command and registered_command.name == "/xp",
      registered_command and registered_command.name)

local function frame(t) handlers["Char.XP"]("Char.XP", t) end

-- ---- first frame seeds, never attributes ------------------------------------
died_cb(nil, "a rabid weasel")
frame({ xp = 4000000, to_next = 50000, to_spend = 1200, gain30 = 0,
        per_hour = 0, eta_secs = 0, maxed = 0, modifier = 0 })
check("first frame seeds total", stored.total == 4000000, stored.total)
check("first frame records no kill", #stored.kills == 0, #stored.kills)
check("first frame sets the reset baseline", stored.baseline == 4000000, stored.baseline)

-- ---- a kill's gain is attributed to the victim ------------------------------
died_cb(nil, "a cave troll")
frame({ xp = 4012000, to_next = 38000, to_spend = 13200, gain30 = 12000,
        per_hour = 24000, eta_secs = 5700, maxed = 0, modifier = 0 })
check("gain is attributed to the pending victim",
      #stored.kills == 1 and stored.kills[1].enemy == "a cave troll"
      and stored.kills[1].xp == 12000, stored.kills[1] and stored.kills[1].xp)
check("derived fields land", stored.per_hour == 24000 and stored.eta == 5700
      and stored.to_next == 38000, stored.per_hour)

-- ---- a frame with no kill behind it attributes nothing ----------------------
frame({ xp = 4012500, to_next = 37500, to_spend = 13700, gain30 = 12500,
        per_hour = 25000, eta_secs = 5400, maxed = 0, modifier = 1 })
check("no pending victim means no new kill row", #stored.kills == 1, #stored.kills)
check("modifier is carried", stored.modifier == 1, stored.modifier)

-- ---- maxed ------------------------------------------------------------------
frame({ xp = 5000000, to_next = 0, to_spend = 0, gain30 = 100,
        per_hour = 200, eta_secs = 0, maxed = 1, modifier = 0 })
check("maxed flag", stored.max == true, tostring(stored.max))

-- ---- a malformed frame keeps the old numbers --------------------------------
frame({})
check("empty frame keeps the last good values",
      stored.total == 5000000 and stored.gain30 == 100, stored.total)
handlers["Char.XP"]("Char.XP", "not a table")
check("non-table payload is ignored", stored.total == 5000000, stored.total)

-- ---- reset ------------------------------------------------------------------
registered_command.handler("reset")
check("reset rebaselines to the current total", stored.baseline == 5000000, stored.baseline)
check("reset clears the kill list", #stored.kills == 0, #stored.kills)

-- ---- unload -----------------------------------------------------------------
xp.on_unload()
check("unsubscribes on unload", removed[1] == "Char.XP", removed[1])

print(failures == 0 and "ALL XP_MONITOR TESTS PASSED"
      or (failures .. " XP_MONITOR TEST(S) FAILED"))
os.exit(failures == 0 and 0 or 1)
