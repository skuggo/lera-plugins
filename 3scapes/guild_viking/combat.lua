-- Combat status for the viking guild: the STFX effect metadata, session XP
-- accumulation, and GMCP Char.Combat. (Originally ported from LEGACY
-- guild_viking.lua, github.com/.../3s_scripts_old, read-only reference.)

local S = require("state").S

local M = {}

-- LEGACY guild_viking.lua:302-335 (STFX_META / STFX_DEFAULT): tag -> visual
-- metadata for the STFX effects bar. The colors are unconsumed without a
-- window in stage 1, but every write LEGACY made to a stfx entry (including
-- cat/cs/ci) is preserved verbatim per the porting rule -- stage 2 reads
-- them back rather than re-deriving from the tag name.
local STFX_META = {
  aeg  = { cat="Def",  cs="#00CCCC", ci=0xCCCC00 },
  sev  = { cat="Def",  cs="#00CCCC", ci=0xCCCC00 },
  skad = { cat="Def",  cs="#00CCCC", ci=0xCCCC00 },
  vkj  = { cat="Def",  cs="#00CCCC", ci=0xCCCC00 },
  ram  = { cat="Def",  cs="#00CCCC", ci=0xCCCC00 },
  -- Heimdall's vital-sight enchantments are purple effects, not defensive
  -- wards.
  --
  -- The server emits `bsjon`/`gsjon` for Broddsjón/Gullsjón -- see
  -- query_spell_fx_bar() in players/viking/obj/include/spell_data.h, which
  -- picks the tag from vital_sight_tier. An unknown tag falls through to
  -- STFX_DEFAULT, whose cat is "DoT", so Broddsjón was being filed and
  -- coloured as a damage-over-time effect rather than an enchantment.
  --
  -- `bro`/`gul` are kept as aliases: an older feed used them, and `gul` in
  -- particular must stay because gullhjalmr_buff ALSO emits `gul` (same file,
  -- cyan ward). Removing it would send Gullhjalmr to the DoT bucket instead.
  bsjon = { cat="Off",  cs="#DD44DD", ci=0xDD44DD },
  gsjon = { cat="Off",  cs="#DD44DD", ci=0xDD44DD },
  bro  = { cat="Off",  cs="#DD44DD", ci=0xDD44DD },
  gul  = { cat="Off",  cs="#DD44DD", ci=0xDD44DD },
  tvi  = { cat="Def",  cs="#00CCCC", ci=0xCCCC00 },
  nau  = { cat="Def",  cs="#00CCCC", ci=0xCCCC00 },
  valg = { cat="Def",  cs="#00CCCC", ci=0xCCCC00 },
  gisl = { cat="Def",  cs="#00CCCC", ci=0xCCCC00 },
  gjal = { cat="Def",  cs="#00CCCC", ci=0xCCCC00 },
  bif  = { cat="Def",  cs="#00CCCC", ci=0xCCCC00 },
  ein  = { cat="Def",  cs="#00CCCC", ci=0xCCCC00 },
  bvorn= { cat="Def",  cs="#00CCCC", ci=0xCCCC00 },
  hrei = { cat="Heal", cs="#33CC33", ci=0x33CC33 },
  bles = { cat="Heal", cs="#33CC33", ci=0x33CC33 },
  gro  = { cat="Heal", cs="#33CC33", ci=0x33CC33 },
  jor  = { cat="Heal", cs="#33CC33", ci=0x33CC33 },
  -- Baldr's lingering regen (ljosbylgja_regen). Emitted green by the server
  -- like every other regen, but it was absent from this table, so it landed
  -- in STFX_DEFAULT's "DoT" bucket -- a heal displayed as damage-over-time.
  ljos = { cat="Heal", cs="#33CC33", ci=0x33CC33 },
  van  = { cat="Heal", cs="#33CC33", ci=0x33CC33 },
  frey = { cat="Heal", cs="#33CC33", ci=0x33CC33 },
  gald = { cat="Off",  cs="#DD44DD", ci=0xDD44DD },
  veth = { cat="Off",  cs="#DD44DD", ci=0xDD44DD },
  hug  = { cat="Off",  cs="#DD44DD", ci=0xDD44DD },
  bolv = { cat="Off",  cs="#DD44DD", ci=0xDD44DD },
  rune = { cat="Off",  cs="#DD44DD", ci=0xDD44DD },
  valhr= { cat="Pwr",  cs="#FF3333", ci=0x3333FF },
}
local STFX_DEFAULT = { cat="DoT", cs="#FF5555", ci=0x5555FF }

