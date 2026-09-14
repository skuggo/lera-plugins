-- guild_viking Guild.Livestock writers unit tests. Run from the lera-plugins
-- repo root with LERA_ROOT pointing at a built Lera checkout.
--
-- Every case asserts the writer's output against values written out literally
-- and names the state field its consumer reads, matching the framing of
-- guild_viking_gmcp_settlement_test.lua.
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

local S = require("state").S
local livestock = require("handlers.livestock")
local w = livestock._gmcp

-- ---- herds -----------------------------------------------------------------
w.HERDS({
  { bldg = "sheepfold", head = 12, quality = 61, gen = 3, sterile = 0,
    hard = 40, fert = 55, yield = 70, vigor = 66, con = 50,
    breed = "nordic", hv = 1, trait = "prolific", age_ticks = 12 },
  { bldg = "byre", head = 4, quality = 30, gen = 1, sterile = 0,
    hard = 10, fert = 12, yield = 14, vigor = 20, con = 18,
    breed = "", hv = 0, trait = "0", age_ticks = 41 },
})
check("herds keyed by bldg", S.herds and S.herds.sheepfold and S.herds.byre)
-- The spec's Corrections-to-LEGACY table requires Auto-Herd to gate on
-- "Guild.Livestock having arrived", replacing LEGACY's MIP gate. herds is one
-- of the keys gmcp.h says is ALWAYS sent, even empty, so its writer is the
-- arrival signal; state.reset_connection() clears the latch so it can never
-- outlive the connection that set it.
check("a herds frame latches S.livestock_seen", S.livestock_seen == true,
      tostring(S.livestock_seen))
check("herds numeric fields land", S.herds.sheepfold.head == 12
      and S.herds.sheepfold.yield == 70 and S.herds.sheepfold.con == 50)
check("herds real trait kept", S.herds.sheepfold.trait == "prolific")
-- The server sends "0", not "" or nil, for a herd with no trait. Left as "0"
-- it would be looked up as a trait id and render as an unknown trait.
check('herds trait "0" normalised to nil', S.herds.byre.trait == nil)
check("herds empty breed stays a string", S.herds.byre.breed == "")

-- A building with head <= 0 is omitted by the server entirely. A later frame
-- with fewer herds must not leave the vanished one behind.
w.HERDS({
  { bldg = "sheepfold", head = 12, quality = 61, gen = 3, sterile = 0,
    hard = 40, fert = 55, yield = 70, vigor = 66, con = 50,
    breed = "nordic", hv = 1, trait = "prolific", age_ticks = 12 },
})
check("herds replaced wholesale, byre gone", S.herds.byre == nil)

