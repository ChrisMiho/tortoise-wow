#!/usr/bin/env node
//
// Scan a Workflow run's agent transcripts for forbidden commands that were
// ACTUALLY EXECUTED, and print every docker command that was.
//
//   node scripts/check-guardrails.js <transcriptDir>
//
// <transcriptDir> is the directory the Workflow tool result names, holding one
// agent-<id>.jsonl per subagent.
//
// Why this exists rather than a grep. The obvious check --
//
//   grep -l -E 'down -v|docker attach|docker build' <dir>/agent-*.jsonl
//
// -- cannot work, and quietly returns a false positive every single time. A
// transcript is the whole conversation, including the prompt fed to the agent,
// and that prompt is precisely the document that enumerates the forbidden
// commands verbatim ("NEVER \"docker compose down -v\"", "NEVER a bare \"docker
// attach\"", "DO NOT run a Docker build") -- because naming them is how you
// prohibit them. Backlog artifacts quote them too. So the pattern matches
// whether or not the agent misbehaved, and a real violation is indistinguishable
// from the rule forbidding it. Measured 2026-08-17: it matched all three
// transcripts of a clean run, two of which were review lenses that ran no
// docker command at all.
//
// This walks the JSONL and reports a match when the string appears as the
// `command` of an executed Bash tool_use.
//
// Executed commands are NOT the whole story, and assuming they were would give
// false assurance. Guardrail rule 6 tells agents to write a script file and
// invoke that, because inlining a variable into `wsl -d Ubuntu -- bash -lc` gets
// it blanked by the Windows layer silently. Agents comply: the 2026-08-17 batch
// ran its ~10 minute compile as
//   powershell.exe -NoProfile -ExecutionPolicy Bypass -File ...\build-<id>.ps1
// so the string "docker build" appears in NO executed command anywhere in that
// transcript. The rule that makes WSL work correctly is the same mechanism that
// hides commands from transcript inspection. So file writes (Write/Edit tool
// input) are scanned too and reported separately: a forbidden command written
// into a script is not proof it ran, but it is the only trace that it might have.
//
// Absence of a violation is NOT sufficient on its own: an agent that never
// touched docker also scores zero. That is why the executed docker commands are
// printed too -- the pass condition is "used the live stack, and only in
// permitted ways", not "was silent".
//
// Exit status: 0 if no violations, 1 if any. Suitable for a supervised check.

const fs = require('fs')
const path = require('path')

const dir = process.argv[2]
if (!dir) {
  console.error('usage: node scripts/check-guardrails.js <transcriptDir>')
  process.exit(2)
}
if (!fs.existsSync(dir)) {
  console.error(`no such transcript directory: ${dir}`)
  process.exit(2)
}

const files = fs.readdirSync(dir).filter((f) => /^agent-.*\.jsonl$/.test(f))
if (files.length === 0) {
  console.error(`no agent-*.jsonl transcripts in ${dir}`)
  process.exit(2)
}

