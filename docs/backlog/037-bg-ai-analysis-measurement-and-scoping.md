---
status: done
risk: low
area: playerbots/battlegrounds
depends-on: 036-bg-ai-analysis-code-reading.md
---

# The flag-carrier lead is reasoning, not evidence

**Problem:** `docs/playerbots/BG-AI-ANALYSIS.md` ends with a findings table built
entirely from reading code. The strongest lead — three commented-out flag-carrier
triggers at `BattlegroundStrategy.cpp:44-51` — *predicts* 0-0 draws, but nothing
has measured whether that is what actually happens. Until it is confirmed or
refuted with data, re-enabling those triggers would be a change made on a hunch,
and relevance interacts globally: raising one action starves others.

**Suspected cause / area:** Implements
`docs/superpowers/plans/2026-08-16-07-bg-combat-analysis.md` Tasks 3-4.

**Acceptance criteria:**

- A real WSG match has been run with `Tournament.TelemetryIntervalMs = 5000`, and
  `docs/playerbots/BG-AI-ANALYSIS.md` gains **§4** naming the run directory,
  duration and result.
- §4 answers four questions with numbers, not adjectives, each with where it was
  read from:
  - Do bots leave their base at all? (`REPORT ... entered=<n> stuck=<n>`)
  - Do the two sides ever occupy the same ground? Sustained separation means they
    are not fighting, which is a **different** problem from fighting badly.
  - How much of the match is spent in combat? (share of samples with `combat=1`)
  - Was the flag ever picked up? Honor bursts of 495 in `honor.log` mark flag
    captures — that is how the first recorded match was eventually shown to be a
    2-0 Horde win rather than the scoreless draw it was first reported as
    (`docs/playerbots/WSG-BOT-MATCH.md` §6).
- §4 states plainly whether the commented-out flag-carrier triggers are
  **confirmed** as the cause of 0-0 draws with supporting telemetry, or
  **explicitly refuted**, naming the measurement that refuted them.
- §4 ranks recommendations by expected match-quality improvement per unit of
  risk, saying so explicitly — a change touching shared pathing is higher risk
  than one re-enabling a trigger.
- One `docs/backlog/<NNN>-<slug>.md` artifact exists per **actionable** finding,
  in the format `docs/backlog/README.md` specifies, each with acceptance criteria
  that are checkable. A finding that is interesting but not actionable stays in
  the analysis and gets no artifact — the backlog is work, not a notebook.
- The analysis and the artifacts cross-link: every §4 recommendation names its
  artifact path, and every artifact's **Notes** names
  `docs/playerbots/BG-AI-ANALYSIS.md` as its source.
- **No bot AI behaviour is changed by this artifact.**

**Notes:**

- **This artifact requires a running stack and a full ~25-minute match.** It needs
  `Tournament.TelemetryIntervalMs = 5000` in the live bind-mounted
  `~/tortoise-wow-server-V2/etc/mangosd.conf` followed by
  `docker restart tcm-mangosd` (the conf is read only at startup), then
  `scripts/tournament/match-run.sh` end to end, which itself needs teams created,
  geared and logged in. **If a live stack is not available, report this artifact
  blocked rather than writing §4 from reasoning.** A §4 that reads like a
  measurement but was inferred is worse than an empty §4 — the whole point of the
  section is that it is evidence.
- **Check the running image before deciding it is blocked, and say which image it
  was either way.** `Tournament.TelemetryIntervalMs` is read by the telemetry
  sampler from artifact 026 — C++, so it exists only in an image built *after*
  026 was batched. Run `docker ps --format '{{.Names}} {{.Image}}'`:
  - `tortoise-cm:<buildId>` containing 026 and 029 — the measurement is possible;
    take it. The batch pass leaves the stack up on the image it validated and
    `.env`'s `TW_IMAGE` tracks that tag, so this is the expected case by the time
    this artifact is picked (026 and 029 batch several waves earlier).
  - `tortoise-cm:c06b2fb`, or any image predating 026 — the sampler is not in the
    binary, `mangosd.conf` will accept the key and nothing will emit samples.
    That is `blocked`, and the `blockedReason` must name the image that was
    running, not just "no telemetry".
  An empty `telemetry.csv` from an image without the sampler and an empty one from
  bots that never left their base look identical in the output and mean opposite
  things. Distinguishing them is the image check, not the data.
