-- Court page: LEGACY's draw_page_court
-- (/home/simon/code/3s_scripts_old/lua/guild_viking.lua:13236-13304). Pure
-- builder: lines(width) -> array of ANSI strings, reading state.lua's S and
-- page_opts.lua only.
--
-- Section order/gates, read from the source top to bottom:
--   Realm/House title (UNGATED -- always drawn once state.dynasty exists,
--     13243) -- "<realm>  --  House <house>".
--   Consort (show_court_consort, 13245-13259) -- the ruling spouse (name,
--     house, age, and whether the match is a lineage or town match), or an
--     empty-seat prompt naming the "vcourt wed" commands when unmarried.
--   Children (show_court_children, 13261-13290) -- a living/cap count with
--     a fill bar, then one row per child (name, gender, age, optional trait/
--     role, and a [HEIR]/child tag), or "(none yet)" when the list is empty.
--   A top-level "No court data" fallback (13238-13242, UNGATED) replaces the
--     ENTIRE page when state.dynasty is nil (before mip_kingdom/vcourt has
--     ever populated it).
--
-- Disclosed simplification: MUSHclient colors here are 0xBBGGRR
-- (guild_viking.lua line 301); every mapping below was decoded byte-by-byte.
-- The spouse name color (0x00CCCC for a lineage match, else 0xEEEEEE)
-- decodes to (R=CC,G=CC,B=00) -- a yellow-gold -- vs. near-white, matching
-- the source's own "gold"/"white" naming exactly, so those map to
-- pagelib.C.yellow / pagelib.C.white with no discrepancy to disclose. Every
-- other color in this page (0x999999/0x888888/0x777777/0x666666, all
-- greys; 0xEEEEEE near-white; 0x40FF40 -> R=40,G=FF,B=40, bright green) maps
-- onto pagelib.C.dim/white/bright_green just as cleanly.
local pagelib = require("pagelib")
local state = require("state")
local page_opts = require("page_opts")

local S = state.S
local C = pagelib.C

local M = {}

-- ---------------------------------------------------------------------------
-- Consort (guild_viking.lua:13245-13259, gated show_court_consort)
-- ---------------------------------------------------------------------------

local function consort_lines(add, width, d)
  add(pagelib.header(width, "Consort"))
  local s = d.spouse
  if not s then
    add(pagelib.trunc(C.dim .. "The seat beside you is empty." .. pagelib.RESET, width))
    add(pagelib.trunc(C.dim .. "vcourt wed lineage <house>  |  vcourt wed town <town>" .. pagelib.RESET,
      width))
    return
  end

  -- rank == 2: lineage match (their house rides with you, gold name, "House"
  -- prefix); anything else: town match (white name, no "House" prefix).
  local is_lineage = (s.rank == 2)
  local name_col = is_lineage and C.yellow or C.white
  local house_str = (is_lineage and "House " or "") .. (s.house or "?")
  add(pagelib.trunc(name_col .. (s.name or "?") .. pagelib.RESET ..
    C.dim .. "  of " .. house_str .. ", age " .. (s.age or 0) .. pagelib.RESET, width))

  local desc = is_lineage
    and "  lineage match -- their house rides with you, +2 heirs"
    or "  town match -- +1 heir"
  add(pagelib.trunc(C.dim .. desc .. pagelib.RESET, width))
end

-- ---------------------------------------------------------------------------
-- Children (guild_viking.lua:13261-13290, gated show_court_children)
-- ---------------------------------------------------------------------------

local function child_row(width, d, c)
  local is_heir = d.heir and c.name == d.heir
  local name_col = is_heir and C.bright_green or (c.adult and C.white or C.dim)
  local left = name_col .. (c.name or "?") .. pagelib.RESET

  local meta = string.format("  %s, age %d", c.gender or "?", c.age or 0)
  if c.trait and c.trait ~= "" then meta = meta .. ", " .. c.trait end
  if c.role and c.role ~= "" then meta = meta .. ", " .. c.role end
  left = left .. C.dim .. meta .. pagelib.RESET

  local tag = is_heir and "[HEIR]" or ((not c.adult) and "child" or "")
  if tag == "" then
    return pagelib.trunc(left, width)
  end
  local tag_part = (is_heir and C.bright_green or C.dim) .. tag .. pagelib.RESET
  local pad = width - pagelib.visible_width(left) - pagelib.visible_width(tag_part)
  if pad < 1 then pad = 1 end
  return pagelib.trunc(left .. string.rep(" ", pad) .. tag_part, width)
end

local function children_lines(add, width, d)
  local living, cap = d.living or 0, d.cap or 0
  add(pagelib.header(width, string.format("Children  (%d / %d)", living, cap)))
  add(pagelib.trunc(pagelib.bar(20, living, cap, C.green), width))

  local kids = d.children or {}
  if #kids == 0 then
    add(pagelib.trunc(C.dim .. "(none yet)" .. pagelib.RESET, width))
    return
  end
  for _, c in ipairs(kids) do
    add(child_row(width, d, c))
  end
end

-- ---------------------------------------------------------------------------

function M.lines(width)
  width = width or 80
  local lines = {}
  local function add(s) lines[#lines + 1] = s end

  local d = S.dynasty
  if not d then
    add(pagelib.trunc(C.dim ..
      "No court data yet -- run 'vcourt found' to populate it" .. pagelib.RESET, width))
    return lines
  end

  add(pagelib.header(width, (d.realm or "Realm") .. "  --  House " .. (d.house or "?")))

  if page_opts.get("show_court_consort") then
    consort_lines(add, width, d)
  end

  if page_opts.get("show_court_children") then
    children_lines(add, width, d)
  end

  return lines
end

return M
