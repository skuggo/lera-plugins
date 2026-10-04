# Autostepper

Exploration speedwalks the complete shortest route through known rooms to the next
unexplored room. A route such as `s s e` sends all three moves together; arriving
room contents track each move, with combat and exploration decisions at the
destination. Each intermediate arrival restarts the five-second movement timeout.

An interrupted or blocked frontier speedwalk discards its map. Already sent
commands may still run, so wait for queued movement to finish before restarting.
`/step explore reset` also stops an outstanding frontier speedwalk;
`/step explore leave` refuses until the current route arrives. Stored routes and
the walk back to the origin continue to check each room for mobs.

Farm restarts wait through the portal lobby, "A swirling Sea of Chaos", until
complete entry contents arrive for a "Layer ... of the Sea of Chaos" room.
Only that maze room becomes the new exploration origin; its mobs are handled
before stepping continues.

## Status and configuration

`/step status` shows farm on/off, selected level and difficulty, and whether the
next restart is scheduled, waiting for maze entry, or due after clearing the cask room.
Stopping cancels pending restarts and keeps the farm configuration enabled for the next run.

It also shows auto-attack and the attack command, the event being awaited
(initial contents, maze/room entry, combat end or a combat contents refresh),
and confirmed arrivals versus total rooms during a frontier speedwalk. Stored
route runs show their step counts even when an old exploration map is retained.
`/step set config` includes farm settings and the configured exploration policy.

Room entries and occupants come from GMCP. The automatic glance setting and
`set_glance_cmd()` API have been removed; no extra glance is sent on start or
after a step.

## Chaos Sea farming

```
/step chaossea farm 5 risky
/step explore
```

The first command only configures automatic repeats. Both level (a non-negative
whole number) and difficulty (`risky`, `alarming` or `deadly`) are required. It sends
no gameplay commands or notifications and does not start or interrupt exploration.
Changing these settings applies to the next restart, including one already scheduled.

`/step explore` starts or resumes exploring the current sea; `/step explore chaossea`
starts a fresh map in the current sea. After the cask/portal room is cleared, farming
opens the cask, enters the portal, unsets the old sea, creates the configured sea,
and enters it. Only this automatic restart sends the setup commands.

Position in the sea is dead reckoned, so any room entry the stepper did not send
for -- wimpy, a mob moving you, a direction typed by hand mid-run or while paused --
drops the map. A running explore stops with "Moved outside the stepper"; the next
`/step explore` maps afresh from where you stand.

When exploring ends "no unvisited exits remain", the stepper saves a report in
the profile's `.storage/autostepper.json` under `explore_dumps` (last 5, newest
last): position and counters, the room you stand in as the server reports it
and as the map holds it, every recorded room with its exits (`*` marks an exit
into a coordinate never recorded), and the last 120 log/trace lines, kept even
with trace off. `/step dump` saves one on demand.

`/step chaossea farm off` disables repeats and cancels a pending restart without
interrupting the current exploration or fight. `-!`, `/step stop` and `/step explore off`
stop exploration and cancel pending restarts while keeping the farm configuration.
Settings last until changed or the plugin is reloaded.

Bare `/step chaossea`, its old level/setup/off forms, and the `/step cs` shorthand
are no longer accepted. Use `/step explore` to start and the farm commands to configure.

## Exploration push notifications

Enable the channels you want in the existing `push_notify` plugin:

```
/pushn toggle explore_exhausted
/pushn toggle chaossea_cask
/pushn toggle chaossea_farm
```

All channels default off. `/pushn toggle` lists their current states; toggling
an enabled channel turns it off again. Global push enable, credentials, activity
grace and rate limits remain controlled by `push_notify`.

`explore_exhausted` announces when exploration stops because no reachable
unvisited rooms remain. It fires once at that stop, including when farming is
configured. Manual stops, returning to the origin with `explore leave`, movement
failures, stored-route completion and reaching the Chaos Sea cask/portal do not
trigger it. A new exploration run can send another alert, subject to the normal
push settings; suppressed events are not queued or replayed.

`chaossea_cask` announces a cask once per fresh exploration run, when a complete
contents list shows it, before fighting its boss. It means the cask was found,
not that the room is clear. Pausing/resuming and combat refreshes do not repeat
it; a portal alone does not trigger this alert.

`chaossea_farm` announces each automatic restart after its setup commands are sent.
Configuring farming or starting exploration sends no farm alert. Cancelling a pending
repeat sends no restart alert; rejected setup sends also suppress it. Separate
channels prevent discovery from rate-limiting the nearby farm alert. No notifications are queued if the consumer is missing
or suppresses the event.

## Mob ignores

```
/step mobignore add A gentle guide
/step mobignore remove A gentle guide
/step mobignore list
/step mobignore clear
```

`add` and `remove` take the entire remaining text as one name (no quotes
needed). `list` and `clear` accept no name. Bare `/step mobignore` also lists
entries. Missing names, unknown operations, extra arguments to list/clear,
and non-whitespace control characters are rejected without changing the list.
Duplicates are harmless; listing is sorted.

Names match the **entire GMCP monster display name**, lowercased with Lua's
`string.lower`, with leading/trailing whitespace removed and runs of Lua `%s`
whitespace collapsed to one space. This is not Unicode case folding.
Punctuation, articles, and all other words remain significant. For example,
`A gentle guide` matches `  a  GENTLE guide ` but not `a gentle guide captain`.
There are no substring, wildcard, or Lua-pattern matches; `.*` is literal.
Use the full name reported by roominfo, not just a kill-command keyword.
The legacy XML's `-mobignore` used Lua-pattern substring matching; this list
is intentionally safer and is not automatically imported.

Changes are saved immediately in autostepper's Lera plugin store, isolated by
Lera profile (not by explorer area). A failed save is reported; the in-memory
change still applies. The default list is empty. No friendly mobs are ignored
automatically.

Ignored mobs are excluded from both target selection and the remaining-mob
check in normal stepping, targets-only stepping, explorer clear/dive/leave,
and Chaos Sea farming. A room containing only ignored mobs can be traversed;
a real non-ignored mob later in the room list is still considered normally.
The underlying room snapshot is retained, so removing an ignore makes that
mob eligible again at the next decision.

Edits take effect at the **next room decision**; they do not interrupt an
already issued attack or manufacture a new room/combat event. Existing player
skip, auto-attack, navigation exclusions, difficulty/setup and safety behavior
are unchanged. This is not protection from a mob attacking you, nor a new
health/boss safety system. Ignoring a required gatekeeper may prevent the MUD
from allowing progress.

After combat, the stepper requests complete room contents before attacking or
moving again. It waits three seconds per attempt and retries twice if needed.
After three unanswered attempts (nine seconds total), it stops with the target
still tracked. A complete reply, stop, disconnect, or unload cancels the retries.

Chaos Sea runs stop at the cask or portal after clearing its non-ignored mobs,
even with unexplored rooms remaining. Farm mode starts its next instance from
there. If the server truncates that room's contents, the run stops with a warning
without declaring completion or restarting, since omitted mobs may still exist.

For example, ignore a guide while exploring:

```
/step mobignore add A gentle guide
/step explore chaossea
```
