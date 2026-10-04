-- Colours for the file pane, in the spirit of a shell's `ls`: the type of a
-- thing should be readable before you have read its name.
--
-- The palette is the plain SGR 3x/9x family the rest of this client uses -- no
-- 256-colour or truecolour, so it survives whatever terminal a wizard is on.
--
-- The grouping is chosen for a MUDLIB tree rather than a generic filesystem,
-- which is where it departs from LS_COLORS:
--
--   directory   bright blue   what `ls` has always used, and the only entry
--                             that is also clickable to navigate
--   .c          bright cyan   the file you are actually here to edit
--   .h          cyan          the same family, one step down: included, not
--                             loaded as an object of its own
--   .o          dim           save files and compiled data. In a mudlib these
--                             outnumber the source in many directories and
--                             are almost never what you are looking for, so
--                             they recede instead of competing
--   scripts     bright green  .sh/.ps1/.py -- `ls` colours what you can run
--                             green, and these are the runnable things here
--   docs        white         .txt/.md/.doc and friends: read, not compiled
--   backups     red           .bak/.orig/~ and the .before-<date> convention
--                             this tree uses. Stale by definition; worth
--                             seeing at a glance so a directory full of them
--                             is obvious
--   anything else             terminal default
--
-- Nothing here parses file CONTENT: extension only, which is all a listing
-- gives us.

local M = {}

M.RESET = "\27[0m"

M.DIR     = "\27[94m"   -- bright blue
M.SOURCE  = "\27[96m"   -- bright cyan
M.HEADER  = "\27[36m"   -- cyan
M.DATA    = "\27[90m"   -- dim
M.SCRIPT  = "\27[92m"   -- bright green
M.DOC     = "\27[37m"   -- white
M.BACKUP  = "\27[31m"   -- red
M.PLAIN   = ""          -- terminal default

-- Chrome, kept here so the pane has one palette rather than two.
--
-- Toned down deliberately: the toolbar is always on screen and never the
-- thing you came to read. Its brackets recede to dim and only the word keeps
-- a colour -- blue for the two that MOVE you, plain white for the two that DO
-- something, matching the menu's own command colour. Bright yellow made a
-- permanent row shout over the listing it sits above.
M.BRACKET = "\27[90m"   -- dim: the [ ] around a button
M.BUTTON  = "\27[37m"   -- white: an action button's word
-- Bright blue, not plain: SGR 34 on a dark terminal is near-invisible, which
-- is a poor showing for the two buttons that move you around. The toning-down
-- is carried by the dim brackets either side, not by dimming the word itself.
M.NAV     = "\27[94m"   -- bright blue: a navigation button's word
M.NOTICE  = "\27[90m"   -- dim
M.BUSY    = "\27[93m"   -- bright yellow: a ferry command is running

-- Menu rows are two columns: the command, then what it does. The command is
-- what you aim at, so it keeps the strong colour; the explanation is there to
-- be read once and then ignored, so it recedes. All-yellow rows made the two
-- compete and the menu read as a wall.
M.MENU_CMD    = "\27[97m"   -- bright white: the word that gets sent
M.MENU_DESC   = "\27[90m"   -- dim: what it does
M.MENU_DANGER = "\27[91m"   -- bright red: it deletes something
M.MENU_CANCEL = "\27[90m"   -- dim: the way out

local BY_EXT = {
  c = M.SOURCE,
  h = M.HEADER,
  o = M.DATA,
  db = M.DATA,
  json = M.DATA,
  state = M.DATA,
  sh = M.SCRIPT,
  ps1 = M.SCRIPT,
  py = M.SCRIPT,
  lua = M.SCRIPT,
  txt = M.DOC,
  md = M.DOC,
  doc = M.DOC,
  readme = M.DOC,
  bak = M.BACKUP,
  orig = M.BACKUP,
  old = M.BACKUP,
  rej = M.BACKUP,
}

-- A backup is as often a SUFFIX as an extension in this tree: `foo.c.bak`,
-- `lera.png.before-transparent-20260908`, an editor's `foo.c~`. Extension
-- matching alone would colour the first as a backup, the second as nothing,
-- and the third as nothing.
local function is_backup(name)
  if name:sub(-1) == "~" then return true end
  if name:find("%.before%-") then return true end
  if name:find("%.bak%f[%W]") then return true end
  return false
end

-- The colour for one entry of the pane's model ({ name = ..., is_dir = ... }).
function M.color(entry)
  if not entry then return M.PLAIN end
  if entry.is_dir then return M.DIR end

  local name = entry.name or ""
  if is_backup(name) then return M.BACKUP end

  -- Longest-suffix first is wrong here: an extension is the text after the
  -- LAST dot, so `gather_daemon.o` is data and `notes.txt.bak` is a backup
  -- (caught above before we get here).
  local ext = name:match("%.([%w_]+)$")
  if not ext then return M.PLAIN end
  return BY_EXT[ext:lower()] or M.PLAIN
end

-- Wrap text in a colour, resetting after. A no-op for M.PLAIN so an ordinary
-- file costs no escapes at all.
function M.paint(text, color)
  if not color or color == "" then return text end
  return color .. text .. M.RESET
end

return M
