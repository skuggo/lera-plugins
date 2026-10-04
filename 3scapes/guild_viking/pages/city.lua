-- City page: the `mode ~= "trade"` branches of LEGACY's draw_page2(y, mode)
-- (/home/simon/code/3s_scripts_old/lua/guild_viking.lua:7573-9114). Pure
-- builder: lines(width) -> array of ANSI strings, reading state.lua's S and
-- page_opts.lua only.
--
-- LEGACY's draw_page2 is three sibling `if mode ~= ...` blocks: a
-- "settlement-before" block (Daler/Active God/Longships/Raids), a
-- "logistics" block (Carts and everything nested under it -- see
-- pages/trade.lua), and a "settlement-after" block (Warehouse/Production/
-- Buildings/Trade Routes/Runic Monuments/City Plan). This page renders the
-- first and third blocks, in source order; pages/trade.lua renders the
-- second. See the task report for the full section/gate/field table and the
-- discrepancies found versus the task brief's landmark list (several
-- sections the brief called "city" turned out to be nested in the trade
-- block instead, and vice versa is NOT the case -- the source wins).
--
-- EXCLUDED by the task: the City Plan interior-layout grid
-- (guild_viking.lua:8759-9108, anchor `section_header("City Plan"...)`
-- ~8761) -- replaced with a one-line placeholder, gated the same as LEGACY
-- (show_city_plan).
local pagelib = require("pagelib")
local state = require("state")
local page_opts = require("page_opts")
local cc = require("pages.city_common")
-- Private-repo module; nil in the public base (see util.optional_require).
local autoraid = require("util").optional_require("autoraid")

local S = state.S
local C = pagelib.C

local M = {}

-- ---------------------------------------------------------------------------
-- Longships (guild_viking.lua:7626-7762, gated show_city_ships)
-- ---------------------------------------------------------------------------

