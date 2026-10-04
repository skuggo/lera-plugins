-- Chat Monitor Plugin for Lera
-- Captures chat events (tells, emotes, chat lines) and displays them in a
-- separate panel with color coding and gag support.
--
-- Two protocols can carry channel lines. MIP CAA is the historical source;
-- GMCP Comm.Channel.Text is preferred when the server proves it is sending it,
-- because 3K sends the same line over both and printing both would double
-- every message. See the "Source selection" section below.

local M = {}
local companion_epoch = 1
M.name = "chat_monitor"
M.version = "1.3"
M.priority = 50  -- Run before most plugins

local wm = require("wm")
-- URL detection/highlighting, inlined from Lera core's
-- scripts/default/url_links.lua (which wm.lua uses for the window manager's
-- own links). It cannot be required here: the plugin sandbox resolves
-- require() to "command", "wm" and "menu" only, and sends every other name
-- into the plugin's own directory (src/script/plugin.c:520-535) -- core
-- modules are deliberately unreachable. A single-file plugin has no such
-- directory (root_off == 0), so require("url_links") raised "plugin module is
-- not allowed" and took chat_monitor down at load.
--
-- Kept byte-identical to core's implementation apart from the local name, so
-- the two can be diffed. If core's copy changes, re-sync this one.
local url_links = {}

