-- guild_viking Guild.Trade writers unit tests. Run from the lera-plugins repo
-- root with LERA_ROOT pointing at a built Lera checkout.
--
-- Expected values are written out literally rather than derived by calling the
-- decoder, and each names the state field its consumer reads.
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

ui = { dirty = function() end }
lera = { time = function() return 1000 end }
buffer = { color_print = function() end }

local protocol = require("protocol")
-- init.lua's RESERVED set: the module-level convention fields, not MIP keys.
local RESERVED_KEYS = { _market_seam = true, _patterns = true, _gmcp = true,
                        _retired_keys = true, _retired_patterns = true }
local S = require("state").S
local market = require("market")

local RESERVED = RESERVED_KEYS
local trade_mod
for _, name in ipairs({ "handlers.trade", "handlers.kingdom", "handlers.voyage",
                        "handlers.city" }) do
  local mod = require(name)
  if name == "handlers.trade" then trade_mod = mod end
  for key, fn in pairs(mod._gmcp or {}) do
    protocol.gmcp_handler(key, fn)
  end
end

local function trade(payload)
  payload.guild = "viking"
  protocol.on_gmcp("Guild.Trade", payload)
end

-- ---- carts + cart_legs -----------------------------------------------------
-- A cart's legs are a container, which a record used as a container element
-- may not hold, so they travel as their own array foreign-keyed by `cart`.
-- The legs below are deliberately supplied out of order and interleaved
-- between two carts: a writer that trusted arrival order would build the
-- wrong journey.
trade({
  carts = {
    { mode = "sell", good = "timber", village = "Havn", secs = 240, amount = 30,
      half_in = 120, quality_pct = 85, cart_id = 4, tier = 2, durability = 70,
      cap = 50, escort = 2, refit = "reinforced", horses = 3 },
    { mode = "buy", good = "iron", village = "Birka", cart_id = 9 },
  },
  cart_legs = {
    { cart = 9, seq = 1, mode = "buy", good = "iron", amount = 10, village = "Birka", value = 500 },
    { cart = 4, seq = 2, mode = "sell", good = "mead", amount = 5, village = "Jorvik", value = 900 },
    { cart = 4, seq = 1, mode = "sell", good = "timber", amount = 30, village = "Havn", value = 1500 },
  },
  -- Split from `carts` itself (see write_carts's comment): a 17-field cart
  -- record would exceed the protocol's 16-field-per-record cap.
  cart_extra = {
    { cart = 4, grade = "well-aged", value = 4200, cur_leg = -1 },
  },
})
check("carts count", #S.carts == 2, #S.carts)
local c = S.carts[1]
check("carts secs lands on return_in", c.return_in == 240, c.return_in)
check("carts half_in lands on halfway_in", c.halfway_in == 120, c.halfway_in)
check("carts scalar fields", c.mode == "sell" and c.good == "timber"
      and c.village == "Havn" and c.amount == 30 and c.quality_pct == 85
      and c.cart_id == 4 and c.tier == 2 and c.durability == 70 and c.cap == 50
      and c.escort == 2 and c.refit == "reinforced")
check("carts horses/grade/value/cur_leg", c.horses == 3 and c.grade == "well-aged"
      and c.value == 4200 and c.cur_leg == -1)
check("cart legs group on their own cart, ordered by seq",
      #c.legs == 2 and c.legs[1].good == "timber" and c.legs[1].amount == 30
      and c.legs[2].good == "mead" and c.legs[2].village == "Jorvik"
      and #S.carts[2].legs == 1 and S.carts[2].legs[1].good == "iron",
      #c.legs .. "/" .. tostring((c.legs[1] or {}).good))
check("cart leg value", c.legs[1].value == 1500 and c.legs[2].value == 900
      and S.carts[2].legs[1].value == 500)
check("carts defaults", S.carts[2].tier == 1 and S.carts[2].durability == 100
      and S.carts[2].quality_pct == 100 and S.carts[2].refit == "standard"
      and S.carts[2].return_in == 0 and S.carts[2].horses == 0
      and S.carts[2].grade == "" and S.carts[2].value == 0 and S.carts[2].cur_leg == -1)

-- A delta push resending only `carts` (secs ticked down) with cart_legs/
-- cart_extra OMITTED (protocol.lua: absence on a delta means unchanged, not
-- gone) must NOT wipe the route/grade/value data that arrived in the
-- previous full push -- this is exactly the bug that made a route cart's
-- stops and a sell cart's grade/value vanish moments after first appearing.
trade({
  carts = {
    { mode = "sell", good = "timber", village = "Havn", secs = 239, amount = 30,
      half_in = 119, quality_pct = 85, cart_id = 4, tier = 2, durability = 70,
      cap = 50, escort = 2, refit = "reinforced", horses = 3 },
    { mode = "buy", good = "iron", village = "Birka", cart_id = 9 },
  },
})
check("a carts-only delta preserves the cart's own new fields",
      S.carts[1].return_in == 239 and S.carts[1].halfway_in == 119)
check("a carts-only delta preserves previously-known legs (not wiped)",
      #S.carts[1].legs == 2 and S.carts[1].legs[1].good == "timber"
      and #S.carts[2].legs == 1 and S.carts[2].legs[1].good == "iron")
check("a carts-only delta preserves previously-known grade/value/cur_leg",
      S.carts[1].grade == "well-aged" and S.carts[1].value == 4200
      and S.carts[1].cur_leg == -1)

local many = {}
for i = 1, 40 do many[i] = { mode = "sell", cart_id = i } end
trade({ carts = many })
check("carts cap at 30", #S.carts == 30, #S.carts)

-- ---- queue + queue_legs ----------------------------------------------------
-- A queued job shows its FIRST leg's mode/good/amount/village; that is how MIP
-- expressed it and how the pages read it. Ordering the legs by seq is what
-- decides which leg is first.
trade({
  queue = { { job = 1, escort = 3 }, { job = 2, escort = 0 } },
  queue_legs = {
    { job = 1, seq = 2, mode = "sell", good = "fur", amount = 8, village = "Birka" },
    { job = 2, seq = 1, mode = "buy", good = "salt", amount = 4, village = "Havn" },
    { job = 1, seq = 1, mode = "buy", good = "timber", amount = 20, village = "Jorvik" },
  },
})
check("queue count", #S.trade_queue == 2, #S.trade_queue)
check("a job displays its first leg by seq, not by arrival",
      S.trade_queue[1].good == "timber" and S.trade_queue[1].mode == "buy"
      and S.trade_queue[1].amount == 20 and S.trade_queue[1].village == "Jorvik",
      S.trade_queue[1].good)
check("job escort", S.trade_queue[1].escort == 3 and S.trade_queue[2].escort == 0)
check("job legs kept in seq order", #S.trade_queue[1].legs == 2
      and S.trade_queue[1].legs[2].good == "fur")
-- A job with no legs has nothing to display, exactly as over MIP.
trade({ queue = { { job = 7, escort = 1 } }, queue_legs = {} })
check("a job with no legs is skipped", #S.trade_queue == 0, #S.trade_queue)

-- ---- cidle -----------------------------------------------------------------
-- The idle-cart record calls the cart id `slot`.
trade({ cidle = { { slot = 12, tier = 3, durability = 55, cap = 80,
                    refit = "insulated", horses = 2 } } })
check("cidle slot lands on cart_id", S.idle_carts[1].cart_id == 12)
check("cidle fields", S.idle_carts[1].tier == 3
      and S.idle_carts[1].durability == 55 and S.idle_carts[1].cap == 80
      and S.idle_carts[1].refit == "insulated")
trade({ cidle = { { slot = 1 } } })
check("cidle defaults", S.idle_carts[1].tier == 1
      and S.idle_carts[1].durability == 100 and S.idle_carts[1].refit == "standard")

-- ---- cupg ------------------------------------------------------------------
-- Five renames in one record, all carrying integers.
trade({ cupg = { { cart = 4, tier = 3, secs = 600, mats = 50, done = 20,
                   detail = "timber:10/25,iron:10/25", refit = "reinforced",
                   job_type = "refit" } } })
local u = S.cart_upgrades[1]
check("cupg cart lands on cart_id", u.cart_id == 4, u.cart_id)
check("cupg tier lands on target_tier", u.target_tier == 3, u.target_tier)
check("cupg secs lands on secs_left", u.secs_left == 600, u.secs_left)
check("cupg mats lands on mats_total", u.mats_total == 50, u.mats_total)
check("cupg done lands on mats_done", u.mats_done == 20, u.mats_done)
check("cupg refit lands on target_refit and job_type is carried",
      u.target_refit == "reinforced" and u.job_type == "refit")
check("cupg detail parses into per-good rows", #u.mats == 2
      and u.mats[1].good == "timber" and u.mats[1].done == 10
      and u.mats[1].need == 25)
-- The explicit job_type can still be empty, and MIP inferred it from whether a
-- target refit was named. Both branches are kept.
trade({ cupg = { { cart = 5, refit = "reinforced" } } })
check("an empty job_type with a refit infers 'refit'",
      S.cart_upgrades[1].job_type == "refit")
trade({ cupg = { { cart = 5 } } })
check("an empty job_type with no refit infers 'upgrade'",
      S.cart_upgrades[1].job_type == "upgrade" and S.cart_upgrades[1].target_tier == 2)

-- ---- routes ----------------------------------------------------------------
-- Keyed by village id, which the record calls `village`; the id is the table
-- key rather than a field.
trade({ routes = { { village = "havn", name = "Havn", road_tier = 2,
                     fort_tier = 1, road_maint = 30, fort_maint = 40,
                     road_name = "Coast Road", fort_name = "Havn Watch" } } })
check("routes are keyed by village id", S.routes.havn ~= nil)
check("route fields", S.routes.havn.name == "Havn"
      and S.routes.havn.road_tier == 2 and S.routes.havn.fort_tier == 1
      and S.routes.havn.road_maint == 30 and S.routes.havn.fort_maint == 40
      and S.routes.havn.road_name == "Coast Road"
      and S.routes.havn.fort_name == "Havn Watch")
trade({ routes = { { village = "birka" } } })
check("a route with no name falls back to its id",
      S.routes.birka.name == "birka" and S.routes.havn == nil)

-- ---- blocks ----------------------------------------------------------------
-- An array of records over the wire, a good -> amount lookup in state.
trade({ blocks = { { good = "timber", amount = 40 }, { good = "iron", amount = 5 } } })
check("blocks become a good -> amount lookup",
      S.blocks.timber == 40 and S.blocks.iron == 5)

-- ---- refinery + refinery_grades --------------------------------------------
-- Foreign-keyed by `bldg`, and the building id is `id` in state.
trade({
  refinery = { { bldg = "smelter", tier = 2, stock = 60, cap = 100 },
               { bldg = "bakehouse", tier = 1, stock = 10, cap = 40 } },
  refinery_grades = {
    { bldg = "bakehouse", grade = "coarse", qty = 4, pct = 60 },
    { bldg = "smelter", grade = "fine", qty = 20, pct = 90 },
    { bldg = "smelter", grade = "crude", qty = 15, pct = 40 },
  },
})
check("refinery count", #S.refineries == 2, #S.refineries)
check("refinery bldg lands on id", S.refineries[1].id == "smelter")
check("refinery fields", S.refineries[1].tier == 2 and S.refineries[1].stock == 60
      and S.refineries[1].cap == 100)
check("grades group on their own building",
      #S.refineries[1].grades == 2 and S.refineries[1].grades[1].name == "fine"
      and S.refineries[1].grades[1].qty == 20
      and S.refineries[1].grades[1].pct == 90
      and #S.refineries[2].grades == 1
      and S.refineries[2].grades[1].name == "coarse",
      #S.refineries[1].grades .. "/" .. #S.refineries[2].grades)

-- ---- market ----------------------------------------------------------------
-- The seam is what market.lua hangs its price recording off, so it has to fire
-- on this path too.
local seam_calls = 0
trade_mod._market_seam.on_market = function() seam_calls = seam_calls + 1 end
trade({ market = { { id = 3, buyer = "Sven", good = "mead", remain = 12,
                     price = 40, age = 90 } } })
check("market remain lands on remaining", S.market_orders[1].remaining == 12)
check("market age lands on age_secs", S.market_orders[1].age_secs == 90)
check("market fields", S.market_orders[1].id == 3
      and S.market_orders[1].buyer == "Sven" and S.market_orders[1].good == "mead"
      and S.market_orders[1].price == 40)
check("the market seam fires on the GMCP path", seam_calls == 1, seam_calls)
trade_mod._market_seam.on_market = nil

-- ---- incoming --------------------------------------------------------------
trade({ incoming = { { good = "grain", amount = 25, secs = 180, seller = "Astrid" } } })
check("incoming secs lands on arrives_in", S.incoming_fills[1].arrives_in == 180)
check("incoming fields", S.incoming_fills[1].good == "grain"
      and S.incoming_fills[1].amount == 25
      and S.incoming_fills[1].seller == "Astrid")

-- ---- wstock + wstock_cap ---------------------------------------------------
trade({
  wstock_cap = 500,
  wstock = { { good = "timber", amount = 120, pct = 95 },
             { good = "mead", amount = 40, pct = 60, grade = "fine" },
             { good = "iron", amount = 10, pct = 100, grade = "" } },
})
check("wstock pct lands on freshness_pct",
      S.wstock[1].freshness_pct == 95 and S.wstock[1].good == "timber"
      and S.wstock[1].amount == 120)
check("wstock is also indexed by good",
      S.wstock_by_good.mead == S.wstock[2] and S.wstock_by_good.timber.amount == 120)
check("wstock_cap lands on S.wh_cap", S.wh_cap == 500, S.wh_cap)
-- The pages test the grade for presence, so an absent or empty label must be
-- nil rather than the empty string.
check("an absent or empty grade stays nil",
      S.wstock[1].grade == nil and S.wstock[2].grade == "fine"
      and S.wstock[3].grade == nil)
local wmany = {}
for i = 1, 60 do wmany[i] = { good = "g" .. i, amount = i } end
trade({ wstock = wmany })
check("wstock cap at 50", #S.wstock == 50, #S.wstock)

-- ---- Guild.TradeGoods -------------------------------------------------------
-- The price/demand matrix arrives as one key per lineage rather than one
-- array. That split is the server's and it is not cosmetic: the flat list runs
-- to about 420 records, and a container over PROTOCOL_GUILD_NEST_MAX (128) is
-- refused whole during validation and the key dropped with no error and no
-- partial data.
local seam_goods = {}
trade_mod._market_seam.on_tgoods = function(lin, good, buy, sell)
  seam_goods[#seam_goods + 1] = { lin = lin, good = good, buy = buy, sell = sell }
end

local function tradegoods(payload)
  payload.guild = "viking"
  protocol.on_gmcp("Guild.TradeGoods", payload)
end

local function tgoods_errors()
  return protocol.gmcp_stats().errors.TGOODS or 0
end

local function streamed_timber(lin)
  return S.trade_goods[lin] and S.trade_goods[lin].timber
end

-- Current servers stream one lineage per frame. Keep the last committed grid
-- hidden until the complete cycle is present, so auto-trading never observes
-- a partial or mixed generation.
local sentinel = { [9] = { sentinel = { buy = 99, sell = 99 } } }
S.trade_goods = sentinel
local before_errors = tgoods_errors()
tradegoods({ lin = 0, goods = { { good = "t", score = -1, sup = 100,
                                  dem = 0, buy = 10, sell = 0 } } })
check("a stream without an established lineage count leaves the grid committed",
      S.trade_goods == sentinel)
check("a stream without an established lineage count records TGOODS once",
      tgoods_errors() == before_errors + 1, tgoods_errors())

local before_unknown = protocol.gmcp_stats().unknown
local unknown_lin = before_unknown.lin or 0
local unknown_lin_count = before_unknown.lin_count or 0
local unknown_goods = before_unknown.goods or 0
tradegoods({ lin = 0, lin_count = 2,
             goods = { { good = "t", score = -1, sup = 100, dem = 0,
                         buy = 10, sell = 0 } } })
check("an incomplete streamed cycle leaves the committed grid untouched",
      S.trade_goods == sentinel and S.trade_goods[0] == nil)
check("the tgoods seam waits for a streamed commit", #seam_goods == 0, #seam_goods)
tradegoods({ lin = 1,
             goods = { { good = "t", score = 2, sup = 0, dem = 100,
                         buy = 0, sell = 50 } } })
check("a complete streamed cycle atomically replaces the committed grid",
      S.trade_goods ~= sentinel and S.trade_goods[9] == nil
      and streamed_timber(0) ~= nil and streamed_timber(1) ~= nil)
check("streamed tgoods maps supply demand buy and sell",
      streamed_timber(0) and streamed_timber(1)
      and streamed_timber(0).supply == 100 and streamed_timber(0).demand == 0
      and streamed_timber(0).buy == 10 and streamed_timber(0).sell == 0
      and streamed_timber(1).supply == 0 and streamed_timber(1).demand == 100
      and streamed_timber(1).buy == 0 and streamed_timber(1).sell == 50)
local after_unknown = protocol.gmcp_stats().unknown
check("stream envelope fields are not counted unknown",
      (after_unknown.lin or 0) == unknown_lin
      and (after_unknown.lin_count or 0) == unknown_lin_count
      and (after_unknown.goods or 0) == unknown_goods)
check("the tgoods seam fires only after a streamed commit",
      #seam_goods == 2 and seam_goods[1].lin == 0 and seam_goods[2].lin == 1,
      #seam_goods)
local movers = market.compute_market_movers()
check("the committed streamed grid produces one timber market mover",
      #movers == 1 and movers[1].good == "timber"
      and movers[1].buy_lin == 0 and movers[1].sell_lin == 1, #movers)

tradegoods({ lin = 0,
             goods = { { good = "t", score = -1, sup = 100, dem = 0,
                         buy = 12, sell = 0 } } })
check("a delta-count next cycle stays pending until complete",
      streamed_timber(0) and streamed_timber(0).buy == 10)
tradegoods({ lin = 1,
             goods = { { good = "t", score = 2, sup = 0, dem = 100,
                         buy = 0, sell = 55 } } })
check("a delta-count next cycle retains expected lineage count",
      streamed_timber(0) and streamed_timber(1)
      and streamed_timber(0).buy == 12 and streamed_timber(1).sell == 55)

-- A non-increasing lineage starts a new generation and abandons stale pending
-- rows, even when the count itself was delta-suppressed.
tradegoods({ lin = 0, lin_count = 3,
             goods = { { good = "t", score = -1, sup = 101, dem = 0,
                         buy = 20, sell = 0 } } })
tradegoods({ lin = 1,
             goods = { { good = "t", score = 2, sup = 0, dem = 101,
                         buy = 0, sell = 60 } } })
tradegoods({ lin = 0,
             goods = { { good = "t", score = -1, sup = 102, dem = 0,
                         buy = 30, sell = 0 } } })
tradegoods({ lin = 1,
             goods = { { good = "t", score = 2, sup = 0, dem = 102,
                         buy = 0, sell = 70 } } })
tradegoods({ lin = 2,
             goods = { { good = "t", score = 0, sup = 102, dem = 102,
                         buy = 31, sell = 71 } } })
check("a non-increasing lineage restarts instead of mixing pending generations",
      streamed_timber(0) and streamed_timber(1) and streamed_timber(2)
      and streamed_timber(0).buy == 30 and streamed_timber(1).sell == 70
      and streamed_timber(2).buy == 31 and streamed_timber(2).sell == 71)

tradegoods({ lin = 0,
             goods = { { good = "t", score = -1, sup = 103, dem = 0,
                         buy = 40, sell = 0 } } })
tradegoods({ lin = 1,
             goods = { { good = "t", score = 2, sup = 0, dem = 103,
                         buy = 0, sell = 80 } } })
tradegoods({ full = 1, lin = 2, lin_count = 3,
             goods = { { good = "t", score = -1, sup = 104, dem = 0,
                         buy = 50, sell = 0 } } })
tradegoods({ lin = 3,
             goods = { { good = "t", score = 2, sup = 0, dem = 104,
                         buy = 0, sell = 90 } } })
tradegoods({ lin = 4,
             goods = { { good = "t", score = 0, sup = 104, dem = 104,
                         buy = 51, sell = 91 } } })
check("full starts a fresh streamed cycle even above the interrupted lineage",
      S.trade_goods[0] == nil and S.trade_goods[1] == nil
      and streamed_timber(2) and streamed_timber(3) and streamed_timber(4)
      and streamed_timber(2).buy == 50 and streamed_timber(3).sell == 90
      and streamed_timber(4).buy == 51 and streamed_timber(4).sell == 91)

tradegoods({ lin = 0, lin_count = 2,
             goods = { { good = "t", score = -1, sup = 105, dem = 0,
                         buy = 60, sell = 0 } } })
tradegoods({ lin = 1,
             goods = { { good = "t", score = 2, sup = 0, dem = 105,
                         buy = 0, sell = 100 } } })
local committed = S.trade_goods
before_errors = tgoods_errors()
tradegoods({ lin = 2,
             goods = { { good = "t", score = 0, sup = 105, dem = 105,
                         buy = 61, sell = 101 } } })
check("a higher lineage after completion is excess and leaves the grid committed",
      tgoods_errors() == before_errors + 1 and S.trade_goods == committed
      and S.trade_goods[2] == nil, tgoods_errors())

local function invalid_tgoods(name, payload)
  local grid, errors = S.trade_goods, tgoods_errors()
  tradegoods(payload)
  check(name, tgoods_errors() == errors + 1 and S.trade_goods == grid,
        tgoods_errors())
end
invalid_tgoods("an out-of-range streamed lineage is rejected", {
  lin = 14, goods = {},
})
invalid_tgoods("a non-integer streamed lineage count is rejected", {
  lin = 0, lin_count = 1.5, goods = {},
})
invalid_tgoods("an out-of-range streamed lineage count is rejected", {
  lin = 0, lin_count = 15, goods = {},
})
invalid_tgoods("non-table streamed goods are rejected", {
  lin = 0, goods = "not-a-table",
})

-- Legacy servers use a per-lineage key shape. Its replacement semantics are
-- deliberately separate from streamed atomic snapshots.
seam_goods = {}
S.trade_goods = {}
tradegoods({
  tgoods_2 = { { lin = 2, good = "o", score = 1, sup = 0, dem = 1000,
                 buy = 0, sell = 100 },
               { lin = 2, good = "t", score = -1, sup = 500, dem = 0,
                 buy = 12, sell = 0 } },
  tgoods_5 = { { lin = 5, good = "zz", score = 0, sup = 1, dem = 2,
                 buy = 3, sell = 4 } },
})
-- The one-character abbreviation resolves to the name the pages index by.
check("tgoods abbreviations resolve to good names",
      S.trade_goods[2] ~= nil and S.trade_goods[2].ore ~= nil
      and S.trade_goods[2].timber ~= nil, "ore/timber missing")
check("tgoods sup/dem land on supply/demand",
      S.trade_goods[2].ore.supply == 0 and S.trade_goods[2].ore.demand == 1000
      and S.trade_goods[2].timber.supply == 500)
check("tgoods scalar fields", S.trade_goods[2].ore.score == 1
      and S.trade_goods[2].ore.sell == 100 and S.trade_goods[2].ore.buy == 0
      and S.trade_goods[2].timber.buy == 12)
check("a lineage key becomes its own numeric index",
      S.trade_goods[5] ~= nil and S.trade_goods[5].zz ~= nil)

-- An abbreviation with no entry in the table stays as itself rather than
-- becoming nil and dropping the good.
check("an unknown abbreviation is kept verbatim",
      S.trade_goods[5].zz.sell == 4)
-- market.lua records price history off this seam, only when either side is
-- priced.
check("the market seam fires for priced goods only", #seam_goods == 3,
      #seam_goods)
check("the seam carries the lineage it came from",
      seam_goods[1].lin == 2 and seam_goods[3].lin == 5)

-- Frames are deltas and each lineage is its own key, so a frame replaces
-- exactly the lineages it carries. MIP had to guess at this with a
-- two-second burst window; the split removes the guess.
tradegoods({ tgoods_2 = { { lin = 2, good = "o", score = 3, sup = 0,
                            dem = 1, buy = 0, sell = 7 } } })
check("a lineage key replaces that lineage outright",
      S.trade_goods[2].ore.sell == 7 and S.trade_goods[2].timber == nil)
check("a lineage the frame did not carry is left standing",
      S.trade_goods[5] ~= nil and S.trade_goods[5].zz.sell == 4)
trade_mod._market_seam.on_tgoods = nil

-- ---- abbreviation mapping -------------------------------------------------
-- Its own section, and last: it resets S.trade_goods, so run inside the
-- per-lineage block above it wiped the lineages those cases still assert on
-- and added its twelve goods to seam_goods's expected three.
-- Regression: GOOD_SHORT was missing the 11 husbandry/refined-husbandry
-- abbreviations entirely (a bare letter decoded to itself, matching no good
-- id best_sell_of()/the stock-sell scanner could ever look up), and `a` was
-- mapped to the good's pre-rename id "amber" instead of "sunstone" (which is
-- what market.lua's own GOODS_ALL, and the warehouse, actually key on).
-- Both silently made the affected goods unsellable via auto-trade
-- regardless of stock or demand -- see client.h's _v_tgoods() _abbrevs
-- array for the server's authoritative letter-to-good mapping.
S.trade_goods = {}
tradegoods({
  tgoods_3 = {
    { lin = 3, good = "a", score = 0, sup = 10, dem = 0, buy = 5, sell = 0 },
    { lin = 3, good = "c", score = 0, sup = 0, dem = 20, buy = 0, sell = 8 },
    { lin = 3, good = "d", score = 0, sup = 0, dem = 5, buy = 0, sell = 3 },
    { lin = 3, good = "p", score = 0, sup = 0, dem = 5, buy = 0, sell = 3 },
    { lin = 3, good = "q", score = 0, sup = 0, dem = 5, buy = 0, sell = 3 },
    { lin = 3, good = "v", score = 0, sup = 0, dem = 5, buy = 0, sell = 3 },
    { lin = 3, good = "x", score = 0, sup = 0, dem = 5, buy = 0, sell = 3 },
    { lin = 3, good = "mi", score = 0, sup = 0, dem = 5, buy = 0, sell = 3 },
    { lin = 3, good = "hm", score = 0, sup = 0, dem = 5, buy = 0, sell = 3 },
    { lin = 3, good = "z", score = 0, sup = 0, dem = 40, buy = 0, sell = 12 },
    { lin = 3, good = "sm", score = 0, sup = 0, dem = 15, buy = 0, sell = 20 },
    { lin = 3, good = "cs", score = 0, sup = 0, dem = 25, buy = 0, sell = 30 },
  },
})
check("`a` resolves to sunstone, not the pre-rename `amber`",
      S.trade_goods[3].sunstone ~= nil and S.trade_goods[3].amber == nil)
check("husbandry abbreviations resolve to their good names",
      S.trade_goods[3].wool ~= nil and S.trade_goods[3].eggs ~= nil
      and S.trade_goods[3].pork ~= nil and S.trade_goods[3].mutton ~= nil
      and S.trade_goods[3].poultry ~= nil and S.trade_goods[3].beef ~= nil
      and S.trade_goods[3].milk ~= nil and S.trade_goods[3].horsemeat ~= nil)
check("refined-husbandry abbreviations (the reported goods) resolve correctly",
      S.trade_goods[3].cloth ~= nil and S.trade_goods[3].cloth.demand == 40
      and S.trade_goods[3].smoked_meat ~= nil and S.trade_goods[3].smoked_meat.sell == 20
      and S.trade_goods[3].cheese ~= nil and S.trade_goods[3].cheese.sell == 30)


-- ---- unmapped and foreign --------------------------------------------------
-- crpr (cart repairs) has no MIP key and no consumer, so it stays counted.
local before = protocol.gmcp_stats().unknown["crpr"] or 0
trade({ crpr = { { cart = 1, durability = 50, secs = 10 } } })
check("crpr is counted, not applied",
      (protocol.gmcp_stats().unknown["crpr"] or 0) > before)

protocol.on_gmcp("Guild.Trade", { guild = "berserker",
                                  blocks = { { good = "foreign", amount = 1 } } })
check("a foreign guild's frame is dropped", S.blocks.foreign == nil)

if failures > 0 then
  print("FAILURES: " .. failures)
  os.exit(1)
end
print("ALL GUILD_VIKING GMCP TRADE TESTS PASSED")
