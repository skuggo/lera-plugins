-- guild_viking combat.lua unit tests. Run from the lera-plugins repo root
-- with LERA_ROOT pointing at a built Lera checkout.
package.path = "3scapes/guild_viking/?.lua;" .. package.path

local failures = 0
local function check(name, ok, detail)
  if ok then
    print("CASE " .. name .. ": PASS")
  else
    failures = failures + 1
    print("CASE " .. name .. ": FAIL" .. (detail and (" - " .. tostring(detail)) or ""))
  end
end

-- ---- lera API stubs (same shape as guild_viking_test.lua) ------------------
local dirty_count = 0
ui = { dirty = function() dirty_count = dirty_count + 1 end }
local stored = nil
store = {
  load = function() end,
  get = function() return stored end,
  set = function(d) stored = d end,
  save = function() end,
}
lera = { time = function() return 1000 end, version = function() return "test" end }
buffer = { color_print = function() end }
mud = { send = function() end }
local mip_handlers, mip_handler_count = {}, 0
mip = {
  on = function(code, cb)
    mip_handlers[code] = cb
    mip_handler_count = mip_handler_count + 1
    return mip_handler_count
  end,
  off = function() end,
  enabled = function() return true end,
  -- real shape: callback(key, code, data) -- key is the 5-digit packet
  -- sequence number, data is the payload string.
  fire = function(code, data) mip_handlers[code](12345, code, data) end,
}
local gmcp_handlers, gmcp_handler_count = {}, 0
gmcp = {
  on = function(pkg, cb)
    gmcp_handlers[pkg] = cb
    gmcp_handler_count = gmcp_handler_count + 1
    return gmcp_handler_count
  end,
  remove = function() end,
  enabled = function() return false end,
  fire = function(pkg, data) gmcp_handlers[pkg](pkg, data) end,
}
-- trigger stub captures registrations by pattern so init.lua wiring can be
-- exercised the same way guild_viking_test.lua exercises mip/gmcp wiring.
local trigger_handlers, trigger_id_count = {}, 0
trigger = {
  add = function(pattern, fn)
    trigger_id_count = trigger_id_count + 1
    trigger_handlers[trigger_id_count] = { pattern = pattern, fn = fn }
    return trigger_id_count
  end,
  remove = function(id) trigger_handlers[id] = nil end,
}
timer = { every = function() return 1 end, remove = function() end }
alias = { add = function() return 1 end, remove = function() end }
plugin = { get = function() return nil end }
local real_require = require
require = function(name)
  if name == "command" then
    return { register = function() return 1 end, unregister = function() return true end,
             get = function() return nil end, list = function() return {} end }
  end
  return real_require(name)
end

local S = require("state").S
local combat = require("combat")

-- The hp-bar screen-scrape triggers are gone: GMCP carries every field they
-- parsed, and 'autohp' turns the status lines off MUD-wide.
check("the hp-bar triggers are gone", combat.triggers == nil, type(combat.triggers))
check("the FFF composite reader is gone", combat.on_composite == nil,
      type(combat.on_composite))


-- ---- GMCP Char.Combat -----------------------------------------------------
-- Guild.State (handlers/vitals.lua) owns S.en5/S.ens/S.rndz/S.combat, so this
-- writer fills only the three fields FFF's K, L and N tags owned.
check("on_gmcp_combat exported", type(combat.on_gmcp_combat) == "function",
      type(combat.on_gmcp_combat))

-- Kills: not mapping attacker_hp. This is the enemy HP percent the Stats page
-- prints (pages/stats.lua:251) and the whole reason Char.Combat is the right
-- source -- Guild.State's target group carries a three-letter word instead.
S.mob_name_full, S.estatus_pct, S.combat_rounds = "stale", -1, -1
combat.on_gmcp_combat({ attacker = "Ice Troll", attacker_hp = 62,
                        rounds = 7, target = "you" })
check("Char.Combat fills attacker name", S.mob_name_full == "Ice Troll",
      S.mob_name_full)
check("Char.Combat fills the enemy hp percent", S.estatus_pct == 62,
      S.estatus_pct)
check("Char.Combat fills the round counter", S.combat_rounds == 7,
      S.combat_rounds)

-- Kills: passing the idle snapshot's empty attacker straight through. FFF's K
-- tag used the literal "None", and pages/stats.lua:246 tests for it.
combat.on_gmcp_combat({ attacker = "", attacker_hp = 0, rounds = 0, target = "" })
check("Char.Combat idle attacker becomes None", S.mob_name_full == "None",
      S.mob_name_full)

-- Kills: a writer that also claims S.combat or S.ens. Guild.State owns both,
-- and a second writer on a field another source maintains is the
-- collision that cost the housing totals their meaning.
S.combat, S.ens = "sentinel", "sentinel"
combat.on_gmcp_combat({ attacker = "Wolf", attacker_hp = 10, rounds = 2,
                        target = "you" })
check("Char.Combat leaves S.combat to Guild.State", S.combat == "sentinel",
      tostring(S.combat))
check("Char.Combat leaves S.ens to Guild.State", S.ens == "sentinel",
      tostring(S.ens))

-- Kills: trusting the payload. gmcp delivers nil for undecodable JSON.
S.mob_name_full = "keep"
combat.on_gmcp_combat(nil)
combat.on_gmcp_combat({})
check("Char.Combat tolerates nil and empty", S.mob_name_full == "keep",
      S.mob_name_full)


-- The attacker block's three fields, previously FFF's K/L/N tags, are asserted
-- against Char.Combat above. S.combat is Guild.State's.
do
  -- Every writer marks the pane dirty.
  local before = dirty_count
  combat.on_gmcp_combat({ attacker = "Wolf", attacker_hp = 5, rounds = 1 })
  check("Char.Combat marks dirty", dirty_count > before)
end

-- ---- apply_stfx (the STFX effects bar, via Guild.State's fx.stfx) --------
combat.apply_stfx("ein:54 bvorn:91 bles:34")
check("apply_stfx count", #S.stfx == 3)
check("apply_stfx entry fields", S.stfx[1].name == "ein" and S.stfx[1].val == "54"
      and S.stfx[1].cat == "Def" and S.stfx[1].cs == "#00CCCC" and S.stfx[1].ci == 0xCCCC00)
check("apply_stfx heal category", S.stfx[3].name == "bles" and S.stfx[3].cat == "Heal")

combat.apply_stfx("")
check("apply_stfx empty clears stfx", #S.stfx == 0)

-- Heimdall vital-sight enchantments are purple/offensive in the STFX
-- presentation, rather than falling through to the red DoT default or the
-- cyan defensive category.
combat.apply_stfx("bro:12 gul:18")
check("apply_stfx Broddsjón uses purple/off category",
      S.stfx[1].name == "bro" and S.stfx[1].cat == "Off"
      and S.stfx[1].cs == "#DD44DD")
check("apply_stfx Gullsjón uses purple/off category",
      S.stfx[2].name == "gul" and S.stfx[2].cat == "Off"
      and S.stfx[2].cs == "#DD44DD")

-- unknown tag falls back to STFX_DEFAULT
combat.apply_stfx("zzz:12")
check("apply_stfx unknown tag uses default meta", S.stfx[1].cat == "DoT" and S.stfx[1].cs == "#FF5555")

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING COMBAT TESTS PASSED")
