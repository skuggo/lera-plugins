-- Wizard Ferry menus and native callback consumption; no subprocess or network.
-- Run from plugins/ with LERA_ROOT pointing at the Lera checkout.
package.path = "3scapes/wizard/?.lua;" .. package.path

local failures = 0
local real_print = print
local messages = {}
print = function(message) messages[#messages + 1] = tostring(message) end
local function check(name, ok)
  real_print("CASE " .. name .. ": " .. (ok and "PASS" or "FAIL"))
  if not ok then failures = failures + 1 end
end
local function output_has(text)
  for _, line in ipairs(messages) do
    if line:find(text, 1, true) then return true end
  end
  return false
end

local opened, closed = nil, 0
local menu = {}
function menu.close()
  local previous = opened
  opened = nil
  closed = closed + 1
  if previous and previous.on_cancel then previous.on_cancel() end
end
function menu.open(opts)
  if opened then menu.close() end
  opened = opts
  return true
end
function menu.is_open() return opened ~= nil end
local menu_loaded = 0
package.preload.menu = function() menu_loaded = menu_loaded + 1; return menu end
local function choose(value)
  if not opened then return false end
  local previous = opened
  opened = nil
  previous.on_select(value)
  return true
end
local function item_value(item)
  return type(item) == "table" and item.value or item
end

local offset = 0
package.loaded.wm = {
  make_scroller = function(opts)
    local function clamp() offset = math.max(0, math.min(offset, opts.count() - 1)) end
    return {
      offset = function() clamp(); return offset end,
      scroll = function(delta) offset = offset - delta; clamp() end,
      scroll_to_bottom = function() offset = 0 end,
      following_tail = function() return offset == 0 end,
    }
  end,
}
ui = { box = function() end, text = function() end, dirty = function() end,
       -- The pane draws in colour now, so it reaches for text_ansi.
       text_ansi = function() end,
       rect = function(x, y, w, h) return {x = x, y = y, w = w, h = h} end }
local sent = {}
mud = {send = function(line) sent[#sent + 1] = line end}
gmcp = {send = function() return true end}

local calls, cancellations = {}, {}
local next_id, running, launch_error, cancel_error = 0, nil, nil, nil
local api = {}
function api.available() return true end
function api.running() return running end
function api.cancel(id)
  cancellations[#cancellations + 1] = id
  if cancel_error then return nil, cancel_error end
  return true
end
for _, verb in ipairs({"pull", "push", "cc"}) do
  local op = verb
  api[op] = function(path, opts)
    calls[#calls + 1] = {op = op, path = path, opts = opts}
    if launch_error then return nil, launch_error end
    next_id = next_id + 1
    running = next_id
    calls[#calls].id = running
    return running
  end
end
local function complete(result)
  local call = calls[#calls]
  result.id, result.op, result.path = call.id, call.op, call.path
  running = nil
  call.opts.on_complete(result)
end

local protocol = require("protocol")
local pane = require("pane")
check("menu remains lazy while pane loads", menu_loaded == 0)
local function listing(files, dirs, truncated)
  protocol.reset()
  protocol.set_available(true)
  protocol.set_cwd("/players/simon")
  protocol.store(protocol.cwd(), {dirs = dirs or {"archive", "zebra"},
    files = files or {"arena.c", "two words.c"}, complete = true,
    truncated = truncated})
  offset = 0
  pane.render({x = 0, y = 0, w = 30, h = 8})
end
local function click(x, y, extra)
  local event = {kind = "down", button = "right", x = x, y = y,
                 inside = true, width = 30, height = 8}
  for key, value in pairs(extra or {}) do event[key] = value end
  return pane.on_pointer(event)
end

-- The pane draws its own menus in-pane (overlay.lua) rather than through
-- require("menu"), and one right-click offers everything that can be done to
-- what was clicked -- the MUD's own commands AND Ferry. So these cases drive
-- the overlay; the job-level cases further down are unchanged, because the
-- rows still go through ferry_actions and the native API.
local overlay = require("overlay")

local function rows_with(prefix)
  local found = {}
  for _, item in ipairs(overlay.items() or {}) do
    if tostring(item.value):find("^" .. prefix) then found[#found + 1] = item.value end
  end
  return found
end

local function pick(value)
  local items = overlay.items() or {}
  local rect = overlay.layout(28, 24)
  for i, item in ipairs(items) do
    if item.value == value then
      overlay.on_click(rect.x + 1, rect.y + (rect.bordered and 1 or 0) + i - 1, 30, 26)
      return true
    end
  end
  return false
end

listing()
ferry = nil
click(1, 2)
check("older Lera offers no Ferry rows", #rows_with("ferry%-") == 0)
check("unavailable does not load menu", menu_loaded == 0)
overlay.close()
ferry = {available = function() return false, "configure a mirror" end}
click(1, 2)
check("unconfigured Ferry offers no rows", #rows_with("ferry%-") == 0)
overlay.close()

ferry = api
check("directory right-click is consumed", click(1, 2) == true)
check("entry menu offers pull push cc", #rows_with("ferry%-") == 3)
check("opening actions launches nothing", #calls == 0 and #sent == 0)
pick("ferry-pull")
check("pull waits for confirmation", #calls == 0 and overlay.active())
check("confirmation names the verb and what it will touch",
  (overlay.items()[2].desc or ""):find("pull", 1, true)
  and (overlay.items()[2].desc or ""):find("archive", 1, true))
check("confirmation defaults to safe cancel", overlay.items()[1].value == "no")
pick("no")
check("cancelling confirmation launches nothing", #calls == 0)

-- From here the cases are Simon's, unchanged in intent: they drive a menu,
-- pick a row, and check what reached the native API. Only the two helpers
-- below are re-pointed at the pane's own overlay, plus the row coordinates
-- (the pane carries a button row above the listing, so entries start a row
-- lower) and the handful of assertions that counted rows in HIS menu.
local function has_row(value)
  for _, item in ipairs(overlay.items() or {}) do
    if item.value == value then return true end
  end
  return false
end
-- ferry_actions.open() still drives require("menu") directly (the pane does
-- not use it, but the module keeps it for callers that do), so the cleanup
-- cases below keep the original menu-driven helpers.
local menu_choose, menu_close = choose, menu.close
choose = function(value)
  if has_row("yes") then
    -- the confirmation box: its rows are yes/no rather than the verb
    value = (value == "cancel") and "no" or "yes"
  elseif value == "pull" or value == "push" or value == "cc" then
    value = "ferry-" .. value
  elseif value == "cancel" then
    value = "abort"
  end
  return pick(value)
end
local function open_menu() return overlay.active() end

-- Two columns, each two rows; file with spaces is column 1, row 2.
click(14, 3)
choose("push")
protocol.set_cwd("/elsewhere")
choose("push")
check("confirmation retains exact path with spaces after cwd changes", #calls == 1
  and calls[1].op == "push" and calls[1].path == "/players/simon/two words.c")
check("job installs both callbacks", calls[1] and type(calls[1].opts.on_progress) == "function"
  and type(calls[1].opts.on_complete) == "function")

if calls[1] then
  messages = {}
  calls[1].opts.on_progress({line = "uploaded file", stream = "stdout"})
  calls[1].opts.on_progress({line = "diagnostic", stream = "stderr", partial = true})
  calls[1].opts.on_progress({waiting = true})
  check("progress prints stdout stderr and silence heartbeat", output_has("uploaded file")
    and output_has("diagnostic") and output_has("waiting"))
  messages = {}
  complete({ok = true, status = 0, output = "uploaded file\ndiagnostic"})
  check("successful completion is concise and does not repeat streamed output",
    output_has("completed") and not output_has("uploaded file"))
end

listing()
click(14, 2)
local before = #calls
choose("cc")
check("cc starts immediately for exact file", #calls == before + 1 and not overlay.active()
  and calls[#calls].op == "cc" and calls[#calls].path == "/players/simon/arena.c")
if #calls > before then
  messages = {}
  complete({ok = true, status = 0, output = "", nothing_to_do = true})
  check("silent no-op is reported", output_has("nothing to do"))
end

for _, result in ipairs({
  {ok = false, status = 19, output = ""},
  {ok = false, status = -1, output = "", cancelled = true},
  {ok = false, status = -1, output = "", timed_out = true},
}) do
  click(1, 2); before = #calls; choose("cc")
  if #calls > before then
    messages = {}
    complete(result)
    check("completion distinguishes silent terminal outcome " .. tostring(result.status)
      .. (result.cancelled and " cancelled" or result.timed_out and " timeout" or " failure"),
      result.cancelled and output_has("cancelled")
      or result.timed_out and output_has("timed out")
      or not result.cancelled and not result.timed_out and output_has("failed") and output_has("19"))
  end
end

messages = {}
launch_error = "mirror unavailable"
click(1, 2); before = #calls; choose("cc")
check("launch errors are visible", #calls == before + 1 and output_has("mirror unavailable"))
launch_error = nil
click(1, 2)
check("launch failure does not leave cancel mode", overlay.active() and #rows_with("ferry%-") == 3)
overlay.close()

-- A stale cache must not authorize an action against a vanished entry.
click(1, 2); choose("push")
protocol.invalidate("/players/simon")
before = #calls
choose("push")
check("invalidated selection cannot start a transfer", #calls == before)
listing()
click(1, 2)
protocol.store("/players/simon", {dirs = {}, files = {}, complete = true})
before = #calls
choose("cc")
check("removed selection cannot compile", #calls == before)

listing()
running = 999
click(1, 2)
check("another caller's running job never offers cancel", not has_row("abort"))
overlay.close()
running = nil
click(1, 2); before = #calls; choose("cc")
if #calls > before then
  local owned_id = calls[#calls].id
  check("running job allows cancel on blank pane space", click(28, 6) == true
    and has_row("abort"))
  overlay.close()
  check("running job allows cancel on pane border", click(0, 0) == true and overlay.active())
  overlay.close()
  check("outside pane never opens cancel", click(30, 2) == false and not overlay.active()
    and click(1, 2, {inside = false}) == false and not overlay.active())
  click(28, 6)
  cancel_error = "cancel refused"
  messages = {}
  choose("cancel")
  check("cancel errors stay visible", output_has("cancel refused"))
  cancel_error = nil
  click(28, 6); choose("cancel")
  check("cancellation targets only the owned id", cancellations[#cancellations] == owned_id)
  complete({ok = false, status = -1, cancelled = true, output = ""})
end

listing()
for _, point in ipairs({{0, 2}, {1, 0}, {9, 2}, {13, 2}, {1, 6}, {30, 2}}) do
  overlay.close()
  check("exact hit rejects border gutter or empty area " .. point[1] .. "," .. point[2],
    click(point[1], point[2]) == false and not overlay.active())
end
listing({"arena.c"}, {"archive", "zebra"})
check("empty column cell is not actionable", click(12, 3) == false and not overlay.active())
listing({}, {"archive"}, true)
-- the notice sits on its own row under the grid
check("listing notice is not actionable", click(1, 3) == false and not overlay.active())
listing({"a.c", "b.c", "c.c", "d.c"}, {})
pane.render({x = 0, y = 0, w = 7, h = 5})
pane.scroll_to_bottom()
check("right-click follows scrolled file rows", click(1, 2, {width = 7, height = 5}) == true)
choose("cc")
check("scrolled file uses displayed target", calls[#calls] and calls[#calls].path == "/players/simon/c.c")
if running then complete({ok = true, status = 0, output = ""}) end

listing({"~literal.c"}, {})
click(1, 2); choose("cc")
check("a leading tilde in a file name stays literal", calls[#calls]
  and calls[#calls].path == "/players/simon/~literal.c")
if running then complete({ok = true, status = 0, output = ""}) end

-- The shared menu replaces its previous owner through on_cancel. Cleanup must
-- not close a menu another plugin opened after ours.
listing()
click(1, 2)
local actions_ok, actions = pcall(require, "ferry_actions")
check("Ferry action module exists", actions_ok)
if actions_ok then
  menu.open({items = {"other plugin"}, on_select = function() end})
  local previous = closed
  actions.cleanup()
  check("unload leaves another plugin's menu open", opened and closed == previous)
  menu_close()
  package.loaded.ferry_actions = nil
  actions = require("ferry_actions")
  actions.open({name = "archive", is_dir = true})
  previous = closed
  local stale_menu = opened
  actions.cleanup()
  check("unload closes its own menu", opened == nil and closed == previous + 1)
  before = #calls
  stale_menu.on_select("cc")
  check("unload makes retained menu callbacks inert", #calls == before)
  package.loaded.ferry_actions = nil
  actions = require("ferry_actions")
  actions.open({name = "archive", is_dir = true})
  menu_choose("cc")
  local call = calls[#calls]
  actions.cleanup()
  check("unload cancels its owned running job", cancellations[#cancellations] == call.id)
  messages = {}
  call.opts.on_progress({line = "late output", stream = "stdout"})
  call.opts.on_complete({id = call.id, ok = true, status = 0})
  check("unload suppresses late callbacks", #messages == 0)
end

real_print(failures == 0 and "ALL PASS" or (failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
