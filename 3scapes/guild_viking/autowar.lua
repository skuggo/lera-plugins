local state = require("state").S
local util = require("util")
local page_opts = require("page_opts")

-- Lera has no MUSHclient ColourNote/OnPluginSaveState globals. Keep output
-- and persistence behind tiny adapters so the planner remains readable.
local function note(colour, text)
  local colours = { orange = "FFA500", darkorange = "CC8800", gray = "808080", red = "FF4444" }
  buffer.color_print(nil, colours[colour] or colour, text)
end
local function ColourNote(colour, _, text)
  note(colour, text)
end
local function save()
  local ok, persist = pcall(require, "persist")
  if ok and persist and persist.save then persist.save() end
end


-- -----------------------------------------------------------------------
-- Static game data mirrored from the server (players/skuggis/army.h +
-- battle.h). Kept local so the planner can score power/terrain without
-- scraping any battle text.
-- -----------------------------------------------------------------------
local AW_INTERVAL        = 4    -- seconds between battle actions (readable log)
local AW_DEPLOY_INTERVAL = 2    -- seconds between deploy placements
local AW_CAMP_INTERVAL   = 8    -- seconds between campaign decisions
local AW_CONFIRM_TIMEOUT = 12   -- seconds to wait for the MIP to confirm a move
local AW_COOLDOWN        = 15   -- pause after an unconfirmed action

-- Base combat weight per unit type (battle.h _btype_base).
local AW_BASE = {
  skirmishers = 1, bogmenn = 2, shieldwall = 2,
  huscarls = 3, berserkir = 3, moose = 3, siege = 2,
  foe_raiders = 2, foe_levy = 1, foe_hird = 3, ally_levy = 3,
}

-- Missile reach by type (battle.h _brange). 0 = melee only.
local AW_RANGE = { bogmenn = 3, skirmishers = 2 }

-- Training cost per head + warehouse materiel (army.h _army_unit_types). Used to
-- precheck an auto-train so we never fire a command the server will reject.
local AW_TRAIN = {
  skirmishers = { daler = 3,  good = nil,       gqty = 0 },
  bogmenn     = { daler = 10, good = "tools",   gqty = 1 },
  shieldwall  = { daler = 15, good = "armour",  gqty = 1 },
  huscarls    = { daler = 20, good = "weapons", gqty = 1 },
  berserkir   = { daler = 25, good = "mead",    gqty = 2 },
  moose       = { daler = 30, good = "tools",   gqty = 2 },
}
-- Preferred standing composition, cheapest-first so a modest treasury still
-- rounds out a balanced host (a wall to hold, bows to soften, a hammer to break).
local AW_TRAIN_ORDER = { "shieldwall", "bogmenn", "huscarls", "berserkir", "moose", "skirmishers" }

-- Per-type terrain modifier % (army.h _army_terrain_mods). Keyed by the
-- battle-board terrain NAME (see AW_TERR_NAME below).
local AW_TERR_MOD = {
  skirmishers = { forest = 20, marsh = 15, open = -10 },
  bogmenn     = { hills = 20, wall = 25, forest = -15 },
  shieldwall  = { fjord = 20, chokepoint = 20, open = -5 },
  huscarls    = { open = 10, forest = -5 },
  berserkir   = { open = 15, forest = 10, marsh = -10 },
  moose       = { open = 25, forest = -25, marsh = -20 },
}

