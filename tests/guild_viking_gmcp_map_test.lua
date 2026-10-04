-- guild_viking Guild.Map writer unit tests, plus protocol dispatch precedence.
-- Run from the lera-plugins repo root with LERA_ROOT pointing at a built Lera
-- checkout.
--
-- These cases lived in guild_viking_voyage_test.lua, which was a MIP-handler
-- behavioural suite; that suite went when its handlers did, and its Guild.Map
-- section -- the only coverage the territory-map writer has -- moved here.
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

-- ---- lera API stubs (same shape as guild_viking_test.lua) -------------------
local dirty_count = 0
ui = { dirty = function() dirty_count = dirty_count + 1 end }
local stored = nil
store = {
  load = function() end,
  get = function() return stored end,
  set = function(d) stored = d end,
  save = function() end,
}
lera = { time = function() return 1000 end, version = function() return "test" end }
buffer = { color_print = function() end }
mud = { send = function() end }
local mip_handlers, mip_handler_count = {}, 0
mip = {
  on = function(code, cb)
    mip_handlers[code] = cb
    mip_handler_count = mip_handler_count + 1
    return mip_handler_count
  end,
  off = function() end,
  enabled = function() return true end,
  fire = function(code, data) mip_handlers[code](12345, code, data) end,
}
local gmcp_handlers, gmcp_handler_count = {}, 0
gmcp = {
  on = function(pkg, cb)
    gmcp_handlers[pkg] = cb
    gmcp_handler_count = gmcp_handler_count + 1
    return gmcp_handler_count
  end,
  remove = function() end,
  enabled = function() return false end,
  fire = function(pkg, data) gmcp_handlers[pkg](pkg, data) end,
}
trigger = { add = function() return 1 end, remove = function() end }
timer = { every = function() return 1 end, remove = function() end }
alias = { add = function() return 1 end, remove = function() end }
plugin = { get = function() return nil end }
local real_require = require
require = function(name)
  if name == "command" then
    return { register = function() return 1 end, unregister = function() return true end,
             get = function() return nil end, list = function() return {} end }
  end
  return real_require(name)
end

local protocol = require("protocol")
-- init.lua's RESERVED set: the module-level convention fields, not MIP keys.
local RESERVED_KEYS = { _market_seam = true, _patterns = true, _gmcp = true,
                        _retired_keys = true, _retired_patterns = true }
local S = require("state").S
local voyage = require("handlers.voyage")
-- Mirrors init.lua's RESERVED set: everything in a handler module that is not
-- one of the module-level conventions is an exact MIP key.
local RESERVED = RESERVED_KEYS
for key, fn in pairs(voyage._gmcp or {}) do
  protocol.gmcp_handler(key, fn)
end


-- ---- Guild.Map -------------------------------------------------------------
--
-- The territory map is GMCP-only: MIP's VMAPH/VMAPL/VMR/MEE/MES keys are
-- received and dropped (see the bottom of this section). Frames arrive
-- through protocol.on_gmcp, which strips the envelope and hands every
-- Guild.Map key to the single composite writer as one table.

