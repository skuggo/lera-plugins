-- guild_viking handler-module census. Run from the lera-plugins repo root with
-- LERA_ROOT pointing at a built Lera checkout.
--
-- This file used to be a 72-case behavioural suite for handlers/city.lua's MIP
-- decoders as well. Those decoders are gone -- every key they read now arrives
-- over GMCP, and the per-panel guild_viking_gmcp_*_test.lua suites cover the
-- writers that replaced them -- so what is left is the census: which MIP keys
-- still have a handler at all, and which have a GMCP writer.
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

-- ---- lera API stubs (same shape as guild_viking_kingdom_test.lua) ---------
local dirty_count = 0
ui = { dirty = function() dirty_count = dirty_count + 1 end }
local stored = nil
store = {
  load = function() end,
  get = function() return stored end,
  set = function(d) stored = d end,
  save = function() end,
}
lera = { time = function() return 1000 end, version = function() return "test" end }
buffer = { color_print = function() end }
mud = { send = function() end }
local mip_handlers, mip_handler_count = {}, 0
mip = {
  on = function(code, cb)
    mip_handlers[code] = cb
    mip_handler_count = mip_handler_count + 1
    return mip_handler_count
  end,
  off = function() end,
  enabled = function() return true end,
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
  fire = function(pkg, data) gmcp_handlers[pkg](pkg, data) end,
}
trigger = { add = function() return 1 end, remove = function() end }
timer = { every = function() return 1 end, remove = function() end }
alias = { add = function() return 1 end, remove = function() end }
plugin = { get = function() return nil end }
local real_require = require
require = function(name)
  if name == "command" then
    return { register = function() return 1 end, unregister = function() return true end,
             get = function() return nil end, list = function() return {} end }
  end
  return real_require(name)
end

local protocol = require("protocol")
-- init.lua's RESERVED set: the module-level convention fields. Only two are
-- left now that the MIP-era members went with the transport.
local RESERVED_KEYS = { _market_seam = true, _gmcp = true }
local S = require("state").S
local city = require("handlers.city")
for key, fn in pairs(city._gmcp or {}) do
  protocol.gmcp_handler(key, fn)
end

-- BLOT, over the transport that carries it: state/reset_in/filled/total.
protocol.on_gmcp("Guild.City", { guild = "viking", full = 1,
  blot = { state = "open", reset_in = 300, filled = 4, total = 9 } })

-- ---- Census: porting-completeness lock across all four handler modules ---
local trade = require("handlers.trade")
local voyage = require("handlers.voyage")
local kingdom = require("handlers.kingdom")

-- The MIP keys that still have a handler -- the thing this census exists to
-- keep at zero, now that the plugin has no MIP intake to fall back on.
--
-- None are left. The last two went together: VRELICS was MIP-only because GMCP
-- carried relic ids and only the MIP serializer knew their display names --
-- the payload carries those names now, in vrelic_names -- and CELLAR had no
-- emitter anywhere in the mudlib and was simply dead.
--
-- TGOODS and the Sea Chart (VCHART/VCHH plus the VCR row pattern) were here
-- before them. Their GMCP sources landed -- Guild.TradeGoods, and
-- Guild.Voyage's voyage_chart/voyage_chart_rows -- so they moved to writers
-- like everything else.
--
-- An empty list is the point, not an oversight: it is what licenses the plugin
-- to stop reading MIP at all. Anything appearing here again means a payload
-- regressed to MIP-only and the BBE intake would have to come back.
local EXPECTED_EXACT_KEYS = {}

-- No pattern-dispatched MIP key has a handler any more. The territory map's
-- rows and edges, the city plan's terrain, the campaign map's terrain and the
-- Sea Chart's rows are all carried whole by their Guild.* packages, and their
-- patterns are declared retired instead.
local EXPECTED_PATTERNS = {}

