-- Auto-Herd: client-side livestock husbandry automation. M.plan() decides
-- what to buy; M.tick() is the ONLY function in this file that calls
-- mud.send.
--
-- *** SPENDING WARNING -- stated plainly, not softened ***
-- Turning `page_opts.get("auto_herd")` ON authorises purchases IMMEDIATELY:
-- `restock`, `crossbreed` and `buy_quality` all default to true below
-- (LEGACY's own defaults, verified at guild_viking_husbandry.lua:83-98 and
-- preserved verbatim), and `reserve` (2000 daler) is the ONLY brake
-- stopping the planner from spending every daler above that floor. This is
-- LEGACY's own behaviour and is the CHOSEN behaviour for this port, not an
-- oversight -- it is documented here, plainly, so nobody discovers it by
-- losing daler.
--
-- Auto-Herd builds purchases only in buy_cmd: legacy whole-lot
-- `vlivestock buy <lineage_token> <id>` or protected buys with count + token.
-- Both use a 1-based id. The normal planner NEVER slaughters. Separately,
-- explicit `replace on` authorizes irreversible slaughter via herd_replace,
-- with the master also on, fresh observations, explicit models/costs and
-- successfully persisted exposure/marker BEFORE sending.
-- At most ONE action is taken per AH_INTERVAL cycle, and every access check
-- (owned + enabled building, budget above `reserve`, herd space under the
-- building cap, no matching delivery already in S.lpending) happens BEFORE
-- any command is constructed -- see M.plan's own header block.
--
-- `keep` (default 4) is NOT a slaughter setting, despite LEGACY's own
-- comment on it (guild_viking_husbandry.lua:86) reading "breeders kept when
-- slaughtering surplus" -- that comment is stale. The code only ever reads
-- `keep` as the RESTOCK BREEDING FLOOR, the same way LEGACY's own
-- ah_keep_ok()/restock planner read it (husbandry.lua:270). Nothing in this
-- normal planner slaughters anything. Replacement additionally respects this
-- floor; it has its own opt-in, limits and halt acknowledgement.
--
-- PROVENANCE, every line grep-verified against
-- /home/simon/code/3s_scripts_old/lua/guild_viking_husbandry.lua before
-- writing. Where a range is given rather than a single opening line, its
-- closing line was located, not estimated:
--   AH_INTERVAL / AH_CONFIRM_TIMEOUT / AH_COOLDOWN   38-40
--   LIVE_BLDGS                                        42
--   GOAL_W                                            66-73
--   GOAL_ORDER                                        74
--   ah_settings (-> M.settings), DEFAULTS table        81-112 (table 83-98)
--   bldg_tier / owns (-> local helpers)               117-122
--   ah_bldg_alias (-> local bldg_alias)               441-448
--   ah_status_line (-> local status_line)             450-467
--   ah_usage (-> local usage; the usage STRING is 470-473)  469-474
--   ah_config (-> M.config)                           476-544
--   AH_RESERVE_STEPS / AH_KEEP_STEPS / AH_TRAIT_CHOICES     565-567
--   ah_step (-> local step_fwd, forward-only; see below)    574-580
--   aherd_menu_build (-> M.menu_items)                588
--   aherd_menu_build's per-building rows              614-645
--   aherd_menu_build's "no buildings owned" fallback row
--     (-> M.menu_items' "_none" row)                  646-649
--   viking_show_aherd_menu (-> M.open_menu)           653-687
--   viking_aherd_menu_pick (-> local menu_pick)       689-736
--
-- M.config carries LEGACY's WHOLE directive set, including the master
-- `on`/`off` toggle and `debug on|off | log [clear] | status` (ah_config,
-- 476-544, see especially 480-481 for on/off). Dropping on/off would leave
-- the master toggle unreachable from `/vik herd on`, and dropping
-- debug/log/status would narrow "exactly LEGACY's directives" to an
-- unstated subset.
--
-- One LEGACY quirk ported as-is rather than fixed: LEGACY's own usage string
-- advertises `age <n|off>`, but ah_config's numeric-directive grammar
-- (`"^(%a+)%s+(%d+)$"`, digits only) never matches the literal word "off",
-- so `aherd age off` has always fallen through to ah_usage() in LEGACY --
-- the documented "|off" form doesn't actually work (age_refresh=0, via
-- `aherd age 0`, achieves the same "off" effect the comment describes).
-- Ported verbatim, matching this port's port-exactly-don't-fix rule (the
-- same rule autoraid.lua's header applies to its own redundant guards).
--
-- Adaptations (all mechanical, same idiom as autoraid.lua/autotrader/core.lua):
--   * LEGACY's implicit global `state` -> `S` (require("state").S).
--   * `page_opts.auto_herd` (LEGACY's bare table field) ->
--     page_opts.get("auto_herd") / page_opts.set("auto_herd", v). The key
--     and its `false` default already exist in page_opts.lua, so no
--     page_opts.lua change is needed here.
--   * ColourNote(name, "", text) -> a local note(hex, text) that calls
--     buffer.color_print(nil, hex, text), same helper shape as
--     autoraid.lua. LEGACY's four colour names here (orange/red/darkorange/
--     gray) map to their standard HTML/CSS hex equivalents, matching the
--     convention autoraid.lua's and autovoyage.lua's own headers already
--     use for the identical named colours: orange=FFA500, red=FF0000,
--     darkorange=FF8C00, gray=808080 (autovoyage.lua's header already uses
--     gray=808080 for this exact name).
--   * OnPluginSaveState() -> a local save() helper that calls
--     require("persist").save(), with the require DEFERRED into the
--     function body rather than a top-level `local persist = ...` -- same
--     idiom and same reasoning as autoraid.lua's own save() (see that
--     module's header): deferring costs nothing and keeps this module safe
--     if a later change requires it from inside the
--     persist -> window -> pages.city require chain.
--   * `aherd_menu_build`'s WindowCreate rows -> M.menu_items() returns
--     require("menu")-shaped items ({id=, label=, value=}); `id` mirrors
--     LEGACY's own row.id, and `value` is set equal to `id` so
--     require("menu")'s on_select dispatch (which reads item.value) works
--     unchanged. Per-item colours (col=... in LEGACY) have no equivalent in
--     menu.lua's plain-label rows and are dropped, same disposition
--     autoraid.lua's own menu port already discloses -- so where LEGACY
--     carried enabled/disabled in a row's COLOUR, the label says it in
--     words (see M.menu_items' per-building rows).
--   * `viking_aherd_menu_pick`'s left/right/middle-click distinctions (its
--     own `right_click`/`middle_click` flags, used to raise/lower reserve
--     and keep, cycle trait either direction, and cycle a building's
--     target/keep on right/middle click) have no equivalent in
--     require("menu")'s single-select model (Enter only). Every cycling
--     item here (goal/reserve/keep/trait) becomes a single FORWARD-only
--     cycle through the same ordered list LEGACY used, and a per-building
--     row's select toggles `enabled` only -- LEGACY's right-click
--     (per-building target) and middle-click (per-building keep override)
--     cycles are dropped. Same "content fidelity, not interaction
--     fidelity" ruling autoraid.lua's own menu port (and its Ships-cycle in
--     particular) already applies; still reachable in full via
--     `/vik herd bldg <name> target <n>` / `keep <n>` (M.config, ported
--     verbatim above).
--
-- CORRECTIONS TO LEGACY, each called out inline where it bites:
--   (a) `herd.generation` -> `herd.gen`  (crossbreed branch of M.plan);
--   (b) `page_opts.auto_herd` -> page_opts.get("auto_herd")  (M.tick's
--       master-toggle gate -- a literal port makes the whole module dead);
--   (c) the feed guard compares warehouse grain STOCK against the herds'
--       need, not S.lfeed.grain, which is itself a per-tick NEED figure
--       (see market.lua's feed_draw for the server citations);
--   (d) LEGACY's feed guard also queued grain into the auto-TRADER's buy
--       queue; that cross-module spend is not ported (see branch 1);
--   (e) LEGACY's two `vtoggle` hints are REWORDED, not ported verbatim:
--       "no livestock data - buy stock, or enable: vtoggle mip_livestock"
--       (LEGACY:356) and "waiting for city data (vtoggle mip_city)"
--       (LEGACY:399). The port-exactly-don't-fix rule this plugin applies
--       to LEGACY response strings does not extend to telling a user to
--       run a command that does not exist: Guild.Livestock and Guild.City
--       are GMCP packages here, always sent, with no toggle and no
--       `vtoggle` command in this client. pages/livestock.lua and
--       autotrader/plan.lua drop the same hint for the same reason;
--   (f) the affordability gate is `price * count`, not `price`: the
--       record's price is already a lot total and the server multiplies it
--       by the lot count again (see lot_cost below for the server lines).
--
-- The per-tick grain draw, the warehouse grain stock and the HERD_CAP tier
-- table each have exactly ONE implementation, in market.lua
-- (M.feed_draw / M.wh_amount_of / M.HERD_CAP), shared with
-- pages/livestock.lua -- so the planner and the page cannot disagree about
-- how much grain the herds need, how much is in the warehouse, or how big a
-- building is.
--
-- `/vik herd [<sub>]` is wired in init.lua by M.herd_command below --
-- without it the whole config/menu surface is unreachable.
local S = require("state").S
local page_opts = require("page_opts")
-- market.lua holds the three livestock figures this module shares with
-- pages/livestock.lua (wh_amount_of/wh_known, feed_draw, HERD_CAP), so the
-- feed guard here and the page's Feed section answer "how much grain is in
-- the warehouse" and "how much do the herds draw" from the same code. It
-- requires only state, so this is a leaf require -- no cycle, unlike the
-- deferred persist require below.
local market = require("market")
local replace = require("herd_replace")
local replacement_initialized = setmetatable({}, { __mode = "k" })
local replacement_save_failed = setmetatable({}, { __mode = "k" })

local M = {}

-- persist.lua's own require("window") chain can circle back through a page
-- that requires this module (see the OnPluginSaveState adaptation note
-- above) -- deferred the same way autoraid.lua's own save() is.
local function save()
  return require("persist").save()
end

-- LEGACY:38-40.
local AH_INTERVAL        = 20   -- seconds between planning cycles
local AH_CONFIRM_TIMEOUT = 15   -- seconds to wait for confirmation
local AH_COOLDOWN        = 30   -- seconds to pause after an unconfirmed action
M.AH_INTERVAL = AH_INTERVAL

local function note(hex, text)
  buffer.color_print(nil, hex, text)
end

-- A failed persistence attempt blocks even ordinary buys until explicit reset.
local function replacement_save(ah)
  local ok, result, err = pcall(save)
  if ok and result ~= false and err == nil then return true end
  replacement_save_failed[ah.replace] = true
  -- Retain an idle/configuration failure across reloads if the halt save succeeds.
  ah.replace.in_flight = ah.replace.in_flight or { phase = "halted" }
  replace.cancel(ah.replace, "persistence failed; inspect server state before reset")
  ah.status = "replacement persistence failed: " .. tostring(ok and (err or result) or result)
  note("FF0000", "[Auto-Herd] " .. ah.status .. "; NO SEND; explicit reset required")
  pcall(save) -- best effort to retain the halt, never permission to send
  return false
end

-- LEGACY:42.
local LIVE_BLDGS = { "sheepfold", "henhouse", "piggery", "byre", "stable" }

-- ---------------------------------------------------------------------------
-- Static game data mirrored from the server (defines.h / set.h). HERD_CAP and
-- LIVESTOCK_FEED_PER_HEAD are NOT here: they are shared with
-- pages/livestock.lua from market.lua. LIN_TOKENS below stays local -- it is
-- a command vocabulary, not display data, and does not overlap the LIN_NAMES
-- display tables (pages/goods.lua, pages/livestock.lua,
-- autotrader/plan.lua).
-- ---------------------------------------------------------------------------

-- LEGACY:43. LEGACY:44's SPECIES_BLDG is deliberately NOT carried over: it
-- is dead code in LEGACY too (`grep -n SPECIES_BLDG
-- guild_viking_husbandry.lua` finds only its own declaration, line 44, and
-- no reader), and nothing in the planner ever maps a species back to a
-- building.
local BLDG_SPECIES = { sheepfold = "sheep", henhouse = "chicken",
                       piggery = "pig", byre = "cow", stable = "horse" }

-- LEGACY:46 (HERD_CAP) and LEGACY:53 (LIVESTOCK_FEED_PER_HEAD) both live in
-- market.lua now, beside wh_amount_of -- one definition each, shared with
-- pages/livestock.lua. cap_for below is the clamped read this module needs.

-- LEGACY:58 (AH_LINEAGE_TOKEN). Single-word lineage tokens the server's
-- lineage_id_from_name() accepts, keyed by the numeric lineage id LMARKET
-- carries -- this avoids display-name mismatches ("Ui Imair" is not a token).
-- ONE deliberate difference from LEGACY: [3] is "ui_imair" here, the primary
-- spelling in the authoritative lmap
-- (3s/players/viking/cmd/vlivestock.c:46), where LEGACY wrote "imair". That
-- same lmap line registers "ui_imair", "uiimair" AND "imair" as three keys
-- all mapping to 3, so both spellings work; this is the authoritative one.
local LIN_TOKENS = {
  [1]  = "lodbrok",    [2]  = "eiriksson", [3]  = "ui_imair",   [4]  = "rurikid",
  [5]  = "harfagre",   [6]  = "yngling",   [7]  = "skallagrim", [8]  = "stenkil",
  [9]  = "sverker",    [10] = "eric",      [11] = "munso",      [12] = "skjoldung",
  [13] = "sigurdsson",
}

-- LEGACY:75. Score boost so a wanted-trait animal wins outright.
local AH_TRAIT_BONUS = 1000

-- LEGACY:83-98 (the DEFAULTS half of ah_settings). Preserved verbatim,
-- including the three spending actions defaulting ON -- see the module
-- header's spending warning. `keep`'s comment is corrected, not copied
-- stale (see the header).
local DEFAULTS = {
  goal        = "yield",  -- stat weighting: yield|fert|con|hard|vigor|balanced
  reserve     = 2000,     -- daler kept untouched by buys
  keep        = 4,        -- restock breeding floor (NOT a slaughter
                           -- setting -- see module header)
  gen_refresh = 0,        -- crossbreed when generation >= this (0 = auto via Con)
  age_refresh = 40,       -- crossbreed when herd age >= this (0 = off, matches server penalty)
  restock     = true,     -- buy foundation stock into empty/under-target buildings
  trait_pref  = "any",    -- prefer trait animals: "any" | "off" | a trait id
  crossbreed  = true,     -- allow fresh-breed injections (hybrid vigor)
  buy_quality = true,     -- allow stat-improving buy-ins
  feed_guard  = true,     -- warn / queue grain when herds would go unfed
  feed_ticks  = 4,        -- grain buffer target, in ticks
  quality_margin = 5,     -- min score improvement to justify a quality buy
  debug       = false,
}

-- LEGACY:66-73.
local GOAL_W = {
  yield    = { hard=1, fert=1, yield=4, vigor=1, con=2 },
  fert     = { hard=1, fert=4, yield=1, vigor=2, con=1 },
  con      = { hard=2, fert=1, yield=1, vigor=1, con=4 },
  hard     = { hard=4, fert=1, yield=1, vigor=1, con=2 },
  vigor    = { hard=1, fert=2, yield=1, vigor=4, con=1 },
  balanced = { hard=1, fert=1, yield=1, vigor=1, con=1 },
}
-- LEGACY:74.
local GOAL_ORDER = { "yield", "fert", "con", "hard", "vigor", "balanced" }

-- LEGACY:117-122 (bldg_tier / owns).
local function bldg_tier(b)
  return (S.buildings and (S.buildings[b] or 0)) or 0
end
local function owns(b)
  return bldg_tier(b) >= 1
end

-- LEGACY:81-112 (ah_settings). Creates S.autoherd from DEFAULTS on first
-- call (plus the UI/log bookkeeping fields LEGACY's own table literal also
-- carried: buildings, last, status, log), then backfills any per-building
-- entry missing from an older save -- same two-phase guard shape LEGACY's
-- own function used.
function M.settings()
  if not S.autoherd then
    local ah = {}
    for k, v in pairs(DEFAULTS) do ah[k] = v end
    ah.buildings = {}
    ah.last = 0
    ah.status = ""
    ah.log = {}
    S.autoherd = ah
  end
  local ah = S.autoherd
  if not replacement_initialized[ah.replace] then
    ah.replace = replace.settings(ah.replace)
    replacement_initialized[ah.replace] = true
    local restored = replace.busy(ah.replace)
    replace.recover(ah.replace)
    if restored then replacement_save(ah) end
  end
  if ah.buildings == nil then ah.buildings = {} end
  if ah.log == nil then ah.log = {} end
  -- Default per-building config: enabled, target head (0 = breed toward
  -- cap), keep (nil = use global keep). LEGACY:106-108.
  for _, b in ipairs(LIVE_BLDGS) do
    if ah.buildings[b] == nil then
      ah.buildings[b] = { enabled = true, target = 0, keep = nil }
    end
  end
  return ah
end

-- Read-only settings view: forecasts must not initialize/recover/save live jobs.
local function preview_settings()
  local ah = {}
  for k, v in pairs(DEFAULTS) do ah[k] = v end
  for k, v in pairs(S.autoherd or {}) do ah[k] = v end
  ah.replace = replace.settings(ah.replace)
  ah.buildings = ah.buildings or {}
  return ah
end

-- Raw records deliberately retain missing/invalid values for fail-closed validation.
function M.replacement_context()
  local ah = preview_settings()
  local prices = {}
  for _, good in ipairs({ "mutton", "beef", "poultry", "pork", "horsemeat", "wool", "milk", "eggs" }) do
    local sell, lin, demand = market.best_sell_of(good)
    local row = lin and S.trade_goods and S.trade_goods[lin] and S.trade_goods[lin][good]
    if row then prices[good] = { sell = sell, demand = demand, at = row._received_at } end
  end
  local buy, lin, supply = market.best_buy_of("grain")
  local row = lin and S.trade_goods and S.trade_goods[lin] and S.trade_goods[lin].grain
  if row then prices.grain = { buy = buy, supply = supply, at = row._received_at } end
  return { now = os.time(), connected = mud ~= nil and type(mud.connected) == "function" and mud.connected() == true,
    master_enabled = page_opts.get("auto_herd") == true,
    epoch = S.herd_connection_epoch or 0, observed = S.herd_observed or {},
    production = S.production,
    herds = S.herds, lmarket = S.lmarket, lpending = S.lpending,
    bqueue = S.bqueue, bqueue_used = S.bqueue_used, bqueue_max = S.bqueue_max,
    daler = S.daler, buildings = S.buildings, reserve = ah.reserve, global_keep = ah.keep,
    quality_margin = ah.quality_margin, weights = GOAL_W[ah.goal],
    building_settings = ah.buildings, prices = prices }
end

-- Transient attempt time, not a receipt or persisted setting. Failed sends also
-- consume the interval so a broken sender cannot cause a retry storm.
local refresh_attempt_at
local REFRESH_HINT = "Use /vik herd refresh; allow ~15 seconds for livestock/city and up to ~5 minutes for the trade grid."
function M.refresh(automatic)
  local function report(ok, text)
    if not automatic then note("FFA500", "[Auto-Herd] " .. text) end
    return ok, text
  end
  if not mud or type(mud.connected) ~= "function" or mud.connected() ~= true then
    return report(false, "refresh blocked: not connected")
  end
  -- Explicit /vik herd refresh must bootstrap missing data after reload.
  -- Only automatic requests require the connection-local Viking livestock latch.
  if automatic and not S.livestock_seen then
    return report(false, "refresh blocked: waiting for Viking livestock data on this connection")
  end
  if not gmcp or type(gmcp.enabled) ~= "function" then
    return report(false, "refresh blocked: GMCP unavailable")
  end
  local ok, enabled = pcall(gmcp.enabled)
  if not ok or enabled ~= true or type(gmcp.send) ~= "function" then
    return report(false, "refresh blocked: GMCP disabled or sender unavailable")
  end
  local now, interval = os.time(), automatic and 120 or 60
  if refresh_attempt_at and now - refresh_attempt_at < interval then
    return report(false, "refresh debounced; wait before requesting again")
  end
  refresh_attempt_at = now
  -- Add preserves other subscriptions. The server invalidates delta caches,
  -- but retains its panel schedule; success here is not data confirmation.
  local sent, result = pcall(gmcp.send, "Core.Supports.Add", { "Guild 1" })
  if not sent or result ~= true then
    return report(false, "refresh request failed; no fresh data confirmed")
  end
  return report(true, "Guild refresh requested (not confirmed). " .. REFRESH_HINT)
end


-- LEGACY:441-448 (ah_bldg_alias). Map rebuilt per call, matching LEGACY's
-- own shape exactly (a local table literal inside the function body).
local function bldg_alias(name)
  name = (name or ""):lower()
  local map = {
    sheep = "sheepfold", fold = "sheepfold", hen = "henhouse", coop = "henhouse",
    chicken = "henhouse", pig = "piggery", sty = "piggery", swine = "piggery",
    cow = "byre", cattle = "byre", horse = "stable", stable = "stable",
    sheepfold = "sheepfold", henhouse = "henhouse", piggery = "piggery", byre = "byre",
  }
  return map[name]
end

-- LEGACY:469-474 (ah_usage). Text unchanged, including the stale "aherd"
-- alias name (`/vik herd <sub>` maps onto M.config, the same fold
-- autoraid.lua's own header discloses for its "araid" usage-line naming).
local function usage()
  note("FF0000", "[Auto-Herd] usage: aherd on|off | goal <yield|fert|con|hard|vigor|balanced> | "
    .. "reserve <n> | keep <n> | gen <n|auto> | age <n|off> | trait <any|off|prolific|hardy|bountiful|purebred> | stock on|off | cross on|off | quality on|off | "
    .. "feed on|off | feedticks <n> | margin <n> | bldg <name> on|off|target <n>|keep <n> | "
    .. "debug on|off | log [clear] | status | refresh | forecast | replace on|off|status|reset|preview | model <building> output N|share 0..1")
end

-- LEGACY:450-467 (ah_status_line).
local function status_line(ah)
  note("FFA500", string.format(
    "[Auto-Herd] %s | goal %s | trait %s | reserve %d | keep %d | gen %s | age %s | stock %s | cross %s | quality %s | feed-guard %s (%d tk)",
    page_opts.get("auto_herd") and "ON" or "OFF", ah.goal, ah.trait_pref or "any", ah.reserve, ah.keep,
    (ah.gen_refresh and ah.gen_refresh > 0) and tostring(ah.gen_refresh) or "auto",
    (ah.age_refresh and ah.age_refresh > 0) and tostring(ah.age_refresh) or "off",
    ah.restock and "on" or "off", ah.crossbreed and "on" or "off", ah.buy_quality and "on" or "off",
    ah.feed_guard and "on" or "off", ah.feed_ticks))
  local parts = {}
  for _, b in ipairs(LIVE_BLDGS) do
    if owns(b) then
      local c = ah.buildings[b] or {}
      parts[#parts + 1] = string.format("%s[%s t%d]", b, c.enabled ~= false and "on" or "off", bldg_tier(b))
    end
  end
  if #parts > 0 then note("FF8C00", "  owned: " .. table.concat(parts, " ")) end
  if ah.status and ah.status ~= "" then note("808080", "  status: " .. tostring(ah.status)) end
end

-- ---------------------------------------------------------------------------
-- PLANNER + EXECUTOR. Everything from here to M.plan()/M.tick() decides what
-- to buy, and M.tick() is the ONLY function in this module that calls
-- mud.send. Read the module header's spending warning first.
--
-- Ported from guild_viking_husbandry.lua:
--   cap_for                123      -> cap_for (local)
--   pending_head           131      -> pending_head (local)
--   warehouse_amount       139      -> warehouse_amount (local)
--   score_stats            148      -> score_stats (local)
--   inbreed_threshold      154      -> inbreed_threshold (local)
--   log_action             157      -> log_action (local)
--   best_listing           169      -> best_listing (local)
--   buy_cmd                192      -> buy_cmd (local); its format string 195
--   ah_plan                202-359  -> M.plan  (closing `end` at 359)
--     feed guard             219
--     stock / restock        256
--     crossbreed refresh     289
--     quality buy-in         320
--   ah_sm                  366      -> ah_sm (local)
--   ah_state_sig           368      -> ah_state_sig (local)
--   auto_herd_tick         386-436  -> M.tick  (closing `end` at 436; the
--                                      master-toggle gate is 387)
-- ---------------------------------------------------------------------------

-- Every numeric read out of S goes through this rather than `x or 0`.
-- handlers/livestock.lua does coerce what it writes, but each of S.lfeed,
-- S.lmarket, S.lpending, S.lneeds and S.buildings is legitimately `{}` (or
-- absent) before its first Guild.Livestock/Guild.City frame, S.daler starts
-- at -1 ("not yet received"), and per-building overrides come from a
-- user-editable persisted table. `x or 0` would still let a STRING reach an
-- arithmetic operator; tonumber(x) or 0 cannot.
local function num(x)
  return tonumber(x) or 0
end

-- LEGACY:123 (cap_for). The clamped read: a buy must never be sized against
-- a nil cap, so an out-of-range tier is pulled back into 1..5 rather than
-- missing the table. pages/livestock.lua deliberately does NOT clamp -- see
-- market.M.HERD_CAP.
local function cap_for(bldg, tier)
  local herd = S.herds and S.herds[bldg]
  if herd and herd.management_present and not herd.management then return 0 end
  if herd and herd.management then return herd.management.cap end
  local t = market.HERD_CAP[bldg]
  if not t then return 0 end
  if tier < 1 then tier = 1 elseif tier > 5 then tier = 5 end
  return t[tier] or 0
end

-- LEGACY:131 (pending_head; its own two-line comment is 129-130). Animals
-- already paid for and in transit (LPENDING) count toward the herd, "so the
-- planner doesn't keep re-buying while deliveries are on the road" --
-- LEGACY's own words. This is the pending-delivery access check, and all
-- three buy branches below apply it.
local function pending_head(bid)
  local herd = S.herds and S.herds[bid]
  local n = 0
  for _, p in ipairs(S.lpending or {}) do
    if p.bldg == bid then n = n + num(p.count) end
  end
  return math.max(n, herd and herd.management and herd.management.pending or 0)
end

-- PEN-FULL LATCH (not in LEGACY). The planner's own space check is
-- `head + pending_head(b) < cap`, computed from S.herds/S.lpending -- both of
-- which arrive on Guild.Livestock's SLOW round-robin cadence. Between a
-- delivery landing (or a herd breeding, which the server does on its own
-- tick without any client action) and the next Livestock push, the client's
-- head is stale-low while the server's is at cap, so the check passes and a
-- buy goes out into a pen the server knows is full. The server answers with
-- "Your <bldg> is full (counting animals already in transit)." and refuses
-- (vlivestock.c:334, when set.h's add_pending_livestock returns 0 because
-- `cap - head - pending <= 0`).
--
-- Without this latch the only backstop is the confirm-window timeout in
-- M.tick, which costs a full AH_CONFIRM_SECS of silence and then prints the
-- generic "no confirmation for last action" -- and, because state genuinely
-- did not move, the very same buy is eligible again as soon as the cooldown
-- lapses. So the refusal repeats on a loop, spamming the pen-full banner.
--
-- Latching the building on the server's own message is authoritative in a
-- way the client's arithmetic can't be: the server just told us there is no
-- space. It is cleared as soon as fresh data shows real room (see
-- pen_full below), so an upgrade, a slaughter or a delivery arriving all
-- release it on the next Livestock push -- it is a suppression of REPEATED
-- futile buys, never a permanent block.
local ah_full = {}

-- Marks a building refused-for-space. Called from M.on_pen_full (the
-- trigger) -- keyed by building, so a full sheepfold never blocks the byre.
function M.mark_pen_full(bldg)
  if not bldg or bldg == "" then return end
  ah_full[bldg] = true
end

-- True while `bldg` is latched full. Self-clearing: once head + pending is
-- genuinely below cap in the data we now hold, the latch is dropped and the
-- normal planner checks take over again. That read is the same one the
-- planner itself uses, so the latch can only outlive the condition by one
-- Livestock push.
local function pen_full(bldg)
  if not ah_full[bldg] then return false end
  local herd = S.herds and S.herds[bldg]
  local head = (herd and num(herd.head)) or 0
  if head + pending_head(bldg) < cap_for(bldg, bldg_tier(bldg)) then
    ah_full[bldg] = nil
    return false
  end
  return true
end

-- Test seam: lets the suite assert the latch clears rather than reaching
-- into the upvalue. Not used by the module itself.
function M.pen_full(bldg) return pen_full(bldg) end

-- LEGACY:139 (warehouse_amount). CORRECTION TO LEGACY (c), stated where it
-- bites: the feed guard compares the herds' per-tick draw against the
-- WAREHOUSE grain stock, NOT against S.lfeed.grain. S.lfeed.grain is not a
-- stock -- the server's _v_lfeed() (client.h:4202) fills it from
-- query_livestock_feed_needs() (query.h:2464), which sums grain NEEDED PER
-- TICK, and vlivestock.c:609 renders that very number as "Feed per tick: N
-- grain + N water (N head)". Comparing that need against need * feed_ticks is
-- true whenever any head exists, which would make the feed guard fire
-- unconditionally forever. LEGACY compared warehouse_amount("grain")
-- (LEGACY:233) against the need, which is the only comparison that means
-- anything.
--
-- The body lives in market.lua's M.wh_amount_of (LEGACY:3315-3318 extended
-- with LEGACY:139's array fallback), which pages/livestock.lua's Feed section
-- calls too. Kept as a one-line local so the call sites below still read like
-- LEGACY's.
local function warehouse_amount(good)
  return market.wh_amount_of(good)
end

local function enabled_owned(ah)
  local owned = {}
  for _, b in ipairs(LIVE_BLDGS) do
    local bc = ah.buildings and ah.buildings[b]
    if bc == nil then bc = {} end -- Read-only equivalent of per-pen defaults.
    if owns(b) and bc and bc.enabled ~= false then owned[#owned + 1] = b end
  end
  return owned
end

-- Pure shared feed assessment: advisory for ordinary purchases, a hard gate
-- for NEW replacement jobs only. Never interrupt a job restoring culled heads.
local function feed_warning(ah, owned)
  if not ah.feed_guard then return nil end
  owned = owned or enabled_owned(ah)
  if #owned == 0 then return nil end
  local head = 0
  local f = S.lfeed
  if f and num(f.head) > 0 then
    head = num(f.head)
  else
    for _, b in ipairs(owned) do
      local h = S.herds and S.herds[b]
      if h then head = head + num(h.head) end
    end
  end
  if head > 0 then
    -- Observed grain is the whole city's per-tick NEED, not stock. feed_draw
    -- prefers it to the ceil(head / 8) fallback; warehouse_amount reads STOCK.
    local per_tick = market.feed_draw(head)
    local need = per_tick * math.max(1, num(ah.feed_ticks))
    local grain = warehouse_amount("grain")
    if grain < need then
      return string.format(
        "feed low: %d grain, herds need %d/tick (%d buffer) - stock grain!",
        grain, per_tick, need)
    end
  end
end

function M.replacement_preview()
  local ctx, ah = M.replacement_context(), preview_settings()
  local p, reason, details = replace.preview(ctx, ah.replace)
  -- Execution context is separate from candidate eligibility and its reasons.
  return p, reason, details, feed_warning(ah)
end

-- LEGACY:148 (score_stats). Works on a herd record and a market record
-- alike: handlers/livestock.lua gives both the same five stat field names
-- (hard/fert/yield/vigor/con).
local function score_stats(s, w)
  if s.management then
    local stats = s.management.stats
    return (stats.hard * w.hard + stats.fert * w.fert + stats.yield * w.yield
      + stats.vigor * w.vigor + stats.con * w.con) / 100
  end
  return num(s.hard) * w.hard + num(s.fert) * w.fert + num(s.yield) * w.yield
       + num(s.vigor) * w.vigor + num(s.con) * w.con
end

-- LEGACY:154 (inbreed_threshold). This is what `gen_refresh = 0` ("auto via
-- Con") resolves to -- a real server-derived function, NOT a formula
-- invented here: the server's inbreeding drift sets in once a herd's
-- generation exceeds con/20 + 5, which is the point a fresh outside breed
-- becomes worth injecting. LEGACY's own crossbreed line is
--   local thresh = (ah.gen_refresh and ah.gen_refresh > 0)
--                  and ah.gen_refresh or inbreed_threshold(herd)
-- and it is reproduced verbatim (modulo num()) in M.plan below.
local function inbreed_threshold(herd)
  return math.floor(num(herd.con) / 20) + 5
end

-- LEGACY:157 (log_action). Feeds M.config's `log` directive.
local function log_action(ah, desc)
  ah.log[#ah.log + 1] = { t = os.date("%H:%M"), desc = desc }
  while #ah.log > 40 do table.remove(ah.log, 1) end
end

-- STRUCTURAL ADAPTATION, the only one in the planner: LEGACY read ONE flat
-- array, state.livestock_market. Here S.lmarket is keyed by numeric lineage
-- id, each value a per-lineage array, because the server sends one
-- lmarket_1..lmarket_13 key per lineage and omits a lineage with no pool
-- (handlers/livestock.lua's write_lmarket merges rather than replaces for
-- exactly that reason). So every listing sweep goes through this two-level
-- iterator instead of ipairs()ing a flat list -- and, importantly, `#S.lmarket`
-- would be 0 for a table keyed { [1] = ..., [7] = ... }, which is why the
-- any-data tail of M.plan counts through here too rather than taking a length.
--
-- The lineage keys are visited in sorted order rather than raw pairs() order
-- on purpose: pairs() order is unspecified, so two listings with an equal
-- goal score in different lineages would otherwise be tie-broken
-- unpredictably -- and the tie-break decides which animal gets BOUGHT.
-- LEGACY's single flat array had a stable order for free; this restores it.
local function each_listing(fn)
  local lm = S.lmarket
  if type(lm) ~= "table" then return end
  local keys = {}
  for k in pairs(lm) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    local na, nb = tonumber(a), tonumber(b)
    if na and nb then return na < nb end
    return tostring(a) < tostring(b)
  end)
  for _, k in ipairs(keys) do
    local pool = lm[k]
    if type(pool) == "table" then
      for _, m in ipairs(pool) do fn(m) end
    end
  end
end

-- What the server will charge for a listing. The record's `price` field IS
-- that figure already: world/livestock_daemon.c:310 stores
-- `"price": price * count`, a LOT TOTAL with the count >= 3 bulk discount
-- already folded into the per-head price it multiplied.
--
-- Legacy buys pass no count and charge the whole lot, m.price. Protected
-- offers instead use their exact unit price and the selected partial count.
--
-- HISTORY, because this line has now been wrong in both directions. This port
-- first gated on `price` and then on `price * count`, the latter because the
-- server's own gate read `total_cost = price * buy_count`, multiplying an
-- already-multiplied total by the lot size and refusing purchases the player
-- could afford. That was a server-side bug, since fixed (do_buy now derives a
-- per-head unit from the lot before costing anything), so the gate is `price`
-- again -- this time because the server agrees, not by accident.
--
-- Either way round the planner is safe if the two sides are briefly out of
-- step: gating too low means one refused buy, which drops the listing and
-- moves on rather than wedging; gating too high just skips an affordable lot.
local function lot_cost(m)
  if m.buy_count then return m.buy_count * m.unit_price end
  return num(m.price)
end

-- New management confirms hundredth-point averaging; legacy remains whole-point.
-- Quotes have no herd head/cap/pending identity and cannot authorize a buy.
-- Forecast from the current herd and exact chosen count, excluding random bonuses.
local function arrival_score(herd, m, cap, w)
  local head = num(herd.head)
  local count = m.buy_count or math.min(num(m.count), cap - head)
  if count <= 0 then return score_stats(herd, w) end
  local score = 0
  local scale = herd.management and 100 or 1
  for stat, weight in pairs(w) do
    local before = herd.management and herd.management.stats[stat] or num(herd[stat])
    score = score + math.floor((before * head + num(m[stat]) * scale * count)
      / (head + count)) * weight
  end
  return score / scale
end

local function has_trait(herd)
  return herd and herd.trait and herd.trait ~= "" and tostring(herd.trait) ~= "0"
end

-- Only the complete server history proves first introduction. Neither the
-- primary breed nor hv (even zero) tells us which older bloodlines persist.
local function fresh_breed(herd, breed)
  if type(herd.breeds) ~= "table" or type(breed) ~= "string" or breed == "" then
    return false
  end
  if breed == herd.breed then return false end
  for _, known in ipairs(herd.breeds) do
    if known == breed then return false end
  end
  return true
end

-- Eligibility uses raw stats; trait preference only ranks eligible lots and
-- only when the herd can inherit a trait (the server never replaces one).
local function best_listing(ah, species, budget, herd, eligible)
  local w = GOAL_W[ah.goal] or GOAL_W.balanced
  local best, best_score
  each_listing(function(m)
    if m.metadata_present or (herd and herd.management) then
      local mg = herd and herd.management
      -- Management confirms the upgraded schema even when the frame budget
      -- omits every optional offer field. Never downgrade to an unprotected buy.
      if not mg or m.offer_valid == false or not m.token or not m.unit_price or m.unit_price <= 0
          or not m.available then return end
      local count = math.min(num(m.count), m.available, mg.free,
        math.floor(budget / m.unit_price))
      if count <= 0 then return end
      local sized = {}
      for k, v in pairs(m) do sized[k] = v end
      sized.buy_count = count
      m = sized
    end
    if m.species == species and num(m.count) > 0 and lot_cost(m) <= budget then
      if not eligible or eligible(m) then
        local sc = score_stats(m, w)
        -- Trait preference: strongly reward a rare-trait animal so the
        -- planner grabs the bloodline while one is on the market.
        local pref = ah.trait_pref or "any"
        if not has_trait(herd) and pref ~= "off" and has_trait(m) then
          if pref == "any" or pref == m.trait then sc = sc + AH_TRAIT_BONUS end
        end
        if not best or sc > best_score then
          best, best_score = m, sc
        end
      end
    end
  end)
  return best, best_score
end

-- LEGACY:192 (buy_cmd), extended with explicit count + offer fingerprint.
-- This is the only command builder; legacy offers retain whole-lot semantics.
-- The wire id is 1-BASED while the record's `idx` is the server's 0-based
-- pool index, hence the +1. An unknown lineage id returns nil and every
-- caller treats nil as "no action" -- a half-built command is never sent.
--
-- `vlivestock slaughter` is NEVER built here or anywhere else in this file.
-- The server has it (vlivestock.c's do_slaughter), LEGACY never called it,
-- and it destroys livestock irreversibly, so it is outside the authority the
-- master toggle grants.
local function buy_cmd(m)
  local tok = LIN_TOKENS[num(m.lin)]
  if not tok then return nil end
  if m.buy_count and m.token then
    return string.format("vlivestock buy %s %d %d %s", tok, num(m.idx) + 1, m.buy_count, m.token)
  end
  return string.format("vlivestock buy %s %d", tok, num(m.idx) + 1)
end

-- LEGACY:202-359 (ah_plan). Returns ONE action or nil, plus a reason string:
--   action = { kind = "buy"|"warn", cmd = string|nil, why = string }
-- Exported (rather than local, as in LEGACY) specifically so the tests can
-- drive the planner without a timer and without a mud connection.
--
-- ACCESS CHECKS, all of which sit BEFORE any command is built:
--   1. owned + enabled  -- the `owned` list below; nothing past it can even
--      name a building the player does not own, or one the user disabled.
--   2. budget           -- `budget = S.daler - reserve`, and each of the
--      three buy branches is gated on `budget > 0`; best_listing() returns
--      only affordable legacy lots or exact reserve-limited protected counts.
--   3. herd space       -- `head + pending_head(b) < cap_for(b, tier)`.
--   4. pending delivery -- pending_head(b) is added to head in all three
--      branches, so a delivery already on the road blocks a re-buy.
-- buy_cmd() is called only after all four have passed, inside the branch.
--
-- The feed guard (branch 1) builds no command at all: LEGACY:251 is explicit
-- that it is "Not a vlivestock action; fall through to other planning this
-- tick", so it records `ah.status` and falls through, and the "warn" action
-- materialises in the tail below only when no branch produced a buy. That
-- ordering is LEGACY's, and it is why turning Auto-Herd on still stocks an
-- empty building for a player with no grain in the warehouse instead of
-- warning forever and never acting.
function M.plan()
  local ah = M.settings()
  ah.status = ""   -- recomputed fresh each cycle; the feed guard may set it
  local w = GOAL_W[ah.goal] or GOAL_W.balanced
  local budget = num(S.daler) - num(ah.reserve)

  -- Access check 1: owned livestock buildings that are also enabled.
  local owned = enabled_owned(ah)
  if #owned == 0 then
    return nil, "no husbandry buildings owned (or all disabled)"
  end

  -- --- 1. Feed guard: never let herds starve. LEGACY:219. ----------------
  -- Emits NOTHING (LEGACY:251). LEGACY additionally pushed the shortfall
  -- onto the auto-TRADER's buy queue when that module was loaded
  -- (LEGACY:238-248); that is deliberately NOT ported. It is a write into
  -- another automation's settings that would make a DIFFERENT module spend
  -- daler on grain, which is outside the authority Auto-Herd's own master
  -- toggle grants, and no test in this plan would have caught it. The
  -- status text therefore always takes LEGACY's own un-queued branch
  -- (" - stock grain!").
  ah.status = feed_warning(ah, owned) or ""

  -- --- 2. Stock / restock: seed EMPTY buildings, refill below target. ----
  -- LEGACY:256. This is what makes "turn it on" actually acquire animals:
  -- branches 3 and 4 only ever touch a herd that already exists.
  if ah.restock and budget > 0 then
    for _, b in ipairs(owned) do
      local tier = bldg_tier(b)
      local cap  = cap_for(b, tier)
      local herd = S.herds and S.herds[b]
      -- Access checks 3 + 4: herd space, counting deliveries in transit.
      local head = (herd and num(herd.head) or 0) + pending_head(b)
      local bc   = (ah.buildings and ah.buildings[b]) or {}
      -- Desired floor: an explicit per-building target, else a small
      -- breeding base (`keep`, capped by the building). Server-side breeding
      -- grows the herd the rest of the way.
      local target  = (num(bc.target) > 0) and num(bc.target) or nil
      local desired = target or math.min(cap, math.max(1, num(ah.keep)))
      if head < desired and head < cap and pending_head(b) == 0 and not pen_full(b) then
        local species = BLDG_SPECIES[b]
        local m = best_listing(ah, species, budget, herd, nil)
        if m then
          local cmd = buy_cmd(m)
          if cmd then
            return { kind = "buy", cmd = cmd,
              lin = num(m.lin), idx = num(m.idx),
              why = string.format("stock %s: buy %s x%d into %s (%d/%d) for %dd",
                species, (m.breed ~= "" and m.breed) or "?", m.buy_count or num(m.count), b,
                head, desired, lot_cost(m)) }, nil
          end
        else
          ah.status = string.format(
            "want to stock %s but no affordable %s for sale - run 'vlivestock market'",
            b, species)
        end
      end
    end
  end

  -- --- 3. Crossbreed refresh: fresh blood for inbred/sterile/old herds. --
  -- LEGACY:289.
  if ah.crossbreed and budget > 0 then
    for _, b in ipairs(owned) do
      local herd = S.herds and S.herds[b]
      local cap  = cap_for(b, bldg_tier(b))
      -- Access checks 3 + 4.
      if herd and num(herd.head) > 0 and (num(herd.head) + pending_head(b)) < cap
         and pending_head(b) == 0 and not pen_full(b) then
        local thresh = (num(ah.gen_refresh) > 0) and num(ah.gen_refresh)
                        or inbreed_threshold(herd)
        local age_thresh = (num(ah.age_refresh) > 0) and num(ah.age_refresh) or nil
        -- FIELD-NAME CORRECTION to LEGACY, and the one that matters:
        -- LEGACY:298 reads `herd.generation`, the name ITS OWN MIP parser
        -- used. handlers/livestock.lua's write_herds stores the field as
        -- `gen`, which is the key the server's _v_herds() builder emits
        -- (client.h). Porting LEGACY's line literally would read nil here,
        -- fall back to 0, and `0 >= thresh` is false for every positive
        -- threshold -- so crossbreed would silently never fire on
        -- generation, only on sterility and age, and half this branch would
        -- be dead while the module still looked alive. Verified against
        -- handlers/livestock.lua's write_herds field list: age_ticks, breed,
        -- con, head and sterile match LEGACY exactly; `generation` -> `gen`
        -- is the only rename.
        local needs_blood = num(herd.gen) >= thresh
          or num(herd.sterile) > 0
          or (age_thresh and num(herd.age_ticks) >= age_thresh)
        if needs_blood then
          local species = BLDG_SPECIES[b]
          -- First introduction can earn hybrid rewards without a raw gain,
          -- but never bank on random vigor to offset a predicted stat loss.
          local current = score_stats(herd, w)
          local m = best_listing(ah, species, budget, herd, function(listing)
            if herd.management then
              local count = listing.buy_count or math.min(num(listing.count), cap - num(herd.head))
              local gen = herd.management.gen_x100
              if math.floor(gen * num(herd.head) / (num(herd.head) + count)) >= gen then return false end
              for stat in pairs(w) do
                if num(listing[stat]) < num(herd[stat]) then return false end
              end
              return true
            end
            return fresh_breed(herd, listing.breed)
              and arrival_score(herd, listing, cap, w) >= current
          end)
          if m then
            local cmd = buy_cmd(m)
            if cmd then
              local age_note = (age_thresh and num(herd.age_ticks) >= age_thresh)
                and string.format(", age %.2f", num(herd.age_ticks)) or ""
              return { kind = "buy", cmd = cmd,
                lin = num(m.lin), idx = num(m.idx),
                why = string.format("crossbreed %s: +%s into %s (gen %.2f, %d sterile%s) for %dd",
                  species, (m.breed ~= "" and m.breed) or "?", b, num(herd.gen),
                  num(herd.sterile), age_note, lot_cost(m)) }, nil
            end
          end
        end
      end
    end
  end

  -- --- 4. Quality buy-in: pull a herd's weighted average up. LEGACY:320. -
  if ah.buy_quality and budget > 0 then
    for _, b in ipairs(owned) do
      local herd = S.herds and S.herds[b]
      local cap  = cap_for(b, bldg_tier(b))
      -- Access checks 3 + 4. (LEGACY does not require head > 0 in this
      -- branch, unlike branch 3 -- ported as written.)
      if herd and (num(herd.head) + pending_head(b)) < cap
         and pending_head(b) == 0 and not pen_full(b) then
        local species = BLDG_SPECIES[b]
        local current = score_stats(herd, w)
        local floor = current + num(ah.quality_margin)
        local m = best_listing(ah, species, budget, herd, function(listing)
          return score_stats(listing, w) >= floor
            and arrival_score(herd, listing, cap, w) > current
        end)
        if m then
          local cmd = buy_cmd(m)
          if cmd then
            return { kind = "buy", cmd = cmd,
              lin = num(m.lin), idx = num(m.idx),
              why = string.format("quality buy %s %s into %s for %dd",
                species, (m.breed ~= "" and m.breed) or "?", b, lot_cost(m)) }, nil
          end
        end
      end
    end
  end

  -- LEGACY:355 (`if ah.status ~= "" then return nil, ah.status end`). The
  -- deliberate shape change: a recorded shortfall/blocked-stock status
  -- surfaces as an explicit
  -- { kind = "warn", cmd = nil } action so callers can distinguish "nothing
  -- to do" from "you should know about this", instead of LEGACY's bare
  -- `nil, status`. It still carries NO command.
  if ah.status ~= "" then
    return { kind = "warn", cmd = nil, why = ah.status }, ah.status
  end

  -- If we own a livestock building but have neither herd nor market data,
  -- there is simply nothing to plan against yet. LEGACY's own trailing hint
  -- read "enable: vtoggle mip_livestock"; REWORDED here, not ported
  -- byte-for-byte -- see the header's Adaptations note. Guild.Livestock is a
  -- GMCP package, so there is no toggle for a user to enable and no
  -- `vtoggle` command in this client at all; telling them to run one would
  -- send them chasing a command that does not exist. pages/livestock.lua
  -- drops the same half of the same hint for the same reason.
  local any_data = false
  each_listing(function() any_data = true end)
  if not any_data then
    for _, b in ipairs(owned) do
      local h = S.herds and S.herds[b]
      if h and num(h.head) > 0 then any_data = true break end
    end
  end
  if not any_data then
    return nil, "no livestock data yet - buy stock via 'vlivestock market'"
  end
  local full, pending = 0, 0
  for _, b in ipairs(owned) do
    local herd = S.herds and S.herds[b]
    local incoming = pending_head(b)
    if incoming > 0 then pending = pending + 1 end
    if (herd and num(herd.head) or 0) + incoming >= cap_for(b, bldg_tier(b))
       or pen_full(b) then full = full + 1 end
  end
  if full == #owned then
    return nil, "husbandry pens full (including deliveries) - no room to improve; no automatic slaughter"
  end
  if pending > 0 then
    return nil, "waiting for livestock deliveries; no affordable beneficial options in other pens"
  end
  if budget <= 0 then return nil, "no livestock budget above reserve" end
  return nil, "no affordable beneficial livestock options - quality needs a rounded stat gain; crossbreed needs verified new blood without rounded stat loss"
end

-- LEGACY:366 (ah_sm). Paced executor state: each vlivestock action is a
-- single atomic command, so M.tick sends one and then waits for the feed to
-- confirm that herds/market/daler actually changed before planning again --
-- which is what stops it double-buying a stale listing.
-- `cmd`/`lin`/`idx` record the action currently in flight, and `refused` the
-- last command whose confirmation never arrived -- see the confirm-timeout
-- branch in M.tick.
local ah_sm = { phase = "idle", next_at = 0, deadline = 0, sig = "",
                cmd = nil, lin = nil, idx = nil, refused = nil,
                last_warn = nil }

-- Forget a listing the server never confirmed. A refused buy changes NO state
-- (the server tells the player and returns), so the state signature is
-- unchanged, the confirm deadline expires, the cooldown lapses, the planner
-- replans over the same S.lmarket and picks the SAME listing -- forever. The
-- two common refusals are "That listing has already been purchased" (the pool
-- entry is gone server-side but this client's per-lineage pool still holds it,
-- because a lineage whose key vanishes cannot be evicted from a delta frame)
-- and a lot the player cannot afford. Dropping the attempted listing here
-- breaks the loop for both, and does not lose anything real: if the listing
-- does still exist, the next Guild.Livestock push carries it again.
local function drop_listing(lin, idx)
  if lin == nil then return end
  local pool = S.lmarket and S.lmarket[lin]
  if type(pool) ~= "table" then return end
  for i = #pool, 1, -1 do
    if num(pool[i].idx) == num(idx) then table.remove(pool, i) end
  end
end

-- LEGACY:368 (ah_state_sig). Three field adaptations: `h.generation` ->
-- `h.gen` (see the crossbreed note above), `state.butchery_queue` ->
-- `S.bqueue` (handlers/livestock.lua's write_bqueue), and LEGACY's
-- `#state.livestock_market` -> a count through each_listing, since S.lmarket
-- is a lineage-keyed table whose `#` is 0.
local function ah_state_sig()
  local parts = {}
  parts[#parts + 1] = "d" .. tostring(num(S.daler))
  for _, b in ipairs(LIVE_BLDGS) do
    local h = S.herds and S.herds[b]
    if h then
      parts[#parts + 1] = b .. ":" .. num(h.head) .. "/" .. num(h.gen)
                            .. "/" .. num(h.sterile)
    end
  end
  local q = 0
  for _ in pairs(S.bqueue or {}) do q = q + 1 end
  parts[#parts + 1] = "q" .. q
  local mcount = 0
  each_listing(function() mcount = mcount + 1 end)
  parts[#parts + 1] = "m" .. mcount
  return table.concat(parts, ",")
end

-- LEGACY:386-436 (auto_herd_tick; closing `end` at 436). Called from
-- notify.lua's countdown_tick tail, LAST of the auto-modules -- LEGACY's own
-- order at guild_viking.lua:3232-3240 is trade, raid, voyage, vfind, herd
-- (this plugin has no auto-vfind, so herd simply follows voyage).
--
-- THE MASTER-TOGGLE GATE. LEGACY:387 is a bare `page_opts.auto_herd` read.
-- In this codebase page_opts keeps its values in a private closure, so
-- `page_opts.auto_herd` is permanently nil (falsy) while
-- page_opts.get("auto_herd") returns the real boolean -- copying LEGACY's
-- line literally would make M.tick() return early forever and Auto-Herd
-- would never run even when the user enabled it. The gate below is
-- page_opts.get("auto_herd"), the same translation M.config and menu_pick
-- apply, and the tick-gate cases at the bottom of
-- tests/guild_viking_autoherd_test.lua assert BOTH states (off: many ticks
-- send nothing; on: the same state sends exactly one buy) precisely because
-- a dead gate would otherwise ship green.
function M.tick()
  local ah = M.settings()
  local ctx = M.replacement_context()
  if replace.busy(ah.replace) and (not ctx.master_enabled or not ctx.connected) then
    replace.cancel(ah.replace, not ctx.connected and "disconnected; explicit reset required" or "master off; explicit reset required")
    replacement_save(ah)
  end
  if replacement_save_failed[ah.replace] then return end
  if not page_opts.get("auto_herd") then
    ah_sm.phase = "idle"
    return
  end
  if not ctx.connected then
    local ah = M.settings(); ah.status = "not connected"
    return
  end
  local now = ctx.now

  -- Existing jobs must observe stale data/epoch changes before ordinary gates.
  if replace.busy(ah.replace) then
    local action, status = replace.step(ctx, ah.replace)
    ah.status = "replacement: " .. tostring(status.reason or status.phase)
    if not replacement_save(ah) then return end
    if action then
      local ok, result = pcall(mud.send, action.cmd)
      if not ok or result == false then
        replace.cancel(ah.replace, "send failed; inspect server state before reset")
        replacement_save(ah)
        note("FF0000", "[Auto-Herd] replacement send failed; explicit reset required")
      end
    end
    return
  end

  -- Reconnect settling hold, the same gate autotrader/plan.lua:287 applies to
  -- cart dispatch. init.lua's M.on_connect sets S.at_hold_until on every
  -- connect, and state.reset_connection() deliberately PRESERVES guild data,
  -- so S.herds, S.lmarket, S.buildings and S.daler all survive a disconnect
  -- and the data gate below is satisfied instantly by stale city data. Without
  -- this the first tick after reconnect plans against last session's market
  -- pool and buys at an index the server has since rebuilt -- a different
  -- species, stats and price than the listing it scored -- and on confirm can
  -- chain further buys every 2s while Guild.Livestock's slow cadence has
  -- refreshed nothing.
  if S.at_hold_until and now < S.at_hold_until then
    local ah = M.settings()
    ah.status = string.format("settling after reconnect (%ds)",
      S.at_hold_until - now)
    return
  end

  -- Data gate: do nothing until the city feed has arrived, since every
  -- access check below depends on S.buildings.
  if not S.buildings or not next(S.buildings) then
    -- LEGACY:399 said "(vtoggle mip_city)"; reworded for the same reason as
    -- the livestock hint above -- Guild.City is GMCP-only here.
    local ah = M.settings(); ah.status = "waiting for city data"
    return
  end

  -- CORRECTION TO LEGACY, required by the spec's Corrections-to-LEGACY table
  -- ("Gate on `Guild.Livestock` having arrived", replacing LEGACY's
  -- mip_livestock gate). The city gate above is not a substitute: Guild.City
  -- and Guild.Livestock are separate slow-cadence panels in a round-robin, so
  -- City routinely lands first and S.buildings is populated while S.herds is
  -- still last session's -- or empty. A planner running in that window
  -- believes every owned building is empty and stocks all five. Latched by
  -- handlers/livestock.lua's write_herds and cleared by
  -- state.reset_connection(), so it is strictly per-connection.
  if not S.livestock_seen then
    local ah = M.settings(); ah.status = "waiting for livestock data"
    return
  end

  if ah_sm.phase == "confirming" then
    if ah_state_sig() ~= ah_sm.sig then
      ah_sm.phase, ah_sm.next_at = "idle", now + 2
    elseif now >= ah_sm.deadline then
      -- Nothing moved inside the confirm window, so the server refused the
      -- command (or it never landed). Forget the listing and remember the
      -- command, so the next cycle cannot simply re-emit it -- see
      -- drop_listing above and the refusal check in the buy branch below.
      drop_listing(ah_sm.lin, ah_sm.idx)
      ah_sm.refused = ah_sm.cmd
      ah_sm.phase, ah_sm.next_at = "cooldown", now + AH_COOLDOWN
      note("FF0000", "[Auto-Herd] no confirmation for last action; pausing briefly")
    end
    return
  end
  if ah_sm.phase == "cooldown" then
    if now < ah_sm.next_at then return end
    ah_sm.phase = "idle"
  end
  if now < ah_sm.next_at then return end

  local ah = M.settings()
  ah.last = now
  -- Busy jobs were handled above. Check feed before step can reserve budget
  -- or create a cull marker; on shortage retain ordinary planning/warn throttle.
  if ah.replace.enabled and not feed_warning(ah) then
    local action, status = replace.step(ctx, ah.replace)
    if action or replace.busy(ah.replace) then
      ah.status = "replacement: " .. tostring(status.reason or status.phase)
      if not replacement_save(ah) then return end
      if action then
        local ok, result = pcall(mud.send, action.cmd)
        if not ok or result == false then
          replace.cancel(ah.replace, "send failed; inspect server state before reset")
          replacement_save(ah)
          note("FF0000", "[Auto-Herd] replacement send failed; explicit reset required")
        end
      end
      return
    end
  end
  -- Only resync when both planners have no command to issue and no local or
  -- server job is outstanding. Preview itself remains strictly read-only.
  local action, status = M.plan()
  if not action and ah.replace.enabled and replace.status(ah.replace).phase == "idle"
      and ah_sm.phase == "idle" and not next(ctx.lpending or {})
      and not next(ctx.bqueue or {}) and ctx.bqueue_used == 0 then
    local preview, reason = M.replacement_preview()
    if not preview and tostring(reason):find("stale", 1, true) then M.refresh(true) end
  end
  -- `action.kind == "buy" and action.cmd` is belt-and-braces: M.plan only
  -- ever returns kind "buy" with a non-nil cmd (buy_cmd's nil result is
  -- filtered inside every branch). Checked anyway -- this is the one line in
  -- the module that spends money.
  if action and action.kind == "buy" and action.cmd then
    -- The command whose confirmation last timed out is not re-emitted on the
    -- very next cycle. Deliberately ONE-SHOT rather than a permanent
    -- blacklist: the refusal may have been transient (a lot that became
    -- affordable, a listing that really is back on the market), and a
    -- permanent blacklist would silently stop the planner buying an animal it
    -- should. Combined with drop_listing above this bounds the retry loop
    -- without ever refusing a legitimate repeat for more than one cycle.
    if ah_sm.refused and ah_sm.refused == action.cmd then
      ah_sm.refused = nil
      ah.status = "held back an unconfirmed repeat of: " .. action.cmd
      if ah.debug then note("808080", "[Auto-Herd] " .. ah.status) end
      ah_sm.next_at = now + AH_INTERVAL
      return
    end
    ah.status = nil                 -- LEGACY:422, overwritten two lines down
    ah_sm.sig = ah_state_sig()
    ah_sm.cmd, ah_sm.lin, ah_sm.idx = action.cmd, action.lin, action.idx
    mud.send(action.cmd)
    log_action(ah, action.why)
    ah.status = "last: " .. action.why
    note("FFA500", "[Auto-Herd] " .. action.why)
    if ah.debug then note("808080", "[Auto-Herd] cmd: " .. action.cmd) end
    ah_sm.last_warn = nil
    ah_sm.phase, ah_sm.deadline = "confirming", now + AH_CONFIRM_TIMEOUT
    save()   -- persist the log/status only when we actually acted
  else
    -- A "warn" action sends NOTHING; it only notes. Everything else is an
    -- ordinary idle tick.
    -- A warn is deduped on unchanged text. The status it carries -- a grain
    -- shortfall, say -- persists until the player acts on it, and printing a
    -- red line about it every AH_INTERVAL forever trains them to ignore the
    -- colour. LEGACY printed nothing at all here unless `debug`; this prints
    -- the first occurrence and then each CHANGE, which is the useful middle.
    local warn_text = nil
    if action and action.kind == "warn" then
      warn_text = tostring(action.why or "")
      if warn_text ~= ah_sm.last_warn then
        note("FF0000", "[Auto-Herd] " .. warn_text)
      end
    end
    ah_sm.last_warn = warn_text
    ah.status = status or "idle"
    if ah.debug then note("808080", "[Auto-Herd] idle tick -- " .. tostring(status)) end
    ah_sm.next_at = now + AH_INTERVAL
  end
end

-- Trigger handler for the server's pen-full refusal (vlivestock.c:334),
-- registered from init.lua via M.triggers below. See the PEN-FULL LATCH note
-- beside ah_full for why the client's own space arithmetic is not enough on
-- its own.
--
-- Two jobs, and the second matters as much as the first:
--   1. Latch the building, so the planner stops choosing it (mark_pen_full).
--   2. Abandon the in-flight confirm IMMEDIATELY. The refused buy moved no
--      state, so ah_state_sig() will not change and the confirm phase would
--      otherwise sit until AH_CONFIRM_TIMEOUT and then report the misleading
--      "no confirmation for last action" -- when in fact we know exactly what
--      happened and can say so. Dropping straight to a cooldown also keeps
--      the ordinary refusal bookkeeping (ah_sm.refused) intact.
--
-- Fires whether or not the buy came from Auto-Herd: a manual `vlivestock buy`
-- into a full pen is the same fact about the world, and latching on it only
-- makes the planner agree with what the player was just told.
function M.on_pen_full(line, c1)
  local bldg = c1 and c1:lower() or nil
  if not bldg then return end
  M.mark_pen_full(bldg)
  local ah = M.settings()
  ah.status = bldg .. " is full -- skipping until there is room"
  if ah_sm.phase == "confirming" then
    drop_listing(ah_sm.lin, ah_sm.idx)
    ah_sm.refused = ah_sm.cmd
    ah_sm.phase, ah_sm.next_at = "cooldown", os.time() + AH_COOLDOWN
  end
  note("FFA500", string.format(
    "[Auto-Herd] %s is full -- no more buys into it until it has room "
    .. "(slaughter, upgrade, or wait for a delivery).", bldg))
end

-- Registered by init.lua alongside notify.triggers. The pattern matches the
-- server's exact wording at vlivestock.c:334, capturing the building name so
-- one full pen never blocks the other four.
M.triggers = {
  { name = "autoherd_pen_full",
    pattern = "Your (\\w+) is full \\(counting animals already in transit\\)",
    fn = function(line, c1) M.on_pen_full(line, c1) end },
}

-- ---------------------------------------------------------------------------
-- Control surface: /vik herd <sub> (the LEGACY:476-544 ah_config port, wired
-- in init.lua) and the settings menu (LEGACY:588-736, aherd_menu_build +
-- viking_aherd_menu_pick). See the module header for every adaptation.
-- ---------------------------------------------------------------------------

local function replacement_status(ah)
  local s = replace.status(ah.replace)
  note("FFA500", "[Auto-Herd] replacement " .. (ah.replace.enabled and "ON (irreversible slaughter)" or "off")
    .. " | " .. s.phase .. " | " .. (s.reason or "")
    .. " | maxcost " .. tostring(ah.replace.max_cost) .. " dailycost " .. tostring(ah.replace.daily_cost)
    .. " dailycull " .. tostring(ah.replace.daily_cull) .. " maxcull " .. tostring(ah.replace.max_cull)
    .. " keep " .. tostring(ah.replace.min_keep) .. " minprofit " .. tostring(ah.replace.min_profit)
    .. " horizon " .. tostring(ah.replace.horizon_ticks) .. " gap " .. tostring(ah.replace.gap_ticks)
    .. " overhead " .. tostring(ah.replace.overhead))
end

local function price_stream_diagnostic()
  -- Load lazily: standalone consumers may not provide the trade handler's UI dependencies.
  local ok, trade = pcall(require, "handlers.trade")
  local status = {}
  if ok and type(trade) == "table" and type(trade._tgoods_status) == "function" then
    local read_ok, value = pcall(trade._tgoods_status)
    if read_ok and type(value) == "table"
        and value.connection_epoch == (S.herd_connection_epoch or 0) then status = value end
  end
  local function finite(n)
    return type(n) == "number" and n == n and n > -math.huge and n < math.huge
  end
  local function count(n, fallback)
    return finite(n) and n >= 0 and string.format("%.0f", math.min(1e9, math.floor(n))) or fallback
  end
  local progress = count(status.received, "0") .. "/" .. count(status.expected, "?")
  local now, last = os.time(), nil
  local observed = (S.herd_observed or {}).prices
  -- Legacy receipts and receipts surviving a handler reload are also proof.
  for _, receipt in pairs({ status = status.last_complete_at, observed = type(observed) == "table" and observed.at or nil }) do
    if finite(receipt) and receipt <= now and (not last or receipt > last) then last = receipt end
  end
  local text = "price stream: "
  if last then
    text = text .. "last complete grid " .. count(now - last, "?") .. "s ago"
    if not status.complete then text = text .. "; receiving " .. progress end
  else
    text = text .. progress .. " lineages; waiting for first complete grid"
  end
  if progress == "0/?" then text = text .. "; waiting for server's next cycle (300s)" end
  note("FFA500", "  " .. text)
end

local function replacement_config(rest, ah)
  if rest == "forecast" or rest == "replace preview" then
    local p, reason, details, feed = M.replacement_preview()
    if feed then
      note("FFA500", "[Auto-Herd] new replacement execution blocked: " .. feed)
    end
    if not p then
      note("FFA500", "[Auto-Herd] replacement preview: " .. tostring(reason))
      if tostring(reason):find("stale/missing prices", 1, true) == 1 then price_stream_diagnostic() end
      for _, detail in ipairs(details or {}) do
        note("FFA500", "  " .. detail.building .. ": " .. detail.reason)
      end
      if tostring(reason):find("missing server", 1, true) then return true end
      if tostring(reason):find("stale", 1, true) or tostring(reason):find("missing", 1, true) then
        note("FFA500", "  " .. REFRESH_HINT)
      end

    else
      note("FFA500", string.format("[Auto-Herd] preview ONLY: %s replace %d; purchase %g; gross opportunity lower %g; advisory high %g (%s)",
        p.building, p.count, p.cost, p.forecast.net_low, p.forecast.net_high, p.model_source))
      note("FFA500", "  Sale transport/risk excluded; not guaranteed profit. Execution separately requires replace overhead N, even when already enabled.")
      for _, text in ipairs(p.forecast.assumptions) do note("808080", "  " .. text) end
      for _, text in ipairs(p.forecast.excluded) do note("808080", "  Excludes: " .. text) end
    end
    return true
  end
  if rest == "replace status" then replacement_status(ah); return true end
  if rest == "replace on" then
    if replace.busy(ah.replace) or replacement_save_failed[ah.replace] then
      note("FF0000", "[Auto-Herd] inspect server state and explicitly reset the replacement halt first")
      return true
    end
    ah.replace.enabled = true
    note("FF0000", "[Auto-Herd] replacement ON authorizes IRREVERSIBLE SLAUGHTER on a later tick, only with master Auto-Herd ON. No command sent now.")
  elseif rest == "replace off" then
    replace.cancel(ah.replace, "replacement off; inspect server state before reset")
  elseif rest == "replace reset" then
    if replace.busy(ah.replace) and replace.status(ah.replace).phase ~= "halted" then
      note("FF0000", "[Auto-Herd] active replacement: use replace off, inspect herd/queue/deliveries manually, then reset")
      return true
    end
    replace.reset(ah.replace)
    replacement_save_failed[ah.replace] = nil
    note("FFA500", "[Auto-Herd] reset acknowledged: you must manually inspect herd/queue/deliveries; budgets retained, replacement OFF")
  elseif rest:match("^replace%s") or rest:match("^model%s") then
    if replace.busy(ah.replace) then
      note("FF0000", "[Auto-Herd] replacement busy; off, inspect, reset before changing its model/limits")
      return true
    end
    local key, text = rest:match("^replace%s+(%a+)%s+(%S+)$")
    local limits = { maxcost = "max_cost", dailycost = "daily_cost", dailycull = "daily_cull",
      maxcull = "max_cull", keep = "min_keep", minprofit = "min_profit", horizon = "horizon_ticks",
      gap = "gap_ticks", overhead = "overhead" }
    local b, field, value = rest:match("^model%s+(%a+)%s+(%a+)%s+(%S+)$")
    b = bldg_alias(b)
    local n = tonumber(text or value)
    local valid = n and n == n and math.abs(n) <= 1000000000
    if key and limits[key] then
      valid = valid and (key == "minprofit" or n >= 0)
        and (key == "minprofit" or key == "overhead" or n % 1 == 0)
      if key == "horizon" then valid = valid and n >= 1 and n >= ah.replace.gap_ticks end
      if key == "gap" then valid = valid and n <= ah.replace.horizon_ticks end
      if valid then ah.replace[limits[key]] = n end
    elseif b and (field == "output" or field == "share") then
      valid = valid and n >= 0 and (field ~= "share" or n <= 1)
      if valid then
        ah.replace.models[b] = ah.replace.models[b] or {}
        ah.replace.models[b][field == "output" and "production_per_tick" or "scaled_share"] = n
      end
    else valid = false end
    if not valid then
      note("FF0000", "[Auto-Herd] replace on|off|status|reset|preview; replace maxcost|dailycost|dailycull|maxcull|keep|minprofit|horizon|gap|overhead N; model <building> output N|share 0..1. Finite magnitude <=1e9; counts/ticks/cost limits integers; gap <= horizon.")
      return true
    end
  else return false end
  replacement_save(ah)
  return true
end

-- LEGACY:476-544 (ah_config).
function M.config(rest)
  rest = (rest or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if rest == "refresh" then M.refresh(); return end
  if rest == "forecast" or rest == "replace preview" then
    replacement_config(rest, preview_settings())
    return
  end
  local ah = M.settings()

  if replacement_config(rest, ah) then return end

  if rest == "on" then
    page_opts.set("auto_herd", true); note("FFA500", "[Auto-Herd] ON.")
  elseif rest == "off" then
    page_opts.set("auto_herd", false); note("FFA500", "[Auto-Herd] OFF.")
    if replace.busy(ah.replace) then
      replace.cancel(ah.replace, "master off; inspect server state before reset")
      replacement_save(ah); return
    end
  elseif rest == "stock on" then
    ah.restock = true; note("FFA500", "[Auto-Herd] stock/restock ON.")
  elseif rest == "stock off" then
    ah.restock = false; note("FFA500", "[Auto-Herd] stock/restock OFF.")
  elseif rest == "cross on" then
    ah.crossbreed = true; note("FFA500", "[Auto-Herd] crossbreed ON.")
  elseif rest == "cross off" then
    ah.crossbreed = false; note("FFA500", "[Auto-Herd] crossbreed OFF.")
  elseif rest == "quality on" then
    ah.buy_quality = true; note("FFA500", "[Auto-Herd] quality buy-ins ON.")
  elseif rest == "quality off" then
    ah.buy_quality = false; note("FFA500", "[Auto-Herd] quality buy-ins OFF.")
  elseif rest == "feed on" then
    ah.feed_guard = true; note("FFA500", "[Auto-Herd] feed guard ON.")
  elseif rest == "feed off" then
    ah.feed_guard = false; note("FFA500", "[Auto-Herd] feed guard OFF.")
  elseif rest == "debug on" then
    ah.debug = true; note("FFA500", "[Auto-Herd] debug ON.")
  elseif rest == "debug off" then
    ah.debug = false; note("FFA500", "[Auto-Herd] debug OFF.")
  elseif rest == "gen auto" then
    ah.gen_refresh = 0; note("FFA500", "[Auto-Herd] crossbreed gen threshold: auto (Constitution-based).")
  elseif rest == "log clear" then
    ah.log = {}; note("FFA500", "[Auto-Herd] log cleared.")
  elseif rest == "log" then
    if #ah.log == 0 then
      note("FFA500", "[Auto-Herd] log is empty.")
    else
      note("FFA500", "[Auto-Herd] recent activity:")
      for _, e in ipairs(ah.log) do
        note("FF8C00", "  " .. (e.t or "") .. " " .. (e.desc or ""))
      end
    end
  elseif rest == "" or rest == "status" then
    status_line(ah)
    replacement_status(ah)
  else
    local goal = rest:match("^goal%s+(%a+)$")
    if goal and GOAL_W[goal] then
      ah.goal = goal; note("FFA500", "[Auto-Herd] goal set to " .. goal .. ".")
      save(); return
    end
    if goal then
      note("FF0000", "[Auto-Herd] goals: " .. table.concat(GOAL_ORDER, ", ")); return
    end

    local tp = rest:match("^trait%s+(%a+)$")
    if tp then
      local valid = { any = true, off = true, prolific = true, hardy = true,
                       bountiful = true, purebred = true }
      if valid[tp] then
        ah.trait_pref = tp; note("FFA500", "[Auto-Herd] trait preference = " .. tp .. ".")
        save(); return
      else
        note("FF0000", "[Auto-Herd] trait: any | off | prolific | hardy | bountiful | purebred"); return
      end
    end

    -- `nval`, not `num`: the captured digits are a STRING, and naming them
    -- `num` shadowed this module's own num() coercion for the rest of the
    -- branch. Harmless while nothing here reads a number, a landmine for the
    -- next numeric read added to it.
    local key, nval = rest:match("^(%a+)%s+(%d+)$")
    if key == "reserve" then
      ah.reserve = tonumber(nval); note("FFA500", "[Auto-Herd] reserve = " .. nval)
    elseif key == "keep" then
      ah.keep = tonumber(nval); note("FFA500", "[Auto-Herd] keep = " .. nval)
    elseif key == "gen" then
      ah.gen_refresh = tonumber(nval); note("FFA500", "[Auto-Herd] crossbreed gen threshold = " .. nval)
    elseif key == "age" then
      ah.age_refresh = tonumber(nval); note("FFA500", "[Auto-Herd] crossbreed age threshold = " .. nval .. " ticks (0 = off)")
    elseif key == "feedticks" then
      ah.feed_ticks = tonumber(nval); note("FFA500", "[Auto-Herd] feed buffer = " .. nval .. " ticks")
    elseif key == "margin" then
      ah.quality_margin = tonumber(nval); note("FFA500", "[Auto-Herd] quality margin = " .. nval)
    else
      -- Per-building: aherd bldg <name> on|off|target <n>|keep <n>
      local bname, brest = rest:match("^bldg%s+(%a+)%s+(.+)$")
      local bldg = bldg_alias(bname)
      if bldg then
        ah.buildings[bldg] = ah.buildings[bldg] or { enabled = true, target = 0 }
        local bc = ah.buildings[bldg]
        if brest == "on" then
          bc.enabled = true; note("FFA500", "[Auto-Herd] " .. bldg .. " enabled.")
        elseif brest == "off" then
          bc.enabled = false; note("FFA500", "[Auto-Herd] " .. bldg .. " disabled.")
        else
          local bk, bv = brest:match("^(%a+)%s+(%d+)$")
          if bk == "target" then
            bc.target = tonumber(bv); note("FFA500", "[Auto-Herd] " .. bldg .. " target head = " .. bv)
          elseif bk == "keep" then
            bc.keep = tonumber(bv); note("FFA500", "[Auto-Herd] " .. bldg .. " keep = " .. bv)
          else
            usage()
          end
        end
      else
        usage(); return
      end
    end
  end
  save()   -- persist auto_herd on/off (page_opts) + settings immediately
end

-- LEGACY:565-567 (AH_RESERVE_STEPS/AH_KEEP_STEPS/AH_TRAIT_CHOICES, three
-- one-line locals). LEGACY's own ah_step (574-580) supported a `back`
-- direction for right-click; menu.lua has no equivalent gesture, so step_fwd
-- below only ever steps forward -- see the module header's
-- interaction-fidelity note.
local AH_RESERVE_STEPS = { 0, 500, 1000, 2000, 3000, 5000, 10000 }
local AH_KEEP_STEPS    = { 0, 2, 4, 6, 8, 10, 15 }
local AH_TRAIT_CHOICES = { "any", "prolific", "hardy", "bountiful", "purebred", "off" }

-- LEGACY:574-580 (ah_step). Forward-only port, see comment above.
local function step_fwd(cur, list)
  local i = 1
  for k, v in ipairs(list) do if v == cur then i = k break end end
  i = i + 1
  if i > #list then i = 1 end
  return list[i]
end

-- LEGACY:588 (aherd_menu_build). Item order/labels/ids are verbatim
-- (id = row.id); per-item colours (col=...) and tooltips (tip=...) have no
-- equivalent in menu.lua's plain-label rows and are dropped, same
-- disposition as autoraid.lua's own menu port. The "no buildings owned"
-- fallback row (LEGACY:646-649, `id="_none"`) is ported below too -- a
-- settings menu that silently renders no per-building rows when the player
-- owns none of the five livestock buildings would be worse than one that
-- says so.
function M.menu_items()
  local ah = M.settings()
  local on = page_opts.get("auto_herd")
  local items = {
    { id = "on", value = "on", label = "Auto-Herd: " .. (on and "ON" or "off") },
    { id = "goal", value = "goal", label = "Goal (stat weighting): " .. ah.goal },
    { id = "reserve", value = "reserve", label = "Daler reserve: " .. tostring(ah.reserve) },
    { id = "keep", value = "keep", label = "Keep breeders (restock floor): " .. tostring(ah.keep) },
    { id = "restock", value = "restock", label = "Stock/restock buildings: " .. (ah.restock and "on" or "off") },
    { id = "trait", value = "trait", label = "Prefer trait: " .. (ah.trait_pref or "any") },
    { id = "cross", value = "cross", label = "Crossbreed (fresh blood): " .. (ah.crossbreed and "on" or "off") },
    { id = "quality", value = "quality", label = "Quality buy-ins: " .. (ah.buy_quality and "on" or "off") },
    { id = "feed", value = "feed", label = "Feed guard: " .. (ah.feed_guard and "on" or "off") },
    { id = "replace preview", value = "replace preview", label = "Replacement preview (no commands)" },
    { id = "replace on", value = "replace on", label = "Enable replacement: IRREVERSIBLE SLAUGHTER" },
    { id = "replace off", value = "replace off", label = "Disable replacement (retain unresolved halt)" },
    { id = "_hdr", value = "_hdr", label = "Per-building (L-click toggles on/off):" },
  }
  local any_bldg = false
  for _, b in ipairs(LIVE_BLDGS) do
    if owns(b) then
      any_bldg = true
      -- LEGACY:614-645's row content, restored: head against cap, `tgt` and
      -- `keep`. LEGACY carried them in row.val ("%d/%d tgt:%s keep:%s" when
      -- enabled, "OFF" when not); menu.lua has one plain label per row, so
      -- they are folded into it. `keep` is settable via
      -- `/vik herd bldg <name> keep <n>` and was previously unreadable
      -- ANYWHERE in the UI, and head-against-cap is what tells a user whether
      -- a target is even reachable. LEGACY conveyed enabled/disabled by row
      -- colour, which menu.lua's plain labels cannot, so the word stays.
      local bc = ah.buildings[b] or { enabled = true, target = 0 }
      local en = bc.enabled ~= false
      local tier = bldg_tier(b)
      local herd = S.herds and S.herds[b]
      local body
      if en then
        local tgt = (bc.target and bc.target > 0) and tostring(bc.target) or "auto"
        local kp = bc.keep and tostring(bc.keep) or "def"
        body = string.format("on %d/%d tgt:%s keep:%s",
          (herd and num(herd.head)) or 0, cap_for(b, tier), tgt, kp)
      else
        body = "OFF"
      end
      items[#items + 1] = {
        id = "bldg_" .. b, value = "bldg_" .. b, bldg = b,
        label = string.format("  %s t%d [%s]", b, tier, body),
      }
    end
  end
  -- LEGACY:646-649 (aherd_menu_build's `if not any_bldg then` fallback).
  if not any_bldg then
    items[#items + 1] = { id = "_none", value = "_none",
      label = "  (no husbandry buildings owned)" }
  end
  return items
end

-- LEGACY:689-736 (viking_aherd_menu_pick). Every branch saves and reopens
-- the menu in place, matching LEGACY's own OnPluginSaveState() +
-- viking_show_aherd_menu() tail (no target-picker-style quirk here, unlike
-- autoraid.lua's raid target).
local function menu_pick(id)
  local ah = M.settings()
  if id:match("^replace ") then
    M.config(id); M.open_menu(); return
  end
  if id == "on" then
    M.config(page_opts.get("auto_herd") and "off" or "on")
    M.open_menu(); return
  elseif id == "restock" then
    ah.restock = not ah.restock
  elseif id == "trait" then
    ah.trait_pref = step_fwd(ah.trait_pref or "any", AH_TRAIT_CHOICES)
  elseif id == "cross" then
    ah.crossbreed = not ah.crossbreed
  elseif id == "quality" then
    ah.buy_quality = not ah.buy_quality
  elseif id == "feed" then
    ah.feed_guard = not ah.feed_guard
  elseif id == "goal" then
    ah.goal = step_fwd(ah.goal, GOAL_ORDER)
  elseif id == "reserve" then
    ah.reserve = step_fwd(ah.reserve, AH_RESERVE_STEPS)
  elseif id == "keep" then
    ah.keep = step_fwd(ah.keep, AH_KEEP_STEPS)
  else
    local b = id:match("^bldg_(%a+)$")
    if b then
      ah.buildings[b] = ah.buildings[b] or { enabled = true, target = 0 }
      local bc = ah.buildings[b]
      bc.enabled = not (bc.enabled ~= false)
    end
    -- "_hdr", "_none", and anything else unrecognised: no-op, reopen below.
  end
  save()
  M.open_menu()
end

-- LEGACY:653-687 (viking_show_aherd_menu; the closing `end` is 687 -- 672 is
-- mid-function, inside a WindowAddHotspot call).
function M.open_menu()
  require("menu").open({
    items = M.menu_items(),
    title = "Auto-Herd Settings",
    on_select = function(value) menu_pick(value) end,
  })
end

-- /vik herd [<sub>] dispatch (init.lua). Bare (rest == "") opens the
-- settings menu; anything else goes through M.config. Same two-line shape as
-- autoraid.lua's own M.raid_command -- LEGACY reached these through its
-- `aherd` alias (guild_viking_husbandry.lua's AddAlias tail), which has no
-- equivalent here.
function M.herd_command(rest)
  rest = rest or ""
  if rest == "" then
    M.open_menu()
    return
  end
  M.config(rest)
end

-- Cross-session persistence snapshot/restore, called from persist.lua's
-- M.save()/M.load() -- same shape as autoraid.lua's own M.snapshot()/
-- M.restore(), persist.lua's established pattern for a plugin-local
-- automation-settings table (see persist.lua's header for why this pair
-- exists at all).
function M.snapshot()
  return { autoherd = S.autoherd }
end

function M.restore(tbl)
  if not tbl then return end
  if tbl.autoherd then S.autoherd = tbl.autoherd; M.settings() end
end

return M
