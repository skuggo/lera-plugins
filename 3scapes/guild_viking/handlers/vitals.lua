-- Guild.State's player vitals block: hp, the guild-point pools, chain, the
-- saga XP totals, toxicity, the effects bar, ledung, and the encounter/target
-- pair.
--
-- WHY THIS EXISTS. combat.lua's eight hp-bar triggers parse all of this out of
-- the MUD's rendered prompt, and for a long time that was the only source --
-- gmcp_map.lua's own comment used to say mapping these keys "would create a
-- second writer for values that already have one". The screen-scrape works,
-- but it is the wrong mechanism for data the server already sends structured:
-- it depends on the prompt being enabled, on its exact layout, and on where
-- the MUD happens to hard-wrap it (hence the three `_cont` continuation
-- triggers reassembling fields split across physical lines). Guild.State has
-- every field as a typed integer. So GMCP is the only source now: the
-- screen-scrape triggers were removed, and 'autohp' turns the prompt lines off
-- MUD-wide for anyone who does not want them on screen.
--
-- WHY ONE COMPOSITE. All eleven keys route to a single writer through
-- gmcp_map.COMPOSITE's VITALS entry. That machinery exists for "one writer fed
-- by several GMCP keys, applying only the halves this frame carried", which is
-- exactly what a delta Guild.State frame needs. The alternative -- eleven
-- separate writers -- would put eleven copies of the latch-setting and the
-- absent-key handling side by side.
--
-- VITALS IS NOT A MIP KEY. Every other entry in that table is named for the
-- MIP key whose data it carries. This one is a label: this block's MIP
-- ancestors were GLINE1, GLINE2, the $STFX$ line and the retired FFF
-- composite -- four keys with no single name between them -- so the writer that
-- owns the vitals block gets a name of its own rather than being split three
-- ways to preserve a naming rule.
--
-- ABSENT MEANS UNCHANGED. Frames are deltas, so every write below is guarded
-- on its own group being present. `ledung` is additionally conditional
-- server-side (gmcp.h:163, `cond: query_ledung_quest_complete()`), so its
-- absence is the normal case for most of a character's life and must not zero
-- what an earlier frame set.
local S = require("state").S
local combat = require("combat")

local M = {}

local function num(v, fallback)
  return tonumber(v) or fallback or 0
end

-- H[hp|mhp(threk|mthrek)]. `delta` is the server's own
-- query_last_round_hp_delta(); the trigger path computes the same number as
-- new-minus-prev and keeps S.hp_prev for it. Taking the server's value is the
-- point of the exercise, so hp_prev is deliberately NOT maintained here -- it
-- is the trigger path's private working state, and writing it would make the
-- fallback's first delta after a latch drop wrong instead of merely stale.
local function write_hp(hp)
  S.hp       = num(hp.cur)
  S.mhp      = num(hp.max)
  S.threk    = num(hp.threk)
  S.mthrek   = num(hp.mthrek)
  S.hp_delta = num(hp.delta)
end

-- S[seid|mseid] V[vig|mvig] R[rad|mrad] F[fury], plus the fourth pool.
--
-- The names differ from the prompt's because the mudlib renamed them to the
-- plain saga-branch names to resolve a real collision (gmcp.h:558-580): the
-- points group used to call the SAGA_BUANDI pool "aud", while MIP's AUD token
-- was the Buandi saga TOTAL -- a live capture read 0/58 for one and
-- 129175/55050 for the other, two unrelated numbers under one name. So
-- vitka/viga/drotta are what the prompt calls seid/vig/rad, and points.buandi
-- is the pool that never had a short name or a prompt field.
local function write_points(p)
  S.seid, S.mseid = num(p.vitka), num(p.mvitka)
  S.vig,  S.mvig  = num(p.viga),  num(p.mviga)
  S.rad,  S.mrad  = num(p.drotta), num(p.mdrotta)
  S.buandi, S.mbuandi = num(p.buandi), num(p.mbuandi)
  S.seid_delta = num(p.vitka_delta)
  S.vig_delta  = num(p.viga_delta)
  S.rad_delta  = num(p.drotta_delta)
  -- Integers, where the prompt's $FURY$ token is a rendered bar string. Both
  -- representations live in state; see state.lua's note on why.
  S.fury_cur = num(p.fury)
  S.fury_max = num(p.mfury)
end

local function write_chain(c)
  S.chain   = num(c.chain)
  S.bsdepth = num(c.bsdepth)
