-- Files.List transport: path resolution, the directory cache, and (Task 5)
-- request/response with page accumulation.
--
-- Cache keys are absolute and resolved client-side. A request may carry a
-- relative path, but the same relative string means different directories from
-- different cwds, so it cannot be a key. The response echoes the path the
-- server resolved, which is reconciled against the key when the reply lands.

local M = {}

local cache = {}
local current = nil     -- tracked cwd, absolute
local home_dir = nil    -- learned from the first cwd of a connection
local is_available = false
local inflight = {}     -- absolute path -> true while a page is outstanding
local waiters = {}      -- absolute path -> array of callbacks
-- Every request sent, oldest first: { seed = true } for a bodyless "where am
-- I", { path = key } otherwise. The MUD answers Files.List requests in the
-- order they arrive, so each reply is matched to the request it answers.
--
-- This replaced a single seed_pending flag. With two quick cds the flag was
-- set once for two "where am I" requests: the FIRST reply (the directory you
-- had already left) consumed it and moved the pane there, and the second --
-- the directory you were actually in -- found no flag and was ignored. The
-- pane stayed on the old directory until the next cd.
local outstanding = {}

-- ---- path arithmetic ------------------------------------------------------

function M.normalize(path)
  if type(path) ~= "string" or path == "" then return nil end
  local absolute = path:sub(1, 1) == "/"
  local parts = {}
  for piece in path:gmatch("[^/]+") do
    if piece == ".." then
      -- ".." cannot escape root. The daemon rejects any path containing ".."
      -- outright, so it must never reach the wire; collapsing here is what
      -- keeps that true.
      if #parts > 0 then parts[#parts] = nil end
    elseif piece ~= "." then
      parts[#parts + 1] = piece
    end
  end
  local joined = table.concat(parts, "/")
  if absolute then return "/" .. joined end
  return joined
end

-- Absolute path for a word's directory part, or nil when it cannot be resolved
-- yet (no cwd, or a "~" before home is known).
function M.resolve(dir, cwd, home)
  if type(dir) ~= "string" then return nil end

  if dir:sub(1, 1) == "~" then
    if not home then return nil end
    local rest = dir:sub(2)
    if rest == "" then return home end
    return M.normalize(home .. "/" .. rest)
  end

  if dir:sub(1, 1) == "/" then return M.normalize(dir) end

  if not cwd then return nil end
  if dir == "" then return M.normalize(cwd) end
  return M.normalize(cwd .. "/" .. dir)
end

-- ---- session state --------------------------------------------------------

function M.reset()
  cache = {}
  current = nil
  home_dir = nil
  is_available = false
  inflight = {}
  waiters = {}
  outstanding = {}
end

-- learn_home is passed only by the seed response, which is the server telling
-- us where the wizard is (current_path is "players/<name>" at logon,
-- secure/pinc/logon.h:1637). It used to be "the first directory seen in a
-- connection", which meant any line that reached set_cwd could define home --
-- and a prompt drawing a rule line ("/-----\") reaches it, because that is a
-- slash followed by non-space characters like any other path.
function M.set_cwd(path, learn_home)
  local resolved = M.normalize(path)
  if not resolved then return end
  current = resolved
  if learn_home and not home_dir then home_dir = resolved end
end

function M.cwd() return current end
function M.home() return home_dir end

function M.set_available(value) is_available = value and true or false end
function M.available() return is_available end

-- ---- cache ----------------------------------------------------------------

function M.lookup(path) return cache[path] end
function M.store(path, entry) cache[path] = entry end
function M.invalidate(path)
  cache[path] = nil
  inflight[path] = nil
end

-- ---- requests and responses -----------------------------------------------
--
-- Request/response only: nothing pushes Files.List, there is no subscription to
-- hold and no delta to apply. The client's request IS its consent.

local function fire(path, entry)
  local list = waiters[path]
  if not list then return end
  waiters[path] = nil
  for i = 1, #list do
    local ok, err = pcall(list[i], entry)
    if not ok then print("[wizard] completion callback error: " .. tostring(err)) end
  end
end

-- page defaults to 1. A nil path sends a bodyless request, which the mudlib
-- answers for the wizard's own current directory -- the "where am I" case.
local function send(path, page)
  local body = {}
  if path then
    body.path = path
    body.page = page or 1
  end
  outstanding[#outstanding + 1] = path and { path = path } or { seed = true }
  return gmcp.send("Files.List", body)
end

-- Which request does a reply for `path` answer? Returns "seed", "path" or nil
-- (unsolicited). A seed answers whatever directory it echoes; a targeted
-- request answers only its own path. Anything queued ahead of the match never
-- got a reply of its own (a dropped message) and is discarded, so one lost
-- reply cannot shift every later one onto the wrong request.
local function take_request(path)
  for i = 1, #outstanding do
    local req = outstanding[i]
    if req.seed or req.path == path then
      for _ = 1, i do table.remove(outstanding, 1) end
      return req.seed and "seed" or "path"
    end
  end
  return nil
end

-- A seed reply is only the answer to "where am I" if no newer seed is still
-- waiting. When one is, the wizard has cd'd again since this was asked, and
-- the newer reply is on its way with the directory they are actually in.
local function newer_seed_queued()
  for i = 1, #outstanding do
    if outstanding[i].seed then return true end
  end
  return false
end

local function seed_answered(path)
  if not newer_seed_queued() then M.set_cwd(path, true) end
end

function M.request(path, cb)
  local key = path and M.normalize(path) or nil

  if cb then
    if key then
      waiters[key] = waiters[key] or {}
      table.insert(waiters[key], cb)
    end
  end

  -- A fast second Tab must not duplicate an outstanding request. The waiter
  -- above is already queued, so the caller still gets its answer.
  if key and inflight[key] then return end
  if key then inflight[key] = true end

  send(key, 1)
end

-- Entries are plain strings when no fields were requested and {n=...} records
-- otherwise. Both shapes are valid, and which one arrives is determined by the
-- request, so both are read here.
local function entry_names(list)
  local out = {}
  if type(list) ~= "table" then return out end
  for i = 1, #list do
    local item = list[i]
    if type(item) == "string" then
      out[#out + 1] = item
    elseif type(item) == "table" and type(item.n) == "string" then
      out[#out + 1] = item.n
    end
  end
  return out
end

local function append(dest, src)
  for i = 1, #src do dest[#dest + 1] = src[i] end
end

function M.on_message(_, data)
  if type(data) ~= "table" then return end
  -- The echoed path is the key: the server is authoritative about what it
  -- resolved, and a relative request resolves to something we only guessed.
  local path = M.normalize(data.path)
  if not path then return end

  if data.error then
    inflight[path] = nil
    local entry = { dirs = {}, files = {}, complete = true,
                    truncated = false, error = data.error }
    M.store(path, entry)
    -- A seed that errors still answers "where am I": the echoed path is the
    -- wizard's own directory, and only the LISTING was refused (the daemon
    -- gates on an ACL glob, so /players comes back "denied" while the cd
    -- itself succeeded). Consume the seed anyway and let the pane show the
    -- reason.
    if take_request(path) == "seed" then seed_answered(path) end
    fire(path, entry)
    if ui and ui.dirty then ui.dirty() end
    return
  end

  -- The bodyless request is the "where am I" request: its echoed path is the
  -- wizard's own working directory. A Tab-driven request for some other
  -- directory must never move the cwd, so only the reply to a seed does.
  if take_request(path) == "seed" then seed_answered(path) end

  local page = tonumber(data.page) or 1
  local pages = tonumber(data.pages) or 1

  -- Page 1 starts the entry over. Pages after it accumulate onto whatever page
  -- 1 began; a stray later page with no entry is dropped rather than producing
  -- a listing with a hole in it.
  local entry
  if page <= 1 then
    entry = { dirs = {}, files = {}, complete = false, truncated = false }
  else
    entry = M.lookup(path)
    if not entry or entry.complete then return end
  end

  append(entry.dirs, entry_names(data.dirs))
  append(entry.files, entry_names(data.files))
  if data.truncated == 1 or data.truncated == true then entry.truncated = true end

  if page >= pages then
    entry.complete = true
    inflight[path] = nil
  end

  M.store(path, entry)

  if entry.complete then
    fire(path, entry)
  else
    -- Dirs and files are sliced as ONE sequence, so the remaining pages carry
    -- the rest of both arrays and have to be asked for in order.
    inflight[path] = true
    send(path, page + 1)
  end

  if ui and ui.dirty then ui.dirty() end
end

return M
