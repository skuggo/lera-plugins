-- Directory actions for the wizard file pane: uall and lall, each behind one
-- confirmation.
--
-- Both are plain MUD commands (cmds/secure/uall.c, cmds/secure/lall.c), so
-- running one is just mud.send. What this module owns is the asking:
--
--   * ONE confirmation, in the client, before anything is sent. Recompiling a
--     directory is not an action a stray click should perform.
--   * The MUD's own second prompt. Outside /players, uall writes "You are
--     about to update all the files in the directory:" and drops into
--     input_to for a y/n (uall.c:38-45). Having already asked, this answers
--     that prompt itself, so one click is one question -- see AUTO-ANSWER.
--
-- Nothing here is privileged: the MUD re-checks the caller on every command,
-- exactly as it does for a typed one. A confirmation this side is a guard
-- against the accident, not against the wizard.

local lpc = require("lpc")

-- The menus are drawn by the PANE, through overlay.lua, rather than by the
-- client's require("menu") -- which anchors above the input bar, nowhere near
-- the file that was clicked. See overlay.lua's header.
--
-- (Historical note worth keeping: require() is a guarded plugin API. It works
-- while this plugin's capability is active -- during load, and inside a hook
-- the dispatcher calls -- and raises "plugin capability is inactive" anywhere
-- else, which a wm pointer callback is. Any module a click path needs must
-- therefore be captured at load, as these two are.)
local ferry_actions = require("ferry_actions")

-- Ferry is a NATIVE api in the client now (lera's `ferry` global, wrapped by
-- ferry_actions). available() answers with a reason as its second return, so
-- this keeps only the boolean for the menus, which just need to know whether
-- to offer the rows at all.
local function ferry_available()
  local ok = ferry_actions.available()
  return ok and true or false
end
local overlay = require("overlay")
local protocol = require("protocol")

local M = {}

-- Forward declaration: reset() below tears down the view filter, which is
-- defined further down with the rest of the viewing state. Without this the
-- name would resolve to a nil GLOBAL at that call site rather than to the
-- local, and reset() would error the first time a disconnect ran it.
local stop_viewing
local walk        -- the recursive uall/lall in progress; see run_recursive()

-- ---- the commands ----------------------------------------------------------

-- Order is the order the buttons are drawn in.
M.COMMANDS = {
  { cmd = "uall", label = "[uall]", verb = "Recompile every file in" },
  { cmd = "lall", label = "[lall]", verb = "Load every unloaded file in" },
}

local BY_CMD = {}
for i = 1, #M.COMMANDS do BY_CMD[M.COMMANDS[i].cmd] = M.COMMANDS[i] end

-- ---- auto-answer -----------------------------------------------------------

-- uall's prompt is answered only when we are the ones who asked for it, and
-- only briefly. The window exists so a prompt that arrives minutes later --
-- because the wizard typed their own uall in the meantime, say -- is theirs to
-- answer, not ours to swallow.
local ANSWER_WINDOW = 10

-- The line matched is the FIRST line of uall's confirmation block, not the
-- "(y/n) : " prompt itself: that last one is written without a newline, so it
-- reaches the client as a prompt rather than as a line a trigger can see.
local UALL_CONFIRM = "^You are about to update all the files in the directory:"

-- A COUNT, not a single path: a recursive uall sends one command per
-- directory and the MUD prompts once for each. Every prompt we caused is ours
-- to answer; the count is what says how many that is.
local pending = nil       -- { path = ..., count = n, at = os.time() }
local trigger_id = nil

local function arm(path)
  local count = (pending and pending.count or 0) + 1
  pending = { path = path, count = count, at = os.time() }
end

local function disarm()
  pending = nil
end

-- Exposed for the tests, and for anything that wants to know whether a click
-- is still waiting on the MUD.
function M.pending()
  return pending and pending.path or nil
end

function M.pending_count()
  return pending and pending.count or 0
end