end

-- G[vis(vkxp)|kap(bkxp)|soe(hkxp)|aud(buxp)] -- the saga totals and their
-- last-round gains, in branch order vitka/viga/drotta/buandi. The maxima have
-- no prompt equivalent at all.
--
-- Session accumulation goes through combat.accumulate_xp_session so the two
-- transports share one implementation of it, including its "only on a non-zero
-- round total" gate -- these gains arrive every beat, and stamping the session
-- clock on a zero-gain frame would report a session that began at connect.
local function write_gxp(g)
  S.vis, S.mvis = num(g.vitka),  num(g.vitka_max)
  S.kap, S.mkap = num(g.viga),   num(g.viga_max)
  S.soe, S.msoe = num(g.drotta), num(g.drotta_max)
  S.aud, S.maud = num(g.buandi), num(g.buandi_max)
  S.vis_gain = num(g.vitka_last)
  S.kap_gain = num(g.viga_last)
  S.soe_gain = num(g.drotta_last)
  S.aud_gain = num(g.buandi_last)
  combat.accumulate_xp_session(S.vis_gain, S.kap_gain, S.soe_gain, S.aud_gain)
end

-- E[en5|ens|rndz]. Two GMCP groups cover what the prompt packed into one
-- field, and either can arrive alone in a delta, so each writes only its own
-- half. `combat` comes from encounter.active -- the server's own "is there an
-- enemy" answer -- rather than being re-derived from the target name the way
-- the trigger path has to (`en5 ~= "None" and en5 ~= ""`).
local function write_encounter(e)
  S.rndz   = num(e.rounds)
  S.combat = num(e.active) ~= 0
end

local function write_target(t)
  S.en5 = tostring(t.name5 or "None")
  S.ens = tostring(t.hp_status or "")
end

-- Conditional server-side. reset_pct is the recharge percentage the prompt
-- renders as L[ldng|mldng(lrst%)].
local function write_ledung(l)
  S.ldng  = num(l.charges)
  S.mldng = num(l.max)
  S.lrst  = num(l.reset_pct)
end

-- fx.stfx is the same bar text the $STFX$ line carries -- the mudlib strips its
-- "@colour:tag@" markup before sending (gmcp.h:651-659) -- so it is parsed by
-- combat.apply_stfx rather than by a second copy of the format here. chan and
-- queue are the channelling and spell-queue bars; stored so /vik source stops
-- calling them unknown, not yet rendered anywhere.
local function write_fx(fx)
  if fx.stfx ~= nil then combat.apply_stfx(tostring(fx.stfx)) end
  if fx.chan ~= nil then S.fx_chan = tostring(fx.chan) end
  if fx.queue ~= nil then S.fx_queue = tostring(fx.queue) end
end

-- Each group is a mapping; a malformed frame that sends a scalar where a
-- record belongs must skip that group rather than index a number.
local function group(parts, name)
  local v = parts[name]
  if type(v) == "table" then return v end
  return nil
end

M._gmcp = {
  VITALS = function(parts)
    local hp = group(parts, "hp")            if hp then write_hp(hp) end
    local points = group(parts, "points")    if points then write_points(points) end
    local chain = group(parts, "chain")      if chain then write_chain(chain) end
    local gxp = group(parts, "gxp")          if gxp then write_gxp(gxp) end
    local enc = group(parts, "encounter")    if enc then write_encounter(enc) end
    local target = group(parts, "target")    if target then write_target(target) end
    local ledung = group(parts, "ledung")    if ledung then write_ledung(ledung) end
    local fx = group(parts, "fx")            if fx then write_fx(fx) end
    local sp = group(parts, "sp")
    if sp then S.sp, S.msp = num(sp.cur), num(sp.max) end
    local tox = group(parts, "tox")
    if tox then S.tox, S.mtox = num(tox.cur), num(tox.max) end
    local bars = group(parts, "bars")
    if bars then
      S.gp1, S.gp1_max = num(bars.gp1), num(bars.gp1_max)
      S.gp2, S.gp2_max = num(bars.gp2), num(bars.gp2_max)
    end

    -- Last, and unconditionally: any vitals frame at all means the structured
    -- source is live, so the triggers stand down from here. Set after the
    -- writes so a writer error leaves the triggers in charge rather than
    -- silencing them in favour of a half-applied frame.
    S.vitals_gmcp = true
  end,
}

return M
