-- Pure replacement counterfactual; no state, actions, prices or rates are fetched.
-- evaluate(input): all numeric inputs must be finite numbers (no coercion).
-- Required: purchase_cost, head, cull_count, yield_before, yield_after,
-- production_per_tick, meat_qty, meat_unit_price, meat_demand, horizon_ticks,
-- gap_ticks, overhead. output_unit_price/output_demand are required only when
-- production_per_tick > 0. scaled_share is optional; nothing else is defaulted.
-- Costs are TOTAL costs, not per animal. Yields describe this herd before/after.
-- Caller supplies conservative meat_qty (one unit per culled animal), not a
-- predicted butchery yield. Quotes/demand are current, not refreshed each tick.
-- output_gain_low/high are conservative/advisory monetary post-arrival scenarios,
-- excluding gap loss. They are not guaranteed production bounds.
-- net_low/high additionally include meat, purchase, overhead and gap loss.
-- Unknown results omit numeric forecasts (Lua nil), never substitute zero.
-- estimate exists only with explicit scaled_share. break_even_ticks is the
-- earliest whole tick at/after arrival covering all gap losses, within horizon;
-- only supplied for explicit share and positive saleable improvement rate.
local M = {}

local function finite(n)
  return type(n) == "number" and n == n and n > -math.huge and n < math.huge
end

function M.evaluate(input)
  local r = {
    known = false,
    reasons = {},
    assumptions = {
      "Counterfactual versus doing nothing; not guaranteed profit.",
      "Current output is a whole-herd baseline, observed fresh or manually configured; not inferred from yield.",
      "Meat quantity is caller-supplied conservative units, not actual butchery yield; sold once upfront up to current demand.",
      "Purchase cost is total replacement cost; overhead is the caller's sale transport/risk assumption (zero for gross preview).",
      "Direct purchase delivery and slaughter fees are zero. Each gap tick charges the whole baseline output, not the culled fraction.",
      "Lower scenario credits no positive production gain: integer rounding and additive staff invalidate guaranteed ratio improvements. High/estimate/break-even are advisory only, not execution guarantees.",
      "Only positive incremental output is capped by current quoted demand over the entire horizon; demand never refreshes.",
      "Replacement restores the same head count; no persistent feed savings; gap feed savings ignored conservatively.",
      "Slaughter has no direct fee; this forecast executes no commands.",
    },
    excluded = {
      "Random births, deaths, hybrid outcomes and disease.",
      "Transport benefits (including horses); zero production does not value transport.",
      "Sale execution, future price changes and future demand changes.",
    },
  }
  if type(input) ~= "table" then
    r.reasons[1] = "input must be a table"
    return r
  end

  local function validate(key, minimum, maximum, integer, optional)
    local value = input[key]
    if value == nil and optional then return end
    if not finite(value) or value < minimum or (maximum and value > maximum)
        or (integer and value ~= math.floor(value)) then
      r.reasons[#r.reasons + 1] = key .. " must be a finite number in valid bounds"
    end
  end
  validate("purchase_cost", 0)
  validate("head", 0)
  validate("cull_count", 0)
  validate("yield_before", 0, 100)
  validate("yield_after", 0, 100)
  validate("production_per_tick", 0)
  validate("meat_qty", 0)
  validate("meat_unit_price", 0)
  validate("meat_demand", 0)
  validate("horizon_ticks", 1, nil, true)
  validate("gap_ticks", 0, nil, true)
  validate("overhead", 0)
  validate("scaled_share", 0, 1, false, true)
  local no_output = input.production_per_tick == 0
  validate("output_unit_price", 0, nil, false, no_output)
  validate("output_demand", 0, nil, false, no_output)
  if finite(input.head) and input.head <= 0 then
    r.reasons[#r.reasons + 1] = "head must be positive"
  end
  if finite(input.cull_count) and finite(input.head)
      and (input.cull_count <= 0 or input.cull_count > input.head) then
    r.reasons[#r.reasons + 1] = "cull_count must be positive and no greater than head"
  end
  if finite(input.gap_ticks) and finite(input.horizon_ticks)
      and input.gap_ticks > input.horizon_ticks then
    r.reasons[#r.reasons + 1] = "gap_ticks must not exceed horizon_ticks"
  end
  if #r.reasons > 0 then return r end
  if not no_output and input.yield_before == 0 then
    r.reasons[1] = "Positive production with yield_before zero has no defined yield ratio"
    return r
  end

  local explicit_share = input.scaled_share ~= nil
  r.assumptions[#r.assumptions + 1] = explicit_share
    and "Only the user-specified scaled_share responds to the herd yield ratio."
    or "Unknown scaled_share: advisory high uses whole-output ratio scaling, without inventing a share; lower credits no gain and charges whole output for yield declines."

  local meat = math.min(input.meat_qty, input.meat_demand) * input.meat_unit_price
  local cost = input.purchase_cost + input.overhead
  local ticks = input.horizon_ticks - input.gap_ticks
  local gap_loss, rate, price, demand = 0, 0, 0, 0
  if not no_output then
    price, demand = input.output_unit_price, input.output_demand
    gap_loss = input.production_per_tick * input.gap_ticks * price
    rate = input.production_per_tick * ((input.yield_after / input.yield_before) - 1)
  end
  local function gain(share)
    local units = rate * share * ticks
    if units > 0 then units = math.min(units, demand) end
    return units * price
  end
  local a = gain(explicit_share and input.scaled_share or 0)
  local b = gain(explicit_share and input.scaled_share or 1)
  local low, high = math.min(0, a, b), math.max(0, a, b)
    -- A yield decline has no reliable discrete ratio floor either.
    if input.yield_after < input.yield_before then
      low = -input.production_per_tick * ticks * price
    end
  local base = meat - cost - gap_loss
  local net_low, net_high = base + low, base + high
  -- Reject intermediate overflow too: a later demand clamp must not hide it.
  local intermediates = { meat, cost, gap_loss, rate, rate * ticks,
    a, b, base, net_low, net_high }
  for _, value in ipairs(intermediates) do
    if not finite(value) then
      r.reasons[1] = "Forecast arithmetic exceeds finite numeric range"
      return r
    end
  end

  r.known = true
  r.purchase_cost = input.purchase_cost
  r.meat_revenue = meat
  r.output_gain_low, r.output_gain_high = low, high
  r.net_low, r.net_high = net_low, net_high
  if explicit_share then
    r.estimate = base + a
    local units_per_tick = rate * input.scaled_share
    local revenue_per_tick = units_per_tick * price
    if units_per_tick > 0 and finite(revenue_per_tick) and revenue_per_tick > 0
        and demand > 0 and ticks > 0 and r.estimate >= 0 then
      local needed = math.max(0, -base)
      local after_arrival = math.ceil(needed / revenue_per_tick)
      if after_arrival <= ticks then
        local available = math.min(units_per_tick * after_arrival, demand) * price
        if finite(available) and available >= needed then
          r.break_even_ticks = input.gap_ticks + after_arrival
        end
      end
    end
  end
  return r
end

return M
