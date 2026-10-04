-- Tab bar + page shell for the guild_viking main pane (stage 2). Pages are
-- pure builders (`mod.lines(width) -> array of strings`, reading state.lua's
-- S and page_opts.lua only, per the plan's "pages are pure" constraint); this
-- module owns the tab bar, the page registry, per-page scroll offsets, and
-- pointer routing, matching CLAUDE.md's wm.assign renderer contract:
-- render(rect, opts), on_pointer(event), and auto-captured
-- scroll/scroll_to_bottom/following_tail.
--
-- Task 6 seam: `mod.lines(width)` MAY return a second value, a `targets`
-- array of `{ row, col_start, col_end, action }` -- `row` is the 1-based
-- index into that SAME `lines` array, `col_start`/`col_end` are zero-based
-- visible columns (`col_end` exclusive), matching the tab-span convention
-- below. A page that returns no second value behaves exactly as before
-- (`targets or {}` in window.render, so `on_pointer` just finds nothing to
-- hit-test). Recorded only on a local render pass, alongside `tab_rows` and
-- the scroll `offset`, using the SAME pass-guard idiom as `tab_spans` (see
-- that comment below) and for the SAME reason: a remote WebSocket viewer's
-- own (possibly different) width/height must never clobber what the local
-- click routing depends on.
--
-- Dispatch shape (review round 2, C1): a body-target hit fires its `action`
-- on the matching UP, not the down -- the down only records the hit target
-- and consumes (returns true). This is a deliberate reversal of this
-- module's first cut, which fired on the down directly, reasoning that
-- doing so made a down/drag/up mismatch structurally unreachable. That
-- argument was correct on its own terms but answered the wrong question:
-- LEGACY's own hotspots for these two buttons (MAIN 10548-10551,
-- 10609-10631 -- `WindowAddHotspot`'s five callback slots are MouseOver,
-- CancelMouseOver, MouseDown, CancelMouseDown, MouseUp) wire only the
-- MouseUp slot, exactly like every other hotspot `popups/pointer_track.lua`
-- already exists for (map/cityplan/war/sea) -- LEGACY draws this
-- distinction deliberately elsewhere in the same file (e.g. a hotspot that
-- DOES fill both the MouseDown and MouseUp slots), and the tab bar's own
-- fire-on-down IS therefore correct on its own terms too, because LEGACY's
-- chrome tab hotspot genuinely is a MouseDown hotspot (MAIN 4508 ->
-- viking_chrome_mousedown -> SetPage) -- it isn't "mirroring" anything, it
-- is a separate, independently-verbatim hotspot family. Firing this seam's
-- buttons on the down was therefore an undisclosed behavioral deviation
-- from LEGACY's own MouseUp wiring, and it silently dropped the protection
-- `pointer_track.lua`'s header documents for exactly this hotspot class: a
-- mouseup is delivered only to the hotspot that took the mousedown, even
-- for a hotspot with no MouseDown callback of its own -- so in LEGACY,
-- pressing the wrong mission row and dragging off before releasing is
-- harmless, while a fire-on-down port would have dispatched irrevocably on
-- the press alone. The parity consequence: this seam now needs (and has)
-- a `popups.pointer_track` tracker, same as every other MouseUp-hotspot
-- module in this plugin, following `popups/map.lua`'s own on_pointer
-- shape (record-on-down, fail-closed-match-on-up, clear-on-cancel-and-
-- after-every-up). See the Task 6 report for the mutation that confirms
-- the row-A/row-B drag test actually discriminates on this tracker.
local pagelib = require("pagelib")
local scroller = require("scroller")
local track = require("popups.pointer_track").tracker()
local page_menu = require("page_menu")

local window = {}
local recorded_boards = {}
local pointer_board = nil

-- Ordered page registry. Task 9 replaces the last two placeholder entries
-- (army/war); no PAGES entry still points at pages.placeholder after this --
-- Task 10's audit removed pages/placeholder.lua once nothing referenced it
-- any more.
local stats_page = require("pages.stats")
local city_page = require("pages.city")
local trade_page = require("pages.trade")
local farm_page = require("pages.farm")
local builds_page = require("pages.builds")
local people_page = require("pages.people")
local goods_page = require("pages.goods")
local bonds_page = require("pages.bonds")
local ranks_page = require("pages.ranks")
local court_page = require("pages.court")
local army_page = require("pages.army")
local war_page = require("pages.war")
local livestock_page = require("pages.livestock")
local sea_page = require("popups.sea")

