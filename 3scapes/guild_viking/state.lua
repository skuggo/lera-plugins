local state = {
  -- HP
  hp = 0, mhp = 0, hp_prev = 0, hp_delta = 0,
  -- Threk (damage absorption pool)
  threk = 0, mthrek = 0, threk_prev = 0, threk_delta = 0,
  -- Guild points. The `_prev` fields belong to the trigger path only: it
  -- computes each delta as new-minus-prev, while Guild.State reports the
  -- server's own last-round delta and leaves `_prev` untouched.
  seid = 0, mseid = 0, seid_prev = 0, seid_delta = 0,
  vig  = 0, mvig  = 0, vig_prev  = 0, vig_delta  = 0,
  rad  = 0, mrad  = 0, rad_prev  = 0, rad_delta  = 0,
  -- The fourth point pool (SAGA_BUANDI). GMCP-only: no field of the rendered
  -- prompt carries it, so the trigger path leaves these at zero.
  buandi = 0, mbuandi = 0,
  -- Fury. Two representations, because the two transports disagree on shape:
  -- the prompt's $FURY$ token is a rendered bar string ("[--***---]") and
  -- Guild.State's points.fury/mfury are integers. pages/stats.lua wants the
  -- integers -- with only the string it recovers them by counting asterisks --
  -- so it prefers fury_cur/fury_max and falls back to decoding `fury`.
  fury = "", fury_cur = nil, fury_max = nil,
  -- Chain / Body-strike depth
  chain = 0, bsdepth = 0,
  -- Saga XP with per-round gains and session totals. The maxima are GMCP-only:
  -- the prompt's G[] field carries a current value and a last-round gain, with
  -- no maximum anywhere in it.
  vis = 0, vis_gain = 0, vis_session = 0, mvis = 0,
  kap = 0, kap_gain = 0, kap_session = 0, mkap = 0,
  soe = 0, soe_gain = 0, soe_session = 0, msoe = 0,
  aud = 0, aud_gain = 0, aud_session = 0, maud = 0,
  xp_session_start = nil,
  -- Generic spell points and shroom toxicity. Stored, not displayed: mapping
  -- them is what keeps /vik source from reporting them as keys nobody has
  -- taught this client about, and they cost two fields each to keep honest.
  sp = 0, msp = 0,
  tox = 0, mtox = 0,
  -- Ledung
  ldng = 0, mldng = 0, lrst = 0,
  -- Enemy from hpbar E field
  en5  = "None",  -- enemy name (5 chars, or "None")
  ens  = "",       -- enemy status descriptor (e.g. "low")
  rndz = 0,        -- rounds in hpbar
  -- Enemy from MIP (supplements E field)
  mob_name_full = "None",
  estatus_pct   = 0,
  combat_rounds = 0,
  -- Combat state
  combat = false,
  -- Active spell effects, e.g. {"ein",54},{"bvorn",91}. Parsed by
  -- combat.apply_stfx from either transport's bar string -- the $STFX$ line the
  -- triggers scrape, or Guild.State's fx.stfx, which the mudlib pre-renders in
  -- the same format.
  stfx = {},
  -- True once a Guild.State frame has written the vitals block. While set,
  -- combat.lua's eight hp-bar triggers stop writing state (they stay
  -- REGISTERED -- they are also what gags the prompt lines from the main
  -- buffer). Per-connection, like the MIP per-key latch: cleared by
  -- reset_connection so a reconnect that never negotiates GMCP falls back to
  -- the triggers instead of freezing on the last connection's numbers.
  vitals_gmcp = false,
  -- City / trade / farm / blot (from mip.viking_extra / send_mip_city)
  carts      = {},   -- { mode, good, village, return_in, amount, halfway_in, quality_pct, cart_id, tier, durability, cap, refit }
  courier    = { tier = 0, runs = {} },  -- Courier Post: tier + { good, village, return_in, amount, cost, fee }
  spy        = { tier = 0, mode = "", village = "", secs = 0, sab_pct = 0, sab_secs = 0, cd_secs = 0, scouts = {} },  -- Shadow-House
  train      = { tier = 0, name = "", stat = "", trained = 0, secs = 0 },  -- Training Yard
  heat       = {},   -- shared lineage heat, values for lineage ids 1..13
  idle_carts = {},   -- { cart_id, tier, durability, cap, refit }
  cart_upgrades = {},  -- { cart_id, target_tier, secs_left, mats_total, mats_done, mats, target_refit, job_type }
  ships      = {},   -- { name, tier, state, target, return_in, ship_id, crew }
  wstock     = {},   -- { good, amount, freshness_pct }
  wh_cap     = nil,  -- real warehouse capacity incl. steward/lager/star bonuses
  market_orders = {},  -- { id, buyer, good, remaining, price, age_secs }
  vfind = { tier = 0, postings = {}, offers = {}, auctions = {} },
  incoming_fills = {},  -- { good, seller, amount, arrives_in }
  blot_status= "",   -- "open" | "complete" | "rest"
  blot_reset_in = 0,
  blot_filled   = 0,
  blot_total    = 9,
  farm_plots = {},   -- { coord, shroom, time_left, fertilized }
  farm_wmod   = 0,    -- weather growth modifier for farm (e.g. +15 or -10)
  -- Buildings under construction
  pending_builds = {},  -- { bldg_id, tier, mats_total, mats_done, complete_at_secs, total_build_secs, mats }
  ship_upgrades  = {},  -- { name, tier, secs_left, mats_total, mats_done, mats }
  route_builds   = {},  -- ["kind:vid"] = { vid, name, kind, tier, mats_total, mats_done, complete_at_secs, total_build_secs, mats }
  -- City
  settlers     = 0,
  settler_mood = 0,
  settler_tax  = 0,
  city_water   = 0,
  city_fert    = 0,
  settler_edict = "",
  settler_edict_left = 0,
  settler_edict_cd = 0,
  settler_housing_cap = 0,
  settler_housing_plots = 0,
  settler_housing_avg = 0,
  settler_housing_quality = 0,
  settler_housing_upkeep = 0,
  settler_jobs = 0,
  settler_employed = 0,
  settler_market_staffed = 0,
  settler_mult_pct = 100,
  settler_security = 0,
  settler_dignity = 0,
  settler_flourishing = 0,
  settler_community_net = 0,
  settler_community_upkeep = 0,
  settler_sustenance = 0,
  settler_emp_score = 0,
  settler_sentiment = 0,
  settler_actions = {}, -- { { name, secs } }
  settler_events = {},  -- { { ts, msg } }
  settler_projects = {}, -- { id, kind, from_tier, to_tier, secs_left, mats_total, mats_done, mat_detail }
  settler_housing_plot_tiers = {}, -- { t1=count .. t5=count }
  settler_supply_next = 0,
  settler_pop_next = 0,
  dispatch_cd = 0,
  settler_community_buildings = {}, -- { civic_id=tier }
  settler_consumption = {}, -- { good=amount }
  settler_roles = {},       -- { {key,label,cur,tgt,work,bonus,effect}, ... }
  city_plan = {},           -- { enabled,dim,uoff,udim,coast,moat,wall,gate,mood,perks,rows={},blds={} }
  settler_commoner = 0,     -- idle populace percent
  settler_identity = "",    -- city identity title from dominant designation
  garrison_stationed = 0,
  garrison_free      = 0,
  garrison_cap       = 0,
  garrison_defpower  = 0,
  varang_out = {},   -- { { name, count, expires_in } } contracts dispatched
  varang_in  = {},   -- { { name, count, expires_in } } reinforcements received
  raid_in            = -1,   -- -1 = no raid; >= 0 = seconds until raid arrives
  raid_faction       = "",
  raid_strength      = 0,
  buildings          = {},   -- { [bldg_id] = tier }
  monuments          = {},   -- array of inscription strings
  monument_cap       = 0,    -- max slots (guild_level / 5)
  -- Guild.Livestock. Read by pages/livestock.lua and by autoherd.lua's planner.
  herds = {}, bqueue = {}, bqueue_used = 0, bqueue_max = 0,
  lfeed = {}, lpending = {}, lfind = { posts = {}, offers = {}, auctions = {} },
  lmarket = {}, lneeds = {},
  -- Has Guild.Livestock arrived this connection? Set by handlers/livestock.lua's
  -- write_herds (herds is always sent, even empty) and cleared by
  -- reset_connection below, so it is strictly per-connection. Auto-Herd's tick
  -- gates its spending on it: Guild.City and Guild.Livestock are separate
  -- slow-cadence panels, so a planner gated only on S.buildings runs while
  -- every herd still reads empty.
  livestock_seen = false,
  thralls          = 0,
  thralls_longhouse = 0,
  thralls_warehouse = 0,
  thrall_assignments = {},
  thrall_follower_level = 0,
  thrall_follower_name = "",
  thrall_follower_xp = 0,
  thrall_follower_xp_cap = 0,
  thrall_follower_carry_used = 0,
  thrall_follower_carry_cap = 0,
  thrall_follower_status = "none",
  missions = {},   -- { id, label, reward_rep, reward, expires_in, origin_town, target_town, want_goods }
  errand   = nil,  -- { id, label, reward, expires_in, origin_town, target_town, reward_good, reward_qty } or nil
  mission_reg_left = -1,  -- regular missions remaining this period (-1 = unknown)
  mission_new_left = -1,  -- newbie errands remaining this period (-1 = unknown)
  bdmg     = {},   -- { bldg_id, pct }
  staff_list = {},  -- { name, assigned_to, stat_key, stats={combat=N,...}, trait, loyalty, age, arrive_at }
  staff_total = 0,     -- how many staff the guild has
  staff_slices = 0,    -- how many rotating slices that list is sent in
  staff_by_slice = {}, -- [index] = slice, accumulated across pushes
  hird_list  = {},  -- { name, status, level, mode }
  hird_by_id = {},    -- [id] = hird record; what Bonds resolves pair ids against
  hird_total = 0,     -- how many hirdmadrs the guild has
  hird_slices = 0,    -- how many rotating slices that list is sent in
  hird_by_slice = {}, -- [index] = slice, accumulated across pushes
  bonds_list  = {},  -- { id_a, id_b, ticks, tier }
  standings   = {},  -- { [lin_id] = { name, score, label, is_own } }
  village_rep = {},  -- { [lin_id] = { name, rep, rank, next_at } }
  -- Trade goods demand/supply per settlement (from mip_trade_goods toggle)
  -- trade_goods[lin_id][good] = { score, supply, demand, buy, sell }
  trade_goods = {},
  -- Rolling price history kept by THIS plugin (auto-persisted via OnPluginSaveState).
  -- price_history[lin_id][good] = { {t=epoch, b=buy, s=sell}, ... } (oldest first)
  price_history = {},
  daler        = -1, -- current daler balance (-1 = not yet received)
  -- Auto-Trade (arbitrage) settings; on/off lives in page_opts.auto_trade.
  -- use_stock: sell matching goods already in the warehouse before buying more.
  -- last_msg: the most recent action, shown on the Goods tab.
  -- pack/status/last_jobs: set by LEGACY's client-side auto-trade tick/menu
  -- (guild_viking.lua:3433,3443,3448), which is stage 4's control surface --
  -- not populated yet, but the Goods page (Task 8) already reads them for
  -- content fidelity with draw_page6's Auto-Trade status block.
  autotrade    = { reserve = 0, min_margin = 3, min_profit = 200, max_carts = 2, last = 0,
                   use_stock = false, auto_stock = 0, last_msg = "", show_n = 6, log = {},
                   stock_priority = true, pack = false, status = "", last_jobs = nil },
  route_upkeep = 0,  -- total road+fort maintenance cost, daler/tick (from RUPKEEP)
  next_tick_in = 0, -- seconds until next trade/stock production tick
  demand_cycle = "",
  demand_cycle_in = 0, -- seconds until next demand cycle shift
  -- Weather / season
  weather         = "",   -- clear|overcast|rain|storm|fog|snow|blizzard
  weather_str     = 1,    -- 1=light 2=moderate 3=heavy
  season          = "",   -- spring|summer|autumn|winter
  god_power_name  = "",
  god_power_next  = 0,
  god_power_next_at = 0,
  god_power_focus = "",
  mip_voyage_seen = false,
  voyage_longships = {},
  voyage_status = nil,
  voyage_chart_width = 0,
  voyage_chart_height = 0,
  voyage_chart_mode = "",
  voyage_chart_rows = {},
  voyage_queue = {},
  voyage_saga = {},
  voyage_memory = {},
  voyage_wait = "",
  voyage_resolve_options = {},
  voyage_boons = "",
  voyage_spoils_daler = 0,
  voyage_goods = {},
  voyage_aids = {},
  voyage_runes = {},
  voyage_relics = {},        -- rendered "Name xN" strings
  voyage_relic_names = {},  -- relic id -> display name, from Guild.Voyage
  voyage_curios = {},
  voyage_reagents = 0,  -- Nikr's Bile phials secured this voyage (VREAGENT)
  -- Territory map (from send_mip_map / vtoggle mip_map)
  vmap_w    = 0,
  vmap_h    = 0,
  vmap_px   = -1,
  vmap_py   = -1,
  -- 1-INDEXED Lua storage for a 0-based wire row: handlers/voyage.lua's
  -- vmr_row/mee_row/mes_row store at [ridx + 1] for wire row ridx (LEGACY
  -- 2571-2579), locked by guild_viking_voyage_test.lua:304-306. A reader
  -- that wants 0-based grid row r must index [r + 1].
  vmap_rows = {},   -- [wire row + 1] = row_string
  vmap_east_edges  = {}, -- [wire row + 1] = east edge passability string
  vmap_south_edges = {}, -- [wire row + 1] = south edge passability string
  vmap_pois = {},   -- { type, name, x, y, owner }
  vmap_pois_keys = {},          -- { "x,y" = true } dedup lookup
  -- 1 while the player is standing on the biome grid, 0 while vmap_px/py are
  -- the last position we saw them at. Starts at 1 because Guild.Map's first
  -- frame after connect is a full one and always carries it -- the value only
  -- ever matters once a real frame has set it.
  vmap_active = 1,
  -- True once any Guild.Map frame has reached the writer, regardless of what
  -- it carried. popups/map.lua uses it to distinguish a missing frame from an
  -- empty map.
  vmap_seen = false,
  -- Guild.Map decoding context, cached across delta frames: `enc` names each
  -- plane's encoding, `legend`/`legend_edge` explain its codes, and
  -- vmap_terrain_glyphs is the code -> glyph table derived from `legend`.
  -- Cleared on disconnect (see reset_connection): decoding a fresh packed
  -- plane against a previous connection's legend draws a wrong map that
  -- looks entirely plausible.
  vmap_enc = nil, vmap_legend = nil, vmap_legend_edge = nil,
  vmap_terrain_glyphs = nil,
}

local M = { S = state }

function M.reset_connection()
  state.combat = false
  state.chain = 0
  state.bsdepth = 0
  state.vitals_gmcp = false
  state.en5 = "None"
  state.ens = ""
  state.rndz = 0
  state.mob_name_full = "None"
  state.estatus_pct = 0
  state.combat_rounds = 0
  state.stfx = {}
  state.vis_gain, state.kap_gain, state.soe_gain, state.aud_gain = 0, 0, 0, 0
  -- Guild data itself is deliberately preserved across a reconnect, but the
  -- claim that it has ARRIVED this connection is not -- see the field comment.
  state.livestock_seen = false
  state.herd_connection_epoch = (state.herd_connection_epoch or 0) + 1
  state.herd_observed = {}
  -- The map planes themselves are left standing (a reconnect redraws them on
  -- the next Guild.Map push, and a blank map in the meantime helps nobody),
  -- but their decoding context is not: see the field comments above.
  state.vmap_enc = nil
  state.vmap_legend = nil
  state.vmap_legend_edge = nil
  state.vmap_terrain_glyphs = nil
end

return M
