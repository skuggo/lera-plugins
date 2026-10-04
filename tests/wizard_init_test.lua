-- wizard cwd tracking, GMCP wiring and the Tab entry point. Run from the
-- lera-plugins repo root with LERA_ROOT pointing at a built Lera checkout.
package.path = "3scapes/wizard/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
  if ok then
    print("CASE " .. name .. ": PASS")
  else
    failures = failures + 1
    print("CASE " .. name .. ": FAIL" .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

-- ---- stubs ----------------------------------------------------------------

local gmcp_handlers = {}
local sent = {}
gmcp = {
  on = function(pkg, fn) gmcp_handlers[pkg] = fn; return pkg end,
  remove = function() return true end,
  send = function(pkg, data) sent[#sent + 1] = { pkg = pkg, data = data }; return true end,
  enabled = function() return true end,
}

local triggers = {}
trigger = {
  add = function(pattern, fn) triggers[#triggers + 1] = { pattern = pattern, fn = fn }; return #triggers end,
  remove = function() return true end,
}

local input_text, input_cursor = "", 1
input = {
  text = function() return input_text end,
  cursor = function() return input_cursor end,
  set_text = function(t) input_text = t end,
}

local menu_opened = nil
package.loaded["menu"] = {
  open = function(opts) menu_opened = opts end,
  close = function() end,
  is_open = function() return false end,
}
package.loaded["wm"] = {
  make_scroller = function()
    return { offset = function() return 0 end, scroll = function() end,
             scroll_to_bottom = function() end, following_tail = function() return true end,
             on_append = function() end, on_trim = function() end }
  end,
}
local registered_command
package.loaded["command"] = { register = function(spec) registered_command = spec; return 1 end, unregister = function() return true end,
                              get = function() return nil end }

ui = { dirty = function() end, text = function() end, box = function() end }
lera = { time = function() return 0 end, dirty = function() end }
local mud_sent = {}
mud = { send = function(t) mud_sent[#mud_sent + 1] = t end }
store = { load = function() end, get = function() return nil end,
          set = function() end, save = function() end }
plugin = { get = function() return nil end }

local wizard = require("init")
local protocol = require("protocol")

-- gmcp.on, trigger.add and command.register all run in on_load, not at module
-- level, so nothing is registered until this call.
wizard.on_load()

-- ---- Core.Supported gating ------------------------------------------------

check("wiring: subscribes to Files.List", gmcp_handlers["Files.List"] ~= nil)
check("wiring: subscribes to Core.Supported", gmcp_handlers["Core.Supported"] ~= nil)

protocol.reset()
gmcp_handlers["Core.Supported"]("Core.Supported", { ["Char.Vitals"] = 1 })
check("gating: a mortal advertisement leaves Files.List unavailable",
      protocol.available() == false,
      "Files.List is omitted entirely for a mortal")

gmcp_handlers["Core.Supported"]("Core.Supported", { ["Files.List"] = 1 })
check("gating: a wizard advertisement makes it available",
      protocol.available() == true)

-- ---- cwd tracking ---------------------------------------------------------

-- Triggers are PCRE, not Lua patterns, so the capture cannot be produced with
-- string.match here. The pattern itself is asserted once below; these cases
-- drive the callback the way the engine would, with the capture supplied.
local function cd_line(path)
  for i = 1, #triggers do triggers[i].fn(path, path) end
end

check("wiring: the cd confirmation trigger is anchored PCRE",
      triggers[1] and triggers[1].pattern == "^(/\\S*)$",
      triggers[1] and triggers[1].pattern)

-- The pane's uall button asks its own question, so the MUD's second prompt
-- (input_to for y/n, outside /players) is answered here rather than left
-- hanging in the input stream. Two triggers, no more: one per thing watched.
check("wiring: uall's confirmation prompt is watched too",
      #triggers == 2 and
      (triggers[2].pattern or ""):find("about to update", 1, true) ~= nil,
      #triggers .. " / " .. tostring(triggers[2] and triggers[2].pattern))

do
  local actions = require("actions")
  local before = #mud_sent
  -- Unarmed: the prompt belongs to a uall the wizard typed themselves.
  triggers[2].fn("You are about to update all the files in the directory:")
  check("uall: an unarmed prompt is left alone", #mud_sent == before,
        "answering a prompt we did not cause would confirm someone else's uall")

  actions.run("uall", "/d/Pinnacle")
  check("uall: running arms the answer and sends the command",
        mud_sent[#mud_sent] == "uall /d/Pinnacle" and actions.pending() == "/d/Pinnacle",
        tostring(mud_sent[#mud_sent]))

  triggers[2].fn("You are about to update all the files in the directory:")
  check("uall: the armed prompt is answered once", mud_sent[#mud_sent] == "y",
        tostring(mud_sent[#mud_sent]))
  check("uall: and disarmed, so the next prompt is not answered too",
        actions.pending() == nil)

  local after = #mud_sent
  triggers[2].fn("You are about to update all the files in the directory:")
  check("uall: a second prompt goes unanswered", #mud_sent == after)

  -- lall asks nothing, so nothing is armed for it.
  actions.run("lall", "/d/Pinnacle")
  check("lall: sends without arming an answer",
        mud_sent[#mud_sent] == "lall /d/Pinnacle" and actions.pending() == nil,
        tostring(mud_sent[#mud_sent]))
end

protocol.reset()
protocol.set_available(true)

-- A bare path line with no cd pending must be ignored.
cd_line("/players/simon")
check("cwd: a path line without a pending cd is ignored",
      protocol.cwd() == nil,
      "the pattern alone would match any output line that is a bare path")

wizard.on_input("cd /open")
cd_line("/open")
check("cwd: a cd confirmation sets the cwd", protocol.cwd() == "/open", tostring(protocol.cwd()))

-- The flag is one-shot: a second bare path line must not move us again.
cd_line("/elsewhere")
check("cwd: the pending flag is one-shot",
      protocol.cwd() == "/open",
      "got " .. tostring(protocol.cwd()))

for _, failure in ipairs({ "No such directory.",
                           "Illegal directory: /nope.",
                           "Invalid path with spaces in it." }) do
  protocol.reset()
  protocol.set_cwd("/open")
  wizard.on_input("cd /nope")
  wizard.on_line(failure)
  cd_line("/nope")
  check("cwd: '" .. failure .. "' disarms without moving",
        protocol.cwd() == "/open",
        "got " .. tostring(protocol.cwd()))
end

protocol.reset()
wizard.on_input("cdtest foo")
cd_line("/open")
check("cwd: a command merely starting with cd does not arm",
      protocol.cwd() == nil)

protocol.reset()
wizard.on_input("cd")
cd_line("/players/simon")
check("cwd: a bare cd arms the flag", protocol.cwd() == "/players/simon")

-- A prompt is free to draw a rule line, and "/--------\\" is a slash followed
-- by non-space characters: the trigger matches it exactly like a path. It must
-- neither become the cwd nor spend the pending cd, or every cd issued under
-- such a prompt lands on the decoration and the pane stops following.
protocol.reset()
protocol.set_cwd("/open")
wizard.on_input("cd /players/adventurer")
cd_line("/-----------------------------------------------------------------------------\\")
check("cwd: a prompt rule line is not a path",
      protocol.cwd() == "/open",
      "got " .. tostring(protocol.cwd()))
cd_line("/players/adventurer")
check("cwd: the real confirmation still lands after the decoration",
      protocol.cwd() == "/players/adventurer",
      "got " .. tostring(protocol.cwd()))

-- A prompt sent without a trailing newline is assembled onto the front of the
-- next line, so the confirmation arrives as "> /players/shaman" and the
-- anchored trigger never matches. The pane must not be stuck there: the first
-- line back from a cd asks the server where it is instead.
protocol.reset()
protocol.set_available(true)
protocol.set_cwd("/players/skuggis")
local before = #sent
wizard.on_input("cd /players/shaman")
wizard.on_line("> /players/shaman")
check("cwd: a prompt-glued confirmation triggers a where-am-I request",
      #sent == before + 1 and sent[#sent].pkg == "Files.List"
      and sent[#sent].data and sent[#sent].data.path == nil,
      tostring(#sent - before))
wizard.on_line("some other line")
check("cwd: the request is sent once per cd, not once per line",
      #sent == before + 1, tostring(#sent - before))
protocol.on_message("Files.List", { path = "/players/shaman", dirs = {}, files = {},
                                    page = 1, pages = 1 })
check("cwd: the server's answer moves the pane",
      protocol.cwd() == "/players/shaman", tostring(protocol.cwd()))

-- Punctuation-only is the give-away, not the backslash alone.
protocol.reset()
protocol.set_cwd("/open")
wizard.on_input("cd /x")
cd_line("/===========")
check("cwd: a punctuation-only line is not a path",
      protocol.cwd() == "/open",
      "got " .. tostring(protocol.cwd()))

-- A scripted cd (the pane's click-to-navigate goes through mud.send, which
-- dispatches on_send, not on_input) must track the cwd exactly as a typed one.
protocol.reset()
protocol.set_available(true)
wizard.on_send("cd /clicked")
cd_line("/clicked")
check("cwd: a scripted cd via on_send tracks the cwd",
      protocol.cwd() == "/clicked",
      "got " .. tostring(protocol.cwd()))

protocol.reset()
wizard.on_send("cdtest foo")
cd_line("/open")
check("cwd: on_send does not arm on a command merely starting with cd",
      protocol.cwd() == nil,
      "got " .. tostring(protocol.cwd()))

check("hooks: on_input passes the text through",
      wizard.on_input("cd /x") == "cd /x")
check("hooks: on_send passes the text through",
      wizard.on_send("cd /x") == "cd /x")

-- ---- disconnect -----------------------------------------------------------

protocol.set_available(true)
protocol.store("/open", { dirs = {}, files = {}, complete = true })
wizard.on_disconnect()
check("disconnect: clears the cache", protocol.lookup("/open") == nil)
check("disconnect: clears availability", protocol.available() == false)

-- ---- Tab completion -------------------------------------------------------

protocol.reset()
protocol.set_available(true)
protocol.set_cwd("/players/simon")
protocol.store("/players/simon", {
  dirs = { "archive", "areas" }, files = { "arena.c", "notes.txt" },
  complete = true, truncated = false,
})

input_text, input_cursor = "cd archi", 9
menu_opened = nil
wizard.complete()
check("tab: a unique directory completes with a trailing slash",
      input_text == "cd archive/", input_text)

input_text, input_cursor = "ar", 3
wizard.complete()
check("tab: a bare first word is left alone", input_text == "ar", input_text)

input_text, input_cursor = "cd ar", 6
menu_opened = nil
wizard.complete()
check("tab: an ambiguous cd opens the menu with directories only",
      menu_opened ~= nil and #menu_opened.items == 2,
      menu_opened and #menu_opened.items)

input_text, input_cursor = "more ar", 8
menu_opened = nil
wizard.complete()
check("tab: more offers files as well as directories",
      menu_opened ~= nil and #menu_opened.items == 3,
      menu_opened and #menu_opened.items)

-- Selecting from the menu rewrites the input line.
input_text = "more ar"
menu_opened.on_select("arena.c", 1)
check("tab: selecting a menu item inserts it",
      input_text == "more arena.c", input_text)

input_text, input_cursor = "lpc ar", 7
menu_opened = nil
wizard.complete()
check("tab: lpc completes nothing",
      input_text == "lpc ar" and menu_opened == nil, input_text)

-- grep's argument 1 is a search term, not a path (cmds/secure/grep.c SYNTAX).
-- Completing it against the filesystem is actively wrong, so from_arg is 2.
sent = {}
input_text, input_cursor = "grep ar", 8
menu_opened = nil
wizard.complete()
check("tab: grep argument 1 is a search term and does not complete",
      input_text == "grep ar" and menu_opened == nil and #sent == 0,
      input_text .. " / menu=" .. tostring(menu_opened ~= nil))

-- ...but argument 2 is a path and completes normally.
input_text, input_cursor = "grep pattern ar", 16
menu_opened = nil
wizard.complete()
check("tab: grep argument 2 completes as a path",
      menu_opened ~= nil and #menu_opened.items == 3,
      "menu=" .. tostring(menu_opened ~= nil)
        .. " items=" .. tostring(menu_opened and #menu_opened.items))

-- A path-shaped word in COMMAND position has arg_index 0. The guard's
-- `arg_index > 0` clause is what stops `0 < from_arg` rejecting it.
input_text, input_cursor = "/players/simon/archi", 21
menu_opened = nil
wizard.complete()
check("tab: a path-shaped word in command position still completes",
      input_text == "/players/simon/archive/",
      input_text)

-- A cache miss requests rather than completing.
sent = {}
input_text, input_cursor = "cd /unseen/x", 13
wizard.complete()
check("tab: a cache miss sends a request",
      #sent == 1 and sent[1].data.path == "/unseen",
      #sent .. " sent, path " .. tostring(sent[1] and sent[1].data.path))

-- An unavailable Files.List completes nothing and sends nothing.
protocol.set_available(false)
sent = {}
input_text, input_cursor = "cd archi", 9
wizard.complete()
check("tab: nothing happens when Files.List is unavailable",
      input_text == "cd archi" and #sent == 0,
      input_text .. " / " .. #sent)

-- /wiz must also explain whether native Ferry actions can be used, including
-- when this plugin runs on an older Lera that has no Ferry global.
local function wiz_status()
  local old_print, lines = print, {}
  print = function(line) lines[#lines + 1] = line end
  registered_command.handler("")
  print = old_print
  return table.concat(lines, "\n")
end
ferry = nil
check("status: older Lera reports Ferry unavailable",
      wiz_status():find("Ferry: unavailable", 1, true) ~= nil)
ferry = {available = function() return false, "mirror not configured" end}
check("status: unavailable reason is visible",
      wiz_status():find("mirror not configured", 1, true) ~= nil)
ferry = {available = function() return true end}
check("status: configured Ferry is available",
      wiz_status():find("Ferry: available", 1, true) ~= nil)
ferry = nil
wizard.on_unload()

print(failures == 0 and "ALL PASS" or (failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
