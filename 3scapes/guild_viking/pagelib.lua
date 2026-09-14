-- pagelib: shared text-rendering toolkit for guild_viking's stage-2 panes.
-- Pure module: no lera API calls, no state access. Every page renderer
-- builds its output through these helpers so cell widths and ANSI resets
-- stay consistent across pages.
local pagelib = {}

pagelib.RESET = "\27[0m"

pagelib.C = {
  green        = "\27[32m",
  bright_green = "\27[92m",
  yellow       = "\27[33m",
  red          = "\27[31m",
  bright_red   = "\27[91m",
  cyan         = "\27[36m",
  bright_cyan  = "\27[96m",
  white        = "\27[37m",
  dim          = "\27[90m",
  magenta      = "\27[35m",
  -- Added so the goods table can separate colours that previously had to
  -- share a slot (six meats collapsing onto two reds, most notably). Plain
  -- SGR 3x/9x codes, same family as the ten above -- nothing here needs
  -- 256-colour or truecolour support.
  bright_yellow  = "\27[93m",
  bright_magenta = "\27[95m",
  bright_white   = "\27[97m",
  blue           = "\27[34m",
  bright_blue    = "\27[94m",
}

-- Strip SGR escapes and measure what's left. Simpler than the trunc walker
-- below since it doesn't need to preserve anything.
function pagelib.visible_width(s)
  local stripped = (s or ""):gsub("\27%[[%d;]*m", "")
  return #stripped
end

