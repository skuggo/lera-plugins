# Lera Plugins

> **Mirrored into [lundmark/lera](https://github.com/lundmark/lera) at
> `plugins/`** as a git subtree. Day-to-day development happens there and is
> pushed here periodically; PRs against this repository are welcome and get
> pulled back into lera after merge. Both directions preserve history, which
> is why a merged PR here reappears in lera with its original commits.

Plugin collection for the Lera MUD client.

## Legacy parity validation

The repeatable validation workflow, its public/private trust boundary, and safe
operating rules are documented in
[validation/README.md](validation/README.md). Public CI verifies committed
artifact consistency only; it cannot authenticate private approval or private
legacy-source parity.

## Structure

```
lera-plugins/
├── generic/      # Plugins that work with any MUD
├── 3scapes/      # Plugins specific to 3scapes MUD
└── examples/     # Example/test plugins for learning
```

## Installation

Copy plugins to your profile's plugin directory or load them directly:

```lua
plugin.load("/path/to/lera-plugins/generic/deadmans")
```

## Viking livestock GMCP chunks

Viking already uses all 16 server package slots, so core and market pushes share
`Guild.Livestock`. No new package or extra subscription is needed; the existing
root `Guild` registration handles both. The core payload has seven keys:
`herds`, `bqueue_used`, `bqueue_max`, `bqueue`, `lfeed`, `lpending`, and `lneeds`.
Separate bounded market payloads carry at most two lineage lists from
`lmarket_1` through `lmarket_13`, plus `lfind_posts`, `lfind_offers`, and
`lfind_auctions`, with the numeric marker `lmarket_partial = 1`.

The marker survives protocol page reassembly and is recognized as metadata, not
an unknown state key. Only numeric `1` on `Guild.Livestock` overrides `full`, and
only for the `LMARKET` composite; `false`, `true`, and string `"1"` do not opt in.
Each delivered lineage list replaces that lineage atomically after reassembly.
Omitted lineages retain their rows and original receipt timestamps; explicit
`[]` clears exactly its lineage. Market-only pushes neither synthesize pending
proof nor refresh core receipt evidence. Consecutive core-only full pushes leave
the market untouched. Unmarked legacy bulk full pushes still evict omitted
lineages when market keys are present. The server's existing eight-page transport
limit and secure implementation are unchanged.

## Viking Auto-Herd quality purchases

Quality buys must meet the configured raw stat-score margin and improve the
forecast weighted herd score. Compact `management` metadata enables hundredth-point
averages: fractional gains count even when the whole-point display would not move.
Legacy records retain whole-point averaging and whole-lot purchase semantics.
Trait preferences only rank eligible lots and are ignored when the herd has a trait.

Complete `breeds` history accepts a comma-separated string or native array; an
explicit empty string is known empty history, while missing or malformed history
is unknown. With valid management, any purchased breed can
provide proportional generation relief, including a known breed, but refresh buys
must not degrade any stat. Only a genuinely new breed can earn hybrid bonuses.
Legacy refresh remains conservative: confirmed fresh history and no weighted loss.

Protected offers require exact `unit_price`, remaining `available`, a 32-hex `token`,
and valid herd management. Count is the minimum of lot/remaining stock, penfree,
and floor((daler - reserve) / unit_price); cost is count times unit price. Commands
are `vlivestock buy <lineage> <idx+1> <count> <token>`. Incomplete new metadata never
falls back to an unprotected command. Herd management confirms the upgraded schema
even if the frame budget omits all optional offer fields; that listing waits for
protected offer metadata rather than using a legacy buy. Upgraded GMCP includes
management for all owned pens, including head-zero pens, so Auto-Herd can stock an
empty pen with an exact count and token. Legacy records retain whole-lot semantics.

Rotating compact quotes are parsed and cleared when an offer row is replaced without
a quote. They are advisory only: the current wire lacks herd head/cap/pending identity,
and the token fingerprints the offer, not the herd. Auto-Herd therefore calculates
deterministic fixedpoint forecasts locally for the exact reserve-limited count;
parsed quotes are advisory and are not used to authorize purchases. Auto-Herd never
banks on random hybrid bonuses.
A future server quote would need a compact herd-state fingerprint (covering head,
cap, pending, stats and generation) before it could safely replace this forecast.
These are forecasts, not guaranteed arrival improvements or future-profit promises.

Pending deliveries pause further purchases to that pen. Full pens remain blocked
in normal Auto-Herd; existing toggles and reserve settings are unchanged.
Replacement below is a separate, default-off authorization for irreversible slaughter. Predictions use the currently reported herd, not a guarantee of
its state when animals arrive. Herd age now shows `Age:0` for a known zero and
`Age:?` when the server did not report an age.

### Opt-in herd replacement and forecast

Replacement is **off by default** and requires the upgraded server management metadata
and guarded count/token purchase commands. The corresponding server changes are prepared
separately but are not deployed by this plugin update. Legacy feeds never authorize
replacement slaughter. If an offer disappears after culling, the planner halts and the
herd can remain smaller; it does not repeatedly cull or buy an unprotected substitute.
Server auto-slaughter must already be off; the plugin does not change that setting.

**`/vik herd replace on` authorizes irreversible slaughter**, but sends nothing
itself. Execution starts only on a later tick with master `/vik herd on` also on,
normal buying neither confirming nor cooling down, and fresh validated state.
Loading, configuring settings, status and previews never send commands or request refreshes.
No viable replacement leaves ordinary safe purchases available; an active or halted
replacement blocks all ordinary Auto-Herd until completion or explicit acknowledgement.

Commands (all prefixed `/vik herd`):

- `refresh`: request a read-only GMCP resync using only
  `gmcp.send('Core.Supports.Add', {'Guild 1'})` (never `Set`, which would replace
  other subscriptions). The explicit command requires only a live connection and
  negotiated GMCP; no prior livestock receipt is needed, so it can bootstrap missing
  herd data after a plugin reload. Requests, including failed sends,
  are debounced for 60 seconds using `os.time()`. This is **a request, not confirmation**:
  the server clears namespace delta caches but does not accelerate its schedule.
  Allow ~15 seconds for livestock/city and up to ~5 minutes for the trade grid.
  No game commands, saves, toggle changes, job resets or receipt timestamp changes.
  With replacement already authorized **and** master Auto-Herd on, an idle tick
  blocked by stale receipts may request the same resync at most once per 120 seconds,
  only with Viking livestock already received on this connection and no ordinary
  action, pending deliveries, butchery queue or local job.
  Busy, halted and reconnect-settling ticks never automatically refresh. Actual
  incoming receipts—not requests—restore freshness, including unchanged fields
  that would otherwise remain older than their replacement freshness limit forever.
- `forecast` or `replace preview`: read-only gross opportunity, purchase cost,
  conservative lower scenario and **advisory high**, with assumptions/exclusions or
  the blocking reason. No sends, refresh requests, configuration initialization,
  recovery or saves. Works with either toggle off and can show negative opportunities
  below the execution profit threshold. Connection, freshness, budget, metadata and
  unresolved-job gates still apply. Known legacy management metadata is reported
  before generic stale receipts; unavailable production is not replaced with zero.
  Rejected previews show at most five additional lines, one per owned pen, sorted by
  building. Reasons come from actual candidate gates: full head/cap, server
  auto-slaughter, disabled pen, protected/minimum keep/cull fraction, pending,
  same-species offer availability/freshness/validity/protected metadata, cost versus
  reserve/budgets, raw quality margin/no gain, production/prices, or unknown forecast.
  When several matching offers fail, the furthest validation gate is shown (lexical
  tie-break); this is a representative rejection, not an exhaustive list. Other
  species are ignored. A global gate instead retains its existing summary. Details
  print only for explicit CLI previews, never unsolicited on ticks.
- `replace on|off|status|reset`: off retains any unresolved halt. Reset rejects active
  jobs: turn replacement off, **manually inspect herd, butchery queue and deliveries**,
  then reset to acknowledge uncertain server state. Reset leaves replacement off and
  retains daily exposure; it does not undo slaughter or purchases.
- `replace maxcost N`, `dailycost N`, `dailycull N`, `maxcull N`, `keep N`,
  `minprofit N`, `horizon N`, `gap N`, `overhead N` (repeat `replace` for each command).
  Cost limits/counts/ticks are nonnegative integers; horizon is positive and gap
  cannot exceed horizon. Profit may be signed/fractional; overhead is nonnegative.
  CLI values must be finite with magnitude at most 1e9. Module defaults: maxcost 500,
  dailycost 2000, dailycull 10, maxcull 2, keep 4, minprofit 0, horizon 8, gap 1.
  The module additionally caps each cull at 10% of the pen and respects protected stock.
- `model <building> output N`: explicitly configure current **whole-herd** output
  units per forecast tick (not output per animal), overriding automatic observations.
  Nonnegative finite number; pigs/horses have known zero direct output by default
  and do not permit a nonzero direct-output model. Horse transport is not valued.
- `model <building> share N`: fraction of output responding to yield, **0..1, not
  percent**. Optional advisory ratio assumption; omission never invents a share or
  midpoint. Even an explicit share cannot turn a positive ratio gain into a lower-bound
  execution benefit: integer rounding and additive staff can erase that gain.

Replacement uses `price_max_age = 600` seconds by default for **only** the last full
TradeGoods grid receipt (`observed.prices`) and each selected meat/output price row's
actual `at` timestamp, including guarded-buy revalidation. The server refreshes
TradeGoods every 300 seconds; the 600-second window allows two refresh cycles,
including bounded scheduling jitter, but rejects age 601. The module option must be
a finite positive integer (no upper cap, matching `max_age`); no CLI option is added.
Missing, invalid or future receipts still block, and a fresh/partial grid cannot
promote stale selected rows. Cached reconnect data without current receipt evidence
is not accepted. Full-grid errors retain the `stale/missing prices` prefix and
identify missing/invalid receipts or the actual stale age and limit. Buying still
requires exactly unchanged selected quote values, not merely a recent timestamp.
Herds, pending deliveries, butchery queue, wallet, production and livestock offers
retain `max_age = 180`; destructive confirmation timeouts and cooldown are unchanged.

Explicit `forecast` / `replace preview` failures for `stale/missing prices` add one
read-only price-stream line: received/expected lineages before the first complete
grid, or the last complete receipt's age and current progress while receiving.
Legacy observed receipts still count as completion evidence after a handler reload.
Unknown `0/?` progress notes the server's next 300-second cycle. This diagnostic
never saves, sends commands/GMCP, or requests a refresh. Automatic retry/resync is
unchanged: its 120-second retry can still interrupt a long partial stream; progress
alone cannot safely suspend retries indefinitely without a bounded stream-age signal.

Without a manual output override, fresh validated `S.production` wool/eggs/milk
supplies the corresponding unique producer's **uncapped current whole-herd output**.
Its `herd_observed.production` receipt `{at,seq}` must be no older than `max_age`
(default 180 seconds), not in the future, and must come from the current connection:
connection reset clears receipt evidence. Cached production alone is not evidence.
The city handler must stamp only validated full production frames. Models are derived
on demand, never saved; manual output remains an explicit user assumption.

Gross preview uses the known zero direct purchase delivery/slaughter fees and zero
persistent same-head feed delta. **Sale transport and risk are excluded**, not assumed
free for execution. Execution still requires an explicit `replace overhead N` assumption,
even if `enabled=true` was previously saved. Set `replace overhead 0` only to knowingly
acknowledge zero additional sale transport/risk cost; preview never supplies this authorization.

The lower scenario credits **zero positive production gain** and charges up to the
**entire baseline output per gap tick**, not a culled fraction. A yield decline charges
whole baseline output after arrival too. High/explicit-share estimate and break-even
are advisory ratio scenarios, not guaranteed bounds or guaranteed profit. Horizon,
gap and manual models remain assumptions. No automatic meat/output sales or grain
buys are emitted. Random births, deaths, hybrids and disease are excluded; gap feed
savings are ignored and current quoted demand does not refresh across the horizon.

Integration API: `autoherd.replacement_context()` exposes raw state records, current
`os.time()`, connection/master flags, connection epoch, per-panel `{at,seq}` observations,
wallet/reserve/keep/weights/building settings and prices. Sell/demand comes from
`market.best_sell_of(good)` with the **currently selected** `S.trade_goods[lin][good]`
row's `_received_at`; missing timestamps remain unknown. Optional grain buy/supply uses
`best_buy_of`. Context also exposes production and its receipt evidence.
`replacement_preview()` calls the separate pure `herd_replace.preview` path with
copied options. Both preview APIs preserve the first two returns `(plan, reason)`
while adding a third array of `{building, reason}` rejections (empty for global
failures or no rejected owned pens). Pens with an eligible candidate are omitted.
`propose`/`step` retain execution authorization, candidate eligibility and profit gates.
No synthetic timestamps, production shares or execution overhead are supplied.

**Feed guard for new replacement jobs:** before the initial cull can reserve daily
budget or create a marker, integration applies the same `feed_guard` / `feed_ticks`
assessment as ordinary Auto-Herd: observed city-wide `lfeed.grain` is per-tick need,
warehouse grain is stock, and the buffer is `need * max(1, feed_ticks)`. When observed
need is unavailable, the existing owned/enabled herd-head fallback is used. With
107 grain / 33 per tick / a four-tick 132 buffer, no replacement job starts; exactly
132 permits it if all other gates pass. Explicit feed-off and custom buffer settings
are respected, never rewritten or lowered.

Only **new** replacement jobs are feed-gated. Busy cull/buy/delivery confirmations
and cooldown continue under their existing safety checks even when feed falls low,
so feed shortage alone does not abandon a smaller, already-culled herd. After
completion, another cull must pass the feed gate again. Ordinary purchase planning
retains its existing advisory feed behavior (it may still select a buy), unchanged
warning deduplication and planning interval; there is no separate tick-warning stream.

Preview remains pure and retains useful candidate forecasts/rejections even when
feed would block execution. `autoherd.replacement_preview()` adds a fourth return,
a feed-warning string or nil, without changing the first three. Explicit `forecast`
and `replace preview` print it separately as a **new replacement execution blocker**,
not as candidate ineligibility or an instruction to halt an existing job. The lower-level
`herd_replace.preview()` API is unchanged.

Replacement reserves daily purchase/cull exposure and persists its marker before
**every send**. Cull needs fresh matching herd **and** queue receipts before a guarded
count/token buy; pending and delivery receipts drive completion. Disconnect, master-off,
stale/drifting state, restart or send/persistence failure retains a halt, not a replay.
Persistence errors block ordinary automation too, even after later saves succeed,
until explicit reset. An idle configuration-save failure also creates a halt marker;
a best-effort save retains the halt across reloads if storage recovers. Recovery runs
once per settings-table reference. `persist.save()` throws an operation-specific error
when either `store.set()` or `store.save()` returns explicit `false`, and lets storage
exceptions propagate. A failed `store.set()` skips `store.save()` so stale data is not
written as if the new snapshot succeeded. Successful `persist.save()` still returns
nil; storage APIs returning nil without throwing remain accepted for legacy compatibility.
The replacement send guard catches these errors (and also rejects explicit false/error
returns from persistence), halts, and sends nothing. Tests exercise both native-style
boolean failures through the real persistence wrapper, not just mocked `persist.save()`.

## Commands

Every plugin command here is registered through the command registry, so it
appears in `/help` and the `/` palette and is owned by the plugin that declared
it:

```lua
local command
do
  local ok, mod = pcall(require, "command")
  if ok then command = mod end
end

function M.on_load()
  if not command then return end
  local id, err = command.register({
    name = "/thing",
    usage = "/thing [status|set <value>]",
    summary = "One line for /help and the palette",
    accepts_args = true,
    handler = dispatch,        -- receives everything after "/thing"
  })
  ...
end
```

The registry installs `^/name(?:\s+(.*))?$` and hands the handler the
remainder, so a plugin splits its own subcommands and validates its own
arguments rather than declaring one alias pattern per form.

`chat_monitor` is the one conditional registration: it claims `/chat` only when
`command.get("/chat")` is nil, so a profile that registered its own `/chat`
before plugins loaded keeps it — a plugin cannot replace a profile-owned
command. Hosted mode used to be that case; it no longer registers one.

Two plugins keep raw `alias.add` alongside their command, for input that cannot
be spelled as a slash token: `speedwalk`'s `.`, `..`, `.,`, `.place` and
`.from-to`, and `autostepper`'s `-`, `-.`, `->` and `-!`. Those are movement
syntax; everything word-shaped lives under `/speedwalk` and `/step`.

## Image surfaces

Directory plugins can load PNG assets relative to their own root and place
them over cell-aligned rectangles:

```lua
local M = {}
local icon, err = ui.image_load("assets/icon.png")
assert(icon, err)
local tile, tile_err = ui.image_load("assets/tile.png")
assert(tile, tile_err)

function M.on_render()
  local icon_rect = ui.rect(4, 2, 2, 1)
  ui.text(icon_rect, "[]") -- always draw useful fallback cells first
  ui.image(icon_rect, icon) -- defaults: contain + nearest

  local tile_rect = ui.rect(8, 2, 6, 3)
  ui.text(tile_rect, "######")
  ui.image(tile_rect, tile, { fit = "stretch", filter = "linear" })
end

return M
```

`contain` preserves aspect ratio; `stretch` fills the rectangle. `nearest`
preserves pixel art; `linear` smooths scaling. Loaded handles are immutable
snapshots owned by the exact plugin load and become stale when it unloads.
Profile code and single-file plugins have no asset root and cannot load images.

The load path must be a non-empty plugin-relative `/`-separated path ending in
`.png`. Absolute paths, `.`/`..` components, backslashes, symlink escapes,
non-PNG data, corrupt PNG structure, oversized dimensions/files, and exhausted
asset quota return `nil, error`. Repeating the same canonical path during one
plugin load returns the same handle and immutable byte snapshot; a changed file
is observed only after unload and reload.

Image rectangles use the same cell coordinates as `ui.text`, panes, pointer
routing, selection, and the cursor. Visible portions are clipped at the screen
edge after contain/stretch geometry is computed. A zero-area or completely
off-screen rectangle is a no-op, but handles and the strict options table are
still validated first. Unknown option fields and values are errors.

Placements draw in `ui.image` call order. Later images alpha-composite over
earlier ones. Selection and cursor overlays remain above images, while pointer
events and hit testing remain cell-based. If decoding or upload fails, the
ordinary fallback cells stay visible.

There is deliberately no `images_supported()` branch. TTY and other cell-only
frontends keep the fallback cells, while image-capable frontends composite the
optional surface over the same layout.

This is the reusable plugin API only. Packaging or converting the existing
`guild_viking` image corpus remains separate consumer work.

## Generic Plugins

| Plugin | Commands | Description |
|--------|----------|-------------|
| `autologin` | `/autologin` | Automatic login on connect |
| `deadmans` | `/deadmans` | Idle detection with warnings and auto-disconnect |
| `gmcp_state` | `/gmcp` | Subscribes to GMCP packages, tracks state, formats vitals bars |
| `help` | *(none)* | Help content library; commands come from `require('commands')` |
| `input_echo` | *(none)* | Display sent commands in output |
| `mxp_links` | `/link` | Makes MXP `<send>`/`<a>` links usable via a popup picker |
| `push_notify` | `/pushn` | Push notifications via Pushover |

### Old push notification producers

With `push_notify` and the producer plugins loaded, these channels are available:

| Channel | Producer | Matching event / notification text |
|---------|----------|------------------------------------|
| `wimpy` | `chat_monitor` | `Your legs run away with you ...` → `You have wimpied.` |
| `worlddrop` | `chat_monitor` | `You have found ...!` or `YOWZA! You are lucky enough to find ...` → original full line |
| `artifactdrop` | `chat_monitor` | Exactly `You catch the glint of something special.` → original full line |
| `killingblow` | `kill_trigger` | Enabled `/killers` system, killer outside the configured list → `Killer dealt the killing blow to Victim` (trimmed names, no final added period) |

The text triggers are anchored PCRE patterns and leave MUD output visible; the
YOWZA variant accepts one space or the old XML's two spaces after `!`. Killing
blows retain their existing formatted replacement output, listener delivery,
and command execution. A configured `self` entry excludes equal killer/victim
names (case-insensitive); it does not mean the logged-in player. `/killers off`
also suppresses the killing-blow producer, not its output or listeners.

All four channels default **off**. Use `/pushn` for status/help and `/pushn toggle`
to list channel states, then opt in individually (each command toggles, not sets):

```text
/pushn toggle wimpy
/pushn toggle worlddrop
/pushn toggle artifactdrop
/pushn toggle killingblow
```

`/pushn enable` and `/pushn disable` control the global push switch;
`/pushn grace <seconds>` controls the existing activity grace period. Credentials
remain exclusively managed by `push_notify` via `/pushn set <token> <userkey>`;
do not put them in producer code or tests. Existing per-channel preferences,
priority, rate limits, and grace settings are unchanged. Enabled notifications
send the text shown above to Pushover, so opt in only if that sharing is wanted.
`/pushn notify <message>` is a **live send** command, not an offline check.

Producers register channels during setup and re-resolve the optional consumer
at delivery. If `push_notify` loads later, channels register on the next matching
event (or producer setup); no event backlog is replayed. Unloading the consumer
is safe, and producer unload removes its text triggers.

Offline regression (LuaJIT plus the system `libpcre2-8`, also in `run_tests.sh`):

```sh
LERA_ROOT=/path/to/lera /path/to/lera/external/luajit/src/luajit tests/old_push_producers_test.lua
```

This exercises actual PCRE2 patterns, producer branching, output retention,
optional-consumer/reload behavior, and opt-in defaults without credentials or
network sends.

### Protocol plugins

`gmcp_state` and `mxp_links` turn a Lera protocol API into features, the way
`chat_monitor` consumes `mip.*`. Both are MUD-agnostic; neither owns layout or
keys, because pane placement and `bind.*` are composition-level and `bind` is
not in the plugin sandbox. A profile composes them:

```lua
local gs = plugin.load("gmcp_state")
local links = plugin.load("mxp_links")

-- Vitals bars in a pane the profile owns.
for _, row in ipairs(gs.vitals_lines(width, height)) do ... end

-- Keys belong to the profile, not the plugin.
bind.add("ctrl+l", function() links.open() end)

-- Plugins have no io, so a profile writes the observation itself.
local f = io.open(path, "w"); f:write(gs.report()); f:close()
```

There is deliberately **no MCCP plugin**: MCCP2 decompression is transparent in
C and its entire Lua surface is one boolean, `mud.mccp_active()`. There are no
events or payloads for a plugin to consume.

## 3scapes Plugins

| Plugin | Commands | Description |
|--------|----------|-------------|
| `autostepper` | `/step`, `-` `-.` `->` `-!` | Automatic speedwalk execution |
| `chat_monitor` | `/chat` | Chat channel monitoring and logging (MIP or GMCP) |
| `guild_druid` | `/dauto`, `/resetgxp` | Druid guild utilities |
| `guild_viking` | `/vik`, `resetvikxp` | Vikings guild: guild state over MIP and GMCP (`Guild.Settlement` keys only so far; see guild sources below), a 12-page tab-bar pane (`/vik <page>` or `/vik page <key>`), popup board overlays (`/vik map\|sea\|voyage\|cityplan\|war`), detached-page parity (`/vik pop <page>`), map pathfinding with point-of-interest travel and mission/errand dispatch (always available, no setting), and three client-side automations (auto-trade, auto-raid, auto-voyage; see below), which ship off by default |
| `kill_trigger` | `/killers` | Combat automation triggers |
| `mapper` | `/map` | Room graph from GMCP Room.Info, waypoints, name search |
| `mapview` | `/mapview` | Visual map display |
| `mercenary` | *(none)* | Mercenary management |
| `minimap` | `/minimap` | Compact minimap overlay |
| `player_stats` | *(none)* | Player statistics tracking |
| `roominfo` | *(none)* | Room information display |
| `speedwalk` | `/speedwalk`, `.` `..` `.,` `.place` | Speedwalk path management |
| `stats_window` | *(none)* | Statistics window UI |

### Autostepper room entry

Autostepper uses GMCP for arrivals and combat decisions. Prompt patterns and the
`set_prompt_pattern()` / `prompt()` APIs have been removed. `-.` starts or resumes
a run; stop an active run before starting another. `/step help` describes the
controls, and `/step trace on` reports the room frames and decisions.

`/step status` includes farm on/off, level, difficulty, restart state, attack
settings, the event being awaited, and progress through a frontier speedwalk.
`/step set config` also includes farm settings and the configured exploration
policy. The automatic glance setting and `set_glance_cmd()` API have been removed;
GMCP supplies room contents without extra text commands.

The server must send a complete `Room.Contents` list on every entry, even when it
matches the previous room. Every page of an entry list carries `entry: 1`;
refresh and subscription snapshots omit it. The matching mudlib change is in
`secure/pinc/gmcp.h` and `secure/protocol/config.h`. Deploy both changes before
using this plugin version. The server contract is documented in `help protocols`,
`help wizprotocols`, `man Protocol`, and `man query_protocol_room_contents`.

The stepper waits for all contents pages before deciding what to attack. Info,
Map, refreshes during movement, and elapsed time cannot advance its coordinates.
If entry is not confirmed within five seconds, it stops. For a single move, a
blocking warning can still be followed by a successful entry (the Sea allows
wizards past some blockers). Combat ends through `Char.Combat`, then a
contents refresh confirms the remaining mobs. Each attempt waits three seconds,
with two retries if no complete reply arrives. After three unanswered attempts
(nine seconds total), the run stops without discarding a target. A complete
reply cancels the retries, as do stopping, disconnecting, and unloading the plugin.

Exploration finds a shortest route through recorded rooms to the next unexplored
room and sends all its directions together. For example, `s s e` is sent without
waiting in the two known rooms. Each complete entry list commits one direction;
only the destination triggers a combat or exploration decision. The five-second
arrival timeout restarts on each intermediate entry. The existing breadth-first
search finds shortest paths for these equal-cost room exits.

A blocking warning, timeout, stop, disconnect, or contradictory map during a
frontier speedwalk stops exploration and discards the map. Commands already sent
may still execute: wait for queued movement to finish before starting a new run.
GMCP has no command identifiers to distinguish late arrivals from a prior run.
`/step explore leave` refuses while a route is outstanding; ask again at its
destination. `/step explore reset` during a frontier speedwalk stops and discards
its map instead of continuing from an uncertain origin.

Stored route steps such as `2n|e`, and `/step explore leave`, still send one
movement at a time and check each room for mobs.

Chaos Sea runs stop at the cask or portal once that room's non-ignored mobs are
cleared, even if other rooms remain unexplored. A normal run leaves opening the cask and
entering the portal to you. `/step chaossea farm <level> <risky|alarming|deadly>`
configures repeats without starting or sending gameplay commands. Both arguments
are required. Start/resume in the current sea with `/step explore`, or start a
fresh map there with `/step explore chaossea`. Farming creates its next instance
only from the cleared cask/portal. Changing settings applies to the next restart.
`-!` cancels pending work while keeping the configuration; `/step chaossea farm off`
disables repeats without interrupting exploration. Bare `/step chaossea`, its old
level/setup/off forms, and `/step cs` are no longer accepted. Farm settings last
until changed or the plugin is reloaded.
Restarting waits through the portal lobby for confirmed entry into a named maze
layer, then checks that room's mobs before exploring the fresh map.
If the server truncates the cask room's contents, the run stops with a warning
without confirming completion or restarting the farm.

Optional push channels `chaossea_cask` and `chaossea_farm` announce cask discovery
(before combat, once per fresh explore run) and each farm setup after its commands
are sent. Configuring farming or starting exploration sends no farm alert. Both
default off; enable them with
`/pushn toggle chaossea_cask` and `/pushn toggle chaossea_farm`. Existing global
push enable, activity grace and rate limits apply. Separate channels keep the
cask alert from suppressing the nearby restart alert. A cancelled pending restart
sends no alert. See [autostepper push notifications](3scapes/autostepper/README.md#chaos-sea-push-notifications).

TODO: track or invalidate coordinates when moving manually during a paused run.

### Chat sources: MIP and GMCP

`chat_monitor` can take chat from either protocol. 3K sends the same lines over
both, so exactly one source feeds the pane at a time:

| Traffic | MIP | GMCP |
|---------|-----|------|
| Channel lines | `CAA` | `Comm.Channel.Text`, `channel = "wiz"` etc. |
| Tells | `BAB` | `Comm.Channel.Text`, `channel = "tell"` |
| Souls | `BAG` | `Comm.Channel.Text`, `channel = "soul"` |

In the default `auto` mode the pane starts on MIP and switches to GMCP the
first time a real `Comm.Channel.Text` arrives — negotiation alone is not
enough, because a server can negotiate GMCP and never send the package. The
latch then suppresses **all three** MIP handlers, not just `CAA`; anything less
double-prints. Pin it with `/chat source mip|gmcp|auto` or
`chat.set_source(mode)`.

Having seen GMCP chat is **remembered across sessions** (`gmcp_chat_seen` in the
plugin's store). Without that memory the very first line of every session
duplicates: both protocols carry it, MIP arrives first, so it prints before the
latch can flip. A profile that has proved GMCP once starts on GMCP and never
gives MIP the opening. The per-connection latch and the counters still reset on
disconnect; the memory does not, or every reconnect would re-earn its duplicate.

The escape hatch, if a server stops sending GMCP chat, is `/chat source mip` —
which persists, being a pinned mode. `/chat source` distinguishes a latch earned
this session from one remembered, so a silent pane is diagnosable:

```
[chat] source: gmcp (auto; remembered from an earlier session)
[chat] mip: 0 messages    gmcp: 0 mapped, 0 unmapped
```

Both protocols name a channel the same way (`wiz`), so both land on the same
`chat_wiz` line type and its color, label and gags survive a source change.

### The lead-in

MIP text is a finished line (`Simon <Wiz>: hi`), which is why the default chat
prefix is empty. GMCP text is the body alone, with everything else in sibling
fields:

```json
{ "text": "test", "talker": "Simon", "targets": ["Lennart"], "channel": "tell" }
{ "text": "smiles at you.", "talker": "Simon", "channel": "soul" }
```

So a GMCP message needs a lead-in rendered for it. Three sources, in order:

1. A `prefix` **field on the message**, used verbatim. Only the server knows how
   it phrases `You tell X, Y: ` against `X tells you: `.
2. A `prefix` **set through `configure()`**.
3. Otherwise **synthesized**: `talker: ` normally, `talker ` for soul-like
   channels (whose text continues the name), and `talker -> a, b: ` when
   `targets` names recipients other than the talker.

A server-sent prefix outranking a configured one is deliberate, and it is the
one place `configure()` does not win. One setting cannot serve both protocols: an
empty emote prefix is correct for MIP text reading `Simon smiles at you.` and
wrong for a GMCP body of `smiles at you.`. The server knows which it sent; the
setting cannot. Configured prefixes still apply to every MIP line and to any
GMCP line the server sent no prefix for.

Synthesis is guesswork about server-side phrasing and exists only so the pane
reads sensibly before a server sends its own `prefix`.

The lead-in and the body are joined by exactly one space, added only when the
prefix does not already end in whitespace — the built-in defaults do (`[Bob] `),
a server-sent one need not (`Simon tells you:`).

### Two-tone colouring

A line with a lead-in renders the lead-in in the line type's colour and the body
in `text_color` (default `white`):

```
[09:57] Simon tells you: are you there?
        ^^^^^^^^^^^^^^^^ type colour
                         ^^^^^^^^^^^^^^ text_color
```

A line *without* a lead-in stays entirely in its type colour. That is deliberate:
MIP text is itself a formatted line (`Simon <Wiz>: hi`), so greying the body would
throw away the per-channel colour that distinguishes one channel from another.

```lua
chat.set_text_color("bright_black")            -- global; "white" by default
chat.configure("chat_wiz", { text_color = "yellow" })   -- per line type
```

Colour spans are painted after wrapping, so escape codes never enter the width
arithmetic, and each wrapped row re-opens in the colour it continues — a body
that wraps stays in `text_color` on every row rather than reverting.

### Direction

`Comm.Channel.Text` has no direction of its own, and `targets` only reveals it
to a client that knows its own character name. When the server sends
`"direction": "in"` or `"out"`, two channels map onto the built-in directional
types:

| Channel | `direction` | Line type |
|---------|-------------|-----------|
| `tell` | `in` / `out` | `tell_in` / `tell_out` |
| `soul` | `in` / `out` | `emote_in` / `emote_out` |

That is what keeps an incoming tell reaching the `tells` push channel and an
outgoing one silent, whichever protocol delivered it. Without a recognised
`direction` the line stays an ordinary `chat_tell` / `chat_soul` type rather than
being guessed into the wrong one — visible in that it notifies on channel `tell`
instead of `tells`. `direction` on any other channel is ignored.

`/chat source` reports which protocol is live and what each has delivered,
including anything under `Comm` that could not be read:

```
[chat] source: mip (auto; no GMCP chat seen yet)
[chat] mip: 143 messages    gmcp: 0 mapped, 2 unmapped
[chat] last unmapped: Comm.Channel.List (fields: channels)
```

### Guild sources: MIP and GMCP

`guild_viking` receives state from either protocol, though currently only the ten
`Guild.Settlement` keys have writers. 3K sends the same state over both, so
selection is per key rather than per transport — a key that arrives over GMCP
suppresses its MIP copy, but the other transport remains active for keys without
a GMCP writer:

| Key | MIP | GMCP |
|-----|-----|------|
| **Settlement** | BBE payload (denoted `SETTLERS`, `SACTIONS`, etc.) | `Guild.Settlement` sub-keys (`settlers`, `sactions`, etc.) |
| **City/Trade** | BBE payload | `Guild.City` / `Guild.Trade` sub-keys (mapped, not consumed yet) |

The latch is per-key because GMCP covers five panels while voyage and war have no
GMCP source yet. A wholesale latch would take those pages dark. In the default
`auto` mode each key picks its source independently: MIP feeds it until GMCP arrives
for that key, then the MIP copy suppresses. Pin it with `/vik source mip|gmcp|auto`.
`/vik source` reports which keys each protocol is feeding and the keys received but
not consumed (no writer yet).

Settlement keys use a shared decoder and writer, so they read identically regardless
of transport. Two keys are exceptions: `SCONSUME` arrives as a hand-written
`name:value` dictionary, and `SEVENTS` splits on the first pipe only, allowing the
message body to contain pipes. Two composite keys gather multiple GMCP sub-keys into
a single writer: `MONUMENTS` joins `monuments_cap` and `monuments_list`, and `SROLES`
joins `sroles` and `sroles_meta`. A delta frame may carry one half without the other,
and the writer applies only what arrived.

`Guild.Info` and `Guild.State` are received and counted but not consumed — they
carry identity and SP fields the plugin does not read, and the vitals they would
duplicate are already owned by `combat.on_composite` off the MIP `FFF` channel.

### Vikings guild automation

`guild_viking` ships three client-side automations, each a straight port of the matching
LEGACY behavior: an arbitrage/stock-offload **auto-trader**, an idle-longship **auto-raider**,
and a voyage-chart **auto-voyager**. Every one of them sends commands with no direct action from
the player, so **all three ship OFF and must be turned on deliberately**:

| Automation | Command | Setting |
|------------|---------|---------|
| Auto-trade | `/vik trader [<sub>]` (bare opens the settings menu) | `auto_trade` |
| Auto-raid | `/vik raid [<sub>]` | `auto_raid` |
| Auto-voyage | `/vik voyage auto [<sub>]` | `auto_voyage` |

Auto-raid and auto-voyage tick on a flat interval (20s / 8s) from the guild's regular per-second
update timer. Auto-trade's 30s is a *planning* interval only — once a plan is drawn, its paced
runner sends one command every 2s and waits up to 20s for MIP confirmation before the next, so
auto-trade can send more often than every 30s while working through a multi-command plan. All
three are gated at the very first line of their tick function on the setting above — nothing is
ever sent until a player flips it on with the command or its menu. Every automated send goes
through the normal `mud.send` path, so if `deadmans` is loaded, its idle-detection `on_send`
governance applies to these sends exactly as it would to a manually-typed command. Settings
persist across reconnects via the guild's own store. `/vik status` reports each automation's
on/off state and its last-action/next-check timing; the Stats page shows the on/off and
last-action half of that (not the next-check timing).

**Deadmans and pointer-driven sends.** `deadmans` resets its idle timer only from typed input
(`on_input`), never from pointer input. That has been true since stage 3's popup click-to-send
paths, but stage 4 raises the stakes: the map popup's point-of-interest travel and the People
pane's mission/errand "Run There" button are both pointer-driven and can each dispatch a whole
path of movement commands, not just one. A player who has been reading rather than typing past
`deadmans`' `block_time` can click one of these and have deadmans silently swallow every command
in the path.

### Interop hooks

Two stage-0 hooks let other plugins react to `kill_trigger` and `stats_window` without
depending on their internals.

**`kill_trigger.on_monster_died(cb)` / `remove_kill_listener(id)`** — a cross-plugin kill
feed. `cb(killer, victim)` fires once per killing blow, in registration order, independent of
`kill_trigger`'s own command-execution enable flag (a disabled `/killers` still reports kills to
listeners). A listener's error is pcall-guarded and does not stop the rest. Listeners die with
`kill_trigger`'s unload, so a producer plugin should re-register from `on_setup` rather than
assume a one-time registration survives a reload:

```lua
local kt = plugin.get("kill_trigger")
local id
function M.on_setup()
  kt = plugin.get("kill_trigger")
  if kt then
    id = kt.on_monster_died(function(killer, victim)
      -- react to the kill
    end)
  end
end

function M.on_unload()
  if kt and id then kt.remove_kill_listener(id) end
end
```

**`stats_window.register_guild(name)`** — adds a guild plugin's name to the probe list
`stats_window` uses to find a guild-stats section to render (`guild_druid` is first and
untouched). Registering resets the cached probe so the next render picks up the newcomer:

```lua
local sw = plugin.get("stats_window")
if sw then sw.register_guild("guild_viking") end
```

## Example Plugins

| Plugin | Description |
|--------|-------------|
| `test_plugin` | Minimal plugin demonstrating hooks |
| `store_test` | Example of persistent storage |
| `mip_example` | MIP protocol integration example |

## Writing Plugins

See `examples/test_plugin.lua` for a minimal template. Plugins export a table with optional hooks:

```lua
local M = {}

M.name = "my_plugin"
M.version = "1.0"

function M.on_load() end
function M.on_unload() end
function M.on_line(line) return line end
function M.on_send(text) return text end
function M.on_connect() end
function M.on_disconnect() end

return M
```
