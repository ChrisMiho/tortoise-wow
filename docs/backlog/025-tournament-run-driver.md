---
status: done
risk: medium
area: tournament/bracket
depends-on: 023-bracket-and-run-state-libraries.md
---

# Nothing drives a whole bracket, and nothing resumes one

**Problem:** One match can be run, but a tournament is a loop over pairings with a
result recorded after each, and there is no such loop. The property that actually
matters is resume: **a multi-hour run will eventually be interrupted** — a crash, a
power cut, a stuck match, an operator stopping it — and a driver that only writes
state at the end turns any of those into the loss of the entire night's matches
instead of one match.

**Suspected cause / area:** Implements
`docs/superpowers/plans/2026-08-16-04-bracket-engine.md` Task 4 and Task 5 Step 5.

**Acceptance criteria:**

- `scripts/tournament/tournament-run.sh <bracket-id> [--run-dir <dir>]` validates
  the bracket, initialises (or resumes) run state, and loops rounds until a
  champion, a block, or a failure.
- **State is written the moment a result is known, before the next match starts.**
  That is the line that makes a reboot cost one match instead of the run.
- **Resume is by pairing, not by index**, so a half-finished round resumes
  correctly: an already-recorded `<alliance> vs <horde>` prints a
  `skipping … — already recorded` line and is not replayed.
- Terminal lines, teed into `<run-dir>/tournament.log`:
  - `TOURNAMENT-RUN bracket=<id> champion=<team-id> rounds=<n>` on completion;
  - `TOURNAMENT-RUN bracket=<id> status=blocked reason=uneven_survivors(A=<n>,H=<n>)`
    when the survivor lists go uneven;
  - `TOURNAMENT-RUN bracket=<id> status=blocked reason=exceeded_expected_rounds`;
  - `TOURNAMENT-RUN bracket=<id> status=failed reason=no_result(<a> vs <h>)` when
    `match-run.sh` returns no `winner=`.
- **A draw is broken by tiebreak, not by blocking**, so a 0-0 match cannot end an
  unattended run. This is not a hypothetical: of the 37 matches recorded in
  `bg.log` as of 2026-08-16, **15 were draws — 41%** (the other 22 split 16
  Alliance / 6 Horde). A blocking driver would stall roughly two rounds in five. On `winner=NONE` the driver walks this ladder in order and
  stops at the first rung that separates the teams:
  1. **Higher score** — `allianceScore` / `hordeScore` from the `MATCH` line. In
     WSG the score *is* flag captures, so this rung is "who capped more". Skip it
     when either reads `-1` (no score could be read) or the two are equal.
  2. **Fewer deaths** — counted from `<match run-dir>/telemetry.csv` as `alive`
     transitions from `1` to `0`, summed per team. Skip this rung entirely when
     the CSV is absent or empty, which is the normal state with
     `Tournament.TelemetryIntervalMs = 0`.
  3. **Higher seed** — the earlier team in its ladder, from
     `bracket_ladder`. This rung always separates, so the ladder always
     terminates.
- Each tiebreak is recorded with the rung that decided it —
  `state_record_result ... <winner> tiebreak_score|tiebreak_deaths|tiebreak_seed`
  — and logged at the time, naming the pairing, the rung, and the numbers that
  decided it. **A decided match must never be recorded as if the server declared
  it.**
- The run's final report states how many matches were decided by tiebreak rather
  than won outright; a champion crowned entirely on tiebreaks is a legitimate
  outcome but not the same as one that won its matches, and the output says
  which.
- `status=blocked reason=uneven_survivors` remains reachable — a match that
  produced no `MATCH` line at all still fails rather than being tiebroken.
- `bash -n scripts/tournament/tournament-run.sh` exits 0.
- With a fabricated run directory — `state_init` for `wsg-open` with the four
  team ids as seeds, then `state_record_result <dir> 1 stormwind-sentinels
  orgrimmar-warsong ALLIANCE` — `state.json` shows one entry in `.results` and
  `survivors.H` no longer containing `orgrimmar-warsong`; and running
  `tournament-run.sh wsg-open --run-dir <that dir>` emits the
  `skipping stormwind-sentinels vs orgrimmar-warsong — already recorded` line
  before it attempts anything else.
- `docs/playerbots/TOURNAMENT-RUNNING.md` exists and covers: how to start and
  resume a run; why the structure is two mirrored ladders (`Unit.cpp:5189`); the
  tiebreak ladder and, plainly, that a tiebroken match is a decision rather than
  a result and where to read `decidedBy` to tell them apart; that **only the 20
  bots playing the current match are online — every other team is logged out and
  the alive-world random pool is off**; and the run-directory artifact layout.

**Notes:**

- **Run the resume check from WSL** —
  `wsl -d Ubuntu -- bash -lc 'cd /mnt/c/<worktree path> && bash -c ". scripts/tournament/lib/state.sh; …"'`.
  `jq` is absent from Git Bash on this host.
- The resume check is deliberately done against **fabricated state**, not by
  killing a real 20-minute match. It stops as soon as the driver reaches the
  second (unplayed) pairing and tries to invoke `match-run.sh`, which will fail
  without a server — that is expected, and the assertion is on the `skipping`
  line, not on the driver's exit code.
- `scripts/tournament/match-run.sh` comes from artifact 024 and is **not** in this
  branch's dependency chain. Its contract: `match-run.sh <allianceTeam>
  <hordeTeam> --run-dir <dir>`, last line
  `MATCH alliance=… horde=… winner=<ALLIANCE|HORDE|NONE> instance=… duration=…`.
  Write against that; do not try to execute a real match here.
- **Live validation checklist.** There is no unit test for this script by
  decision — it is validated by running a real bracket. Budget ~25 minutes per
  match, up to ~75 for `wsg-open`. The thing being proved is that **a second
  match starts, with the next pairing's rosters, after the first one finishes** —
  everything else the driver does is bookkeeping around that. Run in order:
  1. `./scripts/tournament/tournament-run.sh wsg-open --run-dir
     logs/tournament/first`
  2. After the first `MATCH` line, confirm the **roster swap actually happened**
     — the first pairing offline and the second pairing online:
     `SELECT name, online FROM tw_char.characters WHERE name LIKE 'Wsg%' AND
     online = 1 ORDER BY name;`
     This is the single most important observation in the run. A second match
     that starts with the *first* pairing still logged in means `match-run.sh`'s
     logout step silently failed, and the bracket is playing the wrong teams.
  3. A second `MATCH` line appears, naming the second pairing.
  4. `state.json` holds two results with the right teams, winners, and
     `decidedBy` values — `jq '.results' <run-dir>/state.json`.
  5. **Prove resume against the real run**: interrupt it mid-bracket, then
     re-invoke with the same `--run-dir`. It must log
     `skipping <a> vs <h> — already recorded` for every completed pairing and
     pick up at the first unplayed one, not replay from the top.
  6. Ends with `TOURNAMENT-RUN bracket=wsg-open champion=<team-id> rounds=<n>`.
- Record how many matches were decided by tiebreak and at which rung. If most of
  the bracket settles on `tiebreak_seed`, the bots are not scoring at all — that
  is a finding for `docs/playerbots/BG-AI-ANALYSIS.md`, not a tournament that
  worked. Given 15 of 37 recorded matches were draws, expect at least one.
- `tournament-run.sh` does **not** manage the alive-world bot pool. That
  interaction is artifact 043.
