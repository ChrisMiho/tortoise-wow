#!/usr/bin/env bash
# Turn a telemetry CSV into the only two questions worth asking of a bot match:
# did every bot actually get in, and did it actually go anywhere?
#
#   ./scripts/tournament/telemetry-report.sh <csv> [--expected 20]
#
#   ENTRY player=Wsgaone team=469 firstSeen=5 samples=240
#   ...
#   MOVEMENT player=Wsgaone distance=1840.5 maxStep=31.2 idleSamples=12 stuck=0
#   ...
#   REPORT players=20 expected=20 entered=20 stuck=0
#
# A raw extract is 4800 rows and answers nothing on its own. These three shapes
# are what a human or a gate can act on: who turned up, whether they moved, and
# one line summarising both.
#
# Exit 0 = at least --expected players entered and none is stuck.
# Exit 1 = the match is suspect -- too few players entered, or a bot never moved.
#          The report is still printed in full; the code is for the gate.
# Exit 2 = the report could not be produced at all (bad arguments, no such CSV,
#          no awk) -- deliberately a third code, because "could not measure" is
#          not "measured and found a problem", the same distinction
#          telemetry-extract.sh, gear-audit.sh and team-validate.sh draw.
#
# Run from WSL like everything else under scripts/tournament/.
set -uo pipefail

CSV=""
EXPECTED=20

usage() {
    echo "usage: $(basename "$0") <csv> [--expected <n>]" >&2
    echo "       reports entry and movement per player from a telemetry CSV" >&2
    echo "       --expected defaults to 20 (a full Warsong Gulch roster)" >&2
    exit 2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --expected) [ -n "${2:-}" ] || usage; EXPECTED="$2"; shift 2 ;;
        -h|--help)  usage ;;
        -*)         echo "unknown option: $1" >&2; usage ;;
        *)          [ -z "$CSV" ] || { echo "FATAL: more than one CSV given: $CSV and $1" >&2; usage; }
                    CSV="$1"; shift ;;
    esac
done

[ -n "$CSV" ] || usage

case "$EXPECTED" in
    ""|*[!0-9]*) echo "FATAL: --expected must be a number, got: $EXPECTED" >&2; exit 2 ;;
esac

command -v awk >/dev/null 2>&1 || { echo "FATAL: awk is not on PATH" >&2; exit 2; }

# Exit 2, not 1. A path typo and a match nobody entered are the same silence to a
# caller that only looks at the code, and they send the operator to completely
# different places.
[ -f "$CSV" ] || { echo "FATAL: no such CSV: $CSV" >&2; exit 2; }
[ -r "$CSV" ] || { echo "FATAL: cannot read CSV: $CSV" >&2; exit 2; }

# A bot that never crosses this much distance IN TOTAL, across the whole match,
# never left its spawn. Warsong Gulch is roughly 900 yards end to end, so 10
# yards of total travel is not "played cautiously" -- it is a bot that stood on
# the graveyard for twenty minutes while the scoreboard said 0-0. Total travel,
# not displacement: a bot that walked out and came back has still played, and
# would read as zero under a start-to-end measure.
STUCK_TOTAL_DISTANCE=10

# A sample counts as idle when the step since the previous sample is under this.
# Coordinates are logged to two decimals, so a genuinely motionless bot produces
# a step of exactly 0.00 and the epsilon only absorbs float noise out of sqrt().
#
# idleSamples is NOT a second stuck signal and must stay readable as its own
# thing: a high idleSamples with a healthy distance is a bot that moved and then
# held position, which is exactly what a flag carrier in the tunnel and a
# defender on the roof look like. Only distance decides stuck.
IDLE_STEP_EPSILON=0.01

