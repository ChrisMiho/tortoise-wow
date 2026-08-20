---
name: backlog-drain
description: Drain docs/backlog/ one pending artifact at a time by running the backlog-issue Workflow against each, batching several implemented artifacts into one backlog-batch build/validate/PR pass, looping via /loop until the backlog is empty
---

# Backlog Drain

Runs one tick of backlog draining: pick the oldest pending issue, implement
and review it via the `backlog-issue` Workflow — no PR yet — record the
outcome, then schedule the next tick. Once enough freshly-implemented
artifacts have accumulated (see "Batch size" below), runs one `backlog-batch`
pass instead of the next tick to build, validate, and open a PR for each —
see [Running a batch](#running-a-batch). Meant to be started with `/loop
backlog-drain` (self-paced, no fixed interval) so it keeps going across turns
without you re-invoking it.

**Announce when starting a drain session:** "Starting the backlog drain loop."

**First run in an environment?** Do a single supervised tick against a throwaway
artifact before turning this loose on a real backlog — see
[Before trusting an unattended run](#before-trusting-an-unattended-run).

**Batch size:** 4 — the drain accumulates up to this many freshly-implemented
artifacts before running one `backlog-batch` build/validate/PR pass instead of
one per artifact. Chosen to match the largest wave that worked cleanly in the
first real integration (`docs/superpowers/plans/2026-08-12-transport-stack-merge.md`'s
wave 1, 4 PRs). If a batch build breaks, consider lowering this rather than
raising it — smaller batches are cheaper to bisect.

## Before the first tick of a session

Once per session, not per tick. Each of these is a stop-and-fix, not a warning:

1. **Confirm the world still exists.** `docker volume ls --format '{{.Name}}' |
   grep -x tortoise-wow-v2_dbdata`. Silence means restore from
   `/home/deck/tortoise-wow-server-V2/backups/pre-drain-*.sql` (WSL's home, not
   Windows') before doing anything else.
2. **Confirm `gh` is authenticated** — `gh auth status`. Only a batch pass pushes
   or opens PRs, and a batch that builds for ten minutes and then cannot open a
   single PR is a batch-wide failure, which pauses batching for the rest of
   the session (see [Pausing batching](#pausing-batching-nobatch)).
3. **Confirm the working branch's upstream isn't `origin/cm-main`.** Run:

   ```
   git rev-parse --abbrev-ref --symbolic-full-name '@{u}'
   ```

   The hazard is specifically an upstream of `origin/cm-main`, which turns a
   stray `git push` into a commit on the trunk. **No upstream at all is fine
   and so is any other upstream** — that command exiting non-zero with
   `no upstream configured` is a pass, not a failure. Only `origin/cm-main`
   is a stop-and-fix: `git branch --unset-upstream` before continuing.
   (This check used to demand a bare branch name from `git status -sb` and so
   failed a perfectly safe `origin/drain/tournament-2` upstream.)
4. **Confirm the guardrail checker works** — `bash tests/check-guardrails.test.sh`
   prints `21 passed, 0 failed`. **From Git Bash, not WSL** (see Environment).

Report all four in the first tick's summary, then continue.

## Environment

Every one of these has already cost someone a session.

- **`node` runs in Git Bash, `jq` runs in WSL, and neither is in the other.**
  This inverts the usual "run scripts from WSL" rule for exactly two files:
  `scripts/check-guardrails.js` and `scripts/check-workflow-fresh.js` are Windows
  node and die under WSL with `node: command not found`. Everything in
  `scripts/tournament/` needs `jq` and so must run from WSL.
- **Builds run in the FOREGROUND and take ~8.5 minutes.** Set the command
  timeout to **600000 ms** — the Bash tool's maximum, which it silently clamps
  anything larger down to, so `900000` is not a thing you can ask for. The
  build fits: 8m15s measured 2026-08-17 at `BUILD_JOBS=14`, ~90s of margin.
  **Decide success from `docker images --filter reference=tortoise-cm`, not
  from the exit code.** Until 2026-08-17 the default was `-j10`, the build took
  10m11s, and it was killed at exactly 10m00s with **exit 143** (128 + SIGTERM)
  during image export — every layer built, never tagged, which reads as a build
  that vanished. If that recurs, the build has crept back over the ceiling:
  re-running the identical command completes it from cache in ~40s, but report
  it rather than absorbing it. Backgrounded, `nohup`'d or detached builds are a
  different failure entirely and *are* silently cancelled by BuildKit, leaving
  no image and no error. Recompiling all ~1169 translation units on every build
  is normal — `COPY . /src` never cache-hits. Do not add ccache; it was
  measured and reverted.
- **Validation needs `TW_SRC_DIR` *and* `GIT_DIR`.** A worktree's `.git` is a file
  holding a Windows path that WSL's git cannot resolve, which produces a **false**
  `VALIDATE-STACK: FAIL FOREIGN`. Rewrite that path to its `/mnt/c/...` form and
  export it as `GIT_DIR`. Never rebuild chasing a FOREIGN result.
- **`docker compose` outside the main checkout needs
  `--env-file <main-checkout>/.env`** — `.env` is gitignored and exists only
  there. Resolve it with `git worktree list`; the first entry is the main checkout.
- **Prefix `wsl` calls from Git Bash with `MSYS_NO_PATHCONV=1`**, and never put a
  `$VAR` inside a wrapped `wsl -d Ubuntu -- bash -lc '...'` one-liner — the Windows
  layer blanks it silently and you get plausible, wrong output. Write a script file.

### What can actually destroy something

`docker compose down -v` **from this repo is inert** — `dbdata` is `external: true`
and compose never removes an external volume. Do not take reassurance from that;
these are the commands that really do it, and nothing but this list guards them:

- `docker volume prune`, `docker system prune --volumes`, or Docker Desktop's
  cleanup button. With the stack down, Docker reports `tortoise-wow-v2_dbdata`
  **100% reclaimable** — "unused" means "no running container", not "no data".
- `docker compose down -v` run from `~/tortoise-wow-server-V2`, where the same
  volume is compose-*managed*. Never run compose from that directory.
- `docker image prune -a` takes `tortoise-cm:c06b2fb`, the rollback anchor.
  Nothing rebuilds it during a drain. Plain `docker image prune` is safe.

**Never delete a `backlog/*` branch from origin.** Step 5a resolves dependencies
with `git merge-base --is-ancestor origin/backlog/<slug> origin/cm-main`; if the
branch is gone that command *errors*, which is treated as "not ready" — a false
deadlock that can strand half the backlog. Never delete an `integration/*` branch
either: that ref is the only thing keeping a built image's stamped commit
reachable. Do not retag or delete `tortoise-cm:c06b2fb`, and do not edit any
artifact's scope.

## What to watch for

Beyond the outcomes each step already defines:

- **The first `blocked` outcome.** `blocked` deliberately does not count toward
  step 3's circuit breaker, so a new blocking cause would march through the whole
  backlog without ever stopping. Investigate the first one rather than letting it
  repeat.
- **A ~10 minute gap inside a tick.** That is a per-artifact Docker build, which
  the Implement prompt forbids — the batch pass is the compile gate. Report it.
- **Confident but wrong claims.** Agents here have repeatedly reported file paths
  and line numbers that do not exist. Spot-check anything an agent asserts about
  the codebase before repeating it; the drain produces a great many such reports
  with nobody reading them.
- **After each batch**, confirm one PR per artifact and quote the
  `VALIDATE-STACK:` line verbatim rather than summarising it.

Report anything in `backlog-issue.js`, `backlog-batch.js` or this skill that is
wrong, stale, or would break at larger batch sizes. Thirteen such defects came
out of the 2026-08-16/17 runs; more are expected, and they are worth more than a
clean pass.

## One tick

1. Check for a stop request first: if `docs/backlog/.stop` exists, this is
   the terminal tick:
   - **Do not run a batch, unless the file's contents say to.** Read it: the
     word `flush` anywhere in it means run [Running a batch](#running-a-batch)
     once first (even below the batch-size threshold); an **empty** `.stop` —
     the normal case, and what `touch` produces — means stop without
     batching. This is the one terminal path that defaults to *not*
     flushing, and the default is deliberate: `.stop` is the documented
     panic button, reached for precisely when something outside the repo is
     going wrong (a GitHub incident, an API outage, a build host misbehaving).
     Flushing turns that into a ten-minute build plus a push and four `gh pr
     create` calls against the very service that prompted the stop. Nothing
     is stranded by not flushing: artifacts left at `status: implemented` are
     re-counted by step 11 the moment the loop restarts, and batch on the
     next tick that reaches the threshold. The other three terminal paths
     (steps 3, 4, 5) still flush unconditionally, because for those no
     future tick is coming.
   - Report a summary: how many artifacts are `done`, `failed`, stuck
     `in-progress`, still `implemented` (waiting on a future batch — expected
     unless `.stop` said `flush` and that flush ran cleanly; name them by
     path so it's obvious what a restart will batch first), and still `pending` (with
     paths, so they can be picked up — or, for `in-progress`, investigated —
     again later).
   - Delete `docs/backlog/.stop`.
   - Run step 9a (the worktree-isolation branch sweep).
   - Call `ScheduleWakeup({ stop: true })` and stop. Do not pick a new item.
2. List `docs/backlog/*.md`. Read each file's frontmatter. If any file has
   `status: in-progress`, it's left over from a previous tick that crashed or
   otherwise ended before recording an outcome — report it now (e.g. "N
   artifact(s) stuck at in-progress: <paths>"). Never re-pick, edit, or
   restart an `in-progress` file automatically: a human needs to check
   whether a PR was already opened for it before resetting its status to
   `pending` by hand.

   Also check for `docs/backlog/.nobatch` here. If it exists, batching is
   paused — say so in this tick's report, quote the reason it records, and
   name how many artifacts are queued at `status: implemented` behind it. It
   does not change what this tick does (implement ticks run normally while
   paused); it just must not go unmentioned for hours. See
   [Pausing batching](#pausing-batching-nobatch).
3. Check the recent failure history before starting new work — this is the
   circuit breaker. This skill keeps no state between ticks other than the
   filesystem, so read the history out of git: every completed tick commits
   exactly one subject of the form
   `backlog: mark <artifact-name> implemented|blocked|failed` (step 10). Run:

   ```
   git log -n 2 --pretty=format:%s --grep "^backlog: mark " -- :/docs/backlog
   ```

   (`:/docs/backlog` is deliberate: a plain `docs/backlog` pathspec silently
   matches nothing when run from a subdirectory, which would silently disable
   this breaker. `-n 2` applies to matching commits, so unrelated commits in
   between don't hide the history.)

   If both subjects end in `failed` **and** both of those artifacts (subject
   `backlog: mark <name> failed` means `docs/backlog/<name>.md`) still have
   `status: failed` in their frontmatter, this is the terminal tick:
   - Before reporting and calling `ScheduleWakeup({ stop: true })`, if any
     artifact is at `status: implemented`, run
     [Running a batch](#running-a-batch) once — even below the usual
     batch-size threshold — so nothing is left waiting on a batch that will
     never trigger.
   - Report both artifacts by path with their `**Failure notes:**`, say the
     loop stopped deliberately after two consecutive failures rather than
     grinding the rest of the backlog into `failed`, and list what's still
     `implemented` (if the flush above left any — see its own failure
     reporting), `pending`, and untouched.
   - Run step 9a (the worktree-isolation branch sweep).
   - Call `ScheduleWakeup({ stop: true })` and stop. Do not pick a new item.

   Fewer than two such commits (a fresh backlog) never trips this. An artifact
   that's been triaged back to `pending` no longer counts as failed here —
   that's how you clear the breaker before restarting the loop.
4. If no file has `status: pending`, this is the terminal tick:
   - Before reporting the summary and calling `ScheduleWakeup({ stop: true })`,
     if any artifact is at `status: implemented`, run
     [Running a batch](#running-a-batch) once — even below the usual
     batch-size threshold — so nothing is left waiting on a batch that will
     never trigger.
   - Report a summary: how many artifacts are `done`, how many `failed` (with
     their paths, so they can be triaged), how many are stuck `in-progress`
     (with paths, same human-check caveat as step 2), how many are still
     `implemented` (should be none if the flush above just ran cleanly — if
     any remain, the flush's own report says why), and that the backlog is
     drained.
   - Run step 9a (the worktree-isolation branch sweep).
   - Call `ScheduleWakeup({ stop: true })` and stop. Do not continue.
5. Otherwise, pick the file with the lowest numeric prefix among those with
   `status: pending` (ignoring any files without a valid 3-digit `NNN-`
   numeric prefix) **whose dependency is ready**:
   - No `depends-on:` value (or blank) — ready, pick it.
   - `depends-on: <NNN>-<slug>.md` set — read that file's frontmatter. Ready
     only if its `status` is `done`. Anything else (`pending`, `in-progress`,
     `contested`, `blocked`, `failed`, `out-of-scope`, or the file missing
     entirely) means not ready: skip this candidate and check the
     next-lowest-numbered pending file instead.
   - If every remaining `pending` file is blocked on an unready dependency,
     this is a terminal tick: before reporting and calling `ScheduleWakeup({
     stop: true })`, if any artifact is at `status: implemented`, run
     [Running a batch](#running-a-batch) once — even below the usual
     batch-size threshold — so nothing is left waiting on a batch that will
     never trigger. That flush can itself move a dependency artifact from
     `implemented` to `done` (step 4 of "Running a batch"), which is exactly
     the condition this step checks — so after the flush, re-run this
     eligibility check against the current `pending` files before deciding to
     stop: if any of them now has a `done` dependency, it's newly ready —
     pick it and continue the tick from step 5a onward instead of stopping.
     Only if every remaining `pending` file is still blocked after the flush
     do you actually stop: report each blocked artifact by path and what it's
     waiting on, along with any artifacts still `implemented` after that
     flush, run step 9a (the worktree-isolation branch sweep), call
     `ScheduleWakeup({ stop: true })`, and stop. Do not pick anything. (A
     dependency cycle surfaces here too, indistinguishable from an ordinary
     not-yet-drained dependency — both are reported the same way and require
     a human to look.)
5a. Resolve the base branch for the picked artifact:
   - No `depends-on:` — `baseBranch: "cm-main"`, no `dependsOnPrUrl`.
   - `depends-on:` set (and therefore, per step 5, that dependency's
     `status: done`) — determine whether its PR already merged:
     ```
     git fetch origin cm-main
     git merge-base --is-ancestor origin/backlog/<dep-slug> origin/cm-main
     ```
     Exit code `0` means it already merged — use `baseBranch: "cm-main"`
     (nothing left to stack on). Non-zero means it's still open — use
     `baseBranch: "backlog/<dep-slug>"`, and read the dependency artifact's
     `**Result:** PR opened at <url>` line for `dependsOnPrUrl`.

     If the `git merge-base` command itself errors — rather than cleanly
     exiting non-zero for "not an ancestor" — do not treat that as either
     "merged" or "still open". This happens when `origin/backlog/<dep-slug>`
     doesn't exist on the remote at all, which can only mean the dependency
     artifact's `status: done` is stale or wrong (the branch was deleted
     after merging, or never pushed). Treat the dependency as **not ready**:
     log a warning naming the missing branch and fall through to the
     next-lowest-numbered pending artifact, exactly as step 5 does for a
     dependency whose `status` isn't `done`.
6. Edit that file's frontmatter to `status: in-progress` before doing anything
   else, so a crash mid-tick can't cause it to be picked again.
7. Run `Workflow({ name: "backlog-issue", args: { artifactPath: "<absolute
   path to that file>", baseBranch: "<resolved in step 5a>" } })`. No
   `dryRun` argument — Task 7 removed the concept from `backlog-issue.js`
   since it no longer pushes or opens anything, so there's nothing left to
   fall back to a dry run for. No `dependsOnPrUrl` either: `backlog-issue.js`
   no longer consumes that field now that Task 7 removed the PR phase that
   used it — passing it here would be a harmless but pointless no-op. It's
   still needed later, though: re-derive it for the batch call, per
   [Running a batch](#running-a-batch) step 3 below.

   **The moment that call returns, check the script it actually ran** — see
   [Verifying the workflow that actually ran](#verifying-the-workflow-that-actually-ran).
   Do this on **every** tick, not once per session.

   Build the absolute path from the repo root (`git rev-parse --show-toplevel`)
   plus `docs/backlog/<filename>` — e.g.
   `D:/CodingProjects/tortoise-wow/tortoise-wow/docs/backlog/003-bots-stuck-at-spirit-healer.md`.
   Forward slashes are fine on Windows. Do not pass a bare relative path: the
   artifact is still uncommitted at this point and the Implement phase reads it
   from its own worktree after switching branches, so a relative path resolves
   against a working directory this skill doesn't control.
8. Record the outcome. There are four, and they are **not** interchangeable —
   see [Systemic vs. per-artifact failures](#systemic-vs-per-artifact-failures)
   for how to tell the per-artifact ones from a systemic one:
   - **Implemented** — `success: true` (with or without `contested`): edit
     the artifact's frontmatter to `status: implemented`, and append these
     lines to the artifact body. All of them get read back verbatim in
     [Running a batch](#running-a-batch) below — nothing else persists this
     result between the implement tick and the later batch tick:
     - `**Base:** <resolved base branch (step 5a)>`
     - `**Branch:** <result.branchName>` — this is the authoritative branch
       name the batch pass uses; step 9's filename-derived
       `backlog/<slug>` remains only a fallback for locating the worktree
       during that step's own cleanup, not a source of truth for the batch.
     - `**Summary:** <result.summary>` — **check it against the real diff
       before you write it.** Run `git diff --name-status
       origin/<base>...<result.branchName>` and confirm every path in that
       output is accounted for by the summary. The summary is prose an agent
       wrote about what it *meant* to change; on 016 it omitted a whole set of
       battleground edits the diff actually contained, and because the PR body
       quotes this line and lists no files, that work would have reached a
       human reviewer invisibly. If a file isn't covered, append one sentence
       to the line naming it and what changed there — extend the summary,
       never trim the diff to match it. (The PR body now also carries a
       git-derived "Files changed" block as a backstop, but this line is what
       a reviewer actually reads.)
     - `**In-game check:** <result.inGameCheck>`
     - `**Minor findings:**` followed by one bullet per
       `result.minorFindings` entry, each formatted exactly `- <finding.file>:
       <finding.summary>` — this exact format is read back verbatim by
       [Running a batch](#running-a-batch) step 1, so don't paraphrase it.
       Omit the whole line/section entirely if `minorFindings` is empty.
     - If `contested` is present: `**Contested:** <one bullet per
       contestedFindings entry>`
     Do not open a PR here and do not mark it `done` — that, along with
     resolving a contested outcome to `status: contested` instead, happens in
     the batch pass (see [Running a batch](#running-a-batch) step 4).
   - **Blocked** — `success: false, blocked: true, ...`: edit the artifact's
     frontmatter to `status: blocked` and append a `**Blocked:** <reason>`
     line using the result's `reason`. Unchanged from Task 5. A blocked
     outcome is not a failure — do not count it toward the circuit breaker in
     step 3.
   - **Failed** — `success: false` with no `blocked` **and no `systemic:
     true`**, and a reason that's about this issue's own implementation or
     review: edit the artifact's
     frontmatter to `status: failed` and append a `**Failure notes:**
     <reason>` line — use the result's `reason` if present, otherwise record
     what was actually returned or thrown so it's triage-able. Include the
     stale worktree and branch location from step 9's lookup in that same
     line.
   - **Systemic failure** — the invocation itself is broken, or a transient
     outage swallowed a phase; either way it is not this artifact's fault.
     `systemic: true` on the result decides this outright; otherwise see
     [Systemic vs. per-artifact failures](#systemic-vs-per-artifact-failures):
     - Do **not** mark it `failed`. Set its frontmatter back to
       `status: pending` (reverse the step 6 edit; `git checkout -- <path>`
       also works if the artifact was already committed) and don't append
       failure notes — nothing is wrong with the artifact.
     - Don't commit a status change; there's no outcome to record. Discard the
       working-tree change instead of committing it.
     - Report it loudly and specifically, e.g. "This looks **systemic** — the
       `backlog-issue` invocation itself failed, not
       `docs/backlog/003-....md`. Nothing was marked failed; that artifact is
       back at `pending`. N artifacts remain pending and untouched." Quote the
       raw result or error verbatim, and the args you actually passed.
     - Skip step 9's cleanup (treat it like `failed`: leave any worktree and
       branch in place, report the path if one exists).
     - Call `ScheduleWakeup({ stop: true })` and stop. Do **not** continue to
       the next tick: a broken invocation would burn the entire backlog to
       `failed` in minutes, every artifact blamed for something that wasn't
       its fault. Do not run a batch flush here even if artifacts are sitting
       at `status: implemented` — the invocation itself is suspect, and
       kicking off an expensive batch pass on a possibly-broken toolchain is
       the wrong move; that flush stays specific to the four terminal-tick
       stop paths (steps 1, 3, 4, 5), not this one.
9. Find the Implement worktree and clean it up (or deliberately don't). The
   workflow's Implement phase runs with `isolation: 'worktree'` and always
   leaves a commit behind, so Workflow's own auto-cleanup-if-unchanged never
   triggers — each issue otherwise leaves ~400 MB of checkout on disk forever
   if nothing removes it. Locate it by branch name (the result's `branchName`,
   or `backlog/<artifact filename minus the NNN- prefix and .md>` if the result
   didn't carry one):

   ```
   git worktree list --porcelain
   ```

   Each record is a `worktree <path>` line followed by a
   `branch refs/heads/<name>` line; take the path whose branch matches.
   - **On `implemented`:** remove only the worktree —
     `git worktree remove <path>`, run from the main checkout rather than
     from inside the worktree — and leave the branch alone. Unlike the old
     `done` outcome, nothing has pushed this branch anywhere yet
     (`backlog-issue`'s Implement phase commits locally and explicitly does
     not push); the branch is the only copy of the work, and the batch pass
     needs it intact to merge and eventually push. If `git worktree remove`
     refuses because of leftover untracked files (build output), a `--force`
     is acceptable *here specifically*, because nothing is being discarded —
     the branch itself is untouched. If no worktree matches, it's already
     gone — skip.
   - **On `blocked`, `failed`, or a systemic failure:** remove nothing. The
     worktree may hold unpushed work (or, for `blocked`, a branch with no
     commit at all — see the Implement phase's contract) worth reading before
     deciding what to do with the artifact, and the branch is the only copy
     of it. Record the path in the failure or blocked note instead (step 8),
     e.g. `**Failure notes:** <reason> (worktree left at <path>, branch
     <branch> — remove both with "git worktree remove <path>" and "git
     branch -D <branch>" before resetting this artifact to pending)`. If you
     already wrote that note without the path, edit the line now to add it.
     If no worktree exists for that branch, say that instead.
9a. Sweep orphaned Workflow-isolation branches. Every Implement-phase call
    creates a scaffold branch named `worktree-wf_*` before the agent checks
    out `backlog/<slug>` inside that worktree — once that happens, the
    scaffold branch is never referenced again, but nothing deletes it, so it
    accumulates one stale local branch per tick regardless of outcome. Run
    this after step 9's own cleanup, every tick, terminal or not:

    ```
    git branch --list 'worktree-wf_*'
    git worktree list --porcelain
    ```

    For each `worktree-wf_*` branch **not** shown as backing any entry in
    `git worktree list`, check whether it's safe to delete before deleting
    it — its tip must be reachable from somewhere else, or deleting it loses
    the only copy of whatever it holds:

    ```
    git merge-base --is-ancestor <branch tip> origin/cm-main
    ```

    or, for each local `backlog/*` branch still present:

    ```
    git merge-base --is-ancestor <branch tip> backlog/<slug>
    ```

    If either check exits `0`, the branch's content lives on elsewhere —
    delete it: `git branch -D <branch>`. If neither does, **do not delete
    it** — report its name and note that it holds at least one commit
    unreachable from `cm-main` or any live `backlog/*` branch, so a human can
    look before it's lost. (This is exactly what happened to
    `worktree-wf_6d15c61b-144-1` in the first real run: a stray merge-conflict
    resolution commit that survived nowhere else. Content from that specific
    incident is safe — it landed on `cm-main` via a different path — but the
    branch itself was never verified reachable before this sweep existed.)

    This sweep also runs as the last action before every terminal-tick stop
    path that flushes a batch (steps 1, 3, 4, and 5 — the `.stop`-sentinel
    exit, the circuit-breaker stop, the drained-backlog stop, and the
    dependency-deadlock stop) — not only during an ordinary tick — so a drain
    session that halts early still leaves the repo swept rather than
    accumulating scaffold branches across every future session. (The
    systemic-failure stop, step 8, deliberately skips both the flush and this
    sweep — see its own reasoning.)
10. Unless step 8 took the systemic path, stage and commit the artifact's
    status change with a subject in exactly this form — step 3's circuit
    breaker reads it back:
    `backlog: mark <artifact filename without .md> <implemented|blocked|failed>`,
    e.g. `git add docs/backlog/003-bots-stuck-at-spirit-healer.md && git
    commit -m "backlog: mark 003-bots-stuck-at-spirit-healer implemented"`.
    `implemented` and `blocked` don't end in `failed`, so both forms are
    automatically exempt from step 3's circuit breaker grep, with no change
    needed to the grep itself — the same reasoning that already exempted
    `contested`, which this tick no longer produces (that status, along with
    `done`, is now assigned later, in [Running a batch](#running-a-batch)).
11. **Check the batch trigger before scheduling the next tick:** count
    artifacts at `status: implemented` across all of `docs/backlog/`, not
    just the one this tick may have just produced. If that count has reached
    the batch size documented above, or if no `pending` artifacts remain at
    all (so no more accumulation is coming and nothing would ever reach the
    threshold on its own), run the batch pass now — see
    [Running a batch](#running-a-batch) below — before doing anything else.
    That section's own first step no-ops the call if `docs/backlog/.nobatch`
    exists, so the trigger needs no separate check here; when it no-ops, fall
    through to the `ScheduleWakeup` below as though the threshold hadn't been
    reached, and say in the tick's report how many artifacts are now waiting
    on a batch that is paused.
    Otherwise call `ScheduleWakeup` to continue:
    - `delaySeconds: 60` (the minimum — there's no external event to wait on,
      just the next tick starting promptly)
    - `prompt`: the same input you'd give `/loop` to restart this skill —
      `backlog-drain` (matching how this skill is started: `/loop
      backlog-drain`)
    - `reason`: one line, e.g. `"continuing backlog drain, N pending remaining"`
    - `noop: false` (a real tick of work happened)

    Running a batch ends by scheduling the next tick itself (see its step 8
    below), so don't also schedule one here after it returns.

## Running a batch

Triggered from step 11 above, or from one of the terminal-tick flushes (steps
1, 3, 4, 5 — see [Stopping the loop](#stopping-the-loop)).

**First, check whether batching is paused.** If `docs/backlog/.nobatch`
exists, do not run a batch at all — read the file, report its contents
verbatim (it names the `buildId`, the failure reason, and the artifacts that
were in the failed batch), and return immediately to whichever step called
you. That caller then carries on as it otherwise would: step 11 schedules the
next tick as normal, and a terminal-tick flush proceeds straight to its own
report and `ScheduleWakeup({ stop: true })`. This guard covers every entry
point, so no individual call site needs its own check.

The sentinel is written by step 5 below when a batch fails batch-wide, and
**only a human clears it** (`rm docs/backlog/.nobatch`), after looking at what
broke. Its whole purpose is to keep the cheap half of the drain running while
the expensive half waits: an implement tick is local-only — no push, no PR, no
compile — so a broken build has no bearing on whether the next artifact can be
written. Artifacts accumulate at `status: implemented` in the meantime and are
re-counted by step 11 the moment the sentinel is removed.

Otherwise, gather every artifact at `status: implemented`:

1. For each, read back only the `**Base:**` and `**Branch:**` lines appended
   when it moved to `implemented` (step 8 of "One tick" above), plus whether a
   `**Contested:**` block is present.

   **Do not copy the long prose into the batch args.** `backlog-batch` reads
   `**Summary:**`, `**In-game check:**`, `**Minor findings:**`,
   `**Contested:**`, and the artifact's own **Problem:**/**Acceptance
   criteria:** sections out of the artifact file itself, from the
   `artifactPath` you pass. Inlining them instead cost ~11 KB per artifact —
   43 KB for a batch of four, measured 2026-08-17 — which this skill had to
   reproduce verbatim on every call. That scales linearly with batch size, and
   every character of it is a chance to paraphrase text the PR body is
   supposed to quote exactly. Step 8 must still *write* those lines onto the
   artifact; the batch is what stopped needing them handed over.
2. Compute a `buildId` — a short, sortable, human-readable string such as
   `<date>-<sequence>` (e.g. `20260813-1`). Sequence within a day so two
   batches on the same day don't collide, mirroring Task 2's migration-filename
   fix. Do this with a real shell date command (`date +%Y%m%d` or PowerShell's
   `Get-Date`) — this skill runs as an agent with tool access, unlike the
   Workflow scripts it calls, so it's fine to use a real clock here.

   **Derive the sequence from what already exists — do not assume `-1`.** A
   full drain runs several batches in a single day, so a same-day collision is
   the normal case here rather than an edge one. Reusing a `buildId` overwrites
   an already-built, already-validated image and collides with an
   `integration/<buildId>` branch that step 7 below deliberately never deletes.
   Check both namespaces and take the next free number:

   ```
   git branch --list 'integration/<date>-*'
   docker images --format '{{.Repository}}:{{.Tag}}' --filter reference=tortoise-cm
   ```

   `backlog-batch`'s Integrate phase refuses a colliding branch and reports it
   as a batch-wide failure, so getting this wrong costs a wasted build and a
   paused batcher rather than a corrupted image — but it still costs the
   night's remaining PRs until someone clears `.nobatch`.
3. Run `Workflow({ name: "backlog-batch", args: { buildId, batch: [...] } })`
   where each batch entry is exactly
   `{ artifactPath, branchName, baseBranch, dependsOnPrUrl, contested }`
   — identifiers only, five short fields, no prose. `artifactPath` must be
   absolute; it is how the Validate and PR phases find everything else.
   `contested` is a boolean and travels here only because it changes the PR
   title and the status assigned in step 4; the contested *findings* are read
   from the artifact. `dependsOnPrUrl` isn't persisted separately — re-derive
   it the same way step 5a did, from the `depends-on:` frontmatter and the
   dependency artifact's `**Result:**` line, only when `baseBranch` isn't
   `cm-main`.

   Immediately after this call returns its script path, run the freshness
   check in [Verifying the workflow that actually ran](#verifying-the-workflow-that-actually-ran).
4. On `{ success: true, results, buildId, imageTag }`: for each entry in
   `results` with a `prUrl`, edit that artifact's frontmatter to `status: done`
   (or `status: contested` if that entry's `contested` was true) and append
   `**Result:** PR opened at <prUrl>, build ${imageTag}.` For each entry with
   `excluded: true` or a `prReason` instead of a `prUrl`, leave that artifact
   at `status: implemented` and append a `**Batch note:** <prReason or
   "excluded during integration — will retry in a future batch">` line so
   it's visible without blocking the rest of the batch's success.
4a. **Point the stack at the image this batch just built.** Edit the main
   checkout's `.env` so `TW_IMAGE=<imageTag>` — the tag returned in step 4,
   e.g. `TW_IMAGE=tortoise-cm:20260817-3`. Do this only on a successful batch
   (step 4), never after a failed one (step 5), and never to a tag that
   `validate-stack.sh` did not pass.

   This is what makes later implement ticks able to *test* rather than reason.
   `backlog-batch`'s Validate phase runs with `--keep-up`, so the stack is
   already left running on that image; without this edit, the next tick that
   restarts the stack or brings it up itself silently drops back to whatever
   `.env` still names — for the first two drains, the `c06b2fb` rollback
   anchor, in which every command this series adds is absent. An artifact
   whose acceptance criteria need a live server (037 is the clearest case)
   then blocks for a reason that is an artifact of stale config rather than a
   real limitation.

   `.env` is gitignored, so this is not a commit and does not belong in step
   6's staging. The `backlog-issue` Implement prompt's rule 5 tells agents to
   read the running image with `docker ps` rather than assume, so a stale
   `.env` degrades to "tested less" rather than to a wrong conclusion — but
   keep it current anyway.

   Leave `tortoise-cm:c06b2fb` on the host untouched regardless. It is the
   rollback anchor and the only image that predates the series; the `.env`
   comment records it so the way back is one edit, not an archaeology
   session.

5. On `{ success: false, reason }`: this is a **batch-wide** failure (a
   build break, or nothing left after integration exclusions) — not a
   per-artifact one. Leave every artifact in the batch at `status:
   implemented` (do not touch their status), and report the failure loudly
   with the `reason` and the full list of artifacts that were in the
   attempted batch, so a human can decide whether to retry, exclude a
   suspected artifact by hand, or investigate the build break directly.

   Then **pause batching rather than stopping the drain.** Write
   `docs/backlog/.nobatch` containing the `buildId`, the `reason` verbatim,
   and the artifact paths that were in the failed batch, and continue the
   loop as step 8 below describes. The guard at the top of this section
   makes every later batch trigger a no-op until a human removes that file,
   which is what stops the next tick implementing one more artifact, hitting
   the batch-size threshold, and re-triggering this same failing batch —
   burning a full build cycle every retry. Ticks themselves keep running:
   they are local-only and cost nothing on the build host or GitHub, so a
   batch break at 1am should cost the night's builds, not the night's work.
   (This path used to call `ScheduleWakeup({ stop: true })` outright. That
   protected the build host correctly but ended the whole unattended run
   with the backlog barely touched — the sentinel gets the same protection
   without the collateral.)

   The one case where the drain still stops on its own afterwards is
   step 5 of "One tick": with batching paused, no dependency can reach
   `status: done`, so once every remaining `pending` artifact is chained
   behind an unbatched one, that step's deadlock report fires and the loop
   ends gracefully. That is the correct outcome — there is genuinely nothing
   left it can do without a human — and it reports the pause as the cause.

   Step 6's commit and step 7's cleanup below still run as normal.
6. Commit whatever status/body changes steps 4-5 produced, subject
   `backlog: batch ${buildId}`.

   **Stage those files by name, and sweep the repo root first.** Run `git
   status --porcelain` and account for every line: anything that isn't a
   `docs/backlog/*.md` you just edited is scratch a PR agent left behind. The
   2026-08-17 batch left `pr-body-024.md` and `scratchpad-pr-body-023.md`
   untracked in the repo root. Delete any such file once you've confirmed its
   content already reached the PR (`gh pr view <n> --json body`), and never
   `git add .` or `git add -A` here — a blanket add would commit an agent's
   scratchpad into the trunk's history.
7. Clean up the Integrate-phase worktree and its `integration/${buildId}`
   scaffold branch, whether the batch succeeded (step 4) or failed (step 5) —
   the Integrate phase ran with `isolation: 'worktree'` and left both behind,
   and nothing else in this workflow removes them. Do this only once the
   branch's content is confirmed to have landed somewhere durable, using the
   same reachability principle step 9a (of "One tick") uses for its own
   scaffold-branch sweep — deleting an unreachable commit here would lose the
   only copy of it:

   For each artifact actually included in the batch whose branch was
   successfully pushed (i.e. it has a real `prUrl` in `results`), confirm both
   that the integration branch contains that work and that the work is on
   origin:

   ```
   git merge-base --is-ancestor backlog/<slug> integration/<buildId>
   git ls-remote --heads origin backlog/<slug>
   ```

   **Mind the direction of that first check** — it asks whether each artifact
   branch is contained *in* the integration branch, not the reverse. This was
   originally written the other way round (`--is-ancestor integration/<buildId>
   origin/cm-main`), which can never exit `0`: `integration/<buildId>` is by
   construction a merge commit *ahead of* both `origin/cm-main` and every
   `backlog/*` branch, so it is never an ancestor of either. The cleanup below
   was therefore unreachable, and the first real batch left a 398 MB worktree
   on disk — across a full drain, several GB of dead checkouts.

   If every included, pushed branch is contained in `integration/<buildId>`
   and present on origin, then the only commit unique to the integration
   branch is the throwaway merge itself and every artifact's work is safe on
   origin — remove the **worktree** (`git worktree remove <path>`, run from
   the main checkout; `--force` is acceptable if leftover untracked build
   output blocks it, since nothing is being discarded). The worktree is where
   the ~400 MB lives, so this is the part that matters for disk.

   **Keep the branch.** Do *not* `git branch -D integration/<buildId>` here.
   The image built from this batch is stamped with that merge commit's SHA,
   and the branch ref is the only thing keeping the commit reachable — delete
   it and the commit is eventually garbage-collected, after which
   `scripts/validate-stack.sh` can never verify `tortoise-cm:<buildId>` again
   and will report it FOREIGN. A ref costs nothing; a permanently
   unverifiable image is expensive. It becomes safe to delete once that image
   is gone or superseded, which is a human's call and not this step's. Note
   also that `--is-ancestor integration/<buildId> origin/cm-main` will never
   pass even after the PRs merge — GitHub builds its own merge commit, so this
   local one never lands on the trunk.

   If any included branch is missing from origin or is not contained in the
   integration branch (e.g. step 5's batch-wide failure happened before
   anything was pushed), **remove nothing** — leave the worktree and branch in
   place and report the worktree's path and branch name instead, matching step
   9's "not on origin" pattern in "One tick", so a human can look before
   anything is lost.
8. Continue the loop as step 11 would have (schedule the next tick) —
   running a batch does not itself end the drain, and since step 5 now pauses
   batching rather than stopping, that applies to a failed batch too. Use a
   `reason` naming the pause when step 5 was taken, e.g. `"batching paused
   after build break, continuing to implement N pending"`. **Exception**
   (calling `ScheduleWakeup` twice in one tick would be a bug, so skip this
   step if it applies): this batch was triggered by one of the terminal-tick
   flushes instead of step 11 — that terminal tick's own
   `ScheduleWakeup({ stop: true })` still runs right after, per its own
   instructions.

## Verifying the workflow that actually ran

`Workflow({ name: "..." })` does not reliably serve the current file. On
2026-08-17 `backlog-batch.js` ran **one edit behind** the repo copy while
`backlog-issue.js` resolved fresh on three consecutive ticks in the same
session. That time the stale delta was a comment, so nothing behaved
differently — but two workflows disagreeing is the point: you cannot infer from
one being current that the other is, and a check run once at the start of a
drain says nothing about the twenty-ninth tick.

Every `Workflow` result names a **saved script file**. Immediately after each
invocation — every tick and every batch, not once per session — run:

```
node scripts/check-workflow-fresh.js "<the saved script path from the result>"
```

**Run this from Git Bash, not WSL** — the opposite of the usual rule here. `jq`
is absent from Git Bash, which is why the tournament scripts need WSL; `node` is
the mirror image, a Windows install that is not in the Ubuntu distro at all, so
this and `scripts/check-guardrails.js` fail under WSL with
`node: command not found`. The transcripts they read live on the Windows
filesystem regardless.

- **Exit 0** — byte-identical, or comment-only drift. Proceed. A `WARN` is
  worth noting in the tick's report but is not a reason to stop.
- **Exit 1** — a guardrail marker is missing, or the script differs
  *functionally*. **Stop the loop.** Your edits did not reach that run: an
  agent may have live docker access with none of the prohibitions, or the batch
  may be missing its no-PR-opened stop. Re-invoke with
  `Workflow({ scriptPath: ".claude/workflows/<name>.js", args: {...} })`, which
  bypasses name resolution, and report the drift.

This is cheap — one file read against another — and it is the only thing that
notices when a mid-drain fix silently fails to take.

## Systemic vs. per-artifact failures

Treating these the same is how a single broken invocation turns an entire
backlog into `failed` artifacts, each one blamed for the wrong reason.

**Systemic** — the workflow never really ran against this artifact:

- **`systemic: true` is present on the result.** This is the authoritative
  signal and it needs no judgement from you: `backlog-issue.js` sets it when a
  phase agent returned `null`, which happens only when the subagent was
  skipped or died on a terminal API error (a 529, an overloaded window, a
  dropped connection) — never because the artifact was hard. Take the systemic
  path even though the `reason` text mentions the artifact by name.
- `reason` is `no artifactPath supplied`, or otherwise says the args never
  arrived. Step 7 always passes one, so this means it didn't get through.
- The `Workflow` call threw.
- The result is unrecognizable — not an object, or no `success` field at all.
- Several artifacts in a row fail with the same shape while an API or GitHub
  incident is in progress. An outage does not become a property of the
  artifact just because the error message names one.

**Per-artifact** — the workflow ran, gave a real answer, and something about
*this* issue failed: `implement phase returned an unexpected branch name: ...`,
`blocking findings not addressed: ...` (with an actual fix result described).
These are the ones worth marking `failed` and triaging.

Note what is **no longer** per-artifact: `a review lens did not return a
result` and `implement phase failed to produce a change` used to land here and
mark artifacts `failed`. Both are now `systemic: true`, and the review lenses
retry once before giving up. During the 2026-08-17 API-529 outage the old
classification would have burned two innocent artifacts to `failed` and then
tripped step 3's circuit breaker, blaming them for an Anthropic incident. (A `backlog-batch` failure at Build, Validate, or PR
time is a **different** kind of failure entirely — batch-wide, not
per-artifact, and not resolved through the `failed` status at all; see
[Running a batch](#running-a-batch) steps 4-5.)

The line isn't always crisp — a per-artifact reason that repeats verbatim across
different artifacts is systemic in effect, whatever it says. That's what step
3's circuit breaker is for: two consecutive failures stop the loop regardless of
how each one was classified.

## Stopping the loop

Create `docs/backlog/.stop` (an empty file, e.g. `touch docs/backlog/.stop`)
at any time to halt the drain after the current issue finishes. It's checked
at the very start of each tick, before a new issue is picked, so a stop
request never aborts an issue mid-implementation — it lets whatever's already
in flight finish (an implement+review tick just commits locally now; it no
longer opens a PR), then halts before starting another. This works even if no
one is watching the conversation when the sentinel is created.

**An empty `.stop` does not run a batch**, on purpose — see step 1. It is the
button you reach for when GitHub, the API, or the build host is misbehaving,
and a flush would answer that by pushing four branches and opening four PRs
against exactly the thing that's broken. Anything left at `status:
implemented` is picked up by step 11 on restart, so nothing is lost by not
flushing. If you *do* want the partial batch flushed before the halt —
finishing a session cleanly rather than escaping a problem — put the word
`flush` in the file instead: `echo flush > docs/backlog/.stop`.

**A failed batch does not stop the drain** — it writes
`docs/backlog/.nobatch` and keeps ticking, so the night's remaining artifacts
still get implemented while the build break waits for a human. See
[Pausing batching](#pausing-batching-nobatch) below.

The loop stops on its own for four reasons: the backlog is drained (step 4),
two consecutive artifacts failed (step 3), every remaining `pending` artifact
is blocked on an unready dependency (step 5), or a failure looked systemic
(step 8). All four report before stopping. The first three also flush a final
partial batch first if one is waiting (any artifact at `status: implemented`)
— see each step's own instructions — so a stop never leaves artifacts
stranded on a batch that would otherwise never trigger. The `.stop`-sentinel
stop does **not** flush unless the file says `flush`, and the systemic stop
(step 8) never flushes: see each one's own reasoning. Any of these flushes
no-ops while `.nobatch` is present.

## Pausing batching (`.nobatch`)

`docs/backlog/.nobatch` pauses the expensive half of the drain without
stopping the cheap half. While it exists, every batch trigger and every
terminal-tick flush no-ops (the guard is at the top of
[Running a batch](#running-a-batch)), but implement ticks keep running
normally — they commit locally and touch neither the build host nor GitHub,
so a broken build has no bearing on whether the next artifact can be written.

"Running a batch" step 5 writes it automatically on a batch-wide failure,
recording the `buildId`, the failure reason, and the artifacts that were in
the failed batch. Nothing removes it automatically: read it, fix or diagnose
the break, then `rm docs/backlog/.nobatch`. The next tick that reaches the
batch-size threshold picks up everything that accumulated at `status:
implemented` in the meantime.

You can also create it by hand — `touch docs/backlog/.nobatch` — to let a
drain keep implementing while deliberately holding back all pushes, PRs and
builds. That is the difference between it and `.stop`: `.stop` halts
everything, `.nobatch` halts only what reaches outside the repo.

With batching paused, no dependency can reach `status: done`, so a long
enough pause eventually walks the backlog into step 5's dependency deadlock
and the loop ends gracefully there, reporting the pause as the cause. That is
the intended floor, not a bug — by then everything implementable without a
human has been implemented.

## Before trusting an unattended run

The two calls this skill makes — `Workflow({ name: "backlog-issue", args:
{ artifactPath: "...", baseBranch: "..." } })` for a tick, and
`Workflow({ name: "backlog-batch", args: { buildId, batch: [...] } })` for a
batch — have never been exercised successfully end to end since Task 9 split
PR-opening out of the tick and into its own batch pass. A clean implement
tick proves nothing about whether the later batch call can actually build,
validate, and open a PR, so validate both, not just the first one, before
starting a real unattended drain in an environment where it hasn't run
before:

1. Write one throwaway artifact into `docs/backlog/` scoping a trivial,
   harmless change.
2. Run **one** implement tick by hand, with a human watching, and confirm all
   of: the workflow got its `artifactPath` (no `no artifactPath supplied`);
   the result was success-shaped with a `branchName`, not a systemic-shaped
   result (see [Systemic vs. per-artifact failures](#systemic-vs-per-artifact-failures));
   the artifact reached `status: implemented` with the `**Base:**`/
   `**Branch:**`/`**Summary:**`/`**In-game check:**` lines appended; the Implement worktree
   is gone (`git worktree list`) but the `backlog/<slug>` branch still exists
   locally (`git branch --list`) and is **not yet** on origin
   (`git ls-remote --heads origin backlog/<slug>` returns nothing).
3. Immediately run [Running a batch](#running-a-batch) by hand against just
   that one artifact — it will trigger below the usual batch-size threshold
   since there's only one, which is expected for this pilot, not a bug — and
   confirm: the build actually runs; the artifact's branch actually gets
   pushed to origin (`git ls-remote --heads origin backlog/<slug>` now finds
   it); a real PR exists at the returned `prUrl`; the artifact's status moved
   to `done` with a `**Result:**` line.
4. Close the throwaway PR, delete its branch and worktree, and delete the
   throwaway artifact.

Only then start `/loop backlog-drain` against the real backlog. If either
pilot call comes back systemic-shaped or complaining about missing args, the
invocation is broken in this environment — fix that before feeding it a
backlog. Even after a clean pilot, watch the first few real ticks and the
first real batch rather than walking away: only a batch pass pushes branches
and opens PRs now, and it does so for every artifact accumulated in it at
once, not just one.

## Notes

- An individual implement tick no longer pushes or opens anything — it just
  leaves a local commit on a local `backlog/<slug>` branch. Only a
  `backlog-batch` pass pushes branches and opens PRs on GitHub, once per
  accumulated batch rather than once per artifact. This is still autonomous
  by design (see
  `docs/superpowers/specs/2026-08-11-backlog-workflow-design.md`) — review
  happens at the PR, not before.
- `failed` artifacts are never retried automatically. To give one another
  attempt, in this order: read its `**Failure notes:**`; remove the stale
  worktree and branch the failed attempt left behind (`git worktree remove
  <path>` then `git branch -D <branch>` — the note records both); fix the
  artifact or the underlying ambiguity that caused the failure; then set
  `status: pending` by hand. Skipping the worktree removal makes the retry fail
  again with a confusing, unrelated-looking error — git refuses to check out a
  branch that's already checked out in another worktree. Unlike the old
  one-shot flow, a `failed` tick's branch was never pushed — `backlog-issue`
  no longer has a PR phase to fail at — so there's no remote branch to clean
  up here; a stuck-mid-push risk now lives in `backlog-batch` instead (see
  [Running a batch](#running-a-batch)).
- `in-progress` artifacts left behind by a crashed tick are surfaced every
  tick (never silently ignored) but never auto-recovered: check whether a PR
  was already opened for it before resetting its `status` to `pending` by
  hand, and clean up its worktree and branch first, exactly as for `failed`.
  In practice this check should come back negative more often than it used
  to — an `in-progress` crash happens before the artifact ever reaches
  `implemented`, and only a later `backlog-batch` pass opens a PR — but it's
  still worth confirming by hand rather than assuming.
- Branches are cut fresh from `origin/cm-main` when their tick starts, unless
  the artifact declares `depends-on:` on a still-unmerged dependency — see
  `docs/backlog/README.md#dependencies` — in which case the branch is cut
  from the dependency's branch instead. Independent artifacts (no
  `depends-on:`, or one whose dependency already merged) keep the original
  failure isolation: one artifact failing costs nothing to any other branch.
