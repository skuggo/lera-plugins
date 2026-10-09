package.path = "3scapes/guild_viking/?.lua;" .. package.path
local J = require("hpbar_join")

-- What the player sees: kept lines, replacements in place of their line,
-- and the extra lines the plugin print()s right after that line.
local out, printed = {}, {}
print = function(l) printed[#printed + 1] = l end
local function feed(lines)
  out = {}
  for _, l in ipairs(lines) do
    printed = {}
    local r = J.on_line(l)
    if r == true then
      out[#out + 1] = l
    elseif type(r) == "string" then
      out[#out + 1] = r
    end
    for _, p in ipairs(printed) do out[#out + 1] = p end
  end
  return out
end

local H = "H[8269|8502(0|12753)] S[1774|2572] V[1872|2585] R[2400|2530] F[**--------] C[4/1]"

-- The wrapped bar from the MUD, rejoined.
local o = feed({
  "H[8269|8502(0|12753)] S[1774|2572] V[1872|2585] R[2400|2530] F[**-------",
  "-] C[4/1]",
  "G[6299833(3)|7341304(3)|7904467(2)|24226827(9)] L[4|4(%)] E[Deadl|36%|37",
  "]",
  "[aeg:457 skad:456 vkj:5 ram:417 tvi:366 bif:364 hug:135 bsjon:134",
  "hrei:162 jor:231 ljos:41]",
  "You hit the giant hard.",
})
assert(#o == 5, #o)
assert(o[1] == H, o[1])
assert(o[2] == "G[6299833(3)|7341304(3)|7904467(2)|24226827(9)] L[4|4(%)] E[Deadl|36%|37]", o[2])
-- Longer than the H[ line: re-wrapped at its width, one space at the join.
assert(#o[3] <= #H, #o[3])
assert(o[3] .. " " .. o[4] == "[aeg:457 skad:456 vkj:5 ram:417 tvi:366 bif:364 hug:135 bsjon:134 "
  .. "hrei:162 jor:231 ljos:41]", o[3] .. " | " .. o[4])
assert(o[5] == "You hit the giant hard.")

-- A long effects list wraps at the H[ line's width, not 72, and the MUD's
-- trailing space does not double up.
local e = feed({
  H,
  "[aeg:292 skad:291 vkj:450 ram:216 tvi:113 bif:108 hug:104 bsjon:103 ",
  "hrei:59 jor:90 ljos:45 isbi:11 hafg:17 grey:26 skra:8]",
})
assert(#e == 3, #e)
assert(not e[2]:find("  ") and not e[3]:find("  "), e[2])
assert(#e[2] <= #H and #e[2] > 72, #e[2])
assert(e[2] .. " " .. e[3] == "[aeg:292 skad:291 vkj:450 ram:216 tvi:113 bif:108 hug:104 bsjon:103 "
  .. "hrei:59 jor:90 ljos:45 isbi:11 hafg:17 grey:26 skra:8]", e[2] .. " | " .. e[3])

-- Colours survive a cut at column 72.
local c = feed({
  "\27[31mH[8269|8502(0|12753)] S[1774|2572] V[1872|2585] R[2400|2530] F[**-------\27[0m",
  "\27[31m-] C[4/1]\27[0m",
})
assert(#c == 1 and c[1]:find("F%[%*%*%-+\27%[0m\27%[31m%-%] C%[4/1%]"), c[1])

-- A bar that fits, and a chat line with a '[' in it, pass untouched.
local f = feed({ "H[1|2(0|3)] S[1|2] V[1|2] R[1|2] F[--] C[0/0]", "[Warders] Skuggis: hi [there" })
assert(#f == 2 and f[1]:find("C%[0/0%]$") and f[2] == "[Warders] Skuggis: hi [there")

io.write("hpbar_join: all cases pass\n")
