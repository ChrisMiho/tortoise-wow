# Handoff: run the first `backlog-batch` pass

Paste the section below to a fresh agent. It assumes no memory of the scoping or
pilot conversations.

**This is the second half of a supervised pilot, and the half that has never run
end to end in this environment.** The implement half is done and verified. What
is unproven is everything after it: Integrate, Build, Validate, push, and
`gh pr create`. Treat a failure here as information about the machinery, not as a
reason to edit the artifact or the code.

---

## Your task

Run one `backlog-batch` pass over every artifact in `docs/backlog/` that is at
`status: implemented`, then record the outcome. Work on branch
`feature/tournament-backlog-scope`.

**Do NOT run `backlog-drain`. Do NOT implement any more artifacts.** One batch
pass, then report.

## Verified current state (2026-08-16)

Confirm anything you doubt, but these were checked directly:

| Fact | Value |
|---|---|
| Branch | `feature/tournament-backlog-scope`, clean, pushed |
| Artifacts | 33 total, `013`–`045`. **One** at `status: implemented`: `013-tournament-team-definitions.md`. 32 `pending` |
| Implemented branch | `backlog/tournament-team-definitions`, local only, **not** on origin, one commit ahead of `origin/cm-main` |
| Docker images | `tortoise-cm:c06b2fb` (rollback anchor) and `mariadb:10.6`. Nothing else |
| Containers | `tcm-db` is **already running and healthy**. `mangosd`/`realmd` are down |
| `.env` | `TW_IMAGE=tortoise-cm:c06b2fb`; `TW_LOGS=/home/deck/tortoise-wow-server-V2/logs` |
| `gh` | authenticated as `ChrisMiho`, `repo` scope — push and PR creation work |
| Logs on disk | ~94 MB against a ~500 MB budget, rotation installed and running every 5 min |

If more artifacts have reached `status: implemented` by the time you run, **put
all of them in the same batch** — that is what a batch is for. The instructions
below are written for the general case.

## How to invoke it

Follow `.claude/skills/backlog-drain/SKILL.md`, section **"Running a batch"**.
Read that first; it is the contract. In short:

1. For each artifact at `status: implemented`, read back the `**Base:**`,
   `**Branch:**`, `**Summary:**`, `**In-game check:**` and (if present)
   `**Minor findings:**` / `**Contested:**` lines from its body. **Reassemble the
   batch entry from the file — do not retype these from anywhere else.** They are
   long and exact. `problem` and `acceptanceCriteria` come from the artifact's own
   `**Problem:**` and `**Acceptance criteria:**` sections.
2. Compute a `buildId` with a real shell date, e.g. `date +%Y%m%d` giving
   `20260816-1`. Sequence within the day so two batches cannot collide.
3. `Workflow({ name: "backlog-batch", args: { buildId, batch: [...] } })`, each
   entry being
   `{ artifactPath, branchName, baseBranch, dependsOnPrUrl, summary, problem, acceptanceCriteria, inGameCheck, minorFindings, contested, contestedFindings }`.
   For `013`: `baseBranch` is `cm-main` and `dependsOnPrUrl` is not needed —
   that field is only for an artifact stacked on another artifact's still-open PR.
   `minorFindings` is `[]` and `contested` is absent.

**A batch of one is expected here, not a bug.** The normal trigger is four
accumulated artifacts; a pilot runs below that deliberately.

## What the pass does, in order

Four phases, strictly sequential. Each depends on the one before it, and a
failure stops everything after it:

1. **Integrate** — cuts a scratch `integration/<buildId>` branch fresh from
   `origin/cm-main` and merges every artifact branch onto it. Never pushed; it
   exists only so one build can cover the whole batch.
2. **Build** — one Docker image, `tortoise-cm:<buildId>`, from the integration
   worktree. ~9.5 minutes. **One build for the entire batch, not one per
   artifact** — that is the whole reason batching exists.