local function on_uall_prompt()
  if not pending then return end
  -- The window is measured from the LAST send, so a long recursive walk keeps
  -- refreshing it rather than timing out halfway down the tree.
  if os.time() - pending.at > ANSWER_WINDOW then
    disarm()
    return
  end
  pending.count = pending.count - 1
  if pending.count <= 0 then disarm() end
  mud.send("y")
end

function M.install()
  if trigger_id then return end
  trigger_id = trigger.add(UALL_CONFIRM, on_uall_prompt)
end

function M.remove()
  if not trigger_id then return end
  trigger.remove(trigger_id)
  trigger_id = nil
  disarm()
end

-- A disconnect cannot leave a stale arm behind to answer the first prompt of
-- the next session.
function M.reset()
  disarm()
  stop_viewing()
  -- A walk whose replies never arrived (a dropped connection mid-walk) would
  -- otherwise refuse every later one as "already running".
  if walk and walk.timer then timer.cancel(walk.timer) end
  walk = nil
end

-- ---- running ---------------------------------------------------------------

-- Send it. Separated from confirm() so a test (and a future keybind) can drive
-- the command without going through the menu.
function M.run(cmd, path)
  local spec = BY_CMD[cmd]
  if not spec or type(path) ~= "string" or path == "" then return false end
  if cmd == "uall" then arm(path) end
  mud.send(cmd .. " " .. path)
  return true
end

-- ---- recursive ---------------------------------------------------------------

-- uall and lall are ONE directory each: uall.c walks get_dir(path + "*") and
-- lall.c get_dir(path + "*.c"), neither descending (uall.c:66, lall.c:37).
-- There is no -r on the MUD side to ask for.
--
-- So the walk happens here. The pane already has a directory listing over
-- GMCP, which is the same information a recursive uall would need, and every
-- directory it finds gets its own ordinary command. The MUD sees exactly what
-- a wizard typing uall in each folder would send -- no new privilege, no new
-- server code.
--
-- Bounded, because "this directory and everything in it" pointed at /players
-- is a very large promise -- and both bounds are reported when hit rather than
-- silently truncating:
--
--   MAX_SCAN   folders LISTED. Cheap (a GMCP listing each), and generous so
--              data-heavy trees are still searched all the way down: a guild
--              like /players/elemental is 648 folders of which only 23 hold
--              any code.
--   MAX_DIRS   commands SENT. Only folders that contain .c files get one --
--              lall loads *.c and uall recompiles loaded objects, so a folder
--              of data files has nothing for either to do. Sending to every
--              folder spent the whole budget on encyclopedia pages.
--   MAX_DEPTH  how far down the walk goes at all.
--
-- The commands are PACED, one per SEND_GAP_MS, from a queue. They used to go
-- out in a single burst: hundreds of commands in one instant, most of them
-- dropped by the MUD's command queue, and the output a wall of spam.
local MAX_DIRS = 200
local MAX_SCAN = 2000
local MAX_DEPTH = 8
local SEND_GAP_MS = 500

-- { cmd, root, scanned, queued, sent, queue, outstanding, timer, stopped,
--   reason }; forward-declared above.

local function has_code(entry)
  local files = entry and entry.files
  if type(files) ~= "table" then return false end
  for i = 1, #files do
    local f = files[i]
    local name = type(f) == "table" and f.name or f
    if type(name) == "string" and name:match("%.c$") then return true end
  end
  return false
end

local function walk_report()
  if not walk or walk.outstanding > 0 or #walk.queue > 0 then return end
  local verb = (walk.cmd == "uall") and "recompiled" or "loaded"
  local msg = "[wizard] " .. walk.cmd .. " -r " .. walk.root .. ": " ..
              walk.sent .. " folder" .. (walk.sent == 1 and "" or "s") ..
              " with code " .. verb .. " (" .. walk.scanned .. " scanned)"
  if walk.reason then msg = msg .. " -- " .. walk.reason end
  print(msg)
  if walk.timer then timer.cancel(walk.timer) end
  walk = nil
end

