export const meta = {
  name: 'backlog-issue',
  description: 'Implement and review one scoped backlog issue on a local branch; a later backlog-batch pass builds, validates, and opens the PR.',
  phases: [
    { title: 'Implement' },
    { title: 'Review' },
  ],
}

// Review lenses run at medium effort by default (see
// docs/superpowers/plans/2026-08-12-backlog-issue-model-tuning.md) — but keep
// the session's full tier for artifacts with risk: high, where a mid-tier
// lens is more likely to miss a subtle finding. There is no automated
// escalation yet; a human editing this file for a high-risk drain run should
// drop the effort override for that run.
const REVIEW_SCHEMA = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          summary: { type: 'string' },
          file: { type: 'string' },
          severity: { type: 'string', enum: ['blocking', 'minor'] },
          blocked: { type: 'boolean' },
        },
        required: ['summary', 'file', 'severity'],
      },
    },
  },
  required: ['findings'],
}

const IMPLEMENT_SCHEMA = {
  type: 'object',
  properties: {
    branchName: { type: 'string' },
    summary: { type: 'string' },
    problem: { type: 'string' },
    acceptanceCriteria: { type: 'string' },
    blocked: { type: 'boolean' },
    blockedReason: { type: 'string' },
    inGameCheck: { type: 'string' },
  },
  required: ['branchName', 'summary', 'problem', 'acceptanceCriteria', 'inGameCheck'],
}

const FIX_SCHEMA = {
  type: 'object',
  properties: {
    fixed: { type: 'boolean' },
    unresolved: { type: 'array', items: { type: 'string' } },
  },
  required: ['fixed'],
}

// The Implement phase's branch name flows straight into a real "git push" in a
// later batch step, so it is validated rather than trusted here. backlog-scope
// slugifies titles to lowercase
// words joined by hyphens, and the branch slug is that filename minus its NNN-
// prefix and .md suffix, so a well-formed branch is always backlog/<slug>.
// Underscores are tolerated; dots are not, because they would allow ".." and a
// trailing ".lock" -- both of which git rejects in a ref anyway.
const BRANCH_NAME_PATTERN = /^backlog\/[a-z0-9][a-z0-9_-]*$/

// Turn whatever an agent actually returned into something short and printable,
// so a rejected result is debuggable from the drain skill's failure notes.
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

const artifactPath = normalizedArgs.artifactPath
if (!artifactPath) {
  return { success: false, reason: 'no artifactPath supplied' }
}

// backlog-drain passes an absolute path (a relative one is fragile across the
// Implement phase's branch switch), but an absolute path pasted into a PR body
// leaks a machine-specific location. Derive a repo-relative label for the PR.
const normalizedArtifactPath = String(artifactPath).replace(/\\/g, '/')
const backlogDirIndex = normalizedArtifactPath.lastIndexOf('docs/backlog/')
const artifactLabel = backlogDirIndex >= 0
  ? normalizedArtifactPath.slice(backlogDirIndex)
  : normalizedArtifactPath.slice(normalizedArtifactPath.lastIndexOf('/') + 1)

// This fork's trunk is cm-main, not playerbots-integration-gh -- the latter is a
// pristine fast-forward-only mirror of upstream that is never committed to
// directly (see docs/BRANCHING.md).
//
// BASE_BRANCH is normally cm-main, but backlog-drain resolves it to a
// dependency's own backlog/<slug> branch when the artifact declares
// depends-on: and that dependency's PR hasn't merged yet -- targeted
// stacking, not a fresh cm-main cut every tick. Every phase below already
// references BASE_BRANCH by template literal, so this is the only line that
// needs to change for stacking to propagate through Implement/Review.
//
// Validated rather than trusted, same reasoning as branchName below: this
// flows straight into "git fetch" and "git diff", so an unexpected value
// fails safe to cm-main rather than being passed through.
const BASE_BRANCH_PATTERN = /^(cm-main|backlog\/[a-z0-9][a-z0-9_-]*)$/
const requestedBaseBranch = typeof normalizedArgs.baseBranch === 'string' ? normalizedArgs.baseBranch.trim() : ''
let BASE_BRANCH
if (BASE_BRANCH_PATTERN.test(requestedBaseBranch)) {
  BASE_BRANCH = requestedBaseBranch
} else {
  if (requestedBaseBranch) {
    log(`baseBranch was not a recognized ref (got ${JSON.stringify(normalizedArgs.baseBranch)}) -- defaulting to cm-main`)
  }
  BASE_BRANCH = 'cm-main'
}

