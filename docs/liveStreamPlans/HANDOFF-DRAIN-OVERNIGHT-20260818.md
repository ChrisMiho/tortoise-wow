# Handoff: the overnight drain pass

Everything is scoped and staged. This document says what to start, in what
order, and the one place the drain's own rule gives the wrong answer.

---

## Start with 047 — the drain's own pick

**This section was rewritten after batch `20260818-8`. It originally said to
override the drain and run 055 first.** That was based on the gear gate being
the single thing blocking in-world verification. The batch's validation pass
proved otherwise — see
[the correction below](#correction-from-batch-20260818-8-055-is-not-the-only-thing-blocking-verification),
which is the authoritative account and worth reading before you start.

Short version: `wsg-kickoff.sh` does not go through `match-run.sh`, so the gear
gate never entered the picture. The real blocker is that **20 bots queue and no
WSG instance ever pops** — which is artifact **047**'s territory, and is also
what `backlog-drain` would pick on its own. So no override is needed for the
first tick.

055 is still necessary — it owns `gear-apply.sh` leaving 9 of 20 bots at
`cannot_equip`, which makes `gear-audit.sh` report `complete=5/10` and aborts
`match-run.sh` before assembly, blocking the tournament flow. Its dependency
`031-gear-tier-armour-weapon-split` is `done` and merged (PR #42), so it is
ready whenever the drain reaches it. It is simply not the first thing to fix.

---

## What is already done

- **046** is `done` — PR #59, build `tortoise-cm:20260818-8`, `VALIDATE-STACK: PASS`.
  The WSG standstill root cause. `BGTactics::Execute`
  called `ChangeStrategy("-buff")` every tick; `ChangeStrategy` ended in an
  unconditional `Init()`, `Init()` calls `Reset()`, and `Reset()` deleted every
  `ActionBasket` in the queue mid-way through `DoNextAction`'s walk — so the
  tick ended with `no actions executed` and `bg move to objective` (relevance
  1.0) was deleted before it could ever be popped. The fix adds
  `Engine::StrategySignature()` and re-inits only when the attached-strategy set
  actually changed. Branch `backlog/wsg-bots-never-execute-bg-move-to-objective`.
- **Batch `20260818-8`** was running against it at the time of writing — build,
  `validate-stack`, push, PR. Check its outcome before starting anything new; if
  it failed, that is a batch-wide failure and every artifact in it stays at
  `implemented`.
- **067 and 068** are newly scoped from 046's own review — see below.

---

## The two new artifacts, and why they are not optional

**067 — a strategy change from inside `Execute()` still drains the queue.**
`risk: high`. 046 removed the *trigger* but not the defect: `Init()` → `Reset()`
still deletes the queue while `DoNextAction` is mid-walk, and every call site
that genuinely changes the strategy set still hits it — the first BGTactics tick
after `STATUS_IN_PROGRESS`, `ResetStrategies` at
`BattleGroundTactics.cpp:2701`, `ChangeStrategy("-collision")`/`("-arena")` at
`:4879-4902`. It survives today only because `queue.Pop()` already transferred
ownership and the freed `basket` is never dereferenced — incidental, not safe.
One future edit that reads `basket->` after `Execute()` makes it a
use-after-free across ~1000 bots.

**068 — `StrategySignature()` rebuilds a string twice per call.** `risk: low`.
The new guard allocates on the same per-tick, per-bot path the queue rebuild
used to occupy. A `size()` early-out or a dirty flag does the same job for free.
Overlaps 067 — if 067 rewrites those functions first, check whether 068 reduces
to confirming that and closing it.

Both declare `depends-on: 046-...`, so neither is eligible until 046 reaches
`done`, which happens when its batch opens a PR.

---

## Order the drain will actually run

`047 048 049 050 051 052 053 054` → `055 056 … 065` → `067 068` once 046 is
`done` — straight lowest-first, no override. A batch fires every 4 implemented artifacts.

`058` is the one to watch: its dependency `045` is `done` but its branch is
**not** merged (PR #55 is deliberately held — the release-tag script can cut a
real annotated tag with no matching image). Verified: `git merge-base
--is-ancestor origin/backlog/release-tag-script-and-record origin/cm-main` exits
`1` cleanly, not an error, so the drain stacks 058's branch on that PR rather
than skipping it. **Do not delete that branch** — a missing branch makes that
command error instead of answer, and the tick cannot classify the dependency.

---

## Invariants that still hold overnight

1. **Never delete a `backlog/*` or `integration/*` branch on origin.** Expect 36
   or more from `git ls-remote --heads origin 'refs/heads/backlog/*' | wc -l`.
2. **Never run `scripts/release-tag.sh`** — defective, artifact 058.
3. **No `docker volume prune`, `docker system prune --volumes`, or Docker
   Desktop cleanup.** The world is the external volume `tortoise-wow-v2_dbdata`
   and has been lost once. `docker image prune -a` separately destroys
   `tortoise-cm:c06b2fb`, the rollback anchor.
4. **WSG matches are now for verification, not characterisation.** The earlier
   blanket ban existed to stop re-measuring a defect already measured three
   times over. A match that *verifies a code change* is the point — 046's
   criteria 3-5 need exactly one, and it cannot run until the queue funnel in
   047 is fixed.
5. **Builds run in the foreground**, `BUILD_JOBS=14`, `timeout: 600000`, verified
   with `docker images` and not the exit code. Backgrounded builds are silently
   cancelled by BuildKit.

---

## Stopping it

`touch docs/backlog/.stop` halts the drain after the current artifact finishes —
checked at the start of each tick, so it never aborts mid-implementation, and it
flushes any waiting batch first. The loop also stops itself on two consecutive
failures, a drained backlog, a dependency deadlock, a systemic failure, or a
failed batch build. All of them report before stopping.

---

## One thing to fix in the harness when convenient

`validate-stack`'s provenance gate compares the image's stamped revision against
`HEAD`, so running it from a branch with commits past the built image reports
DRIFT rather than PASS. That is correct behaviour, but it means the gate can
only be run from the commit the image was built at — worth an artifact if it
starts costing ticks.

---

## Correction from batch `20260818-8`: 055 is not the only thing blocking verification

The batch's validation pass tried to run 046's in-game check for real and could
not. **The gear gate was not what stopped it.** `wsg-kickoff.sh` does not go
through `match-run.sh`, so 055 was never in the way on that path.

What happened: all 20 bots queued — 90 `queued WSG` lines across all 20 distinct
`Wsg*` bots in the marked window — and **no instance was ever created**. Zero
references to map 489 or Warsong after the mark, and `bg.log` has had no new
line since 2026-08-18 09:18 host time. The queue formed and never popped.

Consequently every numeric criterion read zero for a trivial reason:
`A:move to objective - OK` = 0, `PUSH:bg move to objective` = 0,
`A:check flag` = 0, `S:-buff` = 0, AI ticks attributable to `Wsg*` bots = 0.
**These zeroes are not evidence against the fix.** The before-numbers in the
artifact (23,908 PUSHes, 98.8% empty ticks) come from a match that actually ran.
Treat 046's criteria 3-5 as *unrun*, not failed. `BG-AI-ANALYSIS.md` §4.2a says
so honestly rather than inventing after-numbers, which is the right state to
ship.

Two concrete blockers came out of it:

1. **The queue funnel — 20 queued, no pop.** Upstream of 046 and looks like the
   same territory as artifact **047**. This, not 055, is what has to be fixed
   before any WSG-based verification works.
2. **A stale `.wsg-mode-snapshot.json` dated 2026-08-10** made
   `wsg-mode.sh status` report `MODE: wsg-match` while the world was actually in
   alive-world mode, so `on` would have refused. `wsg-mode.sh on --force`
   re-took the snapshot from live values and got past it.

**Revised first pick:** 047 (the queue funnel) is now at least as good a first
tick as 055 — it is what unblocks in-world verification for 046 and everything
after it, and it is also what the drain would pick on its own. 055 remains
necessary for the `match-run.sh` assembly path and the tournament flow; it is no
longer the single gate it looked like.

**State the batch left behind:** all conf changes reverted
(`EnableActionLog` back to its commented default, `Tournament.TelemetryIntervalMs`
back to 0), `wsg-mode.sh off` run, stack brought down with a plain
`docker compose down` (never `-v`), `tortoise-wow-v2_dbdata` untouched. One
deliberate difference from how it was found: `wsg-mode.sh off` deleted the stale
snapshot, so the world is now in alive-world mode with **no** snapshot — the
correct clean state, but a change.
