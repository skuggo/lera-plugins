-- Auto-trade paced/MIP-confirmed execution runner + its control surface.
-- Ported verbatim from LEGACY guild_viking_autotrader.lua:670-849:
--   at_config              670-724  -> M.config (reached via /vik trader <sub>)
--   vk_atrade_handler      727-729  -> folded into M.config's caller (init.lua)
--   the paced runner       741-849  -> the sm state machine below
--     (note/row_sig/list_sig/mip_sig/transactions/fail_closed/plan/
--      begin_transaction are LEGACY's own local helpers inside the same
--      `if type(plan_tick) == "function" then ... end` block; auto_trade_tick
--      itself is 812-845, viking_autotrader_status 846-848)
-- and from MAIN guild_viking.lua:11266-11380 (the Auto-Trade Options popup):
--   AT_MARGIN_STEPS..AT_AUTOSTOCK_STEPS   11274-11279
--   at_cycle                              11267-11272
--   atrade_menu_build                     11281-11319
--   viking_show_atrade_menu               11321-11351  -> M.open_menu
--   viking_atrade_menu_pick               11353-11380  -> menu_pick (local)
--
-- Stage 4 Task 3. This is the module that actually calls mud.send() for the
-- auto-trader -- every send is gated behind page_opts.get("auto_trade")
-- (checked first thing in M.tick, exactly where LEGACY's own tick checked
-- page_opts.auto_trade) and every send is a plain mud.send(cmd) string, so
-- the deadmans plugin's on_send hook governs it for free, exactly like any
-- other automated send in this client (see CLAUDE.md's Push/deadmans
-- section) -- this module needs no deadmans-specific code of its own.
--
-- Fail-closed gates this module adds ON TOP of autotrader/plan.lua's own
-- (not connected / settling / cooldown / no city data / no idle carts /
-- AT_INTERVAL / cart limit / no deals -- all already ported and tested at
-- the plan.lua level in Task 2's suite). Enumerated here because this is
-- where they live in the source (see the task report for the matching test
-- per gate):
--   1. page_opts.get("auto_trade") false at the top of M.tick -- resets the
--      whole state machine to idle/empty and returns. (LEGACY:814-816)
--   2. phase == "confirming": no new command is sent while waiting for the
--      MIP push that confirms the last one; a stale mip_sig blocks further
--      progress until either it changes or CONFIRM_TIMEOUT (20s) elapses.
--      (LEGACY:817-824)
--   3. confirmation timeout: no confirming mip_sig change within 20s ->
--      fail_closed -- the rest of the CURRENT plan's pending transactions
--      are discarded and no further command is sent until the 30s
--      FAILURE_COOLDOWN elapses. (LEGACY:820-821, 788-792)
--   4. phase == "cooldown": nothing is sent (and no new plan is even drawn)
--      until FAILURE_COOLDOWN's 30s elapses. (LEGACY:825-828)
--   5. post-success idle delay: right after a transaction confirms, the
--      NEXT transaction (if any remain pending) waits out COMMAND_DELAY's
--      2s before it may begin. (LEGACY:817-819, 829-830)
--   6. planner produces no transactions at all (either autotrader/plan.lua
--      itself gated the tick, or genuinely found nothing to do): nothing is
--      sent, and the phase simply stays idle so the NEXT tick tries
--      planning again once next_at allows. (LEGACY:831-832)
--   7. within a multi-command transaction, each command after the first
--      waits out COMMAND_DELAY's 2s before the next is sent (LEGACY:834,
--      843) -- this is also the boundary AT_INTERVAL rides on at the
--      plan.lua level (a fresh plan is only drawn once idle+pending-empty,
--      throttled by that same clock).
--   8. an empty transaction (`not cmd`) -> fail_closed. Structurally
--      unreachable through the public path: transactions() below only ever
--      emits a route transaction with >1 entries (LEGACY:772-787's own
--      `#route>1` guard) or a single-command dispatch transaction, so
--      sm.current is never {}. Kept verbatim as LEGACY's own defensive
--      guard (LEGACY:836); not given a dedicated test for the same reason
--      plan.lua's header discloses LEGACY:339 as dead code -- there is no
--      code path that can produce the state it guards against. The premise
--      itself -- that `#route>1` (not the weaker `if route then`) is what
--      keeps a bare "clear"+"queue add" from ever becoming a transaction --
--      IS pinned by a dedicated test (fix round 1, Minor 4), by
--      monkey-patching autotrader.plan's M.build to hand do_plan a crafted
--      commands list directly, since plan.lua's own invariants never
--      actually produce that shape for transactions() to see.
--   9. do_plan()'s pcall around planner.build() failing (a raised error, not
--      a normal return) -> fail_closed exactly like a confirmation timeout,
--      instead of the error propagating out of M.tick(). (LEGACY:800-802)
--
-- The baseline-capture guard at line ~244 below (`sm.index == #sm.current`)
-- is the ordering LEGACY's own comment there calls out: capturing mip_sig()
-- at the START of a route (index == 1) instead of immediately before its
-- TERMINAL command would let an unrelated cart completion mid-route satisfy
-- mip_sig() ~= baseline the instant the route finishes sending, falsely
-- confirming it before any real MIP push for THIS transaction ever arrives.
-- Fix round 1, Important 2 added a dedicated test for this (mutating
-- S.carts/idle_carts between a transaction's first and last command).
--
-- Adaptations (all mechanical, no logic changes):
--   * Send/real_send's global-hijack wrapper (LEGACY:793-799) is dropped:
--     autotrader/plan.lua's M.build() already returns its own captured
--     `commands` list directly (see that module's header), so `do_plan`
--     below (LEGACY's local `plan()`, renamed to avoid shadowing the
--     `planner` module local this file requires) just calls
--     pcall(planner.build) and reads .commands off the result -- no global
--     to hijack.
--   * ColourNote(colour, "", text) -> a local note(color, text) that calls
--     buffer.color_print(nil, color, "[Auto-Trade] " .. text), the same
--     shape as LEGACY's own note() closure (LEGACY:748-750) with the colour
--     name mapped to a hex string ("red" -> "FF4444") since buffer.color_print
--     takes nil/0-255/hex, not named colours.
--   * shared_state/shared_opts (LEGACY:742, read from
--     viking_autotrader_context()) -> require("state").S / page_opts
--     directly, same adaptation core.lua and plan.lua already use.
--   * plan_tick (LEGACY:741, `= viking_autotrader_plan`) -> the required
--     autotrader.plan module's M.build.
--   * M.config replaces at_config + vk_atrade_handler: LEGACY's alias
--     dispatch (`AddAlias("vk_atrade", ...)`, LEGACY:733-737) has no
--     equivalent here -- /vik trader <sub> (init.lua) calls M.config(rest)
--     directly, matching the plan brief's explicit mapping. ColourNote(...)
--     -> buffer.color_print(nil, "DAA520", text), the fixed color every
--     other /vik command reply in this plugin already uses (init.lua), not
--     LEGACY's per-message colour -- an established codebase convention,
--     not a new choice made here. OnPluginSaveState() -> persist.save().
--     `local string, table, ... = libs()` (LEGACY:670, a MUSHclient
--     sandbox-local-alias idiom) is dropped; those are ordinary globals
--     here. Every response STRING, including the literal word "atrade" in
--     the usage line (LEGACY's own alias name, now stale under /vik trader
--     but kept byte-for-byte per the plan's verbatim-string rule), is
--     unchanged.
--   * M.open_menu/menu_pick replace viking_show_atrade_menu/
--     viking_atrade_menu_pick: LEGACY's bespoke WindowCreate/AddHotspot
--     popup (11321-11351) becomes a require("menu") menu (13 items, LEGACY's
--     own id/label/val strings, in the same order); per-item tooltips and
--     colours have no equivalent in menu.lua's plain-label rows and are
--     dropped (content fidelity, not pixel fidelity -- same ruling this
--     plan's Global Constraints already applies elsewhere). Selecting an
--     item performs the exact same toggle/cycle LEGACY's pick handler did,
--     saves, then reopens the menu in place -- LEGACY did the same
--     (`viking_show_atrade_menu(mx, my)` at the tail of
--     viking_atrade_menu_pick, LEGACY:11377) so repeated adjustments stay
--     inside one menu session, just without needing a remembered window
--     position. Bare `/vik trader` (no subcommand) opens this menu --
--     LEGACY's own `atrade` alias with no argument just printed the status
--     summary (the menu was reachable only from a right-click page-context
--     item with no alias equivalent, guild_viking.lua:11222-11227); lera has
--     no such right-click page chrome (dropped in stage 2/3), and the task
--     brief assigns the bare form to the menu explicitly, so that mapping
--     wins here -- disclosed as the one deliberate behavior change in this
--     module, not a verbatim port of the empty-input case.
--
-- M.reset() is a TEST-ONLY convenience with no LEGACY counterpart: `sm` is
-- persistent module state (module-level, like LEGACY's own closure-captured
-- `sm`), so a test suite that drives several independent scenarios through
-- M.tick() needs a way to rewind it between them.
local S = require("state").S
local util = require("util")
local page_opts = require("page_opts")
local core = require("autotrader.core")
local planner = require("autotrader.plan")
local persist = require("persist")

local M = {}

-- LEGACY:746.
local COMMAND_DELAY, CONFIRM_TIMEOUT, FAILURE_COOLDOWN = 2, 20, 30

local sm = { phase = "idle", pending = {}, index = 1, next_at = 0, deadline = 0,
             baseline = "", last_error = "" }

-- LEGACY:748-750.
local function note(color, text)
  buffer.color_print(nil, color, "[Auto-Trade] " .. text)
end

-- LEGACY:751-761.
local function row_sig(row)
  local fields = {}
  for k, v in pairs(row or {}) do
    local volatile = k == "return_in" or k == "halfway_in"
    if not volatile and type(v) ~= "table" then
      fields[#fields + 1] = tostring(k) .. "=" .. tostring(v)
    end
  end
  table.sort(fields)
  return table.concat(fields, ",")
end

-- LEGACY:762-766.
local function list_sig(list)
  local rows = {}
  for _, row in ipairs(list or {}) do rows[#rows + 1] = row_sig(row) end
  table.sort(rows)
  return table.concat(rows, ";")
end

-- LEGACY:767-771.
local function mip_sig()
  return "C[" .. list_sig(S.carts) .. "]Q["
      .. list_sig(S.trade_queue) .. "]I["
      .. list_sig(S.idle_carts) .. "]"
end

-- LEGACY:772-787.
local function transactions(commands)
  local out, route = {}, nil
  for _, cmd in ipairs(commands) do
    if cmd:match("^vtrade%s+route%s+clear") then
      route = { cmd }
    elseif cmd:match("^vtrade%s+route%s+add%s+") or cmd:match("^vtrade%s+route%s+cart%s+") then
      if route then route[#route + 1] = cmd end
    elseif cmd:match("^vtrade%s+queue%s+add%s*$") then
      if route and #route > 1 then route[#route + 1] = cmd; out[#out + 1] = route end
      route = nil
    elseif cmd:match("^vtrade%s+dispatch%s+") then
      route = nil
      out[#out + 1] = { cmd }
    end
  end
  return out
end

-- LEGACY:788-792.
local function fail_closed(message, now)
  sm.last_error, sm.pending, sm.current = message, {}, nil
  sm.phase, sm.next_at = "cooldown", now + FAILURE_COOLDOWN
  note("FF4444", message .. "; paused without retrying the dispatch")
end

-- LEGACY:793-804 (local plan(), renamed do_plan -- see header).
--
-- `at.debug` (set by "atrade debug on", tick.lua's M.config) was previously
-- write-only: nothing anywhere read it, so the command's own promise --
-- "each idle tick will print why nothing was sent" -- never actually
-- happened. planner.build() already computes exactly that reason in
-- result.status; this was just never surfaced. Gated on `result` itself
-- (not merely on debug being on): planner.build() no-ops to nil under its
-- own AT_INTERVAL throttle, and do_plan() can be reached far more often
-- than that via M.tick()'s idle-phase check -- printing on every one of
-- those no-op calls would spam far faster than the "idle tick" framing
-- implies.
local function do_plan()
  local ok, result = pcall(planner.build)
  if not ok then
    fail_closed("planner failed: " .. tostring(result), os.time())
    return
  end
  if result and core.settings().debug then
    if result.status then
      note("888888", "idle tick: " .. result.status)
    elseif result.jobs and #result.jobs > 0 then
      local labels = {}
      for _, j in ipairs(result.jobs) do labels[#labels + 1] = j.label or "?" end
      note("888888", "idle tick: planned " .. #result.jobs .. " job(s): " .. table.concat(labels, "; "))
    else
      note("888888", "idle tick: nothing to report")
    end
  end
  local commands = (result and result.commands) or {}
  sm.pending = transactions(commands)
end

-- LEGACY:805-811.
local function begin_transaction(now)
  sm.current = table.remove(sm.pending, 1)
  if not sm.current then return false end
  sm.index = 1
  sm.phase, sm.next_at = "sending", now
  return true
end

-- LEGACY:812-845 (auto_trade_tick). See module header for the enumerated
-- gates.
function M.tick()
  local now = os.time()
  if not page_opts.get("auto_trade") then
    sm.pending, sm.current, sm.phase = {}, nil, "idle"
    return
  end
  if sm.phase == "confirming" then
    if mip_sig() ~= sm.baseline then
      sm.current, sm.phase, sm.next_at = nil, "idle", now + COMMAND_DELAY
    elseif now >= sm.deadline then
      fail_closed("no MIP confirmation within " .. CONFIRM_TIMEOUT .. "s", now)
    end
    return
  end
  if sm.phase == "cooldown" then
    if now < sm.next_at then return end
    sm.phase = "idle"
  end
  if sm.phase == "idle" then
    if now < sm.next_at then return end
    if #sm.pending == 0 then do_plan() end
    if #sm.pending == 0 or not begin_transaction(now) then return end
  end
  if sm.phase == "sending" and now >= sm.next_at then
    local cmd = sm.current and sm.current[sm.index]
    -- An empty string is truthy in Lua, so a `not cmd` test let a half-built
    -- command through to the MUD as a bare prompt line. A transaction that
    -- cannot name its own command is a planner bug, so fail closed rather than
    -- skipping the step and letting the rest of the transaction run.
    if type(cmd) ~= "string" or cmd:match("^%s*$") then
      fail_closed("invalid empty transaction", now); return
    end
    -- Baseline immediately before the terminal dispatch/queue command --
    -- earlier cart completions while building a route cannot confirm it.
    if sm.index == #sm.current then sm.baseline = mip_sig() end
    util.send(cmd, "autotrader")
    sm.index = sm.index + 1
    if sm.index > #sm.current then
      sm.phase, sm.deadline = "confirming", now + CONFIRM_TIMEOUT
    else
      sm.next_at = now + COMMAND_DELAY
    end
  end
end

-- LEGACY:846-848 (viking_autotrader_status). The 5th return value (next_at)
-- is a Task 9 addition with no LEGACY counterpart: the epoch second at which
-- the state machine will next do something on its own (sm.deadline while
-- confirming, sm.next_at otherwise) -- exposed so init.lua's /vik status and
-- pages/stats.lua's Automation section can report "next eligible" without
-- reaching into sm directly. Existing callers that only destructure the
-- first 1-4 values (every one before this task) are unaffected -- Lua
-- ignores a trailing return value nothing asks for.
function M.status()
  local next_at = (sm.phase == "confirming") and sm.deadline or sm.next_at
  return sm.phase, #sm.pending, sm.current and (sm.index - 1) or 0, sm.last_error, next_at
end

-- Test-only reset; see module header.
function M.reset()
  sm = { phase = "idle", pending = {}, index = 1, next_at = 0, deadline = 0,
         baseline = "", last_error = "" }
end

-- ---------------------------------------------------------------------------
-- Control surface: /vik trader <sub> (LEGACY:670-729, at_config +
-- vk_atrade_handler) and the settings menu (LEGACY guild_viking.lua:
-- 11266-11380). See module header for both adaptations.
-- ---------------------------------------------------------------------------

local function reply(text)
  buffer.color_print(nil, "DAA520", text)
end

-- LEGACY:670-724 (at_config).
function M.config(rest)
  local at = core.settings()
  rest = (rest or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if rest == "on" then
    page_opts.set("auto_trade", true); reply("[Auto-Trade] ON.")
  elseif rest == "off" then
    page_opts.set("auto_trade", false); reply("[Auto-Trade] OFF.")
  elseif rest == "stock on" then
    at.use_stock = true; reply("[Auto-Trade] use-stock ON.")
  elseif rest == "stock off" then
    at.use_stock = false; reply("[Auto-Trade] use-stock OFF.")
  elseif rest == "pack on" then
    at.pack = true; reply("[Auto-Trade] pack-per-cart ON.")
  elseif rest == "pack off" then
    at.pack = false; reply("[Auto-Trade] pack-per-cart OFF.")
  elseif rest == "debug on" then
    at.debug = true
    reply("[Auto-Trade] debug ON -- each idle tick will print why nothing was sent.")
  elseif rest == "debug off" then
    at.debug = false; reply("[Auto-Trade] debug OFF.")
  elseif rest == "stockroute on" then
    at.stock_route = true; reply("[Auto-Trade] batch stock sells ON (routes).")
  elseif rest == "stockroute off" then
    at.stock_route = false; reply("[Auto-Trade] batch stock sells OFF (dispatch).")
  elseif rest == "stockpriority on" then
    at.stock_priority = true
    reply("[Auto-Trade] stock priority ON (stock sells before arbitrage).")
  elseif rest == "stockpriority off" then
    at.stock_priority = false
    reply("[Auto-Trade] stock priority OFF (merge by profit).")
  elseif rest == "log" then
    if #at.log == 0 then
      reply("[Auto-Trade] log is empty.")
    else
      reply("[Auto-Trade] recent activity:")
      for _, e in ipairs(at.log) do
        if type(e) == "table" and e.jobs then
          local parts = {}
          for _, j in ipairs(e.jobs) do parts[#parts + 1] = j.label end
          reply("  " .. (e.t or "") .. " " .. table.concat(parts, "; "))
        else
          reply("  " .. tostring(e))
        end
      end
    end
    return
  elseif rest == "log clear" then
    at.log = {}; reply("[Auto-Trade] log cleared."); return
  else
    local key, val = rest:match("^(%a+)%s+(%d+)$")
    if key == "reserve" then at.reserve = tonumber(val)
    elseif key == "margin" then at.min_margin = tonumber(val)
    elseif key == "profit" then at.min_profit = tonumber(val)
    elseif key == "carts" then at.max_carts = tonumber(val)
    elseif key == "show" then at.show_n = tonumber(val)
    elseif key == "autostock" then at.auto_stock = tonumber(val)
    elseif rest == "autostock off" then at.auto_stock = 0
    elseif rest ~= "" and rest ~= "status" then
      reply("[Auto-Trade] usage: atrade on|off | stock on|off | stockpriority on|off | "
        .. "autostock <n>|off | pack on|off | debug on|off | reserve <n> | margin <n> | "
        .. "profit <n> | carts <n> | show <n> | log [clear]")
      return
    end
  end
  persist.save()
  reply(string.format(
    "[Auto-Trade] %s | reserve %d | margin %d/u | min-gain %dd | carts %d | pack %s | "
      .. "use-stock %s | auto-stock %s | stockprio %s",
    page_opts.get("auto_trade") and "ON" or "OFF", at.reserve, at.min_margin, at.min_profit or 0,
    at.max_carts, at.pack and "yes" or "no", at.use_stock and "yes" or "no",
    (at.auto_stock or 0) > 0 and (at.auto_stock .. "u") or "off",
    at.stock_priority ~= false and "stock1st" or "profit"))
end

-- LEGACY guild_viking.lua:11274-11279.
local AT_MARGIN_STEPS    = { 1, 2, 3, 5, 8, 10, 15, 20 }
local AT_PROFIT_STEPS    = { 0, 100, 200, 350, 500, 750, 1000, 2000 }
local AT_RESERVE_STEPS   = { 0, 100, 250, 500, 1000, 2500, 5000, 10000 }
local AT_CARTS_STEPS     = { 1, 2, 3, 4, 5, 6, 8 }
local AT_SHOWN_STEPS     = { 3, 6, 9, 12, 15 }
local AT_AUTOSTOCK_STEPS = { 0, 250, 500, 750, 1000, 1500, 2500 }

-- LEGACY guild_viking.lua:11267-11272 (at_cycle).
local function cycle(cur, list)
  for i, v in ipairs(list) do
    if v == cur then return list[(i % #list) + 1] end
  end
  return list[1]
end

-- LEGACY guild_viking.lua:11281-11319 (atrade_menu_build). Item order,
-- labels and values are verbatim; tooltips/colours dropped (menu.lua has no
-- per-row equivalent -- see module header).
local function menu_items()
  local at = core.settings()
  local on = page_opts.get("auto_trade")
  return {
    { label = "Auto-Trade: " .. (on and "ON" or "off"), value = "on" },
    { label = "Pack deals per cart: " .. (at.pack and "yes" or "no"), value = "pack" },
    { label = "Use warehouse stock: " .. (at.use_stock and "yes" or "no"), value = "stock" },
    { label = "Auto-stock over: " .. (((at.auto_stock or 0) > 0) and ((at.auto_stock) .. "u") or "off"),
      value = "autostock" },
    { label = "Batch stock sells: " .. (at.stock_route and "route" or "dispatch"), value = "stockroute" },
    { label = "Stock priority: " .. (at.stock_priority ~= false and "stock1st" or "profit"),
      value = "stockpriority" },
    { label = "Min margin (/u): >=" .. tostring(at.min_margin or 3), value = "margin" },
    { label = "Min gain per job: " .. tostring(at.min_profit or 0) .. "d", value = "profit" },
    { label = "Daler reserve: " .. tostring(at.reserve or 0), value = "reserve" },
    { label = "Max carts: " .. tostring(at.max_carts or 2), value = "carts" },
    { label = "Movers shown: " .. tostring(at.show_n or 6), value = "show_n" },
    { label = "Show log: " .. (page_opts.get("show_goods_atlog") and "yes" or "no"), value = "log" },
    { label = "Clear log", value = "clearlog" },
  }
end

-- LEGACY guild_viking.lua:11353-11380 (viking_atrade_menu_pick).
local function menu_pick(id)
  local at = core.settings()
  if id == "on" then page_opts.set("auto_trade", not page_opts.get("auto_trade"))
  elseif id == "pack" then at.pack = not at.pack
  elseif id == "stock" then at.use_stock = not at.use_stock
  elseif id == "stockroute" then at.stock_route = not at.stock_route
  elseif id == "stockpriority" then at.stock_priority = not at.stock_priority
  elseif id == "log" then page_opts.set("show_goods_atlog", not page_opts.get("show_goods_atlog"))
  elseif id == "margin" then at.min_margin = cycle(at.min_margin or 3, AT_MARGIN_STEPS)
  elseif id == "profit" then at.min_profit = cycle(at.min_profit or 0, AT_PROFIT_STEPS)
  elseif id == "reserve" then at.reserve = cycle(at.reserve or 0, AT_RESERVE_STEPS)
  elseif id == "carts" then at.max_carts = cycle(at.max_carts or 2, AT_CARTS_STEPS)
  elseif id == "show_n" then at.show_n = cycle(at.show_n or 6, AT_SHOWN_STEPS)
  elseif id == "autostock" then at.auto_stock = cycle(at.auto_stock or 0, AT_AUTOSTOCK_STEPS)
  elseif id == "clearlog" then at.log = {}
  end
  persist.save()
  -- Rebuild in place so the new value shows immediately -- LEGACY did the
  -- same (viking_show_atrade_menu(mx, my), LEGACY:11377).
  M.open_menu()
end

-- LEGACY guild_viking.lua:11321-11351 (viking_show_atrade_menu), opened by
-- bare `/vik trader` -- see module header for the bare-form adaptation.
function M.open_menu()
  require("menu").open({
    items = menu_items(),
    title = "Auto-Trade Settings",
    on_select = function(value) menu_pick(value) end,
  })
end

-- /vik trader <sub> dispatch (init.lua). Bare (rest == "") opens the menu;
-- anything else goes through M.config.
function M.trader_command(rest)
  rest = rest or ""
  if rest == "" then
    M.open_menu()
    return
  end
  M.config(rest)
end

return M
