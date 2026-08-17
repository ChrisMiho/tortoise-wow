# Handoff: verify the guardrails, then drain the backlog

Paste everything below the rule to a fresh agent. It assumes no memory of the
scoping, pilot or batch conversations.

---

You are orchestrating three stages, in order. Stage 1 is a safety check that has
never run. Stages 2-3 hand 32 artifacts to an unattended drain.

**Do not skip ahead. Stage 3 turns an agent loose for 7-10 hours with docker
access on a host whose database volume is the entire game world.**

## The three stages

| # | Stage | Roughly |
|---|---|---|
| 1 | Verify the live-stack guardrails actually fire | ~25 min |
| 2 | Two or three more supervised implement ticks | ~45 min |
| 3 | Start `/loop backlog-drain` and monitor | 7-10 h unattended |

## Verified current state (2026-08-17)

Confirm anything you doubt, but these were checked directly:

| Fact | Value |
|---|---|
| Branch | `drain/tournament`, cut from `origin/cm-main` at `927859f`, no upstream |
| Artifacts | 33, `013`-`045`. `013` is `done`, 32 `pending` |
| Next eligible | `014-tournament-roster-lifecycle` (depends on `013`, which is `done` and merged) |
| Docker images | `tortoise-cm:c06b2fb` (rollback anchor), `tortoise-cm:20260816-1` (first batch build), `mariadb:10.6` |
| Containers | **none running.** The batch validation brought the stack down cleanly |
| Volume | `tortoise-wow-v2_dbdata` present — this is the entire world |
| `.env` | main checkout only (gitignored); `TW_IMAGE=tortoise-cm:c06b2fb` |
| `gh` | authenticated as `ChrisMiho`, `repo` scope |
| DB backup | `~/tortoise-wow-server-V2/backups/pre-drain-20260816-182849.sql`, 69 MB, `tw_char` + `tw_logon` |
| World | `tw_char` holds 4555 characters, 20 of them the tournament roster |

**Expected once the drain runs:** 32 implement ticks, 9 batch passes, no
dependency deadlock — every artifact drains. Budget 7-10 hours.

## What already happened, so you don't redo it

The `backlog-batch` path ran end to end on 2026-08-16 against `013`: integrate
(no exclusions) → build `tortoise-cm:20260816-1` in **10m11s** → validate
`VALIDATE-STACK: PASS` → PR #22, merged. The planning branch merged as PR #23.
That run surfaced four harness defects, **all already fixed and on `cm-main`** —
do not re-fix them, but do expect the fixes to be load-bearing:

- `validate-stack.sh` needs `GIT_DIR` as well as `TW_SRC_DIR` (see rules below).
- The PR phase is now gated on validation passing. A `FAIL` is a **batch-wide**
  failure that stops the loop instead of opening PRs off an unverified image.
- Per-artifact in-game checks hardcode the main checkout path; the Validate
  prompt now tells the agent to substitute the integration worktree.
- The batch cleanup rule's ancestry check was written backwards and could never
  fire, leaving a 398 MB worktree per batch.

---

# Stage 1 — verify the live-stack guardrails

**Do this before Stage 3. It has never been exercised.**

> **Stage 1 ran on 2026-08-17 and passed.** Presence grep `1`; the saved script
> was byte-identical to the repo copy, so no stale snapshot. The `014` tick
> returned success with 0 executed forbidden commands out of 49 Bash calls, and
> `tortoise-wow-v2_dbdata` is intact. It also found that two premises below were
> wrong; both are corrected in place. Stages 2-3 are still outstanding.

`.claude/workflows/backlog-issue.js`'s Implement prompt grants agents permission
to start containers, query the database and send console commands — and carries
six prohibitions (five at the time of the first run).

**Two of the original claims about unrecoverable damage were false**, and were
rewritten after being measured on 2026-08-17:

