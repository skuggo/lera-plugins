-- Settlement, city-plan, buildings, missions and global-status payload
-- parsers, ported verbatim from LEGACY guild_viking.lua (github.com/.../
-- 3s_scripts_old, read-only reference). Each parser body transcribes its
-- LEGACY `elseif key == "..."` branch: string.split -> util.split,
-- state. -> S. (module-local alias). Display calls (viking_window.*,
-- ColourNote) are dropped -- the protocol layer already marks ui.dirty();
-- parsers never do.
local S = require("state").S
local observe = require("herd_observe")
local util = require("util")
local gmcp_map = require("gmcp_map")

local M = {}

-- LEGACY 1756
-- The GMCP record shape is canonical: `settlers` arrives as
-- ([settlers, mood, tax_rate, water, fert]) and MIP's string is the same
-- mapping's values joined in that order by _v_join, so the decoder zips and
-- the writer is shared.
local function write_settlers(r)
  if not r then return end
  S.settlers     = tonumber(r.settlers) or 0
  S.settler_mood = tonumber(r.mood)     or 0
  S.settler_tax  = tonumber(r.tax_rate) or 0
  S.city_water   = tonumber(r.water)    or 0
  S.city_fert    = tonumber(r.fert)     or 0
end


-- LEGACY 1765
-- The GMCP record shape is canonical here too: a full 24-field record. LEGACY
-- MIP tolerated three older, shorter field counts (17/21/23) from
-- intermediate server versions that predate later fields; none of those
-- partial layouts are `_v_join`'s current key order (its field 17, for
-- example, is `comm_upkeep` in the 17-field layout but `tax_income` in the
-- canonical one), so they cannot be zipped against one declared order without
-- misreading fields. city_test.lua only exercises the current 23-field
-- layout (field 24, `max_housing_plots`, was never captured even there --
-- LEGACY's own 23-field assignment list stops at `pop_next_secs`), so this
-- decoder no longer special-cases the two retired shorter layouts.
local function write_settlerx(r)
  if not r then return end
  S.settler_edict = r.edict or ""
  S.settler_edict_left = tonumber(r.edict_left) or 0
  S.settler_edict_cd = tonumber(r.edict_cd) or 0
  S.settler_housing_cap = tonumber(r.housing_cap) or 0
  S.settler_housing_plots = tonumber(r.housing_plots) or 0
  S.settler_housing_avg = tonumber(r.housing_avg_tier_x100) or 0
  S.settler_housing_quality = tonumber(r.housing_quality) or 0
  S.settler_housing_upkeep = tonumber(r.housing_upkeep) or 0
  S.settler_jobs = tonumber(r.jobs) or 0
  S.settler_employed = tonumber(r.employed) or 0
  S.settler_market_staffed = tonumber(r.staffed_market_jobs) or 0
  S.settler_mult_pct = tonumber(r.mult_pct) or 100
  S.settler_security = tonumber(r.security) or 0
  S.settler_dignity = tonumber(r.dignity) or 0
  S.settler_flourishing = tonumber(r.flourishing) or 0
  S.settler_community_net = tonumber(r.net) or 0
  -- r.tax_income (order position 17) is decoded but, like LEGACY, never
  -- written to any S.* field.
  S.settler_community_upkeep = tonumber(r.comm_upkeep) or 0
  S.settler_sustenance = tonumber(r.sustenance) or 0
  S.settler_emp_score = tonumber(r.employment_score) or 0
  S.settler_sentiment = tonumber(r.sentiment) or 0
  S.settler_supply_next = tonumber(r.supply_next_secs) or 0
  S.settler_pop_next = tonumber(r.pop_next_secs) or 0
  -- r.max_housing_plots (order position 24) is decoded but, like LEGACY,
  -- never written to any S.* field.
end

local SETTLERX_ORDER = { "edict", "edict_left", "edict_cd", "housing_cap",
  "housing_plots", "housing_avg_tier_x100", "housing_quality",
  "housing_upkeep", "jobs", "employed", "staffed_market_jobs", "mult_pct",
  "security", "dignity", "flourishing", "net", "tax_income", "comm_upkeep",
  "sustenance", "employment_score", "sentiment", "supply_next_secs",
  "pop_next_secs", "max_housing_plots" }

-- Guard against a short frame silently mis-assigning fields: zipping fewer
-- than this many raw "|" fields against the canonical order would read a
-- retired shorter layout's fields at the wrong canonical position (e.g. its
-- position 17 is comm_upkeep, not tax_income), producing a wrong-but-
-- plausible number instead of visibly nothing. The threshold is 23, not the
-- full 24: position 24 (max_housing_plots) is the one canonical field with
-- no counterpart at all in LEGACY's old wire format (see write_settlerx's
-- header comment above) -- every position up through 23 means the same
-- thing in both layouts, so a 23-field frame is safe to decode. That is
-- exactly what city_test.lua's own frozen SETTLERX case sends; anything
-- shorter uses an incompatible position layout and is rejected outright.
local SETTLERX_MIN_FIELDS = 23

