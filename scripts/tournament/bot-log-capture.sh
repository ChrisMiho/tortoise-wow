#!/usr/bin/env bash
# Capture only the bots.log written during one match, for only the bots playing.
#
#   ./scripts/tournament/bot-log-capture.sh --mark  <offset-file>
#   ...run the match...
#   ./scripts/tournament/bot-log-capture.sh --since <offset-file> \
#        --team stormwind-sentinels --team orgrimmar-warsong --out match-bots.log
#
# bots.log is the bot AI's per-tick decision trace. It reached 12.0 GB before
# scripts/cap-logs.sh installed 5-minute rotation (see
# docs/playerbots/BOTS-LOG-GROWTH-HANDOFF.md); with the cap in place the LIVE
# file still peaks around 435 MB between rotations, measured 2026-08-18. That is
# why nobody ever looks at it, and why this script exists.
#
# ROTATION CANNOT BE DETECTED BY SIZE ALONE, and that is the subtle part.
# cap-logs.sh rotates with `copytruncate`: mangosd holds bots.log open, so
# logrotate copies the file aside and truncates it IN PLACE. Same path, same
# inode, size back to 0 -- and then it regrows at ~87 MB/min. Rotation fires
# every five minutes, so a twenty-minute match crosses four boundaries, and by
# the time --since runs the truncated-and-regrown file is normally LARGER than
# the mark again. A `now < start` test therefore misses the ordinary case: it
# catches only a capture landing in the first seconds after a truncate.
# Everything else sails past it, and `tail -c "+$((start + 1))"` then returns an
# arbitrary later slice of the NEW file, presented as the match window.
#
# So the mark carries a FINGERPRINT as well as a size: the sha256 of the last
# few KB before the offset. Those bytes are immutable in an append-only log, so
# if they still hash the same the offset still means what it meant; if they do
# not, the file underneath it was replaced. Both checks are kept -- the size
# test catches a shrink the fingerprint cannot see (a mark taken at offset 0),
# and the fingerprint catches the regrowth the size test cannot see.
#
# THE ONE RULE: nothing here may read bots.log from the beginning. The read is
# anchored on a byte offset taken before the match, so `tail -c "+$((off + 1))"`
# starts at the byte the match started at and the work is proportional to the
# match, not to the file. A `grep` over the whole file, or a `cat` piped into
# anything, is minutes of I/O and defeats the entire point -- there is no
# variant of that which is acceptable here. The fingerprint reads a fixed 4 KB
# at an absolute offset, which is O(1) and does not bend that rule.
#
# Run from WSL: `stat -c '%s'` is GNU stat, `dd iflag=skip_bytes` is GNU dd, and
# lib/team.sh needs jq -- none of which are on Git Bash's PATH on this host.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/team.sh
. "$HERE/lib/team.sh"

# Same server checkout the rest of the WSG tooling defaults to.
BOTS_LOG="${BOTS_LOG:-${WSG_SERVER_ROOT:-$HOME/tortoise-wow-server-V2}/logs/bots.log}"

# How many bytes before the mark get fingerprinted. Large enough that a
# collision is not a thing that happens, small enough that the read is free:
# bots.log lines run ~150 bytes, so this is a few dozen lines of trace.
FP_BYTES=4096

usage() {
    cat >&2 <<'USAGE'
usage: bot-log-capture.sh --mark <offset-file>
       bot-log-capture.sh --since <offset-file> --team <id> [--team <id>] --out <file>
USAGE
    exit 2
}

MODE=""; MARKFILE=""; OUT=""; TEAMS=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --mark)  [ -n "${2:-}" ] || usage; MODE=mark;  MARKFILE="$2"; shift 2 ;;
        --since) [ -n "${2:-}" ] || usage; MODE=since; MARKFILE="$2"; shift 2 ;;
        --team)  [ -n "${2:-}" ] || usage; TEAMS+=("$2"); shift 2 ;;
        --out)   [ -n "${2:-}" ] || usage; OUT="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "unknown arg: $1" >&2; usage ;;
    esac
done

[ -f "$BOTS_LOG" ] || { echo "no bots.log at $BOTS_LOG" >&2; exit 2; }

# `stat -c` is GNU-only. A busybox/BSD stat fails loudly here rather than
# handing back an empty size that would read as "the file is empty".
log_size() { # -> size of bots.log in bytes
    stat -c '%s' "$BOTS_LOG"
}

