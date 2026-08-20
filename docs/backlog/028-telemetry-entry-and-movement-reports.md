---
status: done
risk: low
area: tournament/telemetry
depends-on: 027-telemetry-extract.md
---

# A telemetry CSV is 4800 rows nobody can read

**Problem:** The extracted CSV holds every sample of every player, which answers
nothing on its own. The two questions worth asking of a bot match are: did every
bot actually get in, and did it actually go anywhere. **A bot whose position does
not change across the whole match is not playing, whatever the score says** — and
that is the single most likely explanation for the 0-0 draws this server hard-caps
matches at 20 minutes because of.

**Suspected cause / area:** Implements
`docs/superpowers/plans/2026-08-16-05-bg-telemetry.md` Task 3.

**Acceptance criteria:**

- `scripts/tournament/telemetry-report.sh <csv> [--expected 20]` emits, in order:
  - `ENTRY player=<name> team=<n> firstSeen=<t> samples=<n>` per player;
  - `MOVEMENT player=<name> distance=<f> maxStep=<f> idleSamples=<n> stuck=<0|1>`
    per player;
  - `REPORT players=<n> expected=<n> entered=<n> stuck=<n>`.
- `stuck=1` means total travelled distance across the whole match is under 10
  yards. Warsong Gulch is roughly 900 yards end to end, so that is not "played
  cautiously" — it is a bot that never left its spawn. The threshold is a named
  constant with that reasoning in a comment.
- Exit 1 if fewer than `--expected` players entered **or** any bot is flagged
  stuck, so it works as a gate; exit 0 otherwise.
- Player order in the output is stable (first-seen order), not hash order.
- `bash tests/tournament/telemetry.test.sh` prints `12 passed, 0 failed` and
  exits 0. The added cases use a synthesised CSV with one player that moves every
  sample and one whose coordinates are identical throughout, and assert that only
  the second is flagged.

**Notes:**

- **Run the test from WSL** —
  `wsl -d Ubuntu -- bash -lc 'cd /mnt/c/<worktree path> && bash tests/tournament/telemetry.test.sh'`.
  `jq` is absent from Git Bash on this host.
- This artifact extends `tests/tournament/telemetry.test.sh`, which artifact 027
  creates — that is why it depends on it. The existing six assertions must still
  pass.
- `idleSamples` and `stuck` are different signals and the report must keep them
  distinguishable: a high `idleSamples` with a healthy `distance` is a bot that
  moved and then held position — flag carriers and defenders look like that — and
  is not alarming.
- **Verification needing a live stack (not part of these criteria):** run
  `telemetry-extract.sh` then this report against a real match, expecting 20
  `ENTRY` lines and `REPORT ... entered=20 stuck=0`. **A non-zero `stuck` count or
  an `entered` below 20 is the finding this whole plan exists to produce** —
  record the exact output; it feeds directly into artifacts 036-037.

**Base:** backlog/telemetry-extract

**Branch:** backlog/telemetry-entry-and-movement-reports

**Summary:** Added `scripts/tournament/telemetry-report.sh`, which turns the per-match CSV that `telemetry-extract.sh` produces into three shapes a human or a gate can act on: one `ENTRY player=<name> team=<n> firstSeen=<t> samples=<n>` line per player, then one `MOVEMENT player=<name> distance=<f> maxStep=<f> idleSamples=<n> stuck=<0|1>` line per player, then a single `REPORT players=<n> expected=<n> entered=<n> stuck=<n>`. `stuck=1` is total travelled distance under the named constant `STUCK_TOTAL_DISTANCE=10` yards, commented with the reasoning (Warsong Gulch is ~900 yards end to end, so 10 yards of total travel is a bot that never left its spawn, not a cautious one) — total travel rather than start-to-end displacement, so a bot that walked out and came back still reads as having played. `idleSamples` is kept as a separate signal behind its own `IDLE_STEP_EPSILON=0.01` constant, because a high idle count with a healthy distance is a flag carrier or defender holding position and must not be confused with stuck. Player order comes from an explicit first-seen index array, never awk's `for (k in a)` hash order, so two reports are diffable. Exit 1 when fewer than `--expected` (default 20) entered or any bot is flagged stuck; exit 2 for a CSV that is missing, unreadable, or bad arguments — the same "could not measure" vs "measured and found a problem" tri-state `telemetry-extract.sh` and `gear-audit.sh` draw; exit 0 otherwise. The parser skips line 1 only when it actually is the header (a body-only CSV keeps its first sample), and warns to stderr rather than silently dropping torn rows or non-numeric coordinates, which would otherwise manufacture a thousand-yard step out of nothing. Six new cases were appended to `tests/tournament/telemetry.test.sh` against a synthesised CSV with a bot whose coordinates are identical throughout, a bot that travels 50 yards then holds position for two samples, and a late joiner that sorts first alphabetically but last by first sighting — the suite prints `12 passed, 0 failed` and exits 0 under both gawk and mawk. No C++, config, or SQL changes; nothing needed the live stack.