-- LEGACY 1811
local function write_sactions(r)
  r = r or {}
  local names = {
    { "Assembly", tonumber(r.assembly) or 0 },
    { "Watch",    tonumber(r.watch)    or 0 },
    { "Crafts",   tonumber(r.crafts)   or 0 },
    { "Feast",    tonumber(r.feast)    or 0 },
    { "Relief",   tonumber(r.relief)   or 0 },
    { "Works",    tonumber(r.works)    or 0 },
  }
  S.settler_actions = {}
  for _, rec in ipairs(names) do
    if rec[2] > 0 then
      table.insert(S.settler_actions, { name = rec[1], secs = rec[2] })
    end
  end
end

local SACTIONS_ORDER = { "assembly", "watch", "crafts", "feast", "relief", "works" }

-- LEGACY 1827. Bespoke serializer (query_settler_roles_mip() in
-- settler_roles.h): "settlers|commoner|identity;role:cur:tgt:work:bonus;..."
-- -- the header segment packs three fields (settlers is unused here, same as
-- LEGACY), so this is not a gmcp_map.zip() shape either. GMCP splits the same
-- data across two keys because the snapshot nests four role->value mappings
-- inside one record, which a flat GMCP record cannot do: `sroles` (an array
-- of per-role records) and `sroles_meta` (the header). Both may arrive in one
-- frame, or a delta may carry just one -- write_sroles applies only the half
-- it was given.
local ROLE_LABELS = { smidir="Builders", verkamenn="Laborers",
  handverkarar="Artisans", kaupmenn="Merchants", boendr="Farmers",
  leidangr="Militia", vitkar="Seers", hasetar="Rowers" }

local function write_sroles(parts)
  if parts.sroles then
    S.settler_roles = {}
    for _, r in ipairs(parts.sroles) do
      local k = r.role
      if k and k ~= "" then
        table.insert(S.settler_roles, {
          key = k, label = ROLE_LABELS[k] or k,
          cur = tonumber(r.cur) or 0, tgt = tonumber(r.target) or 0,
          work = tonumber(r.work) or 0, bonus = tonumber(r.bonus) or 0,
        })
      end
    end
  end
  -- Only the half that arrived is applied: a delta frame may carry one key
  -- without the other, and clobbering the absent half would drop good state.
  if parts.sroles_meta then
    S.settler_commoner = tonumber(parts.sroles_meta.commoner) or 0
    S.settler_identity = parts.sroles_meta.identity or ""
  end
end