is_uint() { # <string>
    case "${1:-}" in
        ""|*[!0-9]*) return 1 ;;
    esac
    return 0
}

# sha256 of the <len> bytes ENDING at absolute offset <end>.
#
# Anchored on an absolute offset on both sides, never on `tail -c "$len"`: the
# file gains ~87 MB/min, so "the last 4 KB" already means different bytes by the
# time the mark is written than it did when the size was stat'd, and the
# fingerprint would then fail to match a file nobody rotated. `skip_bytes` and
# `count_bytes` are GNU dd; the seek keeps this O(len), not O(file).
log_fingerprint() { # <end-offset> <len> -> hex digest
    local end="$1" len="$2" sum
    sum="$(dd if="$BOTS_LOG" bs=1M iflag=skip_bytes,count_bytes \
              skip="$((end - len))" count="$len" status=none | sha256sum)" || return 1
    printf '%s\n' "${sum%% *}"
}

# --- mark --------------------------------------------------------------------

if [ "$MODE" = "mark" ]; then
    mkdir -p "$(dirname "$MARKFILE")" 2>/dev/null || true
    size="$(log_size)" || { echo "cannot stat $BOTS_LOG" >&2; exit 2; }
    is_uint "$size" || { echo "stat -c '%s' returned '$size' -- GNU stat is required (run this from WSL)" >&2; exit 2; }

    # A log shorter than FP_BYTES is fingerprinted whole; an empty one -- only
    # ever seen in the seconds after a rotation -- gets no fingerprint, because
    # there are no bytes before offset 0 to hash. It needs none: a capture from
    # 0 is exactly what the rotation branch falls back to anyway.
    fp_len="$FP_BYTES"
    [ "$fp_len" -le "$size" ] || fp_len="$size"
    fp="-"
    if [ "$fp_len" -gt 0 ]; then
        fp="$(log_fingerprint "$size" "$fp_len")" \
            || { echo "cannot fingerprint $BOTS_LOG at byte $size" >&2; exit 2; }
    fi

    # Line 1 stays the bare byte offset -- that is the documented contract of
    # the mark file, and anything that only wants the offset can still read the
    # first line. The fingerprint is a second line.
    { printf '%s\n' "$size"; printf 'fp %s %s\n' "$fp_len" "$fp"; } > "$MARKFILE" \
        || { echo "cannot write $MARKFILE" >&2; exit 2; }
    echo "marked bots.log at $size bytes"
    exit 0
fi

# --- since -------------------------------------------------------------------

[ "$MODE" = "since" ] || usage
[ -f "$MARKFILE" ] || { echo "no mark file at $MARKFILE -- call --mark before the match" >&2; exit 2; }
[ -n "$OUT" ] || { echo "--since needs --out" >&2; usage; }
[ "${#TEAMS[@]}" -gt 0 ] || { echo "--since needs at least one --team" >&2; usage; }

MARK_LINE=""; FP_LINE=""
{ IFS= read -r MARK_LINE || true; IFS= read -r FP_LINE || true; } < "$MARKFILE"
start="$(printf '%s' "$MARK_LINE" | tr -d ' \r\n')"
is_uint "$start" || { echo "mark file $MARKFILE does not hold a byte offset: '$start'" >&2; exit 2; }

fp_len=""; fp_want=""
case "$FP_LINE" in
    "fp "*) read -r _fp_tag fp_len fp_want <<<"$(printf '%s' "$FP_LINE" | tr -d '\r')" ;;
esac

now="$(log_size)" || { echo "cannot stat $BOTS_LOG" >&2; exit 2; }
is_uint "$now" || { echo "stat -c '%s' returned '$now' -- GNU stat is required (run this from WSL)" >&2; exit 2; }

