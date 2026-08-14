#!/usr/bin/env bash
set -euo pipefail
# Was hardcoded to logs/mangosd-cache-fix-build.log — one historical build from
# an investigation that closed months ago. Takes the log as an argument now, or
# BUILD_LOG, and otherwise picks the most recently modified *build*.log so it is
# useful against whatever build is actually running.
LOG="${1:-${BUILD_LOG:-}}"
if [[ -z "$LOG" ]]; then
  LOG=$(ls -t "${TW_STACK_ROOT:-${HOME}/tortoise-wow-server-V2}"/logs/*build*.log 2>/dev/null | head -1 || true)
fi

echo "date=$(date -Iseconds)"
if [[ -z "$LOG" || ! -f "$LOG" ]]; then
  echo "MISSING LOG: ${LOG:-<none found>}"
  echo "usage: check-build-progress.sh [path-to-build.log]   (or set BUILD_LOG)"
  exit 1
fi
echo "log=$LOG"
stat -c "mtime=%y bytes=%s" "$LOG"
echo "--- last pct ---"
grep -oE '\[[0-9]+%\]' "$LOG" | tail -5 || true
echo "--- tail ---"
tail -n 15 "$LOG"
echo "--- procs ---"
pgrep -af 'docker build' | head -5 || true
echo "cc1plus_count=$(pgrep -c cc1plus || true)"
echo "cmake_count=$(pgrep -c cmake || true)"