**In-game check:** This change is a shell script only — no server code, config, or SQL — so the C++ smoke test ("world comes up, bots spawn") is not what confirms it. What confirms it is running the report against a real match's telemetry. Fully scriptable end to end; no human needs to be in the client for any step.

Scriptable, no client needed:

1. Unit gate, runnable right now with no server at all, from WSL:
   `wsl -d Ubuntu -- bash -lc 'cd /mnt/c/<checkout> && bash tests/tournament/telemetry.test.sh'`
   Expect the last line `12 passed, 0 failed` and exit 0. (Confirmed already on this branch under both gawk and mawk.)

2. Confirm the sampler is actually on before blaming the report. In the bind-mounted `~/tortoise-wow-server-V2/etc/mangosd.conf`, `Tournament.TelemetryIntervalMs` must be non-zero (5000 is the plan's value) and `docker restart tcm-mangosd` must have happened since it was set — the conf is read only at startup. Check: `grep -a -c "TELEMETRY tick" ~/tortoise-wow-server-V2/logs/bg.log` returns a non-zero count. A zero here means step 3 will exit 1 from `telemetry-extract.sh`, not from anything in this artifact.

3. Run a full 20-bot Warsong Gulch match (`scripts/tournament/match-run.sh`), note the battleground instance id from `bg.log`, then:
   `./scripts/tournament/telemetry-extract.sh --instance <id> --out /tmp/m.csv`
   `./scripts/tournament/telemetry-report.sh /tmp/m.csv; echo "rc=$?"`
   The pass shape is exactly 20 `ENTRY` lines, 20 `MOVEMENT` lines, a final `REPORT players=20 expected=20 entered=20 stuck=0`, and `rc=0`.

4. Sanity-check the numbers against the map rather than just the exit code: a bot that actually played a WSG match should show `distance` in the hundreds or low thousands of yards and a `maxStep` of a few tens (one sampling interval of running), not a `maxStep` in the hundreds — a huge `maxStep` is a teleport or a torn log, not movement.

Deliberately not a failure of this change, and the thing worth recording rather than fixing: `rc=1` with a non-zero `stuck` count, or `entered` below 20. That is the finding the whole telemetry plan exists to produce — bots that queue in, load into the instance, and then stand on their graveyard for twenty minutes while the scoreboard reads 0-0. Capture the exact `REPORT` line and the `MOVEMENT` lines of the flagged players verbatim; it feeds artifacts 036-037. Distinguish it from `rc=2`, which means the report never ran (no CSV, unreadable path) and says nothing about the match.

Optional human confirmation, only if a flagged bot needs eyeballing: log in as a GM during a live match, `.go name <flagged bot name>`, and check whether that bot is standing motionless in the Silverwing Hold / Warsong Lumber Mill starting area. That corroborates a `stuck=1` row but is not needed to accept this change.

**Minor findings:** none reported by the review lenses.

**Drain note (VERIFIED END-TO-END AGAINST A REAL MATCH — not a synthetic fixture):** on 2026-08-18 the drain ran this artifact's telemetry-report.sh together with 027's telemetry-extract.sh against the genuine bg.log produced by batch 20260818-2's own validate match (image tortoise-cm:20260818-2, instance=101, map=489, Tournament.TelemetryIntervalMs = 5000). Both scripts were taken verbatim from their branches. Results:

- telemetry-extract.sh: `TELEMETRY-EXTRACT instance=101 samples=4280 out=real.csv`, rc=0, header exactly `t,player,team,x,y,z,hp,maxhp,alive,combat`, 4280 rows, 20 distinct players.
- telemetry-report.sh: 20 ENTRY lines and 20 MOVEMENT lines in stable first-seen order, then `REPORT players=20 expected=20 entered=20 stuck=20`, rc=1.
- Every one of the 20 MOVEMENT lines reads `distance=0.0 maxStep=0.0 idleSamples=213 stuck=1`.

So the entry half and the movement half both behave as specified on real data, and the tri-state exit is right: rc=1 here is "measured and found a problem", which this artifact's own in-game check names as the finding the telemetry plan exists to produce rather than a failure of the script. The stuck=1 verdict is not a threshold judgement call in this case — travelled distance is exactly 0.0, far below the STUCK_TOTAL_DISTANCE=10 constant, so no reasonable threshold would disagree.

This independently reproduces the measurement recorded on artifact 026 from the same match, by a completely separate code path (the shipped scripts rather than an ad-hoc awk pass). The first CSV row also shows `125,Wsgaeight,469,1519.53,1481.87,352.02,1,2093,0,0` — hp=1 of maxhp=2093 and alive=0 at first sighting, corroborating 026's finding that three bots were dead from the very first sample and never released.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/41, build tortoise-cm:20260818-3.
