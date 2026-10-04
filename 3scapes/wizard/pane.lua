-- The file pane: the wizard's current directory, laid out in ls-style columns.
--
-- The entry model is separated from the drawing so the layout is testable
-- without a screen, and render() stays a pure draw from it -- which is also
-- what keeps it idempotent across the local and remote (WebSocket) render
-- passes that both call it.
--
-- Two functions describe what to show:
--   entries() -- the navigable entries, directories A-Z then files A-Z
--   notice()  -- a single full-width message (loading, an error, truncation)
-- A notice is never gridded: it is one row spanning the pane, and it is never
-- clickable.

local wm = require("wm")
local protocol = require("protocol")
local actions = require("actions")
local ferry_actions = require("ferry_actions")
local theme = require("theme")
local overlay = require("overlay")

local M = {}

-- Blank columns between cells. Two is the usual `ls` separation and is wide
-- enough that a trailing "/" does not visually run into the next column.
local GUTTER = 2

-- The content width the last render used. The scroller's count() takes no
-- arguments but the number of display rows depends on the pane WIDTH, so the
-- width has to reach it somehow; caching the last render's is the same trick
-- border_shown uses below, and it keeps count() and render() in agreement.
local last_w = nil

-- Identity of the listing currently on screen, so a new one can be spotted and
-- scrolled back to the top.
local last_key = nil

-- Whether the most recent render() drew a border. on_pointer() has no opts of
-- its own -- wm calls it with just the event -- so it has to agree with
-- render() about the inset some other way. Defaults to true, matching
-- opts.show_border's own default.
local border_shown = true

-- ---- the entry model -------------------------------------------------------

local function listing()
  if not protocol.available() then return nil, "Files.List unavailable (not a wizard?)" end
  local cwd = protocol.cwd()
  if not cwd then return nil, "loading..." end
  local entry = protocol.lookup(cwd)
  if not entry then return nil, "loading..." end
  if entry.error then return nil, cwd .. ": " .. entry.error end
  if not entry.complete then return nil, "loading..." end
  return entry, entry.truncated and "(listing truncated)" or nil
end