phase('Implement')
const implemented = await agent(
  `Read the backlog artifact at ${artifactPath} FIRST, before creating or switching
   to any branch. That file is often still uncommitted when this runs, so reading
   it after a branch switch is unreliable — read it now and keep its contents.
   It scopes one bug fix for the Tortoise-WoW mangos server fork (a C++ codebase).

   Then run "git fetch origin ${BASE_BRANCH}" and cut your new branch
   from origin/${BASE_BRANCH} — not from the plain local
   ${BASE_BRANCH} ref, which can lag arbitrarily far behind origin
   during a long unattended drain, and never from playerbots-integration-gh,
   which is a pristine fast-forward-only mirror this fork never commits to.
   Name the branch
   backlog/<the artifact's filename with its NNN- numeric prefix and .md
   extension stripped> — e.g. 003-bots-stuck-at-spirit-healer.md gives
   backlog/bots-stuck-at-spirit-healer. Nothing else is an acceptable branch
   name; a later phase pushes exactly what you return here.

   On that branch, implement exactly what the artifact's Problem, Suspected
   cause/area, and Acceptance criteria sections describe — nothing more.
   Commit the change with a message in this repo's existing terse, bug-report
   commit style (run "git log --oneline -20" first to match the voice).
   Do not push and do not open a PR — a later phase does that.

   If this fix requires a new SQL migration under sql/database_updates/,
   generate its filename with sql/touch_migration.sh (or sql/make_migration.bat
   on Windows) to get a real UTC timestamp — do not hand-write a timestamp.
   Then rename the resulting file to insert this artifact's number before the
   suffix: <timestamp>_${artifactLabel.match(/(\d{3})-/)?.[1] || 'XXX'}_world.sql
   instead of <timestamp>_world.sql. This guarantees uniqueness even if
   another tick generates a migration with the same timestamp — the artifact
   number differs by construction.

   THE LIVE STACK IS AVAILABLE TO YOU. You may start, stop and restart
   containers, query the database, and send console commands, if an acceptance
   criterion actually needs it. Bring up only what you need -- most work needs
   the database alone, which requires no server image and no build:

     docker compose --env-file <main-checkout>/.env up -d db

   Resolve <main-checkout> with "git -C <this worktree> worktree list"; the
   FIRST entry is the main checkout, and .env is gitignored so it exists only
   there. Wait for "docker inspect --format '{{.State.Health.Status}}' tcm-db"
   to read healthy, about 20 seconds.

   Six rules on that access. Most have already cost someone a session:

   1. NEVER destroy the database volume. tortoise-wow-v2_dbdata is the entire
      world and it has been lost once already. Know which commands can
      actually do it, because the notorious one cannot:
      - "docker compose down -v" FROM THIS REPO is inert against it. The
        volume is declared external: true in docker-compose.yml, and compose
        never creates or removes an external volume. Measured 2026-08-17
        against throwaway stacks: the external volume survived, a managed
        control volume was destroyed by the same command. Still prefer plain
        "down" -- the habit is what protects you if anyone ever edits that
        external: declaration out.
      - "docker compose down -v" run from ~/tortoise-wow-server-V2 DOES
        destroy it. That stack is compose project tortoise-wow-v2 and declares
        the same volume as MANAGED -- which is where the volume's name comes
        from, and almost certainly how it was lost the first time. You have no
        reason to run anything from that directory.
      - "docker volume prune", "docker system prune --volumes" and Docker
        Desktop's cleanup button destroy it outright. "external" is a
        compose-file concept the Docker engine knows nothing about, so with
        the stack down the engine reports this volume 100% reclaimable. THESE
        are the commands that actually cost you the world. Never run them.
   2. NEVER delete or retag images to reclaim space. "docker image prune -a"
      takes tortoise-cm:c06b2fb, the rollback anchor -- and because of rule 4
      nothing rebuilds it during a drain, so that is the only working server
      gone, with a ~10 minute compile as the cheapest way back. Plain "docker
      image prune" (no -a) is safe. Do not delete integration/* branches or
      their images either: that branch ref is the only thing keeping a built
      image's stamped commit reachable, and without it the image can never be
      validated again.
   3. NEVER a bare "docker attach". Use wsg_console from
      docs/playerbots/wsg/lib/wsg-bots-common.sh, which detaches properly, and
      batch your commands into as few attaches as you can. mangosd treats
      console EOF as "shut down the world". It currently runs
      restart: unless-stopped, so an EOF costs a restart and every online
      session's unsaved state rather than a permanently dead world -- but a
      match in progress is still lost, and db is restart:"no".
   4. DO NOT run a Docker build. There is no incremental build here -- "COPY .
      /src" never cache-hits, so every build recompiles all ~1169 translation
      units and takes ~8.5 minutes no matter what changed. A later
      backlog-batch pass builds this branch together with its batch; that is
      the compile gate, and running one here just burns ten minutes.
   5. Because of 4, THE RUNNING SERVER IS ALWAYS AN OLDER BUILD THAN YOUR
      BRANCH -- but it is NOT necessarily the rollback anchor, and the
      difference decides whether a failed command means anything. Find out
      which image you are actually talking to before drawing any conclusion
      from a console response:

        docker ps --format '{{.Names}} {{.Image}}'
        docker images --format '{{.Repository}}:{{.Tag}}' --filter reference=tortoise-cm

      A backlog-batch pass validates each batch with --keep-up, so it leaves
      the stack UP on tortoise-cm:<buildId>, and .env's TW_IMAGE tracks that
      same tag. That image contains every artifact batched before yours --
      including this series' own tournament commands and scripts. So:
      - A command from an EARLIER artifact in this series (e.g. "tournament
        team", "tournament instance") SHOULD work against it. If it does not,
        that is a real finding worth reporting, not an expected absence.
      - A command added by THIS artifact does NOT exist in any image on this
        host, because nothing has compiled your branch yet. "There is no such
        subcommand" for your own new command proves nothing about your code:
        do not treat it as a failure and do not rewrite working code chasing
        it.
      - tortoise-cm:c06b2fb is the rollback anchor and predates the whole
        series. If that is what is running, only cm-main commands (rndbot,
        .bg) work, and everything from this series is legitimately absent.
      Exercise what you can against whatever is actually running -- shell
      scripts under scripts/tournament/ and any console command that already
      shipped are testable right now, and testing them is better evidence than
      reasoning about them. Never "fix" the running server by building; that
      is rule 4.
   6. Run scripts from WSL, never Git Bash: jq is absent from Git Bash on this
      host and require_cmd hard-exits, and MSYS rewrites POSIX paths into C:\
      ones. Do NOT put a variable inside a wrapped "wsl -d Ubuntu -- bash -lc
      '...'" one-liner -- that returns plausible-but-wrong output silently.
      Write a script file and invoke that. Invoking it is its own trap: MSYS
      rewrites any STANDALONE argument beginning with "/", so from Git Bash
      "wsl -d Ubuntu -- bash /mnt/c/path/script.sh" dies with "No such file or
      directory" naming "C:/Program Files/Git/mnt/c/path/script.sh" -- a path
      you never typed, and nothing to do with your script. Prefix the command
      with MSYS_NO_PATHCONV=1, or invoke it from PowerShell. A path INSIDE a
      longer argument (bash -lc 'cd /mnt/c/... && ...') is NOT rewritten, which
      is why that form works and the bare one does not.

   One more Windows/WSL trap, and it will bite any git command you run from
   WSL inside this worktree: a worktree's ".git" is a FILE, not a directory,
   holding one line like
   "gitdir: C:/Coding/tortoise-wow/tortoise-wow/.git/worktrees/<name>". That is
   a WINDOWS path, which git under WSL cannot resolve, so git there fails with
   "fatal: not a git repository" even though the worktree is perfectly valid.
   Do not conclude your checkout is broken. Either run git from the Windows
   side (PowerShell or Git Bash, both fine), or export GIT_DIR with that same
   path rewritten into its "/mnt/c/..." form. This cost the first batch run a
   false provenance failure before it was diagnosed.

   One trap worth knowing when you do query the database: wsg_mysql sends
   stderr to /dev/null, so a query that fails returns silence rather than an
   error, and reads exactly like "no rows matched". If a query unexpectedly
   returns nothing, re-run it through a bare "docker exec ... mysql" with
   stderr visible before drawing any conclusion from the emptiness.

   If, after investigating, the artifact's acceptance criteria cannot be
   satisfied in this environment -- missing data, missing tooling, a decision
   only a human can make, not something any code change here can fix -- say
   so plainly. Still create the branch (backlog-drain needs a real branch
   name back either way), but make no commit, return blocked: true, and put
   a specific explanation in blockedReason. Do not fabricate data or write a
   partial implementation to make the criteria look satisfied when they
   aren't really verifiable.

   Describe, concretely, how a human would confirm this fix actually works
   in-game once it's running on a live server -- specific enough to follow as
   a checklist (e.g. "board the Menethil Harbor - Theramore boat as a bot and
   confirm it doesn't fall through the deck", not "test transports"). If part
   of that check could be confirmed from server logs or console output rather
   than requiring a human to look (e.g. a specific log line, an absence of a
   specific error), say so explicitly -- a later batch step will attempt
   whatever's actually scriptable and leave the rest for manual testing.
   Return this as inGameCheck. Every artifact needs one, even a low-risk
   change -- if you're confident it needs no in-game confirmation beyond the
   generic "server starts, bots spawn" smoke test, say that explicitly rather
   than leaving it vague.

   Return:
   - the exact branch name you created
   - a one-paragraph summary of the change you made
   - the artifact's Problem section, quoted verbatim
   - the artifact's Acceptance criteria section, quoted verbatim
   The last two are copied as-is so a later phase can put them in the PR
   description without re-reading the artifact itself.`,
  { phase: 'Implement', isolation: 'worktree', label: 'implement', schema: IMPLEMENT_SCHEMA }
)

