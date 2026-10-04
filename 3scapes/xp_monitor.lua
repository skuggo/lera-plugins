-- XP Monitor. Fed by the MUD's Char.XP GMCP package (secure/pinc/gmcp.h),
-- which carries what `xp` prints -- total, to_next, to_spend, gain30,
-- per_hour, eta_secs, maxed, modifier -- and is pushed on every kill that
-- pays the player, plus once on login and once on subscribe.
--
-- This used to scrape five triggers off the `xp` command's output, which meant
-- the numbers were only ever as fresh as the last time the player typed `xp`,
-- and the per-kill list could only grow when they did. Registering the package
-- IS the subscription request: Lera derives Core.Supports.Set from the names
-- passed to gmcp.on().
local M = { name = "xp_monitor", version = "2.0", priority = 45 }
M.window_launcher = { label = "XP Monitor", compact_label = "XP", order = 20 }
local command = require("command")
local state = { total = 0, spend = 0, gain30 = 0, to_next = 0, per_hour = 0, eta = 0,
                modifier = 0, baseline = 0, reset_at = 0, max = false, mode = "stats", kills = {} }
local gmcp_id, command_id, kill_listener, popup_open = nil, nil, nil, false
local pending_kill, seen_frame
-- Forward local: window.on_pointer() below is defined before changed() and
-- would otherwise capture a nil global instead of it -- clicking [Stats] or
-- [Kills] raised "attempt to call a nil value" on the old file for that reason.
local changed
local function comma(n) local s=tostring(math.floor(n or 0)); repeat s,k=s:gsub("^(%-?%d+)(%d%d%d)", "%1,%2") until k==0; return s end
local function clock(n) n=math.max(0, math.floor(n or 0)); return string.format("%02d:%02d:%02d", math.floor(n/3600), math.floor(n/60)%60, n%60) end
local function elapsed() return clock(os.time()-(state.reset_at or 0)) end
-- eta_secs is the server's own arithmetic (to_next*3600/per_hour), so the two
-- agree with the `xp` command instead of each rounding differently.
local function eta_text()
  if state.max then return "\27[93mMaximum level\27[0m" end
  if (state.eta or 0) <= 0 then return "\27[2mLevel in:    --\27[0m" end
  local h, m = math.floor(state.eta/3600), math.floor(state.eta/60)%60
  return "\27[96mLevel in:    \27[92m"..(h > 0 and (h.."h "..m.."m") or (m.."m")).."\27[0m"
