-- Wizard file browser, driven by the wizard-only Files.List GMCP package
-- (mudlib: secure/pinc/gmcp.h, daemon/gmcp_files_d.c).
--
-- Request/response only. Nothing pushes, there is no cd hook, and no
-- subscription to hold -- so this plugin is responsible for noticing that the
-- wizard moved, and does it by watching cd's own confirmation line.

local M = {}
M.name = "wizard"
M.version = "1.0"
M.priority = 50

local actions = require("actions")
local complete = require("complete")
local protocol = require("protocol")
local ferry_actions = require("ferry_actions")
-- Captured at load for the same reason actions.lua does it: offer() below runs
-- from M.complete(), which the profile drives from a `bind` -- trusted code,
-- outside this plugin's capability, where a call-time require() raises "plugin
-- capability is inactive". The completion menu only opens for an AMBIGUOUS
-- prefix, so this had gone unnoticed: an unambiguous tab inserts and never
-- reaches the menu.
local menu = require("menu")

M.pane = require("pane")

-- require("command") is optional: a profile that never required 'commands' has
-- no registry, and the pane still works.
local command
do
  local ok, mod = pcall(require, "command")
  if ok then command = mod end
end

local command_id = nil
local gmcp_ids = {}
local trigger_ids = {}
local cd_pending = false
local cd_asked = false   -- 1 seed request per cd, see on_line()

-- ---- cwd tracking ---------------------------------------------------------

local CD_FAILURES = {
  ["No such directory."] = true,
  ["Invalid path with spaces in it."] = true,
}

-- A line the user typed dispatches on_input; a scripted mud.send() dispatches
-- on_send (src/core/session.c:422 vs src/lua/api_mud.c:113). Both must arm the
-- flag. The pane's click-to-navigate sends a real `cd` through mud.send, so
-- without on_send a clicked cd moves the MUD and leaves the pane behind.
--
-- Arming on any scripted cd is deliberate, not just a fix for our own click: a
-- cd from a user alias or another plugin should move the pane too, which is
-- what keeps one source of truth for the working directory.
local function arm_if_cd(text)
  if type(text) == "string" then
    -- The first word must be exactly "cd": `cdtest foo` is a different command.
    local first = text:match("^%s*(%S+)")
    if first == "cd" then cd_pending = true; cd_asked = false end
  end
  return text
end

function M.on_input(text)
  -- A view started from the pane is a filter over output; typing anything that
  -- is not a pager key ends it (actions.on_input decides which).
  actions.on_input(text)
  return arm_if_cd(text)
end
function M.on_send(text) return arm_if_cd(text) end

function M.on_line(line)
  if cd_pending and type(line) == "string" then
    -- cd's three failure lines report and leave current_path alone.
    if CD_FAILURES[line] or line:match("^Illegal directory: ") then
      cd_pending = false
    elseif not cd_asked then
      -- ASK, rather than read the screen. The confirmation trigger below is
      -- the fast path, but it only matches a line that is exactly the path:
      -- a prompt sent without a trailing newline is assembled onto the front
      -- of the next line ("> /players/shaman") and the anchored pattern stops
      -- matching, which left the pane sitting on the old directory forever.
      -- A bodyless Files.List request is the server answering "where am I",
      -- and it cannot be spelled wrong by a prompt. Sent once per cd, on the
      -- first line back, so the MUD has already processed the cd.
      cd_asked = true
      protocol.request(nil)
    end
  end
  -- Syntax highlighting for a file being paged through `more`, and a no-op at
  -- every other moment. Last, so the cwd tracking above always sees the line
  -- exactly as the MUD sent it.
  return actions.on_line(line)
end

-- A cd confirmation is a real path, and the trigger's "slash then non-space"
-- is looser than that. A prompt is free to draw a rule line --
-- "/-----------\" -- which is a slash followed by non-space characters and
-- matches the trigger exactly. Two things separate the two: a path has at
-- least one alphanumeric character somewhere, and it never contains a
-- backslash.
local function looks_like_path(text)
  if type(text) ~= "string" then return false end
  if text:find("\\", 1, true) then return false end
  return text:find("%w") ~= nil
end

-- The confirmation: cd writes exactly "/<resolved path>" and nothing else on
-- success (secure/pinc/wiz.h:46). Guarded by cd_pending because this pattern
-- alone matches any output line that happens to be a bare path.
local function on_cd_confirmed(_, path)
  if not cd_pending then return end
  cd_asked = false
  -- Decoration between the cd and its confirmation leaves the arm standing:
  -- disarming here would spend the cd on the decoration and leave the pane on
  -- the old directory for good.
  if not looks_like_path(path) then return end
  cd_pending = false
  protocol.set_cwd(path)
  protocol.invalidate(protocol.cwd())
  protocol.request(protocol.cwd())
end

-- ---- GMCP -----------------------------------------------------------------

-- Files.List is advertised only to a wizard (secure/protocol/gmcp_core_impl.h),
-- so Core.Supported is a real signal rather than a timeout on silence.
local function on_core_supported(_, data)
  local ok = type(data) == "table" and data["Files.List"] ~= nil
  protocol.set_available(ok and true or false)
  if ok then protocol.request(nil) end
  if ui and ui.dirty then ui.dirty() end
end

-- ---- completion -----------------------------------------------------------

local function insert_completion(ctx, prefix, text)
  local line, cursor = complete.apply(input.text(), ctx, prefix, text)
  input.set_text(line)
  -- input.set_text leaves the cursor at the end of the new text; nothing else
  -- in the API can place it, so a mid-line completion moves the cursor to the
  -- end of the line. Acceptable: completing mid-line is rare, and the inserted
  -- text is still what the user asked for.
  return cursor
