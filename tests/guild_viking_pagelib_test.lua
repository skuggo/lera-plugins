-- pagelib unit tests. Pure module: no lera stubs needed. Run from the
-- lera-plugins repo root with LERA_ROOT pointing at a built Lera checkout.
package.path = "3scapes/guild_viking/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
  if ok then
    print("CASE " .. name .. ": PASS")
  else
    failures = failures + 1
    print("CASE " .. name .. ": FAIL" .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

local pagelib = require("pagelib")
local C, RESET = pagelib.C, pagelib.RESET

-- ---- literal byte values ---------------------------------------------------
check("RESET is literal SGR reset", RESET == "\27[0m")
check("C.green is literal SGR", C.green == "\27[32m")
check("C.dim is literal SGR (spec-mandated \\27[90m)", C.dim == "\27[90m")

-- ---- trunc: the primitive --------------------------------------------------
check("trunc pads plain text", pagelib.trunc("hi", 5) == "hi   ")
check("trunc truncates plain text", pagelib.trunc("hello world", 5) == "hello")
check("trunc exact width, no pad no escape", pagelib.trunc("abc", 3) == "abc")

check("trunc pads colored text and appends reset",
  pagelib.trunc(C.green .. "hi" .. RESET, 5) ==
  C.green .. "hi" .. RESET .. "   " .. RESET)

check("trunc truncates colored text and appends reset",
  pagelib.trunc(C.red .. "hello world", 5) == C.red .. "hello" .. RESET)

-- Escape split at the boundary: an escape sequence positioned exactly at
-- the visible-width cutoff must be dropped whole (never partially copied),
-- while one positioned just before the cutoff must be copied whole.
check("trunc drops an escape sitting exactly at the cutoff",
  pagelib.trunc("abc" .. C.red, 3) == "abc")
check("trunc keeps an escape sitting just before the cutoff",
  pagelib.trunc("ab" .. C.red .. "c", 3) == "ab" .. C.red .. "c" .. RESET)

check("trunc width 0 empty input", pagelib.trunc("", 0) == "")
check("trunc width 0 non-empty input", pagelib.trunc("xyz", 0) == "")

-- ---- visible_width ----------------------------------------------------------
check("visible_width plain", pagelib.visible_width("hello") == 5)
check("visible_width strips ANSI", pagelib.visible_width(C.green .. "hi" .. RESET) == 2)
check("visible_width empty", pagelib.visible_width("") == 0)

-- ---- fmt_num: ported from LEGACY (guild_viking.lua:7423) -------------------
-- LEGACY: s:reverse():gsub("(%d%d%d)", "%1,"):reverse(), strip leading comma.
check("fmt_num(0)", pagelib.fmt_num(0) == "0")
check("fmt_num(999)", pagelib.fmt_num(999) == "999")
check("fmt_num(1000) exact 3-digit-group boundary", pagelib.fmt_num(1000) == "1,000")
check("fmt_num(1234567)", pagelib.fmt_num(1234567) == "1,234,567")
check("fmt_num(nil) treated as 0", pagelib.fmt_num(nil) == "0")

-- ---- pct_color: ported from LEGACY get_percent_color (guild_viking.lua:342) -
-- Thresholds: >0.9 bright_green, >0.75 green, >0.5 yellow, >0.25 red, else bright_red.
check("pct_color at 0.9 boundary (not >) falls to green", pagelib.pct_color(90, 100) == C.green)
check("pct_color at 0.9+1", pagelib.pct_color(91, 100) == C.bright_green)
check("pct_color at 0.75 boundary falls to yellow", pagelib.pct_color(75, 100) == C.yellow)
check("pct_color at 0.75+1", pagelib.pct_color(76, 100) == C.green)
check("pct_color at 0.5 boundary falls to red", pagelib.pct_color(50, 100) == C.red)
check("pct_color at 0.5+1", pagelib.pct_color(51, 100) == C.yellow)
check("pct_color at 0.25 boundary falls to bright_red", pagelib.pct_color(25, 100) == C.bright_red)
check("pct_color at 0.25+1", pagelib.pct_color(26, 100) == C.red)

-- ---- bar --------------------------------------------------------------------
check("bar at 0%", pagelib.bar(10, 0, 100, C.green) == "[--------]")
check("bar at 50%", pagelib.bar(10, 50, 100, C.green) ==
  "[" .. C.green .. "####" .. RESET .. "----]")
check("bar at 100%", pagelib.bar(10, 100, 100, C.green) ==
  "[" .. C.green .. "########" .. RESET .. "]")
check("bar val > max clamps full", pagelib.bar(10, 150, 100, C.green) ==
  "[" .. C.green .. "########" .. RESET .. "]")
check("bar max <= 0 renders empty", pagelib.bar(10, 5, 0, C.green) == "[--------]")

-- ---- header -----------------------------------------------------------------
check("header fills to exact width", pagelib.header(20, "Stats") ==
  C.yellow .. "Stats " .. string.rep("-", 14) .. RESET)
check("header text at/past width truncates",
  pagelib.header(5, "LongTitleHere") == C.yellow .. "LongT" .. RESET)

-- ---- kv -----------------------------------------------------------------
check("kv pads label+value to width", pagelib.kv(20, "HP", "123", C.green) ==
  C.dim .. "HP" .. RESET .. " " .. C.green .. "123" .. string.rep(" ", 14) .. RESET)
check("kv without value_color", pagelib.kv(10, "X", "1") ==
  C.dim .. "X" .. RESET .. " " .. "1" .. string.rep(" ", 7) .. RESET)

-- ---- columns ------------------------------------------------------------
local cols = {
  { title = "Name", w = 8 },
  { title = "HP",   w = "*" },
  { title = "Lvl",  w = 4 },
}
-- width 20: fixed 8+4=12, 2 separators -> leftover for "*" = 20-12-2 = 6
local rows = {
  { "Thorvald", C.red .. "LOWHPLOWHPLOWHP", "5" },
}
local out = pagelib.columns(20, cols, rows)

check("columns returns header + 1 row", #out == 2)
check("columns header row", out[1] ==
  table.concat({
    C.dim .. "Name" .. string.rep(" ", 4) .. RESET,
    C.dim .. "HP" .. string.rep(" ", 4) .. RESET,
    C.dim .. "Lvl " .. RESET,
  }, " "))
check("columns data row: exact cell + no-bleed truncated cell + padded cell", out[2] ==
  table.concat({
    "Thorvald",
    C.red .. "LOWHPL" .. RESET,
    "5" .. string.rep(" ", 3),
  }, " "))

-- ---- rjust ------------------------------------------------------------------
-- The counterpart to trunc's left-align. What matters for a numeric column is
-- that two values of DIFFERENT digit counts end at the same cell, so the pairs
-- below are asserted against each other, not just against a literal.
check("rjust pads on the left", pagelib.rjust("42", 5) == "   42")
check("rjust exact width is unchanged", pagelib.rjust("12345", 5) == "12345")
check("rjust zero width", pagelib.rjust("42", 0) == "")
check("rjust nil is all padding", pagelib.rjust(nil, 3) == "   ")
check("rjust ignores ANSI when measuring",
  pagelib.visible_width(pagelib.rjust(C.green .. "42" .. RESET, 5)) == 5)
check("digit counts end in the same column",
  #pagelib.rjust("+7d", 8) == #pagelib.rjust("+13464d", 8))
-- Over-wide input keeps the cell exact rather than pushing the row sideways;
-- trunc drops from the right, which is what the width contract requires.
check("rjust truncates over-wide input to the cell",
  pagelib.visible_width(pagelib.rjust("1234567", 4)) == 4)

if failures > 0 then os.exit(1) end
print("ALL PAGELIB TESTS PASSED")
