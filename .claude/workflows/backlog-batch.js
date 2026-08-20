export const meta = {
  name: 'backlog-batch',
  description: 'Integrate a batch of implemented backlog branches, build once, validate in the stack, and open a PR per artifact',
  phases: [
    { title: 'Integrate' },
    { title: 'Build' },
    { title: 'Validate' },
    { title: 'PR' },
  ],
}

const PR_SCHEMA = {
  type: 'object',
  properties: {
    prUrl: { type: 'string' },
  },
  required: ['prUrl'],
}

const INTEGRATE_SCHEMA = {
  type: 'object',
  properties: {
    excludedArtifacts: {
      type: 'array',
      items: { type: 'string' },
    },
    integrationBranch: { type: 'string' },
    // Absolute path of the worktree the Integrate agent worked in. Build and
    // Validate both need it and neither runs with isolation: 'worktree', so
    // without this handoff the Build agent has to rediscover (or recreate) the
    // integration worktree itself -- which it did on 2026-08-17, wasting a
    // phase and risking a second worktree on the same branch.
    worktreePath: { type: 'string' },
  },
  required: ['integrationBranch', 'worktreePath'],
}

const BUILD_SCHEMA = {
  type: 'object',
  properties: {
    built: { type: 'boolean' },
    imageTag: { type: 'string' },
    failureNote: { type: 'string' },
  },
  required: ['built'],
}

const VALIDATE_SCHEMA = {
  type: 'object',
  properties: {
    dockerReady: { type: 'boolean' },
    liveness: { type: 'string' },
    perArtifactNotes: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          artifactPath: { type: 'string' },
          note: { type: 'string' },
        },
        required: ['artifactPath', 'note'],
      },
    },
  },
  required: ['dockerReady', 'liveness'],
}

const PR_URL_PATTERN = /^https:\/\/github\.com\/[^\s/]+\/[^\s/]+\/pull\/\d+\/?$/
const GH_REPO = 'ChrisMiho/tortoise-wow'
const BASE_BRANCH_PATTERN = /^(cm-main|backlog\/[a-z0-9][a-z0-9_-]*)$/
// Same pattern backlog-issue.js validates branchName against before ever
// returning it -- but that check happens on a different Workflow run, so a
// batch entry's branchName is untrusted here too by the time it reaches a
// real "git push"/"gh pr create --head" below.
const BRANCH_NAME_PATTERN = /^backlog\/[a-z0-9][a-z0-9_-]*$/

const describe = (value) => {
  let text
  try {
    text = typeof value === 'string' ? value : JSON.stringify(value)
  } catch {
    text = null
  }
  if (typeof text !== 'string') {
    text = String(value)
  }
  return text.length > 500 ? `${text.slice(0, 500)} (truncated)` : text
}

let normalizedArgs = args
if (typeof normalizedArgs === 'string') {
  try {
    normalizedArgs = JSON.parse(normalizedArgs)
  } catch {
    normalizedArgs = null
  }
}
if (!normalizedArgs || typeof normalizedArgs !== 'object') {
  normalizedArgs = {}
}

// backlog-drain computes buildId (it has access to a real clock; this script
// cannot use new Date()/Date.now()) and a list of batch entries, each already
// carrying everything Implement+Review produced for that artifact.
const buildId = typeof normalizedArgs.buildId === 'string' ? normalizedArgs.buildId.trim() : ''
const batch = Array.isArray(normalizedArgs.batch) ? normalizedArgs.batch : []

if (!buildId || batch.length === 0) {
  return { success: false, reason: 'no buildId or empty batch supplied' }
}

phase('Integrate')
const batchDescription = batch.map((b) =>
  `- ${b.artifactPath}: branch ${b.branchName}, base ${b.baseBranch || 'cm-main'}${b.dependsOnPrUrl ? ` (stacked on ${b.dependsOnPrUrl})` : ''}`
).join('\n')

