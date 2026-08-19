---
status: pending
risk: low
area: playerbots/config
depends-on:
---

# WSG bots captured flags until 2026-08-11 and have never captured one since

**Problem:** `bg.log` and `honor.log` bracket a regression to a window of six
days, and it is a config window, not a code window.

`bg.log`, all completed Warsong Gulch matches (`[2,<instance>]: winner=<n>`,
`0`=HORDE `1`=ALLIANCE `2`=draw, `BattleGround.h:187-189`):

| date | Horde | Alliance | draw |
|---|---|---|---|
| 2026-08-10 | 6 | 15 | 14 |
| 2026-08-11 | 0 | 1 | 1 |
| 2026-08-17 | 0 | 0 | 2 |
| 2026-08-18 | 0 | 0 | 5 |

`honor.log`, flag-capture honour awards (a 495.0 "type 3" burst to all ten
players of the scoring team): **184 on 2026-08-10, 30 on 2026-08-11, none ever
since.**

So: 22 decisive matches and every flag capture on this server fall on
2026-08-10/11. Every match from 2026-08-17 onward is a scoreless draw, and the
2026-08-18 measurement in `docs/playerbots/BG-AI-ANALYSIS.md` §4 shows why —
the bots do not move a single yard.

The bot AI code cannot be the change: `strategy/generic/BattlegroundStrategy.cpp`
has not been touched since 2026-05-10, and `strategy/actions/BattleGroundTactics.cpp`
not since 2026-07-28 — both before the working window.

`aiplayerbot.conf` did change. Diffing the live
`~/tortoise-wow-server-V2/etc/aiplayerbot.conf` against its own
`aiplayerbot.conf.bak-alive-20260809` backup, the keys that changed or appeared
include:

```
AiPlayerbot.DisableActivityPriorities   0    -> 1
AiPlayerbot.DisableBotOptimizations     -    -> 1
AiPlayerbot.botActiveAlone              -    -> 30
AiPlayerbot.GlobalCooldown              1500 -> 500
AiPlayerbot.RepeatDelay                 5000 -> 2000
AiPlayerbot.MinRandomBots/MaxRandomBots 50   -> 1000
AiPlayerbot.AreaLevelGateEnabled        -    -> 1
AiPlayerbot.DestinationDangerEnabled    -    -> 1
AiPlayerbot.TravelPreemptiveLevelGap    -    -> 3
AiPlayerbot.FightBackWhileTraveling     -    -> 1
AiPlayerbot.*CombatStrategies                 += ,+pull
AiPlayerbot.*NonCombatStrategies              += ,+rpg,-rpg bg,-rpg explore,+pull
```

**Suspected cause / area:** `~/tortoise-wow-server-V2/etc/aiplayerbot.conf`
(bind-mounted, not in this repo, read only at mangosd startup). No source file is
implicated; nothing here needs a build.

**Acceptance criteria:**

- The list above is bisected against a real WSG match, not reasoned about. Each
  round: edit the live `aiplayerbot.conf`, `docker restart tcm-mangosd`, run
  `./scripts/tournament/match-run.sh stormwind-sentinels orgrimmar-warsong`,
  and read the telemetry.
- The pass/fail signal per round is fixed in advance and taken from the
  telemetry CSV: **at least 15 of 20 bots with `distance > 100`** on
  `scripts/tournament/telemetry-report.sh`'s `MOVEMENT` lines. "Looks livelier"
  is not a result.
- The bisect starts from the whole 2026-08-09 backup restored wholesale — if
  that config does *not* restore movement, the cause is not in this file and the
  artifact says so and stops, rather than working down the list anyway.
- The finding is recorded in `docs/playerbots/BG-AI-ANALYSIS.md` §4 naming the
  key(s), the value that breaks it, the value that fixes it, and the number of
  matches each was measured over.
- Whatever the outcome, `aiplayerbot.conf` is left in a stated, recorded state —
  not halfway through a bisect.

**Notes:**

- Source: `docs/playerbots/BG-AI-ANALYSIS.md` §4.
- Do this before, or alongside,
  `docs/backlog/046-wsg-bots-never-execute-bg-move-to-objective.md`: this one is
  config-only and carries no code risk, and if a single key restores movement,
  046's engine question becomes far cheaper to answer with a working baseline to
  compare against.
- Restore `AiPlayerbot.MinRandomBots`/`MaxRandomBots` to 1000 when finished, or
  say explicitly that they were left at 0 — `match-run.sh`'s population gate
  requires the random pool to be off for a match, and the alive-world config
  requires it on.
- Each round costs a ~25 minute match plus a mangosd restart. Order the list by
  how plausibly a key could freeze a bot inside an instance — the movement and
  activity gates (`DisableActivityPriorities`, `botActiveAlone`,
  `AreaLevelGateEnabled`, `DestinationDangerEnabled`,
  `TravelPreemptiveLevelGap`) before the cosmetic ones — and say in the record
  which order was used.
