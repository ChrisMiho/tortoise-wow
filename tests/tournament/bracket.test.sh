#!/usr/bin/env bash
# Unit tests for scripts/tournament/lib/bracket.sh. No server, no database.
#
# Run from WSL, not Git Bash: jq is not on Git Bash's PATH on this host and
# require_cmd is a hard exit, not a skip.
#
#   wsl -d Ubuntu -- bash -lc 'cd /mnt/c/... && bash tests/tournament/bracket.test.sh'
#
# This file deliberately does NOT source lib/team.sh, so bracket_validate's
# team-existence and faction checks are skipped here and the shipped bracket can
# be checked structurally on its own. The full path -- all four teams present and
# on the right faction -- is exercised by sourcing both libraries, which is what
# tournament-run.sh does and what the artifact's own acceptance step runs.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/../lib/assert.sh"
. "$ROOT/scripts/tournament/lib/bracket.sh"

require_cmd jq

SHIPPED="$ROOT/config/tournament/brackets"
export BRACKET_DIR="$SHIPPED"

# --- the shipped bracket ----------------------------------------------------

assert_exit 0 "the shipped bracket validates" -- bracket_validate wsg-open

assert_eq "2 2" \
  "$(bracket_ladder wsg-open A | grep -c .) $(bracket_ladder wsg-open H | grep -c .)" \
  "both ladders hold two teams"

assert_eq "1" "$(bracket_rounds wsg-open)" "two-team ladders imply one round"

# --- pairing ----------------------------------------------------------------
#
# The nth alliance survivor plays the nth horde survivor, so every match is
# cross-faction by construction. Asserting the whole output at once also pins the
# count and the order, which is the part that makes it cross-faction.
assert_eq "$(printf 'alpha|gamma\nbeta|delta\n')" \
  "$(bracket_pairings wsg-open "alpha beta" "gamma delta")" \
  "the nth alliance survivor is paired with the nth horde survivor"

# Uneven lists can only be paired by giving someone a bye or a same-faction
# opponent, and the second is twenty bots refusing to fight.
assert_exit 1 "unequal survivor lists are rejected" \
  -- bracket_pairings wsg-open "alpha beta" "gamma"
assert_exit 1 "empty survivor lists are rejected" \
  -- bracket_pairings wsg-open "" ""

# --- every fault bracket_validate is supposed to catch ----------------------
#
# A rejection that does not say why costs almost as much as no rejection: the
# operator is left with a bracket that "doesn't work". So exit code and message
# are one observation, and therefore one assertion. Same idiom as team.test.sh.
rejection() { # <bracket-id> <needle> -> "rejected: <needle>" when both hold
    local out rc=0
    out="$(bracket_validate "$1" 2>&1)" || rc=$?
    [ "$rc" -eq 1 ] || { printf 'exit %s, expected 1\n' "$rc"; return 0; }
    case "$out" in
        *"$2"*) printf 'rejected: %s\n' "$2" ;;
        *)      printf 'exit 1 but the message never mentions it: %s\n' "$out" ;;
    esac
}

TMP="$(mktemp -d)"
export BRACKET_DIR="$TMP"

# Each fixture changes exactly one thing and carries a matching .id, so the
# assertion below can only be satisfied by the rule it names.
fixture() { # <fixture-name> <jq-filter>
    jq --arg id "$1" ".id = \$id | $2" < "$SHIPPED/wsg-open.json" > "$TMP/$1.json"
}

fixture notpow2  '.allianceLadder = ["a","b","c"] | .hordeLadder = ["d","e","f"]'
fixture lopsided '.hordeLadder = ["d"]'
# .id is what every other file refers to the bracket by; if it disagrees with the
# filename, a run's state.json names a bracket that cannot be loaded back.
jq '.id = "not-wsg-open"' < "$SHIPPED/wsg-open.json" > "$TMP/badid.json"

assert_eq "rejected: power of two" "$(rejection notpow2 'power of two')" \
  "a ladder size that is not a power of two is rejected, naming the fault"
assert_eq "rejected: they must be equal" "$(rejection lopsided 'they must be equal')" \
  "ladders of different lengths are rejected"
assert_eq "rejected: must match the filename" "$(rejection badid 'must match the filename')" \
  "an .id that disagrees with the filename is rejected"

rm -rf "$TMP"
assert_summary