local history = { "nordic", "icelandic" }
w.HERDS({ { bldg = "henhouse", age_ticks = 0, breeds = history } })
check("herd zero age remains known", S.herds.henhouse.age_ticks == 0)
check("complete breed history retained", #S.herds.henhouse.breeds == 2)
history[1] = "changed"
check("breed history is copied", S.herds.henhouse.breeds[1] ~= "changed"
      and S.herds.henhouse.breeds[2] ~= "changed")
w.HERDS({ { bldg = "henhouse" } })
check("legacy age remains unknown", S.herds.henhouse.age_ticks == nil)
check("legacy breed history remains unknown", S.herds.henhouse.breeds == nil)
for _, bad in ipairs({ "nordic,", "nordic,,other", { nordic = 4 }, { "nordic", false }, { [3] = "nordic" } }) do
  w.HERDS({ { bldg = "henhouse", breeds = bad } })
  check("malformed breed history is not proof of novelty", S.herds.henhouse.breeds == nil)
end
w.HERDS({ { bldg = "henhouse", breeds = {} } })
check("explicit empty history remains known", type(S.herds.henhouse.breeds) == "table"
      and #S.herds.henhouse.breeds == 0)

w.HERDS({ { bldg = "stable", head = 9, breeds = "nordic,icelandic",
  management = "20;2;9;4;5;0;4050;825;5001,5025,5100,5200,5300,5400" } })
check("compact management retains row head and fractions", S.herds.stable.head == 9
  and S.herds.stable.hard == 50.01 and S.herds.stable.gen == 8.25
  and S.herds.stable.age_ticks == 40.5 and S.herds.stable.management.free == 9)
check("compact history is complete", #S.herds.stable.breeds == 2)
for _, bad in ipairs({ "", "20;2;9;4;5;0;4050;825;5001,5025,5100,5200,5300",
  "20;2;9;4;5;2;4050;825;5001,5025,5100,5200,5300,5400",
  "20;2;10;4;5;0;4050;825;5001,5025,5100,5200,5300,5400",
  "20;2;9;4;5;0;4050;825;10001,5025,5100,5200,5300,5400",
  "20;2;9;4;5;0;4.5;825;5001,5025,5100,5200,5300,5400" }) do
  w.HERDS({ { bldg = "stable", head = 9, management = bad } })
  check("invalid compact management remains unknown", S.herds.stable.management == nil
    and S.herds.stable.management_present)
end
local token = string.rep("a", 32)
local compact_quote = "2;ok;5000,5000,5000,5000,5000,5000;5010,5010,5010,5010,5010,5010;800;784;0;1"
w.LMARKET({ lmarket_1 = { { token = token, unit_price = "123", available = "3", quote = compact_quote } } })
check("compact exact offer and quote parsed", S.lmarket[1][1].unit_price == 123
  and S.lmarket[1][1].available == 3 and S.lmarket[1][1].token == token
  and S.lmarket[1][1].quote.after_stats.hard == 5010)
w.LMARKET({ lmarket_1 = { { token = token, unit_price = 123, available = 3 } } })
check("rotated missing quote clears old quote", S.lmarket[1][1].quote == nil)
w.LMARKET({ lmarket_1 = { { token = "bad", unit_price = "1.2", available = -1, quote = compact_quote .. ";x" } } })
check("malformed compact offer fields unknown", S.lmarket[1][1].token == nil
  and S.lmarket[1][1].unit_price == nil and S.lmarket[1][1].available == nil
  and S.lmarket[1][1].quote == nil)

-- ---- bqueue (sibling split) ------------------------------------------------
w.BQUEUE({
  bqueue_used = 2, bqueue_max = 6,
  bqueue = { { slot = 1, species = "pig", meat = "pork", qty = 8,
               secs = 120, trait = "0" } },
})
check("bqueue used/max", S.bqueue_used == 2 and S.bqueue_max == 6)
check("bqueue slots", #S.bqueue == 1 and S.bqueue[1].meat == "pork")
check('bqueue trait "0" normalised', S.bqueue[1].trait == nil)

-- ---- lfeed (the only mapping key) ------------------------------------------
w.LFEED({ grain = 800, water = 200, head = 30 })
check("lfeed is a mapping, not positional",
      S.lfeed.grain == 800 and S.lfeed.water == 200 and S.lfeed.head == 30)

-- ---- lpending --------------------------------------------------------------
w.LPENDING({ { bldg = "byre", species = "cow", breed = "nordic",
               count = 2, secs = 300 } })
check("lpending", #S.lpending == 1 and S.lpending[1].secs == 300)

-- ---- lfind (three-part composite) ------------------------------------------
w.LFIND({
  lfind_posts = { { id = 7, species = "sheep", min_quality = 50,
                    max_price = 900, bldg = "sheepfold", tier = 2,
                    trait = "0", state = "open" } },
  lfind_offers = { { id = 9, species = "sheep", breed = "nordic", count = 3,
                     quality = 70, price = 850, hard = 40, fert = 50,
                     yield = 60, vigor = 55, con = 45, secs = 600,
                     trait = "hardy" } },
  lfind_auctions = { { id = 11, species = "cow", breed = "aurochs",
                       quality = 80, reserve = 1200, my_bid = 0,
                       secs = 900, trait = "0" } },
})
check("lfind three sub-arrays", #S.lfind.posts == 1 and #S.lfind.offers == 1
      and #S.lfind.auctions == 1)
check("lfind offer fields", S.lfind.offers[1].price == 850
      and S.lfind.offers[1].trait == "hardy")

-- ---- lmarket (variable-arity composite, merged per lineage) ----------------
-- The server sends one key per lineage and OMITS a lineage with no pool, so
-- this composite can never assume a fixed part count.
w.LMARKET({
  lmarket_1 = { { lin = 1, idx = 0, species = "sheep", breed = "nordic",
                  count = 2, price = 400, hard = 30, fert = 40, yield = 50,
                  vigor = 45, con = 35, trait = "0" } },
  lmarket_5 = { { lin = 5, idx = 0, species = "cow", breed = "aurochs",
                  count = 1, price = 900, hard = 50, fert = 30, yield = 60,
                  vigor = 40, con = 55, trait = "bountiful" } },
})
check("lmarket keyed by numeric lineage", S.lmarket[1] and S.lmarket[5])
check("lmarket record fields", S.lmarket[5][1].price == 900
      and S.lmarket[5][1].trait == "bountiful")

-- A delta carrying ONE lineage must not wipe the others.
w.LMARKET({
  lmarket_5 = { { lin = 5, idx = 0, species = "cow", breed = "aurochs",
                  count = 1, price = 999, hard = 50, fert = 30, yield = 60,
                  vigor = 40, con = 55, trait = "bountiful" } },
})
check("lmarket delta preserves other lineages", S.lmarket[1] ~= nil)
check("lmarket delta updates its own lineage", S.lmarket[5][1].price == 999)

-- A FULL resend replaces instead of merging. The server omits lmarket_<lid>
-- entirely when a pool empties, and on a shrinking key set it sets full=1 and
-- repeats the complete current key set -- so a lineage absent from a full
-- frame is gone, not unchanged. Merging one leaves phantom listings standing
-- forever, and Auto-Herd then scores a sold animal, re-emits a buy the server
-- refuses, and wedges (a stale TRAIT listing carries a +1000 score bonus and
-- would win permanently).
w.LMARKET({
  lmarket_5 = { { lin = 5, idx = 0, species = "cow", breed = "aurochs",
                  count = 1, price = 777, hard = 50, fert = 30, yield = 60,
                  vigor = 40, con = 55, trait = "bountiful" } },
}, true)
check("a full frame omitting a lineage evicts it", S.lmarket[1] == nil,
      S.lmarket[1] and #S.lmarket[1])
check("a full frame keeps the lineages it does carry", S.lmarket[5]
      and S.lmarket[5][1].price == 777)

-- ...and a delta must still merge, which is the behaviour the two cases above
-- this one pin.
w.LMARKET({
  lmarket_1 = { { lin = 1, idx = 0, species = "sheep", breed = "nordic",
                  count = 2, price = 400, hard = 30, fert = 40, yield = 50,
                  vigor = 45, con = 35, trait = "0" } },
})
check("a delta after a full frame merges, not replaces",
      S.lmarket[1] ~= nil and S.lmarket[5] ~= nil)

-- ---- lneeds ----------------------------------------------------------------
w.LNEEDS({ { species = "sheep", current = 2, cap = 14 } })
check("lneeds", #S.lneeds == 1 and S.lneeds[1].cap == 14)

-- ---- connection-local receipt evidence ------------------------------------
do
  local real_time, now = os.time, 10000
  os.time = function() return now end
  local state = require("state")
  local protocol = require("protocol")
  for key, writer in pairs(w) do protocol.gmcp_handler(key, writer) end
  local function frame(payload)
    payload.guild = "viking"
    protocol.on_gmcp("Guild.Livestock", payload)
  end
  local function evidence(key, at, seq)
    local e = (S.herd_observed or {})[key]
    return e and e.at == at and e.seq == seq
  end
  state.reset_connection()
  frame({ bqueue_used = 1 })
  frame({ bqueue_max = 6 })
  check("capacity-only frames cannot establish queue confirmation",
    S.herd_observed.bqueue == nil)
  frame({ herds = { { bldg = "byre", head = 2 } },
    lpending = { { bldg = "byre", count = 1, secs = 30 } },
    bqueue = { { slot = 1, qty = 2, secs = 60 } } })
  check("actual livestock writes establish receipt revisions",
    evidence("herds", 10000, 1) and evidence("pending", 10000, 1)
    and evidence("bqueue", 10000, 1))
  check("herd row records receipt time", S.herds.byre._received_at == 10000)
  local queue = S.bqueue
  now = 10020
  for _, partial in ipairs({ { bqueue_used = 2 }, { bqueue_max = 8 },
      { bqueue_used = 3, bqueue_max = 9 } }) do
    frame(partial)
    check("capacity-only delta cannot refresh existing queue confirmation",
      S.bqueue == queue and evidence("bqueue", 10000, 1))
  end
  check("capacity-only deltas still apply used/max", S.bqueue_used == 3 and S.bqueue_max == 9)
  frame({ lfeed = { grain = 80 }, lneeds = {} })
  check("omitted herds and pending do not advance receipt revisions",
    evidence("herds", 10000, 1) and evidence("pending", 10000, 1)
    and S.herds.byre._received_at == 10000)
  frame({ lpending = {} })
  check("empty pending is an actual write, not an omitted field",
    #S.lpending == 0 and evidence("pending", 10020, 2) and evidence("herds", 10000, 1))
  frame({ lpending = {} })
  check("same-second identical pending receipt advances sequence", evidence("pending", 10020, 3))
  frame({ herds = {}, bqueue = {} })
  check("explicit empty herds and slots refresh confirmation",
    next(S.herds) == nil and #S.bqueue == 0
    and evidence("herds", 10020, 2) and evidence("bqueue", 10020, 2))
  frame({ herds = {} })
  check("same-second identical herds receipt advances sequence", evidence("herds", 10020, 3))

  frame({ lmarket_1 = { { lin = 1, idx = 0, price = 400 } },
    lmarket_5 = { { lin = 5, idx = 0, price = 900 } } })
  now = 10040
  frame({ lmarket_5 = { { lin = 5, idx = 0, price = 950 } } })
  check("market delta timestamps only the received lineage",
    S.lmarket[1][1]._received_at == 10020 and S.lmarket[1][1].price == 400
    and S.lmarket[5][1]._received_at == 10040 and S.lmarket[5][1].price == 950)
  now = 10060
  frame({ full = 1, lmarket_5 = { { lin = 5, idx = 0, price = 950 } } })
  check("market full resend timestamps replacement and evicts missing lineage",
    S.lmarket[1] == nil and S.lmarket[5][1]._received_at == 10060)

  local trade = require("handlers.trade")._gmcp
  trade.DALER(123)
  trade.TGOODS({ tgoods_5 = { { good = "p", sell = 7 } } })
  local epoch = S.herd_connection_epoch
  local market_rows, price_rows = S.lmarket, S.trade_goods
  state.reset_connection()
  check("reconnect clears all receipt evidence and advances epoch",
    next(S.herd_observed) == nil and S.herd_connection_epoch == epoch + 1
    and S.livestock_seen == false)
  check("reconnect preserves cached data without refreshing row receipts",
    S.lmarket == market_rows and S.trade_goods == price_rows and S.daler == 123
    and S.lmarket[5][1]._received_at == 10060
    and S.trade_goods[5].pork._received_at == 10060)
  now = 10080
  frame({ bqueue_used = 0, bqueue_max = 9 })
  check("post-reconnect capacity cannot resurrect old confirmation", next(S.herd_observed) == nil)
  frame({ herds = {} })
  check("new connection starts fresh receipt sequence", evidence("herds", 10080, 1))
  state.reset_connection()
  check("successive reconnect advances epoch again and clears new evidence",
    S.herd_connection_epoch == epoch + 2 and next(S.herd_observed) == nil)
  os.time = real_time
end

-- Same-package bounded chunks: real protocol reassembly and livestock writers.
do
  local state, protocol = require("state"), require("protocol")
  local real_time, now = os.time, 20000
  os.time = function() return now end
  state.reset_connection()
  protocol.reset_connection()
  protocol.gmcp_handler("DALER", require("handlers.trade")._gmcp.DALER)
  S.lmarket = {}
  local function market(payload)
    payload.guild = payload.guild or "viking"
    if payload.lmarket_partial == nil and (not payload.page or payload.page == 1) then
      payload.lmarket_partial = 1
    end
    protocol.on_gmcp("Guild.Livestock", payload)
  end
  market({ full = 1, lmarket_1 = { { idx = 0, price = 100 } },
    lmarket_13 = { { idx = 0, price = 1300 } },
    lfind_posts = { { id = 1 } }, lfind_offers = { { id = 2 } },
    lfind_auctions = { { id = 3 } } })
  local retained = S.lmarket[13]
  check("new market routes find's three keys", S.lfind.posts[1].id == 1
    and S.lfind.offers[1].id == 2 and S.lfind.auctions[1].id == 3)
  check("market-only receipt cannot synthesize pending or herd proof",
    next(S.herd_observed) == nil and not S.livestock_seen)
  now = 20020
  market({ full = 1, lmarket_1 = { { idx = 0, price = 200 } } })
  check("new full market preserves omitted lineage and original timestamp",
    S.lmarket[13] == retained and retained[1]._received_at == 20000
    and S.lmarket[1][1].price == 200 and S.lmarket[1][1]._received_at == 20020)
  local before = S.lmarket[1]
  market({ full = 1, page = 1, pages = 3,
    lmarket_1 = { { idx = 0, price = 300 } } })
  protocol.on_gmcp("Guild.State", { guild = "viking", full = 1, daler = 321 })
  market({ full = 1, page = 2, pages = 3,
    lmarket_1 = { { idx = 1, price = 301 } } })
  check("market slices are not published before final page", S.lmarket[1] == before)
  now = 20040
  market({ full = 1, page = 3, pages = 3,
    lmarket_1 = { { idx = 2, price = 302 } } })
  check("repeated lineage slices concatenate once and replace atomically",
    #S.lmarket[1] == 3 and S.lmarket[1][1].price == 300
    and S.lmarket[1][2].price == 301 and S.lmarket[1][3].price == 302
    and S.lmarket[1][1]._received_at == 20040
    and S.lmarket[1][3]._received_at == 20040 and S.lmarket[13] == retained)
  check("first-page marker survives reassembly and other-package interleaving",
    S.lmarket[13] == retained and S.daler == 321
    and protocol.gmcp_stats().unknown.lmarket_partial == nil)
  local assembled = S.lmarket[1]
  market({ full = 1, page = 3, pages = 3,
    lmarket_1 = { { idx = 2, price = 302 } } })
  check("duplicate final page does not append again", S.lmarket[1] == assembled
    and #S.lmarket[1] == 3)
  market({ guild = "mage", full = 1, lmarket_1 = {}, lpending = {} })
  check("foreign market rejected before handlers", S.lmarket[1] == assembled
    and S.herd_observed.pending == nil)
  protocol.on_gmcp("Guild.Livestock", { guild = "viking", full = 1,
    herds = {}, bqueue_used = 0, bqueue_max = 6, bqueue = {},
    lfeed = { grain = 10 }, lpending = {}, lneeds = {} })
  check("seven-key core full does not clear market", S.lmarket[1] == assembled
    and S.lmarket[13] == retained and retained[1]._received_at == 20000)
  local pending = S.herd_observed.pending
  market({ full = 1, lmarket_1 = {} })
  check("explicit empty clears exactly its lineage", #S.lmarket[1] == 0
    and S.lmarket[13] == retained and retained[1]._received_at == 20000)
  check("market omission cannot refresh pending proof", S.herd_observed.pending == pending)
  market({ full = 1, lfind_posts = {} })
  check("market full without lineage keys preserves pools", S.lmarket[13] == retained
    and #S.lfind.posts == 0 and S.lfind.offers[1].id == 2)
  protocol.on_gmcp("Guild.Livestock", { guild = "viking", full = 1,
    lmarket_1 = { { idx = 0, price = 400 } } })
  check("legacy bulk full still evicts omitted lineage", S.lmarket[13] == nil
    and S.lmarket[1][1].price == 400)
  for _, marker in ipairs({ false, true, "1", 0 }) do
    market({ full = 1, lmarket_13 = { { price = 1300 } } })
    market({ full = 1, lmarket_partial = marker, lmarket_1 = { { price = 500 } } })
    check("non-numeric-one marker retains normal full eviction: " .. tostring(marker),
      S.lmarket[13] == nil and S.lmarket[1][1].price == 500)
  end
  market({ full = 1, lmarket_13 = { { price = 1300 } } })
  protocol.on_gmcp("Guild.Trade", { guild = "viking", full = 1,
    lmarket_partial = 1, lmarket_1 = {} })
  check("marker cannot override full on other packages", S.lmarket[13] == nil)
  market({ full = 1, lmarket_13 = { { price = 1300 } } })
  local malformed = protocol.gmcp_stats().malformed
  market({ full = 1, page = 1, pages = 2, lmarket_partial = 1,
    lmarket_1 = { { price = 600 } } })
  market({ full = 1, page = 2, pages = 2, lmarket_partial = 1,
    lmarket_1 = { { price = 601 } } })
  check("repeated marker is recognized metadata, not a malformed scalar repeat",
    protocol.gmcp_stats().malformed == malformed
    and protocol.gmcp_stats().unknown.lmarket_partial == nil
    and #S.lmarket[1] == 2 and S.lmarket[13] ~= nil)
  os.time = real_time
end

if failures > 0 then
  print(failures .. " FAILURE(S)")
  os.exit(1)
end
print("all livestock writer cases passed")
