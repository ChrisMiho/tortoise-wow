---
status: done
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

**Base:** backlog/bot-log-capture-and-match-artifacts

**Branch:** backlog/run-effect-consumer-during-a-match

**Summary:** Two insertions into `scripts/tournament/match-run.sh` plus one new doc. A new section 5b, immediately after the `tournament start` call, creates the queue file if absent (`${EFFECT_QUEUE:-$RUN_DIR/effects.ndjson}`, via `mkdir -p` + `: >>`) and launches `effect-consume.sh --queue <q> --alliance $ATEAM --horde $HTEAM --state $RUN_DIR/effects --interval 5` in the background with output to `$RUN_DIR/effects.log`, logging the pid. It defines an idempotent `effect_consumer_stop()` that kills and waits on the pid, logs the stop, and clears the pid — so a second call, or a consumer that already exited, is a silent no-op — and installs `trap 'effect_consumer_stop' EXIT` (the script had no prior trap; a comment says so and warns that a later EXIT trap would replace rather than chain). The second insertion is a bare `effect_consumer_stop` as the first statement after the monitor loop's `done`, ahead of the artifact collection and well ahead of section 7's roster logout, so the consumer cannot survive into the next match. A guard skips the launch when `effect-consume.sh` is not present (it ships from artifact 034, outside this branch's chain), matching the file's existing non-fatal idiom for `telemetry-extract.sh`. The diff is a pure insertion: 53 added lines, zero deletions, so the roster swap, gear gate, assemble, start, monitor, telemetry/capture, logout and `MATCH` line are byte-identical. `docs/playerbots/TOURNAMENT-VIEWER-EFFECTS.md` documents the eight effects with their default caps and why caps exist (`kill_team` decides a match), the NDJSON queue shape with `id` named as the dedupe key, `effect-queue.sh` as the mock adapter a real Twitch/TikTok listener replaces alone, and the four safety properties. Verified: `bash -n scripts/tournament/match-run.sh` exits 0 under WSL, and the 5b block was lifted verbatim out of the file by `sed` and run against a stub consumer — correct argv, queue file created, process alive during the match, dead after `effect_consumer_stop`, dead after an early `exit 1` that only the EXIT trap covers, a reaped pid not treated as an error, and a missing `effect-consume.sh` logged rather than fatal.

**In-game check:** This change is shell-only — no C++, no SQL, no server behaviour of its own — so the generic "server starts, bots spawn" smoke test covers nothing relevant. What has to be confirmed is the consumer's lifetime around a real match. Note the whole check requires `scripts/tournament/effect-consume.sh` (artifact 034) to be present in the merged tree; without it `match-run.sh` logs "effect-consume.sh is not present" and there is nothing to observe.

Scriptable, no human eyes needed (a later batch step can run all of this):

1. Run one match: `./scripts/tournament/match-run.sh stormwind-sentinels orgrimmar-warsong --run-dir logs/tournament/effect-smoke` from WSL.
2. While it is live, in a second WSL shell, note the pid from `logs/tournament/effect-smoke/match.log`'s `effect consumer started (pid N)` line and confirm `ps -p N` shows `effect-consume.sh` running. Confirm `logs/tournament/effect-smoke/effects.ndjson` exists even though nothing has been queued.
3. Still live, enqueue two effects against the Horde team:
   `./scripts/tournament/effect-queue.sh --queue logs/tournament/effect-smoke/effects.ndjson --effect kill_player --team orgrimmar-warsong --slot five`, then after 10 s the same with `--effect heal_team --team orgrimmar-warsong`.
4. `grep EFFECT logs/tournament/effect-smoke/effects.log` must show `effect=kill_player … applied=1 failed=0` then `effect=heal_team … applied=10 failed=0`. Absence of `error=not_in_battleground` in that log is the specific negative signal.
5. After the `MATCH …` line is printed, `match.log` must contain `effect consumer stopped (pid N)` for that same N, and `ps -p N` must return nothing — this is the acceptance criterion that matters most. Confirm the stop line appears in `match.log` *above* the `roster.sh logout` chatter in `roster.log` by timestamp, i.e. the consumer died before the bots left the world.
6. Trap path, no live match needed: run `match-run.sh` with a bogus first argument (e.g. a team that does not validate) so `fatal` fires — actually reaching the trap needs a failure *after* the start, so instead run a real match and Ctrl-C it during the monitor loop, then `ps -p N` must return nothing. Any orphaned `effect-consume.sh` process still running after `match-run.sh` has exited is the failure this artifact exists to prevent.
7. The cross-match guarantee: run a second match with a different pairing (e.g. `ironforge-anvils` vs `orgrimmar-warsong`) while the first run's queue still holds unapplied lines. The second run's `effects.log` must not contain any `EFFECT id=` for an id from the first run's `applied.txt` — different run dir, different state dir, and a dead consumer.

Needs a human in the client only if step 4 is to be confirmed visually: spectate as a GM and watch the slot-five Horde bot drop dead and then the whole Horde team snap back to full health ten seconds later. Everything else above reads out of `match.log`, `effects.log`, `telemetry.csv` (`alive` should read `0` for that bot at the matching `t`) and `ps`.

**Minor findings:**
- scripts/tournament/match-run.sh: With `EFFECT_QUEUE` overridden to a queue shared across matches (the intended production shape once a real listener replaces the mock adapter), the per-run `--state "$RUN_DIR/effects"` dir means each match starts with an empty `applied.txt`, so every command a previous match already handled is re-drained at the next `tournament start` and re-fires against any team that happens to be playing again — the backward half of the "consumer never crosses into another match" property is unguarded (a queue offset or a shared state dir would close it).
- scripts/tournament/match-run.sh: The trap comment ("`fatal` exits, the deadline path exits") and the same claim in the doc's Safety section misdescribe the code: the deadline path `break`s out of the monitor loop and is handled by the explicit `effect_consumer_stop` call, and no `fatal` is reachable after `tournament start`, so the EXIT trap's only real job is signals/unexpected exits.
- scripts/tournament/match-run.sh: `effect_consumer_stop` kills only the consumer's own pid, not its process group, so a consumer sitting inside an in-flight `ctl`/`docker exec` dies while that child survives and delivers its effect seconds after "effect consumer stopped" has been logged — `wait` returns as soon as the parent shell is reaped, so the stop is not the hard barrier the surrounding comment claims.
- scripts/tournament/match-run.sh: The trap covers only `EXIT`, and a non-interactive bash with no `TERM`/`HUP` trap dies immediately on `SIGTERM`/`SIGHUP` without running its `EXIT` trap, so a tournament runner or supervisor terminating `match-run.sh` (as opposed to an operator's Ctrl-C, which reaches the consumer via the shared process group) orphans the consumer to keep draining into the following match.

**Drain note (correction to the Summary's line count; the structural claim is sound):** the Summary states the match-run.sh diff is "53 added lines, zero deletions". Measured on 2026-08-18: it is 0 deletions across 2 hunks, but approximately 96 added content lines (git numstat reports 101 for the file), not 53. The load-bearing half of that claim is correct and verified — zero deletions in two clean insertion hunks, so the roster swap, gear gate, assemble, start, monitor, telemetry/capture, logout and MATCH line really are byte-identical. Only the magnitude is understated, by roughly a factor of two. Worth correcting because the PR body quotes this Summary verbatim and a reviewer sizing the change from it would expect half of what is there.

**Drain note (findings 3 and 4 are the ones to act on — they defeat the artifact's central guarantee):** this artifact exists because "a consumer started alongside a match and left running would keep draining after the teams log out, and its next effect would land on the FOLLOWING match's bots". Two of the four findings puncture exactly that:

- Finding 4 is the more serious. The trap is `trap ... EXIT` only. A non-interactive bash that receives an untrapped SIGTERM dies from the signal WITHOUT running its EXIT trap, so the consumer is orphaned and keeps draining. This is not hypothetical here: artifact 025's tournament-run.sh drives match-run.sh once per pairing across a multi-hour bracket, and any supervisor, timeout or driver-side kill of a stuck match sends SIGTERM rather than an operator Ctrl-C. Ctrl-C is the one case that happens to work, because the terminal signals the whole process group, which is also why an interactive test of this path passes while the automated path fails. Trapping TERM and HUP alongside EXIT closes it.
- Finding 3 compounds it: effect_consumer_stop kills the consumer pid but not its process group, so a consumer blocked inside an in-flight ctl/docker exec dies while that child survives and delivers its effect after "effect consumer stopped" was logged. The stop is therefore not the hard barrier the surrounding comment claims.

Finding 1 is the same guarantee failing backwards rather than forwards, and only under the intended production shape (a shared EFFECT_QUEUE with per-run state dirs), so it re-fires already-applied effects at the next match. Finding 2 is documentation-only: the trap comment and the doc's Safety section both misdescribe which paths reach the trap.

**Ordering note:** this artifact runs a consumer that does not exist yet — effect-consume.sh ships with artifact 034, and 032/033/034 are all still pending behind 031 reaching done. The numeric-order rule picked the runner before its subjects because 035's declared dependency (029) is satisfied and theirs are not. The tick handled it correctly rather than silently: the launch is guarded on effect-consume.sh being present and logs "effect-consume.sh is not present" otherwise, matching the existing non-fatal idiom used for telemetry-extract.sh. Nothing in the in-game check can be exercised until 034 lands.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/43, build tortoise-cm:20260818-3.