# Is bots.log still the file the mark was taken on?
#
# Restarting from 0 reads the whole NEW file, which is correct and still
# bounded. Reading on from an offset into a file that was replaced underneath it
# returns an arbitrary slice of a later log window dressed up as the match --
# and a plausible-looking wrong answer is the only outcome here worth
# engineering against.
#
# It re-stats rather than trusting the caller's `now`, because it is called
# again AFTER the capture, by which point that number is minutes old.
mark_is_stale() { # -> 0 when the offset no longer points at the marked bytes
    local fp_now cur
    cur="$(log_size)" || { echo "cannot stat $BOTS_LOG" >&2; exit 2; }
    is_uint "$cur" || { echo "stat -c '%s' returned '$cur' -- GNU stat is required (run this from WSL)" >&2; exit 2; }
    if [ "$cur" -lt "$start" ]; then
        echo "WARNING: bots.log shrank ($start -> $cur bytes) -- it was rotated or truncated mid-match" >&2
        return 0
    fi
    [ "$start" -gt 0 ] || return 1
    if [ -z "$fp_len" ] || ! is_uint "$fp_len" || [ -z "$fp_want" ] || [ "$fp_len" -eq 0 ]; then
        echo "WARNING: mark file $MARKFILE carries no fingerprint -- a rotation that regrew past $start bytes cannot be detected, so what follows may be an arbitrary slice of a newer file" >&2
        return 1
    fi
    fp_now="$(log_fingerprint "$start" "$fp_len")" \
        || { echo "cannot fingerprint $BOTS_LOG at byte $start" >&2; exit 2; }
    if [ "$fp_now" != "$fp_want" ]; then
        echo "WARNING: bots.log was rotated mid-match and has already regrown past the mark (now $cur bytes, marked at $start) -- the bytes at that offset are not the ones that were marked" >&2
        return 0
    fi
    return 1
}

if mark_is_stale; then
    echo "         capturing from the start of the new file; whatever was written before the rotation is in bots.log.1.gz and is not recovered here" >&2
    start=0
fi

# One alternation of every playing bot's name. Validating first is not ceremony:
# team_names on a malformed file yields blank lines, and an empty alternative in
# an ERE matches EVERY line, which would dump the whole match window unfiltered.
pattern=""
for t in "${TEAMS[@]}"; do
    team_validate "$t" >/dev/null || { echo "team $t does not validate" >&2; exit 2; }
    while IFS= read -r nm; do
        [ -n "$nm" ] || continue
        pattern="$pattern${pattern:+|}$nm"
    done < <(team_names "$t")
done
[ -n "$pattern" ] || { echo "the named team(s) list no characters" >&2; exit 2; }

mkdir -p "$(dirname "$OUT")" 2>/dev/null || true

# +N is 1-INDEXED in `tail -c`, so the first byte after the mark is start+1.
# The obvious-looking alternative, `tail -c "$((now - start))"`, counts from the
# END instead and silently returns the wrong window the moment the file grows
# between the stat and the read -- which, at ~87 MB/min, it always does.
#
# Names are alphabetic (team_validate enforces it), so they carry no regex
# metacharacters and \b keeps a name from matching inside a longer word.
capture_from() { # <offset>
    # The output file is opened HERE, on its own, before the pipeline that fills
    # it. Left inside the pipeline, a `> "$OUT"` that cannot be opened -- an
    # unwritable directory, a read-only mount -- makes the pipeline status 1,
    # which is exactly the code the "grep matched nothing" branch below waves
    # through. The capture then reports success over a file it never wrote.
    : > "$OUT" || { echo "cannot write $OUT" >&2; exit 2; }
    tail -c "+$(($1 + 1))" "$BOTS_LOG" | grep -aE "\b($pattern)\b" > "$OUT"
    rc=$?
    # grep exits 1 on "no lines matched", which is a legitimate outcome -- an
    # idle match window is quiet, and BotLogFile may be off entirely. Anything
    # above 1 is a real failure.
    if [ "$rc" -gt 1 ]; then
        echo "capture failed reading $BOTS_LOG from byte $1" >&2
        exit 1
    fi
}

capture_from "$start"

# And rotation during the read itself. The gap between the check above and the
# last byte read is a whole tail of a large file wide, and logrotate does not
# care that a capture is in flight, so re-check the anchor afterwards rather
# than shipping a file that quietly holds the wrong minutes.
if [ "$start" -gt 0 ] && mark_is_stale; then
    echo "         that happened DURING the capture; re-reading from the start of the new file" >&2
    start=0
    now="$(log_size)"
    is_uint "$now" || { echo "cannot stat $BOTS_LOG" >&2; exit 2; }
    capture_from "$start"
fi

lines="$(wc -l < "$OUT" | tr -d ' ')"
# An unreadable $OUT gives wc nothing to count and an empty $lines, which would
# print "captured  line(s)" and exit 0 -- a success line with the number missing
# out of it. Anything that is not a count is a failure, and says so.
is_uint "$lines" || { echo "cannot count the lines in $OUT" >&2; exit 2; }
echo "captured $lines line(s) from $((now - start)) byte(s) into $OUT"
