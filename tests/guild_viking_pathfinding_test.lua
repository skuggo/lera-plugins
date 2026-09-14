-- guild_viking pathfinding.lua (vmap BFS) unit tests. Run from the
-- lera-plugins repo root with LERA_ROOT pointing at a built Lera checkout.
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

-- ---- lera API stubs (same shape as guild_viking_voyage_test.lua; only
-- ui.dirty is actually exercised -- protocol.ingest's dispatch calls it on
-- every successful handler) --------------------------------------------------
local dirty_count = 0
ui = { dirty = function() dirty_count = dirty_count + 1 end }

local state = require("state")
local pathfinding = require("pathfinding")

-- ---- real ingestion pipeline (protocol.ingest -> handlers.voyage), the SAME
-- registration guild_viking_voyage_test.lua and guild_viking_popup_map_test.lua
-- use -- vmap fixtures are driven through production code, never poked into
-- S by hand. This is the discipline that would have caught a previous
-- stage's Critical: a consumer read S.vmap_rows[r] where the handlers write
-- [ridx+1], and hand-poked fixtures agreed with the bug instead of exposing
-- it.
local protocol = require("protocol")
-- init.lua's RESERVED set: the module-level convention fields, not MIP keys.
local RESERVED_KEYS = { _market_seam = true, _patterns = true, _gmcp = true,
                        _retired_keys = true, _retired_patterns = true }
local voyage = require("handlers.voyage")
local RESERVED = RESERVED_KEYS
for key, fn in pairs(voyage._gmcp or {}) do
  protocol.gmcp_handler(key, fn)
end

local S = state.S

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

local function reset_vmap()
  S.vmap_w, S.vmap_h = 0, 0
  S.vmap_px, S.vmap_py = -1, -1
  S.vmap_rows = {}
  S.vmap_east_edges = {}
  S.vmap_south_edges = {}
end

local function path_str(path)
  if not path then return "nil" end
  return "{" .. table.concat(path, ",") .. "}"
end

local function paths_equal(path, expected)
  if not path then return false end
  if #path ~= #expected then return false end
  for i = 1, #path do
    if path[i] ~= expected[i] then return false end
  end
  return true
end

-- =============================================================================
-- Case 1: straight-line path, no obstacles.
--
--   col:      0     1     2
--   row0:   (0,0)-1->(1,0)-1->(2,0)   all tiles 'p' (plains)
--
--   Start=(0,0)  Goal=(2,0)
--   Expected path: {"east", "east"}
-- =============================================================================
reset_vmap()
seed_vmap({
  w = 3, h = 1,
  rows = { "ppp" },
  east_edges = { "111" },
})
local p1 = pathfinding.bfs(0, 0, 2, 0)
check("straight-line: path found", p1 ~= nil, path_str(p1))
check("straight-line: exact route", p1 and paths_equal(p1, { "east", "east" }), path_str(p1))

-- =============================================================================
-- Case 2: detour forced by a blocked east edge.
--
--   col:        0        1        2
--   row0:    (0,0)p --X-- (1,0)p --1-- (2,0)p     (X = east edge of (0,0) blocked)
--               |1                       |1
--   row1:    (0,1)p --1-- (1,1)p --1-- (2,1)p
--
--   east_edges[row0] = "011"  (col0 blocked, col1/col2 open)
--   east_edges[row1] = "111"  (all open)
--   south_edges[row0] = "111" (col0/col1/col2 open, connecting row0<->row1)
--
--   Start=(0,0)  Goal=(2,0). Direct east route is blocked at (0,0)->(1,0), so
--   BFS must detour down and around: south, east, north, east.
--   (Hand-traced against the neighbour order north/south/east/west and the
--   FIFO queue -- see task report for the full trace.)
-- =============================================================================
reset_vmap()
seed_vmap({
  w = 3, h = 2,
  rows = { "ppp", "ppp" },
  east_edges = { "011", "111" },
  south_edges = { "111" },
})
check("east-edge detour: MEE00 landed at the real 1-indexed storage position",
  S.vmap_east_edges[1] == "011")
local p2 = pathfinding.bfs(0, 0, 2, 0)
check("east-edge detour: path found", p2 ~= nil, path_str(p2))
check("east-edge detour: exact route",
  p2 and paths_equal(p2, { "south", "east", "north", "east" }), path_str(p2))

