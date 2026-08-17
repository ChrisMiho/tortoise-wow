#!/usr/bin/env bash
# Unit tests for scripts/tournament/lib/state.sh. No server, no database.
#
# Run from WSL, not Git Bash: jq is not on Git Bash's PATH on this host and
# require_cmd is a hard exit, not a skip.
#
#   wsl -d Ubuntu -- bash -lc 'cd /mnt/c/... && bash tests/tournament/state.test.sh'
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/../lib/assert.sh"
. "$ROOT/scripts/tournament/lib/state.sh"

require_cmd jq

TMP="$(mktemp -d)"
run="$TMP/run1"

# --- a fresh run ------------------------------------------------------------

state_init "$run" wsg-open "swa swb" "hoa hob"

assert_eq "wsg-open|1|running|swa swb|hoa hob" \
  "$(state_get "$run" '.bracketId')|$(state_get "$run" '.round')|$(state_get "$run" '.status')|$(state_survivors "$run" A)|$(state_survivors "$run" H)" \
  "state_init seeds the bracket, round 1, and both survivor lists"

# --- results eliminate losers -----------------------------------------------

state_record_result "$run" 1 swa hoa ALLIANCE
state_record_result "$run" 1 swb hob HORDE

assert_eq "swa|hob" "$(state_survivors "$run" A)|$(state_survivors "$run" H)" \
  "each result eliminates its loser and leaves the other faction's list alone"

# A shell value reaches jq as a string, so .round has to be converted. A string
# round silently breaks the driver's numeric round comparison rather than failing.
assert_eq "2 number" \
  "$(state_get "$run" '.results | length') $(state_get "$run" '.results[0].round | type')" \
  "both results are recorded and .round is a JSON number, not a string"

assert_eq "server" "$(state_get "$run" '.results[0].decidedBy')" \
  "decidedBy defaults to server -- the battleground declared this winner"

# --- a draw eliminates nobody, which is the point ---------------------------
#
# The 20-minute hard cap makes 0-0 common. Advancing a side the battleground did
# not declare would fabricate a winner, so the deadlock is deliberate.
state_record_result "$run" 1 swa hob NONE

assert_eq "3|swa|hob" \
  "$(state_get "$run" '.results | length')|$(state_survivors "$run" A)|$(state_survivors "$run" H)" \
  "a NONE winner with no decidedBy is recorded but eliminates nobody"

# --- a tiebreak eliminates, and says so -------------------------------------

state_record_result "$run" 2 swa hob HORDE tiebreak_deaths

assert_eq "tiebreak_deaths|" \
  "$(state_get "$run" '.results[-1].decidedBy')|$(state_survivors "$run" A)" \
  "a tiebreak eliminates the loser and records who decided it"

# The whole reason decidedBy exists: a run's report can say how many matches were
# decided by the driver rather than won on the field.
assert_eq "1" "$(state_get "$run" '[.results[] | select(.decidedBy != "server")] | length')" \
  "results the server did not decide are queryable"

# --- round and status -------------------------------------------------------

state_advance_round "$run"
state_finish "$run" complete

assert_eq "2 complete" "$(state_get "$run" '.round') $(state_get "$run" '.status')" \
  "the round advances and the run can be finished"

# --- resume -----------------------------------------------------------------
#
# The property that matters overnight: re-running state_init on an existing run
# directory resumes it. Seeds that disagree with the recorded ones must not win.
state_init "$run" wsg-open "clobber" "clobber"

assert_eq "wsg-open|4|complete|" \
  "$(state_get "$run" '.bracketId')|$(state_get "$run" '.results | length')|$(state_get "$run" '.status')|$(state_survivors "$run" A)" \
  "state_init on an existing run resumes it rather than resetting it"

# Every write is temp-file-then-rename. A leftover temp file means a write path
# that can strand a half-written state next to the real one.
assert_eq "" "$(find "$run" -name '*.tmp' -print)" \
  "no temp file survives an atomic write"

rm -rf "$TMP"
assert_summary
