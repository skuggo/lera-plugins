-- Named-popup registry + generic pane-page-to-popup wrapper, backing /vik's
-- popup subcommands (map/sea/voyage/cityplan/war -> toggle; pop <page> ->
-- open_page). See CLAUDE.md's "Popup Overlay" section for the
-- require("wm").popup contract sandboxed plugins reach -- open/close/
-- is_open, owner-bound, one popup at a time.
--
-- A renderer module registered here has the shape:
--   { lines = function(width) -> array of strings, PURE,
--     on_pointer = function(ev, ctx) -> bool|nil, OPTIONAL,
--     geometry = function(width) -> maplib geom | nil, OPTIONAL,
--     grid_line_offset = function(width) -> integer, REQUIRED iff geometry is,
--     reset = function() -> clears any module-local hover/tooltip state,
--       OPTIONAL (fix round 2, Minor). popups.toggle's own on_close calls
--       this (when present) so a stale tooltip from wherever the pointer
--       last was doesn't show immediately on the NEXT open, before any
--       fresh move/down arrives -- see e.g. popups/map.lua's M.reset.
--     title = "..." }
-- `lines` must read only its own view's state (page state / page_opts);
-- `on_pointer` may mud.send, mutate the view's own module-local state, open
-- require("menu"), and ui.dirty() -- see the plan's Global Constraints.
--
-- ctx.cell_from_xy contract (grid views: map/sea/cityplan/war): a module
-- that draws a maplib grid inside its `lines(width)` output can also expose
-- `geometry(width)` -- the SAME grid + opts handed to maplib.geometry, so
-- hit-testing can never drift from what was actually drawn -- plus
-- `grid_line_offset(width)`, the count of lines the module renders ABOVE the
-- grid (headers, position readout, legend, ...) at that width. When both are
-- present, the wrapper below builds `ctx.cell_from_xy(x, y)`: `x`/`y` are
-- wrapper-local coordinates in the SAME space as the `ev.x`/`ev.y` a pointer
-- event already carries (0-based, relative to the popup's own top-left --
-- see CLAUDE.md's "Pane Pointer Input"), and it returns whatever
-- `geom.cell_at` returns (a `c, r` pair, or nil for anything outside the
-- grid). The mapping accounts for the wrapper's own scroll offset (the
-- module's `lines` may be scrolled within the popup) and the module's
-- pre-grid lines, so the module itself never has to know about scrolling:
-- `gy = y + scroll_offset - grid_line_offset(width)`, then
-- `geom.cell_at(x, gy)`. A module with no grid (or no data to grid right
-- now) simply omits `geometry`/`grid_line_offset` and `ctx.cell_from_xy` is
-- nil, exactly like today.
--
-- ctx.line_from_y contract (any module with `on_pointer`, grid or not): a
-- non-grid clickable line -- a text row that is itself the whole hit target,
-- like guild_viking's sea/voyage popups' single "[Actions]" line -- has no
-- cell to look up, only an ABSOLUTE 1-based index into the module's own
-- `lines(width)` output. `ctx.line_from_y(y)` converts a pointer event's
-- wrapper-local `y` into that index: `y + scroll_offset + 1` (the wrapper
-- draws `lines[offset+1 .. offset+h]` at screen rows `0 .. h-1`, so screen
-- row `y` is 1-based line index `y + offset + 1` -- the same derivation
-- `cell_from_xy` documents, one step short of subtracting a grid offset).
-- Unlike `cell_from_xy`, this is always present on `ctx` whenever the module
-- has `on_pointer` at all -- it needs no companion module hook the way
-- `cell_from_xy` needs `geometry`/`grid_line_offset`, since a module that
-- wants to hit-test a specific line already knows (or can derive) that
-- line's own index from its own `lines(width)` construction.
local scroller = require("scroller")
local pagelib = require("pagelib")
local window = require("window")

local popups = {}

local registry = {}

-- Name of the popup last opened via popups.toggle -- cleared by that
-- specific open's own on_close closure, so it always reflects whichever
-- toggle-opened popup (if any) is actually the one on screen right now,
-- regardless of whether it closed via a second toggle, Escape, an outside
-- click, or being replaced by another popup (named or /vik pop).
local shown_name = nil

-- Registers (or replaces) a named popup's renderer module. map/sea/voyage/
-- cityplan/war all self-register at the bottom of this file (see the
-- require+register block there); an unrecognized name still prints the
-- "no such popup" message below, but every one of these five is shipped.
function popups.register(name, module)
  registry[name] = module
end

-- Introspection helper: sorted array of the names currently registered.
-- Cheap and honest -- it reads the same `registry` table popups.toggle()
-- consults, so a name missing here really is unreachable via /vik, not
-- just absent from some separate manifest. Used by init.lua's
-- M.popup_names() (the headless sandbox check's probe that this file's
-- five self-registrations at the bottom actually ran).
function popups.names()
  local names = {}
  for name in pairs(registry) do names[#names + 1] = name end
  table.sort(names)
  return names
end

-- Wraps a pure lines(width) builder (plus an optional on_pointer) in a
-- scrolling wm.popup renderer. The cached line count feeding the scroller's
-- clamp is pass-guarded exactly like window.lua's own render(): only the
-- LOCAL render pass may update it, so a remote WebSocket viewer's own popup
-- size can never reclamp -- and silently move -- the local user's scroll
-- offset (see window.lua's render() comment for the full rationale; this is
-- the identical mechanism, reused here for the same reason).
local function wrap(lines_fn, on_pointer_fn, geometry_fn, grid_line_offset_fn, image_limit)
  local last_count = 0
  local last_width = 0
  local last_image_limit = 2
  local sc = scroller.make_top_scroller(function() return last_count end)

  local wrapper = {}

  function wrapper.render(rect, opts)
    local w, h = rect:w(), rect:h()
    if w <= 0 or h <= 0 then return end
    local lines, _, boards, chosen_image_limit = require("tiles").layout({lines=lines_fn,
      geometry=geometry_fn, grid_line_offset=grid_line_offset_fn,
      image_limit=image_limit}, w, h)
    if lera.render_pass() ~= "remote" then
      last_count = #lines
      last_width = w
      last_image_limit = chosen_image_limit
      sc.set_height(h)
    end
    local offset = sc.offset()
    local first = offset + 1
    local last = math.min(#lines, offset + h)
    for i = first, last do
      ui.text_ansi(ui.rect(rect:x(), rect:y() + (i - first), w, 1),
        pagelib.trunc(lines[i], w))
    end
    require("tiles").render({ geometry=geometry_fn, grid_line_offset=grid_line_offset_fn },
      rect, offset, boards)
  end

  wrapper.scroll = sc.scroll
  wrapper.scroll_to_bottom = sc.scroll_to_bottom
  wrapper.following_tail = sc.following_tail

  -- ctx.cell_from_xy joins ctx only when the module supplies both
  -- geometry() and grid_line_offset() -- see the ctx.cell_from_xy contract
  -- above. `last_width` is whatever the most recent LOCAL render pass drew
  -- at (pass-guarded exactly like last_count, above), which is the only
  -- render a real pointer event can ever follow.
  if on_pointer_fn then
    function wrapper.on_pointer(ev)
      local ctx = {
        close = function() require("wm").popup.close() end,
        line_from_y = function(y) return y + sc.offset() + 1 end,
      }
      if geometry_fn and grid_line_offset_fn then
        ctx.cell_from_xy = function(x, y)
          -- last_width stays 0 until the first non-degenerate local render
          -- (wrapper.render's own `w <= 0 or h <= 0` guard, above, skips
          -- setting it) -- guard here too, rather than handing a module's
          -- geometry_fn a width of 0 before any real render has happened.
          if last_width <= 0 then return nil end
          local geom = geometry_fn(last_width)
          if not geom then return nil end
          local line_offset = grid_line_offset_fn(last_width)
          return geom.cell_at(x, y + sc.offset() - line_offset)
        end
      end
      return require("maplib").with_limit(last_image_limit, function()
        return on_pointer_fn(ev, ctx)
      end)
    end
  end

  return wrapper
end

local function open_wrapper(title, lines_fn, on_pointer_fn, on_close_fn, geometry_fn,
                             grid_line_offset_fn, image_limit)
  local wrapper = wrap(lines_fn, on_pointer_fn, geometry_fn, grid_line_offset_fn, image_limit)
  require("wm").popup.open(wrapper, {
    title = title,
    width = 0.9,
    height = 0.9,
    on_close = on_close_fn,
  })
end

-- Opens the named popup, replacing whatever popup (named or not) is
-- currently open; closes it instead if it is already the one showing.
-- Returns false (and prints a friendly message) for a name nothing has
-- registered yet.
function popups.toggle(name)
  local mod = registry[name]
  if not mod then
    buffer.color_print(nil, "DAA520", "Viking: no such popup '" .. tostring(name) .. "'")
    return false
  end

  local wm = require("wm")
  if wm.popup.is_open() and shown_name == name then
    wm.popup.close()
    return true
  end

  open_wrapper(mod.title, mod.lines, mod.on_pointer, function()
    if shown_name == name then shown_name = nil end
    -- Fix round 2, Minor: clear the module's own hover/tooltip state on
    -- close, whatever closed it (a second toggle, Escape, an outside
    -- click, or being replaced) -- see this file's header comment.
    if mod.reset then mod.reset() end
  end, mod.geometry, mod.grid_line_offset, mod.image_limit)
  shown_name = name
  return true
end

-- Wraps any window.PAGES entry's lines in the same scrolling wrapper, with
-- no on_pointer (a pane page has none of its own). Always opens (replacing
-- whatever else is open); `/vik pop <page>` is detached-window parity, not
-- a toggle.
function popups.open_page(page_key)
  local page
  for _, p in ipairs(window.PAGES) do
    if p.key == page_key then page = p end
  end
  if not page then
    buffer.color_print(nil, "DAA520", "Viking: no such page '" .. tostring(page_key) .. "'")
    return false
  end
  if page.popup then
    return popups.toggle(page.popup)
  end

  open_wrapper(page.label, page.mod.lines, nil, function()
    shown_name = nil
  end, nil, nil, page.mod.image_limit)
  return true
end

-- Lightweight diagnostics for a registered popup.  Kept separate from the
-- normal toggle path so a debug command never opens or redraws a window.
function popups.debug(name)
  local mod = registry[name]
  if not mod or not mod.debug then
    buffer.color_print(nil, "DAA520", "Viking: no debug probe for '" .. tostring(name) .. "'")
    return false
  end
  mod.debug()
  return true
end

-- Named-popup content, one require+register line per task (Tasks 3-6),
-- same self-registration pattern window.lua uses for window.PAGES.
popups.register("map", require("popups.map"))
popups.register("sea", require("popups.sea"))
popups.register("voyage", require("popups.voyage"))
popups.register("cityplan", require("popups.cityplan"))
popups.register("war", require("popups.war"))
popups.register("war_saga", require("popups.war_saga"))

return popups
