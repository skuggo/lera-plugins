-- guild_viking Guild.City writers unit tests. Run from the lera-plugins repo
-- root with LERA_ROOT pointing at a built Lera checkout.
--
-- The cityplan cluster is covered at the end of this file.

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

local RESERVED = RESERVED_KEYS
for _, name in ipairs({ "handlers.trade", "handlers.kingdom", "handlers.voyage",
                        "handlers.city" }) do
  local mod = require(name)
  for key, fn in pairs(mod._gmcp or {}) do
    protocol.gmcp_handler(key, fn)
  end
end

local function city(payload)
  payload.guild = "viking"
  protocol.on_gmcp("Guild.City", payload)
end

-- ---- builds ----------------------------------------------------------------
city({ builds = { { id = "smithy", tier = 2, mats = 40, done = 15, secs = 300,
                    total = 900, detail = "timber:10/20,iron:5/20" } } })
local b = S.pending_builds[1]
check("builds id lands on bldg_id", b.bldg_id == "smithy")
check("builds mats/done land on mats_total/mats_done",
      b.mats_total == 40 and b.mats_done == 15)
check("builds secs lands on complete_at_secs", b.complete_at_secs == 300)
check("builds total lands on total_build_secs", b.total_build_secs == 900)
check("builds detail parses into per-good rows", #b.mats == 2
      and b.mats[1].good == "timber" and b.mats[1].done == 10
      and b.mats[1].need == 20 and b.mats[2].good == "iron")
-- -1 means "awaiting materials" and 0 means "finalizing"; a default of 0 would
-- silently turn the first into the second.
city({ builds = { { id = "apiary" } } })
check("a build with no secs defaults to -1, not 0",
      S.pending_builds[1].complete_at_secs == -1
      and S.pending_builds[1].tier == 1)

-- ---- buildings -------------------------------------------------------------
city({ buildings = { { id = "smithy", tier = 3 }, { id = "apiary", tier = 1 } } })
check("buildings become a bldg -> tier lookup",
      S.buildings.smithy == 3 and S.buildings.apiary == 1)

-- ---- monuments_cap + monuments_list ---------------------------------------
city({ monuments_cap = 5,
       monuments_list = { "Runestone of Havn", "  Great Hall  ", "" } })
