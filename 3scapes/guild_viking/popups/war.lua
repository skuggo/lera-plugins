-- War popup composite (/vik war): picks whichever of the two board views --
-- the campaign map (popups/war_campaign.lua) or the tactical battle board
-- (popups/war_battle.lua) -- is the live, actionable one right now, and
-- delegates lines()/on_pointer()/geometry()/grid_line_offset() to it.
--
-- MODE CONDITION (disclosed -- LEGACY's draw_page_war does NOT gate these
-- two sections as mutually exclusive). Reading guild_viking.lua's
-- draw_page_war (14061-14084) top to bottom: it draws the campaign map
-- whenever `state.war_map and state.war_map.active` (14077-14079), THEN
-- unconditionally draws the prison panel, THEN -- gated only by
-- page_opts.show_war_battle, independent of the campaign check above --
-- either the battle board or "No battle underway." (14084-14601). Both the
-- campaign map and the battle board can and do appear TOGETHER, stacked in
-- one page, whenever a campaign is open while a battle is also under way.
-- LEGACY's own comment at the top of the campaign-map draw explains why
-- that stacking is intentional there: "Campaign map: drawn whenever a
-- campaign is open -- including while a tactical battle runs. The server
-- stops streaming WMAP during a battle (the campaign is frozen), so this
-- renders the last-received state above the battle board" (14073-14076).
--
-- This popup is single-focus by design (the plan's brief: "a manual
-- override cycle via a keyless affordance is NOT needed -- the composite
-- follows state"), so where LEGACY stacks, this composite must pick. The
-- natural either/or implied by LEGACY's own comment is used as the mode
-- condition: a tactical battle, once joined, is the thing actually live
-- and interactive -- the campaign march freezes underneath it -- so BATTLE
-- TAKES PRIORITY whenever `S.battle` is present; the campaign map is shown
-- only when there is no battle (whether or not one ever starts). Neither
-- present -> a plain "nothing to show" line, since a popup needs SOME
-- content and this board-only popup carries none of the pane's other
-- sections (council/campaigns/houses) to fall back on -- by design, since
-- this task's brief scopes the popup to the two BOARD views only.
--
-- The prison panel is NOT part of this composite -- it already lives in
-- the pane (pages/war.lua) and this task's brief says explicitly not to
-- duplicate it.
--
-- GESTURE PINNING (fix round 3, completing Important #1's cross-target
-- guard for the composite specifically). active_module() is re-evaluated
-- on every call because `lines`/`geometry`/`grid_line_offset` are pure,
-- stateless reads that MUST always reflect the current mode -- but
-- `on_pointer` is not: a real pointer gesture spans a down and its
-- matching up/cancel, delivered as SEPARATE calls with server state free to
-- change in between (a battle can end -- `S.battle` cleared by the real
-- BATTLE handler -- in the moment between a down on the battle board and
-- its release). Each of war_campaign.lua/war_battle.lua's own on_pointer
-- guards a down-target match with popups/pointer_track.lua, but that guard
-- is powerless against a re-route ABOVE it: if this composite naively
-- re-resolved active_module() on every call, a down consumed by war_battle
-- (recording ITS OWN target) could have its matching up delivered to
-- war_campaign instead once the mode flips -- war_campaign's own tracker
-- never saw that down, so (before this fix) pointer_track's fail-open
-- default let the mismatched up act anyway, sending a real command for a
-- gesture war_campaign was never part of. Fixed by PINNING: a consumed
-- down records which sub-module handled it; up/cancel are routed to that
-- PINNED module regardless of what active_module() would return by then,
-- and the pin clears on up, cancel, and M.reset(). A "move" is pinned the
-- same way while a gesture is in flight (mid-drag hover must stay with the
-- module that owns the drag), but falls back to the live active_module()
-- once no gesture is pinned (plain, uncaptured hover).
--
-- M.geometry/M.grid_line_offset ALSO consult the pin, not just on_pointer:
-- popups.lua's wrapper builds `ctx.cell_from_xy`/`ctx.line_from_y` once per
-- popup-open by calling THIS module's geometry()/grid_line_offset()
-- (see popups.lua's wrap()), so those two must keep resolving the SAME
-- pinned sub-module's grid for the rest of a captured gesture too --
-- otherwise a mode flip mid-drag would still hand the pinned module's own
-- on_pointer a cell computed against the OTHER module's (differently
-- shaped/offset) grid, which is just as wrong as routing to the wrong
-- module in the first place.
local pagelib = require("pagelib")
local state = require("state")
local war_campaign = require("popups.war_campaign")
local war_battle = require("popups.war_battle")

local S = state.S
local C = pagelib.C
local RESET = pagelib.RESET

local M = {}
M.title = "War"

local function active_module()
  if S.battle then return war_battle end
  if S.war_map and S.war_map.active then return war_campaign end
  return nil
end

-- The sub-module a consumed down pinned this in-flight gesture to, or nil
-- when no gesture is captured right now.
local pinned_module = nil
local menu_down = false

function M.lines(width)
  local mod = active_module()
  if not mod then
    return { pagelib.trunc(C.dim .. "No campaign or battle underway." .. RESET, width) }
  end
  return mod.lines(width)
end

function M.on_pointer(ev, ctx)
  -- Right-click the header/background for display options. Board cells
  -- retain their existing deployment/cancel-selection gestures.
  local c = ctx.cell_from_xy and ctx.cell_from_xy(ev.x, ev.y)
  if ev.kind == "cancel" then menu_down = false end
  if ev.button == "right" and ev.kind == "down" and c == nil then
    menu_down = true
    return true
  end
  if ev.button == "right" and ev.kind == "up" and menu_down then
    menu_down = false
    if c == nil and ev.inside ~= false then require("page_menu").open("war") end
    return true
  end
  if ev.kind == "up" or ev.kind == "cancel" then
    -- Route to the module that took the matching down, not whatever
    -- active_module() resolves to NOW -- see the gesture-pinning comment
    -- above. Falls back to the live module only when nothing was pinned
    -- (e.g. an up/cancel that arrives with no captured gesture at all).
    local mod = pinned_module or active_module()
    pinned_module = nil
    if not mod or not mod.on_pointer then return nil end
    return mod.on_pointer(ev, ctx)
  end

  if ev.kind == "down" then
    local mod = active_module()
    if not mod or not mod.on_pointer then return nil end
    local result = mod.on_pointer(ev, ctx)
    if result == true then pinned_module = mod end
    return result
  end

  -- "move" (or anything else): stay with the pinned module while a
  -- gesture is captured; otherwise this is a plain, uncaptured hover, so
  -- the live active_module() is correct.
  local mod = pinned_module or active_module()
  if not mod or not mod.on_pointer then return nil end
  return mod.on_pointer(ev, ctx)
end

function M.geometry(width)
  local mod = pinned_module or active_module()
  if not mod or not mod.geometry then return nil end
  return mod.geometry(width)
end

function M.grid_line_offset(width)
  local mod = pinned_module or active_module()
  if not mod or not mod.grid_line_offset then return 0 end
  return mod.grid_line_offset(width)
end

-- Called by popups.lua's registry when this popup closes: clears any
-- in-flight gesture pin (a closed popup can never receive its matching
-- up/cancel through the normal path -- popup.lua's own finish() already
-- synthesizes a cancel to the wrapper before this runs, so by the time
-- this fires the pin, if any, is already stale) and forwards to both
-- sub-modules' own reset() so whichever one actually holds hover state
-- gets cleared regardless of which is "active" right now.
function M.reset()
  menu_down = false
  pinned_module = nil
  if war_campaign.reset then war_campaign.reset() end
  if war_battle.reset then war_battle.reset() end
end

return M