const integrated = await agent(
  `Build a scratch integration branch named integration/${buildId}, cut fresh
   from origin/cm-main after "git fetch origin cm-main", so a build can cover
   this whole batch at once instead of one build per artifact:

   ${batchDescription}

   integration/${buildId} MUST NOT already exist -- check before you create it.
   If it does, this buildId collides with an earlier batch from the same day.
   A drain runs several batches per day and the sequence number is assigned by
   hand, so this is a real possibility, not a theoretical one. Do NOT reuse,
   reset, or merge onto the existing branch, and do NOT delete it: that ref is
   the only thing keeping the commit tortoise-cm:${buildId} was stamped from
   reachable, and reusing the tag would overwrite an already-validated image.
   Stop instead, and return every artifactPath in excludedArtifacts -- that
   reports the collision as a clean batch-wide failure rather than shipping
   this batch against the wrong image.

   Merge each artifact's branch onto integration/${buildId} in dependency
   order -- an artifact whose base above is another artifact's backlog/<slug>
   branch (not cm-main) must be merged after that dependency, never before.
   For artifacts with no dependency, order smallest-diff-first, matching the
   "blast radius, smallest first" approach in
   docs/superpowers/plans/2026-08-12-transport-stack-merge.md -- an early
   conflict or build failure is then cheaper to attribute.

   If a merge produces a real conflict, resolve it toward preserving BOTH
   sides' intent -- read docs/superpowers/specs/2026-08-11-backlog-workflow-design.md's
   "Field report" section first if you haven't: a conflict here is a
   silent-revert trap, not routine text reconciliation, because each branch
   was cut before the others' fixes existed. If you cannot confidently
   resolve a conflict without guessing which side is "correct", do NOT
   guess: abort that one artifact's merge (git merge --abort, or drop just
   its commits if you'd already progressed further), leave the rest of the
   batch merging normally, and list that artifact's path in
   excludedArtifacts so it's retried in a later batch instead of silently
   shipped wrong. Do not push integration/${buildId} anywhere -- it's a
   local scratch branch for the Build phase only, never a PR base.

   Return the branch name you created, the ABSOLUTE path of the worktree you
   are working in with integration/${buildId} checked out (run "git rev-parse
   --show-toplevel" inside it and return that, as worktreePath -- the Build and
   Validate phases run outside any worktree and build/validate against this
   path, so a missing or wrong value costs them a phase rediscovering it), and,
   if any, the artifactPath values you had to exclude.`,
  { phase: 'Integrate', isolation: 'worktree', label: 'integrate', schema: INTEGRATE_SCHEMA }
)

if (!integrated || !integrated.integrationBranch) {
  return { success: false, reason: 'integrate phase failed to produce a branch' }
}

// Build and Validate both need the integration worktree's path. If Integrate
// returned one, hand it over verbatim; if it didn't, tell the downstream agents
// how to find it rather than letting them assume the main checkout (which is on
// an unrelated branch and does NOT contain this batch's merges).
const integrationWorktree = typeof integrated.worktreePath === 'string' ? integrated.worktreePath.trim() : ''
const worktreeRef = integrationWorktree
  ? `the integration worktree at "${integrationWorktree}"`
  : `the integration worktree holding branch "${integrated.integrationBranch}" -- the Integrate phase did NOT report its path, so find it yourself with "git worktree list --porcelain" and take the "worktree <path>" line whose following "branch" line is refs/heads/${integrated.integrationBranch}. Do NOT fall back to the main checkout: it is on an unrelated branch and does not contain this batch's merges`

const excluded = new Set(Array.isArray(integrated.excludedArtifacts) ? integrated.excludedArtifacts : [])
const included = batch.filter((b) => !excluded.has(b.artifactPath))
if (included.length === 0) {
  return { success: false, reason: 'every artifact in the batch was excluded during integration -- nothing to build' }
}