window.PAGES = {
  { key = "stats",  label = "Stats",  mod = stats_page },
  { key = "city",   label = "City",   mod = city_page },
  { key = "farm",   label = "Farm",   mod = farm_page },
  { key = "builds", label = "Builds", mod = builds_page },
  { key = "people", label = "People", mod = people_page },
  { key = "goods",  label = "Goods",  mod = goods_page },
  { key = "bonds",  label = "Bonds",  mod = bonds_page },
  { key = "ranks",  label = "Ranks",  mod = ranks_page },
  { key = "court",  label = "Court",  mod = court_page },
  { key = "army",   label = "Army",   mod = army_page },
  { key = "war",    label = "War",    mod = war_page },
  { key = "trade",  label = "Trade",  mod = trade_page },
  -- Task 2 (Viking husbandry): appended at the END rather than inserted
  -- after "farm" (where it would read more naturally, farm/livestock being
  -- neighbouring concerns) -- deliberately, to avoid reflowing this array's
  -- tab-bar column layout, which guild_viking_window_test.lua asserts
  -- against down to exact pixel columns and wrap-row boundaries (e.g. its
  -- 30-wide wrap test, its scrolled/wrapped Task 6 pointer-seam math).
  -- Appending here leaves every existing tab's column span byte-identical;
  -- confirmed by running the suite both ways -- inserting after "farm"
  -- reflowed the 30-wide wrap points and cascaded into ~10 unrelated
  -- failures, appending here reflowed nothing before it.
  { key = "stock",  label = "Stock",  mod = livestock_page },
  -- Sea is also available as `/vik sea`; in the main Viking window it is a
  -- normal pane page, alongside Builds, People, Goods and Bonds.
  { key = "sea",    label = "Sea",    mod = sea_page },
  { key = "map",    label = "Map",    mod = require("popups.map") },
}

local pages_by_key = {}
for _, p in ipairs(window.PAGES) do pages_by_key[p.key] = p end

-- Cached lines from each page's last render, keyed by page key -- feeds that
-- page's scroller's count() and the windowing math in window.render. Starts
-- empty so a page never rendered yet clamps to offset 0.
local last_lines = {}

-- ---------------------------------------------------------------------------
-- Per-page scrolling: scroller.make_top_scroller (scroller.lua) is
-- top-anchored (offset 0 shows lines[1..height]), unlike wm.make_scroller's
-- tail-anchored convention -- see scroller.lua's module comment for the
-- full rationale. popups.lua's popup wrapper reuses the same scroller.
-- ---------------------------------------------------------------------------
local scrollers = {}
for _, p in ipairs(window.PAGES) do
  last_lines[p.key] = {}
  scrollers[p.key] = scroller.make_top_scroller(function() return #last_lines[p.key] end)
end

local current_key = window.PAGES[1].key

function window.current_page()
  return current_key
end

-- Switching pages preserves each page's own scroller offset (LEGACY's
-- page_scroll behavior) -- nothing here touches `scrollers`.
function window.set_page(key)
  if not pages_by_key[key] then return false end
  if pointer_board and pointer_board.mod.on_pointer then
    pointer_board.mod.on_pointer({kind="cancel"}, {cell_from_xy=function() end})
  end
  pointer_board = nil
  recorded_boards = {}
  current_key = key
  ui.dirty()
  return true
end

function window.scroll(delta)
  return scrollers[current_key].scroll(delta)
end

function window.scroll_to_bottom()
  return scrollers[current_key].scroll_to_bottom()
end

function window.following_tail()
  return scrollers[current_key].following_tail()
end

-- ---------------------------------------------------------------------------
-- Tab bar
-- ---------------------------------------------------------------------------

