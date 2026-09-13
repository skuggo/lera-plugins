-- Receipt evidence is connection-local, never restored as proof of freshness.
local S = require("state").S
local M = {}
function M.record(key)
  local now = os.time()
  S.herd_observed = S.herd_observed or {}
  local previous = S.herd_observed[key]
  S.herd_observed[key] = { at = now, seq = (previous and previous.seq or 0) + 1 }
  return now
end
return M
