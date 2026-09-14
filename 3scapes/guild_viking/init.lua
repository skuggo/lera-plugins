-- Guild Viking plugin: stage 1 foundation (protocol, state, notifications,
-- persistence, /vik). Window pages arrive in stage 2 and read this state.
local state_mod = require("state")
local protocol = require("protocol")
local command = require("command")

-- One registration path for every handler module, so a module gaining a
-- `_gmcp` table cannot silently go unregistered. Before this, only the `city`
-- loop forwarded `_gmcp`; the other three would have counted a new GMCP
-- writer's keys `unknown` forever and nothing would have failed loudly.
--
-- A module now carries exactly two things: `_gmcp`, the writer table, and
-- `_market_seam`, trade's injection point for market.lua. The MIP-era members
-- -- bare uppercase keys, `_patterns`, `_retired_keys`, `_retired_patterns` --
-- are gone with the transport, and anything else appearing in a module table
-- is a mistake worth failing on rather than skipping silently, which is what
-- the old `if not RESERVED[key]` branch would now do.
local RESERVED = { _market_seam = true, _gmcp = true }

local function register_handlers(mod)
  for key in pairs(mod) do
    if not RESERVED[key] then
      error("handler module has an unexpected member: " .. tostring(key))
    end
  end
  for key, fn in pairs(mod._gmcp or {}) do
    protocol.gmcp_handler(key, fn)
  end
end

local trade = require("handlers.trade")
register_handlers(trade)

-- Task 7: price history / demand metrics. LEGACY's MARKET branch never
-- calls record_price_history (only TGOODS does -- see market.lua's header
-- comment), so on_market is intentionally left unset.
local market = require("market")
trade._market_seam.on_tgoods = market.on_tgoods

local voyage = require("handlers.voyage")
register_handlers(voyage)

local kingdom = require("handlers.kingdom")
register_handlers(kingdom)

local city = require("handlers.city")
register_handlers(city)

local livestock = require("handlers.livestock")
register_handlers(livestock)

-- Guild.State's vitals block. Registered like any other handler module, but
-- note the ordering constraint it does NOT have: the hp-bar triggers below are
-- registered later and stand down at runtime via S.vitals_gmcp, not by being
-- skipped here -- they are also what gags the prompt lines out of the main
-- buffer, so they must be registered either way.
local vitals = require("handlers.vitals")
register_handlers(vitals)

-- Stage 2: page options + the tab bar / page shell (window.lua). Required
-- after the handlers so the state they populate is available to the pages
-- window.lua registers, even though no page reads it until Task 3+.
local page_opts = require("page_opts")
local window = require("window")
local stats_page = require("pages.stats")

