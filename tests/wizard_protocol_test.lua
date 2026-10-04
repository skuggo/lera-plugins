-- wizard path resolution and directory cache. Run from the lera-plugins repo
-- root with LERA_ROOT pointing at a built Lera checkout.
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

-- Recorded rather than swallowed: a test that asserts nothing was sent has to
-- be able to see that nothing was sent.
local sent = {}
gmcp = {
  on = function() return 1 end,
  send = function(pkg, data) sent[#sent + 1] = { pkg = pkg, data = data }; return true end,
  enabled = function() return true end,
}
ui = { dirty = function() end }

local protocol = require("protocol")

-- ---- normalize ------------------------------------------------------------

check("normalize: plain path", protocol.normalize("/players/simon") == "/players/simon")
check("normalize: collapses double slashes",
      protocol.normalize("/players//simon") == "/players/simon")
check("normalize: drops a trailing slash",
      protocol.normalize("/players/simon/") == "/players/simon")
check("normalize: root stays root", protocol.normalize("/") == "/")
check("normalize: removes .", protocol.normalize("/players/./simon") == "/players/simon")
check("normalize: resolves ..", protocol.normalize("/players/simon/..") == "/players")
check("normalize: .. cannot escape root", protocol.normalize("/../..") == "/")

-- ---- resolve --------------------------------------------------------------

local CWD = "/players/simon"
local HOME = "/players/simon"

check("resolve: empty dir is the cwd", protocol.resolve("", CWD, HOME) == CWD)
check("resolve: absolute wins", protocol.resolve("/open/", CWD, HOME) == "/open")
check("resolve: relative joins the cwd",
      protocol.resolve("areas/", CWD, HOME) == "/players/simon/areas")
check("resolve: .. walks up", protocol.resolve("../", CWD, HOME) == "/players")
check("resolve: tilde is home", protocol.resolve("~/areas/", CWD, HOME) == "/players/simon/areas")
check("resolve: bare tilde is home", protocol.resolve("~", CWD, HOME) == HOME)
check("resolve: tilde without a known home is unresolvable",
      protocol.resolve("~/areas/", CWD, nil) == nil,
      "the home directory is learned from the first response of a connection")
check("resolve: no cwd is unresolvable", protocol.resolve("areas/", nil, HOME) == nil)

-- ---- cwd / home / availability -------------------------------------------

protocol.reset()
check("cwd: unset before any response", protocol.cwd() == nil)
check("home: unset before any response", protocol.home() == nil)
check("available: false before Core.Supported", protocol.available() == false)

protocol.set_available(true)
check("available: set true", protocol.available() == true)

protocol.set_cwd("/players/simon")
check("cwd: set from a cd confirmation", protocol.cwd() == "/players/simon")
-- Home is the server's answer to "where am I", not whatever reached set_cwd
-- first: a cd confirmation is a line off the screen, and a prompt can put a
-- path-shaped line there.
check("home: a cd confirmation does not establish home", protocol.home() == nil)

protocol.set_cwd("/players/simon", true)
check("home: the seed establishes it", protocol.home() == "/players/simon")

protocol.set_cwd("/open")
check("cwd: a later cd moves the cwd", protocol.cwd() == "/open")
check("home: a later cd does not move home", protocol.home() == "/players/simon")

protocol.set_cwd("/later", true)
check("home: a second seed does not move home", protocol.home() == "/players/simon")

-- ---- cache ---------------------------------------------------------------

check("lookup: unknown path is nil", protocol.lookup("/nowhere") == nil)

protocol.store("/open", { dirs = { "a" }, files = { "b.c" }, complete = true })
do
  local e = protocol.lookup("/open")
  check("lookup: stored entry comes back", e ~= nil and e.complete == true)
  check("lookup: entry carries its listing",
        e ~= nil and e.dirs[1] == "a" and e.files[1] == "b.c")
end

protocol.invalidate("/open")
check("invalidate: drops the entry", protocol.lookup("/open") == nil)

protocol.store("/open", { dirs = {}, files = {}, complete = true })
protocol.reset()
check("reset: clears the cache", protocol.lookup("/open") == nil)
check("reset: clears the cwd", protocol.cwd() == nil)
check("reset: clears home", protocol.home() == nil)
check("reset: clears availability",
      protocol.available() == false,
      "the server drops its state on disconnect, so ours cannot outlive it")

check("no traffic: resolution and caching never touch the wire",
      #sent == 0,
      #sent .. " message(s) sent")

-- ---- requests -------------------------------------------------------------

protocol.reset()
protocol.set_cwd("/players/simon")
sent = {}
-- The stub above closes over the original `sent`; rebind it so the send
-- function writes to the table these cases read.
gmcp.send = function(pkg, data) sent[#sent + 1] = { pkg = pkg, data = data }; return true end

protocol.request(nil)
check("request: a bodyless request asks Files.List with an empty body",
      #sent == 1 and sent[1].pkg == "Files.List"
        and type(sent[1].data) == "table" and sent[1].data.path == nil,
      "sent " .. #sent)

sent = {}
protocol.request("/open")
check("request: a path request carries the path and page 1",
      #sent == 1 and sent[1].data.path == "/open" and sent[1].data.page == 1,
      sent[1] and tostring(sent[1].data.path))

sent = {}
protocol.request("/open")
check("request: a second request for an in-flight path is not resent",
      #sent == 0,
      "an outstanding request must not be duplicated by a fast second Tab")

protocol.reset()
sent = {}
local dedup_fired = {}
protocol.request("/dedup", function(e) dedup_fired[#dedup_fired + 1] = e end)
protocol.request("/dedup", function(e) dedup_fired[#dedup_fired + 1] = e end)
check("request: an in-flight duplicate sends once", #sent == 1, #sent .. " sent")
protocol.on_message("Files.List", {
  path = "/dedup", dirs = { "z" }, files = {}, page = 1, pages = 1,
})
check("request: BOTH waiters fire on the single response",
      #dedup_fired == 2,
      "a queue-after-early-return bug drops the second caller silently; got "
        .. #dedup_fired)

-- ---- responses ------------------------------------------------------------

protocol.reset()
protocol.set_cwd("/players/simon")
sent = {}

protocol.on_message("Files.List", {
  path = "/open", dirs = { "sub" }, files = { "a.c" }, page = 1, pages = 1,
})
do
  local e = protocol.lookup("/open")
  check("response: a single page completes the entry",
        e ~= nil and e.complete == true)
  check("response: dirs and files land separately",
        e ~= nil and e.dirs[1] == "sub" and e.files[1] == "a.c")
  check("response: no truncation flag means not truncated",
        e ~= nil and e.truncated == false)
end

-- Records instead of names: the shape is request-determined and both are valid.
protocol.reset()
protocol.on_message("Files.List", {
  path = "/rec", dirs = { { n = "sub" } }, files = { { n = "a.c", s = 12 } },
  page = 1, pages = 1,
})
do
  local e = protocol.lookup("/rec")
  check("response: record entries are read through their n key",
        e ~= nil and e.dirs[1] == "sub" and e.files[1] == "a.c",
        e and tostring(e.dirs[1]))
end

-- Paging: dirs and files are ONE sequence, so page 2 can straddle the boundary.
protocol.reset()
sent = {}
protocol.on_message("Files.List", {
  path = "/big", dirs = { "d1", "d2" }, files = {}, page = 1, pages = 2,
})
do
  local e = protocol.lookup("/big")
  check("paging: an incomplete entry is not complete",
        e ~= nil and e.complete ~= true,
        "a common prefix over a partial listing is wrong invisibly")
  check("paging: the next page is requested automatically",
        #sent == 1 and sent[1].data.page == 2,
        "requested page " .. tostring(sent[1] and sent[1].data.page))
end

protocol.on_message("Files.List", {
  path = "/big", dirs = { "d3" }, files = { "f1.c" }, page = 2, pages = 2,
})
do
  local e = protocol.lookup("/big")
  check("paging: the last page completes the entry", e ~= nil and e.complete == true)
  check("paging: pages accumulate in order across the dirs boundary",
        e ~= nil and table.concat(e.dirs, ",") == "d1,d2,d3"
          and table.concat(e.files, ",") == "f1.c",
        e and table.concat(e.dirs, ","))
end

-- truncated
protocol.reset()
protocol.on_message("Files.List", {
  path = "/huge", dirs = {}, files = { "a" }, page = 1, pages = 1, truncated = 1,
})
check("response: the truncated flag is recorded",
      protocol.lookup("/huge").truncated == true)

-- errors
for _, code in ipairs({ "denied", "badpath", "nodir", "nopage" }) do
  protocol.reset()
  protocol.on_message("Files.List", { path = "/x", error = code })
  local e = protocol.lookup("/x")
  check("error: " .. code .. " is cached as an error",
        e ~= nil and e.error == code and e.complete == true,
        "an error is a settled answer, so it must not be retried on every Tab")
  check("error: " .. code .. " carries no listing",
        e ~= nil and #e.dirs == 0 and #e.files == 0)
end

-- callbacks
protocol.reset()
sent = {}
local fired = {}
protocol.request("/cb", function(entry) fired[#fired + 1] = entry end)
check("callback: not fired before the response arrives", #fired == 0)
protocol.on_message("Files.List", {
  path = "/cb", dirs = { "z" }, files = {}, page = 1, pages = 1,
})
check("callback: fired once the entry completes",
      #fired == 1 and fired[1].dirs[1] == "z",
      #fired .. " call(s)")

protocol.reset()
sent = {}
fired = {}
protocol.request("/cb2", function(entry) fired[#fired + 1] = entry end)
protocol.on_message("Files.List", { path = "/cb2", dirs = {}, files = {}, page = 1, pages = 2 })
check("callback: not fired on a partial listing", #fired == 0)
protocol.on_message("Files.List", { path = "/cb2", dirs = {}, files = {}, page = 2, pages = 2 })
check("callback: fired on the last page", #fired == 1)

protocol.reset()
fired = {}
protocol.request("/cb3", function(entry) fired[#fired + 1] = entry end)
protocol.on_message("Files.List", { path = "/cb3", error = "denied" })
check("callback: an error fires the callback too",
      #fired == 1 and fired[1].error == "denied",
      "a waiter must not hang on a refusal")

-- A reply for a path nobody asked about is still cached: the server echoes the
-- path IT resolved, which may differ from the key we requested under.
protocol.reset()
protocol.on_message("Files.List", {
  path = "/players/simon", dirs = { "a" }, files = {}, page = 1, pages = 1,
})
check("response: the echoed path is the cache key",
      protocol.lookup("/players/simon") ~= nil,
      "the server is authoritative about what it resolved")

-- Malformed payloads must not raise.
protocol.reset()
local ok = pcall(protocol.on_message, "Files.List", nil)
check("robustness: a nil payload does not raise", ok == true)
ok = pcall(protocol.on_message, "Files.List", { dirs = {}, files = {} })
check("robustness: a payload with no path does not raise", ok == true)

-- Finding 2: a raising callback must not take down the other waiters queued
-- on the same completion.
protocol.reset()
local survivor = {}
protocol.request("/boom", function() error("deliberate") end)
protocol.request("/boom", function(e) survivor[#survivor + 1] = e end)
protocol.on_message("Files.List", {
  path = "/boom", dirs = {}, files = {}, page = 1, pages = 1,
})
check("callback: a raising callback does not lose the other waiters",
      #survivor == 1,
      "got " .. #survivor)

-- Finding 3: truncated is sticky once any page reports it, not reset by a
-- later page that doesn't.
protocol.reset()
protocol.on_message("Files.List", {
  path = "/tr", dirs = { "a" }, files = {}, page = 1, pages = 2, truncated = 1,
})
protocol.on_message("Files.List", {
  path = "/tr", dirs = {}, files = { "b" }, page = 2, pages = 2,
})
check("paging: truncated persists once any page reports it",
      protocol.lookup("/tr").truncated == true)

-- On connect the plugin sends a bodyless Files.List; its echoed path IS the
-- wizard's working directory. Without this the pane never leaves "loading...".
protocol.reset()
sent = {}
protocol.request(nil)
protocol.on_message("Files.List", {
  path = "/players/simon", dirs = { "areas" }, files = {}, page = 1, pages = 1,
})
check("seed: a bodyless response sets the cwd",
      protocol.cwd() == "/players/simon", tostring(protocol.cwd()))
check("seed: it also establishes home", protocol.home() == "/players/simon")

-- A seed whose listing is REFUSED still answers "where am I". The daemon
-- gates listings on an ACL glob (daemon/gmcp_files_d.c), so a cd into a
-- directory the wizard may enter but not list -- /players -- answers
-- { path, error }. The pane must follow the cd and show the reason, and the
-- seed must be consumed so a later response is not mistaken for it.
protocol.reset()
sent = {}
protocol.set_cwd("/players/skuggis", true)
protocol.request(nil)
protocol.on_message("Files.List", { path = "/players", error = "denied" })
check("seed: an errored seed still moves the cwd",
      protocol.cwd() == "/players", tostring(protocol.cwd()))
check("seed: the reason is kept for the pane to show",
      (protocol.lookup("/players") or {}).error == "denied")
protocol.on_message("Files.List", {
  path = "/elsewhere", dirs = {}, files = {}, page = 1, pages = 1,
})
check("seed: a later response is not mistaken for the consumed seed",
      protocol.cwd() == "/players", tostring(protocol.cwd()))

-- A Tab-driven request for another directory must NOT move the cwd.
protocol.reset()
protocol.set_cwd("/players/simon")
protocol.request("/open")
protocol.on_message("Files.List", {
  path = "/open", dirs = {}, files = { "a.c" }, page = 1, pages = 1,
})
check("seed: a targeted response does not move the cwd",
      protocol.cwd() == "/players/simon",
      "a completion request must never relocate the wizard; got "
        .. tostring(protocol.cwd()))

print(failures == 0 and "ALL PASS" or (failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)
