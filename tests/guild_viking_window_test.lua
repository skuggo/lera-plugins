-- guild_viking window/tab-bar unit tests. Run from the lera-plugins repo
-- root with LERA_ROOT pointing at a built Lera checkout.
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

-- ---- lera API stubs ---------------------------------------------------------
local function make_rect(x, y, w, h)
  return {
    x = function() return x end, y = function() return y end,
    w = function() return w end, h = function() return h end,
  }
end

local dirty_count = 0
local drawn -- { ansi = {...}, texts = {...} }, reset per case that cares
local function reset_drawn() drawn = { ansi = {}, texts = {} } end
reset_drawn()

ui = {
  dirty = function() dirty_count = dirty_count + 1 end,
  rect = function(x, y, w, h) return make_rect(x, y, w, h) end,
  text = function(r, s) drawn.texts[#drawn.texts + 1] = { x = r:x(), y = r:y(), s = s } end,
  text_ansi = function(r, s) drawn.ansi[#drawn.ansi + 1] = { x = r:x(), y = r:y(), s = s } end,
}

local render_pass = "local"
lera = { render_pass = function() return render_pass end }

-- Review round 2, I3: the real People-page end-to-end case sends through
-- mud.send -- captured here so that case can assert exact command strings.
local send_calls = {}
mud = { send = function(s) send_calls[#send_calls + 1] = s end }

local window = require("window")

-- Snapshot the real page modules right after requiring window, before any
-- later section in this file replaces find_page("stats").mod /
-- find_page("city").mod with fake { lines = ... } tables for windowing-math
-- tests -- the Task 10 end-to-end pass appended at the bottom needs the REAL
-- modules restored, regardless of what ran in between.
local real_mods = {}
for _, p in ipairs(window.PAGES) do real_mods[p.key] = p.mod end

-- ---- PAGES registry ---------------------------------------------------------
-- Task 2 (Viking husbandry) appended "stock" as a 13th entry, AFTER "trade"
-- rather than after "farm" (where the order would read more naturally) --
-- deliberately, so every tab BEFORE it here keeps the exact column span
-- this file's tab-bar/pointer-seam math below already asserts against.
local expected_pages = {
  { key = "stats",  label = "Stats" },
  { key = "city",   label = "City" },
  { key = "farm",   label = "Farm" },
  { key = "builds", label = "Builds" },
  { key = "people", label = "People" },
  { key = "goods",  label = "Goods" },
  { key = "bonds",  label = "Bonds" },
  { key = "ranks",  label = "Ranks" },
  { key = "court",  label = "Court" },
  { key = "army",   label = "Army" },
  { key = "war",    label = "War" },
  { key = "trade",  label = "Trade" },
  { key = "stock",  label = "Stock" },
  { key = "sea",    label = "Sea" },
  { key = "map",    label = "Map" },
}
check("PAGES has 15 entries", #window.PAGES == 15, #window.PAGES)
local pages_ok = true
for i, exp in ipairs(expected_pages) do
  local got = window.PAGES[i]
  if not got or got.key ~= exp.key or got.label ~= exp.label then pages_ok = false end
end
check("PAGES keys/labels match the fourteen Viking tabs", pages_ok)
check("every PAGES entry is a valid page module (stats real, the rest placeholder)", (function()
  for _, p in ipairs(window.PAGES) do
    if type(p.mod) ~= "table" or type(p.mod.lines) ~= "function" then
      return false
    end
  end
  return true
end)())
check("current_page defaults to stats", window.current_page() == "stats")

local function find_page(key)
  for _, p in ipairs(window.PAGES) do
    if p.key == key then return p end
  end
end

-- ---- tab bar: all fourteen labels rendered, current highlighted ------------
reset_drawn()
window.render(make_rect(0, 0, 100, 5), {})
check("tab bar drew at least the header row", #drawn.ansi >= 1)
local tabrow = drawn.ansi[1] and drawn.ansi[1].s or ""
local all_present = true
for _, p in ipairs(expected_pages) do
  if not tabrow:find(p.label, 1, true) then all_present = false end
end
check("tab bar contains all fourteen labels", all_present, tabrow)
check("current tab (Stats) is reverse-video highlighted",
      tabrow:find("\27%[7mStats\27%[27m") ~= nil, tabrow)
check("non-current tab (City) is not reverse-video wrapped",
      not tabrow:find("\27%[7mCity\27%[27m"), tabrow)

-- ---- set_page: switches, unknown key refused --------------------------------
check("set_page switches to a known key", window.set_page("city") == true)
check("current_page reflects the switch", window.current_page() == "city")
check("set_page refuses an unknown key", window.set_page("bogus") == false)
check("current_page unchanged after a refused switch", window.current_page() == "city")
check("set_page back to stats", window.set_page("stats") == true)

-- ---- on_pointer: tab-span down switches page, body down does not -----------
-- Column layout for a 100-wide bar (one label per gap, 1-space separator):
-- Stats[0,5) City[6,10) Farm[11,15) Builds[16,22) ... -- verified against the
-- render above (all thirteen labels fit on row 0 at width 100).
reset_drawn()
window.render(make_rect(0, 0, 100, 5), {})

local down_on_farm = { kind = "down", button = "left", x = 12, y = 0,
                       inside = true, width = 100, height = 5 }
check("down on Farm's tab span switches page", window.on_pointer(down_on_farm) == true)
check("current_page is now farm", window.current_page() == "farm")

-- Fix 3: only a LEFT down on a tab switches pages; a middle (or right)
-- button on the exact same span must fall through false and leave the
-- current page untouched, same as a down elsewhere in the pane.
window.set_page("stats")
local middle_down_on_farm = { kind = "down", button = "middle", x = 12, y = 0,
                              inside = true, width = 100, height = 5 }
check("middle-button down on Farm's tab span returns false",
      window.on_pointer(middle_down_on_farm) == false)
check("current_page unchanged by a middle-button tab down", window.current_page() == "stats")

window.set_page("stats")
local down_in_body = { kind = "down", button = "left", x = 5, y = 2,
                        inside = true, width = 100, height = 5 }
check("down in the body returns false", window.on_pointer(down_in_body) == false)
check("current_page unchanged by a body down", window.current_page() == "stats")

-- ---- per-page scroller offsets are independent; windowing respects offset --
local stats_lines = {}
for i = 1, 50 do stats_lines[i] = "L" .. i end
find_page("stats").mod = { lines = function() return stats_lines end }
find_page("city").mod = { lines = function() return { "C1", "C2", "C3" } end }

window.set_page("stats")
local body_rect = make_rect(0, 0, 100, 5) -- tab row (1) + body height (4)

reset_drawn()
window.render(body_rect, {})
-- drawn.ansi[1] is the tab row; body rows follow.
check("stats body starts at L1 before scrolling",
      drawn.ansi[2] and drawn.ansi[2].s:find("^L1%s") ~= nil, drawn.ansi[2] and drawn.ansi[2].s)
check("stats following_tail true before scrolling", window.following_tail() == true)

window.scroll(10)
check("stats following_tail false after scrolling down", window.following_tail() == false)

reset_drawn()
window.render(body_rect, {})
check("stats body windowed to the new offset (L11..L14)",
      drawn.ansi[2] and drawn.ansi[2].s:find("^L11%s") ~= nil
      and drawn.ansi[5] and drawn.ansi[5].s:find("^L14%s") ~= nil,
      drawn.ansi[2] and drawn.ansi[2].s)

check("switching to city switches page", window.set_page("city") == true)
reset_drawn()
window.render(body_rect, {})
check("city (never scrolled) is at its own tail", window.following_tail() == true)
check("city shows its own short content",
      drawn.ansi[2] and drawn.ansi[2].s:find("^C1%s") ~= nil, drawn.ansi[2] and drawn.ansi[2].s)

check("switching back to stats", window.set_page("stats") == true)
check("stats offset preserved across the page switch", window.following_tail() == false)
reset_drawn()
window.render(body_rect, {})
check("stats still windowed at L11..L14 after switching away and back",
      drawn.ansi[2] and drawn.ansi[2].s:find("^L11%s") ~= nil, drawn.ansi[2] and drawn.ansi[2].s)

window.scroll_to_bottom()
check("scroll_to_bottom moves stats to its last page", window.following_tail() == false)
reset_drawn()
window.render(body_rect, {})
check("stats tail window ends at L50",
      drawn.ansi[5] and drawn.ansi[5].s:find("^L50%s") ~= nil, drawn.ansi[5] and drawn.ansi[5].s)

-- ---- remote pass does not clobber hit-test spans ----------------------------
window.set_page("stats")
render_pass = "local"
reset_drawn()
window.render(make_rect(0, 0, 100, 5), {}) -- records spans for the WIDE layout
check("(setup) down on Farm's span works against the wide layout",
      window.on_pointer(down_on_farm) == true and window.current_page() == "farm")
window.set_page("stats")

render_pass = "remote"
reset_drawn()
local ok_remote = pcall(window.render, make_rect(0, 0, 20, 5), {}) -- drastically different layout
check("remote render into a different-width rect does not error", ok_remote)

check("remote pass did not update the recorded spans",
      window.on_pointer(down_on_farm) == true and window.current_page() == "farm")

-- ---- Finding 1 (review round 1): a remote pass at a DIFFERENT height must --
-- not mutate the shared scroller clamp a later local render depends on. -----
window.set_page("stats")
render_pass = "local"
reset_drawn()
window.render(body_rect, {})       -- establishes height = 4 (body_rect's body_h)
window.scroll_to_bottom()          -- offset -> 46 (count 50 - height 4)
reset_drawn()
window.render(body_rect, {})       -- "before": window at H1 = 4
check("(setup) before window ends at L50",
      drawn.ansi[5] and drawn.ansi[5].s:find("^L50%s") ~= nil, drawn.ansi[5] and drawn.ansi[5].s)
local before_window = { drawn.ansi[2].s, drawn.ansi[3].s, drawn.ansi[4].s, drawn.ansi[5].s }

render_pass = "remote"
reset_drawn()
-- H2 = 10 (a TALLER remote body) -- if set_height ran unguarded here, the
-- clamp's max (count - height) would shrink from 46 to 40 and reclamp the
-- LOCAL offset down, even though only a remote viewer's own size changed.
local ok_remote_height = pcall(window.render, make_rect(0, 0, 100, 11), {})
check("remote render at a different height does not error", ok_remote_height)

render_pass = "local"
reset_drawn()
window.render(body_rect, {})       -- render locally again at the SAME H1
local after_window = { drawn.ansi[2].s, drawn.ansi[3].s, drawn.ansi[4].s, drawn.ansi[5].s }
check("local window unchanged after an intervening remote render at a different height",
      after_window[1] == before_window[1] and after_window[2] == before_window[2]
      and after_window[3] == before_window[3] and after_window[4] == before_window[4],
      after_window[1])

-- ---- Finding 4 (carried into Task 3 review): a remote pass at a DIFFERENT
-- width, for a page whose line COUNT itself depends on width (stats is the
-- first such page), must not mutate the shared last_lines cache a later
-- local render's scroller clamp depends on -- the count axis, distinct from
-- Finding 1's height axis above.
window.set_page("stats")
render_pass = "local"
local wide_lines, narrow_lines = {}, {}
for i = 1, 50 do wide_lines[i] = "W" .. i end
for i = 1, 5 do narrow_lines[i] = "N" .. i end
find_page("stats").mod = {
  lines = function(w) return (w >= 50) and wide_lines or narrow_lines end,
}

reset_drawn()
window.render(make_rect(0, 0, 100, 5), {})  -- W1 = 100: wide_lines (50 rows)
window.scroll_to_bottom()                   -- offset -> 46 (50 - body_h 4)
reset_drawn()
window.render(make_rect(0, 0, 100, 5), {})  -- "before": window at W1 = 100
check("(setup) before window ends at W50",
      drawn.ansi[5] and drawn.ansi[5].s:find("^W50%s") ~= nil, drawn.ansi[5] and drawn.ansi[5].s)
local before_count_window = { drawn.ansi[2].s, drawn.ansi[3].s, drawn.ansi[4].s, drawn.ansi[5].s }

render_pass = "remote"
reset_drawn()
-- W2 = 20: narrow_lines (only 5 rows) -- if last_lines were updated here
-- unguarded, count() would drop from 50 to 5 and the next local render's
-- clamp would yank the offset back down, even though only a remote
-- viewer's own width differed.
local ok_remote_count = pcall(window.render, make_rect(0, 0, 20, 5), {})
check("remote render at a different width (different line count) does not error", ok_remote_count)

render_pass = "local"
reset_drawn()
window.render(make_rect(0, 0, 100, 5), {})  -- render locally again at the SAME W1
local after_count_window = { drawn.ansi[2].s, drawn.ansi[3].s, drawn.ansi[4].s, drawn.ansi[5].s }
check("local window unchanged after an intervening remote render at a different width",
      after_count_window[1] == before_count_window[1] and after_count_window[2] == before_count_window[2]
      and after_count_window[3] == before_count_window[3] and after_count_window[4] == before_count_window[4],
      after_count_window[1])

-- ---- Finding 2a (review round 1): a down on a WRAPPED (row>0) tab span ----
-- switches page and returns true. A 30-wide rect wraps the twelve labels
-- onto three rows: row0 Stats/City/Farm/Builds/People, row1
-- Goods/Bonds/Ranks/Court/Army, row2 War/Trade (verified against
-- render_tabbar's column bookkeeping: Goods[0,5) Bonds[6,11) ...).
window.set_page("stats")
render_pass = "local"
reset_drawn()
window.render(make_rect(0, 0, 30, 10), {})
check("narrow rect wraps the tab bar onto multiple rows", #drawn.ansi >= 3)
check("wrapped row 1 contains Bonds",
      drawn.ansi[2] and drawn.ansi[2].s:find("Bonds", 1, true) ~= nil,
      drawn.ansi[2] and drawn.ansi[2].s)

local down_on_wrapped_bonds = { kind = "down", button = "left", x = 8, y = 1,
                                 inside = true, width = 30, height = 10 }
check("down on a wrapped-row tab span switches page",
      window.on_pointer(down_on_wrapped_bonds) == true)
check("current_page is now bonds (from a row-1 span)", window.current_page() == "bonds")
window.set_page("stats")

-- ---- Finding 2b (review round 1): a down on the separator column between --
-- two adjacent labels matches neither span and returns false.
render_pass = "local"
reset_drawn()
window.render(make_rect(0, 0, 100, 5), {}) -- restores the wide layout's spans
local page_before_separator_down = window.current_page()
local down_on_separator = { kind = "down", button = "left", x = 5, y = 0, -- the
                             -- single space between Stats[0,5) and City[6,10)
                             inside = true, width = 100, height = 5 }
check("down on the separator column between two tabs returns false",
      window.on_pointer(down_on_separator) == false)
check("separator down does not change the page",
      window.current_page() == page_before_separator_down)

render_pass = "local"

-- =============================================================================
-- Task 6: page-level pointer targets seam. A fake page module returns a
-- second `lines(width)` value (a targets array) exercising the whole
-- contract: row/col hit-testing (both column edges), the SCROLLED and
-- wrapped-tab-bar row mapping, GENUINE tab-bar priority (a target that
-- would also match the SAME coordinate if the tab check didn't run first),
-- error containment, the remote-pass guard (at a rect that actually
-- reaches the guarded block), the I1 fix (a narrow-pane render that hits
-- window.render's early `body_h <= 0` return must not leave stale
-- tab-bar/target state behind), and THE discriminating case: a down on one
-- target followed by an "up" delivered at a DIFFERENT target's coordinates
-- must never fire either target. Review round 2 (C1) reversed this seam's
-- dispatch from fire-on-down to a fail-closed down-record/up-fire tracker
-- (`popups/pointer_track.lua`, same shape as `popups/map.lua`'s own
-- on_pointer) -- see window.lua's header comment for why.
-- =============================================================================
window.set_page("stats")
render_pass = "local"

local seam_fired = {}
local seam_lines = {}
for i = 1, 10 do seam_lines[i] = "R" .. i end
local seam_error_row = 5
-- Target D (row 2) exists ONLY to construct M3's genuine tab/target
-- conflict below -- see that section for why row 2 specifically.
local seam_targets = {
  { row = 2, col_start = 0, col_end = 5, action = function() seam_fired[#seam_fired + 1] = "D" end },
  { row = 3, col_start = 2, col_end = 8, action = function() seam_fired[#seam_fired + 1] = "A" end },
  { row = 7, col_start = 0, col_end = 4, action = function() seam_fired[#seam_fired + 1] = "B" end },
  { row = seam_error_row, col_start = 0, col_end = 4, action = function() error("boom") end },
}
-- Width-sensitive (I2 fix): a width < 25 returns NO targets at all. This is
-- what makes the remote-pass guard test below actually discriminate --
-- same precedent as this file's own Finding 4 (`wide_lines`/`narrow_lines`)
-- for `last_lines`. A fake page that returned the SAME `seam_targets`
-- regardless of width would make a remote render at any width
-- indistinguishable from a local one, so removing the guard would leave
-- the whole suite green. width >= 25 covers every OTHER seam case in this
-- file (100 and 30-wide rects).
find_page("stats").mod = {
  lines = function(w)
    if w < 25 then return seam_lines, {} end
    return seam_lines, seam_targets
  end,
}

-- 100-wide -> tab bar is one row (tab_rows == 1, established earlier in this
-- file); an 8-row rect gives body_h == 7 (y in [1,7] maps to page_row ==
-- y at offset 0, since page_row = (y - 1) + 0 + 1 == y).
local seam_rect = make_rect(0, 0, 100, 8)
reset_drawn()
window.render(seam_rect, {})
check("(setup) seam body shows R1 first",
      drawn.ansi[2] and drawn.ansi[2].s:find("^R1%s") ~= nil, drawn.ansi[2] and drawn.ansi[2].s)

-- Small helper: a matched down+up pair at the SAME (x, y) -- the ordinary
-- "click" case every button-style target is dispatched through now.
local function click(x, y, w, h)
  window.on_pointer({ kind = "down", button = "left", x = x, y = y, inside = true, width = w, height = h })
  return window.on_pointer({ kind = "up", button = "left", x = x, y = y, inside = true, width = w, height = h })
end

-- ---- down alone does NOT fire; only the matching up does ------------------
seam_fired = {}
local down_only = window.on_pointer({ kind = "down", button = "left", x = 4, y = 3,
                                       inside = true, width = 100, height = 8 })
check("a down on target A consumes (returns true) but fires nothing yet",
      down_only == true and #seam_fired == 0, seam_fired)
local up_only = window.on_pointer({ kind = "up", button = "left", x = 4, y = 3,
                                     inside = true, width = 100, height = 8 })
check("the matching up (same coordinates) then fires target A",
      up_only == true and #seam_fired == 1 and seam_fired[1] == "A", seam_fired)

-- ---- row hit / column miss / row miss (full click) -------------------------
seam_fired = {}
check("click inside target A's row/col span fires A", click(4, 3, 100, 8) == true)
check("target A fired exactly once", #seam_fired == 1 and seam_fired[1] == "A", seam_fired)

seam_fired = {}
check("click on target A's row but outside its column span returns false",
      click(0, 3, 100, 8) == false)
check("column miss fires nothing", #seam_fired == 0)

seam_fired = {}
check("click on a row with no target returns false", click(4, 4, 100, 8) == false)
check("row miss fires nothing", #seam_fired == 0)

-- ---- M2: column boundaries at BOTH edges of a real span -------------------
-- Target A is col_start=2, col_end=8 (exclusive) -- the boundary a real
-- button's `[` (col_start) and one past its `]` (col_end) sit at.
seam_fired = {}
check("M2: x == col_start (2) is INSIDE the span (inclusive left edge)",
      click(2, 3, 100, 8) == true and #seam_fired == 1 and seam_fired[1] == "A", seam_fired)
seam_fired = {}
check("M2: x == col_start - 1 (1) is OUTSIDE the span", click(1, 3, 100, 8) == false)
check("M2: left-edge-miss fires nothing", #seam_fired == 0)
seam_fired = {}
check("M2: x == col_end - 1 (7) is INSIDE the span (inclusive right edge)",
      click(7, 3, 100, 8) == true and #seam_fired == 1 and seam_fired[1] == "A", seam_fired)
seam_fired = {}
check("M2: x == col_end (8) is OUTSIDE the span (col_end is exclusive)",
      click(8, 3, 100, 8) == false)
check("M2: right-edge-miss fires nothing", #seam_fired == 0)

-- ---- tab-bar priority: a GENUINE conflict, not a click where nothing else
-- could ever match -----------------------------------------------------------
-- Target D (row 2, col [0,5)) was placed to coincide with what page_row
-- WOULD compute to for a tab-bar-row click, once the pane is scrolled: with
-- tab_rows=1, offset=2, y=0 (a real "Stats" tab hit, col [0,5)) gives
-- page_row = (0 - 1) + 2 + 1 = 2 -- exactly D's row, with an overlapping
-- column span. So this coordinate is a genuine ambiguity in NUMBERING
-- terms -- D's row/col happen to equal what the raw page_row arithmetic
-- produces for this tab-row click -- not merely "a coordinate with no
-- target nearby".
--
-- Correction (review round 3): checking tab spans before `target_at` is
-- NOT what resolves this ambiguity, and reordering those two checks is an
-- EQUIVALENT MUTANT (survives the whole suite) -- because `target_at`
-- carries its own independent guard (`event.y < recorded_tab_rows`), and
-- every tab span's `row` is, by construction, one of the rows
-- `render_tabbar` wrapped onto (0..recorded_tab_rows-1) while every
-- reachable page_row is >= 1 once that guard passes. The two regions
-- (tab-bar rows vs. body rows) are disjoint BY CONSTRUCTION, from the
-- SAME `render_tabbar` call under the SAME `lera.render_pass() ~= "remote"`
-- guard that also produced `recorded_tab_rows` -- so `target_at` already
-- rejects this y before either check order could matter. What this case
-- actually verifies is that a tab click still switches pages correctly
-- even when a fake target's numbers happen to collide with what the raw
-- arithmetic would produce if the guard were bypassed -- i.e. that the
-- guard (not the check order) is doing the real work. M1 below pins the
-- guard itself with a mutation that only it can catch.
seam_fired = {}
window.set_page("stats")
window.scroll(2) -- offset -> 2
reset_drawn()
window.render(seam_rect, {}) -- recorded_offset picks up 2
local down_conflict = window.on_pointer({ kind = "down", button = "left", x = 2, y = 0,
                                           inside = true, width = 100, height = 8 })
check("M3: a down on the ambiguous coordinate switches page (tab wins)", down_conflict == true)
local up_conflict = window.on_pointer({ kind = "up", button = "left", x = 2, y = 0,
                                         inside = true, width = 100, height = 8 })
check("M3: the matching up at the SAME ambiguous coordinate still fires no body target",
      up_conflict == false and #seam_fired == 0, seam_fired)
window.scroll(-2) -- back to offset 0
reset_drawn()
window.render(seam_rect, {})
window.set_page("stats")

-- ---- M1: the `event.y < recorded_tab_rows` guard, pinned on its own -----
-- (review round 3): M3 above is an equivalent-mutant case for check
-- ORDER (see its corrected comment) -- this case instead removes the tab
-- span match entirely and relies SOLELY on the guard. A WRAPPED tab bar
-- (30-wide -> tab_rows=3, established earlier in this file) with
-- body_h=7 (so targets ARE recorded, unlike I1's body_h<=0 case) and the
-- pane SCROLLED to its max offset (3, clamped against count 10 - height
-- 7): clicking a SEPARATOR column on a tab-bar row that matches NO tab
-- span at all must still not reach a body target through the raw
-- page_row arithmetic.
--
-- Row 2 of the 30-wide wrapped bar is War[col 0,3) then Trade[col 4,9)
-- (render_tabbar's own column bookkeeping: after Goods..Army wrap onto
-- row 1 -- established by the "wrapped row 1 contains Bonds" case earlier
-- in this file -- War (3 chars) starts row 2 at col 0..2, a 1-col
-- separator follows at col 3, then Trade (5 chars) occupies col 4..8);
-- column 3 is that separator, matching NEITHER span. Without the guard,
-- page_row for (x=3, y=2) at tab_rows=3, offset=3 would be
-- (2 - 3) + 3 + 1 = 3 -- exactly target A's row, and x=3 IS inside A's
-- col span [2, 8) -- the same misfire class as the original I1 defect,
-- reachable here purely by clicking a tab-bar gap on a scrolled, wrapped
-- pane.
seam_fired = {}
window.set_page("stats")
local m1_rect = make_rect(0, 0, 30, 10)
reset_drawn()
window.render(m1_rect, {}) -- tab_rows=3, body_h=7 -- establishes scroller height=7
window.scroll(3) -- offset -> 3 (clamped against count 10 - height 7 = 3)
check("(M1 setup) scrolled to the max offset (3)", window.following_tail() == false)
reset_drawn()
window.render(m1_rect, {}) -- re-render so recorded_offset picks up 3
check("(M1 setup) row 2 of the wrapped bar contains War and Trade",
      drawn.ansi[3] and drawn.ansi[3].s:find("War", 1, true) ~= nil
      and drawn.ansi[3].s:find("Trade", 1, true) ~= nil,
      drawn.ansi[3] and drawn.ansi[3].s)
check("M1: a separator column (x=3) on a wrapped, scrolled tab-bar row (y=2) fires nothing",
      click(3, 2, 30, 10) == false)
check("M1: no body target fired from the separator click", #seam_fired == 0, seam_fired)
window.scroll(-3) -- back to offset 0
reset_drawn()
window.render(seam_rect, {}) -- restore the wide layout's recorded state
window.set_page("stats")

-- ---- SCROLLED mapping: offset > 0 shifts which screen row hits which target-
seam_fired = {}
window.scroll(2) -- offset -> 2 (clamped against count 10 - height 7 = 3)
check("(setup) scrolled offset is 2", window.following_tail() == false)
reset_drawn()
window.render(seam_rect, {}) -- re-render so recorded_offset picks up 2
check("(setup) scrolled body now starts at R3",
      drawn.ansi[2] and drawn.ansi[2].s:find("^R3%s") ~= nil, drawn.ansi[2] and drawn.ansi[2].s)
-- page_row = (y - 1) + 2 + 1 = y + 2; target A (row 3) is now hit at y = 1.
check("scrolled: y=1 now maps to target A's row", click(4, 1, 100, 8) == true)
check("scrolled hit fired A", #seam_fired == 1 and seam_fired[1] == "A", seam_fired)
-- the OLD unscrolled y (3) now maps to page_row 5 (the error target's row),
-- but x=4 misses its col span [0,4) -- still a genuine miss.
seam_fired = {}
check("scrolled: the old y=3 (now a different row) still misses at this column",
      click(4, 3, 100, 8) == false)
check("scrolled old-y click fires nothing", #seam_fired == 0)
window.scroll(-2) -- back to offset 0
reset_drawn()
window.render(seam_rect, {})

-- ---- wrapped tab bar: tab_rows > 1 shifts the row mapping too -------------
-- A 30-wide rect wraps the twelve page tabs onto 3 rows (established
-- earlier in this file), so tab_rows == 3 here; page_row = (y - 3) + 0 + 1.
-- Target A (row 3) is hit at y = 3 - 1 + 3 = 5.
seam_fired = {}
local narrow_seam_rect = make_rect(0, 0, 30, 12)
reset_drawn()
window.render(narrow_seam_rect, {})
check("(setup) narrow rect wraps the tab bar onto 3 rows", #drawn.ansi >= 4)
check("wrapped tab bar: y=5 maps onto target A's row", click(4, 5, 30, 12) == true)
check("wrapped-tab-bar hit fired A", #seam_fired == 1 and seam_fired[1] == "A", seam_fired)
reset_drawn()
window.render(seam_rect, {}) -- restore the wide layout's recorded state

-- ---- errored action is contained; the pane keeps working afterward -------
seam_fired = {}
local ok_error_call, result_error_call = pcall(click, 1, seam_error_row, 100, 8)
check("an erroring action does not propagate the error out of on_pointer",
      ok_error_call and result_error_call == true, result_error_call)
seam_fired = {}
check("the pane still dispatches normally after a contained action error",
      click(4, 3, 100, 8) == true and #seam_fired == 1 and seam_fired[1] == "A")

-- ---- I2 fix: the remote-pass guard test now uses a rect that actually ----
-- REACHES the guarded block (tab_rows=4, body_h=4 at 20x8 -- survivable,
-- unlike the old 20x4 rect, where tab_rows=4 and body_h=0 made
-- window.render bail at the `body_h <= 0` return BEFORE the guarded block,
-- so removing the guard entirely left the whole suite green). See the I1
-- section below for the case that specifically exercises the body_h<=0
-- early return.
window.set_page("stats")
render_pass = "local"
reset_drawn()
window.render(seam_rect, {}) -- records targets/tab_rows/offset for the WIDE layout
render_pass = "remote"
reset_drawn()
local ok_remote_seam = pcall(window.render, make_rect(0, 0, 20, 8), {}) -- reaches the guarded block
check("remote render at a different (but survivable) layout does not error", ok_remote_seam)
render_pass = "local"
seam_fired = {}
check("remote pass did not clobber the recorded seam state -- the wide-layout hit still works",
      click(4, 3, 100, 8) == true and #seam_fired == 1 and seam_fired[1] == "A")

-- ---- I1 fix + M1: a local render that hits the body_h<=0 early return ----
-- must not leave `recorded_tab_rows`/`page_targets` describing the OLD
-- (taller-bodied) layout. Reproduces the reviewer's exact scenario: render
-- 100x8 (tab_rows=1, body_h=7, records target A at page_row=3), then
-- render 20x4 (tab_rows=4, body_h=0 -- the early return). Before the I1
-- fix, `recorded_tab_rows` stayed 1 (stale) while `tab_spans` already
-- reflected the new 4-row wrapped bar, so a click on any of tab rows 1-3
-- (all genuinely `event.y < 4`, i.e. ON the new tab bar, but NOT `< 1`)
-- would fall through the `event.y < recorded_tab_rows` guard using the
-- STALE value and alias page_row = y (with the stale tab_rows=1, offset=0)
-- straight onto target A's row (3) at y=3, or the error target's row (5) --
-- reachable at y=3 only via this exact stale-state bug (y=3 is a real
-- tab-bar row when tab_rows==4, which no genuine body coordinate could
-- ever be simultaneously). This test also stands in for M1 (a dedicated
-- case for the `event.y < recorded_tab_rows` guard): the guard only
-- becomes exercised in a way that matters once I1 keeps it in sync.
render_pass = "local"
window.set_page("stats")
reset_drawn()
window.render(seam_rect, {}) -- 100x8: tab_rows=1, records target A at row 3
local ok_narrow = pcall(window.render, make_rect(0, 0, 20, 4), {}) -- tab_rows=4, body_h=0
check("(I1 setup) a narrow render that hits body_h<=0 does not error", ok_narrow)
seam_fired = {}
local any_fired_on_tabbar_rows = false
for y = 0, 3 do -- every row of the NEW (4-row) tab bar
  seam_fired = {}
  click(4, y, 20, 4)
  if #seam_fired > 0 then any_fired_on_tabbar_rows = true end
end
check("I1: no tab-bar-row click on the narrow layout fires a stale body target",
      not any_fired_on_tabbar_rows, seam_fired)
-- The loop above clicks real tab-bar coordinates on the 20-wide wrapped
-- bar, so some of those downs may have genuinely matched a DIFFERENT
-- page's tab span and switched `current_page()` away from "stats" (the
-- fake module lives only at the "stats" slot) -- restore it explicitly
-- before re-rendering the wide layout for the drag test below.
window.set_page("stats")
reset_drawn()
window.render(seam_rect, {})

-- ---- THE discriminating case: down on target A, up delivered at target --
-- B's coordinates, must fire NEITHER (not A -- the down alone never fires
-- anything now -- and not B, since the up's own resolved target doesn't
-- match what the down recorded). This is wm.lua's real dispatch shape for
-- a captured gesture: after a down returns true, wm.lua re-invokes this
-- SAME on_pointer with kind == "up" at wherever the release landed,
-- translated into the SAME pane-local coordinate space (scripts/default/
-- wm.lua's `local_event`) -- it does not re-hit-test against the down's
-- target first. Calling on_pointer directly with a synthetic "up" event,
-- as below, reproduces that real shape.
seam_fired = {}
local down_A_for_drag = { kind = "down", button = "left", x = 4, y = 3, inside = true, width = 100, height = 8 }
check("drag setup: down on target A consumes but fires nothing",
      window.on_pointer(down_A_for_drag) == true and #seam_fired == 0)
local up_at_B = { kind = "up", button = "left", x = 2, y = 7, inside = true, width = 100, height = 8 }
local up_result = window.on_pointer(up_at_B)
check("drag: an 'up' event at target B's coordinates returns false (mismatch)",
      up_result == false)
check("drag: NEITHER target fired -- not B, and not A a second time",
      #seam_fired == 0, seam_fired)

render_pass = "local"
window.set_page("stats")

-- =============================================================================
-- I3 (review round 2): the REAL People page, driven end to end through the
-- REAL window.on_pointer dispatch, with its mission data driven through
-- protocol.ingest (the real MISSIONS/WSTOCK wire, and Guild.Map
-- handlers) rather than hand-poking S directly -- pinning the exact
-- column span pages/people.lua actually records, end to end, rather than
-- via the fake page module the rest of this section uses. Registration
-- mirrors guild_viking_voyage_test.lua's own top-of-file idiom (the same
-- one init.lua uses in production) -- protocol.handler/pattern_handler are
-- one-shot per key, so this runs once, here, for the whole suite.
-- =============================================================================
do
  local protocol = require("protocol")
-- init.lua's RESERVED set: the module-level convention fields, not MIP keys.
local RESERVED_KEYS = { _market_seam = true, _patterns = true, _gmcp = true,
                        _retired_keys = true, _retired_patterns = true }
  -- Mirrors init.lua's RESERVED set and its three registration tiers; two of
  -- these modules carry a `_gmcp` writer table, so treating it as a MIP key
  -- would register the same name twice.
  local RESERVED = RESERVED_KEYS
  local function register(mod_name)
    local mod = require(mod_name)
    for key, fn in pairs(mod._gmcp or {}) do
      protocol.gmcp_handler(key, fn)
    end
  end
  register("handlers.city")   -- MISSIONS
  register("handlers.voyage") -- Guild.Map
  register("handlers.trade")  -- WSTOCK

  local page_opts = require("page_opts")
  local pagelib = require("pagelib")
  -- Isolate the Missions section: no other people-page section, no patrol
  -- (S.patrol is never set in this file), so the ONE mission's button row
  -- is locatable unambiguously.
  page_opts.set("show_people_settlers", false)
  page_opts.set("show_people_garrison", false)
  page_opts.set("show_people_raids", false)
  page_opts.set("show_people_thralls", false)
  page_opts.set("show_people_missions", true)

  -- Sufficient grain (100 >= 30 needed) -> the mission button renders
  -- enabled. A tiny 4x1 all-passable strip: player at (0,0), target
  -- Holmgard at (3,0) -- a genuine 3-step route (not "already there"),
  -- so the send sequence below discriminates dirs-then-enter from the
  -- #path==0 branch's enter+fulfill (pages/people.lua's mission_run_click,
  -- MAIN 12080-12143).
  protocol.on_gmcp("Guild.Trade", { guild = "viking",
    wstock = { { good = "grain", amount = 100, pct = 100 } } })
  protocol.on_gmcp("Guild.City", { guild = "viking", missions = { {
    id = 7, label = "Deliver grain to Holmgard", rep = 15, reward = 200,
    secs = 1800, origin = "Vestergotland", town = "Holmgard",
    goods = { grain = 30 } } } })
  protocol.on_gmcp("Guild.Map", {
    guild = "viking", w = 4, h = 1, active = 1, pos = { x = 0, y = 0 },
    enc = { terrain = "glyph", east = "glyph", south = "glyph" },
    terrain = { "pppp" }, east = { "111" },
    landmarks = {
      { type = "lineage", name = "Uppsala", x = 0, y = 0, owner = "" },
      { type = "lineage", name = "Vestergotland", x = 1, y = 0, owner = "" },
      { type = "capital", name = "Holmgard", x = 3, y = 0, owner = "" },
    },
  })

  check("(I3 setup) MISSIONS ingest populated S.missions via the real handler",
        #(require("state").S.missions or {}) == 1)

  window.set_page("people")
  render_pass = "local"
  reset_drawn()
  window.render(make_rect(0, 0, 100, 40), {}) -- tall enough for the whole (isolated) section

  -- Locate the button row/column from the ACTUAL RENDERED TEXT -- not
  -- from window's own recorded targets, which is what this test exists to
  -- pin independently. `bracket_byte` is the raw byte offset of "[Run
  -- There]"; the VISIBLE column it starts at is the visible width of
  -- everything before it (escape sequences cost zero width, per
  -- pagelib.trunc's own convention), which this computes directly rather
  -- than assuming the leading indent is exactly 2 unescaped spaces.
  local btn_entry, bracket_byte
  for _, d in ipairs(drawn.ansi) do
    local b = d.s:find("%[Run There%]")
    if b then btn_entry, bracket_byte = d, b; break end
  end
  check("(I3 setup) the rendered People page contains a 'Run There' button row", btn_entry ~= nil)

  local col_start = pagelib.visible_width(btn_entry.s:sub(1, bracket_byte - 1))
  local col_end = col_start + pagelib.visible_width("[Run There]")
  local btn_y = btn_entry.y

  check("(I3 pin) the button's column span is exactly [2, 13) -- 2-space indent + '[Run There]' (11 chars)",
        col_start == 2 and col_end == 13, col_start .. ".." .. col_end)

  send_calls = {}
  local down_hit = window.on_pointer({ kind = "down", button = "left", x = col_start, y = btn_y,
                                        inside = true, width = 100, height = 40 })
  check("(I3) a down on the real button's column/row consumes", down_hit == true)
  check("(I3) the down alone sends nothing yet", #send_calls == 0)
  local up_hit = window.on_pointer({ kind = "up", button = "left", x = col_start, y = btn_y,
                                      inside = true, width = 100, height = 40 })
  check("(I3) the matching up fires the button", up_hit == true)
  check("(I3) exact byte-for-byte send sequence: 3 travel directions then enter, no fulfill",
        #send_calls == 4 and send_calls[1] == "east" and send_calls[2] == "east"
        and send_calls[3] == "east" and send_calls[4] == "enter",
        table.concat(send_calls, ","))

  -- M2 (applied to the REAL button, not the fake one): one column short of
  -- col_start (the '[') misses; one past col_end - 1 (the ']') misses too.
  send_calls = {}
  window.on_pointer({ kind = "down", button = "left", x = col_start - 1, y = btn_y,
                       inside = true, width = 100, height = 40 })
  window.on_pointer({ kind = "up", button = "left", x = col_start - 1, y = btn_y,
                       inside = true, width = 100, height = 40 })
  check("(I3) one column left of the real button's '[' sends nothing", #send_calls == 0)
  window.on_pointer({ kind = "down", button = "left", x = col_end, y = btn_y,
                       inside = true, width = 100, height = 40 })
  window.on_pointer({ kind = "up", button = "left", x = col_end, y = btn_y,
                       inside = true, width = 100, height = 40 })
  check("(I3) one column past the real button's ']' sends nothing", #send_calls == 0)

  page_opts.set("show_people_settlers", true)
  page_opts.set("show_people_garrison", true)
  page_opts.set("show_people_raids", true)
  page_opts.set("show_people_thralls", true)
end

window.set_page("stats")
render_pass = "local"
send_calls = {}

-- =============================================================================
-- Task 10: end-to-end pane pass -- every page in window.PAGES rendered at
-- real pane dimensions with a representative state slice, no page crashing,
-- no emitted row overflowing the rect width, and scrolling working without
-- error. Seeds below are borrowed from guild_viking_pages1-4_test.lua so most
-- sections have real data rather than falling back to "no data yet" text.
-- This is the "no page crashes at real dimensions" lock the task brief asks
-- for.
-- =============================================================================

local pagelib = require("pagelib")
local state = require("state")
local page_opts = require("page_opts")
local S = state.S

-- Restore the REAL page modules (a mid-file section above replaced stats'
-- and city's `.mod` with fake scroller-math doubles).
for _, p in ipairs(window.PAGES) do p.mod = real_mods[p.key] end

-- Replicates render_tabbar's own wrap bookkeeping (window.lua) so the test
-- can tell tab rows apart from body rows in what gets drawn, without
-- exporting that internal from window.lua itself.
local function count_tab_rows(width)
  local row, col = 0, 0
  for _, p in ipairs(window.PAGES) do
    local seg_len = #p.label
    if col > 0 and col + seg_len > width then
      row = row + 1
      col = 0
    end
    col = col + seg_len
    if col < width then col = col + 1 end
  end
  return row + 1
end

-- ---- seed a representative state slice across every page -------------------

-- stats
S.daler = 12345
S.hp, S.mhp, S.hp_delta = 350, 500, 5
S.threk, S.mthrek, S.threk_delta = 10, 50, -2
S.seid, S.mseid, S.seid_delta = 80, 100, 0
S.vig, S.mvig, S.vig_delta = 40, 80, 0
S.rad, S.mrad, S.rad_delta = 20, 40, 0
S.fury = "[***-------]"
S.ldng, S.mldng, S.lrst = 3, 4, 10
S.chain, S.bsdepth = 7, 2
S.god_power_name, S.god_power_next = "Odin's Fury", 125
S.vis, S.vis_gain, S.vis_session = 100, 5, 20
S.kap, S.kap_gain, S.kap_session = 200, 3, 15
S.soe, S.soe_gain, S.soe_session = 50, 0, 5
S.aud, S.aud_gain, S.aud_session = 10, 1, 2
S.xp_session_start = os.time() - 65
S.en5, S.ens, S.rndz = "Wolf", "low", 3
S.mob_name_full, S.estatus_pct, S.combat = "Grey Wolf", 42, true
S.stfx = { { name = "ein", val = "54", cat = "Def" } }

-- city
S.ships = { { name = "Ravager", tier = 2, state = "raiding", target = "Vestergotland",
              return_in = 90, crew = 8, ship_id = nil, convoy = 0, durability = 100 } }
S.raidlog = { { ship = "Ravager", target = "vestergotland", daler = 150,
                goods = { { good = "furs", qty = 12 } }, thralls = 2, lost = false } }
S.buildings = { warehouse = 3, dock = 2 }
S.wstock = {
  { good = "grain", amount = 100, freshness_pct = 100 },
  { good = "fish", amount = 50, freshness_pct = 100 },
  { good = "timber", amount = 200, freshness_pct = 100 },
}
S.next_tick_in = 45
S.production = { timber = 25, ore = 10 }
S.upkeep = { roster = 50, community = 20, throne = 10, roads = 5, forts = 5, total = 90 }
S.routes = { hold = { name = "Hold", road_tier = 2, fort_tier = 1,
                       road_maint = 80, fort_maint = 60, road_name = "", fort_name = "" } }
S.route_upkeep = 12
S.monuments = { "Saga of the North Wind" }
S.monument_cap = 5

-- trade
S.dispatch_cd = 0
S.carts = { { mode = "buy", good = "furs", village = "Vestergotland", return_in = 120,
              amount = 50, halfway_in = 0, quality_pct = 100, cart_id = 3, tier = 2,
              durability = 90, cap = 200, escort = 1, refit = "standard", legs = {} } }
S.idle_carts = { { cart_id = 7, tier = 1, durability = 100, cap = 150, refit = "standard" } }
S.cart_upgrades = { { cart_id = 3, target_tier = 3, secs_left = -1, mats_total = 10,
                       mats_done = 4, mats = { { good = "timber", done = 4, need = 10 } },
                       target_refit = "", job_type = "upgrade" } }
S.courier = { tier = 2, runs = { { good = "fish", village = "Imaird", return_in = 60,
                                    amount = 20, cost = 100, fee = 5 } } }
S.spy = { tier = 1, mode = "sabotage", village = "Holmgard", secs = 300, sab_pct = 10,
          sab_secs = 500, cd_secs = 0, scouts = { { city = "Uppsala", amb = 15, secs = 200 } } }
S.train = { tier = 1, name = "Erik", stat = "combat", trained = 2, secs = 400 }
S.heat = { 10, 80, 5 }
S.grudges = { { town = "Birka", secs = 3600 } }
S.trade_queue = { { mode = "sell", good = "mead", village = "Lejre", amount = 30, escort = 2 } }
S.market_orders = { { id = 1, buyer = "olaf", good = "iron", remaining = 15, price = 8, age_secs = 60 } }
S.incoming_fills = { { good = "honey", amount = 25, arrives_in = 90, seller = "astrid" } }

-- farm
S.season = "spring"
S.weather = "storm"
S.weather_str = 3
S.farm_wmod = 15
S.farm_plots = {
  { coord = "A1", shroom = "fly_agaric_t1", time_left = 0, fertilized = 0, wilt_left = -1 },
  { coord = "A2", shroom = "lions_mane_t2", time_left = 3600, fertilized = 1, wilt_left = -1 },
}
S.city_water = 40
S.city_fert = 25
S.blot_status = "open"
S.blot_reset_in = 3661
S.blot_filled = 4
S.blot_total = 9

-- builds
S.pending_builds = {
  { bldg_id = "warehouse", tier = 2, mats_total = 10, mats_done = 3,
    complete_at_secs = -1, total_build_secs = 0,
    mats = { { good = "timber", done = 3, need = 10 } } },
}
S.ship_upgrades = {
  { name = "Ormen", tier = 3, secs_left = -1, mats_total = 5, mats_done = 2,
    mats = { { good = "iron", done = 2, need = 5 } } },
}
S.bdmg = { { bldg_id = "palisade", pct = 72 } }
S.staff_list = {
  { name = "Ragnar", assigned_to = "0", stat_key = "combat",
    stats = { combat = 10, trade = 2 }, trait = "berserker", loyalty = 4,
    age = "young", arrive_at = 0 },
}

-- people
S.settlers = 42
S.settler_tax = 2
S.settler_edict = "feast"
S.settler_edict_left = 125
S.settler_edict_cd = 0
S.settler_housing_cap = 300
S.settler_housing_plots = 12
S.settler_housing_avg = 250
S.settler_housing_plot_tiers = { t1 = 4, t2 = 3, t3 = 2, t4 = 0 }
S.settler_housing_upkeep = 15
S.settler_community_upkeep = 8
S.settler_jobs = 30
S.settler_employed = 25
S.settler_market_staffed = 3
S.settler_mood = 82
S.settler_housing_quality = 65
S.settler_sustenance = 44
S.settler_emp_score = 30
S.settler_security = 90
S.settler_dignity = 20
S.settler_sentiment = 5
S.settler_flourishing = 1
S.settler_community_net = 120
S.settler_mult_pct = 150
S.settler_community_buildings = { mead_hall = 2, well = 0 }
S.settler_consumption = { grain = 6, water = 4 }
S.settler_supply_next = 300
S.settler_pop_next = 600
S.settler_actions = { { name = "Assembly", secs = 90 } }
S.settler_projects = {
  { id = "longhouse", kind = "housing_upgrade", from_tier = 1, to_tier = 2,
    secs_left = -1, mats_total = 10, mats_done = 4, daler = 50,
    mat_detail = { timber = { have = 4, need = 10 } } },
}
S.settler_identity = "Builders' Hold"
S.settler_roles = {
  { key = "smidir", label = "Builders", cur = 40, tgt = 55, work = 10, bonus = 8 },
  { key = "boendr", label = "Farmers", cur = 30, tgt = 30, work = 5, bonus = 0 },
}
S.settler_commoner = 12
S.patrol = { count = 3, remaining = 45 }
S.garrison_stationed = 8
S.garrison_free = 2
S.garrison_cap = 10
S.garrison_defpower = 55
S.hird_list = {
  { name = "Ragnar", status = "personal_guard", level = 6, atk = 7, def = 5,
    loyalty = 4, age_phase = "veteran", mode = "offensive", champ = 1, wpn = 3, arm = 2 },
}
S.varang_out = { { name = "Skoll's Band", count = 12, expires_in = 3661 } }
S.varang_in = { { name = "Ingvar's Reinforcements", count = 6, expires_in = 120 } }
S.raid_in = 200
S.raid_faction = "Skalgrim Reavers"
S.raid_strength = 80
S.thralls = 14
S.thrall_assignments = { longhouse = 3, warehouse = 2 }
S.thrall_follower_level = 4
S.thrall_follower_name = "grimna"
S.thrall_follower_xp = 120
S.thrall_follower_xp_cap = 400
S.thrall_follower_carry_used = 10
S.thrall_follower_carry_cap = 40
S.thrall_follower_status = "following"
S.missions = {
  { id = 7, label = "Deliver grain to Holmgard", expires_in = 1800,
    origin_town = "Vestergotland", target_town = "Holmgard",
    reward = 200, reward_rep = 15, want_goods = { grain = 30 } },
}
S.errand = {
  id = 99, label = "Fetch water", expires_in = 5400,
  origin_town = "", target_town = "Holmgard",
  reward = 0, reward_good = "water", reward_qty = 10,
}
S.mission_reg_left = 2
S.mission_new_left = 0

-- goods
S.trade_goods = {
  [0] = { iron = { score = -3, supply = 100, demand = 0, buy = 5, sell = 0 },
          mead = { score = 2, supply = 0, demand = 10, buy = 0, sell = 40 } },
  [1] = { iron = { score = 2, supply = 0, demand = 100, buy = 0, sell = 50 } },
}
S.demand_cycle = "Spring Growth"
S.demand_cycle_in = 0
S.wstock_by_good = { mead = { amount = 20 } }
S.blocks = {}
S.autotrade.show_n = 6
S.autotrade.status = "cooldown"
S.autotrade.last_msg = "sell 4x Mead -> Midgard; buy 2x Furs -> Lodbrok's"
S.autotrade.log = {
  { t = "10:00", jobs = { { mode = "sell", qty = 3, good = "mead", stown_lin = 0, profit = 90, margin = 30 } } },
}
S.price_history = { [0] = { iron = { { t = 1, b = 5, s = 40 }, { t = 2, b = 15, s = 60 } } } }
page_opts.set("auto_trade", true)
page_opts.set("show_goods_atlog", true)

-- bonds
S.hird_by_id = {
  [1] = { name = "Ragnar Ironside" },
  [2] = { name = "Skoll" },
}
S.bonds_list = {
  { id_a = 1, id_b = 2, ticks = 850000, tier = 3 },
  { id_a = 3, id_b = 4, ticks = 30000, tier = 0 },
}

-- ranks
S.standings = {
  [1] = { name = "Own Lineage", score = 50, label = "Neutral", is_own = true },
  [2] = { name = "Rival Lineage", score = 620, label = "Allied", is_own = false },
  [3] = { name = "Foe Lineage", score = -350, label = "Feud", is_own = false },
}
S.village_rep = {
  [2] = { name = "Holmgard", rep = 150, rank = 2, start_at = 100, next_at = 300 },
  [1] = { name = "Vestergotland", rep = 999, rank = 7, start_at = 500, next_at = 0 },
}

-- court
S.dynasty = {
  realm = "Norvik", house = "Ulfsson",
  spouse = { name = "Astrid", house = "Ulfsson", age = 34, rank = 2 },
  heir = "Bjorn",
  living = 2, cap = 4,
  children = {
    { name = "Bjorn", gender = "male", age = 16, adult = true, trait = "bold", role = "warrior" },
    { name = "Freya", gender = "female", age = 8, adult = false, trait = "", role = nil },
  },
}

-- army
S.army = {
  conscripts = 42, cap = 10, used = 6,
  units = {
    { uid = 1, type = "skirmishers", size = 12, vet = 55, ready = true,
      leader = "Ivar", traits = { "Blooded", "Scarred" } },
    { uid = 2, type = "huscarls", size = 8, vet = 0, ready = false,
      leader = nil, traits = {} },
  },
}

-- war
S.war_map = {
  active = true, dim = 5, turn = 3, mode = "offense", pending = 0,
  town = "Jorvik", works_budget = 0, march_eta = 125,
  rows = { ".....", ".....", ".....", ".....", "....." },
  upkeep = { food = 10, mead = 5, tools = 2, iron = 1, daler = 3 },
  spoils = { daler = 500, renown = 20, deeds = 2 },
}
S.prison = {
  held = 2, cap = 5, kin = 1, pending = true,
  pend_name = "Ragnar", pend_size = 8, pend_cmd = true,
  roster = { { id = 1, name = "Thrall A", size = 3, cmd = false, val = 50 } },
}
S.siege = { engines = 2, cap = 4 }
S.battle = {
  phase = "turn", target = "Jorvik", mode = "field", turn = 3,
  budget = 100, spent = 60, war_points = 30,
  units = {
    { side = "you", label = "huscarls", size = 8, coord = "C3", morale = 80, leader = "Ivar" },
    { side = "foe", label = "foe_raiders", size = 10, coord = "D4", morale = 20 },
  },
}
S.war_points = 30
S.war = {
  incoming = { town = "Kaupang", strength = 120, days = 3 },
  claims = { { town = "Hedeby", days = 10 } },
  campaigns = { { town = "Hedeby", defense = 40, max = 100 } },
}
S.diplomacy = {
  allies = { { house = "Ivarsson", standing = 5 } },
  foes = { { house = "Ragnarsson", standing = -3 } },
}

-- ---- render every page at 80x24 (a real output-pane-sized rect) -----------
render_pass = "local"
local TAB_ROWS_80 = count_tab_rows(80)
for _, p in ipairs(window.PAGES) do
  window.set_page(p.key)
  reset_drawn()
  local ok, err = pcall(window.render, make_rect(0, 0, 80, 24), {})
  check("80x24 " .. p.key .. ": renders without error", ok, err)

  local widest = nil
  for _, d in ipairs(drawn.ansi) do
    local vw = pagelib.visible_width(d.s)
    if widest == nil or vw > widest then widest = vw end
  end
  check("80x24 " .. p.key .. ": at least one non-tab row rendered",
        #drawn.ansi > TAB_ROWS_80, #drawn.ansi)
  check("80x24 " .. p.key .. ": every emitted row's visible width <= 80",
        widest == nil or widest <= 80, widest)

  local ok_scroll, err_scroll = pcall(function()
    window.scroll(-5)
    window.scroll(5)
    window.render(make_rect(0, 0, 80, 24), {})
  end)
  check("80x24 " .. p.key .. ": scroll(-5) then scroll(5) renders without error",
        ok_scroll, err_scroll)
end

-- ---- render every page at a narrow 40x12 rect (tab bar wraps) -------------
local TAB_ROWS_40 = count_tab_rows(40)
check("40x12: tab bar wraps onto more than one row at this width", TAB_ROWS_40 > 1, TAB_ROWS_40)
for _, p in ipairs(window.PAGES) do
  window.set_page(p.key)
  reset_drawn()
  local ok, err = pcall(window.render, make_rect(0, 0, 40, 12), {})
  check("40x12 " .. p.key .. ": renders without error", ok, err)

  local widest = nil
  for _, d in ipairs(drawn.ansi) do
    local vw = pagelib.visible_width(d.s)
    if widest == nil or vw > widest then widest = vw end
  end
  check("40x12 " .. p.key .. ": at least one non-tab row rendered",
        #drawn.ansi > TAB_ROWS_40, #drawn.ansi)
  check("40x12 " .. p.key .. ": every emitted row's visible width <= 40",
        widest == nil or widest <= 40, widest)

  local ok_scroll, err_scroll = pcall(function()
    window.scroll(-5)
    window.scroll(5)
    window.render(make_rect(0, 0, 40, 12), {})
  end)
  check("40x12 " .. p.key .. ": scroll(-5) then scroll(5) renders without error",
        ok_scroll, err_scroll)
end

window.set_page("stats")
render_pass = "local"

-- =============================================================================
-- Per-page context menu on RIGHT-click (page_menu.lua, LEGACY's right-click
-- page-body hotspot at guild_viking.lua:11151-11163).
--
-- These cases drive window.on_pointer directly; the same feature is driven
-- through the REAL scripts/default/popup.lua dispatch layer for the two popup
-- surfaces in guild_viking_popup_dispatch_test.lua. Both layers are needed:
-- a module-level test cannot see a swallowed down, which is exactly how a
-- dead click shipped in stage 3.
-- =============================================================================
local pm_opened = nil
package.loaded["menu"] = {
  open = function(spec) pm_opened = spec end,
  close = function() pm_opened = nil end,
  is_open = function() return pm_opened ~= nil end,
}
package.loaded["persist"] = { save = function() end, load = function() end }

-- Restore the real page modules (earlier sections swap in fakes) and render
-- once so recorded_tab_rows/page_targets describe a real layout.
for _, p in ipairs(window.PAGES) do
  for _, q in ipairs(window.PAGES) do
    if q.key == p.key then q.mod = real_mods[p.key] end
  end
end
window.set_page("stats")
window.render(make_rect(0, 0, 100, 20), {})

local function rclick(kind, x, y, inside)
  return window.on_pointer({
    kind = kind, button = "right", x = x, y = y,
    inside = inside == nil and true or inside, width = 100, height = 20,
  })
end

-- A right down in the BODY consumes (so the matching up is delivered at all)
-- but must not open anything yet -- LEGACY's hotspot fired on MouseUp.
pm_opened = nil
check("right down in the pane body consumes", rclick("down", 10, 5) == true)
check("right down alone opens no menu", pm_opened == nil)
check("the matching right up opens the page menu",
  rclick("up", 10, 5) == true and pm_opened ~= nil)
check("the menu opened is the CURRENT page's",
  pm_opened and pm_opened.title == "Stats", pm_opened and pm_opened.title)

-- Switching pages switches which menu a right-click opens.
window.set_page("city")
window.render(make_rect(0, 0, 100, 20), {})
pm_opened = nil
rclick("down", 10, 5); rclick("up", 10, 5)
check("after set_page the right-click menu follows the page",
  pm_opened and pm_opened.title == "City", pm_opened and pm_opened.title)

-- Fail-closed: a right down that is released OUTSIDE the pane opens nothing.
-- This is the protection LEGACY's MouseUp hotspot gave for free (a mouseup
-- reaches only the hotspot that took the down), and it is what a fail-open
-- tracker would silently lose.
pm_opened = nil
check("right down consumes before the drag", rclick("down", 10, 5) == true)
check("right up released off-pane does not consume",
  rclick("up", 10, 5, false) ~= true)
check("right up released off-pane opens no menu", pm_opened == nil)

-- A right up with no recorded down (fail-closed default) opens nothing.
pm_opened = nil
check("a bare right up with no recorded down does not consume",
  rclick("up", 10, 5) ~= true)
check("a bare right up opens no menu", pm_opened == nil)

-- Cancel (popup covering the pane, focus loss, a second down) clears the
-- record, so a later up cannot act on it. wm.lua synthesizes cancel with the
-- CAPTURED button, i.e. "right" here -- window.on_pointer must therefore
-- handle cancel before its button check.
pm_opened = nil
rclick("down", 10, 5)
window.on_pointer({ kind = "cancel", button = "right", x = 10, y = 5,
                    inside = true, width = 100, height = 20 })
check("right up after a cancel does not consume", rclick("up", 10, 5) ~= true)
check("right up after a cancel opens no menu", pm_opened == nil)

-- The tab bar is chrome: LEGACY's hotspot covered the page BODY only.
pm_opened = nil
check("right down on the tab bar does not consume", rclick("down", 2, 0) ~= true)
check("right down on the tab bar opens no menu", pm_opened == nil)

-- A LEFT click must be entirely unaffected by any of the above.
pm_opened = nil
local left_consumed = window.on_pointer({
  kind = "down", button = "left", x = 2, y = 0,
  inside = true, width = 100, height = 20,
})
check("a left down on a tab still switches page (unchanged)", left_consumed == true)
check("a left tab click opens no context menu", pm_opened == nil)

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING WINDOW TESTS PASSED")
