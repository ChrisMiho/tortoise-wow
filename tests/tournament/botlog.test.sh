#!/usr/bin/env bash
# Unit tests for scripts/tournament/bot-log-capture.sh. No server, no database:
# BOTS_LOG is overridden to point at a fixture, so nothing here reads the real
# ~400 MB bots.log.
#
# Run from WSL, not Git Bash -- lib/team.sh needs jq, and `stat -c` / GNU dd are
# what the script under test is built on:
#
#   wsl -d Ubuntu -- bash -lc 'cd /mnt/c/... && bash tests/tournament/botlog.test.sh'
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/../lib/assert.sh"

require_cmd jq sha256sum dd stat

CAPTURE="$ROOT/scripts/tournament/bot-log-capture.sh"
TEAM="stormwind-sentinels"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A fixture bots.log holding one line for a bot on the team above and one for a
# character that is not playing. Anything the capture writes has to be the first.
FIX="$TMP/bots.log"
NAME="$(TEAM_DIR="$ROOT/config/tournament/teams" bash -c '
    . "'"$ROOT"'/scripts/tournament/lib/team.sh"; team_names "'"$TEAM"'" | head -1')"
[ -n "$NAME" ] || { echo "FATAL: could not read a character name out of $TEAM" >&2; exit 1; }
{
    printf 'ai: %s decides to attack\n' "$NAME"
    printf 'ai: Someoneelse decides to run away\n'
} > "$FIX"

export BOTS_LOG="$FIX"

MARK="$TMP/bots.offset"
assert_exit 0 "--mark writes an offset for the fixture log" -- \
    bash "$CAPTURE" --mark "$MARK"
# Mark at zero so the whole fixture is inside the capture window.
printf '0\nfp 0 -\n' > "$MARK"

OK_OUT="$TMP/ok.log"
assert_exit 0 "a capture over a writable path succeeds" -- \
    bash "$CAPTURE" --since "$MARK" --team "$TEAM" --out "$OK_OUT"
assert_eq "1" "$(grep -c . "$OK_OUT")" \
    "only the playing team's line is captured"

# Regression: the failure that reported success.
#
# `> "$OUT"` inside the pipeline cannot be opened when $OUT is a directory (or an
# unwritable path, or a read-only mount). That makes the pipeline status 1 --
# which is exactly the status the "grep matched nothing" branch treats as a
# legitimate, quiet match window. The `wc -l` that follows then fails too, and
# the script printed "captured  line(s) from <n> byte(s)" with the count missing
# out of the middle of it and exited 0.
mkdir -p "$TMP/unwritable"
unwritable() { # -> a sentence naming the exit code and what was said about it
    local msg rc=0
    msg="$(bash "$CAPTURE" --since "$MARK" --team "$TEAM" --out "$TMP/unwritable" 2>&1)" || rc=$?
    [ "$rc" -ne 0 ] || { printf 'exit 0 on an unwritable --out, saying: %s\n' "$msg"; return 0; }
    case "$msg" in
        *"captured  line"*) printf 'exit %s but it still printed an empty count: %s\n' "$rc" "$msg"; return 0 ;;
    esac
    case "$msg" in
        *"$TMP/unwritable"*) ;;
        *) printf 'exit %s but the error never names the path: %s\n' "$rc" "$msg"; return 0 ;;
    esac
    printf 'non-zero, and the error names the path it could not write\n'
}
assert_eq "non-zero, and the error names the path it could not write" \
  "$(unwritable)" \
  "an unwritable --out exits non-zero with a named error, never exit 0 with an empty count"

assert_summary
