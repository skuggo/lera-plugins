-- Autostepper GMCP integration regressions: real plugins, simulated I/O and time.
package.path = "3scapes/autostepper/?.lua;3scapes/?.lua;generic/?.lua;" .. package.path

local function engine()
  for _, name in ipairs({"roominfo", "init", "explore.mode", "areas.chaossea"}) do
    package.loaded[name] = nil
  end
  local E = { sent = {}, logs = {}, requests = {}, now = 0, pushes = {}, channels = {} }
  E.push_sink = {
    register_channel = function(name, opts) E.channels[name] = opts or {} end,
    notify = function(channel, message)
      E.pushes[#E.pushes + 1] = {channel = channel, message = message, commands = #E.sent}
      return true
    end,
  }
  package.loaded.command = {
    register = function(spec)
      if spec.name == "/step" then E.command = spec.handler end
      return 1
    end,
    unregister = function() end,
  }
  local handlers, timers, triggers = {}, {}, {}
  local next_id = 0
  lera = { time = function() return E.now / 1000 end }
  mud = { send = function(cmd) E.sent[#E.sent + 1] = cmd end }
  buffer = { color_print = function(...)
    local parts = {}
    for i = 3, select("#", ...), 3 do parts[#parts + 1] = tostring(select(i, ...)) end
    E.logs[#E.logs + 1] = table.concat(parts)
  end }
  timer = {
    after = function(ms, fn)
      next_id = next_id + 1
      timers[next_id] = { at = E.now + ms, fn = fn }
      return next_id
    end,
    cancel = function(id) timers[id] = nil end,
  }
  function E.advance(ms)
    local finish = E.now + ms
    for _ = 1, 100 do
      local chosen, due
      for id, t in pairs(timers) do
        if t.at <= finish and (not due or t.at < due) then chosen, due = id, t.at end
      end
      if not chosen then E.now = finish; return end
      local t = timers[chosen]
      timers[chosen] = nil
      E.now = due
      t.fn()
    end
    error("timer loop")
  end
  trigger = {
    add = function(pattern, fn)
      next_id = next_id + 1
      triggers[next_id] = { pattern = pattern, fn = fn }
      return next_id
    end,
    remove = function(id) triggers[id] = nil end,
  }
  E.triggers = triggers
  function E.no_target(name)
    for _, t in pairs(triggers) do
      if t.pattern:find("There is no", 1, true) then t.fn(nil, name) end
    end
  end
  alias = { add = function() return 1 end, remove = function() end }
  gmcp = {
    on = function(pkg, fn) handlers[pkg] = fn; return pkg end,
    remove = function(pkg) handlers[pkg] = nil end,
    send = function(pkg, data)
      E.requests[#E.requests + 1] = { pkg = pkg, data = data }
      return true
    end,
  }
  function E.deliver(pkg, data) assert(handlers[pkg], pkg)(pkg, data) end
  local ri
  plugin = { get = function(name)
    if name == "roominfo" then return ri end
    if name == "push_notify" then return E.push_sink end
    if name == "speedwalk" then return {
      step_info = function() return {current = 0, total = 0, remaining = 0} end,
      get_current_place = function() return "test route" end,
      get_targets = function() return {} end,
      load_steps = function() return E.routes and #E.routes > 0 end,
      take_step = function() return table.remove(E.routes, 1) end,
    } end
  end }
  ri = require("roominfo")
  local output = print
  print = function() end
  ri.on_load()
  print = output
  E.ri, E.mode, E.as = ri, require("explore.mode"), require("init")
  E.as.on_load()
  if E.as.on_setup then E.as.on_setup() end
  function E.info(exits)
    E.deliver("Room.Info", {num = 0, name = "Layer one of the Sea of Chaos", exits = exits})
  end
  function E.contents(monsters, players, entry, items)
    local entries = {}
    for _, name in ipairs(monsters or {}) do
      entries[#entries + 1] = {name = name, type = "monster", count = 1}
    end
    for _, name in ipairs(players or {}) do
      entries[#entries + 1] = {name = name, type = "player", count = 1}
    end
    for _, name in ipairs(items or {}) do
      entries[#entries + 1] = {name = name, type = "item", count = 1}
    end
    E.deliver("Room.Contents", {full = 1, items = entries, entry = entry and 1 or nil})
  end
  function E.begin(exits, monsters, targets_only, players)
    E.info(exits); E.contents(monsters, players)
    assert(E.as.explore_start("chaossea"))
    assert(E.as.start(targets_only))
    E.info(exits); E.contents(monsters, players)
  end
  -- Seed a completed Sea, then exercise the real delayed restart. Callers
  -- inspect the new instance; drop only the seed's I/O observations.
  function E.restart_farm(level, difficulty)
    local cask = "A cask of chaotic energy (closed)"
    E.info({}); E.contents({}, nil, false, {cask})
    assert(E.as.chaossea_farm_config(level, difficulty))
    E.command("explore chaossea")
    E.contents({}, nil, false, {cask})
    E.pushes, E.requests = {}, {}
    E.advance(1000)
    return E.as.is_running()
  end
  function E.blocked()
    for _, t in pairs(triggers) do
      if t.pattern:find("blocks your way", 1, true) then
        t.fn("A growing mutant being blocks your way!")
        return true
      end
    end
    return false
  end
  function E.pos()
    local s = E.mode.stats()
    return s.x .. "," .. s.y .. "," .. s.z
  end
  return E
end

local failures, checks = 0, 0
local function check(name, ok)
  checks = checks + 1
  if not ok then failures = failures + 1 end
  print("CASE " .. name .. ": " .. (ok and "PASS" or "FAIL"))
end

do
  local e = engine()
  check("prompt APIs are removed", e.as.prompt == nil and e.as.set_prompt_pattern == nil)
  e.begin({n = 0}, {})
  check("initial refresh completes without prompts or timers", e.sent[1] == "n")
  e.info({s = 0, e = 0})
  e.advance(1600)
  check("Info and elapsed settle delays cannot complete a move", #e.sent == 1 and e.pos() == "0,0,0")
  e.deliver("Room.Map", {w = 1, h = 1, rows = {"@"}})
  check("Map cannot complete a move", #e.sent == 1)
  e.contents({"A growing mutant being"}, nil, true)
  check("late contents attacks the mob in the arrived room", e.sent[2] == "kill mutant" and e.pos() == "0,1,0")
  e.advance(1600)
  check("no delayed arrival timer moves during combat", #e.sent == 2 and e.as.get_state() == "fighting")
end

do
  local e = engine()
  e.begin({n = 0, s = 0}, {})
  e.contents({}, nil, false)
  check("an unrelated refresh cannot acknowledge a move", #e.sent == 1 and e.pos() == "0,0,0")
  e.contents({}, nil, true)
  check("identical entry contents still commits exactly one room", #e.sent == 2 and e.pos() == "0,1,0")
  e.deliver("Room.Map", {w = 1, h = 1, rows = {"@"}})
  check("trailing Map cannot acknowledge the following move", #e.sent == 2 and e.pos() == "0,1,0")
end

do
  local e = engine()
  e.begin({n = 0}, {})
  e.info({s = 0})
  e.deliver("Room.Contents", {full = 1, entry = 1, page = 1, pages = 2,
    items = {{type = "item", name = "A rusty sword"}}})
  e.advance(1600)
  check("a partial contents list cannot complete arrival", #e.sent == 1 and e.pos() == "0,0,0")
  e.deliver("Room.Contents", {full = 1, entry = 1, page = 2, pages = 2,
    items = {{type = "monster", name = "A growing mutant being"}}})
  check("final contents page commits and attacks", e.sent[2] == "kill mutant" and e.pos() == "0,1,0")
  check("roominfo retains the entry marker across paging", e.ri.info().entry == true)
end

do
  local e = engine()
  e.begin({n = 0, s = 0}, {"A growing mutant being"}, false, {"OtherPlayer"})
  check("blocked response handler exists", e.blocked())
  e.advance(5000)
  check("blocked movement stops with confirmed coordinates", not e.as.is_running() and e.pos() == "0,0,0")
  e.advance(10000)
  e.contents({}, nil, false)
  check("blocked movement leaves no callbacks that resume walking", #e.sent == 1 and e.pos() == "0,0,0")
end

do
  local e = engine()
  e.begin({n = 0}, {})
  e.blocked() -- Chaossea warns even when a wizard is allowed to pass.
  e.info({s = 0})
  e.contents({"A growing mutant being"}, nil, true)
  check("successful wizard entry wins over the blocking warning", e.pos() == "0,1,0" and e.sent[2] == "kill mutant")
end

do
  local e = engine()
  e.begin({n = 0}, {})
  e.info({s = 0})
  e.deliver("Room.Contents", {full = 1, entry = 1, page = 1, pages = 2, items = {}})
  e.deliver("Room.Contents", {full = 1, page = 2, pages = 2, items = {}})
  check("mismatched entry markers cannot complete a paged arrival", #e.sent == 1 and e.pos() == "0,0,0")
end

do
  local e = engine()
  e.begin({n = 0}, {})
  e.advance(10000)
  check("missing arrival stops instead of advancing the map", not e.as.is_running() and e.pos() == "0,0,0" and #e.sent == 1)
  e.contents({}, nil, true)
  check("late entry cannot restart a timed-out run", #e.sent == 1 and not e.as.is_running())
end

do
  local e = engine()
  e.deliver("Char.Combat", {attacker = ""})
  e.begin({n = 0}, {"A growing mutant being"})
  e.advance(1600)
  check("starting a run cannot prune a target without combat events", #e.sent == 1 and e.sent[1] == "kill mutant" and #e.as.tracked_monsters() == 1)
  e.deliver("Char.Combat", {attacker = "A growing mutant being"})
  e.deliver("Char.Combat", {attacker = ""})
  e.contents({"A growing mutant being"}, nil, false)
  check("combat refresh reattacks a surviving monster", e.sent[2] == "kill mutant")
  e.deliver("Char.Combat", {attacker = "A growing mutant being"})
  e.deliver("Char.Combat", {attacker = ""})
  e.contents({}, nil, false)
  check("combat refresh confirming empty room permits movement", e.sent[3] == "n")
  check("combat refresh is not also a movement arrival", e.pos() == "0,0,0")
end

-- Refresh replies can arrive after the former one-second deadline. Keep
-- combat unresolved until a complete reply arrives, with bounded retries.
do
  local e = engine()
  e.begin({n = 0}, {"A growing mutant being"})
  local initial_requests = #e.requests
  e.deliver("Char.Combat", {attacker = ""})
  e.advance(1200)
  e.no_target("reason to 'dg'")
  check("a delayed refresh keeps the target and ignores unrelated no-target text",
    e.as.is_running() and #e.sent == 1 and #e.as.tracked_monsters() == 1)
  check("ordinary latency does not send a premature retry", #e.requests == initial_requests + 1)
  e.contents({}, nil, false)
  check("a reply after one second still permits exactly one move", #e.sent == 2 and e.sent[2] == "n" and e.pos() == "0,0,0")
end

do
  local e = engine()
  e.begin({n = 0}, {"A growing mutant being"})
  local initial_requests = #e.requests
  e.deliver("Char.Combat", {attacker = ""})
  e.advance(2999)
  check("combat refresh waits three seconds before retrying", e.as.is_running() and #e.requests == initial_requests + 1)
  e.advance(1)
  check("first timeout retries without moving or discarding the target",
    #e.requests == initial_requests + 2 and #e.sent == 1 and #e.as.tracked_monsters() == 1 and e.as.is_running())
  e.deliver("Char.Combat", {attacker = ""})
  check("duplicate combat-end frames do not add retries", #e.requests == initial_requests + 2)
  e.advance(3000)
  check("second timeout sends the final refresh attempt", #e.requests == initial_requests + 3 and e.as.is_running())
  for i = initial_requests + 1, #e.requests do
    local req = e.requests[i]
    check("refresh attempt " .. (i - initial_requests) .. " requests Contents only",
      req.pkg == "Room.Refresh" and #req.data.packages == 1 and req.data.packages[1] == "Room.Contents")
  end
  e.advance(3000)
  check("exhausted refresh attempts stop with the possible live target intact",
    not e.as.is_running() and #e.sent == 1 and #e.as.tracked_monsters() == 1 and e.pos() == "0,0,0")
  e.contents({}, nil, false)
  e.advance(30000)
  check("late replies cannot restart an exhausted refresh", not e.as.is_running() and #e.sent == 1 and #e.requests == initial_requests + 3)
end

do
  local e = engine()
  e.begin({n = 0}, {"A growing mutant being"})
  local initial_requests = #e.requests
  e.deliver("Char.Combat", {attacker = ""})
  e.advance(3000)
  e.contents({"A growing mutant being"}, nil, false)
  check("a retry reply reattacks a surviving monster", #e.sent == 2 and e.sent[2] == "kill mutant")
  e.advance(10000)
  check("an answered retry leaves no timer that interrupts the new fight", e.as.is_running() and #e.requests == initial_requests + 2 and #e.sent == 2)
  e.deliver("Char.Combat", {attacker = ""})
  e.advance(6000)
  check("the next combat gets a fresh retry budget", e.as.is_running() and #e.requests == initial_requests + 5)
  e.contents({}, nil, false)
  e.contents({}, nil, false)
  check("duplicate retry replies do not acknowledge the next movement", #e.sent == 3 and e.sent[3] == "n" and e.pos() == "0,0,0")
end

do
  local e = engine()
  e.begin({n = 0}, {"A growing mutant being"})
  local send, attempts = gmcp.send, 0
  gmcp.send = function(pkg, data)
    local sent = send(pkg, data)
    attempts = attempts + 1
    if attempts == 2 then e.contents({}, nil, false) end
    return sent
  end
  e.deliver("Char.Combat", {attacker = ""})
  e.advance(3000)
  check("a synchronous retry reply moves once", attempts == 2 and #e.sent == 2 and e.sent[2] == "n")
  e.info({s = 0}); e.contents({"A growing mutant being"}, nil, true)
  e.advance(10000)
  check("a synchronous reply cancels the retry timer before the next fight", e.as.is_running() and attempts == 2 and #e.sent == 3)
end

for _, action in ipairs({"stop", "on_disconnect", "on_unload"}) do
  local e = engine()
  e.begin({n = 0}, {"A growing mutant being"})
  e.deliver("Char.Combat", {attacker = ""})
  e.advance(3000)
  local requests = #e.requests
  e.as[action]()
  e.advance(30000)
  check(action .. " cancels pending refresh retries", not e.as.is_running() and #e.requests == requests and #e.sent == 1)
end

do
  local e = engine()
  e.begin({n = 0}, {"A growing mutant being"})
  e.deliver("Char.Combat", {attacker = ""})
  local retries = 0
  gmcp.send = function() retries = retries + 1; return false end
  e.advance(30000)
  check("a refused retry stops immediately and retains the target", retries == 1 and not e.as.is_running() and #e.sent == 1 and #e.as.tracked_monsters() == 1)
end

do
  local e = engine()
  e.begin({n = 0}, {"A growing mutant being"})
  e.deliver("Char.Combat", {attacker = ""})
  e.deliver("Room.Contents", {full = 1, page = 1, pages = 2, items = {}})
  e.advance(3000)
  check("a partial refresh cannot finish combat during retries", e.as.is_running() and #e.sent == 1 and #e.as.tracked_monsters() == 1)
  e.deliver("Room.Contents", {full = 1, page = 2, pages = 2, items = {}})
  check("the final page of a delayed refresh permits movement", #e.sent == 2 and e.sent[2] == "n")
end

do
  local e = engine()
  e.begin({n = 0}, {"A growing mutant being"})
  e.deliver("Char.Combat", {attacker = ""})
  e.advance(3000)
  local requests = #e.requests
  e.contents({}, nil, true)
  e.advance(30000)
  check("room entry during refresh retries stops instead of using another room", not e.as.is_running() and #e.requests == requests and #e.sent == 1 and e.pos() == "0,0,0")
end

do
  local e = engine()
  e.routes = {{raw = "2n", commands = {"n", "n"}}, {raw = "e", commands = {"e"}}}
  e.info({n = 0}); e.contents({})
  local callbacks = 0
  e.as.on_step(function() callbacks = callbacks + 1 end)
  e.as.start(false); e.contents({})
  check("compound route sends only its first movement", table.concat(e.sent, ",") == "n")
  e.deliver("Room.Info", {num = 1, name = "First route room", exits = {n = 0, s = 0}})
  e.contents({"A growing mutant being"}, nil, true)
  check("compound route fights before queuing another movement", table.concat(e.sent, ",") == "n,kill being")
  e.deliver("Char.Combat", {attacker = ""})
  e.contents({}, nil, false)
  check("compound route continues after combat refresh", table.concat(e.sent, ",") == "n,kill being,n")
  e.deliver("Room.Info", {num = 2, name = "Second route room", exits = {s = 0, e = 0}})
  e.contents({}, nil, true)
  check("next route segment waits for the final compound arrival", e.sent[4] == "e" and #e.sent == 4)
  check("compound route preserves one callback per authored segment", callbacks == 2)
end

do
  local e = engine()
  e.begin({n = 0, s = 0}, {})
  e.blocked()
  check("repeated start refuses an already running move", e.as.start(false) == false)
  e.contents({}, nil, false)
  check("repeated start cannot refresh a blocked move into success", e.pos() == "0,0,0" and #e.sent == 1)
end

do
  local e = engine()
  e.deliver("Room.Info", {num = 400, name = "Outside the Sea", exits = {}})
  e.contents({})
  e.restart_farm(0, "risky")
  check("setup sends its commands without a stale initial refresh", #e.sent == 5 and #e.requests == 0)
  e.deliver("Room.Info", {num = 401, name = "The portal shore", exits = {}})
  e.contents({}, nil, true)
  check("setup ignores intermediate entry outside the Sea", #e.sent == 5 and e.as.is_running())
  e.info({n = 0}); e.contents({"A growing mutant being"}, nil, false)
  check("setup ignores an unmarked snapshot of an old instance", #e.sent == 5)
  e.contents({"A growing mutant being"}, nil, true)
  check("setup starts fighting on the confirmed Sea entry", e.sent[6] == "kill mutant" and e.pos() == "0,0,0")
end

do
  local e = engine()
  local send = mud.send
  mud.send = function(cmd)
    send(cmd)
    if cmd == "n" then
      e.info({s = 0})
      e.contents({"A growing mutant being"}, nil, true)
    end
  end
  e.begin({n = 0}, {})
  check("movement wait is armed before sending its command", table.concat(e.sent, ",") == "n,kill mutant" and e.pos() == "0,1,0")
end

do
  local e = engine()
  e.routes = {{raw = "(open door)n", commands = {"open door", "n"}}}
  e.info({n = 0}); e.contents({})
  e.as.start(false); e.contents({})
  check("route sends preparatory commands before its movement", table.concat(e.sent, ",") == "open door,n")
  e.deliver("Room.Info", {num = 1, name = "Beyond the door", exits = {s = 0}})
  e.contents({"A growing mutant being"}, nil, true)
  check("mixed route processes the movement's actual contents", e.sent[3] == "kill being")
end

do
  local e = engine()
  e.routes = {{raw = "open door", commands = {"open door"}}, {raw = "n", commands = {"n"}}}
  e.info({n = 0}); e.contents({})
  e.as.start(false); e.contents({})
  check("a preparatory-only route segment does not wait for impossible entry", table.concat(e.sent, ",") == "open door,n")
end

do
  local e = engine()
  e.routes = {{raw = "(enter portal)n", commands = {"enter portal", "n"}}}
  e.info({n = 0}); e.contents({})
  e.as.start(false); e.contents({})
  check("unfamiliar custom commands require entry before another move", table.concat(e.sent, ",") == "enter portal")
end

-- The captured run reached these items, killed the boss, then walked away
-- because the origin still had unexplored exits. Completion must win before
-- the next frontier is selected, after a full contents list clears the room.
local cask = "A cask of chaotic energy (closed)"
local portal = "A glowing portal (swirling chaotically)"
local boss = "A whirling monstrosity with three tentacles"

do
  local e = engine()
  local completed = 0
  e.as.on_complete(function() completed = completed + 1 end)
  e.begin({n = 0, e = 0}, {})
  e.info({s = 0})
  e.contents({boss}, nil, true, {cask, portal})
  check("cask discovery pushes before the boss fight",
    #e.pushes == 1 and e.pushes[1].channel == "chaossea_cask"
      and e.pushes[1].message:find("cask", 1, true) and e.pushes[1].commands == 1)
  check("cask arrival fights its boss before completing", table.concat(e.sent, ",") == "n,kill mutant" and e.as.is_running() and completed == 0)
  e.deliver("Char.Combat", {attacker = ""})
  e.deliver("Room.Contents", {full = 1, page = 1, pages = 2,
    items = {{name = cask, type = "item", count = 1}}})
  check("cask on a partial combat refresh cannot complete the run", #e.sent == 2 and e.as.is_running() and completed == 0)
  e.deliver("Room.Contents", {full = 1, page = 2, pages = 2,
    items = {{name = boss, type = "monster", count = 1}}})
  check("a surviving boss beside the cask is fought again", e.sent[3] == "kill mutant" and e.as.is_running() and completed == 0)
  e.deliver("Char.Combat", {attacker = ""})
  e.contents({}, nil, false, {cask, portal})
  check("clearing the cask room stops before backtracking to other unexplored exits", not e.as.is_running() and not e.mode.active() and #e.sent == 3 and e.pos() == "0,1,0")
  check("cask completion notifies once", completed == 1)
  check("cask completion reports the destination instead of exhausted exits", table.concat(e.logs, "\n"):find("Chaos Sea complete: cask/portal reached", 1, true) ~= nil)
  e.contents({}, nil, false, {cask, portal})
  e.advance(10000)
  check("boss refreshes and duplicate contents do not repeat the cask push", #e.pushes == 1)
  check("duplicate contents and old timers cannot resume a completed cask run", not e.as.is_running() and #e.sent == 3 and completed == 1)
end

for _, item in ipairs({cask, portal}) do
  local e = engine()
  e.begin({n = 0, e = 0}, {})
  e.info({s = 0, n = 0})
  e.contents({}, nil, true, {item})
  check(item .. " only sends a discovery push for an actual cask", #e.pushes == (item == cask and 1 or 0))
  check(item .. " stops an empty destination room immediately", not e.as.is_running() and #e.sent == 1 and e.pos() == "0,1,0")
end

do
  local e = engine()
  e.info({n = 0}); e.contents({}, nil, false, {cask})
  assert(e.as.explore_start("chaossea"))
  assert(e.as.start(false))
  e.contents({}, nil, false, {cask})
  check("starting at the cleared cask completes without moving", not e.as.is_running() and #e.sent == 0)
end

for _, cancel in ipairs({false, true}) do
  local e = engine()
  e.deliver("Room.Info", {num = 400, name = "Outside the Sea", exits = {}})
  e.contents({})
  assert(e.restart_farm(5, "risky"))
  e.info({n = 0, e = 0}); e.contents({}, nil, true)
  e.info({s = 0}); e.contents({boss}, nil, true, {cask, portal})
  e.advance(1000)
  check("farm waits for the cask room's boss before restarting", #e.sent == 7 and e.sent[7] == "kill mutant" and e.as.is_running())
  e.deliver("Char.Combat", {attacker = ""})
  e.contents({}, nil, false, {cask, portal})
  check("farm start and cask discovery use separate push channels",
    #e.pushes == 2 and e.pushes[1].channel == "chaossea_farm" and e.pushes[1].commands == 5
      and e.pushes[2].channel == "chaossea_cask")
  check("farm completes at the cask with unexplored exits remaining", not e.as.is_running() and #e.sent == 7)
  e.contents({}, nil, false, {cask, portal})
  if cancel then e.as.stop() end
  e.advance(1000)
  if cancel then
    check("cancelling a pending farm restart sends no restart push", #e.pushes == 2)
    check("stop cancels the pending farm restart at the cask", not e.as.is_running() and #e.sent == 7)
  else
    check("automatic farm restart pushes once after sending setup commands",
      #e.pushes == 3 and e.pushes[3].channel == "chaossea_farm" and e.pushes[3].commands == 12
        and e.pushes[3].message:find("5", 1, true) and e.pushes[3].message:find("risky", 1, true))
    check("farm schedules one next instance from the cask", #e.sent == 12 and table.concat(e.sent, ",", 8) == "open cask,enter portal,unsetsea,setsea 5 risky,enter sea" and e.as.is_running())
    e.info({n = 0}); e.contents({}, nil, true)
    e.info({s = 0}); e.contents({}, nil, true, {cask})
    check("the new farm instance can announce its own cask", #e.pushes == 4 and e.pushes[4].channel == "chaossea_cask")
    e.as.stop()
  end
end

-- explore_5.txt: portal lobby and new instance arrive consecutively in the
-- same network read. The lobby must not become the fresh maze's origin.
do
  local e = engine()
  e.deliver("Room.Info", {num = 266, name = "A swirling Sea of Chaos", exits = {out = 267}})
  e.contents({})
  assert(e.restart_farm(5, "risky"))
  e.info({n = 0, e = 0}); e.contents({}, nil, true)
  e.info({s = 0}); e.contents({boss}, nil, true, {cask, portal})
  e.deliver("Char.Combat", {attacker = ""})
  e.contents({}, nil, false, {cask, portal})
  e.advance(1000)
  local sent = #e.sent
  check("farm restart begins with a fresh unrecorded map", e.mode.stats().rooms == 0)
  e.deliver("Room.Info", {num = 266, area = "The Sea of Chaos",
    name = "A swirling Sea of Chaos", exits = {out = 267}})
  e.deliver("Room.Contents", {entry = 1, full = 1,
    items = {{type = "item", count = 64, name = "A cube of raw chaos"}}})
  check("portal lobby cannot complete the farm setup arrival",
    e.as.is_running() and e.as.get_state() == "stepping" and #e.sent == sent)
  check("portal lobby is not recorded as the new maze origin", e.mode.stats().rooms == 0)
  e.deliver("Room.Info", {num = 60494, area = "The Sea of Chaos",
    name = "Layer one of the Sea of Chaos", exits = {n = 0, w = 0, out = 266}})
  e.deliver("Room.Contents", {entry = 1, full = 1,
    items = {{type = "monster", count = 1, name = "A tiny evolving being"}}})
  check("new farm instance attacks the occupant of its actual first room",
    e.as.get_state() == "fighting" and e.sent[sent + 1] == "kill mutant"
      and e.pos() == "0,0,0" and e.mode.stats().rooms == 1)
  e.deliver("Char.Combat", {attacker = ""}); e.contents({})
  check("farm continues exploring after clearing the new entry room",
    e.as.is_running() and e.sent[sent + 2] == "n")
  e.as.stop()
end

do
  local e = engine()
  e.restart_farm(5, "risky")
  e.deliver("Room.Info", {num = 266, name = "A swirling Sea of Chaos", exits = {out = 267}})
  e.contents({}, nil, true)
  e.advance(5000)
  check("farm setup still times out when only the lobby arrives",
    not e.as.is_running() and e.mode.stats().rooms == 0
      and table.concat(e.logs, "\n"):find("Room entry went unanswered", 1, true) ~= nil)
end

-- The server may omit the boss when a crowded room hits its inventory cap.
-- Receiving every page of that truncated list does not establish a clear room.
for _, farm in ipairs({false, true}) do
  for _, after_combat in ipairs({false, true}) do
    local e = engine()
    local completed = 0
    e.as.on_complete(function() completed = completed + 1 end)
    if farm then
      e.deliver("Room.Info", {num = 400, name = "Outside the Sea", exits = {}})
      e.contents({})
      assert(e.restart_farm(5, "risky"))
      e.info({n = 0, e = 0}); e.contents({}, nil, true)
    else
      e.begin({n = 0, e = 0}, {})
    end
    e.info({s = 0})
    if after_combat then
      e.contents({boss}, nil, true, {cask})
      e.deliver("Char.Combat", {attacker = ""})
    end
    local sent = #e.sent
    local pages = {{}, {}}
    for i = 1, 64 do
      local page = i <= 32 and 1 or 2
      pages[page][#pages[page] + 1] = {
        name = i == 1 and cask or ("a trinket " .. i), type = "item", count = 1,
      }
    end
    local label = (farm and "farm" or "ordinary")
      .. (after_combat and " combat refresh" or " entry")
    e.deliver("Room.Contents", {full = 1, page = 1, pages = 2,
      entry = not after_combat and 1 or nil, truncated = 1, items = pages[1]})
    e.deliver("Room.Contents", {full = 1, page = 2, pages = 2,
      entry = not after_combat and 1 or nil, items = pages[2]})
    check(label .. ": truncated cask contents stop without completing", not e.as.is_running() and completed == 0 and #e.sent == sent)
    check(label .. ": truncated cask contents explain the stop", table.concat(e.logs, "\n"):find("contents are truncated", 1, true) ~= nil)
    e.advance(10000)
    check(label .. ": truncated cask contents cannot restart movement or farming", not e.as.is_running() and completed == 0 and #e.sent == sent)
  end
end

for _, farm in ipairs({false, true}) do
  local old_store = store
  store = {
    load = function() return true end,
    get = function() return {ignored_monsters = {["a gentle guide"] = true}} end,
  }
  local e = engine()
  store = old_store
  if farm then
    e.deliver("Room.Info", {num = 400, name = "Outside the Sea", exits = {}})
    e.contents({})
    assert(e.restart_farm(5, "risky"))
    e.info({n = 0, e = 0}); e.contents({}, nil, true)
  else
    e.begin({n = 0, e = 0}, {})
  end
  local sent = #e.sent
  e.info({s = 0})
  e.contents({"A gentle guide", boss}, nil, true, {cask})
  check("cask completion still fights a non-ignored boss", e.sent[sent + 1] == "kill mutant" and e.as.is_running())
  e.deliver("Char.Combat", {attacker = ""})
  e.contents({"A gentle guide"}, nil, false, {cask})
  check((farm and "farm" or "ordinary") .. " cask completion excludes ignored mobs", not e.as.is_running() and #e.sent == sent + 1)
  e.advance(1000)
  if farm then
    check("farm restarts when only ignored mobs remain beside the cask", #e.sent == sent + 6 and e.sent[sent + 2] == "open cask")
  else
    check("ordinary cask run stays stopped beside an ignored mob", #e.sent == sent + 1 and not e.as.is_running())
  end
end

-- Three-hop frontier: C -> B -> A -> unexplored D. The first two rooms
-- were already visited; only D gets a new combat/exploration decision.
local function frontier_trip(before_dispatch)
  local e = engine()
  e.begin({n = 0, e = 0}, {})
  e.info({n = 0, s = 0}); e.contents({}, nil, true)
  e.info({s = 0}); e.contents({"A growing mutant being"}, nil, true)
  e.deliver("Char.Combat", {attacker = ""})
  local sent = #e.sent
  if before_dispatch then before_dispatch(e) end
  e.contents({})
  return e, sent
end

do
  local e, before = frontier_trip()
  check("frontier travel sends all directions before any arrival",
    #e.sent == before + 3 and table.concat(e.sent, ",", before + 1) == "s,s,e")
  check("dispatch does not advance coordinates", e.pos() == "0,2,0")
  e.advance(4000)
  e.info({n = 0, s = 0})
  e.contents({}, nil, false)
  check("unmarked refresh cannot consume a speedwalk direction", e.pos() == "0,2,0")
  e.contents({"A growing mutant being"}, nil, true)
  check("intermediate room updates position without fighting or sending more moves",
    e.pos() == "0,1,0" and #e.sent == before + 3 and e.as.get_state() == "stepping")
  e.advance(4000)
  e.info({n = 0, e = 0}); e.contents({}, nil, true)
  check("each intermediate arrival refreshes the movement watchdog",
    e.as.is_running() and e.pos() == "0,0,0" and #e.sent == before + 3)
  e.advance(4000)
  e.info({w = 0})
  e.deliver("Room.Contents", {full = 1, entry = 1, page = 1, pages = 2, items = {}})
  check("destination waits for the complete contents list", e.pos() == "0,0,0" and #e.sent == before + 3)
  e.deliver("Room.Contents", {full = 1, entry = 1, page = 2, pages = 2,
    items = {{type = "monster", name = "A tiny evolving creature"}}})
  check("destination commits the last direction and attacks exactly once",
    e.pos() == "1,0,0" and #e.sent == before + 4 and e.sent[#e.sent] == "kill mutant")
  e.advance(6000)
  check("finished speedwalk leaves no movement watchdog", e.as.get_state() == "fighting")
end

for _, action in ipairs({"stop", "disconnect", "unload", "timeout", "blocked", "reset", "instance", "desync", "layer", "outside"}) do
  local e, before = frontier_trip()
  if action == "stop" then e.as.stop()
  elseif action == "disconnect" then e.as.on_disconnect()
  elseif action == "unload" then e.as.on_unload()
  elseif action == "timeout" then e.advance(5000)
  elseif action == "blocked" then e.blocked()
  elseif action == "reset" then e.as.explore_reset()
  elseif action == "instance" then e.as.on_send("unsetsea")
  elseif action == "desync" then e.info({w = 0}); e.contents({}, nil, true)
  elseif action == "layer" then
    e.deliver("Room.Info", {num = 0, name = "Layer two of the Sea of Chaos", exits = {n = 0, s = 0}})
    e.contents({}, nil, true)
  elseif action == "outside" then
    e.deliver("Room.Info", {num = 42, name = "Outside the Sea", exits = {}})
    e.contents({}, nil, true)
  end
  check(action .. " during frontier travel stops and discards the uncertain map",
    not e.as.is_running() and not e.mode.active() and not e.mode.retained())
  e.info({n = 0, s = 0}); e.contents({}, nil, true)
  e.advance(10000)
  check(action .. " leaves queued arrivals unable to restart exploration", not e.as.is_running() and #e.sent == before + 3)
end

do
  local e, before = frontier_trip()
  e.info({n = 0, s = 0}); e.contents({}, nil, true)
  check("leave cannot plan from the middle of an outstanding speedwalk", not e.as.explore_leave())
  check("refused leave keeps the frontier trip intact", e.as.is_running() and #e.sent == before + 3)
  e.info({n = 0, e = 0}); e.contents({}, nil, true)
  e.info({w = 0}); e.contents({}, nil, true, {cask})
  check("a cask at the speedwalk destination stops before another frontier",
    not e.as.is_running() and e.pos() == "1,0,0" and #e.sent == before + 3)
end

do
  local notifications, raw = 0
  local e, before = frontier_trip(function(e)
    e.as.on_step(function(path) notifications = notifications + 1; raw = path end)
    local send = mud.send
    local moved = 0
    mud.send = function(cmd)
      send(cmd)
      if cmd == "s" or cmd == "e" then
        moved = moved + 1
        if moved == 1 then e.info({n = 0, s = 0}); e.contents({}, nil, true)
        elseif moved == 2 then e.info({n = 0, e = 0}); e.contents({}, nil, true)
        else e.info({w = 0}); e.contents({"A growing mutant being"}, nil, true) end
      end
    end
  end)
  check("synchronous entries acknowledge a fully registered frontier path",
    table.concat(e.sent, ",", before + 1) == "s,s,e,kill mutant" and e.pos() == "1,0,0")
  check("the whole frontier path produces one step notification", notifications == 1 and raw == "s s e")
  e.advance(6000)
  check("synchronous final arrival leaves no stale watchdog", e.as.get_state() == "fighting")
end

for _, action in ipairs({"stop", "blocked", "desync"}) do
  local e, before = frontier_trip(function(e)
    local send = mud.send
    mud.send = function(cmd)
      send(cmd)
      if action == "stop" then e.as.stop()
      elseif action == "blocked" then e.blocked()
      else e.info({w = 0}); e.contents({}, nil, true) end
    end
  end)
  check("synchronous " .. action .. " prevents sending the remaining directions",
    #e.sent == before + 1 and e.sent[#e.sent] == "s" and not e.as.is_running() and not e.mode.retained())
  e.advance(10000)
  check("synchronous " .. action .. " leaves no queued local work", #e.sent == before + 1)
end

do
  local e, before = frontier_trip(function(e)
    e.as.on_step(function() e.as.stop() end)
  end)
  check("stopping from the step notification sends none of the route", #e.sent == before and not e.as.is_running())
  e.advance(10000)
  check("notification stop cannot rearm the movement timer", #e.sent == before and not e.as.is_running())
end

do
  local e = engine()
  e.begin({n = 0, d = 0}, {})
  e.info({n = 0, s = 0}); e.contents({}, nil, true)
  e.info({s = 0}); e.contents({"A growing mutant being"}, nil, true)
  e.deliver("Char.Combat", {attacker = ""})
  local before = #e.sent
  e.contents({})
  check("frontier speedwalk retains its final vertical direction", table.concat(e.sent, ",", before + 1) == "s,s,d")
  e.info({n = 0, s = 0}); e.contents({}, nil, true)
  e.info({n = 0, d = 0}); e.contents({}, nil, true)
  e.deliver("Room.Info", {num = 0, name = "Layer two of the Sea of Chaos", exits = {u = 0}})
  e.contents({"A growing mutant being"}, nil, true)
  check("vertical frontier arrives on the right layer without correction",
    e.pos() == "0,0,1" and e.mode.stats().layer_corrections == 0 and e.as.get_state() == "fighting")
end

do
  local e = engine()
  check("autostepper registers its push channels during setup",
    e.channels.chaossea_cask ~= nil and e.channels.chaossea_farm ~= nil
      and e.channels.explore_exhausted ~= nil)
  e.begin({n = 0}, {})
  e.info({s = 0})
  e.deliver("Room.Contents", {full = 1, entry = 1, page = 1, pages = 2,
    items = {{type = "item", name = cask}}})
  check("partial cask contents cannot send discovery pushes", #e.pushes == 0)
  e.deliver("Room.Contents", {full = 1, entry = 1, page = 2, pages = 2,
    items = {{type = "monster", name = boss}}})
  check("complete cask contents sends one discovery push", #e.pushes == 1)
  e.as.stop()
  assert(e.as.start(false))
  e.contents({boss}, nil, false, {cask})
  check("pause and resume do not announce the same cask twice", #e.pushes == 1)
end

do
  local e = engine()
  local completed = 0
  e.as.on_complete(function() completed = completed + 1 end)
  e.begin({n = 0}, {})
  check("exploration with a frontier sends no exhaustion alert", #e.pushes == 0)
  e.info({s = 0}); e.contents({}, nil, true)
  check("running out of reachable rooms sends an exhaustion alert",
    #e.pushes == 1 and e.pushes[1].channel == "explore_exhausted"
      and e.pushes[1].message == "Autostepper: exploration stopped; no unvisited exits remain.")
  check("exhaustion still stops and completes the run",
    not e.as.is_running() and not e.mode.active() and completed == 1)
  e.contents({}, nil, true)
  e.deliver("Char.Combat", {attacker = ""})
  e.advance(30000)
  check("duplicate frames and old timers do not repeat exhaustion alerts", #e.pushes == 1)
  e.begin({}, {})
  check("a fresh exploration can announce exhaustion again", #e.pushes == 2)
end

for _, action in ipairs({"stop", "disconnect", "timeout", "outside"}) do
  local e = engine()
  e.begin({n = 0}, {})
  if action == "stop" then e.as.stop()
  elseif action == "disconnect" then e.as.on_disconnect()
  elseif action == "outside" then
    e.deliver("Room.Info", {num = 99, name = "Outside the Sea", exits = {s = 0}})
    e.contents({}, nil, true)
  end
  e.advance(30000)
  check(action .. " does not announce exhausted exploration",
    not e.as.is_running() and #e.pushes == 0)
end

do
  local e = engine()
  e.begin({n = 0}, {})
  e.info({s = 0, n = 0}); e.contents({boss}, nil, true)
  assert(e.as.explore_leave())
  e.deliver("Char.Combat", {attacker = ""}); e.contents({})
  e.info({n = 0}); e.contents({}, nil, true)
  check("returning to the origin is not exhaustion",
    not e.as.is_running() and e.mode.stop_reason() == "at origin" and #e.pushes == 0)
  e.command("explore"); e.contents({})
  e.info({s = 0, n = 0}); e.contents({}, nil, true)
  e.info({s = 0}); e.contents({}, nil, true)
  check("exhaustion after leave and resume replaces the old stop reason",
    not e.as.is_running() and e.pos() == "0,2,0" and e.mode.stop_reason() == "exhausted")
  check("exhaustion after leave and resume sends its alert",
    #e.pushes == 1 and e.pushes[1].channel == "explore_exhausted")
end

do
  local e = engine()
  e.begin({n = 0}, {})
  e.info({s = 0}); e.contents({}, nil, true, {cask})
  check("cask completion sends only the existing cask alert",
    not e.as.is_running() and #e.pushes == 1 and e.pushes[1].channel == "chaossea_cask")
end

do
  local e = engine()
  e.routes = {{raw = "n", commands = {"n"}}}
  e.info({n = 0}); e.contents({})
  assert(e.as.start(false)); e.contents({})
  e.info({s = 0}); e.contents({}, nil, true)
  check("stored-route completion does not announce exhausted exploration",
    not e.as.is_running() and #e.pushes == 0)
end

do
  local e = engine()
  e.push_sink = nil
  e.begin({}, {})
  check("missing consumer does not prevent exhausted exploration stopping",
    not e.as.is_running() and #e.pushes == 0)
  local calls, channels = 0, {}
  e.push_sink = {
    register_channel = function(name) channels[name] = true end,
    notify = function(channel)
      if channel == "explore_exhausted" then calls = calls + 1 end
      return false
    end,
  }
  e.begin({}, {})
  check("exhaustion discovers and registers a replacement consumer",
    calls == 1 and channels.explore_exhausted and not e.as.is_running())
  e.contents({}); e.advance(30000)
  check("declined exhaustion alert is not queued or replayed", calls == 1)
end

do
  local e = engine()
  e.command("chaossea farm 5 risky")
  check("farm configuration sends no push", #e.pushes == 0)
  e.push_sink = nil
  e.as.stop()
  e.restart_farm(5, "risky")
  e.info({n = 0}); e.contents({}, nil, true)
  e.info({s = 0}); e.contents({boss}, nil, true, {cask})
  check("missing push consumer leaves exploration and combat working", #e.pushes == 0 and e.as.get_state() == "fighting")
  local replacement_calls, replacement_channels = {}, {}
  e.push_sink = {
    register_channel = function(name) replacement_channels[name] = true end,
    notify = function(channel) replacement_calls[#replacement_calls + 1] = channel; return false end,
  }
  e.as.stop()
  e.restart_farm(5, "risky")
  check("replacement push consumer is discovered and registered",
    replacement_channels.chaossea_cask and replacement_channels.chaossea_farm
      and replacement_calls[#replacement_calls] == "chaossea_farm")
  check("declined push does not stop the farm setup", e.as.is_running())
end

for _, rejected in ipairs({0, 1, 3, 5}) do
  local e = engine()
  mud.send = function(cmd)
    e.sent[#e.sent + 1] = cmd
    return rejected ~= 0 and #e.sent ~= rejected
  end
  e.restart_farm(5, "risky")
  check("rejected farm setup commands do not announce a restart (" .. rejected .. ")", #e.pushes == 0)
end

-- Exercise the actual notification consumer; this backend only records calls.
do
  local e = engine()
  local old_store, old_push = store, push
  local delivered, limited = {}, {}
  store = {
    load = function() end,
    get = function() return {app_token = "offline-test", user_key = "offline-test",
      config = {grace_period = 0, rate_limit = 60}} end,
  }
  push = {
    init = function(token, key) assert(token == "offline-test" and key == "offline-test") end,
    enabled = function() return true end,
    set_rate_limit = function() end,
    is_rate_limited = function(channel) return limited[channel] == true end,
    record_send = function(channel) limited[channel] = true end,
    send = function(message, opts)
      delivered[#delivered + 1] = {message = message, title = opts.title}
      return #delivered
    end,
  }
  package.loaded.push_notify = nil
  local sink = require("push_notify")
  local output = print
  print = function() end
  sink.on_load()
  print = output
  e.push_sink = sink
  e.as.on_setup()
  e.begin({n = 0}, {})
  e.info({s = 0}); e.contents({}, nil, true, {cask})
  check("real consumer keeps new Chaos Sea channels opt-in", #delivered == 0)
  print = function() end
  sink.enable_channel("chaossea_cask", true)
  sink.enable_channel("chaossea_farm", true)
  print = output
  assert(e.as.explore_start("chaossea"))
  assert(e.as.start(false))
  e.contents({}, nil, false, {cask})
  e.restart_farm(5, "risky")
  check("real consumer delivers both nearby events on distinct rate-limit channels",
    #delivered == 2 and delivered[1].title == "CHAOSSEA_CASK" and delivered[2].title == "CHAOSSEA_FARM")
  e.as.stop()
  e.begin({}, {})
  check("real consumer keeps exhaustion alerts opt-in", #delivered == 2)
  print = function() end
  sink.enable_channel("explore_exhausted", true)
  sink.set_grace_period(60)
  print = output
  sink.on_user_input("")
  e.begin({}, {})
  check("real consumer applies activity grace to exhaustion", #delivered == 2)
  e.advance(61000)
  check("grace-suppressed exhaustion is not replayed", #delivered == 2)
  e.begin({}, {})
  check("enabled exhaustion channel delivers after grace",
    #delivered == 3 and delivered[3].title == "EXPLORE_EXHAUSTED")
  e.begin({}, {})
  check("real consumer rate-limits repeated exploration exhaustion", #delivered == 3)
  store, push = old_store, old_push
  package.loaded.push_notify = nil
end

local function status_text(e)
  local first = #e.logs + 1
  e.as.status()
  return table.concat(e.logs, "\n", first)
end

do
  local e = engine()
  check("obsolete automatic glance API is removed", e.as.set_glance_cmd == nil)
  local text = status_text(e)
  check("idle status includes disabled farm and default settings",
    text:find("Chaos Sea farm: off", 1, true) and text:find("Farm settings: level 0, risky", 1, true))
  e.as.set_auto_attack(false)
  e.as.set_attack_cmd("attack")
  text = status_text(e)
  check("status reports the configured attack settings",
    text:find("Auto-attack: off", 1, true) and text:find("Attack command: attack", 1, true))
end

do
  local e = engine()
  e.restart_farm(5, "deadly")
  local sent, requested = #e.sent, #e.requests
  local text = status_text(e)
  check("farm setup status includes selected level and difficulty",
    text:find("Chaos Sea farm: on", 1, true) and text:find("Farm settings: level 5, deadly", 1, true))
  check("farm setup status explains the wait for the new maze",
    text:find("Waiting for: maze entry", 1, true) and text:find("Farm restart: waiting for maze entry", 1, true))
  check("exploration status hides unrelated stored-route step counts", not text:find("Steps:", 1, true))
  check("status is read-only during farm setup", #e.sent == sent and #e.requests == requested)
  e.info({n = 0}); e.contents({}, nil, true)
  check("movement status identifies the room entry wait", status_text(e):find("Waiting for: room entry", 1, true))
  e.info({s = 0}); e.contents({boss}, nil, true, {cask})
  check("fighting status identifies combat end as the next event", status_text(e):find("Waiting for: combat end", 1, true))
  e.deliver("Char.Combat", {attacker = ""})
  check("post-combat status identifies the contents refresh wait", status_text(e):find("Waiting for: combat contents refresh", 1, true))
  e.contents({}, nil, false, {cask})
  text = status_text(e)
  check("pending farm restart stays visible while stepping is stopped",
    text:find("Running: no", 1, true) and text:find("Chaos Sea farm: on", 1, true)
      and text:find("Farm restart: scheduled", 1, true))
  e.advance(1000)
  check("automatic restart status returns to waiting for maze entry",
    status_text(e):find("Farm restart: waiting for maze entry", 1, true))
  e.as.stop()
  text = status_text(e)
  check("stopped farm status retains its selected settings without a pending restart",
    text:find("Chaos Sea farm: on", 1, true) and text:find("Farm settings: level 5, deadly", 1, true)
      and text:find("Farm restart: none", 1, true) and text:find("Waiting for: nothing", 1, true))
end

do
  local e = frontier_trip()
  check("status shows progress through the full frontier route",
    status_text(e):find("Frontier travel: 0/3 rooms", 1, true))
  e.info({n = 0, s = 0}); e.contents({}, nil, true)
  check("frontier status counts only confirmed room arrivals",
    status_text(e):find("Frontier travel: 1/3 rooms", 1, true))
  e.as.stop()
  check("stopping clears frontier travel status", not status_text(e):find("Frontier travel:", 1, true))
end

do
  local e = engine()
  e.routes = {{raw = "n", commands = {"n"}}}
  e.as.start(false)
  local text = status_text(e)
  check("stored-route status retains its step count", text:find("Steps:", 1, true))
  check("route startup status identifies its initial contents wait",
    text:find("Waiting for: initial room contents", 1, true))
  e.as.stop()
end

do
  local e = engine()
  e.begin({n = 0}, {})
  e.as.stop()
  e.deliver("Room.Info", {num = 400, name = "Outside the Sea", exits = {n = 401}})
  e.contents({}, nil, true)
  e.routes = {{raw = "n", commands = {"n"}}}
  assert(e.as.start(false))
  check("an active stored route shows progress even with an old explore map retained",
    e.mode.retained() and status_text(e):find("Steps:", 1, true))
  e.as.stop()
end

do
  local e = engine()
  e.restart_farm(5, "risky")
  e.info({n = 0}); e.contents({}, nil, true)
  e.info({s = 0}); e.contents({}, nil, true, {cask})
  e.command("chaossea farm off")
  local text = status_text(e)
  check("disabling farm does not report the cancelled timer as a restart",
    text:find("Chaos Sea farm: off", 1, true) and text:find("Farm restart: none", 1, true))
  e.as.stop()
end

do
  local e = engine()
  e.restart_farm(5, "risky")
  e.info({}); e.contents({}, nil, true)
  local text = status_text(e)
  check("exhausted farm reports no automatic restart despite the retained farm setting",
    text:find("Running: no", 1, true) and text:find("Chaos Sea farm: on", 1, true)
      and text:find("Farm restart: none", 1, true))
end

-- Farm configuration never issues gameplay commands or starts a run.
do
  local e = engine()
  e.command("chaossea farm 5 deadly")
  local text = status_text(e)
  check("farm command configures without starting exploration",
    not e.as.is_running() and not e.mode.active() and #e.sent == 0 and #e.requests == 0)
  check("idle configured farm reports no pending restart",
    text:find("Chaos Sea farm: on", 1, true) and text:find("Farm settings: level 5, deadly", 1, true)
      and text:find("Farm restart: none", 1, true) and text:find("Waiting for: nothing", 1, true))
  e.advance(10000)
  check("configuration schedules no work or push", #e.sent == 0 and #e.pushes == 0)
  for _, args in ipairs({"chaossea", "chaossea 5 deadly", "chaossea setup 5 deadly",
      "chaossea off", "cs", "cs farm 5 deadly", "chaossea farm", "chaossea farm 5",
      "chaossea farm 5 impossible", "chaossea farm -1 deadly", "chaossea farm 2.5 deadly",
      "chaossea farm 5deadly", "chaossea farm 5 deadly extra", "chaossea farm off extra"}) do
    e.command(args)
    text = status_text(e)
    check("invalid form leaves configuration and run unchanged: " .. args,
      not e.as.is_running() and #e.sent == 0 and #e.requests == 0
        and text:find("Chaos Sea farm: on", 1, true)
        and text:find("Farm settings: level 5, deadly", 1, true))
  end
  e.command("chaossea farm off")
  text = status_text(e)
  check("farm off disables configuration without starting",
    not e.as.is_running() and #e.sent == 0 and text:find("Chaos Sea farm: off", 1, true))
end

for _, start in ipairs({"explore", "explore chaossea"}) do
  local e = engine()
  e.info({n = 0}); e.contents({boss})
  e.command("chaossea farm 5 risky")
  e.command(start)
  check(start .. " starts in the current sea with an initial refresh",
    e.as.is_running() and #e.sent == 0 and #e.requests == 1)
  e.contents({boss})
  check(start .. " attacks the current room before restarting", e.sent[1] == "kill mutant")
  local sent, requested, pos = #e.sent, #e.requests, e.pos()
  e.command("chaossea farm 7 deadly")
  check("changing farm settings does not interrupt combat",
    e.as.get_state() == "fighting" and #e.sent == sent and #e.requests == requested and e.pos() == pos)
  e.deliver("Char.Combat", {attacker = ""}); e.contents({}, nil, false, {cask})
  check("farm config alone has sent no restart push", #e.pushes == 1 and e.pushes[1].channel == "chaossea_cask")
  e.command("chaossea farm 4 alarming")
  e.advance(1000)
  check("pending restart uses the latest farm configuration",
    table.concat(e.sent, ",", 2) == "open cask,enter portal,unsetsea,setsea 4 alarming,enter sea"
      and #e.pushes == 2 and e.pushes[2].channel == "chaossea_farm")
  e.as.stop()
  local text = status_text(e)
  check("stop keeps farm configuration but cancels work",
    text:find("Chaos Sea farm: on", 1, true) and text:find("Farm restart: none", 1, true))
end

do
  local e = engine()
  e.command("chaossea farm 5 risky")
  e.begin({n = 0}, {boss})
  local sent = #e.sent
  e.command("chaossea farm off")
  check("disabling farm does not interrupt the current fight",
    e.as.is_running() and e.as.get_state() == "fighting" and #e.sent == sent)
  e.deliver("Char.Combat", {attacker = ""}); e.contents({}, nil, false, {cask})
  e.advance(1000)
  check("disabled farm stops at the cask without restarting", not e.as.is_running() and #e.sent == sent)
end

for _, cancel in ipairs({"chaossea farm off", "stop"}) do
  local e = engine()
  e.command("chaossea farm 5 risky")
  e.begin({n = 0}, {})
  e.info({s = 0}); e.contents({}, nil, true, {cask})
  local sent, pushes = #e.sent, #e.pushes
  e.command(cancel)
  e.advance(1000)
  check(cancel .. " cancels the pending farm restart", #e.sent == sent and #e.pushes == pushes)
end

do
  local e = engine()
  e.begin({n = 0}, {boss})
  e.command("chaossea farm 3 alarming")
  e.deliver("Char.Combat", {attacker = ""}); e.contents({}, nil, false, {cask})
  e.advance(1000)
  check("enabling farm during exploration applies at its next cask",
    table.concat(e.sent, ",", 2) == "open cask,enter portal,unsetsea,setsea 3 alarming,enter sea")
end

do
  local e = engine()
  e.begin({n = 0}, {boss})
  e.as.stop()
  local sent, rooms, pos = #e.sent, e.mode.stats().rooms, e.pos()
  e.command("chaossea farm 5 risky")
  check("configuring a paused run preserves its map and stopped state",
    not e.as.is_running() and e.mode.retained() and e.mode.stats().rooms == rooms
      and e.pos() == pos and #e.sent == sent)
  e.command("explore")
  e.contents({boss})
  check("explore resumes the paused map with the configured farm",
    e.as.get_state() == "fighting" and e.mode.stats().rooms == rooms and e.pos() == pos)
  e.deliver("Char.Combat", {attacker = ""}); e.contents({}, nil, false, {cask})
  sent = #e.sent
  e.command("explore")
  e.advance(1000)
  check("explicit resume replaces the pending restart with a fresh contents wait",
    #e.sent == sent and status_text(e):find("Waiting for: initial room contents", 1, true))
  e.contents({boss}, nil, false, {cask})
  check("a cancelled restart cannot bypass a boss found after resume", e.sent[sent + 1] == "kill mutant")
  e.command("chaossea   farm   off")
  check("farm off accepts ordinary command whitespace",
    status_text(e):find("Chaos Sea farm: off", 1, true) and e.as.is_running())
end

-- An entry the stepper did not send for (wimpy, a mob moving the player, a
-- direction typed by hand) leaves the dead-reckoned position wrong. Maze rooms
-- mostly share their neighbours' exits, so nothing contradicts it; the offset
-- then files unvisited rooms under recorded coordinates and the run ends
-- "exhausted" with rooms left. The map has to go.
do
  local e = engine()
  e.begin({n = 0, e = 0}, {"A growing mutant being"})
  check("unasked move setup: fighting in a one-room map",
    e.as.get_state() == "fighting" and e.mode.stats().rooms == 1)
  e.info({n = 0, e = 0}); e.contents({}, nil, true)   -- fled into a look-alike room
  check("an entry during combat stops the run",
    not e.as.is_running() and #e.pushes == 0)
  check("an entry during combat drops the reckoned map", e.mode.stats().rooms == 0)
  e.command("explore"); e.info({n = 0, e = 0}); e.contents({})
  check("resuming after an unasked move maps afresh from where the player stands",
    e.as.is_running() and e.mode.stats().rooms == 1 and e.pos() == "0,0,0")
end

do
  local e = engine()
  e.begin({n = 0, e = 0}, {})
  e.info({n = 0, s = 0}); e.contents({}, nil, true)
  e.as.stop()
  local rooms = e.mode.stats().rooms
  e.info({n = 0, s = 0}); e.contents({}, nil, true)   -- walked by hand while paused
  check("a move while paused drops the retained map",
    rooms == 2 and e.mode.stats().rooms == 0 and not e.as.is_running())
end

-- Exhaustion saves a report in the plugin store: the map with frontier marks,
-- the room as the server last described it, and the history leading up to it
-- -- trace lines included, though trace is off. Plugins get no io in Lera's
-- sandbox, so the store is the only place it can go.
do
  local old_store = store
  local saved = { ignored_monsters = { ["a kept mob"] = true } }
  store = {
    load = function() return true end,
    get = function() return saved end,
    set = function(d) saved = d; return true end,
    save = function() return true end,
    path = function() return "/profile/.storage" end,
  }
  local e = engine()
  e.begin({n = 0}, {})
  e.info({s = 0}); e.contents({}, nil, true)
  local dumps = saved.explore_dumps or {}
  local text = table.concat(dumps[#dumps] or {}, "\n")
  check("exhaustion saves a dump",
    not e.as.is_running() and #dumps == 1 and text:find("explore stopped: exhausted", 1, true) ~= nil)
  check("the dump lists every recorded room with its exits marked",
    text:find("0,0,0: n.", 1, true) ~= nil and text:find("0,1,0: s.", 1, true) ~= nil
      and text:find("rooms per layer: z0=2", 1, true) ~= nil)
  check("the dump carries the history, trace lines included with trace off",
    text:find("Explored: no unvisited exits remain", 1, true) ~= nil
      and text:find("trace: ", 1, true) ~= nil)
  check("saving a dump keeps the mob-ignore list",
    saved.ignored_monsters and saved.ignored_monsters["a kept mob"] == true)
  for _ = 1, 6 do e.command("dump") end
  check("/step dump adds reports and only the last five are kept",
    #saved.explore_dumps == 5
      and saved.explore_dumps[5][1]:find("requested with /step dump", 1, true) ~= nil)
  store = old_store
end

print(string.format("%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
