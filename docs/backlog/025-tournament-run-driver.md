---
status: pending
risk: medium
area: tournament/bracket
depends-on: 023-bracket-and-run-state-libraries.md
---

# Nothing drives a whole bracket, and nothing resumes one

**Problem:** One match can be run, but a tournament is a loop over pairings with a
result recorded after each, and there is no such loop. The property that actually
matters is resume: **this host reboots itself overnight for Windows Update**, and
a driver that only writes state at the end turns a reboot into the loss of the
entire night's matches instead of one match.

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
- **A draw blocks the bracket, by design.** It eliminates nobody, the ladders go
  uneven, and the run stops — advancing a side the server did not declare would
  fabricate a result. The driver logs a warning naming the drawn pairing.
- `bash -n scripts/tournament/tournament-run.sh` exits 0.
- With a fabricated run directory — `state_init` for `wsg-open` with the four
  team ids as seeds, then `state_record_result <dir> 1 stormwind-sentinels
  orgrimmar-warsong ALLIANCE` — `state.json` shows one entry in `.results` and
  `survivors.H` no longer containing `orgrimmar-warsong`; and running
  `tournament-run.sh wsg-open --run-dir <that dir>` emits the
  `skipping stormwind-sentinels vs orgrimmar-warsong — already recorded` line
  before it attempts anything else.
- `docs/playerbots/TOURNAMENT-RUNNING.md` exists and covers: how to start and
  resume a run; why the structure is two mirrored ladders (`Unit.cpp:5189`); that
  draws block the bracket and how to replay or decide one by hand; that only the
  two playing teams are ever logged in, so concurrent population stays at 20
  regardless of bracket size; and the run-directory artifact layout.

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
- **Verification needing a live stack (not part of these criteria):** a full
  `wsg-open` run — two round-1 matches then a final — ending in
  `TOURNAMENT-RUN bracket=wsg-open champion=<team-id> rounds=<n>`. Budget ~25
  minutes per match, so up to ~75 minutes. A `status=blocked
  reason=uneven_survivors` exit is the designed behaviour for a draw, and the fix
  is a human decision (replay or seed advance), not a code change — record which
  happened.
- `tournament-run.sh` does **not** manage the alive-world bot pool. That
  interaction is artifact 043.