check("monument cap", S.monument_cap == 5)
-- Names are trimmed and blanks dropped, matching the MIP handler exactly.
check("monument names are trimmed and blanks dropped",
      #S.monuments == 2 and S.monuments[1] == "Runestone of Havn"
      and S.monuments[2] == "Great Hall", #S.monuments)
-- Two independent keys over a delta transport.
city({ monuments_cap = 6 })
check("a cap-only delta leaves the list standing",
      S.monument_cap == 6 and #S.monuments == 2)

-- ---- blot ------------------------------------------------------------------
city({ blot = { state = "ready", reset_in = 1200, filled = 4, total = 9 } })
check("blot state lands on blot_status", S.blot_status == "ready")
check("blot fields", S.blot_reset_in == 1200 and S.blot_filled == 4
      and S.blot_total == 9)

-- ---- farm_meta + farm_plots ------------------------------------------------
-- MIP packed the meta into the plot list as a "meta|" pseudo-entry.
city({
  farm_meta = { wmod = 15, water = 40, water_cap = 100, fert = 3, fert_cap = 10 },
  farm_plots = { { coord = "a1", name = "chanterelle", time_left = 90,
                   fertilized = 1, wilt_left = 300 } },
})
check("farm meta wmod", S.farm_wmod == 15)
check("a plot's name lands on shroom", S.farm_plots[1].shroom == "chanterelle")
check("farm plot fields", S.farm_plots[1].coord == "a1"
      and S.farm_plots[1].time_left == 90 and S.farm_plots[1].fertilized == 1
      and S.farm_plots[1].wilt_left == 300)
-- wilt_left defaults to -1 ("not wilting"), which is not 0 ("wilting now").
city({ farm_plots = { { coord = "b2", name = "morel" } } })
check("a plot with no wilt_left defaults to -1, not 0",
      S.farm_plots[1].wilt_left == -1)
check("a plots-only delta leaves the meta standing", S.farm_wmod == 15)

-- ---- dcycle / nexttick / cdtime -------------------------------------------
city({ dcycle = { name = "harvest", secs = 600 } })
check("dcycle secs lands on demand_cycle_in",
      S.demand_cycle == "harvest" and S.demand_cycle_in == 600)
city({ nexttick = 42 })
check("nexttick", S.next_tick_in == 42)
-- cdtime is a duration the client turns into an absolute deadline; 0 means "no
-- cooldown", not "expires now".
city({ cdtime = 30 })
check("a positive cdtime becomes a deadline",
      S.dispatch_cd == 30 and S.dispatch_cd_expires_at ~= nil
      and S.dispatch_cd_expires_at >= os.time() + 29)
city({ cdtime = 0 })
check("a zero cdtime clears the deadline rather than setting one now",
      S.dispatch_cd == 0 and S.dispatch_cd_expires_at == nil)

-- ---- production ------------------------------------------------------------
-- Production is raw uncapped output, not net consumption. Legacy signed
-- display values remain readable, but must never authorize the herd planner.
city({ production = { { good = "timber", amount = 12 },
                      { good = "grain", amount = -4 } } })
check("production becomes a signed good -> amount lookup",
      S.production.timber == 12 and S.production.grain == -4)

do
  local real_time, now = os.time, 20000
  os.time = function() return now end
  require("state").reset_connection()
  local function evidence(at, seq)
    local e = (S.herd_observed or {}).production
    return e and e.at == at and e.seq == seq
  end
  local function fresh()
    city({ production = { { good = "grain", amount = 12 },
                          { good = "salted_fish", amount = 0 } } })
  end
  fresh()
  check("production writer records receipt and raw output",
    evidence(20000, 1) and S.production.grain == 12 and S.production.salted_fish == 0)
  now = 20010
  city({ nexttick = 30 })
  city({})
  protocol.on_gmcp("Guild.City", { guild = "berserker", production = {} })
  check("omitted or foreign production does not refresh evidence", evidence(20000, 1))
  fresh()
  check("identical production advances receipt", evidence(20010, 2))
  fresh()
  check("same-second production advances sequence", evidence(20010, 3))
  city({ production = {} })
  check("empty actual array confirms complete zero production",
    next(S.production) == nil and evidence(20010, 4))

  local malformed = {
    { "false", false },
    { "string", "grain:12" },
    { "number", 12 },
    { "mapping", { grain = 12 } },
    { "mixed keys", { { good = "grain", amount = 12 }, extra = true } },
    { "hole", { [1] = { good = "grain", amount = 12 },
                  [3] = { good = "fish", amount = 2 } } },
    { "zero index", { [0] = { good = "grain", amount = 12 } } },
    { "fractional index", { [1.5] = { good = "grain", amount = 12 } } },
    { "non-record", { false } },
    { "missing good", { { amount = 12 } } },
    { "empty good", { { good = "", amount = 12 } } },
    { "whitespace good", { { good = " grain ", amount = 12 } } },
    { "numeric good", { { good = 1, amount = 12 } } },
    { "duplicate good", { { good = "grain", amount = 12 },
                           { good = "grain", amount = 13 } } },
    { "missing amount", { { good = "grain" } } },
    { "string amount", { { good = "grain", amount = "12" } } },
    { "boolean amount", { { good = "grain", amount = false } } },
    { "negative", { { good = "grain", amount = -4 } } },
    { "NaN", { { good = "grain", amount = 0 / 0 } } },
    { "infinity", { { good = "grain", amount = math.huge } } },
    { "negative infinity", { { good = "grain", amount = -math.huge } } },
    { "partially valid", { { good = "grain", amount = 12 }, { good = "fish" } } },
  }
  for _, case in ipairs(malformed) do
    fresh()
    check("valid production restores proof before " .. case[1],
      (S.herd_observed or {}).production ~= nil)
    now = now + 1
    city({ production = case[2] })
    check("invalid production clears proof: " .. case[1], S.herd_observed.production == nil)
    city({ nexttick = 20 })
    check("omission cannot restore proof after " .. case[1], S.herd_observed.production == nil)
  end
  city({ production = { { good = "grain", amount = -4 } } })
  check("negative legacy display does not authorize planner",
    S.production.grain == -4 and S.herd_observed.production == nil)
  fresh()
  local displayed = S.production
  require("state").reset_connection()
  check("reconnect retains display but clears production proof",
    S.production == displayed and S.herd_observed.production == nil)
  now = now + 10
  city({ nexttick = 10 })
  check("reconnect omission cannot authorize retained production", S.herd_observed.production == nil)
  fresh()
  check("fresh production after reconnect establishes new proof", evidence(now, 1))
  os.time = real_time
end

-- ---- errand ----------------------------------------------------------------
city({ errand = { id = 7, label = "Deliver mead", reward = 250, secs = 1800,
                  origin = "Havn", town = "Birka", good = "mead", qty = 12 } })
check("errand secs lands on expires_in", S.errand.expires_in == 1800)
check("errand origin/town land on origin_town/target_town",
      S.errand.origin_town == "Havn" and S.errand.target_town == "Birka")
check("errand good/qty land on reward_good/reward_qty",
      S.errand.reward_good == "mead" and S.errand.reward_qty == 12)
check("errand scalar fields", S.errand.id == 7
      and S.errand.label == "Deliver mead" and S.errand.reward == 250)

-- ---- missions --------------------------------------------------------------
-- `goods` is a mapping here where MIP flattened it into a "good:qty," string.
city({ missions = { { id = 3, label = "Supply Uppsala", rep = 15, reward = 400,
                      secs = 2400, origin = "Havn", town = "Uppsala",
                      goods = { grain = 30, iron = 5 } } } })
local m = S.missions[1]
check("mission rep lands on reward_rep", m.reward_rep == 15)
check("mission secs lands on expires_in", m.expires_in == 2400)
check("mission origin/town land on origin_town/target_town",
      m.origin_town == "Havn" and m.target_town == "Uppsala")
check("mission goods become a want_goods lookup",
      m.want_goods.grain == 30 and m.want_goods.iron == 5)
check("mission scalar fields", m.id == 3 and m.label == "Supply Uppsala"
      and m.reward == 400)

-- ---- rbuild ----------------------------------------------------------------
-- Keyed "kind:vid" for the Trade Routes render; the key is built by the
-- writer, as it was over MIP, rather than being a field.
city({ rbuild = { { vid = "havn", vname = "Havn", kind = "road", tier = 2,
                    mats = 30, done = 10, secs = 240, total = 600,
                    detail = "timber:10/30" },
                  { vid = "havn", vname = "Havn", kind = "fort", tier = 1,
                    mats = 20, done = 20, secs = -1, total = 0 } } })
check("route builds are keyed kind:vid, so one village can have both",
      S.route_builds["road:havn"] ~= nil and S.route_builds["fort:havn"] ~= nil)
check("route build fields", S.route_builds["road:havn"].name == "Havn"
      and S.route_builds["road:havn"].tier == 2
      and S.route_builds["road:havn"].mats_total == 30
      and S.route_builds["road:havn"].mats_done == 10
      and S.route_builds["road:havn"].complete_at_secs == 240
      and S.route_builds["road:havn"].total_build_secs == 600
      and #S.route_builds["road:havn"].mats == 1)
check("a route build awaiting materials keeps its -1",
      S.route_builds["fort:havn"].complete_at_secs == -1)

-- ---- upkeep / rupkeep / heat ----------------------------------------------
city({ upkeep = { roster = 10, community = 20, throne = 5, roads = 8,
                  forts = 12, total = 55 } })
check("upkeep breakdown", S.upkeep.roster == 10 and S.upkeep.community == 20
      and S.upkeep.throne == 5 and S.upkeep.roads == 8 and S.upkeep.forts == 12
      and S.upkeep.total == 55)
city({ rupkeep = 17 })
check("rupkeep", S.route_upkeep == 17)
city({ heat = { 3, 0, 7, 1 } })
check("heat is a plain number array",
      #S.heat == 4 and S.heat[1] == 3 and S.heat[3] == 7)

-- ---- bdmg / raid / patrol / garrison --------------------------------------
city({ bdmg = { { id = "palisade", pct = 40 } } })
check("bdmg id lands on bldg_id",
      S.bdmg[1].bldg_id == "palisade" and S.bdmg[1].pct == 40)

city({ raid = { secs = 900, faction = "Jomsviking", strength = 7 } })
check("raid secs lands on raid_in", S.raid_in == 900
      and S.raid_faction == "Jomsviking" and S.raid_strength == 7)
-- No inbound raid is -1, not 0 -- 0 means "landing now".
city({ raid = { faction = "" } })
check("a raid with no secs defaults to -1, not 0", S.raid_in == -1)

city({ patrol = { count = 3, remaining = 120 } })
check("patrol", S.patrol.count == 3 and S.patrol.remaining == 120)

city({ garrison = { stationed = 12, pool = 4, cap = 20, power = 88 } })
check("garrison pool lands on garrison_free", S.garrison_free == 4)
check("garrison power lands on garrison_defpower", S.garrison_defpower == 88)
check("garrison fields", S.garrison_stationed == 12 and S.garrison_cap == 20)

-- ---- weather ---------------------------------------------------------------
city({ weather = { season = "winter", weather = "snow", strength = 2 } })
check("weather strength lands on weather_str",
      S.season == "winter" and S.weather == "snow" and S.weather_str == 2)

-- ---- cityplan --------------------------------------------------------------
-- Over MIP this was a multi-frame burst with a commit protocol (CPLAN opened a
-- pending plan, CPT/CPB/CPU accumulated, CPEND committed after counting rows).
-- GMCP sends it whole, which is why the server deliberately does not translate
-- CPEND at all.
city({
  cityplan = { enabled = 1, dim = 10, placed = 4, cap = 12, coast_side = 2,
               moat = 1, wall = 0, gate = 5, mood_delta = -3, margin = 2 },
  cityplan_terrain = { ".f^wc", "WGMB." },
  cityplan_buildings = {
    { id = "BLDG_SMITHY", x = 2, y = 3, w = 2, h = 2, pal = "r",
      glyph = "S", name = "Smithy" },
    { id = "BLDG_APIARY", x = 1, y = 1 },
  },
  cityplan_placeable = { { id = "BLDG_MOAT", pal = "b", glyph = "M",
                           name = "Moat" } },
  cityplan_perks = "sturdy,warm",
})
local cp = S.city_plan
check("the plan is committed outright, with no pending copy",
      cp ~= nil and S.cp_pending == nil)
check("cityplan coast_side lands on coast", cp.coast == 2)
check("cityplan mood_delta lands on mood", cp.mood == -3)
check("cityplan scalars", cp.dim == 10 and cp.placed == 4 and cp.cap == 12
      and cp.gate == 5 and cp.margin == 2)
-- Three 0/1 ints become booleans; 0 is truthy in Lua, so `wall` is the one
-- that catches a naive assignment.
check("enabled/moat/wall become booleans",
      cp.enabled == true and cp.moat == true and cp.wall == false)
-- The rows carry the grid's natural glyphs -- '^' for hill, where MIP
-- substituted 'H' to dodge a wire-delimiter collision. popups/cityplan.lua
-- maps both to the same cell, so the rows pass through untouched.
check("terrain rows keep their natural glyphs",
      #cp.rows == 2 and cp.rows[1] == ".f^wc" and cp.rows[2] == "WGMB.")
check("placed buildings", #cp.blds == 2 and cp.blds[1].id == "BLDG_SMITHY"
      and cp.blds[1].x == 2 and cp.blds[1].y == 3 and cp.blds[1].w == 2
      and cp.blds[1].h == 2 and cp.blds[1].pal == "r"
      and cp.blds[1].glyph == "S" and cp.blds[1].name == "Smithy")
-- The wire no longer carries `name` for every building: _cp_name() is a pure
-- Title-Case render of the id (city_plan.h), so the client rebuilds it and the
-- server saves ~40% of the frame. capitalize() only touches the first letter of
-- each word, so an already-upper id comes back unchanged bar the underscore.
check("a nameless building is rebuilt from its id, server-style",
      cp.blds[2].name == "BLDG APIARY" and cp.blds[2].w == 1
      and cp.blds[2].pal == "e" and cp.blds[2].glyph == "?")
check("placeable buildings", #cp.unplaced == 1
      and cp.unplaced[1].id == "BLDG_MOAT" and cp.unplaced[1].name == "Moat")
check("perks", cp.perks == "sturdy,warm")
-- Perks are sent only when there are any, so their absence means none.
city({ cityplan = { enabled = 1, dim = 8 }, cityplan_terrain = { "..." } })
check("a plan with no perks key has empty perks", S.city_plan.perks == "")


-- ---- envelope --------------------------------------------------------------
protocol.on_gmcp("Guild.City", { guild = "berserker",
                                 buildings = { { id = "foreign", tier = 9 } } })
check("a foreign guild's frame is dropped", S.buildings.foreign == nil)

if failures > 0 then
  print("FAILURES: " .. failures)
  os.exit(1)
end
print("ALL GUILD_VIKING GMCP CITY TESTS PASSED")
