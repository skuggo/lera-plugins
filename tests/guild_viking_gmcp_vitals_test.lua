-- guild_viking Guild.State vitals writer unit tests. Run from the
-- lera-plugins repo root with LERA_ROOT pointing at a built Lera checkout.
--
-- Guild.State carries every field combat.lua's eight hp-bar screen-scrape
-- triggers parse out of the MUD's rendered prompt, in structured groups. This
-- file covers the writer that consumes them, and the latch that makes GMCP the
-- source of truth while leaving the triggers as the fallback.
--
-- What is deliberately NOT here: the triggers' own parsing. That is
-- guild_viking_combat_test.lua's subject and must stay green untouched by this
-- work -- it is the check that the fallback path still functions.

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

ui = { dirty = function() end }
lera = { time = function() return 1000 end }
buffer = { color_print = function() end }

local protocol = require("protocol")
local combat = require("combat")
local state = require("state")
local S = state.S

-- init.lua's RESERVED set: the module-level convention fields, not MIP keys.
local RESERVED = { _market_seam = true, _patterns = true, _gmcp = true,
                   _retired_keys = true, _retired_patterns = true }
for _, name in ipairs({ "handlers.trade", "handlers.kingdom", "handlers.voyage",
                        "handlers.city", "handlers.vitals" }) do
  local mod = require(name)
  for key, fn in pairs(mod._gmcp or {}) do
    protocol.gmcp_handler(key, fn)
  end
end

local function vstate(payload)
  payload.guild = "viking"
  protocol.on_gmcp("Guild.State", payload)
end

-- The trigger callbacks, by name, so the latch cases can drive the real ones
-- rather than a stand-in.
local TRIGGER = {}
for _, t in ipairs(combat.triggers) do TRIGGER[t.name] = t.fn end

-- A full line-1 prompt the real hp_bar_1 regex would have captured, expressed
-- as the callback args it produces (the trigger engine passes the line then
-- each capture). Values are deliberately unlike the GMCP fixture's below, so a
-- test can tell which source wrote a field.
local function fire_hp_bar_1()
  TRIGGER.hp_bar_1("H[11|22(33|44)] S[55|66] V[77|88] R[99|110]",
    "11", "22", "33", "44", "55", "66", "77", "88", "99", "110", nil, nil, nil)
end

-- ---------------------------------------------------------------------------
-- hp / threk
-- ---------------------------------------------------------------------------
vstate({ hp = { cur = 2356, max = 3000, threk = 120, mthrek = 3534, delta = -44 } })
check("hp.cur/max land on hp/mhp", S.hp == 2356 and S.mhp == 3000,
      S.hp .. "/" .. S.mhp)
check("hp.threk/mthrek land on threk/mthrek", S.threk == 120 and S.mthrek == 3534,
      S.threk .. "/" .. S.mthrek)
-- The server computes this from query_last_round_hp_delta(); the trigger
-- computed it as new-minus-prev itself. Taking the server's is the point.
check("hp.delta is taken from the server, not recomputed", S.hp_delta == -44, S.hp_delta)

-- ---------------------------------------------------------------------------
-- points: the pools the prompt renders as S[] V[] R[] F[]
--
-- The mudlib renamed these to saga-branch names to resolve a real collision
-- (points.buandi was the spendable pool while the MIP AUD token was the saga
-- TOTAL -- two unrelated numbers under one name). vitka/viga/drotta are what
-- the prompt calls seid/vig/rad.
-- ---------------------------------------------------------------------------
vstate({ points = {
  vitka = 4370, mvitka = 7726, viga = 7229, mviga = 7921,
  drotta = 7126, mdrotta = 7126, buandi = 0, mbuandi = 58,
  fury = 3, mfury = 10,
  vitka_delta = -12, viga_delta = 5, drotta_delta = 0,
} })
check("points.vitka/mvitka land on seid/mseid", S.seid == 4370 and S.mseid == 7726,
      S.seid .. "/" .. S.mseid)
check("points.viga/mviga land on vig/mvig", S.vig == 7229 and S.mvig == 7921,
      S.vig .. "/" .. S.mvig)
check("points.drotta/mdrotta land on rad/mrad", S.rad == 7126 and S.mrad == 7126,
      S.rad .. "/" .. S.mrad)
check("points.buandi/mbuandi land on the fourth pool (no prompt field carries it)",
      S.buandi == 0 and S.mbuandi == 58,
      tostring(S.buandi) .. "/" .. tostring(S.mbuandi))