- **`bots.log` is ~10 GB.** Use `scripts/tournament/bot-log-capture.sh --mark` /
  `--since` (artifact 029) for the match window; never an unbounded read.
- Number any new backlog artifacts by the method in `docs/backlog/README.md` —
  the highest of the git-history high-water mark, the `<!-- BACKLOG-COUNTER -->`
  block, and the files present, plus one. **Numbers are never reused.** Bump the
  counter block in the same commit.
- Leave every new artifact at `status: pending` and do not run any drain against
  them. They have not been reviewed by a human, and they were scoped by an agent
  from its own findings — that is exactly the case that wants a person to read
  them first.
- Faction skew is worth checking against `bg.log`'s winner history
  (`0`=HORDE, `1`=ALLIANCE, `2`=draw, `BattleGround.h:187-189`), but report the
  sample count alongside the ratio — a strong skew on a small sample is not
  evidence.

**Base:** backlog/bg-ai-analysis-code-reading

**Branch:** backlog/bg-ai-analysis-measurement-and-scoping

**Summary:** Ran a real 20-minute Warsong Gulch match on the live stack and turned `docs/playerbots/BG-AI-ANALYSIS.md`'s code-reading into evidence. Brought up `tcm-db` + `tcm-mangosd` on `tortoise-cm:20260818-2` (the only image on this host whose commit graph contains artifact 026's C++ telemetry sampler — `.env`'s `TW_IMAGE=tortoise-cm:20260818-3` does not, since `41e15e4` is reachable only from `integration/20260818-2`), set `Tournament.TelemetryIntervalMs = 5000` in the bind-mounted `mangosd.conf`, turned the 1000-bot random pool off so `match-run.sh`'s population gate could pass, and ran `match-run.sh stormwind-sentinels orgrimmar-warsong` end to end (run dir `/home/deck/tournament-runs/037-wsg-2`). Result: full 20-minute cap, 0-0 draw, and all 20 bots stood motionless on their spawn points — `REPORT players=20 expected=20 entered=20 stuck=20`, every `MOVEMENT` line `distance=0.0`, `combat=1` in 0 of 4540 samples, minimum Alliance-Horde separation 544.8 yd, closest approach to an enemy flag 579.5 yd, zero 495-honor bursts in `honor.log`. `bots.log` sliced to the match window (25,476 AI ticks) names the mechanism: `bg move to objective` was queued 23,908 times and popped **zero** times, while `bg check flag` (relevance 70 from `WarsongStrategy`, 20 from `BattlegroundStrategy`) failed 23,681 times and 98.8% of ticks ended `no actions executed`. The document gains **§4** with all of that plus a ranked recommendation table, and nine new backlog artifacts (046-054), one per actionable finding, with §4.5 listing the seven findings that deliberately get none. The `docs/backlog/README.md` counter is bumped to 054/next 055. Only `docs/` changed — no bot AI behaviour, no source, no SQL. The live `aiplayerbot.conf` and `mangosd.conf` were restored to their pre-run values and `tcm-mangosd` restarted, verified identical to the backups.

**In-game check:** This artifact changes only `docs/`, so the in-game check is two things: a generic smoke test, and a re-run of the measurement itself so the numbers in §4 can be trusted by whoever works artifacts 046/047 next. Almost all of it is scriptable.

**Scriptable — no human needs to watch:**

