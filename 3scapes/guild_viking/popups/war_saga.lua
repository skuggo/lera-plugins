-- popups/war_saga.lua -- the war and battle sagas, in full and scrollable.
--
-- saga.h keeps two ring buffers on the gobj, forty beats each, and speaks
-- every beat once on the Viking-War / Viking-Battle channel as it happens.
-- 'vwar log' and 'vbattle log' replay them in game; this is the same content
-- in the pane, where popups.lua's wrapper gives it scrolling for free -- the
-- module only has to produce lines.
--
-- The entries arrive as the server's own "ts|tone|text" strings (see
-- handlers/kingdom.lua). The text may itself contain "|", so only the first
-- two separators are significant.
local pagelib = require("pagelib")
local state = require("state")

local S = state.S
local C = pagelib.C
local RESET = pagelib.RESET

local M = {}
M.title = "War Saga"

-- saga.h's own tone -> colour mapping, kept in step with _saga_tone_col().
local TONE = {
  triumph = C.bright_green,
  blood   = C.yellow,
  loss    = C.bright_red,
  omen    = C.bright_magenta,
}

-- saga.h's _saga_age(), same thresholds, so a beat reads the same age here
-- as it does in game.
local function age(ts, now)
  local d = (now or os.time()) - (ts or 0)
  if d < 60 then return "now" end
  if d < 3600 then return math.floor(d / 60) .. "m" end
  if d < 86400 then return math.floor(d / 3600) .. "h" end
  return math.floor(d / 86400) .. "d"
end

-- Entries arrive as { t, tone, text } records (the server splits them, so
-- the text is bounded on its own against PROTOCOL_GUILD_STRING_MAX rather
-- than sharing one budget with the timestamp and tone). A plain string is
-- still accepted so a frame sent by an older gobj still renders.
function M.parse(entry)
  if type(entry) == "table" then
    return tonumber(entry.t) or 0, tostring(entry.tone or ""), tostring(entry.text or "")
  end
  if type(entry) ~= "string" then return nil end
  local ts, tone, text = entry:match("^(%d+)|([^|]*)|(.*)$")
  if not ts then return nil end
  return tonumber(ts), tone, text
end

-- Newest last, matching saga_render()'s "oldest first" order in game.
-- `limit` > 0 keeps only the most recent that many.
function M.entries(cat, limit)
  -- Explicit, not "and/or": when cat is "battle" and S.saga_battle is nil,
  -- `(true) and nil or S.saga_war` yields the WAR list, and the battle
  -- section silently renders the war saga's beats.
  local src
  if cat == "battle" then src = S.saga_battle else src = S.saga_war end
  local out = {}
  for _, e in ipairs(src or {}) do
    local ts, tone, text = M.parse(e)
    if ts then out[#out + 1] = { ts = ts, tone = tone, text = text } end
  end
  if limit and limit > 0 and #out > limit then
    local trimmed = {}
    for i = #out - limit + 1, #out do trimmed[#trimmed + 1] = out[i] end
    return trimmed
  end
  return out
end

-- One rendered line per beat: "[ age] text", aged and toned like the box the
-- guild prints in game.
function M.render(cat, width, limit)
  local out = {}
  local rows = M.entries(cat, limit)
  if #rows == 0 then
    out[#out + 1] = pagelib.trunc(C.dim .. "  No deeds recorded yet." .. RESET, width)
    return out
  end
  local now = os.time()
  for _, r in ipairs(rows) do
    local col = TONE[r.tone] or C.white
    out[#out + 1] = pagelib.trunc(string.format("%s[%3s]%s %s%s%s",
      C.dim, age(r.ts, now), RESET, col, r.text, RESET), width)
  end
  return out
end

function M.lines(width)
  width = width or 80
  local out = {}
  out[#out + 1] = pagelib.header(width, "War Saga")
  for _, l in ipairs(M.render("war", width)) do out[#out + 1] = l end
  out[#out + 1] = ""
  out[#out + 1] = pagelib.header(width, "Battle Saga")
  for _, l in ipairs(M.render("battle", width)) do out[#out + 1] = l end
  return out
end

return M