local function collect_exact_keys()
  local keys = {}
  for _, mod in ipairs({ trade, voyage, kingdom, city }) do
    for key, _ in pairs(mod) do
      -- The module-level convention fields. `_gmcp` is censused separately
      -- below: counting it here made this census churn by one every time a
      -- handler module gained its first GMCP writer, which says nothing about
      -- porting completeness -- what this census is for.
      if not RESERVED_KEYS[key] then
        keys[#keys + 1] = key
      end
    end
  end
  table.sort(keys)
  return keys
end

local function collect_patterns()
  local pats = {}
  for _, mod in ipairs({ trade, voyage, kingdom, city }) do
    for _, p in ipairs(mod._patterns or {}) do
      pats[#pats + 1] = p.pattern
    end
  end
  table.sort(pats)
  return pats
end

local function same_set(list, expected)
  if #list ~= #expected then return false, ("count %d ~= %d"):format(#list, #expected) end
  local sorted_expected = {}
  for i, v in ipairs(expected) do sorted_expected[i] = v end
  table.sort(sorted_expected)
  for i, v in ipairs(list) do
    if v ~= sorted_expected[i] then
      return false, ("mismatch at %d: %s ~= %s"):format(i, v, sorted_expected[i])
    end
  end
  return true
end

local actual_keys = collect_exact_keys()
local ok_keys, err_keys = same_set(actual_keys, EXPECTED_EXACT_KEYS)
check("census exact keys match hardcoded list", ok_keys, err_keys)
check("census exact key count is 0", #actual_keys == 0, #actual_keys)

-- ---- Census: which MIP keys have a GMCP writer ----------------------------
-- The migration's own progress bar. A key listed here is fed by GMCP when the
-- server sends its panel, and protocol.ingest's per-key latch then suppresses
-- the MIP copy; a key absent from it is still MIP-only. This is the list to
-- extend as each panel's writers land, and it is what makes an accidentally
-- unregistered writer visible -- init.lua registers `_gmcp` for every handler
-- module, so a writer defined but left out of the table would otherwise just
-- silently never run.
local EXPECTED_GMCP_WRITERS = {
  -- Guild.Settlement (9 MIP keys; 10 GMCP keys, since SROLES is a composite
  -- over `sroles` and `sroles_meta`)
  "SETTLERS", "SETTLERX", "SACTIONS", "SHPLOTS", "SCONSUME", "SPROJ",
  "SEVENTS", "SCIVICS", "SROLES",
  -- Guild.Map (1, composite over all eleven of its payload keys)
  "VMAP",
  -- Guild.Fleet (4)
  "SHIPS", "SUPG", "RAIDLOG", "RTARGETS",
  -- Guild.Roster (10)
  "STAFF", "BONDS", "TRAIN", "COURIER", "SPY", "VFIND", "HIRD", "THRALLS",
  "THRALL_FOLLOWER", "VARANG",
  -- Guild.Trade (10) and Guild.TradeGoods (1, split per lineage server-side)
  "CARTS", "TQUEUE", "CIDLE", "CUPG", "ROUTES", "BLOCKS", "REFINERY", "MARKET",
  "INCOMING", "WSTOCK", "TGOODS",
  -- Guild.City (21, including the city plan -- one composite where MIP spread
  -- it over CPLAN/CPT/CPB/CPU/CPP with a commit protocol)
  "BUILDS", "BUILDINGS", "MONUMENTS", "BLOT", "FARM", "DCYCLE", "NEXTTICK",
  "CDTIME", "PRODUCTION", "ERRAND", "MISSIONS", "RBUILD", "UPKEEP", "RUPKEEP",
  "HEAT", "BDMG", "RAID", "PATROL", "GARRISON", "WEATHER", "CPLAN",
  -- Guild.Voyage (19, the Sea Chart included; VRELICS is a composite over
  -- vrelics and vrelic_names, which is what let it stop being MIP-only)
  "VOYAGE", "LONGSHIP", "VOYAGE_WAIT", "VOFFERS", "VRESOLVE", "VQPATH",
  "VSAGA", "VMEM", "VCURIOS", "VGOODS", "VAIDS", "VRUNES", "VBOONS",
  "VSAILED", "VSPOILS", "VREAGENT", "FLEET_RENOWN", "VCHART", "VRELICS",
  -- Guild.Kingdom (9, including the campaign war map -- one composite where
  -- MIP spread it over WMAP/WMR/WMO/WMQ/WMU/WMP/WMPL/WSG/WSPOIL) and
  -- Guild.War (BATTLE, routed as a whole package)
  "GRUDGES", "STANDINGS", "VREP", "DIPLO", "ARMY", "DYNASTY", "WAR", "WMAP",
  "BATTLE",
  -- Guild.State (4 -- its hp/points/gxp/ledung groups have no MIP twin and are
  -- owned by combat.lua's protocol-independent triggers)
  "DALER", "GOD_POWER", "VMREG", "VMNEW",
}

local function collect_gmcp_writers()
  local keys = {}
  for _, mod in ipairs({ trade, voyage, kingdom, city }) do
    for key in pairs(mod._gmcp or {}) do keys[#keys + 1] = key end
  end
  table.sort(keys)
  return keys
end

local actual_writers = collect_gmcp_writers()
local ok_w, err_w = same_set(actual_writers, EXPECTED_GMCP_WRITERS)
check("census GMCP writers match hardcoded list", ok_w, err_w)

local actual_patterns = collect_patterns()
local ok_pats, err_pats = same_set(actual_patterns, EXPECTED_PATTERNS)
check("census patterns match hardcoded list", ok_pats, err_pats)
check("census pattern count is 0", #actual_patterns == 0, #actual_patterns)

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING CENSUS TESTS PASSED")