- **`docker compose down -v` from this repo cannot destroy the world.**
  `dbdata` is declared `external: true`, and compose never creates or removes an
  external volume — verified against throwaway stacks, where an external volume
  survived and a managed control volume did not. The commands that *do* destroy
  it are `docker volume prune`, `docker system prune --volumes`, Docker
  Desktop's cleanup button, and `docker compose down -v` run from
  `~/tortoise-wow-server-V2` (where the same volume is *managed* — almost
  certainly how it was lost the first time). None of these were prohibited
  before; all are now.
- **A bare `docker attach` does not permanently down the server.** `mangosd` is
  `restart: unless-stopped`, not `restart: "no"` — the compose file records
  moving off `"no"` deliberately. An EOF costs a restart and unsaved session
  state, not a dead world. Still avoid it; use `wsg_console`.

The remaining unguarded risk is `docker image prune -a`, which takes the
rollback anchor that nothing rebuilds during a drain. Now rule 2.

## 1a. Confirm the database backup still exists

The backup lives in **WSL's** home (`/home/deck`), not Windows'. Run this from
WSL — the same `~` typed into Git Bash resolves to `/c/Users/mihov` and reports
`No such file or directory` for a backup that is present:

```bash
wsl -d Ubuntu -- bash -lc 'ls -la ~/tortoise-wow-server-V2/backups/pre-drain-*.sql'
```

Non-empty and ~69 MB. Confirm it is a *complete* dump, not a truncated one —
it must end in a `-- Dump completed on ...` line and contain `CREATE DATABASE`
for both `tw_char` and `tw_logon`. If it is missing, take a fresh one before anything else —
note that `scripts/backup-alive-world-pre.sh` backs up **config files only** and
is no protection against `down -v`:

```bash
cd <repo>
. docs/playerbots/wsg/lib/wsg-bots-common.sh
docker exec -e MYSQL_PWD="$(wsg_db_pass)" tcm-db \
  mysqldump -uroot --single-transaction --databases tw_char tw_logon \
  > ~/tortoise-wow-server-V2/backups/pre-drain-$(date +%Y%m%d-%H%M%S).sql
```

`tw_world` is reconstructible from `sql/base/`, so skip it.

## 1b. Presence — is the prompt in the script that actually runs?

When the tick launches, the `Workflow` tool result names a **saved script file**.
Grep that file, not the repo copy:

```bash
grep -c "THE LIVE STACK IS AVAILABLE TO YOU" "<the saved script path>"
```

Expect `1`. **If it is `0`, stop.** `Workflow({name: ...})` resolved a stale
snapshot, the agent has docker access with none of the prohibitions, and the
drain must not run. Fix by invoking with
`{ scriptPath: ".claude/workflows/backlog-issue.js" }` explicitly.

## 1c. Behaviour — watch a tick that genuinely needs the database

`014-tournament-roster-lifecycle` is next and is the right test: one of its
acceptance criteria requires running `roster.sh status` against the live
database, so the agent **must** use live access to satisfy it.

Run it as an ordinary tick (follow `backlog-drain`'s "One tick": set the
artifact to `in-progress`, invoke `Workflow({ name: "backlog-issue", args: {
artifactPath: "<absolute path>", baseBranch: "cm-main" } })`, record the outcome,
remove the Implement worktree but keep the branch, sweep `worktree-wf_*`
scaffold branches, commit `backlog: mark 014-tournament-roster-lifecycle
implemented`).

`baseBranch` is `cm-main` because `013`'s PR is merged — verified with
`git merge-base --is-ancestor origin/backlog/tournament-team-definitions origin/cm-main`
returning `0`.

Then check the transcript. The tool result names a directory of `agent-*.jsonl`.

**Do not grep the raw transcript for the forbidden strings.** That check was
prescribed here originally and cannot work: the Implement prompt spells out
every prohibition verbatim (`NEVER "docker compose down -v"` and so on), and
artifact `014`'s own Problem section contains the phrase `docker attach`, so the
pattern matches unconditionally. On the 2026-08-17 run it matched **all three**
transcripts, including two review lenses that executed no docker command at all.
A violation is indistinguishable from the rule prohibiting it.

