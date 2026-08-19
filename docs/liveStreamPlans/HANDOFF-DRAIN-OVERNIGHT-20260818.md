# Handoff: the overnight drain pass

Everything is scoped and staged. This document says what to start, in what
order, and the one place the drain's own rule gives the wrong answer.

---

## Start with 055, not 047

`backlog-drain` picks the lowest-numbered `pending` artifact whose dependency is
ready. That is **047**. Override it for the first tick and run **055** instead.

**Why.** `scripts/tournament/gear-apply.sh` leaves 9 of 20 bots undressed —
`cannot_equip` per item — so `gear-audit.sh` reports `complete=5/10` and `6/10`
and `match-run.sh` **aborts before assembly**. No tournament match can run on
this host at all. Until 055 lands, every bot-AI fix from 046 onward ships with
its in-world acceptance criteria unverifiable, and the log-based criteria are
the only gate. 055's own dependency, `031-gear-tier-armour-weapon-split`, is
`done` and merged (PR #42), so it is ready to pick right now.

Run that one tick by hand:

```
Workflow({ name: "backlog-issue", args: {
  artifactPath: "C:/Coding/tortoise-wow/tortoise-wow/docs/backlog/055-gear-apply-cannot-equip-blocks-match-assembly.md",
  baseBranch: "cm-main" } })
```

After it lands and a batch has built it, verify the gate is really open before
trusting the rest — `gear-audit.sh` must report `complete=10/10` for both teams
with zero `cannot_equip` lines, and `match-run.sh` must reach
`tournament start`. Then let the drain resume its normal lowest-first order
from 047.

---

## What is already done

- **046** is `implemented` — the WSG standstill root cause. `BGTactics::Execute`
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

`055` (by hand) → `047 048 049 050 051 052 053 054` → `056 … 065` → `067 068`
once 046 is `done`. A batch fires every 4 implemented artifacts.

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
   times over. Once 055 opens the gate, a match that *verifies a code change* is
   the point — 046's criteria 3-5 need exactly one.
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
