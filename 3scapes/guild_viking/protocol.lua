-- GMCP frame ingestion for Guild.* packages.
--
-- This layer used to be transport-agnostic, with a MIP BBE adapter and a GMCP
-- adapter both reducing to ingest(key, value). MIP is gone: every payload the
-- guild sends is carried by a Guild.* package, and guild_viking_census_test
-- asserts that no MIP-only key is left. What survives of that design is the
-- key space -- writers are still registered under the uppercase names the MIP
-- keys used (VMAP, CPLAN, TQUEUE), because those names are load-bearing in
-- gmcp_map, in every handler module and in the census. Renaming them to their
-- GMCP spellings is a separate refactor with no behavioural payoff.
local gmcp_map = require("gmcp_map")

local protocol = {}

local trace_on = false   -- diagnostic: /vik trace -- off by default, silent otherwise

-- Keys GMCP has fed this connection. Kept per key rather than as one boolean:
-- it is what /vik status counts and /vik source lists, and a panel that has
-- never been pushed is a different thing from one pushed empty.
local gmcp_keys = {}

function protocol.gmcp_keys()
  local out = {}
  for k in pairs(gmcp_keys) do out[k] = true end
  return out
end

-- GMCP-side writers, keyed by MIP key. Registered from a handler module's
-- `_gmcp` table, so one key's two transports are declared next to each other.
local gmcp_handlers = {}

-- Reserved envelope members the protocol layer owns (gmcp_guild_key_reserved).
local ENVELOPE = { guild = true, full = true, page = true, pages = true }

-- `full` is owned by this layer -- it is stripped with the rest of the
-- envelope and never reaches a writer as a payload key -- but its MEANING is a
-- writer's business, so it is passed on as a second argument to every GMCP
-- writer instead of being consumed and discarded.
--
-- gmcp.h's DELTA SEMANTICS: the first push of a sub-package after subscribing
-- (or after send_gmcp_full_snapshot()) carries `full: 1` plus the COMPLETE key
-- set; every later push carries only the keys that changed and no `full` key
-- at all. So on a full frame, a key's ABSENCE means gone, and on a delta it
-- means unchanged. A writer that merges a variable-arity key set cannot tell
-- those apart without this flag -- see handlers/livestock.lua's write_lmarket,
-- whose per-lineage pools are exactly that shape.
--
-- The wire value is the mudlib's `1`; `true` and `"1"` are accepted so a
-- change of JSON encoder on either side cannot silently turn every full
-- resend into a delta. Anything else, absence included, is a delta -- note
-- that a bare truthiness test would read a `0` as full, since 0 is truthy in
-- Lua.
local function frame_is_full(v)
  return v == 1 or v == true or v == "1"
end

-- A composite MIP key (gmcp_map.COMPOSITE) receives two GMCP keys -- e.g.
-- SROLES gets `sroles` and `sroles_meta`. Both halves may arrive in the same
-- frame, or a delta may carry just one; either way the writer gets a single
-- table keyed by GMCP key, built from whichever halves this frame had,
-- rather than being invoked once per half. Reverse-indexed once here so
-- frame processing can test membership in O(1).
local composite_of = {}
for mip_key, parts in pairs(gmcp_map.COMPOSITE) do
  for _, gk in ipairs(parts) do composite_of[gk] = mip_key end
end

-- The mudlib stamps this from query_guild() (secure/pinc/guild.h:257, a bare
-- `return guild;` with no normalization) into the frame's `guild` field
-- (secure/pinc/gmcp.h:676); query_guild() in turn reflects whatever
-- set_guild(...) was called with, which for this guild is the lowercase
-- singular literal "viking" (players/viking/room/gatehouse.c:254). Compare
-- case-insensitively so a casing change on either side cannot silently turn
-- every real frame into a dropped "foreign" one again.
local GUILD_NAME = "viking"

local gmcp_stats = { frames = 0, foreign = 0, malformed = 0, suppressed = 0,
                     unknown = {}, applied = {}, errors = {} }
local gmcp_reported_errors = {}

