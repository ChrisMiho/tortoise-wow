#!/usr/bin/env bash
# Collect one match's telemetry artifacts. Source, don't execute.
#
# This lives here rather than inline in match-run.sh for one reason: the branch
# that tells a missing script apart from a telemetry finding is the branch most
# worth testing, and match-run.sh cannot be run in a test -- it wants docker, a
# database and twenty logged-in bots before it reaches this point.
#
# EVERY PATH RETURNS 0. The match has already been played and decided by the time
# this runs; a missing artifact is a missing artifact, and a non-zero return here
# would tell the bracket driver the match never happened.

# Narration. match-run.sh replaces this with one that also writes match.log; on
# its own -- in a test, or any other caller -- it goes to stderr.
if ! declare -F artifacts_log >/dev/null 2>&1; then
    artifacts_log() { printf '%s\n' "$*" >&2; }
fi

telemetry_artifacts() { # <script-dir> <run-dir> <instance>
    local bin="$1" run="$2" inst="$3" rc=0

    # The extractor and the report ship separately from match-run.sh. Their
    # absence is "no telemetry today", not a broken match.
    if [ ! -x "$bin/telemetry-extract.sh" ]; then
        artifacts_log "$bin/telemetry-extract.sh is not present -- skipping telemetry artifacts"
        return 0
    fi

    if ! "$bin/telemetry-extract.sh" --instance "$inst" --out "$run/telemetry.csv" \
            >> "$run/match.log" 2>&1; then
        artifacts_log "telemetry unavailable for instance $inst (is Tournament.TelemetryIntervalMs set, and was mangosd restarted after setting it?)"
        return 0
    fi

    # Existence-checked exactly like its sibling above. Without this the report
    # step fails with 127 and the shell's "No such file or directory" is written
    # into telemetry-report.txt, where it is indistinguishable from a report --
    # and the non-zero status is then narrated as "stuck bots, or fewer than 20
    # entered", a finding about the match that nothing ever measured.
    if [ ! -x "$bin/telemetry-report.sh" ]; then
        artifacts_log "MISSING SCRIPT: $bin/telemetry-report.sh is not present -- $run/telemetry.csv was written but nothing read it; this says nothing about the bots"
        return 0
    fi

    "$bin/telemetry-report.sh" "$run/telemetry.csv" > "$run/telemetry-report.txt" 2>&1 || rc=$?

    if [ "$rc" -eq 0 ]; then
        artifacts_log "telemetry report written to $run/telemetry-report.txt"
    elif [ "$rc" -eq 127 ] || [ "$rc" -eq 126 ]; then
        # These two survive the check above when the file is there but still does
        # not run: 127 is "not found" (something the report itself called, or the
        # script deleted between the check and the call) and 126 is a shebang
        # naming an interpreter that is not installed. Both are a missing script,
        # neither is a telemetry finding, and the file left behind holds the
        # shell's error rather than a report, so it goes.
        artifacts_log "MISSING SCRIPT: $bin/telemetry-report.sh exited $rc, it could not be executed -- $(head -n 1 "$run/telemetry-report.txt" 2>/dev/null); this says nothing about the bots"
        rm -f "$run/telemetry-report.txt"
    else
        artifacts_log "telemetry report flags a problem (stuck bots, or fewer than 20 entered) -- see $run/telemetry-report.txt"
    fi
    return 0
}
