-- Auto-trade settings and pure policy/quality math, ported verbatim from
-- LEGACY guild_viking_autotrader.lua:19-296 (functions at_settings through
-- at_sell_qual). Stage 4 Task 1 of the automation plan; the paced-execution
-- tick that actually sends `vtrade` commands (at_dispatch_stock_sell and
-- friends, LEGACY:281+) is a later task's territory, not this module's.
--
-- Adaptations (all mechanical, no logic changes):
--   * LEGACY's implicit global `state` -> `S` (require("state").S), same
--     idiom as every other stage-1..3 module (see market.lua's header).
--   * Functions LEGACY made top-level GLOBALS (`function at_foo()` with no
--     `local`) purely to stay under MUSHclient Lua's 200-main-chunk-local
--     cap (see LEGACY:113-114, 143-145's own comments) are ordinary module
--     members here; that cap does not apply to a lera plugin submodule.
--   * `at_best_idle_cart` (LEGACY:67-79) was already a `local function` in
--     LEGACY -- it stays a private module-local helper here too, not part
--     of this module's public interface, since nothing outside at_pick_cart
--     calls it in the source.
--   * AT_CURE_MIN_PCT (LEGACY:159) is a module-local constant here for the
--     same 200-local-cap reason as above.
--   * AT_INTERVAL (LEGACY:17, the 30-second auto-trade tick interval) is
--     OUTSIDE this task's ported line range (19-296). It is declared in
--     autotrader/plan.lua instead (Task 2), not here and not in the
--     tick-wiring task: its only use site, LEGACY:416
--     (`if at.last and (now - at.last) < AT_INTERVAL then return end`), is
--     inside viking_autotrader_plan (TRADER:398-667), which plan.lua ports.
--     `auto_trade_tick` (TRADER:812-849) never references AT_INTERVAL at
--     all.
--   * The MAIN 4128-4211 bridge (`viking_autotrader_context`) hands the
--     separate TRADER chunk `state`, `page_opts`, and a `dependencies` table
--     of `{ libs, compute_market_movers, towns (AT_TOWN), lineage_names
--     (LIN_NAMES) }`. None of those four dependency entries, nor `page_opts`
--     itself, are read by any function in LEGACY:19-296 -- grepping the
--     range confirms it -- so there is no bridge DATA table to port into
--     this module; `page_opts.auto_trade` and the AT_TOWN/LIN_NAMES lookups
--     are exclusively consumed by later automation (at_dispatch_stock_sell
--     onward, and the tick/menu wiring), which is out of scope here. Our
--     module reaches shared state directly via `require("state").S`, per
--     the plan's stated adaptation.
--   * No `Send`/`mud.send` calls exist in the ported range, so this module
--     makes no automated sends and needs no deadmans note of its own; the
--     tick module that calls into it will carry that note.
local S = require("state").S

local M = {}

-- LEGACY:19-31 (at_settings). Ensures state.autotrade exists with every
-- default knob, then backfills any field that predates a later default --
-- exactly LEGACY's own guard shape, not a superset. state.lua already seeds
-- S.autotrade with a superset of these fields (plus stage-2/3 UI fields:
-- pack, status, last_jobs; see state.lua's comment), so the top branch is
-- normally a no-op in this codebase, matching LEGACY's own behavior when
-- OnPluginSaveState had already restored a same-shape table.
function M.settings()
  if not S.autotrade then
    S.autotrade = { reserve = 0, min_margin = 3, min_profit = 200, max_carts = 2, last = 0,
                    use_stock = false, last_msg = "", show_n = 6, log = {},
                    stock_priority = true }
  end
  local at = S.autotrade
  if not at.log then at.log = {} end
  if at.min_profit == nil then at.min_profit = 200 end
  if at.auto_stock == nil then at.auto_stock = 0 end
  if at.stock_priority == nil then at.stock_priority = true end
  return at
end

-- LEGACY:33-39 (at_log). Appends one tick's job list to the persistent,
-- capped (40-entry) auto-trade log.
function M.log(jobs)
  local at = M.settings()
  at.log[#at.log + 1] = { t = os.date("%H:%M"), jobs = jobs }
  while #at.log > 40 do table.remove(at.log, 1) end
end

-- LEGACY:41-50 (at_wh_amount). Warehouse amount of `good` available to sell:
-- WSTOCK total minus anything reserved via 'vtrade block'.
function M.wh_amount(good)
  local amt = 0
  for _, item in ipairs(S.wstock or {}) do
    if item.good == good then amt = item.amount or 0; break end
  end
  amt = amt - ((S.blocks and S.blocks[good]) or 0)
  return (amt > 0) and amt or 0
end

-- LEGACY:52-65 (at_cart_cap). Capacity of the biggest free (idle, else any
-- owned) cart, so the auto-trader never queues more cargo than a cart can
-- carry; 60 is LEGACY's own fallback when no cart data is known at all.
-- Signature note: the brief's interface list wrote "core.cart_cap(cart)",
-- but LEGACY's at_cart_cap takes NO arguments (it scans state.idle_carts /
-- state.carts itself) -- the same sentence says signatures must mirror
-- LEGACY's arguments exactly, so this ports as zero-arg, matching the
-- source. Disclosed in the task report as a brief inconsistency.
function M.cart_cap()
  local cap = 0
  for _, ic in ipairs(S.idle_carts or {}) do
    if (ic.cap or 0) > cap then cap = ic.cap end
  end
  if cap == 0 then
    for _, ct in ipairs(S.carts or {}) do
      if (ct.cap or 0) > cap then cap = ct.cap end
    end
  end
  return (cap > 0) and cap or 60
end

-- LEGACY:67-79 (at_best_idle_cart). Private helper for at_pick_cart below:
-- the largest durable idle cart matching an optional predicate, ties broken
-- by lowest cart_id.
local function best_idle_cart(pred)
  local best
  for _, ic in ipairs(S.idle_carts or {}) do
    if (ic.durability or 100) > 0 and (not pred or pred(ic)) then
      if not best then best = ic
      else
        local bcap, icap = best.cap or 0, ic.cap or 0
        if icap > bcap or (icap == bcap and (ic.cart_id or 0) < (best.cart_id or 0)) then best = ic end
      end
    end
  end
  return best
end

-- LEGACY:81-109 (at_pick_cart). Cart-selection policy for a queued job:
-- "stock" (warehouse-offload) mode prefers a heavy-refit cart once the
-- warehouse is nearly full, else a cart that fits the hinted quantity
-- (avoiding a "heavy" refit for a normal job), else speed, else anything;
-- "arb" (arbitrage) mode skips the heavy-refit-when-full branch entirely;
-- any other mode just takes the best idle cart outright. nil when no idle
-- cart exists at all.
function M.pick_cart(mode, qty_hint, wh_full)
  local idle = S.idle_carts or {}
  if #idle < 1 then return nil end
  local qty = qty_hint or 0
  local fullish = wh_full or M.warehouse_pct() >= 85
  if mode == "stock" then
    if fullish then
      return best_idle_cart(function(ic) return ic.refit == "heavy" end)
          or best_idle_cart()
    end
    if qty > 0 then
      return best_idle_cart(function(ic) return (ic.cap or 0) >= qty and ic.refit ~= "heavy" end)
          or best_idle_cart(function(ic) return ic.refit == "speed" end)
          or best_idle_cart()
    end
    return best_idle_cart(function(ic) return ic.refit == "speed" end)
        or best_idle_cart()
  end
  if mode == "arb" then
    if qty > 0 then
      return best_idle_cart(function(ic) return (ic.cap or 0) >= qty and ic.refit ~= "heavy" end)
          or best_idle_cart(function(ic) return ic.refit == "speed" end)
          or best_idle_cart()
    end
    return best_idle_cart(function(ic) return ic.refit == "speed" end)
        or best_idle_cart()
  end
  return best_idle_cart()
end

-- LEGACY:111-123 (at_warehouse_pct). Warehouse fullness 0-100, from the
-- building tier's capacity table and the summed WSTOCK amounts.
--
-- S.wh_cap (from WSTOCK's cap field) is the server's real capacity,
-- including steward/lager/star bonuses the static per-tier table below
-- knows nothing about -- pages/city.lua prefers it the same way, for the
-- same reason (a warehouse with any such bonus was reported "over 100%
-- full" here using a cap lower than its actual one, which could only ever
-- make wh_full trigger too early, never too late).
function M.warehouse_pct()
  -- Fallback only: S.wh_cap from the server is preferred below. These mirror
  -- trade_daemon.c's warehouse_capacity(), which gained +25% per tier when the
  -- goods list grew (ore, iron, tools, salted fish, bread, fine furs,
  -- gemstones); the table still held the pre-2024 numbers.
  local WH_CAP_BY_TIER = { [1] = 500, [2] = 1250, [3] = 2188, [4] = 3750, [5] = 6563 }
  local wh_tier = (S.buildings and S.buildings.warehouse) or 0
  local cap = S.wh_cap or WH_CAP_BY_TIER[wh_tier] or 0
  if cap <= 0 then return 0 end
  local used = 0
  for _, ws in ipairs(S.wstock or {}) do used = used + (ws.amount or 0) end
  return math.floor(used / cap * 100)
end

-- LEGACY:125-138 (at_max_stops). Max route stops the Trading Post allows:
-- 1 per building tier, +1 if a Silver Tongue staffer is assigned there.
function M.max_stops()
  local tp = (S.buildings and S.buildings.trading_post) or 1
  local stops = tp
  for _, sf in ipairs(S.staff_list or {}) do
    if sf.assigned_to == "trading_post" and sf.trait == "silver_tongue" then
      stops = stops + 1
      break
    end
  end
  return math.max(1, stops)
end

-- LEGACY:146-154 (at_is_graded). Refined goods whose sale price scales with
-- frozen cure grade (88-116% via query_refined_sale_pct); mead included
-- (Mead Cellar ages it up on the same band).
function M.is_graded(good)
  return good == "iron" or good == "salted_fish" or good == "bread"
      or good == "fine_furs" or good == "tools" or good == "mead"
end

-- LEGACY:159 (AT_CURE_MIN_PCT). Minimum freshness_pct for a graded good's
-- stock to count as "cured enough to sell for value" (grade 2+).
local AT_CURE_MIN_PCT = 78

-- LEGACY:161-173 (at_cured_amount). Units of `good` cured enough to sell;
-- non-graded goods return their full warehouse amount (no cure gate).
function M.cured_amount(good)
  if not M.is_graded(good) then return M.wh_amount(good) end
  local n = 0
  for _, it in ipairs(S.wstock or {}) do
    if it.good == good and (it.freshness_pct or 100) >= AT_CURE_MIN_PCT then
      n = n + (it.amount or 0)
    end
  end
  return n
end

-- LEGACY:175-194 (at_cured_premium). Quantity-weighted average sale premium
-- of the cured stock of a graded good, matching the server's
-- query_refined_sale_pct grade bands (2/3/4 -> 1.02/1.09/1.16). 1.0 for a
-- non-graded good or when nothing is cured.
function M.cured_premium(good)
  if not M.is_graded(good) then return 1.0 end
  local val, qty = 0, 0
  for _, it in ipairs(S.wstock or {}) do
    if it.good == good then
      local fp = it.freshness_pct or 100
      if fp >= AT_CURE_MIN_PCT then
        local prem = (fp >= 100 and 1.16) or (fp >= 90 and 1.09) or 1.02
        val = val + (it.amount or 0) * prem
        qty = qty + (it.amount or 0)
      end
    end
  end
  if qty <= 0 then return 1.0 end
  return val / qty
end

-- LEGACY:196-201 (at_perishable). Goods that spoil over time (grain, fish,
-- honey); mead ages UP (handled by at_is_graded instead) and every other
-- good is durable.
function M.perishable(good)
  return good == "grain" or good == "fish" or good == "honey"
end

-- LEGACY:203-223 (at_fresh_quality). Weighted average quality% of the
-- freshest `amount` units of a perishable good (newest lots drained first).
-- 100 for a durable good or when there is nothing to model.
function M.fresh_quality(good, amount)
  if not M.perishable(good) or (amount or 0) < 1 then return 100 end
  local rows = {}
  for _, it in ipairs(S.wstock or {}) do
    if it.good == good then rows[#rows + 1] = { pct = it.freshness_pct or 100, amt = it.amount or 0 } end
  end
  if #rows < 1 then return 100 end
  table.sort(rows, function(x, y) return x.pct > y.pct end)
  local val, rem = 0, amount
  for _, r in ipairs(rows) do
    if rem < 1 then break end
    local take = math.min(r.amt, rem)
    val = val + r.pct * take
    rem = rem - take
  end
  return math.floor(val / amount + 0.5)
end

-- LEGACY:225-243 (at_fifo_quality). Weighted average quality% of the OLDEST
-- `amount` units (FIFO drain order). 100 when not perishable.
function M.fifo_quality(good, amount)
  if not M.perishable(good) or (amount or 0) < 1 then return 100 end
  local rows = {}
  for _, it in ipairs(S.wstock or {}) do
    if it.good == good then rows[#rows + 1] = { pct = it.freshness_pct or 100, amt = it.amount or 0 } end
  end
  if #rows < 1 then return 100 end
  table.sort(rows, function(x, y) return x.pct < y.pct end)
  local val, rem = 0, amount
  for _, r in ipairs(rows) do
    if rem < 1 then break end
    local take = math.min(r.amt, rem)
    val = val + r.pct * take
    rem = rem - take
  end
  return math.floor(val / amount + 0.5)
end

-- LEGACY:245-253 (at_route_sell_suffix). Quality suffix for a ROUTE sell
-- leg: graded goods sell top grade first (" best"), perishables sell oldest
-- first (" oldest"), durables get no suffix (server default, 100%).
function M.route_sell_suffix(good)
  if M.is_graded(good) then return " best" end
  if M.perishable(good) then return " oldest" end
  return ""
end

-- LEGACY:255-261 (at_route_sell_quality). Realized unit-sale multiplier for
-- a ROUTE sell of `qty` units, matching the suffix above.
function M.route_sell_quality(good, qty)
  if M.is_graded(good) then return M.cured_premium(good) end
  if M.perishable(good) then return M.fifo_quality(good, qty) / 100 end
  return 1.0
end

-- LEGACY:263-270 (at_direct_sell_quality). Realized unit-sale multiplier for
-- a DIRECT dispatch sell of `qty` units: the direct path defaults to "fresh"
-- pick server-side (newest lots first).
function M.direct_sell_quality(good, qty)
  if M.is_graded(good) then return M.cured_premium(good) end
  if M.perishable(good) then return M.fresh_quality(good, qty) / 100 end
  return 1.0
end

-- LEGACY:272-279 (at_sell_qual). Quality suffix for a DIRECT dispatch sell:
-- graded goods always sell highest grade first; everything else gets no
-- suffix (server "fresh" default).
function M.sell_qual(good)
  if M.is_graded(good) then return " best" end
  return ""
end

-- Persisted subset for persist.lua's store wiring (LEGACY's own settings
-- were auto-persisted via SetVariable/OnPluginSaveState -- see persist.lua's
-- header). Only the settings table itself round-trips; carts/wstock/etc are
-- live session data, never persisted.
function M.snapshot()
  return { autotrade = S.autotrade }
end

function M.restore(tbl)
  if not tbl then return end
  if tbl.autotrade then S.autotrade = tbl.autotrade end
end

return M
