-- Push notifications + per-second countdown for guild_viking.
--
-- Trigger patterns are ported verbatim from guild_viking.xml:76-164; bodies
-- from LEGACY guild_viking.lua:777-849 (the two-pattern `push_recruit_found`
-- and the `voyage_pause_message` -> `push_voyage_pause` split are collapsed
-- into single functions here, matching the interpolation each performed).
-- countdown_tick is ported from LEGACY guild_viking.lua:2701-2891: every
-- return_in-style field it decremented is preserved here with the same
-- clamp/removal semantics. LEGACY's per-field/per-block `dirty` flag (which
-- also gated a `viking_window.update()` call) is collapsed into a single
-- `ui.dirty()` fired once per tick, only when something actually changed --
-- window repaint arrives in stage 2, and an idle tick (nothing counting
-- down) must stay cheap.
--
-- The trailing `auto_trade_tick`/`auto_raid_tick`/`auto_voyage_tick` calls at
-- LEGACY 2885-2890 run in that exact order, AFTER the dirty check (LEGACY's
-- own viking_window.update() call sits between the countdown work and the
-- three ticks). Stage 4 Task 3 wired the first of the three
-- (autotrader/tick.lua's M.tick); Task 7 wired the third (autovoyage.lua's
-- M.tick); Task 8 (this change) inserts the second (autoraid.lua's M.tick)
-- BETWEEN them, so the order is now trade, raid, voyage -- LEGACY's own.
--
-- CITATION CORRECTION (husbandry plan, Task 4): the "LEGACY 2885-2890" above
-- is wrong. LEGACY's auto-module tick tail is guild_viking.lua:3232-3240
-- (`grep -n "auto_herd_tick" guild_viking.lua` -> 3240; 2885-2890 is inside
-- the MIP VFIND auction decoder). That real site runs FIVE ticks in the
-- order trade, raid, voyage, vfind, herd. Husbandry Task 4 (this change)
-- appends the fifth, autoherd.lua's M.tick, LAST -- this plugin has no
-- auto-vfind, so herd simply follows voyage. Auto-Herd is OFF by default
-- (page_opts' auto_herd = false) and its own first line re-checks that gate,
-- so adding this call sends nothing until a user opts in.
local S = require("state").S
-- The five automation modules ship only in the private plugin repo; see
-- util.optional_require. Each is nil in the public base, and every call site
-- below branches on that.
local optional_require = require("util").optional_require
local autotrade_tick = optional_require("autotrader.tick")
local autoraid = optional_require("autoraid")
local autovoyage = optional_require("autovoyage")
local autoherd = optional_require("autoherd")
local autowar = optional_require("autowar")
local autoroster = optional_require("autoroster")
local autocourt = optional_require("autocourt")

local M = {}

local pushn = nil

function M.set_push(p)
  pushn = p
end

local function notify(message)
  if pushn then
    pushn.notify("viking", message)
  end
end

-- ---------------------------------------------------------------------------
-- Push notification trigger bodies.
-- ---------------------------------------------------------------------------

local function push_cart_return(line)
  notify("Cart returned from trade route.")
end

local function push_longship_return(line)
  notify("Longship returned from island with thralls.")
end

local function push_longship_saved(line)
  notify("Longship saved by Iron Hull perk.")
end

local function push_longship_tattoo(line)
  notify("Longship returned with tattoo pattern.")
end

local function push_longship_thralls(line)
  notify("Longship returned with thralls.")
end

local function push_voyage_node(line, c1)
  local node_type = c1 or "node"
  notify("Voyage: " .. node_type .. " reached - resolve needed.")
end

-- LEGACY split this into a trigger body (voyage_pause_message) that captured
-- the remainder of the line and forwarded it as wildcards[1] to
-- push_voyage_pause, which built the message. Collapsed here since there is
-- only one trigger for it.
local function push_voyage_pause(line, c1)
  local message = c1 or "Voyage paused"
  notify("Voyage: " .. message)
end

local function push_raid_return(line)
  notify("Raid returned with spoils.")
end

local function push_town_captured(line, c1)
  local town = c1 or "A town"
  notify("War: " .. town .. " has fallen to your rule!")
end

local function push_war_declared(line, c1)
  local who = c1 or "A rival"
  notify("War: " .. who .. " marches on your realm -- answer or sue for peace.")
end

local function push_realm_sacked(line)
  notify("War: your holdings were sacked -- you left an incoming war unanswered.")
end

local function push_battle_lost(line)
  notify("Battle: your host was defeated.")
end

-- Shared by both recruit-found patterns (live posting and the "waited while
-- away" variant) -- LEGACY routes both to one body with one message.
local function push_recruit_found(line)
  notify("Kaupstefna: a specialist wanderer is available to hire (vfind).")
end

-- A master specialist at court (server set.h tick_specialist_offer()): the
-- offer waits about five days, so say so now rather than let it scroll by.
local function push_court_specialist(line)
  notify("Court: a master specialist offers to star a building (vbuild specialist).")
end

-- One day before a standing offer leaves (handlers/city.lua write_court()).
function M.court_reminder(o)
  local label = tostring(o.bldg or "a building"):gsub("_", " ")
  notify(string.format("Court: %s leaves within a day; the %d-star %s offer ends "
    .. "(vbuild specialist).", tostring(o.name or "the specialist"), o.to or 1, label))
end

local function push_relic_found(line)
  notify("Voyage: a rare relic was recovered!")
end

M.triggers = {
  { name = "push_court_specialist", pattern = "to hear their price",
    fn = push_court_specialist },
  { name = "push_cart_return",      pattern = "Cart returned from",
    fn = push_cart_return },
  { name = "push_longship_return",  pattern = "(?:The longship returned from the island|The longship docks safely and the secured voyage spoils are brought home)",
    fn = push_longship_return },
  { name = "push_longship_saved",   pattern = "was saved from the deep by the Iron Hull perk",
    fn = push_longship_saved },
  { name = "push_longship_tattoo",  pattern = "returned with a foreign tattoo pattern",
    fn = push_longship_tattoo },
  { name = "push_longship_thralls", pattern = "returned.*thrall",
    fn = push_longship_thralls },
  { name = "push_voyage_node",
    pattern = "(?:A|An) ((?:harbor|hidden harbor|island|wreck|great discovery|unknown site)) rises off",
    fn = push_voyage_node },
  { name = "push_voyage_pause",     pattern = "^\\[Viking-Voyage\\] (.*)$",
    fn = push_voyage_pause },
  { name = "push_raid_return",      pattern = "returned from .+ with",
    fn = push_raid_return },
  { name = "push_town_captured",    pattern = "(\\S+) falls! The town is taken",
    fn = push_town_captured },
  { name = "push_war_declared",     pattern = "(\\S+) declares war and gathers a host",
    fn = push_war_declared },
  { name = "push_realm_sacked",     pattern = "sacks your holdings",
    fn = push_realm_sacked },
  { name = "push_battle_lost",      pattern = "(?:\\] )?Defeat\\. Your",
    fn = push_battle_lost },
  { name = "push_recruit_found",    pattern = "is looking for a hall to serve",
    fn = push_recruit_found },
  { name = "push_recruit_found_2",  pattern = "came seeking a hall",
    fn = push_recruit_found },
  { name = "push_relic_found",      pattern = "A relic is (hauled|taken|drawn)",
    fn = push_relic_found },
}

-- ---------------------------------------------------------------------------
-- Per-second countdown. LEGACY guild_viking.lua:2701-2891.
-- ---------------------------------------------------------------------------

-- Removes array entries that fail keep_fn, in place, preserving order.
-- Returns true if any entry was removed.
local function prune(arr, keep_fn)
  local n, kept = #arr, 0
  for i = 1, n do
    local e = arr[i]
    if keep_fn(e) then
      kept = kept + 1
      arr[kept] = e
    end
  end
  for i = n, kept + 1, -1 do arr[i] = nil end
  return kept ~= n
end

function M.countdown_tick()
  local dirty = false

  -- Carts: decrement while return_in > 1; drop entries that would land at
  -- or under 1 (a cart "arrives" without ever visibly showing 1).
  if #S.carts > 0 then
    for _, ct in ipairs(S.carts) do
      if ct.return_in > 1 then
        ct.return_in = ct.return_in - 1
        if ct.halfway_in and ct.halfway_in > 0 then
          ct.halfway_in = ct.halfway_in - 1
        end
        dirty = true
      end
    end
    if prune(S.carts, function(ct) return ct.return_in > 1 end) then dirty = true end
  end

  -- Courier runs: same shape as carts.
  if S.courier and #(S.courier.runs or {}) > 0 then
    for _, rn in ipairs(S.courier.runs) do
      if rn.return_in > 1 then
        rn.return_in = rn.return_in - 1
        dirty = true
      end
    end
    if prune(S.courier.runs, function(rn) return rn.return_in > 1 end) then dirty = true end
  end

  -- Spy (Shadow-House): secs and cd_secs floor at 0; sab_secs floors at 0
  -- and clears sab_pct when it does; scouts decrement/drop like carts.
  if S.spy then
    if S.spy.secs and S.spy.secs > 1 then
      S.spy.secs = S.spy.secs - 1
      dirty = true
    elseif S.spy.secs == 1 then
      S.spy.secs = 0
      dirty = true
    end
    if S.spy.sab_secs and S.spy.sab_secs > 0 then
      S.spy.sab_secs = S.spy.sab_secs - 1
      if S.spy.sab_secs <= 0 then S.spy.sab_pct = 0 end
      dirty = true
    end
    if S.spy.cd_secs and S.spy.cd_secs > 0 then
      S.spy.cd_secs = S.spy.cd_secs - 1
      dirty = true
    end
    if S.spy.scouts and #S.spy.scouts > 0 then
      for _, s in ipairs(S.spy.scouts) do
        if s.secs > 1 then s.secs = s.secs - 1 end
      end
      if prune(S.spy.scouts, function(s) return s.secs > 1 end) then dirty = true end
    end
  end

  -- Training: decrements while secs > 1; sticks at 1 (never reaches 0 via
  -- this tick -- completion comes from a server update).
  if S.train and S.train.name ~= "" and S.train.secs and S.train.secs > 1 then
    S.train.secs = S.train.secs - 1
    dirty = true
  end

  -- Cart upgrades: decrement while > 0, keep every entry (gathering-mode
  -- rows included) -- no removal here.
  for _, cu in ipairs(S.cart_upgrades) do
    if cu.secs_left and cu.secs_left > 0 then
      cu.secs_left = cu.secs_left - 1
      dirty = true
    end
  end

  -- Incoming fills: decrement while arrives_in > 1; drop at/under 1.
  if #S.incoming_fills > 0 then
    for _, ic in ipairs(S.incoming_fills) do
      if ic.arrives_in > 1 then
        ic.arrives_in = ic.arrives_in - 1
        dirty = true
      end
    end
    if prune(S.incoming_fills, function(ic) return ic.arrives_in > 1 end) then dirty = true end
  end

  -- Trade/stock production tick countdown: floors at 0.
  if S.next_tick_in and S.next_tick_in > 0 then
    S.next_tick_in = S.next_tick_in - 1
    dirty = true
  end

  -- God-power reset: recomputed from an absolute target when one is known
  -- (keeps ticking smoothly across irregular MIP updates); otherwise a
  -- plain per-second decrement floored at 0.
  if S.god_power_next_at and S.god_power_next_at > 0 then
    local left = S.god_power_next_at - os.time()
    if left < 0 then left = 0 end
    if S.god_power_next ~= left then
      S.god_power_next = left
      dirty = true
    end
  elseif S.god_power_next and S.god_power_next > 0 then
    S.god_power_next = S.god_power_next - 1
    dirty = true
  end

  -- Demand cycle: floors at 0.
  if S.demand_cycle_in and S.demand_cycle_in > 0 then
    S.demand_cycle_in = S.demand_cycle_in - 1
    dirty = true
  end

  -- Cartwright's Cadence cooldown: absolute-time recompute, like god-power.
  if S.dispatch_cd_expires_at and S.dispatch_cd_expires_at > 0 then
    local left = S.dispatch_cd_expires_at - os.time()
    if left < 0 then left = 0 end
    if S.dispatch_cd ~= left then
      S.dispatch_cd = left
      dirty = true
    end
  end

  -- Ships: decrement while > 0, keep all (docked at 0 is a valid state) --
  -- no removal here.
  for _, sh in ipairs(S.ships) do
    if sh.return_in and sh.return_in > 0 then
      sh.return_in = sh.return_in - 1
      dirty = true
    end
  end
  -- Voyage longships (the primary display source): same as ships.
  if S.voyage_longships then
    for _, sh in ipairs(S.voyage_longships) do
      if sh.return_in and sh.return_in > 0 then
        sh.return_in = sh.return_in - 1
        dirty = true
      end
    end
  end

  -- Active voyage countdown shown on the Sea tab.
  if S.voyage_status and S.voyage_status.next_move and S.voyage_status.next_move > 0 then
    S.voyage_status.next_move = S.voyage_status.next_move - 1
    dirty = true
  end

  -- Pending builds: decrement while complete_at_secs > 0; drop only when it
  -- lands exactly on 0. nil (unknown) and negative (the -1 "awaiting mats"
  -- sentinel) are kept untouched.
  if #S.pending_builds > 0 then
    for _, pb in ipairs(S.pending_builds) do
      if pb.complete_at_secs and pb.complete_at_secs > 0 then
        pb.complete_at_secs = pb.complete_at_secs - 1
        dirty = true
      end
    end
    if prune(S.pending_builds, function(pb)
      return pb.complete_at_secs == nil or pb.complete_at_secs > 0 or pb.complete_at_secs < 0
    end) then dirty = true end
  end

  -- Route builds (roads/forts): decrement while > 0; remove the instant it
  -- reaches <= 0. An entry already at or under 0 is left alone -- LEGACY
  -- gates both the decrement and the removal on the same > 0 check.
  if S.route_builds and next(S.route_builds) ~= nil then
    for rk, rb in pairs(S.route_builds) do
      if rb.complete_at_secs and rb.complete_at_secs > 0 then
        rb.complete_at_secs = rb.complete_at_secs - 1
        dirty = true
        if rb.complete_at_secs <= 0 then
          S.route_builds[rk] = nil
        end
      end
    end
  end

  -- Ship upgrades: decrement while > 0, keep all (even gathering-mode).
  for _, su in ipairs(S.ship_upgrades) do
    if su.secs_left and su.secs_left > 0 then
      su.secs_left = su.secs_left - 1
      dirty = true
    end
  end

  -- Settler projects: decrement while > 0, keep all (even gathering-mode).
  for _, pr in ipairs(S.settler_projects) do
    if pr.secs_left and pr.secs_left > 0 then
      pr.secs_left = pr.secs_left - 1
      dirty = true
    end
  end

  if dirty then
    ui.dirty()
  end

  -- LEGACY guild_viking.lua:3232-3240 (trade, raid, voyage, vfind, herd
  -- order; the older "2885-2890" citation is corrected in this function's
  -- header). No auto-vfind in this plugin, so herd follows voyage.
  if autotrade_tick then autotrade_tick.tick() end
  if autoraid then autoraid.tick() end
  if autovoyage then autovoyage.tick() end
  if autoherd then autoherd.tick() end
  if autowar then autowar.tick() end
  if autoroster then autoroster.tick() end
  if autocourt then autocourt.tick() end
end

return M
