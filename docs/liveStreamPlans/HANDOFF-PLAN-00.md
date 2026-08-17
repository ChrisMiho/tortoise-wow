# Handoff: implement Plan 00 (build provenance & stack validation gate)

Paste the section below to a fresh agent. It assumes no memory of the planning
conversation.

This is the **supervised pilot** for the tournament plan series — the first real
exercise of the workflow, with a human watching. Plan 00 is the right candidate:
pure infrastructure, no live-match dependency, and everything else depends on it.

---

## Your task

Implement `docs/superpowers/plans/2026-08-16-00-build-provenance-gate.md`
task by task, in order, on branch `feature/bot-tournament-plans`.

**Use the `superpowers:executing-plans` skill.** A human is watching this run —
stop at each checkpoint rather than batching through.

**What this plan achieves:** right now nothing can prove the server it validated
against was built from this repository. `.claude/workflows/backlog-batch.js` builds
with a plain `docker build` and passes no provenance build args, so batch-built
images carry no labels and `scripts/verify-running-commit.sh` can only ever return
`UNKNOWN`. Plan 00 closes that, and adds `scripts/validate-stack.sh` — one command
that brings a named image up and refuses to report success unless provenance,
image identity, and real liveness all pass.

**Read before starting:**

1. The plan itself, whole, before touching anything.
2. `docs/DOCKER.md` — how the stack builds and runs.
3. `scripts/lib/provenance.sh` and `scripts/verify-running-commit.sh` — you are
   extending both.

---

## Step 0 — before Task 1

```bash
sudo apt-get update && sudo apt-get install -y jq   # NOT currently installed
jq --version
docker info >/dev/null && echo "docker ok"
git rev-parse --abbrev-ref HEAD                     # expect feature/bot-tournament-plans
```

`jq` is not used by Plan 00 itself, but it is a hard prerequisite for Plans 01,
03, 04 and 06, and Plan 00 Task 1 Step 0 installs it. Do it now.

---

## Environment rules — violating any of these has already cost real time here

- **Run everything from WSL, never Git Bash.** `scripts/rebuild.sh` fails closed on
  `$MSYSTEM` because MSYS path rewriting once made all five acceptance checks
  report FAIL on a perfectly good image, after a full 40-minute compile.
- **Never `docker compose down -v`.** `tortoise-wow-v2_dbdata` is the entire world.
  Plain `down` only.
- **`docker compose` needs `--env-file`** if you are anywhere other than the main
  checkout. `.env` is gitignored and exists only there; `docker-compose.yml` opens
  with `${DB_PASS:?set DB_PASS in .env}` and dies instantly without it.
- **Always pass `TW_IMAGE` explicitly.** It defaults to `tortoise-cm:local`, so
  omitting it silently starts a stale image and every conclusion after that is
  about the wrong binary.
- **Git Bash mangles `rev:path` arguments.** `git cat-file -e <rev>:<path>` returns
  silent false negatives. Use `git ls-tree -r --name-only <ref> -- <path>`, or
  prefix with `MSYS_NO_PATHCONV=1`.
- **Commit after every task, as the plan says.** Do not batch nine tasks into one
  commit at the end — an interruption then costs all nine.

---

## Task-by-task notes

The plan is self-contained; these are the things worth knowing before you hit them.

### Tasks 1-2 — test harness and provenance helpers

Fast, pure shell, no stack needed. Two things to get right:

- `require_cmd` in `assert.sh` must **hard-fail**, not skip. A test file that skips
  itself prints no failures, exits 0, and is indistinguishable from one that ran and
  passed — an automated run then reports green on work it never did. That is
  precisely the bug this helper exists to prevent, so do not "improve" it into a
  skip.
- Task 2 adds `TW_DB="${TW_DB:-tcm-db}"` alongside the other overridable defaults
  in `provenance.sh`. Easy to miss; the new helpers reference it.

### Task 3 — `validate-stack.sh`

**Step 5 runs it against the real stack, and it may legitimately FAIL.**

A `FAIL` here is a finding about the current server, not a bug in your script. The
image running right now may well have been built before provenance stamping, or
from a different checkout — `tortoise-v2:baseline` and `:elevator-fix` were built
on this machine by a different tree on 2026-08-14, carrying no labels at all.

