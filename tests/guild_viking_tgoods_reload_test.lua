-- TGOODS after a plugin reload. Run from the repository root.
-- The server sends the stream's lin_count only when it changes, so a
-- reloaded writer sees lineage slices with no count: it must not error on
-- every push, it asks once for a full Guild resend and waits for it.
package.path = "3scapes/guild_viking/?.lua;" .. package.path

ui = { dirty = function() end }
buffer = { color_print = function() end }
mud = { connected = function() return true end, send = function() end }
store = { load = function() end, get = function() return nil end,
          set = function() end, save = function() end }

local real_time = os.time
local now = real_time()
os.time = function() return now end

local resends = {}
gmcp = {
  enabled = function() return true end,
  send = function(pkg, data) resends[#resends + 1] = { pkg = pkg, data = data } end,
}

local S = require("state").S
local trade = require("handlers.trade")._gmcp

local fails = 0
local function check(name, cond, detail)
  if cond then print("CASE " .. name .. ": PASS")
  else fails = fails + 1; print("CASE " .. name .. ": FAIL " .. tostring(detail or "")) end
end

local slice = { lin = 3, goods = { { good = "fish", score = 5, sup = 10, dem = 4, buy = 7, sell = 6 } } }

local ok, err = pcall(trade.TGOODS, slice)
check("a slice before lin_count does not error", ok, err)
check("it asks once for a full Guild resend",
      #resends == 1 and resends[1].pkg == "Core.Supports.Add"
        and resends[1].data[1] == "Guild 1", #resends)

now = now + 30
pcall(trade.TGOODS, slice)
check("no second resend inside a minute", #resends == 1, #resends)

now = now + 31
pcall(trade.TGOODS, slice)
check("asks again after a minute without the count", #resends == 2, #resends)

-- The full push arrives with the count: the stream assembles as normal.
ok, err = pcall(trade.TGOODS, { lin = 0, lin_count = 1,
  goods = { { good = "fish", score = 5, sup = 10, dem = 4, buy = 7, sell = 6 } } })
check("with lin_count the stream completes", ok and S.trade_goods and S.trade_goods[0] ~= nil, err)

if fails > 0 then print("guild_viking_tgoods_reload: " .. fails .. " FAILED"); os.exit(1) end
print("ALL TGOODS RELOAD TESTS PASSED")
