-- Portal string.split parity: pattern separator, empty fields preserved,
-- a trailing separator yields a trailing empty field.
local util = {}

function util.split(s, sep)
  local out = {}
  local pos = 1
  while true do
    local a, b = string.find(s, sep, pos)
    if not a then
      out[#out + 1] = string.sub(s, pos)
      return out
    end
    out[#out + 1] = string.sub(s, pos, a - 1)
    pos = b + 1
  end
end

-- Every unattended dispatch goes through here rather than calling mud.send()
-- directly. An empty or whitespace-only command is not a no-op at the MUD: the
-- parser answers "There is no reason to '' here.", which is what an automation
-- with a half-built command string produces at a live prompt, with nothing in
-- the client to say which automation did it.
--
-- Returns true if the command went out. Callers that track a sent command
-- (state machines waiting on a confirmation) must branch on the return value
-- rather than assume the send happened.
function util.send(cmd, who)
  if type(cmd) ~= "string" or cmd:match("^%s*$") then
    print("[vik] refused an empty command from " .. tostring(who or "?")
          .. " (" .. tostring(cmd) .. ")")
    return false
  end
  mud.send(cmd)
  return true
end

return util
