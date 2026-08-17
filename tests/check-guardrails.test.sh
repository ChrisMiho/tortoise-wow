#!/usr/bin/env bash
# Regression suite for scripts/check-guardrails.js.
#
# This exists because that script was WRONG TWICE before it was right, and both
# mistakes were the kind that fail silently in the direction of false assurance:
#
#   1. It matched forbidden strings anywhere in a command, so the PR phase's
#      `cat > body.md << 'PRBODY' ... docker attach ... PRBODY` -- writing a PR
#      body that quotes an artifact mentioning the phrase -- was reported as a
#      guardrail violation. That is the exact mention-vs-execution error the
#      script was written to correct, reproduced inside the script.
#   2. It applied tick-only rules to batch runs, flagging the batch's own
#      `git push` as a violation. A checker that cries wolf on the thing a
#      workflow exists to do trains the reader to ignore its output.
#
#   and it had one blind spot: a build invoked from a written .ps1 file appears
#   in no executed command at all.
#
# Every case below is one of those, or a real violation that must still be
# caught.
#
# RUN THIS FROM GIT BASH, NOT WSL -- the opposite of every other script here.
# The repo rule is "run scripts from WSL, never Git Bash", because jq is absent
# in Git Bash and the tournament scripts need it. node is the mirror image:
# it is a Windows install (v25.9.0) and is NOT present in the Ubuntu distro at
# all, so scripts/check-guardrails.js and this suite fail under WSL with
# "node: command not found". The transcripts it reads are on the Windows
# filesystem anyway.
#
#   bash tests/check-guardrails.test.sh

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECKER="$REPO_ROOT/scripts/check-guardrails.js"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

passed=0
failed=0

# Build a transcript directory from JSON lines given on stdin.
# $1 = case name, $2 = "batch" to make it look like a backlog-batch run.
make_dir() {
  local name="$1" mode="${2:-tick}"
  local d="$WORK/$name"
  mkdir -p "$d"
  cat > "$d/agent-case.jsonl"
  if [ "$mode" = "batch" ]; then
    # The marker check-guardrails.js uses to detect a batch run.
    printf '{"x":{"type":"text","text":"You MUST pass the three provenance build args"}}\n' >> "$d/agent-case.jsonl"
  fi
  echo "$d"
}

# $1 name, $2 expected-substring-count-line ("EXECUTED VIOLATIONS: N"), $3 dir
expect_violations() {
  local name="$1" want="$2" dir="$3"
  local got
  got="$(node "$CHECKER" "$dir" 2>&1 | sed -n 's/^=== EXECUTED VIOLATIONS: \([0-9]*\).*/\1/p')"
  if [ "$got" = "$want" ]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    echo "FAIL: $name -- expected $want executed violation(s), got ${got:-<none>}"
    node "$CHECKER" "$dir" 2>&1 | sed 's/^/      /' | head -12
  fi
}

expect_written() {
  local name="$1" want="$2" dir="$3"
  local got
  got="$(node "$CHECKER" "$dir" 2>&1 | sed -n 's/^=== WRITTEN INTO A FILE[^:]*: \([0-9]*\).*/\1/p')"
  if [ "$got" = "$want" ]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    echo "FAIL: $name -- expected $want written finding(s), got ${got:-<none>}"
  fi
}

cmd_line() { printf '{"a":{"type":"tool_use","input":{"command":%s}}}\n' "$1"; }

# --- real violations, must be caught ---------------------------------------

d=$(cmd_line '"docker compose down -v"' | make_dir down_v)
expect_violations "docker compose down -v is caught" 1 "$d"

d=$(cmd_line '"docker volume prune -f"' | make_dir volprune)
expect_violations "docker volume prune is caught" 1 "$d"

d=$(cmd_line '"docker system prune --volumes -f"' | make_dir sysprune)
expect_violations "docker system prune --volumes is caught" 1 "$d"

