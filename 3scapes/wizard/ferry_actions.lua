-- Native Ferry jobs initiated by the wizard pane. Paths and menu ownership
-- are captured when opened; neither a later cd nor another plugin's menu can
-- redirect a confirmation or make cleanup close the wrong menu.
local protocol = require("protocol")
local M = {}
local active = true
local job = nil
local menu_owner = nil

local function report(text) print("[wizard] Ferry " .. text) end

function M.available()
  if not ferry or type(ferry.available) ~= "function" then
    return false, "native API unavailable"
  end
  return ferry.available()
end

function M.running()
  if job and job.api.running() == job.id then return job.id end
  return nil
end

local function open_menu(title, items, selected)
  local menu = require("menu")
  local owner = {menu = menu}
  menu.open({
    title = title,
    items = items,
    on_select = function(value)
      if menu_owner ~= owner then return end
      menu_owner = nil
      if active then selected(value) end
    end,
    on_cancel = function()
      if menu_owner == owner then menu_owner = nil end
    end,
  })
  -- open() cancels any previous menu synchronously before installing ours.
  menu_owner = owner
  return true
end

local function valid_selection(selection)
  if not protocol.available() then return false end
  local entry = protocol.lookup(selection.parent)
  if not entry or not entry.complete or entry.error then return false end
  local names = selection.is_dir and entry.dirs or entry.files
  for _, name in ipairs(names) do
    if name == selection.name then return true end
  end
  return false
end

local function launch(op, selection)
  if not active then return end
  if not valid_selection(selection) then
    report("selection is no longer available: " .. selection.path)
    return
  end
  local available, reason = M.available()
  if not available then report("unavailable: " .. tostring(reason)); return end
  if ferry.running() then report("another job is running"); return end

  local current = {api = ferry, op = op, path = selection.path, streamed = false}
  local id, err = ferry[op](selection.path, {
    on_progress = function(event)
      if not active or job ~= current then return end
      if event.waiting then
        report(op .. " " .. selection.path .. ": waiting for output...")
      elseif type(event.line) == "string" and event.line ~= "" then
        current.streamed = true
        local stream = event.stream == "stderr" and "stderr: " or ""
        report(stream .. event.line)
      end
    end,
    on_complete = function(result)
      if not active or job ~= current then return end
      job = nil
      -- The native runner streams output. Fall back to the retained output
      -- only when nothing was streamed, rather than printing it all twice.
      if not current.streamed and type(result.output) == "string" and result.output ~= "" then
        report(result.output)
      end
      local outcome
      if result.cancelled then
        outcome = "cancelled; transferred files were not rolled back"
      elseif result.timed_out then
        outcome = "timed out"
      elseif not result.ok then
        outcome = "failed"
      elseif result.nothing_to_do then
        outcome = "nothing to do"
      else
        outcome = "completed"
      end
      outcome = outcome .. " (status " .. tostring(result.status) .. ")"
      if result.truncated then outcome = outcome .. "; output truncated" end
      report(op .. " " .. selection.path .. ": " .. outcome)
    end,
  })
  if not id then
    report(op .. " " .. selection.path .. ": " .. tostring(err))
    return
  end
  current.id = id
  job = current
  report(op .. " " .. selection.path .. ": started")
end

-- Build a selection the way M.open does, from a Files.List entry plus the
-- directory it was listed in. Exposed so the pane's own menus can drive a job
-- without going through the menu M.open puts up: one right-click menu offering
-- everything that can be done to what was clicked, rather than two.
function M.selection(entry)
  local name = entry and entry.name
  if type(name) ~= "string" or name == "" or name == "." or name == ".."
      or name:find("[/\\%c]") then return nil end
  local parent = protocol.cwd()
  if not parent then return nil end
  -- A Files.List entry is a literal name, so prefix its parent before using
  -- the resolver: a leading '~' here must not expand to the wizard's home.
  local path = protocol.resolve(parent .. "/" .. name, parent, protocol.home())
  if not path or path:sub(1, 1) ~= "/" then return nil end
  local selection = {parent = parent, name = name, path = path, is_dir = entry.is_dir}
  if not valid_selection(selection) then return nil end
  return selection
end

-- Start one job. The caller is expected to have asked first for pull and push
-- -- M.open does that with its own confirmation, the pane's menu with its own.
-- `what` is either a listing entry or a selection M.selection() already
-- resolved. Menus resolve at OPEN time and hand the selection back here, so a
-- confirmation still acts on the file that was clicked even if the pane has
-- since been walked somewhere else -- and still refuses if that file has
-- meanwhile left the listing.
function M.start(op, what)
  if op ~= "pull" and op ~= "push" and op ~= "cc" then return false end
  local selection = what and what.path and what or M.selection(what)
  if not selection or not valid_selection(selection) then return false end
  launch(op, selection)
  return true
end

-- "pull /players/x", or nil when nothing is running. For anything that wants
-- to show the job rather than only report it.
function M.describe()
  if not M.running() then return nil end
  return job.op .. " " .. job.path
end

-- Stop the running job without putting a menu up first.
function M.cancel()
  local id = M.running()
  if not id then return false end
  local ok, err = job.api.cancel(id)
  if ok then report("cancellation requested")
  else report("cancel failed: " .. tostring(err)) end
  return ok and true or false
end

function M.open(entry)
  if not active or not M.available() or ferry.running() then return false end
  local name = entry and entry.name
  if type(name) ~= "string" or name == "" or name == "." or name == ".."
      or name:find("[/\\%c]") then return false end
  local parent = protocol.cwd()
  if not parent then return false end
  -- A Files.List entry is a literal name, so prefix its parent before using
  -- the resolver: a leading '~' here must not expand to the wizard's home.
  local path = protocol.resolve(parent .. "/" .. name, parent, protocol.home())
  if not path or path:sub(1, 1) ~= "/" then return false end
  local selection = {parent = parent, name = name, path = path, is_dir = entry.is_dir}
  if not valid_selection(selection) then return false end
  return open_menu("Ferry " .. path, {
    {label = "Pull", value = "pull"},
    {label = "Push", value = "push"},
    {label = "Compile (cc)", value = "cc"},
  }, function(op)
    if op == "cc" then
      launch(op, selection)
    elseif op == "pull" or op == "push" then
      open_menu("Confirm Ferry " .. op .. " " .. path, {
        {label = "Cancel", value = "cancel"},
        {label = op .. " " .. path, value = op},
      }, function(confirmed)
        if confirmed == op then launch(op, selection) end
      end)
    end
  end)
end

function M.open_cancel()
  local id = M.running()
  if not active or not id then return false end
  local current = job
  return open_menu("Ferry " .. current.op .. " " .. current.path, {
    {label = "Cancel running job", value = "cancel"},
  }, function(value)
    if value ~= "cancel" or job ~= current or M.running() ~= id then return end
    local ok, err = current.api.cancel(id)
    if ok then report("cancellation requested")
    else report("cancel failed: " .. tostring(err)) end
  end)
end

function M.cleanup()
  active = false
  if menu_owner then menu_owner.menu.close() end
  local id = M.running()
  local current = job
  job = nil
  if id then current.api.cancel(id) end
end

return M
