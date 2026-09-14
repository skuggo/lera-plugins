-- guild_viking Guild.Voyage writers unit tests. Run from the lera-plugins repo
-- root with LERA_ROOT pointing at a built Lera checkout.
--
-- VRELICS is not covered: it stays on MIP, because GMCP carries relic ids and
-- the display-name lookup is server-side logic the mudlib keeps in the MIP
-- serializer alone.
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

local function voy(payload)
  payload.guild = "viking"
  protocol.on_gmcp("Guild.Voyage", payload)
end

-- ---- voyage + its two trait arrays -----------------------------------------
-- The trait lists are containers, which a record used as a container element
-- may not hold, so the server deletes them from the record and sends each as
-- its own key.
S.mip_voyage_seen = false
voy({
  voyage = { state = "sailing", ship_id = 1, ship_name = "Ormen",
             contract_name = "Raid Fjordholm", contract_type = "raid",
             danger = 3, x = 5, y = 6, width = 20, height = 20,
             hull = 80, morale = 70, supplies = 60, hull_stress = 10,
             crew_alive = 4, crew_max = 5, steps_sailed = 12, next_move_in = 30,
             threat_name = "Kraken", threat_level = 2, threat_pressure = 40,
             paused_type = "storm", weather_key = "gale",
             captain_style = "Erik", ship_identity = "proud" },
  voyage_crew_traits = { "brave", "loyal" },
  voyage_ship_traits = { "swift" },
})
local v = S.voyage_status
check("voyage record arrives", v ~= nil and v.state == "sailing")
-- Five renames, all carrying integers or strings into similarly-shaped
-- fields, so each is asserted on its own.
check("voyage hull_stress lands on stress", v.stress == 10, v.stress)
check("voyage steps_sailed lands on steps", v.steps == 12, v.steps)
check("voyage next_move_in lands on next_move", v.next_move == 30, v.next_move)
check("voyage captain_style lands on captain", v.captain == "Erik", v.captain)
check("voyage ship_identity lands on identity", v.identity == "proud", v.identity)
check("voyage scalar fields", v.ship_id == 1 and v.ship_name == "Ormen"
      and v.contract_name == "Raid Fjordholm" and v.contract_type == "raid"
      and v.danger == 3 and v.x == 5 and v.y == 6 and v.hull == 80
      and v.morale == 70 and v.supplies == 60 and v.crew_alive == 4
      and v.crew_max == 5 and v.threat_name == "Kraken"
      and v.threat_level == 2 and v.threat_pressure == 40
      and v.weather_key == "gale")
check("voyage traits rejoin from their own keys",
      #v.crew_traits == 2 and v.crew_traits[1] == "brave"
      and v.crew_traits[2] == "loyal" and #v.ship_traits == 1
      and v.ship_traits[1] == "swift")
-- Fleet renown travels as its own key, not on this record.
check("voyage renown is zeroed here", v.renown == 0)
-- The three popups and autovoyage all gate their no-data branch on this flag.
check("voyage data sets the seen flag", S.mip_voyage_seen == true)
-- The MIP handler inferred the wait status from paused_type as a fallback.
check("paused_type seeds voyage_wait", S.voyage_wait == "storm")
-- An empty record is how the server says "no active voyage".
voy({ voyage = {} })
check("an empty voyage record clears the status",
      S.voyage_status == nil and S.voyage_wait == "")

-- voyage_wait sorts after VOYAGE, so an explicit value in the same frame wins
-- over the paused_type fallback.
voy({ voyage = { state = "paused", paused_type = "storm" },
      voyage_wait = "becalmed" })
check("an explicit voyage_wait wins over the paused_type fallback",
      S.voyage_wait == "becalmed", S.voyage_wait)

