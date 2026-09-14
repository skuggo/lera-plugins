-- Replacement is opt-in and never sends or saves. opts is ah.replace itself.
-- Integration: recover(opts) at load; block normal autoherd with busy(opts);
-- call step(ctx, opts), SAVE opts successfully, then send the returned action.
-- A failed save/send must cancel, not replay. reset is explicit acknowledgement
-- of unresolved server state; it disables replacement and never restores a job.
-- Context records use the parsed livestock shapes. A managed herd proves pen
-- ownership (optional ctx.buildings can further restrict it). Receipt timestamps
-- must be per row; observed.{herds,pending,bqueue,daler,prices} are {at,seq}.
-- Models describe THIS herd's production, not a per-animal invented rate.
-- opts.daily = {date = UTC YYYY-MM-DD, spent, culled}; spent includes reserved
-- purchase exposure from the initial cull, not only confirmed purchases.
-- Optional timeout/cooldown are seconds, each defaulting to max_age. Neither
-- converts forecast ticks to wall time. A cooldown still blocks normal autoherd.
local forecast = require("herd_forecast")
local M = {}
M.DEFAULTS = { enabled = false, max_age = 180, price_max_age = 600, max_cull = 2,
  max_fraction = 0.1, min_keep = 4, max_cost = 500, daily_cost = 2000,
  daily_cull = 10, min_profit = 0, horizon_ticks = 8, gap_ticks = 1,
  overhead = nil, models = {} }
local species = { sheepfold = "sheep", byre = "cow", henhouse = "chicken",
  piggery = "pig", stable = "horse" }
local meats = { sheepfold = "mutton", byre = "beef", henhouse = "poultry",
  piggery = "pork", stable = "horsemeat" }
local outputs = { sheepfold = "wool", byre = "milk", henhouse = "eggs" }
local buildings = { "byre", "henhouse", "piggery", "sheepfold", "stable" }
local stats = { "hard", "fert", "yield", "vigor", "con" }
local tokens = { "lodbrok", "eiriksson", "ui_imair", "rurikid", "harfagre",
  "yngling", "skallagrim", "stenkil", "sverker", "eric", "munso", "skjoldung", "sigurdsson" }
local MAX_DELIVERY_SECS = 86400
local jobs = setmetatable({}, { __mode = "k" })
local function copy(t)
  if type(t) ~= "table" then return t end
  local r = {}; for k, v in pairs(t) do r[k] = copy(v) end; return r
