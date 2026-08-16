# Assertion helpers for this repo's shell tests. Source, don't execute.
#
# Deliberately does NOT set -e: a failing assertion must record itself and let
# the rest of the file run, so one run reports every failure rather than the
# first one. Callers that want fail-fast can check $ASSERT_FAILED themselves.

ASSERT_PASSED=0
ASSERT_FAILED=0

_assert_ok()   { ASSERT_PASSED=$((ASSERT_PASSED + 1)); printf '  ok   %s\n' "$1"; }
_assert_bad()  { ASSERT_FAILED=$((ASSERT_FAILED + 1)); printf '  FAIL %s\n' "$1"; }

assert_eq() { # <expected> <actual> <label>
  if [ "$1" = "$2" ]; then
    _assert_ok "$3"
  else
    _assert_bad "$3"
    printf '       expected: %s\n       actual:   %s\n' "$1" "$2"
  fi
}

assert_contains() { # <haystack> <needle> <label>
  case "$1" in
    *"$2"*) _assert_ok "$3" ;;
    *)      _assert_bad "$3"
            printf '       looking for: %s\n       in:          %s\n' "$2" "$1" ;;
  esac
}

# Usage: assert_exit 2 "label" -- some command --with args
# Runs the command with errexit disabled so a non-zero code is data, not death.
assert_exit() { # <expected-code> <label> -- <command...>
  local expected="$1" label="$2"; shift 2
  [ "${1:-}" = "--" ] && shift
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  assert_eq "$expected" "$rc" "$label"
}

assert_summary() {
  printf '\n%d passed, %d failed\n' "$ASSERT_PASSED" "$ASSERT_FAILED"
  [ "$ASSERT_FAILED" -eq 0 ]
}

# Hard-fail on a missing tool. Deliberately NOT a skip: a test file that skips
# itself prints no failures, exits 0, and is indistinguishable from one that ran
# and passed -- so an automated run reports green on work it never did. If a
# dependency is genuinely optional, assert on the behaviour with and without it;
# do not make the whole file vanish.
require_cmd() { # <name>...
  local missing=""
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
  done
  if [ -n "$missing" ]; then
    printf 'FATAL: missing required tool(s):%s\n' "$missing" >&2
    printf '       install and re-run; this test did NOT pass, it could not start.\n' >&2
    exit 1
  fi
}
