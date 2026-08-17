---
status: pending
risk: medium
area: tournament/effects
depends-on: 029-bot-log-capture-and-match-artifacts.md
---

# The effect consumer is never started, and could outlive its match

**Problem:** `effect-consume.sh` exists but nothing runs it, so a queued viewer
effect never reaches the game. The naive fix is worse than the gap: a consumer
started alongside a match and left running would keep draining after the teams log
out, and its next effect would land on the **following** match's bots.

**Suspected cause / area:** Implements
`docs/superpowers/plans/2026-08-16-06-viewer-effects.md` Task 6.

**Acceptance criteria:**

- `scripts/tournament/match-run.sh` starts the consumer immediately after
  `tournament start`, pointed at `${EFFECT_QUEUE:-<run-dir>/effects.ndjson}` with
  `--alliance`/`--horde` set to the two playing teams and `--state
  <run-dir>/effects`, logging to `<run-dir>/effects.log`.
- **The consumer is stopped as soon as the monitor loop breaks**, before the
  rosters log out — and an `EXIT` trap kills it too, so an early exit or a
  failure anywhere in the match cannot leave it running.
- The queue file is created if absent, so a match with no viewer activity behaves
  identically to one with it.
- The consumer's lifetime is logged (start with its pid, and stop).
- `bash -n scripts/tournament/match-run.sh` exits 0, and the existing match
  sequence — roster swap, gear gate, assemble, start, monitor, telemetry/capture,
  logout, `MATCH` line — is unchanged apart from these two insertions.
- `docs/playerbots/TOURNAMENT-VIEWER-EFFECTS.md` exists and covers: the eight
  effects with their default caps and why caps exist; the NDJSON queue shape with
  `id` named as the dedupe key; that `effect-queue.sh` is the **mock** adapter and
  a real listener replaces only that script; and the four safety properties —
  effects refuse a bot not in a battleground, a team not in the current match is
  rejected, upgrades move exactly one tier and no-op at the top, and the consumer
  never crosses into the next match.

**Notes:**

- This artifact edits `scripts/tournament/match-run.sh` **after** artifact 029's
  telemetry and bot-log-capture insertions, which is why it stacks on 029 rather
  than on 024 — cutting from 024 would drop 029's edits on merge.
- `scripts/tournament/effect-consume.sh` comes from artifact 034 and is **not** in
  this branch's chain. Its contract:
  `effect-consume.sh --queue <f> --alliance <t> --horde <t> --state <dir>
  [--once] [--interval <s>]`, emitting `CONSUME applied=… skipped=…
  ratelimited=…` per pass. Write against that; do not execute it here.
- **Run syntax checks from WSL** — `jq` is absent from Git Bash on this host.
- Take care that the `EXIT` trap does not clobber a trap the script already
  installs, and that killing a consumer that has already exited is not treated as
  an error.
- **Verification needing a live stack (not part of these criteria):** with a match
  live, enqueue a `kill_player` against one slot and, ten seconds later, a
  `heal_team`. `<run-dir>/effects.log` should show
  `EFFECT id=… effect=kill_player … applied=1 failed=0` then
  `effect=heal_team … applied=10`. Cross-check the kill in the telemetry CSV:
  `alive` should read `0` for that bot at the matching `t`.
