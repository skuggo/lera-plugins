-- guild_viking unit tests. Run from the lera-plugins repo root with LERA_ROOT
-- pointing at a built Lera checkout.
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

-- ---- lera API stubs (extended by later tasks' cases) -----------------------
local dirty_count = 0
ui = { dirty = function() dirty_count = dirty_count + 1 end }
local stored = nil
store = {
  load = function() end,
  get = function() return stored end,
  set = function(d) stored = d end,
  save = function() end,
}
lera = { time = function() return 1000 end, version = function() return "test" end,
         render_pass = function() return "local" end }
-- Captures each color_print call's text segments (positions 3, 6, 9, ... of
-- its bg/fg/text triplets), joined, as one entry -- lets later cases (the
-- Task 2 "/vik opts" dispatch) assert on printed content instead of just
-- that a call happened without erroring.
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
-- Task 3 (M.on_connect / autotrader/tick.lua): `sent` captures every
-- mud.send() call so the reconnect-hook and /vik trader tests below can
-- assert on it.
local sent = {}
local mud_connected = true
mud = {
  send = function(cmd) sent[#sent + 1] = cmd end,
  connected = function() return mud_connected end,
}
-- mip/gmcp stubs capture registrations and can fire them with the real wire
-- shapes, so wiring bugs (e.g. binding the wrong callback argument) show up
-- as test failures instead of only at runtime.
local mip_handlers, mip_handler_count = {}, 0
mip = {
  on = function(code, cb)
    mip_handlers[code] = cb
    mip_handler_count = mip_handler_count + 1
    return mip_handler_count
  end,
  off = function() end,
  enabled = function() return true end,
  -- real shape: callback(key, code, data) -- key is the 5-digit packet
  -- sequence number, data is the payload string.
  fire = function(code, data) mip_handlers[code](12345, code, data) end,
}
local gmcp_handlers, gmcp_handler_count = {}, 0
gmcp = {
  on = function(pkg, cb)
    gmcp_handlers[pkg] = cb
    gmcp_handler_count = gmcp_handler_count + 1
    return gmcp_handler_count
  end,
  remove = function() end,
  enabled = function() return false end,
  -- real shape: callback(package, data)
  fire = function(pkg, data) gmcp_handlers[pkg](pkg, data) end,
}
-- Task 3: captures every trigger.add registration (pattern, fn, opts) with
-- an incrementing id, and every trigger.remove'd id -- so the hp-bar gag
-- tests below can assert the opts a REAL /vik set gag_status_lines
-- re-registration actually passed, and that the old ids were torn down.
local trigger_regs, trigger_reg_count = {}, 0
local removed_trigger_ids = {}
trigger = {
  add = function(pattern, fn, opts)
    trigger_reg_count = trigger_reg_count + 1
    trigger_regs[trigger_reg_count] = { pattern = pattern, fn = fn, opts = opts }
    return trigger_reg_count
  end,
  remove = function(id) removed_trigger_ids[id] = true end,
}
-- Fix 1 regression: capture every timer.every registration (interval, fn) so
-- the sweep timer's callback can be fired directly with realistic
-- lera.time() values, the same way mip/gmcp stubs above capture their
-- callbacks for wiring tests. lera.time() returns EPOCH SECONDS
-- (src/lua/api_lera.c), so the stub below must move in whole seconds.
local timer_regs = {}
-- The real lera timer API is add/every/after/cancel/count -- there is no
-- timer.remove. This stub used to define `remove`, mirroring a mistaken call in
-- the plugin's on_unload rather than the API, so a nil-field crash that aborted
-- on_unload halfway passed this suite. Cancellations are recorded so the
-- teardown case can assert they actually happened.
timer_cancels = {}
timer = {
  every = function(interval, fn)
    timer_regs[#timer_regs + 1] = { interval = interval, fn = fn }
    return #timer_regs
  end,
  cancel = function(id)
    timer_cancels[#timer_cancels + 1] = id
    return true
  end,
}
-- Task 10: capture the ^resetvikxp$ registration so later cases can fire it
-- directly, the same way mip/gmcp stubs above capture their callbacks.
local registered_resetvikxp = nil
alias = {
  add = function(pattern, fn)
    registered_resetvikxp = { pattern = pattern, fn = fn }
    return 1
  end,
  remove = function() end,
}
plugin = { get = function() return nil end }
-- Task 3 (autotrader/tick.lua's M.open_menu): same package.loaded["menu"]
-- stub shape as guild_viking_popup_dispatch_test.lua's preamble -- real
-- Lua require() consults package.loaded before touching package.path, so
-- this is seen even though tick.lua's own `require("menu")` call is routed
-- through the require() override below (which falls through to the real
-- require for any name other than "command").
local last_menu_open = nil
package.loaded["menu"] = {
  open = function(opts) last_menu_open = opts end,
  close = function() last_menu_open = nil end,
  is_open = function() return last_menu_open ~= nil end,
}
local function menu_item_labels(opts)
  local out = {}
  for _, it in ipairs(opts.items or {}) do out[#out + 1] = it.label end
  return out
end
local real_require = require
-- Task 10: capture the spec passed to command.register so later cases can
-- dispatch through the registered /vik handler directly.
local registered_vik = nil
require = function(name)
  if name == "command" then
    return { register = function(spec) registered_vik = spec; return 1 end,
             unregister = function() return true end,
             get = function() return nil end, list = function() return {} end }
  end
  return real_require(name)
end

-- ---- util.split parity with Portal's string.split --------------------------
local util = require("util")
local parts = util.split("a~b~~c", "~")
check("split basic", #parts == 4 and parts[1] == "a" and parts[3] == "" and parts[4] == "c",
      table.concat(parts, ","))
check("split single", #util.split("solo", "~") == 1)
check("split empty tail", (function()
  local p = util.split("x|", "|")
  return #p == 2 and p[2] == ""
end)())

-- ---- state defaults ---------------------------------------------------------
local state_mod = require("state")
local S = state_mod.S
check("state hp default", S.hp == 0)
check("state carts table", type(S.carts) == "table" and #S.carts == 0)
check("state price_history table", type(S.price_history) == "table")
check("state blot_total", S.blot_total == 9)
check("state daler sentinel", S.daler == -1)
check("state en5 default", S.en5 == "None")

-- reset_connection clears per-connection combat state but keeps persisted-style fields
S.combat = true
S.en5 = "orc"
-- The Guild.Livestock arrival latch is per-connection: Auto-Herd gates its
-- spending on it, so a latch left standing across a disconnect would let the
-- first tick after reconnect plan against last session's herds.
S.livestock_seen = true
state_mod.reset_connection()
check("reset clears combat", S.combat == false and S.en5 == "None")
check("reset clears the Guild.Livestock arrival latch",
      S.livestock_seen == false, tostring(S.livestock_seen))

-- ---- plugin table loads -----------------------------------------------------
local M = dofile("3scapes/guild_viking/init.lua")
check("plugin name", M.name == "guild_viking")
check("plugin state accessor", M.state() == S)
check("hooks exist", type(M.on_load) == "function" and type(M.on_unload) == "function"
      and type(M.on_connect) == "function" and type(M.on_disconnect) == "function")

-- ---- protocol: dispatch, batching, latch ------------------------------------
local protocol = require("protocol")

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

-- Guild.Voyage's Sea Chart: a width/height/mode record plus its rows, where
-- MIP sent VCHH and a numbered VCR%02d burst.
local function seed_chart(width, height, mode, rows)
  protocol.on_gmcp("Guild.Voyage", { guild = "viking",
    voyage_chart = { width = width, height = height,
                     chart_mode = mode or "explore" },
    voyage_chart_rows = rows or {} })
end

-- ---------------------------------------------------------------------------
-- Fixture seeding
-- ---------------------------------------------------------------------------
-- Same arrangement as guild_viking_autotrader_test.lua: the fixtures keep the
-- compact notation this suite has always used, and these functions translate
-- it into the Guild.* frames the production writers take. TGOODS and the Sea
-- Chart (VCHH/VCR) still seed over MIP, since they have no GMCP source yet.
local function fixture_fields(entry)
  local out = {}
  for piece in (entry .. "|"):gmatch("([^|]*)|") do out[#out + 1] = piece end
  return out
end

local function fixture_gmcp(pkg, payload)
  payload.guild = "viking"
  protocol.on_gmcp(pkg, payload)
end

local function seed_buildings(str)
  local entries = {}
  for e in tostring(str or ""):gmatch("[^,]+") do
    local id, tier = e:match("^([^:]+):(%d+)$")
    if id then entries[#entries + 1] = { id = id, tier = tonumber(tier) } end
  end
  fixture_gmcp("Guild.City", { buildings = entries })
end

local function seed_wstock(str)
  local entries = {}
  for e in tostring(str or ""):gmatch("[^;]+") do
    local f = fixture_fields(e)
    entries[#entries + 1] = { good = f[1], amount = tonumber(f[2]) or 0,
                              pct = tonumber(f[3]) or 100 }
  end
  fixture_gmcp("Guild.Trade", { wstock = entries })
end

local function seed_staff(str)
  local entries = {}
  for e in tostring(str or ""):gmatch("[^;]+") do
    local f = fixture_fields(e)
    entries[#entries + 1] = { name = f[1], assigned = f[2], stat = f[3],
                              stats = f[4], trait = f[5],
                              loyalty = tonumber(f[6]) or 3, age = f[7],
                              arrive = tonumber(f[8]) or 0 }
  end
  fixture_gmcp("Guild.Roster", { staff = entries })
end

local function seed_blocks(str)
  local entries = {}
  for e in tostring(str or ""):gmatch("[^;]+") do
    local good, amount = e:match("^([^:]+):(%d+)$")
    if good then entries[#entries + 1] = { good = good, amount = tonumber(amount) } end
  end
  fixture_gmcp("Guild.Trade", { blocks = entries })
end

local function seed_carts(str)
  local entries = {}
  for e in tostring(str or ""):gmatch("[^;]+") do
    local f = fixture_fields(e)
    entries[#entries + 1] = { mode = f[1], good = f[2], village = f[3],
      secs = tonumber(f[4]) or 0, amount = tonumber(f[5]) or 0,
      half_in = tonumber(f[6]) or 0, quality_pct = tonumber(f[7]) or 100,
      cart_id = tonumber(f[8]) or 0, tier = tonumber(f[9]) or 1,
      durability = tonumber(f[10]) or 100, cap = tonumber(f[11]) or 0,
      escort = tonumber(f[12]) or 0, refit = f[13] or "" }
  end
  fixture_gmcp("Guild.Trade", { carts = entries, cart_legs = {} })
end

local function seed_cidle(str)
  local entries = {}
  for e in tostring(str or ""):gmatch("[^;]+") do
    local f = fixture_fields(e)
    entries[#entries + 1] = { slot = tonumber(f[1]) or 0, tier = tonumber(f[2]) or 1,
                              durability = tonumber(f[3]) or 100,
                              cap = tonumber(f[4]) or 0, refit = f[5] or "" }
  end
  fixture_gmcp("Guild.Trade", { cidle = entries })
end

local function seed_tqueue(str)
  local jobs, legs = {}, {}
  local index = 0
  for job in tostring(str or ""):gmatch("[^;]+") do
    index = index + 1
    local seq = 0
    for ls in job:gmatch("[^!]+") do
      seq = seq + 1
      local f = fixture_fields(ls)
      if #f >= 4 then
        legs[#legs + 1] = { job = index, seq = seq, mode = f[1], good = f[2],
                            amount = tonumber(f[3]) or 0, village = f[4] }
      end
    end
    jobs[#jobs + 1] = { job = index, escort = 0 }
  end
  fixture_gmcp("Guild.Trade", { queue = jobs, queue_legs = legs })
end

local function seed_daler(v)
  fixture_gmcp("Guild.State", { daler = tonumber(v) or 0 })
end

local function seed_ships(str)
  local entries = {}
  for e in tostring(str or ""):gmatch("[^;]+") do
    local f = fixture_fields(e)
    entries[#entries + 1] = { name = f[1], tier = tonumber(f[2]) or 1,
      state = f[3], target = f[4], secs = tonumber(f[5]) or 0,
      id = tonumber(f[6]), crew = tonumber(f[7]) or 0,
      convoy = tonumber(f[8]) or 0, convoy_size = tonumber(f[9]) or 0,
      convoy_bonus = tonumber(f[10]) or 0, saga_title = f[11] or "",
      saga_raids = tonumber(f[12]) or 0, held = tonumber(f[13]) or 0,
      durability = tonumber(f[14]) or 100 }
  end
  fixture_gmcp("Guild.Fleet", { ships = entries })
end

local seen = {}

-- A Guild.* GMCP frame reaches its registered writer, and the key it fed is
-- latched.
--
-- Observed through a REAL writer's effect on state rather than a probe
-- registered here. Earlier revisions of this case each picked a key that had
-- no _gmcp writer yet and registered their own; every one of them broke as
-- soon as that key gained a real writer and the duplicate-key guard fired
-- (SETTLERS, then RBUILD, then CARTS). BLOCKS is a plain good -> amount
-- lookup, which makes the assertion a value comparison rather than a shape
-- one.
protocol.on_gmcp("Guild.Trade",
  { guild = "viking", blocks = { { good = "gmcprouted", amount = 7 } } })
check("guild frame routes to its registered writer", S.blocks.gmcprouted == 7)
check("the fed key is latched", protocol.gmcp_keys().BLOCKS == true)

-- ---- init.lua wiring: gmcp "Guild" reaches protocol correctly --------------
-- M.on_load() registers the real gmcp/timer callbacks used at runtime.
-- It must only run once in this suite -- later /vik command tests (task 10)
-- rely on it having already run and must not call it again.
M.on_load()

-- What is under test here is the gmcp.on("Guild", ...) subscription reaching
-- protocol.on_gmcp at all, so it is asserted the same way as above: through a
-- real writer's effect, not a probe this file registers. See that case's
-- comment for why a probe is no longer a durable way to write this.
gmcp.fire("Guild", { guild = "viking",
                     blocks = { { good = "gmcpwired", amount = 3 } } })
check("gmcp Guild wiring feeds protocol.on_gmcp", S.blocks.gmcpwired == 3)
-- Lera invokes the root subscription with the actual sub-package name.
local saved_market = S.lmarket
S.lmarket = {}
gmcp_handlers.Guild("Guild.Livestock", { guild = "viking", full = 1,
  lmarket_partial = 1, lmarket_13 = { { idx = 0, price = 1313 } } })
gmcp_handlers.Guild("Guild.Livestock", { guild = "viking", full = 1,
  lmarket_partial = 1, lmarket_1 = {} })
check("root Guild registration handles marked Livestock full omissions",
  S.lmarket[13] and S.lmarket[13][1].price == 1313 and #S.lmarket[1] == 0)
S.lmarket = saved_market

-- ---- notify: push triggers + countdown_tick (Task 9) -----------------------
local notify = require("notify")

check("notify has 15 trigger entries", #notify.triggers == 15, #notify.triggers)

local function find_trigger(name)
  for _, t in ipairs(notify.triggers) do
    if t.name == name then return t end
  end
  error("no trigger named " .. name)
end

-- nil-pushn safety: every trigger fn must no-op without error before
-- set_push is ever called.
for _, t in ipairs(notify.triggers) do
  local ok = pcall(t.fn, "some matching line", "cap")
  check("nil-pushn safe: " .. t.name, ok)
end

local push_records = {}
local pushn_stub = {
  notify = function(channel, message)
    push_records[#push_records + 1] = { channel = channel, message = message }
  end,
}
notify.set_push(pushn_stub)

local function assert_trigger(name, line, capture, want_message)
  push_records = {}
  local t = find_trigger(name)
  t.fn(line, capture)
  local rec = push_records[1]
  check(name .. " channel", rec and rec.channel == "viking", rec and rec.channel)
  check(name .. " message", rec and rec.message == want_message, rec and rec.message)
end

assert_trigger("push_cart_return", "Cart returned from Aldby.", nil,
  "Cart returned from trade route.")
assert_trigger("push_longship_return", "The longship returned from the island.", nil,
  "Longship returned from island with thralls.")
assert_trigger("push_longship_return", "The longship docks safely and the secured voyage spoils are brought home.", nil,
  "Longship returned from island with thralls.")
assert_trigger("push_longship_saved", "The Northwind was saved from the deep by the Iron Hull perk.", nil,
  "Longship saved by Iron Hull perk.")
assert_trigger("push_longship_tattoo", "The Northwind returned with a foreign tattoo pattern.", nil,
  "Longship returned with tattoo pattern.")
assert_trigger("push_longship_thralls", "The Northwind returned with 3 thralls.", nil,
  "Longship returned with thralls.")
assert_trigger("push_voyage_node", "A hidden harbor rises off the port bow.", "hidden harbor",
  "Voyage: hidden harbor reached - resolve needed.")
assert_trigger("push_voyage_node", "A harbor rises off B12.", "harbor",
  "Voyage: harbor reached - resolve needed.")
assert_trigger("push_voyage_node", "An island rises off C03.", "island",
  "Voyage: island reached - resolve needed.")
assert_trigger("push_voyage_pause", "[Viking-Voyage] Spoiled casks are found below deck.",
  "Spoiled casks are found below deck.",
  "Voyage: Spoiled casks are found below deck.")
assert_trigger("push_raid_return", "Your raiders returned from Wessex with plunder.", nil,
  "Raid returned with spoils.")
assert_trigger("push_town_captured", "Eastgate falls! The town is taken.", "Eastgate",
  "War: Eastgate has fallen to your rule!")
assert_trigger("push_war_declared", "Ivar declares war and gathers a host.", "Ivar",
  "War: Ivar marches on your realm -- answer or sue for peace.")
assert_trigger("push_realm_sacked", "A raiding party sacks your holdings.", nil,
  "War: your holdings were sacked -- you left an incoming war unanswered.")
assert_trigger("push_battle_lost", "[War] Defeat. Your host was routed.", nil,
  "Battle: your host was defeated.")
assert_trigger("push_battle_lost", "Defeat. Your host is broken; the fielded companies are lost.", nil,
  "Battle: your host was defeated.")
assert_trigger("push_recruit_found", "A wanderer is looking for a hall to serve.", nil,
  "Kaupstefna: a specialist wanderer is available to hire (vfind).")
assert_trigger("push_recruit_found_2", "A wanderer came seeking a hall.", nil,
  "Kaupstefna: a specialist wanderer is available to hire (vfind).")
assert_trigger("push_relic_found", "A relic is hauled aboard.", nil,
  "Voyage: a rare relic was recovered!")

-- push_voyage_pause fallback when no capture arrives (mirrors LEGACY's
-- `wildcards[1] or "Voyage paused"`). Defensive/unreachable in practice: the
-- trigger pattern's capture group is `(.*)`, which always participates in a
-- real match (at worst as an empty string, which is truthy in Lua), so the
-- real trigger engine can never hand this fn a nil c1. Calling fn() directly
-- with no second argument, as below, is the only way to exercise this branch.
push_records = {}
find_trigger("push_voyage_pause").fn("[Viking-Voyage]")
check("voyage_pause fallback message",
      push_records[1] and push_records[1].message == "Voyage: Voyage paused")

-- ---- countdown_tick ---------------------------------------------------------

-- Carts: decrement while > 1; drop entries that would land at/under 1
-- (a cart never visibly shows "1").
S.carts = { { return_in = 5, halfway_in = 3 }, { return_in = 2 }, { return_in = 1 } }
local cd_before = dirty_count
notify.countdown_tick()
check("cart decremented", S.carts[1] and S.carts[1].return_in == 4 and S.carts[1].halfway_in == 2)
check("carts at/under 1 removed this tick", #S.carts == 1)
check("countdown fires exactly one dirty for the whole tick", dirty_count == cd_before + 1)

-- Courier runs: same family as carts.
S.courier.runs = { { return_in = 3 }, { return_in = 1 } }
notify.countdown_tick()
check("courier run decremented", S.courier.runs[1].return_in == 2)
check("courier run at 1 removed", #S.courier.runs == 1)

-- Spy: secs clamps to 0 at the boundary tick; sab_secs floors at 0 and
-- clears sab_pct when it does; cd_secs floors at 0; scouts decrement/prune
-- like carts.
S.spy = { tier = 1, mode = "raid", village = "x", secs = 1, sab_pct = 40, sab_secs = 1, cd_secs = 3,
          scouts = { { secs = 3 }, { secs = 1 } } }
notify.countdown_tick()
check("spy secs clamps to 0", S.spy.secs == 0)
check("spy sab_secs floors and clears pct", S.spy.sab_secs == 0 and S.spy.sab_pct == 0)
check("spy cd_secs decremented", S.spy.cd_secs == 2)
check("spy scout decremented and pruned", #S.spy.scouts == 1 and S.spy.scouts[1].secs == 2)

-- Training: decrements while > 1; never reaches 0 via the tick.
S.train = { tier = 1, name = "Axework", stat = "str", trained = 0, secs = 1 }
notify.countdown_tick()
check("train stuck at 1", S.train.secs == 1)
S.train.secs = 3
notify.countdown_tick()
check("train decremented", S.train.secs == 2)

-- Cart/ship upgrades and settler projects: floor at 0, no removal ever.
S.cart_upgrades = { { cart_id = 1, secs_left = 2 } }
S.ship_upgrades = { { name = "hull", secs_left = 1 } }
S.settler_projects = { { id = 1, secs_left = 1 } }
notify.countdown_tick()
check("cart upgrade decremented", S.cart_upgrades[1].secs_left == 1)
check("ship upgrade floors at 0, kept", S.ship_upgrades[1].secs_left == 0 and #S.ship_upgrades == 1)
check("settler project floors at 0, kept",
      S.settler_projects[1].secs_left == 0 and #S.settler_projects == 1)

-- Incoming fills: same family as carts.
S.incoming_fills = { { good = "wool", arrives_in = 2 } }
notify.countdown_tick()
check("incoming fill at/under 1 removed this tick", #S.incoming_fills == 0)

-- next_tick_in / demand_cycle_in: floor at 0.
S.next_tick_in = 1
S.demand_cycle_in = 1
notify.countdown_tick()
check("next_tick_in floors at 0", S.next_tick_in == 0)
check("demand_cycle_in floors at 0", S.demand_cycle_in == 0)

-- God power: recomputed from an absolute target while one is set, else a
-- plain per-second decrement floored at 0.
S.god_power_next_at = os.time() + 50
S.god_power_next = 999
notify.countdown_tick()
local gp_expected = S.god_power_next_at - os.time()
check("god power recomputed from target", S.god_power_next == gp_expected)
S.god_power_next_at = 0
S.god_power_next = 3
notify.countdown_tick()
check("god power plain decrement", S.god_power_next == 2)

-- Dispatch cooldown (Cartwright's Cadence): absolute-time recompute.
S.dispatch_cd_expires_at = os.time() + 40
S.dispatch_cd = 999
notify.countdown_tick()
local cd_expected = S.dispatch_cd_expires_at - os.time()
check("dispatch cooldown recomputed from target", S.dispatch_cd == cd_expected)

-- Ships / voyage longships: floor at 0, docked (0) entries kept.
S.ships = { { name = "Northwind", return_in = 1 } }
S.voyage_longships = { { name = "Southwind", return_in = 1 } }
notify.countdown_tick()
check("ship floors at 0, kept", S.ships[1].return_in == 0 and #S.ships == 1)
check("voyage longship floors at 0, kept",
      S.voyage_longships[1].return_in == 0 and #S.voyage_longships == 1)

-- Voyage status next_move (Sea tab countdown).
S.voyage_status = { next_move = 2 }
notify.countdown_tick()
check("voyage next_move decremented", S.voyage_status.next_move == 1)

-- Pending builds: decrement while > 0; drop only at exactly 0; keep nil and
-- negative (the -1 "awaiting mats" sentinel) untouched.
S.pending_builds = { { bldg_id = 1, complete_at_secs = 1 }, { bldg_id = 2, complete_at_secs = -1 },
                     { bldg_id = 3, complete_at_secs = nil } }
notify.countdown_tick()
check("pending build at 1 removed this tick", #S.pending_builds == 2)
check("pending build sentinel/nil kept",
      S.pending_builds[1].complete_at_secs == -1 and S.pending_builds[2].complete_at_secs == nil)

-- Route builds: decrement while > 0, removed the instant it reaches <= 0;
-- an entry already at 0 is left untouched (decrement and removal share the
-- same > 0 gate).
S.route_builds = { ["road:1"] = { vid = 1, complete_at_secs = 1 },
                   ["fort:2"] = { vid = 2, complete_at_secs = 0 } }
notify.countdown_tick()
check("route build at 1 removed", S.route_builds["road:1"] == nil)
check("route build already at 0 left alone",
      S.route_builds["fort:2"] ~= nil and S.route_builds["fort:2"].complete_at_secs == 0)

-- Idle tick: nothing counting down anywhere -> no dirty call, tick stays cheap.
S.carts, S.courier.runs, S.incoming_fills, S.pending_builds = {}, {}, {}, {}
S.route_builds, S.cart_upgrades, S.ship_upgrades, S.settler_projects = {}, {}, {}, {}
S.ships, S.voyage_longships = {}, {}
S.spy = { tier = 0, mode = "", village = "", secs = 0, sab_pct = 0, sab_secs = 0, cd_secs = 0, scouts = {} }
S.train = { tier = 0, name = "", stat = "", trained = 0, secs = 0 }
S.next_tick_in, S.demand_cycle_in = 0, 0
S.god_power_next, S.god_power_next_at = 0, 0
S.dispatch_cd, S.dispatch_cd_expires_at = 0, nil
S.voyage_status = nil
cd_before = dirty_count
notify.countdown_tick()
check("idle tick does not mark dirty", dirty_count == cd_before)

-- ---- notify.countdown_tick's tail wiring (Task 3 + Task 7 + Task 8): calls
-- all three automation ticks, after the dirty check, in LEGACY's own
-- trade/raid/voyage order (MAIN 2885-2890) --------------------------------
-- Monkey-patch the SAME module tables notify.lua captured local references
-- to at require time (require() caches by module name, so these tables are
-- identical either way) -- proves the three call sites themselves and their
-- relative order, independent of what each M.tick() does internally
-- (already covered exhaustively in each automation's own test suite).
--
-- Fix round 1, M-4: the original version of this test only monkey-patched
-- autotrader.tick, so deleting either autoraid.tick() or autovoyage.tick()
-- from notify.lua's countdown_tick (LEGACY 2887/2889-equivalent) passed
-- with 0 failures -- the exact same "tick wiring is untested" gap Task 7
-- left for autovoyage. Confirmed by mutation (see the task report): each of
-- the three calls was deleted from notify.lua in turn and this test caught
-- every one, then all three were confirmed present again.
do
  local trade_mod = require("autotrader.tick")
  local raid_mod = require("autoraid")
  local voyage_mod = require("autovoyage")
  local real_trade_tick, real_raid_tick, real_voyage_tick =
    trade_mod.tick, raid_mod.tick, voyage_mod.tick
  local order = {}
  trade_mod.tick = function() order[#order + 1] = "trade" end
  raid_mod.tick = function() order[#order + 1] = "raid" end
  voyage_mod.tick = function() order[#order + 1] = "voyage" end
  notify.countdown_tick()
  check("countdown_tick calls all three automation ticks exactly once each, "
        .. "in LEGACY's trade/raid/voyage order",
        #order == 3 and order[1] == "trade" and order[2] == "raid" and order[3] == "voyage",
        table.concat(order, ","))
  trade_mod.tick, raid_mod.tick, voyage_mod.tick = real_trade_tick, real_raid_tick, real_voyage_tick
end

-- ---- persist: price_history + source survive save/load (Task 10) -----------
local persist = require("persist")
-- Task 2: page_opts.lua and window.lua, required here for the persistence
-- round-trip extension below (page_opts + current page).
local page_opts = require("page_opts")
local window = require("window")

S.price_history = { [1] = { fish = { { t = 100, b = 2, s = 3 } } } }
-- Task 2 extension: flip a page option and switch pages before saving, so
-- the round-trip below also covers persist's new page_opts/page fields
-- (mirrors LEGACY's SetVariable("popt_"..k) + SetVariable("page", ...)).
page_opts.set("show_stats_buffs", false)
window.set_page("goods")
persist.save()
S.price_history = {}
page_opts.set("show_stats_buffs", true)   -- flip back so load is what restores it
window.set_page("stats")
persist.load()
check("history restored", S.price_history[1] and S.price_history[1].fish[1].b == 2)
check("page_opts restored", page_opts.get("show_stats_buffs") == false)
check("page restored", window.current_page() == "goods")
page_opts.set("show_stats_buffs", true)
window.set_page("stats")

-- ---- persist: autoraid/autovoyage settings round-trip (Fix round 1, I-2) --
-- Before this fix, persist.lua carried autotrade's settings snapshot but had
-- no way to carry autoraid's or autovoyage's -- only their page_opts on/off
-- flags (auto_raid, auto_voyage, av_verbose) survived a reload; the raid
-- target/ships/convoy and the voyage risk/ship/etc were silently lost every
-- restart. Round-trip one setting from each through the same save()/load()
-- pair the block above already exercises.
local ar_mod = require("autoraid")
local av_mod = require("autovoyage")
S.autoraid = nil
S.autovoyage = nil
ar_mod.settings().target = "Uppsala"
ar_mod.settings().ships = 3
ar_mod.settings().convoy = true
av_mod.settings().risk = "max"
av_mod.settings().ship = "Njord"
persist.save()
S.autoraid = nil
S.autovoyage = nil
persist.load()
check("persist: autoraid target round-trips", S.autoraid and S.autoraid.target == "Uppsala")
check("persist: autoraid ships round-trips", S.autoraid and S.autoraid.ships == 3)
check("persist: autoraid convoy round-trips", S.autoraid and S.autoraid.convoy == true)
check("persist: autovoyage risk round-trips", S.autovoyage and S.autovoyage.risk == "max")
check("persist: autovoyage ship round-trips", S.autovoyage and S.autovoyage.ship == "Njord")
S.autoraid = nil
S.autovoyage = nil

-- Additive-change guard: a store file saved BEFORE this fix has no
-- autoraid/autovoyage keys at all -- persist.load() must still restore
-- cleanly to fresh defaults rather than erroring, since data.autoraid/
-- data.autovoyage are simply nil in that snapshot.
store.set({
  settings = { source = "auto" }, price_history = {}, page_opts = {}, page = "stats",
  -- deliberately no autotrade/autoraid/autovoyage keys, simulating a
  -- pre-Task-8 (or pre-Task-1, for autotrade) on-disk snapshot
})
local ok_legacy_load = pcall(persist.load)
check("persist.load: an old store file lacking autoraid/autovoyage keys loads without error",
      ok_legacy_load)
check("persist.load: autoraid falls back to fresh defaults when absent from the store",
      ar_mod.settings().target == "" and ar_mod.settings().ships == 2
        and ar_mod.settings().convoy == false)
check("persist.load: autovoyage falls back to fresh defaults when absent from the store",
      av_mod.settings().risk == "balanced" and av_mod.settings().ship == "")
S.autoraid = nil
S.autovoyage = nil
persist.save()   -- restore a normal on-disk snapshot for any later test in this file

-- ---- /vik registration + dispatch (Task 10) ---------------------------------
-- M.on_load() ran once already (above); it registered the real /vik command
-- and resetvikxp alias, captured by the stubs upgraded at the top of this file.
check("vik registered", registered_vik ~= nil and registered_vik.name == "/vik")
check("vik accepts args", registered_vik.accepts_args == true)

local ok_status = pcall(registered_vik.handler, "status", "/vik")
check("vik status dispatches without error", ok_status)

-- /vik source is a read now: whatever follows it, it reports the GMCP feed
-- rather than selecting a transport, and it must not error on the old
-- arguments someone's muscle memory still types.
local ok_source = pcall(registered_vik.handler, "source", "/vik")
check("vik source dispatches without error", ok_source)
local ok_oldsource = pcall(registered_vik.handler, "source mip", "/vik")
check("vik source with a retired argument does not error", ok_oldsource)

local ok_empty = pcall(registered_vik.handler, "", "/vik")
check("vik empty args falls back to usage without error", ok_empty)

printed = {}
local ok_unknown = pcall(registered_vik.handler, "bogus", "/vik")
check("vik unknown subcommand falls back to usage without error", ok_unknown)
-- Fix round 1, M-6: the usage string listed "trader [<sub>]" and
-- "voyage auto [<sub>]" but not "raid [<sub>]", so the new subcommand was
-- missing from its own help.
check("vik usage string names raid [<sub>] alongside trader and voyage auto",
      printed[1] and printed[1]:find("raid %[<sub>%]", 1, false) ~= nil, printed[1])

-- ---- /vik: stage-2 page switching + page options (Task 2) ------------------
window.set_page("city")   -- somewhere other than stats, so the dispatch below
                          -- proves it actually switches rather than no-op'ing
registered_vik.handler("stats", "/vik")
check("/vik stats switches page", window.current_page() == "stats")

-- Finding 3 (review round 1): the page-key match is case-insensitive.
window.set_page("city")
registered_vik.handler("STATS", "/vik")
check("/vik STATS (uppercase) switches page", window.current_page() == "stats")
window.set_page("stats")
registered_vik.handler("CITY", "/vik")
check("/vik CITY (uppercase) switches page", window.current_page() == "city")
window.set_page("stats")

check("page_opts.set rejects an unknown key directly", page_opts.set("no_such_opt", true) == false)

check("show_stats_xp defaults to true", page_opts.get("show_stats_xp") == true)
registered_vik.handler("set show_stats_xp off", "/vik")
check("/vik set show_stats_xp off flips it", page_opts.get("show_stats_xp") == false)

printed = {}
registered_vik.handler("opts", "/vik")
local opts_text = table.concat(printed, "\n")
check("/vik opts output contains the flipped option",
      opts_text:find("show_stats_xp = off", 1, true) ~= nil, opts_text)

local before_unknown_opt = page_opts.get("show_stats_xp")
local ok_set_unknown = pcall(registered_vik.handler, "set no_such_opt on", "/vik")
check("/vik set with an unknown opt does not error", ok_set_unknown)
check("unknown opt refused, nothing else disturbed",
      page_opts.get("show_stats_xp") == before_unknown_opt)

registered_vik.handler("set show_stats_xp on", "/vik")   -- restore for later tests

-- ---- /vik resetxp: session counters reset (XML alias body, lines 175-186) --
S.vis_session, S.kap_session, S.soe_session, S.aud_session = 10, 20, 30, 40
S.xp_session_start = 12345
registered_vik.handler("resetxp", "/vik")
check("resetxp clears sessions", S.vis_session == 0 and S.kap_session == 0
      and S.soe_session == 0 and S.aud_session == 0)
check("resetxp clears session start", S.xp_session_start == nil)

-- ---- resetvikxp alias: same reset path --------------------------------------
check("resetvikxp alias registered", registered_resetvikxp ~= nil
      and registered_resetvikxp.pattern == "^resetvikxp$")
S.vis_session = 99
registered_resetvikxp.fn()
check("resetvikxp alias resets sessions", S.vis_session == 0)

-- ---- /vik trace: toggles protocol.trace, off by default, silent otherwise --
check("trace off by default", protocol.trace() == false)
registered_vik.handler("trace on", "/vik")
check("trace on via /vik", protocol.trace() == true)
-- Tracing prints a line per routed key, so a frame under trace must still
-- apply normally rather than erroring inside the trace print.
local ok_trace_frame = pcall(protocol.on_gmcp, "Guild.Trade",
  { guild = "viking", blocks = { { good = "traced", amount = 1 } } })
check("a frame with trace on applies without error",
      ok_trace_frame and S.blocks.traced == 1)
registered_vik.handler("trace off", "/vik")
check("trace off via /vik", protocol.trace() == false)

-- ---- /vik save: delegates to persist.save -----------------------------------
S.price_history[2] = { wool = { { t = 200, b = 5, s = 6 } } }
local ok_save = pcall(registered_vik.handler, "save", "/vik")
check("vik save dispatches without error", ok_save)

-- ---- M.on_connect: the reconnect settle window + stale-list wipe (Task 3) --
-- LEGACY guild_viking.lua:4770-4788 (OnPluginConnect). Task 2's plan.lua
-- suite left this branch dormant (nothing wrote S.at_hold_until yet); this
-- is the connect hook that plan.lua's header flagged as still needed.
S.carts       = { { mode = "sell", good = "stale", return_in = 5 } }
S.trade_queue = { { good = "stale_q" } }
S.idle_carts  = { { cart_id = 99 } }
S.at_hold_until = nil
sent = {}
local before_connect = os.time()
M.on_connect()
local after_connect = os.time()
check("on_connect: sends a plain 'hp' (LEGACY:4771, distinct from the "
      .. "on_monster_died '!hp' refresh)", sent[1] == "hp" and #sent == 1, sent[1])
check("on_connect: at_hold_until is ~60s out",
      S.at_hold_until ~= nil and S.at_hold_until >= before_connect + 60
        and S.at_hold_until <= after_connect + 60, S.at_hold_until)
check("on_connect: wipes state.carts", type(S.carts) == "table" and #S.carts == 0)
check("on_connect: wipes state.trade_queue", type(S.trade_queue) == "table" and #S.trade_queue == 0)
check("on_connect: wipes state.idle_carts", type(S.idle_carts) == "table" and #S.idle_carts == 0)

-- The hold window actually blocks the auto-trader's dispatch (proving the
-- documented failure mode, not just that a field got set): with auto_trade
-- on and a fixture that WOULD dispatch, autotrader/plan.lua's own gate
-- (Task 2) reports "settling after reconnect" and sends nothing while
-- S.at_hold_until is still in the future.
local at_core_for_connect = require("autotrader.core")
local plan_for_connect = require("autotrader.plan")
page_opts.set("auto_trade", true)
S.autotrade = nil
at_core_for_connect.settings()
seed_buildings( "warehouse:1")
seed_wstock( "ore|475|100")
seed_staff( "")
seed_blocks( "")
seed_cidle( "31|1|100|200|standard")
seed_tqueue( "")
seed_daler( "1000")
seed_tgoods( "2=o:-3:0:1000:0:20")
local held = plan_for_connect.build()
check("on_connect: the hold window blocks dispatch (plan.build reports settling, sends nothing)",
      held and held.status and held.status:find("^settling after reconnect") ~= nil
        and #held.jobs == 0 and #held.commands == 0,
      held and held.status)
S.at_hold_until = nil   -- clear for later tests
page_opts.set("auto_trade", false)

-- The hold boundary walked end-to-end through tick.tick() itself (not just
-- plan.build() directly, above): 59s after connect, still held -- nothing
-- sent; 60s, the hold lifts and a real dispatch fires. Deterministic via a
-- temporary os.time() stub (same idiom guild_viking_autotrader_test.lua
-- uses), restored immediately after.
do
  local real_os_time = os.time
  local conn_now = 500000
  os.time = function() return conn_now end

  M.on_connect()   -- S.at_hold_until = conn_now + 60 = 500060
  sent = {}

  local tick_for_hold = require("autotrader.tick")
  page_opts.set("auto_trade", true)
  S.autotrade = nil
  at_core_for_connect.settings()
  seed_buildings( "warehouse:1")
  seed_wstock( "ore|475|100")
  seed_staff( "")
  seed_blocks( "")
  seed_carts( "")
  seed_cidle( "31|1|100|200|standard")
  seed_tqueue( "")
  seed_daler( "1000")
  seed_tgoods( "2=o:-3:0:1000:0:20")
  tick_for_hold.reset()

  conn_now = conn_now + 59   -- 500059, still < 500060
  tick_for_hold.tick()
  check("on_connect hold boundary (tick.tick): 59s after connect, still held -- nothing sent",
        #sent == 0, #sent)

  conn_now = conn_now + 1   -- 500060, hold lifts (now < at_hold_until is false)
  tick_for_hold.tick()
  check("on_connect hold boundary (tick.tick): 60s after connect, hold lifts -- a dispatch fires",
        #sent == 1 and sent[1] == "vtrade dispatch sell 200 ore eiriksson", sent[1])

  os.time = real_os_time
  page_opts.set("auto_trade", false)
  S.at_hold_until = nil
end

-- ---- /vik trader <sub>: LEGACY's at_config grammar, verbatim (Task 3) -----
-- guild_viking_autotrader.lua:670-724. autotrader/core.lua's settings() is
-- used directly (not through protocol.ingest) for the same reason Task 1's
-- own suite pokes S.autotrade directly: it is plugin-local settings state,
-- not wire-parsed data.
local at_core = require("autotrader.core")
S.autotrade = nil
at_core.settings()

check("/vik trader: auto_trade off by default", page_opts.get("auto_trade") == false)
printed = {}
registered_vik.handler("trader on", "/vik")
check("/vik trader on: flips page_opts.auto_trade", page_opts.get("auto_trade") == true)
check("/vik trader on: reply text verbatim", printed[1] == "[Auto-Trade] ON.", printed[1])
-- The trailing status line format string, LEGACY:713-717, verbatim.
check("/vik trader on: trailing status line",
      printed[2] == "[Auto-Trade] ON | reserve 0 | margin 3/u | min-gain 200d | carts 2 | "
        .. "pack no | use-stock no | auto-stock off | stockprio stock1st", printed[2])

printed = {}
registered_vik.handler("trader off", "/vik")
check("/vik trader off: flips page_opts.auto_trade back", page_opts.get("auto_trade") == false)
check("/vik trader off: reply text verbatim", printed[1] == "[Auto-Trade] OFF.", printed[1])

printed = {}
registered_vik.handler("trader stock on", "/vik")
check("/vik trader stock on: sets use_stock", S.autotrade.use_stock == true)
check("/vik trader stock on: reply verbatim", printed[1] == "[Auto-Trade] use-stock ON.", printed[1])
registered_vik.handler("trader stock off", "/vik")
check("/vik trader stock off: clears use_stock", S.autotrade.use_stock == false)

registered_vik.handler("trader pack on", "/vik")
check("/vik trader pack on: sets pack", S.autotrade.pack == true)
registered_vik.handler("trader pack off", "/vik")
check("/vik trader pack off: clears pack", S.autotrade.pack == false)

printed = {}
registered_vik.handler("trader debug on", "/vik")
check("/vik trader debug on: sets debug", S.autotrade.debug == true)
check("/vik trader debug on: reply verbatim",
      printed[1] == "[Auto-Trade] debug ON -- each idle tick will print why nothing was sent.",
      printed[1])
registered_vik.handler("trader debug off", "/vik")
check("/vik trader debug off: clears debug", S.autotrade.debug == false)

registered_vik.handler("trader stockroute on", "/vik")
check("/vik trader stockroute on: sets stock_route", S.autotrade.stock_route == true)
registered_vik.handler("trader stockroute off", "/vik")
check("/vik trader stockroute off: clears stock_route", S.autotrade.stock_route == false)

registered_vik.handler("trader stockpriority off", "/vik")
check("/vik trader stockpriority off: clears stock_priority", S.autotrade.stock_priority == false)
registered_vik.handler("trader stockpriority on", "/vik")
check("/vik trader stockpriority on: sets stock_priority", S.autotrade.stock_priority == true)

registered_vik.handler("trader reserve 50", "/vik")
check("/vik trader reserve <n>: sets reserve", S.autotrade.reserve == 50)
registered_vik.handler("trader margin 7", "/vik")
check("/vik trader margin <n>: sets min_margin", S.autotrade.min_margin == 7)
registered_vik.handler("trader profit 300", "/vik")
check("/vik trader profit <n>: sets min_profit", S.autotrade.min_profit == 300)
registered_vik.handler("trader carts 4", "/vik")
check("/vik trader carts <n>: sets max_carts", S.autotrade.max_carts == 4)
registered_vik.handler("trader show 9", "/vik")
check("/vik trader show <n>: sets show_n", S.autotrade.show_n == 9)
registered_vik.handler("trader autostock 500", "/vik")
check("/vik trader autostock <n>: sets auto_stock", S.autotrade.auto_stock == 500)
registered_vik.handler("trader autostock off", "/vik")
check("/vik trader autostock off: clears auto_stock", S.autotrade.auto_stock == 0)

-- log / log clear: return early, no trailing status line.
S.autotrade.log = {}
printed = {}
registered_vik.handler("trader log", "/vik")
check("/vik trader log (empty): exact message",
      printed[1] == "[Auto-Trade] log is empty." and #printed == 1, printed[1])

S.autotrade.log = { { t = "12:00", jobs = { { label = "sell 5 ore->X +10d" } } } }
printed = {}
registered_vik.handler("trader log", "/vik")
check("/vik trader log (non-empty): header + one entry, no trailing status line",
      printed[1] == "[Auto-Trade] recent activity:"
        and printed[2] == "  12:00 sell 5 ore->X +10d"
        and #printed == 2, table.concat(printed, "|"))

printed = {}
registered_vik.handler("trader log clear", "/vik")
check("/vik trader log clear: clears the log and replies, no trailing status line",
      #S.autotrade.log == 0 and printed[1] == "[Auto-Trade] log cleared." and #printed == 1,
      printed[1])

-- Unrecognized subcommand: usage message, no state change, no trailing
-- status line.
local reserve_before = S.autotrade.reserve
printed = {}
local ok_bad_trader = pcall(registered_vik.handler, "trader bogus", "/vik")
check("/vik trader bogus: does not error", ok_bad_trader)
check("/vik trader bogus: usage message verbatim",
      printed[1] == "[Auto-Trade] usage: atrade on|off | stock on|off | stockpriority on|off | "
        .. "autostock <n>|off | pack on|off | debug on|off | reserve <n> | margin <n> | "
        .. "profit <n> | carts <n> | show <n> | log [clear]" and #printed == 1,
      printed[1])
check("/vik trader bogus: no state disturbed", S.autotrade.reserve == reserve_before)

-- "status" is explicitly accepted (falls through to the trailing status
-- line, same as an empty rest at the plan-config level -- NOT the same as
-- bare `/vik trader`, which opens the menu; see below).
printed = {}
registered_vik.handler("trader status", "/vik")
check("/vik trader status: prints the trailing status line, no usage error",
      #printed == 1 and printed[1]:find("^%[Auto%-Trade%]") ~= nil, printed[1])

-- ---- /vik trader (bare): opens the settings menu (Task 3) ------------------
S.autotrade = nil
at_core.settings()
page_opts.set("auto_trade", false)
last_menu_open = nil
registered_vik.handler("trader", "/vik")
check("/vik trader (bare): opens a menu", last_menu_open ~= nil)
check("/vik trader (bare): menu title", last_menu_open and last_menu_open.title == "Auto-Trade Settings")
check("/vik trader (bare): 13 items, LEGACY's atrade_menu_build order",
      last_menu_open and #last_menu_open.items == 13, last_menu_open and #last_menu_open.items)
if last_menu_open then
  local labels = menu_item_labels(last_menu_open)
  check("/vik trader (bare): item labels reflect current OFF/default settings",
        labels[1] == "Auto-Trade: off" and labels[2] == "Pack deals per cart: no"
          and labels[3] == "Use warehouse stock: no" and labels[4] == "Auto-stock over: off"
          and labels[5] == "Batch stock sells: dispatch" and labels[6] == "Stock priority: stock1st"
          and labels[7] == "Min margin (/u): >=3" and labels[8] == "Min gain per job: 200d"
          and labels[9] == "Daler reserve: 0" and labels[10] == "Max carts: 2"
          and labels[11] == "Movers shown: 6" and labels[12] == "Show log: no"
          and labels[13] == "Clear log",
        table.concat(labels, "|"))
end

-- Selecting the "on" item toggles the flag, saves, and reopens the menu in
-- place (LEGACY:11377's rebuild-in-place) -- the SAME on_select call this
-- test drives is exactly what a menu.lua Enter keypress would invoke.
last_menu_open.on_select("on")
check("/vik trader menu: selecting 'on' flips auto_trade", page_opts.get("auto_trade") == true)
check("/vik trader menu: reopens itself in place (a new menu is open)", last_menu_open ~= nil)
if last_menu_open then
  check("/vik trader menu: reopened item reflects the new ON state",
        menu_item_labels(last_menu_open)[1] == "Auto-Trade: ON")
end

-- Cycling knobs: margin 3 -> 5 (AT_MARGIN_STEPS = {1,2,3,5,8,10,15,20}).
last_menu_open.on_select("margin")
check("/vik trader menu: cycling margin 3 -> 5", S.autotrade.min_margin == 5, S.autotrade.min_margin)
-- Clear log via the menu.
S.autotrade.log = { "one", "two" }
last_menu_open.on_select("clearlog")
check("/vik trader menu: clearlog empties the log", #S.autotrade.log == 0)

page_opts.set("auto_trade", false)   -- restore default for later tests
last_menu_open = nil

-- ---- /vik raid <sub>: LEGACY's ar_config grammar (Task 8) -----------------
-- Full gate/branch/menu coverage lives in guild_viking_autoraid_test.lua;
-- this section only proves the DISPATCH WIRING (init.lua's `sub_lower ==
-- "raid"` branch, added right between "trader" and the "voyage auto" prefix
-- match, matching LEGACY's own trade/raid/voyage order) actually reaches
-- autoraid.lua's M.raid_command/M.config, and that the immediate-persist
-- behavior survives that whole path, not just a direct M.config() call.
local autoraid = require("autoraid")
S.autoraid = nil

check("/vik raid: auto_raid off by default", page_opts.get("auto_raid") == false)
printed = {}
stored = nil
registered_vik.handler("raid on", "/vik")
check("/vik raid on: flips page_opts.auto_raid", page_opts.get("auto_raid") == true)
check("/vik raid on: reply text verbatim", printed[1] == "[Auto-Raid] ON.", printed[1])
check("/vik raid on: persists IMMEDIATELY through the full /vik dispatch path "
      .. "(no separate /vik save needed)",
      stored ~= nil and stored.page_opts and stored.page_opts.auto_raid == true)

printed = {}
registered_vik.handler("raid off", "/vik")
check("/vik raid off: flips page_opts.auto_raid back", page_opts.get("auto_raid") == false)
check("/vik raid off: reply text verbatim", printed[1] == "[Auto-Raid] OFF.", printed[1])

registered_vik.handler("raid target Uppsala", "/vik")
check("/vik raid target <name>: sets the target", S.autoraid.target == "Uppsala")
registered_vik.handler("raid convoy on", "/vik")
check("/vik raid convoy on: sets convoy", S.autoraid.convoy == true)
registered_vik.handler("raid ships 3", "/vik")
check("/vik raid ships <n>: sets ships", S.autoraid.ships == 3)

printed = {}
local ok_bad_raid = pcall(registered_vik.handler, "raid bogus", "/vik")
check("/vik raid bogus: does not error", ok_bad_raid)
check("/vik raid bogus: usage message verbatim",
      printed[1] == "[Auto-Raid] usage: araid on|off | convoy on|off | ships <n>|all | target <name> | mode fixed|rotate"
        and #printed == 1, printed[1])

-- ---- /vik raid (bare): opens the settings menu -----------------------------
S.autoraid = nil
page_opts.set("auto_raid", false)
last_menu_open = nil
registered_vik.handler("raid", "/vik")
check("/vik raid (bare): opens a menu", last_menu_open ~= nil)
check("/vik raid (bare): menu title", last_menu_open and last_menu_open.title == "Auto-Raid Settings")
check("/vik raid (bare): 6 items, LEGACY's araid_menu_build order plus the Mode entry",
      last_menu_open and #last_menu_open.items == 6, last_menu_open and #last_menu_open.items)

last_menu_open.on_select("on")
check("/vik raid menu: selecting 'on' flips auto_raid", page_opts.get("auto_raid") == true)
check("/vik raid menu: reopens itself in place", last_menu_open ~= nil)

page_opts.set("auto_raid", false)   -- restore default for later tests
S.autoraid = nil
last_menu_open = nil

-- ---- /vik voyage auto <sub>: dispatch prefix-parsing (Task 7) -------------
-- init.lua's own new branch (M.vik_command): "voyage auto" strips the "auto"
-- token case-insensitively and forwards the remainder to
-- autovoyage.voyage_command -- the exact same "trader <sub>" shape used
-- above, plus the one bit of new parsing (the "auto" token itself). Plain
-- "/vik voyage" (no "auto") must be untouched: it still falls through to
-- POPUP_NAMES and toggles the voyage popup, not the automation.
local av_core = require("autovoyage")
S.autovoyage = nil

check("/vik voyage auto: off by default", page_opts.get("auto_voyage") == false)
printed = {}
registered_vik.handler("voyage auto on", "/vik")
check("/vik voyage auto on: exact reply", printed[1] == "[Auto-Voyage] ON.", printed[1])
check("/vik voyage auto on: flag flipped", page_opts.get("auto_voyage") == true)

printed = {}
registered_vik.handler("voyage auto off", "/vik")
check("/vik voyage auto off: exact reply", printed[1] == "[Auto-Voyage] OFF.", printed[1])
check("/vik voyage auto off: flag flipped", page_opts.get("auto_voyage") == false)

-- Case-insensitivity of the "auto" token itself, and tolerance of extra
-- internal whitespace -- both handled by init.lua's own prefix match, not
-- by autovoyage.lua.
printed = {}
registered_vik.handler("voyage AUTO  on", "/vik")
check("/vik voyage AUTO  on (mixed case, extra space): still reaches the ON reply",
      printed[1] == "[Auto-Voyage] ON.", printed[1])
page_opts.set("auto_voyage", false)

-- A bare "/vik voyage" (no "auto" token) is untouched -- still the
-- POPUP_NAMES toggle, not the automation. popups.toggle's own behavior is
-- exercised in guild_viking_popups_test.lua; this file has never called
-- require("wm") before, so a minimal local stub (same shape as that suite's
-- own preamble) lets popups.toggle run without erroring here too -- we only
-- need proof this path did NOT reach autovoyage (no menu opened, flag
-- untouched).
package.loaded["wm"] = {
  popup = {
    is_open = function() return false end,
    open = function() end,
    close = function() end,
  },
}
last_menu_open = nil
local ok_bare_voyage = pcall(registered_vik.handler, "voyage", "/vik")
check("/vik voyage (bare, no auto token): does not error", ok_bare_voyage)
check("/vik voyage (bare, no auto token): does not open the auto-voyage menu", last_menu_open == nil)
check("/vik voyage (bare, no auto token): does not touch the automation flag",
      page_opts.get("auto_voyage") == false)

-- "/vik voyage autosomething" (starts with "auto" but not a whitespace/end
-- boundary) must NOT be treated as the auto-voyage sub-dispatch either.
last_menu_open = nil
local ok_autolike = pcall(registered_vik.handler, "voyage automatic", "/vik")
check("/vik voyage automatic: does not error", ok_autolike)
check("/vik voyage automatic: does not open the auto-voyage menu (word-boundary guard)",
      last_menu_open == nil)

-- Unrecognized subcommand under "voyage auto": usage message, verbatim.
printed = {}
local ok_bad_voyage = pcall(registered_vik.handler, "voyage auto bogus", "/vik")
check("/vik voyage auto bogus: does not error", ok_bad_voyage)
check("/vik voyage auto bogus: exact usage message",
      printed[1] == "[Auto-Voyage] usage: avoyage on|off | balanced|max|safe | "
        .. "abyssal on|off | ship <name>|auto | verbose on|off | log", printed[1])

-- Bare "/vik voyage auto" opens the settings menu (the one deliberate
-- adaptation this module's header discloses).
S.autovoyage = nil
last_menu_open = nil
registered_vik.handler("voyage auto", "/vik")
check("/vik voyage auto (bare): opens a menu", last_menu_open ~= nil)
check("/vik voyage auto (bare): menu title",
      last_menu_open and last_menu_open.title == "Auto-Voyage Settings")
check("/vik voyage auto (bare): 13 items",
      last_menu_open and #last_menu_open.items == 13, last_menu_open and #last_menu_open.items)
last_menu_open = nil
S.autovoyage = nil

-- ---- /vik herd <sub>: LEGACY's ah_config grammar --------------------------
-- Full gate/branch/planner/menu coverage lives in
-- guild_viking_autoherd_test.lua; this section only proves the DISPATCH
-- WIRING (init.lua's `sub_lower == "herd"` branch) actually reaches
-- autoherd.lua's M.herd_command/M.config, and that the immediate-persist
-- behavior survives that whole path -- the same thing the trader/raid/voyage
-- blocks above prove for their own automations. It matters most here: `herd
-- on` is the switch that authorises Auto-Herd to SPEND DALER, and it was the
-- one directive set in this file with no dispatch test at all.
local autoherd_cmd = require("autoherd")
S.autoherd = nil
page_opts.set("auto_herd", false)

check("/vik herd: auto_herd off by default", page_opts.get("auto_herd") == false)
printed = {}
stored = nil
registered_vik.handler("herd on", "/vik")
check("/vik herd on: flips page_opts.auto_herd", page_opts.get("auto_herd") == true)
check("/vik herd on: reply text verbatim", printed[1] == "[Auto-Herd] ON.", printed[1])
check("/vik herd on: persists IMMEDIATELY through the full /vik dispatch path "
      .. "(no separate /vik save needed)",
      stored ~= nil and stored.page_opts and stored.page_opts.auto_herd == true)

printed = {}
registered_vik.handler("herd off", "/vik")
check("/vik herd off: flips page_opts.auto_herd back", page_opts.get("auto_herd") == false)
check("/vik herd off: reply text verbatim", printed[1] == "[Auto-Herd] OFF.", printed[1])

printed = {}
stored = nil
registered_vik.handler("herd reserve 3000", "/vik")
check("/vik herd reserve <n>: sets the reserve", S.autoherd.reserve == 3000,
      S.autoherd and S.autoherd.reserve)
check("/vik herd reserve <n>: reply text verbatim",
      printed[1] == "[Auto-Herd] reserve = 3000", printed[1])
check("/vik herd reserve <n>: persists immediately through the dispatch path",
      stored ~= nil and stored.autoherd and stored.autoherd.reserve == 3000)

registered_vik.handler("herd goal fert", "/vik")
check("/vik herd goal <stat>: sets the goal", S.autoherd.goal == "fert", S.autoherd.goal)
registered_vik.handler("herd quality off", "/vik")
check("/vik herd quality off: clears buy_quality", S.autoherd.buy_quality == false)
registered_vik.handler("herd bldg byre target 8", "/vik")
check("/vik herd bldg <name> target <n>: sets the per-building target",
      S.autoherd.buildings.byre and S.autoherd.buildings.byre.target == 8)

printed = {}
local ok_bad_herd = pcall(registered_vik.handler, "herd bogus", "/vik")
check("/vik herd bogus: does not error", ok_bad_herd)
check("/vik herd bogus: usage message verbatim",
      printed[1] == "[Auto-Herd] usage: aherd on|off | goal "
        .. "<yield|fert|con|hard|vigor|balanced> | reserve <n> | keep <n> | "
        .. "gen <n|auto> | age <n|off> | trait "
        .. "<any|off|prolific|hardy|bountiful|purebred> | stock on|off | "
        .. "cross on|off | quality on|off | feed on|off | feedticks <n> | "
        .. "margin <n> | bldg <name> on|off|target <n>|keep <n> | "
        .. "debug on|off | log [clear] | status | refresh | forecast | replace on|off|status|reset|preview | model <building> output N|share 0..1",
      printed[1])

do
  local old_enabled, old_send = gmcp.enabled, gmcp.send
  local old_seen, old_connected = S.livestock_seen, mud_connected
  local old_save = require("persist").save
  local requests, saves = 0, 0
  gmcp.enabled = function() return true end
  gmcp.send = function(pkg, data)
    requests = requests + 1
    check("herd refresh dispatch uses Add only", pkg == "Core.Supports.Add" and #data == 1 and data[1] == "Guild 1")
    return true
  end
  require("persist").save = function() saves = saves + 1 end
  S.livestock_seen, mud_connected = false, true
  local settings, master = S.autoherd, page_opts.get("auto_herd")
  printed = {}
  registered_vik.handler("herd refresh", "/vik")
  check("herd refresh dispatch bootstraps without livestock or settings changes", requests == 1 and saves == 0
    and not S.livestock_seen and S.autoherd == settings and page_opts.get("auto_herd") == master)
  check("herd refresh reply is not confirmation", printed[1]:find("not confirmed", 1, true) ~= nil)
  registered_vik.handler("herd refresh", "/vik")
  check("herd refresh dispatch debounces", requests == 1)
  gmcp.enabled, gmcp.send = old_enabled, old_send
  S.livestock_seen, mud_connected = old_seen, old_connected
  require("persist").save = old_save
end

-- ---- /vik herd (bare): opens the settings menu ----------------------------
S.autoherd = nil
page_opts.set("auto_herd", false)
last_menu_open = nil
registered_vik.handler("herd", "/vik")
check("/vik herd (bare): opens a menu", last_menu_open ~= nil)
check("/vik herd (bare): menu title",
      last_menu_open and last_menu_open.title == "Auto-Herd Settings")

last_menu_open.on_select("on")
check("/vik herd menu: selecting 'on' flips auto_herd", page_opts.get("auto_herd") == true)
check("/vik herd menu: reopens itself in place", last_menu_open ~= nil)

page_opts.set("auto_herd", false)   -- restore the default for later tests
S.autoherd = nil
last_menu_open = nil

-- =============================================================================
-- Task 9: the safety lock + the integration ordering test.
--
-- The shipped default is all three automations OFF (page_opts.lua's own
-- defaults: auto_trade/auto_raid/auto_voyage all false). The safety lock
-- proves that default is inert: driving MANY notify.countdown_tick()s over a
-- fixture that is genuinely, simultaneously actionable by all three
-- automations sends nothing at all. "Genuinely actionable" is not asserted,
-- it is DEMONSTRATED -- the same fixture, unchanged, is driven again with
-- each automation flipped on (one at a time, then all three together) and
-- shown to send the exact expected command. A fixture that sent nothing for
-- an unrelated reason (missing city data, no idle ship, no charted node...)
-- would pass the zero-sends assertion for the wrong reason; this is the
-- exact weakness called out as having been found three times already in
-- this stage, so it is not enough to build empty state and call it done.
--
-- Every wire field below goes through protocol.ingest with the REAL
-- handlers already required at the top of this file (handlers.trade,
-- handlers.voyage, handlers.kingdom, handlers.city) -- never a direct S.xxx
-- poke. S.autotrade/S.autoraid/S.autovoyage remain the one documented
-- exception (plugin-local automation SETTINGS, not wire data), exactly as
-- every per-automation suite in this stage already establishes.
-- =============================================================================
local trade_tick2 = require("autotrader.tick")
local at_core2 = require("autotrader.core")
local raid2 = require("autoraid")
local voyage2 = require("autovoyage")

-- handlers/voyage.lua's M.VOYAGE field order (27 pipe-delimited fields) --
-- same shape as guild_viking_autovoyage_test.lua's own VOYAGE_FIELDS/
-- set_voyage helpers, duplicated here in miniature rather than requiring
-- that test file.
local SAFETY_VOYAGE_FIELDS = {
  "state", "ship_id", "ship_name", "contract_name", "contract_type", "danger",
  "x", "y", "width", "height", "hull", "morale", "supplies", "stress",
  "crew_alive", "crew_max", "steps", "next_move", "threat_name", "threat_level",
  "threat_pressure", "paused_type", "weather_key", "captain", "identity",
  "crew_traits", "ship_traits",
}
local function safety_set_voyage(overrides)
  local f = {
    state = "idle", ship_id = 1, ship_name = "Ship1", contract_name = "c",
    contract_type = "raid", danger = 0, x = 0, y = 0, width = 0,
    height = 0, hull = 100, morale = 100, supplies = 100, stress = 0,
    crew_alive = 1, crew_max = 1, steps = 0, next_move = 0,
    threat_name = "", threat_level = 0, threat_pressure = 0, paused_type = "",
    weather_key = "", captain = "", identity = "",
  }
  for k, v in pairs(overrides or {}) do f[k] = v end
  fixture_gmcp("Guild.Voyage", { voyage = {
    state = f.state, ship_id = tonumber(f.ship_id), ship_name = f.ship_name,
    contract_name = f.contract_name, contract_type = f.contract_type,
    danger = tonumber(f.danger), x = tonumber(f.x), y = tonumber(f.y),
    width = tonumber(f.width), height = tonumber(f.height),
    hull = tonumber(f.hull), morale = tonumber(f.morale),
    supplies = tonumber(f.supplies), hull_stress = tonumber(f.stress),
    crew_alive = tonumber(f.crew_alive), crew_max = tonumber(f.crew_max),
    steps_sailed = tonumber(f.steps), next_move_in = tonumber(f.next_move),
    threat_name = f.threat_name, threat_level = tonumber(f.threat_level),
    threat_pressure = tonumber(f.threat_pressure), paused_type = f.paused_type,
    weather_key = f.weather_key, captain_style = f.captain,
    ship_identity = f.identity,
  } })
end

-- handlers/voyage.lua's M.SHIPS field order (14 pipe-delimited fields) --
-- same shape as guild_viking_autoraid_test.lua's own ship_entry helper.
local function safety_ship_entry(name)
  return table.concat({ name, "2", "docked", "", "0", "", "8", "0", "0", "0",
    "", "0", "0", "100" }, "|")
end

-- Builds ONE fixture actionable by all three automations at once:
--   trade  -- a warehouse-stock cart ready to dispatch (same numbers as
--             guild_viking_autotrader_test.lua's setup_single_dispatch_fixture)
--   raid   -- one idle docked longship and a chosen target
--   voyage -- an active voyage paused at a resolvable, non-harbor node
-- The three do not share any state the others read (trade uses idle carts/
-- warehouse stock/prices; raid uses S.ships/S.autoraid; voyage uses
-- S.voyage_status/S.voyage_chart_*/S.voyage_wait, never S.ships), so building
-- all three at once cannot make one automation's send depend on another's.
local function build_safety_fixture()
  S.autotrade, S.autoraid, S.autovoyage = nil, nil, nil
  S.at_hold_until = nil
  trade_tick2.reset()

  -- Trade: explicit direct resets of every S field autotrader/core.lua and
  -- autotrader/plan.lua read (S.buildings, S.wstock/wstock_by_good,
  -- S.staff_list, S.blocks, S.carts, S.idle_carts, S.trade_queue, S.daler,
  -- S.trade_goods/_tgoods_last, S.dispatch_cd_expires_at) BEFORE this
  -- fixture's own ingests, not after. Review round 2, Critical: without
  -- this, deleting every ingest call below still left the trade leg
  -- sending its expected command, because the identical values were left
  -- behind, unreset, by the earlier "on_connect hold boundary" test 400+
  -- lines above (guild_viking_test.lua:802-833, the same warehouse/WSTOCK/
  -- CIDLE/DALER/TGOODS numbers) -- this fixture was PASSING BY ACCIDENT on
  -- 400-line-old ambient state, not by its own ingests. TGOODS in
  -- particular cannot be relied on to self-clear across two ingest calls
  -- inside the same wall-clock 2s (handlers/trade.lua's own burst-batching
  -- window, M.TGOODS's `now - S._tgoods_last > 2` gate): it merges into
  -- whatever S.trade_goods already held rather than replacing it, so an
  -- explicit direct reset is the only way this fixture can be provably
  -- self-contained against a deleted or reordered ingest call. This is the
  -- one place in this fixture direct S pokes are used for WIRE state, not
  -- just plugin-local settings -- authorized specifically for this
  -- hermeticity fix, not a general exception to the protocol.ingest rule.
  S.buildings, S.wstock, S.wstock_by_good = {}, {}, {}
  S.staff_list, S.blocks = {}, {}
  S.carts, S.idle_carts, S.trade_queue = {}, {}, {}
  S.daler = 0
  S.trade_goods, S._tgoods_last = {}, nil
  S.dispatch_cd_expires_at = nil

  at_core2.settings()
  seed_buildings( "warehouse:1,dock:1")
  seed_wstock( "ore|475|100")
  seed_staff( "")
  seed_blocks( "")
  seed_carts( "")
  seed_cidle( "31|1|100|200|standard")
  seed_tqueue( "")
  seed_daler( "1000")
  seed_tgoods( "2=o:-3:0:1000:0:20")

  -- Raid.
  seed_ships( safety_ship_entry("Drakkar1"))
  raid2.settings().target = "Uppsala"

  -- Voyage: chart with a non-harbor node paused for resolution.
  seed_chart(3, 1, "explore", { "H.X" })
  safety_set_voyage({ x = "1", y = "0" })
  fixture_gmcp("Guild.Voyage", { voyage_wait = "island",
                                vresolve = { "scout", "plunder" } })
end

local TRADE_SEND = "vtrade dispatch sell 200 ore eiriksson"
local RAID_SEND = "vlongship raid Drakkar1 Uppsala"
local VOYAGE_SEND = "vvoyage resolve plunder"

-- ---- Actionability proof, one automation at a time -------------------------
-- Each automation, alone, sends its expected command against the SAME
-- fixture -- proving the fixture is genuinely eligible for each of the three,
-- not just constructed to look rich.
page_opts.set("auto_trade", false); page_opts.set("auto_raid", false); page_opts.set("auto_voyage", false)
build_safety_fixture()
page_opts.set("auto_trade", true)
sent = {}
trade_tick2.tick()
check("safety-lock fixture is actionable: trade alone sends the expected dispatch",
      #sent == 1 and sent[1] == TRADE_SEND, table.concat(sent, "|"))
page_opts.set("auto_trade", false)

build_safety_fixture()
page_opts.set("auto_raid", true)
sent = {}
raid2.tick()
check("safety-lock fixture is actionable: raid alone sends the expected dispatch",
      #sent == 1 and sent[1] == RAID_SEND, table.concat(sent, "|"))
page_opts.set("auto_raid", false)

build_safety_fixture()
page_opts.set("auto_voyage", true)
sent = {}
voyage2.tick()
check("safety-lock fixture is actionable: voyage alone sends the expected dispatch",
      #sent == 1 and sent[1] == VOYAGE_SEND, table.concat(sent, "|"))
page_opts.set("auto_voyage", false)

-- ---- The safety lock: all three OFF (the shipped default), many ticks -----
-- The SHIPPED default lives in page_opts.defaults (the static table the
-- module was loaded with), not in whatever the CURRENT flag happens to be at
-- this point in a long test file that has already toggled all three on and
-- off repeatedly above. Checking page_opts.defaults directly, rather than
-- page_opts.get(), is what actually catches a page_opts.lua edit that ships
-- one of these three ON by default -- get() only reflects this file's own
-- explicit set(false) restores, which would mask exactly that mutation.
check("safety lock: the SHIPPED DEFAULT (page_opts.defaults, untouched by any "
      .. "set() call anywhere in this file) has all three automations off",
      page_opts.defaults.auto_trade == false and page_opts.defaults.auto_raid == false
        and page_opts.defaults.auto_voyage == false)

build_safety_fixture()
page_opts.set("auto_trade", false); page_opts.set("auto_raid", false); page_opts.set("auto_voyage", false)
check("safety lock: all three automations are off going into this test",
      page_opts.get("auto_trade") == false and page_opts.get("auto_raid") == false
        and page_opts.get("auto_voyage") == false)
sent = {}
for _ = 1, 25 do
  notify.countdown_tick()
end
check("SAFETY LOCK: 25 countdown_tick()s over a fixture proven actionable by all "
      .. "three automations, with all three at their default OFF, send ZERO mud.send calls",
      #sent == 0, table.concat(sent, "|"))

-- ---- Ordering: all three ON, one tick, at most one action each, in --------
-- LEGACY's trade/raid/voyage order (MAIN 2884-2890) -------------------------
build_safety_fixture()
page_opts.set("auto_trade", true)
page_opts.set("auto_raid", true)
page_opts.set("auto_voyage", true)
sent = {}
notify.countdown_tick()
check("ordering: exactly one send from each automation, trade first, raid second, "
      .. "voyage last -- LEGACY's own order",
      #sent == 3 and sent[1] == TRADE_SEND and sent[2] == RAID_SEND and sent[3] == VOYAGE_SEND,
      table.concat(sent, " | "))

page_opts.set("auto_trade", false)
page_opts.set("auto_raid", false)
page_opts.set("auto_voyage", false)
S.autotrade, S.autoraid, S.autovoyage = nil, nil, nil
S.at_hold_until = nil
trade_tick2.reset()
sent = {}

-- ---- /vik status: automation on/off + last-action/next-eligible (Task 9) --
-- Lera-only extension (see init.lua's print_automation_status comment) --
-- no LEGACY /vik status equivalent exists for these three.
S.autotrade, S.autoraid, S.autovoyage = nil, nil, nil
page_opts.set("auto_trade", true)
page_opts.set("auto_raid", false)
page_opts.set("auto_voyage", true)
-- phase=idle/pending=0 below comes from trade_tick2.reset() a few lines
-- above (the ordering test's own cleanup), not from this call -- this just
-- ensures S.autotrade exists so the settings table is in its normal shape.
at_core2.settings()
raid2.settings().last_dispatch = { t = "12:34", target = "Uppsala", n = 2, convoy = false }
raid2.settings().last = 0
voyage2.settings().log = { "12:00 explore -> A2" }
voyage2.settings().last = 0
local herd2 = require("autoherd")
herd2.settings().log = { { t = "11:45", desc = "stock sheep into sheepfold" } }
herd2.settings().last = 0
local war2 = require("autowar")
war2.settings().status = "battle live (auto-fight off)"
war2.settings().last = 0

printed = {}
registered_vik.handler("status", "/vik")
check("/vik status: Auto-Trade line reports ON, idle phase, no pending, ready",
      printed[4] == "  Auto-Trade: ON | phase=idle pending=0 | next: ready", printed[4])
check("/vik status: Auto-Raid line reports off + the last dispatch + ready",
      printed[5] == "  Auto-Raid: off | last dispatch: 2 ships to Uppsala at 12:34 | next: ready",
      printed[5])
check("/vik status: Auto-Voyage line reports ON + the last log entry + ready",
      printed[6] == "  Auto-Voyage: ON | last: 12:00 explore -> A2 | next: ready", printed[6])
-- Auto-Herd is the only automation that spends daler, and /vik help
-- advertises status as showing "each automation's on/off state and
-- last-action/next-eligible summary" -- which was false by omission while
-- this line did not exist.
check("/vik status: Auto-Herd line reports off + the last log entry + ready",
      printed[7] == "  Auto-Herd: off | last: 11:45 stock sheep into sheepfold | next: ready",
      printed[7])
-- Auto-War is the fifth automation, and /vik help makes the same promise for
-- it as for the other four, so status has to account for its line too.
check("/vik status: Auto-War line reports off + phase + the last action + ready",
      printed[8] == "  Auto-War: off | phase=idle"
        .. " | last: battle live (auto-fight off) | next: ready",
      printed[8])
check("/vik status: exactly 8 lines printed (3 ingestion + 5 automation)",
      #printed == 8, #printed)

-- "next: Ns" -- not yet ready -- when a real dispatch happened recently.
raid2.settings().last = os.time()
printed = {}
registered_vik.handler("status", "/vik")
check("/vik status: Auto-Raid next check counts down from a recent dispatch, not 'ready'",
      printed[5]:find("^  Auto%-Raid: off | last dispatch: 2 ships to Uppsala at 12:34 | next: %d+s$")
        ~= nil,
      printed[5])

page_opts.set("auto_trade", false)
page_opts.set("auto_voyage", false)
S.autotrade, S.autoraid, S.autovoyage = nil, nil, nil

-- ---- stats_window contract: has_data / render_guild_stats (Task 3) ---------
-- Stage 2: render_guild_stats draws a truncated view of pages.stats.lines(w)
-- itself (not a separate, hand-rolled 3-line summary), via ui.text_ansi.
check("has_data is a function", type(M.has_data) == "function")
check("render_guild_stats is a function", type(M.render_guild_stats) == "function")
check("has_data true after ingestion", M.has_data() == true)

ui.rect = function(x, y, w, h) return { x = x, y = y, w = w, h = h } end
ui.text = function() end
local ansi_drawn = {}
ui.text_ansi = function(r, s) ansi_drawn[#ansi_drawn + 1] = s end

local stats_page = require("pages.stats")

S.vis, S.vis_session, S.kap, S.kap_session = 100, 5, 200, 10
S.soe, S.soe_session, S.aud, S.aud_session = 300, 15, 400, 20
S.ldng, S.mldng = 3, 4

local full_stats_lines = stats_page.lines(40)
check("(setup) the full stats page has more lines than a 2-row rect fits",
      #full_stats_lines > 2, #full_stats_lines)

ansi_drawn = {}
local used_clipped = M.render_guild_stats({ x = 0, y = 0, w = 40, h = 2 }, {})
check("render_guild_stats clips to rect height", used_clipped == 2, used_clipped)
check("render_guild_stats draws exactly the rows it reports using",
      #ansi_drawn == used_clipped, #ansi_drawn)
check("render_guild_stats's first drawn row matches pages.stats.lines(w)[1]",
      ansi_drawn[1] == full_stats_lines[1], ansi_drawn[1])

ansi_drawn = {}
local used_full = M.render_guild_stats({ x = 0, y = 0, w = 40, h = 1000 }, {})
check("render_guild_stats returns <= rect height", used_full <= 1000, used_full)
check("a tall-enough rect gets every produced line",
      used_full == #full_stats_lines, used_full)
check("first drawn row still matches pages.stats.lines(w)[1] (plain-field rect)",
      ansi_drawn[1] == full_stats_lines[1], ansi_drawn[1])

-- Dual rect-shape handling (rect_dims): a plain-field rect (rect.x/.y/.w/.h,
-- used above) and a colon-method rect (rect:x()/.../rect:h(), conui's real
-- shape, used by window.lua/pages) must both work identically.
local function make_colon_rect(x, y, w, h)
  return { x = function() return x end, y = function() return y end,
           w = function() return w end, h = function() return h end }
end
ansi_drawn = {}
local used_colon = M.render_guild_stats(make_colon_rect(0, 0, 40, 1000), {})
check("render_guild_stats works with a colon-method rect", used_colon == #full_stats_lines, used_colon)
check("colon-method rect's first drawn row matches pages.stats.lines(w)[1]",
      ansi_drawn[1] == full_stats_lines[1], ansi_drawn[1])

check("render_guild_stats zero height returns 0",
      M.render_guild_stats({ x = 0, y = 0, w = 40, h = 0 }, {}) == 0)

-- ---- hp-bar gagging: registration reads gag_status_lines, re-registers on --
-- flip (Task 3's stage-1 ruling, see init.lua's combat_trigger_opts/
-- register_combat_triggers/reregister_combat_triggers). M.on_load() (above)
-- already registered the 8 combat.triggers once with the default
-- gag_status_lines = true.
local function combat_regs_since(from_id)
  local out = {}
  for id = from_id + 1, trigger_reg_count do
    out[#out + 1] = trigger_regs[id]
  end
  return out
end

check("gag_status_lines defaults to true", page_opts.get("gag_status_lines") == true)

-- on_load's register_combat_triggers() runs BEFORE the notify.triggers loop
-- (init.lua), so the 8 combat triggers are always ids 1-8, whatever else
-- trigger.add gets called for afterward (notify.triggers registers 15 more
-- of its own right after -- which is why combat_regs_since(0) would
-- over-capture here; ids 1-8 specifically are combat's).
local first_8 = {}
for id = 1, 8 do first_8[id] = trigger_regs[id] end
check("exactly 8 combat triggers were registered on_load (ids 1-8)",
      #first_8 == 8, #first_8)
local all_gagged_by_default = true
for _, r in ipairs(first_8) do
  if not (r.opts and r.opts.omit_from_output == true) then all_gagged_by_default = false end
end
check("all 8 combat triggers registered gagged (omit_from_output) by default",
      all_gagged_by_default)

-- Only the 8 combat trigger ids (1-8) are expected to be torn down by a
-- gag flip -- notify's 15 triggers (registered right after, in the same
-- on_load) are a different subsystem entirely and must be left alone.
local combat_ids_before_flip = { 1, 2, 3, 4, 5, 6, 7, 8 }

registered_vik.handler("set gag_status_lines off", "/vik")
check("gag_status_lines flipped off", page_opts.get("gag_status_lines") == false)

local all_old_ids_removed = true
for _, id in ipairs(combat_ids_before_flip) do
  if not removed_trigger_ids[id] then all_old_ids_removed = false end
end
check("flipping the opt removes the old 8 combat trigger registrations",
      all_old_ids_removed)
check("notify's triggers were NOT removed by the gag flip",
      not removed_trigger_ids[9], removed_trigger_ids[9])

local reregistered_off = combat_regs_since(trigger_reg_count - 8)
check("re-registration adds exactly 8 new triggers", #reregistered_off == 8, #reregistered_off)
local none_gagged_after_off = true
for _, r in ipairs(reregistered_off) do
  if r.opts ~= nil then none_gagged_after_off = false end
end
check("re-registered triggers carry no omit_from_output once the opt is off",
      none_gagged_after_off)

local reg_count_before_on = trigger_reg_count
registered_vik.handler("set gag_status_lines on", "/vik")
check("gag_status_lines flipped back on", page_opts.get("gag_status_lines") == true)
local reregistered_on = combat_regs_since(reg_count_before_on)
check("flipping back on re-registers 8 more triggers", #reregistered_on == 8, #reregistered_on)
local all_gagged_after_on = true
for _, r in ipairs(reregistered_on) do
  if not (r.opts and r.opts.omit_from_output == true) then all_gagged_after_on = false end
end
check("re-registered triggers are gagged again once the opt is back on",
      all_gagged_after_on)

-- ---- Fix 1 regression: a persisted gag_status_lines=false must be honored --
-- by the INITIAL combat-trigger registration in on_load, not just by a later
-- reregister_combat_triggers() call. register_combat_triggers() historically
-- ran before persist.load() in on_load, so a freshly-loaded persisted value
-- never reached the first registration -- only a subsequent /vik set flip
-- would. The shared M's on_load must not be re-run (Task 10 comment above),
-- and dofile-ing init.lua again against the SAME cached "protocol" module
-- would trip protocol.lua's duplicate-handler guard (every handlers.* module
-- registers unconditionally at file scope). So: save the persisted state via
-- the real /vik path, clear this plugin's require cache, and dofile a
-- genuinely independent second instance (fresh protocol/state/page_opts/...)
-- through on_load exactly once. It shares only the global stub tables
-- (store/trigger/mip/gmcp/...), so its persist.load() sees the same saved
-- store data, and its combat-trigger registrations land in the same
-- trigger_regs capture, right after whatever the shared M already used.
registered_vik.handler("set gag_status_lines off", "/vik")   -- real /vik path
check("gag_status_lines off before save", page_opts.get("gag_status_lines") == false)
persist.save()

local cleared_modules = {
  "protocol", "state", "page_opts", "window", "persist", "market", "combat",
  "notify", "util", "handlers.trade", "handlers.voyage", "handlers.kingdom",
  "handlers.city",
}
for _, name in ipairs(cleared_modules) do package.loaded[name] = nil end

local before_m2_regs = trigger_reg_count
local M2 = dofile("3scapes/guild_viking/init.lua")
M2.on_load()

local page_opts2 = real_require("page_opts")
check("fresh instance's persist.load restored gag_status_lines=false during on_load",
      page_opts2.get("gag_status_lines") == false)

local m2_first_8 = {}
for id = before_m2_regs + 1, before_m2_regs + 8 do
  m2_first_8[#m2_first_8 + 1] = trigger_regs[id]
end
check("M2's on_load registered 8 combat triggers", #m2_first_8 == 8, #m2_first_8)
local any_gagged_m2 = false
for _, r in ipairs(m2_first_8) do
  if r.opts and r.opts.omit_from_output then any_gagged_m2 = true end
end
check("initial combat-trigger registration honors the persisted gag=false "
      .. "(no omit_from_output)", not any_gagged_m2, any_gagged_m2)

pcall(M2.on_unload)
page_opts.set("gag_status_lines", true)   -- restore the shared instance's default

-- ---- on_unload: full cleanup, must not error (Task 10; call LAST) ----------
local cancels_before_unload = #timer_cancels
local ok_unload, unload_err = pcall(M.on_unload)
check("on_unload does not error", ok_unload, unload_err)
-- on_unload cancels the countdown timer -- the only one left since the MIP
-- batch sweep went. Asserting the count is what proves on_unload ran to
-- completion rather than aborting early: every teardown step after it
-- (combat triggers, notify triggers, the /vik command registration) is
-- silent, so "did not error" alone cannot see it.
check("on_unload cancelled its timer",
      #timer_cancels - cancels_before_unload == 1,
      #timer_cancels - cancels_before_unload)

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING TESTS PASSED")