-- Board terrain glyph -> terrain name used by AW_TERR_MOD (battle.h terrain
-- glyphs: . plains, ^ hills, * forest, w marsh, = fjord, x chokepoint,
-- # rampart).
local AW_TERR_NAME = {
  ["."] = "open", ["^"] = "hills", ["*"] = "forest", ["w"] = "marsh",
  ["="] = "fjord", ["x"] = "chokepoint", ["#"] = "wall",
}

-- Role of each of OUR unit types.
local AW_ROLE = {
  skirmishers = "ranged", bogmenn = "ranged",
  shieldwall = "line", huscarls = "line", berserkir = "shock",
  moose = "shock", siege = "siege",
}
local function aw_role(t) return AW_ROLE[t] or "line" end
local function aw_base(t) return AW_BASE[t] or 2 end
local function aw_range(t) return AW_RANGE[t] or 0 end

-- -----------------------------------------------------------------------
-- Settings (persisted inside `state`, which the plugin auto-serializes via
-- OnPluginSaveState -- same as state.autoherd / state.autotrader). Everything
-- here is user-configurable through the 'awar' alias and the popup menu.
-- -----------------------------------------------------------------------
function aw_settings()
  if not state.autowar then
    state.autowar = {
      deploy      = true,   -- auto-deploy the host within the command budget
      fortify     = true,   -- raise stakes/dugouts on the defence
      fight       = true,   -- give orders + advance turns to win the battle
      campaign    = true,   -- march the host & give battle on the war map
      defend      = true,   -- auto-answer an incoming war (vcampaign defend)
      offense     = false,  -- auto-declare war on towns we hold a claim on (risky)
      focus       = "weakest", -- focus-fire target: weakest | nearest | strongest
      retreat_at  = 0,       -- withdraw when our power < this % of the foe's
                             -- (0 = never retreat; e.g. 35 = pull out at 35%)
      reinforce   = true,    -- call up reserves at the muster point
      -- Army readiness (run only when no battle/campaign is live) --------------
      prep        = true,    -- master switch for keeping the army war-ready
      levy        = true,    -- keep the conscript tax running
      levy_rate   = 3,       -- settlers drawn to the levy per 6h tick
      muster      = true,    -- top up the conscript pool on hand
      muster_target = 20,    -- conscripts to keep mustered (for reinforcement)
      replenish   = true,    -- refill under-strength ready units with conscripts
      train       = false,   -- train fresh units toward a balanced host (spends
                             -- daler + warehouse goods + a free captain)
      train_batch = 12,      -- conscripts folded into each new unit
      daler_reserve = 3000,  -- daler kept untouched by muster/train
      verbose     = true,    -- echo each Auto-War action to the main window
      debug       = false,
      last = 0, status = "", log = {},
    }
  end
  local aw = state.autowar
  if aw.log == nil then aw.log = {} end
  return aw
end

-- -----------------------------------------------------------------------
-- Small helpers
-- -----------------------------------------------------------------------
local function aw_note(colour, text)
  if ColourNote then ColourNote(colour, "", "[Auto-War] " .. tostring(text)) end
end
local function aw_say(aw, colour, text)
  if aw.verbose and ColourNote then ColourNote(colour, "", "[Auto-War] " .. tostring(text)) end
end
local function aw_dbg(aw, text)
  if aw.debug and ColourNote then ColourNote("gray", "", "[Auto-War] " .. tostring(text)) end
end
local function log_action(aw, desc)
  aw.log[#aw.log + 1] = { t = os.date("%H:%M:%S"), desc = desc }
  while #aw.log > 40 do table.remove(aw.log, 1) end
end

-- Coord "A5" <-> {col,row} (1-based). Column letters A.. map to 1..; the board
-- is at most 26 wide.
local function coord_to_cr(s)
  if type(s) ~= "string" or #s < 2 then return nil end
  local col = string.byte(s:upper(), 1) - 64
  local row = tonumber(s:sub(2))
  if not col or not row or col < 1 or row < 1 then return nil end
  return col, row
end
local function cr_to_coord(c, r)
  return string.char(64 + c) .. tostring(r)
end
local function aw_dist(c1, r1, c2, r2)   -- Chebyshev (king moves)
  return math.max(math.abs(c1 - c2), math.abs(r1 - r2))
end

-- Terrain glyph at a battle square (1-based c,r), from state.battle.terrain_rows.
local function terr_glyph(b, c, r)
  local row = b.terrain_rows and b.terrain_rows[r]
  if not row then return "." end
  local ch = row:sub(c, c)
  return (ch ~= "" and ch) or "."
end
local function terr_name(b, c, r)
  return AW_TERR_NAME[terr_glyph(b, c, r)] or "open"
end
-- Field-work glyph at a square ("v" stakes, "u" dugout, "." none).
local function work_glyph(b, c, r)
  local row = b.works_rows and b.works_rows[r]
  if not row then return "." end
  local ch = row:sub(c, c)
  return (ch ~= "" and ch) or "."
end
-- Total field works currently on the board (used to detect a spent works budget).
local function works_count(b)
  local n = 0
  for r = 1, (b.height or 8) do
    local row = b.works_rows and b.works_rows[r]
    if row then
      for i = 1, #row do local ch = row:sub(i, i); if ch == "v" or ch == "u" then n = n + 1 end end
    end
  end
  return n
end
-- Per-battle fortify tracker: stops us re-issuing works once the budget is gone.
local aw_fort = { key = nil, prev = nil, stop = false }

-- Last-seen foe positions (bid -> {c,r}), so we can infer a company's facing
-- from how it moved and aim for its exposed flank / rear.
local aw_prev_foe = {}
-- Remembered peak strength per standing-army unit (uid -> size), so we can tell
-- when a unit is under-strength and worth replenishing.
local aw_unit_peak = {}

-- Warehouse quantity of a good (mirrors the husbandry helper).
local function warehouse_amount(good)
  if not good then return 0 end
  local rec = state.wstock_by_good and state.wstock_by_good[good]
  if rec then return rec.amount or 0 end
  local n = 0
  for _, ws in ipairs(state.wstock or {}) do
    if ws.good == good then n = n + (ws.amount or 0) end
  end
  return n
end

-- Rough combat power of one fielded company, the way the server scores it:
-- size * base * terrain% * morale%. (Leader/vet/traits aren't in the MIP feed,
-- so they fall out equally on both sides and we can omit them.)
local function unit_power(b, u)
  local size = u.size or 0
  if size <= 0 then return 0 end
  local c, r = coord_to_cr(u.coord)
  local terr = (c and r) and terr_name(b, c, r) or "open"
  local base = aw_base(u.utype)
  local p = size * base
  local mod = (AW_TERR_MOD[u.utype] and AW_TERR_MOD[u.utype][terr]) or 0
  p = p * (100 + mod) / 100
  p = p * (u.morale or 100) / 100
  if p < 1 then p = 1 end
  return math.floor(p)
end

-- Split fielded units into your side / foe side (with parsed coords).
local function split_units(b)
  local mine, foe = {}, {}
  for _, u in ipairs(b.units or {}) do
    local c, r = coord_to_cr(u.coord)
    if c and r then
      local rec = { u = u, c = c, r = r }
      if u.side == "you" then mine[#mine + 1] = rec else foe[#foe + 1] = rec end
    end
  end
  return mine, foe
end

-- Is square (c,r) inside the board and empty of any fielded unit?
local function square_free(b, occ, c, r)
  if c < 1 or r < 1 or c > (b.width or 8) or r > (b.height or 8) then return false end
  return not occ[c .. "," .. r]
end
local function occupancy(b)
  local occ = {}
  for _, u in ipairs(b.units or {}) do
    local c, r = coord_to_cr(u.coord)
    if c and r then occ[c .. "," .. r] = u end
  end
  return occ
end

-- =======================================================================
-- DEPLOY PLANNER
-- Place one reserve company per tick onto the best square in the deploy zone
-- (rows 1..dz): the line up front, the bows at the back, each on the terrain
-- that flatters it. Returns a single {cmd,desc} or nil.
-- =======================================================================
local function best_deploy_square(b, utype, occ)
  local dz = b.dz or 2
  local w  = b.width or 8
  local role = aw_role(utype)
  -- Ranged sit on the rear row (row 1); everything else on the front row (dz).
  -- We still fall back across the whole zone if the preferred row is full.
  local row_order
  if role == "ranged" then row_order = { 1, dz }
  else row_order = { dz, 1 } end
  if dz >= 3 then
    if role == "ranged" then row_order = { 1, 2, 3 }
    else row_order = { dz, dz - 1, 1 } end
  end

  local best_c, best_r, best_score
  for _, r in ipairs(row_order) do
    for c = 1, w do
      if square_free(b, occ, c, r) then
        local terr = terr_name(b, c, r)
        local mod = (AW_TERR_MOD[utype] and AW_TERR_MOD[utype][terr]) or 0
        -- Prefer good terrain; prefer central columns for the line (so it can
        -- converge), and spread archers is fine either way. First preferred row
        -- gets a big bonus so rows stay sorted.
        local score = mod
        local rowbonus = (r == row_order[1]) and 100 or 0
        local centre = w / 2 + 0.5
        local central = 8 - math.abs(c - centre) * 2   -- higher toward centre
        if role == "ranged" then central = math.abs(c - centre) * 1 end
        score = score + rowbonus + central
        if not best_score or score > best_score then
          best_score, best_c, best_r = score, c, r
        end
      end
    end
  end
  if best_c then return cr_to_coord(best_c, best_r) end
  return nil
end

-- Value of fielding a reserve company now: raw power per command point, so a
-- tight budget still fields the most muscle. Ranged get a small nudge (cheap
-- and they soften the foe before contact).
local function reserve_value(sp)
  local base = aw_base(sp.utype or sp.type)
  local size = sp.size or 0
  local cost = (sp.cost and sp.cost > 0) and sp.cost or 1
  local v = (size * base) / cost
  if aw_role(sp.utype or sp.type) == "ranged" then v = v * 1.15 end
  return v
end

local function aw_plan_deploy(aw, b)
  local budget = (b.budget or 0) - (b.spent or 0)
  local reserve = b.reserve or {}

  -- 1) Deploy the highest-value affordable company we can still place.
  if aw.deploy and #reserve > 0 and budget > 0 then
    local occ = occupancy(b)
    -- Sort a shallow copy by value, descending.
    local order = {}
    for _, sp in ipairs(reserve) do order[#order + 1] = sp end
    table.sort(order, function(x, y) return reserve_value(x) > reserve_value(y) end)
    for _, sp in ipairs(order) do
      local cost = sp.cost or 1
      if cost <= budget then
        -- reserve entries carry utype? The MIP reserve line is label,size,uid,
        -- cost,leader with no type -- infer type from the label so terrain
        -- placement still works; default to a line unit.
        local utype = sp.utype or reserve_type_from_label(sp.label)
        local sq = best_deploy_square(b, utype, occ)
        if sq then
          return { cmd = string.format("vbattle deploy %d %s", sp.uid or 0, sq),
            kind = "deploy",
            desc = string.format("deploy %s (%d men) to %s [%d pts left]",
              sp.label or "unit", sp.size or 0, sq, budget - cost) }
        end
      end
    end
  end

  -- 2) Fortify: on the defence, dig in the archers (missile cover) and stake
  --    the front row (anti-charge). The works budget isn't in the MIP feed, so
  --    we watch the board: if an attempt doesn't add a work, we've run out of
  --    budget -- stop fortifying and join battle rather than looping forever.
  if aw.fortify and (b.mode == "siege_defend" or b.mode == "field") then
    local bkey = (b.mode or "") .. (b.width or 0) .. "x" .. (b.height or 0) .. (b.target or "")
    if aw_fort.key ~= bkey then aw_fort.key, aw_fort.prev, aw_fort.stop = bkey, nil, false end
    local wc = works_count(b)
    if aw_fort.prev ~= nil and wc <= aw_fort.prev then
      aw_fort.stop = true   -- last attempt placed nothing -> no works budget left
    end
    if not aw_fort.stop then
      local dz = b.dz or 2
      local w  = b.width or 8
      local occ = occupancy(b)
      local mine = split_units(b)
      -- Dugouts under our archers first (heavy missile cover).
      for _, rec in ipairs(mine) do
        if aw_role(rec.u.utype) == "ranged" and work_glyph(b, rec.c, rec.r) == "." then
          aw_fort.prev = wc
          return { cmd = "vbattle fortify dugout " .. cr_to_coord(rec.c, rec.r),
            kind = "fortify", desc = "dig in the bows at " .. cr_to_coord(rec.c, rec.r) }
        end
      end
      -- Then stakes on empty front-row approach tiles.
      for c = 1, w do
        local r = dz
        if not occ[c .. "," .. r] and work_glyph(b, c, r) == "." then
          aw_fort.prev = wc
          return { cmd = "vbattle fortify stakes " .. cr_to_coord(c, r),
            kind = "fortify", desc = "stake the approach at " .. cr_to_coord(c, r) }
        end
      end
    end
  end

  -- 3) Nothing left to place -- join battle (only if we actually fielded a
  --    company; the server rejects an empty host anyway).
  local placed = 0
  for _, u in ipairs(b.units or {}) do if u.side == "you" then placed = placed + 1 end end
  if placed >= 1 then
    return { cmd = "vbattle begin", kind = "begin",
      desc = string.format("host arrayed (%d companies) -- joining battle", placed) }
  end
  return nil, "waiting for a company to deploy"
end

-- Infer a reserve unit's type from its label (the MIP reserve line has no type
-- field). Falls back to a generic line company.
function reserve_type_from_label(label)
  local l = (label or ""):lower()
  if l:find("skirm") or l:find("thrall") then return "skirmishers" end
  if l:find("bog") or l:find("bow") or l:find("archer") then return "bogmenn" end
  if l:find("skjald") or l:find("shield") or l:find("wall") then return "shieldwall" end
  if l:find("huscarl") or l:find("hird") then return "huscarls" end
  if l:find("berserk") then return "berserkir" end
  if l:find("elg") or l:find("moose") or l:find("cavalry") then return "moose" end
  if l:find("siege") or l:find("engine") or l:find("ram") or l:find("tower") then return "siege" end
  return "shieldwall"
