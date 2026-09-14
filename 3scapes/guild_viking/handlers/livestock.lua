-- Guild.Livestock payload writers: herds, butchery queue, feed upkeep, pending
-- deliveries, the Livestock Find hall and the per-lineage market.
--
-- Field names are the server's, read from
-- 3s/players/viking/obj/include/client.h's _v_* builders -- NOT from LEGACY's
-- parser, whose local names differ (bid/qual/ster/yld are bldg/quality/
-- sterile/yield on the wire).
--
-- Display calls are deliberately absent: the protocol layer already marks
-- ui.dirty().
-- No MIP decoder in this file needs util.split: Guild.Livestock has no MIP
-- predecessor in this plugin (see the ORDER-array comment near the bottom),
-- so there is nothing here to zip against a declared field order.
local S = require("state").S

local M = {}

-- The server sends "0" for "no trait" (client.h's _v_herds/_v_lmarket set
-- htrait/mtrait to "0" when the herd or listing has none). Left as "0" it
-- would be looked up as a trait id, so it is normalised here, once, rather
-- than in every consumer.
local function trait_or_nil(t)
  if t == nil or t == "" or t == "0" then return nil end
  return tostring(t)
end

local HERDS_ORDER = { "bldg", "head", "quality", "gen", "sterile", "hard",
                      "fert", "yield", "vigor", "con", "breed", "hv",
                      "trait", "age_ticks" }

