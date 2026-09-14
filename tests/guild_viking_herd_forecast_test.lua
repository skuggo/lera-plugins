-- Run from the plugin checkout: luajit tests/guild_viking_herd_forecast_test.lua
package.path = "3scapes/guild_viking/?.lua;" .. package.path
local M = require("herd_forecast")
local failures, cases = 0, 0
local function check(name, ok)
  cases = cases + 1
  print("CASE " .. name .. ": " .. (ok and "PASS" or "FAIL"))
  if not ok then failures = failures + 1 end
end
local function near(a, b)
  return type(a) == "number" and math.abs(a - b) < 1e-9
end
local function input(overrides)
  local t = {
    purchase_cost = 100, head = 10, cull_count = 2,
    yield_before = 50, yield_after = 75, production_per_tick = 10,
    output_unit_price = 2, output_demand = 1000,
    meat_qty = 2, meat_unit_price = 10, meat_demand = 100,
    horizon_ticks = 20, gap_ticks = 2, overhead = 5, scaled_share = 1,
  }
  for k, v in pairs(overrides or {}) do t[k] = v end
  return t
end
local function unknown(name, t)
  local r = M.evaluate(t)
  check(name, not r.known and #r.reasons > 0 and r.net_low == nil
    and r.net_high == nil and r.estimate == nil and r.break_even_ticks == nil
    and r.purchase_cost == nil and r.meat_revenue == nil
    and r.output_gain_low == nil and r.output_gain_high == nil)
end

local r = M.evaluate(input())
check("explicit ratio remains advisory", r.known and near(r.net_low, -125) and near(r.net_high, 55)
  and near(r.estimate, 55) and r.purchase_cost == 100 and r.meat_revenue == 20
  and r.output_gain_low == 0 and near(r.output_gain_high, 180))
check("advisory break-even includes whole-output gap", r.break_even_ticks == 15)
check("honest assumptions and exclusions", #r.assumptions > 0 and #r.excluded == 3
  and table.concat(r.assumptions, " "):find("not guaranteed profit", 1, true)
  and table.concat(r.excluded, " "):find("Transport", 1, true))

r = M.evaluate(input({ yield_after = 50 }))
check("equal yield does not count baseline revenue", r.net_low == -125
  and r.output_gain_low == 0 and r.break_even_ticks == nil)
r = M.evaluate(input({ gap_ticks = 0 }))
check("no gap still no guaranteed gain", r.net_low == -85 and r.break_even_ticks == 9)
r = M.evaluate(input({ gap_ticks = 20 }))
check("gap equals horizon", r.net_low == -485 and r.output_gain_high == 0
  and r.break_even_ticks == nil)
r = M.evaluate(input({ horizon_ticks = 1, gap_ticks = 0 }))
check("one tick horizon cannot break even", r.net_low == -85 and r.break_even_ticks == nil)
r = M.evaluate(input({ horizon_ticks = 12, purchase_cost = 75 }))
check("exact advisory break-even equality", r.estimate == 0 and r.break_even_ticks == 12)
r = M.evaluate(input({ scaled_share = 0.5 }))
check("explicit partial scaling advisory only", r.output_gain_low == 0 and r.net_low == -125
  and r.estimate == -35 and r.break_even_ticks == nil)
r = M.evaluate(input({ scaled_share = 0 }))
check("zero share valid", r.net_low == -125 and r.estimate == -125 and r.break_even_ticks == nil)

r = M.evaluate(input({ yield_after = 50.01, scaled_share = 1, gap_ticks = 0 }))
check("tiny discrete improvement never guaranteed even with explicit full share", r.output_gain_low == 0
  and r.net_low == -85 and r.output_gain_high > 0)
r = M.evaluate(input({ cull_count = 1 }))
check("gap loss not proportional to removed heads", r.net_low == -125)
local t = input()
t.scaled_share = nil
r = M.evaluate(t)
check("unknown share optimistic range, no invented midpoint", r.net_low == -125
  and r.net_high == 55 and r.output_gain_low == 0 and r.output_gain_high == 180
  and r.estimate == nil and r.break_even_ticks == nil)
t.yield_after = 25
r = M.evaluate(t)
check("declining yield loses at most full baseline", r.net_low == -485 and r.net_high == -125
  and r.output_gain_low == -360 and r.output_gain_high == 0)
r = M.evaluate(input({ yield_after = 0 }))
check("zero after yield valid and loses output", r.known and r.net_low == -485)
r = M.evaluate(input({ output_demand = 10 }))
check("current demand capped once across horizon", r.output_gain_high == 20
  and r.net_low == -125 and r.break_even_ticks == nil)
r = M.evaluate(input({ output_demand = 10, horizon_ticks = 2000 }))
check("long horizon never refreshes demand", r.net_high == -105)
r = M.evaluate(input({ output_demand = 62.5 }))
check("demand exactly covers advisory break-even", r.estimate == 0 and r.break_even_ticks == 15)
r = M.evaluate(input({ output_demand = 62.4 }))
check("demand just short prevents break-even", r.net_low < 0 and r.break_even_ticks == nil)
r = M.evaluate(input({ output_demand = 0 }))
check("zero output demand retains conservative gap loss", r.net_low == -125
  and r.output_gain_low == 0 and r.break_even_ticks == nil)
