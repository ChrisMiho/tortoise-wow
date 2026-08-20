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

**Base:** cm-main

**Branch:** backlog/tournament-run-driver

**Summary:** Added `scripts/tournament/tournament-run.sh` (commit bba4e15 on `backlog/tournament-run-driver`, cut from `origin/cm-main`), the loop that drives a whole bracket, plus `docs/playerbots/TOURNAMENT-RUNNING.md`. The driver validates the bracket, initialises or resumes run state, and loops rounds until a champion, a block, or a failure, calling `match-run.sh` once per pairing and writing each result to `state.json` the moment it is known and before the next match starts. Resume is by pairing, not index — and getting that right required a fix the plan's sketch did not have: half way through a round some of that round's losers are already eliminated, so pairing off the live survivor list yields unequal lists and stops a merely half-finished run with `uneven_survivors`. A new `round_survivors` helper puts the current round's losers back by filtering the ladder (preserving seed order), so an already-recorded pairing prints `skipping <a> vs <h> — already recorded` and the run picks up at the first unplayed one. Draws are decided rather than blocking: on `winner=NONE` the driver walks higher score (skipped on `-1` or a tie) → fewer deaths (counted as `alive` 1→0 transitions per team from the match's `telemetry.csv`, skipped when absent/empty) → higher seed from `bracket_ladder`, with the round-one equal-index case resolved for the Alliance seed so the ladder always terminates. Each rung logs the pairing, the rung and the deciding numbers, and the match is recorded with `decidedBy=tiebreak_score|tiebreak_deaths|tiebreak_seed` — never `server`. New `TOURNAMENT-REPORT` lines count outright wins versus tiebreaks for the run and for the champion, adding `note=champion_won_no_match_outright` when the champion won nothing outright. `no_result` (no `MATCH` line at all) still fails, `uneven_survivors` stays reachable, and the expected-rounds guard is `bracket_rounds + 1` because the two ladders' last survivors still have to play each other — without that the round counter never advanced past 1 and `exceeded_expected_rounds` was unreachable.

**In-game check:** Run the whole thing from WSL against a live stack (`jq` is absent from Git Bash). Budget ~25 min per match, ~75 min for `wsg-open`.

PRECONDITION (scriptable, and the run refuses without it). Turn the alive-world random bot pool off in `aiplayerbot.conf` and restart mangosd first — `tournament-run.sh` will not do it mid-run. Confirm with `SELECT COUNT(*) FROM tw_char.characters WHERE online = 1;` reading 0 (1 is tolerated for a GM). If a stray pool is up, `match-run.sh`'s population gate aborts the first match with the character names listed in `match.log`.

1. `./scripts/tournament/tournament-run.sh wsg-open --run-dir logs/tournament/first`

2. THE SINGLE MOST IMPORTANT OBSERVATION — the roster swap. Right after the first `MATCH …` line appears in `logs/tournament/first/tournament.log`, run `SELECT name, online FROM tw_char.characters WHERE name LIKE 'Wsg%' AND online = 1 ORDER BY name;`. It must list the SECOND pairing's 20 bots and NONE of the first pairing's. If the first pairing is still logged in, `match-run.sh`'s logout step silently failed and the bracket is playing the wrong teams. Fully scriptable — a script can poll `tournament.log` for the `MATCH` line and then run that query.

3. HUMAN EYES REQUIRED, once, during the first match. Log in a GM and spectate the Warsong Gulch instance (`.go` to WSG / `tournament members <inst>` for the instance id). Confirm twenty bots are in the battleground and actually fighting each other — not standing in a tunnel ignoring one another, which is what a same-faction pairing looks like and which produces no error anywhere. Nothing in the logs distinguishes "20 bots fighting" from "20 bots idling"; this is the part a log line cannot cover.

