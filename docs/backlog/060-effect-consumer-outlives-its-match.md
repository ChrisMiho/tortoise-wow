---
status: done
risk: medium
area: tournament/match-run
depends-on: 035-run-effect-consumer-during-a-match.md
---

# The effect consumer can outlive its match and fire into the next one

**Problem:** three gaps in how `match-run.sh` starts and stops the consumer, all
against the guarantee artifact 035 exists to provide.

1. `effect_consumer_stop` kills the consumer's own pid, not its process group,
   so a consumer sitting inside an in-flight `ctl`/`docker exec` dies while that
   child survives and delivers its effect seconds after "effect consumer stopped"
   has been logged. `wait` returns as soon as the parent shell is reaped, so the
   stop is not the hard barrier the surrounding code treats it as.
2. The trap covers `EXIT` only. A non-interactive bash with no `TERM`/`HUP` trap
   dies immediately on `SIGTERM` without running it, so a tournament runner
   terminating `match-run.sh` orphans the consumer to keep draining into the
   following match. An operator's Ctrl-C is safe only because it reaches the
   consumer through the shared process group — which is luck, not design.
3. With `EFFECT_QUEUE` overridden to a queue shared across matches — the intended
   production shape once a real listener replaces the mock adapter — the per-run
   `--state "$RUN_DIR/effects"` directory means each match starts with an empty
   `applied.txt`, so every command a previous match already handled is re-drained
   at the next `tournament start`.

**Suspected cause / area:** `scripts/tournament/match-run.sh`, the consumer
start/stop block and its trap.

**Acceptance criteria:**

- After `match-run.sh` exits by any path — normal, deadline, Ctrl-C, `SIGTERM`,
  `SIGHUP` — no `effect-consume.sh` process and no descendant `docker exec`
  remains; `pgrep -f effect-consume` returns nothing.
- A shared `EFFECT_QUEUE` across two consecutive matches re-applies nothing from
  the first.
- The trap comment is corrected to match what the code actually does; it
  currently misdescribes both the deadline path and the reachability of `fatal`.

**Notes:**

- Process-group kills are easy to get wrong in a way that takes the parent down
  with them — test the parent survives its own cleanup.
- The signal paths are testable against a stub consumer with no world. The
  in-flight-`ctl` case needs a live match to prove fully (blocked on artifact
  055); do not treat that as a reason to skip the other two.

**Base:** cm-main

**Branch:** backlog/effect-consumer-outlives-its-match

**Summary:** The consumer's lifetime moved out of `match-run.sh` into a new `scripts/tournament/lib/effect-runner.sh`, because all of it is signals and process groups and none of it needs a world to test. The consumer is now launched under `set -m` so it gets its OWN process group; `effect_consumer_stop` SIGTERMs that whole group (so an in-flight `ctl`/`docker exec` dies with its parent instead of delivering a viewer's kill seconds after "effect consumer stopped" was logged), polls the group until it is empty, and SIGKILLs after `EFFECT_STOP_GRACE_S` (5s). It never signals its own group, so the match survives its own cleanup. Traps now cover EXIT, TERM, HUP and INT — TERM/HUP because a non-interactive bash with no handler dies without running its EXIT trap, which is exactly how a tournament runner terminating a match orphaned the consumer, and INT because the consumer's own process group is what Ctrl-C used to reach it through by luck. The signal handlers re-raise with the default disposition, so a killed run still exits 128+signal rather than a 0 a bracket driver would read as a match played to a result. The monitor loop's poll is now `effect_sleep` (background sleep + `wait`): a trap fires only once the foreground command finishes, so a plain `sleep 30` left a SIGTERM unhandled — and the consumer draining — for the rest of the interval; that sleep inherits no stdout and is reaped by the stop, because `tournament-run.sh` reads a match through `$(match-run.sh ... | tail -1)` and a command substitution returns only when every writer has closed the pipe. The shared-queue half (seeding `applied.txt` with every id already queued) was already implemented and is unchanged, but is now under test. The misleading trap comment is corrected in code and in `docs/playerbots/TOURNAMENT-VIEWER-EFFECTS.md`, which repeated the same wrong claim. New `tests/tournament/effect-runner.test.sh` (18 assertions, no world/DB) covers all of it against a stub consumer that leaves a child in flight; checked non-vacuous — the same test on the old pid-only stop leaves that child alive. Whole `tests/tournament/` suite is green (`tests/check-guardrails.test.sh` fails on this host for a pre-existing reason: `node` is not installed in WSL).

**In-game check:** Scriptable, no human eyes needed (run these first — they are the bulk of the check):

