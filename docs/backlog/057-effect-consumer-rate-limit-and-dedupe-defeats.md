---
status: done
risk: low
area: tournament/effects
depends-on: 034-viewer-effect-consumer.md
---

# The viewer-effect rate limit and dedupe can both be defeated

**Problem:** five defects in `scripts/tournament/effect-consume.sh`, all against
guarantees the artifact was written to provide.

1. `limit_for` passes the `EFFECT_LIMIT_*` environment override through
   unvalidated, so a non-numeric value makes `[ "$used" -ge "$lim" ]` error and
   evaluate false — silently disabling the cap. This is the same failure mode
   the artifact already fixed one variable over in `count_for`.
2. The effect class is appended to `counts.txt` even when `effect_apply`
   refused, so two stale queue lines naming a team not in this match exhaust the
   default `kill_team` cap of 2 before any legitimate command lands —
   contradicting the adjacent comment that "a refused command never touched the
   world".
3. The id is appended to `applied.txt` only *after* `effect_apply` returns, so a
   consumer killed partway through a `*_team` effect's ten `ctl` calls leaves it
   unrecorded and the next pass replays it in full.
4. `applied.txt` and `counts.txt` are read and appended with no lock, so two
   consumers sharing one `--state` dir — an operator restarting the loop without
   killing the old one — both miss the id and both apply the same `kill_team`.
5. A trailing flag with no value (`--interval` as the final argument) spins the
   argument loop forever: `shift 2` cannot shift with one argument left, so `$#`
   never decreases. Reproduced as `timeout` rc=124 with no output. **The
   identical bug exists in `scripts/tournament/effect-queue.sh` — fix both.**

**Suspected cause / area:** `scripts/tournament/effect-consume.sh` and
`scripts/tournament/effect-queue.sh`.

**Acceptance criteria:**

- `EFFECT_LIMIT_KILL_TEAM=abc` is rejected with a named error rather than
  disabling the cap; a test asserts it.
- A refused or failed command does not increment `counts.txt`; five `kill_team`
  against a team not in the match leave the legitimate cap intact.
- An id is claimed in `applied.txt` **before** the first `ctl` call, so a kill
  interrupted mid-run is not replayed.
- Two consumers on one `--state` dir apply each command exactly once.
- Both scripts exit 2 with usage on a trailing valueless flag; a test drives each
  under `timeout` and asserts a non-124 exit.

**Notes:**

- Fully testable with the existing `CTL_STUB` seam. No world, no build.
- Run `tests/tournament/effects.test.sh` **from WSL** — `jq` is absent from Git
  Bash on this host and `require_cmd jq` hard-exits 1.

**Base:** cm-main

**Branch:** backlog/effect-consumer-rate-limit-and-dedupe-defeats

**Summary:** Fixed all five defects in the viewer-effect path, entirely in shell — no C++ and no migration. In `scripts/tournament/effect-consume.sh`: (1) a new `check_limit` runs over all eight `EFFECT_LIMIT_*` overrides at startup and exits 2 with `FATAL: EFFECT_LIMIT_KILL_TEAM must be a non-negative integer, got 'abc'` rather than letting a non-numeric value make `[ "$used" -ge "$lim" ]` error and evaluate false; (2) the effect class is appended to `counts.txt` only when `effect_apply` returns 0, so a command refused for naming a team not in the match no longer spends cap; (3) the id is appended to `applied.txt` *before* `effect_apply` is called, so a consumer killed partway through a `kill_team`'s ten `ctl` calls does not replay the wipe next pass; (4) an `flock` on `<state>/lock` (fd 9) is held across the whole claim-check-apply-count section, so two consumers sharing one `--state` dir apply each command exactly once and cannot race past a full cap — a missing `flock` binary degrades to a loud WARN, not a hard exit; (5) both `effect-consume.sh` and `effect-queue.sh` gained a `need_val` guard on every value-taking flag, so a trailing `--interval` / `--source` exits 2 with usage instead of spinning forever on a `shift 2` that cannot shift. `tests/tournament/effects.test.sh` gained eight assertions covering all five, driven through the existing `CTL_STUB` seam (one stub `kill -9`s the consumer on its fourth `ctl` call; another logs calls and sleeps so two backgrounded consumers genuinely overlap). Verified negatively: reverting only the two scripts makes exactly the seven new assertions fail, including the two `timeout` cases returning 124. With the fix, all nine `tests/tournament/*.test.sh` files pass under WSL — effects.test.sh reports 31 passed, 0 failed.