end

-- =======================================================================
-- BATTLE ORDER PLANNER
-- One decision per turn: give every company its order, then advance. Because
-- issuing orders is free and only sets each unit's target, we send the whole
-- turn's orders in ONE tick and finish with 'vbattle go'.
-- =======================================================================

-- Rank the foe for focus fire. We combine THREAT (its power -- how much it hurts
-- us) with FRAILTY (how close it is to breaking), and hand a big bonus to a
-- company we can finish outright, because a dead foe deals no damage next turn.
-- Returns the foe recs sorted best-target-first.
local function rank_targets(aw, b, foe)
  local scored = {}
  for _, f in ipairs(foe) do
    local pw = unit_power(b, f.u)
    local size = f.u.size or 0
    local morale = f.u.morale or 100
    local s
    if aw.focus == "strongest" then
      s = pw                                   -- break their best first
    elseif aw.focus == "nearest" then
      s = -size                                -- caller re-weights by distance
    else -- weakest (default): collapse the line fastest
      s = 100000 - size * 120 - (100 - morale) * 40
      if morale <= 45 then s = s + 60000 end   -- one push from routing
      if size <= 12 then s = s + 40000 end      -- almost gone -- finish it
      s = s + pw                                 -- tie-break toward the deadlier
    end
    scored[#scored + 1] = { f = f, s = s }
  end
  table.sort(scored, function(x, y) return x.s > y.s end)
  local out = {}
  for _, e in ipairs(scored) do out[#out + 1] = e.f end
  return out
end

-- Nearest foe rec to (c,r).
local function nearest_foe(foe, c, r)
  local best, bd
  for _, f in ipairs(foe) do
    local d = aw_dist(c, r, f.c, f.r)
    if not bd or d < bd then bd, best = d, f end
  end
  return best, bd
end

-- Infer a foe's facing from how it moved since last turn: the unit rec carries a
-- bid, and aw_prev_foe remembers where it stood. Returns (fc,fr) unit facing
-- vector, or nil if it held still / is newly seen (then it's chasing our nearest
-- company, so we fall back to that heading at the call site).
local function foe_facing(f)
  local prev = aw_prev_foe[f.u.bid]
  if not prev then return nil end
  local dc = f.c - prev.c
  local dr = f.r - prev.r
  if dc == 0 and dr == 0 then return nil end
  local function sgn(x) return (x > 0 and 1) or (x < 0 and -1) or 0 end
  return sgn(dc), sgn(dr)
end

-- Score how exposed an attacker at (ac,ar) is when it strikes a foe facing
-- (fc,fr): rear (dot<0) 160, flank (dot==0) 130, front 100 -- mirrors
-- battle.h _bfacing_mult. Higher = better hit.
local function facing_bonus(fx, fy, fcoc, fcor, ac, ar)
  if not fx then return 115 end   -- facing unknown: assume a modest edge
  if fx == 0 and fy == 0 then return 100 end
  local dot = fx * (ac - fcoc) + fy * (ar - fcor)
  if dot > 0 then return 100 end
  if dot == 0 then return 130 end
  return 160
end

-- Choose the best empty tile adjacent to a foe for a melee/shock unit: prefer
-- the exposed flank/rear (using inferred facing), then good terrain for our
-- type, then the fewest steps for our unit to get there. Falls back to the
-- foe's own square (walk straight in) when the ring is full.
local function approach_square(b, occ, f, uc, ur, utype, claimed)
  local fc, fr = f.c, f.r
  local fx, fy = foe_facing(f)
  if not fx then
    -- Newly seen / stationary: it will turn to chase our unit, so treat it as
    -- facing toward us and aim for the opposite (rear) side.
    local function sgn(x) return (x > 0 and 1) or (x < 0 and -1) or 0 end
    fx, fy = sgn(uc - fc), sgn(ur - fr)
  end
  local best, best_score
  for dc = -1, 1 do
    for dr = -1, 1 do
      if not (dc == 0 and dr == 0) then
        local c, r = fc + dc, fr + dr
        local key = c .. "," .. r
        if square_free(b, occ, c, r) and not claimed[key] then
          local terr = terr_name(b, c, r)
          local tmod = (AW_TERR_MOD[utype] and AW_TERR_MOD[utype][terr]) or 0
          local face = facing_bonus(fx, fy, fc, fr, c, r)
          local steps = aw_dist(uc, ur, c, r)
          -- Weight: hitting the exposed side dominates, then terrain, then how
          -- soon we can arrive.
          local score = face * 10 + tmod * 2 - steps
          if not best_score or score > best_score then best_score, best = score, key end
        end
      end
    end
  end
  if best then return best end
  return fc .. "," .. fr
end

-- A safe tile to kite an archer to: the adjacent square that maximises distance
-- from every foe (and stays on the board / unoccupied), so it re-opens its
-- shooting band instead of being caught in melee.
local function kite_square(b, occ, m, foe)
  local best, best_score
  for dc = -1, 1 do
    for dr = -1, 1 do
      local c, r = m.c + dc, m.r + dr
      if square_free(b, occ, c, r) or (c == m.c and r == m.r) then
        local mind = 99
        for _, f in ipairs(foe) do
          local d = aw_dist(c, r, f.c, f.r); if d < mind then mind = d end
        end
        local terr = terr_name(b, c, r)
        local tmod = (AW_TERR_MOD[m.u.utype] and AW_TERR_MOD[m.u.utype][terr]) or 0
        local score = mind * 10 + tmod
        if not best_score or score > best_score then best_score, best = score, cr_to_coord(c, r) end
      end
    end
  end
  return best or m.coord
end

local function aw_plan_orders(aw, b)
  local mine, foe = split_units(b)

  -- Remember foe positions for next turn's facing inference.
  local seen = {}
  for _, f in ipairs(foe) do
    if f.u.bid then aw_prev_foe[f.u.bid] = { c = f.c, r = f.r }; seen[f.u.bid] = true end
  end
  for bid in pairs(aw_prev_foe) do if not seen[bid] then aw_prev_foe[bid] = nil end end

  if #mine == 0 then
    return { cmd = "vbattle go", kind = "advance", desc = "no companies to order -- advancing" }
  end
  if #foe == 0 then
    return { cmd = "vbattle go", kind = "advance", desc = "no foe in sight -- advancing" }
  end

  -- Retreat check: compare total effective power. Withdraw (fighting) if we've
  -- fallen below the configured share of the enemy's strength.
  if (aw.retreat_at or 0) > 0 then
    local mp, fp = 0, 0
    for _, m in ipairs(mine) do mp = mp + unit_power(b, m.u) end
    for _, f in ipairs(foe) do fp = fp + unit_power(b, f.u) end
    if fp > 0 and mp * 100 < fp * aw.retreat_at then
      return { cmd = "vbattle retreat", kind = "retreat",
        desc = string.format("outmatched (%d vs %d power) -- fighting withdrawal", mp, fp) }
    end
  end

  local occ = occupancy(b)
  local claimed = {}          -- squares already targeted this turn
  local orders = {}           -- {bid, coord}
  local ranked = rank_targets(aw, b, foe)   -- best focus target first

  -- Local superiority: pour attackers onto the top target until it is likely
  -- to break, THEN move down the list. We approximate "enough" as 2 companies
  -- per foe (more if the foe badly out-sizes a single company of ours).
  local assign_idx = 1                         -- which ranked foe we're filling
  local on_target = 0
  local per_target = 2

  -- The server moves your companies in the order the orders arrive, with an
  -- enemy company stepping between each of yours, so the sequence below is a
  -- real tactical choice rather than bookkeeping: whoever is ordered first
  -- takes contested ground. Lead with the moves that lose the most by being
  -- blocked -- engines, whose positioning IS the plan in an assault, then the
  -- companies about to make contact, then the rest.
  local function order_priority(m)
    local role = aw_role(m.u.utype)
    if role == "siege" then return 1 end
    local _, d = nearest_foe(foe, m.c, m.r)
    if d and d <= 2 then return 2 end        -- closing to contact this turn
    if role == "ranged" then return 4 end    -- repositioning, least urgent
    return 3
  end
  local seq = {}
  for i, m in ipairs(mine) do
    seq[i] = { m = m, i = i, p = order_priority(m) }
  end
  table.sort(seq, function(x, y)
    if x.p ~= y.p then return x.p < y.p end
    return x.i < y.i                         -- stable: keep the server's order
  end)

  for _, e in ipairs(seq) do
    local m = e.m
    local u = m.u
    local role = aw_role(u.utype)
    local rng = aw_range(u.utype)
    local target_coord

    if role == "ranged" and rng > 0 then
      -- Kite off contact; otherwise hold at the band and loose (the engine keeps
      -- ranged units at range on its own once they can reach a foe).
      local nf, nd = nearest_foe(foe, m.c, m.r)
      if nf and nd <= 1 then
        target_coord = kite_square(b, occ, m, foe)
      elseif nf then
        target_coord = cr_to_coord(nf.c, nf.r)
      end

    elseif role == "siege" then
      -- Siege engines exist to breach walls: drive them at the nearest rampart
      -- tile (or a foe standing on one). They batter walls within 2 tiles.
      local tgt = nearest_foe(foe, m.c, m.r)
      local wallc, wallr, wd, wgap
      for r = 1, (b.height or 8) do
        for c = 1, (b.width or 8) do
          if terr_glyph(b, c, r) == "#" then
            local d = aw_dist(m.c, m.r, c, r)
            local gap = math.abs(c - m.c)   -- tie-break: head straight in
            if not wd or d < wd or (d == wd and gap < wgap) then
              wd, wgap, wallc, wallr = d, gap, c, r
            end
          end
        end
      end
      if wallc then target_coord = cr_to_coord(wallc, wallr)
      elseif tgt then target_coord = cr_to_coord(tgt.c, tgt.r) end

    else
      -- Line & shock: concentrate on the ranked focus target from its most
      -- exposed side. Shock units (moose/berserk) always take the current focus
      -- for the charge; once a target has its share of attackers, move on.
      if on_target >= per_target and assign_idx < #ranked then
        assign_idx = assign_idx + 1
        on_target = 0
      end
      local tgt = ranked[assign_idx] or ranked[1]
      -- A foe that badly out-sizes one of our companies needs more bodies.
      per_target = ((tgt.u.size or 0) > 60) and 3 or 2
      if tgt then
        local key = approach_square(b, occ, tgt, m.c, m.r, u.utype, claimed)
        claimed[key] = true
        on_target = on_target + 1
        local cc, rr = key:match("^(%d+),(%d+)$")
        if cc then target_coord = cr_to_coord(tonumber(cc), tonumber(rr)) end
      end
    end

    if target_coord and target_coord ~= u.coord then
      orders[#orders + 1] = { bid = u.bid, coord = target_coord }
    end
  end

  return { cmd = "vbattle go", kind = "advance", orders = orders,
    desc = string.format("turn %d: %d order%s, advancing",
      (b.turn or 0) + 1, #orders, (#orders == 1) and "" or "s") }
end

-- =======================================================================
-- CAMPAIGN PLANNER (war map)
-- March the host at the nearest enemy army (or the objective), give battle when
-- contact is pending, break off if badly outweighed. Returns {cmd,desc} or nil.
-- =======================================================================
local function wm_find(wm, id)
  for _, u in ipairs(wm.units or {}) do
    if u.id == id then return u end
  end
  return nil
end
local function wm_enemies(wm)
  local out = {}
  for _, u in ipairs(wm.units or {}) do
    if u.id ~= "A" and u.id ~= "F" and u.id ~= "*" then out[#out + 1] = u end
  end
  return out
end

local function aw_plan_campaign(aw, wm)
  -- 1) A tactical battle is pending contact -- give battle (or flee if set and
  --    we're badly outweighed vs the nearest enemy stack).
  if wm.pending and wm.pending ~= 0 then
    local you = wm_find(wm, "A")
    if you and (aw.retreat_at or 0) > 0 then
      -- Compare our host size to the strongest adjacent enemy stack.
      local worst
      for _, e in ipairs(wm_enemies(wm)) do
        if aw_dist(you.c, you.r, e.c, e.r) <= 1 then
          if not worst or (e.size or 0) > worst then worst = (e.size or 0) end
        end
      end
      if worst and (you.size or 0) * 100 < worst * (aw.retreat_at or 0) then
        return { cmd = "vcampaign flee", kind = "flee",
          desc = string.format("host %d vs enemy %d -- breaking contact", you.size or 0, worst) }
      end
    end
    return { cmd = "vcampaign fight", kind = "fight", desc = "battle at hand -- giving battle" }
  end

  -- 2) On the march already -- let it ride.
  if (wm.march_eta or 0) > 0 then
    return nil, "on the march"
  end

  -- 3) Holding: pick a destination. Prefer the nearest enemy army (we win by
  --    clearing them); fall back to the objective '*'.
  local you = wm_find(wm, "A")
  if not you then return nil, "no host on the map" end

  local dest, dnote
  local enemies = wm_enemies(wm)
  local best, bd
  for _, e in ipairs(enemies) do
    local d = aw_dist(you.c, you.r, e.c, e.r)
    if not bd or d < bd then bd, best = d, e end
  end
  if best then
    dest = best; dnote = "closing on the enemy host"
  else
    local obj = wm_find(wm, "*")
    if obj then dest = obj; dnote = "marching to the objective" end
  end

  if not dest then
    -- Nothing to chase and no objective: reinforce if we can, else hold.
    if aw.reinforce then
      return { cmd = "vcampaign reinforce", kind = "reinforce", desc = "calling up reserves" }
    end
    return nil, "holding -- no target on the map"
  end

  -- Already on the destination tile but no pending battle: hold (contact will
  -- resolve on the server's own clock).
  if you.c == dest.c and you.r == dest.r then
    return nil, "in position -- holding"
  end

  -- MIP tiles are 0-based; game squares are 1-based (A1..). Move one step
  -- toward the destination; the server paths the rest over time.
  local sc = string.char(65 + dest.c) .. tostring(dest.r + 1)
  return { cmd = "vcampaign move " .. sc, kind = "march",
    desc = dnote .. " -- march to " .. sc }
end

-- =======================================================================
-- ARMY READINESS (idle-time prep)
-- When no battle or campaign is live, keep the host war-ready: run the levy,
-- muster a conscript pool, replenish thinned units, and (opt-in) train toward a
-- balanced army. Every branch is prechecked against the client's own view of
-- conscripts / daler / warehouse / free captains, so we never fire a command
-- the server would only bounce. One action per call.
-- =======================================================================
local AW_MUSTER_COST = 5        -- daler per settler (army.h ARMY_MUSTER_COST)
local AW_WAR_COST    = 50000    -- daler to mobilise a war (battle.h BATTLE_COST)

local function aw_plan_prep(aw)
  if not aw.prep then return nil, "army prep off" end
  local army = state.army
  if not army then return nil, "no army data (varmy)" end
  local daler = state.daler or 0
  local reserve = aw.daler_reserve or 0

  -- 1) Keep the conscript tax running.
  if aw.levy and (army.levy_rate or 0) <= 0 and (aw.levy_rate or 0) > 0 then
    return { cmd = "varmy levy " .. aw.levy_rate, kind = "levy",
      desc = "set conscript tax to " .. aw.levy_rate .. " per 6h" }
  end

  -- 2) Replenish an under-strength READY unit toward its remembered peak.
  if aw.replenish and army.units then
    for _, u in ipairs(army.units) do
      local pk = aw_unit_peak[u.uid] or 0
      if (u.size or 0) > pk then aw_unit_peak[u.uid] = u.size or 0 end
    end
    if (army.conscripts or 0) > 0 then
      for _, u in ipairs(army.units) do
        local pk = aw_unit_peak[u.uid] or 0
        local gap = pk - (u.size or 0)
        if u.ready and gap >= 3 then
          local n = math.min(gap, army.conscripts or 0)
          if n >= 1 then
            return { cmd = string.format("varmy replenish %d %d", u.uid, n), kind = "replenish",
              desc = string.format("replenish %s +%d (toward %d)", u.type or "unit", n, pk) }
          end
        end
      end
    end
  end

  -- 3) Muster settlers into the conscript pool up to the target.
  if aw.muster then
    local have = army.conscripts or 0
    local cap  = army.conscript_cap or 0
    local target = math.min(aw.muster_target or 0, cap)
    if have < target then
      local want = target - have
      local afford = math.floor((daler - reserve) / AW_MUSTER_COST)
      local n = math.min(want, afford)
      if n >= 1 then
        return { cmd = "varmy muster " .. n, kind = "muster",
          desc = string.format("muster %d settlers (%d/%d conscripts)", n, have + n, cap) }
      end
    end
  end

  -- 4) Train toward a balanced host (opt-in; every cost prechecked).
  if aw.train then
    local slots = (army.cap or 0) - (army.used or 0)
    if slots >= 1 then
      local leader, leader_id
      for id, h in pairs(state.hird_by_id or {}) do
        if h.status == "city_pool" then
          if not leader or ((h.atk or 0) + (h.def or 0)) > ((leader.atk or 0) + (leader.def or 0)) then
            leader, leader_id = h, id
          end
        end
      end
      local n = math.min(aw.train_batch or 12, army.conscripts or 0)
      if leader and n >= 1 then
        local counts = {}
        for _, u in ipairs(army.units or {}) do counts[u.type] = (counts[u.type] or 0) + 1 end
        local function can_afford(t)
          local tc = AW_TRAIN[t]; if not tc then return false end
          local cost = n * tc.daler
          local gok = (not tc.good) or (tc.gqty == 0) or (warehouse_amount(tc.good) >= n * tc.gqty)
          return (daler - reserve) >= cost and gok
        end
        -- First fill a gap in the composition, then just deepen the cheapest arm.
        for _, t in ipairs(AW_TRAIN_ORDER) do
          if (counts[t] or 0) < 1 and can_afford(t) then
            return { cmd = string.format("varmy train %s %d %d", t, n, leader_id), kind = "train",
              desc = string.format("train %d %s under %s", n, t, leader.name or "a captain") }
          end
        end
        for _, t in ipairs(AW_TRAIN_ORDER) do
          if can_afford(t) then
            return { cmd = string.format("varmy train %s %d %d", t, n, leader_id), kind = "train",
              desc = string.format("train %d %s under %s", n, t, leader.name or "a captain") }
          end
        end
      end
    end
  end

  return nil, "army ready"
end

-- Optional: open an offensive campaign against a town we already hold a claim
-- on. Guarded hard -- a claim, ready troops, and the full mobilisation fee above
-- the reserve -- because it is expensive and irreversible.
local function aw_plan_offense(aw)
  if not aw.offense then return nil end
  if state.war_map and state.war_map.active then return nil end
  if not (state.war and state.war.claims and #state.war.claims > 0) then return nil, "no war claims" end
  local army = state.army
  local ready = 0
  if army and army.units then for _, u in ipairs(army.units) do if u.ready then ready = ready + 1 end end end
  if ready < 1 then return nil, "no ready units to march" end
  if (state.daler or 0) - (aw.daler_reserve or 0) < AW_WAR_COST then
    return nil, "treasury too thin to mobilise a war"
  end
  local town = state.war.claims[1].town
  return { cmd = "vcampaign start " .. town, kind = "declare",
    desc = "declaring war on " .. town .. " (claim in hand)" }
end

-- =======================================================================
-- PACED EXECUTOR
-- One state machine, three arenas (deploy / battle / campaign). After any
-- send we wait for the MIP to confirm the world changed before acting again,
-- so we never double-deploy or re-order a stale turn.
-- =======================================================================
local aw_sm = { phase = "idle", next_at = 0, deadline = 0, sig = "" }

-- A signature that changes whenever a meaningful bit of war state moves.
local function aw_sig()
  local p = {}
  local b = state.battle
  if b then
    p[#p+1] = "b" .. tostring(b.phase) .. "/" .. tostring(b.turn or 0)
    p[#p+1] = "sp" .. tostring(b.spent or 0)
    p[#p+1] = "rs" .. tostring(#(b.reserve or {}))
    p[#p+1] = "wk" .. tostring(works_count(b))
    local mine, foe = 0, 0
    for _, u in ipairs(b.units or {}) do
      if u.side == "you" then mine = mine + 1 else foe = foe + 1 end
    end
    p[#p+1] = "u" .. mine .. "/" .. foe
  else
    p[#p+1] = "b-"
  end
  local wm = state.war_map
  if wm and wm.active then
    local you = wm_find(wm, "A")
    p[#p+1] = "w" .. tostring(wm.pending or 0) .. "/" .. tostring(wm.march_eta or 0)
    if you then p[#p+1] = "@" .. you.c .. "," .. you.r .. ":" .. (you.size or 0) end
    p[#p+1] = "e" .. tostring(#wm_enemies(wm))
  else
    p[#p+1] = "w-"
  end
  -- Army fingerprint so idle prep (muster/levy/train/replenish) confirms fast.
  local a = state.army
  if a then
    local usz, un = 0, 0
    for _, u in ipairs(a.units or {}) do usz = usz + (u.size or 0); un = un + 1 end
    p[#p+1] = "a" .. tostring(a.conscripts or 0) .. "/" .. tostring(a.levy_rate or 0)
             .. "/" .. un .. "/" .. usz
  end
  p[#p+1] = "$" .. tostring(state.daler or 0)
  return table.concat(p, ",")
end

-- Send a whole turn's worth of battle orders, then the advance/other command.
local function aw_dispatch(aw, action)
  if action.orders then
    for _, o in ipairs(action.orders) do
      if o.bid and o.coord then mud.send("vbattle order " .. o.bid .. " " .. o.coord) end
    end
  end
  -- `if action.cmd` alone is not enough: "" is truthy in Lua, and an empty
  -- cmd reached the MUD as a bare prompt line.
  if action.cmd then util.send(action.cmd, "autowar") end
  log_action(aw, action.desc)
  aw.status = "last: " .. action.desc
  aw_say(aw, "orange", action.desc)
  aw_dbg(aw, "cmd: " .. tostring(action.cmd) .. (action.orders and (" (+" .. #action.orders .. " orders)") or ""))
end

function auto_battle_tick()
  if not page_opts.get("auto_battle") then
    aw_sm.phase = "idle"
    return
  end
  if not mud.connected() then return end
  local aw = aw_settings()
  local now = os.time()

  -- Confirm / cooldown gates so we act on fresh state only.
  if aw_sm.phase == "confirming" then
    if aw_sig() ~= aw_sm.sig then
      -- Confirmed. KEEP the next_at the dispatch set (now + AW_*INTERVAL) rather
      -- than firing again ~1s later: resetting it here bypassed the per-mode
      -- pacing, which made 'vbattle go' spam every 1-2s and gave each deploy no
      -- time to land in the feed before the next action raced it.
      aw_sm.phase = "idle"
    elseif now >= aw_sm.deadline then
      aw_sm.phase, aw_sm.next_at = "cooldown", now + AW_COOLDOWN
      aw_dbg(aw, "no confirmation for last action; brief pause")
    else
      return
    end
  end
  if aw_sm.phase == "cooldown" then
    if now < aw_sm.next_at then return end
    aw_sm.phase = "idle"
  end
  if now < aw_sm.next_at then return end

  aw.last = now
  local action, status, interval

  local b = state.battle
  if b and b.phase == "deploy" then
    action, status = aw_plan_deploy(aw, b)
    interval = AW_DEPLOY_INTERVAL
  elseif b then
    if aw.fight then action, status = aw_plan_orders(aw, b)
    else status = "battle live (auto-fight off)" end
    interval = AW_INTERVAL
  elseif state.war_map and state.war_map.active then
    if aw.campaign then action, status = aw_plan_campaign(aw, state.war_map)
    else status = "campaign live (auto-campaign off)" end
    interval = AW_CAMP_INTERVAL
  else
    -- No live battle/campaign. Priority: answer an incoming war, else open an
    -- offensive campaign (if enabled), else keep the army war-ready.
    if aw.defend and state.war and state.war.incoming
       and (state.war.incoming.days or 1) <= 0 then
      action = { cmd = "vcampaign defend", kind = "defend",
        desc = "an enemy host is upon us -- opening the defence" }
    else
      action, status = aw_plan_offense(aw)
      if not action then action, status = aw_plan_prep(aw) end
    end
    interval = AW_CAMP_INTERVAL
  end

  if action then
    aw_sm.sig = aw_sig()
    aw_dispatch(aw, action)
    aw_sm.phase, aw_sm.deadline = "confirming", now + AW_CONFIRM_TIMEOUT
    aw_sm.next_at = now + (interval or AW_INTERVAL)
    save()
  else
    aw.status = status or "idle"
    aw_dbg(aw, "idle -- " .. tostring(status))
    aw_sm.next_at = now + (interval or AW_INTERVAL)
  end
end

-- =======================================================================
-- 'awar' config alias
-- =======================================================================
local function aw_status_line(aw)
  ColourNote("orange", "", string.format(
    "[Auto-War] %s | deploy %s | fortify %s | fight %s | campaign %s | defend %s | offense %s | focus %s | retreat %s",
    page_opts.get("auto_battle") and "ON" or "OFF",
    aw.deploy and "on" or "off", aw.fortify and "on" or "off",
    aw.fight and "on" or "off", aw.campaign and "on" or "off",
    aw.defend and "on" or "off", aw.offense and "on" or "off",
    aw.focus, (aw.retreat_at or 0) > 0 and (aw.retreat_at .. "%") or "never"))
  ColourNote("darkorange", "", string.format(
    "  prep %s | levy %s (%d/6h) | muster %s (target %d) | replenish %s | train %s (batch %d) | reserve %dd",
    aw.prep and "on" or "off", aw.levy and "on" or "off", aw.levy_rate or 0,
    aw.muster and "on" or "off", aw.muster_target or 0,
    aw.replenish and "on" or "off", aw.train and "on" or "off", aw.train_batch or 0,
    aw.daler_reserve or 0))
  if aw.status and aw.status ~= "" then ColourNote("gray", "", "  status: " .. tostring(aw.status)) end
end

local function aw_usage()
  ColourNote("red", "", "[Auto-War] battle: awar on|off | deploy on|off | fortify on|off | "
    .. "fight on|off | focus <weakest|nearest|strongest> | retreat <n%|off>")
  ColourNote("red", "", "[Auto-War] campaign: campaign on|off | defend on|off | offense on|off | reinforce on|off")
  ColourNote("red", "", "[Auto-War] army prep: prep on|off | levy on|off | levyrate <n> | "
    .. "muster on|off | mustertarget <n> | replenish on|off | train on|off | batch <n> | reserve <n>")
  ColourNote("red", "", "[Auto-War] misc: verbose on|off | debug on|off | log [clear] | status")
end

local function aw_config(rest)
  local aw = aw_settings()
  rest = (rest or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")

  if rest == "on" then page_opts.set("auto_battle", true); ColourNote("orange", "", "[Auto-War] ON.")
  elseif rest == "off" then page_opts.set("auto_battle", false); ColourNote("orange", "", "[Auto-War] OFF.")
  elseif rest == "deploy on" then aw.deploy = true; ColourNote("orange", "", "[Auto-War] auto-deploy ON.")
  elseif rest == "deploy off" then aw.deploy = false; ColourNote("orange", "", "[Auto-War] auto-deploy OFF.")
  elseif rest == "fortify on" then aw.fortify = true; ColourNote("orange", "", "[Auto-War] fortify ON.")
  elseif rest == "fortify off" then aw.fortify = false; ColourNote("orange", "", "[Auto-War] fortify OFF.")
  elseif rest == "fight on" then aw.fight = true; ColourNote("orange", "", "[Auto-War] auto-fight ON.")
  elseif rest == "fight off" then aw.fight = false; ColourNote("orange", "", "[Auto-War] auto-fight OFF.")
  elseif rest == "campaign on" then aw.campaign = true; ColourNote("orange", "", "[Auto-War] auto-campaign ON.")
  elseif rest == "campaign off" then aw.campaign = false; ColourNote("orange", "", "[Auto-War] auto-campaign OFF.")
  elseif rest == "defend on" then aw.defend = true; ColourNote("orange", "", "[Auto-War] auto-defend ON.")
  elseif rest == "defend off" then aw.defend = false; ColourNote("orange", "", "[Auto-War] auto-defend OFF.")
  elseif rest == "offense on" or rest == "offence on" then aw.offense = true; ColourNote("orange", "", "[Auto-War] auto-offense ON (will declare war on claimed towns).")
  elseif rest == "offense off" or rest == "offence off" then aw.offense = false; ColourNote("orange", "", "[Auto-War] auto-offense OFF.")
  elseif rest == "reinforce on" then aw.reinforce = true; ColourNote("orange", "", "[Auto-War] reinforce ON.")
  elseif rest == "reinforce off" then aw.reinforce = false; ColourNote("orange", "", "[Auto-War] reinforce OFF.")
  elseif rest == "prep on" then aw.prep = true; ColourNote("orange", "", "[Auto-War] army prep ON.")
  elseif rest == "prep off" then aw.prep = false; ColourNote("orange", "", "[Auto-War] army prep OFF.")
  elseif rest == "levy on" then aw.levy = true; ColourNote("orange", "", "[Auto-War] auto-levy ON.")
  elseif rest == "levy off" then aw.levy = false; ColourNote("orange", "", "[Auto-War] auto-levy OFF.")
  elseif rest == "muster on" then aw.muster = true; ColourNote("orange", "", "[Auto-War] auto-muster ON.")
  elseif rest == "muster off" then aw.muster = false; ColourNote("orange", "", "[Auto-War] auto-muster OFF.")
  elseif rest == "replenish on" then aw.replenish = true; ColourNote("orange", "", "[Auto-War] replenish ON.")
  elseif rest == "replenish off" then aw.replenish = false; ColourNote("orange", "", "[Auto-War] replenish OFF.")
  elseif rest == "train on" then aw.train = true; ColourNote("orange", "", "[Auto-War] auto-train ON.")
  elseif rest == "train off" then aw.train = false; ColourNote("orange", "", "[Auto-War] auto-train OFF.")
  elseif rest == "verbose on" then aw.verbose = true; ColourNote("orange", "", "[Auto-War] verbose ON.")
  elseif rest == "verbose off" then aw.verbose = false; ColourNote("orange", "", "[Auto-War] verbose OFF.")
  elseif rest == "debug on" then aw.debug = true; ColourNote("orange", "", "[Auto-War] debug ON.")
  elseif rest == "debug off" then aw.debug = false; ColourNote("orange", "", "[Auto-War] debug OFF.")
  elseif rest == "retreat off" then aw.retreat_at = 0; ColourNote("orange", "", "[Auto-War] retreat: never.")
  elseif rest == "log clear" then aw.log = {}; ColourNote("orange", "", "[Auto-War] log cleared.")
  elseif rest == "log" then
    if #aw.log == 0 then ColourNote("orange", "", "[Auto-War] log is empty.")
    else
      ColourNote("orange", "", "[Auto-War] recent activity:")
      for _, e in ipairs(aw.log) do ColourNote("darkorange", "", "  " .. (e.t or "") .. " " .. (e.desc or "")) end
    end
  elseif rest == "" or rest == "status" then
    aw_status_line(aw)
  else
    local focus = rest:match("^focus%s+(%a+)$")
    if focus then
      if focus == "weakest" or focus == "nearest" or focus == "strongest" then
        aw.focus = focus; ColourNote("orange", "", "[Auto-War] focus-fire = " .. focus .. ".")
      else ColourNote("red", "", "[Auto-War] focus: weakest | nearest | strongest") end
      save(); return
    end
    local pct = rest:match("^retreat%s+(%d+)%%?$")
    if pct then aw.retreat_at = tonumber(pct); ColourNote("orange", "", "[Auto-War] retreat below " .. pct .. "% of the foe's power.")
      save(); return end
    local key, num = rest:match("^(%a+)%s+(%d+)$")
    if key == "levyrate" then aw.levy_rate = tonumber(num); ColourNote("orange", "", "[Auto-War] levy rate = " .. num .. " per 6h.")
    elseif key == "mustertarget" then aw.muster_target = tonumber(num); ColourNote("orange", "", "[Auto-War] muster target = " .. num .. " conscripts.")
    elseif key == "batch" then aw.train_batch = tonumber(num); ColourNote("orange", "", "[Auto-War] train batch = " .. num .. ".")
    elseif key == "reserve" then aw.daler_reserve = tonumber(num); ColourNote("orange", "", "[Auto-War] daler reserve = " .. num .. ".")
    else aw_usage(); return end
    save(); return
  end
  save()
end

-- Lera Auto-War adapter. The planner above is ported from the legacy Viking
-- plugin; MUSHclient aliases and pixel-window code are intentionally omitted.

local M = {}
M.name = "guild_viking_autowar"
M.version = "1.0"
M.AW_INTERVAL = AW_INTERVAL
M.AW_DEPLOY_INTERVAL = AW_DEPLOY_INTERVAL
M.AW_CAMP_INTERVAL = AW_CAMP_INTERVAL

function M.settings()
  return aw_settings()
end

function M.tick()
  auto_battle_tick()
end

function M.status()
  local aw = aw_settings()
  return {
    enabled = not not page_opts.get("auto_battle"),
    status = aw.status or "idle",
    last = aw.last or 0,
    phase = aw_sm.phase,
    next_at = aw_sm.next_at or 0,
  }
end

function M.config(rest)
  aw_config(rest)
end

function M.snapshot()
  return { autowar = aw_settings() }
end

function M.restore(tbl)
  if not (tbl and tbl.autowar) then return end
  local aw = aw_settings()
  for k, v in pairs(tbl.autowar) do aw[k] = v end
  if type(aw.log) ~= "table" then aw.log = {} end
end

return M
