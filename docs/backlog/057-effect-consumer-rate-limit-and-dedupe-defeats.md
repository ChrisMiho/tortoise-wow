---
status: pending
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
