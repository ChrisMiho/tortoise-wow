---
status: implemented
risk: low
area: playerbots/battlegrounds
depends-on:
---

# An Alliance bot stepping back into the tunnel is immediately re-sent to mid-field

**Problem:** `BGTactics::wsgPaths()`'s westbound (Alliance-attacking) branch
issues a `MoveTo` at `BattleGroundTactics.cpp:2457-2459` and another at
`:2460-2462` and then **falls out of the `else if` chain** instead of returning.
Control reaches `:2471-2478`, which issues a second `MoveTo` to mid-field and
overwrites the first. The eastbound (Horde-attacking) mirror at `:2324-2341`
returns from every branch, so only the Alliance side is affected.

In-game: an Alliance bot with `bg role < 4` standing between roughly `x = 1381`
and `x = 1450` is sent to mid-field instead of stepping back into the tunnel —
the exact manoeuvre the inline comment at `:2457` says is required, because
"moving from the fasty to the gate directly is bugged". Note the direction: this
defect works *against* Alliance, so it is not the cause of the 15-6 Alliance skew
in `bg.log` — it is a straightforward control-flow bug on its own.

**Suspected cause / area:**
`src/modules/PlayerBots/playerbot/strategy/actions/BattleGroundTactics.cpp`,
`wsgPaths()` — the two branches at `:2457-2462`, against the working mirror at
`:2333-2340`, overridden by `:2471-2478`.

**Acceptance criteria:**

- Both branches at `:2457-2459` and `:2460-2462` return `true` after their
  `MoveTo`, matching the eastbound mirror at `:2333-2340`.
- The mid-field fallback at `:2471-2478` is unchanged and still reachable for the
  cases that legitimately fall through to it.
- No other branch of `wsgPaths()` changes.
- The commit message states which two `MoveTo` calls were being discarded and
  quotes the `:2457` comment that says why the tunnel step exists.

**Notes:**

- Source: `docs/playerbots/BG-AI-ANALYSIS.md`, finding **F-06**.
- Like every other movement fix in this set, it is unobservable until bots move
  at all — see `docs/backlog/046-wsg-bots-never-execute-bg-move-to-objective.md`.

**Base:** cm-main

**Branch:** backlog/wsg-westbound-tunnel-move-is-overridden

**Summary:** Added `return true;` to the two westbound (Alliance-attacking) branches in `BGTactics::wsgPaths()` in `src/modules/PlayerBots/playerbot/strategy/actions/BattleGroundTactics.cpp` — the `x > 1443.9f` "back to the tunnel first" branch and the `x > 1380.9f` "move into the tunnel" branch. Both previously issued a `MoveTo` and then fell out of the `else if` chain, so control reached the unconditional `if (bot->GetPositionX() > 1240.f)` mid-field fallback, which issued a second `MoveTo` and discarded the tunnel destination. The fix is a 2-line insertion; the mid-field fallback block is untouched and still reachable for the legitimate fall-through range `1240 < x <= 1351.9` (the `x > 1351.9f` alliance-entrance branch already returned). No other branch of `wsgPaths()` changed, and the eastbound mirror is unmodified. Committed as fbf4608 with a message naming both discarded `MoveTo` calls and quoting the `:2457` comment ("moving from the fasty to the gate directly is bugged.. moving back to the tunnel first"). No SQL migration needed; no build run, per the batch-gate rule.

**In-game check:** Prerequisite: this is unobservable unless bots actually move, so the fix from `046-wsg-bots-never-execute-bg-move-to-objective` (commit 74d2ace, already on cm-main) must be in the same build. Checklist:

1. Start a server built from this branch and queue a Warsong Gulch match with bots on both sides (`.bg` / rndbot standup used by `docs/playerbots/wsg/`). The build must include this branch — the only image on this host is the pre-change rollback anchor, so testing against it proves nothing.
2. Pick an Alliance bot whose `bg role` is below 4 (the tunnel-route roles). `.pinfo`/console the bot, or just watch several — with a full team some will hold role < 4.
3. Position the check: the bot must be heading toward the Horde base (its "bg objective" target x is lower than its own x) and standing in the Silverwing/Alliance ramp corridor with x between roughly 1381 and 1450 — i.e. just after "the fasty" on the Alliance side. The most natural way to observe it is to follow an Alliance flag-runner or returner as it leaves its own base heading west.
4. Correct behaviour: the bot steps west/down into the tunnel, passing through approximately (1443.8, 1459.6, 342.1) then (1380.8, 1457.6, 329.1), and continues through the tunnel mouth toward (1125.8, ~1452, 315.7). Bug behaviour (pre-fix): the same bot instead turns out and runs toward mid-field around (1227, 1476, 307) or (1239, 1541, 306), never entering the tunnel, and typically ends up pathing across open ground where the fasty-to-gate path is bugged.
5. Repeat with a Horde bot heading east to confirm the mirror route is unchanged — Horde tunnel bots should behave exactly as before.

Scriptable portion: no dedicated log line exists for wsgPaths branch selection, so this cannot be fully asserted from logs. What a later automated step CAN confirm without a human watching: (a) the server starts and a WSG match runs to completion with no new errors or crashes in `mangosd`/`bg.log`; (b) Alliance bot position samples taken during a match include coordinates inside the tunnel corridor (x between 1130 and 1380, z near 315-330) rather than exclusively mid-field values — sampling bot positions via console `.gps` on a followed bot, or via the existing wsg telemetry scripts under `docs/playerbots/wsg/`, would show tunnel traversal is happening at all on the Alliance side. The per-bot branch verification in steps 3-4 needs a human in-game.
