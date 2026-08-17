#!/usr/bin/env bash
# Unit tests for scripts/tournament/lib/ctl.sh. No server, no database, no build.
#
# Every assertion runs against a captured string rather than a live console, so
# this file is deliberately independent of whether the C++ commands exist yet --
# ctl.sh calls wsg_console only inside ctl(), never at source time.
#
# Run from WSL, not Git Bash, to match the rest of this repo's shell tests:
#
#   wsl -d Ubuntu -- bash -lc 'cd /mnt/c/... && bash tests/tournament/ctl.test.sh'
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/../lib/assert.sh"
. "$ROOT/scripts/tournament/lib/ctl.sh"

# --- a record buried in console noise ---------------------------------------
#
# The console is never quiet: the prompt carries no newline
# (CliRunnable.cpp:66-70) and the world logs over the top of a command's reply.
# A parser that only works on a clean line does not work.
SAMPLE='mangos>tournament create 2 60
TOURNAMENT create instance=101 type=2 map=489 bracket=5
[World] some unrelated chatter'

assert_eq "101" "$(ctl_field "$SAMPLE" instance)" "extracts instance out of console noise"
assert_eq "489" "$(ctl_field "$SAMPLE" map)"      "extracts map out of console noise"

# `stance` is missing, and it is also a suffix of `instance` -- so this one
# assertion pins both halves of the leading anchor: a key that is not there
# reads empty, and it does not read 101 by matching inside another key's name.
assert_eq "" "$(ctl_field "$SAMPLE" stance)" "a missing key is empty, and does not match inside instance="

# --- the two ways an unanchored parser reads the wrong thing -----------------
#
# `ok` is a prefix of `okay`, and `slot=0` is the head slot -- the most ordinary
# result `equip` produces, and the one a truthiness test would throw away.
SAMPLE2='TOURNAMENT equip player=Wsgaone item=12640 slot=0 ok=1 okay=nonsense'

assert_eq "1" "$(ctl_field "$SAMPLE2" ok)"   "ok=1 is not confused with the longer okay="
assert_eq "0" "$(ctl_field "$SAMPLE2" slot)" "slot=0 reads 0, not empty"

# --- failure is reported through the same field parser ----------------------
ERR='TOURNAMENT create error=no_template'

assert_eq "no_template" "$(ctl_field "$ERR" error)" "extracts an error reason"

assert_summary