end
local function save() store.set(state); store.save() end
local function lines(w)
  local out = { "\27[96m[Stats] [Kills] [Close]\27[0m" }
  if state.mode == "kills" then
    local total=0; for _, k in ipairs(state.kills) do total=total+k.xp end
    out[#out+1]=string.format("\27[96m%d kills\27[0m  Total \27[92m%s\27[0m  Avg \27[92m%s\27[0m", #state.kills, comma(total), comma(#state.kills>0 and total/#state.kills or 0))
    for _, k in ipairs(state.kills) do out[#out+1]=string.format("\27[93m%-24s\27[0m +\27[92m%s XP\27[0m", k.enemy:sub(1,24), comma(k.xp)) end
    if #state.kills==0 then out[#out+1]="\27[2mNo kills recorded yet\27[0m" end
  else
    out[#out+1]="\27[96mTotal XP:    \27[0m"..comma(state.total)
    out[#out+1]="\27[96mXP to Spend: \27[0m"..comma(state.spend)
    out[#out+1]=state.max and "\27[93mMaximum level\27[0m" or ("\27[96mTo Next:     \27[0m"..comma(state.to_next))
    out[#out+1]="\27[96m30min Gain:  \27[92m"..comma(state.gain30).."\27[0m"
    out[#out+1]="\27[96mXP / hour:   \27[92m"..comma(state.per_hour).."\27[0m"
    out[#out+1]=eta_text()
    out[#out+1]="\27[96mSince Reset: \27[92m"..comma(state.total-state.baseline).."\27[0m ("..elapsed()..")"
    if (state.modifier or 0) > 0 then out[#out+1]="\27[92mXP bonus active\27[0m"
    elseif (state.modifier or 0) < 0 then out[#out+1]="\27[91mXP penalty active\27[0m" end
    if not seen_frame then out[#out+1]="\27[2mWaiting for Char.XP (relog if the MUD just reloaded)\27[0m" end
  end
  out[#out+1]=""; out[#out+1]="\27[2m/xp [kills|stats|reset]\27[0m"; return out
end
local window = { render=function(rect) local ls=lines(rect:w()); for i,l in ipairs(ls) do if i>rect:h() then break end; ui.text_ansi(ui.rect(rect:x(),rect:y()+i-1,rect:w(),1),l) end end }
function window.on_pointer(event)
  if event.kind ~= "down" or event.button ~= "left" or event.y ~= 0 then return false end
  if event.x >= 0 and event.x < 7 then state.mode = "stats"
  elseif event.x >= 8 and event.x < 15 then state.mode = "kills"
  elseif event.x >= 16 and event.x < 23 then M.close(); return true
  else return false end
  changed()
  return true
end
local function toggle() local wm=require("wm"); if popup_open and wm.popup.is_open() then wm.popup.close(); popup_open=false else wm.popup.open(window,{title="XP Monitor",width=.5,height=.42,on_close=function() popup_open=false end}); popup_open=true end end
changed = function() if popup_open then ui.dirty() end; save() end
local function close_popup()
  local wm = require("wm")
  if popup_open and wm.popup.is_open() then wm.popup.close() end
  popup_open = false
end

-- One frame is one complete snapshot: every key ships every time, so a missing
-- key means a malformed frame, not "unchanged", and the old value is kept.
local function on_frame(_, data)
  if type(data) ~= "table" then return end
  local n = tonumber(data.xp)
  if n then
    -- Attribution needs a previous reading to subtract from. The first frame
    -- after a load has none (state.total is whatever was saved, or 0), so it
    -- only seeds -- otherwise a stale pending_kill would be credited with the
    -- character's entire lifetime xp.
    local gain = seen_frame and (n - (state.total or 0)) or 0
    state.total = n
    if state.baseline == 0 then state.baseline = n; state.reset_at = os.time() end
    if gain > 0 and pending_kill then
      table.insert(state.kills, 1, { enemy = pending_kill, xp = gain })
      if #state.kills > 20 then table.remove(state.kills) end
      pending_kill = nil
    end
  end
  state.spend    = tonumber(data.to_spend) or state.spend
  state.gain30   = tonumber(data.gain30)   or state.gain30
  state.to_next  = tonumber(data.to_next)  or state.to_next
  state.per_hour = tonumber(data.per_hour) or state.per_hour
  state.eta      = tonumber(data.eta_secs) or state.eta
  state.modifier = tonumber(data.modifier) or 0
  state.max      = (tonumber(data.maxed) or 0) == 1
  seen_frame = true
  changed()
end
M.on_gmcp = on_frame   -- exposed for tests and for profiles that fan GMCP out themselves

function M.is_open() return popup_open end
function M.open() if not popup_open then toggle() end end
function M.close() close_popup() end
function M.toggle() toggle() end

function M.on_load()
  store.load(); local saved=store.get(); if type(saved)=="table" then state=saved; state.kills=state.kills or {} end
  gmcp_id = gmcp.on("Char.XP", on_frame)
  local k=plugin.get("kill_trigger"); if k and k.on_monster_died then kill_listener=k.on_monster_died(function(_,victim) pending_kill=victim end) end
  command_id=assert(command.register({name="/xp",usage="/xp [stats|kills|reset]",summary="XP monitor",accepts_args=true,handler=function(a) local x=(a or ""):match("%S+") or ""; if x=="kills" or x=="stats" then state.mode=x; changed(); if not popup_open then toggle() end elseif x=="reset" then state.baseline=state.total; state.reset_at=os.time(); state.kills={}; changed() else toggle() end end}))
end
function M.on_unload() close_popup(); if gmcp_id then pcall(gmcp.remove, gmcp_id) end; if command_id then command.unregister(command_id) end; local k=plugin.get("kill_trigger"); if k and kill_listener then k.remove_kill_listener(kill_listener) end end

return M
