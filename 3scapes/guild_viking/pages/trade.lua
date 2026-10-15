-- Trade page: the `mode ~= "city"` logistics block of LEGACY's
-- draw_page2(y, mode) (/home/simon/code/3s_scripts_old/lua/guild_viking.lua
-- :7833-8317). Pure builder: lines(width) -> array of ANSI strings, reading
-- state.lua's S and page_opts.lua only.
--
-- LOAD-BEARING SOURCE QUIRK (guild_viking.lua:7835-8248): Couriers, Spies,
-- Training, Lineage Heat, Reprisal Grudges and Trade Queue are all drawn
-- INSIDE the `if page_opts.show_city_carts then ... end` block -- there is
-- no `end` between the Carts section and any of them, and the block only
-- closes right before Market Orders. Each of those six sections keeps its
-- OWN opt gate too, but turning show_city_carts off hides all six as a side
-- effect, regardless of their individual opts. This is preserved faithfully
-- (see the task report); it is very likely an accidental over-broad `if` in
-- LEGACY rather than a deliberate design, but "the source wins" per the
-- plan's Global Constraints.
--
-- Market Orders and Incoming Fills share a single gate (show_city_market,
-- guild_viking.lua:8251-8315) with no separate opt for Incoming Fills.
local pagelib = require("pagelib")
local state = require("state")
local page_opts = require("page_opts")
local cc = require("pages.city_common")

local S = state.S
local C = pagelib.C

local M = {}

-- ---------------------------------------------------------------------------
-- Carts (+ idle carts, + cart upgrades) (guild_viking.lua:7834-8248,
-- gated show_city_carts)
-- ---------------------------------------------------------------------------