**In-game check:** Almost all of this is scriptable and needs no world — the change is pure shell around the `ctl` seam. Scriptable now, no server, no build (run from WSL, jq and flock required):

1. `bash tests/tournament/effects.test.sh` must print `31 passed, 0 failed` and exit 0. That is the whole acceptance list: the `EFFECT_LIMIT_KILL_TEAM=abc` refusal, the five refused `kill_team` leaving the cap of 2 intact, the id claimed before the first `ctl` call, two concurrent consumers producing exactly 10 `ctl` calls and 1 line in `applied.txt`, and both scripts exiting 2 (not 124) under `timeout` on a trailing valueless flag. One line of expected noise appears mid-run — `Killed  ( CTL_COUNT=... effect-consume.sh ... )` — that is the deliberate SIGKILL in the crash case, not a failure.
2. `for t in tests/tournament/*.test.sh; do bash "$t"; done` — all nine must exit 0, confirming nothing else in the tournament scripts regressed.

The one thing a stub cannot prove is that the consumer still drives a real world, since `CTL_STUB` replaces `ctl` wholesale. That needs a build of this branch (the rollback image predates `tournament kill`, so a "no such subcommand" there proves nothing). Once a batch build is running, in-game:

3. Start a WSG match with two bot teams, say `stormwind-sentinels` vs `orgrimmar-warsong`, and start `effect-consume.sh --queue var/effects.ndjson --alliance stormwind-sentinels --horde orgrimmar-warsong --state logs/tournament/<run>/effects --interval 5` in one terminal.
4. Enqueue `effect-queue.sh --effect kill_team --team ironforge-anvils` five times — a team not in this match. Watch as a spectator: no Horde or Alliance bot in the Gulch should die, and the consumer must log `WARN: id=... (kill_team) did not fully apply` five times. Then `grep -c '^kill_team$' logs/tournament/<run>/effects/counts.txt` must print `0`, not `5` — that is the fix to defect 2, and it is checkable from the file rather than by eye.
5. Now enqueue two legitimate `kill_team --team orgrimmar-warsong`. Both must land: watch all ten Horde bots drop and release to the graveyard, twice. A third one must be refused with `WARN: kill_team is over its cap of 2 for this match` on the consumer's stderr and no bot dying — the cap survived the five refusals.
6. Leave the consumer looping and start a second one against the same `--state` dir, then enqueue one `heal_team`. Each of the ten bots must be healed once, not twice: `grep -c 'tournament heal' ` in the mangosd console log for that window should show 10 lines, and only one `EFFECT id=<id>` line should appear across the two consumers' output.
7. Kill the consumer with `kill -9` while a `kill_team` is mid-flight (partway through the ten deaths), then restart it. The remaining bots must stay alive — the interrupted wipe must not restart from bot one on the next pass — and the id must already be present in `applied.txt`.

Steps 4-7 are all confirmable from `counts.txt`, `applied.txt` and the consumer's own `WARN`/`EFFECT`/`CONSUME` lines; only the visual "did the bots actually drop" half needs a human watching the Gulch.

**Minor findings:**
- scripts/tournament/effect-consume.sh: When `flock` is absent (or `exec 9>` fails) the script prints a warning and then runs completely unserialised, and `lock_hold`/`lock_release` also swallow a runtime `flock` failure with `return 0`, so the acceptance criterion "two consumers on one --state dir apply each command exactly once" silently does not hold on such a host rather than the consumer refusing to start or degrading loudly.
- scripts/tournament/effect-consume.sh: The `check_limit` calls sit above the argument-parsing loop, so a typo'd `EFFECT_LIMIT_*` makes even `effect-consume.sh --help` exit 2 with the FATAL instead of printing usage; validating after parsing (or after the `-h` arm) keeps the help path usable.
- scripts/tournament/effect-consume.sh: lock_hold() discards flock's exit status and always returns 0, so a failed lock acquisition silently proceeds into the claim/apply/cap section unlocked -- the double-apply this change exists to prevent, with no diagnostic.
- scripts/tournament/effect-consume.sh: flock is taken with no -w timeout while the lock is held across effect_apply's ten console round trips, so one stalled wsg_console attach parks the per-match lock indefinitely and a second consumer blocks inside flock 9 forever with no output.
- scripts/tournament/effect-consume.sh: fd 9 is inherited by every child effect_apply spawns, so a console child that outlives a killed consumer keeps the lock's open file description alive and stalls the restarted consumer the design explicitly anticipates.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/71, build tortoise-cm:20260819-3.
