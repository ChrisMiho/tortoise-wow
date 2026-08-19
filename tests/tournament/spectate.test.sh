#!/usr/bin/env bash
# Director-loop tests for scripts/tournament/spectate.sh. No server, no database,
# no build.
#
# The point of the CTL_STUB seam is that this file pins the director's LOGIC --
# when it stops, what it counts, what it prints -- without needing the C++
# `tournament camera` command to exist. That command ships in a separate change;
# here a shell function stands in for it and answers on cue.
#
# The stub plays out one match's worth of answers: two successful repositions,
# then the instance is gone. A finished battleground is DESTROYED on this server,
# so `error=no_such_instance` is not a failure -- it is how a match ends
# (BattleGround.cpp:317-323 hard-caps a match at 20 minutes and ends it).
#
# Run from WSL, not Git Bash, like the rest of this repo's shell tests:
#
#   wsl -d Ubuntu -- bash -lc 'cd /mnt/c/... && bash tests/tournament/spectate.test.sh'
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/../lib/assert.sh"

st="$(mktemp -d)"
trap 'rm -rf "$st"' EXIT

# The stub replaces BOTH ctl() and ctl_field(), which is why spectate.sh sources
# $CTL_STUB *instead of* lib/ctl.sh rather than after it: sourcing the real
# lib/ctl.sh would pull in wsg-bots-common.sh and, through it, an expectation of
# a running container.
cat > "$st/ctlstub.sh" <<'STUB'
CALLS_FILE="${CALLS_FILE:-/dev/null}"
ctl() {
  printf '%s\n' "$*" >> "$CALLS_FILE"
  n=$(grep -c 'tournament camera' "$CALLS_FILE")
  if [ "$n" -ge 3 ]; then
    printf 'TOURNAMENT camera error=no_such_instance\n'
  else
    printf 'TOURNAMENT camera player=Astral instance=101 x=1.0 y=2.0 z=30.0 reason=combat moved=1\n'
  fi
}
ctl_field() { printf '%s\n' "$1" | sed -n "s/.*[[:space:]]$2=\\([^[:space:]]*\\).*/\\1/p" | head -1; }
STUB

# --interval 0 so the loop never sleeps, and --max-minutes 5 so the time budget
# is nowhere near what ends this run: the director must stop because the INSTANCE
# went away, not because the clock did. If the budget were what stopped it, the
# call count would be far more than three and this file would say so.
CALLS="$st/calls.txt"; : > "$CALLS"
RC=0
OUT="$(CTL_STUB="$st/ctlstub.sh" CALLS_FILE="$CALLS" \
       bash "$ROOT/scripts/tournament/spectate.sh" \
       --spectator Astral --instance 101 --interval 0 --max-minutes 5 2>&1)" || RC=$?

assert_eq "0" "$RC" "director exits 0 when the match ends"
# Three, not two and not four: the third call is the one that discovers the
# instance is gone, and nothing may be sent after it.
assert_eq "3" "$(grep -c 'tournament camera' "$CALLS")" "stops as soon as the instance is gone"
assert_contains "$OUT" "SPECTATE" "emits a summary line"
assert_contains "$OUT" "repositions=2" "counts only successful repositions"

assert_summary
