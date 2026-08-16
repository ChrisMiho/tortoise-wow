#!/usr/bin/env bash
# Unit tests for scripts/tournament/lib/team.sh. No server, no database.
#
# Run from WSL, not Git Bash: jq is not on Git Bash's PATH on this host and
# require_cmd is a hard exit, not a skip.
#
#   wsl -d Ubuntu -- bash -lc 'cd /mnt/c/... && bash tests/tournament/team.test.sh'
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/../lib/assert.sh"
. "$ROOT/scripts/tournament/lib/team.sh"

require_cmd jq

SHIPPED="$ROOT/config/tournament/teams"
export TEAM_DIR="$SHIPPED"

# --- reading a definition --------------------------------------------------

assert_eq "A" "$(team_field stormwind-sentinels '.faction')" \
  "team_field reads a scalar out of a team file"

assert_eq "$(printf '%s\n' Wsgaone Wsgatwo Wsgathree Wsgafour Wsgafive \
                           Wsgasix Wsgaseven Wsgaeight Wsganine Wsgaten)" \
  "$(team_names stormwind-sentinels)" \
  "team_names emits namePrefix+slot for all ten slots, in order"

# The strongest assertion in this file: the JSON must describe exactly the 20
# bots that already exist and already work. If these two ever diverge, the
# tournament would be played by a roster nobody has ever seen come online.
assert_eq "$(tr -d '\r' < "$ROOT/docs/playerbots/wsg/wsg-team-roster.txt")" \
  "$( team_rows stormwind-sentinels; team_rows orgrimmar-warsong )" \
  "team_rows for both teams reproduces wsg-team-roster.txt exactly"

# --- the shipped teams are valid -------------------------------------------

assert_exit 0 "the shipped Alliance team validates" -- team_validate stormwind-sentinels
assert_exit 0 "the shipped Horde team validates"    -- team_validate orgrimmar-warsong

# --- every fault team_validate is supposed to catch ------------------------
#
# A rejection that does not say why is nearly as expensive as no rejection at
# all -- the fault it guards against already masquerades as a successful login.
# So exit code and message are one observation, and therefore one assertion.
rejection() { # <team-id> <needle> -> "rejected: <needle>" when both hold
    local out rc=0
    out="$(team_validate "$1" 2>&1)" || rc=$?
    [ "$rc" -eq 1 ] || { printf 'exit %s, expected 1\n' "$rc"; return 0; }
    case "$out" in
        *"$2"*) printf 'rejected: %s\n' "$2" ;;
        *)      printf 'exit 1 but the message never mentions it: %s\n' "$out" ;;
    esac
}

TMP="$(mktemp -d)"
export TEAM_DIR="$TMP"

# Each fixture changes exactly one thing, and carries a matching .id, so the
# assertion below can only be satisfied by the rule it names.
fixture() { # <fixture-name> <jq-filter>
    jq --arg id "$1" ".id = \$id | $2" < "$SHIPPED/stormwind-sentinels.json" \
        > "$TMP/$1.json"
}

# The regression that cost a full debugging session.
fixture badprefix   '.namePrefix = "Wsga1"'
fixture wrongfaction '.faction = "H"'
# Ten entries still, but "two" before "one": prefix+slot means slot order is
# name order, and a swapped or duplicated slot is a silently wrong character.
fixture slotorder   '.roster |= (.[0:2] | reverse) + .[2:]'
# Alphabetic and only nine characters, but "Sentinelsthree" is 14.
fixture longname    '.namePrefix = "Sentinels"'
fixture badrole     '.roster[0].role = "flagrunner"'

assert_eq "rejected: alphabetic" "$(rejection badprefix alphabetic)" \
  "a non-alphabetic namePrefix is rejected, and the message says alphabetic"
assert_eq "rejected: not playable by faction H" "$(rejection wrongfaction 'not playable by faction H')" \
  "a faction that disagrees with the roster's races is rejected"
assert_eq "rejected: in order" "$(rejection slotorder 'in order')" \
  "a roster that is not the ten canonical slots in order is rejected"
assert_eq "rejected: 'Sentinelsthree' exceeds 12 characters" \
  "$(rejection longname "'Sentinelsthree' exceeds 12 characters")" \
  "a generated name over 12 characters is rejected"
assert_eq "rejected: role 'flagrunner' must be tank, healer or dps" \
  "$(rejection badrole "role 'flagrunner' must be tank, healer or dps")" \
  "a role outside tank|healer|dps is rejected"

rm -rf "$TMP"
assert_summary
