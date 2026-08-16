#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/validate-stack.sh"
. "$HERE/lib/assert.sh"
. "$HERE/lib/stub.sh"

run_with_stub() { # <docker-body>  -> prints combined output, sets RC
  local d body="$1"; shift
  d="$(stub_dir)"
  stub_cmd "$d" docker "$body"
  stub_cmd "$d" nc 'exit 0'
  local envfile="$d/.env"; printf 'DB_PASS=x\n' > "$envfile"
  OUT="$(TW_LIVE_ROOT="$d" bash "$SCRIPT" --image tortoise-cm:test --env-file "$envfile" 2>&1)"
  RC=$?
  stub_cleanup "$d"
}

# A missing docker daemon is UNKNOWN (2), never a silent pass.
run_with_stub 'if [ "$1" = "info" ]; then exit 1; fi; exit 0'
assert_eq "2" "$RC" "docker down exits 2"
assert_contains "$OUT" "VALIDATE-STACK: FAIL" "docker down reports FAIL"

# An image with no provenance labels is UNKNOWN, not a pass.
run_with_stub '
case "$1 $2" in
  "info "*)            exit 0 ;;
  "image inspect")     case "$*" in *Id*) echo "sha256:same";; *) echo "";; esac; exit 0 ;;
  "compose "*)         exit 0 ;;
  "inspect "*)         echo "sha256:same"; exit 0 ;;
esac
exit 0'
assert_eq "2" "$RC" "unlabelled image exits 2"
assert_contains "$OUT" "no provenance labels" "unlabelled image says why"

assert_summary
