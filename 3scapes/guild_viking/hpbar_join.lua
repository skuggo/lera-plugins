-- Rejoin the Viking hp bar lines the MUD wrapped.
--
-- The MUD sends the bar through its 72-column wrap, so a long bar line
-- arrives in two pieces:
--   H[8269|8502(0|12753)] S[1774|2572] V[1872|2585] R[2400|2530] F[**-------
--   -] C[4/1]
-- A field cut at exactly column 72 continues with no space between; a line
-- wrapped at a space (the bracketed effects list) continues after one.
--
-- Used from init.lua's on_line hook, which sees every raw line (colours
-- included): the first piece is hidden, and its continuation is replaced
-- by the whole line, so the bar shows as the player laid it out (vsethp).
-- The effects list is the exception: it is re-wrapped at the width of the
-- H[ line above it, so the bar keeps one width instead of 72 columns.

local M = {}

local WRAP = 72  -- the MUD's wrap width: a line this long was cut mid-field

local held           -- raw first piece waiting for its continuation
local held_width = 0 -- its visible width
local bar_width = 80 -- visible width of the last H[ line, for the effects

local function plain(s)
  return (s:gsub("\27%[[%d;]*m", ""))
end

-- The bar's own lines: H[...], G[...], Vis:..., and the effects list.
local function is_bar(p)
  return p:match("^H%[%d") or p:match("^G%[%d") or p:match("^Vis:%d")
    or p:match("^%[%s*%a+:%d")
end

-- True while a '[' is still open at the end of the text.
local function open_bracket(p)
  local depth = 0
  for c in p:gmatch("[%[%]]") do
    depth = depth + (c == "[" and 1 or -1)
  end
  return depth > 0
end

-- Split raw text (colours included) at the last space that keeps the
-- visible part within width. Returns head, tail (tail nil when it fits).
local function split_at(raw, width)
  local col, cut, i = 0, nil, 1
  while i <= #raw do
    local esc = raw:match("^\27%[[%d;]*m", i)
    if esc then
      i = i + #esc
    else
      if raw:sub(i, i) == " " and col <= width then cut = i end
      col = col + 1
      i = i + 1
    end
  end
  if col <= width or not cut then return raw, nil end
  return raw:sub(1, cut - 1), raw:sub(cut + 1)
end

-- The effects list, re-wrapped at the bar's width: the first line replaces
-- the MUD's line, the rest is printed after it.
local function wrap_effects(joined)
  local head, tail = split_at(joined, bar_width)
  while tail do
    local next_tail
    tail, next_tail = split_at(tail, bar_width)
    print(tail)
    tail = next_tail
  end
  return head
end

-- Returns what on_line should return: true keeps the line, nil hides it,
-- a string replaces it.
function M.on_line(line)
  if held then
    local glue = held_width >= WRAP and "" or " "
    local first, cont = held, line
    if glue == " " then
      -- Word wrap: exactly one space between the pieces.
      first = first:gsub("%s+$", "")
      cont = cont:gsub("^%s+", "")
    end
    local joined = first .. glue .. cont
    held = nil
    local p = plain(joined)
    -- A bar long enough to wrap twice: keep holding.
    if open_bracket(p) then
      held, held_width = joined, #plain(line)
      return nil
    end
    return M.finish(joined)
  end
  local p = plain(line)
  if p:match("^H%[%d") and not open_bracket(p) then
    bar_width = #p
  end
  if is_bar(p) and open_bracket(p) then
    held, held_width = line, #p
    return nil
  end
  return true
end

-- A whole bar line on its way out: note the H[ width, re-wrap the effects.
function M.finish(joined)
  local p = plain(joined)
  if p:match("^H%[%d") then
    bar_width = #p
  elseif p:match("^%[%s*%a+:%d") then
    return wrap_effects(joined)
  end
  return joined
end

-- A held piece never outlives a reconnect.
function M.reset()
  held, held_width = nil, 0
end

return M