1. `wsl -d Ubuntu -- bash -lc 'cd <repo> && bash tests/tournament/effect-runner.test.sh'` must print "18 passed, 0 failed". It covers the process-group kill with an in-flight child, SIGTERM/SIGHUP/SIGINT, the 128+signal exit codes, the shared-queue non-replay, and that capturing the run's stdout returns promptly. No world, no DB, no build.
2. With the stack up and a real match running (`scripts/tournament/match-run.sh <ateam> <hteam> --run-dir <dir>` in one shell), from another shell: `kill -TERM <match-run pid>`, then within 2 seconds run `pgrep -af effect-consume` and `pgrep -af 'docker exec'` — both must return nothing, and `<dir>/match.log` must carry an "effect consumer stopped (group <pgid>)" line. Also check `echo $?` of the killed run reads 143, not 0.
3. Same test with Ctrl-C in the match's own terminal, and with `kill -HUP`: same two `pgrep` calls must come back empty.
4. Shared queue, from logs only: run two matches back-to-back with `EFFECT_QUEUE=/tmp/shared.ndjson` exported, queueing one `heal_player` during match one. Match two's `<run-dir>/effects.log` must contain no `EFFECT id=<that id>` line, and `<run-dir>/match.log` must contain "queue /tmp/shared.ndjson held N command(s) before this match".

Needs a human in the world (the one thing the stub cannot prove — artifact note says this is the in-flight-`ctl` case, blocked on 055 for a full match):

5. Start a match, watch the two teams in-game as a spectator. Queue a `kill_team` against the Horde team with `effect-queue.sh`, and while `effects.log` shows that command being applied (the console attach is open for ~10s), `kill -TERM` the `match-run.sh` process. The ten Horde bots may or may not die from that in-flight command — either is fine. What must NOT happen is the following: start the next match with the same two teams, and no bot may drop dead in the first 30 seconds without a queued command for that match. A death with no matching `EFFECT id=` line in the new match's `effects.log` is this bug still present.

6. Generic smoke: a whole two-match bracket via `tournament-run.sh` still finishes, each match prints its `MATCH ...` line, and `tournament.log` shows the driver picking it up immediately after the match ends rather than ~30 seconds later (that delay would be the poll-sleep holding stdout).

**Minor findings:**
- scripts/tournament/lib/effect-runner.sh: In effect_consumer_stop the SIGKILL escalation targets a pgid whose leader was already reaped by the preceding `wait "$pid"`, so if the id is recycled during the grace window the `kill -KILL "-$pgid"` lands on an unrelated process group rather than the consumer's.
- scripts/tournament/lib/effect-runner.sh: effect_sleep's trailing `kill "$EFFECT_SLEEP_PID"` is only reachable after `wait` has already reaped that pid (the comment says so itself), so it is dead code that fires a SIGTERM at a freed pid on every poll iteration of every match.
- tests/tournament/effect-runner.test.sh: The new test file is committed mode 100644 while every other tests/tournament/*.test.sh is 100755, so it is skipped by anything that globs and execs the suite directly.
- scripts/tournament/lib/effect-runner.sh: In effect_sleep, the trailing `kill "$EFFECT_SLEEP_PID"` runs on the normal path after `wait` has already reaped that exact pid, so it signals a pid the kernel is free to have reassigned — the shell analogue of a use-after-free, and the comment above it ("a trap interrupts wait and never reaches the kill below") only excuses the trap path, not the normal one.
- scripts/tournament/lib/effect-runner.sh: effect_consumer_stop does an unbounded `wait "$pid"` before the grace/SIGKILL escalation loop, so the escalation is unreachable for the one case it exists to cover: a consumer that defers or ignores SIGTERM (its own TERM trap, or SIGSTOP) leaves match-run.sh blocked in the stop forever instead of SIGKILLing the group after EFFECT_STOP_GRACE_S.
- scripts/tournament/lib/effect-runner.sh: effect_consumer_stop clears EFFECT_PID/EFFECT_PGID before it kills, so a SIGTERM arriving while the explicit post-loop stop is inside its `sleep 1` grace poll makes the trap's re-entrant stop a no-op that immediately re-raises and exits — abandoning a group that received only SIGTERM and never the SIGKILL escalation, which is exactly the "no effect-consume process remains" criterion.
- docs/playerbots/TOURNAMENT-VIEWER-EFFECTS.md: The header guarantee ("once effect_consumer_stop has returned, nothing started by the consumer can still deliver an effect") and the matching doc paragraph overstate what a host-side process-group kill can do: `ctl` reaches the world through `wsg_console`, which writes the command into `docker attach`'s stdin, and once that text is in mangosd's QueueCliCommand the effect executes on the world thread no matter what happens to the consumer's group.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/74, build tortoise-cm:20260819-4.