-- Lera's cell renderer uses one cell per UTF-8 codepoint (not wcwidth).
-- Keep raw byte positions as well, for consumers with word-wrapped rows.
function url_links.cells(text)
  local cells, plain, map, i, col = {}, {}, {}, 1, 0
  while i <= #text do
    local escape = text:byte(i) == 27 and text:sub(i):match("^\27%[[0-9;]*.")
    if escape then
      i = i + #escape
    else
      local b = text:byte(i)
      local n = 1
      if b >= 194 and b <= 244 then
        local candidate = b < 224 and 2 or (b < 240 and 3 or 4)
        local valid = i + candidate - 1 <= #text
        for j = 1, candidate - 1 do
          local c = text:byte(i+j) or 0
          valid = valid and c >= 128 and c <= 191
        end
        local second = text:byte(i+1) or 0
        if b == 224 then valid = valid and second >= 160 end
        if b == 237 then valid = valid and second <= 159 end
        if b == 240 then valid = valid and second >= 144 end
        if b == 244 then valid = valid and second <= 143 end
        if valid then n = candidate end
      end
      local cell = { first = i, last = i+n-1, col = col }
      -- Controls delimit candidates but occupy no rendered cells.
      plain[#plain+1] = text:sub(i, i+n-1)
      for j = 1, n do map[#map+1] = cell end
      if b >= 32 and b ~= 127 then
        cells[#cells+1] = cell
        col = col + 1
      end
      i = i + n
    end
  end
  return cells, table.concat(plain), map
end

function url_links.find(text)
  local _, plain, map = url_links.cells(text)
  local lower, links, pos = plain:lower(), {}, 1
  while pos <= #plain do
    local start
    for _, prefix in ipairs({"http://", "https://", "www."}) do
      local at = lower:find(prefix, pos, true)
      if at and (not start or at < start) then start = at end
    end
    if not start then break end
    local finish = start
    while finish <= #plain and not plain:sub(finish, finish):match('[%s<>"\'`]') do
      finish = finish + 1
    end
    local value = plain:sub(start, finish-1)
    local prev = plain:sub(start-1, start-1)
    local valid = start == 1 or not prev:match('[%w_/@.:%-]')
    valid = valid and not value:find('[%c\\]')
    -- Sentence punctuation is not part of a URL; balanced path brackets are.
    while #value > 0 do
      local last = value:sub(-1)
      local opener = ({ [")"] = "(", ["]"] = "[", ["}"] = "{" })[last]
      local trim = last:match('[.,;:!?]') ~= nil
      if opener then
        local opens, closes = 0, 0
        for c in value:gmatch('.') do
          if c == opener then opens = opens + 1 end
          if c == last then closes = closes + 1 end
        end
        trim = closes > opens
      end
      if not trim then break end
      value = value:sub(1, -2)
    end
    local normalized = value:lower():sub(1,4) == 'www.' and ('https://' .. value) or value
    local host = normalized:match('^[Hh][Tt][Tt][Pp][Ss]?://([^/?#]+)')
    valid = valid and host and host ~= '' and not host:find('@', 1, true)
    if value:lower():sub(1,4) == 'www.' then
      valid = valid and #host > 4 and host:sub(-1) ~= '.'
    end
    if valid then
      local a, b = map[start], map[start+#value-1]
      links[#links+1] = {kind='url', value=normalized, col_start=a.col,
        col_end=b.col+1, byte_start=a.first, byte_end=b.last}
    end
    pos = math.max(start+1, finish)
  end
  return links
end
-- Match api_ui.c's SGR style semantics, including its all-style reset for
-- selective style-off codes. Extended colour operands are not style codes.
local style_bits = { [1]=1, [2]=2, [3]=4, [4]=8, [5]=16, [7]=32 }
local function sgr_styles(params, styles)
  local codes = {}
  if params == '' then codes[1] = 0 end
  local pos = 1
  while pos <= #params do
    local stop = params:find(';', pos, true) or (#params+1)
    codes[#codes+1] = tonumber(params:sub(pos, stop-1)) or 0
    pos = stop+1
  end
  local i = 1
  while i <= #codes do
    local code = codes[i]
    if code == 0 or code == 22 or code == 23 or code == 24 or code == 25 or code == 27 then
      styles = {}
    elseif style_bits[code] then
      styles[code] = true
    elseif code == 38 or code == 48 then
      local mode = codes[i+1]
      i = i + (mode == 2 and 4 or (mode == 5 and 2 or 1))
    end
    i = i + 1
  end
  return styles
end

-- Spans use visible cell columns, so callers can reuse wrapped click metadata.
-- Never replay source escapes: only underline and style restoration are added.
function url_links.highlight(text, state, spans, excluded)
  spans = spans or url_links.find(text)
  local ranges = {}
  for _, span in ipairs(spans) do
    local overlap = false
    for _, anchor in ipairs(excluded or {}) do
      if span.col_start < anchor.col_end and span.col_end > anchor.col_start then
        overlap = true
        break
      end
    end
    if not overlap then ranges[#ranges+1] = span end
  end
  if #ranges == 0 then return text end
  local styles = {}
  for code, bit in pairs(style_bits) do
    if math.floor(((state and state.style) or 0) / bit) % 2 == 1 then styles[code] = true end
  end
  local actual = {}
  for code in pairs(styles) do actual[code] = true end
  local out, cursor, range = {}, 1, 1
  local function restore()
    out[#out+1] = '\27[24m'
    for _, code in ipairs({1,2,3,4,5,7}) do
      if styles[code] then out[#out+1] = '\27[' .. code .. 'm' end
    end
    actual = {}
    for code in pairs(styles) do actual[code] = true end
  end
  local function escapes(fragment)
    out[#out+1] = fragment
    for params in fragment:gmatch('\27%[([0-9;]*)m') do
      styles = sgr_styles(params, styles)
      actual = sgr_styles(params, actual)
    end
  end
  for _, cell in ipairs(url_links.cells(text)) do
    escapes(text:sub(cursor, cell.first-1))
    while ranges[range] and ranges[range].col_end <= cell.col do range = range + 1 end
    local span = ranges[range]
    local linked = span and cell.col >= span.col_start and cell.col < span.col_end
    if linked then
      if not actual[4] then out[#out+1] = '\27[4m'; actual[4] = true end
    elseif actual[4] and not styles[4] then
      restore()
    end
    out[#out+1] = text:sub(cell.first, cell.last)
    cursor = cell.last+1
  end
  if actual[4] and not styles[4] then restore() end
  out[#out+1] = text:sub(cursor)
  return table.concat(out)
end

-- Configuration
local config = {
  max_lines = 32768,      -- Max lines to keep in scrollback (32k default)
  default_color = "white",
  timestamps = true,      -- Prepend a timestamp to every message
  padding = true,         -- Compact flattened prose padding at ingestion
  timestamp_format = "%H:%M",
  timestamp_color = "white",
  -- Body colour for a line that has a lead-in: the prefix carries the line
  -- type's colour and the message itself reads in this one. A line with no
  -- prefix stays entirely in its type colour, so MIP chat lines -- whose text
  -- *is* the whole formatted line -- keep their per-channel colour.
  text_color = "white",
}

-- Default prefix function for built-in types
local function default_tell_prefix(cfg, who)
  return "[" .. (who or "???") .. "] "
end

local function default_emote_prefix(cfg, who)
  return "* " .. (who or "???") .. " "
end

-- MIP CAA text already contains the formatted line ("Simon <Wiz>: hi"), so
-- chat lines get no prefix of their own; use configure() to opt back in.
local function default_chat_prefix(cfg, who)
  return ""
end

-- The three prefixes above are defaults, not user intent. A prefix installed
-- through configure() is, which is why the two are told apart when deciding
-- what a line's lead-in should be.
local BUILTIN_PREFIXES = {
  [default_tell_prefix] = true,
  [default_emote_prefix] = true,
  [default_chat_prefix] = true,
}

-- GMCP channels that map onto the built-in directional types, so an incoming
-- tell keeps its colour, its gags and the "tells" push channel whichever
-- protocol delivered it. Requires the server to say which way it went:
-- Comm.Channel.Text has no direction of its own, and targets only reveals it to
-- a client that knows its own character name.
local DIRECTED_CHANNELS = {
  tell = { ["in"] = "tell_in", out = "tell_out" },
  soul = { ["in"] = "emote_in", out = "emote_out" },
}

-- Channels whose text reads as a continuation of the speaker's name ("smiles at
-- you.") rather than something quoted after a colon. Pure guesswork about
-- server-side channel semantics, and superseded the moment the server sends its
-- own prefix field -- see gmcp_prefix() below.
local SPACE_JOINED_CHANNELS = {
  soul = true, souls = true, emote = true, emotes = true,
}

-- GMCP Comm.Channel.Text carries the body alone, with the speaker, the channel
-- and any targets in separate fields, so the text on its own loses all of that.
-- The server may send the finished lead-in as a "prefix" field; when it does it
-- is used verbatim, because only the server knows how it phrases a tell, a soul
-- or a multi-target tell. This is the fallback for when it does not.
local function gmcp_prefix(channel, talker, targets)
  if not talker or talker == "" then return "" end
  if SPACE_JOINED_CHANNELS[channel] then return talker .. " " end

  -- A multi-target tell names its recipients; without them "Simon: test" gives
  -- no hint that it went to anyone in particular.
  if type(targets) == "table" and #targets > 0 then
    local named = {}
    for _, name in ipairs(targets) do
      if type(name) == "string" and name ~= "" and name ~= talker then
        named[#named + 1] = name
      end
    end
    if #named > 0 then
      return talker .. " -> " .. table.concat(named, ", ") .. ": "
    end
  end

  return talker .. ": "
end

-- Chat line types with their colors and enabled state
-- Format: { color = "color_name", enabled = true/false, gags = {}, prefix = function }
local line_types = {
  -- Built-in types
  tell_in   = { color = "cyan",    enabled = true, gags = {}, label = "Tell (in)",   prefix = default_tell_prefix },
  tell_out  = { color = "magenta", enabled = true, gags = {}, label = "Tell (out)",  prefix = default_tell_prefix },
  emote_in  = { color = "yellow",  enabled = true, gags = {}, label = "Emote (in)",  prefix = default_emote_prefix },
  emote_out = { color = "green",   enabled = true, gags = {}, label = "Emote (out)", prefix = default_emote_prefix },
  -- Chat lines are added dynamically via add_chatline()
}

-- Color codes for ANSI output
local colors = {
  black   = "\027[30m",
  red     = "\027[31m",
  green   = "\027[32m",
  yellow  = "\027[33m",
  blue    = "\027[34m",
  magenta = "\027[35m",
  cyan    = "\027[36m",
  white   = "\027[37m",
  reset   = "\027[0m",
  -- Bright variants
  bright_black   = "\027[90m",
  bright_red     = "\027[91m",
  bright_green   = "\027[92m",
  bright_yellow  = "\027[93m",
  bright_blue    = "\027[94m",
  bright_magenta = "\027[95m",
  bright_cyan    = "\027[96m",
  bright_white   = "\027[97m",
}

-- Chat message buffer
-- Each entry: { type = "type_id", sender = "name", text = "message", seq = N }
local messages = {}
local message_seq = 0  -- Sequence number for ordering
local listeners = {}

-- Protocol handler refs for cleanup
local mip_handlers = {}
local gmcp_handlers = {}
local command_id = nil

-- require("command") is optional: a profile that never required 'commands' has
-- no registry, and the chat pane still works.
local command
do
  local ok, mod = pcall(require, "command")
  if ok then command = mod end
end

-- Wrapped-line cache: a deque so trimming old messages never shifts the array.
-- Rebuilt in full when the render width changes; appended to incrementally.
-- Entries: { text, color_code, is_continuation }
local wrapped = { width = nil, lines = {}, first = 1, last = 0 }
local selection_generation = 0

local sc = wm.make_scroller({
  count = function() return wrapped.last - wrapped.first + 1 end,
})

-- Cache helpers are defined after word_wrap (which they use) but called from
-- add_message above them; predeclare so those calls bind these locals, not
-- accidental globals.
local wrapped_reset, wrapped_append, wrapped_ensure, wrapped_trim_front
local record_message, record_history
local recording_source

--------------------------------------------------------------------------------
-- Internal helpers
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Source selection
--------------------------------------------------------------------------------
--
-- mode is the user's preference and persists; channels is which protocol is
-- actually feeding channel lines right now and resets on every disconnect.
--
-- In "auto", channel lines come from MIP until GMCP delivers one, then GMCP
-- owns them for the rest of the connection. That ordering is deliberate: a
-- server can negotiate GMCP and never send Comm.Channel.Text, and latching the
-- other way round would leave the pane empty with no fallback.
--
-- The latch covers every kind of chat line, because Comm.Channel.Text carries
-- all of them -- channels, tells (channel "tell") and souls (channel "soul").
-- An earlier version latched channels only and left MIP BAB/BAG always on,
-- which double-printed every tell and soul once GMCP took over.
--
-- Whether GMCP chat has ever been seen is remembered across sessions. Both
-- protocols deliver the same line and MIP gets there first, so a session that
-- starts on MIP prints that first line before the latch can flip -- exactly one
-- duplicate per connection. A profile that has proved GMCP once starts on it.
local source = {
  mode = "auto",        -- "auto" | "mip" | "gmcp"
  active = "mip",       -- "mip" | "gmcp": which protocol feeds every chat line
  gmcp_seen = false,    -- persisted: GMCP chat arrived in some earlier session
  mip_count = 0,
  gmcp_count = 0,
  gmcp_unmapped = 0,
  last_unmapped = nil,  -- { package = "Comm.Channel.List", fields = "channels" }
}

local function mip_allowed()
  if source.mode == "gmcp" then return false end
  if source.mode == "mip" then return true end
  return source.active ~= "gmcp"
end

local function gmcp_allowed()
  return source.mode ~= "mip"
end

-- Reported by /chat source, and the answer to "is GMCP actually arriving?".
local function source_status()
  local qualifier
  if source.mode ~= "auto" then
    qualifier = "pinned"
  elseif source.active ~= "gmcp" then
    qualifier = "auto; no GMCP chat seen yet"
  elseif source.gmcp_count > 0 then
    qualifier = "auto; latched"
  else
    qualifier = "auto; remembered from an earlier session"
  end
  return {
    mode = source.mode,
    gmcp_seen = source.gmcp_seen,
    active = source.active,
    channels = source.active,  -- kept: earlier name for the same value
    qualifier = qualifier,
    mip_count = source.mip_count,
    gmcp_count = source.gmcp_count,
    gmcp_unmapped = source.gmcp_unmapped,
    last_unmapped = source.last_unmapped and {
      package = source.last_unmapped.package,
      fields = source.last_unmapped.fields,
    } or nil,
  }
end

local function get_color(color_name)
  return colors[color_name] or colors.white
end

local pushn
local push_trigger_ids = {}

-- Resolve again at delivery: the optional consumer may load late or reload.
local function get_push_notify()
  local current = plugin and plugin.get("push_notify")
  if current ~= pushn then
    pushn = current
    if pushn and pushn.register_channel then
      pushn.register_channel("tells", { priority = 1 })
      pushn.register_channel("wimpy")
      pushn.register_channel("worlddrop")
      pushn.register_channel("artifactdrop")
    end
  end
  return pushn
end

local function register_push_triggers()
  local function add(pattern, channel, message)
    local id = trigger.add(pattern, function(line)
      local sink = get_push_notify()
      if sink and sink.notify then sink.notify(channel, message or line) end
    end, { omit_from_output = false })
    if id then push_trigger_ids[#push_trigger_ids + 1] = id end
  end
  add("^Your legs run away with you (.*?)$", "wimpy", "You have wimpied.")
  add("^You have found (.*?)!$", "worlddrop")
  -- Portal used two spaces; also accept the current one-space spelling.
  add("^YOWZA! {1,2}You are lucky enough to find (.*?)$", "worlddrop")
  add("^You catch the glint of something special\\.$", "artifactdrop")
end

-- A lead-in and the body need exactly one space between them, and a prefix may
-- or may not already end in whitespace: the built-in defaults do ("[Bob] "), a
-- server-sent one need not ("Simon tells you:").
local function join_prefix(prefix, text)
  if prefix == "" then return text end
  if prefix:match("%s$") then return prefix .. text end
  return prefix .. " " .. text
end

-- One prefix rule for both the pane and the push_notify forward.
--
-- A prefix set through configure() always wins: the user asked for it. Failing
-- that, a structured (GMCP) message uses the lead-in worked out at intake and
-- stored on the record, since its text carries no speaker of its own. MIP text
-- is already a formatted line, which is why the default is empty.
local function resolve_prefix(type_cfg, msg)
  -- A lead-in the server sent with this message wins outright. A configured
  -- prefix cannot know whether the body already carries its own attribution,
  -- and the same setting has to serve both protocols: an empty emote prefix is
  -- right for MIP text that reads "Simon smiles at you." and wrong for a GMCP
  -- body of "smiles at you.".
  if msg.prefix_from_server and type(msg.prefix) == "string" then
    return msg.prefix
  end

  local prefix_fn = type_cfg.prefix
  if prefix_fn and not BUILTIN_PREFIXES[prefix_fn] then
    return prefix_fn(type_cfg, msg.sender)
  end
  if type(msg.prefix) == "string" then return msg.prefix end
  if prefix_fn then return prefix_fn(type_cfg, msg.sender) end
  return "[" .. (msg.sender or msg.type) .. "] "
end

-- Fold single indented continuations, not arbitrary runs of spaces. Keep SGR
-- in order even inside indentation. Unindented line breaks and blank paragraphs
-- (including their indentation) are explicit layout, not inferred wrapping.

local function fold_continuations(text)
  if not text:find("[\r\n]") then return text end
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  local out, pending, breaks, visible = {}, {}, 0, false
  local function flush(at_end)
    if #pending == 0 then return end
    local gap = table.concat(pending)
    if breaks > 0 then
      local whitespace = gap:gsub("\27%[[0-9;]*m", "")
      local continuation = breaks == 1 and whitespace:match("\n[ \t]+$")
      if not visible or at_end or continuation then
        if visible and not at_end then out[#out + 1] = " " end
        gap = gap:gsub("[ \t\n]", "")
      end
    end
    out[#out + 1] = gap
    pending, breaks = {}, 0
  end
  local i = 1
  while i <= #text do
    local sgr = text:match("^\27%[[0-9;]*m", i)
    local c = text:sub(i, i)
    if sgr then
      pending[#pending + 1] = sgr
      i = i + #sgr
    elseif c == " " or c == "\t" or c == "\n" then
      pending[#pending + 1] = c
      if c == "\n" then breaks = breaks + 1 end
      i = i + 1
    else
      flush(false)
      out[#out + 1] = c
      visible = true
      i = i + 1
    end
  end
  flush(true)
  return table.concat(out)
end

-- Treat SGR as zero-width inside a gap, retaining every escape in order.
-- Only internal ASCII-space runs count; tabs and leading/trailing layout do not.
local function compact_padding(text)
  local out, pending, spaces, visible = {}, {}, 0, false
  local function flush(internal)
    local gap = table.concat(pending)
    if internal and visible and spaces >= 8 then
      local kept = false
      gap = gap:gsub(" ", function()
        if not kept then kept = true; return " " end
        return ""
      end)
    end
    out[#out + 1] = gap
    pending, spaces = {}, 0
  end
  local i = 1
  while i <= #text do
    local sgr = text:match("^\27%[[0-9;]*m", i)
    local c = text:sub(i, i)
    if sgr then
      pending[#pending + 1] = sgr
      i = i + #sgr
    elseif c == " " then
      pending[#pending + 1] = c
      spaces = spaces + 1
      i = i + 1
    else
      flush(not c:match("%s"))
      out[#out + 1] = c
      visible = not c:match("%s")
      i = i + 1
    end
  end
  flush(false)
  return table.concat(out)
end

local function normalize_prose(msg_type, text)
  local prose = msg_type == "tell_in" or msg_type == "tell_out"
    or msg_type == "emote_in" or msg_type == "emote_out" or msg_type:match("^chat_")
  if not prose then return text end
  if text:find("[\r\n]") then
    -- Do not turn multiline alignment into single-line padding that a relay
    -- would compact on its second pass. Indented first lines are layout too.
    local plain = text:gsub("\27%[[0-9;]*m", "")
    if plain:match("^[ \t]+%S") then return text end
    local lines = plain:gsub("\r\n", "\n"):gsub("\r", "\n")
    if lines:match("%S.-\n[ \t]*\n.-%S") or lines:match("%S.-\n%S") then
      return text:gsub("\r\n", "\n"):gsub("\r", "\n")
    end
    for line in text:gmatch("[^\r\n]+") do
      if compact_padding(line) ~= line then return text end
    end
    return fold_continuations(text)
  end
  return config.padding and compact_padding(text) or text
end

-- Diagnostics retain only numeric metadata and fixed labels, never input text.
local spacing_enabled, spacing_records = false, {}
local function spacing_measure(text, with_runs)
  local lf, cr, runs = 0, 0, {}
  for c in text:gmatch("[\r\n]") do
    if c == "\n" then lf = lf + 1 else cr = cr + 1 end
  end
  if with_runs then
    local start = 1
    while true do
      local first, last = text:find("  +", start)
      if not first then break end
      if #runs == 10 then runs[#runs + 1] = "..."; break end
      runs[#runs + 1] = string.format("%d:%d", first, last - first + 1)
      start = last + 1
    end
  end
  return string.format("bytes=%d lf=%d cr=%d", #text, lf, cr)
    .. (with_runs and (" spaces=[" .. table.concat(runs, ",") .. "]") or "")
end

local function spacing_capture(msg_type, opts, raw, normalized)
  local category = "other"
  if msg_type == "tell_in" or msg_type == "tell_out" then category = msg_type
  elseif msg_type == "emote_in" or msg_type == "emote_out" then category = msg_type
  elseif msg_type:match("^chat_") then category = "channel" end
  local origin = opts and opts.remote and "relay"
    or (opts and opts.structured and "gmcp" or "mip")
  if #spacing_records == 20 then table.remove(spacing_records, 1) end
  spacing_records[#spacing_records + 1] = origin .. " " .. category
    .. " raw{" .. raw .. "} normalized{" .. spacing_measure(normalized, true) .. "}"
end

local function spacing_command(action, extra)
  if extra or (action ~= "on" and action ~= "report" and action ~= "off") then
    return print("Usage: /chat spacing on|report|off")
  end
  if action ~= "report" then
    spacing_enabled, spacing_records = action == "on", {}
    return print("[chat spacing] " .. (spacing_enabled and "on" or "off") .. "; records cleared")
  end
  print(string.format("[chat spacing] %s; records=%d/20; bytes include ANSI/UTF-8; spaces=1-based byte position:length (first 10 runs >=2; ...=more)",
    spacing_enabled and "on" or "off", #spacing_records))
  for i, record in ipairs(spacing_records) do
    print(string.format("[chat spacing] %d %s", i, record))
  end
end

local function add_message(msg_type, sender, text, opts)
  local spacing_raw = spacing_enabled and spacing_measure(text, true)
  text = normalize_prose(msg_type, text)
  if spacing_raw then spacing_capture(msg_type, opts, spacing_raw, text) end
  local structured = opts and opts.structured or false
  local prefix_text = opts and opts.prefix or nil
  local prefix_from_server = opts and opts.prefix_from_server or false
  local type_cfg = line_types[msg_type]
  if not type_cfg then
    -- Unknown type, use defaults
    type_cfg = { color = config.default_color, enabled = true, gags = {} }
  end

  -- Check if this type is enabled
  if not type_cfg.enabled then
    return false
  end

  -- Check gags
  for _, pattern in ipairs(type_cfg.gags or {}) do
    if text:match(pattern) or (sender and sender:match(pattern)) then
      return false  -- Gagged
    end
  end

  -- Notify optional consumers (for example chat relay) after local filtering.
  if not (opts and opts.remote) then
    local listener_opts = opts or {}
    if listener_opts.prefix == nil then
      listener_opts = {}
      for key, value in pairs(opts or {}) do listener_opts[key] = value end
      listener_opts.prefix = resolve_prefix(type_cfg, {
        type = msg_type, sender = sender, structured = structured,
        prefix = prefix_text, prefix_from_server = prefix_from_server,
      })
    end
    for _, listener in ipairs(listeners) do
      local ok, err = pcall(listener, msg_type, sender, text, listener_opts)
      if not ok then print("[chat_monitor] listener error: " .. tostring(err)) end
    end
  end

  -- Forward to push_notify: incoming tells/emotes and chat lines, never our
  -- own outgoing messages. push_notify applies its own per-channel gating.
  local sink = get_push_notify()
  if sink and sink.notify then
    local channel
    if msg_type == "tell_in" then
      channel = "tells"
    elseif msg_type == "emote_in" then
      channel = "emotes"
    else
      channel = msg_type:match("^chat_(.+)")
    end
    if channel then
      local prefix = resolve_prefix(type_cfg, {
        type = msg_type, sender = sender, structured = structured,
        prefix = prefix_text, prefix_from_server = prefix_from_server,
      })
      sink.notify(channel, join_prefix(prefix, text))
    end
  end

  -- Add to buffer
  message_seq = message_seq + 1
  table.insert(messages, {
    type = msg_type,
    sender = sender,
    text = text,
    seq = message_seq,
    time = os.time(),
    -- Persisted: a restored GMCP line must keep rendering its lead-in.
    structured = structured or nil,
    prefix = prefix_text,
    prefix_from_server = prefix_from_server or nil,
  })

  -- Wrap into the cache at the current width (first render builds it otherwise)
  -- and let the scroller hold a scrolled-back view still.
  if wrapped.width then
    local rows = wrapped_append(messages[#messages], wrapped.width)
    sc.on_append(rows)
  end

  if recording_source then record_message(messages[#messages]) end

  -- Trim buffer if too large
  while #messages > config.max_lines do
    local dead = table.remove(messages, 1)
    wrapped_trim_front(dead)
  end

  return true
end

local function parse_delimited(data, delim)
  local parts = {}
  local start = 1
  delim = delim or "~"
  while true do
    local pos = data:find(delim, start, true)
    if pos then
      table.insert(parts, data:sub(start, pos - 1))
      start = pos + 1
    else
      table.insert(parts, data:sub(start))
      break
    end
  end
  return parts
end

-- Word wrap text to fit within width
-- Returns array of lines
-- Returns the wrapped lines and, alongside them, how many source characters
-- each line consumed. They differ whenever a break space is dropped, and colour
-- spans are mapped back onto the wrapped output by source offset, so the count
-- has to be exact rather than inferred from the line lengths.
local function wrap_line(text, width, continuation, indent)
  if width <= 0 then return { text }, { #text } end
  indent = indent or 0
  if #url_links.cells(text) <= width - (continuation and indent or 0) then
    return { text }, { #text }
  end

  local lines = {}
  local consumed = {}
  local remaining = text

  while #remaining > 0 do
    local cells = url_links.cells(remaining)
    local row_width = math.max(1, width - ((continuation or #lines > 0) and indent or 0))
    if #cells <= row_width then
      table.insert(lines, remaining)
      table.insert(consumed, #remaining)
      break
    end

    -- Find a good break point (space, hyphen, etc.)
    local break_pos = cells[row_width].last
    local found_break = false

    -- Look backwards for a space or break character
    for index = row_width, 1, -1 do
      local i = cells[index].last
      local c = remaining:sub(i, i)
      if c == " " or c == "-" or c == "," or c == "." or c == ":" or c == ";" then
        break_pos = i
        found_break = true
        break
      end
    end

    -- If no break found, just break at width
    if not found_break then
      break_pos = cells[row_width].last
    end

    local line = remaining:sub(1, break_pos)
    -- Trim trailing space if we broke on a space
    if line:sub(-1) == " " then
      line = line:sub(1, -2)
    end
    table.insert(lines, line)
    -- remaining always advances past the break character, whether or not it was
    -- trimmed off the line above.
    table.insert(consumed, break_pos)

    remaining = remaining:sub(break_pos + 1)
  end

  return lines, consumed
end

-- Paragraph separators consume source bytes too: link and colour offsets on
-- subsequent rows must include them, even though they are not painted.
local function word_wrap(text, width, indent)
  if not text:find("\n", 1, true) then return wrap_line(text, width, false, indent) end
  local lines, consumed, start = {}, {}, 1
  while true do
    local boundary = text:find("\n", start, true)
    local rows, counts = wrap_line(text:sub(start, boundary and boundary - 1), width, #lines > 0, indent)
    for i, row in ipairs(rows) do
      lines[#lines + 1] = row
      consumed[#consumed + 1] = counts[i]
    end
    if not boundary then break end
    consumed[#consumed] = consumed[#consumed] + 1
    start = boundary + 1
  end
  return lines, consumed
end

function wrapped_reset()
  selection_generation = selection_generation + 1
  wrapped.width = nil
  wrapped.lines = {}
  wrapped.first = 1
  wrapped.last = 0
end

-- Format + word-wrap one message at a given width. Shared by the local cache
-- builder (wrapped_append) and the transient remote-pass builder below, so
-- prefix/color formatting can't drift between the two.
-- Paint colour spans onto already-wrapped lines. Wrapping runs on the plain
-- string so escape codes never enter the width arithmetic; the spans are then
-- mapped back by source offset, which is what word_wrap's consumed counts are
-- for. A span boundary landing mid-line splits that line; one landing at a line
-- edge simply becomes the next line's opening colour.
--
-- Each line opens with an explicit colour code, so a continuation line resumes
-- in the right colour rather than inheriting the row's base one.
local function paint_spans(lines, consumed, spans, source)
  local bounds, acc = {}, 0
  for _, span in ipairs(spans) do
    if span.len > 0 then
      bounds[#bounds + 1] = { at = acc, code = span.code }
      acc = acc + span.len
    end
  end
  if #bounds == 0 then return lines end

  local painted = {}
  local offset = 0
  for i, line in ipairs(lines) do
    local opening, span_start = bounds[1].code, 0
    for _, bound in ipairs(bounds) do
      if bound.at <= offset then opening, span_start = bound.code, bound.at end
    end
    -- Inline ANSI in a message must also resume after a word-wrap boundary.
    local carry = {}
    for code in source:sub(span_start+1, offset):gmatch("\27%[[0-9;]*m") do
      carry[#carry+1] = code
    end

    local parts, cursor = { opening, table.concat(carry) }, 0
    for _, bound in ipairs(bounds) do
      local rel = bound.at - offset
      if rel > 0 and rel < #line then
        parts[#parts + 1] = line:sub(cursor + 1, rel)
        parts[#parts + 1] = bound.code
        cursor = rel
      end
    end
    parts[#parts + 1] = line:sub(cursor + 1)

    painted[i] = table.concat(parts)
    offset = offset + (consumed[i] or #line)
  end
  return painted
end

local function logical_message(msg)
  local type_cfg = line_types[msg.type] or { color = config.default_color }
  local prefix = resolve_prefix(type_cfg, msg)
  local stamp = ""
  if config.timestamps and msg.time then
    stamp = "[" .. os.date(config.timestamp_format, msg.time) .. "] "
  end

  local color_code = get_color(type_cfg.color)
  -- With no lead-in the whole line stays in the type colour: MIP text is itself
  -- a formatted line ("Simon <Wiz>: hi"), and greying it would throw away the
  -- per-channel colour that distinguishes one channel from another.
  local body_code = color_code
  if #prefix > 0 then
    body_code = get_color(type_cfg.text_color or config.text_color)
  end

  local body = join_prefix(prefix, msg.text)
  local lead = stamp .. body:sub(1, #body - #msg.text)
  return color_code, stamp .. body, {
    { len = #stamp, code = get_color(config.timestamp_color) },
    { len = #lead - #stamp, code = color_code },
    { len = #msg.text, code = body_code },
  }, #url_links.cells(lead)
end

-- Shared unwrapped, painted bytes for the companion and recording archive.
local function logical_text(msg)
  local _, plain, spans = logical_message(msg)
  return paint_spans({plain}, {#plain}, spans, plain)[1]
end

record_message = function(msg)
  if not recording_source or not recording.source_active() then return false end
  local id = msg.seq
  -- Lua numbers stop representing every integer beyond this bound. Fail only
  -- capture before formatting; the existing live history remains untouched.
  if type(id) ~= "number" or id < 1 or id > 9007199254740991 or id % 1 ~= 0 then
    return recording.source_upsert(recording_source, "", "")
  end
  return recording.source_upsert(recording_source, string.format("%.0f", id), logical_text(msg))
end

record_history = function()
  if not recording_source then return end
  for i = 1, #messages do
    if not record_message(messages[i]) then break end
  end
end

local function wrap_msg(msg, width)
  local color_code, source, spans, indent = logical_message(msg)
  -- Hang continuation rows under the message body, not under the timestamp.
  -- A narrow pane still needs useful text space when the prefix nearly fills it.
  if indent > math.max(0, width - 8) then
    indent = math.min(2, math.max(0, width - 1))
  end
  local lines, consumed = word_wrap(source, width, indent)
  local detected, row_links, offset = url_links.find(source), {}, 0
  for i, line in ipairs(lines) do
    row_links[i] = {}
    for _, link in ipairs(detected) do
      local first = math.max(link.byte_start, offset + 1)
      local last = math.min(link.byte_end, offset + #line)
      if first <= last then
        row_links[i][#row_links[i]+1] = {
          value = link.value, message = msg, source_start = link.byte_start,
          col_start = #url_links.cells(line:sub(1, first-offset-1)),
          col_end = #url_links.cells(line:sub(1, last-offset)),
        }
      end
    end
    offset = offset + consumed[i]
  end

  local painted = paint_spans(lines, consumed, spans, source)
  for i, line in ipairs(painted) do
    painted[i] = url_links.highlight(line, nil, row_links[i])
  end
  return color_code, painted, row_links, indent
end

-- Wrap one message and append its rows to the cache. Returns the row count,
-- which is also recorded on the message for trim accounting.
function wrapped_append(msg, width)
  local color_code, lines, row_links, indent = wrap_msg(msg, width)
  for j = 1, #lines do
    wrapped.last = wrapped.last + 1
    wrapped.lines[wrapped.last] = {
      text = lines[j],
      links = row_links[j],
      indent = j > 1 and indent or 0,
      color_code = color_code,
      is_continuation = (j > 1),
    }
  end
  msg._rows = #lines
  return #lines
end

function wrapped_ensure(width)
  if wrapped.width == width then return end
  wrapped_reset()
  wrapped.width = width
  for i = 1, #messages do
    wrapped_append(messages[i], width)
  end
  sc.on_trim()  -- re-clamp: row count changed with the width
end

-- Drop the oldest message's rows off the front of the cache.
function wrapped_trim_front(msg)
  if not wrapped.width then return end
  if not msg._rows then
    -- A message the cache never saw (e.g. restored from store mid-session):
    -- the bookkeeping is unknowable, rebuild lazily instead.
    wrapped_reset()
    return
  end
  for i = wrapped.first, wrapped.first + msg._rows - 1 do
    wrapped.lines[i] = nil
  end
  wrapped.first = wrapped.first + msg._rows
  sc.on_trim()
end

--------------------------------------------------------------------------------
-- MIP Handlers
--------------------------------------------------------------------------------

-- BAB - Tells
-- Format: direction~object~text
-- direction: "x" = outgoing, "" = incoming
local function handle_tell(key, code, data)
  if not mip_allowed() then return end
  source.mip_count = source.mip_count + 1
  local parts = parse_delimited(data)
  local direction = parts[1] or ""
  local person = parts[2] or "Unknown"
  local text = parts[3] or ""

  local msg_type = (direction == "x") and "tell_out" or "tell_in"
  add_message(msg_type, person, text)
end

-- BAG - Emotes/Souls
-- Format: direction~person~text
-- direction: "x" = from afar (incoming?), "" = local
local function handle_emote(key, code, data)
  if not mip_allowed() then return end
  source.mip_count = source.mip_count + 1
  local parts = parse_delimited(data)
  local direction = parts[1] or ""
  local person = parts[2] or "Unknown"
  local text = parts[3] or ""

  local msg_type = (direction == "x") and "emote_in" or "emote_out"
  add_message(msg_type, person, text)
end

-- Colors assigned in rotation to newly discovered chat types.
local CHAT_COLORS = { "bright_cyan", "bright_green", "bright_yellow", "bright_magenta", "bright_blue" }

-- Both protocols name the same channel the same way ("wiz"), so both land on
-- the same type ID and a channel keeps its color, label and gags when the
-- source flips. Shared so the two intake paths cannot drift apart.
local function ensure_chat_type(command, label)
  local msg_type = "chat_" .. command
  if line_types[msg_type] then return msg_type end

  local color_idx = 1
  for k, _ in pairs(line_types) do
    if k:match("^chat_") then
      color_idx = color_idx + 1
    end
  end
  line_types[msg_type] = {
    color = CHAT_COLORS[((color_idx - 1) % #CHAT_COLORS) + 1],
    enabled = true,
    gags = {},
    label = label or command,
    command = command,
    prefix = default_chat_prefix,
  }
  return msg_type
end

-- CAA - Chat lines
-- Format: command~line_name~sender~text
local function handle_chat(key, code, data)
  if not mip_allowed() then return end
  source.mip_count = source.mip_count + 1

  local parts = parse_delimited(data)
  local command = parts[1] or "unknown"
  local line_name = parts[2] or "Chat"
  local sender = parts[3] or "Unknown"
  local text = parts[4] or ""

  -- Use command as the type ID (e.g., "gossip", "guildchat")
  add_message(ensure_chat_type(command, line_name), sender, text)
end

-- Anything under Comm that is not a channel line we can read. Counted and
-- described rather than printed, so "GMCP is silent" stays distinguishable
-- from "GMCP is arriving in a shape this does not understand".
local function note_unmapped(package, data)
  source.gmcp_unmapped = source.gmcp_unmapped + 1

  local fields = {}
  if type(data) == "table" then
    for k, _ in pairs(data) do fields[#fields + 1] = tostring(k) end
    table.sort(fields)
  end
  source.last_unmapped = {
    package = package,
    fields = (#fields > 0) and table.concat(fields, ", ") or "(none)",
  }
end

-- GMCP Comm.Channel.Text, as 3K sends it:
--   { "channel": "wiz", "talker": "Simon", "text": "test" }
-- The channel name is used exactly as sent.
local function handle_gmcp_comm(package, data)
  if not gmcp_allowed() then return end
  if tostring(package):lower() ~= "comm.channel.text" then
    return note_unmapped(package, data)
  end
  if type(data) ~= "table" then
    return note_unmapped(package, data)
  end

  local channel, text = data.channel, data.text
  if type(channel) ~= "string" or channel == "" or type(text) ~= "string" then
    return note_unmapped(package, data)
  end
  local talker = (type(data.talker) == "string" and data.talker ~= "") and data.talker or nil

  -- The server's own lead-in, when it sends one, beats anything reconstructed
  -- here: it knows how it phrases "You tell X, Y:" against "X tells you:".
  local prefix, from_server = data.prefix, true
  if type(prefix) ~= "string" then
    prefix, from_server = gmcp_prefix(channel, talker, data.targets), false
  end

  -- A directed channel lands on the matching built-in type, but only when the
  -- server says which direction it went; without that it stays an ordinary
  -- chat_<channel> type rather than being guessed into the wrong one.
  local msg_type
  local directed = DIRECTED_CHANNELS[channel:lower()]
  local direction = type(data.direction) == "string" and data.direction:lower() or nil
  if directed and direction and directed[direction] then
    msg_type = directed[direction]
  else
    msg_type = ensure_chat_type(channel, channel)
  end

  source.gmcp_count = source.gmcp_count + 1
  -- The latch: a real chat line is what promotes GMCP, not negotiation. Also
  -- remembered, so the next session need not re-learn it the expensive way.
  source.gmcp_seen = true
  if source.mode == "auto" then source.active = "gmcp" end

  add_message(msg_type, talker, text,
              { structured = true, prefix = prefix, prefix_from_server = from_server })
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

local function formatting_options_changed(opts)
  return opts.color ~= nil or opts.label ~= nil or opts.prefix ~= nil
     or opts.text_color ~= nil
end

local function invalidate_wrapped_formatting()
  companion_epoch = companion_epoch + 1
  selection_generation = selection_generation + 1
  wrapped.width = nil
  record_history()
end

function M.on_message(callback)
  if type(callback) ~= "function" then return false end
  listeners[#listeners + 1] = callback
  return true
end

function M.receive(msg_type, sender, text, prefix)
  return add_message(msg_type, sender, text, {
    remote = true,
    structured = true,
    prefix = prefix or "",
    prefix_from_server = true,
  })
end

-- Configure any line type (built-in or chat)
-- type_id: "tell_in", "tell_out", "emote_in", "emote_out", or "chat_<command>"
-- opts: { color = "color_name", label = "Display Name", prefix = function, enabled = true/false }
-- Source control. "auto" latches to GMCP once it delivers a channel line,
-- "mip" and "gmcp" pin it. Returns true, or false plus a reason.
function M.set_source(mode)
  if mode ~= "auto" and mode ~= "mip" and mode ~= "gmcp" then
    return false, "source must be auto, mip or gmcp"
  end
  selection_generation = selection_generation + 1
  source.mode = mode
  if mode == "mip" then
    source.active = "mip"
  elseif mode == "gmcp" then
    source.active = "gmcp"
  else
    -- Back to latching, which a profile that has already proved GMCP resolves
    -- in GMCP's favour immediately.
    source.active = (source.gmcp_count > 0 or source.gmcp_seen) and "gmcp" or "mip"
  end
  return true
end

-- Snapshot of which protocol is feeding the pane and what each has delivered.
function M.source()
  return source_status()
end

function M.configure(type_id, opts)
  opts = opts or {}
  if not line_types[type_id] then
    return false  -- Type doesn't exist
  end
  selection_generation = selection_generation + 1
  if opts.color then line_types[type_id].color = opts.color end
  if opts.label then line_types[type_id].label = opts.label end
  if opts.prefix then line_types[type_id].prefix = opts.prefix end
  if opts.enabled ~= nil then line_types[type_id].enabled = opts.enabled end
  -- Per-type override of the body colour; falls back to config.text_color.
  if opts.text_color and colors[opts.text_color] then
    line_types[type_id].text_color = opts.text_color
  end
  if formatting_options_changed(opts) then invalidate_wrapped_formatting() end
  return true
end

-- Add or configure a chat line type (for MIP CAA chat lines)
-- id: unique identifier (e.g., "gossip", "guild", "ooc")
-- opts: { color = "color_name", label = "Display Name", enabled = true/false }
function M.add_chatline(id, opts)
  opts = opts or {}
  local type_id = "chat_" .. id
  selection_generation = selection_generation + 1

  if line_types[type_id] then
    -- Update existing
    if opts.color then line_types[type_id].color = opts.color end
    if opts.label then line_types[type_id].label = opts.label end
    if opts.prefix then line_types[type_id].prefix = opts.prefix end
    if opts.enabled ~= nil then line_types[type_id].enabled = opts.enabled end
    if formatting_options_changed(opts) then invalidate_wrapped_formatting() end
  else
    -- Create new
    line_types[type_id] = {
      color = opts.color or config.default_color,
      enabled = opts.enabled ~= false,
      gags = {},
      label = opts.label or id,
      prefix = opts.prefix or default_chat_prefix,
      command = id,
    }
  end
end

-- Toggle a line type on/off
-- type_id: "tell_in", "tell_out", "emote_in", "emote_out", or "chat_<command>"
function M.toggle(type_id, enabled)
  if line_types[type_id] then
    selection_generation = selection_generation + 1
    if enabled == nil then
      line_types[type_id].enabled = not line_types[type_id].enabled
    else
      line_types[type_id].enabled = enabled
    end
    return line_types[type_id].enabled
  end
  return nil
end

-- Enable a line type
function M.enable(type_id)
  return M.toggle(type_id, true)
end

-- Disable a line type
function M.disable(type_id)
  return M.toggle(type_id, false)
end

-- Check if a line type is enabled
function M.is_enabled(type_id)
  if line_types[type_id] then
    return line_types[type_id].enabled
  end
  return nil
end

-- Set color for a line type
function M.set_color(type_id, color)
  if line_types[type_id] and colors[color] then
    line_types[type_id].color = color
    invalidate_wrapped_formatting()
    return true
  end
  return false
end

-- Add a gag pattern to a line type
-- pattern: Lua pattern to match against sender or text
function M.add_gag(type_id, pattern)
  if line_types[type_id] then
    selection_generation = selection_generation + 1
    table.insert(line_types[type_id].gags, pattern)
    return true
  end
  return false
end

-- Remove a gag pattern from a line type
function M.remove_gag(type_id, pattern)
  if line_types[type_id] then
    for i, p in ipairs(line_types[type_id].gags) do
      if p == pattern then
        selection_generation = selection_generation + 1
        table.remove(line_types[type_id].gags, i)
        return true
      end
    end
  end
  return false
end

-- List all gags for a line type
function M.list_gags(type_id)
  if line_types[type_id] then
    return line_types[type_id].gags
  end
  return {}
end

-- Clear all messages
function M.clear()
  companion_epoch = companion_epoch + 1
  messages = {}
  wrapped_reset()
  sc.scroll_to_bottom()
  if recording_source then recording.source_reset(recording_source) end
end

-- Get message count
function M.count()
  return #messages
end

local link_capture
local pointer_border = 1

-- Scroll the chat pane by wrapped rows. delta < 0 = up/older.
function M.scroll(delta)
  link_capture = nil
  selection_generation = selection_generation + 1
  sc.scroll(delta)
end

function M.scroll_to_bottom()
  link_capture = nil
  selection_generation = selection_generation + 1
  sc.scroll_to_bottom()
end

-- True when the pane is showing the newest line.
function M.following_tail()
  return sc.following_tail()
end

-- List all configured line types
function M.list_types()
  local result = {}
  for id, cfg in pairs(line_types) do
    table.insert(result, {
      id = id,
      label = cfg.label or id,
      color = cfg.color,
      enabled = cfg.enabled,
      gag_count = #(cfg.gags or {}),
    })
  end
  table.sort(result, function(a, b) return a.id < b.id end)
  return result
end

-- Get messages (for external rendering)
-- Returns array of { type, sender, text, seq, color }
function M.get_messages(limit)
  limit = limit or #messages
  local result = {}
  local start = math.max(1, #messages - limit + 1)
  local stop = #messages

  for i = start, stop do
    local msg = messages[i]
    if msg then
      local type_cfg = line_types[msg.type] or { color = config.default_color }
      local prefix_text = resolve_prefix(type_cfg, msg)
      table.insert(result, {
        type = msg.type,
        sender = msg.sender,
        text = msg.text,
        seq = msg.seq,
        time = msg.time,
        color = type_cfg.color,
        color_code = get_color(type_cfg.color),
        prefix = prefix_text,
      })
    end
  end

  return result
end

-- Indexed logical history for the mobile companion. Binary search touches
-- only log(N) retained entries; a live poll never copies the entire history.
local companion_provider = {}
local function companion_id(msg) return msg and string.format("%.0f", msg.seq) or "" end
local function companion_find(id)
  local value = tonumber(id)
  if not value or value < 1 or value % 1 ~= 0 or string.format("%.0f",value) ~= id then return nil end
  local low, high = 1, #messages
  while low <= high do
    local mid = math.floor((low + high) / 2)
    if messages[mid].seq == value then return mid end
    if messages[mid].seq < value then low = mid + 1 else high = mid - 1 end
  end
  return nil, low
end
function companion_provider.page(req)
  local epoch = tostring(companion_epoch)
  local reset = req.epoch ~= "" and req.epoch ~= epoch
  local after, before = reset and "" or req.after, reset and "" or req.before
  local gap, more, first, last = false, false, 1, #messages
  if after ~= "" or before ~= "" then
    local cursor = after ~= "" and after or before
    local at, insertion = companion_find(cursor)
    if not at then
      gap = true
      if not insertion then error("Invalid Chat cursor") end
      at = after ~= "" and insertion - 1 or insertion
    end
    if after ~= "" then first = at + 1 else last = at - 1 end
  end
  if after ~= "" then
    more = last - first + 1 > req.limit
    last = math.min(last, first + req.limit - 1)
  else
    more = last - first + 1 > req.limit
    first = math.max(first, last - req.limit + 1)
  end
  local records = {}
  for i = first, last do
    local msg = messages[i]
    if msg then
      records[#records+1] = {id=companion_id(msg),text=logical_text(msg)}
    end
  end
  return {epoch=epoch,records=records,oldest=companion_id(messages[1]),latest=companion_id(messages[#messages]),
    more=more,gap=gap,reset=reset,cursor=#records > 0 and (after ~= "" and records[#records].id or records[1].id) or after ~= "" and after or before}
end
function M.companion_source() return companion_provider end

-- Shared by local/remote rendering and immutable selection snapshots so color
-- and continuation indentation stay identical.
local function row_text(line)
  return line.color_code .. string.rep(" ", line.indent or 0)
      .. line.text .. colors.reset
end

local function draw_row(x, y, w, line)
  if not line then return end
  ui.text_ansi(ui.rect(x, y, w, 1), row_text(line), nil)
end

function M.selection_source(rect)
  local x, y, w, h
  if type(rect.x) == "function" then
    x, y, w, h = rect:x(), rect:y(), rect:w(), rect:h()
  else
    x, y, w, h = rect.x, rect.y, rect.w, rect.h
  end
  local border = pointer_border
  local b = {x=x+border, y=y+border, w=w-2*border, h=h-2*border}
  if b.w <= 0 or b.h <= 0 then return nil end
  wrapped_ensure(b.w)
  local rows, entries = {}, {}
  local first, started_at_tail = wrapped.first, sc.following_tail()
  for i = wrapped.first, wrapped.last do
    -- These are independently formatted display rows: continuation indentation
    -- and word-wrap spacing prevent treating them as unmodified soft wraps.
    rows[#rows+1] = {text=row_text(wrapped.lines[i])}
    entries[#rows] = wrapped.lines[i]
  end
  local generation = selection_generation
  local function valid() return selection_generation == generation end
  return {bounds=b, rows=rows, bottom=#rows-sc.offset(), valid=valid,
    finish=function(selection, reason)
      -- Reflow/configuration changes discard the old identities; an explicit
      -- scroll owns its newer view. Append and trim leave this generation alone.
      if not valid() then return end
      if reason == "escape" and started_at_tail then
        sc.scroll_to_bottom()
        return
      end
      local index = first + selection.bottom - 1
      if wrapped.lines[index] ~= entries[selection.bottom] then
        index = wrapped.first  -- the selected bottom row was evicted
      end
      local offset = math.max(0, wrapped.last-index)
      sc.scroll(sc.offset()-offset)
    end}
end

-- Paint h rows bottom-up. get_row(screen_row) returns the wrapped-line entry
-- (or nil) for that screen row; screen_row runs h..1 (h = bottom row).
local function draw_rows(x, y, w, h, get_row)
  for screen_row = h, 1, -1 do
    draw_row(x, y + screen_row - 1, w, get_row(screen_row))
  end
end

-- Build a disposable (non-cached) wrapped-line list at `width`, newest rows
-- first, stopping once `need_rows` rows are collected. This mirrors the
-- pre-cache render's early-exit shape and exists so the WebSocket remote
-- render pass (which can run at a different width than the local screen)
-- never touches the local `wrapped` cache or `sc` scroller state.
local function build_transient(width, need_rows)
  local list = {}
  for i = #messages, 1, -1 do
    local color_code, lines, _, indent = wrap_msg(messages[i], width)
    for j = #lines, 1, -1 do
      list[#list + 1] = {
        text = lines[j],
        indent = j > 1 and indent or 0,
        color_code = color_code,
        is_continuation = (j > 1),
      }
      if #list >= need_rows then return list end
    end
  end
  return list
end

-- wm supplies zero-based pane-local coordinates, including the border.
local function link_at(event)
  local trace = event.url_trace
  if event.inside == false then return nil end
  local border = pointer_border
  local w, h = event.width - 2*border, event.height - 2*border
  local x, y = event.x - border, event.y - border
  if w <= 0 or h <= 0 or x < 0 or x >= w or y < 0 or y >= h then return nil end
  wrapped_ensure(w)
  local offset = sc.offset()
  if trace then
    trace.pane, trace.width, trace.height, trace.offset = "chat", w, h, offset
  end
  if offset > 0 and y == h-1 then
    local length = #string.format(" [+%d] ", offset)
    if x >= w-length-1 and x < w-1 then return nil end
  end
  local index = wrapped.last - offset - (h-1-y)
  local row = index >= wrapped.first and wrapped.lines[index]
  if not row then return nil end
  x = x - (row.indent or 0)
  if trace then
    local _, plain = url_links.cells(row.text)
    local _, www = plain:lower():gsub("www%.", "")
    local _, controls = plain:gsub("%c", "")
    trace.cell, trace.plain, trace.www, trace.controls = x, #(row.links or {}), www, controls
  end
  for _, link in ipairs(row.links or {}) do
    if x >= link.col_start and x < link.col_end then
      if trace then trace.hit = "plain-url" end
      return link
    end
  end
end

function M.on_pointer(event)
  if event.kind == "cancel" then link_capture = nil; return false end
  if event.kind == "move" then
    if link_capture and (event.x ~= link_capture.x or event.y ~= link_capture.y) then
      link_capture.cancelled = true
    end
    return false
  end
  if event.kind == "down" then
    link_capture = nil
    if event.button ~= "left" then return false end
    local link = link_at(event)
    if not link then return false end
    link_capture = { link=link, x=event.x, y=event.y,
      width=event.width, height=event.height }
    return true
  end
  if event.kind == "up" then
    local capture = link_capture
    link_capture = nil
    if event.url_trace then
      event.url_trace.activation = not capture and "no-capture"
        or (capture.cancelled and "drag-cancelled" or "not-matched")
    end
    if not capture or capture.cancelled or event.button ~= "left" then return false end
    if event.width ~= capture.width or event.height ~= capture.height then
      if event.url_trace then event.url_trace.activation = "geometry-changed" end
      return false
    end
    local link = link_at(event)
    if link and link.message == capture.link.message
       and link.source_start == capture.link.source_start and link.value == capture.link.value then
      local ok, err = mxp.open_url(link.value)
      if event.url_trace then event.url_trace.activation = ok and "opened" or "opener-failed" end
      if not ok then print("[chat] " .. (err or "could not open URL")) end
    end
  end
  return false
end

-- Render the chat monitor in a given rect
-- rect: { x, y, w, h } or rect object with :x(), :y(), :w(), :h() methods
-- opts: { show_border = true, title = "Chat" }
function M.render(rect, opts)
  opts = opts or {}
  local show_border = opts.show_border ~= false
  if lera.render_pass() ~= "remote" then
    local border = show_border and 1 or 0
    if pointer_border ~= border then selection_generation = selection_generation + 1 end
    pointer_border = border
  end
  local title = opts.title or "Chat"

  -- Get rect dimensions
  local x, y, w, h
  if type(rect.x) == "function" then
    x, y, w, h = rect:x(), rect:y(), rect:w(), rect:h()
  else
    x, y, w, h = rect.x, rect.y, rect.w, rect.h
  end

  -- Draw border if requested
  if show_border then
    ui.box(rect, "single", title)
    x, y, w, h = x + 1, y + 1, w - 2, h - 2
  end

  if w <= 0 or h <= 0 then return end

  local offset

  if lera.render_pass() == "remote" then
    offset = sc.offset()
    -- The render callback runs a second time per dirty frame when a
    -- WebSocket client is connected, at the CLIENT screen's width. Mutating
    -- the local cache/scroller from here would thrash the width-keyed
    -- wrapped cache and re-clamp the LOCAL user's scroll offset against the
    -- REMOTE row count, silently yanking a scrolled-back local view. So:
    -- build a throwaway wrapped list at the remote width instead, and
    -- render it through the untouched local offset. The remote viewer sees
    -- approximately the local scroll position, per spec.
    local list = build_transient(w, h + offset)
    draw_rows(x, y, w, h, function(screen_row)
      return list[1 + offset + (h - screen_row)]
    end)
  else
    wrapped_ensure(w)
    offset = sc.offset()
    draw_rows(x, y, w, h, function(screen_row)
      local idx = wrapped.last - offset - (h - screen_row)
      if idx >= wrapped.first then return wrapped.lines[idx] end
      return nil
    end)
  end

  -- Show scroll indicator if not at bottom
  if offset > 0 then
    local indicator = string.format(" [+%d] ", offset)
    ui.text(ui.rect(x + w - #indicator - 1, y + h - 1, #indicator, 1), indicator)
  end
end

-- Set max lines (history size)
function M.set_max_lines(n)
  config.max_lines = n or 32768
  -- Trim existing messages if needed
  while #messages > config.max_lines do
    local dead = table.remove(messages, 1)
    wrapped_trim_front(dead)
  end
end

-- Get max lines setting
function M.get_max_lines()
  return config.max_lines
end

-- Toggle timestamps on every message; format is an os.date() format string
-- (default "%H:%M"), color a name from the color table (default "white").
-- Returns the new enabled state.
function M.set_timestamps(enabled, format, color)
  config.timestamps = enabled and true or false
  if format then config.timestamp_format = format end
  if color and colors[color] then config.timestamp_color = color end
  invalidate_wrapped_formatting()
  return config.timestamps
end

-- Returns enabled, format, color
function M.timestamps()
  return config.timestamps, config.timestamp_format, config.timestamp_color
end

-- Body colour for lines that have a lead-in. A line without one keeps its type
-- colour throughout, so this never touches MIP chat lines.
function M.set_text_color(color)
  if not colors[color] then return false end
  config.text_color = color
  invalidate_wrapped_formatting()
  return true
end

function M.text_color()
  return config.text_color
end

--------------------------------------------------------------------------------
-- Persistence helpers
--------------------------------------------------------------------------------

-- Serialize line type config (only serializable parts, not functions)
local function serialize_line_types()
  local data = {}
  for id, cfg in pairs(line_types) do
    data[id] = {
      color = cfg.color,
      enabled = cfg.enabled,
      gags = cfg.gags or {},
      label = cfg.label,
      command = cfg.command,
    }
  end
  return data
end

-- Restore line type config from saved data
local function restore_line_types(data)
  if not data then return end
  for id, saved in pairs(data) do
    if line_types[id] then
      -- Update existing type
      if saved.color then line_types[id].color = saved.color end
      if saved.enabled ~= nil then line_types[id].enabled = saved.enabled end
      if saved.gags then line_types[id].gags = saved.gags end
      if saved.label then line_types[id].label = saved.label end
    else
      -- Create new chat type (only for chat_* types)
      if id:match("^chat_") then
        line_types[id] = {
          color = saved.color or config.default_color,
          enabled = saved.enabled ~= false,
          gags = saved.gags or {},
          label = saved.label or id:sub(6),  -- Remove "chat_" prefix
          command = saved.command or id:sub(6),
          prefix = default_chat_prefix,
        }
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Plugin lifecycle
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Command
--------------------------------------------------------------------------------

local function print_source()
  local st = source_status()
  print("[chat] source: " .. st.active .. " (" .. st.qualifier .. ")")
  print("[chat] mip: " .. st.mip_count .. " messages    gmcp: " ..
        st.gmcp_count .. " mapped, " .. st.gmcp_unmapped .. " unmapped")
  if st.last_unmapped then
    print("[chat] last unmapped: " .. st.last_unmapped.package ..
          " (fields: " .. st.last_unmapped.fields .. ")")
  end
end

local function chat_help()
  print("Chat monitor commands:")
  print("  /chat source [mip|gmcp|auto] - Show or pin the channel source")
  print("  /chat spacing on|report|off - Temporary metadata-only spacing diagnostics")
  print("  /chat padding [on|off] - Compact internal 8+ spaces in new single-line prose (default on)")
  print("  /chat types           - List all chat line types")
  print("  /chat toggle <type>   - Toggle a line type on/off")
  print("  /chat enable <type>   - Enable a line type")
  print("  /chat disable <type>  - Disable a line type")
  print("  /chat color <type> <color> - Set color for a type")
  print("  /chat gag <type> <pattern> - Add a gag pattern")
  print("  /chat ungag <type> <pattern> - Remove a gag pattern")
  print("  /chat gags <type>     - List gags for a type")
  print("  /chat clear           - Clear all chat messages")
  print("")
  print("Colors: black, red, green, yellow, blue, magenta, cyan, white")
  print("        bright_black, bright_red, bright_green, etc.")
end

local function chat_command(args)
  local parts = {}
  for word in tostring(args or ""):gmatch("%S+") do parts[#parts + 1] = word end
  local subcmd = (parts[1] or ""):lower()

  if subcmd == "" or subcmd == "help" then
    chat_help()
  elseif subcmd == "spacing" then
    spacing_command(parts[2], parts[3])
  elseif subcmd == "padding" then
    if parts[3] or (parts[2] and parts[2] ~= "on" and parts[2] ~= "off") then
      return print("Usage: /chat padding [on|off]")
    end
    if parts[2] then config.padding = parts[2] == "on" end
    print("[chat] padding: " .. (config.padding and "on" or "off") .. "; new single-line prose only")
  elseif subcmd == "source" then
    if parts[2] then
      local ok, err = M.set_source(parts[2]:lower())
      if not ok then
        print("[chat] " .. err)
        return
      end
    end
    print_source()
  elseif subcmd == "types" then
    local types = M.list_types()
    print("Chat line types:")
    for _, item in ipairs(types) do
      local status = item.enabled and "ON" or "OFF"
      local gags = item.gag_count > 0 and (" [" .. item.gag_count .. " gags]") or ""
      print(string.format("  %-15s %-12s %s (%s)%s",
        item.id, item.color, status, item.label, gags))
    end
  elseif subcmd == "toggle" then
    local type_id = parts[2]
    if not type_id then return print("Usage: /chat toggle <type>") end
    local enabled = M.toggle(type_id)
    if enabled ~= nil then
      print(type_id .. " is now " .. (enabled and "enabled" or "disabled"))
    else
      print("Unknown type: " .. type_id)
    end
  elseif subcmd == "enable" then
    local type_id = parts[2]
    if not type_id then return print("Usage: /chat enable <type>") end
    print(M.enable(type_id) and (type_id .. " enabled") or ("Unknown type: " .. type_id))
  elseif subcmd == "disable" then
    local type_id = parts[2]
    if not type_id then return print("Usage: /chat disable <type>") end
    print(M.disable(type_id) and (type_id .. " disabled") or ("Unknown type: " .. type_id))
  elseif subcmd == "color" then
    local type_id, color = parts[2], parts[3]
    if not type_id or not color then return print("Usage: /chat color <type> <color>") end
    if M.set_color(type_id, color) then
      print(type_id .. " color set to " .. color)
    else
      print("Failed - unknown type or invalid color")
    end
  elseif subcmd == "gag" then
    local type_id, pattern = parts[2], parts[3]
    if not type_id or not pattern then return print("Usage: /chat gag <type> <pattern>") end
    if M.add_gag(type_id, pattern) then
      print("Added gag '" .. pattern .. "' to " .. type_id)
    else
      print("Unknown type: " .. type_id)
    end
  elseif subcmd == "ungag" then
    local type_id, pattern = parts[2], parts[3]
    if not type_id or not pattern then return print("Usage: /chat ungag <type> <pattern>") end
    print(M.remove_gag(type_id, pattern)
      and ("Removed gag '" .. pattern .. "' from " .. type_id) or "Gag not found")
  elseif subcmd == "gags" then
    local type_id = parts[2]
    if not type_id then return print("Usage: /chat gags <type>") end
    local gags = M.list_gags(type_id)
    if #gags == 0 then
      print("No gags for " .. type_id)
    else
      print("Gags for " .. type_id .. ":")
      for index, gag in ipairs(gags) do print("  " .. index .. ". " .. gag) end
    end
  elseif subcmd == "clear" then
    M.clear()
    print("Chat cleared")
  else
    print("Unknown subcommand: " .. subcmd)
    print("Type /chat help for usage")
  end
end

-- Hosted mode registers its own /chat (scripts/hosted/commands.lua) before any
-- plugin loads, and a plugin cannot replace a profile-owned command. Claiming
-- it only when it is free gives local profiles the same interface without
-- fighting hosted for the name.
local function register_command()
  if not command then return end
  if command.get("/chat") then return end

  local id, err = command.register({
    name = "/chat",
    usage = "/chat <subcommand>",
    summary = "Manage the chat monitor",
    description = "List and configure chat types, colors, gags and messages, "
      .. "and choose whether channel lines come from MIP or GMCP.",
    accepts_args = true,
    handler = chat_command,
  })
  if id then
    command_id = id
  else
    print("[chat_monitor] command registration failed: " .. tostring(err))
  end
end

function M.on_load()
  -- Load saved data from disk
  store.load()
  local data = store.get()
  if data then
    -- Restore config
    if data.config then
      if data.config.max_lines then config.max_lines = data.config.max_lines end
      if data.config.default_color then config.default_color = data.config.default_color end
      if data.config.timestamps ~= nil then config.timestamps = data.config.timestamps end
      if data.config.timestamp_format then config.timestamp_format = data.config.timestamp_format end
      if data.config.timestamp_color then config.timestamp_color = data.config.timestamp_color end
      if data.config.text_color then config.text_color = data.config.text_color end
      if type(data.config.padding) == "boolean" then config.padding = data.config.padding end
      local mode = data.config.source_mode
      if mode == "auto" or mode == "mip" or mode == "gmcp" then
        source.mode = mode
        source.active = (mode == "gmcp") and "gmcp" or "mip"
      end
      -- Restored before the first line arrives, which is the whole point: MIP
      -- is ignored from the outset rather than after it has printed one.
      if data.config.gmcp_chat_seen then
        source.gmcp_seen = true
        if source.mode == "auto" then source.active = "gmcp" end
      end
    end
    -- Restore line type configurations
    restore_line_types(data.line_types)
    -- Restore message history
    if data.messages then
      messages = data.messages
      message_seq = data.message_seq or #messages
    end
    -- Restored messages carry stale (or absent) _rows bookkeeping; force a
    -- clean rebuild of the wrapped cache on first render.
    wrapped_reset()
  end


  -- Optional on older Lera. Inactive sessions do no capture-only traversal or
  -- formatting; each row checks again in case capture stops or fails midway.
  if recording and recording.source_active and recording.source_register
      and recording.source_upsert and recording.source_reset and recording.source_retire
      and recording.source_active() then
    recording_source = recording.source_register("chat", "Chat")
    record_history()
  end

  -- Register MIP handlers
  table.insert(mip_handlers, mip.on("BAB", handle_tell))
  table.insert(mip_handlers, mip.on("BAG", handle_emote))
  table.insert(mip_handlers, mip.on("CAA", handle_chat))

  -- One GMCP subscription: dot-boundary matching delivers everything under
  -- Comm, so Comm.Channel.Text arrives here along with anything else the
  -- server sends under that package.
  local gmcp_id = gmcp.on("Comm", handle_gmcp_comm)
  if gmcp_id then table.insert(gmcp_handlers, gmcp_id) end

  register_push_triggers()
  register_command()
end

-- The latch belongs to a connection: a reconnect (or a different server) must
-- re-prove GMCP rather than inherit the last session's answer. The counters
-- describe the session too, so they reset with it.
function M.on_disconnect()
  spacing_enabled, spacing_records = false, {}
  -- The per-connection latch goes, the memory of having seen GMCP does not:
  -- otherwise every reconnect re-earns its duplicate first line.
  if source.mode == "auto" then
    source.active = source.gmcp_seen and "gmcp" or "mip"
  end
  source.mip_count = 0
  source.gmcp_count = 0
  source.gmcp_unmapped = 0
  source.last_unmapped = nil
end

function M.on_setup()
  get_push_notify()
end

function M.on_unload()
  spacing_enabled, spacing_records = false, {}
  for _, id in ipairs(push_trigger_ids) do trigger.remove(id) end
  push_trigger_ids = {}
  pushn = nil

  -- Unregister protocol handlers
  for _, handler_id in ipairs(mip_handlers) do
    mip.off(handler_id)
  end
  mip_handlers = {}

  for _, handler_id in ipairs(gmcp_handlers) do
    pcall(gmcp.remove, handler_id)
  end
  gmcp_handlers = {}

  -- The loader drops a plugin's commands on unload; unregistering here keeps a
  -- manual reload from colliding with its own leftover record.
  if command and command_id then
    pcall(command.unregister, command_id)
    command_id = nil
  end

  -- Save data to disk
  store.set({
    config = {
      max_lines = config.max_lines,
      default_color = config.default_color,
      timestamps = config.timestamps,
      timestamp_format = config.timestamp_format,
      timestamp_color = config.timestamp_color,
      text_color = config.text_color,
      padding = config.padding,
      source_mode = source.mode,
      gmcp_chat_seen = source.gmcp_seen,
    },
    line_types = serialize_line_types(),
    messages = messages,
    message_seq = message_seq,
  })
  store.save()
  if recording_source then
    recording.source_retire(recording_source)
    recording_source = nil
  end
end

return M
