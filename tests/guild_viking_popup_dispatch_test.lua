-- Dispatch-layer tests for the guild_viking popups, driven through the REAL
-- scripts/default/popup.lua -- not the direct on_pointer(ev, ctx) calls
-- every per-popup unit suite (guild_viking_popup_war_test.lua and friends)
-- uses. This is fix round 2's Fix 0, the systemic gap the whole-branch
-- review named as the enabler for both Critical findings: popup.lua's real
-- dispatch has its OWN capture/hit-test rules (a "down" must return `true`
-- for the popup layer to ever deliver the matching "up" at all; a captured
-- "up" is delivered at whatever coordinates the release landed on, not
-- re-hit-tested against the down) -- rules no test exercised before this
-- file, which is exactly how war_campaign.lua's down-not-consumed bug
-- (Critical #1) and war_battle.lua's fixed-probe-width bug (Critical #2)
-- both shipped invisibly: calling on_pointer directly with a synthetic "up"
-- event, as every per-popup suite does, bypasses popup.lua's capture logic
-- entirely and cannot see either one.
--
-- Run from the lera-plugins repo root with LERA_ROOT pointing at a built Lera
-- checkout. scripts/default/popup.lua is reached through LERA_ROOT rather than
-- a path relative to the cwd: run_tests.sh resolves the Lera checkout as a
-- SIBLING of lera-plugins, so the "../scripts/default" this once used only
-- resolved when the repo sat inside Lera as plugins/ -- see tests/popup_test.lua
-- (run from the Lera repo root instead) for the same module loaded the other way.
local lera_root = assert(os.getenv("LERA_ROOT"), "LERA_ROOT is required")
lera_root = lera_root:gsub("/+$", "")
package.path = "3scapes/guild_viking/?.lua;" .. lera_root
  .. "/scripts/default/?.lua;" .. package.path

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

-- ---- stub globals: ui/lera/bind (scripts/default/popup.lua's own deps,
-- copied from tests/popup_test.lua's preamble) plus mud/buffer/menu (the
-- guild_viking popup modules' deps, copied from the per-popup suites). ----
local function make_rect(x, y, w, h)
  return {
    x = function() return x end, y = function() return y end,
    w = function() return w end, h = function() return h end,
  }
end

local dirty_count = 0
local drawn
local function reset_drawn() drawn = { boxes = {}, ansi = {} } end
reset_drawn()

ui = {
  dirty = function() dirty_count = dirty_count + 1 end,
  rect = function(x, y, w, h) return make_rect(x, y, w, h) end,
  shrink = function(r, n) return make_rect(r:x() + n, r:y() + n, r:w() - 2 * n, r:h() - 2 * n) end,
  box = function(r, style, title)
    drawn.boxes[#drawn.boxes + 1] = { x = r:x(), y = r:y(), w = r:w(), h = r:h() }
  end,
  text = function() end,
  text_ansi = function(r, s) drawn.ansi[#drawn.ansi + 1] = { x = r:x(), y = r:y(), s = s } end,
}

local render_pass = "local"
lera = { render_pass = function() return render_pass end, time = function() return 1000 end,
         version = function() return "test" end }

local bind_enabled = {}
local bind_defs = {}
bind = {
  add = function(key, fn)
    bind_defs[#bind_defs + 1] = { key = key, fn = fn }
    return #bind_defs
  end,
  enable = function(id, on) bind_enabled[id] = on end,
}

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

local last_menu_open = nil
package.loaded["menu"] = {
  open = function(opts) last_menu_open = opts end,
  close = function() last_menu_open = nil end,
  is_open = function() return last_menu_open ~= nil end,
}
local function menu_has_label(opts, substr)
  for _, it in ipairs(opts.items or {}) do
    if tostring(it.label):find(substr, 1, true) then return true end
  end
  return false
end

-- ---- the REAL popup overlay, wired as require("wm").popup -----------------
-- Sandboxed/trusted composition code (popups.lua) reaches the popup surface
-- through require("wm").popup.{open,close,is_open} (CLAUDE.md "Popup
-- Overlay"); this delegates every one of those three straight to the real
-- module loaded from LERA_ROOT/scripts/default/popup.lua, so popups.lua's own
-- open_wrapper/toggle call the REAL open()/close()/is_open() -- the one
-- thing every other guild_viking popup test suite stubs away.
local real_popup = require("popup")
package.loaded["wm"] = {
  popup = {
    open = real_popup.open,
    close = real_popup.close,
    is_open = real_popup.is_open,
  },
}

-- ---- real ingestion pipeline (protocol.ingest -> handlers), same standing
-- lesson as every other guild_viking popup suite: fixtures MUST route
-- through the real handlers, never direct S. pokes.
local state = require("state")
local protocol = require("protocol")
-- init.lua's RESERVED set: the module-level convention fields, not MIP keys.
local RESERVED_KEYS = { _market_seam = true, _patterns = true, _gmcp = true,
                        _retired_keys = true, _retired_patterns = true }
local kingdom = require("handlers.kingdom")
for key, fn in pairs(kingdom._gmcp or {}) do
  protocol.gmcp_handler(key, fn)
end

-- Task 5 needs VMAP* too (map.lua's own popup test's seed_vmap uses the
-- same registration).
local voyage = require("handlers.voyage")
local RESERVED = RESERVED_KEYS
for key, fn in pairs(voyage._gmcp or {}) do
  protocol.gmcp_handler(key, fn)
end

local S = state.S

-- popups.lua self-registers map/sea/voyage/cityplan/war against the "wm"
-- stub above at require-time.
local popups = require("popups")
local war_campaign = require("popups.war_campaign")
local war_battle = require("popups.war_battle")
local map = require("popups.map")

-- seed_wmap/seed_battle: shared shape with guild_viking_popup_war_test.lua, so
-- a fixture written here is directly comparable to that suite's own. Both seed
-- through the production GMCP path -- the campaign map and the battle board
-- have no other transport now.
--
-- Callers still describe a campaign overlay as {id, c, r, size, f}, the shape
-- MIP's WMO used; the writer takes {kind, id, ...}, so the two sentinel ids are
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
  protocol.on_gmcp("Guild.Kingdom", {
    guild = "viking",
    campaign = {
      active = (t.active ~= false) and 1 or 0,
      dim = t.dim or 0, turn = t.turn or 0, mode = t.mode or "offense",
      pending = t.pending or 0, town = t.town or "",
      works_budget = t.works_budget or 0, march_eta = t.march_eta or 0,
    },
    campaign_terrain = t.rows or {},
    campaign_units = units,
  })
end

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
                            ord = u.ord or 0 }
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

-- Seeds the vmap through the real Guild.Map pipeline (protocol.on_gmcp ->
-- handlers.voyage's composite writer), never by poking S directly. `rows`/
-- `east_edges`/`south_edges` are plain 1-based Lua arrays in wire order
-- (rows[1] is wire row 0), which is also the layout the planes arrive in, so
-- there is no index translation left to get wrong. Only the keys a caller
-- actually supplies are sent: Guild.Map frames are deltas, and a key absent
-- from a frame means unchanged.
--
-- `enc` says "glyph" so the rows travel as written. The packed encodings the
-- server normally uses are the codec's own subject
-- (guild_viking_gmcp_grid_test.lua) and the writer's
-- (guild_viking_voyage_test.lua); a fixture here is about what the map
-- CONTAINS, not how it was encoded.
local function seed_vmap(t)
  local frame = {
    guild = "viking", w = t.w, h = t.h, active = 1,
    pos = { x = t.px or -1, y = t.py or -1 },
    enc = { terrain = "glyph", east = "glyph", south = "glyph" },
  }
  if t.rows then frame.terrain = t.rows end
  if t.east_edges then frame.east = t.east_edges end
  if t.south_edges then frame.south = t.south_edges end
  if t.pois then
    local landmarks = {}
    for _, p in ipairs(t.pois) do
      landmarks[#landmarks + 1] =
        { type = p.type, name = p.name, x = p.x, y = p.y, owner = p.owner or "" }
    end
    frame.landmarks = landmarks
  end
  protocol.on_gmcp("Guild.Map", frame)
end

-- ---- popup.lua's OWN private box-geometry math, replicated here so this
-- test can convert a popup-LOCAL (lx, ly) -- the same coordinate space
-- on_pointer's `ev.x`/`ev.y` already use -- into the SCREEN (col, row) a
-- real pointer event carries, exactly the conversion wm.lua's own pointer
-- routing would perform before calling popup.handle_pointer. popups.lua's
-- open_wrapper always opens at width=0.9, height=0.9 (never configurable
-- per named popup), so hardcoding those two fractions here is safe and
-- stable, not a guess.
local function resolve(dim, total)
  local n
  if dim <= 1 then n = math.floor(total * dim + 0.5) else n = math.floor(dim) end
  if n > total then n = total end
  if n < 3 then n = math.min(3, total) end
  return n
end

local function box_geometry(root_w, root_h)
  local w = resolve(0.9, root_w)
  local h = resolve(0.9, root_h)
  local x = math.floor((root_w - w) / 2)
  local y = math.floor((root_h - h) / 2)
  return x, y, w, h
end

local function to_screen(root_w, root_h, lx, ly)
  local x, y = box_geometry(root_w, root_h)
  return x + 1 + lx, y + 1 + ly
end

-- Grid column -> wrapper-local x, for to_screen. None of the three boards
-- exercised here passes col_headers/row_headers, so each grid's body starts
-- at wrapper-local column 0 with no header offset to add -- only the pitch
-- differs, and the two boards' pitches are NOT interchangeable:
--
--   wide_lx    -- war_campaign, maplib's default 3-column pitch (2-char
--                 glyph slot + one east-edge slot). Clicking anywhere in the
--                 glyph's own 2 columns hits the cell (this uses the first);
--                 the 3rd column is the edge slot and hit-tests to nil.
--   compact_lx -- war_battle and the territory map, which render with
--                 maplib's `compact`: a 1-column pitch, so the grid column
--                 IS the x. Every column is a cell; there is no edge slot.
local function wide_lx(gc) return gc * 3 end
local function compact_lx(gc) return gc end

-- =============================================================================
-- Scenario A (Critical #1 RED before the fix): campaign select-own-stack,
-- then queue-a-waypoint, via REAL down->up pairs through popup.lua's actual
-- capture/hit-test dispatch. Before the fix, war_campaign.on_pointer's
-- "down" case returned nil (unconsumed) -- popup.lua therefore never
-- captures the pointer, and the matching "up" is swallowed one layer up
-- (handle_pointer's own `return false` for an uncaptured, non-down,
-- non-move event) -- on_pointer's "up" branch, and therefore
-- viking_campaign_click's whole select/queue/send flow, was NEVER REACHED.
-- =============================================================================
do
  seed_wmap({
    dim = 3, town = "Jorvik", rows = { "...", "...", "..." },
    units = { { id = "A", c = 0, r = 0, size = 10 } },
  })
  check("war_map seeded and active", S.war_map ~= nil and S.war_map.active == true)
  check("popups.toggle('war') opens the campaign map (no battle yet)",
    popups.toggle("war") == true)

  local root_w, root_h = 100, 30
  local root = ui.rect(0, 0, root_w, root_h)
  real_popup.render(root)
  local _, _, bw = box_geometry(root_w, root_h)
  local inner_w = bw - 2

  local off = war_campaign.grid_line_offset(inner_w)

  -- Down+up on (0,0) -- the host's own cell -- selects it.
  local dcol, drow = to_screen(root_w, root_h, wide_lx(0), off + 0)
  send_calls = {}
  check("a REAL down on the host's own cell consumes",
    real_popup.handle_pointer({ kind = "down", button = "left", x = dcol, y = drow }) == true)
  check("a REAL up on the SAME cell also consumes (this is the fix: previously unreachable)",
    real_popup.handle_pointer({ kind = "up", button = "left", x = dcol, y = drow }) == true)
  check("selecting via the real dispatch path never sends", #send_calls == 0)
  check("war_campaign now shows 'Selected A' after a REAL down+up pair",
    find_plain(war_campaign.lines(inner_w), "Selected A"))

  -- Queue a waypoint at grid (1,1) ("B2") via a second real down+up pair.
  local qcol, qrow = to_screen(root_w, root_h, wide_lx(1), off + 1)
  send_calls = {}
  real_popup.handle_pointer({ kind = "down", button = "left", x = qcol, y = qrow })
  real_popup.handle_pointer({ kind = "up", button = "left", x = qcol, y = qrow })
  check("queuing a waypoint via the REAL dispatch path sends the exact command",
    #send_calls == 1 and send_calls[1] == "vcampaign queue A B2", send_calls[1])

  real_popup.close()
  check("scenario A: popup closed cleanly", real_popup.is_open() == false)
end

-- =============================================================================
-- Scenario B (Critical #2 RED before the fix): battle [Actions] line at a
-- REAL popup width (~88 inner columns, the default gui_cols=100 case) vs
-- the 76-column probe war_battle.actions_line_index used to default to
-- unconditionally inside on_pointer. maplib.legend wraps by width, so the
-- [Actions] line's own index shifts between these two widths -- clicking
-- its TRUE on-screen row must open the actions menu.
-- =============================================================================
do
  seed_battle({
    phase = "deploy", target = "Fjordvik", width = 3, height = 2, dz = 1,
    terrain_rows = { "..#", "^*w" }, works_rows = { "v.u", "..." },
  })
  check("battle seeded and active (deploy phase)", S.battle ~= nil and S.battle.phase == "deploy")
  check("popups.toggle('war') now opens the battle board (battle takes priority)",
    popups.toggle("war") == true)

  local root_w, root_h = 100, 30
  local root = ui.rect(0, 0, root_w, root_h)
  real_popup.render(root)
  local _, _, bw = box_geometry(root_w, root_h)
  local inner_w = bw - 2
  check("popup inner width is the real-world figure this bug needs (~88 cols)",
    inner_w == 88, inner_w)

  local idx76 = war_battle.actions_line_index(76)
  local idx_real = war_battle.actions_line_index(inner_w)
  check("the [Actions] line's index genuinely differs by width (legend wrap)",
    idx76 ~= idx_real, idx76 .. " (@76) vs " .. tostring(idx_real) .. " (@" .. inner_w .. ")")

  local col, row = to_screen(root_w, root_h, 0, idx_real - 1)
  last_menu_open = nil
  check("a real down on the TRUE (real-width) [Actions] row consumes",
    real_popup.handle_pointer({ kind = "down", button = "left", x = col, y = row }) == true)
  check("it opens the deploy-phase actions menu (the fix threads the real ev.width through)",
    last_menu_open ~= nil and menu_has_label(last_menu_open, "Begin Battle"),
    last_menu_open)

  real_popup.close()
  check("scenario B: popup closed cleanly (a live capture is auto-cancelled)",
    real_popup.is_open() == false)
end

-- =============================================================================
-- Scenario C (Important #1 / cross-target drag): a down on the REAL
-- [Actions] row followed by an up released over a DIFFERENT target (a grid
-- cell) must NOT fire that cell's action -- only the target that took the
-- mousedown gets the mouseup, exactly LEGACY's own hotspot semantics
-- (popups/pointer_track.lua's header comment). Turn phase, so a leaked
-- cross-target send would be observable as a "vbattle order" command.
-- =============================================================================
do
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
  check("battle turn-phase seeded", S.battle ~= nil and S.battle.phase == "turn")
  check("popups.toggle('war') opens the battle board (turn phase)",
    popups.toggle("war") == true)

  local root_w, root_h = 100, 30
  local root = ui.rect(0, 0, root_w, root_h)
  real_popup.render(root)
  local _, _, bw = box_geometry(root_w, root_h)
  local inner_w = bw - 2
  local off = war_battle.grid_line_offset(inner_w)

  -- Select the own unit at A1 (gc=0, gr=1) via a real matched down+up pair.
  local scol, srow = to_screen(root_w, root_h, compact_lx(0), off + 1)
  send_calls = {}
  real_popup.handle_pointer({ kind = "down", button = "left", x = scol, y = srow })
  real_popup.handle_pointer({ kind = "up", button = "left", x = scol, y = srow })
  check("selecting the own unit via the real dispatch path never sends", #send_calls == 0)

  -- Cross-target drag: down on the REAL [Actions] row, release over the
  -- enemy's cell (B2, gc=1, gr=0).
  local idx = war_battle.actions_line_index(inner_w)
  local acol, arow = to_screen(root_w, root_h, 0, idx - 1)
  last_menu_open = nil
  real_popup.handle_pointer({ kind = "down", button = "left", x = acol, y = arow })
  check("down on the real [Actions] row opens the turn-phase menu",
    last_menu_open ~= nil and menu_has_label(last_menu_open, "Advance Turn"))

  local ecol, erow = to_screen(root_w, root_h, compact_lx(1), off + 0)
  send_calls = {}
  real_popup.handle_pointer({ kind = "up", button = "left", x = ecol, y = erow })
  check("releasing over the enemy cell after an [Actions] down sends NOTHING",
    #send_calls == 0, send_calls[1])

  -- The selection survives the mismatched drag untouched: a genuinely
  -- matched down+up on the SAME enemy cell right after it still orders the
  -- move -- proving the guard rejects only the mismatch, not selections in
  -- general.
  real_popup.handle_pointer({ kind = "down", button = "left", x = ecol, y = erow })
  real_popup.handle_pointer({ kind = "up", button = "left", x = ecol, y = erow })
  check("a real matched down+up right after still sends the exact order command",
    #send_calls == 1 and send_calls[1] == "vbattle order 201 B2", send_calls[1])

  real_popup.close()
  check("scenario C: popup closed cleanly", real_popup.is_open() == false)
end

-- =============================================================================
-- Scenario D (fix round 3, completing Important #1: the war COMPOSITE's own
-- mid-drag mode-flip race). A real down on a battle unit is captured
-- (war_battle consumes, popup.lua captures) while a campaign selection
-- already exists; `S.battle` is then cleared MID-DRAG (a battle ending is
-- exactly the real-world trigger); the matching up must still be routed to
-- war_battle (the module that took the down), NOT re-resolved to
-- war_campaign via the composite's live active_module() -- which would
-- otherwise let a stale campaign selection turn this up into a real
-- "vcampaign queue ..." send for a gesture war_campaign was never part of.
-- Before popups/war.lua's gesture pinning, this was reachable even with
-- war_campaign's own down-consumption fix (Critical #1) applied: the down
-- was consumed by war_battle, not war_campaign, so war_campaign's OWN
-- tracker never recorded anything for this gesture at all -- exactly the
-- fail-open gap pointer_track.lua's contract now closes as a second,
-- independent line of defense, with war.lua's pin as the first.
-- =============================================================================
do
  -- Scenario C's own fixture left S.battle set (it never clears it) --
  -- clear it first via the real handler, so this scenario genuinely starts
  -- with no battle and the campaign as the only live mode.
  seed_battle({ active = false })
  check("no leftover battle from an earlier scenario", S.battle == nil)

  seed_wmap({
    dim = 2, rows = { "..", ".." },
    units = { { id = "A", c = 0, r = 0, size = 10 } },
  })
  check("war_map seeded and active (scenario D)", S.war_map ~= nil and S.war_map.active == true)
  check("popups.toggle('war') opens the campaign map (no battle yet)",
    popups.toggle("war") == true)

  local root_w, root_h = 100, 30
  local root = ui.rect(0, 0, root_w, root_h)
  real_popup.render(root)
  local _, _, bw = box_geometry(root_w, root_h)
  local inner_w = bw - 2
  local off_c = war_campaign.grid_line_offset(inner_w)
  local scol, srow = to_screen(root_w, root_h, wide_lx(0), off_c + 0)

  -- war_campaign.selected/queue are module-local singletons that persist
  -- across scenarios by design (see war_campaign.lua's own M.reset() doc
  -- comment) -- scenario A left "A" selected. Clear that first with a real
  -- click on its own (still-unmoved) cell, which war_campaign.lua's
  -- on_click reads as "hold" (deselect) rather than a fresh select, exactly
  -- like every other suite's own "cleanup deselect" step.
  real_popup.handle_pointer({ kind = "down", button = "left", x = scol, y = srow })
  real_popup.handle_pointer({ kind = "up", button = "left", x = scol, y = srow })
  check("cleanup: no stale selection carried in from an earlier scenario",
    not find_plain(war_campaign.lines(inner_w), "Selected A"))

  -- Legitimately select "A" on the campaign grid, via a real matched
  -- down+up pair, while the campaign is the only mode live -- this is the
  -- pre-existing selection a mis-routed up would otherwise act against.
  real_popup.handle_pointer({ kind = "down", button = "left", x = scol, y = srow })
  real_popup.handle_pointer({ kind = "up", button = "left", x = scol, y = srow })
  check("campaign selection established before the battle exists",
    find_plain(war_campaign.lines(inner_w), "Selected A"))

  -- A battle now starts (composite mode flips to war_battle -- battle takes
  -- priority -- on the NEXT pointer dispatch; no re-render is needed, since
  -- neither the popup's box geometry nor the wrapper's last_width changed).
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
  local off_b = war_battle.grid_line_offset(inner_w)
  check("campaign and battle pre-grid line counts coincide (both headers-only) " ..
    "-- the scenario's own premise: the SAME screen row is a valid cell in BOTH grids",
    off_c == off_b, off_c .. " vs " .. off_b)

  -- Real down on the battle's own unit (gc=0, gr=1, "A1") -- consumed by
  -- war_battle, pinning this gesture to it.
  local dcol, drow = to_screen(root_w, root_h, compact_lx(0), off_b + 1)
  send_calls = {}
  check("a REAL down on the battle unit consumes (war_battle, battle takes priority)",
    real_popup.handle_pointer({ kind = "down", button = "left", x = dcol, y = drow }) == true)
  check("the down never sends", #send_calls == 0)

  -- MID-DRAG: the battle ends. Cleared via the real BATTLE handler
  -- (active=0), not a direct S.battle poke -- same standing lesson as every
  -- fixture in the per-popup suites: state transitions go through
  -- protocol.ingest so kingdom.lua's own `S.battle = nil` clearing logic is
  -- what's actually exercised, matching guild_viking_popup_war_test.lua's
  -- own "BATTLE active=0" clear exactly.
  seed_battle({ active = false })
  check("S.battle is nil mid-drag", S.battle == nil)
  check("S.war_map is still active mid-drag (the mode active_module() would flip to)",
    S.war_map.active == true)

  -- The matching up, released at the SAME screen position as the down.
  -- Without gesture pinning, the composite would re-resolve active_module()
  -- to war_campaign now and dispatch the up there -- war_campaign's own
  -- tracker never recorded this down (war_battle did), and pointer_track's
  -- fail-open default used to let it act anyway.
  send_calls = {}
  real_popup.handle_pointer({ kind = "up", button = "left", x = dcol, y = drow })
  check("the up after a mid-drag mode flip sends NOTHING", #send_calls == 0, send_calls[1])
  check("the up after a mid-drag mode flip does not touch the campaign's selection/queue at all",
    find_plain(war_campaign.lines(inner_w), "Selected A")
    and not find_plain(war_campaign.lines(inner_w), "Queued for A"))

  real_popup.close()
  check("scenario D: popup closed cleanly", real_popup.is_open() == false)
end

-- =============================================================================
-- Scenario D positive control: the SAME battle, with NO mid-drag mode
-- flip, still behaves normally end to end through the real dispatch path
-- -- gesture pinning must not disturb the ordinary, undisturbed case.
-- =============================================================================
do
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
  check("popups.toggle('war') opens the battle board (positive control)",
    popups.toggle("war") == true)

  local root_w, root_h = 100, 30
  local root = ui.rect(0, 0, root_w, root_h)
  real_popup.render(root)
  local _, _, bw = box_geometry(root_w, root_h)
  local inner_w = bw - 2
  local off = war_battle.grid_line_offset(inner_w)

  -- Select the own unit, then order it to the enemy cell -- both as real
  -- matched down+up pairs, with S.battle untouched throughout.
  local scol, srow = to_screen(root_w, root_h, compact_lx(0), off + 1)
  send_calls = {}
  real_popup.handle_pointer({ kind = "down", button = "left", x = scol, y = srow })
  real_popup.handle_pointer({ kind = "up", button = "left", x = scol, y = srow })
  check("positive control: selecting the own unit never sends", #send_calls == 0)

  local ecol, erow = to_screen(root_w, root_h, compact_lx(1), off + 0)
  real_popup.handle_pointer({ kind = "down", button = "left", x = ecol, y = erow })
  real_popup.handle_pointer({ kind = "up", button = "left", x = ecol, y = erow })
  check("positive control: ordering the unit sends the exact command with no mode flip in play",
    #send_calls == 1 and send_calls[1] == "vbattle order 201 B2", send_calls[1])

  real_popup.close()
  check("scenario D positive control: popup closed cleanly", real_popup.is_open() == false)
end

-- =============================================================================
-- Scenario E (Task 5): the map popup's POI travel menu, driven end to end
-- through the REAL popup.lua down/up dispatch -- the case this suite exists
-- for (per its own header comment): a down on the map's POI cell (2,0)
-- must be CONSUMED (so popup.lua actually captures the gesture and
-- delivers the matching up), the up must open the ported travel menu, and
-- selecting the menu's item must send the EXACT path (mirrors
-- pathfinding_test.lua's Case 1: (0,0) -> (2,0) on a clear row =
-- {"east", "east"}). Then two fail-closed sub-cases: down on the POI,
-- release over a DIFFERENT, non-POI cell (the brief's own case); and,
-- review round 1's Important finding, down on POI A, release over POI B
-- -- see that block's own comment for why the non-POI case alone doesn't
-- discriminate the tracker.
-- =============================================================================
do
  seed_vmap({
    w = 3, h = 1, rows = { "ppp" }, east_edges = { "111" },
    px = 0, py = 0,
    pois = { { type = "capital", name = "asgard", x = 2, y = 0, owner = "" } },
  })
  check("vmap seeded (scenario E)", S.vmap_w == 3 and S.vmap_px == 0)
  check("popups.toggle('map') opens the territory map", popups.toggle("map") == true)

  local root_w, root_h = 100, 30
  local root = ui.rect(0, 0, root_w, root_h)
  real_popup.render(root)
  local _, _, bw = box_geometry(root_w, root_h)
  local inner_w = bw - 2

  local off = map.grid_line_offset(inner_w)
  local pcol, prow = to_screen(root_w, root_h, compact_lx(2), off + 0)

  -- Review round 1, Minor 3: popup.lua's own handle_pointer (line ~220)
  -- returns true for EVERY down inside the popup rect regardless of
  -- whether the module consumed it (`return true -- a down inside never
  -- falls through to panes or selection`) -- so asserting that return
  -- value proves nothing about map.lua's own consumption. What DOES
  -- discriminate it: popup.lua only sets its internal `capture` (and
  -- therefore only ever calls on_pointer again for the matching up) when
  -- the module's on_pointer actually returned true. The "matching up
  -- opens the travel menu" check just below is what would fail if
  -- map.lua's down handler stopped consuming -- that check carries the
  -- consumption-verification role instead.
  send_calls, last_menu_open = {}, nil
  real_popup.handle_pointer({ kind = "down", button = "left", x = pcol, y = prow })
  check("the down never sends", #send_calls == 0)
  real_popup.handle_pointer({ kind = "up", button = "left", x = pcol, y = prow })
  check("the matching up opens the travel menu via the REAL dispatch path "
    .. "(this is what actually proves the down was consumed -- see the comment above)",
    last_menu_open ~= nil)

  local asgard_value
  for _, it in ipairs((last_menu_open or {}).items or {}) do
    if it.value and it.value.name == "asgard" then asgard_value = it.value end
  end
  check("menu contains the asgard item", asgard_value ~= nil)

  -- Review round 1, Minor 4: guard against a nil last_menu_open (e.g. a
  -- real regression reintroducing the down-consumption bug) so a failure
  -- here reports as a FAILED check on this and every later case, rather
  -- than a Lua error that aborts the whole script before they run.
  if last_menu_open then
    send_calls = {}
    last_menu_open.on_select(asgard_value)
    check("selecting the item sends the EXACT path, in order",
      #send_calls == 2 and send_calls[1] == "east" and send_calls[2] == "east",
      table.concat(send_calls, ","))
  else
    check("selecting the item sends the EXACT path, in order", false, "menu never opened")
  end

  -- Fail-closed (the brief's own case): down on the POI cell, release over
  -- a DIFFERENT, non-POI cell (0,0) -- must not open the menu or send.
  local ocol, orow = to_screen(root_w, root_h, compact_lx(0), off + 0)
  send_calls, last_menu_open = {}, nil
  real_popup.handle_pointer({ kind = "down", button = "left", x = pcol, y = prow })
  real_popup.handle_pointer({ kind = "up", button = "left", x = ocol, y = orow })
  check("fail-closed (non-POI up): down on POI, up over a different cell -> menu never opens",
    last_menu_open == nil)
  check("fail-closed (non-POI up): down on POI, up over a different cell -> nothing sent",
    #send_calls == 0)

  -- Review round 1, Important: the case above releases over a NON-POI
  -- cell, so map.lua's own guard `poi_at_cell(...) ~= nil and
  -- track.matches(...)` is already rejected by its FIRST conjunct --
  -- track.matches() is never even called with a chance to matter, so
  -- that case cannot tell a working tracker from a broken (fail-open)
  -- one. This block closes that gap: TWO real POIs, down on POI A's cell
  -- (2,0), release on POI B's cell (1,0) -- poi_at_cell(...) ~= nil is
  -- TRUE for the up (B is a genuine POI), so only track.matches()
  -- rejecting the mismatched cell can be what keeps the menu shut.
  --
  -- Guild.Map's `landmarks` is one array key carrying the whole list, so
  -- seeding it replaces the single-POI fixture above outright -- no
  -- double-buffer, and no second heartbeat needed to promote it. (MIP's
  -- VMAPL chunked the list across packets and needed both.)
  seed_vmap({
    w = 3, h = 1, rows = { "ppp" }, east_edges = { "111" },
    px = 0, py = 0,
    pois = {
      { type = "capital", name = "asgard", x = 2, y = 0, owner = "" },
      { type = "ruins", name = "vanaheim", x = 1, y = 0, owner = "" },
    },
  })
  check("two-POI fixture replaced the live list (scenario E)", #S.vmap_pois == 2, #S.vmap_pois)

  local bcol, brow = to_screen(root_w, root_h, compact_lx(1), off + 0)
  send_calls, last_menu_open = {}, nil
  real_popup.handle_pointer({ kind = "down", button = "left", x = pcol, y = prow }) -- down on A (2,0)
  real_popup.handle_pointer({ kind = "up", button = "left", x = bcol, y = brow })   -- up on B (1,0)
  check("fail-closed (POI A -> POI B drag): menu never opens "
    .. "(the up lands on a REAL poi, so only track.matches() can be rejecting this)",
    last_menu_open == nil)
  check("fail-closed (POI A -> POI B drag): nothing sent", #send_calls == 0)

  real_popup.close()
  check("scenario E: popup closed cleanly", real_popup.is_open() == false)
end

-- =============================================================================
-- Scenario F: the per-page context menu on RIGHT-click, driven end to end
-- through the REAL popup.lua dispatch for both popup surfaces that have one
-- (LEGACY's PAGE_MENUS[7] = Map, PAGES_MENUS[10] = Sea). A module-level test
-- cannot see popup.lua swallowing an unconsumed down -- which is exactly how
-- stage 3 shipped a dead click -- so the right-down MUST be proven to capture
-- here, by the matching up actually arriving and opening the menu.
-- =============================================================================
do
  seed_vmap({
    w = 3, h = 1, rows = { "ppp" }, east_edges = { "111" },
    px = 0, py = 0,
    pois = { { type = "capital", name = "asgard", x = 2, y = 0, owner = "" } },
  })
  check("popups.toggle('map') opens for scenario F", popups.toggle("map") == true)

  local root_w, root_h = 100, 30
  local root = ui.rect(0, 0, root_w, root_h)
  real_popup.render(root)
  local _, _, bw = box_geometry(root_w, root_h)
  local inner_w = bw - 2
  local off = map.grid_line_offset(inner_w)
  local pcol, prow = to_screen(root_w, root_h, compact_lx(1), off + 0)

  -- A right down inside the popup, then the matching right up: the menu must
  -- open. If the module had NOT consumed the down, popup.lua would never have
  -- captured the gesture and this up would never reach map.lua at all.
  last_menu_open = nil
  real_popup.handle_pointer({ kind = "down", button = "right", x = pcol, y = prow })
  check("scenario F: right down alone opens no menu (LEGACY fires on MouseUp)",
    last_menu_open == nil)
  real_popup.handle_pointer({ kind = "up", button = "right", x = pcol, y = prow })
  check("scenario F: the matching right up opens the MAP page menu",
    last_menu_open ~= nil and last_menu_open.title == "Map",
    last_menu_open and last_menu_open.title)

  -- The menu's content is the map page's own row set, not another page's.
  local labels = {}
  for _, it in ipairs(last_menu_open.items or {}) do labels[#labels + 1] = it.label end
  local joined = table.concat(labels, "|")
  check("scenario F: the map menu carries Show Locations List",
    joined:find("Show Locations List", 1, true) ~= nil, joined)
  check("scenario F: the map menu carries the Travel action row",
    joined:find("Travel to...", 1, true) ~= nil, joined)
  check("scenario F: the map menu omits the inert icons toggle",
    joined:find("Map Icons", 1, true) == nil, joined)

  -- Fail-closed through the REAL dispatch: a right down inside, released
  -- OUTSIDE the popup rect. popup.lua routes an outside up to the capturing
  -- module (capture is by button), so the tracker is what must refuse it.
  last_menu_open = nil
  real_popup.handle_pointer({ kind = "down", button = "right", x = pcol, y = prow })
  real_popup.handle_pointer({ kind = "up", button = "right", x = 0, y = 0 })
  check("scenario F: right up released outside the popup opens no menu",
    last_menu_open == nil)

  -- A right down still leaves a LEFT POI click working (the two paths share
  -- one tracker, so a right gesture must not eat the left one's record).
  last_menu_open = nil
  real_popup.handle_pointer({ kind = "down", button = "right", x = pcol, y = prow })
  real_popup.handle_pointer({ kind = "up", button = "right", x = pcol, y = prow })
  local pcol2, prow2 = to_screen(root_w, root_h, compact_lx(2), off + 0)
  last_menu_open = nil
  real_popup.handle_pointer({ kind = "down", button = "left", x = pcol2, y = prow2 })
  real_popup.handle_pointer({ kind = "up", button = "left", x = pcol2, y = prow2 })
  check("scenario F: a LEFT POI click still opens the travel menu afterwards",
    last_menu_open ~= nil and last_menu_open.title == "Travel to...",
    last_menu_open and last_menu_open.title)

  real_popup.close()
  check("scenario F: map popup closed cleanly", real_popup.is_open() == false)

  -- The same, for the Sea popup (LEGACY's PAGE_MENUS[10]).
  check("popups.toggle('sea') opens for scenario F", popups.toggle("sea") == true)
  real_popup.render(root)
  last_menu_open = nil
  real_popup.handle_pointer({ kind = "down", button = "right", x = 50, y = 15 })
  real_popup.handle_pointer({ kind = "up", button = "right", x = 50, y = 15 })
  check("scenario F: right-click in the SEA popup opens the sea page menu",
    last_menu_open ~= nil and last_menu_open.title == "Sea",
    last_menu_open and last_menu_open.title)
  local sea_labels = {}
  for _, it in ipairs(last_menu_open and last_menu_open.items or {}) do
    sea_labels[#sea_labels + 1] = it.label
  end
  local sea_joined = table.concat(sea_labels, "|")
  check("scenario F: the sea menu carries Confirm Chart Clicks",
    sea_joined:find("Confirm Chart Clicks", 1, true) ~= nil, sea_joined)
  check("scenario F: the sea menu omits the inert chart-icons toggle",
    sea_joined:find("Chart Icons", 1, true) == nil, sea_joined)

  real_popup.close()
  check("scenario F: sea popup closed cleanly", real_popup.is_open() == false)
end

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING POPUP DISPATCH TESTS PASSED")