Record the literal output either way. If it reports `FOREIGN` or `UNKNOWN`, say so
plainly and continue — do not "fix" it by loosening the gate.

### Tasks 4-6 — `.claude/workflows/backlog-batch.js`

**These changes will not affect the run that implements them.** The workflow that
executes is the one in the session's `.claude/`, not the one on your branch, so
Tasks 4-6 improve *future* batch passes. Do not expect to see `validate-stack.sh`
being invoked during your own run, and do not treat its absence as a failure.

Verify by inspection and `node --check`, exactly as the plan says.

Task 4 Step 2 pastes text containing `\${DB_PASS...}`. **The backslash is
load-bearing** — that text lives inside a JS template literal, and an unescaped
`${` is interpolated and throws a `ReferenceError` at parse time. `node --check`
catches it; run it.

### Task 5 — the one real build

Step 3 needs a genuine `docker build`, ~9-10 minutes. Pass the three provenance
build args exactly as written and **do not pass `--build-arg BUILD_JOBS`** — the
Dockerfile default of 10 is correct for this host (16 CPU / 24 GB VM). Only lower
it to 4 if the build OOMs.

The point of the step is reaching a **definite** verdict from `validate-stack.sh`
— `PASS`, or an explicit `DRIFT`/`IDENTITY`/`LIVENESS`. **`UNKNOWN` means the task
failed**, because `UNKNOWN` is exactly the state Plan 00 exists to eliminate.

Remove `tortoise-cm:provtest` when done.

### Task 8 — `.dockerignore`

Required, and it must land before Plan 01 creates `config/`. Use the throwaway
`FROM scratch` Dockerfile the plan specifies to measure context size — building the
real Dockerfile would spend ten minutes compiling to answer a question about bytes.

Check `.dockerignore` is back to its fixed state before committing; the measurement
temporarily comments a line out.

### Task 9 — ccache (optional)

**Decide before you start Task 9, not during.** It changes `DOCKERFILE_SHA`, so
every image built earlier reports a Dockerfile-drift warning afterwards. Either do
it now or skip it entirely — do not retrofit it later in the series.

It costs three builds (~30 min): cold, no-op, one-file-change. **Judge it on the
third number.** If a one-file change still takes close to the ~9.5 min baseline,
revert the Dockerfile change rather than keeping a complication that buys nothing.
Report the measured numbers either way — "it should be faster" is not a result.

---

## Verification standard

`superpowers:verification-before-completion` applies: evidence before assertions.

- Never write "tests pass" without pasting the actual `N passed, 0 failed` line.
- Never write "the gate works" without pasting the `VALIDATE-STACK:` line.
- If a step fails, report the real output. A `FAIL` from `validate-stack.sh` against
  the current server is a genuine finding worth having, and hiding it defeats the
  entire point of the plan.

## Done when

All of the plan's "Done when" bullets are satisfied, specifically:

- `bash tests/lib/assert.selftest.sh`, `bash tests/provenance.test.sh`, and
  `bash tests/validate-stack.test.sh` each exit 0, with their tallies pasted.
- `./scripts/validate-stack.sh --image tortoise-cm:local` reaches a **definite**
  verdict — never `UNKNOWN`.
- A hand-run build produces an image whose `org.opencontainers.image.revision`
  label is a real short SHA.
- `node --check .claude/workflows/backlog-batch.js` exits 0, and the file builds
  into `tortoise-cm:` and passes `--env-file` on both `up` and `down`.
- `.dockerignore` excludes `config/`, `tests/` and `logs/`, proven by the
  before/after context measurement.
- `docs/DOCKER.md` documents the gate.

## What not to do

- Do not implement any other plan in the series.
- Do not loosen a gate to make it pass. `FOREIGN`, `DRIFT` and `UNKNOWN` are
  answers, not obstacles.
- Do not merge or delete the `memory/baseline-measurement` branch.
- Do not run `docker compose down -v`, ever.

## Hand back

Report: each task's status, the literal `VALIDATE-STACK:` verdict against the
current stack, whether you did Task 9 and its three timings, and anything the plan
told you to do that turned out not to match reality — that last one matters most.
None of this plan's code has ever been executed, so a step whose expected output
does not appear is useful information, not a failure to hide.
