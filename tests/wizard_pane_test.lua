-- wizard file pane: entries, column layout, scrolling and pointer navigation.
-- Run from the lera-plugins repo root with LERA_ROOT pointing at a built Lera
-- checkout.
--
-- The pane lays entries out in ls-style columns, filled COLUMN-MAJOR (down
-- column 1, then down column 2). Several cases below exist specifically to
-- kill a row-major implementation, which would pass a naive single-column
-- suite unnoticed.
package.path = "3scapes/wizard/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
  if ok then
    print("CASE " .. name .. ": PASS")
  else
    failures = failures + 1
    print("CASE " .. name .. ": FAIL" .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

local offset = 0
package.loaded["wm"] = {
  make_scroller = function(opts)
    local count = opts.count
    -- Clamps exactly as scripts/default/wm.lua does: offset is a DISTANCE FROM
    -- THE TAIL bounded to [0, count-1], and a negative delta (up/older)
    -- increases it. A stub that skipped the clamp would make the pane's
    -- top-anchoring look broken when it is correct.
    local function clamp()
      local max = count() - 1
      if max < 0 then max = 0 end
      if offset > max then offset = max end
      if offset < 0 then offset = 0 end
    end
    return {
      offset = function() clamp(); return offset end,
      scroll = function(d) offset = offset - d; clamp() end,
      scroll_to_bottom = function() offset = 0 end,
      following_tail = function() clamp(); return offset == 0 end,
      on_append = function() end,
      on_trim = function() end,
      count = count,
    }
  end,
}

local drawn = {}
local boxes = {}
ui = {
  dirty = function() end,
  -- Records position as well as text: a column layout is only testable if the
  -- x of each cell is observable. `text` is the STRIPPED string so the layout
  -- cases stay about layout; `raw` keeps the escapes for the colour cases.
  text = function(rect, s) drawn[#drawn + 1] = { x = rect.x, y = rect.y, text = s, raw = s } end,
  text_ansi = function(rect, s)
    drawn[#drawn + 1] = {
      x = rect.x, y = rect.y, raw = s,
      text = (s:gsub("\27%[[%d;]*m", "")),
    }
  end,
  box = function(_, style, title) boxes[#boxes + 1] = { style = style, title = title } end,
  -- Real rects are userdata with method accessors; the stub returns the plain
  -- table form the renderer also has to accept.
  rect = function(x, y, w, h) return { x = x, y = y, w = w, h = h } end,
}
local sent = {}
mud = { send = function(t) sent[#sent + 1] = t end }

local protocol = require("protocol")
local pane = require("pane")

-- The menus are the pane's own overlay now, so they are answered by CLICKING
-- a row rather than by calling a stub's callback: the test drives the same
-- path a user does, hit-testing included.
local overlay = require("overlay")
local actions_reset = require("actions").reset

-- Click the row carrying `label`, in a pane of content size w x h. Returns
-- false when the overlay is closed or has no such row.
local function pick_overlay(label, pane_w, pane_h)
  if not overlay.active() then return false end
  local ow, oh = pane_w - 2, pane_h - 2       -- the border inset render() uses
  local rect = overlay.layout(ow, oh)
  local items = overlay.items()
  for i = 1, rect.rows do
    local it = items[i]
    local l = type(it) == "table" and it.label or tostring(it)
    if l:find(label, 1, true) then
      -- +1 for the pane border, +1 again for the box's own border row.
      return pane.on_pointer({ kind = "down", button = "left",
                               x = rect.x + 1 + 1, y = rect.y + i + 1,
                               inside = true, width = pane_w, height = pane_h })
    end
  end
  return false
end

local triggers = {}
trigger = {
  add = function(pattern, fn) triggers[#triggers + 1] = { pattern = pattern, fn = fn }
                              return #triggers end,
  remove = function() end,
}
gmcp = { on = function() return 1 end, send = function() return true end,
         enabled = function() return true end }

local function drawn_text(x, y)
  for i = 1, #drawn do
    if drawn[i].x == x and drawn[i].y == y then return drawn[i].text end
  end
  return nil
end

local function has_text(s)
  for i = 1, #drawn do if drawn[i].text == s then return true end end
  return false
end

local function drawn_raw(x, y)
  for i = 1, #drawn do
    if drawn[i].x == x and drawn[i].y == y then return drawn[i].raw end
  end
  return nil
end

-- ---- entries ---------------------------------------------------------------

protocol.reset()
protocol.set_available(true)
protocol.set_cwd("/players/simon")
protocol.store("/players/simon", {
  dirs = { "zebra", "archive" },
  files = { "notes.txt", "arena.c" },
  complete = true, truncated = false,
})

do
  local e = pane.entries()
  check("entries: directories first, alphabetical",
        e[1].text == "archive/" and e[2].text == "zebra/",
        e[1] and e[1].text .. "," .. tostring(e[2] and e[2].text))
  check("entries: files follow, alphabetical, unslashed",
        e[3].text == "arena.c" and e[4].text == "notes.txt",
        tostring(e[3] and e[3].text) .. "," .. tostring(e[4] and e[4].text))
  check("entries: directories are flagged", e[1].is_dir == true and e[3].is_dir == false)
  check("entries: name is the bare entry, no slash", e[1].name == "archive")
  check("entries: one per listing entry", #e == 4, #e)
  check("entries: a normal listing has no notice", pane.notice() == nil,
        tostring(pane.notice()))
end

-- ---- notices ---------------------------------------------------------------

protocol.store("/players/simon", {
  dirs = {}, files = { "a" }, complete = true, truncated = true,
})
check("notice: truncation is reported",
      (pane.notice() or ""):find("truncated", 1, true) ~= nil, tostring(pane.notice()))
check("notice: truncation does not become an entry",
      #pane.entries() == 1, #pane.entries())

protocol.store("/players/simon", {
  dirs = {}, files = {}, complete = true, error = "denied",
})
check("notice: an error is reported",
      (pane.notice() or ""):find("denied", 1, true) ~= nil, tostring(pane.notice()))
check("notice: an error yields no entries", #pane.entries() == 0)

protocol.store("/players/simon", { dirs = {}, files = {}, complete = false })
check("notice: an incomplete listing says loading",
      (pane.notice() or ""):find("loading", 1, true) ~= nil, tostring(pane.notice()))

protocol.reset()
check("notice: unavailable Files.List is explained rather than blank",
      (pane.notice() or ""):find("wizard", 1, true) ~= nil, tostring(pane.notice()))
check("notice: unavailable yields no entries", #pane.entries() == 0)

-- ---- column layout ---------------------------------------------------------
--
-- Fixture, sorted: archive/(8) areas/(6) mmm/(4) zebra/(6) arena.c(7)
-- notes.txt(9). Longest is 9, so cell width is 9 + 2 gutter = 11.
-- A pane of w=30 insets to 28 content columns: floor((28+2)/11) = 2 columns,
-- and ceil(6/2) = 3 grid rows.
--   column 0 (x=1)  : archive/  areas/  mmm/
--   column 1 (x=12) : zebra/    arena.c notes.txt

protocol.reset()
protocol.set_available(true)
protocol.set_cwd("/players/simon")
protocol.store("/players/simon", {
  dirs = { "zebra", "archive", "mmm", "areas" },
  files = { "notes.txt", "arena.c" },
  complete = true, truncated = false,
})

drawn = {}
pane.render({ x = 0, y = 0, w = 30, h = 10 }, { title = "Files" })
-- Six cells plus the two action buttons, which occupy content row 0. Every
-- grid row below is therefore one lower than the content origin.
-- Six cells, plus four toolbar buttons: [..] [~] [uall] [lall].
check("layout: six entries draw six cells, under the button row", #drawn == 10, #drawn)
check("layout: column 0 starts at the content x", drawn_text(1, 2) == "archive/",
      tostring(drawn_text(1, 2)))
check("layout: column 1 is one cell width across", drawn_text(12, 2) == "zebra/",
      tostring(drawn_text(12, 2)))
check("layout: column-major fills DOWN column 0 first",
      drawn_text(1, 3) == "areas/" and drawn_text(1, 4) == "mmm/",
      "row-major would put zebra/ at (1,3); got "
        .. tostring(drawn_text(1, 3)))
check("layout: column 1 continues the sequence",
      drawn_text(12, 3) == "arena.c" and drawn_text(12, 4) == "notes.txt",
      tostring(drawn_text(12, 3)))

-- ---- colours ---------------------------------------------------------------
--
-- Type before name, the way a shell's ls reads. The mapping itself is asserted
-- against theme directly; these two cases prove the pane actually applies it.

do
  local theme = require("theme")
  check("colour: a directory is painted, and its escape wraps the whole cell",
        drawn_raw(1, 2) == theme.DIR .. "archive/" .. theme.RESET,
        tostring(drawn_raw(1, 2)))
  check("colour: a .c file takes the source colour",
        drawn_raw(12, 3) == theme.SOURCE .. "arena.c" .. theme.RESET,
        tostring(drawn_raw(12, 3)))

  check("theme: .h is the header colour, distinct from .c",
        theme.color({ name = "path.h" }) == theme.HEADER and theme.HEADER ~= theme.SOURCE)
  check("theme: .o recedes as data",
        theme.color({ name = "gather_daemon.o" }) == theme.DATA)
  check("theme: a script is runnable-green",
        theme.color({ name = "rebuild_help.ps1" }) == theme.SCRIPT)
  check("theme: a doc is plain white",
        theme.color({ name = "NOTES.md" }) == theme.DOC)
  check("theme: an unknown extension is left at the terminal default",
        theme.color({ name = "core.dump" }) == theme.PLAIN)
  check("theme: no extension at all is left alone",
        theme.color({ name = "Makefile" }) == theme.PLAIN)
  check("theme: a directory wins over whatever its name looks like",
        theme.color({ name = "include.h", is_dir = true }) == theme.DIR,
        "a directory called include.h is still a directory")

  -- Backups are a SUFFIX convention here as often as an extension, so all
  -- three shapes this tree actually uses must land on the backup colour.
  check("theme: foo.c.bak is a backup, not a source file",
        theme.color({ name = "shgather.c.bak" }) == theme.BACKUP)
  check("theme: an editor tilde file is a backup",
        theme.color({ name = "threshold.c~" }) == theme.BACKUP)
  check("theme: the .before-<date> convention is a backup",
        theme.color({ name = "deadmans.lua.before-user-activity-20260907" }) == theme.BACKUP)

  check("theme: paint is a no-op for the default colour, costing no escapes",
        theme.paint("plain", theme.PLAIN) == "plain")
end

-- ---- the button row --------------------------------------------------------

check("buttons: navigation comes first on the toolbar row",
      drawn_text(1, 1) == "[..]" and drawn_text(7, 1) == "[~]",
      tostring(drawn_text(1, 1)) .. "," .. tostring(drawn_text(7, 1)))
check("buttons: then the directory actions",
      drawn_text(12, 1) == "[uall]" and drawn_text(20, 1) == "[lall]",
      tostring(drawn_text(12, 1)) .. "," .. tostring(drawn_text(20, 1)))
do
  local theme = require("theme")
  -- Dim brackets, coloured word: blue for the buttons that move you, white
  -- for the ones that act. The toolbar is permanent furniture, so it recedes.
  check("buttons: navigation and actions are coloured apart",
        drawn_raw(1, 1):find(theme.NAV, 1, true) ~= nil and
        drawn_raw(12, 1):find(theme.BUTTON, 1, true) ~= nil and
        theme.NAV ~= theme.BUTTON,
        "moving somewhere and recompiling something must not look alike")
  check("buttons: the brackets recede",
        drawn_raw(1, 1):find(theme.BRACKET, 1, true) == 1,
        tostring(drawn_raw(1, 1)))
end

-- ---- navigating up and home ------------------------------------------------

sent = {}
pane.on_pointer({ kind = "down", button = "left", x = 1, y = 1,
                  inside = true, width = 30, height = 10 })
check("nav: [..] cds to the parent, absolute",
      #sent == 1 and sent[1] == "cd /players", tostring(sent[1]))

sent = {}
pane.on_pointer({ kind = "down", button = "left", x = 7, y = 1,
                  inside = true, width = 30, height = 10 })
-- A BARE cd: wiz.h's cd defaults its argument to "~", so this is the MUD's
-- own way home, and it works before Files.List has told the pane where home
-- is.
check("nav: [~] sends a bare cd",
      #sent == 1 and sent[1] == "cd", tostring(sent[1]))


sent = {}
local consumed_btn = pane.on_pointer({ kind = "down", button = "left", x = 12, y = 1,
                                       inside = true, width = 30, height = 10 })
check("buttons: clicking uall asks before sending anything",
      consumed_btn == true and #sent == 0 and overlay.active(), tostring(sent[1]))
check("buttons: the box names the command and the directory",
      (overlay.title() or ""):find("uall", 1, true) ~= nil and
      (overlay.title() or ""):find("simon", 1, true) ~= nil, tostring(overlay.title()))

-- "this directory and everything in it" has to be reachable for the directory
-- you are STANDING IN, not only for a folder listed below.
check("buttons: the toolbar offers flat or recursive, plus a way out",
      #overlay.items() == 3 and overlay.items()[1].value == "uall" and
      overlay.items()[2].value == "uall -r" and overlay.items()[3].value == "",
      overlay.items()[2].value)

pick_overlay("uall", 30, 10)
check("buttons: choosing still asks before sending", #sent == 0 and overlay.active())
check("buttons: no is the row nearest the pointer",
      overlay.items()[1].label == "no", tostring(overlay.items()[1].label))

pick_overlay("no", 30, 10)
check("buttons: answering No sends nothing and closes the box",
      #sent == 0 and not overlay.active(), tostring(sent[1]))

pane.on_pointer({ kind = "down", button = "left", x = 12, y = 1,
                  inside = true, width = 30, height = 10 })
pick_overlay("uall", 30, 10)
pick_overlay("yes", 30, 10)
check("buttons: answering Yes runs it against the cwd",
      #sent == 1 and sent[1] == "uall /players/simon", tostring(sent[1]))

-- The recursive path from the toolbar: cwd first, then everything under it.
sent = {}
pane.on_pointer({ kind = "down", button = "left", x = 12, y = 1,
                  inside = true, width = 30, height = 10 })
pick_overlay("uall -r", 30, 10)
pick_overlay("yes", 30, 10)
check("buttons: the recursive choice walks from the cwd",
      #sent >= 1 and sent[1] == "uall /players/simon", tostring(sent[1]))
-- The cwd holds four folders, so a recursive run is the cwd plus those four.
-- Their own listings are not cached, so the walk stops there rather than
-- inventing depth it has not been told about.
check("buttons: and reaches every folder listed in it",
      #sent == 5 and sent[1] == "uall /players/simon", table.concat(sent, " | "))
do
  local joined = table.concat(sent, " | ")
  check("buttons: including the one clicked on elsewhere in these cases",
        joined:find("uall /players/simon/archive", 1, true) ~= nil, joined)
end

-- A walk still waiting on listings must not block the next one.
actions_reset()

-- Kills a button row that is drawn but hit-tested at the old offset: a click
-- on the gap between the labels must not fire the nearest one.
sent = {}
pane.on_pointer({ kind = "down", button = "left", x = 11, y = 1,
                  inside = true, width = 30, height = 10 })
check("buttons: the gap between labels is not a button",
      not overlay.active() and #sent == 0)

-- ---- pointer over columns --------------------------------------------------

sent = {}
local consumed = pane.on_pointer({ kind = "down", button = "left", x = 1, y = 2,
                                   inside = true, width = 30, height = 10 })
check("pointer: a click in column 0 navigates", #sent == 1 and sent[1] == "cd archive",
      tostring(sent[1]))
check("pointer: a consumed down returns literal true", consumed == true)

sent = {}
pane.on_pointer({ kind = "down", button = "left", x = 12, y = 2,
                  inside = true, width = 30, height = 10 })
check("pointer: a click in column 1 resolves COLUMN-MAJOR",
      #sent == 1 and sent[1] == "cd zebra",
      "row-major would resolve areas/ here; got " .. tostring(sent[1]))

sent = {}
pane.on_pointer({ kind = "down", button = "left", x = 1, y = 4,
                  inside = true, width = 30, height = 10 })
check("pointer: the third row of column 0 is the third entry",
      #sent == 1 and sent[1] == "cd mmm", tostring(sent[1]))

-- ---- clicking a file -------------------------------------------------------

-- Left-click opens it, the way left-click on a folder enters it.
sent = {}
consumed = pane.on_pointer({ kind = "down", button = "left", x = 12, y = 3,
                             inside = true, width = 30, height = 10 })
check("file: a left-click views it outright",
      consumed == true and sent[1] == "more /players/simon/arena.c" and not overlay.active(),
      tostring(sent[1]))

-- Right-click is where the rest lives, including the one that destructs a
-- live object.
-- Height 16: the menu is nine rows plus a border, and a pane that cannot show
-- it all is its own case below.
local MENU_H = 16
sent = {}
consumed = pane.on_pointer({ kind = "down", button = "right", x = 12, y = 3,
                             inside = true, width = 30, height = MENU_H })
check("file: a right-click offers the menu instead",
      consumed == true and #sent == 0 and overlay.active(), tostring(sent[1]))
check("file: the menu is titled with the file, not the whole path",
      overlay.title() == "arena.c", tostring(overlay.title()))
-- Everything the MUD offers on one file, each a real wizard command.
do
  local want = { view = true, cat = true, head = true, cc = true, ed = true,
                 ul = true, update = true, load = true, rm = true }
  local got, missing = {}, {}
  for _, it in ipairs(overlay.items()) do got[it.value] = true end
  for k in pairs(want) do if not got[k] then missing[#missing + 1] = k end end
  check("file: the menu offers the whole file command set",
        #missing == 0 and #overlay.items() == 10,   -- nine commands + (cancel)
        #overlay.items() .. " items, missing: " .. table.concat(missing, ","))
end

-- The two columns are the point of the layout: every command starts at the
-- same x and so does every explanation, or the menu reads as a wall.
do
  local rect = overlay.layout(28, MENU_H - 2)
  local label_w = 0
  for _, it in ipairs(overlay.items()) do
    if #it.label > label_w then label_w = #it.label end
  end
  check("file: the explanation column clears the longest command",
        rect.desc_x >= label_w + 1, rect.desc_x .. " vs " .. label_w)
  check("file: every entry carries an explanation", (function()
    for _, it in ipairs(overlay.items()) do
      if type(it.desc) ~= "string" or it.desc == "" then return false end
    end
    return true
  end)())
end

-- rm is the row that deletes something, and it is coloured as such rather
-- than sitting in the same white as `load`.
do
  local rm_kind, cancel_kind
  for _, it in ipairs(overlay.items()) do
    if it.value == "rm" then rm_kind = it.kind end
    if it.value == "" then cancel_kind = it.kind end
  end
  check("file: rm is marked dangerous", rm_kind == "danger", tostring(rm_kind))
  check("file: cancel is marked as the way out", cancel_kind == "cancel",
        tostring(cancel_kind))
end

-- A menu longer than the pane must SAY so rather than hiding its tail, which
-- is where rm sits.
do
  local shown = 0
  drawn = {}
  pane.render({ x = 0, y = 0, w = 30, h = 8 }, {})
  for _, d in ipairs(drawn) do if (d.text or ""):find("more (taller pane)", 1, true) then shown = shown + 1 end end
  check("file: an overlong menu shows a +N more marker", shown == 1, shown)
end

-- The box opens AT the click, which is the whole point of drawing it here
-- rather than above the input bar.
do
  local rect = overlay.layout(28, MENU_H - 2)
  check("file: the box opens at the click, not at a fixed corner",
        rect.x <= 11 and rect.x + rect.w >= 11,
        "clicked column 11; box spans " .. rect.x .. ".." .. (rect.x + rect.w))
end

pick_overlay("view", 30, MENU_H)
check("file: view pages the file, absolute",
      #sent == 1 and sent[1] == "more /players/simon/arena.c", tostring(sent[1]))
check("file: choosing closes the box", not overlay.active())

sent = {}
pane.on_pointer({ kind = "down", button = "right", x = 12, y = 3,
                  inside = true, width = 30, height = MENU_H })
pick_overlay("ul", 30, MENU_H)
check("file: ul updates and loads that one file",
      #sent == 1 and sent[1] == "ul /players/simon/arena.c", tostring(sent[1]))

-- rm deletes with no confirmation of its own (cmds/secure/rm.c), so the menu
-- must not be the last word on it.
sent = {}
pane.on_pointer({ kind = "down", button = "right", x = 12, y = 3,
                  inside = true, width = 30, height = MENU_H })
pick_overlay("rm", 30, MENU_H)
check("file: rm asks before deleting anything",
      #sent == 0 and overlay.active(), tostring(sent[1]))
pick_overlay("no", 30, MENU_H)
check("file: answering No deletes nothing", #sent == 0, tostring(sent[1]))

pane.on_pointer({ kind = "down", button = "right", x = 12, y = 3,
                  inside = true, width = 30, height = MENU_H })
pick_overlay("rm", 30, MENU_H)
pick_overlay("yes", 30, MENU_H)
check("file: confirming rm sends it, absolute",
      #sent == 1 and sent[1] == "rm /players/simon/arena.c", tostring(sent[1]))

-- A click outside the box dismisses it and does NOT fall through to whatever
-- entry is underneath.
sent = {}
pane.on_pointer({ kind = "down", button = "right", x = 12, y = 3,
                  inside = true, width = 30, height = MENU_H })
-- The menu is as wide as the pane and opens under the clicked row, so the
-- pane outside it is the rows ABOVE. y=1 is the first content row.
local dismissed = pane.on_pointer({ kind = "down", button = "left", x = 1, y = 1,
                                    inside = true, width = 30, height = MENU_H })
check("file: clicking away closes the menu and navigates nowhere",
      dismissed == true and not overlay.active() and #sent == 0, tostring(sent[1]))

-- A pointer callback runs OUTSIDE the plugin's capability (wm invokes it
-- directly), where require() raises "plugin capability is inactive". This is
-- the case that catches a lazy require creeping back into a click path: the
-- stubs above would otherwise let one pass unnoticed.
do
  local real_require = require
  require = function(name)
    error("a pointer callback must not require('" .. tostring(name) .. "') -- "
          .. "capture the module at load instead")
  end
  local ok, err = pcall(pane.on_pointer, { kind = "down", button = "right", x = 12, y = 3,
                                           inside = true, width = 30, height = MENU_H })
  require = real_require
  check("click: a file click requires no module at callback time", ok, tostring(err))
  check("click: and still opened its menu", overlay.active(), "no menu opened")
  overlay.close()
end

-- ---- right-clicking a directory --------------------------------------------

sent = {}
pane.on_pointer({ kind = "down", button = "right", x = 1, y = 2,
                  inside = true, width = 30, height = 10 })
check("dir: right-click offers the directory actions, flat and recursive",
      overlay.active() and #overlay.items() == 5 and #sent == 0,   -- four + (cancel)
      tostring(sent[1]))
check("dir: the box names the clicked folder",
      overlay.title() == "archive", tostring(overlay.title()))
check("dir: each command is offered with and without subfolders",
      overlay.items()[1].value == "uall" and overlay.items()[2].value == "uall -r" and
      overlay.items()[3].value == "lall" and overlay.items()[4].value == "lall -r",
      overlay.items()[2].value)

pick_overlay("lall -r", 30, 10)
check("dir: choosing one still asks before sending", #sent == 0, tostring(sent[1]))
check("dir: and the question replaces it in the same place", overlay.active())
pick_overlay("yes", 30, 10)
check("dir: confirming a recursive run walks from that folder",
      #sent >= 1 and sent[1] == "lall /players/simon/archive", tostring(sent[1]))

sent = {}
pane.on_pointer({ kind = "down", button = "right", x = 1, y = 2,
                  inside = true, width = 30, height = 10 })
pick_overlay("lall", 30, 10)
pick_overlay("yes", 30, 10)
check("dir: the flat variant sends exactly one command",
      #sent == 1 and sent[1] == "lall /players/simon/archive", tostring(sent[1]))

sent = {}
pane.on_pointer({ kind = "down", button = "left", x = 1, y = 0,
                  inside = true, width = 30, height = 10 })
check("pointer: a click on the top border does not navigate", #sent == 0)

sent = {}
menus = {}
pane.on_pointer({ kind = "down", button = "left", x = 0, y = 2,
                  inside = true, width = 30, height = 10 })
check("pointer: a click on the left border does not navigate",
      #sent == 0 and not overlay.active(), "x=0 is the border column, not content")

sent = {}
pane.on_pointer({ kind = "down", button = "left", x = 1, y = 40,
                  inside = true, width = 30, height = 10 })
check("pointer: a click past the last row sends nothing", #sent == 0)

sent = {}
menus = {}
pane.on_pointer({ kind = "move", button = "left", x = 1, y = 2,
                  inside = true, width = 30, height = 10 })
check("pointer: only a down acts", #sent == 0 and not overlay.active())

sent = {}
menus = {}
pane.on_pointer({ kind = "down", button = "middle", x = 1, y = 2,
                  inside = true, width = 30, height = 10 })
check("pointer: the middle button does nothing", #sent == 0 and not overlay.active())

sent = {}
menus = {}
pane.on_pointer({ kind = "down", button = "right", x = 1, y = 1,
                  inside = true, width = 30, height = 10 })
check("pointer: the buttons take LEFT clicks only", #sent == 0 and not overlay.active(),
      "a right-click on the toolbar must not confirm anything")

-- An empty cell: column 1 of a 5-entry grid has a hole at its last row.
protocol.store("/players/simon", {
  dirs = { "archive", "areas", "mmm" }, files = { "notes.txt", "arena.c" },
  complete = true, truncated = false,
})
-- sorted: archive/ areas/ mmm/ arena.c notes.txt -> 5 entries, cols 2, rows 3
-- column 0: archive/ areas/ mmm/   column 1: arena.c notes.txt (row 3 empty)
sent = {}
menus = {}
pane.on_pointer({ kind = "down", button = "left", x = 12, y = 4,
                  inside = true, width = 30, height = 10 })
check("pointer: a click on an empty grid cell does nothing",
      #sent == 0 and not overlay.active(), tostring(sent[1]))

-- ---- narrow pane -----------------------------------------------------------

protocol.store("/players/simon", {
  dirs = { "archive" }, files = { "verylongfilename.c" },
  complete = true, truncated = false,
})
drawn = {}
pane.render({ x = 0, y = 0, w = 10, h = 10 })
check("narrow: a pane too small for two columns falls back to one",
      drawn_text(1, 2) == "archive/" and drawn_text(1, 3) ~= nil,
      "entries must stack, not sit side by side")
check("narrow: an over-long name is truncated to the content width",
      #(drawn_text(1, 3) or "") <= 8,
      "content width is 8; got " .. tostring(drawn_text(1, 3)))

-- ---- scrolling and top anchoring -------------------------------------------
--
-- Six single-column entries in a pane with two GRID rows. h=5 insets to 3
-- content rows, one of which the button row takes -- so the scrolling maths
-- below is unchanged from before the toolbar existed, which is the point: the
-- scroller counts CONTENT rows and knows nothing about the buttons.
--
-- The content is 6 columns wide, so only the first toolbar button fits. A
-- button that would be drawn off the edge is not drawn at all.

protocol.store("/players/simon", {
  dirs = { "d1", "d2", "d3", "d4", "d5", "d6" }, files = {},
  complete = true, truncated = false,
})
offset = 0
drawn = {}
pane.render({ x = 0, y = 0, w = 8, h = 5 })
check("scroll: a fresh listing opens at the TOP, not the tail",
      has_text("d1/") and has_text("d2/"),
      "tail-anchored would show d5/,d6/")
check("scroll: only the visible rows are drawn, plus the one button that fits",
      #drawn == 3, #drawn)
-- Content is 6 columns: "[..]" fits, and everything after it (from "[~]" at
-- column 6) does not.
check("buttons: a label too wide for the pane is dropped, not truncated",
      has_text("[..]") and not has_text("[~]") and not has_text("[uall]"))

pane.scroll_to_bottom()
drawn = {}
pane.render({ x = 0, y = 0, w = 8, h = 5 })
check("scroll: scroll_to_bottom shows the last entries",
      has_text("d5/") and has_text("d6/"),
      "got " .. tostring(drawn[2] and drawn[2].text))

sent = {}
pane.on_pointer({ kind = "down", button = "left", x = 1, y = 2,
                  inside = true, width = 8, height = 5 })
check("scroll: a click follows the scrolled view",
      #sent == 1 and sent[1] == "cd d5", tostring(sent[1]))

pane.scroll(-1)
drawn = {}
pane.render({ x = 0, y = 0, w = 8, h = 5 })
check("scroll: scrolling up one row moves the view up one entry",
      has_text("d4/") and has_text("d5/"),
      "got " .. tostring(drawn[2] and drawn[2].text))

check("scroll: following_tail is false once scrolled back",
      pane.following_tail() == false)

-- ---- border ----------------------------------------------------------------

boxes = {}
pane.render({ x = 0, y = 0, w = 30, h = 10 }, { title = "Files /players/simon" })
check("render: the pane boxes itself with the title wm passed",
      #boxes == 1 and boxes[1].title == "Files /players/simon",
      boxes[1] and tostring(boxes[1].title))

boxes = {}
pane.render({ x = 0, y = 0, w = 30, h = 10 })
check("render: a missing opts table still renders", #boxes == 1)

boxes = {}
drawn = {}
pane.render({ x = 0, y = 0, w = 30, h = 10 }, { show_border = false })
check("render: show_border=false draws no box", #boxes == 0)
check("render: unbordered content starts at x=0",
      drawn_text(0, 0) ~= nil,
      "without a border there is no inset; got "
        .. tostring(drawn[1] and drawn[1].x) .. "," .. tostring(drawn[1] and drawn[1].y))

-- ---- notice rendering ------------------------------------------------------

protocol.store("/players/simon", {
  dirs = { "archive" }, files = {}, complete = true, truncated = true,
})
drawn = {}
pane.render({ x = 0, y = 0, w = 30, h = 10 }, { title = "Files" })
check("render: the notice draws below the grid, full width",
      has_text("archive/") and (drawn[#drawn].text or ""):find("truncated", 1, true) ~= nil,
      tostring(drawn[#drawn] and drawn[#drawn].text))

protocol.reset()
drawn = {}
pane.render({ x = 0, y = 0, w = 30, h = 10 }, { title = "Files" })
check("render: an unavailable pane draws only its notice",
      #drawn == 1 and (drawn[1].text or ""):find("wizard", 1, true) ~= nil,
      tostring(drawn[1] and drawn[1].text))

-- ---- entry names are literal, and home may be unknown ----------------------
--
-- Home arrives with the seed response, so every click before it lands has
-- home = nil. A name beginning with "~" must still resolve: it is a file
-- name, not the wizard's home directory.

protocol.reset()
protocol.set_available(true)
protocol.set_cwd("/players/simon")
protocol.store("/players/simon", {
  dirs = {}, files = { "~literal.c" }, complete = true,
})
sent = {}
pane.render({ x = 0, y = 0, w = 30, h = 10 })
pane.on_pointer({ kind = "down", button = "left", x = 1, y = 2,
                  inside = true, width = 30, height = 10 })
pick_overlay("view", 30, 10)
check("entry: a leading ~ is part of the name, not home",
      #sent == 1 and sent[1] == "more /players/simon/~literal.c",
      tostring(sent[1]))

print(failures == 0 and "ALL PASS" or (failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