4. A second `MATCH …` line appears naming the SECOND pairing (scriptable: grep `tournament.log` for `^\[.*\] MATCH ` / the driver's `match-run.sh exit=` lines).

5. `jq '.results' logs/tournament/first/state.json` holds two entries with the right teams, winners, and `decidedBy` values (scriptable).

6. RESUME AGAINST THE REAL RUN. Interrupt mid-bracket (Ctrl-C, or stop mangosd), then re-invoke with the same `--run-dir`. It must log `skipping <a> vs <h> — already recorded` for every completed pairing and start at the first unplayed one, not replay from the top (scriptable: assert the `skipping` count equals the `.results` length).

7. It ends with `TOURNAMENT-REPORT bracket=wsg-open matches=… outright=… tiebreak=… tiebreak_score=… tiebreak_deaths=… tiebreak_seed=…`, a `champion=` report line, and `TOURNAMENT-RUN bracket=wsg-open champion=<team-id> rounds=<n>`, exit 0 (all scriptable).

8. RECORD THE TIEBREAKS. `grep 'tiebreak ' logs/tournament/first/tournament.log` and note how many matches were decided and at which rung — given 15 of 37 recorded matches were draws, expect at least one. If most of the bracket settles on `tiebreak_seed`, the bots are not scoring at all: that is a finding for `docs/playerbots/BG-AI-ANALYSIS.md`, not a tournament that worked (scriptable).

TWO NON-FAILURES to expect. `status=blocked reason=uneven_survivors(A=2,H=0)` when both round-one matches go to the same faction is the bracket's designed shape (two alliance survivors have no horde opponent), not a bug in this change — Alliance took 16 of the 22 decided matches on record, so it is likely. And `status=failed reason=no_result(...)` means the match never ran; the cause is in that match's `match.log`/`roster.log`, not in the driver.

**Minor findings:**
- scripts/tournament/tournament-run.sh: The seed rung resolves an equal-index tie to ALLIANCE unconditionally, so a round in which every match is a draw (41% of matches are draws, and round 1 pairs seed n against seed n) awards every match to Alliance and the run stops with `status=blocked reason=uneven_survivors` — verified by running the driver with an all-draw stub, which blocked at round 2 with A=2,H=0, exactly the unattended stall the tiebreak ladder exists to prevent; alternating the tie direction by pairing index would keep the ladders even.
- scripts/tournament/tournament-run.sh: `already_played` returns 1 both when the pairing has no result and when the jq read of state.json fails (`n="$(jq ...)" || return 1`), so a transient or corrupt state read is indistinguishable from "not yet played" and silently replays an already-completed 20-minute match instead of failing the run.
- scripts/tournament/tournament-run.sh: On resume the driver replays an interrupted pairing into the identical `mdir="$RUN_DIR/r${round}-${ateam}-vs-${hteam}"`, and neither `match-run.sh` nor the telemetry sampler truncates that directory, so `tb_deaths` awk-scans a `telemetry.csv` that concatenates the abandoned attempt with the real one — `prev[player]` carries across the boundary and counts an alive→dead transition between two different matches — deciding `tiebreak_deaths` on a match that was thrown away.
- scripts/tournament/tournament-run.sh: `match-run.sh` is invoked inside `while IFS='|' read -r ateam hteam; ... done <<< "$pairings"`, so it inherits the here-string as stdin; any command in that ~25-minute script that reads stdin would swallow the remaining pairings and the round would silently end early, with no error — redirect the call `< /dev/null`.

**Drain note:** Treat the FIRST minor finding above as a must-fix for this PR, not a nit — it defeats this artifact's headline acceptance criterion ("a draw is broken by tiebreak, not by blocking, so a 0-0 match cannot end an unattended run"). Verified against the branch on 2026-08-18: scripts/tournament/tournament-run.sh:280 reads `if [ "$ai" -le "$hi" ]; then TB_WINNER="ALLIANCE"`, so an equal-index tie always goes to Alliance, and the file's own comment at :276-277 concedes round one pairs seed n against seed n so that is the common case. Rung 1 is skipped on a 0-0 draw and rung 2 is skipped whenever telemetry.csv is absent, which line :271 documents as the normal state with Tournament.TelemetryIntervalMs = 0. So an all-draw round one — 41% of matches are draws — sends every match to Alliance and the run halts at round 2 with status=blocked reason=uneven_survivors, which is precisely the unattended 3am stall the tiebreak ladder was written to prevent. Alternating the tie direction by pairing index keeps the ladders even and is the fix the finding names.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/36, build tortoise-cm:20260818-1.
