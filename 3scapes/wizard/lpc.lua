-- LPC syntax highlighting, line at a time, emitting plain SGR escapes.
--
-- Line-at-a-time because that is how the text reaches us: `more` sends a file
-- through the output stream one line per line, so the highlighter has to be
-- resumable rather than seeing a whole buffer. Everything that can span lines
-- lives in the state table threaded through line() -- today that is the block
-- comment and nothing else.
--
-- Deliberately a LEXER, not a parser. It knows strings, comments, the
-- preprocessor, numbers and a keyword list; it does not know types from
-- variables, or which identifier is a function. That is enough to read code
-- with and cheap enough to run on every line of a 4,000-line daemon.
--
-- The one rule that matters for correctness: a comment introducer inside a
-- string is not a comment, and a quote inside a comment is not a string. A
-- naive gsub-based highlighter gets both wrong, which is why this walks the
-- line by hand.

local M = {}

local RESET = "\27[0m"

M.COLORS = {
  comment = "\27[90m",   -- dim: present, not competing
  preproc = "\27[95m",   -- bright magenta
  string  = "\27[33m",   -- yellow
  number  = "\27[36m",   -- cyan
  keyword = "\27[94m",   -- bright blue: control flow
  type    = "\27[96m",   -- bright cyan: types and modifiers
  -- Most of a mudlib file is CALLS -- set_name, add_clone, ::create -- and a
  -- highlighter that paints only keywords leaves those pages nearly plain.
  func    = "\27[93m",   -- bright yellow: an identifier being called
  -- ALL_CAPS is the mudlib's macro convention (ANGPATH_ROOM, MAX_PRIV), and
  -- knowing at a glance which names come from a header is most of reading an
  -- area file.
  macro   = "\27[35m",   -- magenta
}

-- Control flow and the statement words. Split from types below purely so the
-- two read differently on screen.
local KEYWORDS = {}
for w in ([[
  if else for foreach while do switch case default break continue return
  inherit include catch sscanf new in
]]):gmatch("%S+") do KEYWORDS[w] = true end

-- Types, storage classes and modifiers -- everything that decorates a
-- declaration rather than driving control.
local TYPES = {}
for w in ([[
  int string object mapping mixed float status void closure symbol struct
  private public protected static nomask varargs virtual nosave
]]):gmatch("%S+") do TYPES[w] = true end

function M.new_state()
  return { in_comment = false }
end

local function paint(out, color, text)
  if color then
    out[#out + 1] = color
    out[#out + 1] = text
    out[#out + 1] = RESET
  else
    out[#out + 1] = text
  end
end

-- One line in, one painted line out, plus the state to feed the next line.
--
-- `state` may be nil, which starts clean -- a caller that highlights a single
-- line in isolation does not have to invent one.
function M.line(text, state)
  if type(text) ~= "string" then return text, state end
  state = state or M.new_state()

  local out = {}
  local i, n = 1, #text
  local C = M.COLORS

  while i <= n do
    -- Inside a block comment: everything up to a closing */ is comment,
    -- including quotes and #directives.
    if state.in_comment then
      local close = text:find("*/", i, true)
      if close then
        paint(out, C.comment, text:sub(i, close + 1))
        i = close + 2
        state.in_comment = false
      else
        paint(out, C.comment, text:sub(i))
        i = n + 1
      end

    else
      local c = text:sub(i, i)
      local two = text:sub(i, i + 1)

      if two == "/*" then
        state.in_comment = true

      elseif two == "//" then
        -- To end of line, whatever it contains.
        paint(out, C.comment, text:sub(i))
        i = n + 1

      elseif c == '"' or c == "'" then
        -- Scan to the matching quote, honouring backslash escapes so
        -- "a\"b" is one string and not two.
        local j = i + 1
        while j <= n do
          local ch = text:sub(j, j)
          if ch == "\\" then j = j + 2
          elseif ch == c then break
          else j = j + 1 end
        end
        if j > n then
          -- Unterminated: colour the rest and stop. Better than dropping it.
          paint(out, C.string, text:sub(i))
          i = n + 1
        else
          paint(out, C.string, text:sub(i, j))
          i = j + 1
        end

      elseif c == "#" and text:sub(1, i - 1):match("^%s*$") then
        -- A preprocessor directive, but only when it is the first thing on
        -- the line: `#` elsewhere is an operator or part of a closure.
        local word = text:match("^#%s*%a*", i) or c
        paint(out, C.preproc, word)
        i = i + #word

      elseif c:match("%d") and not text:sub(i - 1, i - 1):match("[%w_]") then
        local num = text:match("^0[xX]%x+", i) or text:match("^%d+%.?%d*", i) or c
        paint(out, C.number, num)
        i = i + #num

      elseif c:match("[%a_]") then
        local word = text:match("^[%w_]+", i)
        -- What follows decides between a call and a bare name, so look past
        -- any spaces to the next character.
        local after = text:match("^%s*(.)", i + #word)
        if KEYWORDS[word] then paint(out, C.keyword, word)
        elseif TYPES[word] then paint(out, C.type, word)
        -- A macro is ALL_CAPS with no lower-case letter in it. Digits and
        -- underscores are allowed (GOOD_IRON, LSTOCK_TRAIT_PCT_R1); a single
        -- capital is not, since `N` in a $N$ message is not a macro.
        elseif #word > 1 and word:match("^[A-Z][A-Z0-9_]*$") then
          paint(out, C.macro, word)
        elseif after == "(" then paint(out, C.func, word)
        else paint(out, nil, word) end
        i = i + #word

      else
        paint(out, nil, c)
        i = i + 1
      end

      -- The /* branch above only sets the flag; emitting is left to the
      -- in_comment arm on the next turn of the loop so the opener and the
      -- body are coloured by one piece of code.
      if state.in_comment and two == "/*" then
        local close = text:find("*/", i + 2, true)
        if close then
          paint(out, C.comment, text:sub(i, close + 1))
          i = close + 2
          state.in_comment = false
        else
          paint(out, C.comment, text:sub(i))
          i = n + 1
        end
      end
    end
  end

  return table.concat(out), state
end

-- Whole-text convenience, for a caller that does have the entire file.
function M.highlight(text)
  local state = M.new_state()
  local out = {}
  for line in tostring(text):gmatch("([^\n]*)\n?") do
    local painted
    painted, state = M.line(line, state)
    out[#out + 1] = painted
  end
  return table.concat(out, "\n")
end

-- Whether a path is worth highlighting at all. `more` on a .o save file or a
-- log should come through untouched.
function M.applies(path)
  if type(path) ~= "string" then return false end
  local ext = path:match("%.([%w_]+)$")
  if not ext then return false end
  ext = ext:lower()
  return ext == "c" or ext == "h" or ext == "lpc"
end

return M