end
local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not same(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end
local function num(n, lo, hi, integer)
  return type(n) == "number" and n == n and n < math.huge and n > -math.huge
    and (lo == nil or n >= lo) and (hi == nil or n <= hi)
    and (not integer or n % 1 == 0)
end
function M.defaults() return copy(M.DEFAULTS) end
-- Pure merged view; never persist defaults over explicit user values.
function M.settings(opts)
  local r = M.defaults()
  if opts ~= nil and type(opts) ~= "table" then
    r.enabled = false
    return r
  end
  for k, v in pairs(opts or {}) do r[k] = copy(v) end
  return r
end
function M.busy(opts) return type(opts) == "table" and opts.in_flight ~= nil end
function M.status(opts)
  local marker = type(opts) == "table" and opts.in_flight
  if M.busy(opts) then
    return type(marker) == "table" and copy(marker)
      or { phase = "halted", reason = "invalid replacement marker" }
  end
  return { phase = "idle" }
end
function M.cancel(opts, reason)
  opts.enabled = false
  if not M.busy(opts) then return M.status(opts) end
  if type(opts.in_flight) ~= "table" then opts.in_flight = {} end
  opts.in_flight.phase = "halted"
  opts.in_flight.reason = reason or "cancelled; explicit reset required"
  jobs[opts] = nil
  return M.status(opts)
end
function M.recover(opts)
  if M.busy(opts) and not jobs[opts] then
    opts.enabled = false
    if type(opts.in_flight) ~= "table" or opts.in_flight.phase ~= "halted" then
      M.cancel(opts, "unresolved persisted replacement; explicit reset required")
    end
  end
  return M.status(opts)
end
function M.reset(opts)
  jobs[opts] = nil
  opts.in_flight = nil
  opts.enabled = false
  -- Budget exposures survive acknowledgement, including uncertain commands.
  return M.status(opts)
end
local function fresh(at, ctx, s, limit)
  return num(at, 0) and at <= ctx.now and ctx.now - at <= (limit or s.max_age)
end
local function revision(ctx, key, s)
  local o = type(ctx.observed) == "table" and ctx.observed[key]
  return type(o) == "table"
      and fresh(o.at, ctx, s, key == "prices" and s.price_max_age or nil)
      and num(o.seq, 0, nil, true)
end
-- Explicit manual values take precedence; never persist inferred production/share.
function M.model(ctx, opts, b)
  local s = M.settings(opts)
  if type(ctx) ~= "table" or not num(ctx.now, 0) or not num(s.max_age, 1)
      or type(s.models) ~= "table" or (ctx.models ~= nil and type(ctx.models) ~= "table") then
    return nil, "invalid production model context"
  end
  local configured = (ctx.models or s.models)[b]
  if configured ~= nil and type(configured) ~= "table" then return nil, "invalid model " .. b end
  local model = copy(configured or {})
  if model.production_per_tick ~= nil then return model end
  local good = outputs[b]
  if not good then
    model.production_per_tick, model.source = 0, "known zero direct output"
  elseif revision(ctx, "production", s) and type(ctx.production) == "table" then
    -- A valid full snapshot omits goods with zero production.
    for key, value in pairs(ctx.production) do
      if type(key) ~= "string" or not num(value, 0) then
        return nil, "invalid production snapshot"
      end
    end
    model.production_per_tick, model.source = ctx.production[good] or 0, "fresh observed " .. good
  else
    return nil, "stale/missing production receipt or " .. good .. " output for " .. b
  end
  return model
end
local function later(ctx, key, baseline, sent_at, s)
  return revision(ctx, key, s) and ctx.observed[key].seq > baseline[key].seq
    and ctx.observed[key].at >= sent_at
end
local function day(ctx)
  local ok, value = pcall(os.date, "!%Y-%m-%d", ctx.now)
  return ok and value or nil
end
local function valid_date(value)
  if type(value) ~= "string" then return false end
  local y, m, d = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  if not y or y < 1 or m < 1 or m > 12 then return false end
  local days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  if y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0) then days[2] = 29 end
  return d >= 1 and d <= days[m]
end
local function budget(ctx, opts)
  local d = day(ctx)
  if not d then return nil end
  local b = opts.daily
  if b == nil then return { date = d, spent = 0, culled = 0 } end
  if type(b) ~= "table" or not valid_date(b.date)
      or not num(b.spent, 0) or not num(b.culled, 0, nil, true) then return nil end
  -- Never roll a date backwards or reset exposures across an in-flight job.
  if d > b.date and not M.busy(opts) then return { date = d, spent = 0, culled = 0 } end
  return copy(b)
end
local function common(ctx, s, passive)
  if type(ctx) ~= "table" or not num(ctx.now, 0) or not num(ctx.epoch, 0, nil, true) then
    return "invalid clock/epoch"
  end
  if ctx.connected ~= true then return "disconnected" end
  if ctx.master_enabled ~= true or s.enabled ~= true then return "disabled" end
  for _, k in ipairs({ "max_age", "max_cull", "min_keep", "max_cost", "daily_cost",
      "daily_cull", "horizon_ticks", "gap_ticks" }) do
    if not num(s[k], 0, nil, true) then return "invalid setting: " .. k end
  end
  if not num(s.price_max_age, 1, nil, true) then return "invalid setting: price_max_age" end
  if s.max_age == 0 or s.horizon_ticks == 0 or s.gap_ticks > s.horizon_ticks
      or not num(s.max_fraction, 0, 0.1) or not num(s.min_profit)
      or not num(s.timeout == nil and s.max_age or s.timeout, 1)
      or not num(s.cooldown == nil and s.max_age or s.cooldown, 0) then
    return "invalid replacement limits"
  end
  if type(s.models) ~= "table" then return "invalid models" end
  if passive then return end
  if not num(ctx.daler, 0) or not num(ctx.reserve, 0)
      or not num(ctx.global_keep, 0, nil, true)
      or not num(ctx.quality_margin == nil and 5 or ctx.quality_margin, 0) then
    return "invalid wallet/keep/margin"
  end
  for _, k in ipairs({ "herds", "lmarket", "lpending", "bqueue", "prices",
      "weights", "building_settings" }) do
    if type(ctx[k]) ~= "table" then return "missing " .. k end
  end
  -- A received legacy herd cannot support protected replacement even if other
  -- receipts are missing. Say that first instead of asking for endless refreshes.
  for b, h in pairs(ctx.herds) do
    if species[b] and type(h) == "table" and h.management == nil
        and h._received_at ~= nil then
      return "missing server management metadata for " .. b .. "; protected replacement unavailable"
    end
  end
  for _, k in ipairs({ "herds", "pending", "bqueue", "daler", "prices" }) do
    if not revision(ctx, k, s) then
      if k == "prices" then
        local o = type(ctx.observed) == "table" and ctx.observed.prices
        local detail = "missing/invalid receipt"
        if type(o) == "table" and num(o.at, 0) and num(o.seq, 0, nil, true) then
          detail = o.at > ctx.now and "future receipt"
            or ("age " .. tostring(ctx.now - o.at) .. "s exceeds limit " .. tostring(s.price_max_age) .. "s")
        end
        return "stale/missing prices (last full grid " .. detail .. ")"
      end
      return "stale/missing " .. k
    end
  end
  if (ctx.buildings ~= nil and type(ctx.buildings) ~= "table")
      or (ctx.models ~= nil and type(ctx.models) ~= "table") or type(s.models) ~= "table" then
    return "invalid ownership/models"
  end
  local total = 0
  for _, k in ipairs(stats) do
    if not num(ctx.weights[k], 0) then return "invalid weights" end
    total = total + ctx.weights[k]
  end
  if not num(total, 0) or total == 0 then return "invalid weights" end
  if not num(ctx.bqueue_used, 0, nil, true) or not num(ctx.bqueue_max, 1, nil, true)
      or ctx.bqueue_used > ctx.bqueue_max then return "invalid bqueue" end