1. Smoke test. `docker compose --env-file <main-checkout>/.env up -d db mangosd`, wait for `World server is up and running!` in `docker logs tcm-mangosd` (that is the readiness line on this fork, ~45 s; there is no "World initialized" line, do not wait for one), then confirm ~1000 bots log in: `select count(*) from tw_char.characters where online=1;` against `tcm-db` should climb well past 100. No source changed, so a diff-only failure here means something else is wrong.
2. Re-run the measurement. It needs an image whose commit graph contains `41e15e4` (artifact 026's sampler) — on this host that is `tortoise-cm:20260818-2`, **not** `tortoise-cm:20260818-3`. Check with `git branch --contains 41e15e4` before blaming empty telemetry on the bots. Then, from WSL: set `Tournament.TelemetryIntervalMs = 5000` in `~/tortoise-wow-server-V2/etc/mangosd.conf`, set `AiPlayerbot.MinRandomBots`/`MaxRandomBots` to 0 in `aiplayerbot.conf` (otherwise `match-run.sh`'s population gate fails by design), `docker restart tcm-mangosd`, then `./scripts/tournament/match-run.sh stormwind-sentinels orgrimmar-warsong --run-dir <dir>`.
3. Assert the §4 numbers reproduce, from the logs alone: `scripts/tournament/telemetry-extract.sh --instance <id>` then `telemetry-report.sh` should print `REPORT players=20 expected=20 entered=20 stuck=20` with every `MOVEMENT` line reading `distance=0.0`; `awk` over the CSV should give `combat=1` in 0 of the samples; and `grep -c "A:move to objective" bots.log` over the match window should be **0** against ~24,000 `PUSH:bg move to objective - 1.000000` lines. `grep "495.000000 honor" honor.log` should show nothing for that date.

Two traps that cost this run time and are worth repeating: `match-run.sh` reuses instance id 101 after a mangosd restart, so slice `bg.log` by line offset before extracting or you will analyse the *previous* match; and `gear-audit.sh` currently fails both teams (`complete=5/10` and `6/10`), so the gear gate aborts the run before assembly unless it is bypassed — that is recorded in §4.5 and belongs to artifact 031.

**Needs a human, and only this:** log in a GM, `.go xyz 1230 1476 307 489` into the Warsong Gulch instance while a match is running, and look. §4 claims twenty bots standing still on two spawn points half a map apart; that is the one claim worth confirming with eyes, because it is so unlike a normal match that a reader will assume the telemetry is broken. Note that the GM's presence changes bot behaviour on their own faction (`BgTeamHasRealPlayer`, finding F-14), so do this as a confirmation of the standing-still, not as a source of new numbers.

**Minor findings:**
- docs/playerbots/BG-AI-ANALYSIS.md: §4.5 defers the gear-gate blocker (`gear-apply.sh` cannot dress 9 of 20 bots, so `gear-audit.sh` fails and `match-run.sh` aborts before assembly) to `docs/backlog/031-gear-tier-armour-weapon-split.md`, but 031 is scoped to splitting a tier into armour/weapon sets for viewer effects and says nothing about `cannot_equip` items — so a finding that makes the match-run acceptance criteria of 046, 047 and 053 unrunnable on this host has no artifact and a pointer that reads as if it does.
- docs/backlog/050-team-flagcarrier-near-trigger-is-never-registered.md: 050 and 051 name the trigger registry as `src/modules/PlayerBots/playerbot/strategy/TriggerContext.h`, which does not exist — the file is `strategy/triggers/TriggerContext.h` — and 051's cited registration lines (`:185`, `:187`, `:191`) are each one off from the real ones (184, 186, 190), so both artifacts' acceptance criteria point at a nonexistent path.
- docs/backlog/050-team-flagcarrier-near-trigger-is-never-registered.md: 050's third acceptance criterion ("one WSG match ... shows `A:protect fc` lines in `bots.log`") cannot be met until 046 lands, since no bot moves or carries a flag, yet 050 has an empty `depends-on:` while 053 correctly declares `depends-on: 046-...` for the same reason — drain can pick 050, restore the trigger node, and be unable to satisfy its own criterion.
- docs/playerbots/BG-AI-ANALYSIS.md: §4.3 cites the commented-out flag-carrier triggers at `BattlegroundStrategy.cpp:44-56` while artifact 037 cites `:44-51`; the three commented blocks actually span `:44-54`, so neither reference is right.