if (!implemented) {
  // Same reasoning as the review-lens null below: agent() returns null only
  // when the subagent was skipped or died on a terminal API error, never
  // because the artifact was hard. Nothing here is evidence against
  // ${artifactLabel}, so this must not become a per-artifact `failed`.
  return {
    success: false,
    systemic: true,
    reason: `implement phase returned no result at all for ${artifactLabel} -- the subagent died on a terminal API error or was skipped, `
      + `which is not a statement about this artifact. Do NOT mark it failed; leave it pending and check API health before resuming.`,
  }
}

if (implemented.blocked === true) {
  return {
    success: false,
    blocked: true,
    reason: implemented.blockedReason || 'implement phase reported the acceptance criteria are unsatisfiable in this environment, with no reason given',
    branchName: typeof implemented.branchName === 'string' ? implemented.branchName.trim() : undefined,
  }
}

// Everything downstream -- including a later batch step's real "git push" --
// trusts this string. If the agent handed back the base branch (or anything
// else that isn't the backlog/<slug> branch it was told to create), stop here
// rather than letting a bad ref reach that push.
const branchName = typeof implemented.branchName === 'string' ? implemented.branchName.trim() : ''
if (!BRANCH_NAME_PATTERN.test(branchName)) {
  return {
    success: false,
    reason: `implement phase returned an unexpected branch name: ${describe(implemented.branchName)}`,
  }
}