-- Recorded { key, row, col_start, col_end } spans from the most recent LOCAL
-- render, for on_pointer hit-testing. Mirrors wm.lua's slot-rect recording
-- and popup.lua's render() hit-test rect: recorded only when
-- `lera.render_pass() ~= "remote"` (CLAUDE.md "Pane Pointer Input" /
-- popup.lua's idiom), so a remote render pass never clobbers what the local
-- click routing depends on.
local tab_spans = {}

-- Recorded page-body targets from the most recent LOCAL render (Task 6
-- seam), plus the `tab_rows`/`offset` inputs the row-mapping formula in
-- `window.on_pointer` needs. Same local-only recording discipline as
-- `tab_spans` above -- see this module's header comment.
local page_targets = {}
local recorded_tab_rows = 0
local recorded_offset = 0
local recorded_width = 0
local recorded_image_limit = 2

local SEPARATOR = " "

-- Draws the tab bar into the top of `rect`, flowing onto further rows when
-- the joined label width exceeds the rect width. Returns the number of rows
-- used. Column tracking is explicit (not string length) because the reverse-
-- video escapes wrapping the current tab must not count toward wrap
-- decisions or hit-test spans.
local function render_tabbar(rect)
  local w = rect:w()
  local row_texts, spans = { "" }, {}
  local row, col = 0, 0

  for _, p in ipairs(window.PAGES) do
    local text = p.label
    local seg_len = #text
    if col > 0 and col + seg_len > w then
      row = row + 1
      row_texts[row + 1] = ""
      col = 0
    end
    local start_col = col
    local draw_text = text
    if p.key == current_key then
      draw_text = "\27[7m" .. text .. "\27[27m"
    end
    row_texts[row + 1] = row_texts[row + 1] .. draw_text
    col = col + seg_len
    spans[#spans + 1] = { key = p.key, popup = p.popup, row = row,
      col_start = start_col, col_end = col }
    if col < w then
      row_texts[row + 1] = row_texts[row + 1] .. SEPARATOR
      col = col + 1
    end
  end

  if lera.render_pass() ~= "remote" then
    tab_spans = spans
  end

  for r = 1, row + 1 do
    ui.text_ansi(ui.rect(rect:x(), rect:y() + (r - 1), w, 1),
      pagelib.trunc(row_texts[r] or "", w))
  end

  return row + 1
end

-- ---------------------------------------------------------------------------
-- wm.assign renderer contract
-- ---------------------------------------------------------------------------

function window.render(rect, opts)
  local w, h = rect:w(), rect:h()
  if w <= 0 or h <= 0 then return end

  local tab_rows = render_tabbar(rect)
  local body_h = h - tab_rows

  -- Fix I1 (review round 2): keep `recorded_tab_rows` in lockstep with
  -- `tab_spans` -- both are derived from THIS SAME render_tabbar() call, on
  -- a local pass, regardless of whether `body_h` leaves room to draw a body
  -- at all. Before this fix, a local render that hit the `body_h <= 0`
  -- early return below left `recorded_tab_rows` (and `page_targets`)
  -- describing the PREVIOUS render's layout while `tab_spans` already
  -- reflected the new one -- e.g. a resize that makes the tab bar wrap onto
  -- more rows. A down/up on the new (taller) tab bar could then alias a
  -- stale body target from the old, shorter tab bar, because on_pointer's
  -- `event.y < recorded_tab_rows` guard was comparing against the wrong
  -- number. Clearing `page_targets` here (there is no body to have targets
  -- in) closes that window; `recorded_offset` is left alone since it is
  -- never read when `page_targets` is empty.
  if lera.render_pass() ~= "remote" then
    recorded_tab_rows = tab_rows
    if body_h <= 0 then
      page_targets = {}
    end
  end

  if body_h <= 0 then return end

  local page = pages_by_key[current_key]
  local lines, targets, boards, image_limit = require("tiles").layout(page.mod, w, body_h)

  local sc = scrollers[current_key]
  -- Only the LOCAL render pass may adjust the scroller's height-based clamp,
  -- or update the cached `lines` that clamp's count() reads. The scroll
  -- offset itself is a single Lua-side value shared across render targets by
  -- design (CLAUDE.md "Pane Scrolling" WebSocket note: a Lua-scrolled wm
  -- pane has no local/remote gate). But a remote WebSocket viewer can be
  -- sized independently of the local pane (CLAUDE.md "Resize semantics"),
  -- AND -- for a page whose line count is width-sensitive, stats being the
  -- first -- can produce a different total line count at its own width. If
  -- either leaked into the shared clamp, a remote render could reclamp --
  -- and silently move -- the offset the LOCAL user chose, purely as a side
  -- effect of the remote client's own screen size or width. Skipping both on
  -- a remote pass leaves the persisted clamp (and therefore the offset)
  -- exactly as the last local render left it; the remote pass still reads
  -- that same offset and windows its OWN `lines`/body_h against it below
  -- (see the loop after `offset` is read), it just never mutates the shared
  -- state.
  if lera.render_pass() ~= "remote" then
    last_lines[current_key] = lines
    sc.set_height(body_h)
  end
  local offset = sc.offset()
  local count = #lines
  local first = offset + 1
  local last = math.min(count, offset + body_h)

  -- Task 6 seam: same local-pass-only recording as `last_lines`/
  -- `sc.set_height` just above, and for the identical reason -- see this
  -- module's header comment and `tab_spans`' own comment. `recorded_tab_rows`
  -- is already up to date (set above, before the `body_h <= 0` early
  -- return -- see the I1 fix comment there).
  if lera.render_pass() ~= "remote" then
    page_targets = targets or {}
    recorded_offset = offset
    recorded_width = w
    recorded_image_limit = image_limit
    recorded_boards = boards or {}
  end

  local body_y = rect:y() + tab_rows
  for i = first, last do
    ui.text_ansi(ui.rect(rect:x(), body_y + (i - first), w, 1),
      pagelib.trunc(lines[i], w))
  end
  require("tiles").render(page.mod, ui.rect(rect:x(), body_y, w, body_h), offset, boards)
end

-- Maps a pane-local event's row/col onto the current page's own `targets`
-- array, or nil on a miss. `page_row` uses the SAME inputs the render pass
-- just windowed the visible rows with (`recorded_tab_rows`,
-- `recorded_offset`); an event still on a tab-bar row (`event.y <
-- recorded_tab_rows`) is deliberately excluded rather than allowed to
-- alias onto some body row's target (e.g. the separator column at a
-- wrapped tab bar, or -- before the I1 fix above -- a stale
-- `recorded_tab_rows` from a differently-sized previous render).
local function target_at(event)
  if event.y < recorded_tab_rows then return nil end
  local page_row = (event.y - recorded_tab_rows) + recorded_offset + 1
  for _, t in ipairs(page_targets) do
    if page_row == t.row and event.x >= t.col_start and event.x < t.col_end then
      return t
    end
  end
  return nil