-- LEGACY guild_viking.lua:335-337 (STFX_CAT_ORDER/STFX_CAT_LABELS): category
-- grouping order and display labels for the Stats page's active-effects
-- section (pages/stats.lua). Exported (not duplicated) per the plan's
-- preference -- the page reads the same metadata combat.lua already derives
-- stfx entries' `cat` field from, so the two can never drift apart. Colors
-- are NOT exported: LEGACY's STFX_CAT_COLORS/per-effect `ci` are BGR pixel
-- hex, which has no faithful ANSI equivalent worth the complexity (Global
-- Constraints: "exact hex fidelity is NOT required") -- pages/stats.lua maps
-- each category to a pagelib.C name instead.
M.STFX_CAT_ORDER  = { "Def", "Heal", "Off", "Pwr", "DoT" }
M.STFX_CAT_LABELS = { Def="Def", Heal="Heal", Off="Off", Pwr="Pwr", DoT="DoT" }

-- The hp-bar screen-scrape triggers that used to live here are gone. Every
-- field they parsed arrives over GMCP (Guild.State -> handlers/vitals.lua,
-- Char.Combat below), and a player who does not want the status lines on
-- screen turns them off MUD-wide with 'autohp' -- so neither the parsing nor
-- the gag_status_lines gagging they did has a job left.

-- Session XP accumulation, used by handlers/vitals.lua's gxp writer. Gated on a non-zero round total:
-- the gains arrive on every prompt/beat, so accumulating unconditionally would
-- be harmless but starting the session clock unconditionally would not -- it
-- would stamp the clock at connect and report a session that began before the
-- player earned anything.
function M.accumulate_xp_session(vis_gain, kap_gain, soe_gain, aud_gain)
  local round_total = vis_gain + kap_gain + soe_gain + aud_gain
  if round_total <= 0 then return end
  S.vis_session = S.vis_session + vis_gain
  S.kap_session = S.kap_session + kap_gain
  S.soe_session = S.soe_session + soe_gain
  S.aud_session = S.aud_session + aud_gain
  if not S.xp_session_start then
    S.xp_session_start = os.time()
  end
end
-- The STFX effects bar: "ein:54 bvorn:91 bles:34", empty when none active.
-- Guild.State's fx.stfx carries it (the mudlib strips its colour markup), and
-- handlers/vitals.lua parses it through this.
function M.apply_stfx(inner)
  local new_stfx = {}
  for k, v in (inner or ""):gmatch("(%a+):([%d/]+)") do
    local meta = STFX_META[k] or STFX_DEFAULT
    new_stfx[#new_stfx + 1] = { name = k, val = v, cat = meta.cat, cs = meta.cs, ci = meta.ci }
  end
  S.stfx = new_stfx
end

-- ---------------------------------------------------------------------------
-- GMCP Char.Combat.
--
-- Char.Combat is the purpose-built replacement for that attacker block. Its own
-- header says it "mirrors the MIP composite's attacker block", and it carries
-- all three: attacker, attacker_hp and rounds. Guild.State's target/encounter
-- groups cover the same subject but omit the hp percent, so this stays the
-- source for the attacker block. Both are mapped now (handlers/vitals.lua
-- consumes target/encounter into en5/ens/rndz/combat), and the fields they
-- write are disjoint by design -- two GMCP sources on one field would be the
-- collision that cost the housing totals their meaning, and
-- guild_viking_gmcp_test.lua pins the disjointness in both directions.
--
--   { attacker = "", attacker_hp = 0, rounds = 0, target = "" }
--
-- is the canonical idle snapshot (secure/protocol/char_combat_impl.h). Note the
-- empty attacker string where FFF's K tag used the literal "None" -- the
-- consumer at pages/stats.lua:246 tests for "None", so translate rather than
-- passing "" through.
--
-- `target` (who the attacker is attacking, "you" when that is this player) has
-- no field on the Stats page and is deliberately not mapped.
function M.on_gmcp_combat(data)
  if type(data) ~= "table" then return end

  if type(data.attacker) == "string" then
    S.mob_name_full = data.attacker ~= "" and data.attacker or "None"
  end
  if data.attacker_hp ~= nil then
    S.estatus_pct = tonumber(data.attacker_hp) or 0
  end
  if data.rounds ~= nil then
    S.combat_rounds = tonumber(data.rounds) or 0
  end

  ui.dirty()
end

return M