end
local function pending(ctx, b)
  if type(ctx.lpending) ~= "table" then return nil end
  local n = 0
  for _, p in pairs(ctx.lpending) do
    if type(p) ~= "table" or type(p.bldg) ~= "string" or not num(p.count, 1, nil, true) then
      return nil
    end
    if p.bldg == b then n = n + p.count end
  end
  return n
end
local function pen(ctx, b, s)
  if type(ctx.herds) ~= "table" or type(ctx.building_settings) ~= "table"
      or not num(ctx.global_keep, 0, nil, true)
      or (ctx.buildings ~= nil and type(ctx.buildings) ~= "table") then return nil, nil, "invalid pen context" end
  local h, bc = ctx.herds[b], ctx.building_settings[b]
  if bc == nil then bc = {} end
  if type(bc) ~= "table" or (bc.enabled ~= nil and bc.enabled ~= true) then return nil, nil, "disabled/invalid pen settings" end
  if ctx.buildings and (not num(ctx.buildings[b], 1)) then return nil, nil, "unowned pen" end
  if type(h) ~= "table" or not fresh(h._received_at, ctx, s)
      or not num(h.head, 1, nil, true) then return nil, nil, "stale/invalid herd head or receipt" end
  local g = h.management
  if type(g) ~= "table" or type(g.stats) ~= "table" then return nil, nil, "missing/invalid server management metadata" end
  for _, k in ipairs({ "cap", "pending", "free", "protected", "cullable" }) do
    if not num(g[k], 0, nil, true) then return nil, nil, "invalid management " .. k end
  end
  if h.head > g.cap or g.protected > h.head or g.cullable > h.head - g.protected
      or g.free ~= math.max(0, g.cap - h.head - g.pending) then
    return nil, nil, "inconsistent management capacity/protected/cullable counts"
  end
  if g.auto_slaughter ~= 0 then
    return nil, nil, "server auto_slaughter must be zero (actual "
      .. (num(g.auto_slaughter) and tostring(g.auto_slaughter) or "invalid/missing") .. ")"
  end
  for _, k in ipairs(stats) do
    if not num(g.stats[k], 0, 10000, true) then return nil, nil, "invalid management stats" end
  end
  if bc.keep ~= nil and not num(bc.keep, 0, nil, true) then return nil, nil, "invalid pen keep" end
  return h, math.max(ctx.global_keep, bc.keep or 0, s.min_keep, g.protected)
end
local offer_keys = { "lin", "idx", "species", "breed", "count", "price", "unit_price",
  "available", "token", "hard", "fert", "yield", "vigor", "con", "trait" }
local function fingerprint(o)
  local r = {}; for _, k in ipairs(offer_keys) do r[k] = o[k] end; return r
