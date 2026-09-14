-- Trade and economy payload parsers, ported verbatim from LEGACY
-- guild_viking.lua (github.com/.../3s_scripts_old, read-only reference).
-- Each parser body transcribes its LEGACY `elseif key == "..."` branch:
-- string.split -> util.split, state. -> S. (module-local alias). Display
-- calls (viking_window.*, ColourNote) are dropped -- the protocol layer already
-- marks ui.dirty(); parsers never do.
local S = require("state").S
local observe = require("herd_observe")
local util = require("util")

local M = {}

-- MARKET/TGOODS seam for Task 7's market module (price history, demand
-- tracking). nil until Task 7 sets it; parsers call through only when set.
M._market_seam = { on_market = nil, on_tgoods = nil }

-- Good abbreviations used by TGOODS, index-matched to the server's own
-- _abbrevs/ALL_GOODS pair (players/viking/obj/include/client.h's
-- _v_tgoods()). Two confirmed bugs fixed here:
--   * `a` was mapped to "amber" -- the good's OLD id, before the server
--     renamed it to "sunstone" (GOOD_AMBER is now a #define alias for
--     GOOD_SUNSTONE server-side, kept only so old references still
--     resolve). market.lua's own GOODS_ALL already uses "sunstone", so
--     Sunstone trade-goods data landed under a key nothing else read.
--   * The 11 husbandry/refined-husbandry goods (appended to ALL_GOODS
--     "LAST" per that file's own comment, to keep earlier abbrev indices
--     stable) had no entries here AT ALL -- c/d/p/q/v/x/mi/hm/z/sm/cs
--     decoded to themselves as bare letters instead of to a good id
--     best_sell_of()/the stock-sell scanner could ever match, so Wool,
--     Eggs, Pork, Mutton, Poultry, Beef, Milk, Horsemeat, Cloth, Smoked
--     Meat and Cheese were silently unsellable via auto-trade regardless
--     of stock, demand, or blocks.
local GOOD_SHORT = {
  t = "timber", o = "ore",   i = "iron",  f = "furs",  h = "fish",
  g = "grain",  m = "mead",  a = "sunstone", r = "runestones",
  s = "spoils", k = "salted_fish", b = "bread", e = "fine_furs",
  l = "tools",  j = "gemstones", y = "honey",
  w = "weapons", u = "armour", n = "finery",
  c = "wool", d = "eggs", p = "pork", q = "mutton", v = "poultry",
  x = "beef", mi = "milk", hm = "horsemeat",
  z = "cloth", sm = "smoked_meat", cs = "cheese",
}

-- STAFF stat-slot order (LEGACY guild_viking.lua:2348).
local STAFF_STAT_ORDER = { "combat", "trade", "craft", "sea", "wild", "land", "charm" }

-- ---------------------------------------------------------------------------
-- Guild.TradeGoods
-- ---------------------------------------------------------------------------
-- The current GMCP transport streams one lineage per frame as
-- `{ lin, lin_count?, goods }`. A complete cycle replaces the grid atomically:
-- auto-trading reads this state independently of protocol dispatch, so staging
-- a lineage directly into `S.trade_goods` would expose a partial generation.
-- `lin_count` is delta-suppressed after it has first been observed. Older
-- servers use `tgoods_0`, `tgoods_1`, ... instead; those remain independent
-- per-lineage replacements.
--
-- `good` is the one-character abbreviation on the wire; GOOD_SHORT resolves it
-- to the name the pages index by. `sup`/`dem` are supply/demand.
local TGOODS_MIN_LIN = 0
local TGOODS_MAX_LIN = 13
local TGOODS_MAX_COUNT = 14
local tgoods_stream = {
  connection_epoch = S.herd_connection_epoch or 0,
  expected = nil,
  pending = nil,
  seen = nil,
  count = 0,
  last_lin = nil,
  complete = false,
}

-- Detached scalars only: querying progress must neither publish pending prices
-- nor create receipt evidence. A reset invalidates the view immediately, even
-- before the next frame arrives to discard the old decoding context.
local function tgoods_status()
  local epoch = S.herd_connection_epoch or 0
  if tgoods_stream.connection_epoch ~= epoch then
    return { received = 0, complete = false, ever_complete = false,
             connection_epoch = epoch }
  end
  return {
    received = tgoods_stream.complete and tgoods_stream.expected or tgoods_stream.count,
    expected = tgoods_stream.expected,
    complete = tgoods_stream.complete,
    ever_complete = tgoods_stream.last_complete_at ~= nil,
    last_complete_at = tgoods_stream.last_complete_at,
    last_lin = tgoods_stream.last_lin,
    connection_epoch = epoch,
  }