3. **Validate** — brings the stack up once via `scripts/validate-stack.sh` and
   then attempts whatever each artifact's `**In-game check:**` says is
   scriptable. If the gate reports FAIL, no per-artifact check is attempted at
   all: a check that "passed" against an unverified image is worse than no check.
4. **PR** — pushes each artifact branch and opens one PR per artifact, in
   sequence. This is the only phase that touches origin.

**Merge order inside Integrate matters, and is not arbitrary:**

- **Dependency order first.** An artifact whose `baseBranch` is another
  artifact's `backlog/<slug>` (rather than `cm-main`) must be merged *after* that
  dependency, never before.
- **Then smallest diff first** among the independents, matching the "blast
  radius, smallest first" approach in
  `docs/superpowers/plans/2026-08-12-transport-stack-merge.md`. An early conflict
  or build failure is then far cheaper to attribute to a specific artifact.
- **A real conflict is a silent-revert trap, not routine text reconciliation** —
  each branch was cut before the others' changes existed. Resolve toward
  preserving both sides' intent. If that cannot be done without guessing which
  side is "correct", **do not guess**: abort that one artifact's merge, let the
  rest of the batch proceed, and list it in `excludedArtifacts` so it is retried
  in a later batch rather than silently shipped wrong.

**Which artifacts can even be in a batch.** An artifact with `depends-on:` was
only implementable if its dependency had already reached `status: done` — the
drain skips it otherwise. So in practice a batch holds independents, plus
artifacts stacked on a dependency whose PR is already open. You will not have to
resolve a dependency that is merely `implemented`; that combination cannot occur.

## The build will look like it did nothing. That is correct.

`013` adds only shell scripts and JSON under `config/` and `tests/`, and **both
of those directories are in `.dockerignore`**. No `CMakeLists.txt` references
either path. So the image this batch builds is behaviourally identical to the
anchor image, and `validate-stack.sh` comparing them will show no functional
difference.

**Do not chase that as a defect.** This pass is a test of the machinery — can it
integrate, build, validate, push and open a PR — not a test of the code. An agent
that "fixes" a working build because the image seems unchanged has broken the
only thing being measured.

## Environment rules. Each of these has already cost someone a session.

- **The build is ~9.5 minutes and must run in the FOREGROUND.** There is no
  incremental build: `COPY . /src` never cache-hits, so every build recompiles all
  ~1169 translation units regardless of what changed. Backgrounded, `nohup`'d or
  detached builds get killed and BuildKit cancels them, leaving no image and no
  error — just a truncated log. Do not report a build as "slow" or "hung" because
  it recompiles everything; that is normal.
- **Do not add ccache or any build-speed change.** It was implemented, measured
  (cold 9m07s / no-op 9m24s / one-file 9m05s, zero cache hits) and reverted.
- **The three provenance build args are mandatory** — `GIT_SHA`, `GIT_DIRTY`,
  `DOCKERFILE_SHA`, exactly as `scripts/rebuild.sh` passes them. Without them the
  image carries no provenance labels and `validate-stack.sh` can only ever return
  UNKNOWN. Check `GIT_SHA` is non-empty *before* starting a ten-minute compile.
- **`TW_SRC_DIR=<integration worktree>` is not optional for validation.** The gate
  compares the image's stamped revision against HEAD of whatever repo it reads git
  from, defaulting to the main checkout — a different commit. Without the override
  gate 1 reports DRIFT on every batch run and nothing downstream is validated.
- **Never `docker compose down -v`.** `tortoise-wow-v2_dbdata` is the entire
  world and has been lost once already. Plain `down` only.
- **`docker compose` needs `--env-file <main-checkout>/.env`** anywhere other than
  the main checkout; `.env` is gitignored and exists only there. Resolve the main
  checkout with `git worktree list` — the FIRST entry.
