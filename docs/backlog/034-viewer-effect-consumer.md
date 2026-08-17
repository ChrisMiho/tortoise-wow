---
status: pending
risk: medium
area: tournament/effects
depends-on: 033-viewer-effect-queue.md
---

# Nothing drains the effect queue, dedupes it, or limits it

**Problem:** The queue accepts commands but nothing applies them, and applying
them naively would be worse than not applying them at all. Two correctness
requirements, not niceties: **the queue is append-only and replayed after a
crash, and an adapter can deliver the same command twice** — an effect applied
twice is a viewer defrauded or a team wiped twice; and **`kill_team` is
match-deciding** — without a cap, one script hammering the queue ends every match
instantly.

**Suspected cause / area:** Implements
`docs/superpowers/plans/2026-08-16-06-viewer-effects.md` Task 5.

**Acceptance criteria:**

- `scripts/tournament/effect-consume.sh --queue <file> --alliance <team>
  --horde <team> --state <dir> [--once] [--interval <s>]` drains the queue,
  looping on the interval unless `--once`.
- **Dedupe by command id.** Every applied id is appended to `<state>/applied.txt`
  and any id already present is skipped. A second pass over the same queue applies
  nothing.
- Per-effect-class caps, each overridable from the environment
  (`EFFECT_LIMIT_KILL_TEAM`, `EFFECT_LIMIT_HEAL_PLAYER`, …). Defaults:
  `kill_team` 2, `kill_player` 20, `heal_team` 10, `heal_player` 50, each
  `upgrade_*_team` 2 and each `upgrade_*_player` 20.
- A rate-limited command is **recorded as applied** so it is not retried forever,
  and counted separately from a skipped duplicate.
- Each pass emits `CONSUME applied=<n> skipped=<n> ratelimited=<n>`.
- An unparseable queue line is warned about and skipped, never fatal.
- `bash tests/tournament/effects.test.sh` prints `23 passed, 0 failed` and
  exits 0. Added cases cover: a duplicate id applied exactly once with
  `skipped=1`; the id recorded once in `applied.txt`; a second pass applying
  nothing; `kill_team` capped to one under `EFFECT_LIMIT_KILL_TEAM=1`; and
  `ratelimited=2` reported for the rest.
- **The per-effect counter must return a single integer in every case**, including
  the case where the counts file exists but holds no matching line.

**Notes:**

- **This is the one place in the nine plans with a defect that will make the
  plan's own test fail as written.** The plan's counter is
  `count_for() { grep -c "^$1\$" "$STATE/counts.txt" 2>/dev/null || echo 0; }`.
  When the counts file exists but has no matching line, `grep -c` prints `0`
  **and** exits 1, so the `|| echo 0` fires too and the function returns the
  two-line string `0\n0`. The following `[ "$used" -ge "$lim" ]` then dies with
  `integer expression expected` and evaluates false, so **the rate limit never
  bites**. The plan's own `kill_team` case reaches exactly that state, because an
  earlier `heal_player` in the same test already created `counts.txt`. Fix the
  counter so it yields one integer whether the file is missing, empty, or present
  without a match — do not "fix" the test to match the bug.
- **Run the test from WSL** —
  `wsl -d Ubuntu -- bash -lc 'cd /mnt/c/<worktree path> && bash tests/tournament/effects.test.sh'`.
  `jq` is absent from Git Bash on this host.
- The tests inject a stub control plane through `CTL_STUB`, so no server is
  needed: the script sources `$CTL_STUB` when that variable is set, and
  `lib/ctl.sh` plus `wsg-bots-common.sh` otherwise. Keep that switch.
- This artifact extends `tests/tournament/effects.test.sh` (artifacts 031-033),
  which is why it stacks on 033. All 17 existing assertions must still pass.
- Never rewrite the queue file in place; the producer may be appending to it.