phase('Build')
// tortoise-cm, matching docker-compose.yml's TW_IMAGE default and the rest of
// this repo's images. It was `tortoise-wow:` -- a third namespace belonging to
// nothing, which meant a batch build could never be compared against, rolled
// back to, or recognised by scripts/verify-running-commit.sh.
const imageTag = `tortoise-cm:${buildId}`
const built = await agent(
  `Build the Docker image from ${worktreeRef}, per
   docs/superpowers/plans/2026-08-11-docker-build-from-this-checkout.md:
   "docker build" from the repo root of that worktree. You are NOT running
   inside that worktree -- pass its path as the build context, do not cd into
   it and do not create a second worktree on the same branch (git refuses
   that anyway). Everywhere <worktree> appears below, it means that same
   path. The Dockerfile already
   bakes in -DBUILD_PLAYERBOTS=ON -DCMAKE_INSTALL_PREFIX=/opt/turtle and a
   BUILD_JOBS default of 14 (the Docker VM is 16 CPUs/24GB, see docs/DOCKER.md)
   -- do not pass --build-arg BUILD_JOBS unless the build OOMs, in which case
   retry with --build-arg BUILD_JOBS=4.

   Budget ~8.5 minutes and do not try to make it faster. There is NO incremental
   build here: "COPY . /src" does not cache-hit across builds, so every build
   recompiles all ~1169 translation units regardless of whether you changed one
   file or a hundred. Everything downstream of that COPY is invalidated before
   any cache is consulted, so no build-arg, cache mount or compiler cache can
   help. ccache was implemented and measured on 2026-08-16 -- cold 9m07s, no-op
   9m24s, one-file change 9m05s, zero cache hits in all three -- and reverted.
   Do not re-add it, and do not report a build as "slow" or "hung" merely
   because it recompiles everything; that is the normal, expected behaviour.

   You MUST pass the three provenance build args, exactly as scripts/rebuild.sh
   does. Without them the image carries no provenance labels, and
   scripts/validate-stack.sh can only ever return UNKNOWN against it -- meaning
   nobody can prove the server that gets validated was built from this repo:

     GIT_SHA        = git -C <worktree> rev-parse --short HEAD
     GIT_DIRTY      = git -C <worktree> status --porcelain --untracked-files=no | wc -l
     DOCKERFILE_SHA = sha256sum <worktree>/Dockerfile | cut -c1-12

   So the command is:

     docker build -t ${imageTag} \\
       --build-arg GIT_SHA=<sha> \\
       --build-arg GIT_DIRTY=<count> \\
       --build-arg DOCKERFILE_SHA=<dfsha> \\
       <worktree>

   An empty GIT_SHA stamps the image "unknown" -- check it is non-empty BEFORE
   starting a ~8.5 minute compile, and fail immediately if it is empty.

   Run the build in the FOREGROUND and wait for it (~8.5 minutes). Do NOT
   background it, nohup it, or detach it. "docker build" streams from a client
   the daemon watches, so killing the client cancels the build -- a backgrounded
   build dies partway through and leaves no image and no error, just a truncated
   log. nohup does not help: WSL tears down the session's processes when the
   wsl.exe that started them exits. This has bitten more than one agent on this
   host; see docs/DOCKER.md, "Things that will cost you an afternoon".

   Set the command timeout to 600000 ms, which is the Bash tool's maximum --
   it silently clamps anything larger, so asking for 900000 gets you 600000
   and a build killed at exactly 10m00s. The build fits: 8m15s measured
   2026-08-17 at BUILD_JOBS=14, leaving ~90 s of margin. This is ONE
   foreground call, not two -- do not plan for a retry.

   Confirm the image actually exists before you report success. This, not the
   exit code, is what decides built: true/false:

     docker images --format '{{.Repository}}:{{.Tag}}' --filter reference=${imageTag}

   If that prints ${imageTag}, the build succeeded regardless of what the exit
   code was. If it prints nothing, the build genuinely did not produce an
   image -- report built: false with the actual error.

   ONE exit code is worth recognising: 143 (= 128 + SIGTERM) at almost exactly
   10m00s means the command hit that 600000 ms clamp, not that anything is
   wrong with the code. That was the normal outcome before BUILD_JOBS went to
   14, and it should no longer happen; if you see it, the build has regressed
   past the ceiling and that is worth reporting in failureNote whether or not
   the image exists. In that case re-running the identical command completes
   it -- BuildKit's layer cache survives the killed client and the second pass
   only has to redo the export -- but treat needing that as a finding, not as
   routine.

   Run "docker build" itself from Windows PowerShell directly against that
   worktree's path -- the build context is just the repo directory and needs
   no WSL path semantics. Do NOT use a wrapped "wsl -d Ubuntu -- bash -lc
   '...'" one-liner containing any variable -- that has previously returned
   plausible-but-wrong output silently rather than failing. If a WSL step is
   unavoidable for any part of this, write it to a script file first and
   invoke that file from PowerShell, never an inline wrapped one-liner.

   Report whether it built successfully. If it failed, report the actual
   compiler/linker error, not just "build failed" -- this feeds a bisection
   decision, not just a status flag.`,
  { phase: 'Build', label: 'build', schema: BUILD_SCHEMA }
)

