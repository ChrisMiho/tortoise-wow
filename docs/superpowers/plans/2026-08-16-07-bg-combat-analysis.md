# Battleground Bot Combat Analysis — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a written, evidence-backed account of how the bot battleground AI
actually decides what to do, what is broken or disabled in it, and what would most
improve match quality — plus a scoped backlog artifact per finding.

**Architecture:** This is an investigation, not a feature. Its deliverables are
documents and backlog artifacts, and every claim in them is anchored to a `file:line`
or to telemetry from a real match. Nothing in the bot AI is changed here; changes are
scoped as separate artifacts so each can be reviewed on its own.

**Tech Stack:** Reading C++, `grep`, telemetry CSV from Plan 05, `bg.log`.

**Spec:** `docs/superpowers/specs/2026-08-16-bot-tournament-design.md` (§1.5)

**Depends on:** `2026-08-16-05-bg-telemetry.md` — the movement and entry reports are
the evidence half of this analysis. The code-reading half can start before that lands.

## Global Constraints

- **Change nothing in the bot AI in this plan.** Every improvement becomes a
  `docs/backlog/` artifact. A behavioural change bundled into an investigation is a
  change nobody reviewed against a measurement.
- **Every claim carries a `file:line` or a measurement.** "Bots seem passive" is not
  a finding; "`enemy flagcarrier near → attack enemy flag carrier` is commented out
  at `BattlegroundStrategy.cpp:44-46`" is.
- `BattleGroundTactics.cpp` is 4954 lines. Read it in bounded passes by concern, not
  end to end.
- `bots.log` is ~10 GB — use `bot-log-capture.sh` from Plan 05, never an unbounded
  read.
- Distinguish **disabled** (commented out, config-gated off) from **broken** (runs
  and does the wrong thing) from **absent** (never written). The fix for each is
  different and the artifacts must say which.

---

## What is already known

Recorded here so the investigation starts from the current frontier rather than
rediscovering it:

- `BGJoinAction::isUseful()` re-rolled a hardcoded 20% tank/healer gate over a queue
  choice the operator had already made, and `Engine::ExecuteAction` gates every
  commanded action on `isUseful()` — so `bg join` never ran. Fixed; measured 0/3
  commanded joins before, 8/8 after (`docs/playerbots/WSG-BOT-MATCH.md` §3).
- The queue gates are enumerated at `BattleGroundJoinAction.cpp:544-590`:
  `randomBotJoinBG`, already in BG, <30 s since login, level<10, player master (568),
  in combat (574), Deserter (578), no free slot (582), tank/healer roll (586).
- Matches are hard-capped at 20 minutes (`BattleGround.cpp:317-323`), a **custom**
  addition to this server, made precisely because bots stand around instead of
  capping flags.
- **Two flag-carrier triggers are commented out** in
  `BattlegroundStrategy.cpp:44-51`: `enemy flagcarrier near → attack enemy flag
  carrier` (relevance 80) and `team flagcarrier near → bg protect fc` (40). A third,
  `player has flag → bg move to objective` (90), is also commented out.

That last item is the single most promising lead in the whole file and Task 3 is
built around confirming or refuting it.

---

## File Structure

| File | Responsibility |
|---|---|
| `docs/playerbots/BG-AI-ANALYSIS.md` (create) | The deliverable: order of operations, findings, recommendations |
| `docs/backlog/NNN-*.md` (create, one per actionable finding) | Scoped work, for the drain |

---

### Task 1: Map the order of operations

**Files:**
- Create: `docs/playerbots/BG-AI-ANALYSIS.md` (sections 1-2)

**Deliverable:** a written trace of how a bot in a battleground decides what to do,
from trigger to action, with `file:line` for each hop.

- [ ] **Step 1: Enumerate the strategies and their triggers**

```bash
grep -n "InitNonCombatTriggers\|InitCombatTriggers\|InitTriggers" \
  src/modules/PlayerBots/playerbot/strategy/generic/BattlegroundStrategy.cpp
sed -n '1,249p' src/modules/PlayerBots/playerbot/strategy/generic/BattlegroundStrategy.cpp
```

Record, for **every** strategy class in that file (`BGStrategy`,
`BattlegroundStrategy`, `WarsongStrategy`, and any others): each trigger, the action
it fires, and the relevance value. Relevance is the priority — it decides which
action wins when several are eligible, and it is the number that explains most
observed behaviour.

- [ ] **Step 2: Record which triggers are commented out**

