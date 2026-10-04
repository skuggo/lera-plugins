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

-- Load a module that ships only in the PRIVATE plugin repo (3s-lera), which
-- carries this same base plus the auto* automation modules. In the public
-- repo those files are absent, and the sandbox's require() raises rather than
-- returning nil, so every call site that wants one has to come through here
-- and branch on the result.
--
-- The base is deliberately identical in both repos: only the presence of the
-- auto* files differs, so a diff between the two copies stays empty for every
-- file that is not an automation module.
function util.optional_require(name)
  local ok, mod = pcall(require, name)
  if ok and mod then return mod end
  return nil
end

-- Paged rosters (Guild.Roster staff and hird). A roster is too big for one
-- push, so the server sends part of it per push. It used to send rotating
-- `<name>_<n>` slice keys; it now sends ONE fixed key, `<name>_page` (an array
-- of records), with `<name>_from` naming the member index the window starts
-- at. A client that only knew `<name>_<n>` saw nothing at all -- an empty
-- hird, so Auto-War found no captain to train a company under.
--
-- Both shapes are accumulated, each the way its sender numbers it: pages by
-- member index, slices by slice index. A re-sent part replaces rather than
-- appends. The fields live on `acc`: acc.members and acc.slices.

-- Merge whatever parts of the roster `name` this frame carried into `acc`.
-- Returns true when it carried any.
function util.merge_roster(acc, parts, name)
  acc.members = acc.members or {}
  acc.slices = acc.slices or {}
  local carried = false
  local page = parts[name .. "_page"]
  if type(page) == "table" then
    local from = tonumber(parts[name .. "_from"]) or 0
    for i, r in ipairs(page) do acc.members[from + i - 1] = r end
    carried = true
  end
  for k, v in pairs(parts) do
    local idx = tostring(k):match("^" .. name .. "_(%d+)$")
    if idx and type(v) == "table" then
      acc.slices[tonumber(idx)] = v
      carried = true
    end
  end
  return carried
end

-- The roster's records in order. Pages win when any have arrived (that is what
-- the current server sends); otherwise the slices are stitched in index order.
-- Anything at or past `total` members (`slices` slices) is dropped, so a
-- roster that shrank leaves no stale tail. Parts not yet received are simply
-- absent: the list fills in over the first pushes.
function util.roster_records(acc, total, slices)
  local out = {}
  if next(acc.members or {}) ~= nil then
    for i in pairs(acc.members) do
      if i >= total then acc.members[i] = nil end
    end
    for i = 0, total - 1 do
      if acc.members[i] ~= nil then out[#out + 1] = acc.members[i] end
    end
    return out
  end
  for i in pairs(acc.slices or {}) do
    if i >= slices then acc.slices[i] = nil end
  end
  for i = 0, slices - 1 do
    for _, r in ipairs(acc.slices[i] or {}) do out[#out + 1] = r end
  end
  return out
end

return util
