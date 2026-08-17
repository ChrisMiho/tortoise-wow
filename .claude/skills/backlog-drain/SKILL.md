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

## One tick

1. Check for a stop request first: if `docs/backlog/.stop` exists, this is
   the terminal tick:
   - Before reporting the summary and calling `ScheduleWakeup({ stop: true })`,
     if any artifact is at `status: implemented`, run
     [Running a batch](#running-a-batch) once — even below the usual
     batch-size threshold — so nothing is left waiting on a batch that will
     never trigger.
   - Report a summary: how many artifacts are `done`, `failed`, stuck
     `in-progress`, still `implemented` (waiting on a future batch — should be
     none if the flush above just ran cleanly), and still `pending` (with
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
     - `**Summary:** <result.summary>`
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
   - **Failed** — `success: false` with no `blocked`, and a reason that's
     about this issue's own implementation or review: edit the artifact's
     frontmatter to `status: failed` and append a `**Failure notes:**
     <reason>` line — use the result's `reason` if present, otherwise record
     what was actually returned or thrown so it's triage-able. Include the
     stale worktree and branch location from step 9's lookup in that same
     line.
   - **Systemic failure** — the invocation itself is broken, not this artifact:
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
1, 3, 4, 5 — see [Stopping the loop](#stopping-the-loop)). Gather every
artifact at `status: implemented`:

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
   as a batch-wide failure, so getting this wrong costs a stopped loop rather
   than a corrupted image — but it still costs the loop.
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
5. On `{ success: false, reason }`: this is a **batch-wide** failure (a
   build break, or nothing left after integration exclusions) — not a
   per-artifact one. Leave every artifact in the batch at `status:
   implemented` (do not touch their status), and report the failure loudly
   with the `reason` and the full list of artifacts that were in the
   attempted batch, so a human can decide whether to retry, exclude a
   suspected artifact by hand, or investigate the build break directly. This
   is a stopping condition, not a continue-the-loop one — mirroring step 8's
   systemic-failure handling in "One tick": after step 6's commit and step
   7's cleanup below run as normal, call `ScheduleWakeup({ stop: true })`
   here rather than proceeding to step 8's continue. Without this, the next
   tick would implement one more artifact, hit the batch-size threshold
   again, and re-trigger this same failing batch — burning a full build
   cycle every retry until a human intervenes. Step 8 below does not apply
   when this path is taken.
6. Commit whatever status/body changes steps 4-5 produced, subject
   `backlog: batch ${buildId}`.
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
   running a batch does not itself end the drain. **Exceptions** (calling
   `ScheduleWakeup` twice in one tick would be a bug, so skip this step if
   either applies):
   - Step 5's batch-wide failure path was just taken — its own text already
     called `ScheduleWakeup({ stop: true })` above.
   - This batch was triggered by one of the terminal-tick flushes instead of
     step 11 — that terminal tick's own `ScheduleWakeup({ stop: true })`
     still runs right after, per its own instructions.

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

- `reason` is `no artifactPath supplied`, or otherwise says the args never
  arrived. Step 7 always passes one, so this means it didn't get through.
- The `Workflow` call threw.
- The result is unrecognizable — not an object, or no `success` field at all.

**Per-artifact** — the workflow ran, and something about *this* issue failed:
`implement phase failed to produce a change`, `implement phase returned an
unexpected branch name: ...`, `a review lens did not return a result`,
`blocking findings not addressed: ...`. These are the ones worth marking
`failed` and triaging. (A `backlog-batch` failure at Build, Validate, or PR
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

The loop also stops on its own for five reasons: the backlog is drained (step
4), two consecutive artifacts failed (step 3), every remaining `pending`
artifact is blocked on an unready dependency (step 5), a failure looked
systemic (step 8), or a batch pass itself failed (batch-wide, not
per-artifact — see "Running a batch" step 5). All five report before
stopping. The first three "One tick" reasons, plus the `.stop`-sentinel stop
above, also flush a final partial batch first if one is waiting (any artifact
at `status: implemented`) — see each step's own instructions — so a stop
never leaves artifacts stranded on a batch that would otherwise never
trigger. The systemic stop (step 8) deliberately does not flush: see its own
reasoning for why. The batch-wide-failure stop doesn't flush either — it *is*
the flush (or the batch pass a flush would have run), and it already stopped
because that very batch failed, so there's nothing further to flush before
stopping.

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