```bash
grep -n "^\s*/\*triggers.push_back" -A 4 \
  src/modules/PlayerBots/playerbot/strategy/generic/BattlegroundStrategy.cpp
```

For each, note the trigger, the action, the relevance, and — by reading the
surrounding code — whether the action it names still exists. A commented-out trigger
naming an action that was deleted is a dead end; one naming a live action is a
switch someone turned off.

- [ ] **Step 3: Trace `BGTactics::Execute`**

```bash
grep -n "bool BGTactics::Execute" -A 120 \
  src/modules/PlayerBots/playerbot/strategy/actions/BattleGroundTactics.cpp
```

Write down the branch order: which condition is checked first, what each branch
calls, and where each returns. The private helpers are declared at
`BattleGroundTactics.h:60-81` — `moveToStart`, `selectObjective`, `moveToObjective`,
`selectObjectiveWp`, `moveToObjectiveWp`, `startNewPathBegin`, `startNewPathFree`,
`resetObjective`, `wsgPaths`, `atFlag`, `flagTaken`, `teamFlagTaken`, `protectFC`,
`useBuff`, `getDefendersCount`, `IsLockedInsideKeep`.

**Order matters more than content here.** An early `return true` starves everything
below it, and that is the shape most "bot does nothing" bugs take.

- [ ] **Step 4: Write sections 1-2 of the deliverable**

`docs/playerbots/BG-AI-ANALYSIS.md`:

```markdown
# Battleground bot AI — how it actually works

Analysis dated 2026-08-16, against <commit sha>. Every claim below carries a
`file:line`. Nothing here changes behaviour; actionable findings are scoped as
`docs/backlog/` artifacts and linked from §4.

## 1. Strategy and trigger table

| Strategy | Trigger | Action | Relevance | Live? |
|---|---|---|---|---|
| ... | ... | ... | ... | active / commented out |

## 2. BGTactics::Execute — order of operations

<numbered branch order, each with file:line and what starves if it returns early>
```

Fill both tables completely. A partially-filled table is worse than none — it
implies the gaps were checked and found empty.

- [ ] **Step 5: Commit**

```bash
git add docs/playerbots/BG-AI-ANALYSIS.md
git commit -m "docs(bg-ai): map the battleground strategy triggers and tactics order"
```

---

### Task 2: Bug hunt across the tactics code

**Files:**
- Modify: `docs/playerbots/BG-AI-ANALYSIS.md` (section 3)

**Deliverable:** a findings table. Each row: what, `file:line`, classification
(disabled / broken / absent), observable symptom, confidence.

- [ ] **Step 1: Sweep for the failure shapes that actually occur here**

Run each of these and read the hits. They are chosen because each maps to a symptom
already seen on this server, not because they are generically suspicious:

```bash
T=src/modules/PlayerBots/playerbot/strategy/actions/BattleGroundTactics.cpp

# Early returns in Execute -- the "bot does nothing" shape.
grep -n "return true;\|return false;" "$T" | head -60

# Hardcoded probability rolls. One already caused 0/3 commanded joins to fail
# (BGJoinAction::isUseful).
grep -n "urand\|rand()\|frand" "$T"

# Distance and range constants -- an objective radius that is too tight makes a
# bot orbit forever without ever arriving.
grep -n "sqrt\|GetDistance\|IsWithinDist\|INTERACTION_DISTANCE" "$T" | head -40

# Map-id and team assumptions.
grep -n "489\|GetMapId()\|== ALLIANCE\|== HORDE" "$T" | head -40

# Null dereference risk on objective/path lookups.
grep -n "->at(\|\[0\]\|\.front()\|\.back()" "$T" | head -40
```

- [ ] **Step 2: Check the flag logic specifically**

WSG is a flag game, and the observed failure is 0-0 draws. So the flag path gets its
own pass:

```bash
grep -n "bool BGTactics::flagTaken" -A 60 "$T"
grep -n "bool BGTactics::teamFlagTaken" -A 60 "$T"
grep -n "bool BGTactics::atFlag" -A 80 "$T"
grep -n "bool BGTactics::protectFC" -A 60 "$T"
```

For each: does it ever return true under a realistic match state? Is it reachable
from `Execute`'s branch order (Task 1 Step 3)? An unreachable correct function is
the same as a broken one from the match's point of view.

- [ ] **Step 3: Check `wsgPaths` and the waypoint data**

```bash
grep -n "bool BGTactics::wsgPaths" -A 80 "$T"
grep -n "BattleBotPath" src/modules/PlayerBots/playerbot/strategy/actions/BattleGroundTactics.cpp | head -20
```