-- ANSI-aware truncation/padding to exactly `width` visible cells. Escape
-- sequences (\27[...m) are copied through verbatim and cost zero width;
-- everything else counts one cell. We walk the string one unit at a time
-- (one whole escape, or one visible char) so an escape can never be split
-- mid-sequence by the width cutoff: the loop only ever stops *between*
-- units, right when `visible == width`, never inside one.
function pagelib.trunc(s, width)
  s = s or ""
  if width < 0 then width = 0 end
  local out = {}
  local visible = 0
  local escaped = false
  local i, len = 1, #s
  while i <= len and visible < width do
    if s:byte(i) == 27 then
      local seq = s:match("^\27%[[%d;]*m", i)
      if seq then
        out[#out + 1] = seq
        escaped = true
        i = i + #seq
      else
        out[#out + 1] = s:sub(i, i)
        visible = visible + 1
        i = i + 1
      end
    else
      out[#out + 1] = s:sub(i, i)
      visible = visible + 1
      i = i + 1
    end
  end
  if visible < width then
    out[#out + 1] = string.rep(" ", width - visible)
  end
  if escaped then
    out[#out + 1] = pagelib.RESET
  end
  return table.concat(out)
end

-- Right-align to exactly `width` visible cells, padding on the LEFT. The
-- counterpart to trunc's left-align, for numeric columns: a column of prices
-- or profits has to stack on its digits, not on its leading "+" or "(", or
-- every row with one more digit pushes the rest of the line sideways.
--
-- Over-wide input is truncated from the left to keep the cell's width exact,
-- since the low-order digits are the ones that matter least to lose.
function pagelib.rjust(s, width)
  s = s or ""
  if width < 0 then width = 0 end
  local visible = pagelib.visible_width(s)
  if visible >= width then return pagelib.trunc(s, width) end
  return string.rep(" ", width - visible) .. s
end

-- Ported from LEGACY's fmt_num (/home/simon/code/3s_scripts_old/lua/guild_viking.lua:7423):
--   fmt_num = function(n)
--     local s = tostring(math.floor(n or 0))
--     local result = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
--     return result:gsub("^,", "")
--   end
-- Same convention: reverse, comma every 3 digits from the right, reverse
-- back, strip a leading comma left over from a length that's a multiple of 3.
function pagelib.fmt_num(n)
  local s = tostring(math.floor(n or 0))
  local result = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (result:gsub("^,", ""))
end

-- Ported from LEGACY's get_percent_color
-- (/home/simon/code/3s_scripts_old/lua/guild_viking.lua:342-355):
--   amount = (current or 0) / (max or 100)
--   > 0.9  -> "#19ff25" (bright green)
--   > 0.75 -> "#1e7523" (green)
--   > 0.5  -> "#f2e935" (yellow)
--   > 0.25 -> "#ffa500" (orange)
--   else   -> "#ff0000" (red)
-- Same five strict thresholds, mapped onto pagelib.C's green/yellow/red
-- family in best-to-worst order (five tiers, five colors: no separate
-- "orange" in the ANSI table, so that tier maps to red and the worst tier
-- to bright_red).
function pagelib.pct_color(val, max)
  local amount = (val or 0) / (max or 100)
  if amount > 0.9 then
    return pagelib.C.bright_green
  elseif amount > 0.75 then
    return pagelib.C.green
  elseif amount > 0.5 then
    return pagelib.C.yellow
  elseif amount > 0.25 then
    return pagelib.C.red
  else
    return pagelib.C.bright_red
  end
end

-- Text bar "[####----]" of exactly `width` total visible cells including
-- the brackets. `color` colors the filled run only, reset after.
function pagelib.bar(width, val, max, color)
  local inner = width - 2
  if inner < 0 then inner = 0 end
  val = val or 0
  max = max or 0
  local filled
  if max <= 0 then
    filled = 0
  elseif val >= max then
    filled = inner
  else
    filled = math.floor(inner * val / max + 0.5)
    if filled < 0 then filled = 0 end
    if filled > inner then filled = inner end
  end
  local empty = inner - filled
  local body
  if filled > 0 and color then
    body = color .. string.rep("#", filled) .. pagelib.RESET .. string.rep("-", empty)
  else
    body = string.rep("#", filled) .. string.rep("-", empty)
  end
  return "[" .. body .. "]"
end

-- Targets helper (Task 6): a bracketed clickable label ("[Run There]"),
-- colored, with its own PLAIN (escape-free) width returned alongside so a
-- caller building a window.lua pointer target's col_start/col_end can do
-- the column arithmetic in plain character counts -- the same "escapes
-- cost zero width" convention window.lua's render_tabbar already uses for
-- its own tab-span bookkeeping, rather than re-deriving width by stripping
-- escapes back out of the colored string via pagelib.visible_width.
function pagelib.button(text, color)
  local plain = "[" .. text .. "]"
  return (color or "") .. plain .. pagelib.RESET, #plain
end

-- Section header: text then a dash fill to exactly `width`, all in one
-- fixed header color. Overflow (text alone at/past width) truncates via
-- trunc exactly like every other primitive.
function pagelib.header(width, text)
  text = text or ""
  local raw = pagelib.C.yellow .. text .. " " .. string.rep("-", width)
  return pagelib.trunc(raw, width)
end

-- Dim label, a space, the (optionally colored) value, padded/truncated to
-- width.
function pagelib.kv(width, label, value, value_color)
  local raw = pagelib.C.dim .. (label or "") .. pagelib.RESET .. " " ..
    (value_color or "") .. tostring(value)
  return pagelib.trunc(raw, width)
end

-- cols: array of { title = string, w = number | "*" } -- exactly one "*"
-- column takes the leftover width. Returns an array: one header row
-- (titles, dim) followed by one row per entry in `rows` (each entry an
-- array of cell strings). Every cell is truncated independently via trunc,
-- so a too-long colored cell can never bleed its color into its neighbor.
function pagelib.columns(width, cols, rows)
  local n = #cols
  local fixed_total, star_idx = 0, nil
  for i, c in ipairs(cols) do
    if c.w == "*" then
      star_idx = i
    else
      fixed_total = fixed_total + c.w
    end
  end
  local sep_total = n > 0 and (n - 1) or 0
  local widths = {}
  local leftover = width - fixed_total - sep_total
  if leftover < 0 then leftover = 0 end
  for i, c in ipairs(cols) do
    widths[i] = (star_idx == i) and leftover or c.w
  end

  local function row_str(cells)
    local parts = {}
    for i = 1, n do
      parts[i] = pagelib.trunc(tostring(cells[i] or ""), widths[i])
    end
    return table.concat(parts, " ")
  end

  local out = {}
  local header_cells = {}
  for i, c in ipairs(cols) do
    header_cells[i] = pagelib.C.dim .. (c.title or "")
  end
  out[1] = row_str(header_cells)
  for _, r in ipairs(rows) do
    out[#out + 1] = row_str(r)
  end
  return out
end

return pagelib
