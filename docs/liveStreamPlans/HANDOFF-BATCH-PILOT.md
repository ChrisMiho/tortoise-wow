# Handoff: finish the pilot and hand the backlog to the drain

Paste everything below the rule to a fresh agent. It assumes no memory of the
scoping or pilot conversations.

You are orchestrating five stages, in order. Stage 1 is the half of the pilot
that has never run end to end. Stage 2 is a safety check that has never run at
all. Stages 3-5 hand the remaining 32 artifacts to an unattended drain.

**Do not skip ahead. Stage 5 turns an agent loose for 7-10 hours with docker
access on a host whose database volume is the entire game world.**

---

## The five stages

| # | Stage | Roughly |
|---|---|---|
| 1 | Run the first `backlog-batch` pass | ~15 min |
| 2 | Verify the live-stack guardrails actually fire | ~20 min |
| 3 | PR the planning branch to `cm-main`, cut a fresh branch | ~5 min |
| 4 | Three or four supervised implement ticks | ~1 h |
| 5 | Start `/loop backlog-drain` and monitor | 7-10 h unattended |

## Verified current state (2026-08-16)

Confirm anything you doubt, but these were checked directly:

| Fact | Value |
|---|---|
| Branch | `feature/tournament-backlog-scope`, clean, pushed |
| Artifacts | 33, `013`–`045`. One at `status: implemented` (`013`), 32 `pending` |
| `013`'s branch | `backlog/tournament-team-definitions`, local only, **not** on origin, one commit ahead of `origin/cm-main` |
| Docker images | `tortoise-cm:c06b2fb` (rollback anchor) and `mariadb:10.6`. Nothing else |
| Containers | `tcm-db` **already running and healthy**. mangosd/realmd down |
| `.env` | `TW_IMAGE=tortoise-cm:c06b2fb`, `TW_LOGS=/home/deck/tortoise-wow-server-V2/logs` |
| `gh` | authenticated as `ChrisMiho`, `repo` scope |
| Logs on disk | ~94 MB against a ~500 MB budget, rotation running every 5 min |
| World | `tw_char` holds 4555 characters, 20 of them the tournament roster |

**Expected total once the drain runs:** 32 implement ticks, 9 batch passes, no
dependency deadlock — every artifact drains. Simulated against the real
dependency graph with the drain's own pick-lowest-eligible rule. One real tick
took 15.2 minutes, so budget 7-10 hours.

---

# Stage 1 — the first batch pass

Run one `backlog-batch` pass over every artifact at `status: implemented`. Follow
`.claude/skills/backlog-drain/SKILL.md`, section **"Running a batch"** — that is
the contract, read it first.

1. For each `implemented` artifact, read back the `**Base:**`, `**Branch:**`,
   `**Summary:**`, `**In-game check:**` and (if present) `**Minor findings:**` /
   `**Contested:**` lines from its body. **Reassemble from the file — do not
   retype.** They run to thousands of characters and go verbatim into the PR body.
   `problem` and `acceptanceCriteria` come from the artifact's own sections.
2. Compute a `buildId` with a real shell date, e.g. `20260816-1`. Sequence within
   the day so two batches cannot collide.
3. `Workflow({ name: "backlog-batch", args: { buildId, batch: [...] } })`, each
   entry `{ artifactPath, branchName, baseBranch, dependsOnPrUrl, summary,
   problem, acceptanceCriteria, inGameCheck, minorFindings, contested,
   contestedFindings }`. For `013`: `baseBranch` is `cm-main`, `dependsOnPrUrl`
   is not needed, `minorFindings` is `[]`, `contested` absent.

**A batch of one is expected, not a bug.** The normal trigger is four accumulated
artifacts; a pilot runs below that deliberately.

## What the pass does, in order

Four phases, strictly sequential; a failure stops everything after it.

1. **Integrate** — cuts a scratch `integration/<buildId>` branch from
   `origin/cm-main` and merges every artifact branch onto it. Never pushed.
2. **Build** — one image, `tortoise-cm:<buildId>`, ~9.5 min. **One build for the
   whole batch**, which is the entire reason batching exists.
3. **Validate** — brings the stack up once via `scripts/validate-stack.sh`, then
   attempts whatever each artifact's `**In-game check:**` says is scriptable. On
   a FAIL gate, no per-artifact check is attempted: a check that "passed" against
   an unverified image is worse than none.
