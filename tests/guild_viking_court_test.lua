-- Court (master specialists, building stars) tests. Run from the repository
-- root. Frames go through the real GMCP writer (handlers/city.lua) in the
-- shape the server sends (players/viking/obj/include/builders.h _v_court()
-- and _v_buildings()'s "stars").
package.path = "3scapes/guild_viking/?.lua;" .. package.path

ui = { dirty = function() end }
local printed = {}
buffer = { color_print = function(_, _, t) printed[#printed + 1] = t end }
local sent = {}
mud = { connected = function() return true end,
        send = function(command) sent[#sent + 1] = command end }
store = { load = function() end, get = function() return nil end,
          set = function() end, save = function() end }

local real_time = os.time
local now = real_time()
os.time = function() return now end

local opts = require("page_opts")
local S = require("state").S
local city = require("handlers.city")._gmcp
local page = require("pages.city")
local notify = require("notify")
local pushed = {}
notify.set_push({ notify = function(_, msg) pushed[#pushed + 1] = msg end })

local function render()
  return table.concat(page.lines(80), "\n")
end

-- 1) Stars arrive on the buildings list and show beside the tier.
city.BUILDINGS({ { id = "warehouse", tier = 5, stars = 2 }, { id = "farm", tier = 5 } })
assert(S.buildings.warehouse == 5 and S.building_stars.warehouse == 2,
  "stars are kept per building")
assert(S.building_stars.farm == nil, "a building without stars has none")
opts.set("show_city_buildings", true)
assert(render():find("Warehouse T5 ★★", 1, true), "the city page shows a starred tier")
print("guild_viking court stars: PASS")

-- 2) A locked court says what is still missing.
city.COURT({ unlocked = 0, chance = 6, fraegd = 200, need = "a throne room" })
assert(S.court.unlocked == false and S.court.need == "a throne room")
opts.set("show_city_court", true)
local out = render()
assert(out:find("Court", 1, true) and out:find("a throne room", 1, true),
  "a locked court names the missing gate")
print("guild_viking court locked: PASS")

-- 3) An offer shows name, building, step, price and time left.
local offer = { name = "Alfvard", title = "runesmith", bldg = "warehouse", to = 3,
                secs = 3 * 86400, daler = 5600000, fraegd = 2500 }
city.COURT({ unlocked = 1, chance = 12, fraegd = 3000, offer = offer })
out = render()
for _, want in ipairs({ "Alfvard", "Warehouse", "3-star", "5,600,000", "2500", "3d" }) do
  assert(out:find(want, 1, true), "the offer shows '" .. want .. "':\n" .. out)
end
assert(#pushed == 0, "no reminder while days remain")
print("guild_viking court offer: PASS")

-- 4) Under a day left: one reminder, not one per frame.
offer.secs = 20 * 3600
city.COURT({ unlocked = 1, chance = 12, fraegd = 3000, offer = offer })
city.COURT({ unlocked = 1, chance = 12, fraegd = 3000, offer = offer })
assert(#pushed == 1 and pushed[1]:find("Alfvard", 1, true),
  "exactly one reminder before the visitor leaves, got " .. #pushed)
print("guild_viking court reminder: PASS")

-- 5) The arrival line the server prints fires an alert.
local hit
for _, t in ipairs(notify.triggers) do
  if t.name == "push_court_specialist" then hit = t end
end
assert(hit, "a trigger for the specialist's arrival")
local line = "[Court] Alfvard, a runesmith, has come to court offering to perfect "
  .. "your Warehouse. See 'vbuild specialist' to hear their price."
assert(line:find(hit.pattern, 1, true), "the trigger matches the server line")
hit.fn(line)
assert(pushed[#pushed]:find("specialist", 1, true), "the arrival alert names the specialist")
print("guild_viking court arrival: PASS")

os.time = real_time