-- BGR decode workbook (guild_viking.lua:301, 0xBBGGRR -- leftmost byte =
-- Blue, middle = Green, rightmost = Red; same convention as pages/goods.lua's
-- commit 9b6b7b6 workbook and pages/army.lua's comment):
--   0xFF8844 (outbound cart arrow, player_sell arrow, below; Cartyard
--             cooldown, carts_lines)          -> R=44/G=88/B=FF -> blue.
--             pagelib.C has no true blue; nearest hue is the cyan family --
--             picked C.cyan (not bright_cyan: the literal's R/G bytes are
--             mid-range, not maxed, so the dimmer cyan reads closer).
--   0x00CCCC (cart_upgrade_row label, below)  -> R=CC/G=CC/B=00 -> yellow
--   0x66CCFF (sabotage countdown, spies_lines) -> R=FF/G=CC/B=66 -> gold,
--             mapped to yellow (nearest pagelib.C hue)
--   0x88CCEE (training countdown, training_lines) -> R=EE/G=CC/B=88 -> tan,
--             mapped to yellow (nearest pagelib.C hue)
--   0xFFCC00 (sell-mode arrow, trade_queue_lines) -> R=00/G=CC/B=FF ->
--             cyan-blue, mapped to C.cyan
-- Each was previously mapped by variable-name guess (yellow/cyan/bright_cyan)
-- rather than decoded; corrected below.
local function cart_arrow(ct)
  local outbound = ct.halfway_in and ct.halfway_in > 0
  if ct.mode == "buy" then
    return outbound and ">>" or "<<", outbound and C.green or C.white
  elseif ct.mode == "player_sell" then
    return ">>", C.cyan
  else
    return outbound and ">>" or "<<", outbound and C.cyan or C.white
  end
end

local function cart_row(width, ct)
  local arrow, acolor = cart_arrow(ct)
  local quality = ""
  if ct.mode == "sell" and ct.quality_pct and cc.is_perishable(ct.good) then
    local show = (ct.good == "mead") or (ct.quality_pct < 100)
    if show then
      local label, qcolor = cc.quality_label(ct.good, ct.quality_pct)
      quality = string.format("  %s[%s %d%%]%s", qcolor, label, ct.quality_pct, pagelib.RESET)
    end
  end
  local cd = cc.fmt_time(ct.return_in)
  local cd_color = ((ct.return_in or 0) <= 0) and C.bright_green or C.white
  return pagelib.trunc(string.format("Cart #%-3d: %s%s%s %5dx %s%-12s%s %-14s%s %s%s%s",
    ct.cart_id or 0, acolor, arrow, pagelib.RESET, ct.amount or 0,
    cc.good_color(ct.good), cc.good_label(ct.good), pagelib.RESET,
    ct.village or "", quality, cd_color, cd, pagelib.RESET), width)
end

local function cart_sub_row(width, ct)
  local tname = cc.CART_TIER_NAMES[ct.tier] or "Basic"
  local tcolor = cc.cart_tier_color(ct.tier)
  local dur = ct.durability or 100
  local parts = { string.format("  %s%-10s%s %3d%%", tcolor, tname, pagelib.RESET, dur) }
  local refit = ct.refit or "standard"
  if refit ~= "standard" then
    parts[#parts + 1] = "[" .. cc.cart_refit_label(refit) .. "]"
  end
  if ct.cap and ct.cap > 0 then
    parts[#parts + 1] = "Cap:" .. ct.cap
  end
  if ct.escort and ct.escort > 0 then
    parts[#parts + 1] = ct.escort .. " escort" .. ((ct.escort ~= 1) and "s" or "")
  end
  return pagelib.trunc(table.concat(parts, "  "), width)
end

local function idle_cart_row(width, ic)
  local tname = cc.CART_TIER_NAMES[ic.tier] or "Basic"
  local tcolor = cc.cart_tier_color(ic.tier)
  local dur = ic.durability or 100
  local refit = ic.refit or "standard"
  local refit_txt = (refit ~= "standard") and (" [" .. cc.cart_refit_label(refit) .. "]") or ""
  local status = (dur <= 0) and "destroyed" or "available"
  local status_color = (dur <= 0) and C.red or C.bright_green
  local row = string.format("Cart #%d: %s%s%s%s  %d%%  %s%s%s",
    ic.cart_id or 0, tcolor, tname, refit_txt, pagelib.RESET, dur,
    status_color, status, pagelib.RESET)
  if ic.cap and ic.cap > 0 then
    row = row .. "  Cap:" .. ic.cap
  end
  return pagelib.trunc(row, width)
end

local CART_UPGRADE_TIER_NAMES = { [2] = "Reinforced", [3] = "Heavy", [4] = "Armored", [5] = "War-cart" }

local function cart_upgrade_row(width, cu)
  local label
  if cu.job_type == "refit" and (cu.target_refit or "") ~= "" then
    label = string.format("Cart #%d -> %s refit", cu.cart_id, cc.cart_refit_label(cu.target_refit))
  elseif cu.job_type == "rebuild" then
    label = string.format("Cart #%d -> rebuild %s", cu.cart_id,
      CART_UPGRADE_TIER_NAMES[cu.target_tier] or ("T" .. tostring(cu.target_tier)))
  else
    label = string.format("Cart #%d -> %s", cu.cart_id,
      CART_UPGRADE_TIER_NAMES[cu.target_tier] or ("T" .. tostring(cu.target_tier)))
  end
  local status
  if (cu.secs_left or -1) < 0 then
    status = ((cu.mats_total or 0) > 0)
      and string.format("Mats %d/%d", cu.mats_done or 0, cu.mats_total or 0)
      or "Awaiting mats"
  elseif cu.secs_left == 0 then
    status = "Finalizing..."
  else
    status = cc.fmt_time(cu.secs_left)
  end
  return pagelib.trunc(string.format("%s%s%s  %s", C.yellow, label, pagelib.RESET, status), width)
end

local function mat_row(width, mg)
  local color = cc.mat_color(mg.done or 0, mg.need or 1)
  return pagelib.trunc(string.format("  %s%-12s%s %d/%d %s",
    cc.good_color(mg.good), cc.good_label(mg.good), pagelib.RESET,
    mg.done or 0, mg.need or 0, pagelib.bar(12, mg.done or 0, mg.need or 1, color)), width)
end

local function carts_lines(add, width)
  add(pagelib.header(width, "Carts"))
  local cd = S.dispatch_cd or 0
  add(pagelib.kv(width, "Cartyard:", (cd > 0) and cc.fmt_time(cd) or "ready",
    (cd > 0) and C.cyan or C.bright_green))

  if not S.carts or #S.carts == 0 then
    add(pagelib.trunc(C.dim .. "No carts" .. pagelib.RESET, width))
  else
    for _, ct in ipairs(S.carts) do
      add(cart_row(width, ct))
      add(cart_sub_row(width, ct))
      if ct.mode == "route" and ct.legs and #ct.legs > 0 then
        add(pagelib.trunc(C.dim .. "Route stops:" .. pagelib.RESET, width))
        for idx, leg in ipairs(ct.legs) do
          local larrow = (leg.mode == "buy") and "<<" or ">>"
          add(pagelib.trunc(string.format("  %d %s %dx %s -> %s",
            idx, larrow, leg.amount or 0, cc.good_label(leg.good), leg.village or ""), width))
        end
      end
    end
  end

  if S.idle_carts and #S.idle_carts > 0 then
    for _, ic in ipairs(S.idle_carts) do
      add(idle_cart_row(width, ic))
    end
  end

  if S.cart_upgrades and #S.cart_upgrades > 0 then
    for _, cu in ipairs(S.cart_upgrades) do
      add(cart_upgrade_row(width, cu))
      if cu.mats and #cu.mats > 0 then
        for _, mg in ipairs(cu.mats) do
          add(mat_row(width, mg))
        end
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Couriers (guild_viking.lua:8106-8131) -- nested inside show_city_carts,
-- see module comment above.
-- ---------------------------------------------------------------------------

local function couriers_lines(add, width)
  add(pagelib.header(width, "Couriers"))
  if #(S.courier.runs or {}) == 0 then
    add(pagelib.trunc(C.dim .. "No runner out" .. pagelib.RESET, width))
    return
  end
  for _, rn in ipairs(S.courier.runs) do
    local cd = cc.fmt_time(rn.return_in)
    local cd_color = ((rn.return_in or 0) <= 0) and C.bright_green or C.white
    if rn.gift then
      -- A gift runs outbound: "gift 10 Grain -> Birka  +10 rep  4m".
      local what = (rn.good == "daler") and (C.yellow .. "daler" .. pagelib.RESET)
        or (cc.good_color(rn.good) .. cc.good_label(rn.good) .. pagelib.RESET)
      add(pagelib.trunc(string.format("gift %d %s -> %s  %s+%d rep%s  %s%s%s",
        rn.amount or 0, what, rn.village or "?", C.bright_green, rn.rep or 0, pagelib.RESET,
        cd_color, cd, pagelib.RESET), width))
    else
      add(pagelib.trunc(string.format(">> %dx %s%-12s%s %-14s %s%s%s",
        rn.amount or 0, cc.good_color(rn.good), cc.good_label(rn.good), pagelib.RESET,
        rn.village or "?", cd_color, cd, pagelib.RESET), width))
    end
  end
end

-- ---------------------------------------------------------------------------
-- Spies (Shadow-House) (guild_viking.lua:8132-8173) -- nested, see above.
-- ---------------------------------------------------------------------------

local function spies_lines(add, width)
  add(pagelib.header(width, "Spies"))
  local shown = false
  if S.spy.mode ~= "" then
    shown = true
    add(pagelib.kv(width, cc.cap_first(S.spy.mode) .. " -> " .. S.spy.village .. ":",
      cc.fmt_time(S.spy.secs), C.white))
  end
  if (S.spy.sab_pct or 0) > 0 then
    shown = true
    add(pagelib.kv(width, string.format("Sabotage +%d%% raids:", S.spy.sab_pct),
      cc.fmt_time(S.spy.sab_secs), C.yellow))
  end
  for _, s in ipairs(S.spy.scouts or {}) do
    shown = true
    add(pagelib.kv(width, string.format("Scouted %s (-%d%% ambush):", s.city, s.amb),
      cc.fmt_time(s.secs), C.green))
  end
  if (S.spy.cd_secs or 0) > 0 and S.spy.mode == "" then
    shown = true
    add(pagelib.kv(width, "Agents lying low:", cc.fmt_time(S.spy.cd_secs), C.white))
  end
  if not shown then
    add(pagelib.trunc(C.dim .. "No agent afoot" .. pagelib.RESET, width))
  end
end

-- ---------------------------------------------------------------------------
-- Training (Training Yard) (guild_viking.lua:8174-8189) -- nested, see above.
-- ---------------------------------------------------------------------------

local function training_lines(add, width)
  add(pagelib.header(width, "Training"))
  if S.train.name ~= "" then
    local st = cc.cap_first(S.train.stat)
    add(pagelib.kv(width, string.format("%s: %s %d/3", S.train.name, st, S.train.trained or 0),
      cc.fmt_time(S.train.secs), C.yellow))
  else
    add(pagelib.trunc(C.dim .. "No one training" .. pagelib.RESET, width))
  end
end

-- ---------------------------------------------------------------------------
-- Lineage Heat + Reprisal Grudges (guild_viking.lua:8190-8226) -- both
-- gated show_city_heat, nested, see above.
-- ---------------------------------------------------------------------------

local HEAT_CITY = { "Hold", "Eiriksby", "Imaird", "Holmgard", "Hafrfjord",
  "Uppsala", "Borgarfjord", "Vestergotland", "Sverkersby", "Ericsgard",
  "Birka", "Lejre", "Nidaros" }

local function heat_lines(add, width)
  add(pagelib.header(width, "Lineage Heat"))
  for i, h in ipairs(S.heat) do
    local color = (h >= 66) and C.red or ((h >= 33) and C.yellow or C.green)
    add(pagelib.trunc(string.format("%-14s %s", HEAT_CITY[i] or ("#" .. i),
      pagelib.bar(20, h, 100, color)), width))
  end
end

local function grudges_lines(add, width)
  add(pagelib.header(width, "Reprisal Grudges"))
  for _, g in ipairs(S.grudges) do
    add(pagelib.kv(width, g.town .. " reprisal risk:",
      "fades in " .. cc.fmt_time(g.secs or 0), C.red))
  end
end

-- ---------------------------------------------------------------------------
-- Trade Queue (guild_viking.lua:8227-8242) -- NO page_opts gate at all;
-- unconditional on state.trade_queue being non-empty. Nested, see above.
-- ---------------------------------------------------------------------------

local function trade_queue_lines(add, width)
  add(pagelib.header(width, "Trade Queue"))
  for _, tq in ipairs(S.trade_queue) do
    local arrow = (tq.mode == "buy") and "<<" or ">>"
    local acolor = (tq.mode == "buy") and C.green or C.cyan
    local esc = ((tq.escort or 0) > 0)
      and string.format("  [%d escort%s]", tq.escort, (tq.escort ~= 1) and "s" or "") or ""
    add(pagelib.trunc(string.format("%s%s%s %dx %s%s%s %s%s",
      acolor, arrow, pagelib.RESET, tq.amount or 0,
      cc.good_color(tq.good), cc.good_label(tq.good), pagelib.RESET,
      tq.village or "", esc), width))
  end
end

-- ---------------------------------------------------------------------------
-- Market Orders + Incoming Fills (guild_viking.lua:8250-8315, shared gate
-- show_city_market)
-- ---------------------------------------------------------------------------

local function market_lines(add, width)
  add(pagelib.header(width, "Market Orders"))
  if not S.market_orders or #S.market_orders == 0 then
    add(pagelib.trunc(C.dim .. "No open orders" .. pagelib.RESET, width))
  else
    for _, mo in ipairs(S.market_orders) do
      add(pagelib.trunc(string.format("%s  %s%s%s  Need:%d Price:%d/ea",
        cc.cap_first(mo.buyer), cc.good_color(mo.good), cc.cap_first(mo.good), pagelib.RESET,
        mo.remaining or 0, mo.price or 0), width))
    end
  end

  add(pagelib.header(width, "Incoming Fills"))
  if not S.incoming_fills or #S.incoming_fills == 0 then
    add(pagelib.trunc(C.dim .. "None incoming" .. pagelib.RESET, width))
  else
    for _, ic in ipairs(S.incoming_fills) do
      local eta = cc.fmt_time(ic.arrives_in)
      local eta_color = ((ic.arrives_in or 0) <= 0) and C.bright_green or C.white
      add(pagelib.trunc(string.format(">> %dx %s%s%s from %s  %s%s%s",
        ic.amount or 0, cc.good_color(ic.good), cc.cap_first(ic.good), pagelib.RESET,
        cc.cap_first(ic.seller), eta_color, eta, pagelib.RESET), width))
    end
  end
end

function M.lines(width)
  width = width or 80
  local lines = {}
  local function add(s) lines[#lines + 1] = s end

  -- LOAD-BEARING: guild_viking.lua:7835-8248 nests Couriers/Spies/Training/
  -- Heat/Grudges/Trade Queue inside this SAME `if`. See module comment.
  if page_opts.get("show_city_carts") then
    carts_lines(add, width)

    if page_opts.get("show_city_couriers") and S.courier
        and ((S.courier.tier or 0) > 0 or #(S.courier.runs or {}) > 0) then
      couriers_lines(add, width)
    end

    if page_opts.get("show_city_spies") and S.spy and (S.spy.tier or 0) > 0 then
      spies_lines(add, width)
    end

    if page_opts.get("show_city_training") and S.train and (S.train.tier or 0) > 0 then
      training_lines(add, width)
    end

    if page_opts.get("show_city_heat") and S.heat and #S.heat > 0 then
      heat_lines(add, width)
    end

    if page_opts.get("show_city_heat") and S.grudges and #S.grudges > 0 then
      grudges_lines(add, width)
    end

    if S.trade_queue and #S.trade_queue > 0 then
      trade_queue_lines(add, width)
    end
  end

  if page_opts.get("show_city_market") then
    market_lines(add, width)
  end

  return lines
end

return M
