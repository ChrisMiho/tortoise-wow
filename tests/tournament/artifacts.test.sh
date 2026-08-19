#!/usr/bin/env bash
# Unit tests for scripts/tournament/lib/artifacts.sh and for match-run.sh's
# run-start cleanup. No server, no database, no bots: the two scripts
# telemetry_artifacts shells out to are stubs in a temp bin dir.
#
#   wsl -d Ubuntu -- bash -lc 'cd /mnt/c/... && bash tests/tournament/artifacts.test.sh'
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/../lib/assert.sh"
. "$ROOT/scripts/tournament/lib/artifacts.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Narration is captured rather than printed, because what the operator is told is
# half of every assertion here: the bug was a real failure narrated as a finding.
LOGGED=""
artifacts_log() { LOGGED="${LOGGED}$*"$'\n'; }

# Deliberately does NOT clear $LOGGED: every caller captures this as
# run="$(new_run x)", which is a subshell, so an assignment here would be
# discarded and each case would then assert against the previous case's lines.
# Clearing is the caller's job, one line above the call it is about.
new_run() { # <name> -> a fresh run dir
    local d="$TMP/$1"; mkdir -p "$d"; printf '%s\n' "$d"
}

# An extractor that always writes a CSV, so every case below differs only in what
# happens to the REPORT.
new_bin() { # <name> -> a bin dir holding a working telemetry-extract.sh
    local d="$TMP/bin-$1"; mkdir -p "$d"
    cat > "$d/telemetry-extract.sh" <<'EOF'
#!/usr/bin/env bash
out=""
while [ "$#" -gt 0 ]; do case "$1" in --out) out="$2"; shift 2 ;; *) shift ;; esac; done
printf 't,player\n5,Wsgaone\n' > "$out"
EOF
    chmod +x "$d/telemetry-extract.sh"
    printf '%s\n' "$d"
}

# --- the report ran and said something --------------------------------------

LOGGED=""; BIN="$(new_bin ok)"; RUN="$(new_run ok)"
cat > "$BIN/telemetry-report.sh" <<'EOF'
#!/usr/bin/env bash
echo "REPORT players=20 expected=20 entered=20 stuck=0"
EOF
chmod +x "$BIN/telemetry-report.sh"
telemetry_artifacts "$BIN" "$RUN" 101
assert_contains "$LOGGED" "telemetry report written to $RUN/telemetry-report.txt" \
    "a report that exits 0 is logged as written"

LOGGED=""; BIN="$(new_bin finding)"; RUN="$(new_run finding)"
cat > "$BIN/telemetry-report.sh" <<'EOF'
#!/usr/bin/env bash
echo "REPORT players=3 expected=20 entered=3 stuck=1"
exit 1
EOF
chmod +x "$BIN/telemetry-report.sh"
telemetry_artifacts "$BIN" "$RUN" 101
assert_contains "$LOGGED" "telemetry report flags a problem" \
    "a report that exits 1 is still a finding about the bots"

# --- regression: a missing report script is not a finding --------------------
#
# Only telemetry-extract.sh used to be existence-checked. With telemetry-report.sh
# absent the call failed with 127, the shell's "No such file or directory" was
# written into telemetry-report.txt where nothing distinguishes it from a report,
# and the non-zero status was narrated as "stuck bots, or fewer than 20 entered"
# -- a verdict on a match that nothing ever measured.
missing_report() { # -> a sentence naming how the absence was reported
    local run bin
    LOGGED=""; bin="$(new_bin absent)"; run="$(new_run absent)"
    telemetry_artifacts "$bin" "$run" 101
    case "$LOGGED" in
        *"stuck bots"*) printf 'a missing script was reported as a telemetry finding: %s\n' "$LOGGED"; return 0 ;;
    esac
    case "$LOGGED" in
        *"MISSING SCRIPT"*"telemetry-report.sh"*) ;;
        *) printf 'the absence was not reported as a missing script: %s\n' "$LOGGED"; return 0 ;;
    esac
    [ ! -e "$run/telemetry-report.txt" ] \
        || { printf 'it wrote a telemetry-report.txt anyway: %s\n' "$(cat "$run/telemetry-report.txt")"; return 0; }
    [ -e "$run/telemetry.csv" ] || { printf 'the extracted CSV was lost too\n'; return 0; }
    printf 'reported as a missing script, no report file, the CSV kept\n'
}
assert_eq "reported as a missing script, no report file, the CSV kept" \
  "$(missing_report)" \
  "telemetry-report.sh is existence-checked like its sibling, and its absence is not a bot finding"