if (!built || built.built !== true) {
  // A batch build failure is NOT a per-artifact failure -- nothing in this
  // batch is provably broken individually, the combination might just not
  // compile. Leave every included artifact at status: implemented (backlog-drain
  // does not touch their status on this branch of the return) so a human can
  // bisect or retry, rather than marking N artifacts failed for one build break.
  return {
    success: false,
    reason: `batch build failed: ${built ? (built.failureNote || 'no failure detail returned') : describe(built)}`,
  }
}

phase('Validate')
// The artifact file is the source of truth for every long field, and the batch
// entries carry only identifiers. Inlining summary/problem/acceptanceCriteria/
// inGameCheck into the args instead cost ~11 KB per artifact -- 43 KB for a
// batch of four, measured 2026-08-17 -- which the drain has to reproduce
// verbatim on every call. That scales linearly with batch size, and every
// character of it is a chance to paraphrase something the PR body is supposed to
// quote exactly. Reading the file is both cheaper and more faithful: the tick
// already wrote those lines onto the artifact (backlog-drain SKILL.md step 8),
// and the batch runs after it.
const inGameChecklist = included.map((b) => `- ${b.artifactPath}`).join('\n')

const validated = await agent(
  `The image ${imageTag} was built from ${worktreeRef}. Everywhere <worktree>
   appears below, it means that path -- you are NOT running inside it, so pass
   it explicitly to every command that needs it.

   Check Docker readiness first: run "docker info" (from Windows PowerShell,
   the Windows-side CLI works even when the Ubuntu WSL distro itself can't
   see the docker command). If it's not ready or errors, return
   dockerReady: false and liveness: a one-sentence explanation, and do NOT
   attempt docker compose at all -- skip straight to reporting that back.

   If Docker is ready: do NOT hand-roll the compose invocation. Run the repo's
   gate script, which brings the stack up and refuses to report success unless
   provenance, image identity, and real liveness all pass:

     TW_SRC_DIR=<worktree> GIT_DIR=<the worktree's real gitdir, see below> \\
       <main-checkout>/scripts/validate-stack.sh \\
       --image ${imageTag} --env-file <main-checkout>/.env --keep-up

   where <main-checkout> is the repository root of the ORIGINAL session
   directory, not this worktree -- .env is gitignored and exists only there.
   Resolve it with "git -C <worktree> worktree list": the FIRST entry is the
   main checkout. The script must be run from WSL, not Git Bash. If you launch
   it from Git Bash as "wsl -d Ubuntu -- bash <path>", prefix the whole command
   with MSYS_NO_PATHCONV=1: MSYS rewrites a standalone "/mnt/c/..." argument
   into "C:/Program Files/Git/mnt/c/...", so the script appears not to exist. A
   path inside a longer "bash -lc '...'" string is not rewritten.

   TW_SRC_DIR is NOT optional here. The gate compares the image's stamped
   revision against HEAD of the repo it reads git from, which defaults to the
   checkout the script lives in -- the main checkout. This image was built from
   the worktree at "${integrated.integrationBranch}", whose HEAD is a different
   commit, so without this override gate 1 reports DRIFT on every batch run and
   nothing downstream is ever validated. Point it at the worktree and it
   compares against the commit the image was actually built from. Compose still
   runs from the main checkout, which is where docker-compose.yml and .env live,
   so only the git comparison moves.

   GIT_DIR is NOT optional either, and unlike TW_SRC_DIR this one is not a
   theory -- it is the failure that actually happened on the first real batch,
   2026-08-16. A worktree's ".git" is a FILE, not a directory, holding one line
   like "gitdir: C:/Coding/tortoise-wow/tortoise-wow/.git/worktrees/<name>".
   That is a WINDOWS path, and git running under WSL cannot resolve it, so the
   gate's provenance step dies with "fatal: not a git repository" and gate 1
   reports:

     VALIDATE-STACK: FAIL FOREIGN -- revision <sha> is not a commit in this repository

   That FOREIGN is FALSE. The revision is the worktree's own HEAD and the exact
   commit the image was built from. Do not go looking for a real provenance
   problem, and do not rebuild. Fix it instead: read <worktree>/.git, rewrite
   the "C:/..." path it names into its "/mnt/c/..." form, and export that as
   GIT_DIR alongside TW_SRC_DIR. The commondir recorded inside it is the
   relative "../..", which resolves correctly once GIT_DIR itself does. With
   both set, gate 1 provenance, gate 2 image identity and gate 3 liveness all
   pass.

   Its last stdout line is "VALIDATE-STACK: PASS" or
   "VALIDATE-STACK: FAIL <reason>". Report that line verbatim in liveness.
   If it is FAIL, set dockerReady false and do not attempt any per-artifact
   check -- an unverified server cannot confirm anything, and a check that
   "passed" against a foreign or drifted image is worse than no check at all.

   Report that line accurately in either direction, because the PR phase is
   gated on it: a FAIL stops this batch outright and nothing gets pushed, while
   a PASS you did not actually observe would ship unverified work as a
   ready-to-merge pull request. Exhaust the GIT_DIR fix above before you accept
   a FOREIGN failure as real.

   Then, for each artifact listed at the end of this prompt, READ THAT ARTIFACT
   FILE and find its "**In-game check:**" section -- the implement tick appended
   it there, and it is the checklist for that artifact. Attempt only what it says
   is confirmable from logs or console output (not everything is -- most checks
   here will legitimately be "not scriptable, needs a human" and that's
   expected, say so plainly rather than guessing at a result).

   RUN THOSE CHECKS AGAINST THE INTEGRATION WORKTREE, not against whatever path
   the checklist names. Each inGameCheck was written by an agent working inside
   its own worktree, and they routinely hardcode the MAIN checkout path -- e.g.
   "cd /mnt/c/Coding/tortoise-wow/tortoise-wow && bash tests/...". The main
   checkout sits on an unrelated branch and does NOT contain this batch's
   changes, so those commands fail with "No such file or directory", which
   looks exactly like a broken implementation and is not one. Substitute the
   integration worktree's path for the repo root in every such command: that
   tree holds the merged batch and is the one the image was built from. If a
   check still fails after that substitution, THAT is a real result worth
   reporting:

   ${inGameChecklist}

   For each one, return one entry in perArtifactNotes: what you actually
   attempted, and what you observed or why it wasn't scriptable. Do not claim
   you confirmed something you only assumed.

   Whether or not the build/validation was clean, finish by bringing the stack
   back down before you return, so it is never left running unattended:

     docker compose --env-file <main-checkout>/.env down

   Plain "down". NEVER "down -v" -- tortoise-wow-v2_dbdata is the entire world.
   This must happen even if something above failed or looked wrong.`,
  { phase: 'Validate', label: 'validate', schema: VALIDATE_SCHEMA }
)