r = M.evaluate(input({ yield_after = 25, output_demand = 0 }))
check("demand cap cannot erase negative output changes", r.output_gain_low == -360)
r = M.evaluate(input({ meat_demand = 1 }))
check("meat demand bounded upfront only", r.meat_revenue == 10 and r.net_low == -135)
r = M.evaluate(input({ meat_demand = 0 }))
check("zero meat demand", r.meat_revenue == 0 and r.net_low == -145)
r = M.evaluate(input({ output_unit_price = 0 }))
check("zero output price valid", r.net_low == -85 and r.break_even_ticks == nil)
r = M.evaluate(input({ meat_unit_price = 0 }))
check("zero meat price valid", r.meat_revenue == 0 and r.net_low == -145)

t = input({ production_per_tick = 0, yield_before = 0 })
t.output_unit_price, t.output_demand = nil, nil
r = M.evaluate(t)
check("pigs/horses zero output without quotes", r.known and r.net_low == -85
  and r.output_gain_low == 0 and r.break_even_ticks == nil)
t.production_per_tick = nil
unknown("missing production is not zero", t)
unknown("positive output with zero yield cannot form ratio", input({ yield_before = 0 }))
unknown("zero yield unknown even with zero share", input({ yield_before = 0, scaled_share = 0 }))
unknown("zero yield unknown even for all-gap horizon", input({ yield_before = 0, gap_ticks = 20 }))

for _, key in ipairs({ "purchase_cost", "head", "cull_count", "yield_before", "yield_after",
    "production_per_tick", "output_unit_price", "output_demand", "meat_qty",
    "meat_unit_price", "meat_demand", "horizon_ticks", "gap_ticks", "overhead" }) do
  t = input()
  t[key] = nil
  unknown("required " .. key, t)
end
for _, key in ipairs({ "purchase_cost", "head", "cull_count", "yield_before", "yield_after",
    "production_per_tick", "output_unit_price", "output_demand", "meat_qty",
    "meat_unit_price", "meat_demand", "horizon_ticks", "gap_ticks", "overhead", "scaled_share" }) do
  for _, bad in ipairs({ -1, 0/0, math.huge, -math.huge, "10", false }) do
    t = input()
    t[key] = bad
    unknown("invalid " .. key .. " " .. tostring(bad), t)
  end
end
for _, bad in ipairs({ { head = 0 }, { cull_count = 0 }, { cull_count = 11 },
    { yield_before = 101 }, { yield_after = 101 }, { scaled_share = 1.01 },
    { horizon_ticks = 0 }, { horizon_ticks = 1.5 }, { gap_ticks = 0.5 },
    { gap_ticks = 21 } }) do
  unknown("invalid bounds", input(bad))
end
unknown("invalid input table", false)
unknown("missing input table", nil)
unknown("finite inputs overflowing costs", input({ purchase_cost = 1e308, overhead = 1e308 }))
unknown("finite inputs overflowing rate despite cap", input({ production_per_tick = 1e308 }))
unknown("finite inputs overflowing meat", input({ meat_unit_price = 1e308 }))
unknown("optional quote still validated at zero production",
  input({ production_per_tick = 0, output_unit_price = math.huge }))

-- This module must not acquire state or execute slaughter/cull/sale commands.
local previous_mud = _G.mud
_G.mud = { send = function() error("forecast must never send commands") end }
t = input({ purchase_cost = 0, overhead = 0, gap_ticks = 0, production_per_tick = 0 })
r = M.evaluate(t)
check("free cull needs no slaughter action or invented fee", r.known and r.net_low == 20
  and r.purchase_cost == 0 and r.meat_revenue == 20 and M.tick == nil)
_G.mud = previous_mud

t = input()
t.extra = { untouched = true }
local snapshot = {}
for k, v in pairs(t) do snapshot[k] = v end
r = M.evaluate(t)
local unchanged = true
for k, v in pairs(t) do if snapshot[k] ~= v then unchanged = false end end
for k, v in pairs(snapshot) do if t[k] ~= v then unchanged = false end end
check("does not mutate input", unchanged and t.extra.untouched)
r.assumptions[1] = "changed"
r.excluded[1] = "changed"
r.reasons[1] = "changed"
local fresh = M.evaluate(t)
check("fresh results have no shared module state", fresh.assumptions[1] ~= "changed"
  and fresh.excluded[1] ~= "changed" and #fresh.reasons == 0 and fresh.net_low == -125)
check("no autoherd or state dependency loaded", package.loaded.autoherd == nil
  and package.loaded.state == nil and package.loaded.persist == nil)

print(string.format("%d cases, %d failures", cases, failures))
if failures > 0 then os.exit(1) end
