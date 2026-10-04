-- Raid, war, dynasty, army and kingdom payload parsers, ported verbatim from
-- LEGACY guild_viking.lua (github.com/.../3s_scripts_old, read-only
-- reference). Each parser body transcribes its LEGACY `elseif key == "..."`
-- branch: string.split -> util.split, state. -> S. (module-local alias).
-- Display calls (viking_window.*, ColourNote) are dropped -- the protocol layer
-- already marks ui.dirty(); parsers never do.
local S = require("state").S
local util = require("util")

local M = {}

-- ---------------------------------------------------------------------------
-- Guild.Fleet writers
-- ---------------------------------------------------------------------------

-- raidlog + raidlog_goods. A raid entry's goods breakdown is a mapping, and a
-- record used as a container element may not hold one, so the server flattens
-- it into its own top-level array foreign-keyed by `idx` back to the parent
-- entry (_v_raidlog_goods in the mudlib's client.h). Rejoining them is this
-- writer's whole reason for being a composite.
--
-- Either half may arrive alone: frames are deltas, and a raid that brought
-- back nothing produces entries with no goods rows at all. So a missing
-- `raidlog` leaves the list alone, and missing goods simply means every entry
-- gets an empty breakdown.
local function write_raidlog(parts)
  if type(parts) ~= "table" then return end
  local entries = parts.raidlog
  if type(entries) ~= "table" then return end

  -- idx -> goods list, built in one pass. The server appends goods rows in the
  -- order the source mapping iterates, and that order is what MIP's
  -- comma-joined sub-list preserved, so append order is kept here too.
  local goods_by_idx = {}
  if type(parts.raidlog_goods) == "table" then
    for _, g in ipairs(parts.raidlog_goods) do
      if type(g) == "table" then
        local idx = tonumber(g.idx)
        if idx then
          local list = goods_by_idx[idx]
          if not list then list = {}; goods_by_idx[idx] = list end
          list[#list + 1] = { good = tostring(g.good or "?"),
                              qty = tonumber(g.amount) or 0 }
        end
      end
    end
  end

  S.raidlog = {}
  for i, r in ipairs(entries) do
    if #S.raidlog >= 20 then break end
    if type(r) == "table" then
      -- `idx` is the record's own 0-based position; fall back to the array
      -- position when a frame omits it, so a goods-less entry still lands.
      local idx = tonumber(r.idx)
      if idx == nil then idx = i - 1 end
      table.insert(S.raidlog, {
        ship    = tostring(r.ship or ""),
        target  = tostring(r.target or ""),
        daler   = tonumber(r.daler) or 0,
        thralls = tonumber(r.thralls) or 0,
        lost    = (tonumber(r.lost) or 0) ~= 0,
        goods   = goods_by_idx[idx] or {},
      })
    end
  end
end

-- rtargets_lineage + rtargets_historical. These never had a _v_ builder: MIP
-- joined the two arrays with a '|' into one scalar, so GMCP sends them as the
-- two arrays they always were. Each element is still the same
-- "name:good1:good2" string the MIP entries were -- the mudlib's own
-- _war_town_lineage reads them with explode(hold, ":")[0] -- so the per-entry
-- parse is unchanged.
--
-- autoraid.lua indexes S.raid_targets_lin and S.raid_targets_hist
-- positionally within their own group, so each group's order matters but the
-- two are never mixed. S.raid_targets, the flat concatenation, has no reader
-- outside this module; it is still maintained because MIP maintains it and
-- dropping it is a separate cleanup, not part of a transport change.
local function parse_target_group(list)
  local out = {}
  for _, entry in ipairs(list or {}) do
    local t = tostring(entry)
    local nm, g1, g2 = t:match("^([^:]+):([^:]*):([^:]*)$")
    if not nm then nm = t end
    out[#out + 1] = { name = nm, g1 = (g1 ~= "" and g1) or nil,
                      g2 = (g2 ~= "" and g2) or nil }
  end
  return out
end

local function write_rtargets(parts)
  if type(parts) ~= "table" then return end
  -- Each half is replaced only when the frame actually carried it. Frames are
  -- deltas, so rebuilding both from one half would empty the group that did
  -- not change -- the flat list below is then regenerated from what is
  -- STORED, not from what arrived, which is what keeps it whole.
  if parts.rtargets_lineage ~= nil then
    S.raid_targets_lin = parse_target_group(parts.rtargets_lineage)
  end
  if parts.rtargets_historical ~= nil then
    S.raid_targets_hist = parse_target_group(parts.rtargets_historical)
  end
  S.raid_targets = {}
  for _, group in ipairs({ S.raid_targets_lin or {}, S.raid_targets_hist or {} }) do
    for _, rec in ipairs(group) do
      S.raid_targets[#S.raid_targets + 1] = rec.name
    end
  end
end


-- ---------------------------------------------------------------------------
-- Guild.Roster writers
-- ---------------------------------------------------------------------------

-- hird. MIP tolerated five shorter field layouts from older servers; GMCP
-- carries a record, so a field the server did not send is simply absent and
-- takes its default. `hired` -> hired_at and `age` -> age_phase are the two
-- renames; `id` keys the by-id lookup rather than being stored on the record,
-- exactly as the MIP handler had it.
--
-- `mode` is normalised the same way MIP normalised it: anything that is not
-- "offensive" or "defensive" is "neutral", so an unfamiliar mode reads as the
-- harmless one rather than reaching the pages verbatim.
-- hird arrives as ONE ROTATING SLICE per push, the same way staff does and
-- for the same reason: a package cannot carry the whole list inside its page
-- budget, so the server walks a cursor and this accumulates the slices.
--
-- This is what the Bonds page resolves its pair ids against, so a half-filled
-- accumulator renders "#7 + #8" -- which is exactly the symptom that started
-- this. The list is rebuilt from every slice seen so far, in index order.
local function write_hird(parts)
  if type(parts) ~= "table" then return end

  if parts.hird_total ~= nil then S.hird_total = tonumber(parts.hird_total) or 0 end
  if parts.hird_slices ~= nil then S.hird_slices = tonumber(parts.hird_slices) or 0 end

  S.hird_by_slice = S.hird_by_slice or {}
  local carried = false
  for i = 0, 3 do
    local slice = parts["hird_" .. i]
    if type(slice) == "table" then
      S.hird_by_slice[i] = slice
      carried = true
    end
  end
  if not carried then return end

  for i in pairs(S.hird_by_slice) do
    if i >= (S.hird_slices or 0) then S.hird_by_slice[i] = nil end
  end

  local records = {}
  for i = 0, (S.hird_slices or 0) - 1 do
    for _, r in ipairs(S.hird_by_slice[i] or {}) do records[#records + 1] = r end
  end

  S.hird_list = {}
  S.hird_by_id = {}
  for _, r in ipairs(records) do
    if type(r) == "table" and r.name ~= nil then
      local mode = tostring(r.mode or "")
      if mode ~= "offensive" and mode ~= "defensive" then mode = "neutral" end
      local rec = {
        name      = tostring(r.name),
        status    = r.status ~= nil and tostring(r.status) or nil,
        level     = tonumber(r.level) or 1,
        atk       = tonumber(r.atk) or 1,
        def       = tonumber(r.def) or 1,
        loyalty   = tonumber(r.loyalty) or 3,
        hired_at  = tonumber(r.hired) or 0,
        age_phase = tostring(r.age or "young"),
        mode      = mode,
        champ     = tonumber(r.champ) or 0,
        wpn       = tonumber(r.wpn) or 0,
        arm       = tonumber(r.arm) or 0,
      }
      table.insert(S.hird_list, rec)
      local hid = tonumber(r.id)
      if hid then S.hird_by_id[hid] = rec end
    end
  end
end

-- thralls. A mapping of `total` plus one count per building, where MIP sent
-- the same numbers positionally against a building order the client had to
-- keep in step with the server's. Keyed by name, that whole class of
-- off-by-one is gone: an unfamiliar building is simply a key nothing reads,
-- and a building the server stops sending defaults to 0 rather than shifting
-- every later count by one.
local THRALL_BUILDINGS = {
  "longhouse", "warehouse", "farm", "apiary", "tannery", "fishery",
  "lumber_yard", "mine", "smithy", "watchtower", "palisade", "salting_house",
  "bakehouse", "furriers_lodge", "smelter", "weaponry", "armoury", "goldsmith",
  "skald_hall",
}

local function write_thralls(rec)
  if type(rec) ~= "table" then return end
  S.thralls = tonumber(rec.total) or 0
  S.thrall_assignments = {}
  for _, bid in ipairs(THRALL_BUILDINGS) do
    S.thrall_assignments[bid] = tonumber(rec[bid]) or 0
  end
  S.thralls_longhouse = S.thrall_assignments.longhouse
  S.thralls_warehouse = S.thrall_assignments.warehouse
end

-- thrall_follower. `state` -> thrall_follower_status is the one rename.
local function write_thrall_follower(rec)
  if type(rec) ~= "table" then return end
  S.thrall_follower_level      = tonumber(rec.level) or 0
  S.thrall_follower_name       = tostring(rec.name or "")
  S.thrall_follower_xp         = tonumber(rec.xp) or 0
  S.thrall_follower_xp_cap     = tonumber(rec.xp_cap) or 0
  S.thrall_follower_carry_used = tonumber(rec.carry_used) or 0
  S.thrall_follower_carry_cap  = tonumber(rec.carry_cap) or 0
  S.thrall_follower_status     = tostring(rec.state or "none")
end

-- varang_out + varang_in, MIP's two '^'-separated sections. `secs` ->
-- expires_in. Each half is replaced only when the frame carried it, since the
-- two are independent keys over a delta transport.
local function parse_varang(list, cap)
  local out = {}
  for _, r in ipairs(list or {}) do
    if #out >= cap then break end
    if type(r) == "table" then
      out[#out + 1] = { name = tostring(r.name or ""),
                        count = tonumber(r.count) or 0,
                        expires_in = tonumber(r.secs) or 0 }
    end
  end
  return out
end

local function write_varang(parts)
  if type(parts) ~= "table" then return end
  if parts.varang_out ~= nil then S.varang_out = parse_varang(parts.varang_out, 30) end
  if parts.varang_in ~= nil then S.varang_in = parse_varang(parts.varang_in, 30) end
end

-- ---------------------------------------------------------------------------
-- Guild.City writers that live here, beside their MIP twins
-- ---------------------------------------------------------------------------

-- bdmg. `id` -> bldg_id.
local function write_bdmg(records)
  if type(records) ~= "table" then return end
  S.bdmg = {}
  for _, r in ipairs(records) do
    if type(r) == "table" and r.id ~= nil then
      table.insert(S.bdmg, { bldg_id = tostring(r.id), pct = tonumber(r.pct) or 0 })
    end
  end
end

-- raid. `secs` -> raid_in, which is -1 when no raid is inbound rather than 0 --
-- 0 means "now".
local function write_raid(rec)
  if type(rec) ~= "table" then return end
  S.raid_in       = tonumber(rec.secs) or -1
  S.raid_faction  = tostring(rec.faction or "")
  S.raid_strength = tonumber(rec.strength) or 0
end

local function write_patrol(rec)
  if type(rec) ~= "table" then return end
  S.patrol = { count = tonumber(rec.count) or 0,
               remaining = tonumber(rec.remaining) or 0 }
end

-- garrison. `pool` -> garrison_free and `power` -> garrison_defpower are the
-- two renames.
local function write_garrison(rec)
  if type(rec) ~= "table" then return end
  S.garrison_stationed = tonumber(rec.stationed) or 0
  S.garrison_free      = tonumber(rec.pool) or 0
  S.garrison_cap       = tonumber(rec.cap) or 0
  S.garrison_defpower  = tonumber(rec.power) or 0
end

-- ---------------------------------------------------------------------------
-- Guild.Kingdom writers
-- ---------------------------------------------------------------------------

-- grudges: towns that may send a reprisal raid.
local function write_grudges(records)
  if type(records) ~= "table" then return end
  S.grudges = {}
  for _, r in ipairs(records) do
    if type(r) == "table" and r.town ~= nil then
      S.grudges[#S.grudges + 1] = { town = tostring(r.town),
                                    secs = tonumber(r.secs) or 0 }
    end
  end
end

-- standings / vrep: both keyed by lineage id, which the record calls `lin`.
local function write_standings(records)
  if type(records) ~= "table" then return end
  S.standings = {}
  for _, r in ipairs(records) do
    if type(r) == "table" and r.lin ~= nil then
      S.standings[tonumber(r.lin) or 0] = {
        name   = tostring(r.name or ""),
        score  = tonumber(r.score) or 0,
        label  = tostring(r.label or ""),
        -- `own` -> is_own, and it arrives as 0/1 where the client stores a
        -- boolean.
        is_own = (tonumber(r.own) or 0) ~= 0,
      }
    end
  end
end

local function write_vrep(records)
  if type(records) ~= "table" then return end
  S.village_rep = {}
  for _, r in ipairs(records) do
    if type(r) == "table" and r.lin ~= nil then
      S.village_rep[tonumber(r.lin) or 0] = {
        name     = tostring(r.name or ""),
        rep      = tonumber(r.rep) or 0,
        rank     = tonumber(r.rank) or 0,
        start_at = tonumber(r.start_at) or 0,
        next_at  = tonumber(r.next_at) or 0,
      }
    end
  end
end

-- diplo: one flat list where the client wants two, split on each row's `side`.
-- "you" is the ally side (the mudlib's own diplomacy_mip does the same test);
-- anything else is a foe. `name` is the house name.
local function write_diplo(records)
  if type(records) ~= "table" then return end
  local d = { allies = {}, foes = {} }
  for _, r in ipairs(records) do
    if type(r) == "table" and r.name ~= nil then
      local into = (tostring(r.side) == "you") and d.allies or d.foes
      into[#into + 1] = { house = tostring(r.name),
                          standing = tonumber(r.standing) or 0 }
    end
  end
  -- nil rather than an empty pair of lists, matching the MIP handler: the
  -- Court page tests S.diplomacy for presence to decide whether to draw the
  -- section at all.
  S.diplomacy = (#d.allies > 0 or #d.foes > 0) and d or nil
end

-- army + army_units + army_traits. Each unit's trait list is a container a
-- record may not hold, so it is flattened out and foreign-keyed by `uid`.
--
-- `used` and `cap` are remapped, and this is a behaviour FIX rather than a
-- transcription. pages/army.lua renders one header from them --
-- "Units  (used / cap)" -- so they are the unit count and the unit cap. The
-- MIP handler could not supply either: it parses three leading fields
-- (conscripts|cap|used) from a value the server has since grown to six
-- (conscripts|cap|levy_rate|unit_cap|unit_count|units...), so `used` has been
-- holding the levy rate, `cap` the CONSCRIPT cap, and the trailing `.*`
-- capture has been swallowing unit_cap and unit_count into the first unit
-- record. That header has been wrong on the MIP path for as long as the server
-- has sent six fields. Here `used` is unit_count and `cap` is unit_cap, which
-- is what the header says it is showing. S.army.conscripts, the only other
-- field with a reader, is unaffected.
local function write_army(parts)
  if type(parts) ~= "table" then return end
  local rec = parts.army
  if type(rec) ~= "table" then return end
  local traits_by_uid = {}
  for _, t in ipairs(parts.army_traits or {}) do
    if type(t) == "table" and t.uid ~= nil then
      local list = traits_by_uid[t.uid]
      if not list then list = {}; traits_by_uid[t.uid] = list end
      list[#list + 1] = tostring(t.trait or "")
    end
  end
  local units = {}
  for _, u in ipairs(parts.army_units or {}) do
    if type(u) == "table" then
      units[#units + 1] = {
        uid    = tonumber(u.uid) or 0,
        type   = tostring(u.type or ""),
        size   = tonumber(u.size) or 0,
        vet    = tonumber(u.vet) or 0,
        ready  = (tonumber(u.ready) or 0) ~= 0,
        leader = tostring(u.leader or "-"),
        traits = traits_by_uid[u.uid] or {},
      }
    end
  end
  S.army = {
    conscripts    = tonumber(rec.conscripts) or 0,
    -- Keep both capacities: `cap`/`used` describe army unit slots for the
    -- Army page, while Auto-War needs the conscript pool capacity separately.
    conscript_cap = tonumber(rec.cap) or 0,
    levy_rate     = tonumber(rec.levy_rate) or 0,
    cap           = tonumber(rec.unit_cap) or 0,
    used          = tonumber(rec.unit_count) or 0,
    units         = units,
  }
end

-- dynasty_*: eight keys the server splits out of one structure, two of them
-- because a record may not nest a container (children, and each child's
-- schooling rows). The schooling list has no consumer here and is ignored.
local function write_dynasty(parts)
  if type(parts) ~= "table" then return end
  -- The whole record is rebuilt from the frame's keys, so a delta carrying one
  -- of them must not drop the rest: start from what is already stored.
  local prev = S.dynasty or {}
  local d = {
    realm    = prev.realm or "",
    house    = prev.house or "",
    heir     = prev.heir,
    spouse   = prev.spouse,
    living   = prev.living or 0,
    cap      = prev.cap or 0,
    children = prev.children or {},
  }
  if parts.dynasty_realm ~= nil then d.realm = tostring(parts.dynasty_realm) end
  if parts.dynasty_house ~= nil then d.house = tostring(parts.dynasty_house) end
  if parts.dynasty_heir ~= nil then
    local heir = tostring(parts.dynasty_heir)
    -- An empty heir is "none", which the pages test for by presence.
    d.heir = (heir ~= "") and heir or nil
  end
  if parts.dynasty_living ~= nil then d.living = tonumber(parts.dynasty_living) or 0 end
  if parts.dynasty_cap ~= nil then d.cap = tonumber(parts.dynasty_cap) or 0 end
  if type(parts.dynasty_spouse) == "table" then
    d.spouse = {
      name  = tostring(parts.dynasty_spouse.name or ""),
      house = tostring(parts.dynasty_spouse.house or ""),
      age   = tonumber(parts.dynasty_spouse.age) or 0,
      rank  = tonumber(parts.dynasty_spouse.rank) or 1,
    }
  end
  if type(parts.dynasty_children) == "table" then
    local children = {}
    for _, c in ipairs(parts.dynasty_children) do
      if type(c) == "table" and c.name ~= nil then
        local role = tostring(c.role or "")
        children[#children + 1] = {
          name   = tostring(c.name),
          gender = tostring(c.gender or ""),
          age    = tonumber(c.age) or 0,
          adult  = (tonumber(c.adult) or 0) ~= 0,
          trait  = tostring(c.trait or ""),
          -- "-" is the server's "no role" placeholder, and so is "". Both
          -- become nil, which is what the Court page tests for.
          role   = (role ~= "-" and role ~= "") and role or nil,
        }
      end
    end
    d.children = children
  end
  S.dynasty = d
end

-- war_cb + war_camp + war_incoming. `cb` is the claims list and `camp` the
-- campaign list; `war_incoming` is sent only when a war is actually inbound,
-- so its absence from a frame carrying the other two means "none".
local function write_war(parts)
  if type(parts) ~= "table" then return end
  if parts.war_cb == nil and parts.war_camp == nil and parts.war_incoming == nil then
    return
  end
  local w = { claims = {}, incoming = nil, campaigns = {} }
  for _, r in ipairs(parts.war_cb or {}) do
    if type(r) == "table" and r.town ~= nil then
      w.claims[#w.claims + 1] = { town = tostring(r.town),
                                  days = tonumber(r.days) or 0 }
    end
  end
  for _, r in ipairs(parts.war_camp or {}) do
    if type(r) == "table" and r.town ~= nil then
      w.campaigns[#w.campaigns + 1] = { town = tostring(r.town),
                                        defense = tonumber(r.defense) or 0,
                                        max = tonumber(r.max) or 100 }
    end
  end
  if type(parts.war_incoming) == "table" and parts.war_incoming.town ~= nil then
    w.incoming = { town = tostring(parts.war_incoming.town),
                   days = tonumber(parts.war_incoming.days) or 0,
                   strength = tonumber(parts.war_incoming.strength) or 100 }
  end
  -- nil when there is nothing at all, matching the MIP handler: the War page
  -- tests S.war for presence.
  S.war = (#w.claims > 0 or w.incoming or #w.campaigns > 0) and w or nil
end

-- ---------------------------------------------------------------------------
-- Guild.Kingdom: the campaign war map
-- ---------------------------------------------------------------------------
-- MIP spread this over WMAP/WMR/WMO/WMQ/WMU/WMP/WMPL/WSG/WSPOIL with the same
-- burst-and-commit protocol the city plan used, and WMEND compared a promised
-- row count before committing. GMCP sends the campaign whole, so the writer
-- commits outright -- and, as with the city plan, the server declines to
-- translate WMEND into a key at all.
--
-- Captives and the siege park persist independently of an active campaign,
-- which the MIP path expressed by assigning them before the active check.
-- Kept.
--
-- `campaign_units` is one merged overlay list. "host" is your stack (id "A"),
-- "objective" is the target (id "*"), and "foe" keeps its numeric id.
--
-- ALLIES AND LANDMARKS used to be dropped here, on the grounds that the
-- renderer had no cell for them. It does: popups/war_campaign.lua's
-- unit_cell() already draws "F" in cyan and any "P.." landmark as a "w", and
-- has since the port. So the overlays the server sends were being thrown away
-- in front of a renderer that was waiting for them -- the ally never appeared
-- on the campaign map or in the legend, and Auto-War could not see it either.
-- An ally keeps its own server id ("F"); a landmark becomes "P1" once taken
-- and "P*" while it still stands, which is the pair unit_cell() distinguishes.
local CAMPAIGN_UNIT_ID = { host = "A", objective = "*" }

-- "A1" -> column 0, row 0. The queue labels are 1-based letters-and-digits;
-- MIP sent the same strings and the client did this conversion itself.
local function square_to_cell(label)
  local col = string.byte(label:sub(1, 1) or "") 
  if not col then return nil end
  col = col - 65
  local row = (tonumber(label:sub(2)) or 0) - 1
  if col < 0 or row < 0 then return nil end
  return col, row
end

local function write_campaign(parts)
  if type(parts) ~= "table" then return end
  local rec = parts.campaign
  if type(rec) ~= "table" then return end

  -- Captives and the siege park first: they outlive a campaign.
  if type(parts.campaign_prison) == "table" then
    local pr = parts.campaign_prison
    local roster = {}
    for _, r in ipairs(parts.campaign_prison_roster or {}) do
      if type(r) == "table" then
        roster[#roster + 1] = {
          id = tonumber(r.id) or 0, name = tostring(r.name or ""),
          size = tonumber(r.size) or 0,
          cmd = (tonumber(r.cmd) or 0) ~= 0,
          val = tonumber(r.val) or 0,
        }
      end
    end
    S.prison = {
      held = tonumber(pr.held) or 0,
      -- `capacity` -> cap.
      cap = tonumber(pr.capacity) or 0,
      kin = tonumber(pr.kin) or 0,
      pending = (tonumber(pr.pending) or 0) ~= 0,
      pend_name = tostring(pr.pend_name or ""),
      pend_size = tonumber(pr.pend_size) or 0,
      pend_cmd = (tonumber(pr.pend_cmd) or 0) ~= 0,
      roster = roster,
    }
  end
  if type(parts.campaign_siege) == "table" then
    local sg = parts.campaign_siege
    -- Held, forging and merely ordered are three DIFFERENT states, and the
    -- server says so in its own contract note (gmcp.h:322-329): "a park
    -- reading 0/4 with three on order is not an empty one, and a client that
    -- renders only engines/capacity cannot tell them apart". This used to
    -- keep exactly those two fields and drop the other seven, so an order
    -- waiting on iron looked identical to an empty park.
    -- reserved/next_needs are flat good->int maps ("timber"/"iron"/"tools"),
    -- so a shortfall readout needs no knowledge of the recipe.
    local function goods(t)
      local out = {}
      if type(t) == "table" then
        for k, v in pairs(t) do out[tostring(k)] = tonumber(v) or 0 end
      end
      return out
    end
    S.siege = {
      engines    = tonumber(sg.engines) or 0,
      -- `capacity` -> cap, the same rename S.prison does just above.
      cap        = tonumber(sg.capacity) or 0,
      forging    = tonumber(sg.forging) or 0,
      queue_max  = tonumber(sg.queue_max) or 0,
      ordered    = tonumber(sg.ordered) or 0,
      order_max  = tonumber(sg.order_max) or 0,
      reserved   = goods(sg.reserved),
      next_needs = goods(sg.next_needs),
      daler_each = tonumber(sg.daler_each) or 0,
      -- Full forge time for one engine, the denominator for a progress bar.
      build_secs = tonumber(sg.build_secs) or 0,
      queue = {},
    }
    -- Per-engine forge clocks (sibling array, like campaign_prison_roster):
    -- eta is seconds left and total the full forge time, so elapsed =
    -- total - eta drives a bar exactly as pending_builds does for buildings.
    for _, e in ipairs(parts.campaign_siege_queue or {}) do
      if type(e) == "table" then
        S.siege.queue[#S.siege.queue + 1] = {
          slot  = tonumber(e.slot) or (#S.siege.queue + 1),
          eta   = tonumber(e.eta) or 0,
          total = tonumber(e.total) or S.siege.build_secs or 0,
        }
      end
    end
  end

  if (tonumber(rec.active) or 0) ~= 1 then
    -- No campaign: the map clears, but the two above stay.
    S.war_map = nil
    S.wm_pending = nil
    return
  end

  local prev_wm = S.war_map
  local wm = {
    active = true,
    dim = tonumber(rec.dim) or 0,
    turn = tonumber(rec.turn) or 0,
    mode = tostring(rec.mode or "offense"),
    pending = tonumber(rec.pending) or 0,
    town = tostring(rec.town or ""),
    works_budget = tonumber(rec.works_budget) or 0,
    march_eta = tonumber(rec.march_eta) or 0,
    -- Guild.Kingdom frames are DELTAS, and these four ride on their own
    -- sibling keys (campaign_terrain / campaign_units / campaign_queue). A
    -- frame carrying only a new `campaign` record -- a turn tick, a march ETA
    -- -- has none of them, and rebuilding them empty threw away terrain that
    -- had arrived perfectly well: the board then sat on "(waiting for map
    -- data...)" with the header above it rendering from this same record.
    -- Carry the previous contents forward; the loops below replace each one
    -- only when the frame actually carries its key.
    rows    = (prev_wm and prev_wm.rows)    or {},
    units   = (prev_wm and prev_wm.units)   or {},
    -- queue/queues deliberately do NOT carry forward. Their contract is the
    -- opposite of terrain's: the server stops echoing a queue once it has
    -- drained, and the pane falls back to its local echo -- so remembering
    -- the last one would leave a march order on screen that no longer exists.
    -- popups/war_campaign's own tests pin this.
    queue = {}, queues = {},
    upkeep = {
      food = tonumber(rec.upkeep_food) or 0,
      mead = tonumber(rec.upkeep_mead) or 0,
      tools = tonumber(rec.upkeep_tools) or 0,
      iron = tonumber(rec.upkeep_iron) or 0,
      daler = tonumber(rec.upkeep_daler) or 0,
    },
    -- MIP called the war-points field `renown` on this record; the server
    -- calls it wpts. Same number.
    spoils = {
      daler = tonumber(rec.spoils_daler) or 0,
      renown = tonumber(rec.spoils_wpts) or 0,
      deeds = tonumber(rec.spoils_deeds) or 0,
    },
    prison = S.prison,
    siege = S.siege,
  }

  if parts.campaign_terrain ~= nil then
    wm.rows = {}
    for i, row in ipairs(parts.campaign_terrain) do
      wm.rows[i] = tostring(row)
    end
  end
  -- Trust the rows over the declared size. `dim` and `campaign_terrain` are
  -- separate keys, so one can arrive without the other -- a delta frame
  -- carrying only the terrain, or a size the server could not determine --
  -- and pages/war.lua tests BOTH before drawing. Deriving the missing half
  -- from the half that did arrive is what keeps the board from sitting on
  -- "(waiting for map data...)" with a perfectly good grid in hand.
  if (wm.dim or 0) < 1 then wm.dim = #wm.rows end

  if parts.battles_won ~= nil then wm.battles_won = tonumber(parts.battles_won) or 0 end
  if parts.campaign_units ~= nil then wm.units = {} end
  for _, u in ipairs(parts.campaign_units or {}) do
    if type(u) == "table" then
      local kind = tostring(u.kind or "")
      local id = CAMPAIGN_UNIT_ID[kind]
      if kind == "foe" or kind == "ally" or kind == "detach" then
        id = tostring(u.id or "")
      end
      if kind == "poi" then id = (tonumber(u.taken) or 0) ~= 0 and "P1" or "P*" end
      if id and id ~= "" then
        wm.units[#wm.units + 1] = {
          id = id, c = tonumber(u.c) or 0, r = tonumber(u.r) or 0,
          size = tonumber(u.size) or 0, f = tostring(u.flag or ""),
          owner = tostring(u.owner or ""),
          kind = kind,
          -- Carried so the legend can read like the text board rather than
          -- printing a bare glyph and a number.
          name = (u.name ~= nil and tostring(u.name)) or nil,
          shaken = tonumber(u.shaken) or 0,
          taken = (tonumber(u.taken) or 0) ~= 0,
        }
      end
    end
  end

  for _, q in ipairs(parts.campaign_queue or {}) do
    if type(q) == "table" and q.id ~= nil and q.label ~= nil then
      local id = tostring(q.id)
      local label = tostring(q.label)
      local c, r = square_to_cell(label)
      if c then
        local list = wm.queues[id]
        if not list then list = {}; wm.queues[id] = list end
        list[#list + 1] = { c = c, r = r, sq = label }
      end
    end
  end
  wm.queue = wm.queues.A or {}

  S.war_map = wm
  S.wm_pending = nil
end

-- ---------------------------------------------------------------------------
-- Guild.War: the tactical battle board
-- ---------------------------------------------------------------------------
-- S.war_points is set from every frame, active or not, exactly as the MIP
-- handler set it from every BATTLE value: it is the running total, not a
-- property of a battle in progress.
--
-- The grids arrive as arrays of row strings. MIP sent one flat string per grid
-- and the client sliced it into rows itself, guarding on the string being long
-- enough -- a guard that exists only because a truncated wire value was
-- possible. Rows are rows here, so the slicing and its guard both go.
--
-- `wall_hp` and `wall_tier` are carried by the payload and have no reader in
-- popups/war.lua, so they are not stored.
-- Guild.War frames are DELTAS: gmcp_ns_delta_step() sends only the keys whose
-- value changed since the last push. This used to read every field off `rec`
-- unconditionally, so the common mid-battle frame -- the one carrying just a
-- new `turn` or `spent` -- arrived without `active`, "(tonumber(rec.active)
-- or 0) ~= 1" was true, and a LIVE battle was wiped. The board vanished from
-- the War tab a second after it appeared, and autowar.lua (which reads
-- state.battle to decide whether a battle is underway) fell through to the
-- campaign planner and re-sent "vcampaign fight" at a battle already open --
-- the server answering "A battle is already underway (vbattle)".
--
-- An absent key means UNCHANGED, never empty. So: clear only when `active`
-- says 0 outright, start from the battle already held unless the frame is a
-- full resend, and copy each field only when the frame actually carries it.
-- The war and battle sagas (saga.h), as { t, tone, text }
-- records. Its own package, not part of Kingdom: eighty records competing
-- for Kingdom's eight pages would have pushed later-sorting keys off the
-- frame (see send_gmcp_saga's comment). Kept on the state root rather than
-- inside the campaign record, because a saga is how you read back a war
-- that has already ended and so must survive the map being cleared.
local function read_saga(src)
  local out = {}
  for _, e in ipairs(src or {}) do
    if type(e) == "table" then
      out[#out + 1] = { t = tonumber(e.t) or 0,
                        tone = tostring(e.tone or ""),
                        text = tostring(e.text or "") }
    end
  end
  return out
end

-- Called from write_battle: the sagas ride on Guild.War, which
-- PACKAGE_KEY dispatches as one unit, so they arrive alongside the board.
local function write_saga(parts)
  if parts.saga_war ~= nil then S.saga_war = read_saga(parts.saga_war) end
  if parts.saga_battle ~= nil then S.saga_battle = read_saga(parts.saga_battle) end
end

local function write_battle(rec, full)
  if type(rec) ~= "table" then return end
  if rec.war_points ~= nil then S.war_points = tonumber(rec.war_points) or 0 end

  -- Before the inactive early-return below: a saga is read back precisely
  -- when no battle is running.
  write_saga(rec)

  if rec.active ~= nil and (tonumber(rec.active) or 0) ~= 1 then
    S.battle = nil
    return
  end
  -- A delta about a battle we never had says nothing we can use.
  if rec.active == nil and not S.battle then return end

  local prev = (not full) and S.battle or nil
  local b = {
    phase      = prev and prev.phase      or "",
    turn       = prev and prev.turn       or 0,
    mode       = prev and prev.mode       or "",
    target     = prev and prev.target     or "",
    budget     = prev and prev.budget     or 0,
    spent      = prev and prev.spent      or 0,
    width      = prev and prev.width      or 8,
    height     = prev and prev.height     or 8,
    dz         = prev and prev.dz         or 2,
    war_points = prev and prev.war_points or 0,
    terrain      = prev and prev.terrain,
    terrain_rows = prev and prev.terrain_rows,
    works_rows   = prev and prev.works_rows,
    units   = prev and prev.units   or {},
    reserve = prev and prev.reserve or {},
  }
  if rec.phase      ~= nil then b.phase      = tostring(rec.phase) end
  if rec.turn       ~= nil then b.turn       = tonumber(rec.turn) or 0 end
  if rec.mode       ~= nil then b.mode       = tostring(rec.mode) end
  if rec.target     ~= nil then b.target     = tostring(rec.target) end
  if rec.budget     ~= nil then b.budget     = tonumber(rec.budget) or 0 end
  if rec.spent      ~= nil then b.spent      = tonumber(rec.spent) or 0 end
  if rec.w          ~= nil then b.width      = tonumber(rec.w) or 8 end
  if rec.h          ~= nil then b.height     = tonumber(rec.h) or 8 end
  if rec.dz         ~= nil then b.dz         = tonumber(rec.dz) or 2 end
  if rec.war_points ~= nil then b.war_points = tonumber(rec.war_points) or 0 end

  if type(rec.terrain) == "table" and #rec.terrain > 0 then
    b.terrain_rows = {}
    for i, row in ipairs(rec.terrain) do b.terrain_rows[i] = tostring(row) end
    -- popups/war.lua reads terrain_rows; `terrain` is kept as the same flat
    -- concatenation MIP delivered, because the Battle Board's own tooltip path
    -- indexes it directly.
    b.terrain = table.concat(b.terrain_rows)
  end
  if type(rec.works) == "table" and #rec.works > 0 then
    b.works_rows = {}
    for i, row in ipairs(rec.works) do b.works_rows[i] = tostring(row) end
  end

  if rec.units ~= nil then b.units = {} end
  for _, u in ipairs(rec.units or {}) do
    if type(u) == "table" then
      -- The wire value is the server's own word: battle.h builds every
      -- company with "side":"you" and compares on that string. This tested
      -- for "Y" -- MIP's spelling, and MIP is gone -- so EVERY company of
      -- yours was classified as the foe's.
      --
      -- Not a cosmetic miss. The War tab's "Deployed" block filters on
      -- side == "you" and listed nothing; the board drew your own host in the
      -- foe's red; and autowar.lua's split_units() saw no units of yours and
      -- the whole board as hostile, which is what it plans orders from.
      local side = (tostring(u.side) == "you") and "you" or "foe"
      local utype = tostring(u.type or "")
      -- Allied house levies ride under the hird type because the server reuses
      -- foe_hird for allied aid; the client renames them so they load the
      -- green-tinted art. Ported verbatim from the MIP handler.
      if side == "you" and utype == "foe_hird" then utype = "ally_levy" end
      local leader = tostring(u.leader or "")
      b.units[#b.units + 1] = {
        side = side,
        label = tostring(u.label or ""),
        size = tonumber(u.size) or 0,
        coord = tostring(u.coord or ""),
        morale = tonumber(u.morale) or 0,
        utype = utype,
        leader = (leader ~= "") and leader or nil,
        bid = tonumber(u.bid) or 0,
        -- Per-battle letter handle: lowercase yours, uppercase the foe's, one
        -- per unit. Empty from servers older than the letter change, which is
        -- what keeps `ord` around as the fallback.
        g = tostring(u.g or ""),
        ord = tonumber(u.ord) or 0,
      }
    end
  end

  if rec.reserve ~= nil then b.reserve = {} end
  for _, u in ipairs(rec.reserve or {}) do
    if type(u) == "table" then
      local leader = tostring(u.leader or "")
      b.reserve[#b.reserve + 1] = {
        label = tostring(u.label or ""),
        size = tonumber(u.size) or 0,
        uid = tonumber(u.uid) or 0,
        cost = tonumber(u.cost) or 0,
        leader = (leader ~= "") and leader or nil,
      }
    end
  end

  S.battle = b
end


M._gmcp = {
  RAIDLOG          = write_raidlog,
  RTARGETS         = write_rtargets,
  HIRD             = write_hird,
  THRALLS          = write_thralls,
  THRALL_FOLLOWER  = write_thrall_follower,
  VARANG           = write_varang,
  BDMG             = write_bdmg,
  RAID             = write_raid,
  PATROL           = write_patrol,
  GARRISON         = write_garrison,
  GRUDGES          = write_grudges,
  STANDINGS        = write_standings,
  VREP             = write_vrep,
  DIPLO            = write_diplo,
  ARMY             = write_army,
  DYNASTY          = write_dynasty,
  WAR              = write_war,
  WMAP             = write_campaign,
  BATTLE           = write_battle,
}

return M
