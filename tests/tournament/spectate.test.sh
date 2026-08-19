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

# A spectator_teleporting refusal must NOT end the broadcast. The camera is
# itself a teleport, so this is what a cut issued while the spectator is still on
# the previous cut's loading screen looks like -- a state that clears itself when
# the world-port ack lands. This stub cuts once, refuses twice while "loading",
# cuts again, then ends the match: a director that treated the token as fatal
# would stop at call two with rc=1 and repositions=1.
cat > "$st/ctlstub-teleporting.sh" <<'STUB'
CALLS_FILE="${CALLS_FILE:-/dev/null}"
ctl() {
  printf '%s\n' "$*" >> "$CALLS_FILE"
  n=$(grep -c 'tournament camera' "$CALLS_FILE")
  case "$n" in
    2|3) printf 'TOURNAMENT camera error=spectator_teleporting(Astral)\n' ;;
    5)   printf 'TOURNAMENT camera error=no_such_instance\n' ;;
    *)   printf 'TOURNAMENT camera player=Astral instance=101 x=1.0 y=2.0 z=30.0 reason=combat moved=1\n' ;;
  esac
}
ctl_field() { printf '%s\n' "$1" | sed -n "s/.*[[:space:]]$2=\\([^[:space:]]*\\).*/\\1/p" | head -1; }
STUB

CALLS2="$st/calls2.txt"; : > "$CALLS2"
RC2=0
OUT2="$(CTL_STUB="$st/ctlstub-teleporting.sh" CALLS_FILE="$CALLS2" \
        bash "$ROOT/scripts/tournament/spectate.sh" \
        --spectator Astral --instance 101 --interval 0 --max-minutes 5 2>&1)" || RC2=$?

assert_eq "0" "$RC2" "a transient spectator_teleporting refusal does not end the broadcast"
assert_eq "5" "$(grep -c 'tournament camera' "$CALLS2")" "keeps polling through the loading screen"
assert_contains "$OUT2" "repositions=2" "counts the cut that landed after the refusals"
assert_eq "1" "$(printf '%s\n' "$OUT2" | grep -c 'still loading')" "says it once per streak, not once per poll"

assert_summary