check("points deltas land on seid_delta/vig_delta/rad_delta",
      S.seid_delta == -12 and S.vig_delta == 5 and S.rad_delta == 0,
      S.seid_delta .. "/" .. S.vig_delta .. "/" .. S.rad_delta)

-- Fury arrives as two integers. pages/stats.lua wants exactly that: it
-- currently recovers filled/total by stripping brackets off the trigger's
-- "[--***---]" string and counting asterisks.
check("points.fury/mfury land as numbers", S.fury_cur == 3 and S.fury_max == 10,
      tostring(S.fury_cur) .. "/" .. tostring(S.fury_max))

-- ---------------------------------------------------------------------------
-- chain
-- ---------------------------------------------------------------------------
vstate({ chain = { chain = 4, bsdepth = 2 } })
check("chain.chain/bsdepth land on chain/bsdepth", S.chain == 4 and S.bsdepth == 2,
      S.chain .. "/" .. S.bsdepth)

-- ---------------------------------------------------------------------------
-- gxp: the saga totals the prompt renders as G[vis(vkxp)|kap|soe|aud]
--
-- Order is vitka/viga/drotta/buandi = vis/kap/soe/aud. The *_max values have
-- no prompt equivalent at all -- G[] carries only current and last-round gain.
-- ---------------------------------------------------------------------------
S.vis_session, S.kap_session, S.soe_session, S.aud_session = 0, 0, 0, 0
S.xp_session_start = nil
vstate({ gxp = {
  vitka = 12399, vitka_max = 20000, vitka_last = 7,
  viga = 16168, viga_max = 30000, viga_last = 3,
  drotta = 495, drotta_max = 1000, drotta_last = 0,
  buandi = 14507, buandi_max = 40000, buandi_last = 1,
} })
check("gxp branch totals land on vis/kap/soe/aud in branch order",
      S.vis == 12399 and S.kap == 16168 and S.soe == 495 and S.aud == 14507,
      table.concat({ S.vis, S.kap, S.soe, S.aud }, "/"))
check("gxp *_last land on the per-round gains",
      S.vis_gain == 7 and S.kap_gain == 3 and S.soe_gain == 0 and S.aud_gain == 1,
      table.concat({ S.vis_gain, S.kap_gain, S.soe_gain, S.aud_gain }, "/"))
check("gxp *_max land (new data -- the prompt's G[] never carried a maximum)",
      S.mvis == 20000 and S.mkap == 30000 and S.msoe == 1000 and S.maud == 40000,
      table.concat({ tostring(S.mvis), tostring(S.mkap),
                     tostring(S.msoe), tostring(S.maud) }, "/"))
-- The session accumulation is hp_bar_2's, shared rather than copied.
check("a gxp frame with gains accumulates the session totals",
      S.vis_session == 7 and S.kap_session == 3 and S.soe_session == 0
        and S.aud_session == 1,
      table.concat({ S.vis_session, S.kap_session,
                     S.soe_session, S.aud_session }, "/"))
check("a gxp frame with gains starts the session clock", S.xp_session_start ~= nil)

-- A second frame accumulates on top rather than replacing.
vstate({ gxp = {
  vitka = 12404, vitka_max = 20000, vitka_last = 5,
  viga = 16168, viga_max = 30000, viga_last = 0,
  drotta = 495, drotta_max = 1000, drotta_last = 0,
  buandi = 14507, buandi_max = 40000, buandi_last = 0,
} })
check("a second gxp frame adds to the session totals", S.vis_session == 12,
      S.vis_session)

-- A zero-gain frame must not START the session clock. The gains arrive on
-- every beat, so without the non-zero-round-total gate the clock would be
-- stamped by the first frame after connect and the pane would report a session
-- that began before the player earned anything.
--
-- The clock has to be nil to see this: with it already set, an ungated
-- accumulation is indistinguishable from a gated one (adding zero changes no
-- total, and `if not S.xp_session_start` is false either way).
local clock_before, sessions_before = S.xp_session_start, S.vis_session
S.xp_session_start = nil
vstate({ gxp = {
  vitka = 12404, vitka_max = 20000, vitka_last = 0,
  viga = 16168, viga_max = 30000, viga_last = 0,
  drotta = 495, drotta_max = 1000, drotta_last = 0,
  buandi = 14507, buandi_max = 40000, buandi_last = 0,
} })
check("a zero-gain gxp frame does not start the session clock",
      S.xp_session_start == nil, tostring(S.xp_session_start))