local function decode_sroles(val)
  local segs = util.split(val, ";")
  local parts = { sroles = {} }
  if segs[1] then
    -- "settlers|commoner|identity" -- m[1] (settlers) is unused, matching
    -- the original handler.
    local m = util.split(segs[1], "|")
    parts.sroles_meta = { commoner = m[2], identity = m[3] }
  end
  for i = 2, #segs do
    local k, cur, tgt, work, bon = segs[i]:match("^([^:]*):([^:]*):([^:]*):([^:]*):([^:]*)$")
    if k and k ~= "" then
      parts.sroles[#parts.sroles + 1] =
        { role = k, cur = cur, target = tgt, work = work, bonus = bon }
    end
  end
  return parts
end

-- LEGACY 2037
local function write_sproj(recs)
  S.settler_projects = {}
  for _, r in ipairs(recs or {}) do
    if #S.settler_projects >= 30 then break end  -- Safety limit
    local mat_detail = {}
    if r.detail and r.detail ~= "" then
      for part in r.detail:gmatch("[^,]+") do
        local gname, have, need = part:match("^([^:]+):(%d+)/(%d+)$")
        if gname then
          mat_detail[gname] = { have = tonumber(have) or 0, need = tonumber(need) or 0 }
        end
      end
    end
    table.insert(S.settler_projects, {
      id = r.id or "",
      kind = r.kind or "",
      from_tier = tonumber(r.from) or 0,
      to_tier = tonumber(r.to) or 0,
      secs_left = tonumber(r.secs) or 0,
      mats_total = tonumber(r.mats) or 0,
      mats_done = tonumber(r.done) or 0,
      mat_detail = mat_detail,
      daler = tonumber(r.paid) or 0,
    })
  end
end

local SPROJ_ORDER = { "id", "kind", "from", "to", "secs", "mats", "done", "detail", "paid" }

-- LEGACY 2065. GMCP's record carries a 5th slot (`h5`) LEGACY's 4-field MIP
-- string never had; it is decoded and kept in the tiers table alongside the
-- others.
--
-- This key owns ONLY settler_housing_plot_tiers. LEGACY also recomputed
-- settler_housing_plots/settler_housing_cap here, from a per-tier capacity
-- table (18/30/45/65) that no longer exists server-side: housing capacity is
-- flat per plot, not per tier. _community_housing_capacity()
-- (players/viking/obj/include/settlers.h:302-314) is
-- `(t1+t2+t3+t4+t5) * HEARTH_CAP_FLAT`, with HEARTH_CAP_FLAT == 11 -- summing
-- every tier, at one rate. SETTLERX's housing_cap/housing_plots carry exactly
-- that server-side computation, so they are authoritative and SETTLERX is the
-- sole writer of both fields.
--
-- Removing the recompute is also what makes the two transports agree. Over
-- MIP the server emits SETTLERX before SHPLOTS in one packet, so SHPLOTS'
-- stale arithmetic deterministically won; over GMCP frames are deltas with no
-- order, so either writer could have landed last and the housing line could
-- change with no underlying state change.
local function write_shplots(r)
  r = r or {}
  S.settler_housing_plot_tiers = {
    t1 = tonumber(r.h1) or 0,
    t2 = tonumber(r.h2) or 0,
    t3 = tonumber(r.h3) or 0,
    t4 = tonumber(r.h4) or 0,
    t5 = tonumber(r.h5) or 0,
  }
end

local SHPLOTS_ORDER = { "h1", "h2", "h3", "h4", "h5" }

-- LEGACY 2078. Bespoke serializer (_mip_scivics_value() in client.h): joins
-- records with ";" and writes id .. ":" .. count -- a colon inside each
-- record, not gmcp_map.zip's "|" wire form, so this needs its own decoder.
local function decode_scivics(val)
  local out = {}
  for entry in val:gmatch("[^;]+") do
    local cid, ctier = entry:match("^([^:]+):(%d+)$")
    if cid then
      out[#out + 1] = { id = cid, count = ctier }
    end
  end
  return out
end

-- S.settler_community_buildings is a { civic_id = tier } mapping (state.lua,
-- pages/people.lua's sorted_keys(cb) walk) rather than a list of records --
-- keep that shape; only the wire decoding changes.
local function write_scivics(recs)
  S.settler_community_buildings = {}
  for _, r in ipairs(recs or {}) do
    S.settler_community_buildings[r.id] = tonumber(r.count) or 0
  end
end

-- SCONSUME is a "good:amount" dictionary rather than a positional record: the
-- guild sends whichever of the thirteen goods the settlers are actually
-- consuming, so a fixed-order zip was never possible for it. The GMCP payload
-- is the same dict shape, which is why this writer takes one directly.
local function write_sconsume(dict)
  local out = {}
  for good, amt in pairs(dict or {}) do
    out[good] = tonumber(amt) or 0
  end
  S.settler_consumption = out
end




-- LEGACY 2648. Unlike the other keys in this file, SEVENTS is hand-encoded
-- (players/viking/obj/include/client.h: `out += r["ts"] + "|" + r["msg"]`),
-- not _v_join: msg is inserted raw and may itself contain "|" (a copied
-- command, a channel name, ...), so it cannot be zipped against a declared
-- {ts, msg} order -- that would split on every pipe and truncate msg at the
-- first one. LEGACY's own decode captures the remainder greedily
-- (`entry:match("^([^|]+)|(.*)$")`); this decoder does the same and hands
-- write_sevents the identical {ts=, msg=} records it already took.
local function write_sevents(recs)
  S.settler_events = {}
  for _, r in ipairs(recs or {}) do
    table.insert(S.settler_events, { ts = tonumber(r.ts) or 0, msg = r.msg or "" })
  end
end

-- GMCP-side writers. init.lua registers every entry here; the key is the
-- panel's internal name, which is still the uppercase spelling MIP used
-- (see protocol.lua's header for why those names stayed).

-- Guild.Fleet: pending ship upgrades. The record is {name, tier, secs, mats,
-- done, detail}; `detail` is the one field that is not a scalar, a
-- comma-joined "good:done/need" list the server builds as a string for both
-- transports (_v_supg in the mudlib's client.h), so it is parsed the same way
-- here as the MIP handler parses it.
local function write_supg(records)
  if type(records) ~= "table" then return end
  S.ship_upgrades = {}
  for _, r in ipairs(records) do
    if #S.ship_upgrades >= 20 then break end
    if type(r) == "table" then
      local mats = {}
      for piece in tostring(r.detail or ""):gmatch("[^,]+") do
        local g, d, n = piece:match("^([^:]+):(%d+)/(%d+)$")
        if g then
          table.insert(mats, { good = g, done = tonumber(d) or 0, need = tonumber(n) or 0 })
        end
      end
      table.insert(S.ship_upgrades, {
        name       = tostring(r.name or "?"),
        tier       = tonumber(r.tier) or 1,
        secs_left  = tonumber(r.secs) or 0,
        mats_total = tonumber(r.mats) or 0,
        mats_done  = tonumber(r.done) or 0,
        mats       = mats,
      })
    end
  end
end


-- ---------------------------------------------------------------------------
-- Guild.City writers
-- ---------------------------------------------------------------------------

-- "good:done/need,..." -- the same detail string SUPG and CUPG carry, built
-- once server-side for both transports.
local function parse_mats(detail)
  local mats = {}
  for piece in tostring(detail or ""):gmatch("[^,]+") do
    local good, done, need = piece:match("^([^:]+):(%d+)/(%d+)$")
    if good then
      table.insert(mats, { good = good, done = tonumber(done) or 0,
                           need = tonumber(need) or 0 })
    end
  end
  return mats
end

-- builds. `id` -> bldg_id, `mats`/`done` -> mats_total/mats_done, `secs` ->
-- complete_at_secs (-1 means awaiting materials), `total` -> total_build_secs.
local function write_builds(records)
  if type(records) ~= "table" then return end
  S.pending_builds = {}
  for _, r in ipairs(records) do
    if #S.pending_builds >= 30 then break end
    if type(r) == "table" then
      table.insert(S.pending_builds, {
        bldg_id          = tostring(r.id or ""),
        tier             = tonumber(r.tier) or 1,
        mats_total       = tonumber(r.mats) or 0,
        mats_done        = tonumber(r.done) or 0,
        complete_at_secs = tonumber(r.secs) or -1,
        total_build_secs = tonumber(r.total) or 0,
        mats             = parse_mats(r.detail),
      })
    end
  end
end

-- buildings. An array of {id, tier} over the wire, a bldg -> tier lookup in
-- state.
local function write_buildings(records)
  if type(records) ~= "table" then return end
  S.buildings = {}
  for _, r in ipairs(records) do
    if type(r) == "table" and r.id ~= nil then
      S.buildings[tostring(r.id)] = tonumber(r.tier) or 1
    end
  end
end

-- monuments_cap + monuments_list. MIP sent the cap as the first ';'-separated
-- field of one value and the names after it; GMCP sends the two separately.
-- Each half is applied only when its own key arrived.
local function write_monuments(parts)
  if type(parts) ~= "table" then return end
  if parts.monuments_cap ~= nil then
    S.monument_cap = tonumber(parts.monuments_cap) or 0
  end
  if type(parts.monuments_list) == "table" then
    S.monuments = {}
    for _, name in ipairs(parts.monuments_list) do
      -- MIP trimmed each name, because its own separator handling could leave
      -- surrounding space; harmless and kept so the two agree exactly.
      local trimmed = tostring(name):match("^%s*(.-)%s*$")
      if trimmed ~= "" and #S.monuments < 50 then
        table.insert(S.monuments, trimmed)
      end
    end
  end
end

-- blot. `state` -> blot_status.
local function write_blot(rec)
  if type(rec) ~= "table" then return end
  S.blot_status   = tostring(rec.state or "")
  S.blot_reset_in = tonumber(rec.reset_in) or 0
  S.blot_filled   = tonumber(rec.filled) or 0
  S.blot_total    = tonumber(rec.total) or 9
end

-- farm_meta + farm_plots. MIP packed the meta into the plot list as a "meta|"
-- pseudo-entry; GMCP gives it its own key. The meta record also carries
-- water/water_cap/fert/fert_cap, which MIP never sent and nothing reads.
-- `name` -> shroom is the plot rename.
local function write_farm(parts)
  if type(parts) ~= "table" then return end
  if type(parts.farm_meta) == "table" then
    S.farm_wmod = tonumber(parts.farm_meta.wmod) or 0
  end
  if type(parts.farm_plots) == "table" then
    S.farm_plots = {}
    for _, r in ipairs(parts.farm_plots) do
      if #S.farm_plots >= 50 then break end
      if type(r) == "table" then
        table.insert(S.farm_plots, {
          coord      = tostring(r.coord or ""),
          shroom     = tostring(r.name or ""),
          time_left  = tonumber(r.time_left) or 0,
          fertilized = tonumber(r.fertilized) or 0,
          wilt_left  = tonumber(r.wilt_left) or -1,
        })
      end
    end
  end
end

-- dcycle. `secs` -> demand_cycle_in.
local function write_dcycle(rec)
  if type(rec) ~= "table" then return end
  S.demand_cycle = tostring(rec.name or "")
  S.demand_cycle_in = tonumber(rec.secs) or 0
end

-- -1 from the server means "no production tick has ever run", which is a
-- different thing from 0 ("due now") and from the key being absent. Kept as
-- -1 so the page can say which -- see production_lines in pages/city.lua.
local function write_nexttick(v)
  S.next_tick_in = tonumber(v) or 0
end

-- cdtime is a duration, and the MIP handler turned it into an absolute
-- deadline at the moment it arrived. Kept exactly: the pages count down from
-- dispatch_cd_expires_at, and a 0 means "no cooldown" rather than "expires
-- now".
local function write_cdtime(v)
  local cd = tonumber(v) or 0
  if cd > 0 then
    S.dispatch_cd_expires_at = os.time() + cd
    S.dispatch_cd = cd
  else
    S.dispatch_cd_expires_at = nil
    S.dispatch_cd = 0
  end
end

-- Raw uncapped output per tick, not net of consumption. Keep the legacy
-- display coercions, but only a complete valid snapshot is planner evidence.
local function write_production(records)
  if type(records) ~= "table" then
    if S.herd_observed then S.herd_observed.production = nil end
    return
  end
  local valid, count, seen = true, 0, {}
  for i, r in pairs(records) do
    count = count + 1
    if type(i) ~= "number" or i < 1 or i % 1 ~= 0 then valid = false end
    if type(r) ~= "table" or type(r.good) ~= "string"
        or not r.good:match("^[a-z][a-z_]*$") or seen[r.good]
        or type(r.amount) ~= "number" or r.amount ~= r.amount
        or r.amount < 0 or r.amount == math.huge then
      valid = false
    else
      seen[r.good] = true
    end
  end
  -- Counting keys alone would allow holes or an object masquerading as an array.
  for i = 1, count do
    if rawget(records, i) == nil then valid = false end
  end
  S.production = {}
  for _, r in ipairs(records) do
    if type(r) == "table" and r.good ~= nil then
      S.production[tostring(r.good)] = tonumber(r.amount) or 0
    end
  end
  if valid then
    observe.record("production")
  elseif S.herd_observed then
    S.herd_observed.production = nil
  end
end

-- errand. `secs` -> expires_in, `origin`/`town` -> origin_town/target_town,
-- `good`/`qty` -> reward_good/reward_qty. MIP had a 7-field fallback with no
-- origin town; a GMCP record simply omits the field and it defaults.
local function write_errand(rec)
  if type(rec) ~= "table" then return end
  S.errand = {
    id          = tonumber(rec.id) or 0,
    label       = tostring(rec.label or ""),
    reward      = tonumber(rec.reward) or 0,
    expires_in  = tonumber(rec.secs) or 0,
    origin_town = tostring(rec.origin or ""),
    target_town = tostring(rec.town or ""),
    reward_good = tostring(rec.good or ""),
    reward_qty  = tonumber(rec.qty) or 0,
  }
end

-- missions. Same rename family as errand, plus `rep` -> reward_rep. `goods` is
-- the wanted-goods mapping, which MIP flattened into a "good:qty," string.
local function write_missions(records)
  if type(records) ~= "table" then return end
  S.missions = {}
  for _, r in ipairs(records) do
    if #S.missions >= 20 then break end
    if type(r) == "table" then
      local want = {}
      if type(r.goods) == "table" then
        for good, qty in pairs(r.goods) do
          want[tostring(good)] = tonumber(qty) or 0
        end
      end
      table.insert(S.missions, {
        id          = tonumber(r.id) or 0,
        label       = tostring(r.label or ""),
        reward_rep  = tonumber(r.rep) or 0,
        reward      = tonumber(r.reward) or 0,
        expires_in  = tonumber(r.secs) or 0,
        origin_town = tostring(r.origin or ""),
        target_town = tostring(r.town or ""),
        want_goods  = want,
      })
    end
  end
end

-- ---------------------------------------------------------------------------
-- Guild.State: the god-power block
-- ---------------------------------------------------------------------------
-- MIP spent five keys on this (GOD_POWER/GOD_ACTIVE naming one handler,
-- GOD_POWER_NEXT/GOD_NEXT another, GOD_POWER_FOCUS a third); GMCP sends one
-- `god` record carrying all three fields, so one writer covers the family.
--
-- The key map can only latch the MIP key a GMCP key resolves to, which is
-- GOD_POWER. Until the MIP layer comes out, the other four keep flowing and
-- write the same fields -- harmlessly, since both transports read the same
-- server state, and the one value that is recomputed rather than copied
-- (god_power_next_at, an absolute deadline derived from a duration) can differ
-- only by the gap between the two frames.
local VALID_GODS = {
  Odin = true, Thor = true, Freyja = true, Freyr = true, Tyr = true,
  Loki = true, Frigg = true, Heimdall = true, Baldr = true, Hel = true,
  Njord = true, Skadi = true, Forseti = true,
}

local function write_god(rec)
  if type(rec) ~= "table" then return end
  -- The name is validated against a fixed list, as the MIP handler validates
  -- it: anything unrecognised reads as "no god power" rather than being
  -- rendered verbatim.
  local name = tostring(rec.name or "")
  S.god_power_name = VALID_GODS[name] and name or ""
  local secs = tonumber(rec.seconds_left) or 0
  if secs < 0 then secs = 0 end
  S.god_power_next = secs
  S.god_power_next_at = os.time() + secs
  S.god_power_focus = tostring(rec.focus or "")
end

-- ---------------------------------------------------------------------------
-- Guild.City: the city plan
-- ---------------------------------------------------------------------------
-- Over MIP this was a multi-frame burst with its own commit protocol: CPLAN
-- opened a pending plan, CPT rows and CPB/CPU segments accumulated into it,
-- and CPEND either committed it or reported a dropped chunk by comparing a
-- row count. None of that is needed here. GMCP delivers the whole plan in one
-- frame (or across pages the protocol layer rejoins before dispatch), which is
-- exactly why the server declines to translate CPEND into a key at all.
--
-- Two renames: coast_side -> coast and mood_delta -> mood. enabled, moat and
-- wall arrive as 0/1 where the client stores booleans.
--
-- The terrain rows carry the grid's NATURAL glyphs -- '^' for hill, where MIP
-- substituted 'H' to dodge a wire-delimiter collision that does not exist in
-- JSON. popups/cityplan.lua already maps both characters to the same cell, so
-- nothing downstream needs to change.
-- Mirror of the server's _cp_name() (city_plan.h): underscores become spaces
-- and each word is capitalised. The server stopped sending the rendered name
-- for every building because it is derivable from the id and the list was
-- overrunning its frame budget with it.
local function cp_title_case(id)
  local out = {}
  for w in tostring(id):gmatch("[^_]+") do
    out[#out + 1] = w:sub(1, 1):upper() .. w:sub(2)
  end
  return table.concat(out, " ")
end

local function write_cityplan(parts)
  if type(parts) ~= "table" then return end

  -- The plan arrives across SEVERAL frames, not one.
  --
  -- A list too big for the remaining page budget is sliced, and a sliced key
  -- never shares a page with anything else (namespace_info_impl.h:488-510).
  -- cityplan_buildings is by far the largest key here -- a full city is 56
  -- records of eight fields -- so it routinely arrives in a frame of its own,
  -- with NO cityplan meta record beside it. Requiring that record meant every
  -- such frame was dropped on the floor, which is why the grid rendered as
  -- bare terrain with no buildings on it.
  --
  -- So the meta record is optional: when it is present it refreshes the plan
  -- header, and when it is absent we merge into the plan already held. Each
  -- list is likewise only replaced when this frame actually carried it, so no
  -- frame can blank a part of the plan that arrived in a different one.
  local rec  = parts.cityplan
  local prev = S.city_plan
  local plan

  if type(rec) == "table" then
    plan = {
      enabled = (tonumber(rec.enabled) or 0) == 1,
      dim     = tonumber(rec.dim) or 12,
      placed  = tonumber(rec.placed) or 0,
      cap     = tonumber(rec.cap) or 0,
      coast   = tonumber(rec.coast_side) or 0,
      moat    = (tonumber(rec.moat) or 0) == 1,
      wall    = (tonumber(rec.wall) or 0) == 1,
      gate    = tonumber(rec.gate) or 6,
      mood    = tonumber(rec.mood_delta) or 0,
      margin  = tonumber(rec.margin) or 3,
      rows = (prev and prev.rows) or {},
      blds = (prev and prev.blds) or {},
      unplaced = (prev and prev.unplaced) or {},
      -- Sent only when there are any, so on a frame carrying the plan record
      -- its absence really does mean none.
      perks = tostring(parts.cityplan_perks or ""),
    }
  elseif type(prev) == "table" then
    plan = prev
    if parts.cityplan_perks ~= nil then
      plan.perks = tostring(parts.cityplan_perks)
    end
  else
    -- A list turned up before any plan header did; nothing to attach it to.
    return
  end

  if parts.cityplan_terrain ~= nil then
    local rows = {}
    for i, row in ipairs(parts.cityplan_terrain) do rows[i] = tostring(row) end
    plan.rows = rows
  end

  if parts.cityplan_buildings ~= nil then
    local blds = {}
    for _, b in ipairs(parts.cityplan_buildings) do
      if type(b) == "table" and b.id ~= nil and tostring(b.id) ~= "" then
        local id = tostring(b.id)
        local name = tostring(b.name or "")
        blds[#blds + 1] = {
          id = id,
          x = tonumber(b.x) or 0, y = tonumber(b.y) or 0,
          -- Absent means 1: the server omits w/h at their default to keep the
          -- list inside its frame budget (see send_gmcp_citybuildings()).
          w = tonumber(b.w) or 1, h = tonumber(b.h) or 1,
          pal = tostring(b.pal or "e"), glyph = tostring(b.glyph or "?"),
          -- `name` no longer travels: the server's _cp_name() is a Title-Case
          -- render of the id and nothing else, so it is reconstructed here
          -- rather than repeated on the wire for all 56 buildings. A name
          -- that IS sent still wins, so the field can come back at any time
          -- without a client change.
          name = (name ~= "") and name or cp_title_case(id),
        }
      end
    end
    plan.blds = blds
  end

  if parts.cityplan_placeable ~= nil then
    local un = {}
    for _, b in ipairs(parts.cityplan_placeable) do
      if type(b) == "table" and b.id ~= nil and tostring(b.id) ~= "" then
        local id = tostring(b.id)
        local name = tostring(b.name or "")
        un[#un + 1] = {
          id = id, pal = tostring(b.pal or "e"),
          glyph = tostring(b.glyph or "?"),
          name = (name ~= "") and name or id,
        }
      end
    end
    plan.unplaced = un
  end

  S.city_plan = plan
  S.cp_pending = nil
end

M._gmcp = {
  SUPG       = write_supg,
  SETTLERS = write_settlers,
  SETTLERX = write_settlerx,
  SACTIONS = write_sactions,
  SHPLOTS  = write_shplots,
  SCONSUME = write_sconsume,
  SPROJ    = write_sproj,
  SEVENTS  = write_sevents,
  SCIVICS  = write_scivics,
  SROLES   = write_sroles,
  BUILDS     = write_builds,
  BUILDINGS  = write_buildings,
  MONUMENTS  = write_monuments,
  BLOT       = write_blot,
  FARM       = write_farm,
  DCYCLE     = write_dcycle,
  NEXTTICK   = write_nexttick,
  CDTIME     = write_cdtime,
  PRODUCTION = write_production,
  ERRAND     = write_errand,
  MISSIONS   = write_missions,
  GOD_POWER  = write_god,
  CPLAN      = write_cityplan,
}

return M