-- Stage 3: named-popup registry + /vik pop. map/sea/voyage/cityplan/war
-- all self-register (popups.lua's own require+register block) -- see that
-- file's header comment for the renderer-module contract.
local popups = require("popups")

-- Task 8: combat composite + hp-bar triggers. The FFF MIP composite this used
-- to read is gone; Char.Combat carries the attacker block now (subscribed in
-- on_load), and the hp-bar text triggers stay registered either way because
-- they are also what gags the prompt lines out of the main buffer.
local combat = require("combat")

-- Task 9: push notifications + the per-second countdown timer. `pushn` is
-- looked up in on_setup (plugins load before on_setup runs, per CLAUDE.md's
-- Push API producer pattern) and handed to notify.set_push; it stays nil,
-- and every trigger fn is a safe no-op, if push_notify isn't loaded.
local notify = require("notify")

-- Task 10: cross-session persistence (price history + transport source).
local persist = require("persist")

-- Stage 4 Task 3: the auto-trade paced runner + its /vik trader control
-- surface and settings menu. notify.lua calls autotrade_tick.tick() itself
-- (see its own header); init.lua only needs it for the command surface.
local autotrade_tick = require("autotrader.tick")

-- Stage 4 Task 8: the auto-raider + its /vik raid control surface and
-- settings menu. notify.lua calls autoraid.tick() itself (see its own
-- header); init.lua only needs it for the command surface.
local autoraid = require("autoraid")

-- Stage 4 Task 7: the auto-voyage router + its /vik voyage auto control
-- surface and settings menu. notify.lua calls autovoyage.tick() itself (see
-- its own header); init.lua only needs it for the command surface.
local autovoyage = require("autovoyage")

-- Husbandry plan Task 4: Auto-Herd + its /vik herd control surface and
-- settings menu. notify.lua calls autoherd.tick() itself (see its own
-- header); init.lua only needs it for the command surface. Without the
-- `herd` branch in M.vik_command below, the whole Task 3 settings surface
-- (goal/reserve/keep/per-building/menu) would be unreachable -- only the
-- master toggle would be, via `/vik set auto_herd on`. Auto-Herd is OFF by
-- default and sends nothing until explicitly enabled.
local autoherd = require("autoherd")

-- Client-side Viking Auto-War planner. It is deliberately OFF by default;
-- notify.lua owns its paced tick and this module only provides configuration
-- and status here.
local autowar = require("autowar")

local S = state_mod.S

local M = {}
M.name = "guild_viking"
M.version = "0.1"

function M.state()
  return state_mod.S
end

local gmcp_id, combat_gmcp_id, countdown_id
local combat_trigger_ids = {}
local notify_trigger_ids = {}
local vik_command_id, resetvikxp_id, kill_listener_id

-- LEGACY plugins/guild_viking.xml:175-186 (`resetvikxp` alias), also reached
-- via `/vik resetxp`. viking_window.update() is dropped -- stage 2 territory.
local function do_resetxp()
  S.vis_session = 0
  S.kap_session = 0
  S.soe_session = 0
  S.aud_session = 0
  S.xp_session_start = nil
  buffer.color_print(nil, "DAA520", "Viking XP session counter reset.")
  ui.dirty()
end

-- Hp-bar gagging (stage-1 ruling, landed here per Task 3): the 8 combat/
-- hp-bar triggers (combat.triggers) go into the main output buffer raw
-- unless gagged -- LEGACY never printed them there either (they only ever
-- fed its detached window), and now that the Stats page (pages/stats.lua)
-- shows the same data in the pane, gagging keeps lera's main output as quiet
-- as LEGACY's was. `page_opts.get("gag_status_lines")` is read fresh each
-- time this registers, so a later re-registration (below) picks up a
-- changed setting without a reconnect/reload.
local function combat_trigger_opts()
  if page_opts.get("gag_status_lines") then
    return { omit_from_output = true }
  end
  return nil
end

local function register_combat_triggers()
  local opts = combat_trigger_opts()
  for _, t in ipairs(combat.triggers) do
    combat_trigger_ids[#combat_trigger_ids + 1] = trigger.add(t.pattern, t.fn, opts)
  end
end

local function unregister_combat_triggers()
  for _, tid in ipairs(combat_trigger_ids) do
    trigger.remove(tid)
  end
  combat_trigger_ids = {}
end

-- `/vik set gag_status_lines on|off` needs the new setting to take effect
-- immediately rather than only on the next reconnect: simplest fix is to
-- tear the 8 triggers down and re-add them reading the option fresh. Called
-- once from on_load (via register_combat_triggers directly, since there's
-- nothing to tear down yet) and again from set_opt below whenever that one
-- option changes.
local function reregister_combat_triggers()
  unregister_combat_triggers()
  register_combat_triggers()
end

-- "ready" convention: same as pages/stats.lua's own fmt_time (secs <= 0 ->
-- "ready") -- duplicated here in miniature rather than requiring the pages
-- module into init.lua for one helper.
local function fmt_next(next_at)
  if not next_at or next_at <= 0 then return "ready" end
  local left = next_at - os.time()
  if left <= 0 then return "ready" end
  return left .. "s"
end

-- Task 9 (lera-only -- LEGACY has no /vik status equivalent for these
-- three; see each automation module's own header for that disclosure).
-- Reads each automation's own status surface rather than any internals:
-- autotrade_tick.status() (extended this task with a 5th "next check" epoch
-- return), autoraid.settings()/M.AR_INTERVAL, autovoyage.settings()/
-- M.AV_INTERVAL (the latter newly exported this task, mirroring autoraid's
-- own M.AR_INTERVAL).
local function print_automation_status()
  local trade_phase, trade_pending, _, trade_last_error, trade_next_at = autotrade_tick.status()
  buffer.color_print(nil, "DAA520", string.format(
    "  Auto-Trade: %s | phase=%s pending=%d%s | next: %s",
    page_opts.get("auto_trade") and "ON" or "off", trade_phase, trade_pending,
    (trade_last_error ~= "" and (" last_error=" .. trade_last_error)) or "",
    fmt_next(trade_next_at)))

  local ar = autoraid.settings()
  local raid_last = "none"
  if ar.last_dispatch then
    raid_last = string.format("%d ship%s to %s%s at %s", ar.last_dispatch.n,
      ar.last_dispatch.n == 1 and "" or "s", ar.last_dispatch.target,
      ar.last_dispatch.convoy and " (convoy)" or "", ar.last_dispatch.t)
  end
  buffer.color_print(nil, "DAA520", string.format(
    "  Auto-Raid: %s | last dispatch: %s | next: %s",
    page_opts.get("auto_raid") and "ON" or "off", raid_last,
    fmt_next((ar.last or 0) + autoraid.AR_INTERVAL)))

  local av = autovoyage.settings()
  local voyage_last = (av.log and #av.log > 0) and av.log[#av.log] or "none"
  buffer.color_print(nil, "DAA520", string.format(
    "  Auto-Voyage: %s | last: %s | next: %s",
    page_opts.get("auto_voyage") and "ON" or "off", voyage_last,
    fmt_next((av.last or 0) + autovoyage.AV_INTERVAL)))

  -- Auto-Herd, mirroring the three blocks above. Its log entries are
  -- { t = "HH:MM", desc = ... } records rather than Auto-Voyage's plain
  -- strings, hence the join. This block being absent made the `/vik` help
  -- text's own promise ("each automation's on/off state and
  -- last-action/next-eligible summary") false by omission -- for the ONE
  -- automation that spends the player's daler.
  local ah = autoherd.settings()
  local herd_last = "none"
  if ah.log and #ah.log > 0 then
    local e = ah.log[#ah.log]
    herd_last = tostring(e.t or "") .. " " .. tostring(e.desc or "")
  end
  buffer.color_print(nil, "DAA520", string.format(
    "  Auto-Herd: %s | last: %s | next: %s",
    page_opts.get("auto_herd") and "ON" or "off", herd_last,
    fmt_next((ah.last or 0) + autoherd.AH_INTERVAL)))

  local aw = autowar.settings()
  buffer.color_print(nil, "DAA520", string.format(
    "  Auto-War: %s | phase=%s | last: %s | next: %s",
    page_opts.get("auto_battle") and "ON" or "off", autowar.status().phase,
    aw.status ~= "" and aw.status or "none",
    fmt_next((aw.last or 0) + (autowar.AW_INTERVAL or 4))))
end

-- The keys GMCP has fed this connection, sorted. The single extraction both
-- /vik status (which wants the count) and /vik source (which wants the list)
-- read, so the two can never disagree about what is latched.
local function gmcp_key_names()
  local names = {}
  for k in pairs(protocol.gmcp_keys()) do names[#names + 1] = k end
  table.sort(names)
  return names
end

-- Which panels GMCP has actually fed, plus the frame counters. There is only
-- one transport now, so this is no longer a "which source won" breakdown --
-- it is the answer to "is the guild pushing me anything, and what".
local function print_sources()
  local names = gmcp_key_names()
  if #names == 0 then
    buffer.color_print(nil, "DAA520", "  no keys fed by GMCP yet")
  else
    buffer.color_print(nil, "DAA520",
      "  GMCP keys (" .. #names .. "): " .. table.concat(names, " "))
  end

  local gs = protocol.gmcp_stats()
  local unknown = {}
  for k in pairs(gs.unknown) do unknown[#unknown + 1] = k end
  table.sort(unknown)
  if #unknown > 0 then
    buffer.color_print(nil, "DAA520",
      "  received, not consumed: " .. table.concat(unknown, " "))
  end
  buffer.color_print(nil, "DAA520", string.format(
    "  frames %d, foreign %d, malformed %d",
    gs.frames, gs.foreign, gs.malformed))
end

local function print_status()
  local st = protocol.gmcp_stats()
  -- One transport, so the summary counts frames and the panels they carried.
  -- `applied` is per key; the total is what "this client is being fed" means,
  -- and gmcp_keys is how many distinct panels have ever arrived. `/vik source`
  -- names them.
  local applied = 0
  for _, n in pairs(st.applied) do applied = applied + n end
  buffer.color_print(nil, "DAA520", string.format(
    "Viking: gmcp_keys=%d frames=%d applied=%d foreign=%d malformed=%d",
    #gmcp_key_names(), st.frames, applied, st.foreign, st.malformed))

  local unknown = {}
  for k, n in pairs(st.unknown) do unknown[#unknown + 1] = { key = k, n = n } end
  table.sort(unknown, function(a, b) return a.n > b.n end)
  if #unknown > 0 then
    local parts = {}
    for i = 1, math.min(5, #unknown) do
      parts[#parts + 1] = unknown[i].key .. "=" .. unknown[i].n
    end
    buffer.color_print(nil, "DAA520", "  unknown: " .. table.concat(parts, " "))
  else
    buffer.color_print(nil, "DAA520", "  unknown: none")
  end

  local err_total, err_keys = 0, 0
  for _, n in pairs(st.errors) do
    err_total = err_total + n
    err_keys = err_keys + 1
  end
  buffer.color_print(nil, "DAA520", string.format(
    "  writer errors: %d (%d key%s)", err_total, err_keys, err_keys == 1 and "" or "s"))

  print_automation_status()
end

-- `/vik opts`: list every page option with its current value.
local function print_opts()
  local lines = {}
  for _, o in ipairs(page_opts.all()) do
    lines[#lines + 1] = o.key .. " = " .. (o.value and "on" or "off")
  end
  buffer.color_print(nil, "DAA520", table.concat(lines, "\n"))
end

-- `/vik set <opt> on|off|toggle`: validated flip of one page option.
local function set_opt(rest)
  local opt, mode = rest:match("^(%S+)%s+(%S+)$")
  if not opt then
    buffer.color_print(nil, "DAA520", "Usage: /vik set <opt> on|off|toggle")
    return
  end
  local current = page_opts.get(opt)
  if current == nil then
    buffer.color_print(nil, "DAA520", "Viking: unknown page option '" .. opt .. "'")
    return
  end
  local new_val
  if mode == "on" then new_val = true
  elseif mode == "off" then new_val = false
  elseif mode == "toggle" then new_val = not current
  end
  if new_val == nil then
    buffer.color_print(nil, "DAA520", "Usage: /vik set <opt> on|off|toggle")
    return
  end
  page_opts.set(opt, new_val)
  if opt == "gag_status_lines" then
    reregister_combat_triggers()
  end
  buffer.color_print(nil, "DAA520", "Viking: " .. opt .. " = " .. (new_val and "on" or "off"))
end

-- The five named popups /vik toggles (map/sea/voyage/cityplan/war). "war"
-- also names a pane page (window.PAGES) -- the binding ruling (plan Task 1)
-- is that the bare key toggles the POPUP; `/vik page war` reaches the pane.
local POPUP_NAMES = { map = true, sea = true, voyage = true, cityplan = true, war = true }

-- Dispatches /vik's subcommands. `args` is everything after "/vik " (may be
-- ""); an unknown or empty subcommand prints usage. A bare arg matching one
-- of window.PAGES' keys (case-insensitively) switches the pane's current
-- page, same as clicking its tab -- EXCEPT "war", which the bare form routes
-- to its popup instead (see POPUP_NAMES above); `/vik page war` is the
-- explicit pane route for it.
function M.vik_command(args)
  args = args or ""
  local sub, rest = args:match("^%s*(%S*)%s*(.-)%s*$")
  sub = sub or ""
  local sub_lower = sub:lower()

  if sub == "status" then
    print_status()
  elseif sub == "trace" then
    local want
    if rest == "on" then want = true
    elseif rest == "off" then want = false end
    local now = protocol.trace(want)
    buffer.color_print(nil, "DAA520", "Viking protocol trace: " .. (now and "on" or "off"))
  elseif sub == "save" then
    persist.save()
    buffer.color_print(nil, "DAA520", "Viking guild data saved.")
  elseif sub == "source" then
    -- A read now, whatever follows it. There is one transport, so the old
    -- mip/gmcp/auto argument has nothing to select; accepting and ignoring it
    -- says so once rather than erroring at someone's muscle memory.
    if rest ~= "" then
      buffer.color_print(nil, "DAA520",
        "Viking runs on GMCP only; there is no transport to select.")
    end
    buffer.color_print(nil, "DAA520", "Viking transport: GMCP (Guild.*)")
    print_sources()
  elseif sub == "resetxp" then
    do_resetxp()
  elseif sub == "opts" then
    print_opts()
  elseif sub == "set" then
    set_opt(rest)
  elseif sub_lower == "trader" then
    autotrade_tick.trader_command(rest)
  elseif sub_lower == "raid" then
    autoraid.raid_command(rest)
  elseif sub_lower == "herd" then
    autoherd.herd_command(rest)
  elseif sub_lower == "awar" or sub_lower == "autowar" then
    autowar.config(rest)
  elseif sub_lower == "voyage" and rest:sub(1, 4):lower() == "auto"
      and (#rest == 4 or rest:sub(5, 5):match("%s")) then
    -- "/vik voyage auto [<sub>]" -- strip the "auto" token (case-
    -- insensitively) and hand the remainder to autovoyage.lua, same shape
    -- as the "trader" branch above. Plain "/vik voyage" (no "auto" prefix)
    -- falls through to the POPUP_NAMES branch below, unchanged.
    autovoyage.voyage_command((rest:sub(5):gsub("^%s+", "")))
  elseif POPUP_NAMES[sub_lower] then
    popups.toggle(sub_lower)
  elseif sub_lower == "page" then
    local key = rest:lower()
    if key ~= "" and window.set_page(key) then
      buffer.color_print(nil, "DAA520", "Viking page: " .. key)
    else
      buffer.color_print(nil, "DAA520", "Usage: /vik page <page>")
    end
  elseif sub_lower == "pop" then
    local key = rest:lower()
    if key == "" then
      buffer.color_print(nil, "DAA520", "Usage: /vik pop <page>")
    else
      popups.open_page(key)
    end
  elseif sub ~= "" and window.set_page(sub_lower) then
    buffer.color_print(nil, "DAA520", "Viking page: " .. sub_lower)
  else
    buffer.color_print(nil, "DAA520",
      "Usage: /vik [status | trace | save | source | resetxp | "
      .. "map | sea | voyage | cityplan | war | page <page> | pop <page> | "
      .. "<page> | opts | set <opt> on|off|toggle | trader [<sub>] | raid [<sub>] | "
      .. "voyage auto [<sub>] | herd [<sub>] | awar [<sub>]]")
  end
end

-- Introspection helper (Task 7): sorted array of the popup names popups.lua
-- has actually self-registered right now -- the cheapest honest probe that
-- popups.lua's map/sea/voyage/cityplan/war registrations ran, for a
-- headless sandbox check that has no MUD connection to drive any of them
-- open through /vik.
function M.popup_names()
  return popups.names()
end

function M.on_load()
  -- Char.Combat is not a Guild.* frame -- it carries no guild envelope and does
  -- not go through protocol.on_gmcp -- so it gets its own subscription here,
  -- next to the MIP channel it replaces. Subscribing advertises `Char 1`.
  combat_gmcp_id = gmcp.on("Char.Combat", function(pkg, data)
    combat.on_gmcp_combat(data)
  end)
  -- One registration covers every Guild.* sub-package: lera dispatches on
  -- dot-boundary prefix, and advertising `Guild 1` subscribes them all through
  -- the mudlib's root fallback. A panel added server-side later needs no change
  -- here.
  gmcp_id = gmcp.on("Guild", function(pkg, data) protocol.on_gmcp(pkg, data) end)

  -- Fix 1: persist.load() must run BEFORE the initial combat-trigger
  -- registration, not after. register_combat_triggers() reads
  -- page_opts.get("gag_status_lines") fresh at call time (see its comment
  -- above), so a persisted gag_status_lines=false has to already be applied
  -- by the time this first registration happens -- otherwise every session
  -- silently re-gags the 8 hp-bar triggers regardless of what the user last
  -- saved, and only a subsequent /vik set flip would notice. persist.load
  -- depends only on market/protocol/page_opts/window, all required above
  -- this point, so moving it earlier has no ordering hazard of its own.
  persist.load()

  register_combat_triggers()
  for _, t in ipairs(notify.triggers) do
    notify_trigger_ids[#notify_trigger_ids + 1] = trigger.add(t.pattern, t.fn)
  end
  -- autoherd's own server-refusal trigger (the pen-full latch) rides the same
  -- list: it is registered unconditionally like notify's, and torn down by the
  -- same loop in on_unload. Not gated on page_opts.auto_herd -- the latch is a
  -- fact about the world worth recording even while the automation is off, and
  -- the planner is what consults it.
  for _, t in ipairs(autoherd.triggers or {}) do
    notify_trigger_ids[#notify_trigger_ids + 1] = trigger.add(t.pattern, t.fn)
  end
  countdown_id = timer.every(1000, function() notify.countdown_tick() end)

  local id, err = command.register({
    name = "/vik",
    usage = "/vik [status | trace | save | source | resetxp | "
      .. "map | sea | voyage | cityplan | war | page <page> | pop <page> | "
      .. "<page> | opts | set <opt> on|off|toggle | trader [<sub>] | raid [<sub>] | "
      .. "voyage auto [<sub>] | herd [<sub>] | awar [<sub>]]",
    summary = "Viking guild data, pane, and controls",
    description = "Ingestion status and counters, plus each automation's "
      .. "on/off state and last-action/next-eligible summary (status), key tracing "
      .. "(trace), explicit save (save), the per-panel GMCP feed report "
      .. "(source), the "
      .. "saga-XP session reset (resetxp; the bare 'resetvikxp' alias does "
      .. "the same), toggling a named popup open or closed -- map (Territory "
      .. "Map), sea (Sea Chart), voyage (Voyage Status), cityplan (City "
      .. "Plan), or war (Campaign Map / Battle Board) --, "
      .. "opening any pane page as a detached popup (pop <page>), "
      .. "switching the pane to a page by key -- stats, city, farm, "
      .. "builds, people, goods, bonds, ranks, court, army, war, or trade "
      .. "-- (page <page>; a bare <page> does the same, same as clicking "
      .. "its tab, EXCEPT 'war', whose bare form toggles the popup instead "
      .. "-- use 'page war' for the pane), listing every page option with "
      .. "its current value (opts), flipping one page option (set), and the "
      .. "client-side auto-trader: bare 'trader' opens its settings menu, "
      .. "'trader <sub>' configures it (on|off, stock on|off, pack on|off, "
      .. "stockroute on|off, stockpriority on|off, debug on|off, "
      .. "reserve/margin/profit/carts/show <n>, autostock <n>|off, "
      .. "log [clear]); and the client-side auto-voyage router: bare "
      .. "'voyage auto' opens its settings menu, 'voyage auto <sub>' "
      .. "configures it (on|off, balanced|max|safe, abyssal on|off, "
      .. "ship <name>|auto, verbose on|off, log); and the client-side "
      .. "Auto-Herd livestock planner: bare 'herd' opens its settings menu, "
      .. "'herd <sub>' configures it (on|off, goal <stat>, reserve/keep/gen/"
      .. "age/feedticks/margin <n>, trait <pref>, stock|cross|quality|feed "
      .. "on|off, bldg <name> on|off|target <n>|keep <n>, debug on|off, "
      .. "log [clear], status). All three automations are "
      .. "OFF by default and send nothing until explicitly enabled -- note "
      .. "that enabling Auto-Herd authorises it to SPEND DALER on "
      .. "'vlivestock buy', down to its own configurable reserve.",
    accepts_args = true,
    handler = function(args) M.vik_command(args or "") end,
  })
  if id then
    vik_command_id = id
  else
    print("[vik] /vik registration failed: " .. tostring(err))
  end

  resetvikxp_id = alias.add("^resetvikxp$", function() do_resetxp() end)
end

function M.on_setup()
  local sw = plugin.get("stats_window")
  if sw and sw.register_guild then
    sw.register_guild("guild_viking")
  end

  local kt = plugin.get("kill_trigger")
  if kt and kt.on_monster_died then
    -- Ported from LEGACY guild_viking.lua:2676-2682
    -- (guild.events.on_monster_died): clear the combat display fields and
    -- re-poll the hp-bar prompt so the UI reflects "no longer fighting"
    -- immediately rather than waiting for the next server update.
    kill_listener_id = kt.on_monster_died(function(killer, victim)
      S.combat = false
      S.combat_rounds = 0
      S.estatus_pct = 0
      S.mob_name_full = "None"
      mud.send("!hp")
      ui.dirty()
    end)
  end

  local pushn = plugin.get("push_notify")
  if pushn then
    pushn.register_channel("viking", { priority = 0 })
    notify.set_push(pushn)
  end
end

function M.on_unload()
  persist.save()

  gmcp.remove(gmcp_id)
  gmcp.remove(combat_gmcp_id)
  timer.cancel(countdown_id)
  unregister_combat_triggers()
  for _, tid in ipairs(notify_trigger_ids) do
    trigger.remove(tid)
  end
  notify_trigger_ids = {}

  if vik_command_id then
    command.unregister(vik_command_id)
    vik_command_id = nil
  end
  if resetvikxp_id then
    alias.remove(resetvikxp_id)
    resetvikxp_id = nil
  end

  if kill_listener_id then
    local kt = plugin.get("kill_trigger")
    if kt and kt.remove_kill_listener then
      kt.remove_kill_listener(kill_listener_id)
    end
    kill_listener_id = nil
  end
end

-- LEGACY guild_viking.lua:4770-4788 (OnPluginConnect). Two Portal-window-only
-- lines in that range (detached_pages_from_string(...), viking_window.create())
-- have no lera analog and are dropped, same disposition as every other
-- viking_window.*/detached-page call elsewhere in this port. Send("hp")
-- (LEGACY:4771) is ported verbatim as a plain mud.send("hp") -- this is a
-- DIFFERENT refresh than the "!hp" sent from on_setup's on_monster_died
-- listener above (that one ports LEGACY:2681's Execute("!hp"), fired after
-- combat ends, not on connect); nothing else in this plugin sends an hp
-- refresh at connect time, so this is not a duplicate.
function M.on_connect()
  mud.send("hp")
  -- Give the server a minute to push fresh prices/city state before the
  -- auto-trader is allowed to dispatch carts again (autotrader/plan.lua
  -- reads S.at_hold_until -- see that module's header).
  S.at_hold_until = os.time() + 60
  -- Clear transient, server-authoritative trade state. These lists persist
  -- in `state`, so after a client/computer restart they can hold carts or
  -- queued jobs that actually finished while we were down -- the server
  -- never re-reports a cart it no longer has, so stale entries would count
  -- against the cart limit forever and silently stall the auto-trader
  -- despite it reading ON. Wiping here fails safe: with carts/queue/idle
  -- empty the trader waits, and fresh CARTS/TQUEUE/CIDLE MIP repopulates
  -- the true state within the hold window above.
  S.carts       = {}
  S.trade_queue = {}
  S.idle_carts  = {}
end

function M.on_disconnect()
  persist.save()
  state_mod.reset_connection()
  protocol.reset_connection()
end

-- ---------------------------------------------------------------------------
-- stats_window contract (CLAUDE.md "Plugins" section, stats_window.lua
-- ~374-400): has_data() gates whether render_guild_stats is called at all.
-- Stage 2: the SAME builder the Stats pane page uses (pages/stats.lua),
-- truncated to the widget's rect -- not a separate, narrower summary.
-- ---------------------------------------------------------------------------

function M.has_data()
  -- Any panel having arrived, not a frame count: an empty-but-delivered frame
  -- is still the guild talking to us. This read the MIP ingest counter before,
  -- which would now be zero forever and leave the stats widget permanently
  -- blank -- the one place the transport swap could have gone silently wrong.
  return next(protocol.gmcp_keys()) ~= nil
end

local function rect_dims(rect)
  if type(rect.x) == "function" then
    return rect:x(), rect:y(), rect:w(), rect:h()
  end
  return rect.x, rect.y, rect.w, rect.h
end

-- The Stats page's lines, for a host that windows them itself (stats_window's
-- scrollable info pane asks for these so the guild block can scroll like any
-- other pane). render_guild_stats below keeps the older draw-into-a-rect
-- contract for hosts that don't.
function M.guild_stats_lines(width)
  if type(width) ~= "number" or width <= 0 then return {} end
  return stats_page.lines(width)
end

function M.render_guild_stats(rect, opts)
  opts = opts or {}
  local x, y, w, h = rect_dims(rect)
  if w <= 0 or h <= 0 then return 0 end

  local lines = M.guild_stats_lines(w)
  local n = math.min(#lines, h)
  for i = 1, n do
    ui.text_ansi(ui.rect(x, y + i - 1, w, 1), lines[i])
  end
  return n
end

-- ---------------------------------------------------------------------------
-- wm.assign renderer contract (CLAUDE.md "Pane Pointer Input" / "Pane
-- Scrolling"): a profile can `wm.assign("viking", plugin_table)` directly --
-- wm auto-discovers render/on_pointer/scroll/scroll_to_bottom/following_tail
-- on the assigned table, and every one of these just delegates to window.lua.
-- ---------------------------------------------------------------------------

function M.render(rect, opts)
  return window.render(rect, opts)
end

function M.on_pointer(event)
  return window.on_pointer(event)
end

function M.scroll(delta)
  return window.scroll(delta)
end

function M.scroll_to_bottom()
  return window.scroll_to_bottom()
end

function M.following_tail()
  return window.following_tail()
end

return M
