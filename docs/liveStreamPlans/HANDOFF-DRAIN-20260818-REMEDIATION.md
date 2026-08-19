# Handoff: remediate the 18 Aug drain and merge its 24 PRs

The 18 Aug drain implemented every scoped artifact (013–045, all `status: done`,
zero `failed`) across seven batches. Nothing is left pending on `cm-main`. What
remains is the other half: **24 open PRs that have to land in dependency order**,
and **a set of verified-but-unfixed defects the drain deliberately did not fix**,
because `backlog-issue` reviews and records rather than re-opening its own work.

This file is the input to `backlog-scope`. Part 2 is written so each item already
answers every question the skill asks — Problem, Suspected cause, Acceptance
criteria, Risk, Area, Depends-on, Feasibility. Scope them in the order given.

---

## Read this before scoping anything

**Artifacts 046–054 already exist, but only on an unmerged branch.** The nine
bot-AI fixes scoped by artifact 037 live on `backlog/bg-ai-analysis-measurement-and-scoping`
(PR #46). On `cm-main` the backlog directory is empty and the counter in
`docs/backlog/README.md` reads `045`.

Consequences, both of which bite silently:

1. **Merge PR #46 before running `backlog-scope`.** Otherwise the skill's
   three-source high-water check (git history, README counter, files on disk)
   resolves to 054 from history but the README says 045 — and a scoper trusting
   the README alone reissues numbers that already name nine different issues.
   Numbers are never reused; a collision repoints every `depends-on:` in the
   chain.
2. **Merge PR #46 before restarting the drain.** A drain tick on today's
   `cm-main` sees an empty backlog and reports nothing to do, while the nine
   highest-value fixes sit on a branch.

**The first free number is 055.** Everything in Part 2 assumes that.

---

## Part 1 — merge strategy

### The two real blockers, stated once

**1. The bots do not play.** In-game: 20 of 20 bots enter Warsong Gulch, then
stand where they land for the full 20 minutes — never move, never fight, never
touch the flag. Technical: measured across three independent matches, ~98.5% of
playerbot AI ticks end "no actions executed"; `bg move to objective` was queued
23,908 times and popped **zero** times; `bg check flag` failed its prerequisite
23,681 of 23,681 times. Causes are read out in `docs/playerbots/BG-AI-ANALYSIS.md`
(on PR #46): three high-relevance `BattlegroundStrategy` entries commented out,
`team flagcarrier near` never registered in `playerbot/strategy/triggers/TriggerContext.h`,
and the PvP flag triggers compiled out behind `#ifdef MANGOS` — a define that
appears nowhere in `src/`. Artifacts 046–054 own these.

**2. The gear gate blocks `match-run` on this host, and no artifact owns it.**
`gear-apply.sh` cannot dress 9 of 20 bots (`cannot_equip`), so `gear-audit.sh`
reports `complete=5/10` and `6/10` and `match-run.sh` aborts before assembly.
`BG-AI-ANALYSIS.md` §4.5 defers this to artifact 031 — but 031 is the
armour/weapon tier split and says nothing about `cannot_equip`, so the blocker
has a pointer that only looks like an owner. This makes the in-world acceptance
criteria of 046, 047 and 053 unrunnable. **Item R-1 below is that missing artifact.**

Neither blocker is a merge blocker. Both are why no further in-world validation
is worth running until they are fixed — three matches have already produced the
same measurement.

### Dependency graph

Ten branches were cut from other backlog branches rather than from `cm-main`, so
merge order is load-bearing. Computed from `git merge-base --is-ancestor`:

```
gear-tier-armour-weapon-split #42
  └─ viewer-effect-library #45
       └─ viewer-effect-queue #52
            └─ viewer-effect-consumer #56

tournament-equip-and-store-commands #33
  └─ tournament-heal-and-kill-commands #40
       └─ tournament-poi-and-camera-commands #47

telemetry-extract #38                     └─ telemetry-entry-and-movement-reports #41
bot-log-capture-and-match-artifacts #39   └─ run-effect-consumer-during-a-match #43
spectator-director-loop #48               └─ streaming-feasibility-assessment #49
recover-ramp-and-plateau-instruments #50  └─ standup-1000-script #54
tournament-run-driver #36                 └─ reconcile-bot-pool-with-match-profile #53
bg-ai-analysis-code-reading #44           └─ bg-ai-analysis-measurement-and-scoping #46

independent: #34  #37  #51  #55
```

Merging a child before its parent produces conflicts that look like real
divergence but are only replayed commits.

### Waves

**Wave 0 — unblock the backlog.** `#44` then `#46`. Do this first, for the two
reasons in "Read this before scoping anything". After it lands, `docs/backlog/`
holds 046–054 at `status: pending` and the counter reads 054.

**Wave 1 — independent, already validated in-stack.** `#33`, `#34`, `#35`,
`#36`, `#37`, `#38`, `#39`, `#42`, `#48`, `#50`, `#51`. Scripts, docs, one
config-gated C++ sampler, and one two-literal change to `PlayerbotAIConfig.cpp`
matching what the shipped conf has always said. Each was built and passed
`VALIDATE-STACK` in its own batch image.

**Wave 2 — chains, strictly in graph order.** `#40` → `#47`; `#41`; `#43`;
`#45` → `#52` → `#56`; `#49`; `#53`; `#54`.

**Wave 3 — hold.** `#55` (`release-tag.sh`) is the one PR to keep out of
`cm-main` until its remediation lands (**R-4**). Every other known defect fails
loudly or fails in-world, where nothing can currently run; this one creates
persistent bad state — a real annotated git tag with no matching image, which is
exactly what its own gate was written to prevent. Merge it after R-4.

The alternative — holding `#47` and `#56` as well, since both ship a defect that
defeats their artifact's headline criterion — is defensible. The recommendation
is to merge them and let R-2 and R-3 fix them on `cm-main`, because their failure
modes need a live match and no live match can run until the two blockers above
are fixed.

### After the merges

Rebuild once from the merged `cm-main`, run `./scripts/validate-stack.sh`, and
record the image tag. Do **not** run another WSG validation match to characterise
bot behaviour — that measurement exists three times over. The next in-world run
worth doing is the one that verifies 046/047 actually made a bot move.

---

## Part 2 — items to scope

Eleven items, in priority order. Suggested numbers assume PR #46 has merged and
the sequence resumes at **055**.

---

### R-1 → 055 — `gear-apply` cannot dress half the roster, so no match can start

**Problem:** `scripts/tournament/gear-apply.sh` leaves 9 of 20 bots undressed —
the console reports `cannot_equip` per item — so `gear-audit.sh` returns
`complete=5/10` for one team and `6/10` for the other and `match-run.sh` aborts
before assembly. No tournament match can be run on this host. The finding was
recorded in `docs/playerbots/BG-AI-ANALYSIS.md` §4.5 and deferred to artifact
031, which is scoped to splitting a tier into armour and weapon subsets and says
nothing about `cannot_equip`; the blocker therefore has no owner.

**Suspected cause / area:** the provisional tier files generated by artifact 021
select items without checking class/race/level equip requirements against
`tw_world.item_template` (snake_case on this server: `inventory_type`,
`item_level`, `required_level`), so a tier hands a class an item it cannot wear.
Either the generator's filter or the `tournament equip` handler's requirement
check is the wrong side of the fix — determine which before writing code.

**Acceptance criteria:**
- For both shipped teams, `gear-apply.sh` followed by `gear-audit.sh` reports
  `complete=10/10` with zero `cannot_equip` lines.
- `match-run.sh <alliance> <horde>` gets past assembly and reaches
  `tournament start`.
- A regression test under `tests/tournament/` proves a tier containing an item
  the target class cannot equip is rejected at generation time with a named
  reason, not silently at equip time.

**Risk:** medium — touches gear generation that four other scripts consume.

**Area:** `tournament/gear`

**Depends-on:** `031-gear-tier-armour-weapon-split.md`

**Feasibility:** needs a running world and the `tw_world` database to re-derive
tiers. Both are available. Note the acceptance criteria stop at "the match
starts" — whether the bots then *play* is artifacts 046–054, not this one.

---

### R-2 → 056 — `tournament camera` can still turn a match into 11v10

**Problem:** the camera command's participant refusal tests
`bg->IsPlayerInBattleGround(plr->GetObjectGuid())`, which is the `m_Players`
lookup only. A player whom `tournament add` has already invited and sent, but who
has not yet been inserted by `HandleMoveWorldPortAckOpcode`, is not in
`m_Players` — so they pass the guard, get teleported as a spectator, and are then
added anyway when the world-port ack arrives. That is exactly the 11v10 the
refusal exists to prevent, and the code's own comment three lines above already
names the mid-port state that defeats it. Separately, the same handler writes
`SetBattleGroundEntryPoint()` and `SetBattleGroundId()` *before* `TeleportTo` and
never rolls them back on failure; both set `m_bgData.m_needSave`, so a `moved=0`
refusal leaves a GM persistently marked as being in a match they never entered —
it survives logout, relocates them on next login, and makes a later
`tournament add` refuse them with `already_in_a_battleground`.

**Suspected cause / area:** the `tournament camera` handler added by artifact 038.
`tournament add` already models both correct patterns: an `IsBeingTeleported()`
check, and `TournamentReleaseInvite` for rollback.

**Acceptance criteria:**
- A player invited to the match but not yet ported is refused by `camera` with a
  named reason; the match ends 10v10.
- A `camera` call whose `TeleportTo` fails leaves `m_bgData` exactly as it was —
  a subsequent `tournament add` for that player succeeds rather than reporting
  `already_in_a_battleground`.
- One rollback on the failure path closes both the entry-point and the
  battleground-id writes.

**Risk:** medium — battleground player state, and `m_needSave` makes a mistake
persistent across logout.

**Area:** `game/tournament`

**Depends-on:** `038-tournament-poi-and-camera-commands.md`

**Feasibility:** needs a build and a live instance to verify the mid-port race.
The rollback half can be proven by forcing `TeleportTo` to fail without a match.

---

### R-3 → 057 — the viewer-effect rate limit and dedupe can both be defeated

**Problem:** five defects in `scripts/tournament/effect-consume.sh`, all against
guarantees the artifact was written to provide.

1. `limit_for` passes the `EFFECT_LIMIT_*` environment override through
   unvalidated, so a non-numeric value makes `[ "$used" -ge "$lim" ]` error and
   evaluate false — silently disabling the cap. This is the same failure mode the
   artifact already fixed one variable over in `count_for`.
2. The effect class is appended to `counts.txt` even when `effect_apply` refused,
   so two stale queue lines naming a team not in this match exhaust the default
   `kill_team` cap of 2 before any legitimate command lands — contradicting the
   adjacent comment that "a refused command never touched the world".
3. The id is appended to `applied.txt` only *after* `effect_apply` returns, so a
   consumer killed partway through a `*_team` effect's ten `ctl` calls leaves it
   unrecorded and the next pass replays it in full.
4. `applied.txt` and `counts.txt` are read and appended with no lock, so two
   consumers sharing one `--state` dir — an operator restarting the loop without
   killing the old one — both miss the id and both apply the same `kill_team`.
5. A trailing flag with no value (`--interval` as the final argument) spins the
   argument loop forever: `shift 2` cannot shift with one argument left, so `$#`
   never decreases. Reproduced as `timeout` rc=124 with no output. The identical
   bug exists in `scripts/tournament/effect-queue.sh` — fix both.

**Suspected cause / area:** `scripts/tournament/effect-consume.sh` and
`scripts/tournament/effect-queue.sh`.

**Acceptance criteria:**
- `EFFECT_LIMIT_KILL_TEAM=abc` is rejected with a named error rather than
  disabling the cap; a test asserts it.
- A refused or failed command does not increment `counts.txt`; five `kill_team`
  against a team not in the match leave the legitimate cap intact.
- An id is claimed in `applied.txt` before the first `ctl` call, so a kill
  interrupted mid-run is not replayed.
- Two consumers on one `--state` dir apply each command exactly once.
- Both scripts exit 2 with usage on a trailing valueless flag; a test drives each
  under `timeout` and asserts a non-124 exit.

**Risk:** low — shell only, covered by `tests/tournament/effects.test.sh`.

**Area:** `tournament/effects`

**Depends-on:** `034-viewer-effect-consumer.md`

**Feasibility:** fully testable with the existing `CTL_STUB` seam; no world, no
build.

---

### R-4 → 058 — `release-tag.sh` can cut a git tag with no matching image

**Problem:** two defects, both in the gates that exist to prevent a half-cut
release. (1) The gate-3 refusal message interpolates the raw `${TW_IMAGE}`
instead of the `IMAGE_REPO` value the script correctly strips a trailing tag from
further down, so with today's `.env` (`TW_IMAGE=tortoise-cm:20260818-4`) it hands
a blocked operator the remediation command
`./scripts/validate-stack.sh --image tortoise-cm:20260818-4:9a1b2c3` — not a
valid image reference. (2) The up-front name validation rejects only names
starting with `.` or `-`, so a git-legal name containing `/` (`release/v1`, a
common convention) passes, the annotated git tag **is** created, and
`docker tag tortoise-cm:release/v1` then fails as an invalid reference — leaving
exactly the git-tag-without-an-image state gate 2 was written to prevent.

**Suspected cause / area:** `scripts/release-tag.sh`, the two gates.

**Acceptance criteria:**
- The gate-3 message prints the stripped `IMAGE_REPO`, producing a runnable
  command.
- `release-tag.sh 'release/v1'` is refused before any tag is created; verify with
  `git tag -l` that nothing was left behind.
- Both paths covered by a test that runs against a stubbed
  `verify-running-commit.sh` and deletes its probe tags afterwards.

**Risk:** low — one script, no server.

**Area:** `ops/release`

**Depends-on:** `045-release-tag-script-and-record.md`

**Feasibility:** testable with a stub. **Do not run the real script as part of
routine validation — it creates a real release tag.** PR #55 should stay unmerged
until this lands (see Wave 3).

---

### R-5 → 059 — `effect_apply` reports partial failures as success and burns ten console attaches

**Problem:** three defects in `scripts/tournament/lib/effects.sh`, all paid for by
the consumer downstream. (1) A target counts as applied whenever *any* line of the
`ctl` reply contains `ok=1`. Against `tournament equip`'s real output — one
`ok=<0|1>` per item plus an `equipped=n failed=n` summary — a reply of
`item=1 ok=1` / `item=2 ok=0` / `equipped=1 failed=12` is reported as a clean
success, which `effect-consume.sh` then records in `applied.txt` and dedupes away
permanently. A viewer pays, gets one item, and nothing says so. (2)
`effect_upgrade_one` always reads the current tier from the team's `.gearTier`,
which nothing ever updates, so a second `upgrade_armor_player` on the same bot
re-equips the tier it is already wearing and reports `ok=1`. (3) `effect_apply`
opens one console attach per target, so a `heal_team` or `kill_team` costs ten
attaches — against this repo's explicit one-attach-per-run convention and the
`wsg_console` warning that "forty attaches is forty chances to EOF the console,
which shuts the world down". `gear-apply.sh` and `roster.sh` both batch correctly.

**Suspected cause / area:** `scripts/tournament/lib/effects.sh`, `effect_apply`
and `effect_upgrade_one`.

**Acceptance criteria:**
- Success is decided from the summary line (`failed=0`), not from any `ok=1`; a
  partial equip yields a failure for that target and a non-zero exit.
- A second `upgrade_*_player` on the same bot either advances a tier that is
  actually recorded, or reports a distinct reason — never a silent re-equip
  reported as `ok=1`.
- A `*_team` effect issues **one** console attach for all ten targets.
- All three covered in `tests/tournament/effects.test.sh` via `CTL_STUB`.

**Risk:** medium — the console-attach change alters how every effect reaches the
world.

**Area:** `tournament/effects`

**Depends-on:** `032-viewer-effect-library.md`

**Feasibility:** the batching change should be smoke-tested against a live console
once a match can run; the reporting and tier changes are stub-testable now.

---

### R-6 → 060 — the effect consumer can outlive its match and fire into the next one

**Problem:** three gaps in how `match-run.sh` starts and stops the consumer, all
against the guarantee artifact 035 exists to provide. (1) `effect_consumer_stop`
kills the consumer's own pid, not its process group, so a consumer sitting inside
an in-flight `ctl`/`docker exec` dies while that child survives and delivers its
effect seconds after "effect consumer stopped" has been logged — `wait` returns as
soon as the parent shell is reaped, so the stop is not the hard barrier the
surrounding code treats it as. (2) The trap covers `EXIT` only; a non-interactive
bash with no `TERM`/`HUP` trap dies immediately on `SIGTERM` without running it,
so a tournament runner terminating `match-run.sh` orphans the consumer to keep
draining into the following match. An operator's Ctrl-C is safe only because it
reaches the consumer through the shared process group. (3) With `EFFECT_QUEUE`
overridden to a queue shared across matches — the intended production shape once a
real listener replaces the mock adapter — the per-run `--state "$RUN_DIR/effects"`
directory means each match starts with an empty `applied.txt`, so every command a
previous match already handled is re-drained at the next `tournament start`.

**Suspected cause / area:** `scripts/tournament/match-run.sh`, the consumer
start/stop block and its trap.

**Acceptance criteria:**
- After `match-run.sh` exits by any path — normal, deadline, Ctrl-C, `SIGTERM`,
  `SIGHUP` — no `effect-consume.sh` process and no descendant `docker exec`
  remains; `pgrep -f effect-consume` returns nothing.
- A shared `EFFECT_QUEUE` across two consecutive matches re-applies nothing from
  the first.
- The trap comment is corrected to match what the code actually does; it currently
  misdescribes both the deadline path and the reachability of `fatal`.

**Risk:** medium — process-group kills are easy to get wrong in a way that takes
the parent down with them.

**Area:** `tournament/match-run`

**Depends-on:** `035-run-effect-consumer-during-a-match.md`

**Feasibility:** the signal paths are testable against a stub consumer with no
world. The in-flight-`ctl` case needs a live match to prove fully.

---

### R-7 → 061 — `tournament heal` reports a resurrection that never happened

**Problem:** `Player::ResurrectPlayer` begins
`if (IsHardcore() && !forceHc) return;` (`src/game/Objects/Player.cpp:5755`), and
the heal handler passes no `forceHc`. A dead hardcore target therefore stays a
ghost while the command's record claims `resurrected=1`, and `SetHealth` then runs
on a dead unit. Tournament bots are never hardcore, so the impact is not the bots
— it is the name-collision case the artifact already argued on the kill side: the
kill path has a hardcore guard precisely so a collision from the viewer-effect
queue cannot destroy a real hardcore character. By the same argument, heal emits a
false resurrection record for one.

**Suspected cause / area:** the `tournament heal` handler added by artifact 030.

**Acceptance criteria:** a hardcore target is either refused with a named reason or
the result is re-checked with `IsAlive()` after the call — in neither case does the
record read `resurrected=1` for a character still a ghost.

**Risk:** low — one guard in one handler.

**Area:** `game/tournament`

**Depends-on:** `030-tournament-heal-and-kill-commands.md`

**Feasibility:** needs a build; verifiable with any hardcore test character, no
match required.

---

### R-8 → 062 — the telemetry gate takes a process-wide lock on every tick of every battleground

**Problem:** the sampler's default-off gate calls
`sConfig.GetIntDefault("Tournament.TelemetryIntervalMs", 0)` every world tick for
every live battleground, and `Config::GetValueHelper` takes an exclusive
`unique_lock` on the process-wide config mutex and linearly enumerates every
section doing a string key lookup. The conf comment's claim that it "costs nothing
when off" understates the cost: the gate serialises the instance-map threads
against every other `sConfig` reader in the process even when telemetry is
disabled. Compounding it, the sampler's comment asserts it "runs on the main world
loop", but `BattleGround::Update` is reached from `BattleGroundMap::Update` inside
the instance thread pool in `MapManager::Update` — and that wrong claim is exactly
what makes the cross-thread player access above it look safe to the next reader.

**Suspected cause / area:** `src/game/Battlegrounds/BattleGround.cpp`, the
artifact-026 sampler block.

**Acceptance criteria:**
- The interval is read once (a cached world-config entry or equivalent), not per
  tick per battleground; the config lock is not taken on the hot path.
- The comments name the instance thread pool rather than the main world loop, and
  the thread-safety of the player access is stated explicitly rather than implied
  by a wrong claim.
- With telemetry off, a 1000-bot stand-up shows no regression against the
  4.2682 GiB / 1017-bot reference.

**Risk:** medium — hot path, and the comment correction changes what a future
reader believes about thread safety.

**Area:** `game/battlegrounds`

**Depends-on:** `026-battleground-telemetry-sampler.md`

**Feasibility:** needs a build. The stand-up comparison is a ~2.5 h run
(`scripts/standup-1000.sh`) — treat it as operator follow-up, not a gate on the
code change.

---

### R-9 → 063 — `standup-1000.sh` leaves the live config pinned and can pass a still-climbing stack

**Problem:** two defects in `scripts/standup-1000.sh`. (1) It saves
`aiplayerbot.conf.before` but never restores it on any exit path — the EXIT trap
only kills the sampler — so a failed run silently leaves the live pool target
pinned at 1000 on a host whose config is shared state. It also `sed -i`s that live
conf and restarts `tcm-mangosd` with no lock guarding concurrent runs. (2) If no
plateau is reached within the 60-minute hold the script logs a WARN, breaks with
`PLATEAU=0`, then applies the remaining gates normally — so a run whose RSS is
still climbing can print `plateau=0 ... verdict=PASS` and exit 0. That contradicts
the artifact's own premise that reaching the bot count is not proof the stack
settled.

**Suspected cause / area:** `scripts/standup-1000.sh`, the EXIT trap and the
plateau branch.

**Acceptance criteria:**
- Every exit path restores `aiplayerbot.conf` from the backup; verified by diffing
  the live conf before and after a deliberately failed run.
- A second concurrent invocation refuses to start rather than racing the first.
- `plateau=0` cannot produce `verdict=PASS` — either it is a gate, or the verdict
  names it as unproven.

**Risk:** medium — mutates host-global shared state and restarts the world server.

**Area:** `ops/standup`

**Depends-on:** `044-standup-1000-script.md`

**Feasibility:** the restore and lock paths are testable with a short run that
fails early — the script already stops cleanly at `validate-stack`. A full stand-up
is ~2.5 h and is not required to verify either fix.

---

### R-10 → 064 — three scripts report success on a failure path

**Problem:** a cluster of the same shape — an error that reaches the caller as
clean output. (1) `telemetry-extract.sh` exits 1 on the no-samples path without
touching `$OUT`, so a pre-existing CSV from an earlier successful run at the same
path survives and a downstream reader that checks only the file consumes stale
telemetry (reproduced: a second run with `--instance 202` exits 1 while the earlier
`--instance 101` CSV remains). (2) `bot-log-capture.sh` — if the `> "$OUT"`
redirection fails on an unwritable path, the pipeline status is 1, which the code
treats as the legitimate "grep matched nothing" case; the subsequent
`wc -l < "$OUT"` also fails and the script prints
`captured  line(s) from <m> byte(s)` with an empty count and exits 0. (3)
`match-run.sh` — the bot-log capture is gated on `[ -f "$RUN_DIR/bots.offset" ]`
but nothing removes a stale offset file, so a failed `--mark` or an aborted
previous run in the shared `logs/tournament/adhoc` dir captures against the
*previous* match's offset instead of taking the skip branch; and only
`telemetry-extract.sh` is existence-checked, so a missing `telemetry-report.sh`
fails with 127 while the code logs "telemetry report flags a problem (stuck bots,
or fewer than 20 entered)" and writes the shell's "No such file" error into
`telemetry-report.txt` as if it were the report.

**Suspected cause / area:** `scripts/tournament/telemetry-extract.sh`,
`scripts/tournament/bot-log-capture.sh`, `scripts/tournament/match-run.sh`.

**Acceptance criteria:**
- A no-samples extract removes or truncates `$OUT` so no stale CSV can be read as
  current.
- An unwritable output path makes `bot-log-capture.sh` exit non-zero with a named
  error, never `exit 0` with an empty count.
- A stale `bots.offset` is cleared at run start; `telemetry-report.sh` is
  existence-checked like its sibling, and a 127 is reported as a missing script,
  not as a telemetry finding.
- One regression test per case.

**Risk:** low — three shell scripts.

**Area:** `tournament/telemetry`

**Depends-on:** `029-bot-log-capture-and-match-artifacts.md`

**Feasibility:** all three reproducible without a world.

---

### R-11 → 065 — documentation claims that point the next reader at the wrong thing

**Problem:** four load-bearing-but-false statements left by the drain, each of the
kind that survives because it reads plausibly. (1) `spectate.sh`'s header justifies
"run from WSL" with "jq is not on Git Bash's PATH on this host" — but
`spectate.sh`, `lib/ctl.sh` and `wsg-bots-common.sh` contain no `jq` call at all,
so a correct instruction rests on a dependency that does not exist and will be
"corrected" away by someone who checks. (2) The same header points twice at
`docs/playerbots/TOURNAMENT-STREAMING.md`, which artifact 040 creates — the
reference dangles until PR #49 merges, and if the wave order changes it dangles on
`cm-main`. (3) `wsg-mode.sh`'s new header comment says "the compiled pool default
moved from 200 to 1000 (`aiplayerbot.conf.dist.in:57-58`)", but the `.dist.in` has
shipped 1000 all along; what moved was `PlayerbotAIConfig.cpp:250` and the stale
200 was this script's own literal — so the comment points a maintainer at the wrong
file for the history. (4) `wsg-mode.sh`'s no-snapshot fallback prints
"pool 1000/1000 (from `<DIST_AICONF>`)" unconditionally, naming a file it never
read — on a server host where the script was copied without the source tree, which
is the exact case those literals exist for.

**Suspected cause / area:** `scripts/tournament/spectate.sh`,
`docs/playerbots/wsg/wsg-mode.sh`.

**Acceptance criteria:** each of the four statements is either corrected to match
the code or removed; the `TOURNAMENT-STREAMING.md` reference resolves on `cm-main`;
and the fallback's provenance string distinguishes "read from the file" from
"compiled-in literal".

**Risk:** low — comments and one output string.

**Area:** `docs/tournament`

**Depends-on:** `039-spectator-director-loop.md`

**Feasibility:** no build, no world.

---

## Not scoped here

**Artifacts 020–025 carry 18 further review findings** recorded in their
`**Minor findings:**` sections. Those PRs (#30–#32) are already merged, so the
findings are live on `cm-main` and none of them were triaged into this file. They
are mostly the same shapes covered above — swallowed exit statuses, a stale
run-directory guard, argument validation. Worth a triage pass before the next
drain, not worth blocking this one.

**The two transient failures of the 18 Aug run needed no fix and have none
pending.** A GitHub API error mid-response made the PR call return `null` for
`backlog/viewer-effect-queue` in batch `20260818-5`; batch `20260818-6` retried it
as PR #52 after confirming no duplicate existed. And the drain-skill defect where
ticks tested against the wrong image is already fixed in `d079a6c`.

**Never actually executed, by design:** `standup-1000.sh` (a real stand-up is
~2.5 h and edits the live conf) and `release-tag.sh` (it cuts a real tag). Both are
syntax- and stub-verified only. R-9 and R-4 are written so neither needs a full
real run to be verified.