-- Sorted so a grid scans predictably. Directories stay grouped ahead of files
-- -- the grouping keeps left-click navigation predictable.
function M.entries()
  local entry = listing()
  if not entry then return {} end

  local dirs = {}
  for i = 1, #entry.dirs do dirs[i] = entry.dirs[i] end
  table.sort(dirs)

  local files = {}
  for i = 1, #entry.files do files[i] = entry.files[i] end
  table.sort(files)

  local out = {}
  for i = 1, #dirs do
    out[#out + 1] = { text = dirs[i] .. "/", is_dir = true, name = dirs[i] }
  end
  for i = 1, #files do
    out[#out + 1] = { text = files[i], is_dir = false, name = files[i] }
  end
  return out
end

function M.notice()
  local _, message = listing()
  return message
end

-- ---- the button row --------------------------------------------------------

-- One row at the top of the pane carrying an action per command, run against
-- the CURRENT directory. Laid out by the same discipline as the border inset:
-- one function that both render() and on_pointer() call, so a button can never
-- be drawn in one place and clicked in another.
--
-- Returns the cells and the number of rows they occupy (0 when the pane is too
-- small, or when there is no directory to act on -- a button that would send
-- `uall nil` is worse than no button).
local BUTTON_GAP = 2

-- Navigation first, then the directory actions. The two groups are coloured
-- differently (see render): moving somewhere and recompiling something should
-- not look alike on a row two characters apart.
--
-- ".." and "~" are here rather than as entries in the listing because the
-- listing is what the SERVER said is in this directory -- keeping synthetic
-- rows out of it leaves entries(), the column maths and the sort alone.
local NAV = {
  { key = "up",   label = "[..]" },
  { key = "home", label = "[~]" },
}

local function buttons(w, h)
  if not w or w <= 0 or not h or h < 2 then return {}, 0 end
  if not protocol.available() or not protocol.cwd() then return {}, 0 end

  local cells, x = {}, 0
  for i = 1, #NAV do
    local label = NAV[i].label
    if x + #label > w then break end
    cells[#cells + 1] = { x = x, text = label, nav = NAV[i].key }
    x = x + #label + BUTTON_GAP
  end
  for i = 1, #actions.COMMANDS do
    local label = actions.COMMANDS[i].label
    if x + #label > w then break end
    cells[#cells + 1] = { x = x, text = label, cmd = actions.COMMANDS[i].cmd }
    x = x + #label + BUTTON_GAP
  end
  if #cells == 0 then return {}, 0 end
  return cells, 1
end

-- The command each navigation button sends.
--
-- "~" sends a BARE `cd`, which is the MUD's own way home: wiz.h's cd defaults
-- its argument to "~" (secure/pinc/wiz.h:15). Sending the command rather than
-- a resolved path also means the button works before the pane has learned
-- where home is -- Files.List seeds that, and it may not have arrived yet.
--
-- ".." is resolved here instead, and sent absolute: the MUD would resolve a
-- bare ".." against ITS cwd, and the pane's is the directory being browsed.
local function nav_command(key)
  if key == "home" then return "cd" end
  if key == "up" then
    local target = protocol.resolve("..", protocol.cwd(), protocol.home())
    return target and ("cd " .. target) or nil
  end
  return nil
end

-- ---- layout ----------------------------------------------------------------

-- Grid geometry for a content width: the entries, how many columns fit, how
-- many rows that needs, and the per-cell width.
--
-- Columns are uniform, sized to the longest entry in the whole listing. n
-- columns need n*longest + (n-1)*GUTTER cells, so the count that fits is
-- floor((w + GUTTER) / (longest + GUTTER)) -- the +GUTTER accounts for the
-- last column needing no trailing gutter.
local function grid(w)
  local entries = M.entries()
  if #entries == 0 then return entries, 1, 0, w end

  local longest = 0
  for i = 1, #entries do
    if #entries[i].text > longest then longest = #entries[i].text end
  end

  local cell = longest + GUTTER
  local cols = math.floor((w + GUTTER) / cell)
  if cols < 1 then cols = 1 end
  local rows = math.ceil(#entries / cols)
  return entries, cols, rows, cell
end

-- Total display rows: the grid, plus the notice's own row when there is one.
local function display_rows(w)
  local _, _, rows = grid(w)
  return rows + (M.notice() and 1 or 0)
end

local sc = wm.make_scroller({
  -- Before the first render there is no width to lay out against. 40 is only
  -- a placeholder for that one call; every later count() uses the real width.
  count = function() return display_rows(last_w or 40) end,
})

M.scroll = sc.scroll
M.scroll_to_bottom = sc.scroll_to_bottom
M.following_tail = sc.following_tail

-- The first display row drawn, given the scroll offset. The offset is a
-- distance from the tail, so the arithmetic is tail-relative even though a
-- fresh listing is anchored to the top by reset_scroll_on_new_listing below.
local function first_visible(h, total)
  local start = total - h + 1 - sc.offset()
  if start < 1 then start = 1 end
  return start
end

-- A directory listing should open showing its FIRST entries; the scroller
-- otherwise starts at the tail, which is right for a chat pane and wrong here.
-- Scrolling up by the row count lands on the top because the scroller clamps
-- the offset to count-1.
local function reset_scroll_on_new_listing()
  local cwd = protocol.cwd()
  local entry = cwd and protocol.lookup(cwd)
  local key = table.concat({
    tostring(cwd),
    tostring(entry and entry.complete),
    tostring(entry and #entry.dirs or 0),
    tostring(entry and #entry.files or 0),
    tostring(M.notice()),
  }, "|")
  if key == last_key then return end
  last_key = key
  sc.scroll(-(display_rows(last_w or 40) + 1))
end

-- ---- drawing ---------------------------------------------------------------

-- A rect is USERDATA whose fields are methods (src/lua/api_ui.c:79-86), not a
-- table of plain fields. wm may also hand a plain table through, so both forms
-- are read -- the same dual-form idiom as chat_monitor.lua:973-976. Note the
-- fields are w/h, not width/height.
local function rect_dims(rect)
  if type(rect.x) == "function" then
    return rect:x(), rect:y(), rect:w(), rect:h()
  end
  return rect.x, rect.y, rect.w, rect.h
end

-- The one place the border inset is applied, so render() and on_pointer()
-- can never drift apart on it. Takes the OUTER (pane-local, border included)
-- geometry and returns the CONTENT geometry.
local function inset_for_border(x, y, w, h, show_border)
  if show_border then
    return x + 1, y + 1, w - 2, h - 2
  end
  return x, y, w, h
end

function M.render(rect, opts)
  opts = opts or {}
  local show_border = opts.show_border ~= false
  local title = opts.title or "Files"
  border_shown = show_border

  local x, y, w, h = rect_dims(rect)
  if show_border then ui.box(rect, "single", title) end
  x, y, w, h = inset_for_border(x, y, w, h, show_border)
  if w <= 0 or h <= 0 then return end

  last_w = w
  reset_scroll_on_new_listing()

  local cells, brows = buttons(w, h)
  for i = 1, #cells do
    -- Brackets dim, word coloured: navigation blue, actions white. Drawn as
    -- three runs rather than one so the punctuation can recede while the word
    -- stays legible -- the toolbar is permanent furniture and should not
    -- compete with the listing under it.
    local cell = cells[i]
    local word = cell.text:sub(2, #cell.text - 1)
    local color = cell.nav and theme.NAV or theme.BUTTON
    ui.text_ansi(ui.rect(x + cell.x, y, #cell.text, 1),
                 theme.paint("[", theme.BRACKET) ..
                 theme.paint(word, color) ..
                 theme.paint("]", theme.BRACKET))
  end

  -- The grid gets what the button row leaves. Only the VISIBLE height changes:
  -- the scroller counts content rows, which the buttons are not part of.
  local gh = h - brows
  if gh <= 0 then return end

  local notice = M.notice()
  local entries, cols, rows, cell = grid(w)
  local start = first_visible(gh, rows + (notice and 1 or 0))

  local line = 0
  for r = start, rows do
    if line >= gh then break end
    for c = 0, cols - 1 do
      -- Column-major: a column runs the full grid height before the next
      -- begins, so entry order reads DOWN a column, as plain `ls` does.
      local e = entries[c * rows + r]
      if e then
        local cx = c * cell
        local avail = w - cx
        if avail > 0 then
          local text = e.text
          if #text > avail then text = text:sub(1, avail) end
          -- Truncation happens on the plain text, and the colour is applied
          -- after: an escape costs no cells, so measuring the painted string
          -- would cut the name short by the length of its own colour code.
          ui.text_ansi(ui.rect(x + cx, y + brows + line, #text, 1),
                       theme.paint(text, theme.color(e)))
        end
      end
    end
    line = line + 1
  end

  if notice and line < gh then
    ui.text_ansi(ui.rect(x, y + brows + line, w, 1),
                 theme.paint(notice, theme.NOTICE))
    line = line + 1
  end

  -- A running ferry command, named in the pane rather than only in the output
  -- log. Two reasons: a transfer can be silent for a long time and the pane is
  -- where you are looking, and the right-click-to-abort gesture depends on
  -- this state -- so if the row is not here, abort will not fire either.
  local busy = ferry_actions.running() and ferry_actions.describe()
  if busy and line < gh then
    local text = "* " .. busy .. " -- right-click to abort"
    if #text > w then text = text:sub(1, w) end
    ui.text_ansi(ui.rect(x, y + brows + line, #text, 1),
                 theme.paint(text, theme.BUSY))
  end

  -- Last, so it sits over the listing rather than under it. Coordinates are
  -- content-relative; the pane adds its own origin here, which is the only
  -- place overlay geometry meets the screen.
  overlay.render(w, h,
    function(bx, by, bw, bh, title)
      ui.box(ui.rect(x + bx, y + by, bw, bh), "single", title)
    end,
    function(tx, ty, text, opts)
      local kind = opts and opts.kind or "command"
      local color = theme.MENU_CMD
      if kind == "desc" then color = theme.MENU_DESC
      elseif kind == "danger" then color = theme.MENU_DANGER
      elseif kind == "cancel" then color = theme.MENU_CANCEL end
      ui.text_ansi(ui.rect(x + tx, y + ty, #text, 1), theme.paint(text, color))
    end)
end

-- The absolute path of an entry in the current listing. Everything a click
-- sends is absolute: the MUD resolves a bare name against ITS cwd, and the
-- pane's idea of the directory is the thing being clicked in.
local function entry_path(e)
  local cwd = protocol.cwd()
  if not cwd then return nil end
  -- A Files.List entry is a literal file name, so its parent goes on before
  -- the resolver sees it: a leading "~" belongs to the name and must not
  -- expand to the wizard's home. ferry_actions.selection builds its path the
  -- same way, for the same reason.
  return protocol.resolve(cwd .. "/" .. e.name, cwd, protocol.home())
end

function M.on_pointer(event)
  if event.kind ~= "down" then return false end
  local button = event.button
  if button ~= "left" and button ~= "right" then return false end
  -- wm still routes a click to the focused pane when the pointer is outside
  -- it. Nothing here should act on one: the row under a coordinate that is
  -- not in the pane is a coincidence.
  if event.inside == false then return false end

  -- A running Ferry job can be cancelled from anywhere inside the pane,
  -- including blank space, notices and the border: the thing you want to stop
  -- is not a row you can point at.
  if button == "right" and ferry_actions.running() and not overlay.active() then
    local x, y = event.x or 0, event.y or 0
    if event.inside ~= false and x >= 0 and y >= 0
        and x < (event.width or 0) and y < (event.height or 0) then
      return actions.cancel_menu({ x = 0, y = 0 })
    end
  end

  -- event.x/event.y are pane-local and include the border; run them through the
  -- same inset render() used so a click lands on the cell it visually points
  -- at, and a click on a border row or column navigates nowhere.
  local ox, oy, ow, oh = inset_for_border(0, 0, event.width or 0, event.height or 0,
                                          border_shown)
  local lx = (event.x or 0) - ox
  local ly = (event.y or 0) - oy
  if lx < 0 or lx >= ow or ly < 0 or ly >= oh then return false end

  -- An open menu owns every click in the pane: one on an item chooses it, one
  -- anywhere else dismisses. Nothing falls through to the listing underneath,
  -- which would navigate away from the very thing being asked about.
  if overlay.active() then
    overlay.on_click(lx, ly, ow, oh)
    if ui and ui.dirty then ui.dirty() end
    return true
  end

  -- The button row, when there is one. Same call render() makes, so the hit
  -- boxes are the drawn ones.
  local cells, brows = buttons(ow, oh)
  if brows > 0 and ly == 0 then
    if button ~= "left" then return false end
    for i = 1, #cells do
      -- The label itself, not the gap after it.
      if lx >= cells[i].x and lx < cells[i].x + #cells[i].text then
        if cells[i].nav then
          local command = nav_command(cells[i].nav)
          if not command then return false end
          mud.send(command)
          return true
        end
        local cwd = protocol.cwd()
        if not cwd then return false end
        -- Flat or recursive, then the confirmation: the toolbar acts on the
        -- directory you are IN, which is exactly where "and everything under
        -- it" is most often wanted.
        actions.command_menu(cells[i].cmd, cwd, { x = lx, y = ly + 1 })
        return true
      end
    end
    return false
  end
  ly = ly - brows
  oh = oh - brows
  if oh <= 0 then return false end

  local notice = M.notice()
  local entries, cols, rows, cell = grid(ow)
  local row = first_visible(oh, rows + (notice and 1 or 0)) + ly
  -- Past the grid: either the notice's row or empty space. Neither navigates.
  if row > rows then return false end

  local col = math.floor(lx / cell)
  if col >= cols then return false end

  -- Indexed against the TOTAL grid rows, not the visible ones: a column spans
  -- the whole grid, so scrolling changes which rows show, not how a column is
  -- numbered.
  local e = entries[col * rows + row]
  if not e then return false end
  -- Only the text itself is clickable, not the gutter padding after it.
  if (lx - col * cell) >= #e.text then return false end

  -- This pane's own menus own right-click on an entry; Ferry is offered
  -- inside them (actions.FERRY_ACTIONS) rather than as a second menu system,
  -- so one click gives you everything that can be done to what you clicked.
  if e.is_dir then
    if button == "right" then
      local path = entry_path(e)
      if not path then return false end
      actions.dir_menu(path, { x = lx, y = ly + brows }, e)
      return true
    end
    -- A real cd, so the confirmation line updates the cwd exactly as a typed
    -- one would. There is deliberately no second source of truth here.
    mud.send("cd " .. e.name)
    return true
  end

  -- A file: left opens it, right offers the rest. Viewing is the thing you
  -- want nine times out of ten and it is harmless -- it pages the file into
  -- the output pane and nothing else -- so it gets the plain click, the same
  -- way a directory gets cd. ul destructs a live object, so it stays behind
  -- the menu.
  local path = entry_path(e)
  if not path then return false end
  if button == "right" then
    actions.file_menu(path, { x = lx, y = ly + brows }, e)
  else
    actions.view(path)
  end
  return true
end

return M