-- GMCP writer outcomes record into gmcp_stats, mirroring the MIP-side
-- reported_errors dedup below but scoped separately -- a MIP key and a GMCP
-- key that happen to share a name must not suppress each other's first-error
-- print. Built as closures over the `gmcp_stats` upvalue (rather than
-- snapshotting its sub-tables) so they keep working after
-- protocol.reset_connection() reassigns gmcp_stats wholesale.
local function gmcp_record_error(key, err)
  gmcp_stats.errors[key] = (gmcp_stats.errors[key] or 0) + 1
  if not gmcp_reported_errors[key] then
    gmcp_reported_errors[key] = true
    print("[vik] gmcp writer error " .. key .. ": " .. tostring(err))
  end
end

local function gmcp_record_success(key)
  gmcp_stats.applied[key] = (gmcp_stats.applied[key] or 0) + 1
  gmcp_keys[key] = true
  ui.dirty()
end

local gmcp_dispatch_opts = { record_error = gmcp_record_error, record_success = gmcp_record_success }

function protocol.gmcp_handler(key, fn)
  if gmcp_handlers[key] then error("duplicate gmcp handler: " .. key) end
  gmcp_handlers[key] = fn
end

-- A copy, like protocol.gmcp_keys() above: callers (init.lua's /vik source and
-- /vik status) get a snapshot they cannot accidentally mutate into the live
-- counters. Sub-tables are copied too, since the counts that matter live in
-- them.
function protocol.gmcp_stats()
  local out = {}
  for k, v in pairs(gmcp_stats) do
    if type(v) == "table" then
      local sub = {}
      for sk, sv in pairs(v) do sub[sk] = sv end
      out[k] = sub
    else
      out[k] = v
    end
  end
  return out
end

-- Invoke one writer: pcall, print the first error per key, account the rest.
-- Still parameterized by opts.record_error/opts.record_success -- it was
-- shared with MIP's two dispatch tiers before those went, and the indirection
-- costs nothing while keeping the accounting in one place.
local function dispatch(key, fn, opts, ...)
  local ok, err = pcall(fn, ...)
  if not ok then
    opts.record_error(key, err)
    return
  end
  opts.record_success(key)
end

-- Paging state, per package: two panels can be mid-run at once.
local page_runs = {}