Establish where the WSG paths come from, how many there are, and whether both
factions have symmetric coverage. Asymmetric path data would show up as one faction
consistently outperforming the other — cross-check against `bg.log` winner history:

```bash
grep -a "^\[2,.*winner=" ~/tortoise-wow-server-V2/logs/bg.log | \
  sed -n 's/.*winner=\([0-9]*\).*/\1/p' | sort | uniq -c
```

`0`=HORDE, `1`=ALLIANCE, `2`=draw (`BattleGround.h:187-189`). A strong skew is
evidence; a small sample is not — report the count alongside the ratio.

- [ ] **Step 4: Write section 3**

```markdown
## 3. Findings

| # | Finding | Where | Class | Symptom | Confidence |
|---|---|---|---|---|---|
| 1 | `enemy flagcarrier near → attack enemy flag carrier` is commented out | `BattlegroundStrategy.cpp:44-46` | disabled | nobody chases a flag carrier; matches end 0-0 | high |
| ... | | | | | |

Confidence is `high` only where the code path was read end to end **and** a
matching symptom was observed in telemetry or `bg.log`. Everything else is
`medium` or `low`, and says what would raise it.
```

- [ ] **Step 5: Commit**

```bash
git add docs/playerbots/BG-AI-ANALYSIS.md
git commit -m "docs(bg-ai): findings from the tactics bug hunt"
```

---

### Task 3: Confirm or refute the flag-carrier lead with telemetry

**Files:**
- Modify: `docs/playerbots/BG-AI-ANALYSIS.md` (section 4)

The commented-out flag-carrier triggers are the strongest lead. This task settles
whether they explain the 0-0 draws, using data rather than reasoning.

- [ ] **Step 1: Run a match with telemetry on**

```bash
sed -i 's/^Tournament.TelemetryIntervalMs.*/Tournament.TelemetryIntervalMs = 5000/' \
  ~/tortoise-wow-server-V2/etc/mangosd.conf
docker restart tcm-mangosd
# wait for the world, then:
./scripts/tournament/match-run.sh stormwind-sentinels orgrimmar-warsong \
  --run-dir logs/tournament/ai-analysis
```

- [ ] **Step 2: Ask the data three questions**

```bash
CSV=logs/tournament/ai-analysis/telemetry.csv

# 1. Do bots leave their base at all? (movement report, Plan 05)
./scripts/tournament/telemetry-report.sh "$CSV"

# 2. Do the two sides ever occupy the same ground? Sustained separation means
#    they are not fighting, which is a different problem from fighting badly.
awk -F, 'NR>1 { print $1","$3","$4","$5 }' "$CSV" | head -40

# 3. How much of the match is spent in combat at all?
awk -F, 'NR>1 { total++; if ($10 == 1) fighting++ }
         END { printf "samples=%d inCombat=%d (%.1f%%)\n", total, fighting, 100*fighting/total }' "$CSV"
```

- [ ] **Step 3: Check whether the flag was ever picked up**

```bash
grep -a "flag\|Flag" logs/tournament/ai-analysis/bots-match.log | head -40
grep -a "\[489," ~/tortoise-wow-server-V2/logs/bg.log | tail -40
```

Honor bursts of 495 in `honor.log` mark flag captures — that is how the first
recorded match was eventually shown to be a 2-0 Horde win rather than the scoreless
draw it was first reported as (`docs/playerbots/WSG-BOT-MATCH.md` §6).

- [ ] **Step 4: Write section 4 — the verdict and the recommendations**

```markdown
## 4. Measured behaviour, and what to change

Match: <run dir>, <duration>, result <winner>.

| Question | Measurement | Reading |
|---|---|---|
| Do bots leave base? | `entered=N stuck=M` | ... |
| Do the sides meet? | ... | ... |
| Time in combat | `inCombat=N (X%)` | ... |
| Was the flag ever taken? | ... | ... |

### Recommendations, highest expected value first

1. **<change>** — expected effect, risk, and the artifact that scopes it:
   `docs/backlog/NNN-<slug>.md`
2. ...

Ranked by expected match-quality improvement per unit of risk. A change that
touches shared pathing is higher risk than one that re-enables a trigger, and the
ranking says so explicitly.
```

- [ ] **Step 5: Commit**

```bash
git add docs/playerbots/BG-AI-ANALYSIS.md
git commit -m "docs(bg-ai): measured match behaviour and ranked recommendations"
```

---

### Task 4: Scope each actionable finding as a backlog artifact

**Files:**
- Create: `docs/backlog/NNN-<slug>.md`, one per actionable finding