-- LEGACY 2300 (guild_viking.lua, the MIP HERDS branch).
-- Keyed by building, because every consumer looks a herd up by the building
-- that houses it. Replaced wholesale on each arrival: the server OMITS a
-- building whose head has dropped to 0, so merging would resurrect dead herds.
local function write_herds(value)
  local out = {}
  for _, r in ipairs(value or {}) do
    if r.bldg then
      out[r.bldg] = {
        bldg = r.bldg,
        head = tonumber(r.head) or 0,
        quality = tonumber(r.quality) or 0,
        gen = tonumber(r.gen) or 0,
        sterile = tonumber(r.sterile) or 0,
        hard = tonumber(r.hard) or 0,
        fert = tonumber(r.fert) or 0,
        yield = tonumber(r.yield) or 0,
        vigor = tonumber(r.vigor) or 0,
        con = tonumber(r.con) or 0,
        breed = tostring(r.breed or ""),
        hv = tonumber(r.hv) or 0,
        trait = trait_or_nil(r.trait),
        age_ticks = tonumber(r.age_ticks) or 0,
      }
    end
  end
  S.herds = out
  -- The Guild.Livestock arrival latch. gmcp.h's Guild.Livestock comment says
  -- herds is one of the keys ALWAYS sent, even empty, so this writer running
  -- at all is the package having arrived. Auto-Herd gates its spending on it
  -- (the spec's Corrections-to-LEGACY table: "Gate on `Guild.Livestock`
  -- having arrived", replacing LEGACY's mip_livestock gate) -- Guild.City and
  -- Guild.Livestock are separate slow-cadence panels in a round-robin, so
  -- City routinely lands first and a planner gated only on S.buildings runs
  -- believing every building is empty. state.reset_connection() clears the
  -- latch, so it can never outlive the connection that set it.
  S.livestock_seen = true
end

local BQUEUE_SLOT_ORDER = { "slot", "species", "meat", "qty", "secs", "trait" }

-- LEGACY 2325 (guild_viking.lua, the MIP BQUEUE branch). A sibling split of
-- one server mapping (_v_bqueue()'s used/max/slots), so a delta frame may
-- carry any subset of the three halves -- each is applied only when present,
-- matching write_sroles/write_monuments in handlers/city.lua.
local function write_bqueue(parts)
  parts = parts or {}
  if parts.bqueue_used ~= nil then
    S.bqueue_used = tonumber(parts.bqueue_used) or 0
  end
  if parts.bqueue_max ~= nil then
    S.bqueue_max = tonumber(parts.bqueue_max) or 0
  end
  if type(parts.bqueue) == "table" then
    local out = {}
    for _, r in ipairs(parts.bqueue) do
      table.insert(out, {
        slot = tonumber(r.slot) or 0,
        species = tostring(r.species or ""),
        meat = tostring(r.meat or ""),
        qty = tonumber(r.qty) or 0,
        secs = tonumber(r.secs) or 0,
        trait = trait_or_nil(r.trait),
      })
    end
    S.bqueue = out
  end
end

local LFEED_ORDER = { "grain", "water", "head" }

-- LEGACY 2352 (guild_viking.lua, the MIP LFEED branch). The only mapping key
-- in this file: grain/water/head, not a positional record.
local function write_lfeed(value)
  value = value or {}
  S.lfeed = {
    grain = tonumber(value.grain) or 0,
    water = tonumber(value.water) or 0,
    head = tonumber(value.head) or 0,
  }
end

local LPENDING_ORDER = { "bldg", "species", "breed", "count", "secs" }

-- LEGACY 2361 (guild_viking.lua, the MIP LPENDING branch).
local function write_lpending(value)
  local out = {}
  for _, r in ipairs(value or {}) do
    table.insert(out, {
      bldg = tostring(r.bldg or ""),
      species = tostring(r.species or ""),
      breed = tostring(r.breed or ""),
      count = tonumber(r.count) or 0,
      secs = tonumber(r.secs) or 0,
    })
  end
  S.lpending = out
end

local LFIND_POSTS_ORDER = { "id", "species", "min_quality", "max_price",
                            "bldg", "tier", "trait", "state" }
local LFIND_OFFERS_ORDER = { "id", "species", "breed", "count", "quality",
                             "price", "hard", "fert", "yield", "vigor", "con",
                             "secs", "trait" }
local LFIND_AUCTIONS_ORDER = { "id", "species", "breed", "quality", "reserve",
                               "my_bid", "secs", "trait" }

-- LEGACY 2899 (guild_viking.lua, the MIP LFIND branch; bespoke '!'-joined
-- three-section value, matching client.h's _mip_lfind_value()). Three
-- sub-arrays -- postings, offers, auctions -- each applied only when its own
-- key arrived in this frame.
local function write_lfind(parts)
  parts = parts or {}
  if type(parts.lfind_posts) == "table" then
    local out = {}
    for _, r in ipairs(parts.lfind_posts) do
      table.insert(out, {
        id = tonumber(r.id) or 0,
        species = tostring(r.species or ""),
        min_quality = tonumber(r.min_quality) or 0,
        max_price = tonumber(r.max_price) or 0,
        bldg = tostring(r.bldg or ""),
        tier = tonumber(r.tier) or 0,
        trait = trait_or_nil(r.trait),
        state = (r.state and tostring(r.state) ~= "") and tostring(r.state) or "open",
      })
    end
    S.lfind.posts = out
  end
  if type(parts.lfind_offers) == "table" then
    local out = {}
    for _, r in ipairs(parts.lfind_offers) do
      table.insert(out, {
        id = tonumber(r.id) or 0,
        species = tostring(r.species or ""),
        breed = tostring(r.breed or ""),
        count = tonumber(r.count) or 0,
        quality = tonumber(r.quality) or 0,
        price = tonumber(r.price) or 0,
        hard = tonumber(r.hard) or 0,
        fert = tonumber(r.fert) or 0,
        yield = tonumber(r.yield) or 0,
        vigor = tonumber(r.vigor) or 0,
        con = tonumber(r.con) or 0,
        secs = tonumber(r.secs) or 0,
        trait = trait_or_nil(r.trait),
      })
    end
    S.lfind.offers = out
  end
  if type(parts.lfind_auctions) == "table" then
    local out = {}
    for _, r in ipairs(parts.lfind_auctions) do
      table.insert(out, {
        id = tonumber(r.id) or 0,
        species = tostring(r.species or ""),
        breed = tostring(r.breed or ""),
        quality = tonumber(r.quality) or 0,
        reserve = tonumber(r.reserve) or 0,
        my_bid = tonumber(r.my_bid) or 0,
        secs = tonumber(r.secs) or 0,
        trait = trait_or_nil(r.trait),
      })
    end
    S.lfind.auctions = out
  end
end

local LMARKET_ORDER = { "lin", "idx", "species", "breed", "count", "price",
                        "hard", "fert", "yield", "vigor", "con", "trait" }

local function build_lmarket_record(r)
  return {
    lin = tonumber(r.lin) or 0,
    idx = tonumber(r.idx) or 0,
    species = tostring(r.species or ""),
    breed = tostring(r.breed or ""),
    count = tonumber(r.count) or 0,
    price = tonumber(r.price) or 0,
    hard = tonumber(r.hard) or 0,
    fert = tonumber(r.fert) or 0,
    yield = tonumber(r.yield) or 0,
    vigor = tonumber(r.vigor) or 0,
    con = tonumber(r.con) or 0,
    trait = trait_or_nil(r.trait),
  }
end

-- LEGACY 2942 (guild_viking.lua, the MIP LMARKET branch). The server
-- sends one key per lineage (lmarket_1..lmarket_13) and OMITS a lineage
-- with no pool entirely, so this composite is inherently variable-arity --
-- MERGE on a delta, do not replace. A delta frame carrying only some
-- lineages must leave the others' last-known pools standing.
--
-- But merging is only right for a DELTA. Because a lineage whose pool empties
-- loses its key altogether, a shrinking key set makes the protocol layer send
-- the whole Livestock push as a full resend with the complete current key set
-- (gmcp.h's own note on that trade-off, at the lmarket_<n> partitioning
-- comment). On such a frame a missing lineage means GONE, and merging leaves
-- its last-known pool standing forever: Auto-Herd then scores an animal that
-- is no longer for sale, emits a buy the server refuses, and -- since a
-- refusal changes no state -- replans, picks the same listing and repeats. A
-- stale TRAIT listing carries a +1000 score bonus, so it would win every
-- comparison permanently and the planner would never buy anything again.
--
-- `full` is the frame's own flag, surfaced by protocol.lua (see frame_is_full
-- there). Replace on full, merge on a delta.
--
-- Residual, worth knowing: a full frame that carries NO lmarket_<n> key at
-- all -- every one of the thirteen pools empty at once -- never reaches this
-- writer, because protocol.lua only builds a composite unit when at least one
-- of its part keys is present in the frame. Closing that would need a
-- package -> composite association the key map does not currently hold.
local function write_lmarket(parts, full)
  parts = parts or {}
  local replacement = full and {} or nil
  for k, records in pairs(parts) do
    local lin = tostring(k):match("^lmarket_(%d+)$")
    if lin and type(records) == "table" then
      local out = {}
      for _, r in ipairs(records) do
        table.insert(out, build_lmarket_record(r))
      end
      if replacement then
        replacement[tonumber(lin)] = out
      else
        S.lmarket[tonumber(lin)] = out
      end
    end
  end
  if replacement then S.lmarket = replacement end
end

local LNEEDS_ORDER = { "species", "current", "cap" }

-- LEGACY 2966 (guild_viking.lua, the MIP LNEEDS branch).
local function write_lneeds(value)
  local out = {}
  for _, r in ipairs(value or {}) do
    table.insert(out, {
      species = tostring(r.species or ""),
      current = tonumber(r.current) or 0,
      cap = tonumber(r.cap) or 0,
    })
  end
  S.lneeds = out
end

-- The nine ORDER locals above (HERDS_ORDER .. LNEEDS_ORDER) are, like
-- city.lua's SETTLERS_ORDER/SACTIONS_ORDER/SPROJ_ORDER/SHPLOTS_ORDER,
-- declared-order documentation only -- none of them is consumed by any
-- function in this file, and none of them is exercised by a MIP branch here:
-- Guild.Livestock is GMCP-only in this plugin. They exist to record the wire
-- order gmcp_map.zip() would need if a MIP decoder were ever added for this
-- package. They are pure locals, matching city.lua's shape exactly: nothing
-- but `_gmcp` belongs on the returned module table below, since init.lua's
-- register_handlers loop registers every non-reserved M.* field as an exact
-- MIP key.

M._gmcp = {
  HERDS = write_herds, BQUEUE = write_bqueue, LFEED = write_lfeed,
  LPENDING = write_lpending, LFIND = write_lfind,
  LMARKET = write_lmarket, LNEEDS = write_lneeds,
}

return M
