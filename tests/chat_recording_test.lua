local root = assert(os.getenv("LERA_ROOT"), "LERA_ROOT is required")
package.path = "3scapes/?.lua;" .. root .. "/scripts/default/?.lua;" .. package.path
package.loaded.wm = {make_scroller=function() return {
  on_append=function() end, on_trim=function() end, scroll_to_bottom=function() end,
  following_tail=function() return true end, offset=function() return 0 end,
} end}
package.loaded.command = {get=function() return true end}
local stored, handlers, gmcp_handler, events = nil, {}, nil, {}
local active, fail_after, writes, queries, dates, next_source = true, nil, 0, 0, 0, 0
local sources, current = {}, nil
local function event(name) events[#events+1]=name end
store = {load=function() event("load") end, get=function() return stored end,
  set=function(value) stored=value end, save=function() event("save") end}
mip = {on=function(key,fn) handlers[key]=fn; return key end, off=function() end}
gmcp = {on=function(_,fn) gmcp_handler=fn; return 1 end, remove=function() end}
trigger = {add=function() return 1 end, remove=function() end}
ui = {dirty=function() end}
local push = {notify=function() event("push") end,register_channel=function() end}
plugin = {get=function() return push end}
local original_date = os.date
os.date = function(...) dates=dates+1; return original_date(...) end
local api = {
  source_active=function() queries=queries+1;return active end,
  source_register=function(key,title)
    assert(active and key=="chat" and title=="Chat")
    next_source=next_source+1; current={id=next_source,epoch=1,rows={},active=true}
    sources[#sources+1]=current; event("appear");return current
  end,
  source_upsert=function(handle,id,text)
    assert(handle.active); writes=writes+1
    if id=="" or (fail_after and writes>=fail_after) then active=false;return false end
    assert(id:match("^[1-9]%d*$"));handle.rows[id]=text;event("line");return true
  end,
  source_reset=function(handle)
    if not active then return false end
    handle.rows={};handle.epoch=handle.epoch+1;event("reset");return true
  end,
  source_retire=function(handle) handle.active=false;event("retire");return active end,
}
recording = api
local function load_chat()
  package.loaded.chat_monitor=nil
  local chat=require("chat_monitor");chat.on_load();return chat
end
local function page(chat)
  return chat.companion_source().page({epoch="",after="",before="",limit=100})
end
local function matches(chat)
  local result=page(chat)
  for _,row in ipairs(result.records) do
    assert(current.rows[row.id]==row.text,"missing or incorrectly formatted captured logical Chat message")
  end
  return result
end
local chat=load_chat()
assert(events[1]=="load" and events[2]=="appear")
chat.on_message(function() event("listener") end)
events={}
handlers.BAB("BAB","","~Example~direct message")
assert(table.concat(events,",")=="listener,push,line","intake hook ordering changed")
events={}
chat.receive("tell_in","Example","relay \27[31mred\27[0m\n  continuation","Example:")
assert(table.concat(events,",")=="push,line","relay must bypass listeners")
assert(#matches(chat).records==2)
chat.disable("tell_in")
local before=writes
assert(not chat.receive("tell_in","X","filtered","X:"));assert(writes==before)
chat.enable("tell_in")
chat.add_gag("tell_in","hidden")
chat.receive("tell_in","X","hidden","X:")
assert(writes==before)
chat.remove_gag("tell_in","hidden")
gmcp_handler("Comm.Channel.Text",{channel="wiz",talker="Wizard",text="GMCP message"})
assert(#matches(chat).records==3)
local epoch=current.epoch
chat.set_timestamps(true,"%Y-%m-%d %H:%M","yellow")
assert(current.epoch==epoch and dates>0)
assert(#matches(chat).records==3)
chat.configure("tell_in",{color="green",text_color="cyan"});matches(chat)
local first=page(chat).records[1].id
chat.set_max_lines(1)
chat.receive("tell_in","Example","new retained","Example:")
assert(#matches(chat).records==1 and current.rows[first],"LIVE retention must preserve archive")
local previous=current
chat.on_unload()
assert(events[#events-1]=="save" and events[#events]=="retire" and not previous.active)
chat=load_chat()
assert(current.id~=previous.id and #matches(chat).records==1,"restored history/new source missing")
chat.clear()
assert(current.epoch==2 and next(current.rows)==nil and #page(chat).records==0)
chat.receive("tell_in","Example","after clear","Example:");matches(chat)
-- A cached handle cannot keep capture-only date formatting alive after stop.
active=false;dates=0;before=writes
chat.receive("tell_in","Example","after stop","Example:")
chat.set_timestamps(true,"%H")
assert(dates==0 and writes==before)
chat.on_unload()
-- No recorder (including older Lera) does no source traversal/date formatting.
for _,mode in ipairs({"inactive","older"}) do
  recording=mode=="older" and nil or api
  active=false;dates=0;before=writes
  chat=load_chat();chat.receive("tell_in","X","ordinary","X:")
  chat.set_timestamps(true,"%M")
  assert(dates==0 and writes==before)
  chat.on_unload()
end
-- Stop/failure halfway through restored/reformatted history prevents later dates.
recording=api;active=true
stored={config={timestamps=true,max_lines=100},message_seq=3,messages={
  {seq=1,type="tell_in",text="one",time=1},
  {seq=2,type="tell_in",text="two",time=2},
  {seq=3,type="tell_in",text="three",time=3},
}}
fail_after=writes+1;dates=0
chat=load_chat();assert(not active and dates==1)
chat.receive("tell_in","X","after failure","X:");assert(dates==1)
chat.on_unload();fail_after=nil
-- Exact-safe maximum is canonical; the next live seq remains unchanged but
-- capture fails before date formatting, rather than pretending it has an ID.
active=true;dates=0
stored={config={timestamps=true},message_seq=9007199254740990,messages={}}
chat=load_chat();chat.receive("tell_in","X","safe","X:")
assert(current.rows["9007199254740991"] and dates==1)
chat.receive("tell_in","X","unsafe","X:")
assert(not active and dates==1 and chat.count()==2)
chat.on_unload()
os.date=original_date
print("chat_recording_test: OK (logical bytes, lifecycle, ordering, inactive/failure and exact IDs)")