**Drain note (THIRD independent confirmation of the same result):** this tick ran a fresh 20-minute match and reproduced, from a different match and a different code path, what the drain had already measured twice. Its numbers: REPORT players=20 expected=20 entered=20 stuck=20, every MOVEMENT distance=0.0, combat=1 in 0 of 4540 samples, 25476 AI ticks with 98.8% ending "no actions executed", `bg move to objective` queued 23908 times and popped ZERO times, `bg check flag` failing 23681 times. The drain independently measured on the batch 20260818-2 validate match: 0.0 yards for all 20 bots over 172 samples, combat=0 throughout, 8708 AI ticks with 98.3% "no actions executed", check flag PREREQ failing 6810 of 6810. Two separate matches, two separate analyses, same conclusion. The 98.3% / 98.8% agreement across independent runs is strong. This is no longer a hypothesis.

**Drain note (STRUCTURAL DEFECT in the backlog-drain skill, step 4a — and a correction to what the drain previously recorded):** this tick was RIGHT and the drain was WRONG about which image to test on, and the underlying cause is a real flaw worth fixing in the skill.

The drain previously stated that .env pointing at tortoise-cm:20260818-3 gave later ticks an image containing artifact 026's telemetry sampler. It does not. Verified 2026-08-18:

```
git branch --contains 41e15e4   ->  backlog/battleground-telemetry-sampler
                                    integration/20260818-2      (ONLY)
git merge-base --is-ancestor backlog/battleground-telemetry-sampler integration/20260818-3  ->  NOT contained
```

The reason is structural: each batch cuts integration/<buildId> from cm-main and merges only THAT batch's branches. Earlier batches' PRs are still open against cm-main, so their work is absent from every later integration branch. Consequently the images do NOT accumulate — tortoise-cm:20260818-3 contains 028/031/035/036 (all shell and docs) but NONE of 017/021/022/025/026/027/029/030. It is strictly LESS capable for testing than 20260818-2, which at least carries batch 2's C++.

That makes the skill's step 4a actively harmful as written: it says to point TW_IMAGE at the newest image so later ticks can "test rather than reason", but the newest image can silently lack C++ features an older one had. Following it here pointed .env at the one recent image with no telemetry sampler at all. The correct rule is to point .env at the newest image whose commit graph CONTAINS the capability being tested, checked with `git branch --contains <commit>` — which is exactly what this tick did, and why it chose 20260818-2 and said so. The Implement prompt's existing "read the running image with docker ps rather than assume" discipline is what caught it.

**Drain note (findings 2 and 4 verified; they matter because they land in NEW backlog artifacts):** 
- Finding 2 HOLDS. `src/modules/PlayerBots/playerbot/strategy/TriggerContext.h` does not exist; the real path is `src/modules/PlayerBots/playerbot/strategy/triggers/TriggerContext.h`, and artifact 050 cites the former. This is worse than an ordinary doc typo because 050 and 051 are newly created backlog artifacts that a future drain tick will pick up and work from — the broken path would propagate into their acceptance criteria and cost that tick real time. Fix before either is drained.
- Finding 4 HOLDS and matches the drain's own earlier reading: the three commented-out blocks in BattlegroundStrategy.cpp span :44-54. The analysis says :44-56 and artifact 037 says :44-51; neither is right.
- Finding 3 is a genuine dependency bug in a new artifact: 050 has an empty depends-on: yet its third acceptance criterion cannot be satisfied until 046 lands, while sibling 053 correctly declares depends-on: 046 for the identical reason. Left as-is, a future drain tick will pick 050, do the work, and be unable to meet its own criterion.
- Finding 1 is the most consequential for planning: the gear gate blocks match-run on this host (gear-audit reports complete=5/10 and 6/10), which makes the match-run acceptance criteria of 046, 047 and 053 unrunnable, and it is deferred to artifact 031 — which is scoped to splitting tiers for viewer effects and says nothing about cannot_equip items. A blocker with a pointer that only looks like an owner.

**Note on scope:** this tick created nine new artifacts (046-054) and bumped docs/backlog/README.md to 054/next 055. They exist only on this branch, so they are NOT visible to the current drain and will enter the backlog only once this PR merges to cm-main. This drain session will not pick them up.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/46, build tortoise-cm:20260818-4.
