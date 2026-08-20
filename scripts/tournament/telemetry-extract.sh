#!/usr/bin/env bash
# Pull one battleground instance's telemetry out of bg.log as CSV.
#
#   ./scripts/tournament/telemetry-extract.sh --instance 101 [--log <path>] [--out <file>]
#
#   t,player,team,x,y,z,hp,maxhp,alive,combat
#   5,Wsgaone,469,1500.10,1490.20,352.00,4000,4000,1,0
#   ...
#
# bg.log carries every instance's samples interleaved with every other kind of
# battleground traffic, so filtering by instance is not optional: two concurrent
# battlegrounds would otherwise produce one nonsensical trace, and nothing that
# expects tabular data can be fed the raw log at all.
#
# Exit 0 = at least one sample was written. Exit 1 = the log was readable but
# held no samples for this instance. Exit 2 = the extract could not run (bad
# arguments, no such log, no awk) -- deliberately a third code, because "could
# not measure" is not "measured and found nothing", the same distinction
# gear-audit.sh and team-validate.sh draw.
#
# Reads bg.log, which is small and rotated. bots.log is ~10 GB -- never read that
# one unbounded, and do not add anything here that does.
#
# Run from WSL like everything else under scripts/tournament/.
set -uo pipefail

LOG="${HOME}/tortoise-wow-server-V2/logs/bg.log"
INSTANCE=""
OUT=""

usage() {
    echo "usage: $(basename "$0") --instance <id> [--log <path>] [--out <file>]" >&2
    echo "       extracts one instance's TELEMETRY samples from bg.log as CSV" >&2
    echo "       --log defaults to \$HOME/tortoise-wow-server-V2/logs/bg.log" >&2
    echo "       --out defaults to telemetry-<id>.csv in the current directory" >&2
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --instance) [ -n "${2:-}" ] || usage; INSTANCE="$2"; shift 2 ;;
        --log)      [ -n "${2:-}" ] || usage; LOG="$2";      shift 2 ;;
        --out)      [ -n "${2:-}" ] || usage; OUT="$2";      shift 2 ;;
        -h|--help)  usage ;;
        *)          echo "unknown option: $1" >&2; usage ;;
    esac
done

[ -n "$INSTANCE" ] || usage
# Instance ids are uint32. Rejecting anything else here means a typo'd id fails
# as a usage error rather than as "no samples", which would otherwise read as a
# broken sampler and send the operator off restarting mangosd for nothing.
case "$INSTANCE" in
    *[!0-9]*) echo "FATAL: --instance must be a number, got: $INSTANCE" >&2; exit 2 ;;
esac

command -v awk >/dev/null 2>&1 || { echo "FATAL: awk is not on PATH" >&2; exit 2; }

# A missing log is exit 2, not exit 1: the difference between "the sampler wrote
# nothing" and "there is nothing to read" is the whole diagnosis.
[ -f "$LOG" ] || { echo "FATAL: no such log: $LOG" >&2; exit 2; }

[ -n "$OUT" ] || OUT="telemetry-${INSTANCE}.csv"

# The body is assembled in a temp file, never next to $OUT: a failed extract must
# leave nothing behind at all -- not a stray sidecar, and above all not a
# header-only CSV, which every downstream reader would happily parse as "the
# match had zero samples" instead of failing.
BODY="$(mktemp)" || { echo "FATAL: cannot create a temp file" >&2; exit 2; }
trap 'rm -f "$BODY"' EXIT

# Two things this parse deliberately does NOT do:
#
# 1. It does not anchor on ^TELEMETRY. bg.log's timestamp prefix is controlled by
#    BgLogTimestamp in mangosd.conf (Log.cpp:332, Log.h:203-220). It is 0 in the
#    shipped .dist.in, but the live server's bind-mounted conf has it ON -- every
#    line in ~/tortoise-wow-server-V2/logs/bg.log is prefixed
#    "YYYY-MM-DD HH:MM:SS " (checked 2026-08-18). An anchored match would return
#    zero rows there and read exactly like an unset Tournament.TelemetryIntervalMs,
#    sending the operator off restarting mangosd over a working sampler.
# 2. It does not read fields by column index. It walks every whitespace field and
#    splits on the FIRST "=", keying by name. The line format is stable but its
#    field order is not something a downstream reader should depend on, so a
#    key-based parse survives a field being added, removed or moved -- including
#    the timestamp prefix, which carries no "=" and is ignored for free.
#
# A line that matches but is missing a key it needs is reported, not silently
# dropped: a torn write during log rotation is the realistic cause, and a trace
# quietly short a few samples is worse than one that says so.
awk -v want="$INSTANCE" '
    index($0, "TELEMETRY tick") == 0 { next }
    {
        split("", kv)
        for (i = 1; i <= NF; i++) {
            p = index($i, "=")
            if (p > 1) kv[substr($i, 1, p - 1)] = substr($i, p + 1)
        }
        if (!("instance" in kv) || kv["instance"] != want) next

        n = split("t,player,team,x,y,z,hp,maxhp,alive,combat", cols, ",")
        ok = 1
        for (i = 1; i <= n; i++) {
            if (!(cols[i] in kv)) {
                printf "WARNING: %s:%d has no %s= -- sample skipped\n", FILENAME, FNR, cols[i] > "/dev/stderr"
                ok = 0
                break
            }
        }
        if (!ok) next

        out = kv[cols[1]]
        for (i = 2; i <= n; i++) out = out "," kv[cols[i]]
        print out
    }
' "$LOG" | LC_ALL=C sort -t, -k1,1n -k2,2 > "$BODY"
# pipefail is on, so this covers awk dying on a malformed log as well as sort.
# Without the check a failed read is indistinguishable from an empty body, and
# the operator would be sent off restarting mangosd over an unreadable file.
pipe_status=$?
[ "$pipe_status" -eq 0 ] || { echo "FATAL: could not read $LOG (exit $pipe_status)" >&2; exit 2; }

rows="$(wc -l < "$BODY" | tr -d ' ')"
if [ "$rows" -eq 0 ]; then
    # Exiting without touching $OUT is not enough. Nothing here owns that path,
    # so a CSV an EARLIER successful run left at it survives this failure whole,
    # and a downstream reader that only checks the file -- match-run.sh's report
    # step is exactly that -- reads the previous instance's telemetry as this
    # instance's. Removing it makes the absent file agree with the exit code.
    if [ -e "$OUT" ]; then
        rm -f "$OUT" || {
            echo "FATAL: no samples for instance $INSTANCE, and the stale $OUT could not be removed" >&2
            exit 2; }
        echo "NOTE: removed the stale $OUT left by an earlier run" >&2
    fi
    echo "FATAL: no telemetry samples for instance $INSTANCE in $LOG" >&2
    echo "       Tournament.TelemetryIntervalMs is probably unset or 0, which disables" >&2
    echo "       sampling entirely -- or it was set but mangosd was not restarted" >&2
    echo "       afterwards (the live conf is read only at startup)." >&2
    exit 1
fi

{ echo "t,player,team,x,y,z,hp,maxhp,alive,combat"; cat "$BODY"; } > "$OUT" || {
    echo "FATAL: cannot write $OUT" >&2; exit 2; }

# stderr, not stdout: stdout stays clean for the CSV should anyone ever pipe it.
echo "TELEMETRY-EXTRACT instance=$INSTANCE samples=$rows out=$OUT" >&2