d=$(cmd_line '"docker image prune -a -f"' | make_dir imgprune)
expect_violations "docker image prune -a is caught (takes the rollback anchor)" 1 "$d"

d=$(cmd_line '"docker attach tcm-mangosd"' | make_dir attach)
expect_violations "bare docker attach is caught" 1 "$d"

d=$(cmd_line '"cd /x && docker compose --env-file /x/.env down --volumes"' | make_dir downvol)
expect_violations "down --volumes after cd is caught" 1 "$d"

# --- mention vs execution: must NOT be caught (regression, bug #1) ----------

d=$(printf '{"a":{"type":"tool_use","input":{"command":"cat > /tmp/pr.md << %s\\nconsole EOF shuts the world down, so every extra docker attach is a risk\\nPRBODY"}}}\n' "'PRBODY'" | make_dir heredoc)
expect_violations "heredoc BODY mentioning docker attach is NOT a violation" 0 "$d"

d=$(cmd_line '"echo just talking about docker compose down -v in prose"' | make_dir prose)
expect_violations "prose echo mentioning down -v is NOT a violation" 0 "$d"

d=$(cmd_line '"git commit -m \"never run docker volume prune here\""' | make_dir commitmsg)
expect_violations "commit message mentioning volume prune is NOT a violation" 0 "$d"

# --- permitted commands: must NOT be caught --------------------------------

d=$(cmd_line '"docker compose --env-file /x/.env down"' | make_dir plaindown)
expect_violations "plain docker compose down is permitted" 0 "$d"

d=$(cmd_line '"docker compose --env-file /x/.env up -d db"' | make_dir updb)
expect_violations "bringing up only db is permitted" 0 "$d"

d=$(cmd_line '"docker image prune"' | make_dir imgpruneplain)
expect_violations "docker image prune WITHOUT -a is permitted" 0 "$d"

# --- tick vs batch scoping (regression, bug #2) ----------------------------

d=$(cmd_line '"git push origin backlog/x"' | make_dir push_tick)
expect_violations "git push IS a violation in a tick" 1 "$d"

d=$(cmd_line '"git push origin backlog/x"' | make_dir push_batch batch)
expect_violations "git push is NOT a violation in a batch" 0 "$d"

d=$(cmd_line '"docker build -t tortoise-cm:x ."' | make_dir build_tick)
expect_violations "docker build IS a violation in a tick" 1 "$d"

d=$(cmd_line '"docker build -t tortoise-cm:x ."' | make_dir build_batch batch)
expect_violations "docker build is NOT a violation in a batch" 0 "$d"

# --- the blind spot: commands written into a script file -------------------

d=$(printf '{"a":{"type":"tool_use","input":{"file_path":"/tmp/build.ps1","content":"docker build -t tortoise-cm:x ."}}}\n' | make_dir written_build)
expect_written "docker build written into a .ps1 is reported" 1 "$d"

d=$(printf '{"a":{"type":"tool_use","input":{"file_path":"/tmp/wipe.sh","content":"docker volume prune -f"}}}\n' | make_dir written_prune)
expect_written "volume prune written into a script is reported" 1 "$d"

d=$(printf '{"a":{"type":"tool_use","input":{"file_path":"/tmp/notes.md","content":"Do not run docker volume prune, it destroys the world"}}}\n' | make_dir written_prose)
expect_written "prose in a written doc is NOT reported" 0 "$d"

# --- exit status ------------------------------------------------------------

d=$(cmd_line '"docker volume prune -f"' | make_dir exitcode)
node "$CHECKER" "$d" >/dev/null 2>&1
if [ $? -eq 1 ]; then passed=$((passed + 1)); else failed=$((failed + 1)); echo "FAIL: exits 1 on a violation"; fi

d=$(cmd_line '"docker ps"' | make_dir exitclean)
node "$CHECKER" "$d" >/dev/null 2>&1
if [ $? -eq 0 ]; then passed=$((passed + 1)); else failed=$((failed + 1)); echo "FAIL: exits 0 on a clean run"; fi

echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