phase('Review')
const lenses = [
  {
    key: 'correctness',
    prompt: 'Review this diff for logic bugs and for behavior that does not match the acceptance criteria in the artifact. If a finding is that the acceptance criteria are fundamentally unsatisfiable in this environment -- not something the implementer coded wrong, but something no code change here can fix -- set blocked: true on that finding in addition to severity: blocking.',
  },
  {
    key: 'lifetime-threading',
    prompt: 'Review this diff for pointer/reference lifetime issues and unsynchronized access to shared state. This server runs ~1000 concurrent playerbots and has a history of dangling-pointer and missing-lock bugs in exactly this kind of change. If a finding is that the acceptance criteria are fundamentally unsatisfiable in this environment -- not something the implementer coded wrong, but something no code change here can fix -- set blocked: true on that finding in addition to severity: blocking.',
  },
]
const reviews = await parallel(lenses.map((lens) => () =>
  agent(
    `${lens.prompt}

     Branch "${branchName}" has the change. Branch and remote-tracking refs are
     shared across worktrees in this repository, so run
     "git diff origin/${BASE_BRANCH}...${branchName}" directly from
     wherever you are -- no need to locate or check out that branch's worktree.
     Diff against origin/${BASE_BRANCH}, never the bare local
     ${BASE_BRANCH}: the branch was cut from origin (the Implement
     phase fetched it), and the local ref can lag behind, which would drag
     already-merged commits into what you're reviewing as if they were
     part of this change.
     Artifact for context: ${artifactPath}.

     Report every real finding with a one-sentence summary, the file it's in,
     and a severity of "blocking" or "minor". Return an empty findings array
     if there's nothing to flag.

     Give "file" as a REPO-RELATIVE path (scripts/tournament/roster.sh), never
     an absolute one. Minor findings are copied verbatim into the PR body, so
     an absolute path both leaks a machine-specific location and, since it
     names the main checkout, points at a path where this branch's file does
     not exist -- which reads to a human as a broken reference.

     IF YOUR REVIEW DIMENSION DOES NOT APPLY TO THIS DIFF AT ALL, an empty
     findings array is the correct and complete answer. Most artifacts in this
     backlog are entirely shell scripts, JSON config or documentation, and a
     lens looking for pointer lifetime or lock discipline has nothing to say
     about those -- that is expected, not a problem, and not a finding.

     Do NOT reach for blocked: true to express it. blocked: true is a claim
     about the ARTIFACT, not about your lens: it asserts that the artifact's
     own acceptance criteria cannot be satisfied in this environment no matter
     what anyone codes -- missing data, missing tooling, a decision only a
     human can make. It halts the work and requires a human to triage it. A
     lens that has merely found its own dimension irrelevant to the diff must
     never set it.`,
    { phase: 'Review', label: `review:${lens.key}`, schema: REVIEW_SCHEMA, effort: 'medium' }
  )
))