if (!validated) {
  return { success: false, reason: 'validate phase did not return a result' }
}

// A failed gate means the image was never verified -- so do not push branches
// or open PRs off it. Previously the only check here was the null check above,
// so a "VALIDATE-STACK: FAIL" still fell through to the PR phase and shipped
// pull requests whose "In-game validation" section quoted a validation that had
// failed, while the workflow returned success: true. Unattended, that is the
// worst possible outcome: unverified work merged-ready with a note nobody reads.
//
// This is a BATCH-WIDE failure, not a per-artifact one -- nothing in the batch
// is provably broken on its own, the build merely isn't trusted. backlog-drain
// leaves every artifact at status: implemented and stops the loop, which is the
// designed response (see its "Running a batch" step 5).
const livenessText = typeof validated.liveness === 'string' ? validated.liveness : ''
const gatePassed = /VALIDATE-STACK:\s*PASS/.test(livenessText) && !/VALIDATE-STACK:\s*FAIL/.test(livenessText)
if (validated.dockerReady !== true || !gatePassed) {
  return {
    success: false,
    reason: `stack validation did not pass for build ${imageTag} -- nothing was pushed and no PR was opened. `
      + `dockerReady=${describe(validated.dockerReady)}, liveness=${describe(validated.liveness)}. `
      + `If liveness says FOREIGN, check GIT_DIR was exported alongside TW_SRC_DIR before concluding the image is bad.`,
  }
}

