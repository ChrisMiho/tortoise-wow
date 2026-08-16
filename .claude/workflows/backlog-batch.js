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
  },
  required: ['integrationBranch'],
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

   Return the branch name you created and, if any, the artifactPath values
   you had to exclude.`,
  { phase: 'Integrate', isolation: 'worktree', label: 'integrate', schema: INTEGRATE_SCHEMA }
)

if (!integrated || !integrated.integrationBranch) {
  return { success: false, reason: 'integrate phase failed to produce a branch' }
}

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
  `On branch "${integrated.integrationBranch}" (in its own worktree), build the
   Docker image per docs/superpowers/plans/2026-08-11-docker-build-from-this-checkout.md:
   "docker build" from the repo root of that worktree. The Dockerfile already
   bakes in -DBUILD_PLAYERBOTS=ON -DCMAKE_INSTALL_PREFIX=/opt/turtle and a
   BUILD_JOBS default of 10 (the Docker VM is now 16 CPUs/24GB, see
   docs/DOCKER.md) -- do not pass --build-arg BUILD_JOBS unless the build
   OOMs, in which case retry with --build-arg BUILD_JOBS=4.

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
   starting a ~10 minute compile, and fail immediately if it is empty.

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
const inGameChecklist = included.map((b) => `- ${b.artifactPath}: ${b.inGameCheck}`).join('\n')

const validated = await agent(
  `Check Docker readiness first: run "docker info" (from Windows PowerShell,
   the Windows-side CLI works even when the Ubuntu WSL distro itself can't
   see the docker command). If it's not ready or errors, return
   dockerReady: false and liveness: a one-sentence explanation, and do NOT
   attempt docker compose at all -- skip straight to reporting that back.

   If Docker is ready: do NOT hand-roll the compose invocation. Run the repo's
   gate script, which brings the stack up and refuses to report success unless
   provenance, image identity, and real liveness all pass:

     <main-checkout>/scripts/validate-stack.sh --image ${imageTag} \\
       --env-file <main-checkout>/.env --keep-up

   where <main-checkout> is the repository root of the ORIGINAL session
   directory, not this worktree -- .env is gitignored and exists only there.
   Resolve it with "git -C <worktree> worktree list": the FIRST entry is the
   main checkout. The script must be run from WSL, not Git Bash.

   Its last stdout line is "VALIDATE-STACK: PASS" or
   "VALIDATE-STACK: FAIL <reason>". Report that line verbatim in liveness.
   If it is FAIL, set dockerReady false and do not attempt any per-artifact
   check -- an unverified server cannot confirm anything, and a check that
   "passed" against a foreign or drifted image is worse than no check at all.

   Then, for each artifact below, attempt only what its inGameCheck says is
   confirmable from logs or console output (not everything is -- most checks
   here will legitimately be "not scriptable, needs a human" and that's
   expected, say so plainly rather than guessing at a result):

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
  const contestedSection = item.contested
    ? `
   8. A section headed "Contested — needs manual adjudication", listing exactly
      these and nothing else, one bullet per line:
${(item.contestedFindings || []).map((u) => `      - ${u}`).join('\n')}`
    : ''
  // minorFindings arrives as an array of already-formatted "- <file>:
  // <summary>" bullet strings (backlog-drain's SKILL.md persists them in
  // that exact form and reassembles them verbatim) -- not {file, summary}
  // objects, so use them as-is rather than re-formatting fields off them.
  const minorSection = item.minorFindings && item.minorFindings.length > 0
    ? `
   9. A section headed "Automated review — non-blocking findings", one bullet
      per line:
${item.minorFindings.map((line) => `      ${line}`).join('\n')}`
    : ''
  const stackedSection = base !== 'cm-main'
    ? `
   0. A line before everything else: "Stacked on ${item.dependsOnPrUrl || base} — merge that first."`
    : ''

  const prResult = await agent(
    `Push branch "${item.branchName}" to origin (it is unpushed local work from
     an earlier Implement+Review run), then open a pull request against base
     branch ${base}: "gh pr create --repo ${GH_REPO} --head ${item.branchName}
     --base ${base} --title ... --body ...".

     Title: ${item.contested ? '"[contested] " followed by a' : 'a'} short
     summary of the fix, in this repo's existing commit-message voice.

     Body must include, in this order:${stackedSection}
     1. The backlog artifact this implements: ${item.artifactPath}
     2. Problem, quoted verbatim: "${item.problem}"
     3. Summary of the change made: ${item.summary}
     4. Acceptance criteria, quoted verbatim: "${item.acceptanceCriteria}"
     5. This line, verbatim: "Build: ${imageTag} — run TW_IMAGE=${imageTag}
        docker compose up against this image to test (docker-compose.yml
        resolves the image via TW_IMAGE; a bare 'docker compose up' silently
        reuses whatever was built previously). Compose project is
        tortoise-cm." Followed by this line, verbatim: "This image
        contains every artifact in build ${buildId} merged together, not
        just this PR's change alone — if something looks off while testing,
        it may belong to a batch-mate rather than this PR."
     6. A section headed "In-game validation" containing this artifact's
        checklist item verbatim: "${item.inGameCheck}", followed by what was
        already attempted automatically in the shared batch validation pass:
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

return { success: true, buildId, imageTag, dockerReady: validated.dockerReady, results }
