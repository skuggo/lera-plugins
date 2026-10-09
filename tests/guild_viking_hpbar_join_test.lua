package.path = "3scapes/guild_viking/?.lua;" .. package.path
local J = require("hpbar_join")
local out = {}
local function feed(lines)
  out = {}
  for _, l in ipairs(lines) do
    local r = J.on_line(l)
    if r == true then out[#out+1] = l elseif type(r) == "string" then out[#out+1] = r end
  end
  return out
end
local o = feed({
  "H[8269|8502(0|12753)] S[1774|2572] V[1872|2585] R[2400|2530] F[**-------",
  "-] C[4/1]",
  "G[6299833(3)|7341304(3)|7904467(2)|24226827(9)] L[4|4(%)] E[Deadl|36%|37",
  "]",
  "[aeg:457 skad:456 vkj:5 ram:417 tvi:366 bif:364 hug:135 bsjon:134",
  "hrei:162 jor:231 ljos:41]",
  "You hit the giant hard.",
})
assert(#o == 4, #o)
assert(o[1] == "H[8269|8502(0|12753)] S[1774|2572] V[1872|2585] R[2400|2530] F[**--------] C[4/1]", o[1])
assert(o[2] == "G[6299833(3)|7341304(3)|7904467(2)|24226827(9)] L[4|4(%)] E[Deadl|36%|37]", o[2])
assert(o[3] == "[aeg:457 skad:456 vkj:5 ram:417 tvi:366 bif:364 hug:135 bsjon:134 hrei:162 jor:231 ljos:41]", o[3])
assert(o[4] == "You hit the giant hard.")
-- Colours survive; a bar that fits is untouched; ordinary [ lines untouched.
local c = feed({ "\27[31mH[8269|8502(0|12753)] S[1774|2572] V[1872|2585] R[2400|2530] F[**-------\27[0m", "\27[31m-] C[4/1]\27[0m" })
assert(#c == 1 and c[1]:find("F%[%*%*%-+\27%[0m\27%[31m%-%] C%[4/1%]"), c[1])
local f = feed({ "H[1|2(0|3)] S[1|2] V[1|2] R[1|2] F[--] C[0/0]", "[Warders] Skuggis: hi [there" })
assert(#f == 2 and f[1]:find("C%[0/0%]$") and f[2] == "[Warders] Skuggis: hi [there")
print("hpbar_join: all cases pass")
