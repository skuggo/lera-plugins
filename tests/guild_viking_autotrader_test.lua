-- guild_viking autotrader/core.lua unit tests (stage 4 Task 1: settings,
-- warehouse/cart policy, quality math). Ported verbatim from LEGACY
-- guild_viking_autotrader.lua:19-296. Run from the lera-plugins repo root
-- with LERA_ROOT pointing at a built Lera checkout.
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

-- ---- lera API stubs (same shape as guild_viking_trade_test.lua) -----------
ui = { dirty = function() end }
lera = { time = function() return 1000 end, version = function() return "test" end }
-- mud.connected() is Task 2's IsConnected() stand-in (plan.lua). `sent`
-- collects mud.send() calls -- plan.lua itself never calls mud.send (it
-- captures into its own returned `commands` list -- see its header), so
-- this only fills up once Task 3's tick.lua starts actually dispatching.
local mud_connected = true
local sent = {}
mud = {
  send = function(cmd) sent[#sent + 1] = cmd end,
  connected = function() return mud_connected end,
}
local stored = nil
store = {
  load = function() end,
  get = function() return stored end,
  set = function(d) stored = d end,
  save = function() end,
}
-- Task 3 (tick.lua): fail_closed()/M.config() print via buffer.color_print.
-- Same capture shape as every other guild_viking test file's `buffer` stub.
local printed = {}
buffer = {
  color_print = function(...)
    local args = { ... }
    local parts = {}
    for i = 3, #args, 3 do
      parts[#parts + 1] = tostring(args[i])
    end
    printed[#printed + 1] = table.concat(parts)
  end,
}

local protocol = require("protocol")
-- init.lua's RESERVED set: the module-level convention fields, not MIP keys.
local RESERVED_KEYS = { _market_seam = true, _patterns = true, _gmcp = true,
                        _retired_keys = true, _retired_patterns = true }
local S = require("state").S

-- Guild.TradeGoods seeding. Fixtures keep MIP's compact notation --
-- "<lin>=<abbr>:<score>:<sup>:<dem>:<buy>:<sell>;..." with lineages joined by
-- "|" -- and this turns it into the per-lineage keys the payload uses. The
-- split is the server's: the flat list runs to ~420 records and a container
-- over 128 elements is refused whole.
local function seed_tgoods(str)
  -- Each fixture means "the world now holds exactly this", which MIP expressed
  -- by resetting trade_goods at the start of a burst. A GMCP frame is a delta
  -- -- an unchanged lineage is simply not resent, so the writer deliberately
  -- leaves lineages a frame does not carry standing -- so the reset belongs
  -- here, in the fixture, rather than in the writer.
  S.trade_goods = {}
  local payload = { guild = "viking" }
  for part in tostring(str or ""):gmatch("[^|]+") do
    local lin, goods = part:match("^(%d+)=(.*)$")
    if lin then
      local records = {}
      for entry in goods:gmatch("[^;]+") do
        local f = {}
        for piece in (entry .. ":"):gmatch("([^:]*):") do f[#f + 1] = piece end
        if f[1] and f[1] ~= "" then
          records[#records + 1] = { lin = tonumber(lin), good = f[1],
            score = tonumber(f[2]) or 0, sup = tonumber(f[3]) or 0,
            dem = tonumber(f[4]) or 0, buy = tonumber(f[5]) or 0,
            sell = tonumber(f[6]) or 0 }
        end
      end
      payload["tgoods_" .. lin] = records
    end
  end
  protocol.on_gmcp("Guild.TradeGoods", payload)
end

-- ---------------------------------------------------------------------------
-- Fixture seeding
-- ---------------------------------------------------------------------------
-- These fixtures are written in the compact notation this suite has always
-- used -- a good's stock as "good|amount|pct", a cart as its pipe-joined
-- fields -- and are translated here into the Guild.Trade / Guild.City frames
-- the production writers take. The notation is the fixture language, not a
-- wire format: nothing decodes it but the seven functions below, each of which
-- handles only the shapes this file actually writes.
--
-- Every case here asserts on autotrader behaviour, so a translation that
-- produced different state fails loudly rather than quietly testing nothing.
--
-- TGOODS is the exception and still seeds over MIP: it has no GMCP source yet,
-- so its handler and its fixtures stay until one lands.
local function split(str, sep)
  local out = {}
  for piece in tostring(str or ""):gmatch("[^" .. sep .. "]+") do
    out[#out + 1] = piece
  end
  return out
end

local function fields(entry)
  local out = {}
  for piece in (entry .. "|"):gmatch("([^|]*)|") do out[#out + 1] = piece end
  return out
end

local function gmcp(pkg, payload)
  payload.guild = "viking"
  protocol.on_gmcp(pkg, payload)
end

-- "good|amount|pct" or "good|amount|pct|grade", entries joined by ";".
local function seed_wstock(str)
  local entries = {}
  for _, e in ipairs(split(str, ";")) do
    local f = fields(e)
    entries[#entries + 1] = { good = f[1], amount = tonumber(f[2]) or 0,
                              pct = tonumber(f[3]) or 100,
                              grade = (f[4] ~= "" and f[4]) or nil }
  end
  gmcp("Guild.Trade", { wstock = entries })
end

-- "good:amount", entries joined by ";".
local function seed_blocks(str)
  local entries = {}
  for _, e in ipairs(split(str, ";")) do
    local good, amount = e:match("^([^:]+):(%d+)$")
    if good then entries[#entries + 1] = { good = good, amount = tonumber(amount) } end
  end
  gmcp("Guild.Trade", { blocks = entries })
end

-- "cart_id|tier|durability|cap|refit", entries joined by ";". The payload
-- calls the cart id `slot`.
local function seed_cidle(str)
  local entries = {}
  for _, e in ipairs(split(str, ";")) do
    local f = fields(e)
    entries[#entries + 1] = { slot = tonumber(f[1]) or 0, tier = tonumber(f[2]) or 1,
                              durability = tonumber(f[3]) or 100,
                              cap = tonumber(f[4]) or 0, refit = f[5] or "" }
  end
  gmcp("Guild.Trade", { cidle = entries })
end

-- 14 pipe-joined fields, entries joined by ";". `ret` is `secs` and `half` is
-- `half_in` on the payload. The final legs field is not used by any fixture in
-- this file, so a cart's legs are always empty here.
local function seed_carts(str)
  local entries = {}
  for _, e in ipairs(split(str, ";")) do
    local f = fields(e)
    entries[#entries + 1] = {
      mode = f[1], good = f[2], village = f[3], secs = tonumber(f[4]) or 0,
      amount = tonumber(f[5]) or 0, half_in = tonumber(f[6]) or 0,
      quality_pct = tonumber(f[7]) or 100, cart_id = tonumber(f[8]) or 0,
      tier = tonumber(f[9]) or 1, durability = tonumber(f[10]) or 100,
      cap = tonumber(f[11]) or 0, escort = tonumber(f[12]) or 0,
      refit = f[13] or "",
    }
  end
  gmcp("Guild.Trade", { carts = entries, cart_legs = {} })
end

-- A queued job is its legs, "mode|good|amount|village" joined by "!", jobs
-- joined by ";". The payload splits the job from its legs, keyed by job id.
local function seed_tqueue(str)
  local jobs, legs = {}, {}
  for job_index, job in ipairs(split(str, ";")) do
    local escort = 0
    local leg_strings = split(job, "!")
    for seq, ls in ipairs(leg_strings) do
      local f = fields(ls)
      if #f >= 4 then
        legs[#legs + 1] = { job = job_index, seq = seq, mode = f[1], good = f[2],
                            amount = tonumber(f[3]) or 0, village = f[4] }
        if seq == #leg_strings and f[5] and f[5] ~= "" then
          escort = tonumber(f[5]) or 0
        end
      end
    end
    jobs[#jobs + 1] = { job = job_index, escort = escort }
  end
  gmcp("Guild.Trade", { queue = jobs, queue_legs = legs })
end

-- "id:tier", entries joined by ",".
local function seed_buildings(str)
  local entries = {}
  for _, e in ipairs(split(str, ",")) do
    local id, tier = e:match("^([^:]+):(%d+)$")
    if id then entries[#entries + 1] = { id = id, tier = tonumber(tier) } end
  end
  gmcp("Guild.City", { buildings = entries })
end

-- 8 pipe-joined fields, entries joined by ";". `assigned`/`stat`/`arrive` are
-- the payload's names for assigned_to/stat_key/arrive_at.
local function seed_staff(str)
  local entries = {}
  for _, e in ipairs(split(str, ";")) do
    local f = fields(e)
    entries[#entries + 1] = { name = f[1], assigned = f[2], stat = f[3],
                              stats = f[4], trait = f[5],
                              loyalty = tonumber(f[6]) or 3, age = f[7],
                              arrive = tonumber(f[8]) or 0 }
  end
  -- One rotating slice carrying the whole fixture: staff_slices tells the
  -- client how many slices make up the list, and these fixtures fit in one.
  gmcp("Guild.Roster", { staff_0 = entries, staff_total = #entries,
                         staff_slices = #entries > 0 and 1 or 0 })
end

local function seed_daler(v)
  gmcp("Guild.State", { daler = tonumber(v) or 0 })
end
-- Mirrors init.lua's RESERVED set and its three registration tiers. The
-- fixtures above reach Guild.Trade, Guild.City, Guild.Roster and Guild.State
-- writers, which live across all four handler modules.
local RESERVED = RESERVED_KEYS
local trade = require("handlers.trade")
for _, name in ipairs({ "handlers.trade", "handlers.city", "handlers.voyage",
                        "handlers.kingdom" }) do
  local mod = require(name)
  for key, fn in pairs(mod._gmcp or {}) do
    protocol.gmcp_handler(key, fn)
  end
end

local at_core = require("autotrader.core")
local page_opts = require("page_opts")
local plan = require("autotrader.plan")
local tick = require("autotrader.tick")

-- ---------------------------------------------------------------------------
-- at_settings (LEGACY:19-31): default-knob guard, exercised on both the
-- fully-absent branch and the partial-table backfill branch. state.lua
-- normally seeds S.autotrade eagerly (see its own header comment), so this
-- clobbers it directly to exercise both of at_settings' own guard paths --
-- S.autotrade is plugin-local settings state, not a wire-parsed field, so
-- this is the same "direct S poke" market.lua's own test uses for
-- S.trade_goods, not the wire-fixture rule.
-- ---------------------------------------------------------------------------
S.autotrade = nil
local at = at_core.settings()
check("settings: fully-absent defaults",
      at.reserve == 0 and at.min_margin == 3 and at.min_profit == 200
      and at.max_carts == 2 and at.last == 0 and at.use_stock == false
      and at.last_msg == "" and at.show_n == 6 and #at.log == 0
      and at.stock_priority == true and at.auto_stock == 0)

S.autotrade = { reserve = 9 }   -- partial table missing log/min_profit/auto_stock/stock_priority
local at2 = at_core.settings()
check("settings: partial-table backfill preserves existing field",
      at2.reserve == 9)
check("settings: partial-table backfill fills in missing knobs",
      type(at2.log) == "table" and #at2.log == 0 and at2.min_profit == 200
      and at2.auto_stock == 0 and at2.stock_priority == true)
check("settings: partial-table backfill leaves OTHER missing fields alone (verbatim, not a superset)",
      at2.min_margin == nil and at2.max_carts == nil)

-- ---------------------------------------------------------------------------
-- at_log (LEGACY:33-39): appends, then trims to the 40-entry cap, oldest
-- first.
-- ---------------------------------------------------------------------------
S.autotrade = nil
at_core.settings()
for i = 1, 41 do at_core.log({ idx = i }) end
local at3 = at_core.settings()
check("log: capped at 40 entries", #at3.log == 40, #at3.log)
check("log: oldest (idx 1) dropped, idx 2 now first", at3.log[1].jobs.idx == 2)
check("log: newest (idx 41) is last", at3.log[#at3.log].jobs.idx == 41)
check("log: entry carries a t timestamp field", at3.log[1].t ~= nil)

-- ---------------------------------------------------------------------------
-- at_wh_amount (LEGACY:41-50): warehouse total minus vtrade-blocked amount,
-- floored at 0.
-- ---------------------------------------------------------------------------
seed_wstock( "salt|100|100")
seed_blocks( "salt:30")
check("wh_amount: total 100 minus blocked 30 = 70", at_core.wh_amount("salt") == 70)
seed_blocks( "salt:150")
check("wh_amount: blocked exceeding total floors at 0", at_core.wh_amount("salt") == 0)
check("wh_amount: unknown good is 0", at_core.wh_amount("nosuchgood") == 0)

-- ---------------------------------------------------------------------------
-- FIFO-vs-fresh quality (LEGACY:203-243) over a seeded warehouse stock of a
-- perishable good (fish: 3 freshness brackets from WSTOCK, oldest to
-- newest). Hand-computed for amount = 70:
--
--   fresh (newest-first, pct desc: 100/60, 80/40, 50/20):
--     take 60 @ 100%  -> val = 60*100        = 6000
--     take 10 @ 80%   -> val += 10*80 = 800   -> 6800
--     quality = floor(6800/70 + 0.5) = floor(97.142857 + 0.5) = floor(97.642857) = 97
--
--   fifo (oldest-first, pct asc: 50/20, 80/40, 100/60):
--     take 20 @ 50%   -> val = 20*50          = 1000
--     take 40 @ 80%   -> val += 40*80 = 3200  -> 4200
--     take 10 @ 100%  -> val += 10*100 = 1000 -> 5200
--     quality = floor(5200/70 + 0.5) = floor(74.285714 + 0.5) = floor(74.785714) = 74
--
-- fresh (97) and fifo (74) diverge sharply because the newest bracket is
-- much larger (60 units) than the oldest (20 units).
-- ---------------------------------------------------------------------------
seed_wstock( "fish|60|100;fish|40|80;fish|20|50")
check("fresh_quality: fish amount 70 -> 97 (hand-computed above)",
      at_core.fresh_quality("fish", 70) == 97, at_core.fresh_quality("fish", 70))
check("fifo_quality: fish amount 70 -> 74 (hand-computed above)",
      at_core.fifo_quality("fish", 70) == 74, at_core.fifo_quality("fish", 70))
check("fresh_quality: non-perishable good always 100", at_core.fresh_quality("timber", 70) == 100)
check("fifo_quality: non-perishable good always 100", at_core.fifo_quality("timber", 70) == 100)
check("fresh_quality: amount < 1 returns 100", at_core.fresh_quality("fish", 0) == 100)
check("fifo_quality: no stock at all returns 100", at_core.fifo_quality("nosuchfish", 5) == 100)

-- ---------------------------------------------------------------------------
-- at_cured_amount / at_cured_premium (LEGACY:161-194) over a seeded mead
-- cellar (WSTOCK freshness brackets for a graded good). AT_CURE_MIN_PCT =
-- 78 (LEGACY:159) gates which brackets count at all.
--
-- Brackets: 10 units @ 100% (>=100 -> premium 1.16), 20 units @ 90%
-- (>=90 -> 1.09), 5 units @ 80% (>=78, <90 -> 1.02), 100 units @ 50%
-- (< 78 -> excluded entirely, both from cured_amount and the premium
-- weighting).
--
--   cured_amount = 10 + 20 + 5           = 35   (the 100-unit 50% bracket is dropped)
--   val = 10*1.16 + 20*1.09 + 5*1.02
--       = 11.6   + 21.8   + 5.1          = 38.5
--   premium = val / qty = 38.5 / 35      = 1.1
-- ---------------------------------------------------------------------------
seed_wstock( "mead|10|100;mead|20|90;mead|5|80;mead|100|50")
check("is_graded: mead is graded", at_core.is_graded("mead") == true)
check("is_graded: timber is not graded", at_core.is_graded("timber") == false)
check("cured_amount: mead sums only >=78%-fresh brackets (10+20+5=35)",
      at_core.cured_amount("mead") == 35, at_core.cured_amount("mead"))
check("cured_premium: mead weighted premium = 38.5/35 = 1.1 (hand-computed above)",
      at_core.cured_premium("mead") == 1.1, at_core.cured_premium("mead"))
check("cured_amount: non-graded good returns full wh_amount (no cure gate)",
      at_core.cured_amount("nosuchgraded") == at_core.wh_amount("nosuchgraded"))
check("cured_premium: non-graded good is always 1.0", at_core.cured_premium("timber") == 1.0)
seed_wstock( "mead|100|50")   -- nothing cured at all
check("cured_premium: no cured stock at all is 1.0", at_core.cured_premium("mead") == 1.0)

-- ---------------------------------------------------------------------------
-- at_perishable (LEGACY:196-201).
-- ---------------------------------------------------------------------------
check("perishable: grain/fish/honey", at_core.perishable("grain") and at_core.perishable("fish")
      and at_core.perishable("honey"))
check("perishable: mead is NOT perishable (it is graded/ages up instead)",
      at_core.perishable("mead") == false)
check("perishable: durable goods are not perishable", at_core.perishable("timber") == false)

-- ---------------------------------------------------------------------------
-- at_cart_cap (LEGACY:52-65). Signature note: the plan brief's interface
-- list wrote "core.cart_cap(cart)", but LEGACY's at_cart_cap takes NO
-- arguments -- it scans state.idle_carts, falling back to state.carts. This
-- ports as zero-arg to mirror LEGACY's own signature exactly (see this
-- task's report for the full discrepancy note).
-- ---------------------------------------------------------------------------
seed_cidle( "1|1|100|40|standard;2|2|90|60|heavy")
check("cart_cap: biggest idle cart's capacity (60)", at_core.cart_cap() == 60)
seed_cidle( "")
seed_carts( "sell|fish|Havn|120|40|60|85|c1|2|90|35|1|armored|leg1,leg2")
check("cart_cap: falls back to state.carts when no idle carts (35)", at_core.cart_cap() == 35)
seed_carts( "")
check("cart_cap: LEGACY's 60 fallback when nothing at all is known", at_core.cart_cap() == 60)

-- ---------------------------------------------------------------------------
-- at_pick_cart (LEGACY:81-109): mode/idle/tier/refit preference order.
-- Fixture (via CIDLE, real handler): 5 idle carts spanning refits and caps,
-- one with durability 0 (must never be picked).
--   id1: tier1 dur100 cap40 standard
--   id2: tier2 dur90  cap60 heavy
--   id3: tier1 dur80  cap30 speed
--   id4: tier3 dur0   cap100 standard  (durability 0 -> excluded entirely)
--   id5: tier2 dur100 cap60 standard
-- ---------------------------------------------------------------------------
local function cart_id(c) return c and c.cart_id end

-- Low warehouse fullness (2%, well under the 85% "fullish" threshold) so an
-- explicit wh_full=false argument is not accidentally overridden by a real
-- warehouse_pct() that also happens to read >= 85.
seed_buildings( "warehouse:1")
seed_wstock( "junk|10|100")
check("warehouse_pct: sanity check, low fixture reads 2% (well under 85)",
      at_core.warehouse_pct() == 2, at_core.warehouse_pct())

seed_cidle(
  "1|1|100|40|standard;2|2|90|60|heavy;3|1|80|30|speed;4|3|0|100|standard;5|2|100|60|standard")

check("pick_cart: stock mode, warehouse full -> prefers heavy refit (id2)",
      cart_id(at_core.pick_cart("stock", nil, true)) == 2)
check("pick_cart: stock mode, not full, qty hint 50 -> cap>=50 excluding heavy (id5; id2 is heavy)",
      cart_id(at_core.pick_cart("stock", 50, false)) == 5)
check("pick_cart: stock mode, not full, no qty hint -> prefers speed refit (id3)",
      cart_id(at_core.pick_cart("stock", 0, false)) == 3)
check("pick_cart: arb mode, qty hint 50 -> cap>=50 excluding heavy (id5)",
      cart_id(at_core.pick_cart("arb", 50, false)) == 5)
check("pick_cart: arb mode ignores the fullish/heavy branch entirely (still id5 even when full)",
      cart_id(at_core.pick_cart("arb", 50, true)) == 5)
check("pick_cart: arb mode, no qty hint -> prefers speed refit (id3)",
      cart_id(at_core.pick_cart("arb", 0, false)) == 3)
check("pick_cart: unrecognized mode falls back to best overall; cap60 tie (id2/id5) breaks to lowest id",
      cart_id(at_core.pick_cart("other", nil, nil)) == 2)

seed_cidle( "")
check("pick_cart: no idle carts at all returns nil", at_core.pick_cart("stock", 10, false) == nil)

-- Fullish DERIVED from real warehouse_pct (no wh_full argument at all):
-- grain 350 / cap 400 (tier 1) = floor(87.5) = 87% >= 85 -> heavy branch.
seed_wstock( "grain|437|100")
seed_buildings( "warehouse:1")
seed_cidle( "1|1|100|40|standard;2|2|90|60|heavy;3|1|80|30|speed")
check("warehouse_pct: 437/500 = 87 (hand-computed: floor(437/500*100))",
      at_core.warehouse_pct() == 87, at_core.warehouse_pct())
check("pick_cart: derived fullish (87% >= 85) with no wh_full arg still prefers heavy (id2)",
      cart_id(at_core.pick_cart("stock", nil, nil)) == 2)

-- ---------------------------------------------------------------------------
-- at_max_stops (LEGACY:125-138): trading_post tier, +1 for an assigned
-- silver_tongue staffer.
-- ---------------------------------------------------------------------------
seed_buildings( "trading_post:3")
seed_staff( "")
check("max_stops: trading_post tier 3, no staff -> 3", at_core.max_stops() == 3)
seed_staff( "Bjorn|trading_post|trade|5,3,2,1,4,2,1|silver_tongue|4|veteran|1000")
check("max_stops: +1 for an assigned silver_tongue staffer -> 4", at_core.max_stops() == 4)
seed_staff( "Bjorn|trading_post|trade|5,3,2,1,4,2,1|0|4|veteran|1000")
check("max_stops: staffer assigned but not silver_tongue -> back to 3", at_core.max_stops() == 3)
seed_buildings( "")
check("max_stops: no trading_post building at all -> LEGACY's default tier 1", at_core.max_stops() == 1)

-- ---------------------------------------------------------------------------
-- Sell-suffix / quality policy for graded vs. perishable vs. durable goods
-- (LEGACY:245-279). Re-seed the mead/fish brackets from above for the
-- quality-multiplier assertions.
-- ---------------------------------------------------------------------------
seed_wstock(
  "mead|10|100;mead|20|90;mead|5|80;mead|100|50;fish|60|100;fish|40|80;fish|20|50")

check("route_sell_suffix: graded good sells ' best' first", at_core.route_sell_suffix("iron") == " best")
check("route_sell_suffix: perishable good sells ' oldest' first", at_core.route_sell_suffix("fish") == " oldest")
check("route_sell_suffix: durable good has no suffix", at_core.route_sell_suffix("timber") == "")

check("sell_qual: graded good sells ' best' first", at_core.sell_qual("iron") == " best")
check("sell_qual: non-graded good has no suffix", at_core.sell_qual("timber") == "")

check("route_sell_quality: graded good is the cured premium (1.1, hand-computed above)",
      at_core.route_sell_quality("mead", 99) == 1.1)
check("route_sell_quality: perishable good is fifo_quality/100 (74/100 = 0.74, hand-computed above)",
      at_core.route_sell_quality("fish", 70) == 0.74)
check("route_sell_quality: durable good is 1.0", at_core.route_sell_quality("timber", 99) == 1.0)

check("direct_sell_quality: graded good is the cured premium (1.1)",
      at_core.direct_sell_quality("mead", 99) == 1.1)
check("direct_sell_quality: perishable good is fresh_quality/100 (97/100 = 0.97, hand-computed above)",
      at_core.direct_sell_quality("fish", 70) == 0.97)
check("direct_sell_quality: durable good is 1.0", at_core.direct_sell_quality("timber", 99) == 1.0)

-- ---------------------------------------------------------------------------
-- snapshot()/restore() round-trip (mirrors market.lua's own test).
-- ---------------------------------------------------------------------------
S.autotrade = nil
at_core.settings()
S.autotrade.min_margin = 42
local snap = at_core.snapshot()
check("snapshot: carries the autotrade table", snap.autotrade == S.autotrade)
local saved = S.autotrade
S.autotrade = nil
at_core.restore(snap)
check("restore: round-trips the autotrade table", S.autotrade == saved and S.autotrade.min_margin == 42)
at_core.restore(nil)
check("restore: nil-safe", S.autotrade == saved)

-- ---------------------------------------------------------------------------
-- Settings defaults round-trip through persist.lua (the real save/load
-- path, not just this module's own snapshot/restore): persist.save() must
-- store the autotrade table, and persist.load() into a wiped S.autotrade
-- must bring it back with the settings a user configured.
-- ---------------------------------------------------------------------------
local persist = require("persist")

S.autotrade = nil
local at4 = at_core.settings()
at4.min_margin = 7
at4.reserve = 42
at4.max_carts = 5

persist.save()
check("persist round-trip: store.set() received the autotrade table",
      stored ~= nil and stored.autotrade ~= nil and stored.autotrade.min_margin == 7)

S.autotrade = nil   -- simulate a fresh process before persist.load()
persist.load()
check("persist round-trip: reloaded settings match what was saved",
      S.autotrade ~= nil and S.autotrade.min_margin == 7 and S.autotrade.reserve == 42
      and S.autotrade.max_carts == 5)

-- ===========================================================================
-- Task 2: autotrader/plan.lua (viking_autotrader_plan and its three helpers,
-- LEGACY guild_viking_autotrader.lua:281-667). Every fixture below is built
-- through protocol.ingest with the real handlers (never a direct S. poke,
-- except S.autotrade -- plugin-local settings state, the same exception
-- Task 1's own tests use). A fake, monotonically-increasing os.time() drives
-- both TGOODS' own >2s burst-reset window (handlers/trade.lua's M.TGOODS)
-- and plan.lua's 30s AT_INTERVAL gate deterministically, following the same
-- os.time-stubbing precedent guild_viking_trade_test.lua uses for price
-- history timestamps.
-- ===========================================================================
local real_os_time = os.time
local fake_now = 100000
os.time = function() return fake_now end

-- ---------------------------------------------------------------------------
-- Off by default (global constraint): before page_opts.auto_trade is ever
-- turned on, plan.build() must return nil and touch nothing.
-- ---------------------------------------------------------------------------
S.autotrade = nil
check("plan: off by default (page_opts.auto_trade starts false) -> nil",
      plan.build() == nil)

page_opts.set("auto_trade", true)

-- ---------------------------------------------------------------------------
-- A couple of the earlier top-of-function gates, ported in this same range
-- (LEGACY:401, 412-415), get a light sanity check before any fixture below
-- ever populates S.trade_queue -- Task 1's own tests never touch TQUEUE, so
-- it is still genuinely nil here (state.lua pre-seeds S.carts/S.idle_carts
-- to {} at load, always truthy, which is why the "waiting for city data"
-- gate in this port is effectively driven by S.trade_queue alone; see
-- plan.lua's header). Not exhaustively boundary-tested here -- that is Task
-- 3's job for auto_trade_tick's own preconditions -- just proof the gate
-- exists and returns the right status, without poking S. directly.
-- ---------------------------------------------------------------------------
mud_connected = false
local p0a = plan.build()
check("plan/not connected: status set, no jobs/commands",
      p0a and p0a.status == "not connected" and #p0a.jobs == 0 and #p0a.commands == 0)
mud_connected = true

check("plan/waiting for city data sanity: S.trade_queue is still nil (never ingested yet)",
      S.trade_queue == nil)
local p0b = plan.build()
check("plan/waiting for city data: status set, no jobs/commands",
      p0b and p0b.status == "waiting for city data"
      and #p0b.jobs == 0 and #p0b.commands == 0, p0b and p0b.status)
-- The status must not tell the player to run a command this client does not
-- have: Guild.City is a GMCP package here, always sent, with no toggle and no
-- `vtoggle` command at all.
check("plan/waiting for city data: no stale vtoggle advice",
      p0b and p0b.status:find("vtoggle", 1, true) == nil, p0b and p0b.status)

-- ---------------------------------------------------------------------------
-- Branch: budget clamp (LEGACY:376-379, inside at_add_deal_legs). One
-- arbitrage deal for a durable, non-graded good (timber, so
-- route_sell_quality is always 1.0 and the arithmetic stays simple).
--
-- TGOODS: lineage 0 buys timber at 10d (score -1, supply 1000); lineage 1
-- sells timber at 50d (score 2, demand 1000). compute_market_movers sizes
-- the deal at qty = min(supply 1000, floor(demand*0.8) = 800) = 800 -- that
-- 800 is only the MOVERS-suggested size, not what gets dispatched.
--
-- daler 500, reserve 0 -> budget 500. at_add_deal_legs:
--   qty = floor(budget / buy) = floor(500 / 10) = 50
--   (50 is not > a.qty=800, not > cap_left=200, not > have=1000 -> stays 50)
--   unit_margin = floor(sell*1.0 - buy + 0.5) = floor(50 - 10 + 0.5) = 40
--   gain = 50 * 40 = 2000
-- One idle cart (cap 200) comfortably covers cap_left, so cap_left never
-- binds here -- only the budget does.
-- ---------------------------------------------------------------------------
S.autotrade = nil
at_core.settings()
seed_buildings( "")
seed_wstock( "timber|1000|100")
seed_staff( "")
seed_blocks( "")
seed_carts( "")
seed_cidle( "11|1|100|200|standard")
seed_tqueue( "")
seed_daler( "500")
seed_tgoods( "0=t:-1:1000:0:10:0|1=t:2:0:1000:0:50")

local p1 = plan.build()
check("plan/budget clamp: returns a table", type(p1) == "table")
check("plan/budget clamp: exactly one job", p1 and #p1.jobs == 1, p1 and #p1.jobs)
if p1 and p1.jobs[1] then
  local j = p1.jobs[1]
  check("plan/budget clamp: job qty clamped to 50 by budget (not movers' 800)", j.qty == 50, j.qty)
  check("plan/budget clamp: job fields (mode/good/btown_lin/stown_lin/margin/profit)",
        j.mode == "buy" and j.good == "timber" and j.btown_lin == 0 and j.stown_lin == 1
        and j.margin == 40 and j.profit == 2000)
  check("plan/budget clamp: job label exact",
        j.label == "buy 50 Timber @Midgard->Lodbrok's Hold (+40/u, ~2000d) [cart #11]", j.label)
end
check("plan/budget clamp: exact command sequence",
      p1 and p1.commands[1] == "vtrade route clear quiet"
      and p1.commands[2] == "vtrade route cart 11"
      and p1.commands[3] == "vtrade route add buy 50 timber midgard"
      and p1.commands[4] == "vtrade route add sell 50 timber lodbrok"
      and p1.commands[5] == "vtrade queue add"
      and #p1.commands == 5)
check("plan/budget clamp: status cleared once jobs dispatch", p1 and p1.status == nil)

-- AT_INTERVAL (LEGACY:17, 30s) gate: calling again immediately (same
-- fake_now) must return nil without touching anything.
check("plan/AT_INTERVAL: a second call inside the 30s window returns nil",
      plan.build() == nil)

-- ---------------------------------------------------------------------------
-- Branch: cap_left exhaustion (LEGACY:378, `if qty > cap_left then qty =
-- cap_left end`). Same shape as above, but a HUGE budget/movers qty and a
-- small idle cart (cap 30), so cap_left -- not budget -- is what clamps qty.
--
--   qty (pre-clamp) = floor(100000 / 10) = 10000
--   a.qty (movers)  = min(2000, floor(2000*0.8)=1600) = 1600 -> qty clamps to 1600
--   cap_left = 30 (the only idle cart's capacity)             -> qty clamps to 30
--   unit_margin = floor(50*1.0 - 10 + 0.5) = 40
--   gain = 30 * 40 = 1200
-- ---------------------------------------------------------------------------
fake_now = fake_now + 1000
S.autotrade = nil
at_core.settings()
seed_buildings( "")
seed_wstock( "timber|1000|100")
seed_staff( "")
seed_blocks( "")
seed_carts( "")
seed_cidle( "21|1|100|30|standard")
seed_tqueue( "")
seed_daler( "100000")
seed_tgoods( "0=t:-1:2000:0:10:0|1=t:2:0:2000:0:50")

local p2 = plan.build()
check("plan/cap_left exhaustion: exactly one job", p2 and #p2.jobs == 1, p2 and #p2.jobs)
if p2 and p2.jobs[1] then
  local j = p2.jobs[1]
  check("plan/cap_left exhaustion: qty clamped to the cart's cap_left (30), not budget's 10000 nor movers' 1600",
        j.qty == 30, j.qty)
  check("plan/cap_left exhaustion: margin/profit", j.margin == 40 and j.profit == 1200)
end
check("plan/cap_left exhaustion: exact command sequence",
      p2 and p2.commands[1] == "vtrade route clear quiet"
      and p2.commands[2] == "vtrade route cart 21"
      and p2.commands[3] == "vtrade route add buy 30 timber midgard"
      and p2.commands[4] == "vtrade route add sell 30 timber lodbrok"
      and p2.commands[5] == "vtrade queue add"
      and #p2.commands == 5)

-- ---------------------------------------------------------------------------
-- add_deal_legs' "use warehouse stock" sub-path (LEGACY:344-365, inside
-- at_add_deal_legs' `if at.use_stock then ... end` block): an ARBITRAGE
-- candidate (so this must reach add_deal_legs, not dispatch_stock_sell/
-- add_stock_leg) that gets satisfied by SELLING EXISTING WAREHOUSE STOCK
-- instead of buying -- no "route add buy" command at all.
--
-- Two sell-side TGOODS entries for the same good (ore) create the
-- divergence that keeps this candidate out of the top-level stock scan
-- (LEGACY:461-513) while still reaching compute_market_movers as a genuine
-- arbitrage deal:
--   lineage 2: score 1  (fails compute_market_movers' score>=2 sell gate,
--              but wins best_sell_of on price alone: sell 100)
--   lineage 3: score 3  (qualifies for compute_market_movers: sell 50)
-- best_sell_of(ore) picks lineage 2 (sell 100 > 50) -> the top-level scan's
-- weak_sell check sees score 1 < AT_SELL_MIN_SCORE (2) and excludes ore
-- from `sc` entirely, regardless of warehouse amount. compute_market_movers
-- only accepts lineage 3 (score 3) for its sell side, so the arb candidate
-- carries sell=50, sell_lin=3, sell_demand=1000 (lineage 3's demand).
-- Warehouse stock (200 ore) is untouched by any of this -- it is read
-- directly by add_deal_legs' own core.wh_amount(a.good) call.
--
-- Inside add_deal_legs (at.use_stock true, cap_left 300 from the one idle
-- cart, never binding):
--   have = wh_amount(ore) = 200
--   sq = min(have 200, cap_left 300, sell_demand 1000) = 200
--   sq (200) >= AT_MIN_LEG_QTY (5) -> proceeds
--   gain = floor(200 * 50 * route_sell_quality(ore,200)=1.0 + 0.5)
--        = floor(10000.5) = 10000
-- Returns (job, cost=0, units=200) -- cost 0 is the tell: nothing was
-- bought. A single sell leg is queued, no buy leg, no second cart pass.
-- ---------------------------------------------------------------------------
fake_now = fake_now + 1000
S.autotrade = nil
at_core.settings()
S.autotrade.use_stock = true
seed_buildings( "")
seed_wstock( "ore|200|100")
seed_staff( "")
seed_blocks( "")
seed_carts( "")
seed_cidle( "71|1|100|300|standard")
seed_tqueue( "")
seed_daler( "5000")
seed_tgoods( "0=o:-1:1000:0:10:0|2=o:1:0:1000:0:100|3=o:3:0:1000:0:50")

local pu = plan.build()
check("plan/use-stock arb leg: exactly one job", pu and #pu.jobs == 1, pu and #pu.jobs)
if pu and pu.jobs[1] then
  local j = pu.jobs[1]
  check("plan/use-stock arb leg: job is a SELL of existing stock, not a buy",
        j.mode == "sell" and j.stock == true and j.good == "ore" and j.qty == 200
        and j.stown_lin == 3 and j.margin == 40 and j.profit == 10000, j.mode)
  check("plan/use-stock arb leg: label exact",
        j.label == "sell 200 Ore (stock)->Ui Imair Hold +10000d [cart #71]", j.label)
end
check("plan/use-stock arb leg: exactly ONE sell command, no buy leg at all",
      pu and pu.commands[1] == "vtrade route clear quiet"
      and pu.commands[2] == "vtrade route cart 71"
      and pu.commands[3] == "vtrade route add sell 200 ore ui_imair"
      and pu.commands[4] == "vtrade queue add"
      and #pu.commands == 4)

-- ---------------------------------------------------------------------------
-- Branch: warehouse-full stock dispatch (LEGACY:457-458, 471, 505 --
-- `overflow` bypasses both the weak-sell wait and the profit floor). A
-- durable, non-graded good (ore) piled to 95% of a tier-1 warehouse (cap
-- 400), with NO use_stock/auto_stock and a deliberately weak score (-3,
-- below AT_SELL_MIN_SCORE) that would normally hold it back.
--
--   warehouse_pct = floor(475/500*100) = 95 >= 85 -> wh_full/overflow = true
--   qty (top-level, and again at dispatch) = min(380, cart_cap 200, demand
--     1000) = 200
--   gain = floor(200*20*1.0 + 0.5) = 4000 (direct_sell_quality = 1.0: ore is
--     neither graded nor perishable)
-- ---------------------------------------------------------------------------
fake_now = fake_now + 1000
S.autotrade = nil
at_core.settings()
seed_buildings( "warehouse:1")
seed_wstock( "ore|475|100")
seed_staff( "")
seed_blocks( "")
seed_carts( "")
seed_cidle( "31|1|100|200|standard")
seed_tqueue( "")
seed_daler( "1000")
seed_tgoods( "2=o:-3:0:1000:0:20")

check("plan/warehouse-full sanity: 475/500 = 95% >= 85", at_core.warehouse_pct() == 95, at_core.warehouse_pct())

local p3 = plan.build()
check("plan/warehouse-full stock dispatch: exactly one job", p3 and #p3.jobs == 1, p3 and #p3.jobs)
if p3 and p3.jobs[1] then
  local j = p3.jobs[1]
  check("plan/warehouse-full stock dispatch: job fields",
        j.mode == "sell" and j.stock == true and j.good == "ore" and j.qty == 200
        and j.stown_lin == 2 and j.margin == 20 and j.profit == 4000)
  check("plan/warehouse-full stock dispatch: label exact",
        j.label == "sell 200 Ore (stock)->Eiriksson Hold +4000d [cart #31]", j.label)
end
check("plan/warehouse-full stock dispatch: single dispatch command, no route/queue machinery",
      p3 and #p3.commands == 1 and p3.commands[1] == "vtrade dispatch sell 200 ore eiriksson", p3 and p3.commands[1])

-- ---------------------------------------------------------------------------
-- Branch: demand-safety refusal (LEGACY:291/293/354-355, sell_demand caps
-- `sq` below AT_MIN_LEG_QTY=5 even though the CANDIDATE cleared the
-- top-level profit filter using that same demand-capped size). Furs (durable,
-- not graded), use_stock on, single-dispatch mode.
--
--   top-level candidate qty = min(have 50, cart_cap 60, demand 4) = 4
--   qty * eff = 4 * 100 = 400 >= min_profit 200 -> candidate is KEPT
--   at dispatch: sq = min(have 50, cap 60, demand 4) = 4 < AT_MIN_LEG_QTY (5)
--     and not forced -> dispatch_stock_sell returns nil: no send, no job
-- ---------------------------------------------------------------------------
fake_now = fake_now + 1000
S.autotrade = nil
at_core.settings()
S.autotrade.use_stock = true
seed_buildings( "")
seed_wstock( "furs|50|100")
seed_staff( "")
seed_blocks( "")
seed_carts( "")
seed_cidle( "41|1|100|60|standard")
seed_tqueue( "")
seed_daler( "1000")
seed_tgoods( "3=f:3:0:4:0:100")

local p4 = plan.build()
check("plan/demand-safety refusal: no jobs (leg fell under AT_MIN_LEG_QTY)",
      p4 and #p4.jobs == 0, p4 and #p4.jobs)
check("plan/demand-safety refusal: no commands sent",
      p4 and #p4.commands == 0, p4 and #p4.commands)
check("plan/demand-safety refusal: status names the one unaffordable candidate",
      p4 and p4.status == "1 deal(s) found but none affordable after reserve (budget 1000d) -- "
        .. "lower reserve/margin/min-profit or raise carts",
      p4 and p4.status)

-- ---------------------------------------------------------------------------
-- Branch: stop-limit truncation (LEGACY:580-586, `max_legs = at.pack and
-- at_max_stops() or 1` bounds a SINGLE cart's packed route). Three durable,
-- non-perishable, non-graded stock candidates (furs/ore/timber) with
-- trading_post tier 2 (no staff) -> max_stops() = 2 -> max_legs = 2 with
-- Pack on. Two idle carts, so the third candidate spills into its OWN
-- cart/route rather than being folded into the first (which still has
-- cap_left to spare -- the stop count, not the cap, is what truncates it).
--
--   sc products (margin*qty): furs 20*50=1000, ore 24*40=960, timber
--   15*60=900 -> sorted desc: furs, ore, timber
--
-- Cart 1 (cap 300): furs leg sq=min(50,300,1000)=50, gain=floor(50*20+0.5)=1000,
--   cap_left 300->250; ore leg sq=min(40,250,1000)=40, gain=floor(40*24+0.5)=960,
--   cap_left 250->210. #packed reaches max_legs (2) -> the inner loop stops
--   BEFORE consuming timber, even though cap_left (210) still has room.
-- Cart 2 (same only idle cart -- pick_cart is stateless within one planning
--   pass, an existing LEGACY property): timber leg sq=min(60,300,1000)=60,
--   gain=floor(60*15+0.5)=900.
-- ---------------------------------------------------------------------------
fake_now = fake_now + 1000
S.autotrade = nil
at_core.settings()
S.autotrade.use_stock = true
S.autotrade.stock_route = true
S.autotrade.pack = true
seed_buildings( "trading_post:2")
seed_wstock( "furs|50|100;timber|60|100;ore|40|100")
seed_staff( "")
seed_blocks( "")
seed_carts( "")
seed_cidle( "11|1|100|300|standard;12|1|100|300|standard")
seed_tqueue( "")
seed_daler( "1000")
seed_tgoods( "3=f:3:0:1000:0:20|4=t:3:0:1000:0:15|5=o:3:0:1000:0:24")

check("plan/stop-limit sanity: max_stops = 2 (trading_post tier 2, no staff)",
      at_core.max_stops() == 2, at_core.max_stops())

local p5 = plan.build()
check("plan/stop-limit truncation: three jobs total, across two carts",
      p5 and #p5.jobs == 3, p5 and #p5.jobs)
if p5 and #p5.jobs == 3 then
  local j1, j2, j3 = p5.jobs[1], p5.jobs[2], p5.jobs[3]
  check("plan/stop-limit truncation: job order furs, ore, timber (sorted by margin*qty desc)",
        j1.good == "furs" and j2.good == "ore" and j3.good == "timber")
  check("plan/stop-limit truncation: furs leg (cart 1)",
        j1.qty == 50 and j1.stown_lin == 3 and j1.profit == 1000
        and j1.label == "sell 50 Furs (stock)->Ui Imair Hold +1000d [cart #11]", j1.label)
  check("plan/stop-limit truncation: ore leg (cart 1, the 2nd and LAST leg max_legs allows)",
        j2.qty == 40 and j2.stown_lin == 5 and j2.profit == 960
        and j2.label == "sell 40 Ore (stock)->Harfagre Hold +960d [cart #11]", j2.label)
  check("plan/stop-limit truncation: timber leg spilled into its OWN cart/route (cart 2)",
        j3.qty == 60 and j3.stown_lin == 4 and j3.profit == 900
        and j3.label == "sell 60 Timber (stock)->Rurikid Hold +900d [cart #11]", j3.label)
end
check("plan/stop-limit truncation: exact command sequence -- two separate route/queue blocks",
      p5 and p5.commands[1] == "vtrade route clear quiet"
      and p5.commands[2] == "vtrade route cart 11"
      and p5.commands[3] == "vtrade route add sell 50 furs ui_imair"
      and p5.commands[4] == "vtrade route add sell 40 ore harfagre"
      and p5.commands[5] == "vtrade queue add"
      and p5.commands[6] == "vtrade route clear quiet"
      and p5.commands[7] == "vtrade route cart 11"
      and p5.commands[8] == "vtrade route add sell 60 timber rurikid"
      and p5.commands[9] == "vtrade queue add"
      and #p5.commands == 9)

-- ---------------------------------------------------------------------------
-- Mixed mode (LEGACY:526-554, at.stock_priority == false): the candidate
-- merge computes a comparable `profit_margin` for stock sells
-- (eff - replacement-cost, via best_buy_of) and arbitrage deals (margin
-- as-is), then sorts everyone by profit_margin*qty. Two stock candidates
-- (furs, ore) and one arbitrage candidate (timber) are built so the three
-- plausible outcomes give three DIFFERENT orders:
--
--   furs: eff (sp) = 90, best_buy_of = 20 -> profit_margin = 70, qty = 5
--         -> product = 350
--   ore:  eff (sp) = 70, best_buy_of = 20 -> profit_margin = 50, qty = 6
--         -> product = 300
--   timber (arb): margin = sell(50) - buy(40) = 10, movers qty = 50
--         -> profit_margin = margin = 10, product = 500
--
-- Correct order (sort by profit_margin*qty, descending): timber (500),
-- furs (350), ore (300).
--   * A wrong-direction bug (ascending instead of descending) would give
--     ore, furs, timber -- the exact reverse.
--   * A wrong-precedence bug (comparing raw margin/eff instead of
--     profit_margin*qty -- i.e. forgetting the best_buy_of subtraction and
--     the qty weighting) would rank by 90/70/10 and give furs, ore, timber
--     -- also different, and different from the reversed order too.
-- All three are distinct, so the exact job order below pins the real
-- comparator against both mistakes at once.
--
-- Timber is sourced from the ARB list, not `sc` -- a second, lower-scoring
-- "decoy" sell lineage (score 1, sell 999) makes best_sell_of(timber) win
-- on price and keeps timber's weak_sell check (score 1 < AT_SELL_MIN_SCORE
-- 2) failing it out of the top-level stock scan, exactly the same
-- divergence trick used for the use-stock-arb-leg fixture above. That is
-- what matters for THIS test: timber's `profit_margin` comes from the
-- `a.profit_margin = a.margin` line (LEGACY:543), not the stock branch's
-- `eff - best_buy_of` line (LEGACY:537), and its `qty` for the sort is
-- compute_market_movers' own qty (50: min(buy_supply 50, floor(sell_demand
-- 100 * 0.8) = 80)) -- both exercised BEFORE any dispatch happens.
--
-- Timber's warehouse stock (1000 units, given so a plain buy leg's own
-- `qty > have` clamp would not have zeroed it) turns out to be irrelevant
-- to which PATH it dispatches through: with at.use_stock true, LEGACY's
-- own `if at.use_stock then ... end` block in at_add_deal_legs (LEGACY:
-- 344-365) is checked BEFORE the plain buy path, and it succeeds for ANY
-- good already holding at least AT_MIN_LEG_QTY sellable units -- so timber
-- dispatches as a "sell existing stock" leg here too, same as furs/ore,
-- even though it is arb-sourced. Confirmed by tracing every clamp in that
-- branch: sq = min(have 1000, cap_left 300, sell_demand 100) = 100 (>=
-- AT_MIN_LEG_QTY), gain = floor(100 * 50 * 1.0 + 0.5) = 5000. This is a
-- genuine LEGACY property, not a fixture mistake -- "Use-stock: sell what
-- we already hold, skip buying" (LEGACY's own comment at :344) really does
-- mean skip buying for every candidate with usable stock, not only the
-- ones already flagged stock_only. The dedicated use-stock-arb-leg fixture
-- above already exercises this exact branch in isolation; this fixture's
-- job here is the MERGE/SORT, which is fully settled before any of that.
--
-- Furs and ore both dispatch as single direct sells (stock_route off);
-- furs' qty of 5 sits exactly on the AT_MIN_LEG_QTY boundary (5 < 5 is
-- false) so it is not itself a trickle refusal.
-- max_carts is raised to 3 so all three candidates get a cart (idle count
-- 3, otherwise the default max_carts=2 would truncate the dispatch loop
-- before the third candidate, confusing "wrong order" with "ran out of
-- carts").
-- ---------------------------------------------------------------------------
fake_now = fake_now + 1000
S.autotrade = nil
at_core.settings()
S.autotrade.use_stock = true
S.autotrade.stock_priority = false
S.autotrade.max_carts = 3
seed_buildings( "")
seed_wstock( "furs|5|100;ore|6|100;timber|1000|100")
seed_staff( "")
seed_blocks( "")
seed_carts( "")
seed_cidle( "91|1|100|300|standard;92|1|100|300|standard;93|1|100|300|standard")
seed_tqueue( "")
seed_daler( "100000")
seed_tgoods(
  "0=t:-1:50:0:40:0|1=t:2:0:100:0:50|2=f:3:0:1000:0:90|3=f:0:500:0:20:0"
  .. "|4=o:3:0:1000:0:70|5=o:0:500:0:20:0|6=t:1:0:1000:0:999")

local pm = plan.build()
check("plan/mixed mode: three jobs, one per candidate", pm and #pm.jobs == 3, pm and #pm.jobs)
if pm and #pm.jobs == 3 then
  local j1, j2, j3 = pm.jobs[1], pm.jobs[2], pm.jobs[3]
  check("plan/mixed mode: order is timber, furs, ore -- NOT the ascending reverse "
        .. "(ore, furs, timber) and NOT the raw-margin order (furs, ore, timber)",
        j1.good == "timber" and j2.good == "furs" and j3.good == "ore",
        string.format("%s, %s, %s", j1.good, j2.good, j3.good))
  check("plan/mixed mode: timber is arb-sourced (margin 10, the compute_market_movers "
        .. "margin, not an eff-minus-best_buy_of figure) but dispatches via the "
        .. "use-stock sub-path (qty 100, profit 5000) -- see the fixture comment above",
        j1.mode == "sell" and j1.stock == true and j1.margin == 10 and j1.qty == 100 and j1.profit == 5000)
  check("plan/mixed mode: furs stock sell (qty 5, right at the AT_MIN_LEG_QTY boundary)",
        j2.mode == "sell" and j2.stock == true and j2.qty == 5 and j2.margin == 90 and j2.profit == 450)
  check("plan/mixed mode: ore stock sell (qty 6, margin 70, profit 420)",
        j3.mode == "sell" and j3.stock == true and j3.qty == 6 and j3.margin == 70 and j3.profit == 420)
end
check("plan/mixed mode: exact command sequence -- timber's route/queue block first, "
      .. "then furs' and ore's direct dispatches, in that order",
      pm and pm.commands[1] == "vtrade route clear quiet"
      and pm.commands[2] == "vtrade route cart 91"
      and pm.commands[3] == "vtrade route add sell 100 timber lodbrok"
      and pm.commands[4] == "vtrade queue add"
      and pm.commands[5] == "vtrade dispatch sell 5 furs eiriksson"
      and pm.commands[6] == "vtrade dispatch sell 6 ore rurikid"
      and #pm.commands == 6)

-- ---------------------------------------------------------------------------
-- Branch: the empty-plan case (LEGACY:446-450). No arbitrage deals and no
-- reason to offload stock at all.
-- ---------------------------------------------------------------------------
fake_now = fake_now + 1000
S.autotrade = nil
at_core.settings()
seed_buildings( "")
seed_wstock( "")
seed_staff( "")
seed_blocks( "")
seed_carts( "")
seed_cidle( "51|1|100|100|standard")
seed_tqueue( "")
seed_daler( "500")
seed_tgoods( "")

local p6 = plan.build()
check("plan/empty-plan case: no jobs, no commands",
      p6 and #p6.jobs == 0 and #p6.commands == 0)
check("plan/empty-plan case: status exact",
      p6 and p6.status == "no profitable deals right now (and no stock set to offload)", p6 and p6.status)

-- ===========================================================================
-- Task 3: autotrader/tick.lua (auto_trade_tick's paced/MIP-confirmed
-- runner, LEGACY guild_viking_autotrader.lua:670-849). One test per
-- fail-closed gate enumerated in tick.lua's own header, plus the
-- AT_INTERVAL boundary walked end-to-end through the tick (not just
-- plan.build() directly, as the Task 2 section above already covers). The
-- same fake os.time() control from Task 2 stays active.
-- ===========================================================================

-- Reusable single-dispatch fixture (same numbers as the "plan/warehouse-full
-- stock dispatch" case above): produces EXACTLY one job, as a single-command
-- transaction ("vtrade dispatch sell 200 ore eiriksson"), so the state
-- machine's idle->sending->confirming cycle can be walked one command at a
-- time. warehouse_pct = floor(475/500*100) = 95 >= 85 -> overflow/wh_full;
-- qty = min(380, cart cap 200, demand 1000) = 200; gain =
-- floor(200*20*1.0 + 0.5) = 4000 (direct_sell_quality = 1.0: ore is neither
-- graded nor perishable).
local function setup_single_dispatch_fixture()
  S.autotrade = nil
  at_core.settings()
  seed_buildings( "warehouse:1")
  seed_wstock( "ore|475|100")
  seed_staff( "")
  seed_blocks( "")
  seed_carts( "")
  seed_cidle( "31|1|100|200|standard")
  seed_tqueue( "")
  seed_daler( "1000")
  seed_tgoods( "2=o:-3:0:1000:0:20")
end

-- ---------------------------------------------------------------------------
-- Gate 1: OFF by default. Task 2 above left page_opts.auto_trade ON, so
-- turn it off explicitly. Many ticks over a fixture that WOULD dispatch (if
-- the flag were on) must send nothing at all.
-- ---------------------------------------------------------------------------
page_opts.set("auto_trade", false)
setup_single_dispatch_fixture()
tick.reset()
sent, printed = {}, {}
for _ = 1, 50 do
  fake_now = fake_now + 1
  tick.tick()
end
check("tick/gate 1 (off by default): 50 ticks over a would-dispatch fixture send nothing",
      #sent == 0, #sent)
do
  local phase, pending = tick.status()
  check("tick/gate 1 (off by default): phase reset to idle, nothing pending",
        phase == "idle" and pending == 0, phase)
end

-- ---------------------------------------------------------------------------
-- Gate 1, ISOLATED from plan.lua's own auto_trade gate (TRADER:399). The
-- "50 ticks send nothing" property above is real, but it does not by
-- itself prove THIS module's own gate is what blocks it: even with that
-- gate removed, do_plan() would still call plan.build(), which has its OWN
-- page_opts.get("auto_trade") check and would return nil/empty regardless.
-- To isolate tick.lua's own gate, get the state machine into "sending" with
-- a command already staged (auto_trade legitimately ON at the time), THEN
-- flip auto_trade OFF and tick again -- that path never reaches do_plan()/
-- plan.lua's gate at all, so only M.tick's own top-of-function check can be
-- what stops the next command.
-- ---------------------------------------------------------------------------
page_opts.set("auto_trade", true)
S.autotrade = nil
at_core.settings()
S.autotrade.use_stock = true
S.autotrade.stock_route = true
S.autotrade.pack = true
seed_buildings( "trading_post:2")
seed_wstock( "furs|50|100;timber|60|100;ore|40|100")
seed_staff( "")
seed_blocks( "")
seed_carts( "")
seed_cidle( "11|1|100|300|standard;12|1|100|300|standard")
seed_tqueue( "")
seed_daler( "1000")
seed_tgoods( "3=f:3:0:1000:0:20|4=t:3:0:1000:0:15|5=o:3:0:1000:0:24")
tick.reset()
sent, printed = {}, {}
local g1_t0 = fake_now + 10000
fake_now = g1_t0
tick.tick()   -- idle -> plan (2 transactions, 5+4 cmds) -> begin T1 -> sends T1[1]
check("tick/gate 1 isolation setup: T1's first command sent, 4 more staged in this transaction",
      #sent == 1 and sent[1] == "vtrade route clear quiet", sent[1])
check("tick/gate 1 isolation setup: still sending, mid-transaction", tick.status() == "sending")

page_opts.set("auto_trade", false)
fake_now = g1_t0 + 2   -- next_at has elapsed -- ONLY the top-of-tick gate can stop this now
tick.tick()
check("tick/gate 1 (isolated): flipping auto_trade off mid-transaction sends NOTHING further "
      .. "-- this path never reaches do_plan()/plan.lua's own gate at all",
      #sent == 1, #sent)
do
  local phase, pending = tick.status()
  check("tick/gate 1 (isolated): state machine reset to idle/empty",
        phase == "idle" and pending == 0, phase)
end
page_opts.set("auto_trade", true)   -- restore for the sections below

-- ---------------------------------------------------------------------------
-- Turn the feature on and walk the full single-command dispatch cycle: the
-- commands seam (plan.build()'s own `commands` list, fed through this
-- module's port of LEGACY's transactions()) and gates 2/3 (confirming-phase
-- wait, then confirmation timeout -> fail_closed).
-- ---------------------------------------------------------------------------
page_opts.set("auto_trade", true)
setup_single_dispatch_fixture()
tick.reset()
sent, printed = {}, {}
local g23_t0 = fake_now + 1000
fake_now = g23_t0
tick.tick()
check("tick/commands seam: one call plans, begins, and sends the single-command transaction",
      #sent == 1 and sent[1] == "vtrade dispatch sell 200 ore eiriksson", sent[1])
do
  local phase, pending = tick.status()
  check("tick/commands seam: phase is confirming, nothing left pending",
        phase == "confirming" and pending == 0, phase)
end

-- Gate 2: confirming-phase wait -- mip_sig unchanged, well before the 20s
-- deadline -> no new send, still confirming.
fake_now = g23_t0 + 5
tick.tick()
check("tick/gate 2 (confirming wait): no send while mip unchanged and before the deadline",
      #sent == 1)
check("tick/gate 2 (confirming wait): still confirming", tick.status() == "confirming")

-- Gate 3: confirmation timeout. The send happened at g23_t0 (gate 2's probe
-- at g23_t0+5 only READ the state, it did not send anything), so
-- CONFIRM_TIMEOUT's deadline is g23_t0+20, not g23_t0+25. Test both sides
-- of that exact boundary: 19s after the send, still confirming (before the
-- deadline); 20s, fail_closed fires (>= deadline, not merely > it).
fake_now = g23_t0 + 19
tick.tick()
check("tick/gate 3 (confirm timeout): 19s after the send, still confirming (before the deadline)",
      tick.status() == "confirming")
check("tick/gate 3 (confirm timeout): no send yet at 19s", #sent == 1)

fake_now = g23_t0 + 20
tick.tick()
do
  local phase, pending, _, last_error = tick.status()
  check("tick/gate 3 (confirm timeout): fail_closed moves to cooldown exactly at the 20s deadline",
        phase == "cooldown", phase)
  check("tick/gate 3 (confirm timeout): last_error set verbatim",
        last_error == "no MIP confirmation within 20s", last_error)
end
check("tick/gate 3 (confirm timeout): diagnostic printed verbatim",
      printed[#printed] ==
        "[Auto-Trade] no MIP confirmation within 20s; paused without retrying the dispatch",
      printed[#printed])
check("tick/gate 3 (confirm timeout): no additional send", #sent == 1)

-- ---------------------------------------------------------------------------
-- Gate 4: cooldown (30s FAILURE_COOLDOWN from the fail_closed above) blocks
-- everything -- including drawing a fresh plan -- until it elapses; the
-- boundary is exact (29s no, 30s yes). Once it lifts, the SAME fixture is
-- still sitting there ready to dispatch, so a fresh send at exactly 30s
-- proves the gate actually reopened rather than merely not having
-- re-errored.
-- ---------------------------------------------------------------------------
local g4_fail_at = g23_t0 + 20   -- the fail_closed above fired exactly at the 20s deadline
fake_now = g4_fail_at + 29
tick.tick()
check("tick/gate 4 (cooldown): still blocked 29s after the failure", tick.status() == "cooldown")
check("tick/gate 4 (cooldown): no send at 29s", #sent == 1)

fake_now = g4_fail_at + 30
tick.tick()
check("tick/gate 4 (cooldown): cooldown lifts at 30s and a fresh dispatch fires",
      #sent == 2 and sent[2] == "vtrade dispatch sell 200 ore eiriksson", sent[2])

-- ---------------------------------------------------------------------------
-- Gates 5/6/7 plus a full multi-transaction commands-seam check: a fixture
-- whose plan produces TWO transactions (5 + 4 commands, matching the
-- "plan/stop-limit truncation" fixture and its exact command sequence in
-- the Task 2 section above). Walks: gate 7 (inter-command COMMAND_DELAY
-- within one transaction), the confirm/success handoff, gate 5 (COMMAND_DELAY
-- before the NEXT pending transaction may begin), and gate 6 (a pending
-- transaction means do_plan() is skipped -- the second transaction's
-- commands are exactly what the ORIGINAL plan produced, not recomputed).
-- ---------------------------------------------------------------------------
tick.reset()
sent, printed = {}, {}
S.autotrade = nil
at_core.settings()
S.autotrade.use_stock = true
S.autotrade.stock_route = true
S.autotrade.pack = true
seed_buildings( "trading_post:2")
seed_wstock( "furs|50|100;timber|60|100;ore|40|100")
seed_staff( "")
seed_blocks( "")
seed_carts( "")
seed_cidle( "11|1|100|300|standard;12|1|100|300|standard")
seed_tqueue( "")
seed_daler( "1000")
seed_tgoods( "3=f:3:0:1000:0:20|4=t:3:0:1000:0:15|5=o:3:0:1000:0:24")

local expect_commands = {
  "vtrade route clear quiet", "vtrade route cart 11",
  "vtrade route add sell 50 furs ui_imair", "vtrade route add sell 40 ore harfagre",
  "vtrade queue add",
  "vtrade route clear quiet", "vtrade route cart 11",
  "vtrade route add sell 60 timber rurikid", "vtrade queue add",
}

local t0 = fake_now + 1000
fake_now = t0
tick.tick()   -- idle -> plan (2 transactions queued) -> begin T1 -> sends T1[1]
check("tick/multi-tx: first call plans and sends T1's first command",
      #sent == 1 and sent[1] == expect_commands[1], sent[1])

-- Gate 7: inter-command delay -- 1s later (< 2s COMMAND_DELAY) sends
-- nothing more.
fake_now = t0 + 1
tick.tick()
check("tick/gate 7 (inter-command delay): no send 1s after the previous command (< 2s)",
      #sent == 1)

-- Send T1's remaining 4 commands, one every 2s, each gated by COMMAND_DELAY.
local at_time = t0
for i = 2, 5 do
  at_time = at_time + 2
  fake_now = at_time
  tick.tick()
  check("tick/multi-tx: T1 command " .. i .. " sent exactly at its COMMAND_DELAY boundary",
        #sent == i and sent[i] == expect_commands[i], sent[i])
end
do
  local phase, pending = tick.status()
  check("tick/multi-tx: after T1's queue-add, confirming with T2 still pending",
        phase == "confirming" and pending == 1, phase)
end

-- Confirm T1 (a real MIP push would move cart 11 off the idle list; adding a
-- second idle-cart row changes mip_sig() without zeroing idle_carts, which
-- both plan.build()'s own "no idle carts" gate and this fixture's second
-- transaction still need to be non-empty).
seed_cidle( "11|1|100|300|standard;12|1|100|300|standard;13|1|100|10|standard")
fake_now = at_time + 1
tick.tick()
do
  local phase = tick.status()
  check("tick/multi-tx: T1 confirmed, back to idle (T2 still pending)", phase == "idle", phase)
end

-- Gate 5: post-success COMMAND_DELAY (2s) -- T2 must NOT begin before it
-- elapses, even though it is already pending.
fake_now = at_time + 2   -- 1s after confirmation, < 2s COMMAND_DELAY from it
tick.tick()
check("tick/gate 5 (post-success delay): T2 has not started yet (still #sent == 5)",
      #sent == 5, #sent)

-- COMMAND_DELAY elapses: T2 begins. Gate 6: pending is non-empty, so
-- do_plan() is skipped -- T2's commands are the ORIGINAL plan's, unchanged.
fake_now = at_time + 3
tick.tick()
check("tick/gate 6 (pending skips replanning): T2's first command is the ORIGINAL plan's, "
      .. "not a freshly recomputed one",
      #sent == 6 and sent[6] == expect_commands[6], sent[6])

local at_time2 = fake_now
for i = 7, 9 do
  at_time2 = at_time2 + 2
  fake_now = at_time2
  tick.tick()
  check("tick/multi-tx: T2 command " .. i .. " sent exactly at its COMMAND_DELAY boundary",
        #sent == i and sent[i] == expect_commands[i], sent[i])
end
check("tick/multi-tx: full 9-command sequence matches plan.build()'s own "
      .. "\"stop-limit truncation\" fixture exactly (the commands seam)",
      table.concat(sent, "|") == table.concat(expect_commands, "|"))

-- ---------------------------------------------------------------------------
-- Baseline placement (LEGACY:837-839's own comment: "Earlier cart
-- completions while building a route cannot confirm it"). mip_sig() must be
-- captured immediately before the TERMINAL command of a transaction, not at
-- its start (sm.index == 1). Mutate S mid-route -- after the first command,
-- before the rest -- to simulate an UNRELATED cart returning while the
-- route is still being built. If the baseline were captured at the start,
-- that unrelated change would already satisfy mip_sig() ~= baseline the
-- instant the route finishes sending, falsely confirming it before any real
-- MIP push for THIS transaction arrives -- releasing the next queued
-- transaction (more cart dispatches) early. Both of gate 2/3's existing
-- checks above only mutate mip AFTER the terminal command, so neither would
-- ever notice this.
-- ---------------------------------------------------------------------------
tick.reset()
sent, printed = {}, {}
S.autotrade = nil
at_core.settings()
S.autotrade.use_stock = true
S.autotrade.stock_route = true
S.autotrade.pack = true
seed_buildings( "trading_post:2")
seed_wstock( "furs|50|100;timber|60|100;ore|40|100")
seed_staff( "")
seed_blocks( "")
seed_carts( "")
seed_cidle( "11|1|100|300|standard;12|1|100|300|standard")
seed_tqueue( "")
seed_daler( "1000")
seed_tgoods( "3=f:3:0:1000:0:20|4=t:3:0:1000:0:15|5=o:3:0:1000:0:24")

local bp_t0 = fake_now + 10000
fake_now = bp_t0
tick.tick()   -- T1[1] = "vtrade route clear quiet"
check("tick/baseline placement setup: T1's first command sent",
      #sent == 1 and sent[1] == "vtrade route clear quiet", sent[1])

-- Mid-route mutation: an UNRELATED idle cart (13) appears while T1 (cart 11)
-- is still being built -- changes mip_sig() well before T1's terminal
-- command is even sent.
seed_cidle( "11|1|100|300|standard;12|1|100|300|standard;13|1|100|10|standard")

-- Send T1's remaining 4 commands normally, with NO further state changes.
local bt = bp_t0
for _ = 2, 5 do
  bt = bt + 2
  fake_now = bt
  tick.tick()
end
do
  local phase, pending = tick.status()
  check("tick/baseline placement setup: T1 fully sent, confirming, T2 still pending",
        phase == "confirming" and pending == 1, phase)
end
check("tick/baseline placement setup: all 5 T1 commands sent", #sent == 5, #sent)

-- The mid-route mutation above must NOT be mistaken for T1's own real
-- confirmation: with no further state change since the terminal command,
-- the next tick must still be waiting -- the baseline was captured AFTER
-- that mid-route mutation, immediately before the terminal command
-- (LEGACY:837-839), so it already reflects cart 13's presence.
fake_now = bt + 1
tick.tick()
check("tick/baseline placement (LEGACY:837-839): an EARLIER mid-route cart change does "
      .. "NOT falsely confirm the transaction -- still confirming",
      tick.status() == "confirming")
check("tick/baseline placement: no premature send of T2's commands", #sent == 5, #sent)

-- A genuine change AFTER the terminal command (T1's real MIP confirmation
-- -- cart 11 itself leaving the idle list) still correctly releases T2.
seed_cidle( "12|1|100|300|standard;13|1|100|10|standard")
fake_now = bt + 2
tick.tick()
check("tick/baseline placement: a REAL post-terminal change confirms normally",
      tick.status() == "idle")

-- ---------------------------------------------------------------------------
-- `#route > 1` (TRADER:780): a "route clear" immediately closed by "queue
-- add" with NO adds in between must NOT become a transaction -- this is the
-- guard Gate 8's unreachability argument (below) rests on. plan.lua's own
-- invariants never actually produce that shape (every real "queue add" is
-- preceded by at least one "route add"), so it is exercised here by
-- monkey-patching autotrader.plan's M.build to hand do_plan a crafted
-- commands list directly -- restored immediately after.
-- ---------------------------------------------------------------------------
tick.reset()
sent, printed = {}, {}
page_opts.set("auto_trade", true)
local real_plan_build = plan.build
plan.build = function()
  return { status = nil, jobs = {}, commands = {
    "vtrade route clear quiet",
    "vtrade queue add",
    "vtrade dispatch sell 10 furs eiriksson",   -- a genuine transaction right after the empty one
  } }
end
fake_now = fake_now + 20000
tick.tick()
check("tick/#route>1 (empty route dropped): the bare clear+queue-add produces NO transaction "
      .. "-- only the genuine dispatch afterward is ever sent",
      #sent == 1 and sent[1] == "vtrade dispatch sell 10 furs eiriksson", sent[1])
plan.build = real_plan_build

-- ---------------------------------------------------------------------------
-- Gate 8 (LEGACY:836, `if not cmd then fail_closed(...) end`): structurally
-- unreachable through the public path -- see tick.lua's header for why
-- transactions() can never hand begin_transaction an empty array -- so it is
-- not given a synthetic test here, same disclosed treatment plan.lua's
-- header already gives LEGACY:339's dead code. The `#route>1` guard that
-- unreachability rests on IS pinned above.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Gate 9 (LEGACY:800-802): planner failed -- do_plan()'s pcall around
-- planner.build() catching a raised error, not just a normal return, must
-- fail-closed exactly like a confirmation timeout rather than letting the
-- error propagate out of M.tick().
-- ---------------------------------------------------------------------------
tick.reset()
sent, printed = {}, {}
page_opts.set("auto_trade", true)
local real_plan_build_err = plan.build
plan.build = function() error("boom: planner exploded") end
fake_now = fake_now + 50000
tick.tick()
do
  local phase, pending, _, last_error = tick.status()
  check("tick/gate 9 (planner error): fail_closed moves to cooldown",
        phase == "cooldown", phase)
  check("tick/gate 9 (planner error): last_error names the planner failure",
        last_error ~= nil and last_error:find("^planner failed: ") ~= nil
          and last_error:find("boom: planner exploded", 1, true) ~= nil,
        last_error)
end
check("tick/gate 9 (planner error): diagnostic printed with the failure reason",
      printed[#printed] ~= nil and printed[#printed]:find("planner failed:", 1, true) ~= nil
        and printed[#printed]:find("paused without retrying the dispatch", 1, true) ~= nil,
      printed[#printed])
check("tick/gate 9 (planner error): nothing sent", #sent == 0)
plan.build = real_plan_build_err

-- ---------------------------------------------------------------------------
-- Gate: the planner itself finds nothing to do (no arbitrage, no stock to
-- offload) -- nothing is sent, and the phase stays idle so a later tick
-- retries planning rather than getting stuck.
-- ---------------------------------------------------------------------------
tick.reset()
sent, printed = {}, {}
S.autotrade = nil
at_core.settings()
seed_buildings( "")
seed_wstock( "")
seed_staff( "")
seed_blocks( "")
seed_carts( "")
seed_cidle( "61|1|100|100|standard")
seed_tqueue( "")
seed_daler( "500")
seed_tgoods( "")
fake_now = fake_now + 10000
tick.tick()
check("tick/gate (no candidates): nothing sent", #sent == 0)
check("tick/gate (no candidates): phase stays idle", tick.status() == "idle")
fake_now = fake_now + 1
tick.tick()
check("tick/gate (no candidates): a later tick retries planning, still nothing sent", #sent == 0)

-- ---------------------------------------------------------------------------
-- "atrade debug on" (at.debug) was previously write-only: nothing read it,
-- so the command's own promise ("each idle tick will print why nothing was
-- sent") never happened. do_plan() now prints plan.build()'s own status
-- string via note() when debug is on and the planner actually ran (not on
-- every throttled AT_INTERVAL no-op).
-- ---------------------------------------------------------------------------
at_core.settings().debug = true
printed = {}
fake_now = fake_now + 10000
tick.tick()
check("tick/debug on: an idle tick with nothing to do prints the planner's status",
      #printed == 1 and printed[1]:find("idle tick:", 1, true) ~= nil
      and printed[1]:find("no profitable deals", 1, true) ~= nil,
      printed[1])
printed = {}
fake_now = fake_now + 1
tick.tick()
check("tick/debug on: a throttled (no-op) call in between prints nothing new",
      #printed == 0, #printed)
at_core.settings().debug = false

-- ===========================================================================
-- AT_INTERVAL (30s) boundary walked end-to-end through the tick, not just
-- plan.build() directly (already covered in the Task 2 section above): 29s
-- after the first dispatch's plan.build() call, still blocked; 30s, a fresh
-- dispatch fires.
-- ===========================================================================
page_opts.set("auto_trade", true)
setup_single_dispatch_fixture()
tick.reset()
sent, printed = {}, {}
local ati_t0 = fake_now + 1000
fake_now = ati_t0
tick.tick()
check("tick/AT_INTERVAL setup: first dispatch fires immediately",
      #sent == 1 and sent[1] == "vtrade dispatch sell 200 ore eiriksson", sent[1])

-- Confirm it (a second idle cart appears -- mip_sig changes -- without
-- zeroing idle_carts, so plan.build()'s own idle-cart gate stays open and
-- AT_INTERVAL, not that gate, is what the 29s/30s probe below exercises).
seed_cidle( "31|1|100|200|standard;32|1|100|50|standard")
fake_now = ati_t0 + 1
tick.tick()
check("tick/AT_INTERVAL setup: confirmed back to idle", tick.status() == "idle")

-- The post-confirm COMMAND_DELAY (next_at = ati_t0+1+2 = ati_t0+3) has long
-- elapsed by ati_t0+29, so AT_INTERVAL -- not COMMAND_DELAY -- is what is
-- doing the blocking from here on.
fake_now = ati_t0 + 29
tick.tick()
check("tick/AT_INTERVAL: 29s after the first plan.build() call, still blocked (no send)",
      #sent == 1, #sent)

fake_now = ati_t0 + 30
tick.tick()
check("tick/AT_INTERVAL: 30s after the first plan.build() call, a fresh dispatch fires",
      #sent == 2 and sent[2] == "vtrade dispatch sell 200 ore eiriksson", sent[2])

os.time = real_os_time

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING AUTOTRADER TESTS PASSED")