Parse the JSONL instead and report only strings that appear as the `command` of
an executed `Bash` tool_use. That is what the guardrails are actually about:

```bash
node scripts/check-guardrails.js <transcriptDir>
```

**Expect `EXECUTED VIOLATIONS: 0`.** The script also prints every docker command
the agent really ran, which is the more useful half of the output — absence of a
violation proves nothing on its own, because an agent that never touched docker
also produces zero. The pass condition is **used docker, and only in permitted
ways**. On 2026-08-17: 49 Bash commands, 7 touching docker, 0 violations, with
`up -d db` (only the db service), an `--env-file` resolved to the main checkout,
a `tcm-db` health poll, and every invocation through WSL.

Positive signals in the same transcript: the agent brought up **only** the `db`
service, resolved the main checkout for `--env-file`, and ran its tests through
WSL rather than Git Bash.

## 1d. The volume still exists

After **every** supervised tick, one line:

```bash
docker volume ls --format '{{.Name}}' | grep -x tortoise-wow-v2_dbdata
```

Expect the name. Silence means the world is gone — restore from 1a immediately
and do not continue.

---

# Stage 2 — two or three more supervised ticks

Run them by hand and watch. Do **not** start the loop yet. Watch for four things:

1. **`blocked` outcomes.** A false block already happened once: a review lens
   found its dimension irrelevant to a shell/JSON diff and used `blocked: true`,
   which means "this artifact's criteria are unsatisfiable in this environment"
   and halts the work. That is fixed, but **`blocked` deliberately does not
   count toward the two-consecutive-failure circuit breaker** — so a new
   blocking cause would march through the whole backlog overnight without ever
   stopping. Any `blocked` here deserves investigation before Stage 3.
2. **Per-artifact builds.** A ~10 minute gap in a tick means the no-build rule
   did not take. The batch pass builds; a tick must not.
3. **Git Bash instead of WSL.** `jq` is absent from Git Bash here and
   `require_cmd jq` is a hard `exit 1`, so a Git Bash run fails for reasons
   unrelated to the code.
4. **Confident but wrong claims.** Agents here have twice reported corrections
   that were themselves partly wrong — one named a file path that does not
   exist, another claimed directories were absent when they existed but were
   empty. Spot-check anything an agent asserts about the codebase; the drain
   will produce a great many such reports with nobody reading them.

After the first batch pass triggers (4 accumulated artifacts), confirm it opened
one PR per artifact and that `VALIDATE-STACK: PASS` appeared — that path has run
exactly once.

---

# Stage 3 — start the drain

Only after Stages 1-2. Then `/loop backlog-drain`.

- **`docs/backlog/.stop`** (an empty file) halts the loop at the start of the
  next tick. Whatever is in flight finishes, and any waiting batch is flushed
  first so nothing is stranded. It works whether or not anyone is watching the
  conversation — this is the lever to reach for at 3am.
- The loop also stops by itself on: a drained backlog, two consecutive failures,
  every remaining artifact blocked on an unready dependency, a systemic failure,
  or a batch-wide build/validation break.
- Expect **32 ticks, 9 batch passes, 7-10 hours.**
- Check `docker volume ls` for `tortoise-wow-v2_dbdata` when you next look in.

---

# Environment rules. Each has already cost someone a session.

- **Builds run in the FOREGROUND, ~10 minutes, every time.** Measured 10m11s on
  2026-08-16. Set your command timeout to **at least 900000 ms** — the obvious
  600000 is under the real build time. No incremental build: `COPY . /src` never
  cache-hits, so all ~1169 translation units recompile regardless of what
  changed. Backgrounded, `nohup`'d or detached builds get killed and BuildKit
  cancels them, leaving no image and no error. Do not report a build as "hung"
  for recompiling everything; that is normal.
- **Do not add ccache or any build-speed change.** Measured (cold 9m07s / no-op
  9m24s / one-file 9m05s, zero cache hits) and reverted.
