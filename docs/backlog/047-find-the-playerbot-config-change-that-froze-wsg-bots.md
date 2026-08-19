---
status: implemented
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

**Base:** cm-main

**Branch:** backlog/find-the-playerbot-config-change-that-froze-wsg-bots

**Summary:** Ran the bisect the artifact asked for, live, and it terminated on its own first round. I brought the stack up on `tortoise-cm:20260818-2` (the only telemetry-capable image, and the same one §4.0 measured on — it predates artifact 046's `Engine::StrategySignature` fix), copied `~/tortoise-wow-server-V2/etc/aiplayerbot.conf.bak-alive-20260809` over the live `aiplayerbot.conf` wholesale with only `MinRandomBots`/`MaxRandomBots` forced to 0 so `match-run.sh`'s population gate could pass, set `Tournament.TelemetryIntervalMs = 5000`, restarted mangosd, and ran `match-run.sh stormwind-sentinels orgrimmar-warsong` twice (14:00–14:18Z, 19 bots entered; 14:30–14:49Z, 20 bots entered, `winner=NONE allianceScore=0 hordeScore=0 duration=1118`). The pre-registered signal — at least 15 of 20 bots with `distance > 100` on `telemetry-report.sh`'s MOVEMENT lines — scored **0 of 20 in both matches**: 39 of 39 bot-slots read `distance=0.0 maxStep=0.0 stuck=1`, and `combat=1` in zero samples. Under the artifact's own stop rule that ends the bisect: the cause is not in `aiplayerbot.conf`, so no individual key was tried, and §4.2a's engine defect (`Engine::ChangeStrategy` → `Init()` → `Reset()` wiping the action queue every tick) remains the whole explanation. The only change committed is a new `docs/playerbots/BG-AI-ANALYSIS.md` §4.6 recording the config, the images, both matches, the numbers, the order the keys would have been tried in, and the stated end state. It also records a measurement trap that nearly faked a pass: battleground instance ids are reused (every run got `instance=101`) and `telemetry-extract.sh` filters `bg.log` by instance id alone over the whole file, so two matches interleave into invented `distance=16080.3 maxStep=38.4` figures for bots that never moved — the run directory's own `telemetry.csv` has the same defect since `match-run.sh:539` passes only `--instance`; slicing `bg.log` to the match's wall-clock window and passing it with `--log` is what produced the real numbers. No source file and no SQL migration was touched, so nothing here needs a build. The live `aiplayerbot.conf` and `mangosd.conf` are byte-identical to the backups taken before the run (`aiplayerbot.conf.pre-047-bisect-20260819`, `mangosd.conf.pre-047-20260819`): `MinRandomBots`/`MaxRandomBots` back at 1000, `Tournament.TelemetryIntervalMs` back at 0, and the stack was brought down with a plain `docker compose down` (`tortoise-wow-v2_dbdata` verified present afterwards).

**In-game check:** This branch changes no code and no config — it is a documentation-only record of a negative measurement — so the only generic check it needs is the batch smoke test: server starts, bots spawn. There is nothing new to see in-game from this commit itself.

What a human *can* confirm, and most of it is scriptable rather than visual:

1. Confirm the live config is where §4.6 says it is (scriptable, no server needed): on the host, `diff ~/tortoise-wow-server-V2/etc/aiplayerbot.conf ~/tortoise-wow-server-V2/etc/aiplayerbot.conf.pre-047-bisect-20260819` and the same diff for `mangosd.conf` vs `mangosd.conf.pre-047-20260819` must both be empty; `grep -E '^AiPlayerbot.(Min|Max)RandomBots' aiplayerbot.conf` must read 1000 and `grep '^Tournament.TelemetryIntervalMs' mangosd.conf` must read 0. If any of those differ, someone left a bisect half-applied and §4.6's "state left behind" paragraph is stale.
2. Re-confirm the negative, if anyone doubts it (scriptable, ~25 min, needs the stack): set `Tournament.TelemetryIntervalMs = 5000`, copy `aiplayerbot.conf.bak-alive-20260809` over `aiplayerbot.conf` with `MinRandomBots`/`MaxRandomBots` set to 0, `docker restart tcm-mangosd`, run `scripts/tournament/match-run.sh stormwind-sentinels orgrimmar-warsong` with `ASSEMBLE_MODE=direct`, then — this part matters — slice `logs/bg.log` to that match's wall-clock window before running `telemetry-extract.sh --instance <n> --log <slice>`, because instance ids repeat and extracting by id alone silently merges this match with 2026-08-18's and reports movement that did not happen. The expected result is every `MOVEMENT` line reading `distance=0.0 maxStep=0.0 stuck=1` and `REPORT ... stuck=20`. Restore both configs afterwards.
3. The positive check this artifact hands off to artifact 046 (needs an image built from `cm-main` after commit `74d2ace`, so not this branch): same procedure, and the same telemetry gate should then flip to at least 15 of 20 bots with `distance > 100`. A human watching with `.go xyz` into the WSG instance would see bots leave both bases and meet in the middle field instead of standing on their spawn circles for the full 20 minutes; from logs alone, `A:move to objective - OK` appearing in `bots.log` for five or more distinct `Wsg*` bots, and a non-zero `allianceScore`/`hordeScore` on the `MATCH` line, are the scriptable equivalents.

**Minor findings:**
- docs/playerbots/BG-AI-ANALYSIS.md: §4.6 concludes the regression is "not in aiplayerbot.conf", but the single round was run on `tortoise-cm:20260818-2`, an image that still carries the `Engine::ChangeStrategy` → `Init()` → `Reset()` queue wipe (fixed only in 74d2ace) which by §4.2a freezes every bot regardless of config — so the 2026-08-09 config is confounded/untested rather than exonerated, and the section should say the config question can only be reopened on a post-fix build.
- docs/playerbots/BG-AI-ANALYSIS.md: The Result row's headline "0 of 20 bots with `distance > 100`" does not say which extraction it came from, even though the same section warns that the run directory's `telemetry.csv` (and any `--instance`-only extract) interleaves 2026-08-18's instance 101 and invents `distance=16080.3`, leaving the one load-bearing number in the record untraceable to a time-sliced `bg.log`.
- docs/playerbots/BG-AI-ANALYSIS.md: The Result row states "0 of 20 bots ... in either match" while its own Matches row records only 19 bots entering the first match and 39 total bot-slots, so the denominator in the pass/fail statement contradicts the run it is describing.
