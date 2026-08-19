#!/usr/bin/env bash
# Unit tests for scripts/tournament/telemetry-extract.sh. No server, no database,
# no build: the fixture log below IS the sampler as far as this file is
# concerned, so nothing here waits on the C++ side of the telemetry work.
#
# Run from WSL, not Git Bash -- everything under scripts/tournament/ assumes a
# POSIX environment, and MSYS rewrites the paths this file builds:
#
#   wsl -d Ubuntu -- bash -lc 'cd /mnt/c/... && bash tests/tournament/telemetry.test.sh'
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/../lib/assert.sh"

require_cmd awk sort

EXTRACT="$ROOT/scripts/tournament/telemetry-extract.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The fixture is everything bg.log actually throws at this script:
#
#  - an unrelated bg.log line, because the sampler shares the file with every
#    other kind of battleground traffic;
#  - two samples at t=5 and two at t=10 for the wanted instance, so sort order is
#    observable and t=10 following t=5 can only come out right under a NUMERIC
#    sort (lexically "10" precedes "5");
#  - a sample for instance 999, which must not appear in the output -- two
#    concurrent battlegrounds is the normal case, not the exotic one;
#  - one line carrying a BgLogTimestamp prefix, its keys in a different order and
#    an extra zone= field. It is the same sample as any other and must extract
#    identically: that is the whole point of parsing by key rather than by column.
FIX="$TMP/bg.log"
cat > "$FIX" <<'EOF'
2026-08-16 21:00:00 BATTLEGROUND: instance 101 on map 489 started
TELEMETRY tick instance=101 map=489 t=5 player=Wsgaone team=469 x=1500.10 y=1490.20 z=352.00 hp=4000 maxhp=4000 alive=1 combat=0
TELEMETRY tick instance=101 map=489 t=5 player=Wsghone team=67 x=900.50 y=1440.00 z=345.10 hp=3800 maxhp=4200 alive=1 combat=1
TELEMETRY tick instance=999 map=489 t=5 player=Otherguy team=469 x=1.00 y=2.00 z=3.00 hp=1 maxhp=1 alive=1 combat=0
2026-08-16 21:00:10 TELEMETRY tick player=Wsgaone t=10 zone=3277 instance=101 team=469 combat=1 alive=1 maxhp=4000 hp=3900 z=352.00 y=1480.00 x=1495.00 map=489
TELEMETRY tick instance=101 map=489 t=10 player=Wsgatwo team=469 x=1400.00 y=1470.00 z=350.00 hp=4000 maxhp=4000 alive=0 combat=0
EOF

OUT="$TMP/telemetry.csv"
rc=0
bash "$EXTRACT" --instance 101 --log "$FIX" --out "$OUT" 2>/dev/null || rc=$?

assert_eq "0" "$rc" "the extract exits 0 when the instance has samples"

# The whole file in one assertion: header, contents, and -- because t=10 sorts
# after t=5 and Wsgaone before Wsgatwo -- the ordering rule as well.
EXPECTED="$(cat <<'EOF'
t,player,team,x,y,z,hp,maxhp,alive,combat
5,Wsgaone,469,1500.10,1490.20,352.00,4000,4000,1,0
5,Wsghone,67,900.50,1440.00,345.10,3800,4200,1,1
10,Wsgaone,469,1495.00,1480.00,352.00,3900,4000,1,1
10,Wsgatwo,469,1400.00,1470.00,350.00,4000,4000,0,0
EOF
)"
assert_eq "$EXPECTED" "$(cat "$OUT")" \
  "the CSV is the header plus one row per sample, sorted by t then player"

assert_eq "0" "$(grep -c 'Otherguy' "$OUT")" \
  "samples belonging to another instance are excluded"

# The reordered, timestamp-prefixed, zone=-carrying line. Under a column-index
# parse this row would be garbage or absent; under a key parse it is ordinary.
assert_eq "10,Wsgaone,469,1495.00,1480.00,352.00,3900,4000,1,1" \
  "$(grep '^10,Wsgaone,' "$OUT")" \
  "keys are read by name, so field order, an extra field and a log prefix are all harmless"

# A run that matched nothing has four things to get right at once, and any one of
# them alone is worthless: the exit code tells a caller to stop, the message
# tells the operator where to look, and the absent file stops a header-only CSV
# being parsed downstream as a match in which nobody moved. So they are one
# observation and therefore one assertion, the idiom bracket.test.sh uses.
no_samples() { # -> a sentence naming everything that held
    local out="$TMP/absent.csv" msg rc=0
    msg="$(bash "$EXTRACT" --instance 777 --log "$FIX" --out "$out" 2>&1 >/dev/null)" || rc=$?
    [ "$rc" -eq 1 ] || { printf 'exit %s, expected 1\n' "$rc"; return 0; }
    case "$msg" in *777*)   ;; *) printf 'exit 1 but the message never names the instance: %s\n' "$msg"; return 0 ;; esac
    case "$msg" in *"$FIX"*) ;; *) printf 'exit 1 but the message never names the log: %s\n' "$msg"; return 0 ;; esac
    case "$msg" in *Tournament.TelemetryIntervalMs*) ;;
                   *) printf 'exit 1 but the message never names the likely cause: %s\n' "$msg"; return 0 ;; esac
    [ ! -e "$out" ] || { printf 'exit 1 but it left %s behind: %s\n' "$out" "$(cat "$out")"; return 0; }
    printf 'exit 1, names the instance, the log and the cause, and writes no file\n'
}
assert_eq "exit 1, names the instance, the log and the cause, and writes no file" \
  "$(no_samples)" \
  "an instance with no samples exits 1, says why, and leaves no header-only file"

# Exit 2, not 1. "There is nothing to read" and "the sampler wrote nothing" send
# the operator to completely different places, and a caller that retries on 1
# would spin forever on a path typo.
assert_exit 2 "a missing log file is exit 2, not exit 1" -- \
  bash "$EXTRACT" --instance 101 --log "$TMP/no-such-file.log" --out "$TMP/never.csv"

assert_summary
