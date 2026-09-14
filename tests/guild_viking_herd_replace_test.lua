-- Run from the plugin checkout: luajit tests/guild_viking_herd_replace_test.lua
package.path = "3scapes/guild_viking/?.lua;" .. package.path
local M = require("herd_replace")
local failures, checks = 0, 0
local function check(name, ok)
  checks = checks + 1
  if not ok then failures = failures + 1 end
  print("CASE " .. name .. ": " .. (ok and "PASS" or "FAIL"))
end
local function copy(t)
  if type(t) ~= "table" then return t end
  local r = {}; for k, v in pairs(t) do r[k] = copy(v) end; return r
end
local function equal(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not equal(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end
-- Any hidden side effect is a hard test failure.
mud = { send = function() error("replacement must never send") end }
local function fixture(b)
  b = b or "sheepfold"
  local sp = ({ sheepfold = "sheep", stable = "horse", piggery = "pig" })[b]
  local ctx = { now = 1700000000, epoch = 1, connected = true, master_enabled = true,
    daler = 1000, reserve = 200, global_keep = 4, quality_margin = 5,
    building_settings = {}, herds = {}, lpending = {}, bqueue = {}, bqueue_used = 0,
    bqueue_max = 4, observed = {}, weights = { hard = 0.2, fert = 0.2,
      yield = 0.2, vigor = 0.2, con = 0.2 }, prices = {} }
  local g = { cap = 20, pending = 0, free = 0, protected = 4, cullable = 16,
    auto_slaughter = 0, stats = { hard = 5000, fert = 5000, yield = 5000,
      vigor = 5000, con = 5000, quality = 5000 } }
  ctx.herds[b] = { head = 20, management = g, _received_at = ctx.now }
  ctx.lmarket = { [1] = { { lin = 1, idx = 0, species = sp, breed = "nordic",
    count = 5, available = 5, unit_price = 10, price = 50,
    token = string.rep("a", 32), hard = 90, fert = 90, yield = 90,
    vigor = 90, con = 90, _received_at = ctx.now } } }
  for _, k in ipairs({ "herds", "pending", "bqueue", "daler", "prices" }) do
    ctx.observed[k] = { at = ctx.now, seq = 1 }
  end
  for _, k in ipairs({ "mutton", "wool", "horsemeat", "pork" }) do
    ctx.prices[k] = { sell = 100, demand = 100, buy = 110, supply = 10, at = ctx.now }
  end
  local opts = M.defaults()
  opts.enabled, opts.overhead = true, 0
  opts.models[b] = { production_per_tick = b == "sheepfold" and 1 or 0 }
  return ctx, opts
end
local function receipt(ctx, key)
  ctx.observed[key] = { at = ctx.now, seq = ctx.observed[key].seq + 1 }
end
local function cull(ctx, b)
  b = b or "sheepfold"
  ctx.now = ctx.now + 1
  ctx.herds[b].head = 18
  ctx.herds[b].management.free = 2
  ctx.herds[b].management.cullable = 14
  ctx.herds[b]._received_at = ctx.now
  receipt(ctx, "herds")
  ctx.bqueue = { { slot = 1, species = ctx.lmarket[1][1].species,
    meat = ({ sheepfold = "mutton", stable = "horsemeat", piggery = "pork" })[b], qty = 24 } }
  ctx.bqueue_used = 1
  receipt(ctx, "bqueue")
end
local function expect_block(name, mutate, b)
  local ctx, opts = fixture(b)
  mutate(ctx, opts)
  local p = M.propose(ctx, opts)
  local action = M.step(ctx, opts)
  check(name, p == nil and action == nil and not M.busy(opts))
end
do
  local function rejected(name, mutate, expected)
    local c, s = fixture()
    mutate(c, s)
    local before_c, before_s = copy(c), copy(s)
    local plan, reason, details = M.preview(c, s)
    check("preview reason: " .. name, not plan
      and reason == "no eligible modeled replacement under current limits"
      and #details == 1 and details[1].building == "sheepfold"
      and details[1].reason:find(expected, 1, true) ~= nil)
    check("preview no effects: " .. name, equal(c, before_c) and equal(s, before_s)
      and not M.busy(s))
    check("execution still rejects: " .. name, M.propose(c, s) == nil and M.step(c, s) == nil)
  end
  rejected("not full without offers", function(c)
    c.herds.sheepfold.head = 19; c.herds.sheepfold.management.free = 1
        c.herds.sheepfold.management.cullable = 15; c.lmarket = {}
  end, "pen not full: head 19/cap 20")
  rejected("server slaughter", function(c) c.herds.sheepfold.management.auto_slaughter = 2 end, "auto_slaughter must be zero (actual 2)")
  rejected("disabled pen", function(c) c.building_settings.sheepfold = { enabled = false } end, "disabled")
  rejected("protected", function(c)
    c.herds.sheepfold.management.protected = 20; c.herds.sheepfold.management.cullable = 0
  end, "protected 20")
  rejected("keep", function(_, s) s.min_keep = 20 end, "keep 20")
  rejected("fraction", function(_, s) s.max_fraction = 0 end, "max_fraction 0 (floor 0)")
  rejected("max cull", function(_, s) s.max_cull = 0 end, "max_cull 0")
  rejected("no species offers", function(c) c.lmarket[1][1].species = "horse" end, "no sheep offers")
  rejected("stale offers", function(c) c.lmarket[1][1]._received_at = c.now - 181 end, "stale/missing offer")
  rejected("invalid offers", function(c) c.lmarket[1][1].offer_valid = false end, "offer_valid=false")
  rejected("protected offer metadata", function(c) c.lmarket[1][1].token = nil end, "protected offer metadata")
  rejected("pending", function(c) c.lpending = { { bldg = "sheepfold", count = 1 } } end, "pending livestock")
  rejected("reserve", function(c) c.daler = 210 end, "cost 20 exceeds wallet 210 minus reserve 200")
  rejected("cost", function(_, s) s.max_cost = 19 end, "cost 20 exceeds max_cost 19")
  rejected("daily cost", function(_, s) s.daily_cost = 19 end, "exceeds daily_cost 19")
  rejected("daily cull", function(_, s) s.daily_cull = 1 end, "daily_cull budget")
  rejected("raw quality", function(c)
    for _, key in ipairs({ "hard", "fert", "yield", "vigor", "con" }) do c.lmarket[1][1][key] = 54 end
  end, "raw quality margin 4 <= required 5")
  rejected("no quality gain", function(c)
    for _, key in ipairs({ "hard", "fert", "yield", "vigor", "con" }) do c.lmarket[1][1][key] = 50 end
  end, "no positive valid herd quality gain")
  rejected("missing production", function(_, s) s.models = {} end, "stale/missing production")
  rejected("missing prices", function(c) c.prices.wool = nil end, "wool sell/demand price")
  rejected("unknown forecast", function(_, s) s.models.sheepfold.scaled_share = 2 end, "unknown forecast: scaled_share")

  local c, s = fixture()
  local expected = M.propose(c, s)
  local before_c, before_s = copy(c), copy(s)
  local plan, reason, details = M.preview(c, s)
  check("valid candidate and first two returns unchanged", equal(plan, expected) and reason == "ready" and #details == 0)
  check("valid preview is pure", equal(c, before_c) and equal(s, before_s) and not M.busy(s))
  s.enabled, c.master_enabled = false, false
  check("diagnostics do not enable", M.preview(c, s) ~= nil and not s.enabled and not c.master_enabled and M.step(c, s) == nil)

  c, s = fixture()
  local stale = copy(c.lmarket[1][1]); stale._received_at = c.now - 181
  c.lmarket[1][1].token = nil
  c.lmarket[1][2] = stale
  for i = 3, 100 do local o = copy(stale); o.species = "horse"; c.lmarket[1][i] = o end
  local _, _, first = M.preview(c, s)
  c.lmarket[1][1], c.lmarket[1][2] = c.lmarket[1][2], c.lmarket[1][1]
  local _, _, second = M.preview(c, s)
  check("deterministic same-gate tie and no species flood", #first == 1 and equal(first, second)
    and first[1].reason:find("protected offer metadata", 1, true))
  c.lmarket[1][2].token = string.rep("a", 32); s.max_cost = 1
  local _, _, furthest = M.preview(c, s)
  check("furthest actual candidate gate wins", #furthest == 1 and furthest[1].reason:find("max_cost", 1, true))
  c.buildings = {}
  local _, _, unowned = M.preview(c, s)
  check("no unowned pen diagnostics", #unowned == 0)
  c.buildings = { sheepfold = 1, stable = 1 }
  c.herds.stable = copy(c.herds.sheepfold); c.herds.stable.management.auto_slaughter = 1
  local _, _, owned = M.preview(c, s)
  check("only owned pens sorted", #owned == 2 and owned[1].building == "sheepfold" and owned[2].building == "stable")
  c.buildings = nil; c.lmarket = {}
  for _, b in ipairs({ "byre", "henhouse", "piggery" }) do c.herds[b] = copy(c.herds.sheepfold) end
  local _, _, bounded = M.preview(c, s)
  check("at most five sorted pen details", #bounded == 5 and bounded[1].building == "byre" and bounded[5].building == "stable")
  c.observed.prices = nil
  local _, global, no_details = M.preview(c, s)
  check("global gates keep legacy summary and bounded third return", global == "stale/missing prices (last full grid missing/invalid receipt)" and #no_details == 0)
end
local ctx, opts = fixture()
local before_ctx, before_opts = copy(ctx), copy(opts)
local p = M.propose(ctx, opts)
check("pure propose", p and equal(ctx, before_ctx) and equal(opts, before_opts))
check("defaults and independent models", M.DEFAULTS.enabled == false and M.DEFAULTS.overhead == nil
  and M.DEFAULTS.max_age == 180 and M.DEFAULTS.price_max_age == 600
    and next(M.defaults().models) == nil)
check("conservative full-head x100 forecast", p and p.count == 2 and p.after_stats.yield == 5400
  and p.forecast_input.yield_before == 50 and p.forecast_input.yield_after == 54
  and p.forecast_input.meat_qty == 2 and p.forecast.net_low == 80
  and p.why:find("lower-bound gross opportunity", 1, true))
opts.dry_run = true
check("dry run returns zero commands", M.step(ctx, opts) == nil and not M.busy(opts))
opts.dry_run = nil
local a, status = M.step(ctx, opts)
check("first action is one worst cull", a and a.kind == "slaughter"
  and a.cmd == "vlivestock slaughter sheepfold 2 worst" and status.phase == "await_cull")
check("exposures and marker precede command", opts.daily.spent == 20 and opts.daily.culled == 2
  and opts.in_flight.count == 2 and M.busy(opts))
check("no immediate replay", M.step(ctx, opts) == nil)
ctx.now = ctx.now + 1
receipt(ctx, "daler"); receipt(ctx, "pending"); receipt(ctx, "prices")
check("unrelated receipts do not confirm", M.step(ctx, opts) == nil)
cull(ctx)
local oldq = ctx.observed.bqueue.seq
ctx.observed.bqueue.seq = 1
check("herd alone cannot confirm", M.step(ctx, opts) == nil)
ctx.observed.bqueue.seq = oldq
a, status = M.step(ctx, opts)
check("one guarded buy after both receipts", a and a.kind == "buy"
  and a.cmd == "vlivestock buy lodbrok 1 2 " .. string.rep("a", 32)
  and status.phase == "await_pending")
check("buy never repeats", M.step(ctx, opts) == nil and opts.daily.spent == 20)
ctx.now = ctx.now + 1
ctx.lpending = { { bldg = "sheepfold", breed = "nordic", species = "sheep", count = 2, secs = 10800 } }
check("pending contents without receipt not confirmation", select(2, M.step(ctx, opts)).phase == "await_pending")
receipt(ctx, "pending")
check("matching pending confirms purchase", select(2, M.step(ctx, opts)).phase == "await_delivery")
ctx.now = ctx.now + 1
ctx.lpending = {}
ctx.herds.sheepfold.head = 20
ctx.herds.sheepfold.management.free = 0
ctx.herds.sheepfold._received_at = ctx.now
receipt(ctx, "pending")
check("delivery requires new herd revision too", select(2, M.step(ctx, opts)).phase == "await_delivery")
receipt(ctx, "herds")
check("delivery enters blocked cooldown", select(2, M.step(ctx, opts)).phase == "cooldown" and M.busy(opts))
opts.cooldown = 2
ctx.now = ctx.now + 2
a, status = M.step(ctx, opts)
check("cooldown completion emits no action", a == nil and status.phase == "complete" and not M.busy(opts))

expect_block("replacement off", function(_, s) s.enabled = false end)
expect_block("master off", function(c) c.master_enabled = false end)
expect_block("disconnected", function(c) c.connected = false end)
expect_block("no explicit overhead", function(_, s) s.overhead = nil end)
expect_block("missing model", function(_, s) s.models = {} end)
expect_block("no invented production", function(_, s) s.models.sheepfold.production_per_tick = nil end)
expect_block("fraction cannot exceed ten percent", function(_, s) s.max_fraction = 0.11 end)
expect_block("minimum keep", function(_, s) s.min_keep = 20 end)
expect_block("global breeder keep", function(c) c.global_keep = 20 end)
expect_block("building breeder keep", function(c) c.building_settings.sheepfold = { keep = 20 } end)
expect_block("disabled pen", function(c) c.building_settings.sheepfold = { enabled = false } end)
expect_block("unowned pen", function(c) c.buildings = {} end)
expect_block("only full pens", function(c)
  c.herds.sheepfold.head = 19; c.herds.sheepfold.management.free = 1
end)
expect_block("management mandatory", function(c) c.herds.sheepfold.management = nil end)
expect_block("auto slaughter blocked", function(c) c.herds.sheepfold.management.auto_slaughter = 1 end)
expect_block("pending list blocked", function(c)
  c.lpending = { { bldg = "sheepfold", count = 1 } }
end)
expect_block("management pending blocked", function(c) c.herds.sheepfold.management.pending = 1 end)
expect_block("malformed pending blocked", function(c) c.lpending = { {} } end)
expect_block("full queue", function(c) c.bqueue_max = 1; c.bqueue_used = 1
  c.bqueue = { { slot = 0, species = "pig", qty = 1 } } end)
expect_block("inconsistent queue", function(c) c.bqueue_used = 1 end)
expect_block("protected horses", function(c)
  c.herds.stable.management.protected = 20; c.herds.stable.management.cullable = 0
end, "stable")
expect_block("nonzero transport rate rejected", function(_, s) s.models.stable.production_per_tick = 1 end, "stable")
expect_block("no positive horse transport valuation", function(_, s) s.models.stable.production_per_tick = 1 end, "stable")
expect_block("nonzero pig direct rate rejected", function(_, s) s.models.piggery.production_per_tick = 1 end, "piggery")
expect_block("reserve", function(c) c.daler = 210 end)
expect_block("per action cost cap", function(_, s) s.max_cost = 19 end)
expect_block("daily cost cap", function(_, s) s.daily_cost = 19 end)
expect_block("daily cull cap", function(_, s) s.daily_cull = 1 end)
expect_block("unprofitable", function(c) c.prices.mutton.sell = 0 end)
expect_block("demand limits gross opportunity", function(c) c.prices.mutton.demand = 0 end)
expect_block("minimum profit", function(_, s) s.min_profit = 171 end)
expect_block("raw quality margin", function(c) c.quality_margin = 40 end)
expect_block("fractional gain must be positive", function(c)
  local o = c.lmarket[1][1]
  o.hard, o.fert, o.yield, o.vigor, o.con = 50, 50, 50, 50, 50
end)
for _, key in ipairs({ "herds", "pending", "bqueue", "daler", "prices" }) do
  expect_block("stale observation " .. key, function(c)
      c.observed[key].at = c.now - (key == "prices" and 601 or 181)
    end)
  expect_block("missing revision " .. key, function(c) c.observed[key].seq = nil end)
end
expect_block("stale individual herd", function(c) c.herds.sheepfold._received_at = c.now - 181 end)
expect_block("stale offer despite fresh market", function(c)
  c.observed.market = { at = c.now, seq = 99 }; c.lmarket[1][1]._received_at = c.now - 181
end)
expect_block("stale meat quote", function(c) c.prices.mutton.at = c.now - 601 end)
expect_block("stale output quote", function(c) c.prices.wool.at = c.now - 601 end)
for _, age in ipairs({ 299, 300, 599, 600, 601 }) do
  for _, source in ipairs({ "grid", "mutton", "wool" }) do
    local c, s = fixture()
    local row = source == "grid" and c.observed.prices or c.prices[source]
    row.at = c.now - age
    local before = copy(c)
    local plan, reason = M.propose(c, s)
    check(source .. " price age " .. age, (plan ~= nil) == (age <= 600) and equal(c, before))
    if source == "grid" and age == 601 then
      check("stale grid reports actual age and limit", reason ==
        "stale/missing prices (last full grid age 601s exceeds limit 600s)")
    end
    -- Start with a valid quote, then cross the boundary before guarded buying.
    row.at = c.now - math.min(age, 600)
    M.step(c, s); cull(c)
    row.at = c.now - age
    local action, st = M.step(c, s)
    check(source .. " buy price age " .. age, age <= 600 and action and action.kind == "buy"
      or age > 600 and action == nil and st.phase == "halted")
  end
end
for _, source in ipairs({ "grid", "mutton", "wool" }) do
  for _, invalid in ipairs({ "missing", "future", "nan", "infinite" }) do
    expect_block(source .. " " .. invalid .. " price receipt", function(c)
      local row = source == "grid" and c.observed.prices or c.prices[source]
      if invalid == "missing" then row.at = nil
      elseif invalid == "future" then row.at = c.now + 1
      elseif invalid == "nan" then row.at = 0/0
      else row.at = math.huge end
    end)
  end
end
for _, value in ipairs({ 0, -1, 1.5, math.huge, -math.huge, 0/0, "600", false }) do
  local c, s = fixture(); s.price_max_age = value
  check("invalid price_max_age " .. tostring(value), select(2, M.propose(c, s)) == "invalid setting: price_max_age")
  check("invalid price_max_age cannot execute " .. tostring(value), M.step(c, s) == nil and not M.busy(s))
end
do
  local c, s = fixture(); s.price_max_age = nil
  c.observed.prices.at = c.now - 600
  check("omitted price_max_age uses default", M.propose(c, s) ~= nil)
  s.price_max_age = 601; c.observed.prices.at = c.now - 601
  check("explicit price_max_age has no arbitrary cap", M.propose(c, s) ~= nil)
  s.price_max_age = 1; c.observed.prices.at = c.now - 2
  check("explicit positive price limit enforced", M.propose(c, s) == nil)
end
for _, source in ipairs({ "herds", "pending", "bqueue", "daler", "herd row", "offer", "production" }) do
  for _, age in ipairs({ 180, 181 }) do
    local c, s = fixture()
    if source == "herd row" then c.herds.sheepfold._received_at = c.now - age
    elseif source == "offer" then c.lmarket[1][1]._received_at = c.now - age
    elseif source == "production" then
      s.models = {}; c.production = { wool = 1 }
      c.observed.production = { at = c.now - age, seq = 1 }
    else c.observed[source].at = c.now - age end
    check(source .. " retains 180s boundary " .. age, (M.propose(c, s) ~= nil) == (age == 180))
  end
end
for _, key in ipairs({ "token", "unit_price", "available", "idx", "lin", "yield" }) do
  expect_block("malformed offer " .. key, function(c) c.lmarket[1][1][key] = "bad" end)
end
expect_block("zero unit price", function(c) c.lmarket[1][1].unit_price = 0 end)
expect_block("invalid management stats", function(c) c.herds.sheepfold.management.stats.yield = 0/0 end)

local function halt_after_cull(name, mutate)
  local c, s = fixture()
  M.step(c, s); cull(c); mutate(c, s)
  local action, st = M.step(c, s)
  check(name, action == nil and st.phase == "halted" and M.busy(s)
    and s.daily.spent == 20 and s.daily.culled == 2)
  check(name .. " never retries", M.step(c, s) == nil)
end
for _, age in ipairs({ 180, 181 }) do
  local c, s = fixture()
  local started = c.now
  M.step(c, s); cull(c); c.now = started + age
  for _, key in ipairs({ "herds", "pending", "bqueue", "daler" }) do receipt(c, key) end
  c.herds.sheepfold._received_at = c.now
  c.lmarket[1][1]._received_at = c.now
  local action, st = M.step(c, s)
  check("default destructive timeout remains 180s: " .. age,
    age == 180 and action and action.kind == "buy"
    or age == 181 and action == nil and st.reason == "replacement timeout/clock rollback")
end
expect_block("cached reconnect prices without full-grid evidence", function(c)
  c.epoch = 2; c.observed.prices = nil
end)
expect_block("partial price rows cannot replace missing full-grid receipt", function(c)
  c.observed.prices = nil; c.prices = { mutton = c.prices.mutton }
end)
halt_after_cull("changed offer price", function(c) c.lmarket[1][1].unit_price = 11 end)
halt_after_cull("changed market price", function(c) c.prices.mutton.sell = 101 end)
halt_after_cull("offer vanished", function(c) c.lmarket = {} end)
halt_after_cull("changed availability", function(c) c.lmarket[1][1].available = 4 end)
halt_after_cull("reserve changed", function(c) c.reserve = 990 end)
halt_after_cull("daily limit lowered", function(_, s) s.daily_cost = 10 end)
halt_after_cull("epoch changed", function(c) c.epoch = 2 end)
halt_after_cull("disconnect partial job", function(c) c.connected = false end)
halt_after_cull("master disabled partial job", function(c) c.master_enabled = false end)
halt_after_cull("replacement disabled partial job", function(_, s) s.enabled = false end)
halt_after_cull("unexpected herd drop", function(c)
  c.herds.sheepfold.head = 17; c.herds.sheepfold.management.free = 3
end)
halt_after_cull("unexpected pending before buy", function(c)
  c.lpending = { { bldg = "sheepfold", count = 2 } }
end)
halt_after_cull("timeout reserves exposures", function(c, s) s.timeout = 1; c.now = c.now + 2 end)

ctx, opts = fixture()
M.step(ctx, opts)
ctx.bqueue = { { slot = 1, species = "sheep", qty = 2 } }; ctx.bqueue_used = 1
receipt(ctx, "bqueue")
check("queue alone not confirmation", M.step(ctx, opts) == nil and M.status(opts).phase == "await_cull")
cull(ctx)
ctx.bqueue[1].species = "pig"
check("wrong queue species not confirmation", M.step(ctx, opts) == nil and M.status(opts).phase == "await_cull")
ctx.bqueue[1].species, ctx.bqueue[1].qty = "sheep", 1
check("insufficient queue quantity not confirmation", M.step(ctx, opts) == nil and M.status(opts).phase == "await_cull")
ctx.herds.sheepfold.management.stats.yield = 5100
ctx.bqueue[1].qty = 2
check("post-cull stats drift halts", select(2, M.step(ctx, opts)).phase == "halted")

ctx, opts = fixture()
ctx.bqueue = { { slot = 1, species = "sheep", qty = 2 } }; ctx.bqueue_used = 1
M.step(ctx, opts); cull(ctx)
check("existing queue slot cannot confirm", M.step(ctx, opts) == nil and M.status(opts).phase == "await_cull")

ctx, opts = fixture()
M.step(ctx, opts); cull(ctx); M.step(ctx, opts)
ctx.lpending = { { bldg = "sheepfold", species = "sheep", breed = "other", count = 2 } }
receipt(ctx, "pending")
check("wrong pending breed halts", select(2, M.step(ctx, opts)).phase == "halted")

for _, phase in ipairs({ "await_cull", "await_pending", "await_delivery", "cooldown" }) do
  ctx, opts = fixture()
  M.step(ctx, opts)
  -- A persisted marker at every phase is unresolved without its local job.
  local saved = copy(opts); saved.in_flight.phase = phase
  local reloaded = dofile("3scapes/guild_viking/herd_replace.lua")
  local action, st = reloaded.step(ctx, saved)
  check("reload " .. phase .. " disables and halts", action == nil and st.phase == "halted"
    and saved.enabled == false and reloaded.busy(saved) and saved.daily.spent == 20)
  reloaded.reset(saved)
  check("explicit reset never replays " .. phase, not reloaded.busy(saved)
    and not saved.enabled and reloaded.step(ctx, saved) == nil and saved.daily.culled == 2)
end
ctx, opts = fixture()
M.step(ctx, opts)
M.cancel(opts, "user cancelled")
check("cancel retains marker and budget", M.busy(opts) and M.status(opts).reason == "user cancelled"
  and opts.daily.spent == 20)
opts.enabled = true
check("toggle on cannot resume cancelled job", M.step(ctx, opts) == nil and M.busy(opts))
M.reset(opts); opts.enabled = true; opts.daily_cost = 20
check("acknowledgement does not refund daily budget", M.propose(ctx, opts) == nil)
opts.daily.date = "2000-01-01"
local old = copy(opts)
check("pure next-day preview", M.propose(ctx, opts) ~= nil and equal(opts, old))
M.step(ctx, opts)
check("next-day exposure reset persists", opts.daily.date == os.date("!%Y-%m-%d", ctx.now)
  and opts.daily.spent == 20 and opts.daily.culled == 2)
opts.daily.date = "2000-01-01"
M.cancel(opts)
M.step(ctx, opts)
check("in-flight date never rolls", opts.daily.date == "2000-01-01" and opts.daily.spent == 20)

ctx, opts = fixture()
local extra = copy(ctx.lmarket[1][1]); extra.lin = 2
ctx.lmarket[2] = { extra }
check("stable lineage tie break", M.propose(ctx, opts).offer.lin == 1)
extra.unit_price = 9
check("best conservative profit first", M.propose(ctx, opts).offer.lin == 2)
ctx, opts = fixture("stable")
check("explicit zero horse production valid without transport value", M.propose(ctx, opts) ~= nil)
expect_block("malformed context models", function(c) c.models = 42 end)
expect_block("malformed saved models", function(_, s) s.models = false end)
expect_block("malformed ownership", function(c) c.buildings = true end)
expect_block("malformed building keep", function(c) c.building_settings.sheepfold = { keep = false } end)
expect_block("malformed price", function(c) c.prices.mutton.supply = "bad" end)
expect_block("malformed daily exposure", function(_, s) s.daily = { date = "2023-11-14", spent = -1, culled = 0 } end)
halt_after_cull("changed offer token", function(c) c.lmarket[1][1].token = string.rep("b", 32) end)
halt_after_cull("changed offer stats", function(c) c.lmarket[1][1].yield = 91 end)
halt_after_cull("changed offer breed", function(c) c.lmarket[1][1].breed = "other" end)
halt_after_cull("stale offer before buy", function(c) c.lmarket[1][1]._received_at = c.now - 181 end)
halt_after_cull("disabled pen before buy", function(c) c.building_settings.sheepfold = { enabled = false } end)
for _, phase in ipairs({ "await_pending", "await_delivery" }) do
  ctx, opts = fixture()
  M.step(ctx, opts); cull(ctx); M.step(ctx, opts)
  if phase == "await_delivery" then
    ctx.lpending = { { bldg = "sheepfold", species = "sheep", breed = "nordic", count = 2, secs = 10800 } }
    receipt(ctx, "pending"); M.step(ctx, opts)
  end
  opts.timeout = 2
  ctx.now = ctx.now + (phase == "await_delivery" and 10981 or 3)
  check(phase .. " timeout halts without refund", select(2, M.step(ctx, opts)).phase == "halted"
    and opts.daily.spent == 20 and M.busy(opts))
end
ctx, opts = fixture()
M.step(ctx, opts); cull(ctx); M.step(ctx, opts)
ctx.herds.sheepfold.head, ctx.herds.sheepfold.management.free = 20, 0
receipt(ctx, "herds"); receipt(ctx, "pending")
check("cannot skip matching purchase pending", select(2, M.step(ctx, opts)).phase == "await_pending")
ctx, opts = fixture()
M.step(ctx, opts); cull(ctx); M.step(ctx, opts)
ctx.building_settings.sheepfold = { enabled = false }
check("pen disabled while awaiting purchase halts", select(2, M.step(ctx, opts)).phase == "halted")
ctx, opts = fixture()
opts.in_flight = "corrupt saved marker"
check("malformed restart marker fails closed", select(2, M.step(ctx, opts)).phase == "halted"
  and opts.enabled == false and M.busy(opts))
ctx, opts = fixture()
ctx.lmarket[1][1].available = 1
opts.gap_ticks = 0
check("count respects exact availability", M.propose(ctx, opts).count == 1)
ctx.herds.sheepfold.management.cullable = 0
check("zero cullable blocks", M.propose(ctx, opts) == nil)
for _, value in ipairs({ false, true, 42, "corrupt" }) do
  ctx = fixture()
  local ok, action, st = pcall(M.step, ctx, value)
  check("malformed options fail closed " .. tostring(value), ok and action == nil and st.phase == "halted")
  local proposed, plan = pcall(M.propose, ctx, value)
  check("malformed options preview is safe " .. tostring(value), proposed and plan == nil)
  check("malformed options recovery is safe " .. tostring(value), pcall(M.recover, value))
end
for _, key in ipairs({ "timeout", "cooldown" }) do
  expect_block("false saved " .. key, function(_, s) s[key] = false end)
end
for _, date in ipairs({ "", "0", "2023-2-01", "2023-02-29", "2023-04-31", "0000-01-01", "2023-00-01" }) do
  expect_block("invalid budget date " .. date, function(_, s)
    s.daily = { date = date, spent = s.daily_cost, culled = s.daily_cull }
  end)
end
ctx, opts = fixture()
opts.daily = { date = "2020-02-29", spent = opts.daily_cost, culled = opts.daily_cull }
check("valid leap-day budget rolls forward", M.propose(ctx, opts) ~= nil)
expect_block("duplicate identical offer blocks before cull", function(c)
  c.lmarket[2] = { copy(c.lmarket[1][1]) }
end)
expect_block("duplicate conflicting offer blocks before cull", function(c)
  local duplicate = copy(c.lmarket[1][1]); duplicate.token = string.rep("b", 32)
  c.lmarket[2] = { duplicate }
end)
ctx, opts = fixture()
M.step(ctx, opts); cull(ctx)
ctx.bqueue[1].qty = 24
check("meat yield larger than heads confirms cull", M.step(ctx, opts).kind == "buy"
  and M.status(opts).phase == "await_pending")
for _, value in ipairs({ false, true, 42, "corrupt" }) do
  ctx, opts = fixture()
  opts.in_flight = value
  check("malformed marker status is halted " .. tostring(value), M.status(opts).phase == "halted")
  local action, st = M.step(ctx, opts)
  check("malformed marker reload blocks " .. tostring(value), action == nil
    and st.phase == "halted" and M.busy(opts) and opts.enabled == false)
end
for _, mutation in ipairs({
  function(s) s.in_flight = nil end,
  function(s) s.in_flight.phase = "cooldown" end,
  function(s) s.in_flight = false end,
  function(s) s.daily = nil end,
  function(s) s.daily.spent = 0 end,
  function(s) s.daily.culled = 0 end,
  function(s) s.daily.date = "2000-01-01" end,
}) do
  ctx, opts = fixture()
  M.step(ctx, opts); cull(ctx); mutation(opts)
  local action, st = M.step(ctx, opts)
  check("changed live bookkeeping halts", action == nil and st.phase == "halted"
    and M.busy(opts) and opts.daily.spent == 20 and opts.daily.culled == 2)
  M.reset(opts); opts.enabled = true; opts.daily_cost = 20
  check("changed bookkeeping cannot refund exposure", M.propose(ctx, opts) == nil)
end
ctx, opts = fixture()
M.step(ctx, opts); cull(ctx); opts.daily.spent = 100
M.step(ctx, opts)
check("bookkeeping halt retains higher exposure", opts.daily.spent == 100)
ctx, opts = fixture()
opts.models, opts.overhead = {}, nil
ctx.production = { wool = 1 }
ctx.observed.production = { at = ctx.now, seq = 1 }
before_ctx, before_opts = copy(ctx), copy(opts)
p = M.preview(ctx, opts)
check("automatic fresh whole-herd gross preview", p and p.forecast.net_low == 80
  and p.forecast_input.scaled_share == nil and p.forecast.estimate == nil
  and p.model_source == "fresh observed wool")
check("preview does not fill execution authorization", equal(ctx, before_ctx)
  and equal(opts, before_opts) and M.propose(ctx, opts) == nil and M.step(ctx, opts) == nil)
opts.models.sheepfold = { overhead = 0 }
check("per-model overhead is not replace overhead acknowledgement", M.propose(ctx, opts) == nil)
opts.overhead = 0
check("acknowledged observed execution model valid", M.propose(ctx, opts) ~= nil)
for _, age in ipairs({ 180, 181, -1 }) do
  ctx.observed.production.at = ctx.now - age
  check("production receipt age " .. age, (M.preview(ctx, opts) ~= nil) == (age == 180))
end
ctx.observed.production = nil
ctx.epoch = ctx.epoch + 1
check("connection reset cannot use cached production", M.preview(ctx, opts) == nil)
opts.models.sheepfold.production_per_tick = 1
check("manual output remains valid without production receipt", M.propose(ctx, opts) ~= nil)
opts.models.sheepfold = { scaled_share = 1 }
ctx.observed.production = { at = ctx.now, seq = 1 }
ctx.production.wool = 10
p = M.preview(ctx, opts)
check("negative gross preview bypasses only profit gate", p and p.forecast.net_low < 0
  and M.propose(ctx, opts) == nil)
ctx.production.wool = nil
check("omitted good in fresh full snapshot is known zero", M.model(ctx, opts, "sheepfold").production_per_tick == 0
  and M.preview(ctx, opts) ~= nil)
ctx.production = { wool = 3, eggs = 7, milk = 11 }
for b, amount in pairs({ sheepfold = 3, henhouse = 7, byre = 11 }) do
  local model = M.model(ctx, opts, b)
  check(b .. " uses unique whole-herd producer", model and model.production_per_tick == amount)
end
for _, invalid in ipairs({ -1, "1", math.huge, 0/0 }) do
  ctx.production.wool = invalid
  check("invalid observed production rejected", M.preview(ctx, opts) == nil)
end
ctx.production.wool = 0
check("observed zero accepted", M.preview(ctx, opts) ~= nil)
for _, b in ipairs({ "stable", "piggery" }) do
  ctx, opts = fixture(b); opts.models = {}
  p = M.preview(ctx, opts)
  check(b .. " known direct zero without production frame", p and p.forecast_input.production_per_tick == 0)
end
ctx, opts = fixture()
ctx.herds.sheepfold.management = nil
ctx.observed = {}
local _, reason = M.preview(ctx, opts)
check("known legacy blocker precedes generic stale", reason:find("missing server management metadata", 1, true))
-- Real server deliveries take three hours; no market or wallet traffic is needed.
local function delivery()
  local c, s = fixture()
  M.step(c, s); cull(c); M.step(c, s)
  c.now = c.now + 1
  c.lpending = { { bldg = "sheepfold", species = "sheep", breed = "nordic", count = 2, secs = 10800 } }
  receipt(c, "pending")
  local action, st = M.step(c, s)
  check("three-hour pending accepted", action == nil and st.phase == "await_delivery")
  return c, s
end
local function delivered(c)
  c.lpending = {}
  c.herds.sheepfold.head = 20
  c.herds.sheepfold.management.free = 0
  c.herds.sheepfold._received_at = c.now
  receipt(c, "herds"); receipt(c, "pending")
end
ctx, opts = delivery()
local started = ctx.now
ctx.now = started + 1000
check("expired unchanged prices and wallet allow passive wait", select(2, M.step(ctx, opts)).phase == "await_delivery")
ctx.prices, ctx.daler, ctx.bqueue, ctx.lmarket = nil, nil, nil, nil
ctx.now = started + 10800
delivered(ctx)
local pending_revision = copy(ctx.observed.pending)
ctx.observed.pending.at = started
check("stale pending cannot complete", select(2, M.step(ctx, opts)).phase == "await_delivery")
ctx.observed.pending = pending_revision
ctx.herds.sheepfold._received_at = started
check("fresh aggregate cannot replace stale herd row", select(2, M.step(ctx, opts)).phase == "await_delivery")
ctx.herds.sheepfold._received_at = ctx.now
check("fresh actual delivery needs no unrelated data", select(2, M.step(ctx, opts)).phase == "cooldown")
ctx.observed, ctx.herds, ctx.lpending = nil, nil, nil
ctx.now = ctx.now + 180
local action, st = M.step(ctx, opts)
check("passive cooldown with expired data sends nothing", action == nil and st.phase == "complete")

for _, missing in ipairs({ "herds", "lpending", "observed" }) do
  ctx, opts = delivery()
  ctx.now = ctx.now + 1000
  ctx[missing] = nil
  check("partial delivery data waits: " .. missing, select(2, M.step(ctx, opts)).phase == "await_delivery")
  ctx.now = ctx.now + 10000
  check("partial delivery data reaches deadline: " .. missing, select(2, M.step(ctx, opts)).phase == "halted"
    and opts.daily.spent == 20 and opts.daily.culled == 2)
end
ctx, opts = delivery()
started = ctx.now
ctx.now = started + 10000
ctx.lpending[1].secs = 10800
receipt(ctx, "pending")
check("repeated countdown does not finish delivery", select(2, M.step(ctx, opts)).phase == "await_delivery")
opts.timeout = 86400
ctx.now = started + 10980
check("immutable deadline boundary still waits", select(2, M.step(ctx, opts)).phase == "await_delivery")
ctx.now = ctx.now + 1
delivered(ctx)
check("countdown and timeout edits cannot extend deadline", select(2, M.step(ctx, opts)).phase == "halted"
  and opts.daily.spent == 20 and M.step(ctx, opts) == nil)

for _, invalid in ipairs({ -1, 86401, math.huge, 0/0, "10800", false, 1.5 }) do
  ctx, opts = fixture()
  M.step(ctx, opts); cull(ctx); M.step(ctx, opts)
  ctx.lpending = { { bldg = "sheepfold", species = "sheep", breed = "nordic", count = 2, secs = invalid } }
  receipt(ctx, "pending")
  check("invalid delivery countdown rejected " .. tostring(invalid), select(2, M.step(ctx, opts)).phase == "halted")
end
ctx, opts = fixture()
M.step(ctx, opts); cull(ctx); M.step(ctx, opts)
ctx.lpending = { { bldg = "sheepfold", species = "sheep", breed = "nordic", count = 2 } }
receipt(ctx, "pending")
check("missing delivery countdown rejected", select(2, M.step(ctx, opts)).phase == "halted")

for _, phase in ipairs({ "await_delivery", "cooldown" }) do
  for name, mutate in pairs({
    disconnect = function(c) c.connected = false end,
    epoch = function(c) c.epoch = c.epoch + 1 end,
    master = function(c) c.master_enabled = false end,
    disabled = function(_, s) s.enabled = false end,
    limits = function(_, s) s.timeout = false end,
    models = function(_, s) s.models = false end,
    bookkeeping = function(_, s) s.daily.spent = 0 end,
    rollback = function(c) c.now = c.now - 1 end,
  }) do
    ctx, opts = delivery()
    if phase == "cooldown" then delivered(ctx); M.step(ctx, opts) end
    ctx.now = ctx.now + 10; M.step(ctx, opts)
    mutate(ctx, opts)
    action, st = M.step(ctx, opts)
    check(phase .. " safety gate " .. name, action == nil and st.phase == "halted"
      and opts.daily.spent == 20 and opts.daily.culled == 2 and M.step(ctx, opts) == nil)
  end
end
for name, mutate in pairs({
  head = function(c) c.herds.sheepfold.head = 19; c.herds.sheepfold.management.free = 1 end,
  cap = function(c) c.herds.sheepfold.management.cap = 21; c.herds.sheepfold.management.free = 1 end,
  management = function(c) c.herds.sheepfold.management = nil end,
  pending = function(c) c.herds.sheepfold.management.pending = 2 end,
  auto_slaughter = function(c) c.herds.sheepfold.management.auto_slaughter = 1 end,
}) do
  ctx, opts = delivery()
  ctx.now = ctx.now + 10800; delivered(ctx); mutate(ctx)
  check("invalid actual delivery cannot complete: " .. name, select(2, M.step(ctx, opts)).phase == "await_delivery")
end
halt_after_cull("multiple matching new slots ambiguous", function(c)
  local q = copy(c.bqueue[1]); q.slot = 2
  c.bqueue[2], c.bqueue_used = q, 2
end)
halt_after_cull("multiple mixed new slots ambiguous", function(c)
  c.bqueue[2] = { slot = 2, species = "pig", meat = "pork", qty = 10 }
  c.bqueue_used = 2
end)
for _, meat in ipairs({ "beef", "" }) do
  ctx, opts = fixture(); M.step(ctx, opts); cull(ctx)
  ctx.bqueue[1].meat = meat
  check("wrong meat cannot confirm " .. meat, M.step(ctx, opts) == nil and M.status(opts).phase == "await_cull")
end
ctx, opts = fixture(); M.step(ctx, opts); cull(ctx)
ctx.bqueue[1].meat = nil
check("missing meat cannot confirm", M.step(ctx, opts) == nil and M.status(opts).phase == "await_cull")
ctx, opts = fixture(); opts.models = {}
ctx.production = {}; ctx.observed.production = { at = ctx.now, seq = 1 }
check("empty fresh production snapshot proves zero", M.model(ctx, opts, "sheepfold").production_per_tick == 0)
ctx.production = { milk = "invalid" }
check("invalid full snapshot does not prove omitted zero", M.model(ctx, opts, "sheepfold") == nil)
ctx.production = nil
check("missing snapshot does not prove zero", M.model(ctx, opts, "sheepfold") == nil)
ctx.production = {}; ctx.observed.production.at = ctx.now - 181
check("stale empty snapshot does not prove zero", M.model(ctx, opts, "sheepfold") == nil)
print(string.format("%d checks, %d failures", checks, failures))
if failures > 0 then os.exit(1) end