-- ---- longship + its per-ship trait arrays ----------------------------------
-- Each trait row names the ship id it belongs to, so the rows are deliberately
-- given here out of order and interleaved between two ships.
voy({
  longship = {
    { id = 3, name = "Ormen", tier = 2, state = "sailing", target = "Havn",
      secs = 300, crew = 4, hired_crew = 1, safe = 1,
      voyage_identity = "proud", captain_style = "Erik",
      saga_title = "Saga of Ormen", saga_raids = 6 },
    { id = 8, name = "Naglfar" },
  },
  longship_crew_traits = {
    { id = 8, trait = "green" },
    { id = 3, trait = "brave" },
    { id = 3, trait = "loyal" },
  },
  longship_ship_traits = { { id = 3, trait = "swift" } },
})
local ls = S.voyage_longships[1]
check("longship id lands on ship_id", ls.ship_id == 3)
check("longship secs lands on return_in", ls.return_in == 300)
check("longship voyage_identity lands on identity", ls.identity == "proud")
check("longship captain_style lands on captain", ls.captain == "Erik")
check("longship scalar fields", ls.name == "Ormen" and ls.tier == 2
      and ls.state == "sailing" and ls.target == "Havn" and ls.crew == 4
      and ls.hired_crew == 1 and ls.safe == 1
      and ls.saga_title == "Saga of Ormen" and ls.saga_raids == 6)