# The two statuses that survive the existence check, because the file is there
# and executable and STILL does not run: 127 -- "not found", which is what the
# report itself produces if it was deleted between the check and the call -- and
# 126, a shebang naming an interpreter that is not installed (measured: bash
# returns 126, not 127, for a bad interpreter). Both are a missing script.
unrunnable_report() { # <case-name> <report-body> <expected-status>
    local run bin name="$1" body="$2" want="$3"
    LOGGED=""; bin="$(new_bin "$name")"; run="$(new_run "$name")"
    printf '%s' "$body" > "$bin/telemetry-report.sh"
    chmod +x "$bin/telemetry-report.sh"
    telemetry_artifacts "$bin" "$run" 101
    case "$LOGGED" in
        *"stuck bots"*) printf 'exit %s was reported as a telemetry finding: %s\n' "$want" "$LOGGED"; return 0 ;;
    esac
    case "$LOGGED" in
        *"MISSING SCRIPT"*"exited $want"*) ;;
        *) printf 'exit %s was not reported as a missing script: %s\n' "$want" "$LOGGED"; return 0 ;;
    esac
    [ ! -e "$run/telemetry-report.txt" ] \
        || { printf 'the shell error was left behind as a report: %s\n' "$(cat "$run/telemetry-report.txt")"; return 0; }
    printf 'reported as a missing script, and the shell error is not left behind as a report\n'
}
assert_eq "reported as a missing script, and the shell error is not left behind as a report" \
  "$(unrunnable_report notfound '#!/usr/bin/env bash
echo "telemetry-report.sh: No such file or directory" >&2
exit 127
' 127)" \
  "an exit 127 from telemetry-report.sh is reported as a missing script, not as a telemetry finding"

assert_eq "reported as a missing script, and the shell error is not left behind as a report" \
  "$(unrunnable_report badshebang '#!/nonexistent/interpreter
echo hi
' 126)" \
  "a telemetry-report.sh whose interpreter is missing is reported as a missing script too"

# --- regression: a stale bots.offset is cleared at run start -----------------
#
# logs/tournament/adhoc is shared by every ad-hoc match and nothing else removes
# this file, so a failed --mark or an aborted run leaves the PREVIOUS match's
# offset in it. Section 6b gates the capture on the file existing, so instead of
# skipping, the run captured the previous match's window and filed it under this
# one. The check below runs match-run.sh with a team that does not exist: it
# fails at validation long before anything touches docker, which is exactly what
# makes it a check that the clearing happens at run START.
stale_offset() { # -> a sentence naming what happened to the offset file
    local run rc=0
    run="$TMP/staledir"; mkdir -p "$run"
    printf '123456\nfp 4096 deadbeef\n' > "$run/bots.offset"
    bash "$ROOT/scripts/tournament/match-run.sh" no-such-team-a no-such-team-h \
        --run-dir "$run" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || { printf 'match-run.sh exited 0 on a team that does not exist\n'; return 0; }
    [ ! -e "$run/bots.offset" ] \
        || { printf 'the stale offset survived: %s\n' "$(head -1 "$run/bots.offset")"; return 0; }
    printf 'the stale offset was removed before the run got going\n'
}
assert_eq "the stale offset was removed before the run got going" \
  "$(stale_offset)" \
  "match-run.sh clears a stale bots.offset at run start, so the capture gate cannot fire on a previous match's mark"

assert_summary
