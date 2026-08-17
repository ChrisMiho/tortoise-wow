#!/usr/bin/env node
//
// Confirm the workflow script that a Workflow() call ACTUALLY RAN matches the
// one in the repo, and still carries its guardrails.
//
//   node scripts/check-workflow-fresh.js <savedScriptPath> [repoScriptPath]
//
// <savedScriptPath> is the "Script file:" path in the Workflow tool result.
// <repoScriptPath> defaults to .claude/workflows/<name>.js inferred from it.
//
// Why this is per-invocation and not a one-time check.
//
// Workflow({name: "..."}) does not always serve the current file. Observed
// 2026-08-17: backlog-batch.js ran one edit behind the repo copy, while
// backlog-issue.js resolved fresh on three consecutive ticks in the same
// session. That time the stale delta was a comment, so nothing behaved
// differently -- but the two workflows disagreeing means you cannot infer from
// one being current that the other is, and a check run once at the start of a
// drain says nothing about the twenty-ninth tick. If a fix is edited in
// mid-drain, this is the only thing that will notice it did not take.
//
// Exit 0 = safe to proceed. Exit 1 = functional difference or missing guardrail,
// STOP. Exit 2 = could not check (bad paths).

const fs = require('fs')
const path = require('path')

const savedPath = process.argv[2]
if (!savedPath) {
  console.error('usage: node scripts/check-workflow-fresh.js <savedScriptPath> [repoScriptPath]')
  process.exit(2)
}
if (!fs.existsSync(savedPath)) {
  console.error(`saved script not found: ${savedPath}`)
  process.exit(2)
}

// backlog-issue-wf_036774d1-505.js -> backlog-issue
const inferred = path.basename(savedPath).replace(/-wf_[^.]*\.js$/, '')
// Forward slashes throughout: this path is printed back as a Workflow({
// scriptPath: "..." }) argument, and a Windows backslash there is a JS escape.
const repoPath = (process.argv[3] || path.join('.claude', 'workflows', `${inferred}.js`)).replace(/\\/g, '/')
if (!fs.existsSync(repoPath)) {
  console.error(`repo script not found: ${repoPath}`)
  process.exit(2)
}

const saved = fs.readFileSync(savedPath, 'utf8')
const repo = fs.readFileSync(repoPath, 'utf8')

// Guardrails that must be present in whatever actually runs. A missing marker
// means the agent has live docker access with none of the prohibitions.
const MARKERS = {
  'backlog-issue': [
    'THE LIVE STACK IS AVAILABLE TO YOU',
    'NEVER destroy the database volume',
    'docker system prune --volumes',
    'NEVER delete or retag images',
    'NEVER a bare "docker attach"',
    'DO NOT run a Docker build',
  ],
  'backlog-batch': [
    'not one pull request was opened',
    'MUST NOT already exist',
    'NEVER "down -v"',
  ],
}

let failed = false

const markers = MARKERS[inferred] || []
if (markers.length === 0) {
  console.log(`no marker set defined for "${inferred}" -- content check skipped`)
}
for (const m of markers) {
  const n = saved.split(m).length - 1
  if (n < 1) {
    console.error(`MISSING GUARDRAIL in the script that ran: ${JSON.stringify(m)}`)
    failed = true
  }
}

// Compare ignoring comment-only and blank-line drift: a stale comment is worth
// reporting but is not a reason to halt a drain, while any difference in code
// or in prompt text (which IS the behaviour for these scripts) is.
const strip = (src) => src
  .split('\n')
  .map((l) => l.replace(/^\s*\/\/.*$/, ''))
  .filter((l) => l.trim() !== '')
  .join('\n')

const identical = saved === repo
const functionallyIdentical = strip(saved) === strip(repo)

if (identical) {
  console.log(`OK  ${inferred}: script that ran is byte-identical to ${repoPath}`)
} else if (functionallyIdentical) {
  console.log(`WARN ${inferred}: script that ran differs from ${repoPath} in COMMENTS ONLY.`)
  console.log('     Behaviour is unaffected, but the resolver served a stale snapshot --')
  console.log('     a later edit to this file may not reach the next invocation either.')
} else {
  console.error(`STALE ${inferred}: the script that ran differs FUNCTIONALLY from ${repoPath}.`)
  console.error('      Your edits did not reach this run. Stop and re-invoke with')
  console.error(`      Workflow({ scriptPath: "${repoPath}", args: {...} }) instead of { name: ... }.`)
  failed = true
}

process.exit(failed ? 1 : 0)