-- protocol_grid_pack_row()'s packing, transcribed from
-- secure/protocol/grid_codec_impl.h. Only used to prove a packed plane
-- reaches the codec at all; the codec's own correctness is
-- guild_viking_gmcp_grid_test.lua's subject.
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function pack_row(codes, bits)
  local octets, acc, held = {}, 0, 0
  for i = 1, #codes do
    acc = acc * (2 ^ bits) + codes[i]
    held = held + bits
    if held >= 8 then
      octets[#octets + 1] = math.floor(acc / 2 ^ (held - 8)) % 256
      held = held - 8
      acc = (held > 0) and (acc % 2 ^ held) or 0
    end
  end
  if held > 0 then octets[#octets + 1] = (acc * 2 ^ (8 - held)) % 256 end
  local out = {}
  for i = 1, #octets, 3 do
    local chunk = octets[i] * 65536
      + (octets[i + 1] or 0) * 256 + (octets[i + 2] or 0)
    local function ch(n) return B64:sub(n + 1, n + 1) end
    out[#out + 1] = ch(math.floor(chunk / 262144) % 64)
    out[#out + 1] = ch(math.floor(chunk / 4096) % 64)
    if octets[i + 1] then out[#out + 1] = ch(math.floor(chunk / 64) % 64) end
    if octets[i + 2] then out[#out + 1] = ch(chunk % 64) end
  end
  return table.concat(out)
end

local GLYPH_ENC = { terrain = "glyph", east = "glyph", south = "glyph" }
local TERRAIN_LEGEND = {
  ["0"] = "unexplored", ["1"] = "plains", ["2"] = "forest", ["3"] = "hills",
  ["4"] = "mountains", ["5"] = "tundra", ["6"] = "coast",
  ["7"] = "water (fjord/lake)", ["8"] = "bridge",
  ["9"] = "river/ford (unbridged)", ["10"] = "road",
}
local EDGE_LEGEND = { ["0"] = "blocked (impassable edge)", ["1"] = "open (passable edge)" }

local function map_frame(payload)
  payload.guild = "viking"
  protocol.on_gmcp("Guild.Map", payload)
end

-- A full frame: dimensions, position, all three planes as glyph rows, and the
-- landmark list.
map_frame({
  full = 1, w = 5, h = 2, active = 1, pos = { x = 3, y = 1 },
  enc = GLYPH_ENC, legend = TERRAIN_LEGEND, legend_edge = EDGE_LEGEND,
  terrain = { "pp.ff", "AAtt." },
  east = { "10101", "11110" },
  south = { "01010" },
  landmarks = {
    { type = "town", name = "Havn", x = 3, y = 1, owner = "PlayerA" },
    { type = "fort", name = "Alpha", x = 5, y = 2, owner = "" },
  },
})
check("map dims", S.vmap_w == 5 and S.vmap_h == 2)
check("map player pos", S.vmap_px == 3 and S.vmap_py == 1)
check("map active", S.vmap_active == 1)
check("map terrain rows land at 1-indexed positions",
      S.vmap_rows[1] == "pp.ff" and S.vmap_rows[2] == "AAtt.")
check("map east edges", S.vmap_east_edges[1] == "10101" and S.vmap_east_edges[2] == "11110")
-- The south plane describes the boundary between row r and row r+1, so it is
-- one row shorter than the grid by construction.
check("map south edges", S.vmap_south_edges[1] == "01010" and #S.vmap_south_edges == 1)
check("map landmarks", #S.vmap_pois == 2 and S.vmap_pois[1].type == "town"
      and S.vmap_pois[1].name == "Havn" and S.vmap_pois[1].x == 3
      and S.vmap_pois[1].y == 1 and S.vmap_pois[1].owner == "PlayerA")
check("map landmark owner default", S.vmap_pois[2].owner == "")

-- Terrain rows are CLEAN -- no player marker baked in. This is the whole
-- reason MIP's map path is gone rather than kept: MIP wrote an 'X' into the
-- player's own cell, which popups/map.lua overdrew but pathfinding.lua read
-- as if it were terrain.
check("the player's own cell carries real terrain, not a marker",
      S.vmap_rows[2]:sub(4, 4) == "t")

-- A step sends `pos` alone. Every other key is absent, which means unchanged
-- -- never empty.
map_frame({ pos = { x = 4, y = 1 } })
check("a pos-only delta moves the marker", S.vmap_px == 4 and S.vmap_py == 1)
check("a pos-only delta leaves the planes standing",
      S.vmap_rows[1] == "pp.ff" and S.vmap_east_edges[1] == "10101"
      and #S.vmap_pois == 2 and S.vmap_w == 5)

-- Walking off the biome grid keeps the last known coordinates but clears
-- `active`, which is what the popup labels the position with.
map_frame({ active = 0 })
check("active clears without disturbing the position",
      S.vmap_active == 0 and S.vmap_px == 4 and S.vmap_py == 1)
map_frame({ active = 1 })

-- Same dimensions preserve the planes; a changed dimension drops them,
-- because rows sized for the old grid cannot be reinterpreted at a new width.
map_frame({ w = 5, h = 2 })
check("unchanged dims preserve the planes", S.vmap_rows[1] == "pp.ff")
map_frame({ w = 6, h = 3 })
check("changed dims reset the planes",
      S.vmap_rows[1] == nil and S.vmap_east_edges[1] == nil
      and S.vmap_south_edges[1] == nil)
check("changed dims are applied", S.vmap_w == 6 and S.vmap_h == 3)

-- A frame naming only one dimension still resets, and keeps the other.
map_frame({ w = 5, h = 2, terrain = { "ppppp", "fffff" } })
map_frame({ h = 4 })
check("a partial dimension change keeps the dimension it did not name",
      S.vmap_w == 5 and S.vmap_h == 4 and S.vmap_rows[1] == nil)

-- Landmarks are one array key, so a frame carrying them carries the whole
-- list: it replaces rather than merges, and two landmarks on one cell keep
-- the first (popups/map.lua indexes one POI per cell).
map_frame({
  landmarks = {
    { type = "town", name = "Havn", x = 3, y = 4, owner = "PlayerA" },
    { type = "fort", name = "Beta", x = 9, y = 9, owner = "" },
    { type = "fort", name = "BetaDup", x = 9, y = 9, owner = "PlayerC" },
  },
})
check("landmarks replace the previous list", #S.vmap_pois == 2)
check("two landmarks on one cell keep the first", S.vmap_pois[2].name == "Beta")

-- The server namespace delta cache omits unchanged revision/count metadata
-- after the first chunk. The receiver must retain those values while joining
-- later chunk-only deltas rather than treating each slice as a whole list.
S.vmap_landmark_rev = nil
S.vmap_landmark_chunks = 0
S.vmap_landmark_parts = {}
S.vmap_landmark_received = 0
map_frame({ landmark_rev = 7, landmark_chunk = 1, landmark_chunks = 3,
  landmarks = { { type = "player", name = "First", x = 1, y = 1, owner = "a" } } })
check("partial landmark snapshot keeps previous list until complete",
  #S.vmap_pois == 2)
map_frame({ landmark_chunk = 2,
  landmarks = { { type = "player", name = "Second", x = 2, y = 2, owner = "b" } } })
check("chunk-only delta does not discard the pending snapshot",
  #S.vmap_pois == 2 and S.vmap_landmark_received == 2)
map_frame({ landmark_chunk = 3,
  landmarks = { { type = "seer", name = "Third", x = 3, y = 3, owner = "" } } })
check("landmark chunks publish as one complete POI list",
  #S.vmap_pois == 3 and S.vmap_pois[1].name == "First"
  and S.vmap_pois[2].name == "Second" and S.vmap_pois[3].name == "Third")

-- A packed push. `enc` names the encoding per plane and `legend` explains the
-- codes; both are cached, so the delta that follows can ship planes alone.
map_frame({
  w = 3, h = 2,
  enc = { terrain = "b4", east = "b1", south = "b1" },
  legend = TERRAIN_LEGEND, legend_edge = EDGE_LEGEND,
  terrain = { pack_row({ 1, 1, 0 }, 4), pack_row({ 2, 2, 4 }, 4) },
  east = { pack_row({ 1, 0, 1 }, 1) },
  south = { pack_row({ 0, 0, 1 }, 1) },
})
check("a packed terrain plane decodes to glyph rows",
      S.vmap_rows[1] == "pp." and S.vmap_rows[2] == "ffA",
      tostring(S.vmap_rows[1]) .. "/" .. tostring(S.vmap_rows[2]))
check("packed edge planes decode to passability rows",
      S.vmap_east_edges[1] == "101" and S.vmap_south_edges[1] == "001")

-- enc/legend change only when the server's own tables do, so a delta shipping
-- fresh planes will not repeat them. Decoding against the cached pair is the
-- ordinary case, not the exception.
map_frame({ terrain = { pack_row({ 0, 10, 8 }, 4) } })
check("a plane arriving without enc decodes against the cached context",
      S.vmap_rows[1] == ".+=", tostring(S.vmap_rows[1]))

-- That cache must not outlive its connection: a fresh packed plane read
-- against a previous session's legend would draw a wrong map that looks
-- entirely plausible.
require("state").reset_connection()
check("disconnect clears the decoding context",
      S.vmap_enc == nil and S.vmap_legend == nil and S.vmap_terrain_glyphs == nil)
map_frame({ w = 3, h = 1, enc = { terrain = "b4" },
            terrain = { pack_row({ 1, 1, 0 }, 4) } })
check("a packed plane with no legend empties rather than guessing glyphs",
      S.vmap_rows[1] == "", tostring(S.vmap_rows[1]))

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING GMCP MAP TESTS PASSED")
