---
status: implemented
risk: medium
area: playerbots/battlegrounds
depends-on: 046-wsg-bots-never-execute-bg-move-to-objective.md
---

# The WSG graveyard route is annotated BUGGED in the source and still given to 30% of bots

**Problem:** `bg role` is `urand(0, 9)`
(`strategy/actions/BattleGroundJoinAction.cpp:1520`), and `Preference` 4-6
selects the graveyard branch of `wsgPaths()`. The source says that branch is
broken: the comment at `BattleGroundTactics.cpp:2342` reads
"`preference < 7 = move through graveyard (BUGGED)`", and its mirror is at
`:2480`. A second comment at `:2326` claims the graveyard is disabled
("`< 6 becuse GY disabled`") — but the code does not disable it.

So roughly three bots in ten take a route the author marked broken, and
`resetObjective()`'s 1-in-4 role re-roll (`:4219-4223`), which fires every five
seconds, can move a bot onto that route mid-run.

Nothing in the repository says *what* the bug is. That is the first half of this
work: characterise it, then decide between fixing the route and actually
disabling it the way the `:2326` comment claims.

**Suspected cause / area:**
`src/modules/PlayerBots/playerbot/strategy/actions/BattleGroundTactics.cpp`
`wsgPaths()` — graveyard branches at `:2342` and `:2480`, role assignment at
`strategy/actions/BattleGroundJoinAction.cpp:1520`, re-roll at `:4219-4223`.

**Acceptance criteria:**

- One WSG match is run with `Tournament.TelemetryIntervalMs = 5000` and at least
  three bots whose `bg role` lands in 4-6, and
  `docs/playerbots/BG-AI-ANALYSIS.md` (or a section this artifact adds to it)
  states in numbers what the graveyard-route bots do differently from the tunnel
  and ramp bots — distance travelled, whether they reach the enemy base, where
  they stop.
- The outcome is one of two, chosen on that evidence and stated in the commit
  message: the route is corrected, or the branch is actually disabled so
  `Preference` 4-6 falls to a working route — matching what the `:2326` comment
  already claims.
- Whichever is chosen, the two stale comments (`:2326` and `:2342`) are made to
  agree with the code.
- The role distribution itself (`urand(0, 9)`) is not changed here.

**Notes:**

- Source: `docs/playerbots/BG-AI-ANALYSIS.md`, finding **F-07**.
- `depends-on` 046 is not optional: with bots not moving at all, a graveyard-route
  bot and a tunnel-route bot are indistinguishable, and the measurement this
  artifact's first criterion asks for cannot be taken.

**Base:** cm-main

**Branch:** backlog/wsg-graveyard-route-is-marked-bugged-and-still-assigned

**Summary:** I ran the measurement the artifact demanded before touching the branch, and it refuted the premise. One 20-minute 10v10 WSG match (instance 101, 2026-08-19 16:57–17:18Z) on `tortoise-cm:20260819-1` — the only image on this host that carries both the telemetry sampler and artifact 046's engine fix, so bots actually move — with `Tournament.TelemetryIntervalMs = 5000`, 4,500 samples over 20 bots. `match-run.sh` could not be used (its gear gate still fails on this host, and gear-apply cannot run against this image), so I assembled directly with `tournament create` / `tournament add` / `tournament start`; the match ran the clock and was decided (`winner=1, duration=22m`). `bg role` cannot be read back (`rndbot debug <bot> values bg` crashes the world), so routes were attributed geometrically from the band just outside each base where the three branches separate cleanly on y, counting only the outbound leg. Result: of the crossings begun on the graveyard exit, 77.6% reached the middle of the map within 90 s, against 70.4% for the tunnel and 61.7% for the ramp; 17 of 20 bots used the graveyard at least once and all 17 came within 20 yd of the enemy flag room, averaging 5,765 yd travelled against 3,950 yd for the three that never used it; neither `noPath` drop produced any non-combat health loss or stall cluster, and the stalls are on the ramp (66 samples at the Horde ramp top, only 8 in combat). So the route was neither corrected nor disabled — there is nothing to correct and nothing worth turning off. What changed is the two false comments: `:2326` no longer claims the graveyard is disabled, the branch carries the measured numbers instead of a bare `(BUGGED)`, and the Alliance mirror says the same. `bg role`'s `urand(0, 9)` is untouched. `docs/playerbots/BG-AI-ANALYSIS.md` gains §4.7 with the run, the attribution method and its limits, and the F-07 row is marked refuted. This is a comments-and-docs commit: no executable code changed, so the compile risk is a stray comment syntax error only.