end
local function offer_ok(o, ctx, s, b)
  if type(o) ~= "table" then return false, "invalid offer" end
  if o.offer_valid == false then return false, "invalid offer (offer_valid=false)" end
  if not fresh(o._received_at, ctx, s) then return false, "stale/missing offer receipt" end
  if not num(o.lin, 1, #tokens, true) or not num(o.idx, 0, nil, true)
      or o.species ~= species[b] or type(o.breed) ~= "string" or o.breed == ""
      or not num(o.count, 1, nil, true) or not num(o.unit_price, 1, nil, true) then
    return false, "invalid offer identity/species/count/price"
  end
  if not num(o.available, 1, o.count, true) or type(o.token) ~= "string"
      or #o.token ~= 32 or not o.token:match("^%x+$") then return false, "missing/invalid protected offer metadata (available/token)" end
  for _, k in ipairs(stats) do if not num(o[k], 0, 100, true) then return false, "invalid offer stats" end end
  return true
end
local function quote(ctx, good, s)
  local q = ctx.prices[good]
  if type(q) ~= "table" or not fresh(q.at, ctx, s, s.price_max_age)
      or not num(q.sell, 0) or not num(q.demand, 0)
      or (q.buy ~= nil and not num(q.buy, 0))
      or (q.supply ~= nil and not num(q.supply, 0)) then return nil end
  return { sell = q.sell, demand = q.demand, buy = q.buy, supply = q.supply }
end
local function queue_slots(ctx)
  local r, n = {}, 0
  for _, q in pairs(ctx.bqueue) do
    if type(q) ~= "table" or not num(q.slot, 0, nil, true) or r[q.slot]
        or type(q.species) ~= "string" or not num(q.qty, 1, nil, true) then return nil end
    r[q.slot], n = true, n + 1
  end
  if n ~= ctx.bqueue_used then return nil end
  return r
end
local function candidate(ctx, s, b, o, bgt, preview)
  local h, keep, reason = pen(ctx, b, s)
  if not h then return nil, reason, 1 end
  if h.head ~= h.management.cap then
    return nil, string.format("pen not full: head %d/cap %d", h.head, h.management.cap), 2
  end
  if h.management.pending ~= 0 or pending(ctx, b) ~= 0 then return nil, "pending livestock or invalid pending snapshot", 3 end
  if o == nil then return nil, "no " .. species[b] .. " offers", 4 end
  local ok, rejected = offer_ok(o, ctx, s, b)
  if not ok then return nil, rejected, 5 end
  local n = math.min(s.max_cull, math.floor(h.head * s.max_fraction), o.available,
    h.head - keep, h.management.cullable)
  if n < 1 then
    return nil, string.format("no cull allowance: max_cull %d, max_fraction %g (floor %d), keep %d, protected %d, cullable %d",
      s.max_cull, s.max_fraction, math.floor(h.head * s.max_fraction), keep,
      h.management.protected, h.management.cullable), 6
  end
  local cost = n * o.unit_price
  if not num(cost, 0) then return nil, "invalid purchase cost", 7 end
  if cost > ctx.daler - ctx.reserve then
    return nil, string.format("cost %g exceeds wallet %g minus reserve %g", cost, ctx.daler, ctx.reserve), 7
  end
  if cost > s.max_cost then return nil, string.format("cost %g exceeds max_cost %g", cost, s.max_cost), 7 end
  if cost + bgt.spent > s.daily_cost then return nil, string.format("cost %g + spent %g exceeds daily_cost %g", cost, bgt.spent, s.daily_cost), 7 end
  if n + bgt.culled > s.daily_cull then return nil, "daily_cull budget exhausted", 7 end
  local gain, raw, after = 0, 0, {}
  for _, k in ipairs(stats) do
    local before = h.management.stats[k]
    -- Ignore any improvement from selecting the worst: remove average animals.
    after[k] = math.floor((before * (h.head - n) + o[k] * 100 * n) / h.head)
    raw = raw + (o[k] - before / 100) * ctx.weights[k]
    gain = gain + (after[k] - before) / 100 * ctx.weights[k]
  end
  if not num(gain, 0) or gain <= 0 then return nil, "no positive valid herd quality gain", 8 end
  if raw <= (ctx.quality_margin or 5) then
    return nil, string.format("raw quality margin %g <= required %g", raw, ctx.quality_margin or 5), 8
  end
  local model, missing = M.model(ctx, s, b)
  if type(model) ~= "table" then return nil, missing, 9 end
  if not outputs[b] and model.production_per_tick ~= 0 then return nil, "invalid nonzero direct production model", 9 end
  local meat = quote(ctx, meats[b], s)
  local output = outputs[b] and quote(ctx, outputs[b], s)
  if not meat then return nil, "missing/stale/invalid " .. meats[b] .. " sell/demand price", 10 end
  if model.production_per_tick ~= 0 and not output then return nil, "missing/stale/invalid " .. tostring(outputs[b]) .. " sell/demand price", 10 end
  -- Gross preview is not an execution authorization, even with enabled saved.
  local overhead = preview and 0 or s.overhead
  if not num(overhead, 0) then return nil, "missing/invalid overhead assumption", 11 end
  local input = { purchase_cost = cost, head = h.head, cull_count = n,
    yield_before = h.management.stats.yield / 100, yield_after = after.yield / 100,
    production_per_tick = model.production_per_tick, scaled_share = model.scaled_share,
    meat_qty = n, meat_unit_price = meat.sell, meat_demand = meat.demand,
    output_unit_price = output and output.sell, output_demand = output and output.demand,
    horizon_ticks = s.horizon_ticks, gap_ticks = s.gap_ticks, overhead = overhead }
  local f = forecast.evaluate(input)
  if not f.known then return nil, "unknown forecast: " .. tostring(f.reasons[1] or "invalid result"), 12 end
  if not preview and f.net_low < s.min_profit then return nil, "forecast below min_profit", 13 end
  return { building = b, species = species[b], count = n, head = h.head,
    cost = cost, gain = gain, raw_margin = raw, after_stats = after,
    before_stats = copy(h.management.stats), offer = fingerprint(o),
    prices = { meat = meat, output = output }, forecast = f, forecast_input = input,
    model_source = model.source or "manual whole-herd output",
        why = "lower-bound gross opportunity under assumptions; not guaranteed profit: " .. tostring(f.net_low),
    slaughter_cmd = string.format("vlivestock slaughter %s %d worst", b, n),
    buy_cmd = string.format("vlivestock buy %s %d %d %s", tokens[o.lin], o.idx + 1, n, o.token) }
end
local find_offer
-- Pure: also suitable for dry-run previews; disabled settings return no plan.
local function propose(ctx, opts, preview)
  if opts ~= nil and type(opts) ~= "table" then return nil, "invalid replacement options" end
  local s = M.settings(opts)
  local err = common(ctx, s)
  if err then return nil, err end
  if not preview and not num(s.overhead, 0) then
    return nil, "execution requires explicit sale transport/risk assumption: replace overhead N"
  end
  if M.busy(opts) then return nil, "replacement busy" end
  local bgt = budget(ctx, opts or {})
  if not bgt then return nil, "invalid daily budget" end
  if ctx.bqueue_used >= ctx.bqueue_max or not queue_slots(ctx) then return nil, "bqueue unavailable" end
  local best
  local details = preview and {} or nil
  for _, b in ipairs(buildings) do
    local owned = preview and (ctx.buildings and num(ctx.buildings[b], 1)
      or not ctx.buildings and type(ctx.herds[b]) == "table" and type(ctx.herds[b].management) == "table")
    local rejection, depth, eligible
    if owned then
      local _, reason, gate = candidate(ctx, s, b, nil, bgt, preview)
      rejection, depth = reason, gate
    end
    for _, pool in pairs(ctx.lmarket) do
      if type(pool) == "table" then
        for _, o in pairs(pool) do
          local p, reason, gate = candidate(ctx, s, b, o, bgt, preview)
          -- Only matching offers contribute diagnostics. Furthest gate wins;
          -- lexical ties make the bounded summary independent of table order.
          if owned and type(o) == "table" and o.species == species[b] and not p
              and (gate > depth or (gate == depth and reason < rejection)) then
            rejection, depth = reason, gate
          end
          if p then
            eligible = true
            local better = not best or p.forecast.net_low > best.forecast.net_low
            if best and p.forecast.net_low == best.forecast.net_low then
              local a, z = p.gain / p.cost, best.gain / best.cost
              better = a > z or (a == z and (p.building < best.building
                or (p.building == best.building and (p.offer.lin < best.offer.lin
                or (p.offer.lin == best.offer.lin and p.offer.idx < best.offer.idx)))))
            end
            if better then best = p end
          end
        end
      end
    end
    if owned and not eligible then
      details[#details + 1] = { building = b, reason = rejection }
    end
  end
  if best and not find_offer(ctx, s, best) then return nil, "ambiguous market offer", details end
  return best, best and "ready" or "no eligible modeled replacement under current limits", details
end
function M.propose(ctx, opts) return propose(ctx, opts, false) end
function M.preview(ctx, opts)
  if type(ctx) ~= "table" then return nil, "invalid context", {} end
  if opts ~= nil and type(opts) ~= "table" then return nil, "invalid replacement options", {} end
  local c, s = copy(ctx), M.settings(opts)
  c.master_enabled, s.enabled = true, true
  local p, reason, details = propose(c, s, true)
  return p, reason, details or {}
end
find_offer = function(ctx, s, p)
  local found
  for _, pool in pairs(ctx.lmarket) do
    if type(pool) == "table" then
      for _, o in pairs(pool) do
        if type(o) == "table" and o.lin == p.offer.lin and o.idx == p.offer.idx then
          if found or not offer_ok(o, ctx, s, p.building)
              or not same(fingerprint(o), p.offer) then return nil end
          found = o
        end
      end
    end
  end
  return found
end
local function buy_safe(ctx, s, opts, job)
  local p = job.plan
  local h = pen(ctx, p.building, s)
  if not h or h.head ~= p.head - p.count or h.management.cap ~= p.head
      or h.management.pending ~= 0 or pending(ctx, p.building) ~= 0
      or not same(h.management.stats, job.post_stats) then return "post-cull herd drift" end
  if not find_offer(ctx, s, p) then return "offer changed or vanished" end
  if not same(quote(ctx, meats[p.building], s), p.prices.meat)
      or (outputs[p.building] and not same(quote(ctx, outputs[p.building], s), p.prices.output)) then
    return "prices changed or stale"
  end
  local bgt = budget(ctx, opts)
  if not bgt or bgt.spent > s.daily_cost or bgt.culled > s.daily_cull
      or p.cost > s.max_cost or p.cost > ctx.daler - ctx.reserve then return "purchase budget changed" end
end
local function mark(opts, job, phase, now)
  job.phase, job.sent_at = phase, now
  opts.in_flight = { phase = phase, building = job.plan.building, count = job.plan.count,
    cost = job.plan.cost, epoch = job.epoch, at = now }
  job.marker = copy(opts.in_flight)
end
function M.step(ctx, opts)
  if type(opts) ~= "table" then
    return nil, { phase = "halted", reason = "invalid replacement options" }
  end
  M.recover(opts)
  local job = jobs[opts]
  if job and (not same(opts.in_flight, job.marker) or not same(opts.daily, job.budget)) then
    -- Lost bookkeeping must never turn an unresolved command into an idle job.
    opts.in_flight = copy(job.marker)
    local changed = opts.daily
    opts.daily = copy(job.budget)
    if type(changed) == "table" then
      if num(changed.spent, 0) then opts.daily.spent = math.max(opts.daily.spent, changed.spent) end
      if num(changed.culled, 0, nil, true) then opts.daily.culled = math.max(opts.daily.culled, changed.culled) end
    end
    return nil, M.cancel(opts, "replacement bookkeeping changed; explicit reset required")
  end
  if M.busy(opts) and not job then return nil, M.status(opts) end
  local s = M.settings(opts)
  local passive = job and (job.phase == "await_delivery" or job.phase == "cooldown")
  local err = common(ctx, s, passive)
  if job and (err or ctx.epoch ~= job.epoch) then
    return nil, M.cancel(opts, err or "connection epoch changed")
  end
  if err then return nil, { phase = "idle", reason = err } end
  if job and not passive and not pen(ctx, job.plan.building, s) then
    return nil, M.cancel(opts, "managed pen disabled, stale or invalid")
  end
  if job and (ctx.now < (job.last_now or job.sent_at)
      or (job.phase == "await_delivery" and ctx.now > job.delivery_deadline)
      or (not passive and ctx.now - job.sent_at > (s.timeout or s.max_age))) then
    return nil, M.cancel(opts, "replacement timeout/clock rollback")
  end
  if job then job.last_now = ctx.now end
  if opts.dry_run then return nil, { phase = job and job.phase or "idle", reason = "dry run" } end
  if not job then
    local p, reason = M.propose(ctx, opts)
    if not p then return nil, { phase = "idle", reason = reason } end
    local bgt = budget(ctx, opts)
    -- Reserve BOTH command exposures before the first destructive action. Never
    -- refund: even a timeout or missing delivery may have executed on the server.
    bgt.spent, bgt.culled = bgt.spent + p.cost, bgt.culled + p.count
    opts.daily = bgt
    job = { plan = p, epoch = ctx.epoch, baseline = copy(ctx.observed), slots = queue_slots(ctx),
      budget = copy(bgt) }
    jobs[opts] = job
    mark(opts, job, "await_cull", ctx.now)
    return { kind = "slaughter", cmd = p.slaughter_cmd, why = p.why }, M.status(opts)
  end
  local p = job.plan
  if job.phase == "await_cull" then
    if later(ctx, "herds", job.baseline, job.sent_at, s) then
      local h = pen(ctx, p.building, s)
      if not h then return nil, M.cancel(opts, "invalid post-cull herd") end
      if h.head ~= p.head and h.head ~= p.head - p.count then
        return nil, M.cancel(opts, "unexpected cull count")
      end
      if h.head == p.head - p.count and h._received_at >= job.sent_at then
        if job.post_stats and not same(job.post_stats, h.management.stats) then
          return nil, M.cancel(opts, "post-cull stats drift")
        end
        for _, k in ipairs(stats) do
          if h.management.stats[k] < p.before_stats[k] then
            return nil, M.cancel(opts, "cull worsened conservative stats")
          end
        end
        job.post_stats = copy(h.management.stats)
      end
    end
    local new_slot = false
    if later(ctx, "bqueue", job.baseline, job.sent_at, s) then
      if not queue_slots(ctx) then return nil, M.cancel(opts, "invalid cull queue") end
      local added = 0
      for _, q in pairs(ctx.bqueue) do
        if not job.slots[q.slot] then
          added = added + 1
          -- Queue quantity is meat yield, not heads; the server guarantees
          -- at least one meat unit per head. Head loss is proved separately.
          new_slot = q.species == p.species and q.meat == meats[p.building] and q.qty >= p.count
        end
      end
      if added > 1 then return nil, M.cancel(opts, "ambiguous new cull queue slots") end
    end
    if job.post_stats and new_slot then
      local reason = buy_safe(ctx, s, opts, job)
      if reason then return nil, M.cancel(opts, reason) end
      job.baseline = copy(ctx.observed)
      mark(opts, job, "await_pending", ctx.now)
      return { kind = "buy", cmd = p.buy_cmd, why = p.why }, M.status(opts)
    end
  elseif job.phase == "await_pending" then
    if later(ctx, "pending", job.baseline, job.sent_at, s) then
      local matched = false
      for _, entry in pairs(ctx.lpending) do
        if type(entry) ~= "table" then return nil, M.cancel(opts, "invalid pending") end
        if entry.bldg == p.building then
          if matched or entry.breed ~= p.offer.breed or entry.species ~= p.species
              or entry.count ~= p.count or not num(entry.secs, 0, MAX_DELIVERY_SECS, true) then
            return nil, M.cancel(opts, "unexpected pending delivery")
          end
          matched = entry
        end
      end
      if matched then
        -- Anchor once to the fresh receipt, never to subsequent countdowns.
        job.delivery_deadline = ctx.observed.pending.at + matched.secs + (s.timeout or s.max_age)
        if not num(job.delivery_deadline, ctx.now) then
          return nil, M.cancel(opts, "invalid delivery deadline")
        end
        job.baseline = copy(ctx.observed)
        mark(opts, job, "await_delivery", ctx.now)
      end
    end
  elseif job.phase == "await_delivery" then
    if later(ctx, "pending", job.baseline, job.sent_at, s)
        and later(ctx, "herds", job.baseline, job.sent_at, s) then
      local h = pen(ctx, p.building, s)
      if h and h.head == p.head and h.management.cap == p.head
          and h._received_at >= job.sent_at and h.management.pending == 0
          and pending(ctx, p.building) == 0 then
        mark(opts, job, "cooldown", ctx.now)
      end
    end
  elseif job.phase == "cooldown" and ctx.now - job.sent_at >= (s.cooldown or s.max_age) then
    opts.in_flight, jobs[opts] = nil, nil
    -- Return without proposing again in this cycle.
    return nil, { phase = "complete" }
  end
  return nil, M.status(opts)
end
return M