phase('PR')
const perArtifactNote = (artifactPath) => {
  const entry = Array.isArray(validated.perArtifactNotes)
    ? validated.perArtifactNotes.find((n) => n.artifactPath === artifactPath)
    : null
  return entry ? entry.note : 'not attempted'
}

const results = []
for (const item of included) {
  if (!BRANCH_NAME_PATTERN.test(item.branchName || '')) {
    // Never let an unvalidated branchName reach "git push"/"gh pr create
    // --head" below -- exclude this artifact from the batch's git/gh
    // commands the same way an Integrate-phase exclusion does, rather than
    // trusting or silently defaulting it the way baseBranch does.
    results.push({
      artifactPath: item.artifactPath,
      branchName: item.branchName,
      contested: Boolean(item.contested),
      excluded: true,
      prUrl: null,
      prReason: `branchName failed validation before push/PR, got: ${describe(item.branchName)}`,
    })
    continue
  }
  const base = BASE_BRANCH_PATTERN.test(item.baseBranch || '') ? item.baseBranch : 'cm-main'
  // Contested and minor findings both live on the artifact as "**Contested:**"
  // and "**Minor findings:**" bullet blocks, written by the implement tick. Only
  // the contested BOOLEAN travels in the args, because it changes the PR title
  // and the status the drain assigns; the findings themselves are read from the
  // file like everything else.
  const contestedSection = item.contested
    ? `
   8. A section headed "Contested — needs manual adjudication", listing exactly
      the artifact's "**Contested:**" bullets and nothing else, one per line.`
    : ''
  const minorSection = `
   9. If, and only if, the artifact has a "**Minor findings:**" block, a section
      headed "Automated review — non-blocking findings" reproducing those bullets
      verbatim, one per line. Omit the whole section if it has none.`
  const stackedSection = base !== 'cm-main'
    ? `
   0. A line before everything else: "Stacked on ${item.dependsOnPrUrl || base} — merge that first."`
    : ''

  const prResult = await agent(
    `FIRST, read the backlog artifact at ${item.artifactPath}. It holds every
     piece of prose this pull request body needs, and it is the authority for
     all of them -- do not paraphrase, summarise or reformat anything you take
     from it:
       - its "**Problem:**" section
       - its "**Acceptance criteria:**" section
       - the "**Summary:**" line the implement tick appended
       - the "**In-game check:**" section
       - its "**Minor findings:**" bullets, if it has any
       - its "**Contested:**" bullets, if it has any
     These are read from the file rather than passed in, because passing them
     inline cost ~11 KB per artifact and every character was a chance to alter
     text the PR body is meant to quote exactly.

     Then push branch "${item.branchName}" to origin (it is unpushed local work
     from an earlier Implement+Review run), and open a pull request against base
     branch ${base}: "gh pr create --repo ${GH_REPO} --head ${item.branchName}
     --base ${base} --title ... --body ...". Write the body to a file and use
     --body-file; these bodies contain backticks and newlines that do not
     survive being passed as a shell argument.

     WRITE THAT FILE OUTSIDE THE REPOSITORY, in the OS temp directory --
     "$env:TEMP\\pr-body-${buildId}.md" from PowerShell, "$TMPDIR/..." or
     /tmp from a POSIX shell -- and DELETE it once "gh pr create" has
     returned. Earlier runs left pr-body-*.md and scratchpad-*.md sitting
     untracked in the repo root, where the drain's next "git status" reads
     them as unexplained working-tree dirt and a stray "git add ." would
     commit them. Never create any scratch file inside the working tree.

     Title: ${item.contested ? '"[contested] " followed by a' : 'a'} short
     summary of the fix, in this repo's existing commit-message voice.

     Body must include, in this order:${stackedSection}
     1. The backlog artifact this implements: ${item.artifactPath}
     2. The artifact's Problem section, quoted verbatim
     3. Summary of the change made: the artifact's "**Summary:**" line
     3b. A REQUIRED section headed "Files changed", holding the literal output
        of:

          git diff --name-status origin/${base}...${item.branchName}

        one line per file, inside a fenced code block. Do not summarise it, do
        not filter it, do not sort it, do not stop at "the interesting ones".
        This section exists because the "**Summary:**" line above is prose an
        agent wrote about what it MEANT to change, and on 016 it silently
        omitted a whole set of battleground edits the diff actually contained.
        The file list is derived from git and cannot omit anything, so it is
        the only part of this body a reviewer can trust to be complete. If the
        diff touches a file the Summary line does not account for, add one
        sentence under the code block naming that file and saying the summary
        does not cover it -- do not rewrite the Summary line to hide the gap.
     4. The artifact's Acceptance criteria section, quoted verbatim
     5. This line, verbatim: "Build: ${imageTag} — run TW_IMAGE=${imageTag}
        docker compose up against this image to test (docker-compose.yml
        resolves the image via TW_IMAGE; a bare 'docker compose up' silently
        reuses whatever was built previously). Compose project is
        tortoise-cm." Followed by this line, verbatim: "This image
        contains every artifact in build ${buildId} merged together, not
        just this PR's change alone — if something looks off while testing,
        it may belong to a batch-mate rather than this PR."
     6. A section headed "In-game validation" containing the artifact's
        "**In-game check:**" section verbatim, followed by what was already
        attempted automatically in the shared batch validation pass:
        "${perArtifactNote(item.artifactPath)}"
     7. A line stating this is a single-developer server: manual in-game
        testing is still required from you before merge${contestedSection}${minorSection}

     Return the URL of the pull request you opened, and nothing else in that
     field. If you could not push or open the PR, say so in prUrl rather than
     inventing a URL.`,
    { phase: 'PR', label: `open-pr:${item.artifactPath}`, schema: PR_SCHEMA, model: 'sonnet', effort: 'low' }
  )

  const prUrl = prResult && typeof prResult === 'object' ? prResult.prUrl : prResult
  const trimmedPrUrl = typeof prUrl === 'string' ? prUrl.trim() : ''
  results.push({
    artifactPath: item.artifactPath,
    branchName: item.branchName,
    contested: Boolean(item.contested),
    excluded: false,
    prUrl: PR_URL_PATTERN.test(trimmedPrUrl) ? trimmedPrUrl : null,
    prReason: PR_URL_PATTERN.test(trimmedPrUrl) ? null : `PR phase did not return a pull request URL, got: ${describe(prResult)}`,
  })
}

