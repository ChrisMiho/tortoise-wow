---
status: pending
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