-- Merge state.voyage_longships (primary source: has ship_id + more detail)
-- with state.ships (supplies convoy/durability/state/return_in when the
-- voyage feed is stale or absent), same dedup-by-name logic as LEGACY
-- (guild_viking.lua:7629-7677).
local function merged_ships()
  local by_id, order = {}, {}
  for _, sh in ipairs(S.voyage_longships or {}) do
    local sid = sh.ship_id or ("name:" .. (sh.name or "unknown"))
    if not by_id[sid] then order[#order + 1] = sid end
    by_id[sid] = sh
  end
  for _, sh in ipairs(S.ships or {}) do
    local name = sh.name or "unknown"
    local found_sid
    for sid, vsh in pairs(by_id) do
      if vsh.name == name then found_sid = sid break end
    end
    if found_sid then
      local vsh = by_id[found_sid]
      if sh.convoy and sh.convoy ~= 0 and (not vsh.convoy or vsh.convoy == 0) then
        vsh.convoy, vsh.convoy_size, vsh.convoy_bonus = sh.convoy, sh.convoy_size, sh.convoy_bonus
      end
      vsh.durability = sh.durability
      if sh.state and sh.state ~= "" then vsh.state = sh.state end
      if sh.return_in then vsh.return_in = sh.return_in end
    else
      local sid = "name:" .. name
      if not by_id[sid] then order[#order + 1] = sid end
      by_id[sid] = sh
    end
  end
  local out = {}
  for _, sid in ipairs(order) do out[#out + 1] = by_id[sid] end
  return out
end

-- BGR decode workbook (guild_viking.lua:301, 0xBBGGRR -- leftmost byte =
-- Blue, middle = Green, rightmost = Red; same convention as pages/goods.lua's
-- commit 9b6b7b6 workbook and pages/army.lua's comment):
--   0x00CCCC (building/upgrading ship state, below; Daler and Active God
--             "In Power"/"Resets In", further down)      -> R=CC/G=CC/B=00
--             -> yellow
--   0x0099FF (repairing ship state, below)                -> R=FF/G=99/B=00
--             -> orange, folded to red (pagelib.pct_color's own orange-tier
--             precedent)
--   0x00AAFF (partial-crew color, longship_lines)         -> R=FF/G=AA/B=00
--             -> orange, folded to red (same precedent)
--   0x66CCFF (Auto-Raid target, raids_lines)               -> R=FF/G=CC/B=66
--             -> gold, mapped to yellow (nearest pagelib.C hue)
-- Each was previously mapped by variable-name guess (cyan/bright_cyan)
-- rather than decoded; corrected below and where noted further down.
local SHIP_STATE_ANSI = {
  docked = C.dim, raiding = C.red, building = C.yellow, upgrading = C.yellow,
  repairing = C.red, voyaging = C.magenta, ["on voyage"] = C.magenta,
}

-- Ship identity: the name, plus the earned saga title when it has one. Kept
-- as one field so a titled ship reads "Applet the Saga-Born" once, rather than
-- printing the bare name and then repeating it on a line of its own.
local function ship_ident(sh)
  local out = C.bright_white .. (sh.name or "?") .. pagelib.RESET
  if sh.saga_title and sh.saga_title ~= "" then
    out = out .. " " .. C.magenta .. sh.saga_title .. pagelib.RESET
  end
  return out
end

local function longship_lines(add, width)
  add(pagelib.header(width, "Longships"))
  local ships = merged_ships()
  if #ships == 0 then
    add(pagelib.trunc(C.dim .. "No ships" .. pagelib.RESET, width))
    return
  end
  for _, sh in ipairs(ships) do
    local tier_name = cc.SHIP_TIER_NAMES[sh.tier] or ("T" .. tostring(sh.tier))
    local crew_max = cc.CREW_MAX[sh.tier] or 5
    local crew = sh.crew or 0
    -- Partial crew (0x00AAFF, workbook above) folds to the same red as an
    -- empty crew -- both are "not fully crewed," and pagelib has no orange.
    local crew_color = crew >= crew_max and C.bright_green or C.red
    local state_color = SHIP_STATE_ANSI[sh.state] or C.dim
    -- A docked ship's stale target is not shown. Kept as a flag rather than a
    -- prebuilt string so the row below has one place that decides how a target
    -- is coloured and spelled.
    local has_target = sh.target and sh.target ~= "" and sh.state ~= "docked"
    -- Name and tier were already %-padded, but the state was not -- so
    -- "Crew:" slid with the length of "docked"/"returning"/"upgrading", and
    -- the trailing target pushed it further. State now has its own column and
    -- the variable-length target moves to the END of the row, after Crew, so
    -- every fixed field stacks down the page.
    -- Colours added here are NEW, not decoded from LEGACY like the workbook
    -- entries above: LEGACY drew the name, tier, target, countdown and saga
    -- line plain, so a fleet of ten ships was a wall of undifferentiated text
    -- with only the state and crew picked out. Hues are chosen to match this
    -- file's existing vocabulary rather than invented: the target takes the
    -- same yellow raids_lines already gives an Auto-Raid target, and the
    -- countdown takes cyan, the neutral "pending" hue.
    --
    -- Every colour wraps an ALREADY-PADDED field. Putting an escape inside a
    -- "%-12s" would have the padding count the escape bytes and the columns
    -- would drift apart by row.
    add(pagelib.trunc(
      -- Name and earned title are ONE identity field, not a name here and the
      -- same name repeated three lines down. trunc() pads to an exact visible
      -- width and is ANSI-aware, so the colours can sit inside the field --
      -- which string.format("%-26s") could not do, per the note above.
      -- 22 fits the longest real identity ("Nyckeln the Deathless", 21) and
      -- keeps the whole row inside 80 columns with the raid count on the end.
      pagelib.trunc(ship_ident(sh), 22)
      .. " " .. C.dim .. string.format("%-10s", tier_name) .. pagelib.RESET
      .. " " .. state_color .. string.format("%-10s", sh.state or "docked") .. pagelib.RESET
      .. "  " .. C.dim .. "Crew:" .. pagelib.RESET
      .. crew_color .. crew .. "/" .. crew_max .. pagelib.RESET
      .. (has_target and (C.dim .. " -> " .. pagelib.RESET .. C.yellow
          .. (sh.target or "") .. pagelib.RESET
          .. ((sh.convoy == 1) and (C.dim .. " (convoy)" .. pagelib.RESET) or "")) or "")
      .. (((sh.saga_raids or 0) > 0)
          and ("  " .. C.dim .. string.format("(%d raids)", sh.saga_raids) .. pagelib.RESET)
          or ""),
      width))
    if sh.return_in and sh.return_in > 0 then
      add(pagelib.trunc("  " .. C.cyan .. cc.fmt_time(sh.return_in) .. pagelib.RESET, width))
    elseif sh.state == "upgrading" then
      for _, su in ipairs(S.ship_upgrades or {}) do
        if su.name == sh.name and su.secs_left and su.secs_left > 0 then
          add(pagelib.trunc("  " .. C.cyan .. cc.fmt_time(su.secs_left) .. pagelib.RESET, width))
          break
        end
      end
    end
    local dur = sh.durability or 100
    if dur < 100 then
      add(pagelib.kv(width, "  Hull:", dur .. "%", cc.dur_color(dur, 100)))
    end
  end
end

-- ---------------------------------------------------------------------------
-- Raids (guild_viking.lua:7764-7829, gated show_city_raidlog)
-- ---------------------------------------------------------------------------

local function raids_lines(add, width)
  add(pagelib.header(width, "Raids"))
  -- Auto-Raid status. LEGACY caps the displayed ship count with
  -- ar_max_ships() (guild_viking.lua:7778-7779) -- now the real function,
  -- autoraid.lua's M.max_ships() (stage 4 Task 8), which derives the cap
  -- from the Dock building tier and owned/non-held ship counts. state.autoraid
  -- itself is still only populated once the user actually configures the
  -- automation (client-only settings state, never wire-parsed), so this reads
  -- defensively exactly like LEGACY's own `local ar = state.autoraid or {}`.
  --
  -- Disclosure: `autoraid.max_ships()` below calls `autoraid.lua`'s
  -- `M.merged_ships()`, which mutates the `S.voyage_longships`/`S.ships`
  -- records it merges in place (copying convoy/durability/state/return_in
  -- fields onto the matched `voyage_longships` entry) -- this render path
  -- is therefore NOT a pure builder despite this file's own header claim
  -- and `window.lua`'s "pages are pure ... reading S and page_opts only".
  -- LEGACY-faithful, not a bug: MAIN 7778 calls `ar_max_ships()` from
  -- `draw_page7` the same way, and `ar_merged_ships` mutates identically.
  -- The mutation is idempotent (each call re-copies the same source
  -- fields), so running it twice per frame -- once per render target, when
  -- a WebSocket client is attached alongside the local view -- produces no
  -- drift. One wrinkle, also LEGACY's own behavior: `vsh.durability =
  -- sh.durability` is unconditional, so a `voyage_longships` entry with a
  -- durability that `S.ships` doesn't carry gets nilled out by the merge.
  local ar = S.autoraid or {}
  local on = page_opts.get("auto_raid")
  local ships_txt = (ar.ships == "all") and "All Ships"
    -- Without autoraid installed there is no Dock-derived cap to clamp to, so
    -- the configured ship count stands on its own.
    or (tostring(autoraid and math.min(tonumber(ar.ships) or 2, autoraid.max_ships())
                 or (tonumber(ar.ships) or 2)) .. " Ships")
  local convoy_txt = ar.convoy and " convoy" or ""
  local has_tgt = ar.target and ar.target ~= ""
  local target_txt = has_tgt and cc.tcase(ar.target) or "(no target)"
  add(pagelib.trunc(string.format("Auto-Raid %s%s%s   %s%s  ->  %s%s%s",
    on and C.bright_green or C.dim, on and "ON" or "off", pagelib.RESET,
    ships_txt, convoy_txt, has_tgt and C.yellow or C.dim, target_txt, pagelib.RESET), width))

  -- KEEP AND DISCLOSE (semantic exceptions, same style as pages/army.lua's
  -- "training status" note):
  --   - lost-raid line, below: LEGACY's own literal is 0xFF5555, which
  --     decodes (R=55,G=55,B=FF) to a blue/cyan hue, not the red the
  --     "raid lost" semantics obviously call for. Treated as an author
  --     slip against LEGACY's own documented BGR convention (a plain
  --     RGB-red-looking hex picked without re-checking it against the
  --     byte order LEGACY itself declares) rather than mechanically ported
  --     -- kept as C.bright_red.
  --   - raid-daler gain, below: LEGACY's literal is 0xFFCC33, which decodes
  --     (R=33,G=CC,B=FF) to a blue hue on paper, but the value is a
  --     currency gain and every other daler-gain readout in this page
  --     (Daler treasury, Active God) uses the warm gold/yellow family --
  --     kept as C.yellow for that consistency rather than decoded literally.
  local rl = S.raidlog or {}
  if #rl == 0 then
    add(pagelib.trunc(C.dim .. "No raids returned yet." .. pagelib.RESET, width))
    return
  end
  local first = math.max(1, #rl - 8)
  for li = #rl, first, -1 do
    local r = rl[li]
    if r.lost then
      add(pagelib.trunc(string.format("%s%s @%s  raid lost%s",
        C.bright_red, r.ship, cc.tcase(r.target or "?"), pagelib.RESET), width))
    else
      local goods_parts = {}
      for _, g in ipairs(r.goods or {}) do
        -- LEGACY colours each cargo entry by its good (guild_viking.lua:8957);
        -- the port printed the label plain, so every raid haul rendered white.
        goods_parts[#goods_parts + 1] = string.format("%d %s%s%s",
          g.qty or 0, cc.good_color(g.good), cc.good_label(g.good), pagelib.RESET)
      end
      local goods_txt = (#goods_parts > 0) and ("  " .. table.concat(goods_parts, "  ")) or ""
      local thralls_txt = ((r.thralls or 0) > 0)
        and string.format("  %d thrall%s", r.thralls, (r.thralls == 1) and "" or "s") or ""
      -- Ship and target were unpadded, so the daler figure and the whole
      -- cargo list slid with the length of each name. Both get a column, and
      -- the daler is right-aligned so the digits stack.
      add(pagelib.trunc(string.format("%-12s %-18s %s%6s%s%s%s",
        r.ship or "?", "@" .. cc.tcase(r.target or "?"),
        C.yellow, "+" .. tostring(r.daler or 0) .. "d", pagelib.RESET,
        goods_txt, thralls_txt), width))
    end
  end
end

-- ---------------------------------------------------------------------------
-- Warehouse (+ nested Refineries) (guild_viking.lua:8321-8479,
-- gated show_city_warehouse)
-- ---------------------------------------------------------------------------

local WH_CAP = { [1] = 400, [2] = 1000, [3] = 1750, [4] = 3000, [5] = 5250 }
local REFINERY_NAMES = {
  salting_house = "Salting House", bakehouse = "Bakehouse",
  furriers_lodge = "Furrier's Lodge", smelter = "Smelter", smithy = "Smithy",
  mead_cellar = "Mead Cellar", weaponry = "Weaponry", armoury = "Armoury",
  goldsmith = "Goldsmith's Hall",
  -- The three the server added later. Without these the rows fell back to the
  -- raw id and rendered lowercase next to their properly-named siblings.
  weaver = "Weaver", smokehouse = "Smokehouse", creamery = "Creamery",
}

local function wstock_row(width, ws, show_name)
  local pct = ws.freshness_pct or 100
  local label, lcolor
  if ws.grade then
    label, lcolor = ws.grade, pagelib.pct_color(pct, 100)
  elseif cc.is_perishable(ws.good) then
    label, lcolor = cc.quality_label(ws.good, pct)
  else
    label, lcolor = "stable", C.green
    pct = 100
  end
  local name = show_name and cc.good_label(ws.good) or ""
  -- Amount and percentage are RIGHT-aligned to fixed widths. They were bare
  -- %d, so every row's figures sat at a different column: "100  100%" and
  -- "2929  100%" put the percentage four cells apart, and a column of stock
  -- levels could not be read down. Amount is comma-grouped to match the
  -- "[9,374 / 9,056]" in the section header.
  return pagelib.trunc(string.format("%s%-14s%s %s%-16s%s %s %s  %s",
    cc.good_color(ws.good), name, pagelib.RESET, lcolor, label, pagelib.RESET,
    pagelib.bar(12, pct, 100, lcolor),
    pagelib.rjust(pagelib.fmt_num(ws.amount or 0), 7),
    pagelib.rjust(pct .. "%", 4)), width)
end

local function warehouse_lines(add, width)
  local wh_tier = S.buildings and S.buildings["warehouse"] or 0
  -- S.wh_cap (from WSTOCK's cap field) is the server's real capacity,
  -- including steward/lager/star bonuses the static per-tier table below
  -- knows nothing about -- LEGACY prefers it the same way
  -- (guild_viking.lua:9626).
  local wh_cap = S.wh_cap or WH_CAP[wh_tier] or 0
  local wh_used = 0
  for _, ws in ipairs(S.wstock or {}) do wh_used = wh_used + (ws.amount or 0) end
  if wh_cap > 0 then
    add(pagelib.header(width, string.format("Warehouse  [%s / %s]",
      pagelib.fmt_num(wh_used), pagelib.fmt_num(wh_cap))))
  else
    add(pagelib.header(width, "Warehouse"))
  end

  local tick_txt = (S.next_tick_in and S.next_tick_in > 0) and cc.fmt_time(S.next_tick_in) or "now"
  add(pagelib.kv(width, "Next stock tick:", tick_txt, C.bright_cyan))

  if not S.wstock or #S.wstock == 0 then
    add(pagelib.trunc(C.dim .. "Empty" .. pagelib.RESET, width))
  else
    local last_good = nil
    for _, ws in ipairs(S.wstock) do
      add(wstock_row(width, ws, ws.good ~= last_good))
      last_good = ws.good
    end
  end

  if S.refineries and #S.refineries > 0 then
    add(pagelib.header(width, "Refineries"))
    for _, r in ipairs(S.refineries) do
      add(pagelib.trunc(string.format("%-16s [%d / %d]",
        REFINERY_NAMES[r.id] or r.id, r.stock or 0, r.cap or 0), width))

      -- What the chain actually makes, and why it might be idle. The server
      -- sends in/out/wstock on Guild.Refinery; an older server omits them, so
      -- both lines are gated on the data being present rather than assumed.
      if r.input ~= nil and r.input ~= "" then
        add(pagelib.trunc("    " .. C.dim .. cc.good_label(r.input)
          .. " -> " .. pagelib.RESET .. C.white
          .. cc.good_label(r.output or "") .. pagelib.RESET, width))
        -- Zero input in the warehouse is the usual reason a refinery with
        -- capacity produces nothing, so it is coloured as a problem.
        local have = r.wstock or 0
        add(pagelib.trunc("    " .. C.dim .. "Warehouse: " .. pagelib.RESET
          .. (have > 0 and C.bright_green or C.red) .. have .. pagelib.RESET
          .. " " .. C.dim .. cc.good_label(r.input) .. pagelib.RESET, width))
      end

      for _, g in ipairs(r.grades or {}) do
        local col = pagelib.pct_color(g.pct or 100, 100)
        add(pagelib.trunc(string.format("  %s%-14s%s %3d  %s",
          col, g.name, pagelib.RESET, g.qty or 0, pagelib.bar(12, g.pct or 100, 100, col)), width))
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Production (guild_viking.lua:8481-8542, gated show_city_production)
-- ---------------------------------------------------------------------------

local PROD_GOOD_ORDER = { "timber", "ore", "furs", "fish", "grain", "honey" }
local PROD_BLDGS = {
  lumber_yard = { good = "timber", yields = { 5, 12, 25, 36, 56 } },
  mine        = { good = "ore",    yields = { 6, 15, 30, 44, 64 } },
  tannery     = { good = "furs",   yields = { 4, 10, 20, 29, 44 } },
  fishery     = { good = "fish",   yields = { 6, 15, 30, 44, 64 } },
  farm        = { good = "grain",  yields = { 8, 20, 40, 56, 80 } },
  apiary      = { good = "honey",  yields = { 4, 10, 15, 20, 32 } },
}

local function production_lines(add, width)
  local totals = {}
  -- `next(S.production)`, not `S.production` alone: an EMPTY table is truthy
  -- in Lua, and write_production sets S.production = {} before filling it. One
  -- frame carrying no rows therefore latched an empty table for good, which
  -- took the building-based estimate below out of reach -- it only ran when
  -- the key had never arrived at all.
  if S.production and next(S.production) ~= nil then
    for good, amt in pairs(S.production) do
      if amt ~= 0 then totals[good] = (totals[good] or 0) + amt end
    end
  else
    for bid, info in pairs(PROD_BLDGS) do
      local tier = S.buildings and S.buildings[bid]
      if tier then
        local qty = info.yields[tier] or info.yields[#info.yields]
        totals[info.good] = (totals[info.good] or 0) + qty
      end
    end
  end
  local has_prod = false
  for _, g in ipairs(PROD_GOOD_ORDER) do if totals[g] then has_prod = true; break end end

  -- The tick countdown used to sit BELOW an early return on has_prod, so a
  -- city with nothing to show that moment lost the timer as well -- and the
  -- timer is the half you watch. It is the tick that is being counted, not
  -- the goods: show the section whenever either is worth showing.
  -- The tick is sent on every push now (Guild.City's "nexttick"), so its
  -- absence is meaningful rather than an artefact of delta frames: nil means
  -- nothing has arrived yet, -1 means no production tick has ever run, and
  -- 0 or more is a real countdown. Show the section whenever either the tick
  -- or the goods are worth showing -- the countdown is the half you watch,
  -- and it used to sit below an early return that took it away exactly when
  -- there was nothing produced that moment.
  local tick = S.next_tick_in
  local has_tick = tick ~= nil
  if not has_prod and not has_tick then return end

  add(pagelib.header(width, "Production / Tick"))
  if has_tick then
    if tick > 0 then
      add(pagelib.kv(width, "Next in:", cc.fmt_time(tick), C.bright_cyan))
    elseif tick == 0 then
      add(pagelib.kv(width, "Next in:", "due now", C.bright_cyan))
    else
      add(pagelib.kv(width, "Next in:", "no tick yet", C.dim))
    end
  end
  if not has_prod then return end
  local parts = {}
  for _, good in ipairs(PROD_GOOD_ORDER) do
    local qty = totals[good]
    if qty then
      parts[#parts + 1] = cc.good_color(good) .. cc.good_label(good) .. " +" .. qty .. pagelib.RESET
    end
  end
  add(pagelib.trunc(table.concat(parts, "  "), width))
end

-- ---------------------------------------------------------------------------
-- Buildings + Upkeep/Tick (guild_viking.lua:8544-8639, both gated
-- show_city_buildings)
-- ---------------------------------------------------------------------------

local BLDG_LABELS = {
  warehouse = "Warehouse", trading_post = "Trading Post", dock = "Dock",
  courier_post = "Courier Post", beacon = "Beacon", shadow_house = "Shadow-House",
  training_yard = "Training Yard", lumber_yard = "Lumber Yard", mine = "Mine",
  smithy = "Smithy", smelter = "Smelter", weaponry = "Weaponry", armoury = "Armoury",
  goldsmith = "Goldsmith's Hall", skald_hall = "Skald's Hall",
  salting_house = "Salting House", bakehouse = "Bakehouse",
  furriers_lodge = "Furrier's Lodge", tannery = "Tannery", fishery = "Fishery",
  farm = "Farm", apiary = "Apiary", mead_cellar = "Mead Cellar", longhouse = "Longhouse",
  garrison = "Garrison", palisade = "Palisade", watchtower = "Watchtower",
  mead_hall = "Mead Hall", thrall_pen = "Thrall Pen", muster_ground = "Muster Ground",
  settler_plots = "Settler Plots", well = "Well",
}

local function buildings_lines(add, width)
  local bld_ids = {}
  for bid in pairs(S.buildings or {}) do bld_ids[#bld_ids + 1] = bid end
  table.sort(bld_ids)

  if #bld_ids > 0 then
    add(pagelib.header(width, "Buildings"))
    local half = math.floor(width / 2)
    local function cell(bid)
      local label = BLDG_LABELS[bid] or cc.cap_first((bid:gsub("_", " ")))
      return string.format("%s T%d", label, S.buildings[bid] or 1)
    end
    for i = 1, #bld_ids, 2 do
      local left = pagelib.trunc(cell(bld_ids[i]), half)
      local right = bld_ids[i + 1] and cell(bld_ids[i + 1]) or ""
      add(pagelib.trunc(left .. " " .. right, width))
    end
  end

  if S.upkeep and (S.upkeep.total or 0) > 0 then
    add(pagelib.header(width, "Upkeep / Tick"))
    local u = S.upkeep
    local urows = {
      { "Roster (staff)", u.roster }, { "Settlers/civic", u.community },
      { "Throne Room", u.throne }, { "Roads", u.roads }, { "Forts", u.forts },
    }
    for _, r in ipairs(urows) do
      if (r[2] or 0) > 0 then
        add(pagelib.kv(width, r[1] .. ":", "-" .. pagelib.fmt_num(r[2]) .. "/tick", C.red))
      end
    end
    add(pagelib.kv(width, "Total:", "-" .. pagelib.fmt_num(u.total) .. " daler/tick", C.bright_red))
  end
end

-- ---------------------------------------------------------------------------
-- Trade Routes (guild_viking.lua:8641-8739) -- NOTE: no page_opts gate at
-- all in LEGACY, despite the name; unconditional on state.routes being
-- non-empty. Rendered in the CITY-mode (settlement-after) block, not trade
-- mode -- see the task report.
-- ---------------------------------------------------------------------------

local function trade_routes_lines(add, width)
  if not S.routes or next(S.routes) == nil then return end
  add(pagelib.header(width, "Trade Routes"))
  if S.route_upkeep and S.route_upkeep > 0 then
    add(pagelib.kv(width, "Upkeep:", S.route_upkeep .. " daler/tick", C.bright_cyan))
  end
  local route_ids = {}
  for vid in pairs(S.routes) do route_ids[#route_ids + 1] = vid end
  table.sort(route_ids)
  for _, vid in ipairs(route_ids) do
    local r = S.routes[vid]
    local road_str = (r.road_tier or 0) > 0
      and ((r.road_name ~= "" and r.road_name) or ("Road T" .. r.road_tier)) or "No Road"
    local fort_str = (r.fort_tier or 0) > 0
      and ((r.fort_name ~= "" and r.fort_name) or ("Fort T" .. r.fort_tier)) or "No Fort"
    add(pagelib.trunc(string.format("%-16s %s%-14s%s %s%-14s%s",
      r.name or vid,
      (r.road_tier or 0) > 0 and C.green or C.dim, road_str, pagelib.RESET,
      (r.fort_tier or 0) > 0 and C.green or C.dim, fort_str, pagelib.RESET), width))
    if (r.road_tier or 0) > 0 or (r.fort_tier or 0) > 0 then
      local parts = {}
      if (r.road_tier or 0) > 0 then
        parts[#parts + 1] = "Rd " .. pagelib.bar(10, r.road_maint or 0, 100,
          pagelib.pct_color(r.road_maint or 0, 100))
      end
      if (r.fort_tier or 0) > 0 then
        parts[#parts + 1] = "Ft " .. pagelib.bar(10, r.fort_maint or 0, 100,
          pagelib.pct_color(r.fort_maint or 0, 100))
      end
      add(pagelib.trunc("  " .. table.concat(parts, "  "), width))
    end
    if S.route_builds then
      for _, kind in ipairs({ "road", "fort" }) do
        local rb = S.route_builds[kind .. ":" .. vid]
        if rb then
          local klabel = (kind == "road") and "Road" or "Fort"
          local detail
          if rb.complete_at_secs and rb.complete_at_secs > 0 then
            detail = "- " .. cc.fmt_time(rb.complete_at_secs) .. " left"
          elseif rb.complete_at_secs == 0 then
            detail = "- finalizing..."
          elseif (rb.mats_total or 0) > 0 then
            detail = string.format("- mats %d/%d", rb.mats_done or 0, rb.mats_total or 0)
          else
            detail = "- awaiting mats"
          end
          add(pagelib.trunc(string.format("  Building %s T%d %s", klabel, rb.tier or 1, detail), width))
        end
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Runic Monuments (guild_viking.lua:8741-8756, gated show_city_monuments)
-- ---------------------------------------------------------------------------

local function monuments_lines(add, width)
  add(pagelib.header(width, "Runic Monuments"))
  add(pagelib.trunc(string.format("(%d/%d slots)",
    #(S.monuments or {}), S.monument_cap or 0), width))
  if not S.monuments or #S.monuments == 0 then
    add(pagelib.trunc(C.dim .. "None inscribed" .. pagelib.RESET, width))
  else
    for _, ins in ipairs(S.monuments) do
      add(pagelib.trunc(ins, width))
    end
  end
end

function M.lines(width)
  width = width or 80
  local lines = {}
  local function add(s) lines[#lines + 1] = s end

  -- ---- settlement-before block (guild_viking.lua:7588-7831) -------------
  -- Daler and Active God both use 0x00CCCC (workbook near SHIP_STATE_ANSI
  -- above) -> yellow, not the bright_cyan they were guessed at.
  if S.daler and S.daler >= 0 then
    add(pagelib.kv(width, "Daler:", pagelib.fmt_num(S.daler), C.yellow))
  end

  do
    local has_god = S.god_power_name and S.god_power_name ~= ""
    local gname = has_god and S.god_power_name or "--"
    local gtxt
    if S.god_power_next and S.god_power_next > 0 then
      gtxt = cc.fmt_time(S.god_power_next)
    elseif has_god then
      gtxt = "now"
    else
      gtxt = "--"
    end
    add(pagelib.header(width, "Active God"))
    add(pagelib.kv(width, "In Power:", gname, has_god and C.yellow or C.dim))
    add(pagelib.kv(width, "Resets In:", gtxt, has_god and C.yellow or C.dim))
  end

  if page_opts.get("show_city_ships") then
    longship_lines(add, width)
  end

  if page_opts.get("show_city_raidlog") then
    raids_lines(add, width)
  end

  -- ---- settlement-after block (guild_viking.lua:8319-9114) --------------
  if page_opts.get("show_city_warehouse") then
    warehouse_lines(add, width)
  end

  if page_opts.get("show_city_production") then
    production_lines(add, width)
  end

  if page_opts.get("show_city_buildings") then
    buildings_lines(add, width)
  end

  trade_routes_lines(add, width)

  if page_opts.get("show_city_monuments") then
    monuments_lines(add, width)
  end

  -- City Plan grid, inline -- where LEGACY drew it (guild_viking.lua:10338).
  -- This page used to print a one-line pointer to the popup instead; the grid
  -- itself lives in popups/cityplan.lua and is reused through inline_lines()
  -- so the two views cannot drift apart. Gated the same as LEGACY
  -- (show_city_plan), and pre_grid_lines() inside it emits its own header and
  -- the "No data" line, so nothing extra is needed here.
  if page_opts.get("show_city_plan") then
    for _, l in ipairs(require("popups.cityplan").inline_lines(width)) do
      add(l)
    end
  end

  return lines
end

return M