end

local function offer(ctx, prefix, entry, kind)
  local decision = complete.decide(
    complete.candidates(entry.dirs, entry.files, prefix, kind), prefix)
  if not decision then return end

  if decision.action == "insert" then
    insert_completion(ctx, prefix, decision.text)
    return
  end

  local line = input.text()
  menu.open({
    items = decision.items,
    title = "Complete",
    restore_input = line,
    on_select = function(value)
      -- The menu restores the snapshotted input before this runs, so writing
      -- here is the write that survives.
      insert_completion(ctx, prefix, value)
    end,
  })
end

-- The pane title reads this (see the simon profile).
function M.cwd() return protocol.cwd() end

function M.complete()
  if not protocol.available() then return end

  local line = input.text()
  local ctx = complete.context(line, input.cursor())
  if not ctx then return end

  local rule = complete.rule(ctx.command)
  if rule.kind == "none" then return end
  if ctx.arg_index > 0 and ctx.arg_index < rule.from_arg then return end

  local dir, prefix = complete.split(ctx.word)
  local abs = protocol.resolve(dir, protocol.cwd(), protocol.home())
  if not abs then return end

  local entry = protocol.lookup(abs)
  if entry and entry.complete then
    if entry.error then return end
    offer(ctx, prefix, entry, rule.kind)
    return
  end

  -- A miss requests and completes when the reply lands. The line may have moved
  -- on by then, so the context is re-derived rather than reused.
  protocol.request(abs, function(fresh)
    if fresh.error then return end
    local now = complete.context(input.text(), input.cursor())
    if not now or now.word ~= ctx.word then return end
    offer(now, prefix, fresh, rule.kind)
  end)
end

-- ---- /wiz -----------------------------------------------------------------

local function wiz_command(args)
  local sub, rest = (args or ""):match("^(%S*)%s*(.*)$")

  if sub == "" then
    print("[wizard] cwd: " .. (protocol.cwd() or "(unknown)"))
    print("[wizard] home: " .. (protocol.home() or "(unknown)"))
    print("[wizard] Files.List: " ..
          (protocol.available() and "available" or "unavailable (not a wizard?)"))
    local available, reason = ferry_actions.available()
    print("[wizard] Ferry: " .. (available and "available" or
          "unavailable (" .. tostring(reason) .. ")"))
    return
  end

  if sub == "refresh" then
    local cwd = protocol.cwd()
    if not cwd then print("[wizard] no known directory yet") return end
    protocol.invalidate(cwd)
    protocol.request(cwd)
    print("[wizard] refreshing " .. cwd)
    return
  end

  if sub == "cd" then
    if rest == "" then print("[wizard] usage: /wiz cd <path>") return end
    mud.send("cd " .. rest)
    return
  end

  if sub == "ls" then
    local target = (rest ~= "") and rest or protocol.cwd()
    if not target then print("[wizard] no known directory yet") return end
    local abs = protocol.resolve(target, protocol.cwd(), protocol.home())
    if not abs then print("[wizard] cannot resolve " .. target) return end
    protocol.request(abs, function(entry)
      if entry.error then
        print("[wizard] " .. abs .. ": " .. entry.error)
        return
      end
      for i = 1, #entry.dirs do print("  " .. entry.dirs[i] .. "/") end
      for i = 1, #entry.files do print("  " .. entry.files[i]) end
      if entry.truncated then print("  (listing truncated)") end
    end)
    return
  end

  print("[wizard] usage: /wiz [refresh | cd <path> | ls [path]]")
end

-- ---- lifecycle ------------------------------------------------------------

function M.on_load()
  gmcp_ids[#gmcp_ids + 1] = gmcp.on("Files.List", protocol.on_message)
  gmcp_ids[#gmcp_ids + 1] = gmcp.on("Core.Supported", on_core_supported)
  trigger_ids[#trigger_ids + 1] = trigger.add("^(/\\S*)$", on_cd_confirmed)
  -- Owns its own trigger (uall's confirmation prompt); registered here so the
  -- plugin has one load/unload story.
  actions.install()

  -- Say once, on load, whether Ferry is there. Everything else about this
  -- plugin announces itself by existing -- the pane, the menus -- but a
  -- missing Ferry shows up only as rows that are not on a menu, which looks
  -- exactly like something being broken.
  do
    local available, reason = ferry_actions.available()
    print("[wizard] Ferry: " .. (available and "available -- pull/push/cc are on the file menu"
          or ("unavailable (" .. tostring(reason) .. ")")))
  end

  if command and not command.get("/wiz") then
    local id, err = command.register({
      name = "/wiz",
      usage = "/wiz [refresh | cd <path> | ls [path]]",
      summary = "Wizard file browser",
      description = "Show the tracked working directory and Files.List/Ferry "
        .. "availability, refresh the file pane, change directory, or print a "
        .. "listing to the output buffer.",
      accepts_args = true,
      handler = wiz_command,
    })
    if id then command_id = id
    else print("[wizard] command registration failed: " .. tostring(err)) end
  end
end

function M.on_connect()
  protocol.reset()
end

function M.on_disconnect()
  -- The server drops its whole state on disconnect, so retained cache, cwd and
  -- availability would all be claims we can no longer support.
  protocol.reset()
  cd_pending = false
  -- An armed uall must not answer the first prompt of the NEXT session.
  actions.reset()
end

function M.on_unload()
  ferry_actions.cleanup()
  for i = 1, #gmcp_ids do gmcp.remove(gmcp_ids[i]) end
  for i = 1, #trigger_ids do trigger.remove(trigger_ids[i]) end
  actions.remove()
  if command and command_id then command.unregister(command_id) end
end

return M