end

-- A LEFT down inside a recorded tab span switches page and returns true
-- immediately (LEGACY's own chrome-tab hotspot fires on MouseDown -- see
-- this module's header comment); every other down (a different/no button,
-- e.g. a middle- or right-click on a tab, or a down elsewhere) returns
-- false so the pane never falsely claims an interaction it didn't handle.
--
-- A body-target down instead just records the hit via `track` and
-- consumes (`return true`) -- it does NOT fire `action` yet. The matching
-- UP re-hit-tests at ITS OWN coordinates and only fires when that hit
-- target's identity (`row`+`col_start`, encoded through `track` as a
-- "cell") matches what the down recorded (`track.matches`, fail-closed: no
-- recorded down at all also means no match) -- reproducing LEGACY's real
-- MouseUp-hotspot semantics
-- (a mouseup only reaches the hotspot that took the matching mousedown)
-- despite wm.lua's own capture being coarser than that (button-only, no
-- notion of which target the down landed on -- see `popups/
-- pointer_track.lua`'s header for the full rationale, and this module's
-- header comment for why this seam needs that discipline where the tab
-- bar's fire-on-down dispatch does not). `action` is pcall'd so an errant
-- target can never wedge the pane or leak an error out of `on_pointer`.
-- `cancel` (popup-covering-pane, focus loss, a second down while
-- captured, etc. -- see CLAUDE.md's "Pane Pointer Input") and every up
-- (matched or not) clear the tracker.
function window.on_pointer(event)
  -- Cancel is handled before the button check, because wm.lua synthesizes it
  -- with `button = capture.button` -- a RIGHT-button gesture's cancel
  -- therefore carries button == "right", and gating this branch on "left"
  -- would leave that gesture's record behind for a later up to match against.
  if event.kind == "cancel" then
    track.clear()
    if pointer_board and pointer_board.mod.on_pointer then
      pointer_board.mod.on_pointer(event, {cell_from_xy=function() end})
    end
    pointer_board = nil
    return false
  end

  -- RIGHT-click: the per-page context menu (page_menu.lua, LEGACY's
  -- right-click page-body hotspot at guild_viking.lua:11151-11163). Body only
  -- -- a right-click on the tab bar is a no-op, matching LEGACY's hotspot,
  -- which covered the page body and not its chrome tabs. Same down/up
  -- discipline as the body-target path below (record on down, consume, act on
  -- a matching up) for the same reason: LEGACY's hotspot fired on MouseUp, so
  -- pressing in the pane and releasing outside it must do nothing.
  -- pointer_track's `same()` compares c/r only for kind == "cell"; every other
  -- kind matches on kind alone, which is what this whole-body gesture wants --
  -- there is exactly one target, so identity IS the kind.
  if event.button == "right" then
    if event.kind == "down" then
      if event.y < recorded_tab_rows then return false end
      if not page_menu.has_menu(current_key) then return false end
      track.record({ kind = "pagemenu" })
      return true
    end
    if event.kind == "up" then
      local matched = event.inside and event.y >= recorded_tab_rows
        and track.matches({ kind = "pagemenu" })
      track.clear()
      if matched then
        page_menu.open(current_key)
        return true
      end
      return false
    end
    return false
  end

  -- Inline maps use the same pointer handlers as their detached popups.
  -- Pin a press to its board until release, including when GMCP updates it.
  if event.y >= recorded_tab_rows and (event.button == "left" or event.kind == "move") then
    local board = pointer_board
    if not board then
      local row = event.y - recorded_tab_rows + recorded_offset
      for _, b in ipairs(recorded_boards) do
        if b.full_page or (b.geometry and row >= b.offset
            and row < b.offset + b.geometry.height) then board = b; break end
      end
    end
    if board and board.mod.on_pointer then
      local ev = {}
      for k,v in pairs(event) do ev[k] = v end
      ev.y = event.y - recorded_tab_rows
      ev.width = recorded_width
      local ctx = {
        close = function() end,
        cell_from_xy = function(x,y)
          if board.geometry then return board.geometry.cell_at(x, y+recorded_offset-board.offset) end
        end,
      }
      if board.full_page then ctx.line_from_y = function(y) return y+recorded_offset+1 end end
      local consumed = board.mod.on_pointer(ev, ctx)
      if event.kind == "down" and consumed then pointer_board = board end
      if event.kind == "up" then pointer_board = nil end
      if consumed then return true end
    end
  elseif event.kind == "up" and pointer_board then
    pointer_board.mod.on_pointer({kind="cancel"}, {cell_from_xy=function() end})
    pointer_board = nil
  end

  if event.button ~= "left" then return false end

  if event.kind == "down" then
    for _, s in ipairs(tab_spans) do
      if event.y == s.row and event.x >= s.col_start and event.x < s.col_end then
        return window.set_page(s.key)
      end
    end
    local t = target_at(event)
    if t then
      -- popups/pointer_track.lua's `same()` only compares c/r for
      -- kind=="cell" -- every OTHER kind matches on kind alone (see its
      -- header/body). Encoding this target's identity as a "cell" with
      -- r=row, c=col_start is what makes the match value-discriminating
      -- (two different targets, or a stale one, correctly fail to match)
      -- rather than degenerating into "any target matches any other".
      track.record({ kind = "cell", r = t.row, c = t.col_start })
      return true
    end
    return false
  end

  if event.kind ~= "up" then return false end

  local t = target_at(event)
  local matched = t ~= nil and track.matches({ kind = "cell", r = t.row, c = t.col_start })
  track.clear()
  if matched then
    pcall(t.action)
    return true
  end
  return false
end

local pointer = window.on_pointer
function window.on_pointer(event)
  return require("maplib").with_limit(recorded_image_limit, function()
    return pointer(event)
  end)
end

return window