end

local function decode_tgoods_records(records)
  if type(records) ~= "table" then error("TGOODS goods must be a table") end
  local goods = {}
  for _, r in ipairs(records) do
    if type(r) == "table" and r.good ~= nil then
      local abbr = tostring(r.good)
      local good = GOOD_SHORT[abbr] or abbr
      goods[good] = {
        _received_at = os.time(),
        score  = tonumber(r.score) or 0,
        supply = tonumber(r.sup) or 0,
        demand = tonumber(r.dem) or 0,
        buy    = tonumber(r.buy) or 0,
        sell   = tonumber(r.sell) or 0,
      }
    end
  end
  return goods
end

local function record_tgoods_history(lin, goods)
  if not M._market_seam.on_tgoods then return end
  local names = {}
  for good in pairs(goods) do names[#names + 1] = good end
  table.sort(names)
  for _, good in ipairs(names) do
    local entry = goods[good]
    if entry.buy > 0 or entry.sell > 0 then
      M._market_seam.on_tgoods(lin, good, entry.buy, entry.sell)
    end
  end
end

local function record_tgoods_grid_history(grid)
  local lineages = {}
  for lin in pairs(grid) do lineages[#lineages + 1] = lin end
  table.sort(lineages)
  for _, lin in ipairs(lineages) do
    record_tgoods_history(lin, grid[lin])
  end
end

local function is_tgoods_integer(v)
  return type(v) == "number" and v == math.floor(v)
end

local function start_tgoods_stream()
  tgoods_stream.pending = {}
  tgoods_stream.seen = {}
  tgoods_stream.count = 0
  tgoods_stream.last_lin = nil
  tgoods_stream.complete = false
end

local function write_streamed_tgoods(parts, full)
  local epoch = S.herd_connection_epoch or 0
  if tgoods_stream.connection_epoch ~= epoch then
    tgoods_stream = { connection_epoch = epoch, count = 0, complete = false }
  end
  local lin = parts.lin
  local supplied_expected = parts.lin_count
  if not is_tgoods_integer(lin) or lin < TGOODS_MIN_LIN or lin > TGOODS_MAX_LIN then
    error("TGOODS lin must be an integer from 0 to 13")
  end
  if supplied_expected ~= nil
      and (not is_tgoods_integer(supplied_expected)
           or supplied_expected < 1 or supplied_expected > TGOODS_MAX_COUNT) then
    error("TGOODS lin_count must be an integer from 1 to 14")
  end
  local goods = decode_tgoods_records(parts.goods)
  local expected = supplied_expected or tgoods_stream.expected
  if not expected then error("TGOODS lin_count is required before the first stream") end

  local fresh = full
      or supplied_expected ~= nil and supplied_expected ~= tgoods_stream.expected
      or (not tgoods_stream.pending and not tgoods_stream.complete)
      or (tgoods_stream.last_lin ~= nil and lin <= tgoods_stream.last_lin)
  if tgoods_stream.complete and not fresh then
    error("TGOODS lineage exceeds a completed cycle")
  end
  if fresh then start_tgoods_stream() end

  tgoods_stream.expected = expected
  if not tgoods_stream.seen[lin] then
    tgoods_stream.pending[lin] = goods
    tgoods_stream.seen[lin] = true
    tgoods_stream.count = tgoods_stream.count + 1
  end
  tgoods_stream.last_lin = lin

  if tgoods_stream.count == tgoods_stream.expected then
    S.trade_goods = tgoods_stream.pending
    observe.record("prices")
    record_tgoods_grid_history(S.trade_goods)
    tgoods_stream.pending = nil
    tgoods_stream.seen = nil
    tgoods_stream.count = 0
    tgoods_stream.complete = true
    tgoods_stream.last_complete_at = os.time()
  end
end

local function write_tgoods(parts, full)
  if type(parts) ~= "table" then return end
  if parts.lin ~= nil or parts.lin_count ~= nil or parts.goods ~= nil then
    write_streamed_tgoods(parts, full)
    return
  end

  -- Sorted so legacy per-lineage replacements and their history writes land
  -- in a stable order; pairs() order is unspecified.
  local keys = {}
  for key in pairs(parts) do
    if type(key) == "string" and key:match("^tgoods_%d+$") then
      keys[#keys + 1] = key
    end
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local lin = tonumber(key:match("^tgoods_(%d+)$"))
    local records = parts[key]
    if lin and type(records) == "table" then
      local goods = decode_tgoods_records(records)
      S.trade_goods[lin] = goods
      observe.record("prices")
      record_tgoods_history(lin, goods)
    end
  end
end

-- staff. `stats` is a comma-joined string in a fixed stat order on both
-- transports (the server builds one string for both -- see _v_staff), so it is
-- parsed here exactly as the MIP handler parses it, against the same
-- STAFF_STAT_ORDER. The record also carries `id` and `best_stat`, which MIP
-- never sent and nothing reads; they are ignored rather than stored.
-- staff arrives as ONE ROTATING SLICE per push, not the whole list: a full
-- roster does not fit a package's page budget, so the server walks a cursor
-- and this accumulates the slices. Slices are keyed by INDEX, so a re-sent
-- slice replaces rather than appends and the list cannot drift as staff are
-- hired or die.
--
-- The list is rebuilt from every slice seen so far, in index order, so it
-- fills in over the first few pushes and stays complete after that. A frame
-- carrying no slice at all (only the counters) leaves it alone.
local function write_staff(parts)
  if type(parts) ~= "table" then return end

  if parts.staff_total ~= nil then S.staff_total = tonumber(parts.staff_total) or 0 end
  if parts.staff_slices ~= nil then S.staff_slices = tonumber(parts.staff_slices) or 0 end

  S.staff_by_slice = S.staff_by_slice or {}
  local carried = false
  for i = 0, 7 do
    local slice = parts["staff_" .. i]
    if type(slice) == "table" then
      S.staff_by_slice[i] = slice
      carried = true
    end
  end
  if not carried then return end

  -- Drop slices past the current count: a roster that shrank must not leave a
  -- stale tail behind.
  for i in pairs(S.staff_by_slice) do
    if i >= (S.staff_slices or 0) then S.staff_by_slice[i] = nil end
  end

  S.staff_list = {}
  for i = 0, (S.staff_slices or 0) - 1 do
    for _, r in ipairs(S.staff_by_slice[i] or {}) do
      if #S.staff_list >= 80 then break end
      if type(r) == "table" then
        local stats = {}
        local si = 0
        for v in tostring(r.stats or ""):gmatch("[^,]+") do
          si = si + 1
          if STAFF_STAT_ORDER[si] then stats[STAFF_STAT_ORDER[si]] = tonumber(v) or 0 end
        end
        table.insert(S.staff_list, {
          name        = tostring(r.name or ""),
          -- `assigned` -> assigned_to, `stat` -> stat_key, `arrive` -> arrive_at.
          assigned_to = tostring(r.assigned or "0"),
          stat_key    = tostring(r.stat or ""),
          stats       = stats,
          trait       = tostring(r.trait or "0"),
          loyalty     = tonumber(r.loyalty) or 3,
          age         = tostring(r.age or "veteran"),
          arrive_at   = tonumber(r.arrive) or 0,
        })
      end
    end
  end
end

-- bonds. `a`/`b` are HIRD ids, not staff ids -- the Bonds page resolves them
-- against S.hird_by_id, which write_hird in handlers/kingdom.lua fills.
local function write_bonds(records)
  if type(records) ~= "table" then return end
  S.bonds_list = {}
  for _, r in ipairs(records) do
    if type(r) == "table" then
      table.insert(S.bonds_list, {
        id_a  = tonumber(r.a) or 0,
        id_b  = tonumber(r.b) or 0,
        ticks = tonumber(r.ticks) or 0,
        tier  = tonumber(r.tier) or 0,
      })
    end
  end
end

-- train. A single record, not a list: one member drills at a time.
local function write_train(rec)
  if type(rec) ~= "table" then return end
  S.train = {
    tier    = tonumber(rec.tier) or 0,
    name    = tostring(rec.name or ""),
    stat    = tostring(rec.stat or ""),
    trained = tonumber(rec.trained) or 0,
    secs    = tonumber(rec.secs) or 0,
  }
end

-- courier + courier_tier. MIP packed the tier and the run list into one value
-- separated by '!'; GMCP sends the tier as its own top-level key, so the two
-- are gathered back together here.
local function write_courier(parts)
  if type(parts) ~= "table" then return end
  if parts.courier_tier ~= nil then
    S.courier.tier = tonumber(parts.courier_tier) or 0
  end
  if type(parts.courier) == "table" then
    local runs = {}
    for _, r in ipairs(parts.courier) do
      if type(r) == "table" then
        table.insert(runs, {
          good      = tostring(r.good or ""),
          village   = tostring(r.village or ""),
          -- `secs` -> return_in.
          return_in = tonumber(r.secs) or 0,
          amount    = tonumber(r.amount) or 0,
          cost      = tonumber(r.cost) or 0,
          fee       = tonumber(r.fee) or 0,
        })
      end
    end
    S.courier.runs = runs
  end
end

-- spy + spy_scouts, likewise split out of MIP's one '!'-separated value. The
-- record carries a `sablin` field MIP never sent and nothing reads.
local function write_spy(parts)
  if type(parts) ~= "table" then return end
  local rec = parts.spy
  if type(rec) == "table" then
    S.spy.tier     = tonumber(rec.tier) or 0
    S.spy.mode     = tostring(rec.mode or "")
    S.spy.village  = tostring(rec.village or "")
    S.spy.secs     = tonumber(rec.secs) or 0
    -- sabpct/sabsecs/cdsecs -> sab_pct/sab_secs/cd_secs.
    S.spy.sab_pct  = tonumber(rec.sabpct) or 0
    S.spy.sab_secs = tonumber(rec.sabsecs) or 0
    S.spy.cd_secs  = tonumber(rec.cdsecs) or 0
  end
  if type(parts.spy_scouts) == "table" then
    local scouts = {}
    for _, sc in ipairs(parts.spy_scouts) do
      if type(sc) == "table" then
        -- The scout record's `name` IS the city it is watching; the client has
        -- always called that field `city`.
        table.insert(scouts, { city = tostring(sc.name or ""),
                               amb = tonumber(sc.amb) or 0,
                               secs = tonumber(sc.secs) or 0 })
      end
    end
    S.spy.scouts = scouts
  end
end

-- vfind_hall + vfind_posts + vfind_offers + vfind_auctions, MIP's four
-- '!'-separated sections. The server sends the three lists only when the hall
-- exists, so a frame with no hall carries none of them.
--
-- The offer and auction records carry more than MIP did (stat, trait, age,
-- post_id, upkeep / stat, skill, trait, age, part). Those are ignored here:
-- nothing renders them, and inventing state for them would be state with no
-- reader.
local function write_vfind(parts)
  if type(parts) ~= "table" then return end
  if type(parts.vfind_hall) == "table" then
    S.vfind.tier = tonumber(parts.vfind_hall.tier) or 0
  end
  if type(parts.vfind_posts) == "table" then
    local posts = {}
    for _, r in ipairs(parts.vfind_posts) do
      if type(r) == "table" then
        table.insert(posts, {
          id        = tonumber(r.id) or 0,
          stat      = tostring(r.stat or ""),
          min_skill = tonumber(r.min_skill) or 0,
          max_wage  = tonumber(r.max_wage) or 0,
          trait     = tostring(r.trait or ""),
          state     = tostring(r.state or ""),
        })
      end
    end
    S.vfind.postings = posts
  end
  if type(parts.vfind_offers) == "table" then
    local offers = {}
    for _, r in ipairs(parts.vfind_offers) do
      if type(r) == "table" then
        table.insert(offers, {
          id         = tonumber(r.id) or 0,
          name       = tostring(r.name or ""),
          wage       = tonumber(r.wage) or 0,
          haggles    = tonumber(r.haggles) or 0,
          -- `secs` -> expires_in.
          expires_in = tonumber(r.secs) or 0,
        })
      end
    end
    S.vfind.offers = offers
  end
  if type(parts.vfind_auctions) == "table" then
    local auctions = {}
    for _, r in ipairs(parts.vfind_auctions) do
      if type(r) == "table" then
        table.insert(auctions, {
          id        = tonumber(r.id) or 0,
          name      = tostring(r.name or ""),
          reserve   = tonumber(r.reserve) or 0,
          my_bid    = tonumber(r.my_bid) or 0,
          -- `secs` -> closes_in on this one, not expires_in.
          closes_in = tonumber(r.secs) or 0,
        })
      end
    end
    S.vfind.auctions = auctions
  end
end


-- ---------------------------------------------------------------------------
-- Guild.Trade writers
-- ---------------------------------------------------------------------------

-- Group a flattened child array by its foreign key, preserving each group's
-- `seq` order. Three Guild.Trade keys need this and so does Guild.Fleet's
-- raidlog: a record used as a container element may not hold a container, so
-- the server sends legs and grade breakdowns as their own top-level arrays
-- pointing back at their parent.
local function group_by(rows, fk)
  local out = {}
  if type(rows) ~= "table" then return out end
  for _, r in ipairs(rows) do
    if type(r) == "table" and r[fk] ~= nil then
      local key = r[fk]
      local list = out[key]
      if not list then list = {}; out[key] = list end
      list[#list + 1] = r
    end
  end
  -- Sorted by `seq` rather than trusted to arrive in order: a leg list drawn
  -- out of sequence describes a different journey, and paging can split the
  -- array. Rows with no seq keep their arrival order behind those that have
  -- one.
  for _, list in pairs(out) do
    table.sort(list, function(a, b)
      return (tonumber(a.seq) or 0) < (tonumber(b.seq) or 0)
    end)
  end
  return out
end

local function leg_records(rows)
  local legs = {}
  for _, l in ipairs(rows or {}) do
    legs[#legs + 1] = { mode = tostring(l.mode or ""), good = tostring(l.good or ""),
                        amount = tonumber(l.amount) or 0,
                        village = tostring(l.village or ""),
                        value = tonumber(l.value) or 0 }
  end
  return legs
end

-- carts + cart_legs + cart_extra. `secs` -> return_in and `half_in` ->
-- halfway_in are the renames. `cart_extra` (fk "cart") carries
-- grade/value/cur_leg split out of the main cart record: adding those 3
-- fields there pushed a cart record from 14 to 17 fields, over the
-- protocol's 16-field-per-record cap, so every active cart was silently
-- refused whole (see client.h's _v_cart_extra() comment) -- the split fixes
-- that the same way legs already avoid the container-depth limit. All three
-- are server-computed (query_quality_label, query_effective_sell_price, and
-- the dispatch/return travel-window bucket respectively) so the client shows
-- the exact same numbers vtrade.c's own text display does, rather than
-- re-deriving pricing/grade-name logic here.
--
-- DELTA-SAFE like write_lmarket: cart_legs/cart_extra rarely change once a
-- cart is dispatched (a route's legs and a sell cart's grade/value are fixed
-- at dispatch), while `carts` itself changes almost every push (its secs/
-- half_in countdowns tick every beat) -- so a typical delta after the first
-- full frame carries `carts` but OMITS cart_legs/cart_extra entirely
-- (protocol.lua's DELTA SEMANTICS: absence on a delta means unchanged, not
-- gone). Rebuilding legs/grade/value from an absent key every time silently
-- erased a route's stops and a cart's estimated value moments after they
-- first appeared -- carry the previous cart's values forward by cart_id
-- when the corresponding key is missing from THIS push, matching the old
-- S.carts entry rather than defaulting to empty.
--
-- No `full` parameter needed here, unlike write_lmarket: cart_legs/
-- cart_extra are always-emitted keys in send_gmcp_trade()'s payload (never
-- conditionally built), so their only omission mechanism is the delta
-- layer's "unchanged" compression -- there is no "key vanished on a full
-- frame with a different meaning" case to distinguish, the way a genuinely
-- variable-arity key set (lmarket_1..13) has.
local function write_carts(parts)
  if type(parts) ~= "table" then return end
  if type(parts.carts) ~= "table" then return end

  local old_by_id = {}
  for _, c in ipairs(S.carts or {}) do old_by_id[c.cart_id] = c end

  local legs_present = type(parts.cart_legs) == "table"
  local extra_present = type(parts.cart_extra) == "table"
  local legs_by_cart = legs_present and group_by(parts.cart_legs, "cart") or nil
  local extra_by_cart = extra_present and group_by(parts.cart_extra, "cart") or nil

  S.carts = {}
  for _, r in ipairs(parts.carts) do
    if #S.carts >= 30 then break end
    if type(r) == "table" then
      local cart_id = tonumber(r.cart_id) or 0
      local old = old_by_id[cart_id]
      local refit = tostring(r.refit or "")
      if refit == "" then refit = "standard" end

      local legs
      if legs_present then
        legs = leg_records(legs_by_cart[cart_id])
      elseif old then
        legs = old.legs
      else
        legs = {}
      end

      local grade, value, cur_leg
      if extra_present then
        local extra = (extra_by_cart[cart_id] or {})[1] or {}
        grade, value, cur_leg = tostring(extra.grade or ""), tonumber(extra.value) or 0, tonumber(extra.cur_leg) or -1
      elseif old then
        grade, value, cur_leg = old.grade, old.value, old.cur_leg
      else
        grade, value, cur_leg = "", 0, -1
      end

      table.insert(S.carts, {
        mode        = tostring(r.mode or ""),
        good        = tostring(r.good or ""),
        village     = tostring(r.village or ""),
        return_in   = tonumber(r.secs) or 0,
        amount      = tonumber(r.amount) or 0,
        halfway_in  = tonumber(r.half_in) or 0,
        quality_pct = tonumber(r.quality_pct) or 100,
        grade       = grade,
        value       = value,
        cur_leg     = cur_leg,
        cart_id     = cart_id,
        tier        = tonumber(r.tier) or 1,
        durability  = tonumber(r.durability) or 100,
        cap         = tonumber(r.cap) or 0,
        escort      = tonumber(r.escort) or 0,
        horses      = tonumber(r.horses) or 0,
        refit       = refit,
        legs        = legs,
      })
    end
  end
end

-- queue + queue_legs. A queued job's displayed mode/good/amount/village are
-- its FIRST leg's -- MIP had no other way to express it and the pages read it
-- that way -- so a job whose legs did not arrive has nothing to show and is
-- skipped, exactly as the MIP handler skipped a job that parsed no legs.
local function write_queue(parts)
  if type(parts) ~= "table" then return end
  if type(parts.queue) ~= "table" then return end
  local legs_by_job = group_by(parts.queue_legs, "job")
  S.trade_queue = {}
  for _, r in ipairs(parts.queue) do
    if type(r) == "table" then
      local legs = leg_records(legs_by_job[r.job])
      if #legs > 0 then
        table.insert(S.trade_queue, {
          mode = legs[1].mode, good = legs[1].good,
          amount = legs[1].amount, village = legs[1].village,
          escort = tonumber(r.escort) or 0,
          legs = legs,
        })
      end
    end
  end
end

-- cidle. `slot` is the cart id; MIP called the same number `cid`. `horses` is
-- again carried and unread.
local function write_cidle(records)
  if type(records) ~= "table" then return end
  S.idle_carts = {}
  for _, r in ipairs(records) do
    if type(r) == "table" then
      local refit = tostring(r.refit or "")
      if refit == "" then refit = "standard" end
      table.insert(S.idle_carts, {
        cart_id    = tonumber(r.slot) or 0,
        tier       = tonumber(r.tier) or 1,
        durability = tonumber(r.durability) or 100,
        cap        = tonumber(r.cap) or 0,
        refit      = refit,
      })
    end
  end
end

-- cupg. Five renames in one record: cart -> cart_id, tier -> target_tier,
-- secs -> secs_left, mats -> mats_total, done -> mats_done. `detail` is the
-- same comma-joined "good:done/need" string SUPG uses.
local function write_cupg(records)
  if type(records) ~= "table" then return end
  S.cart_upgrades = {}
  for _, r in ipairs(records) do
    if type(r) == "table" then
      local mats = {}
      for piece in tostring(r.detail or ""):gmatch("[^,]+") do
        local g, d, n = piece:match("^([^:]+):(%d+)/(%d+)$")
        if g then
          table.insert(mats, { good = g, done = tonumber(d) or 0, need = tonumber(n) or 0 })
        end
      end
      local target_refit = tostring(r.refit or "")
      local job_type = tostring(r.job_type or "")
      -- MIP inferred the job type from whether a target refit was named, for
      -- servers that predate the explicit field. Kept: the field can still be
      -- empty on a record.
      if job_type == "" then
        job_type = (target_refit ~= "" and "refit" or "upgrade")
      end
      table.insert(S.cart_upgrades, {
        cart_id      = tonumber(r.cart) or 0,
        target_tier  = tonumber(r.tier) or 2,
        secs_left    = tonumber(r.secs) or 0,
        mats_total   = tonumber(r.mats) or 0,
        mats_done    = tonumber(r.done) or 0,
        target_refit = target_refit,
        job_type     = job_type,
        mats         = mats,
      })
    end
  end
end

-- routes. Keyed by village id, which the record calls `village`; the id is the
-- key rather than a field, as it was over MIP.
local function write_routes(records)
  if type(records) ~= "table" then return end
  S.routes = {}
  for _, r in ipairs(records) do
    if type(r) == "table" and r.village ~= nil then
      local vid = tostring(r.village)
      S.routes[vid] = {
        name       = tostring(r.name or vid),
        road_tier  = tonumber(r.road_tier) or 0,
        fort_tier  = tonumber(r.fort_tier) or 0,
        road_maint = tonumber(r.road_maint) or 0,
        fort_maint = tonumber(r.fort_maint) or 0,
        road_name  = tostring(r.road_name or ""),
        fort_name  = tostring(r.fort_name or ""),
      }
    end
  end
end

-- blocks. An array of records over the wire, a good -> amount lookup in state.
local function write_blocks(records)
  if type(records) ~= "table" then return end
  S.blocks = {}
  for _, r in ipairs(records) do
    if type(r) == "table" and r.good ~= nil then
      S.blocks[tostring(r.good)] = tonumber(r.amount) or 0
    end
  end
end

-- refinery + refinery_grades, foreign-keyed by `bldg`. The building id is
-- `bldg` on both halves and `id` in state.
-- refinery and refinery_grades are two halves of one composite, and the
-- protocol layer only re-sends a key that CHANGED. Refinery stock moves every
-- tick; the grade rows change far less often -- so the overwhelmingly common
-- delta carries `refinery` alone. Rebuilding the grade list from a nil
-- `refinery_grades` wiped every grade row on that frame, which is why the
-- Refineries section collapsed to bare "name [stock / cap]" lines within a
-- tick of the last full push.
--
-- MIP hid this: it had no delta cache and re-sent the whole REFINERY string,
-- grades included, on every push. The bug arrived with the GMCP migration and
-- only became visible once MIP stopped covering for it.
--
-- So a missing half means "unchanged", not "gone": carry the grades already in
-- state across. Same shape as write_wstock's `wstock_cap` presence test.
local function write_refinery(parts)
  if type(parts) ~= "table" then return end
  if type(parts.refinery) ~= "table" then return end
  local carried_grades = type(parts.refinery_grades) == "table"
  local grades_by_bldg = group_by(parts.refinery_grades, "bldg")
  local previous = {}
  if not carried_grades then
    for _, r in ipairs(S.refineries or {}) do previous[r.id] = r.grades end
  end
  S.refineries = {}
  for _, r in ipairs(parts.refinery) do
    if type(r) == "table" then
      local grades
      if carried_grades then
        grades = {}
        for _, g in ipairs(grades_by_bldg[r.bldg] or {}) do
          grades[#grades + 1] = { name = tostring(g.grade or ""),
                                  qty = tonumber(g.qty) or 0,
                                  pct = tonumber(g.pct) or 100 }
        end
      else
        grades = previous[tostring(r.bldg or "")] or {}
      end
      S.refineries[#S.refineries + 1] = {
        id    = tostring(r.bldg or ""),
        tier  = tonumber(r.tier) or 0,
        stock = tonumber(r.stock) or 0,
        cap   = tonumber(r.cap) or 0,
        grades = grades,
      }
    end
  end
end

-- market. `remain` -> remaining, `age` -> age_secs. The seam call is what
-- market.lua hangs price recording off, so it fires on this path too.
local function write_market(records)
  if type(records) ~= "table" then return end
  S.market_orders = {}
  for _, r in ipairs(records) do
    if type(r) == "table" then
      table.insert(S.market_orders, {
        id        = tonumber(r.id) or 0,
        buyer     = tostring(r.buyer or ""),
        good      = tostring(r.good or ""),
        remaining = tonumber(r.remain) or 0,
        price     = tonumber(r.price) or 0,
        age_secs  = tonumber(r.age) or 0,
      })
    end
  end
  if M._market_seam.on_market then M._market_seam.on_market(S.market_orders) end
end

-- incoming. `secs` -> arrives_in.
local function write_incoming(records)
  if type(records) ~= "table" then return end
  S.incoming_fills = {}
  for _, r in ipairs(records) do
    if type(r) == "table" then
      table.insert(S.incoming_fills, {
        good       = tostring(r.good or ""),
        amount     = tonumber(r.amount) or 0,
        arrives_in = tonumber(r.secs) or 0,
        seller     = tostring(r.seller or ""),
      })
    end
  end
end

-- wstock + wstock_cap. The server splits its one mapping into the entry array
-- and its cap -- LEGACY's own WSTOCK handler (guild_viking.lua:1491-1494)
-- stores this same value as state.wh_cap ("incl. steward/lager/star bonuses
-- from query_warehouse_capacity()"), which pages/city.lua prefers over its
-- static per-tier table for exactly that reason. `pct` -> freshness_pct, and
-- an empty grade label stays nil so the pages can test it for presence.
local function write_wstock(parts)
  if type(parts) ~= "table" then return end
  -- The cap is written BEFORE the entry-list guard below, and only when this
  -- frame actually carried it. A composite writer is invoked with whichever
  -- halves the frame had (protocol.lua:58-63), so a delta carrying only
  -- `wstock_cap` is normal -- and returning early on a missing entry list
  -- discarded it, leaving S.wh_cap nil so pages/city.lua and autotrader fell
  -- back to their static per-tier tables. Those hold the pre-2024 base
  -- capacity, so a T5 warehouse displayed 5250 instead of the real
  -- query_warehouse_capacity() figure (9056 with steward/lager/star bonuses).
  -- Testing for presence rather than assigning unconditionally also stops an
  -- entries-only delta from nil-ing out a cap that had already arrived.
  if parts.wstock_cap ~= nil then
    S.wh_cap = tonumber(parts.wstock_cap)
  end
  if type(parts.wstock) ~= "table" then return end
  S.wstock = {}
  S.wstock_by_good = {}
  for _, r in ipairs(parts.wstock) do
    if #S.wstock >= 50 then break end
    if type(r) == "table" and r.good ~= nil then
      local grade = r.grade ~= nil and tostring(r.grade) or ""
      local rec = {
        good          = tostring(r.good),
        amount        = tonumber(r.amount) or 0,
        freshness_pct = tonumber(r.pct) or 100,
        grade         = (grade ~= "") and grade or nil,
      }
      table.insert(S.wstock, rec)
      S.wstock_by_good[rec.good] = rec
    end
  end
end

-- ---------------------------------------------------------------------------
-- Guild.City writers that live here, beside their MIP twins
-- ---------------------------------------------------------------------------

-- rbuild. Roads and forts under construction, keyed "kind:vid" for the Trade
-- Routes render -- the key is built here, as it was over MIP, rather than
-- being a field. `vname` -> name, `mats`/`done` -> mats_total/mats_done,
-- `secs` -> complete_at_secs (-1 awaiting materials, 0 finalizing), `total` ->
-- total_build_secs.
local function write_rbuild(records)
  if type(records) ~= "table" then return end
  S.route_builds = {}
  for _, r in ipairs(records) do
    if type(r) == "table" and r.vid ~= nil and r.kind ~= nil then
      local mats = {}
      for piece in tostring(r.detail or ""):gmatch("[^,]+") do
        local good, done, need = piece:match("^([^:]+):(%d+)/(%d+)$")
        if good then
          table.insert(mats, { good = good, done = tonumber(done) or 0,
                               need = tonumber(need) or 0 })
        end
      end
      local vid = tostring(r.vid)
      local kind = tostring(r.kind)
      S.route_builds[kind .. ":" .. vid] = {
        vid = vid, name = tostring(r.vname or vid), kind = kind,
        tier = tonumber(r.tier) or 1,
        mats_total = tonumber(r.mats) or 0,
        mats_done = tonumber(r.done) or 0,
        complete_at_secs = tonumber(r.secs) or -1,
        total_build_secs = tonumber(r.total) or 0,
        mats = mats,
      }
    end
  end
end

-- upkeep. A per-tick daler breakdown; field names already match.
local function write_upkeep(rec)
  if type(rec) ~= "table" then return end
  S.upkeep = {
    roster    = tonumber(rec.roster) or 0,
    community = tonumber(rec.community) or 0,
    throne    = tonumber(rec.throne) or 0,
    roads     = tonumber(rec.roads) or 0,
    forts     = tonumber(rec.forts) or 0,
    total     = tonumber(rec.total) or 0,
  }
end

local function write_rupkeep(v)
  S.route_upkeep = tonumber(v) or 0
end

-- heat. A bare array of numbers on both transports.
local function write_heat(values)
  if type(values) ~= "table" then return end
  S.heat = {}
  for _, v in ipairs(values) do S.heat[#S.heat + 1] = tonumber(v) or 0 end
end

-- Guild.State: banked daler. Its MIP twin lives here, so its writer does too.
local function write_daler(v)
  S.daler = tonumber(v) or 0
  observe.record("daler")
end

M._gmcp = {
  STAFF    = write_staff,
  BONDS    = write_bonds,
  TRAIN    = write_train,
  COURIER  = write_courier,
  SPY      = write_spy,
  VFIND    = write_vfind,
  CARTS    = write_carts,
  TQUEUE   = write_queue,
  CIDLE    = write_cidle,
  CUPG     = write_cupg,
  ROUTES   = write_routes,
  BLOCKS   = write_blocks,
  REFINERY = write_refinery,
  MARKET   = write_market,
  INCOMING = write_incoming,
  WSTOCK   = write_wstock,
  RBUILD   = write_rbuild,
  UPKEEP   = write_upkeep,
  RUPKEEP  = write_rupkeep,
  HEAT     = write_heat,
  DALER    = write_daler,
  TGOODS   = write_tgoods,
}

-- init.register_handlers enumerates every non-reserved field as a MIP key;
-- an underscore alone is NOT reserved. Keep this read-only API lookup-only.
return setmetatable(M, { __index = function(_, key)
  if key == "_tgoods_status" then return tgoods_status end
end })