check("a zero-gain gxp frame leaves the session totals alone",
      S.vis_session == sessions_before, S.vis_session)
S.xp_session_start = clock_before

-- ---------------------------------------------------------------------------
-- fx.stfx -- the same pre-rendered bar format apply_stfx already parses, so
-- the effects list comes through the trigger path's own parser, not a copy.
-- ---------------------------------------------------------------------------
vstate({ fx = { chan = "", stfx = "[ein:54 bvorn:91 bles:34]", queue = "" } })
check("fx.stfx yields three parsed effects", #S.stfx == 3, #S.stfx)
check("fx.stfx keeps name/value per effect",
      S.stfx[1] and S.stfx[1].name == "ein" and S.stfx[1].val == "54",
      S.stfx[1] and (S.stfx[1].name .. ":" .. S.stfx[1].val))
check("fx.stfx resolves each effect's category through STFX_META",
      S.stfx[3] and S.stfx[3].name == "bles" and S.stfx[3].cat == "Heal",
      S.stfx[3] and (S.stfx[3].name .. "/" .. tostring(S.stfx[3].cat)))
-- An empty bar clears the list -- combat.lua's apply_stfx rebuilds it whole.
vstate({ fx = { chan = "", stfx = "[]", queue = "" } })
check("an empty fx.stfx bar clears the effects list", #S.stfx == 0, #S.stfx)

-- ---------------------------------------------------------------------------
-- ledung -- CONDITIONAL server-side (cond: query_ledung_quest_complete()), so
-- its absence is normal and must not zero what an earlier frame set.
-- ---------------------------------------------------------------------------
vstate({ ledung = { charges = 1, max = 4, reset_pct = 62 } })
check("ledung lands on ldng/mldng/lrst",
      S.ldng == 1 and S.mldng == 4 and S.lrst == 62,
      table.concat({ S.ldng, S.mldng, S.lrst }, "/"))
vstate({ chain = { chain = 0, bsdepth = 0 } })
check("a frame without ledung leaves it standing (conditional key, not cleared)",
      S.ldng == 1 and S.mldng == 4 and S.lrst == 62,
      table.concat({ S.ldng, S.mldng, S.lrst }, "/"))

-- ---------------------------------------------------------------------------
-- encounter / target -- the prompt's E[] field and the combat flag
-- ---------------------------------------------------------------------------
vstate({ encounter = { active = 1, rounds = 19 },
         target = { name = "a cave troll", name5 = "a cav", hp_status = "low" } })
check("encounter.rounds lands on rndz", S.rndz == 19, S.rndz)
check("target.name5/hp_status land on en5/ens",
      S.en5 == "a cav" and S.ens == "low", S.en5 .. "/" .. S.ens)
check("encounter.active drives the combat flag", S.combat == true, tostring(S.combat))

vstate({ encounter = { active = 0, rounds = 0 },
         target = { name = "None", name5 = "None", hp_status = "" } })
check("encounter.active = 0 clears the combat flag", S.combat == false,
      tostring(S.combat))

-- ---------------------------------------------------------------------------
-- sp / tox -- stored, not displayed. Mapping them is what stops /vik source
-- reporting them as keys nobody has taught this client about.
-- ---------------------------------------------------------------------------
vstate({ sp = { cur = 210, max = 400 }, tox = { cur = 12, max = 100 } })
check("sp.cur/max are stored", S.sp == 210 and S.msp == 400,
      tostring(S.sp) .. "/" .. tostring(S.msp))
check("tox.cur/max are stored", S.tox == 12 and S.mtox == 100,
      tostring(S.tox) .. "/" .. tostring(S.mtox))

-- ---------------------------------------------------------------------------
-- Accounting: none of the eleven keys is "unknown" any more
-- ---------------------------------------------------------------------------
do
  local unknown = protocol.gmcp_stats().unknown
  local leaked = {}
  for _, k in ipairs({ "hp", "sp", "points", "chain", "gxp", "tox", "fx",
                       "encounter", "target", "ledung", "bars" }) do
    if unknown[k] then leaked[#leaked + 1] = k end
  end
  check("no vitals key is counted unknown once the writer exists",
        #leaked == 0, table.concat(leaked, ","))
end

-- ---------------------------------------------------------------------------
-- The latch: GMCP becomes the source of truth, triggers are the fallback
-- ---------------------------------------------------------------------------

-- Fallback direction first, from a clean connection: with no GMCP frame seen,
-- the trigger writes exactly as it always did.
state.reset_connection()
S.hp, S.mhp, S.threk, S.mthrek, S.seid = 0, 0, 0, 0, 0
check("reset_connection clears the vitals latch", S.vitals_gmcp ~= true,
      tostring(S.vitals_gmcp))
fire_hp_bar_1()
check("with no GMCP frame seen, the hp-bar trigger still writes hp",
      S.hp == 11 and S.mhp == 22, S.hp .. "/" .. S.mhp)
check("with no GMCP frame seen, the hp-bar trigger still writes the pools",
      S.seid == 55 and S.mseid == 66, S.seid .. "/" .. S.mseid)

-- Now a GMCP frame arrives and takes over.
vstate({ hp = { cur = 900, max = 1000, threk = 0, mthrek = 0, delta = 0 } })
check("a vitals frame sets the latch", S.vitals_gmcp == true, tostring(S.vitals_gmcp))
check("the vitals frame wrote hp", S.hp == 900 and S.mhp == 1000,
      S.hp .. "/" .. S.mhp)

-- The same trigger that worked a moment ago is now a no-op: the prompt line
-- still arrives (it has to -- init.lua's triggers are also what GAG it from
-- the main buffer), it just no longer writes.
--
-- The pools get a sentinel first. Asserting `S.seid ~= 55` would not test
-- anything: the pre-latch trigger above already wrote 55, and the GMCP frame
-- carried only `hp`, so 55 is what an UNGUARDED trigger would leave there too.
S.seid, S.mseid = 4242, 4242
fire_hp_bar_1()
check("once latched, the hp-bar trigger does not overwrite GMCP's hp",
      S.hp == 900 and S.mhp == 1000, S.hp .. "/" .. S.mhp)
check("once latched, the hp-bar trigger does not write the pools",
      S.seid == 4242 and S.mseid == 4242, S.seid .. "/" .. S.mseid)
check("once latched, the hp-bar trigger does not write the deltas either",
      S.hp_delta == 0, S.hp_delta)

-- Every one of the eight triggers has to respect the latch, not just line 1 --
-- a single unguarded callback puts a second writer back on the same fields.
S.rndz, S.ldng, S.stfx = 4242, 4242, { { name = "sentinel" } }
TRIGGER.hp_bar_1_cont("--] C[7/7]", "7", "7")
TRIGGER.hp_bar_2("G[1(1)|2(2)|3(3)|4(4)] L[5|6(7%)] E[foo|bar|8]",
  "1", "1", "2", "2", "3", "3", "4", "4", "5", "6", "7", "foo", "bar", "8")
TRIGGER.hp_bar_2_cont("9]", "9")
TRIGGER.hp_bar_2_vis("Vis:1  Kap:2  Soe:3  Aud:4  L[5|6] E[None]",
  "1", "2", "3", "4", "5", "6", "None")
TRIGGER.hp_bar_3("[gald:1]", "gald:1")
TRIGGER.hp_bar_3_open("[gald:1", "gald:1")
TRIGGER.hp_bar_3_cont("veth:2]", "veth:2")
check("once latched, no hp-bar trigger touches rndz", S.rndz == 4242, S.rndz)
check("once latched, no hp-bar trigger touches ledung", S.ldng == 4242, S.ldng)
check("once latched, no hp-bar trigger touches the effects list",
      #S.stfx == 1 and S.stfx[1].name == "sentinel",
      #S.stfx .. "/" .. tostring(S.stfx[1] and S.stfx[1].name))

-- A reconnect re-earns it: the latch is per-connection, matching the MIP-side
-- per-key latch, so a reconnect that never negotiates GMCP falls back rather
-- than freezing on the last connection's numbers.
state.reset_connection()
check("reset_connection clears the latch again", S.vitals_gmcp ~= true,
      tostring(S.vitals_gmcp))
S.hp, S.mhp = 0, 0
fire_hp_bar_1()
check("after a reconnect with no GMCP frame, the trigger writes again",
      S.hp == 11 and S.mhp == 22, S.hp .. "/" .. S.mhp)

if failures > 0 then os.exit(1) end
print("ALL GUILD_VIKING GMCP VITALS TESTS PASSED")