**In-game check:** No behavioural change is expected in-game: this commit edits only comments in `wsgPaths()` and adds a section to `BG-AI-ANALYSIS.md`. The generic smoke test is the whole of the required manual confirmation — server builds, mangosd reaches "World server is up and running!", bots spawn, a WSG match still runs to a result.

Fully scriptable, no human eyes needed:
1. The build itself is the real gate — the only way this commit can break anything is a comment that does not close, so a clean compile of `BattleGroundTactics.cpp` in the batch build IS the correctness check.
2. `docker logs tcm-mangosd` shows no new error lines around battleground start, and `bg.log` gains a `winner=` line for the match run in the batch validation.

Optional, to re-confirm the measurement itself rather than the commit (this is what I ran, and it is fully scripted):
1. Set `Tournament.TelemetryIntervalMs = 5000` in `~/tortoise-wow-server-V2/etc/mangosd.conf` and `docker restart tcm-mangosd` (the key is read only at boot).
2. Bring 20 roster bots online (`rndbot add <name>` for each name in `docs/playerbots/wsg/wsg-team-roster.txt`, in ONE `wsg_console` attach) and assemble directly: `tournament create 2 60`, then `tournament add <instance> <name>` ×20 in one attach, then `tournament start <instance>`. Do not use `match-run.sh` — its gear gate fails on this host and gear is irrelevant to pathing.
3. When the match ends, slice `bg.log` to the match's wall-clock window FIRST (instance ids are reused; extracting by id alone interleaves old matches and invents distances), then `scripts/tournament/telemetry-extract.sh --instance <id> --log <slice> --out telemetry.csv`.
4. Expect ≈4,500 samples, every bot moving except any that never left spawn, and graveyard-corridor crossings completing at least as often as tunnel and ramp ones. If the graveyard ever completes materially WORSE than the other two, §4.7's conclusion is wrong and the comments should be revisited.

A human watching in-game would only be needed to confirm the visual claim behind the numbers: `.appear` a bot leaving the Horde base whose route takes it south past the Horde graveyard at roughly (1055, 1397, 339) and confirm it drops cleanly off the ledge at (1077, 1396, 324) and keeps running east, rather than sticking against the ledge.

**Minor findings:**
- docs/playerbots/BG-AI-ANALYSIS.md: The F-07 summary-table row now leads with "REFUTED by measurement" but its Class cell still reads **broken** and its Observable-symptom cell still asserts "Roughly 3 in 10 bots take a route the author marked broken", so the same row both refutes and restates the finding.
- docs/playerbots/BG-AI-ANALYSIS.md: The comment insertions shift every line in BattleGroundTactics.cpp after :2326 by +4/+15 (the graveyard branch is now :2357, its mirror :2498, the tunnel test :2330), but the file:line citations in F-05, F-06, F-07 and F-10 were not updated and now point at the wrong lines in the very file this change edits.
- src/modules/PlayerBots/playerbot/strategy/actions/BattleGroundTactics.cpp: The artifact's second acceptance criterion requires one of exactly two outcomes — the route corrected or the branch disabled — and the change takes a third (neither, code unchanged); the evidence and commit message justify it, but a human should confirm the artifact is satisfied by a refutation rather than one of its two listed outcomes.
- src/modules/PlayerBots/playerbot/strategy/actions/BattleGroundTactics.cpp: The new comments describe the branch as "preference 4-6 ... plus any bot already standing in it", but the guard is `Preference < 7 || (atGY && urand(0, 2))`: a graveyard-standing bot with Preference 0-3 enters unconditionally while one with Preference 7-9 enters only two times in three, so the comment overstates the atGY case it was written to clarify.
