#!/usr/bin/env bash
# Self-test for the assertion helpers. If this fails, no other test can be trusted.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/assert.sh"
. "$HERE/stub.sh"

assert_eq "abc" "abc" "assert_eq matches"
assert_contains "hello world" "lo wo" "assert_contains finds a substring"
assert_exit 3 "assert_exit reads an exit code" -- bash -c 'exit 3'

d="$(stub_dir)"
stub_cmd "$d" faketool 'echo STUBBED; exit 0'
assert_eq "STUBBED" "$(faketool)" "stub_cmd shadows PATH"
assert_exit 0 "stub survives a second call" -- faketool
stub_cleanup "$d"

assert_summary
