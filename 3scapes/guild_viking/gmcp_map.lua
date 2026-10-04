-- GMCP payload key -> the internal handler key it routes to.
--
-- The handler keys are still the uppercase spellings the MIP wire used. That
-- is deliberate: they are load-bearing in every handler module and in the
-- census, and renaming them buys nothing behavioural. The MIP wire decoder
-- that used to live at the bottom of this file is gone with the transport.
--
-- The map is a table of explicit entries rather than a naming rule because
-- three keys break the rule: `queue` is renamed, and MONUMENTS and SROLES are
-- each split across two GMCP keys. Everything else is the uppercase of its
-- GMCP key, listed anyway so an unrecognized key is unmapped by construction
-- and therefore counted rather than routed somewhere plausible.

local M = {}

M.COMPOSITE = {
  MONUMENTS = { "monuments_cap", "monuments_list" },
  SROLES    = { "sroles", "sroles_meta" },
  -- Guild.Fleet. raidlog's per-entry goods breakdown is a mapping, which a
  -- record used as a container element may not hold, so the server flattens
  -- it to its own top-level key foreign-keyed by `idx`; the two halves have
  -- to reach one writer to be rejoined. rtargets never had a _v_ builder --
  -- MIP joined two arrays with a '|' -- so GMCP sends them as the two arrays
  -- they always were, and the writer keeps MIP's lineage-then-historical
  -- order for the flat name list.
  RAIDLOG   = { "raidlog", "raidlog_goods" },
  RTARGETS  = { "rtargets_lineage", "rtargets_historical" },
  -- Guild.Roster. Each of these four was one MIP value with an internal
  -- separator ('!' for courier/spy/vfind, '^' for varang) packing what the
  -- server holds as separate structures; GMCP sends the structures, so the
  -- writer gathers them back into the one state table the pages read.
  COURIER   = { "courier", "courier_tier" },
  SPY       = { "spy", "spy_scouts" },
  VARANG    = { "varang_out", "varang_in" },
  VFIND     = { "vfind_hall", "vfind_posts", "vfind_offers", "vfind_auctions" },
  -- Guild.Trade. Three of these are the same depth-limit flattening raidlog
  -- uses: a cart's legs, a queued job's legs and a refinery's grade breakdown
  -- are containers, which a record used as a container element may not hold,
  -- so each travels as its own top-level array foreign-keyed back to its
  -- parent. MIP packed all three INSIDE their parent key, and the Trade pages
  -- render them, so they are rejoined here rather than dropped.
  CARTS     = { "carts", "cart_legs", "cart_extra" },
  TQUEUE    = { "queue", "queue_legs" },
  REFINERY  = { "refinery", "refinery_grades" },
  WSTOCK    = { "wstock", "wstock_cap" },
  -- Guild.City. MONUMENTS was already declared composite (its cap and its name
  -- list are separate keys) and now has a writer. FARM is the same shape: MIP
  -- packed the meta into the plot list as a "meta|" pseudo-entry, GMCP gives it
  -- its own key.
  FARM      = { "farm_meta", "farm_plots" },
  -- The city plan. MIP spread this over CPLAN/CPT/CPB/CPU/CPP with a commit
  -- protocol; GMCP sends it whole, which is why the server deliberately does
  -- not translate CPEND -- page/pages plus the delta cache already say when a
  -- push is complete.
  CPLAN     = { "cityplan", "cityplan_terrain", "cityplan_buildings",
                "cityplan_placeable", "cityplan_perks" },
  -- Guild.Voyage. A voyage's and a longship's crew/ship trait lists are
  -- containers a record may not hold, so the server deletes them from the
  -- record and sends each as its own key -- per ship, keyed by `id`. voffers
  -- likewise splits the ship name off the offer list MIP packed together.
  VOYAGE    = { "voyage", "voyage_crew_traits", "voyage_ship_traits" },
  -- vrelics travels as raw relic ids; the display names the Sea popup renders
  -- arrive beside it in vrelic_names, keyed by those same ids. Composite so
  -- one writer sees whichever halves a delta frame carried.
  VRELICS   = { "vrelics", "vrelic_names" },
  LONGSHIP  = { "longship", "longship_crew_traits", "longship_ship_traits" },
  VOFFERS   = { "voffers", "voffers_ship" },
  -- The Sea Chart: a width/height/mode record plus its rows, which a record
  -- may not nest. MIP spread the same data over VCHH, VCHART and a numbered
  -- VCR%02d row burst.
  VCHART    = { "voyage_chart", "voyage_chart_rows" },
  TGOODS    = { "tgoods_0", "tgoods_1", "tgoods_2", "tgoods_3", "tgoods_4",
                "tgoods_5", "tgoods_6", "tgoods_7", "tgoods_8", "tgoods_9",
                "tgoods_10", "tgoods_11", "tgoods_12", "tgoods_13",
                "tgoods_14" },
  -- Guild.State's player vitals. Unlike every other entry here, VITALS is not
  -- the name of a MIP key -- see handlers/vitals.lua's header for why this
  -- block gets a label of its own instead of being split across the three or
  -- four MIP keys its data used to arrive on. It is declared composite for the
  -- ordinary reason: eleven GMCP keys, one writer, and a delta frame that may
  -- carry any subset of them.
  -- staff's chunk keys plus its two counters reach one writer: a delta may
  -- carry any subset, and the writer has to see them together to rebuild the
  -- list in order without a half-applied frame blanking it.
  -- One ROTATING slice per push, not the whole list: the server walks a cursor
  -- so each push stays inside the page budget, and the client accumulates the
  -- slices. staff_slices says how many there are, so a page can tell whether
  -- it has seen a full set yet.
  STAFF     = { "staff_total", "staff_slices",
                "staff_0", "staff_1", "staff_2", "staff_3",
                "staff_4", "staff_5", "staff_6", "staff_7" },
  HIRD      = { "hird_total", "hird_slices",
                "hird_0", "hird_1", "hird_2", "hird_3" },
  VITALS    = { "hp", "sp", "points", "chain", "gxp", "tox", "fx",
                "encounter", "target", "ledung", "bars" },
  -- Guild.Kingdom. army and dynasty each flatten a nested container out of
  -- their records -- a unit's traits, and a child's schooling rows -- and
  -- dynasty additionally splits its scalars into one key each. war is three
  -- named sections MIP joined into a single value.
  ARMY      = { "army", "army_units", "army_traits" },
  DYNASTY   = { "dynasty_realm", "dynasty_house", "dynasty_heir",
                "dynasty_living", "dynasty_cap", "dynasty_children",
                "dynasty_schooling", "dynasty_spouse" },
  WAR       = { "war_cb", "war_camp", "war_incoming" },
  -- The campaign war map, folded into Guild.Kingdom. MIP spread it over
  -- WMAP/WMR/WMO/WMQ/WMU/WMP/WMPL/WSG/WSPOIL with a burst-and-commit protocol;
  -- WMEND, its row-count sentinel, is deliberately untranslated for the same
  -- reason CPEND is.
  WMAP      = { "campaign", "campaign_terrain", "campaign_units",
                "campaign_queue", "campaign_prison", "campaign_prison_roster",
                "campaign_siege", "campaign_siege_queue" },
  -- Guild.Map is composite in full, not per key. Its planes cannot be read
  -- without `enc` (which encoding packed them) and `legend` (what each code
  -- means), and its rows cannot be sized without `w` -- so routing the keys
  -- individually would hand a writer a packed plane it has no way to decode.
  -- Gathering the frame's keys into one call is exactly what the composite
  -- path exists for; the writer still treats every member as optional,
  -- because ordinary frames are deltas and a step sends `pos` alone.
  VMAP      = { "w", "h", "active", "pos", "legend", "legend_edge", "enc",
                "terrain", "east", "south", "landmarks", "landmark_rev",
                "landmark_chunk", "landmark_chunks" },
  -- Guild.Livestock. bqueue is a sibling split of one server mapping
  -- (_v_bqueue()'s used/max/slots). lfind was three MIP values '!'-joined.
  BQUEUE = { "bqueue_used", "bqueue_max", "bqueue" },
  LFIND  = { "lfind_posts", "lfind_offers", "lfind_auctions" },
  -- lmarket is ONE key PER LINEAGE, and a lineage with no pool sends no key
  -- at all -- so this composite is variable-arity by necessity. That is
  -- already how GMCP composites work (protocol.lua: the writer gets whichever
  -- halves this frame had); do not confuse it with the MIP-side
  -- KEY_<n>of<m> batch mechanism, which IS fixed-arity.
  LMARKET = { "lmarket_1", "lmarket_2", "lmarket_3", "lmarket_4",
              "lmarket_5", "lmarket_6", "lmarket_7", "lmarket_8",
              "lmarket_9", "lmarket_10", "lmarket_11", "lmarket_12",
              "lmarket_13" },
}

-- Packages whose ENTIRE payload is one MIP key's data, dispatched as a unit
-- without consulting the key map below.
--
-- This is not a convenience. The key map is a single flat table keyed by GMCP
-- key name, which works only while a name means the same thing in every
-- package -- and Guild.War breaks that: its `w`, `h`, `active` and `terrain`
-- are the battle board's, while Guild.Map's keys of exactly those names are
-- the territory map's. Routed through the flat map, a battle's grid would
-- overwrite the territory map. Guild.War is a whole package for one MIP key
-- anyway, so dispatching it as a unit sidesteps the ambiguity rather than
-- teaching every lookup about packages.
--
-- Keyed by the sub-package name -- the part after "Guild." -- compared
-- case-insensitively, like the guild name in the envelope.
M.PACKAGE_KEY = {
  war = "BATTLE",
  tradegoods = "TGOODS",
}

-- The sub-package a Guild.* package name names, lowercased, or nil.
function M.package_key(package)
  local sub = tostring(package or ""):match("^[Gg][Uu][Ii][Ll][Dd]%.(.+)$")
  if not sub then return nil end
  return M.PACKAGE_KEY[sub:lower()]
end

local MAP = {
  -- Guild.Settlement
  settlers = "SETTLERS", settlerx = "SETTLERX", sactions = "SACTIONS",
  shplots = "SHPLOTS", scivics = "SCIVICS", sproj = "SPROJ",
  sevents = "SEVENTS", sconsume = "SCONSUME",
  sroles = "SROLES", sroles_meta = "SROLES",

  -- Guild.City
  rbuild = "RBUILD", bdmg = "BDMG", upkeep = "UPKEEP", rupkeep = "RUPKEEP",
  cdtime = "CDTIME", raid = "RAID", heat = "HEAT", patrol = "PATROL",
  builds = "BUILDS", garrison = "GARRISON", buildings = "BUILDINGS",
  monuments_cap = "MONUMENTS", monuments_list = "MONUMENTS",
  cityplan = "CPLAN", cityplan_terrain = "CPLAN",
  cityplan_buildings = "CPLAN", cityplan_placeable = "CPLAN",
  cityplan_perks = "CPLAN",
  blot = "BLOT", weather = "WEATHER", dcycle = "DCYCLE", nexttick = "NEXTTICK",
  production = "PRODUCTION", farm_meta = "FARM", farm_plots = "FARM",

  -- Guild.Livestock
  herds = "HERDS", lfeed = "LFEED", lpending = "LPENDING", lneeds = "LNEEDS",
  bqueue_used = "BQUEUE", bqueue_max = "BQUEUE", bqueue = "BQUEUE",
  lfind_posts = "LFIND", lfind_offers = "LFIND", lfind_auctions = "LFIND",
  lmarket_1 = "LMARKET", lmarket_2 = "LMARKET", lmarket_3 = "LMARKET",
  lmarket_4 = "LMARKET", lmarket_5 = "LMARKET", lmarket_6 = "LMARKET",
  lmarket_7 = "LMARKET", lmarket_8 = "LMARKET", lmarket_9 = "LMARKET",
  lmarket_10 = "LMARKET", lmarket_11 = "LMARKET", lmarket_12 = "LMARKET",
  lmarket_13 = "LMARKET",

  -- Guild.Roster. gneeds and rneeds are deliberately absent: they have no MIP
  -- counterpart and no consumer, so they stay counted under their own names.
  -- staff arrives capped and chunked (staff_0, staff_1, ...) with its own
  -- total/shown scalars, the same shape Guild.Market's order book uses: a
  -- 64-staff roster does not fit a package's 8-page budget, so the server
  -- sends a bounded prefix that SAYS it is one.
  staff_total = "STAFF", staff_slices = "STAFF",
  staff_0 = "STAFF", staff_1 = "STAFF", staff_2 = "STAFF", staff_3 = "STAFF",
  staff_4 = "STAFF", staff_5 = "STAFF", staff_6 = "STAFF", staff_7 = "STAFF",
  hird_total = "HIRD", hird_slices = "HIRD",
  hird_0 = "HIRD", hird_1 = "HIRD", hird_2 = "HIRD", hird_3 = "HIRD",
  bonds = "BONDS", train = "TRAIN",
  thralls = "THRALLS", thrall_follower = "THRALL_FOLLOWER",
  courier = "COURIER", courier_tier = "COURIER",
  spy = "SPY", spy_scouts = "SPY",
  varang_out = "VARANG", varang_in = "VARANG",
  vfind_hall = "VFIND", vfind_posts = "VFIND",
  vfind_offers = "VFIND", vfind_auctions = "VFIND",

  -- Guild.State. The vitals block routes to the one VITALS writer declared
  -- above; combat.lua's output-line triggers are the fallback for it now,
  -- latched off once a frame arrives, rather than the sole source they were.
  -- The attacker block stays with Char.Combat -- a purpose-built package that
  -- carries the enemy hp percent Guild.State's target group does not.
  hp = "VITALS", sp = "VITALS", points = "VITALS", chain = "VITALS",
  gxp = "VITALS", tox = "VITALS", fx = "VITALS", encounter = "VITALS",
  target = "VITALS", ledung = "VITALS", bars = "VITALS",
  daler = "DALER", god = "GOD_POWER",
  missions_reg = "VMREG", missions_newbie = "VMNEW",

  -- Guild.Kingdom
  grudges = "GRUDGES", standings = "STANDINGS", vrep = "VREP", diplo = "DIPLO",
  army = "ARMY", army_units = "ARMY", army_traits = "ARMY",
  dynasty_realm = "DYNASTY", dynasty_house = "DYNASTY",
  dynasty_heir = "DYNASTY", dynasty_living = "DYNASTY",
  dynasty_cap = "DYNASTY", dynasty_children = "DYNASTY",
  dynasty_schooling = "DYNASTY", dynasty_spouse = "DYNASTY",
  war_cb = "WAR", war_camp = "WAR", war_incoming = "WAR",
  campaign = "WMAP", campaign_terrain = "WMAP", campaign_units = "WMAP",
  campaign_queue = "WMAP", campaign_prison = "WMAP",
  campaign_prison_roster = "WMAP", campaign_siege = "WMAP",
  campaign_siege_queue = "WMAP",


  -- Guild.TradeGoods. One key per lineage rather than one array: the flat list
  -- runs to about 420 records, and a container over PROTOCOL_GUILD_NEST_MAX
  -- (128) is refused whole during validation and the key dropped silently.
  -- Declared explicitly for all fifteen lineage ids rather than matched by
  -- pattern, so an id outside the range is counted rather than routed.
  tgoods_0 = "TGOODS", tgoods_1 = "TGOODS", tgoods_2 = "TGOODS",
  tgoods_3 = "TGOODS", tgoods_4 = "TGOODS", tgoods_5 = "TGOODS",
  tgoods_6 = "TGOODS", tgoods_7 = "TGOODS", tgoods_8 = "TGOODS",
  tgoods_9 = "TGOODS", tgoods_10 = "TGOODS", tgoods_11 = "TGOODS",
  tgoods_12 = "TGOODS", tgoods_13 = "TGOODS", tgoods_14 = "TGOODS",

  -- Guild.Voyage. vrelics used to sit out here, because GMCP carried relic ids
  -- and only the MIP serializer knew their display names. The payload carries
  -- the names now, in vrelic_names, so it is a composite like the rest.
  voyage = "VOYAGE", voyage_crew_traits = "VOYAGE", voyage_ship_traits = "VOYAGE",
  longship = "LONGSHIP", longship_crew_traits = "LONGSHIP",
  longship_ship_traits = "LONGSHIP",
  voffers = "VOFFERS", voffers_ship = "VOFFERS",
  voyage_chart = "VCHART", voyage_chart_rows = "VCHART",
  voyage_wait = "VOYAGE_WAIT", vresolve = "VRESOLVE", vqpath = "VQPATH",
  vsaga = "VSAGA", vmem = "VMEM", vcurios = "VCURIOS", vgoods = "VGOODS",
  vaids = "VAIDS", vrunes = "VRUNES", vboons = "VBOONS", vsailed = "VSAILED",
  vrelics = "VRELICS", vrelic_names = "VRELICS",
  vspoils = "VSPOILS", vreagent = "VREAGENT", fleet_renown = "FLEET_RENOWN",

  -- Guild.Fleet
  ships = "SHIPS", supg = "SUPG",
  raidlog = "RAIDLOG", raidlog_goods = "RAIDLOG",
  rtargets_lineage = "RTARGETS", rtargets_historical = "RTARGETS",

  -- Guild.Map (all composite; see M.COMPOSITE above)
  w = "VMAP", h = "VMAP", active = "VMAP", pos = "VMAP", legend = "VMAP",
  legend_edge = "VMAP", enc = "VMAP", terrain = "VMAP", east = "VMAP",
  south = "VMAP", landmarks = "VMAP", landmark_rev = "VMAP",
  landmark_chunk = "VMAP", landmark_chunks = "VMAP",

  -- Guild.Trade
  carts = "CARTS", cart_legs = "CARTS", cart_extra = "CARTS",
  queue = "TQUEUE", queue_legs = "TQUEUE",
  refinery = "REFINERY", refinery_grades = "REFINERY",
  wstock = "WSTOCK", wstock_cap = "WSTOCK",
  cidle = "CIDLE", cupg = "CUPG",
  routes = "ROUTES", blocks = "BLOCKS",
  market = "MARKET", incoming = "INCOMING", missions = "MISSIONS",
  errand = "ERRAND",

  -- Deliberately absent, so they are counted rather than routed:
  --   crpr           (cart repairs -- no MIP key ever carried it and nothing
  --                   renders it)
  --   gneeds, rneeds (Guild.Roster; same reason)
  --
  -- cart_legs, queue_legs and refinery_grades used to be listed here on the
  -- grounds that nothing renders them. That was wrong: MIP packed each one
  -- inside its parent key, and the Trade pages read carts' `legs`, the trade
  -- queue's `legs` and a refinery's `grades`. They are composites now.
}

function M.mip_key(gmcp_key)
  return MAP[tostring(gmcp_key)]
end

return M
