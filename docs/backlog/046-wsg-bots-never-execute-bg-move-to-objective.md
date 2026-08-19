---
status: implemented
risk: medium
area: playerbots/battlegrounds
depends-on:
---

# WSG bots queue `bg move to objective` thousands of times and never once run it

**Problem:** In a measured 20-minute Warsong Gulch match (2026-08-18, run
directory `/home/deck/tournament-runs/037-wsg-2`, image `tortoise-cm:20260818-2`,
`Tournament.TelemetryIntervalMs = 5000`), all 20 bots entered the instance,
spawned at their correct faction start points, and then **did not move a single
yard for the entire match**. Every bot's telemetry trace holds exactly one
distinct `(x, y)` across every sample; `combat=1` never appears; the closest an
Alliance bot and a Horde bot ever come is **544.8 yd**, at the first sample; the
match ends 0-0.

`bots.log` says why the bots are idle, and it is not idleness. The AI ticks
normally and the battleground strategies are attached — `T:bg active` fires
every tick. The counts below are `docs/playerbots/BG-AI-ANALYSIS.md` §4.2's,
unchanged — that section is the single source for them, this artifact only
quotes it. They are counted over `bots-window.log`: `bots.log` sliced to the
match window **13:12:46Z–13:32:06Z** and filtered to the 20 `Wsg*` bots,
403,139 lines, **25,476 AI ticks**.

| line | count |
|---|---|
| `PUSH:bg move to objective - 1.000000 (trigger)` | 23,908 |
| **`A:move to objective - <anything>`** | **0** |
| `PUSH:bg check flag - 70.000000 (trigger)` | 23,908 |
| `PUSH:bg check flag - 20.000000 (trigger)` | 23,908 |
| `A:check flag - PREREQ` / `A:check flag - FAILED` | 23,681 / 23,681 |
| `PUSH:bg check objective - 10.000000 (trigger)` | 4,370 |
| `A:check objective - PREREQ` / `A:check objective - FAILED` | 16 / 16 |
| `A:select objective` / `A:protect fc` / `A:attack fc` / `A:move to start` | 0 / 0 / 0 / 0 |
| ticks ending `no actions executed` | **25,175 of 25,476 (98.8%)** |

`bg move to objective` — the only action that carries a WSG bot across the field
— is queued on essentially every tick and is **never popped off the queue at
all**. The tick is spent on `bg check flag`, whose action `check flag` returns
`atFlag(...)` == false (`BattleGroundTactics.cpp:2834-2850`) and is logged
`FAILED`, after which the tick ends with `no actions executed`.

**The gate phase before that window is the contrast to explain.** Sliced from
the same `bots.log` to **13:11:38Z–13:12:34Z** — the bots are already in
instance 101 and ticking, but `TOURNAMENT start instance=101 ok=1` has not
fired yet (`bg-slice.log`, 13:12:35Z) — those 1,414 AI ticks look nothing like
the 25,476 that follow:

| line | 13:11:38Z–13:12:34Z (1,414 ticks) | 13:12:35Z–13:12:45Z (262 ticks) |
|---|---|---|
| `PUSH:bg check flag - 70.000000` | 0 | 229 |
| `PUSH:bg move to objective - 1.000000` | 0 | 229 |
| `A:check flag - FAILED` | 0 | 209 |
| `A:check values - OK` (relevance 1.0) | **188** | 3 |
| `A:move to start - OK` | **34** | 0 |
| `A:move to objective - <anything>` | 0 | 0 |

Relevance 1 is reached 188 times in the 1,414 ticks where nothing at relevance
70 is queued, and 12 times in the 25,476 ticks where something at relevance 70
is queued and fails. `move to start`, the one WSG action that ever succeeds,
succeeds only in that first phase. Same bots, same instance, same relevance
table — the variable is whether a failing relevance-70 action is in the queue.

The relevance ladder that produces this is in
`strategy/generic/BattlegroundStrategy.cpp`:

- `"bg active"` → `check mount state` 2.0, **`bg move to objective` 1.0** (`:28-30`)
- `"very often"` → `bg check objective` 10.0 (`:32-34`)
- `"bg active"` → `bg check flag` `ACTION_HIGH` = 20.0 (`:36-38`, `strategy/Strategy.h:30`)
- `WarsongStrategy`, `"bg active"` → `bg check flag` **70.0** (`:59-61`)

So the action that moves the bot sits at relevance 1, below every check action,
and the checks fail without yielding. What has *not* been established is
whether `Engine::DoNextAction`'s queue walk is *defective* — ending the tick
early — or working exactly as designed, with a failing relevance-70 action
legitimately consuming the tick and relevance 1 simply unreachable underneath
it. The phase comparison above is consistent with both readings.

**Suspected cause / area:**
`src/modules/PlayerBots/playerbot/strategy/Engine.cpp` `DoNextAction`
(`:124-330`, in particular the `do { ... } while (basket && ++iterations <= iterationsPerTick)`
loop and the `A:... - FAILED` arm at `:262-267`), `strategy/Queue.cpp`
(`Push` merges baskets by action-node name; `Peek`/`Pop` select by relevance),
and the relevance table in
`src/modules/PlayerBots/playerbot/strategy/generic/BattlegroundStrategy.cpp:18-91`.