4. **PR** — pushes each branch and opens one PR per artifact. The only phase that
   touches origin.

**Merge order inside Integrate is not arbitrary.** Dependency order first (an
artifact based on another's `backlog/<slug>` merges after it), then
smallest-diff-first among independents, so an early conflict is cheap to
attribute. **A conflict is a silent-revert trap**, not routine reconciliation —
each branch was cut before the others existed. Resolve toward preserving both
sides' intent; if that needs guessing, abort that one artifact's merge, let the
rest proceed, and list it in `excludedArtifacts`.

## The build will look like it did nothing. That is correct.

`013` adds only shell and JSON under `config/` and `tests/`, and **both are in
`.dockerignore`**. No `CMakeLists.txt` references either path. The image is
behaviourally identical to the anchor.

**Do not chase that as a defect.** This pass tests the machinery, not the code.
An agent that "fixes" a working build because the image seems unchanged has
destroyed the only thing being measured.

## Stage 1 succeeds when

- Integrate excluded nothing; Build returned `built: true` with
  `tortoise-cm:<buildId>`; Validate's last line was `VALIDATE-STACK: PASS`.
- `git ls-remote --heads origin backlog/tournament-team-definitions` now finds
  the branch, where before it found nothing.
- A real PR exists against base `cm-main`.
- `013` moved to `status: done` with `**Result:** PR opened at <url>, build
  <imageTag>.` appended, committed as `backlog: batch <buildId>`.

**On failure this is batch-wide, not per-artifact. Leave every artifact at
`status: implemented` — mark nothing `failed`** — report the reason verbatim and
stop. Clean up the Integrate worktree and `integration/<buildId>` branch only
after confirming reachability with `git merge-base --is-ancestor` against
`origin/cm-main` or a pushed `backlog/*` branch; if neither passes, leave both
and report their paths.

---

# Stage 2 — verify the live-stack guardrails

**Do this before Stage 5. It has never been exercised.**

`.claude/workflows/backlog-issue.js`'s Implement prompt grants agents permission
to start containers, query the database and send console commands — and carries
five prohibitions. **None has ever executed.** The pilot tick ran a snapshot of
the file taken before those edits, so the whole block is untested.

Why it matters: two of the prohibitions guard against unrecoverable damage.
`docker compose down -v` destroys `tortoise-wow-v2_dbdata`, which is the entire
world and has been lost once already. A bare `docker attach` reaching EOF shuts
the world down, because compose is `restart: "no"`.

## 2a. Back up the irreplaceable databases first

**`scripts/backup-alive-world-pre.sh` backs up CONFIG FILES ONLY.** It does not
touch the databases and is no protection against `down -v`. Run a real dump:

```bash
cd <repo>
. docs/playerbots/wsg/lib/wsg-bots-common.sh
mkdir -p ~/tortoise-wow-server-V2/backups
docker exec -e MYSQL_PWD="$(wsg_db_pass)" tcm-db \
  mysqldump -uroot --single-transaction --databases tw_char tw_logon \
  > ~/tortoise-wow-server-V2/backups/pre-drain-$(date +%Y%m%d-%H%M%S).sql
```

`tw_char` and `tw_logon` are the irreplaceable ones — 4555 characters and the
accounts. `tw_world` is reconstructible from `sql/base/` in the repo, so skip it
if the dump is unwieldy. Confirm the file is non-empty before continuing.

## 2b. Presence — is the prompt actually in the script that runs?

When any tick launches, the `Workflow` tool result names a **saved script file**.
Grep that file, not the repo copy:

```bash
grep -c "THE LIVE STACK IS AVAILABLE TO YOU" "<the saved script path>"
```

Expect `1`. **If it is `0`, stop.** `Workflow({name: ...})` resolved a stale
snapshot, the agent has docker access with none of the prohibitions, and the
drain must not run. The fix is to invoke with
`{ scriptPath: ".claude/workflows/backlog-issue.js" }` explicitly, or edit the
saved script and re-invoke with `{ scriptPath, resumeFromRunId }`.

## 2c. Behaviour — watch a tick that genuinely needs the database

After Stage 1, `014-tournament-roster-lifecycle` becomes eligible and is what the
drain picks next. It is the right test: one of its acceptance criteria requires
running `roster.sh status` against the live database, so the agent **must** use
live access to satisfy it.

Run that tick and then grep the transcript for forbidden actions. The tool result
names a transcript dir containing `agent-*.jsonl`:

```bash
grep -l -E 'down -v|down --volumes|docker attach|docker build' <transcriptDir>/agent-*.jsonl
```

**Expect no output.** Any hit is a guardrail failure — read the surrounding
context before drawing a conclusion, since a mention in reasoning is not the same
as an executed command, but treat it as a stop-and-investigate either way.

Positive signals in the same transcript: the agent brought up **only** the `db`
service, resolved the main checkout for `--env-file`, and ran its tests through
WSL rather than Git Bash.

## 2d. The volume still exists

After **every** supervised tick, one line:

```bash
docker volume ls --format '{{.Name}}' | grep -x tortoise-wow-v2_dbdata
```

Expect the name. Silence means the world is gone — restore from 2a immediately
and do not continue.

---

# Stage 3 — PR the planning branch, cut a fresh one

Once Stage 1 and 2 pass, put the planning work on the trunk so the backlog and
the work it describes live in the same place.

1. Open a PR from `feature/tournament-backlog-scope` to `cm-main`. It is
   docs-only plus `.claude/`: the 33 artifacts, the `cap-logs.sh` fix, the
   `backlog-issue.js` prompt fixes, and these handoffs.
2. **It will not conflict with `013`'s PR.** `013`'s branch touches only
   `config/`, `scripts/`, `tests/`; this branch touches only `docs/` and
   `.claude/`. No overlap.
3. After it merges, cut a fresh branch from `origin/cm-main` for the drain run.
   The drain reads `docs/backlog/*.md` from the checked-out branch and commits
   status changes there, so a fresh branch keeps the drain's bookkeeping churn
   separate from the planning history.

---

# Stage 4 — three or four supervised ticks

From the fresh branch, run individual ticks by hand and watch them. Do **not**
start the loop yet.

For each: follow `backlog-drain`'s "One tick" — set the artifact to
`in-progress`, invoke `Workflow({ name: "backlog-issue", args: { artifactPath:
"<absolute path>", baseBranch: "<cm-main, or the dependency's backlog/<slug> if
its PR is unmerged>" } })`, then record the outcome per step 8, remove the
Implement worktree but keep the branch (step 9), sweep `worktree-wf_*` scaffold
branches (step 9a), and commit `backlog: mark <name> implemented`.

Watch for four things:

1. **`blocked` outcomes.** A false block already happened once: a review lens
   found its dimension irrelevant to a shell/JSON diff and used `blocked: true`,
   which means "this artifact's criteria are unsatisfiable in this environment"
   and halts the work. That is fixed, but **`blocked` deliberately does not count
   toward the two-consecutive-failure circuit breaker** — so a new blocking cause
   would march through the whole backlog overnight without ever stopping. Any
   `blocked` in these ticks deserves investigation before Stage 5.
2. **Per-artifact builds.** A ~10 minute gap in a tick means the no-build rule
   did not take. The batch pass builds; a tick must not.
3. **Git Bash instead of WSL.** `jq` is absent from Git Bash here and
   `require_cmd jq` is a hard `exit 1`, so a Git Bash run fails for reasons
   unrelated to the code.
4. **Confident but wrong claims.** The pilot's agent reported a citation
   correction that was itself partly wrong, naming a file path that does not
   exist. Spot-check anything an agent asserts about the codebase rather than
   accepting it — the drain will produce a great many such reports with nobody
   reading them.

---

# Stage 5 — start the drain

Only after Stages 1-4. Then `/loop backlog-drain`.

- **`docs/backlog/.stop`** (an empty file) halts the loop at the start of the
  next tick. Whatever is in flight finishes, and any waiting batch is flushed
  first so nothing is stranded. It works whether or not anyone is watching the
  conversation — this is the lever to reach for at 3am.
- The loop also stops by itself on: a drained backlog, two consecutive failures,
  every remaining artifact blocked on an unready dependency, a systemic failure,
  or a batch-wide build break.
- Expect **32 ticks, 9 batch passes, 7-10 hours**. Nine builds rather than eight
  because dependency chains force a few partial flushes.
- Check `docker volume ls` for `tortoise-wow-v2_dbdata` when you next look in.

---

# Environment rules. Each has already cost someone a session.

- **Builds run in the FOREGROUND, ~9.5 minutes, every time.** No incremental
  build: `COPY . /src` never cache-hits, so all ~1169 translation units recompile
  regardless of what changed. Backgrounded, `nohup`'d or detached builds get
  killed and BuildKit cancels them, leaving no image and no error. Do not report
  a build as "hung" for recompiling everything; that is normal.
- **Do not add ccache or any build-speed change.** Measured (cold 9m07s / no-op
  9m24s / one-file 9m05s, zero cache hits) and reverted.
- **The three provenance build args are mandatory** — `GIT_SHA`, `GIT_DIRTY`,
  `DOCKERFILE_SHA`, exactly as `scripts/rebuild.sh` passes them. Without them
  `validate-stack.sh` can only return UNKNOWN. Check `GIT_SHA` is non-empty
  *before* a ten-minute compile.
- **`TW_SRC_DIR=<integration worktree>` is not optional for validation.** The gate
  compares the image's stamped revision against HEAD of whatever repo it reads git
  from, defaulting to the main checkout — a different commit. Without it gate 1
  reports DRIFT every run and nothing downstream is validated.
- **Never `docker compose down -v`.** Plain `down` only.
- **`docker compose` needs `--env-file <main-checkout>/.env`** anywhere but the
  main checkout; `.env` is gitignored and exists only there. Resolve it with
  `git worktree list` — the FIRST entry.
- **Run scripts from WSL, never Git Bash.** MSYS rewrites POSIX paths into `C:\`
  ones; `rebuild.sh` fails closed on `$MSYSTEM` for that reason.
- **Prefix `wsl` calls from Git Bash with `MSYS_NO_PATHCONV=1`.** MSYS rewrites
  any *standalone* argument beginning with `/` into `C:/Program Files/Git/...`
  (that is the MSYS root — check with `cd / && pwd -W`), so
  `wsl -d Ubuntu -- bash /mnt/c/foo.sh` fails with `No such file or directory`
  naming a path you never typed. Verified on this host 2026-08-16. A path
  *inside* a longer argument — `bash -lc 'cd /mnt/c/... && ...'`, the form every
  artifact's in-game checklist uses — is **not** rewritten and works as written.
  This is the same MSYS conversion that mangles `git <rev>:<path>` arguments.
- **Never put a shell variable inside a wrapped `wsl -d Ubuntu -- bash -lc '...'`
  one-liner.** It returns plausible-but-wrong output silently — during scoping it
  reported an empty directory and a wrong `du` total in one command, and
  separately made a correct `exit 1` read as `EXIT=0`. Write a script file and
  invoke that.
- **`wsg_mysql` sends stderr to `/dev/null`.** A failing query returns silence,
  indistinguishable from "no rows matched" — six consecutive queries failed that
  way on an unknown-column error. Re-run through a bare `docker exec ... mysql`
  with stderr visible before concluding anything from an empty result.
- **`tw_world.item_template` is snake_case** on this server: `inventory_type`,
  `quality`, `item_level`, `required_level`, `allowable_class`. The CamelCase
  names in the plans all fail with `Unknown column`.

# What not to do

- Do not skip Stage 2. It is the only thing standing between an unattended agent
  and the game world.
- Do not implement, re-implement or edit any artifact's scope.
- Do not force-push, and do not delete any `backlog/*` branch.
- Do not change `.env`, and do not retag or delete `tortoise-cm:c06b2fb` — it is
  the rollback path.

# Report back

1. Whether each Stage 1 phase succeeded, with the literal `VALIDATE-STACK:` line
   and the PR URL.
2. **Stage 2's result explicitly** — the grep counts, whether any forbidden
   command appeared in a transcript, and that the volume still exists.
3. Anything that failed, quoted verbatim rather than summarised.
4. **Anything in `backlog-batch.js`, `backlog-issue.js` or the drain skill that is
   wrong, stale, or would break at larger batch sizes.** This is the first real
   run of this path since PR-opening was split out of the implement tick, so
   harness defects are the expected finding — more valuable than a clean pass.
5. How long the build actually took, so the ~9.5 minute figure can be confirmed.