// agent() returns null when a subagent dies on a terminal API error after its
// own retries -- an Anthropic 529, a network blip, an overloaded window. That
// says nothing whatsoever about this artifact, but the original code returned a
// plain success: false here, which backlog-drain classes as a PER-ARTIFACT
// failure: the artifact gets status: failed, and two such nulls in a row trip
// the circuit breaker. During the API-529 outage on 2026-08-17 that would have
// burned two innocent artifacts to `failed` and stopped the loop blaming them.
//
// So: retry the missing lenses once (the outage is usually shorter than a lens
// run), and if they still come back empty, return a SYSTEMIC-shaped result.
// backlog-drain's "Systemic vs. per-artifact failures" section keys on the
// systemic: true flag and puts the artifact back to pending untouched.
let returnedReviews = reviews.filter(Boolean)
if (returnedReviews.length < lenses.length) {
  log(`${lenses.length - returnedReviews.length} review lens(es) returned nothing -- retrying once before treating it as a failure`)
  const retried = await parallel(lenses.map((lens, i) => () =>
    reviews[i]
      ? Promise.resolve(reviews[i])
      : agent(
          `${lens.prompt}

           Branch "${branchName}" has the change. Run
           "git diff origin/${BASE_BRANCH}...${branchName}" from wherever you
           are. Artifact for context: ${artifactPath}.

           Report every real finding with a one-sentence summary, a
           REPO-RELATIVE file path, and a severity of "blocking" or "minor".
           An empty findings array is the correct and complete answer if your
           review dimension does not apply to this diff. Do not set
           blocked: true to express that your lens is irrelevant.`,
          { phase: 'Review', label: `review:${lens.key}:retry`, schema: REVIEW_SCHEMA, effort: 'medium' }
        )
  ))
  returnedReviews = retried.filter(Boolean)
}
if (returnedReviews.length < lenses.length) {
  return {
    success: false,
    systemic: true,
    reason: `a review lens returned no result twice in a row (${returnedReviews.length}/${lenses.length} lenses reported). `
      + `A null from agent() is a terminal API error -- an overloaded/529 window or a dropped connection -- not a defect in `
      + `${artifactLabel}. Do NOT mark this artifact failed: leave it pending, and check whether the API is healthy before resuming.`,
    branchName,
  }
}