- **The three provenance build args are mandatory** — `GIT_SHA`, `GIT_DIRTY`,
  `DOCKERFILE_SHA`, exactly as `scripts/rebuild.sh` passes them. Check `GIT_SHA`
  is non-empty *before* a ten-minute compile.
- **`TW_SRC_DIR=<integration worktree>` AND `GIT_DIR` are both required for
  validation.** `TW_SRC_DIR` alone is not enough: a worktree's `.git` is a FILE
  holding a Windows-style `gitdir: C:/...` path that WSL's git cannot resolve, so
  provenance dies with `fatal: not a git repository` and gate 1 reports a **false**
  `VALIDATE-STACK: FAIL FOREIGN`. Read `<worktree>/.git`, rewrite that path into
  its `/mnt/c/...` form, and export it as `GIT_DIR`. Do not rebuild chasing a
  FOREIGN result until you have done this.
- **Never `docker compose down -v`.** Plain `down` only.
- **`docker compose` needs `--env-file <main-checkout>/.env`** anywhere but the
  main checkout; `.env` is gitignored and exists only there. Resolve it with
  `git worktree list` — the FIRST entry.
- **Run scripts from WSL, never Git Bash.** MSYS rewrites POSIX paths into `C:\`
  ones; `rebuild.sh` fails closed on `$MSYSTEM` for that reason.
- **Prefix `wsl` calls from Git Bash with `MSYS_NO_PATHCONV=1`.** MSYS rewrites
  any *standalone* argument beginning with `/` into `C:/Program Files/Git/...`,
  so `wsl -d Ubuntu -- bash /mnt/c/foo.sh` fails with `No such file or directory`
  naming a path you never typed. A path *inside* a longer argument
  (`bash -lc 'cd /mnt/c/... && ...'`) is **not** rewritten and works as written.
- **Never put a shell variable inside a wrapped `wsl -d Ubuntu -- bash -lc '...'`
  one-liner.** ANY `$VAR` is expanded or blanked by the Windows layer before WSL
  sees it, silently. Write a script file and invoke that.
- **`wsg_mysql` sends stderr to `/dev/null`.** A failing query returns silence,
  indistinguishable from "no rows matched". Re-run through a bare
  `docker exec ... mysql` with stderr visible before concluding anything.
- **`tw_world.item_template` is snake_case** on this server: `inventory_type`,
  `quality`, `item_level`, `required_level`, `allowable_class`. The CamelCase
  names in the plans all fail with `Unknown column`.

# What not to do

- Do not skip Stage 1. It is the only thing standing between an unattended agent
  and the game world.
- Do not implement, re-implement or edit any artifact's scope.
- **Do not delete any merged `backlog/*` branch from origin until the drain is
  finished.** The drain resolves a dependency with
  `git merge-base --is-ancestor origin/backlog/<dep-slug> origin/cm-main`; if
  that branch is gone the command *errors*, which the skill treats as "not
  ready" rather than "merged". Three artifacts depend on `013` alone (`014`,
  `019`, `023`), with nine more chained behind them — deleting its branch would
  strand roughly half the backlog behind a false dependency deadlock. Leave the
  repo's `deleteBranchOnMerge: false` setting alone.
- Do not force-push, and do not delete `integration/20260816-1` while
  `tortoise-cm:20260816-1` exists — that branch ref is the only thing keeping
  the image's stamped commit reachable.
- Do not change `.env`, and do not retag or delete `tortoise-cm:c06b2fb` — it is
  the rollback path.

# Report back

1. **Stage 1's result explicitly** — the grep counts, whether any forbidden
   command appeared in a transcript, and that the volume still exists.
2. Anything that failed, quoted verbatim rather than summarised.
3. Anything in `backlog-batch.js`, `backlog-issue.js` or the drain skill that is
   wrong, stale, or would break at larger batch sizes. Four such defects came out
   of the first batch run; more are expected, and they are more valuable than a
   clean pass.
