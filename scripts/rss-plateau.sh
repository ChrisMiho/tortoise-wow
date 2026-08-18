#!/usr/bin/env bash
# Has mangosd's RSS stopped rising? Reads the trace written by rss-trace.sh.
#
#   ./scripts/rss-plateau.sh            # default 10-sample (5 min) window
#   ./scripts/rss-plateau.sh 20         # 20-sample (10 min) window
#
# Read-only. Prints the window, the drift across it, and one of three verdicts:
# PLATEAU / RISING / FALLING.
#
# THE CRITERION, stated once so every ramp point in the artifact uses the same
# one: RSS has plateaued when the total drift across the window is under
# TW_PLATEAU_PCT (default 0.25%) of the window's opening RSS.
#
# 0.25% is chosen against the thing being measured, not picked round. At a
# ~3 GiB bot-free intercept it is ~8 MiB, which is far below the ~13 MB/bot
# 011 extrapolates -- so a single bot still logging in and building its
# inventory cannot hide inside the tolerance, which is exactly the failure mode
# ("REACHED is not a plateau") this script exists to prevent. Widen it only
# with a note in the doc saying why.
#
# Also prints the online-bot count at both ends of the window. A "plateau" with
# the count still climbing is not a plateau -- it is a coincidence, and the
# operator needs to see it. That case is reported explicitly rather than being
# left to be noticed.
set -uo pipefail

W="${1:-10}"
F="${TW_RSS_TRACE:-/home/deck/rss-watch.tsv}"
PCT="${TW_PLATEAU_PCT:-0.25}"

[ -f "$F" ] || { echo "FATAL: no trace at $F — is scripts/rss-trace.sh running?" >&2; exit 1; }
[[ "$W" =~ ^[0-9]+$ ]] || { echo "FATAL: window must be an integer number of samples" >&2; exit 1; }

# Rows with a blank rss_kb (mangosd restarting, docker exec hiccup) are skipped
# rather than treated as zero -- a zero would read as a colossal drop and could
# report FALLING through a routine restart.
tail -n "$W" "$F" | awk -F'\t' -v tol="$PCT" '
  $4 ~ /^[0-9]+$/ { n++; kb[n]=$4+0; ts[n]=$1; onl[n]=$3 }
  END {
    if (n < 3) {
      printf "INSUFFICIENT: only %d usable sample(s) in the window\n", n
      exit 3
    }
    first = kb[1]; last = kb[n]; min = kb[1]; max = kb[1]
    for (i = 1; i <= n; i++) { if (kb[i] < min) min = kb[i]; if (kb[i] > max) max = kb[i] }
    d = last - first
    pct = (first > 0) ? 100.0 * d / first : 0

    printf "window:  %s .. %s  (%d usable samples)\n", ts[1], ts[n], n
    printf "online:  %s -> %s\n", onl[1], onl[n]
    printf "rss:     %.3f GiB -> %.3f GiB   drift %+.1f MiB (%+.3f%%)\n", \
           first/1048576, last/1048576, d/1024, pct
    printf "spread:  %.3f .. %.3f GiB\n", min/1048576, max/1048576

    # Rising bot count invalidates a plateau claim no matter what RSS did.
    climbing = (onl[1] ~ /^[0-9]+$/ && onl[n] ~ /^[0-9]+$/ && onl[n] > onl[1])

    if (pct > tol) { print "VERDICT: RISING — do not take the ramp row yet"; exit 1 }
    if (pct < -tol) { print "VERDICT: FALLING — something released memory; investigate before recording"; exit 2 }
    if (climbing) {
      print "VERDICT: NOT SETTLED — RSS is flat but bots are still logging in; wait for the count to settle too"
      exit 1
    }
    printf "VERDICT: PLATEAU — drift within +/-%s%% and the bot count is stable\n", tol
    exit 0
  }'
