-- A small click-driven menu drawn INSIDE the file pane, next to whatever was
-- clicked.
--
-- Neither of the client's two modal widgets is in the right place for this:
-- require("menu") anchors above the input bar, and wm's popup is centred over
-- every pane. A file browser wants the choices where the file is, so the pane
-- draws its own.
--
-- Pure geometry and state -- no ui calls, no mud calls. render() is handed a
-- draw function by the pane, and on_click() answers a hit with the value that
-- was chosen. That keeps the whole thing testable without a screen, which is
-- the same split the pane uses between entries() and render().
--
-- Pointer-driven only, deliberately: `bind` is not in the plugin sandbox, so
-- there is no Escape to lean on. A click anywhere outside the box closes it,
-- which is the gesture people already use on a menu they did not mean to open.

local M = {}

local state = nil   -- { title, items, on_select, anchor = {x, y} }

-- Box furniture: a border on each side, and a space either side of a label.
local BORDER = 2
local PAD = 2
-- Between the command column and its explanation.
local COL_GAP = 2

function M.open(opts)
  if type(opts) ~= "table" then return false end
  if type(opts.items) ~= "table" or #opts.items == 0 then return false end
  state = {
    title = opts.title,
    items = opts.items,
    on_select = opts.on_select,
    anchor = opts.anchor or { x = 0, y = 0 },
  }
  return true
end

function M.close()
  state = nil
end

function M.active()
  return state ~= nil
end

-- Exposed for the pane's title and for tests.
function M.title()
  return state and state.title or nil
end

function M.items()
  return state and state.items or nil
end

local function label_of(item)
  if type(item) == "table" then return tostring(item.label or item.value or "") end
  return tostring(item)
end

local function desc_of(item)
  if type(item) == "table" and type(item.desc) == "string" then return item.desc end
  return nil
end

local function value_of(item)
  if type(item) == "table" then
    if item.value ~= nil then return item.value end
    return item.label
  end
  return item
end

-- The box, in pane CONTENT coordinates, clamped so it is always fully drawn:
-- a menu half off the edge would have unreachable rows.
--
-- Width is the widest of the title and the labels; height is one row per item
-- plus the border. Both are capped at the content size, so a narrow pane gets
-- a narrow menu rather than nothing.
function M.layout(w, h)
  if not state or w <= 0 or h <= 0 then return nil end

  -- Two columns: every command starts at the same x, and so does every
  -- explanation. A ragged second column is the thing that makes a menu like
  -- this look thrown together.
  local label_w, desc_w = 0, 0
  for i = 1, #state.items do
    local n = #label_of(state.items[i])
    if n > label_w then label_w = n end
    local d = desc_of(state.items[i])
    if d and #d > desc_w then desc_w = #d end
  end

  local widest = label_w + (desc_w > 0 and (COL_GAP + desc_w) or 0)
  if state.title and #state.title > widest then widest = #state.title end

  local bw = widest + BORDER + PAD
  if bw > w then bw = w end

  -- Prefer to show the WHOLE list. The border is decoration; the items are
  -- the point. So when the box would not fit the pane with a border, it drops
  -- the border and takes the two rows back -- and only if it still does not
  -- fit does render() spend the last row on a "+N more" marker.
  local bordered = true
  local bh = #state.items + BORDER
  if bh > h then
    bordered = false
    bh = #state.items
    if bh > h then bh = h end
  end

  local x = state.anchor.x or 0
  local y = state.anchor.y or 0
  if x + bw > w then x = w - bw end
  if y + bh > h then y = h - bh end
  if x < 0 then x = 0 end
  if y < 0 then y = 0 end

  -- rows: the item rows. With a border the first and last rows are the frame;
  -- without one every row is an item.
  return { x = x, y = y, w = bw, h = bh, bordered = bordered,
           label_w = label_w, desc_x = label_w + COL_GAP,
           rows = bordered and (bh - BORDER) or bh }
end

-- Draw through callbacks so this module never touches ui directly: `box` gets
-- the rect and title, `text` gets a position and a string.
-- How many item rows a box of `rows` rows can actually offer, and the marker
-- to draw in the last one when the list is longer than that.
--
-- A menu that silently stopped at the pane's height would hide its tail --
-- which is where the least-used and most destructive entries sit -- with
-- nothing on screen to say so. Give up one row to say it instead.
local function visible_rows(rows)
  local n = #state.items
  if rows >= n then return n, nil end
  if rows < 1 then return 0, nil end
  return rows - 1, "+" .. (n - rows + 1) .. " more (taller pane)"
end

function M.render(w, h, box, text)
  local rect = M.layout(w, h)
  if not rect then return end

  local inset = rect.bordered and 1 or 0
  if rect.bordered then box(rect.x, rect.y, rect.w, rect.h, state.title) end

  local avail = rect.w - (rect.bordered and BORDER or 0)
  local shown, marker = visible_rows(rect.rows)
  for i = 1, shown do
    local item = state.items[i]
    local label = label_of(item)
    local desc = desc_of(item)
    local row = rect.y + inset + i - 1
    if #label > avail then label = label:sub(1, avail) end
    -- The caller draws; this decides WHERE. label and desc are handed over
    -- separately so they can be coloured separately.
    text(rect.x + inset, row, label, {
      kind = (type(item) == "table" and item.kind) or "command",
    })
    if desc and rect.desc_x < avail then
      local room = avail - rect.desc_x
      if #desc > room then desc = desc:sub(1, room) end
      text(rect.x + inset + rect.desc_x, row, desc, { kind = "desc" })
    end
  end
  if marker then
    if #marker > avail then marker = marker:sub(1, avail) end
    text(rect.x + inset, rect.y + inset + rect.rows - 1, marker, { kind = "desc" })
  end
  return rect
end

-- A click in pane CONTENT coordinates.
--
-- Returns "selected" when an item was chosen (the callback has already run),
-- "closed" when the click dismissed the menu, and nil when there was no menu
-- to click on. Either way a true return from the pane means consumed: while
-- this is open it owns the pane's clicks.
function M.on_click(lx, ly, w, h)
  if not state then return nil end
  local rect = M.layout(w, h)
  if not rect then M.close() return "closed" end

  local inside = lx >= rect.x and lx < rect.x + rect.w
                 and ly >= rect.y and ly < rect.y + rect.h
  if not inside then
    M.close()
    return "closed"
  end

  -- Same inset render() used, so a click lands on the row it points at.
  local row = ly - rect.y + (rect.bordered and 0 or 1)
  -- A border row is part of the box but selects nothing; clicking one keeps
  -- the menu open rather than dismissing it, so a near-miss on an item is
  -- recoverable. The "+N more" marker is inert for the same reason.
  local shown = visible_rows(rect.rows)
  if row < 1 or row > shown then return "selected_none" end

  local item = state.items[row]
  local cb, value = state.on_select, value_of(item)
  -- Torn down BEFORE the callback, so a callback that opens another menu
  -- (confirm, after choosing an action) is not closed again on the way out.
  M.close()
  if cb then cb(value) end
  return "selected"
end

return M