const allFindings = returnedReviews.flatMap((r) => r.findings || [])
const blocking = allFindings.filter((f) => f.severity === 'blocking')
const minor = allFindings.filter((f) => f.severity === 'minor')

// Checked across ALL findings, not just severity: blocking -- a lens can set
// blocked: true on a minor-severity finding too, and that signal must still
// stop the artifact from reaching status: implemented with an unsatisfiable
// acceptance criterion silently shipped.
const blockingInfeasible = allFindings.filter((f) => f.blocked === true)
if (blockingInfeasible.length > 0) {
  return {
    success: false,
    blocked: true,
    reason: `review found the acceptance criteria unsatisfiable in this environment: ${blockingInfeasible.map((f) => f.summary).join('; ')}`,
    branchName,
  }
}

let contestedFindings = null
if (blocking.length > 0) {
  const fixResult = await agent(
    `On branch "${branchName}", fix these blocking review findings, then amend
     or add a commit:
     ${blocking.map((f) => `- ${f.file}: ${f.summary}`).join('\n')}

     Return fixed: true only if every finding above is actually addressed by a
     commit on that branch. If any of them can't or shouldn't be fixed
     (contradictory acceptance criteria, out of scope, not a real defect),
     return fixed: false and put one entry per unfixed finding in unresolved,
     each saying which finding it is and, specifically, WHY you believe it's
     wrong or shouldn't be fixed -- this rebuttal goes verbatim into the PR
     body for a human to adjudicate, so make the actual argument, not just
     "disagreed". Do not report fixed: true with caveats.`,
    { phase: 'Review', label: 'apply-fixes', schema: FIX_SCHEMA }
  )
  const hasRebuttal = fixResult && Array.isArray(fixResult.unresolved) && fixResult.unresolved.length > 0
  if (!fixResult) {
    // Null, not a bad answer: the fix subagent died on a terminal API error.
    // Systemic, same carve-out as the Implement and Review nulls above.
    return {
      success: false,
      systemic: true,
      reason: `the apply-fixes agent returned no result at all for ${artifactLabel} -- a terminal API error, not a verdict on the findings. `
        + `Do NOT mark this artifact failed; leave it pending and check API health before resuming.`,
      branchName,
    }
  }
  if (fixResult.fixed !== true && !hasRebuttal) {
    // A real answer that fixed nothing and argued nothing -- genuinely this
    // artifact's failure, and correctly per-artifact.
    return { success: false, reason: `blocking findings not addressed: ${describe(fixResult)}`, branchName }
  }
  if (fixResult.fixed !== true) {
    contestedFindings = fixResult.unresolved
  }
}

return contestedFindings
  ? { success: true, contested: true, contestedFindings, branchName, summary: implemented.summary, problem: implemented.problem, acceptanceCriteria: implemented.acceptanceCriteria, inGameCheck: implemented.inGameCheck, minorFindings: minor }
  : { success: true, branchName, summary: implemented.summary, problem: implemented.problem, acceptanceCriteria: implemented.acceptanceCriteria, inGameCheck: implemented.inGameCheck, minorFindings: minor }
