---
status: done
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

**Base:** backlog/viewer-effect-queue

**Branch:** backlog/viewer-effect-consumer

**Summary:** Added `scripts/tournament/effect-consume.sh`, the applier that drains the append-only viewer-effect queue, plus six assertions in `tests/tournament/effects.test.sh` (17 -> 23, all passing, exit 0). It takes `--queue/--alliance/--horde/--state`, runs one pass with `--once` or loops on `--interval` (default 5s), reads the queue read-only on fd 3 (wsg_console attaches to mangosd and reads stdin, which on the loop's own stdin would silently swallow the rest of the file), and hands each command to `effect_apply` from `lib/effects.sh`. Dedupe: every id it closes out is appended to `<state>/applied.txt` and any id already there is skipped with `grep -qxF`, so a second pass over the same queue applies nothing. Rate limits: per-effect-class counts in `<state>/counts.txt`, capped at `kill_team` 2, `kill_player` 20, `heal_team` 10, `heal_player` 50, `upgrade_*_team` 2, `upgrade_*_player` 20, each overridable via `EFFECT_LIMIT_*`; a capped command is recorded as applied (so it is not re-refused every pass and does not fire late when a cap is raised) and counted separately from a duplicate. Each pass emits `CONSUME applied=<n> skipped=<n> ratelimited=<n>`; an unparseable or id-less queue line is warned about on stderr and stepped over, never fatal. The plan's counter defect is fixed as the artifact demands: `grep -c "^$1\$" file || echo 0` prints `0` and exits 1 when the file exists without a match, so the `|| echo 0` also fires and the function returns the two-line string `0\n0`, which makes `[ "$used" -ge "$lim" ]` die with "integer expression expected" and evaluate false — the rate limit never bites. I reproduced that in WSL before fixing it. `count_for` now guards the missing file, keeps grep's stdout, discards its exit status, and coerces non-numeric to 0, so it returns one integer whether counts.txt is missing, empty, or present without a matching line. Two small hardenings beyond the plan text: `limit_for` is a `case`, not `eval "\$LIMIT_$1"` (the effect name comes off a chat-fed queue), and the cap check is skipped for a name not in `$EFFECT_NAMES` so a malformed command is refused by `effect_validate` with a real reason instead of reported as "over its cap of 0". The `CTL_STUB` switch is kept, so the tests need no server, and no SQL migration and no build were required. All seven tournament test files still pass (bracket 9, ctl 6, effects 23, gear 12, roster 11, state 10, team 10).

**In-game check:** This one needs a real match, because the whole point is an effect landing on a bot a viewer can see. Scriptable parts are flagged.

SCRIPTABLE, no server, run first (from WSL — jq is absent from Git Bash here):
1. `wsl -d Ubuntu -- bash -lc 'cd /mnt/c/<worktree> && bash tests/tournament/effects.test.sh'` prints `23 passed, 0 failed` and exits 0. This is the dedupe/rate-limit/counter proof and needs nothing standing up.
2. `bash scripts/tournament/effect-consume.sh --queue /nonexistent --alliance stormwind-sentinels --horde orgrimmar-warsong --state /tmp/st --once` prints exactly `CONSUME applied=0 skipped=0 ratelimited=0` and exits 0 — a missing queue is not an error.

IN-GAME, needs a live match (`tournament heal` / `tournament kill` / `tournament equip` must be in the running image; `tortoise-cm:c06b2fb` predates them):
3. Start a Warsong Gulch match: `./scripts/tournament/match-run.sh stormwind-sentinels orgrimmar-warsong`, and while it is live, log in a GM and `.go` into the instance so you can watch the Alliance bots (Wsga*) at their flag room.
4. In a second shell: `./scripts/tournament/effect-consume.sh --queue var/effects.ndjson --alliance stormwind-sentinels --horde orgrimmar-warsong --state var/effects-state --interval 5`. It should print a `CONSUME applied=0 skipped=0 ratelimited=0` line every five seconds and nothing else.
5. In a third shell, enqueue one heal: `./scripts/tournament/effect-queue.sh --queue var/effects.ndjson --effect kill_player --team stormwind-sentinels --slot one`. Watch Wsgaone: within one interval it should **drop dead once** and release to the graveyard like any normal battleground death — not twice, and not a corpse that never respawns. The consumer prints `EFFECT id=<id> effect=kill_player team=stormwind-sentinels applied=1 failed=0` then `CONSUME applied=1 skipped=0 ratelimited=0`.
6. THE DEDUPE CHECK, and the one worth doing carefully: re-file the *same id* — `./scripts/tournament/effect-queue.sh --queue var/effects.ndjson --effect kill_player --team stormwind-sentinels --slot one --id <the id from step 5>`. Wsgaone must **not** die a second time. Console shows `CONSUME applied=0 skipped=1 ratelimited=0` and no new `EFFECT` line. Confirm `grep -c '^<id>$' var/effects-state/applied.txt` is 1.
7. THE CRASH-REPLAY CHECK: Ctrl-C the consumer and restart it with the same `--state` dir. Nothing in the world may change — no bot dies, no bot is healed — and the first pass must report `applied=0` with `skipped=` equal to the number of commands in the queue. Before this fix a restart re-applied the entire queue.
8. THE RATE-LIMIT CHECK, the match-deciding one: enqueue five `kill_team` against `orgrimmar-warsong`. Exactly **two** Horde wipes should happen (the default cap), the other three producing `WARN: kill_team is over its cap of 2 for this match, dropping id=...` on stderr and `ratelimited=3` on the CONSUME line. The Horde team must still be standing and the match must still be running afterwards. This is precisely the case that silently did nothing with the plan's `0\n0` counter, so watch that `ratelimited=` is non-zero rather than trusting that no third wipe merely happened not to fire.
9. Poison the queue by hand: `echo 'not json' >> var/effects.ndjson`, then enqueue one more valid `heal_team`. The consumer must print `WARN: skipping unparseable queue line: not json`, still apply the heal behind it, and keep looping. It must not exit.
10. Log both teams out and confirm the consumer, left running, keeps emitting `CONSUME applied=0 skipped=<n> ratelimited=0` without erroring — a queue outliving its match is the normal end state, not a fault.

**Minor findings:**
- scripts/tournament/effect-consume.sh: A trailing option with no value (e.g. `--interval` as the last argument) makes the argument-parsing loop spin forever instead of printing usage and exiting 2, because `shift 2` fails when only one argument remains and the loop never advances — confirmed by repro: the script hangs (timeout rc=124) with no output.
- scripts/tournament/effect-consume.sh: The effect class is appended to `counts.txt` even when `effect_apply` refused or failed the command (e.g. a stale queue entry naming a team not in this match), so commands that never touched the world still burn the per-match cap — two stale `kill_team` lines can exhaust the default cap before any legitimate one lands, contradicting the adjacent comment that "a refused command never touched the world".
- scripts/tournament/effect-consume.sh: The counts.txt cap counter is incremented even when effect_apply returns failure (e.g. a command naming a team not in this match, which effect_targets refuses before touching the world), contradicting the adjacent comment "a refused command never touched the world" and letting stale queue lines burn the match-deciding kill_team budget so a legitimate viewer purchase is then rate-limited.
- scripts/tournament/effect-consume.sh: applied.txt and counts.txt are read (grep) and appended without any lock or atomic claim, so two consumer processes sharing one --state dir -- an operator restarting the looping consumer without killing the old one, the ordinary case for a long-running per-match loop -- both miss the id and both apply the same kill_team, which is exactly the double-apply the dedupe exists to prevent.
- scripts/tournament/effect-consume.sh: The id is appended to applied.txt only after effect_apply returns, so a consumer killed partway through a _team effect's ten ctl calls leaves the command unrecorded and the next pass replays it in full, weakening the header's claim that dedupe stops a restart mid-match from re-killing a team.
- scripts/tournament/effect-consume.sh: count_for is hardened to a single integer but limit_for passes the environment override through unvalidated, so a non-numeric EFFECT_LIMIT_* value makes [ "$used" -ge "$lim" ] error and evaluate false, silently disabling the cap -- the same failure mode the artifact calls out for the counter.

**Drain note (the counter defect was REAL and the fix is correct — independently reproduced):** this artifact's own criterion was that the per-effect counter must return a single integer in every case. The drain reproduced the plan's form on 2026-08-18:

```
buggy() { grep -c "^$1$" "$f" || echo 0; }
buggy kill_team   ->  returned $'0
0'   (a TWO-LINE string)
[ "$out" -ge 2 ]  ->  [: 0   and evaluates FALSE
```

grep -c prints 0 AND exits 1 when the file exists without a match, so `|| echo 0` fires as well. The comparison then errors and evaluates false, meaning the rate limit never bites — on kill_team, which this artifact itself calls match-deciding ("without a cap, one script hammering the queue ends every match instantly"). The third state is not exotic: it is reached the first time any OTHER effect is applied, since that is what creates counts.txt. The fix (guard the missing file, keep grep's stdout, discard its exit status, coerce non-numeric to 0) is right, and the header comment at :149-157 documents the trap for the next reader.

**Drain note (finding 6 is the same bug one variable over — fix them together):** count_for is now hardened to a single integer, but limit_for passes the EFFECT_LIMIT_* environment override through unvalidated. A non-numeric override makes `[ "$used" -ge "$lim" ]` error and evaluate false, silently disabling the cap — precisely the failure mode this artifact was written to eliminate. Validate the override the same way.

**Drain note (finding 1 is the SECOND instance of one bug pattern in this chain):** a trailing option with no value spins the argument loop forever (timeout rc=124) because `shift 2` cannot shift with one argument left, so $# never decreases. The drain independently reproduced exactly this bug in artifact 033 (effect-queue.sh) one tick earlier — `--effect heal_team --team stormwind-sentinels --queue` returned exit 124 there too. Both scripts in the viewer-effect chain share it, and both are operator-facing command lines where a trailing flag is an ordinary typo. A hang is worse than an error because nothing reports it. One `[ $# -ge 2 ] || usage_error` in each flag branch closes both.

**Drain note (findings 2/3 are one defect; 4 and 5 are the durability gaps):** 2 and 3 are the same issue seen twice — the effect class is appended to counts.txt even when effect_apply refused, so stale queue entries naming a team not in this match burn the cap before any legitimate command lands, contradicting the adjacent comment that "a refused command never touched the world". Two stale kill_team lines exhaust the default cap of 2. Finding 5 is the mirror image on the dedupe side: the id is recorded only AFTER effect_apply returns, so a consumer killed partway through a _team effect's ten ctl calls leaves it unrecorded and the next pass replays it in full — which weakens the crash-replay guarantee the header claims. Finding 4 notes there is no lock, so two consumers sharing one --state dir both miss the id and both apply the same kill_team.

**Drain note (this artifact closes the viewer-effect chain, and its stdin discipline is the right lesson learned):** 032 (library) -> 033 (queue) -> 034 (consumer) are now all implemented, and 035 wired effect-consume.sh into match-run.sh in anticipation — that call currently logs "effect-consume.sh is not present" and will start working once this merges. Note the consumer reads the queue read-only on fd 3 specifically because wsg_console attaches to mangosd and reads stdin, which would otherwise swallow the rest of the file. That is the same class of defect the drain recorded against artifact 035, where match-run.sh invokes a ~25-minute script inside a `while read` loop fed by a here-string. Same trap, opposite outcome: 034 avoided it deliberately.

**Inherited exposure carried forward from 032 (not this artifact's bug, but this is the code that pays the cost):** effect_apply opens ONE console attach PER TARGET, so every *_team command this consumer drains costs ten attaches against the repo's documented "ONE console attach for the whole run" convention and its warning that repeated attaches risk EOF-ing the console and shutting the world down. And effect_apply counts a target as applied if ANY reply line contains ok=1, so a partial equip reports clean success — which this consumer then records in applied.txt and dedupes away permanently.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/56, build tortoise-cm:20260818-7.