# LC_ALL=C because the %.1f below must print a decimal POINT. Under a comma
# locale every distance in the report would come out as "1840,5", which splits
# the field in half for anything that reads this output as CSV or greps for it.
LC_ALL=C awk -F, -v expected="$EXPECTED" \
                 -v stuckdist="$STUCK_TOTAL_DISTANCE" \
                 -v idleeps="$IDLE_STEP_EPSILON" '
    # Only skip line 1 when it actually IS the header. A body-only CSV -- a tail,
    # a concatenation, a hand-cut slice -- would otherwise silently lose its
    # first sample, and that sample is the one ENTRY reports firstSeen from.
    NR == 1 && $1 == "t" { next }

    # Blank trailing line, or a row torn by a rotation mid-write. Reported, never
    # silently dropped: a trace quietly short a few samples is worse than one
    # that says so, and a short trace is exactly what makes a bot look stuck.
    NF == 0 { next }
    NF < 10 {
        printf "WARNING: %s:%d has %d fields, expected 10 -- sample skipped\n",
               FILENAME, FNR, NF > "/dev/stderr"
        next
    }
    # Coordinates that are not numbers would be read as 0 by awk and manufacture
    # a thousand-yard step out of nothing, which is the one failure mode that
    # turns this report into a liar rather than an error.
    ($4 !~ /^-?[0-9]+(\.[0-9]+)?$/) || ($5 !~ /^-?[0-9]+(\.[0-9]+)?$/) || ($6 !~ /^-?[0-9]+(\.[0-9]+)?$/) {
        printf "WARNING: %s:%d has non-numeric coordinates -- sample skipped\n",
               FILENAME, FNR > "/dev/stderr"
        next
    }

    {
        p = $2
        # order[] is what makes the output stable. Iterating an associative array
        # with for-in yields hash order, which changes with the key set and
        # between awk implementations, so two runs over two matches would print
        # their players in unrelated orders and no diff of the two would mean
        # anything. First-seen order is also the useful one: late joiners sort to
        # the bottom, where an entry problem is easiest to read.
        if (!(p in first)) {
            first[p] = $1
            team[p]  = $3
            order[++n] = p
            dist[p] = 0; maxstep[p] = 0; idle[p] = 0
        }
        samples[p]++

        if (p in px) {
            dx = $4 - px[p]; dy = $5 - py[p]; dz = $6 - pz[p]
            step = sqrt(dx*dx + dy*dy + dz*dz)
            dist[p] += step
            if (step > maxstep[p]) maxstep[p] = step
            if (step < idleeps) idle[p]++
        }
        px[p] = $4; py[p] = $5; pz[p] = $6
    }

    END {
        # Entry first, movement second, summary last -- and every player in both
        # blocks. Interleaving them would read fine for two players and be
        # unusable for twenty.
        for (i = 1; i <= n; i++) {
            p = order[i]
            printf "ENTRY player=%s team=%s firstSeen=%s samples=%d\n",
                   p, team[p], first[p], samples[p]
        }

        stuckcount = 0
        for (i = 1; i <= n; i++) {
            p = order[i]
            # A player seen in a single sample has nowhere to have travelled from
            # and lands here as stuck, which is correct rather than harsh: one
            # sample out of a whole match is itself a bot that was not playing.
            st = (dist[p] < stuckdist) ? 1 : 0
            stuckcount += st
            printf "MOVEMENT player=%s distance=%.1f maxStep=%.1f idleSamples=%d stuck=%d\n",
                   p, dist[p], maxstep[p], idle[p], st
        }

        # players and entered are the same count today: a player is in the CSV
        # only because the sampler saw them inside the battleground. Both are
        # printed because they are read by different eyes -- players is the count
        # the CSV describes, entered is the number the gate is checking -- and a
        # REPORT line missing either would need every downstream reader changed
        # to put it back.
        printf "REPORT players=%d expected=%d entered=%d stuck=%d\n",
               n, expected, n, stuckcount

        # The whole report is already on stdout by now. The code exists so this
        # can sit in a match script without anyone reading the lines.
        exit (n < expected || stuckcount > 0) ? 1 : 0
    }
' "$CSV"
rc=$?

# awk exits 2 on its own errors, which lands on the same "could not measure"
# code by design. Anything else is passed straight through.
exit "$rc"