- **Run scripts from WSL, never Git Bash.** `jq` is not on Git Bash's `PATH` on
  this host and `require_cmd jq` is a hard `exit 1`, not a skip. MSYS also
  rewrites POSIX paths into `C:\` ones. `rebuild.sh` fails closed on `$MSYSTEM`
  for this reason.
- **Never put a shell variable inside a wrapped `wsl -d Ubuntu -- bash -lc '...'`
  one-liner.** It returns plausible-but-wrong output silently — during this
  session it reported an empty directory and a wrong `du` total in one command,
  and separately made a correct `exit 1` read as `EXIT=0`. Write a script file
  and invoke that file instead.
- **`wsg_mysql` sends stderr to `/dev/null`.** A failing query returns silence,
  which reads exactly like "no rows matched". Six consecutive queries failed that
  way during this session on an unknown-column error. If a query unexpectedly
  returns nothing, re-run it through a bare `docker exec ... mysql` with stderr
  visible before concluding anything.

## What success looks like

- Integrate produced an `integration/<buildId>` branch with the artifact branch
  merged, and excluded nothing.
- Build reported `built: true` with an `imageTag` of `tortoise-cm:<buildId>`.
- Validate's last stdout line was `VALIDATE-STACK: PASS`, reported verbatim.
- `git ls-remote --heads origin backlog/tournament-team-definitions` now finds the
  branch, where before the batch it found nothing.
- A real PR exists at the returned URL, against base `cm-main`.
- The artifact moved to `status: done` with
  `**Result:** PR opened at <url>, build <imageTag>.` appended.

Some of the artifact's `**In-game check:**` steps are scriptable and worth
attempting during Validate — the two test invocations and the negative
`namePrefix` check need no server at all, and the character-table queries need
only `tcm-db`, which is already up. Attempt what is genuinely scriptable and say
plainly what was not; do not claim a check you only assumed.

## After the batch

Follow "Running a batch" steps 4-7 exactly:

- **On success:** set each artifact with a `prUrl` to `status: done` and append
  the `**Result:**` line. Commit with subject `backlog: batch <buildId>`.
- **On failure:** this is a **batch-wide** failure, not a per-artifact one.
  **Leave every artifact at `status: implemented` — do not mark anything
  `failed`.** Report the reason and the full batch list so a human can decide
  whether to retry, exclude, or investigate.
- **Clean up the Integrate worktree and `integration/<buildId>` branch only after
  confirming its content is reachable elsewhere** (`git merge-base --is-ancestor`
  against `origin/cm-main` or a pushed `backlog/*` branch). If neither check
  passes, leave both in place and report their paths — deleting an unreachable
  commit loses the only copy of it.

## What not to do

- Do not run `backlog-drain` or start a loop.
- Do not implement, re-implement or edit any artifact's scope.
- Do not push anything except the artifact branches the batch pass itself pushes.
- Do not force-push, and do not delete any `backlog/*` branch.
- Do not change `.env`, and do not retag or delete the `tortoise-cm:c06b2fb`
  anchor image — it is the rollback path.

## Report back

1. Whether each phase — Integrate, Build, Validate, PR — actually succeeded, with
   the literal `VALIDATE-STACK:` line and the PR URL.
2. Anything that failed, quoted verbatim rather than summarised.
3. **Anything in `.claude/workflows/backlog-batch.js` or the drain skill that is
   wrong, stale, or would break at larger batch sizes.** This is the first real
   run of this path since PR-opening was split out of the implement tick, so
   defects in the harness are the expected finding — more valuable than a clean
   pass.
4. How long the build actually took, so the ~9.5 minute figure can be confirmed
   or corrected.

**One known unknown worth checking early:** `Workflow({ name: ... })` appeared to
resolve its script from a snapshot rather than re-reading
`.claude/workflows/` during the previous session — an edit committed before the
invocation was absent from the script that actually ran. When your batch
launches, the tool result names the saved script file; grep it against
`.claude/workflows/backlog-batch.js` to confirm they match before trusting the
run. If they differ, edit the saved script and re-invoke with
`{ scriptPath, resumeFromRunId }` rather than fighting it.