-- One command per tick. Keeps ticking while listings are still arriving, so a
-- folder found late still gets its turn; reports once both are exhausted.
local function pump()
  if not walk then return end
  walk.timer = nil
  local path = table.remove(walk.queue, 1)
  if path then
    walk.sent = walk.sent + 1
    M.run(walk.cmd, path)
  end
  if #walk.queue > 0 or walk.outstanding > 0 then
    walk.timer = timer.after(SEND_GAP_MS, pump)
  else
    walk_report()
  end
end

local function enqueue(path)
  if walk.queued >= MAX_DIRS then
    walk.stopped = true
    walk.reason = "stopped at the " .. MAX_DIRS .. "-folder limit"
    return
  end
  walk.queued = walk.queued + 1
  walk.queue[#walk.queue + 1] = path
  if not walk.timer then walk.timer = timer.after(0, pump) end
end

local function visit(path, depth)
  if not walk or walk.stopped then return end
  if walk.scanned >= MAX_SCAN then
    walk.stopped = true
    walk.reason = "stopped after scanning " .. MAX_SCAN .. " folders"
    return
  end
  walk.scanned = walk.scanned + 1

  -- A directory we cannot read is not a failure of the whole walk: the wizard
  -- simply has no access there, and the rest still runs.
  local function on_listing(entry)
    if not walk or not entry or entry.error then return end
    if has_code(entry) then enqueue(path) end
    if depth >= MAX_DEPTH then
      if entry.dirs and #entry.dirs > 0 then
        walk.reason = walk.reason or ("depth " .. MAX_DEPTH .. " reached; deeper folders skipped")
      end
      return
    end
    for i = 1, #(entry.dirs or {}) do
      local child = protocol.resolve(entry.dirs[i], path, protocol.home())
      if child then visit(child, depth + 1) end
    end
  end

  -- The pane has usually just listed the directory the walk starts in, and
  -- request() always goes to the wire. Reusing a complete cached listing saves
  -- a round trip per directory; a listing stale enough to miss a folder
  -- created seconds ago is an acceptable trade for a bulk recompile.
  local cached = protocol.lookup(path)
  if cached and cached.complete and not cached.error then
    on_listing(cached)
    return
  end

  walk.outstanding = walk.outstanding + 1
  protocol.request(path, function(entry)
    if not walk then return end
    walk.outstanding = walk.outstanding - 1
    on_listing(entry)
    -- The last listing can land after the queue already drained.
    if not walk.timer then walk.timer = timer.after(0, pump) end
  end)
end

-- Run `cmd` against `root` and every directory beneath it that holds code.
-- Returns false when one is already running -- two overlapping walks would
-- interleave their commands and make the reported count meaningless.
function M.run_recursive(cmd, root)
  if not BY_CMD[cmd] or type(root) ~= "string" or root == "" then return false end
  if walk then
    print("[wizard] a recursive " .. walk.cmd .. " is already running")
    return false
  end
  walk = { cmd = cmd, root = root, scanned = 0, queued = 0, sent = 0,
           queue = {}, outstanding = 0 }
  visit(root, 1)
  if walk and not walk.timer then walk.timer = timer.after(0, pump) end
  return true
end

function M.walking()
  return walk and walk.cmd or nil
end

-- ---- files -----------------------------------------------------------------

-- What a click on a FILE offers. Both are ordinary wizard commands:
--
--   view -- `more <path>`, the mudlib's own pager (cmds/secure/more.c). It
--           prints into the output pane. When the MUD grows a Files.Read to
--           match Files.List, this is the entry that becomes an in-pane,
--           syntax-highlighted viewer; until then it is the real thing a
--           wizard would type.
--   ul   -- `ul <path>`: update AND load, i.e. destruct the object and reload
--           it (cmds/secure/ul.c). The everyday "I just edited this" command.
--
-- No extra confirmation: unlike a button that recompiles a whole directory,
-- picking an item out of this menu IS the deliberate choice, and neither of
-- these reaches further than the one file that was clicked.
-- Everything the MUD offers on a single file, as one menu. Each entry is a
-- real wizard command (cmds/secure/*.c) with the path appended -- nothing here
-- is invented, and nothing needs a second argument, which is what keeps cp and
-- mv out: a click has nowhere to type a destination.
--
--   send    the command word; the absolute path is appended
--   run     for entries that are not a plain send (view arms the highlighter)
--   confirm destructive enough to ask first
-- label is the command word, desc is what it does. They are separate so the
-- menu can align them into two columns and colour them apart: you aim at the
-- command, you read the explanation once.
M.FILE_ACTIONS = {
  -- The left-click default too, so the menu shows what a plain click does.
  { key = "view",   label = "view",   desc = "page it here, highlighted",
    run = function(p) M.view(p) end },
  -- Unpaged and unpainted: the highlighter keys off the pager's EOF marker to
  -- know when a file ends, and a bare cat gives it no such end.
  { key = "cat",    label = "cat",    desc = "dump it raw, no pager",  send = "cat" },
  { key = "head",   label = "head",   desc = "just the first lines",   send = "head" },
  { key = "cc",     label = "cc",     desc = "compile-check it",       send = "cc" },
  { key = "ed",     label = "ed",     desc = "open the line editor",   send = "ed" },
  { key = "ul",     label = "ul",     desc = "update and load",        send = "ul" },
  { key = "update", label = "update", desc = "destruct the loaded object", send = "update" },
  { key = "load",   label = "load",   desc = "load it",                send = "load" },
  -- rm asks nothing of its own (cmds/secure/rm.c just removes and reports),
  -- and a file is not something a misclick should delete.
  { key = "rm",     label = "rm",     desc = "delete the file for good",
    send = "rm", confirm = true, kind = "danger" },
}

-- ferry, through the client's native API (ferry_actions -> lera's `ferry`).
-- These are NOT
-- MUD commands: they move the file between the MUD and a local mirror
-- checkout, through a process outside Lera, because the plugin sandbox has no
-- disk of its own.
--
-- They are appended to the menu only when a bridge is actually listening, so
-- a wizard without one sees exactly the MUD-command menu and nothing that
-- would fail if clicked.
M.FERRY_ACTIONS = {
  { key = "ferry-pull", label = "pull", desc = "ferry: MUD -> local mirror", op = "pull",
    confirm = true },
  { key = "ferry-push", label = "push", desc = "ferry: local mirror -> MUD",  op = "push",
    kind = "danger", confirm = true },
  { key = "ferry-cc",   label = "cc!",  desc = "ferry: compile-check remotely", op = "cc" },
}

-- The same three against a DIRECTORY. pull and push recurse in ferry itself,
-- so "everything under it" is ferry's own behaviour rather than a walk this
-- plugin drives -- unlike uall/lall, where the MUD has no recursion at all.
M.FERRY_DIR_ACTIONS = {
  { key = "ferry-pull", label = "pull", desc = "ferry: this folder and below, MUD -> here",
    op = "pull", confirm = true },
  { key = "ferry-push", label = "push", desc = "ferry: this folder and below, here -> MUD",
    op = "push", kind = "danger", confirm = true },
  { key = "ferry-cc",   label = "cc!",  desc = "ferry: compile-check every .c below",
    op = "cc" },
}

-- What the confirmation says the scope is, when a directory was clicked.
M.FERRY_DIR_SCOPE = {
  pull = "and everything under it",
  push = "and everything under it (minus data/ and junk)",
}

-- ---- viewing ---------------------------------------------------------------

-- `more` sends the file through the ordinary output stream, so highlighting it
-- means painting those lines as they arrive: on_line() below is a filter that
-- runs only while a view we started is in progress.
--
-- Bounded three ways, because a filter that stays armed would eventually paint
-- something that is not a file: the pager's own EOF marker, any input that is
-- not a pager key, and a hard line cap.
local MAX_VIEW_LINES = 20000

-- The pager's status line: "More: [path] Line: [26/26] Cmds: [u/d/q] EOF".
--
-- It is not always a line of its own. `more` writes the status without a
-- trailing newline, so the next page's FIRST line arrives joined to it:
--
--   More: [x.c] Line: [48/48] Cmds: [u/d/q] #pragma strict_types
--
-- Treating the whole thing as furniture -- which is what matching only the
-- prefix did -- left that line, and so the first line of every page after the
-- first, unpainted. Split it instead: the status stays plain and whatever
-- follows is file content like any other.
local PAGER_STATUS = "^More: %["

-- Returns the status run and the rest of the line, or nil when this is not a
-- status line at all. The rest is "" for a status line that does stand alone.
local function split_pager(line)
  if not line:match(PAGER_STATUS) then return nil end
  -- Anchored on the LAST bracketed field (Cmds), so a path containing "] "
  -- cannot end the match early.
  local head, rest = line:match("^(More: %[.*Cmds: %[[^%]]*%]%s*)(.*)$")
  if not head then return line, "" end
  return head, rest
end

-- What `more` reads at its prompt. Anything else the wizard types means they
-- have moved on, whatever the pager thinks.
local PAGER_KEYS = { u = true, d = true, q = true, [""] = true }

local viewing = nil   -- { path = ..., state = ..., lines = 0, paint = bool }

function M.viewing()
  return viewing and viewing.path or nil
end

function stop_viewing()
  viewing = nil
end

function M.view(path)
  if type(path) ~= "string" or path == "" then return false end
  viewing = {
    path = path,
    state = lpc.new_state(),
    lines = 0,
    -- A .o save file or a log goes through untouched: there is nothing to
    -- highlight and guessing would only mangle it.
    paint = lpc.applies(path),
  }
  mud.send("more " .. path)
  return true
end

-- Returns the line to display. Painted while a view is running, otherwise
-- exactly what came in.
function M.on_line(line)
  if not viewing or type(line) ~= "string" then return line end

  local head, rest = split_pager(line)
  if head then
    -- EOF, when present, sits immediately after the status and marks the clean
    -- end of the file. Anything after THAT is still content.
    local eof = rest:match("^EOF%s*")
    if eof then
      head = head .. eof
      rest = rest:sub(#eof + 1)
    end

    local painted = rest
    if viewing.paint and rest ~= "" and not rest:find("\27", 1, true) then
      painted, viewing.state = lpc.line(rest, viewing.state)
    end

    -- Stop AFTER painting the tail: the content on an EOF line is the last of
    -- the file and deserves colour as much as the rest of it.
    if eof then stop_viewing() end
    return head .. painted
  end

  viewing.lines = viewing.lines + 1
  if viewing.lines > MAX_VIEW_LINES then
    stop_viewing()
    return line
  end

  if not viewing.paint then return line end
  -- A line that already carries colour is someone else's: leave it be rather
  -- than nesting escapes inside it.
  if line:find("\27", 1, true) then return line end

  local painted, state = lpc.line(line, viewing.state)
  viewing.state = state
  return painted
end

-- Typing anything that is not a pager key ends the view, whether or not the
-- pager agrees -- a disconnect mid-file would otherwise leave the filter armed
-- over ordinary output.
function M.on_input(text)
  if not viewing then return end
  local key = (text or ""):match("^%s*(%S*)%s*$")
  if not key or not PAGER_KEYS[key:lower()] then stop_viewing() end
end

function M.file_menu(path, anchor, entry)
  if type(path) ~= "string" or path == "" then return false end
  -- Resolve what was clicked NOW, so the rows act on this file even after the
  -- pane has moved on (see ferry_actions.start).
  local selection = ferry_available() and ferry_actions.selection(entry) or nil

  local items = {}
  for i = 1, #M.FILE_ACTIONS do
    local spec = M.FILE_ACTIONS[i]
    items[i] = { label = spec.label, desc = spec.desc, value = spec.key, kind = spec.kind }
  end
  -- Only when a bridge answers. An entry that cannot work should not be on
  -- the menu at all: a greyed-out row still invites the click.
  if ferry_available() then
    for i = 1, #M.FERRY_ACTIONS do
      local spec = M.FERRY_ACTIONS[i]
      items[#items + 1] = { label = spec.label, desc = spec.desc,
                            value = spec.key, kind = spec.kind }
    end
  end
  -- Always a way out that does not depend on hitting the strip of pane
  -- outside the box -- which a full-width menu barely leaves -- and there is
  -- no Escape to fall back on: bind is not in the plugin sandbox.
  items[#items + 1] = { label = "cancel", desc = "close this menu",
                        value = "", kind = "cancel" }

  overlay.open({
    -- The basename: the pane is already titled with the directory, and a full
    -- path would set the menu's width to something the pane cannot hold.
    title = path:match("([^/]+)$") or path,
    anchor = anchor,
    items = items,
    on_select = function(value)
      if value == "" then return end
      for i = 1, #M.FERRY_ACTIONS do
        local spec = M.FERRY_ACTIONS[i]
        if spec.key == value then
          -- push overwrites what is on the MUD with what is on disk, which is
          -- not a click's worth of consequence on its own.
          if spec.confirm then
            M.confirm_ferry(spec.op, path, anchor, nil, selection or entry)
          else
            ferry_actions.start(spec.op, selection or entry)
          end
          return
        end
      end
      for i = 1, #M.FILE_ACTIONS do
        local spec = M.FILE_ACTIONS[i]
        if spec.key == value then
          if spec.run then spec.run(path)
          elseif spec.confirm then
            M.confirm_command(spec.send .. " " .. (path:match("([^/]+)$") or path),
                              spec.send .. " " .. path, anchor)
          else
            mud.send(spec.send .. " " .. path)
          end
          return
        end
      end
    end,
  })
  return true
end

-- What a right-click on a DIRECTORY offers: the same two commands the buttons
-- run, against that folder rather than the cwd. Each still goes through
-- confirm(), so the menu narrows the target and the box asks the question.
-- The same two-way choice the directory menu offers, for ONE command against
-- a path: flat, or with everything under it. The toolbar buttons come through
-- here so "this directory and everything in it" is reachable for the
-- directory you are standing in, not only for a folder you can see listed.
function M.command_menu(cmd, path, anchor)
  if not BY_CMD[cmd] or type(path) ~= "string" or path == "" then return false end

  overlay.open({
    title = cmd .. " " .. (path:match("([^/]+)$") or path),
    anchor = anchor,
    items = {
      { label = cmd,          value = cmd,          desc = "this folder only" },
      { label = cmd .. " -r", value = cmd .. " -r", desc = "...and every folder under it" },
      { label = "cancel",     value = "",           desc = "close this menu",
        kind = "cancel" },
    },
    on_select = function(value)
      if value == "" then return end
      M.confirm(value, path, anchor)
    end,
  })
  return true
end

function M.dir_menu(path, anchor, entry)
  if type(path) ~= "string" or path == "" then return false end
  local selection = ferry_available() and ferry_actions.selection(entry) or nil

  local items = {}
  for i = 1, #M.COMMANDS do
    local cmd = M.COMMANDS[i].cmd
    items[#items + 1] = { label = cmd, value = cmd,
                          desc = (cmd == "uall") and "recompile this folder"
                                                  or "load this folder" }
    -- "and everything in it": the same command against this folder and every
    -- folder beneath it, walked client-side.
    items[#items + 1] = { label = cmd .. " -r", value = cmd .. " -r",
                          desc = "...and every folder under it" }
  end
  if ferry_available() then
    for i = 1, #M.FERRY_DIR_ACTIONS do
      local spec = M.FERRY_DIR_ACTIONS[i]
      items[#items + 1] = { label = spec.label, desc = spec.desc,
                            value = spec.key, kind = spec.kind }
    end
  end
  items[#items + 1] = { label = "cancel", desc = "close this menu",
                        value = "", kind = "cancel" }

  overlay.open({
    title = path:match("([^/]+)$") or path,
    anchor = anchor,
    items = items,
    -- The confirmation replaces this menu in the same place, so the answer
    -- appears where the question was asked.
    on_select = function(value)
      if value == "" then return end
      for i = 1, #M.FERRY_DIR_ACTIONS do
        local spec = M.FERRY_DIR_ACTIONS[i]
        if spec.key == value then
          if spec.confirm then
            M.confirm_ferry(spec.op, path, anchor, M.FERRY_DIR_SCOPE[spec.op], selection or entry)
          else
            ferry_actions.start(spec.op, selection or entry)
          end
          return
        end
      end
      M.confirm(value, path, anchor)
    end,
  })
  return true
end

-- The box, drawn in the pane at the point of the click.
--
-- "No" is first: it is the row nearest the pointer, so the cheap, wrong
-- reflex -- clicking again without reading -- is the harmless answer. A click
-- anywhere outside the box also cancels.
-- Ask before one arbitrary command. `label` is what the box offers as the
-- Yes row; `command` is sent verbatim on yes.
function M.confirm_command(label, command, anchor)
  if type(command) ~= "string" or command == "" then return false end
  overlay.open({
    title = "Are you sure?",
    anchor = anchor,
    items = {
      { label = "no",  value = "no",  desc = "leave it alone", kind = "cancel" },
      { label = "yes", value = "yes", desc = label or command, kind = "danger" },
    },
    on_select = function(value)
      if value == "yes" then mud.send(command) end
    end,
  })
  return true
end

-- The running job, and the one thing worth doing to it. Reached by
-- right-clicking anywhere in the pane while it runs -- the thing you want to
-- stop is not a row you can point at.
function M.cancel_menu(anchor)
  local what = ferry_actions.describe()
  if not what then return false end
  overlay.open({
    title = what,
    anchor = anchor,
    items = {
      { label = "keep going", desc = "leave it running", value = "", kind = "cancel" },
      { label = "abort", desc = "stop this job", value = "abort", kind = "danger" },
    },
    on_select = function(value)
      if value == "abort" then ferry_actions.cancel() end
    end,
  })
  return true
end

-- The same box as confirm_command, for a ferry verb rather than a MUD one.
-- `extra` spells out the scope when it is wider than the thing clicked --
-- "and everything under it" for a directory -- so the box says what will
-- actually happen rather than naming one folder.
function M.confirm_ferry(op, path, anchor, extra, entry)
  local name = path:match("([^/]+)$") or path
  overlay.open({
    title = "Are you sure?",
    anchor = anchor,
    items = {
      { label = "no",  value = "no",  desc = "leave it alone", kind = "cancel" },
      { label = "yes", value = "yes", kind = "danger",
        desc = "ferry " .. op .. " " .. name .. (extra and (" " .. extra) or "") },
    },
    on_select = function(value)
      if value == "yes" then ferry_actions.start(op, entry) end
    end,
  })
  return true
end

function M.confirm(cmd, path, anchor)
  -- "uall -r" arrives as one string from the menu; split it back apart.
  local base, recursive = cmd:match("^(%S+)%s*(%-?r?)$")
  base = base or cmd
  recursive = (recursive == "-r")

  local spec = BY_CMD[base]
  if not spec or type(path) ~= "string" or path == "" then return false end

  local name = path:match("([^/]+)$") or path
  overlay.open({
    title = recursive and (base .. " -r?") or (base .. "?"),
    anchor = anchor,
    items = {
      { label = "no",  value = "no", desc = "leave it alone", kind = "cancel" },
      { label = "yes", value = "yes",
        desc = recursive and (base .. " " .. name .. " + subfolders")
                          or (base .. " " .. name) },
    },
    on_select = function(value)
      if value ~= "yes" then return end
      if recursive then M.run_recursive(base, path) else M.run(base, path) end
    end,
  })
  return true
end

return M
