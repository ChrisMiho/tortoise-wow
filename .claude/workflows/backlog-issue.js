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

   Five rules on that access, each of which has already cost someone a session:

   1. NEVER "docker compose down -v". The tortoise-wow-v2_dbdata volume is the
      entire world and it has been lost once already. Plain "down", or just
      leave the database running.
   2. NEVER a bare "docker attach". mangosd treats console EOF as "shut down
      the world" and the compose service is restart:"no". Use wsg_console from
      docs/playerbots/wsg/lib/wsg-bots-common.sh, which detaches properly, and
      batch your commands into as few attaches as you can.
   3. DO NOT run a Docker build. There is no incremental build here -- "COPY .
      /src" never cache-hits, so every build recompiles all ~1169 translation
      units and takes ~9.5 minutes no matter what changed. A later
      backlog-batch pass builds this branch together with its batch; that is
      the compile gate, and running one here just burns ten minutes.
   4. Because of 3, THE ONLY SERVER IMAGE ON THIS HOST IS A ROLLBACK ANCHOR
      THAT PREDATES EVERY UNMERGED CHANGE. Existing commands (rndbot, .bg, and
      anything already on cm-main) work against it. Any console command added
      by this backlog series does NOT exist in it, so "there is no such
      subcommand" against a running server proves nothing about your code --
      do not treat it as a failure, and do not rewrite working code chasing it.
   5. Run scripts from WSL, never Git Bash: jq is absent from Git Bash on this
      host and require_cmd hard-exits, and MSYS rewrites POSIX paths into C:\
      ones. Do NOT put a variable inside a wrapped "wsl -d Ubuntu -- bash -lc
      '...'" one-liner -- that returns plausible-but-wrong output silently.
      Write a script file and invoke that.

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
  return { success: false, reason: 'implement phase failed to produce a change' }
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
     if there's nothing to flag.`,
    { phase: 'Review', label: `review:${lens.key}`, schema: REVIEW_SCHEMA, effort: 'medium' }
  )
))

const returnedReviews = reviews.filter(Boolean)
if (returnedReviews.length < lenses.length) {
  return { success: false, reason: 'a review lens did not return a result', branchName }
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
  if (!fixResult || (fixResult.fixed !== true && !hasRebuttal)) {
    // No usable result at all -- not a defensible disagreement, a broken fix attempt.
    return { success: false, reason: `blocking findings not addressed: ${describe(fixResult)}`, branchName }
  }
  if (fixResult.fixed !== true) {
    contestedFindings = fixResult.unresolved
  }
}

return contestedFindings
  ? { success: true, contested: true, contestedFindings, branchName, summary: implemented.summary, problem: implemented.problem, acceptanceCriteria: implemented.acceptanceCriteria, inGameCheck: implemented.inGameCheck, minorFindings: minor }
  : { success: true, branchName, summary: implemented.summary, problem: implemented.problem, acceptanceCriteria: implemented.acceptanceCriteria, inGameCheck: implemented.inGameCheck, minorFindings: minor }
