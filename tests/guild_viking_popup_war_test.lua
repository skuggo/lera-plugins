-- guild_viking /vik war (War popup: campaign map + battle board composite)
-- unit tests. Run from the lera-plugins repo root with LERA_ROOT pointing
-- at a built Lera checkout.
package.path = "3scapes/guild_viking/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
  if ok then
    print("CASE " .. name .. ": PASS")
  else
    failures = failures + 1
    print("CASE " .. name .. ": FAIL" .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

local function find_plain(lines, needle)
  for _, l in ipairs(lines) do
    if l:find(needle, 1, true) then return true end
  end
  return false
end

-- ---- lera API stubs (same shape as guild_viking_popup_cityplan_test.lua) --
local function make_rect(x, y, w, h)
  return {
    x = function() return x end, y = function() return y end,
    w = function() return w end, h = function() return h end,
  }
end

local drawn
local function reset_drawn() drawn = { ansi = {} } end
reset_drawn()

local dirty_count = 0
ui = {
  dirty = function() dirty_count = dirty_count + 1 end,
  rect = function(x, y, w, h) return make_rect(x, y, w, h) end,
  text_ansi = function(r, s) drawn.ansi[#drawn.ansi + 1] = { x = r:x(), y = r:y(), s = s } end,
}

local render_pass = "local"
lera = { render_pass = function() return render_pass end, time = function() return 1000 end,
         version = function() return "test" end }

local send_calls = {}
mud = { send = function(s) send_calls[#send_calls + 1] = s end }

local printed = {}
buffer = {
  color_print = function(...)
    local args = { ... }
    local parts = {}
    for i = 3, #args, 3 do
      parts[#parts + 1] = tostring(args[i])
    end
    printed[#printed + 1] = table.concat(parts)
  end,
}

-- ---- wm.popup facade stub ---------------------------------------------------
local is_open_flag = false
local current_open = nil
local opens = {}
local close_count = 0
local function finish_popup()
  local old = current_open
  current_open = nil
  is_open_flag = false
  close_count = close_count + 1
  if old and old.opts and old.opts.on_close then old.opts.on_close() end
end
package.loaded["wm"] = {
  popup = {
    open = function(renderer, opts)
      if is_open_flag then finish_popup() end
      current_open = { renderer = renderer, opts = opts }
      is_open_flag = true
      opens[#opens + 1] = current_open
      return true
    end,
    close = function()
      if not is_open_flag then return false end
      finish_popup()
      return true
    end,
    is_open = function() return is_open_flag end,
  },
}

-- ---- menu stub (require("menu") facade) ------------------------------------
local last_menu_open = nil
local menu_close_count = 0
package.loaded["menu"] = {
  open = function(opts) last_menu_open = opts end,
  close = function() menu_close_count = menu_close_count + 1; last_menu_open = nil end,
  is_open = function() return last_menu_open ~= nil end,
}
local function menu_item_labels(opts)
  local labels = {}
  for _, it in ipairs(opts.items or {}) do
    labels[#labels + 1] = it.label
  end
  return labels
end
local function menu_has_label(opts, substr)
  for _, l in ipairs(menu_item_labels(opts)) do
    if tostring(l):find(substr, 1, true) then return true end
  end
  return false
end
local function menu_select(opts, label_substr)
  for _, it in ipairs(opts.items or {}) do
    if tostring(it.label):find(label_substr, 1, true) then
      opts.on_select(it.value)
      return true
    end
  end
  return false
end

local pagelib = require("pagelib")
local maplib = require("maplib")
local state = require("state")
local popups = require("popups")
local war_campaign = require("popups.war_campaign")
local war_battle = require("popups.war_battle")
local war = require("popups.war")

-- ---- real ingestion pipeline (protocol.ingest -> handlers.kingdom) -- the
-- standing lesson: fixtures MUST route through protocol.ingest + the real
-- handlers, never direct S. pokes.
local protocol = require("protocol")
-- init.lua's RESERVED set: the module-level convention fields, not MIP keys.
local RESERVED_KEYS = { _market_seam = true, _patterns = true, _gmcp = true,
                        _retired_keys = true, _retired_patterns = true }
local kingdom = require("handlers.kingdom")
for key, fn in pairs(kingdom._gmcp or {}) do
  protocol.gmcp_handler(key, fn)
end

local S = state.S
local C, RESET = pagelib.C, pagelib.RESET
local WIDTH = 76

-- Seeds a campaign war map through the production GMCP path. `rows`/`units`
-- are the natural fixture shapes, unchanged from when this seeded a
-- WMAP/WMR/WMO/WMEND burst; only what they are turned into has changed.
--
-- Callers describe an overlay as {id, c, r, size, f}, the shape MIP's WMO
-- used; the writer takes {kind, id, ...}, so the two sentinel ids are
-- translated here. "A" is your host and "*" the objective; anything else is a
-- numbered foe.
local UNIT_KIND = { A = "host", ["*"] = "objective" }

local function seed_wmap(t)
  local units = {}
  for _, u in ipairs(t.units or {}) do
    local kind = UNIT_KIND[u.id] or "foe"
    units[#units + 1] = { kind = kind, id = (kind == "foe") and u.id or "",
                          c = u.c or 0, r = u.r or 0, size = u.size or 0,
                          flag = u.f or "" }
  end
  -- `t.queues` is `{ [id] = { "A1", "B2", ... } }`; the payload is a flat list
  -- of {id, label} rows, and an id with no squares contributes none -- which
  -- is what kept it out of the wire string before.
  local queue = {}
  for id, sqs in pairs(t.queues or {}) do
    for _, sq in ipairs(sqs) do queue[#queue + 1] = { id = id, label = sq } end
  end
  local u = t.upkeep or {}
  local sp = t.spoils or {}
  protocol.on_gmcp("Guild.Kingdom", {
    guild = "viking",
    campaign = {
      active = (t.active ~= false) and 1 or 0,
      dim = t.dim or 0, turn = t.turn or 0, mode = t.mode or "offense",
      pending = t.pending or 0, town = t.town or "",
      works_budget = t.works_budget or 0, march_eta = t.march_eta or 0,
      upkeep_food = u.food or 0, upkeep_mead = u.mead or 0,
      upkeep_tools = u.tools or 0, upkeep_iron = u.iron or 0,
      upkeep_daler = u.daler or 0,
      -- The server calls the war-points spoil `wpts`; the client record has
      -- always called it renown.
      spoils_daler = sp.daler or 0, spoils_wpts = sp.renown or 0,
      spoils_deeds = sp.deeds or 0,
    },
    campaign_terrain = t.rows or {},
    campaign_units = units,
    campaign_queue = queue,
  })
end

-- Seeds a battle board. `units` entries: side "R" for a reserve unit
-- (label/size/uid/cost/leader), any other side for a fielded one ("Y" ->
-- S.battle.units[].side == "you"). `terrain_rows`/`works_rows` are 1-indexed
-- arrays in wire row order and now travel as rows rather than being
-- concatenated into one flat string.
local function seed_battle(t)
  local units, reserve = {}, {}
  for _, u in ipairs(t.units or {}) do
    if u.side == "R" then
      reserve[#reserve + 1] = { label = u.label or "", size = u.size or 0,
                                uid = u.uid or 0, cost = u.cost or 0,
                                leader = u.leader or "" }
    else
      units[#units + 1] = { side = u.side or "Y", label = u.label or "",
                            size = u.size or 0, coord = u.coord or "",
                            morale = u.morale or 0, type = u.utype or "",
                            leader = u.leader or "", bid = u.bid or 0,
                            g = u.g, ord = u.ord or 0 }
    end
  end
  protocol.on_gmcp("Guild.War", {
    guild = "viking",
    active = (t.active ~= false) and 1 or 0,
    phase = t.phase or "deploy", turn = t.turn or 0,
    war_points = t.war_points or 0, mode = t.mode or "field",
    target = t.target or "",
    budget = t.budget or 0, spent = t.spent or 0,
    w = t.width or 8, h = t.height or 8, dz = t.dz or 2,
    terrain = t.terrain_rows or {}, works = t.works_rows or {},
    units = units, reserve = reserve,
  })
end

local function reset_all()
  S.war_map, S.wm_pending, S.battle, S.war_points = nil, nil, nil, 0
  send_calls, last_menu_open, menu_close_count = {}, nil, 0
end

-- Exact-field helpers for grid assertions, same idiom as
-- guild_viking_popup_cityplan_test.lua's `field()`. The two boards in this
-- suite render at DIFFERENT maplib pitches and each needs its own helper:
--
--   field()  -- war_campaign, wide 3-char pitch (2-char glyph field + the
--              reserved east-edge slot). It stays wide because an enemy
--              army's marker is its own id string, which can be 2 chars.
--   bfield() -- war_battle, compact 1-char pitch. Its glyphs are all single
--              characters and it draws no headers, so the wide pitch spent
--              two of every three columns on padding.
--
-- There is deliberately no reverse-video variant here: `cell.sel` is
-- maplib's own rendering, covered exactly in
-- tests/guild_viking_maplib_test.lua for both pitches.
local function field(color, glyph)
  return color .. glyph .. " " .. RESET
end
local function bfield(color, glyph)
  return color .. glyph .. RESET
end

-- =============================================================================
-- war_campaign: no-data fallback
-- =============================================================================
reset_all()
local nodata = war_campaign.lines(WIDTH)
check("no war_map: header only", nodata[1] == pagelib.header(WIDTH, "Campaign Map"), nodata[1])
check("no war_map: exactly one line", #nodata == 1, #nodata)
check("no war_map: geometry nil", war_campaign.geometry(WIDTH) == nil)
check("no war_map: grid_line_offset is 1", war_campaign.grid_line_offset(WIDTH) == 1)

reset_all()
seed_wmap({ active = false, dim = 3, rows = { "...", "...", "..." } })
check("war_map inactive: geometry nil", war_campaign.geometry(WIDTH) == nil)

-- =============================================================================
-- war_campaign: grid terrain glyphs/colors (BGR workbook) + unit/dugout
-- overlays. dim=3: rows[0]="f.w" rows[1]="H.." rows[2]="..." (0,0)='f' and
-- (1,1)='.' are left as pure terrain (no overlay) for the terrain-only
-- check; every other cell carries an overlay marker.
-- =============================================================================
reset_all()
seed_wmap({
  dim = 3, turn = 7, town = "Jorvik",
  rows = { "f.w", "H..", "..." },
  units = {
    { id = "A", c = 0, r = 2, size = 10, f = "N" },
    { id = "F", c = 1, r = 2, size = 5 },
    { id = "*", c = 2, r = 0, size = 0 },
    { id = "3", c = 2, r = 1, size = 20 },
    { id = "P1", c = 0, r = 1, size = 0 },
    { id = "P9", c = 1, r = 0, size = 0 },
    { id = "u", c = 2, r = 2, size = 1 },
  },
})
check("war_map committed", S.war_map ~= nil and #S.war_map.rows == 3)

local offset = war_campaign.grid_line_offset(WIDTH)
local glines = war_campaign.lines(WIDTH)
local geom = war_campaign.geometry(WIDTH)
check("geometry non-nil once committed", geom ~= nil)

local function grid_line(gr) return glines[offset + gr + 1] end

-- row0 = "f.w": col0 'f' is pure terrain (unoverlaid, green); col1 '.' is
-- overridden by the P9 waystone landmark (white 'w'); col2 'w' is
-- overridden by the '*' objective (yellow), matching LEGACY's own
-- "objective glyph wins" overlay order (13840-13851 draws the marker on
-- top of whatever terrain/dugout occupies the cell).
check("row0: 'f'(0,0)=green woods (unoverlaid), 'w'(1,0)=white waystone (P9), '*'(2,0)=yellow objective",
  grid_line(0) == field(C.green, "f") .. " " .. field(C.white, "w") .. " " ..
    field(C.yellow, "*") .. " ", grid_line(0))
check("row1: 'w'(0,1)=dim landmark taken(P1), '.'(1,1)=dim plain (unoverlaid), '3'(2,1)=red enemy army",
  grid_line(1) == field(C.dim, "w") .. " " .. field(C.dim, ".") .. " " ..
    field(C.bright_red, "3") .. " ", grid_line(1))
check("row2: 'A'(0,2)=bright_green host, 'F'(1,2)=bright_cyan ally, 'u'(2,2)=white dugout",
  grid_line(2) == field(C.bright_green, "A") .. " " .. field(C.bright_cyan, "F") .. " " ..
    field(C.white, "u") .. " ", grid_line(2))

-- =============================================================================
-- war_campaign: hint text variants (pending battle / marching / holding)
-- =============================================================================
reset_all()
seed_wmap({ dim = 1, rows = { "." }, pending = 1 })
check("hint: battle awaits", find_plain(war_campaign.lines(WIDTH), "A battle awaits -- 'vcampaign fight'"))

reset_all()
seed_wmap({ dim = 1, rows = { "." }, march_eta = 125 })
check("hint: on the march (2m)", find_plain(war_campaign.lines(WIDTH), "On the march -- next tile in 2m"))

reset_all()
seed_wmap({ dim = 1, rows = { "." } })
check("hint: holding", find_plain(war_campaign.lines(WIDTH), "Holding -- 'vcampaign move <sq>'"))

-- =============================================================================
-- war_campaign: upkeep + spoils lines
-- =============================================================================
reset_all()
seed_wmap({
  dim = 1, rows = { "." },
  upkeep = { food = 10, mead = 5, tools = 2, iron = 1, daler = 50 },
  spoils = { daler = 200, renown = 15, deeds = 2 },
})
check("upkeep line", find_plain(war_campaign.lines(WIDTH),
  "Upkeep/tile: 10 food  5 mead  2 tools  1 iron  50d"))
check("spoils line", find_plain(war_campaign.lines(WIDTH),
  "Spoils if you win: 200 daler, 15 renown  (2 deeds)"))

-- =============================================================================
-- war_campaign: width discipline at 76 (a wider dim + long town name)
-- =============================================================================
reset_all()
local wide_rows = {}
for r = 0, 11 do
  local chars = {}
  for c = 0, 11 do chars[#chars + 1] = ({ "f", "H", "w", "." })[(c + r) % 4 + 1] end
  wide_rows[r + 1] = table.concat(chars)
end
seed_wmap({
  dim = 12, town = "A Very Long Settlement Name Indeed", rows = wide_rows,
  upkeep = { food = 999, mead = 999, tools = 999, iron = 999, daler = 99999 },
})
local wlines = war_campaign.lines(76)
local over_width = 0
for _, l in ipairs(wlines) do
  if pagelib.visible_width(l) > 76 then over_width = over_width + 1 end
end
check("war_campaign: no rendered line exceeds 76 visible columns", over_width == 0, over_width)

-- =============================================================================
-- war_campaign: select -> queue -> send flow (exact command strings),
-- deselect/clear semantics, out-of-grid/no-ctx safety, non-left no-op,
-- unconsumed "down" (bcamp_* wires no MouseDown).
-- =============================================================================
local function fixed_ctx(c, r)
  return { cell_from_xy = function() return c, r end, close = function() end }
end

reset_all()
seed_wmap({
  dim = 3, town = "Jorvik", rows = { "...", "...", "..." },
  units = { { id = "A", c = 0, r = 2, size = 10, f = "N" } },
})

local ok_down = war_campaign.on_pointer({ kind = "down", x = 0, y = 0, inside = true }, fixed_ctx(0, 2))
check("down on a bcamp cell IS consumed (fix round 2: capture requires it)", ok_down == true, ok_down)
check("down never sends", #send_calls == 0)

local ok_move = war_campaign.on_pointer({ kind = "move", x = 0, y = 0, inside = true }, fixed_ctx(0, 2))
check("move does not consume", ok_move == nil)
check("move over own stack shows hover with 'host (you)'",
  find_plain(war_campaign.lines(WIDTH), "host (you)"))

-- Click own stack at (0,2) -> selects "A" (sq A3), no send yet. Fix round
-- 3: track.matches() is now fail-CLOSED, so every "up" below that expects
-- an action needs its own matching "down" immediately first -- a real
-- gesture, not just an up sent cold.
war_campaign.on_pointer({ kind = "down", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(0, 2))
local ok_select = war_campaign.on_pointer({ kind = "up", x = 0, y = 0, inside = true, button = "left" },
  fixed_ctx(0, 2))
check("left-up on own stack consumes", ok_select == true)
check("selecting a stack never sends", #send_calls == 0)
check("selected-but-no-queue status line", find_plain(war_campaign.lines(WIDTH),
  "Selected A -- click a cell to queue a move, its own tile to hold & clear"))

-- Queue waypoint 1: (2,1) -> sq "C2".
send_calls = {}
war_campaign.on_pointer({ kind = "down", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(2, 1))
war_campaign.on_pointer({ kind = "up", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(2, 1))
check("queuing waypoint 1 sends the exact command", #send_calls == 1 and send_calls[1] == "vcampaign queue A C2",
  send_calls[1])

-- Queue waypoint 2: (1,0) -> sq "B1".
war_campaign.on_pointer({ kind = "down", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(1, 0))
war_campaign.on_pointer({ kind = "up", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(1, 0))
check("queuing waypoint 2 sends the exact command", #send_calls == 2 and send_calls[2] == "vcampaign queue A B1",
  send_calls[2])
check("queue status line lists both waypoints in order",
  find_plain(war_campaign.lines(WIDTH), "Queued for A: C2 -> B1"))

-- Click the selected stack's OWN (still unmoved) tile (0,2) -> deselect,
-- clear the queue, send "vcampaign hold".
send_calls = {}
war_campaign.on_pointer({ kind = "down", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(0, 2))
war_campaign.on_pointer({ kind = "up", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(0, 2))
check("clicking own tile sends 'vcampaign hold'", #send_calls == 1 and send_calls[1] == "vcampaign hold",
  send_calls[1])
check("deselect clears the queue status line",
  not find_plain(war_campaign.lines(WIDTH), "Selected A") and not find_plain(war_campaign.lines(WIDTH), "Queued for A"))

-- =============================================================================
-- war_campaign: queue status line prefers the SERVER-echoed queue
-- (S.war_map.queues[id], fed by WMQ/WMEND) over the local click-echo,
-- mirroring LEGACY's own `(wm.queues and wm.queues[id]) or (local queue)`
-- fallback (guild_viking.lua:13957-13959) exactly. Without this, a
-- multi-waypoint march would show a stale, ever-growing local list
-- instead of the shrinking server truth as the host actually arrives at
-- each tile.
-- =============================================================================
reset_all()
seed_wmap({
  dim = 3, rows = { "...", "...", "..." },
  units = { { id = "A", c = 0, r = 0, size = 10 } },
})
war_campaign.on_pointer({ kind = "down", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(0, 0))
war_campaign.on_pointer({ kind = "up", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(0, 0))
check("selected A ahead of the server-queue precedence check", find_plain(war_campaign.lines(WIDTH), "Selected A"))

-- Queue ONE local waypoint (sq "B2") before any server echo exists -- the
-- status line should show this local echo while wm.queues is absent.
send_calls = {}
war_campaign.on_pointer({ kind = "down", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(1, 1))
war_campaign.on_pointer({ kind = "up", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(1, 1))
check("local echo shown while no server queue exists yet",
  find_plain(war_campaign.lines(WIDTH), "Queued for A: B2"))

-- Server echoes back a DIFFERENT, longer queue via WMQ/WMEND (same grid,
-- same unit, so WMEND still commits) -- the status line must show the
-- SERVER's waypoints (C3 -> D4), not the stale local "B2".
seed_wmap({
  dim = 3, rows = { "...", "...", "..." },
  units = { { id = "A", c = 0, r = 0, size = 10 } },
  queues = { A = { "C3", "D4" } },
})
check("server queue present: status line shows the SERVER's waypoints, not the local echo",
  find_plain(war_campaign.lines(WIDTH), "Queued for A: C3 -> D4")
  and not find_plain(war_campaign.lines(WIDTH), "Queued for A: B2"))

-- Drain: the server reports the host has arrived at C3, leaving only D4 --
-- the status line must SHRINK to match, not keep showing C3.
seed_wmap({
  dim = 3, rows = { "...", "...", "..." },
  units = { { id = "A", c = 0, r = 0, size = 10 } },
  queues = { A = { "D4" } },
})
check("server queue drains: status line shrinks to the remaining waypoint",
  find_plain(war_campaign.lines(WIDTH), "Queued for A: D4")
  and not find_plain(war_campaign.lines(WIDTH), "C3"))

-- Server queue clears entirely (no WMQ entry for "A" in this burst at
-- all) -- falls back to the local echo (still "B2", untouched throughout).
seed_wmap({
  dim = 3, rows = { "...", "...", "..." },
  units = { { id = "A", c = 0, r = 0, size = 10 } },
})
check("S.war_map.queues.A is absent once the server stops echoing it",
  S.war_map.queues == nil or S.war_map.queues.A == nil)
check("server queue cleared: falls back to the local echo",
  find_plain(war_campaign.lines(WIDTH), "Queued for A: B2"))

-- Clean up: deselect via the current stack position (0,0) before the next
-- section re-seeds its own fixtures.
send_calls = {}
war_campaign.on_pointer({ kind = "down", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(0, 0))
war_campaign.on_pointer({ kind = "up", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(0, 0))
check("cleanup deselect after the server-queue precedence block",
  not find_plain(war_campaign.lines(WIDTH), "Selected A"))

-- Right-click (non-left) consumes but never acts. No preceding down needed
-- for the outcome (the action gate excludes any non-left button before
-- track.matches() is ever consulted), but sending one anyway keeps this a
-- genuine down+up gesture like every other case here.
send_calls = {}
war_campaign.on_pointer({ kind = "down", x = 0, y = 0, inside = true, button = "right" }, fixed_ctx(0, 2))
local ok_right = war_campaign.on_pointer({ kind = "up", x = 0, y = 0, inside = true, button = "right" },
  fixed_ctx(0, 2))
check("right-up consumes the cell", ok_right == true)
check("right-up never sends nor selects", #send_calls == 0
  and not find_plain(war_campaign.lines(WIDTH), "Selected"))

-- Clicking an empty/enemy-free tile with nothing selected is a no-op --
-- exercised via a real matched down+up so on_click's own "no selection,
-- no unit here" branch actually runs, rather than vacuously no-oping
-- because the fail-closed tracker blocked entry to on_click altogether.
send_calls = {}
war_campaign.on_pointer({ kind = "down", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(1, 1))
war_campaign.on_pointer({ kind = "up", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(1, 1))
check("clicking empty ground with no selection never sends", #send_calls == 0)
check("clicking empty ground with no selection selects nothing",
  not find_plain(war_campaign.lines(WIDTH), "Selected"))

-- =============================================================================
-- war_campaign: per-module smoke (a real down+up pair on the SAME cell
-- still selects/queues) + cross-target drag (fix round 2, Important #1: a
-- down on one cell followed by an up on a DIFFERENT cell must not queue a
-- waypoint for either). The fixture still active here is the one the
-- server-queue precedence block above left in place: dim=3, unit "A" at
-- (0,0) (not the (0,2) fixture from the earlier select/queue section).
-- =============================================================================
send_calls = {}
war_campaign.on_pointer({ kind = "down", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(0, 0))
war_campaign.on_pointer({ kind = "up", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(0, 0))
check("down+up on the SAME own-stack cell selects it, via a real down+up pair",
  find_plain(war_campaign.lines(WIDTH), "Selected A") and #send_calls == 0)

send_calls = {}
war_campaign.on_pointer({ kind = "down", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(2, 2))
war_campaign.on_pointer({ kind = "up", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(1, 1))
check("a down/up pair landing on DIFFERENT cells does not queue a waypoint",
  #send_calls == 0, send_calls[1])

-- The mismatched drag neither cleared nor consumed the selection above: a
-- genuinely matched down+up right after it still queues the exact waypoint.
send_calls = {}
war_campaign.on_pointer({ kind = "down", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(1, 1))
war_campaign.on_pointer({ kind = "up", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(1, 1))
check("selection survives the mismatched drag: the next matched click still queues",
  #send_calls == 1 and send_calls[1] == "vcampaign queue A B2", send_calls[1])

-- Cleanup: deselect via the stack's own (unmoved) position before the
-- sections below re-seed their own fixtures.
send_calls = {}
war_campaign.on_pointer({ kind = "down", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(0, 0))
war_campaign.on_pointer({ kind = "up", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(0, 0))
check("cleanup deselect after the smoke/cross-target block",
  not find_plain(war_campaign.lines(WIDTH), "Selected A"))

-- Stale-selection revalidation: re-seed a war_map where "A" no longer
-- exists; selecting it first via a fresh seed, then re-seeding without it,
-- then clicking must clear the stale selection instead of crashing.
reset_all()
seed_wmap({ dim = 2, rows = { "..", ".." }, units = { { id = "A", c = 0, r = 0, size = 10 } } })
war_campaign.on_pointer({ kind = "down", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(0, 0))
war_campaign.on_pointer({ kind = "up", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(0, 0))
check("selected A ahead of the revalidation check", find_plain(war_campaign.lines(WIDTH), "Selected A"))
reset_all()
seed_wmap({ dim = 2, rows = { "..", ".." }, units = { { id = "F", c = 1, r = 1, size = 5 } } })
send_calls = {}
war_campaign.on_pointer({ kind = "down", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(0, 0))
war_campaign.on_pointer({ kind = "up", x = 0, y = 0, inside = true, button = "left" }, fixed_ctx(0, 0))
check("stale 'A' selection is revalidated away (no crash, no stray send)", #send_calls == 0)
check("stale selection no longer shown", not find_plain(war_campaign.lines(WIDTH), "Selected A"))

-- out-of-grid / missing ctx safety
check("on_pointer with no ctx.cell_from_xy is a safe no-op",
  war_campaign.on_pointer({ kind = "down" }, {}) == nil)
local ok_oob = war_campaign.on_pointer({ kind = "up", button = "left" },
  { cell_from_xy = function() return nil end })
check("an out-of-grid ctx coordinate does not consume", ok_oob == nil)

-- =============================================================================
-- war_battle: no-battle fallback
-- =============================================================================
reset_all()
local nb = war_battle.lines(WIDTH)
check("no battle: header + 'No battle underway.'",
  nb[1] == pagelib.header(WIDTH, "Battle Board") and find_plain(nb, "No battle underway."))
check("no battle: geometry nil", war_battle.geometry(WIDTH) == nil)

-- =============================================================================
-- war_battle: deploy-phase grid content (BGR workbook), works overlay,
-- deploy-zone tint, unit-ordinal digit override.
--   width=3 height=2 dz=1 -- row_game 1 (bottom, in the deploy zone) holds
--   the works overlay; row_game 2 (top) is pure terrain plus a "you" unit
--   at A2 and a duplicated-ordinal enemy unit at C2.
-- =============================================================================
reset_all()
seed_battle({
  phase = "deploy", target = "Fjordvik", mode = "field", width = 3, height = 2, dz = 1,
  budget = 100, spent = 20, war_points = 15,
  terrain_rows = { "..#", "^*w" }, -- row1 (bottom) then row2 (top)
  works_rows = { "v.u", "..." },
  units = {
    { side = "Y", label = "Huscarl Guard", size = 8, coord = "A2", morale = 80,
      utype = "huscarls", bid = 101 },
    { side = "N", label = "Raider Warband", size = 6, coord = "C2", morale = 60,
      utype = "foe_raiders", ord = 2 },
    { side = "R", label = "Reserve Skirm", size = 5, uid = 55, cost = 10, leader = "Bjorn" },
  },
})
check("battle deploy committed", S.battle ~= nil and S.battle.phase == "deploy")

local boffset = war_battle.grid_line_offset(WIDTH)
local blines = war_battle.lines(WIDTH)
local bgeom = war_battle.geometry(WIDTH)
check("battle geometry non-nil", bgeom ~= nil)

local function bgrid_line(gr) return blines[boffset + gr + 1] end

-- gr=0 (top, row_game=2): A2 = you-unit override (huscarls "H", bright_green);
-- B2 = forest '*' green; C2 = enemy ordinal-2 override ("2", bright_red).
check("top row: A2 unit override, B2 forest, C2 ordinal-2 enemy override",
  bgrid_line(0) == bfield(C.bright_green, "H") .. bfield(C.green, "*") ..
    bfield(C.bright_red, "2"), bgrid_line(0))

-- gr=1 (bottom, row_game=1, in deploy zone): A1 = stakes 'v' yellow;
-- B1 = empty in-dz cell '+' bright_cyan; C1 = dugout 'u' white.
check("bottom row: A1 stakes, B1 deploy-zone '+', C1 dugout",
  bgrid_line(1) == bfield(C.yellow, "v") .. bfield(C.bright_cyan, "+") ..
    bfield(C.white, "u"), bgrid_line(1))

check("legend: side colours + deploy hint present",
  find_plain(blines, "green = you") and find_plain(blines, "red = foe") and find_plain(blines, "+ deploy"))
check("legend: unit-type key letters present", find_plain(blines, "huscarl") and find_plain(blines, "raiders"))
check("legend: terrain key present", find_plain(blines, "fjord") and find_plain(blines, "rampart"))
check("command/fraegd line", find_plain(blines, "Command 20/100") and find_plain(blines, "Fraegd 15"))
check("actions line (deploy phase)", find_plain(blines, "[Actions] Begin Battle | Abandon"))

-- =============================================================================
-- war_battle: deploy-phase [Actions] menu -- "Begin Battle" sends the exact
-- command (fix round 2, Important #2: previously untested; only the
-- turn-phase "Advance Turn"/"Abandon" pair had send-exactness coverage).
-- =============================================================================
do
  local deploy_idx = war_battle.actions_line_index(WIDTH)
  check("deploy actions_line_index is non-nil while deploying", deploy_idx ~= nil)
  last_menu_open = nil
  war_battle.on_pointer({ kind = "down", width = WIDTH },
    { line_from_y = function() return deploy_idx end })
  check("a down on the deploy [Actions] line opens the actions menu", last_menu_open ~= nil)
  check("deploy-phase actions menu offers Begin Battle + Abandon",
    menu_has_label(last_menu_open, "Begin Battle") and menu_has_label(last_menu_open, "Abandon"))
  send_calls = {}
  menu_select(last_menu_open, "Begin Battle")
  check("selecting Begin Battle sends 'vbattle begin' exactly",
    #send_calls == 1 and send_calls[1] == "vbattle begin", send_calls[1])
  -- Clean up the down-target tracker's leftover "actions" record (a
  -- module-local singleton, like war_campaign's `selected`) via a
  -- synthesized cancel, matching how popup.lua itself clears a captured
  -- renderer's record when the popup closes mid-interaction -- otherwise
  -- the very next section's grid up-events below would mismatch against
  -- this stale "actions" target and never fire.
  war_battle.on_pointer({ kind = "cancel" }, {})
end

-- =============================================================================
-- war_battle: deploy-phase right-click menus (own unit / empty in-dz with
-- reserve / not-your-deploy-zone), left-click closes without sending.
-- =============================================================================
local function bfixed_ctx(gc, gr)
  return { cell_from_xy = function() return gc, gr end, line_from_y = function(y) return y end }
end

-- Right-click own unit at A2 (gc=0, gr=0) -> "Undeploy Huscarl Guard". Fix
-- round 3: track.matches() is now fail-CLOSED, so every "up" below needs
-- its own matching "down" immediately first.
send_calls = {}
last_menu_open = nil
war_battle.on_pointer({ kind = "down", button = "right" }, bfixed_ctx(0, 0))
local ok_undeploy = war_battle.on_pointer({ kind = "up", button = "right" }, bfixed_ctx(0, 0))
check("right-up on own unit consumes", ok_undeploy == true)
check("undeploy menu offers exactly 2 items (Undeploy + Cancel)",
  last_menu_open ~= nil and #last_menu_open.items == 2, last_menu_open and #last_menu_open.items)
check("undeploy item label", menu_has_label(last_menu_open, "Undeploy Huscarl Guard"))
menu_select(last_menu_open, "Undeploy Huscarl Guard")
check("selecting Undeploy sends the exact command",
  #send_calls == 1 and send_calls[1] == "vbattle undeploy 101", send_calls[1])

-- Right-click empty in-dz cell B1 (gc=1, gr=1) -> reserve deploy + fortify + cancel.
send_calls = {}
last_menu_open = nil
war_battle.on_pointer({ kind = "down", button = "right" }, bfixed_ctx(1, 1))
war_battle.on_pointer({ kind = "up", button = "right" }, bfixed_ctx(1, 1))
check("in-dz empty-cell menu offers 4 items (1 reserve + 2 fortify + cancel)",
  last_menu_open ~= nil and #last_menu_open.items == 4, last_menu_open and #last_menu_open.items)
check("reserve deploy item text", menu_has_label(last_menu_open, "Deploy 5x Reserve Skirm (10 pts)"))
menu_select(last_menu_open, "Deploy 5x Reserve Skirm")
check("selecting the reserve item sends the exact deploy command",
  #send_calls == 1 and send_calls[1] == "vbattle deploy 55 B1", send_calls[1])

send_calls = {}
last_menu_open = nil
war_battle.on_pointer({ kind = "down", button = "right" }, bfixed_ctx(1, 1))
war_battle.on_pointer({ kind = "up", button = "right" }, bfixed_ctx(1, 1))
menu_select(last_menu_open, "Fortify: Stakes")
check("Fortify: Stakes sends the exact command",
  #send_calls == 1 and send_calls[1] == "vbattle fortify stakes B1", send_calls[1])
send_calls = {}
war_battle.on_pointer({ kind = "down", button = "right" }, bfixed_ctx(1, 1))
war_battle.on_pointer({ kind = "up", button = "right" }, bfixed_ctx(1, 1))
menu_select(last_menu_open, "Fortify: Dugout")
check("Fortify: Dugout sends the exact command",
  #send_calls == 1 and send_calls[1] == "vbattle fortify dugout B1", send_calls[1])

-- Right-click the enemy-occupied, non-dz cell C2 (gc=2, gr=0) -> "Not your
-- deploy zone" + Cancel (LEGACY ignores the occupant here -- ported as-is).
last_menu_open = nil
war_battle.on_pointer({ kind = "down", button = "right" }, bfixed_ctx(2, 0))
war_battle.on_pointer({ kind = "up", button = "right" }, bfixed_ctx(2, 0))
check("non-dz cell menu offers 'Not your deploy zone' + Cancel",
  last_menu_open ~= nil and #last_menu_open.items == 2
  and menu_has_label(last_menu_open, "Not your deploy zone") and menu_has_label(last_menu_open, "Cancel"),
  last_menu_open and table.concat(menu_item_labels(last_menu_open), " | "))
send_calls = {}
menu_select(last_menu_open, "Not your deploy zone")
check("the decorative item never sends", #send_calls == 0)

-- Regression: an ENEMY occupying a cell INSIDE your own deploy zone still
-- gets the reserve-deploy/fortify branch, not "Not your deploy zone" --
-- LEGACY's own `elseif info.in_dz then` check (13457) never looks at
-- `info.unit` at all, so an enemy sitting in your dz is bug-for-bug
-- offered as if the cell were empty. Ported as-is (not "fixed"), on a
-- fresh minimal 1x1 board so the enemy occupies the ENTIRE dz. No
-- reset_all() here -- seed_battle() alone fully replaces S.battle, and
-- the deploy battle seeded above is restored right after this check so
-- the tests that follow keep seeing its original width=3 shape.
seed_battle({
  phase = "deploy", target = "Fjordvik", width = 1, height = 1, dz = 1,
  terrain_rows = { "." }, works_rows = { "." },
  units = {
    { side = "N", label = "Squatting Raider", size = 4, coord = "A1", morale = 50, utype = "foe_raiders" },
    { side = "R", label = "Reserve Skirm", size = 5, uid = 55, cost = 10, leader = "Bjorn" },
  },
})
last_menu_open = nil
war_battle.on_pointer({ kind = "down", button = "right" }, bfixed_ctx(0, 0))
war_battle.on_pointer({ kind = "up", button = "right" }, bfixed_ctx(0, 0))
check("enemy-occupied in-dz cell still offers the reserve-deploy branch (bug-for-bug)",
  last_menu_open ~= nil and not menu_has_label(last_menu_open, "Not your deploy zone")
  and menu_has_label(last_menu_open, "Deploy 5x Reserve Skirm")
  and menu_has_label(last_menu_open, "Fortify: Stakes"),
  last_menu_open and table.concat(menu_item_labels(last_menu_open), " | "))
send_calls = {}
menu_select(last_menu_open, "Deploy 5x Reserve Skirm")
check("selecting the reserve item there sends the exact deploy command (ignoring the occupant)",
  #send_calls == 1 and send_calls[1] == "vbattle deploy 55 A1", send_calls[1])

-- Restore the original width=3/height=2 deploy battle for the tests below.
seed_battle({
  phase = "deploy", target = "Fjordvik", mode = "field", width = 3, height = 2, dz = 1,
  budget = 100, spent = 20, war_points = 15,
  terrain_rows = { "..#", "^*w" },
  works_rows = { "v.u", "..." },
  units = {
    { side = "Y", label = "Huscarl Guard", size = 8, coord = "A2", morale = 80,
      utype = "huscarls", bid = 101 },
    { side = "N", label = "Raider Warband", size = 6, coord = "C2", morale = 60,
      utype = "foe_raiders", ord = 2 },
    { side = "R", label = "Reserve Skirm", size = 5, uid = 55, cost = 10, leader = "Bjorn" },
  },
})

-- Left-click anywhere on the deploy board just closes any open menu.
last_menu_open = { items = { { label = "x", value = false } }, on_select = function() end }
menu_close_count = 0
send_calls = {}
war_battle.on_pointer({ kind = "down", button = "left" }, bfixed_ctx(1, 1))
local ok_left_close = war_battle.on_pointer({ kind = "up", button = "left" }, bfixed_ctx(1, 1))
check("left-up in deploy phase consumes", ok_left_close == true)
check("left-up closes any open menu", menu_close_count == 1)
check("left-up never sends", #send_calls == 0)

-- =============================================================================
-- war_battle: turn-phase select -> move-order flow (exact command strings),
-- same-tile deselect, right-click cancels selection.
-- width=2 height=2: "you" unit at A1 (gc=0,gr=1), enemy at B2 (gc=1,gr=0).
-- =============================================================================
reset_all()
seed_battle({
  phase = "turn", turn = 4, target = "Fjordvik", width = 2, height = 2, dz = 1,
  budget = 100, spent = 40, war_points = 22,
  terrain_rows = { "..", ".." },
  units = {
    { side = "Y", label = "Shieldwall", size = 10, coord = "A1", morale = 70,
      utype = "shieldwall", bid = 201 },
    { side = "N", label = "Levy Rabble", size = 12, coord = "B2", morale = 40,
      utype = "foe_levy" },
  },
})
check("battle turn-phase committed", S.battle ~= nil and S.battle.phase == "turn")

-- Fix round 3: track.matches() is now fail-CLOSED, so every "up" below
-- needs its own matching "down" immediately first -- a real gesture.
send_calls = {}
war_battle.on_pointer({ kind = "down", button = "left" }, bfixed_ctx(0, 1))
local ok_pick = war_battle.on_pointer({ kind = "up", button = "left" }, bfixed_ctx(0, 1))
check("left-up on own unit (turn phase) consumes", ok_pick == true)
check("selecting a unit never sends", #send_calls == 0)

war_battle.on_pointer({ kind = "down", button = "left" }, bfixed_ctx(1, 0))
war_battle.on_pointer({ kind = "up", button = "left" }, bfixed_ctx(1, 0))
check("left-up on a different cell sends the exact order command",
  #send_calls == 1 and send_calls[1] == "vbattle order 201 B2", send_calls[1])

-- Re-select, then click the SAME cell -> deselect, no send.
war_battle.on_pointer({ kind = "down", button = "left" }, bfixed_ctx(0, 1))
war_battle.on_pointer({ kind = "up", button = "left" }, bfixed_ctx(0, 1))
send_calls = {}
war_battle.on_pointer({ kind = "down", button = "left" }, bfixed_ctx(0, 1))
war_battle.on_pointer({ kind = "up", button = "left" }, bfixed_ctx(0, 1))
check("clicking the same cell twice deselects without sending", #send_calls == 0)

-- Re-select, then right-click -> cancels selection and closes any menu.
war_battle.on_pointer({ kind = "down", button = "left" }, bfixed_ctx(0, 1))
war_battle.on_pointer({ kind = "up", button = "left" }, bfixed_ctx(0, 1))
menu_close_count = 0
send_calls = {}
war_battle.on_pointer({ kind = "down", button = "right" }, bfixed_ctx(0, 1))
war_battle.on_pointer({ kind = "up", button = "right" }, bfixed_ctx(0, 1))
check("right-up cancels the selection", menu_close_count == 1)
check("right-up never sends", #send_calls == 0)
-- Confirm the cancel actually cleared selection: clicking a bare cell next
-- with nothing selected and no own unit there must not send an order.
war_battle.on_pointer({ kind = "down", button = "left" }, bfixed_ctx(1, 0))
war_battle.on_pointer({ kind = "up", button = "left" }, bfixed_ctx(1, 0))
check("post-cancel click on the enemy cell does not order a move (nothing was selected)",
  #send_calls == 0)

-- =============================================================================
-- war_battle: per-module smoke -- a real down+up pair on the SAME cell still
-- works end to end (fix round 2, Important #1: down now consumes and
-- records a target, so this proves that didn't break the ordinary case).
-- =============================================================================
send_calls = {}
war_battle.on_pointer({ kind = "down", button = "left" }, bfixed_ctx(0, 1))
war_battle.on_pointer({ kind = "up", button = "left" }, bfixed_ctx(0, 1))
check("down+up on the SAME own-unit cell selects it", #send_calls == 0)
war_battle.on_pointer({ kind = "down", button = "left" }, bfixed_ctx(1, 0))
war_battle.on_pointer({ kind = "up", button = "left" }, bfixed_ctx(1, 0))
check("down+up on the SAME target cell sends the exact order command",
  #send_calls == 1 and send_calls[1] == "vbattle order 201 B2", send_calls[1])

-- =============================================================================
-- war_battle: cross-target drag -- a down on one cell followed by an up on
-- a DIFFERENT cell must not fire the up cell's action (fix round 2,
-- Important #1). Re-select Shieldwall (matched down+up on A1), then down on
-- the empty cell B1 but release over the enemy at B2 -- if down/up cells
-- were not required to match, this would incorrectly send a move order.
-- =============================================================================
war_battle.on_pointer({ kind = "down", button = "left" }, bfixed_ctx(0, 1))
war_battle.on_pointer({ kind = "up", button = "left" }, bfixed_ctx(0, 1))
send_calls = {}
war_battle.on_pointer({ kind = "down", button = "left" }, bfixed_ctx(1, 1))
war_battle.on_pointer({ kind = "up", button = "left" }, bfixed_ctx(1, 0))
check("a down/up pair landing on DIFFERENT cells does not fire the up cell's action",
  #send_calls == 0, send_calls[1])
-- The mismatched drag neither cleared nor consumed the earlier selection: a
-- genuinely matched down+up on B2 right after it still sends the order.
war_battle.on_pointer({ kind = "down", button = "left" }, bfixed_ctx(1, 0))
war_battle.on_pointer({ kind = "up", button = "left" }, bfixed_ctx(1, 0))
check("selection survives the mismatched drag: the next matched click still orders the move",
  #send_calls == 1 and send_calls[1] == "vbattle order 201 B2", send_calls[1])

-- Hover text on move.
war_battle.on_pointer({ kind = "move", x = 0, y = 0 }, bfixed_ctx(0, 1))
check("hover over own unit shows name/side/size/morale",
  find_plain(war_battle.lines(WIDTH), "Shieldwall (yours)") and find_plain(war_battle.lines(WIDTH), "10 men")
  and find_plain(war_battle.lines(WIDTH), "morale 70"))

-- =============================================================================
-- war_battle: actions line (turn phase: Advance Turn + Abandon)
-- =============================================================================
local idx = war_battle.actions_line_index(WIDTH)
check("actions_line_index is non-nil while a battle is active", idx ~= nil)
last_menu_open = nil
war_battle.on_pointer({ kind = "down", y = 0 }, { line_from_y = function(y) return y end })
-- y=0 maps (via the identity line_from_y stub) to line index 0, which is
-- never the actions line -- confirms a down elsewhere does NOT open it.
check("a down elsewhere on the board does not open the actions menu", last_menu_open == nil)

war_battle.on_pointer({ kind = "down" }, { line_from_y = function() return idx end })
check("a down on the actions line opens the actions menu", last_menu_open ~= nil)
check("turn-phase actions menu offers Advance Turn + Abandon",
  menu_has_label(last_menu_open, "Advance Turn") and menu_has_label(last_menu_open, "Abandon"))
send_calls = {}
menu_select(last_menu_open, "Advance Turn")
check("selecting Advance Turn sends 'vbattle go'", #send_calls == 1 and send_calls[1] == "vbattle go", send_calls[1])

war_battle.on_pointer({ kind = "down" }, { line_from_y = function() return idx end })
send_calls = {}
menu_select(last_menu_open, "Abandon")
check("selecting Abandon sends 'vbattle abandon'",
  #send_calls == 1 and send_calls[1] == "vbattle abandon", send_calls[1])

-- =============================================================================
-- war_battle: width discipline at 76 (a bigger board + long labels)
-- =============================================================================
reset_all()
local function repeat_row(ch, n) return string.rep(ch, n) end
seed_battle({
  phase = "turn", target = "A Very Long Enemy Settlement Name", width = 10, height = 4, dz = 2,
  budget = 999, spent = 999, war_points = 9999,
  terrain_rows = { repeat_row(".", 10), repeat_row("^", 10), repeat_row("*", 10), repeat_row("=", 10) },
  works_rows = { repeat_row(".", 10), repeat_row(".", 10), repeat_row(".", 10), repeat_row(".", 10) },
  units = {
    { side = "Y", label = "A Very Long Unit Label Indeed", size = 99, coord = "A1", morale = 100,
      utype = "moose", bid = 1 },
  },
})
local blines_wide = war_battle.lines(76)
local bover = 0
for _, l in ipairs(blines_wide) do
  if pagelib.visible_width(l) > 76 then bover = bover + 1 end
end
check("war_battle: no rendered line exceeds 76 visible columns", bover == 0, bover)

-- =============================================================================
-- war (composite): mode follows state -- battle takes priority, campaign
-- otherwise, "nothing to show" when neither is active.
-- =============================================================================
reset_all()
seed_wmap({
  dim = 2, town = "Havn", rows = { "..", ".." },
  units = { { id = "A", c = 0, r = 0, size = 10 } },
})
seed_battle({
  phase = "deploy", target = "Havn", width = 2, height = 2, dz = 1,
  terrain_rows = { "..", ".." }, works_rows = { "..", ".." },
})
check("both war_map.active and battle present: composite delegates to war_battle",
  table.concat(war.lines(WIDTH), "\n") == table.concat(war_battle.lines(WIDTH), "\n"))
check("composite geometry delegates to war_battle",
  war.geometry(WIDTH) ~= nil and war.grid_line_offset(WIDTH) == war_battle.grid_line_offset(WIDTH))

-- End the battle: composite falls back to the campaign map. Cleared via
-- the real BATTLE handler (active=0), not a direct S.battle poke -- same
-- standing lesson as every fixture in this file: state transitions go
-- through protocol.ingest so the handler's own clearing logic (here,
-- kingdom.lua's `M.BATTLE` setting `S.battle = nil` whenever `active ~=
-- "1"`) is what's actually exercised.
seed_battle({ active = false })
check("BATTLE active=0 cleared S.battle via the real handler", S.battle == nil)
check("battle cleared, war_map still active: composite delegates to war_campaign",
  table.concat(war.lines(WIDTH), "\n") == table.concat(war_campaign.lines(WIDTH), "\n"))
check("composite grid_line_offset delegates to war_campaign",
  war.grid_line_offset(WIDTH) == war_campaign.grid_line_offset(WIDTH))

-- Neither active: a plain fallback line. Cleared via the real WMAP/WMEND
-- handlers (active=0), same reasoning as the BATTLE clear just above --
-- `seed_wmap({ active = false })` sends WMAP active=0 then WMEND, and
-- kingdom.lua's `M.WMEND` sets `S.war_map = nil` whenever
-- `wm_pending.active` is false, regardless of row count.
seed_wmap({ active = false })
check("WMAP active=0 + WMEND cleared S.war_map via the real handlers", S.war_map == nil)
local neither = war.lines(WIDTH)
check("neither active: single fallback line", #neither == 1
  and find_plain(neither, "No campaign or battle underway."), neither[1])
check("neither active: on_pointer/geometry are safe no-ops",
  war.on_pointer({ kind = "down" }, {}) == nil and war.geometry(WIDTH) == nil
  and war.grid_line_offset(WIDTH) == 0)

-- on_pointer delegation, end to end: re-seed campaign-only, select via the
-- COMPOSITE's on_pointer, confirm the underlying war_campaign module state
-- actually changed (shared module singleton).
reset_all()
seed_wmap({
  dim = 2, rows = { "..", ".." },
  units = { { id = "A", c = 0, r = 0, size = 10 } },
})
-- Fix round 3: track.matches() is now fail-CLOSED, so a real down through
-- the COMPOSITE's own on_pointer must precede each up -- also exercises
-- war.lua's own gesture pinning (the down's consumed result pins this
-- gesture to war_campaign, per its header comment).
send_calls = {}
war.on_pointer({ kind = "down", button = "left" }, fixed_ctx(0, 0))
war.on_pointer({ kind = "up", button = "left" }, fixed_ctx(0, 0))
check("composite on_pointer delegates the select to war_campaign",
  find_plain(war_campaign.lines(WIDTH), "Selected A"))
war.on_pointer({ kind = "down", button = "left" }, fixed_ctx(1, 1))
war.on_pointer({ kind = "up", button = "left" }, fixed_ctx(1, 1))
check("composite on_pointer delegates the queue-and-send to war_campaign",
  #send_calls == 1 and send_calls[1] == "vcampaign queue A B2", send_calls[1])

-- Clean up war_campaign's module-local selection (it's a shared singleton
-- across this whole test file) before the next section re-seeds a fresh
-- war_map with a unit at the same coordinates -- otherwise that section's
-- first click would DESELECT (this leftover selection's stack is still at
-- (0,0)) instead of selecting fresh, exactly the semantics being tested.
war.on_pointer({ kind = "down", button = "left" }, fixed_ctx(0, 0))
war.on_pointer({ kind = "up", button = "left" }, fixed_ctx(0, 0))
check("cleanup click deselects", not find_plain(war_campaign.lines(WIDTH), "Selected A"))

-- =============================================================================
-- popups.lua registration: /vik war opens the composite, titled "War", and
-- the wrapper's ctx.cell_from_xy plumbing works end to end.
-- =============================================================================
reset_all()
seed_wmap({
  dim = 2, rows = { "..", ".." },
  units = { { id = "A", c = 0, r = 0, size = 10 } },
})

is_open_flag = false
opens = {}
close_count = 0
check("popups.toggle('war') opens (war self-registers in popups.lua)", popups.toggle("war") == true)
local renderer = opens[#opens].renderer
check("wrapper is titled 'War' from the composite module", opens[#opens].opts.title == "War")
check("wrapper exposes on_pointer for the war composite", type(renderer.on_pointer) == "function")

local rect_h = 10
reset_drawn()
renderer.render(make_rect(0, 0, WIDTH, rect_h), { title = "War" })

local pre_offset = war_campaign.grid_line_offset(WIDTH)
local wrapper_y_row0 = pre_offset
check("row 0 is within the visible rect at zero scroll", wrapper_y_row0 < rect_h, wrapper_y_row0)
send_calls = {}
renderer.on_pointer({ kind = "down", x = 0, y = wrapper_y_row0, inside = true, button = "left" })
renderer.on_pointer({ kind = "up", x = 0, y = wrapper_y_row0, inside = true, button = "left" })
check("wrapper's ctx.cell_from_xy maps wrapper-local (x,y) to grid cell (0,0), selecting the host",
  find_plain(war_campaign.lines(WIDTH), "Selected A"))

send_calls = {}
local ok_wired_oob = renderer.on_pointer({ kind = "up", x = 0, y = 1000, inside = false, button = "left" })
check("an out-of-grid wrapper coordinate does not send to the MUD", #send_calls == 0)

if is_open_flag then package.loaded["wm"].popup.close() end

-- =============================================================================
-- war_battle: per-unit letter handles. The server gives every unit on the
-- board its own letter for the battle -- lowercase yours, uppercase the foe's
-- -- so a glyph names exactly one unit instead of a type shared by several.
-- The board draws that letter, and the unit key is built from the units on
-- the board rather than from the static type list.
-- =============================================================================
reset_all()
seed_battle({
  phase = "deploy", turn = 0, mode = "field", target = "Jorvik",
  width = 3, height = 2, dz = 1,
  budget = 100, spent = 20, war_points = 15,
  terrain_rows = { "...", "..." },
  works_rows = { "...", "..." },
  units = {
    -- Two units of ONE type on ONE side: the case that used to draw a pair of
    -- indistinguishable "S" tiles, then a pair of ordinals that collided with
    -- every other type's ordinals.
    { side = "Y", label = "First Wall", size = 8, coord = "A2", morale = 80,
      utype = "shieldwall", bid = 101, g = "a" },
    { side = "Y", label = "Second Wall", size = 8, coord = "B2", morale = 80,
      utype = "shieldwall", bid = 102, g = "b" },
    { side = "N", label = "Raider Warband", size = 6, coord = "C2", morale = 60,
      utype = "foe_raiders", bid = 103, g = "A" },
  },
})

local glines = war_battle.lines(WIDTH)
local goffset = war_battle.grid_line_offset(WIDTH)
local function ggrid_line(gr) return glines[goffset + gr + 1] end

check("two units of one type draw as two DIFFERENT letters, not one shared glyph",
  ggrid_line(0) == bfield(C.bright_green, "a") .. bfield(C.bright_green, "b") ..
    bfield(C.bright_red, "A"), ggrid_line(0))

check("the foe's letter is uppercase and red",
  ggrid_line(0):find("A", 1, true) ~= nil and ggrid_line(0):find(C.bright_red, 1, true) ~= nil)

-- The key is now a one-line roster: letter -> what that letter is.
check("unit key lists each unit's own letter",
  find_plain(glines, "a") and find_plain(glines, "b") and find_plain(glines, "wall"))
check("unit key still names the foe's type", find_plain(glines, "raiders"))

-- A server that sends no letters must still render the old way, so the plugin
-- keeps working against an un-upgraded MUD.
reset_all()
seed_battle({
  phase = "deploy", turn = 0, mode = "field", target = "Jorvik",
  width = 3, height = 2, dz = 1,
  budget = 100, spent = 20, war_points = 15,
  terrain_rows = { "...", "..." },
  works_rows = { "...", "..." },
  units = {
    { side = "Y", label = "Huscarl Guard", size = 8, coord = "A2", morale = 80,
      utype = "huscarls", bid = 101 },
    { side = "N", label = "Raider Warband", size = 6, coord = "C2", morale = 60,
      utype = "foe_raiders", bid = 103, ord = 2 },
  },
})
local olines = war_battle.lines(WIDTH)
local ooffset = war_battle.grid_line_offset(WIDTH)
check("without letters the board falls back to type glyph + ordinal",
  olines[ooffset + 1]:find("H", 1, true) ~= nil and
  olines[ooffset + 1]:find("2", 1, true) ~= nil, olines[ooffset + 1])
check("without letters the static type key is used", find_plain(olines, "huscarl"))

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING POPUP WAR TESTS PASSED")