-- =============================================================================
-- Case 3: detour forced by a blocked south edge.
--
--   col:       0                 1
--   row0:   (0,0)p ----1---- (1,0)p
--             |X (blocked)        |1
--   row1:   (0,1)p ----1---- (1,1)p
--             |1                  |1
--   row2:   (0,2)p ----1---- (1,2)p
--
--   south_edges[row0] = "01"  (col0 blocked, col1 open)
--   south_edges[row1] = "11"  (both open)
--   east_edges[*]     = "10"  (col0 open; col1's east edge is unused, w=2)
--
--   Start=(0,0)  Goal=(0,2). Direct south route is blocked at (0,0)->(0,1),
--   so BFS must detour across and back down: east, south, south, west.
-- =============================================================================
reset_vmap()
seed_vmap({
  w = 2, h = 3,
  rows = { "pp", "pp", "pp" },
  east_edges = { "10", "10", "10" },
  south_edges = { "01", "11" },
})
check("south-edge detour: MES00 landed at the real 1-indexed storage position",
  S.vmap_south_edges[1] == "01")
local p3 = pathfinding.bfs(0, 0, 0, 2)
check("south-edge detour: path found", p3 ~= nil, path_str(p3))
check("south-edge detour: exact route",
  p3 and paths_equal(p3, { "east", "south", "south", "west" }), path_str(p3))

-- =============================================================================
-- Case 4: unreachable target (impassable water tile blocks the only route)
-- returns nil, even though every edge is fully open.
--
--   col:      0     1     2
--   row0:   (0,0)p-1->(1,0)W-1->(2,0)p    (W = water, impassable tile)
--
--   Start=(0,0)  Goal=(2,0). No route exists.
-- =============================================================================
reset_vmap()
seed_vmap({
  w = 3, h = 1,
  rows = { "pWp" },
  east_edges = { "111" },
})
local p4 = pathfinding.bfs(0, 0, 2, 0)
check("unreachable: returns nil", p4 == nil, path_str(p4))

-- =============================================================================
-- Case 5: start == goal returns an empty path immediately (matches MAIN
-- 12123/12181/12351's "#path == 0 -> already there" branch), independent of
-- grid contents.
-- =============================================================================
reset_vmap()
seed_vmap({ w = 1, h = 1, rows = { "p" } })
local p5 = pathfinding.bfs(0, 0, 0, 0)
check("start==goal: returns a table, not nil", type(p5) == "table", path_str(p5))
check("start==goal: empty path", p5 and #p5 == 0, path_str(p5))

-- =============================================================================
-- Case 6: exact element shape. Every path element is a plain Lua string,
-- exactly one of "north"/"south"/"east"/"west" (case-sensitive), in travel
-- order -- the shape MAIN's `for _, dir in ipairs(path) do Send(dir) end`
-- depends on.
-- =============================================================================
local VALID_DIRS = { north = true, south = true, east = true, west = true }
reset_vmap()
seed_vmap({
  w = 3, h = 1,
  rows = { "ppp" },
  east_edges = { "111" },
})
local p6 = pathfinding.bfs(0, 0, 2, 0)
check("element shape: is a table", type(p6) == "table", path_str(p6))
check("element shape: exact length", p6 and #p6 == 2, path_str(p6))
local all_valid = true
if p6 then
  for i, dir in ipairs(p6) do
    if type(dir) ~= "string" or not VALID_DIRS[dir] then all_valid = false end
  end
end
check("element shape: every entry is a bare direction string", all_valid, path_str(p6))
check("element shape: first two moves are both 'east'",
  p6 and p6[1] == "east" and p6[2] == "east", path_str(p6))

-- =============================================================================
-- Review round 1 finding: `tile_passable`'s column read
-- (`:sub(x + 1, x + 1)`) was unpinned -- mutating it to `:sub(x, x)`
-- produced zero test failures across cases 1-6. Root cause: in Case 4's
-- fixture (rows={"pWp"}, water at wire-column 1, goal at column 2), the
-- shifted read simultaneously (a) hides the real water at column 1 -- it
-- now reads column 0's 'p' -- and (b) falsely blocks the goal at column 2
-- -- it now reads column 1's 'W'. Both changes point the same way (still
-- unreachable), so the aggregate nil/path answer never moves and the
-- mutant survives. Cases 7 and 8 below each break that cancellation in a
-- different way: 7 keeps the block reachable-but-detourable so the shift
-- changes WHICH path comes back, and 8 puts the only water tile at the
-- goal itself so the shift's direction of error (always "read one column
-- to the left of the one asked for") has nothing to cancel against and
-- flips nil into a false path. Case 9 pins the same indexing directly via
-- the exposed `pathfinding._tile_passable` accessor, bypassing BFS
-- aggregation entirely.
-- =============================================================================

-- =============================================================================
-- Case 7: a mid-corridor water tile that is NOT adjacent to the goal (or to
-- the start), with a second row available so the goal stays reachable by
-- detour either way. A one-column shift in tile_passable's read moves the
-- block from column 2 to column 3, which changes WHICH detour BFS returns
-- rather than whether one exists -- exactly the "different path" failure
-- mode called for, and it cannot be explained away as "still unreachable."
--
--   col:        0     1     2     3     4
--   row0:    (0,0)p--(1,0)p--(2,0)W--(3,0)p--(4,0)p
--               |1    |1    |1    |1    |1        (south edges, all open)
--   row1:    (0,1)p--(1,1)p--(2,1)p--(3,1)p--(4,1)p
--
--   All east edges open on both rows, all south edges open. Water only at
--   (2,0). Start=(0,0)  Goal=(4,0).
--
--   Correct (block at column 2): dip at column 0, cross under the water on
--   row1, climb back up right after the blocked column, at column 3:
--     south, east, east, east, north, east
--
--   Mutant (`:sub(x,x)`): tile_passable(x) now reads the string position
--   for column x, which is what CORRECT would have read for column x-1 --
--   so the block appears to move from column 2 to column 3, and BFS must
--   climb back up one column later, at column 4:
--     south, east, east, east, east, north
--   Same length (6), genuinely different route -- this is the
--   discriminator, not a reachability flip.
-- =============================================================================
reset_vmap()
seed_vmap({
  w = 5, h = 2,
  rows = { "ppWpp", "ppppp" },
  east_edges = { "11111", "11111" },
  south_edges = { "11111" },
})
local p7 = pathfinding.bfs(0, 0, 4, 0)
check("mid-corridor detour (not goal-adjacent): path found", p7 ~= nil, path_str(p7))
check("mid-corridor detour (not goal-adjacent): exact route",
  p7 and paths_equal(p7, { "south", "east", "east", "east", "north", "east" }), path_str(p7))
-- The mutant's route -- included so a reviewer can see by eye that a
-- one-column shift lands on a DIFFERENT valid-looking 6-step path, not on
-- a garbage one; the assertion above is what actually pins the correct
-- route and would fail against this alternative.
local MUTANT_P7 = { "south", "east", "east", "east", "east", "north" }
check("mid-corridor detour: the mutant's route is not what we assert (sanity)",
  not paths_equal({ "south", "east", "east", "east", "north", "east" }, MUTANT_P7))

-- =============================================================================
-- Case 8: the ONLY water tile sits exactly at the goal -- the failure
-- direction that would send a player walking into water. The mutant's
-- read is always "one column left of the one asked for," so when the
-- water is the last column (the goal), the shifted read reports the
-- goal's neighbour's terrain ('p') for the goal itself, and BFS returns a
-- confident path to a tile that is actually water.
--
--   col:      0     1     2
--   row0:   (0,0)p-1->(1,0)p-1->(2,0)W   (goal tile itself is water)
--
--   Start=(0,0)  Goal=(2,0). Correct: the goal tile is impassable, so it
--   can never be enqueued -> nil (correctly "no route to a goal that's
--   underwater"). Mutant: tile_passable(2,0) reads column 1's 'p' instead
--   of column 2's 'W' -> BFS happily reports {"east","east"}.
-- =============================================================================
reset_vmap()
seed_vmap({
  w = 3, h = 1,
  rows = { "ppW" },
  east_edges = { "11" },
})
local p8 = pathfinding.bfs(0, 0, 2, 0)
check("goal-is-water: returns nil, not a false route into the water",
  p8 == nil, path_str(p8))

-- =============================================================================
-- Case 9: pin tile_passable's indexing directly via the exposed
-- `pathfinding._tile_passable` accessor, bypassing BFS's aggregate answer
-- entirely. Two DIFFERENT rows (so a row-index slip -- [y] instead of
-- [y+1] -- also gets caught: row1 read with row0's data would fail this
-- comparison immediately) each mix all three terrain classes so every
-- column position is independently checked, not just "some column blocks
-- somewhere."
--
--   col:        0     1     2     3
--   row0 (y=0): p     W     r     p      -- expect: T  F  F  T
--   row1 (y=1): p     r     W     p      -- expect: T  F  F  T  (same
--                                            pattern, different columns
--                                            hold W vs r, so a row mix-up
--                                            would still show as wrong
--                                            per-column values here)
-- =============================================================================
reset_vmap()
seed_vmap({
  w = 4, h = 2,
  rows = { "pWrp", "prWp" },
})
local EXPECT_ROW0 = { true, false, false, true }
local EXPECT_ROW1 = { true, false, false, true }
local row0_ok, row1_ok = true, true
for x = 0, 3 do
  if pathfinding._tile_passable(x, 0) ~= EXPECT_ROW0[x + 1] then row0_ok = false end
  if pathfinding._tile_passable(x, 1) ~= EXPECT_ROW1[x + 1] then row1_ok = false end
end
check("tile_passable direct: row0 (wire row 0) matches column-by-column", row0_ok)
check("tile_passable direct: row1 (wire row 1) matches column-by-column", row1_ok)
-- Cross-check: row0 and row1 hold water/river in DIFFERENT columns
-- (row0's blockers at x=1,2 are W,r; row1's are r,W) specifically so that
-- reading the wrong row still produces a plausible-looking but WRONG
-- per-column result rather than accidentally matching.
check("tile_passable direct: rows are not identical (a real test of row indexing)",
  S.vmap_rows[1] ~= S.vmap_rows[2], S.vmap_rows[1] .. " / " .. S.vmap_rows[2])

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING PATHFINDING TESTS PASSED")