for (const artifactPath of excluded) {
  results.push({ artifactPath, excluded: true })
}

// If NOT ONE pull request was opened, nothing reached origin, and that is a
// batch-wide failure -- not N per-artifact ones. Returning success: true here
// used to be self-perpetuating rather than merely wrong: backlog-drain leaves
// every artifact at status: implemented on that path, and its step 11 re-counts
// implemented artifacts every tick to decide whether to batch. So the threshold
// stayed met and EVERY subsequent tick fired another ~10 minute build, with the
// batch growing each time and nothing ever stopping it -- the circuit breaker
// only counts `failed`, and the batch-wide stop needs success: false. An
// expired gh token or a network blip partway through an unattended run would
// be enough to trigger it, and it would then consume the rest of the window in
// ~10 minute builds with no PR to show for any of them. (Found by reading the
// code during the 2026-08-17 guardrail check, before it had a chance to fire.)
// Failing here routes into "Running a batch" step 5, which stops the loop and
// leaves the artifacts implemented for a human to retry.
//
// A PARTIAL failure deliberately still returns success: true: at least one PR
// exists, the batch made real progress, and the artifacts that missed out drop
// back below the threshold and are picked up by the next batch normally.
const opened = results.filter((r) => r.prUrl)
if (opened.length === 0) {
  const perArtifact = results
    .filter((r) => !r.prUrl && r.prReason)
    .map((r) => `${r.artifactPath}: ${r.prReason}`)
    .join(' | ')
  return {
    success: false,
    reason: `batch ${buildId} built and validated as ${imageTag}, but not one pull request was opened -- `
      + `nothing reached origin. This is usually gh auth or connectivity, not the code: check `
      + `"gh auth status" before retrying, since the image itself already passed the stack gate. ${perArtifact}`,
  }
}

return { success: true, buildId, imageTag, dockerReady: validated.dockerReady, results }