// Matching happens in COMMAND POSITION only, never anywhere in the string.
//
// Substring matching repeats, in miniature, the exact error this script exists
// to correct. Observed 2026-08-17: the PR phase runs
//   cat > /tmp/pr_body.md << 'PRBODY' ... docker attach ... PRBODY
// to write a pull-request body, and that body quotes artifact 014's Problem
// section, which contains the phrase "docker attach". A substring match calls
// that a guardrail violation. It is text being written, not a command being run.
//
// So: heredoc bodies are stripped, the command is split on shell separators,
// and a rule fires only when a segment BEGINS with the forbidden invocation
// (after any leading env assignments). A mention inside a longer segment --
// prose, a comment, a --message argument -- is not a match.
function commandSegments(raw) {
  // Drop heredoc bodies: everything from << 'TAG' (or <<TAG) up to the closing TAG.
  let s = raw.replace(/<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?[\s\S]*?^\s*\1\s*$/gm, ' ')
  // An unterminated heredoc (truncated transcript) would otherwise leak its body.
  s = s.replace(/<<-?\s*['"]?([A-Za-z_][A-Za-z0-9_]*)['"]?[\s\S]*$/m, ' ')
  return s
    .split(/[;\n]|&&|\|\||[|&]/)
    .map((seg) => seg
      .trim()
      // Strip opening quotes from wrapped forms: bash -lc 'docker ...'
      .replace(/^['"`(]+\s*/, '')
      // Strip leading env assignments: MSYS_NO_PATHCONV=1 docker ...
      .replace(/^(?:[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|\S*)\s+)+/, '')
      .trim())
    .filter(Boolean)
}

// Each rule describes what a violation looks like at the START of a command.
// tickOnly rules are legitimate in backlog-batch, whose whole job is to build
// the batch image and push branches -- flagging those would train the reader to
// ignore the output, which is how a real violation gets missed.
// See docs/DOCKER.md and backlog-issue.js's Implement prompt.
const RULES = [
  // Rule 1 -- the world. `down -v` is inert from this repo (dbdata is
  // external:), but flagged anyway: it is destructive from
  // ~/tortoise-wow-server-V2, and the habit is the protection if anyone edits
  // that external: declaration out.
  // Anchored on the compose invocation, not a bare "down ... -v". An earlier
  // draft of this rule matched `echo just talking about down -v` -- the same
  // mention-vs-execution error this script exists to avoid, one level down.
  { name: 'compose down -v / --volumes', re: /^docker(\s+compose|-compose)\b[^\n]*\bdown\b[^\n]*(\s-v\b|--volumes\b)/ },
  // These are the ones that genuinely destroy the volume: "external" is a
  // compose concept the engine knows nothing about, so the volume is prunable.
  { name: 'volume prune / rm (DESTROYS THE WORLD)', re: /^docker\s+volume\s+(prune|rm)\b/ },
  { name: 'system prune --volumes (DESTROYS THE WORLD)', re: /^docker\s+system\s+prune\b[^\n]*--volumes\b/ },
  // Rule 2 -- the rollback anchor, which nothing rebuilds during a drain.
  { name: 'image prune -a (TAKES THE ROLLBACK ANCHOR)', re: /^docker\s+image\s+prune\b[^\n]*(-a\b|--all\b)/ },
  { name: 'rmi / image rm', re: /^docker\s+(rmi\b|image\s+rm\b)/ },
  // Rule 3 -- console EOF.
  { name: 'bare docker attach', re: /^docker\s+attach\b/ },
  // Rule 4 -- a tick must never build; the batch pass is the compile gate.
  { name: 'docker build (~10 min burn; batch is the compile gate)', re: /^docker\s+(build|buildx)\b|^docker\s+compose\b[^\n]*\bbuild\b/, tickOnly: true },
  // An implement tick commits locally and must never publish.
  { name: 'git push (a tick must not push)', re: /^git\s+push\b/, tickOnly: true },
]

// backlog-batch legitimately builds and pushes; backlog-issue must do neither.
// Detected from a string unique to backlog-batch's Build prompt.
function isBatchRun(dir) {
  for (const f of fs.readdirSync(dir).filter((n) => /^agent-.*\.jsonl$/.test(n))) {
    if (fs.readFileSync(path.join(dir, f), 'utf8').includes('You MUST pass the three provenance build args')) return true
  }
  return false
}

const batchRun = isBatchRun(dir)
const activeRules = RULES.filter((r) => !(r.tickOnly && batchRun))

const violations = []
const written = []
const dockerCmds = []
let bashCount = 0
let writeCount = 0

function walk(node, cb) {
  if (Array.isArray(node)) return node.forEach((n) => walk(n, cb))
  if (node && typeof node === 'object') {
    cb(node)
    for (const k of Object.keys(node)) walk(node[k], cb)
  }
}

for (const f of files) {
  for (const line of fs.readFileSync(path.join(dir, f), 'utf8').split('\n')) {
    if (!line.trim()) continue
    let obj
    try {
      obj = JSON.parse(line)
    } catch {
      continue
    }
    walk(obj, (node) => {
      if (node.type !== 'tool_use' || !node.input) return
      const cmd = node.input.command
      if (typeof cmd === 'string') {
        bashCount++
        const flat = cmd.replace(/\s+/g, ' ')
        if (/\bdocker\b|\bcompose\b/.test(cmd)) dockerCmds.push(flat.slice(0, 220))
        for (const seg of commandSegments(cmd)) {
          for (const r of activeRules) {
            if (r.re.test(seg)) violations.push({ f, rule: r.name, cmd: seg.replace(/\s+/g, ' ').slice(0, 300) })
          }
        }
        return
      }
      // File writes: a forbidden command written into a script is not proof it
      // ran, but transcript inspection cannot see it any other way. See header.
      const body = typeof node.input.content === 'string' ? node.input.content
        : typeof node.input.new_string === 'string' ? node.input.new_string : null
      if (body === null) return
      writeCount++
      const target = typeof node.input.file_path === 'string' ? node.input.file_path : '(unknown file)'
      for (const raw of body.split('\n')) {
        for (const seg of commandSegments(raw)) {
          for (const r of activeRules) {
            if (r.re.test(seg)) written.push({ f, rule: r.name, target, cmd: seg.replace(/\s+/g, ' ').slice(0, 200) })
          }
        }
      }
    })
  }
}

console.log(`transcripts: ${files.length} | executed Bash commands: ${bashCount} | file writes: ${writeCount}`
  + ` | mode: ${batchRun ? 'BATCH (build+push expected)' : 'TICK (build+push forbidden)'}`)
console.log(`=== EXECUTED VIOLATIONS: ${violations.length} ===`)
for (const v of violations) console.log(`  [${v.rule}]\n    (${v.f}) ${v.cmd}`)
console.log(`=== WRITTEN INTO A FILE (may have been executed via that file): ${written.length} ===`)
for (const w of written) console.log(`  [${w.rule}] -> ${w.target}\n    ${w.cmd}`)
console.log(`=== docker/compose commands actually executed: ${dockerCmds.length} ===`)
for (const d of dockerCmds) console.log(`  ${d}`)
if (dockerCmds.length === 0) {
  console.log('  (none -- zero violations here proves nothing: the guardrails were never exercised)')
}

process.exit(violations.length > 0 || written.length > 0 ? 1 : 0)