check("traits group on their own ship", #ls.crew_traits == 2
      and ls.crew_traits[1] == "brave" and ls.crew_traits[2] == "loyal"
      and #ls.ship_traits == 1
      and #S.voyage_longships[2].crew_traits == 1
      and S.voyage_longships[2].crew_traits[1] == "green"
      and #S.voyage_longships[2].ship_traits == 0)
check("longship defaults", S.voyage_longships[2].tier == 1
      and S.voyage_longships[2].state == "docked"
      and S.voyage_longships[2].renown == 0)

-- ---- voffers + voffers_ship ------------------------------------------------
voy({ voffers_ship = "Ormen",
      voffers = { { index = 0, type = "raid", name = "Raid Fjordholm",
                    danger = 3, difficulty = "medium", fit_code = 1 } } })
check("voffers ship and list", S.voyage_offers ~= nil
      and S.voyage_offers.ship == "Ormen" and #S.voyage_offers.list == 1
      and S.voyage_offers.list[1].name == "Raid Fjordholm"
      and S.voyage_offers.list[1].danger == 3
      and S.voyage_offers.list[1].difficulty == "medium")
check("voffers fit_code lands on fit", S.voyage_offers.list[1].fit == 1)
-- A missing fit is "ready" (3), not "suicidal" (0), matching the MIP handler.
voy({ voffers = { { index = 1, type = "trade", name = "Run" } } })
check("a missing fit_code defaults to ready, not suicidal",
      S.voyage_offers.list[1].fit == 3)
-- Only `voffers` itself may clear the list: a frame carrying just a changed
-- ship name must not read as "no offers".
voy({ voffers_ship = "Naglfar" })
check("a ship-only delta renames without clearing the offers",
      S.voyage_offers ~= nil and S.voyage_offers.ship == "Naglfar"
      and #S.voyage_offers.list == 1)
voy({ voffers = {} })
check("an empty offer list clears the offers", S.voyage_offers == nil)
-- GMCP deltas may deliver the ship name before the offer list. Keep that
-- sibling value so the auto-voyage tick can match contracts to its ship.
voy({ voffers_ship = "Sverige" })
voy({ voffers = { { index = 2, type = "hunt", name = "Sea Hunt",
                   danger = 9, difficulty = "legendary", fit_code = 3 } } })
check("voffers list reuses a ship-only delta",
      S.voyage_offers ~= nil and S.voyage_offers.ship == "Sverige"
      and S.voyage_offers.list[1].index == 2)

-- ---- string lists ----------------------------------------------------------
voy({ vresolve = { "fight", "flee", "parley" } })
check("vresolve", #S.voyage_resolve_options == 3
      and S.voyage_resolve_options[2] == "flee")
voy({ vqpath = { "N", "N", "E", "SE" } })
check("vqpath", #S.voyage_queue == 4 and S.voyage_queue[4] == "SE")
voy({ vsaga = { "The fleet set sail.", "A storm was weathered." } })
check("vsaga", #S.voyage_saga == 2)
voy({ vmem = { "Remembered the reefs." } })
check("vmem", #S.voyage_memory == 1)
voy({ vcurios = { "carved whalebone" } })
check("vcurios", #S.voyage_curios == 1)
-- MIP's caps are display bounds the pages rely on and survive the transport.
local long = {}
for i = 1, 250 do long[i] = "line " .. i end
voy({ vsaga = long })
check("vsaga cap at 200", #S.voyage_saga == 200, #S.voyage_saga)

-- ---- count mappings --------------------------------------------------------
-- name -> count on the wire, a {name, count} list in state. Sorted by name: a
-- pairs() walk has no defined order, so an unsorted list would reorder itself
-- between frames with nothing in the data to explain it.
voy({ vgoods = { timber = 12, amber = 3, iron = 7 } })
check("vgoods becomes a name/count list", #S.voyage_goods == 3)
check("vgoods is ordered by name, not by pairs()",
      S.voyage_goods[1].name == "amber" and S.voyage_goods[2].name == "iron"
      and S.voyage_goods[3].name == "timber",
      S.voyage_goods[1].name .. "," .. S.voyage_goods[2].name)
check("vgoods counts", S.voyage_goods[1].count == 3
      and S.voyage_goods[3].count == 12)
voy({ vaids = { rope = 2 } })
check("vaids", #S.voyage_aids == 1 and S.voyage_aids[1].name == "rope")
voy({ vrunes = { algiz = 1 } })
check("vrunes", #S.voyage_runes == 1 and S.voyage_runes[1].count == 1)

-- ---- vrelics ---------------------------------------------------------------
-- The Sea popup renders finished "Name xN" strings, which MIP built on the
-- server. GMCP sends raw ids plus a vrelic_names lookup, and the rendering
-- happens in the writer -- so these cases pin the rendering, the ordering and
-- the two delta shapes that broke the naive version.
voy({ vrelics = { jarls_torc = 2, sea_eye = 1 },
      vrelic_names = { jarls_torc = "Jarl's Torc", sea_eye = "Sea Eye" } })
check("vrelics renders name xN, sorted by display name",
      #S.voyage_relics == 2 and S.voyage_relics[1] == "Jarl's Torc x2"
      and S.voyage_relics[2] == "Sea Eye x1",
      table.concat(S.voyage_relics, "|"))
-- A delta carrying only the counts has to keep rendering: the name table is
-- sent on the full frame and then delta-suppressed, so a writer that required
-- both halves would blank the panel on every subsequent count change.
voy({ vrelics = { jarls_torc = 5, sea_eye = 1 } })
check("a counts-only delta reuses the names already learned",
      S.voyage_relics[1] == "Jarl's Torc x5", table.concat(S.voyage_relics, "|"))
-- An id with no name anywhere falls back to the id rather than vanishing.
voy({ vrelics = { jarls_torc = 1, mystery_shard = 4 } })
check("an unnamed id falls back to the id, it is not dropped",
      #S.voyage_relics == 2 and S.voyage_relics[2] == "mystery_shard x4",
      table.concat(S.voyage_relics, "|"))
-- Zero counts are omissions, not rows -- the server skips them too.
voy({ vrelics = { jarls_torc = 0, sea_eye = 3 } })
check("a zero count is dropped, not rendered as x0",
      #S.voyage_relics == 1 and S.voyage_relics[1] == "Sea Eye x3",
      table.concat(S.voyage_relics, "|"))

-- ---- vboons ----------------------------------------------------------------
-- GMCP sends the flags; MIP sent the finished sentence. The phrasing is a
-- fixed contract transcribed from the mudlib's own serializer, so it is
-- asserted verbatim -- rendering raw flag names would put
-- "storm_charm_ready" on the Sea popup.
voy({ vboons = { chart_fragment_used = 1, revealed_safe_cove = 0,
                 storm_charm_ready = 1, rigging_bonus = 0,
                 favorable_current_steps = 3 } })
check("vboons renders the mudlib's own wording, set flags only",
      S.voyage_boons == "Chart Fragment used;Storm Charm ready;"
        .. "Favorable Current 3 fast steps left", S.voyage_boons)
-- The singular/plural branch is in the server's formatter too.
voy({ vboons = { favorable_current_steps = 1 } })
check("one fast step is singular",
      S.voyage_boons == "Favorable Current 1 fast step left", S.voyage_boons)
voy({ vboons = { chart_fragment_used = 0, favorable_current_steps = 0 } })
check("no set flags renders an empty string", S.voyage_boons == "")
-- 0 is truthy in Lua, so a naive truth test would report every flag set.
voy({ vboons = { rigging_bonus = 0, storm_charm_ready = false } })
check("a zero or false flag is off", S.voyage_boons == "", S.voyage_boons)

-- ---- vsailed ---------------------------------------------------------------
-- Each element is the same "x,y" key MIP joined with ';'. Stored [row][col],
-- both 1-indexed for a 0-based wire coordinate -- so "3,1" is row 2, column 4.
voy({ vsailed = { "3,1", "0,0" } })
check("vsailed maps x,y onto [row+1][col+1]",
      S.voyage_sailed[2] ~= nil and S.voyage_sailed[2][4] == true
      and S.voyage_sailed[1] ~= nil and S.voyage_sailed[1][1] == true)
check("vsailed leaves unvisited cells unset",
      S.voyage_sailed[2][1] == nil)

-- ---- scalars ---------------------------------------------------------------
voy({ vspoils = 450 })
check("vspoils", S.voyage_spoils_daler == 450)
voy({ vreagent = 6 })
check("vreagent", S.voyage_reagents == 6)
voy({ fleet_renown = 1500 })
check("fleet_renown", S.fleet_renown == 1500)

-- ---- the Sea Chart ---------------------------------------------------------
-- MIP spread this over VCHH (dimensions and mode), VCHART (an older combined
-- form) and a numbered VCR%02d row burst. GMCP splits it in two: a record, and
-- the rows as their own key, because a record may not nest a list.
voy({ voyage_chart = { width = 4, height = 3, chart_mode = "explore" },
      voyage_chart_rows = { "S#H?", "OMBD", "++XY" } })
check("chart_mode lands on voyage_chart_mode",
      S.voyage_chart_mode == "explore", S.voyage_chart_mode)
check("chart dimensions", S.voyage_chart_width == 4 and S.voyage_chart_height == 3)
check("chart rows land in wire order", #S.voyage_chart_rows == 3
      and S.voyage_chart_rows[1] == "S#H?" and S.voyage_chart_rows[3] == "++XY")
check("the chart sets the voyage-seen flag", S.mip_voyage_seen == true)
-- Two independent keys over a delta transport: the server pushes the chart
-- every fast tick and lets the delta cache suppress an unchanged one, so a
-- frame carrying only the rows must not blank the dimensions.
voy({ voyage_chart_rows = { "AAAA", "BBBB", "CCCC" } })
check("a rows-only delta leaves the dimensions standing",
      S.voyage_chart_width == 4 and S.voyage_chart_height == 3
      and S.voyage_chart_rows[1] == "AAAA")
voy({ voyage_chart = { width = 6, height = 6, chart_mode = "raid" } })
check("a record-only delta leaves the rows standing",
      S.voyage_chart_width == 6 and S.voyage_chart_mode == "raid"
      and #S.voyage_chart_rows == 3)


-- ---- envelope --------------------------------------------------------------
protocol.on_gmcp("Guild.Voyage", { guild = "berserker", vspoils = 999 })
check("a foreign guild's frame is dropped", S.voyage_spoils_daler == 450)

if failures > 0 then
  print("FAILURES: " .. failures)
  os.exit(1)
end
print("ALL GUILD_VIKING GMCP VOYAGE TESTS PASSED")