local function is_array(v)
  return type(v) == "table" and (#v > 0 or next(v) == nil)
end

-- Merge one page's keys into a run. A key repeated across pages is a sliced
-- array and its slices concatenate in page order; only arrays are ever sliced
-- server-side, so a repeated non-array is last-wins and counted malformed.
local function merge_page(run, data)
  for key, value in pairs(data) do
    if not ENVELOPE[key] then
      local prev = run.keys[key]
      if key == "lmarket_partial" then
        -- Payload metadata, not envelope: retain it until composite dispatch.
        -- Repeated scalar markers are not sliced arrays or malformed repeats.
        run.keys[key] = value
      elseif prev == nil then
        -- Stored by reference, and an array key sliced across later pages is
        -- appended to in place below -- so a future consumer must not retain
        -- the decoded payload table expecting it to stay as delivered.
        run.keys[key] = value
      elseif is_array(prev) and is_array(value) then
        for i = 1, #value do prev[#prev + 1] = value[i] end
      else
        run.keys[key] = value
        gmcp_stats.malformed = gmcp_stats.malformed + 1
      end
    end
  end
end

-- Shared tail for both the single-key and composite paths: look up the
-- registered writer for a MIP key and dispatch it, or count the key as
-- unknown when no writer is registered (e.g. MONUMENTS, which has no writer
-- yet -- see composite_of's callers).
local function dispatch_gmcp(mip_key, value, full)
  if trace_on then
    if mip_key == "VMAP" and type(value) == "table" then
      local fields = {}
      for key, item in pairs(value) do
        local summary = type(item) == "table"
          and (tostring(#item) .. " entries") or tostring(item)
        fields[#fields + 1] = tostring(key) .. "=" .. summary
      end
      table.sort(fields)
      print("[vik] Guild.Map fields: " .. table.concat(fields, ", "))
    end
    print("[vik] gmcp " .. mip_key)
  end
  local fn = gmcp_handlers[mip_key]
  if not fn then
    gmcp_stats.unknown[mip_key] = (gmcp_stats.unknown[mip_key] or 0) + 1
    return
  end
  dispatch(mip_key, fn, gmcp_dispatch_opts, value, full and true or false)
end

-- Route one payload key through the explicit key map. `full` is the frame's
-- own full-resend flag, forwarded to the writer -- see frame_is_full above.
function protocol.apply_gmcp_key(gmcp_key, value, full)
  local mip_key = gmcp_map.mip_key(gmcp_key)
  if not mip_key then
    -- Counted under the GMCP name, so /vik source shows the key the guild
    -- actually sent rather than a synthesised MIP name.
    gmcp_stats.unknown[gmcp_key] = (gmcp_stats.unknown[gmcp_key] or 0) + 1
    return
  end
  dispatch_gmcp(mip_key, value, full)
end

-- Order two apply units. Mapped keys go first, sorted by the MIP key they
-- resolve to; unmapped ones (which only bump a counter) follow, sorted by the
-- GMCP name they were sent under. Two distinct GMCP keys resolving to the same
-- MIP key without being declared COMPOSITE cannot happen today, but the
-- secondary comparison on the GMCP name keeps even that case deterministic --
-- a composite unit carries no single GMCP name and sorts as "".
local function unit_lt(a, b)
  if (a.mip ~= nil) ~= (b.mip ~= nil) then return a.mip ~= nil end
  if a.mip == nil then return a.gmcp < b.gmcp end
  if a.mip ~= b.mip then return a.mip < b.mip end
  return (a.gmcp or "") < (b.gmcp or "")
end

-- Apply every key of one frame, gathering a composite's halves into a single
-- writer call instead of one call per GMCP key. `skip_envelope` is needed
-- only for the unpaged branch's raw `data`; merge_page already excludes
-- envelope members from a de-paged run's `keys`.
--
-- Keys are applied in a declared, stable order (see unit_lt above) rather than
-- in pairs() order. pairs() order is unspecified -- it follows the table's
-- internal hashing, not the frame -- so two writers that touch a common state
-- field would land in an arbitrary order, and since frames are deltas either
-- key may also arrive alone. The visible symptom is a pane value flickering
-- between two answers with no underlying state change, intermittently and
-- with nothing in the frame to explain it. No such collision exists today
-- (SETTLERX owns the housing totals outright -- see write_shplots in
-- handlers/city.lua), but a later plan adds ~20 more keys, and this is the one
-- class of bug that cannot be reconstructed from a bug report.
local function apply_gmcp_frame(data, skip_envelope, full, package)
  local pending = {}  -- mip_key -> { [gmcp_key] = value }, composites only
  local units = {}    -- { mip = <MIP key or nil>, gmcp = <name>, value = ... }
  for key, value in pairs(data) do
    if key ~= "lmarket_partial" and (not skip_envelope or not ENVELOPE[key]) then
      local composite_key = composite_of[key]
      if composite_key then
        local parts = pending[composite_key]
        if not parts then
          parts = {}
          pending[composite_key] = parts
          units[#units + 1] =
            { mip = composite_key, gmcp = "", value = parts, composite = true }
        end
        parts[key] = value
      else
        units[#units + 1] = { mip = gmcp_map.mip_key(key), gmcp = key, value = value }
      end
    end
  end
  table.sort(units, unit_lt)
  for _, u in ipairs(units) do
    if u.composite then
      -- Marked Livestock chunks contain only a bounded subset of lineages.
      -- Each delivered list is complete after reassembly; omitted pools keep
      -- their original receipts. Only numeric 1 opts out of legacy eviction.
      local composite_full = full
      if package == "Guild.Livestock" and data.lmarket_partial == 1
          and u.mip == "LMARKET" then
        composite_full = false
      end
      dispatch_gmcp(u.mip, u.value, composite_full)
    else
      -- Single keys keep going through apply_gmcp_key, so the unmapped-key
      -- accounting lives in exactly one place.
      protocol.apply_gmcp_key(u.gmcp, u.value, full)
    end
  end
end

-- A package whose whole payload is one MIP key's data bypasses the key map
-- entirely -- see gmcp_map.PACKAGE_KEY for why that has to exist rather than
-- being a shortcut. Everything else is applied key by key.
local function apply_gmcp_package(package, data, skip_envelope, full)
  local whole = gmcp_map.package_key(package)
  if not whole then
    apply_gmcp_frame(data, skip_envelope, full, package)
    return
  end
  -- The envelope is the protocol layer's, not the writer's, so it is stripped
  -- here too. merge_page already excluded it from a de-paged run's keys.
  local payload = data
  if skip_envelope then
    payload = {}
    for key, value in pairs(data) do
      if not ENVELOPE[key] then payload[key] = value end
    end
  end
  dispatch_gmcp(whole, payload, full)
end

-- One Guild.* frame. Keys are applied individually: a key absent from a frame
-- means unchanged, never empty, because ordinary frames are deltas. A frame
-- may be split across pages, and an oversized array key sliced across those
-- pages (the key repeated with successive slices) -- see merge_page above.
function protocol.on_gmcp(package, data)
  if type(data) ~= "table" then return end
  gmcp_stats.frames = gmcp_stats.frames + 1

  -- Whose guild sent this. A frame from another guild must never reach a
  -- writer: the protocol layer stamps `guild` precisely so a client can
  -- tell. Compared case-insensitively -- see GUILD_NAME's comment above.
  local guild = data.guild
  if type(guild) ~= "string" or guild:lower() ~= GUILD_NAME then
    gmcp_stats.foreign = gmcp_stats.foreign + 1
    return
  end

  local page = tonumber(data.page)
  local pages = tonumber(data.pages)
  local full = frame_is_full(data.full)

  -- page/pages appear only when a frame is split, so their absence means
  -- this frame is complete on its own.
  if not page or not pages or pages <= 1 then
    page_runs[package] = nil
    apply_gmcp_package(package, data, true, full)
    return
  end

  local run = page_runs[package]
  -- A fresh page 1 abandons whatever was accumulating: it is a new snapshot.
  if page == 1 or not run then
    run = { pages = pages, next_page = 1, keys = {}, full = full }
    page_runs[package] = run
  end

  if page ~= run.next_page or pages ~= run.pages then
    -- Out of order or a pages mismatch: the run cannot be trusted.
    page_runs[package] = nil
    gmcp_stats.malformed = gmcp_stats.malformed + 1
    return
  end

  merge_page(run, data)
  run.next_page = page + 1
  -- gmcp.h's PAGING note says `full` is repeated identically on every page of
  -- a push, and merge_page strips it with the rest of the envelope -- so the
  -- run carries it instead. OR-ed rather than last-wins so a page that lost
  -- the flag cannot downgrade a full resend to a delta and re-open the
  -- eviction hole this exists to close.
  run.full = run.full or full

  if page == pages then
    page_runs[package] = nil
    apply_gmcp_package(package, run.keys, false, run.full)
  end
end

-- Cleared on disconnect: the next session may not negotiate GMCP at all, and
-- stale GMCP state must not outlive the connection that produced it.
function protocol.reset_connection()
  gmcp_stats = { frames = 0, foreign = 0, malformed = 0, suppressed = 0,
                 unknown = {}, applied = {}, errors = {} }
  page_runs = {}
  gmcp_keys = {}
end

-- Diagnostic trace, mirroring gmcp.trace's convention: no argument reports the
-- current setting, true/false sets it. Off by default. It prints one line per
-- payload key as it is routed, which is the level the old MIP trace worked at
-- -- a whole-frame dump is what gmcp.trace itself already gives you.
function protocol.trace(on)
  if on ~= nil then trace_on = on and true or false end
  return trace_on
end

return protocol
