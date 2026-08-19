---
status: pending
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