**Interfaces:**
- Consumes: the findings table from Task 2 and the ranking from Task 3.
- Produces: artifacts in the format `docs/backlog/README.md` specifies, ready for
  `backlog-drain`.

- [ ] **Step 1: Determine the next artifact number**

```bash
ls docs/backlog/*.md | sed 's|.*/||' | grep -E '^[0-9]{3}-' | sort | tail -1
```

Take the highest `NNN` prefix and continue from the next integer, zero-padded to
three digits.

- [ ] **Step 2: Write one artifact per finding**

Each follows `docs/backlog/README.md` exactly. Example, for the strongest lead:

```markdown
---
status: pending
risk: medium
area: playerbots/battlegrounds
depends-on:
---

# Flag-carrier triggers are commented out, so nobody chases or defends a carrier

**Problem:** `BattlegroundStrategy::InitNonCombatTriggers` registers no reaction to
a flag carrier. Three triggers are commented out at `BattlegroundStrategy.cpp:44-51`:
`enemy flagcarrier near → attack enemy flag carrier` (relevance 80),
`team flagcarrier near → bg protect fc` (40), and
`player has flag → bg move to objective` (90). With no carrier reaction, a WSG match
has no mechanism to contest a flag, which is consistent with matches running the
full 20-minute cap and ending 0-0 — the cap itself (`BattleGround.cpp:317-323`) was
added to this server because of that behaviour.

**Suspected cause / area:**
`src/modules/PlayerBots/playerbot/strategy/generic/BattlegroundStrategy.cpp:44-51`.
The actions they name (`attack enemy flag carrier`, `bg protect fc`) still exist —
`BGTactics::protectFC` is declared at `BattleGroundTactics.h:74` — so this is a
disabled switch rather than a reference to deleted code. Why it was disabled is not
recorded in the file or in git history; that is worth establishing before
re-enabling, since a relevance of 80 outranks almost everything else in the table
and may have starved other actions.

**Acceptance criteria:**
- The three triggers are either re-enabled with justified relevance values, or a
  comment states why they must stay off.
- If re-enabled: a WSG match run through `scripts/tournament/match-run.sh` shows at
  least one flag pickup in `bg.log`, and `telemetry-report.sh` shows both factions'
  bots converging on the same coordinates at some point in the match.
- No regression in queueing: 20/20 bots still queue and enter, per the entry report.

**Notes:** Verification needs a running stack and a full 20-minute match, so budget
~25 minutes per attempt. Telemetry must be on
(`Tournament.TelemetryIntervalMs = 5000` in `mangosd.conf`, then restart mangosd).
Relevance interacts globally — raising one action starves others, so check the
movement report for new stuck bots, not just for flag activity.
```

Write one such artifact per **actionable** finding. A finding that is interesting
but not actionable stays in `BG-AI-ANALYSIS.md` and gets no artifact — the backlog
is work, not a notebook.

- [ ] **Step 3: Cross-link the analysis and the artifacts**

In `BG-AI-ANALYSIS.md` §4, make every recommendation name its artifact path, and in
each artifact's **Notes**, name `docs/playerbots/BG-AI-ANALYSIS.md` as the source.
An artifact whose reasoning lives only in a doc nobody links is an artifact whose
implementer will re-derive it wrongly.

- [ ] **Step 4: Verify the artifacts are well formed**

```bash
for f in docs/backlog/*.md; do
  head -6 "$f" | grep -q "^status:" || echo "MISSING status: $f"
  head -6 "$f" | grep -q "^area:"   || echo "MISSING area: $f"
done
```

Expected: no output. `README.md` has no frontmatter and will be reported — confirm
that is the only exception, or exclude it.

- [ ] **Step 5: Commit**

```bash
git add docs/backlog docs/playerbots/BG-AI-ANALYSIS.md
git commit -m "docs(backlog): scope the battleground AI findings as artifacts"
```

---

## Done when

- `docs/playerbots/BG-AI-ANALYSIS.md` exists with all four sections filled: a
  complete strategy/trigger table, `BGTactics::Execute`'s branch order, a findings
  table where every row carries a `file:line` and a classification, and a
  measurements section with real numbers from a real match.
- The commented-out flag-carrier triggers are either confirmed as the cause of 0-0
  draws with supporting telemetry, or explicitly refuted with the measurement that
  refuted them.
- One `docs/backlog/NNN-*.md` artifact exists per actionable finding, each with
  checkable acceptance criteria.
- **No bot AI behaviour was changed by this plan.**