**Acceptance criteria:**

- The reason `bg move to objective` is never popped is established and written
  down with a `file:line` — not inferred. Acceptable evidence: a temporary
  instrumented build, or a reading of `Engine::DoNextAction` that accounts for
  the measured asymmetry (relevance 1 reached 188 times in the 1,414 gate-phase
  ticks with nothing at relevance 70 queued, 12 times in the 25,476 match ticks
  with a failing relevance-70 action queued).
- The fix is stated as one of: (a) the engine defect that ends the tick early,
  or (b) the relevance table, if the engine turns out to be behaving as designed
  and relevance 1 is simply unreachable under a relevance-70 action that fails
  every tick. If (b), the new relevances are justified against the whole ladder
  in `BattlegroundStrategy.cpp:18-91` — raising one action starves others, which
  is exactly how this state was reached.
- After the change, one WSG match run end to end with
  `Tournament.TelemetryIntervalMs = 5000` shows, from the telemetry CSV:
  - at least 15 of 20 bots with `distance > 100` yards
    (`scripts/tournament/telemetry-report.sh`'s `MOVEMENT` lines), and
  - at least one sample where an Alliance bot and a Horde bot are within 30
    yards of each other, and
  - `A:move to objective - OK` present in `bots.log` for at least five distinct
    bots.
- `docs/playerbots/BG-AI-ANALYSIS.md` §4 gains a short "after" paragraph with
  those numbers next to the before numbers above.

**Notes:**

- Source: `docs/playerbots/BG-AI-ANALYSIS.md` §4 (the measurement) and finding
  **F-01** (the code reading that predicted this shape, though it named
  `bg check objective` at relevance 10 as the starver; the measurement says the
  dominant starver is `bg check flag` at 70).
- §4 **refutes** the "commented-out flag-carrier triggers cause the 0-0 draws"
  hypothesis, so do not start there. `bg.log` records 21 decisive WSG matches
  and `honor.log` records 184 flag-capture honour awards on 2026-08-10, with
  those triggers already commented out and that file unchanged since 2026-05-10.
- This is the highest-value item in the whole 037 set. Every other movement or
  flag fix scoped from that analysis is unobservable until this one lands.
- Consider whether `docs/backlog/047-find-the-playerbot-config-change-that-froze-wsg-bots.md`
  should be worked first: it is config-only, carries no code risk, and covers
  the same regression window.
- `bots.log` is large. Use `scripts/tournament/bot-log-capture.sh --mark` /
  `--since` for the match window rather than an unbounded read.

**Base:** cm-main

**Branch:** backlog/wsg-bots-never-execute-bg-move-to-objective

**Summary:** Established the cause by reading, and it is (a), an engine defect — the relevance table is untouched. `BGTactics::Execute` calls `ai->ChangeStrategy("-buff", BOT_STATE_NON_COMBAT)` on every tick of a battleground in progress (`src/modules/PlayerBots/playerbot/strategy/actions/BattleGroundTactics.cpp:2716-2718`). `Engine::ChangeStrategy` ended with an unconditional `Init()` (`src/modules/PlayerBots/playerbot/strategy/Engine.cpp:871-872` pre-fix), and `Init()` (`:104`) calls `Reset()` (`:79-92`), which pops and deletes every `ActionBasket` still in `queue`. Because that call is issued from inside `ListenAndExecute`, it lands mid-way through `DoNextAction`'s `do { ... } while (basket && ++iterations <= iterationsPerTick)` walk (`:141-326`): the next `queue.Peek()` returns NULL, `basket` goes null, the loop exits, and the tick logs `no actions executed` (`:352`). `bg check flag` at relevance 70 is merely the first `BGTactics` action popped each tick, so it is the one that detonates the queue; `bg check objective` (10), `check mount state` (2) and `bg move to objective` (1.0) are deleted before they can be popped. This accounts for the measured asymmetry exactly: in the 1,414 gate-phase ticks `bg->GetStatus()` is `STATUS_WAIT_JOIN`, the `ChangeStrategy` line never runs, the queue survives, and relevance 1.0 is reached 188 times; in the 25,476 match ticks it runs every tick and relevance 1.0 is reached 12 times. The fix adds `Engine::StrategySignature()` (ordered join of attached strategy names) and makes `Engine::addStrategy` and `Engine::ChangeStrategy` call `Init()` only when that signature actually changed — `-buff` changes it once, on the first BGTactics tick after the gates open, and every tick after is a genuine no-op that leaves the queue intact. `PlayerbotAI::ResetStrategies` was checked and is unaffected: it drives `initMode` and calls `Init()` explicitly itself. Files: `src/modules/PlayerBots/playerbot/strategy/Engine.cpp`, `src/modules/PlayerBots/playerbot/strategy/Engine.h`, and `docs/playerbots/BG-AI-ANALYSIS.md` (new §4.2a "after" subsection next to the before numbers, plus a correction to finding F-11, which had scored this same call "no behavioural difference expected"). No SQL migration. NOT DONE HERE, deliberately: the third acceptance criterion is a live 20-minute WSG match with `Tournament.TelemetryIntervalMs = 5000` — that needs a build of this branch, which rule 4 forbids in this phase, and the only server image on the host predates the change. §4.2a states plainly that the after-numbers are pending rather than inventing them; the backlog-batch validation pass is where that run belongs, and it should amend §4.2a with the measured values.

**In-game check:** This needs a real WSG match; the generic "server starts, bots spawn" smoke test will not show it, because the bug only appears once a battleground reaches STATUS_IN_PROGRESS.

Scriptable, no human eyes needed (do these first):
1. Build this branch, bring the stack up, and run the same procedure as run 037-wsg-2: `AiPlayerbot.EnableActionLog = 1` and `Tournament.TelemetryIntervalMs = 5000`, 20 `Wsg*` bots queued into one Warsong Gulch instance, match left to run 20 minutes.
2. Mark the log window with `scripts/tournament/bot-log-capture.sh --mark` before the gates open and `--since` after the match, so `bots.log` is sliced rather than read whole.
3. In the sliced window, `grep -c 'A:move to objective - OK'` must be non-zero, and `grep 'A:move to objective - OK' | awk '{print $1}' | sort -u | wc -l` must be at least 5 distinct bot names. Before the fix this count is exactly 0 over 403,139 lines, so any non-zero value is decisive.
4. In the same window, the share of ticks ending `no actions executed` must fall well below the measured 98.8% — count `--- AI Tick ---` against `no actions executed`.
5. `scripts/tournament/telemetry-report.sh` on the run's telemetry CSV must show at least 15 of the 20 bots with `distance > 100` on its `MOVEMENT` lines, and at least one sample with an Alliance bot and a Horde bot within 30 yards (before the fix the minimum separation was 544.8 yd, at the first sample). Run these from WSL, not Git Bash (jq).
6. Confirm no regression in strategy handling: `grep 'S:-buff'` in the window should appear roughly once per bot near the match start, not once per bot per tick. That is the direct signature of the fix — the no-op ChangeStrategy no longer rebuilds.

Manual, in-game (a human on a GM account):
7. `.go` into the running WSG instance shortly after the gates open and watch: bots should leave their tunnel and run the field along the BattleBot paths instead of standing on the spawn point. Both faction groups should meet somewhere near mid-field within the first minute or two, and a flag room should get visited.
8. Let the match run to its end and check the final score is not 0-0, and that `honor.log` records flag-capture honour awards for the run.

If step 3 shows zero `A:move to objective - OK` while step 6 shows `S:-buff` still firing every tick, the guard did not take effect and the build is stale — check the image tag before touching the code.

**Minor findings:**

- docs/playerbots/BG-AI-ANALYSIS.md: Acceptance criteria 3 and 4 are not met by this diff: §4.2a explicitly states "The 'after' match numbers are not filled in yet", so no WSG run with Tournament.TelemetryIntervalMs = 5000 has been made and BG-AI-ANALYSIS §4 carries no measured after numbers (15/20 bots > 100 yd, one Alliance/Horde sample within 30 yd, `A:move to objective - OK` for five distinct bots) — the batch build/validate pass must run the match and amend that paragraph before this can be called done.
- src/modules/PlayerBots/playerbot/strategy/Engine.cpp: The fix removes the no-op trigger but not the engine defect itself: `Init()` -> `Reset()` still drains `queue` while `DoNextAction`'s do-while is mid-walk, so any strategy change issued from inside an action's `Execute()` that genuinely moves the strategy set — including the very first `BGTactics::Execute` tick after `STATUS_IN_PROGRESS`, when "buff" is still attached, and any later tick where `ResetStrategies`/`RandomPlayerbotMgr::ChangeStrategy` has re-added it — still silently kills the rest of that tick and logs `no actions executed`.
- src/modules/PlayerBots/playerbot/strategy/Engine.cpp: The guard narrows but does not close the re-entrant Init() window: when a strategy change made from inside an action's Execute() actually changes the set, Engine::Reset() still deletes every ActionBasket/ActionNode in `queue` while DoNextAction is mid-walk of it, and the loop survives only incidentally (queue.Pop() already transferred ownership of the current ActionNode, and the freed `basket` is only tested for null, never dereferenced, after ListenAndExecute returns) -- ai->ResetStrategies() two lines above the guarded call site at BattleGroundTactics.cpp:2701 and ChangeStrategy("-collision")/("-arena") at :4879-4902 all still hit it, so any later edit that reads basket-> after Execute becomes a use-after-free across ~1000 bots.
- src/modules/PlayerBots/playerbot/strategy/Engine.cpp: StrategySignature() builds and concatenates a fresh std::string over the whole strategy map twice per addStrategy/ChangeStrategy call, and BattleGroundTactics.cpp:2718 issues ChangeStrategy("-buff") on every non-combat tick of every bot in a battleground, reintroducing exactly the per-tick string churn that Action.h's NextAction::getName() comment records as the server's top allocation source; a size() early-out or a dirty flag set by add/removeStrategy would give the same guard for free.
