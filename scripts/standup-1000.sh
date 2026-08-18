#!/usr/bin/env bash
# Stand the full stack up at N bots and prove it SETTLED there.
#
#   ./scripts/standup-1000.sh --target 1000 --out logs/standup/$(date -u +%Y%m%dT%H%M%SZ)
#
# Run it from an INTERACTIVE WSL shell. Not Git Bash (no /proc/meminfo worth
# reading, MSYS path rewriting, and the host-free gate below needs interop), and
# not a wrapped `wsl.exe -e bash -lc '...'` one-liner either — that tears down
# the backgrounded RSS sampler when the invocation returns, and every gate here
# reads the sampler's trace.
#
# Reference measurement (2026-08-15, image tortoise-cm:6bace7a):
#   1017 bots online -> 4.2682 GiB RSS, plateaued, VM available 17.62 GiB.
#   The ramp did not trip a gate until 2002 bots, and then on WINDOWS HOST free
#   memory (2.37 GiB against a 4 GiB threshold), not the VM, which still had
#   16.80 GiB. A run that watches only the VM reports a pass on a host that is
#   about to fall over — hence the host gate, and hence an unreadable host gate
#   is not a pass.
# So a result materially above ~4.3 GiB at 1000 bots is a regression worth
# chasing, not a new normal.
#
# ORDER MATTERS, and it is the point of the script: validate provenance BEFORE
# standing anything up, set the pool, start the trace and PROVE IT IS ALIVE,
# wait for the count, then SEPARATELY hold for a plateau, then gate. Reaching
# the count is not reaching a plateau — bot inventory and talent construction
# continue well past login, so RSS is still climbing when the count crosses.
#
# Exactly one STANDUP line is printed, on every exit path, and exit 0 happens
# only on PASS.
set -uo pipefail

# Read TW_IMAGE from the caller's environment before provenance.sh defaults it,
# so "was it set?" is still answerable below.
TW_IMAGE_FROM_ENV="${TW_IMAGE:-}"

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/provenance.sh
. "$HERE/lib/provenance.sh"

TARGET=1000
OUT="$ROOT/logs/standup/$(date -u +%Y%m%dT%H%M%SZ)"
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="${2:?--target requires a bot count}"; shift 2 ;;
    --out)    OUT="${2:?--out requires a directory}"; shift 2 ;;
    *) echo "usage: standup-1000.sh [--target 1000] [--out <dir>]" >&2; exit 2 ;;
  esac
done
[[ "$TARGET" =~ ^[0-9]+$ ]] || { echo "FATAL: --target must be a plain integer, got: $TARGET" >&2; exit 2; }
# Absolute from here on: nothing below cd's, but the log lines are meant to be
# pasteable and a bare "logs/standup/first" is not.
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
mkdir -p "$OUT" || { echo "FATAL: cannot create $OUT" >&2; exit 2; }

# Gates from the 2026-08-15 ramp. The host gate is the one that actually bit.
HOST_FREE_MIN_GIB=4
VM_AVAIL_MIN_GIB=2
# 4.2682 GiB was measured at 1017 bots (see the header). The ceiling allows
# headroom for a larger world and a different image, but not so much that a real
# regression passes: anything between 4.3 and 6.0 is a PASS that still wants
# explaining against that reference.
RSS_MAX_GIB=6.0

LOG="$OUT/standup.log"
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

gib() { awk -v b="${1:-0}" 'BEGIN { printf "%.4f", b / 1073741824 }'; }

# Everything the summary line reports, with a value that is honest before it has
# been measured. finish() is the ONLY place a STANDUP line is printed, so every
# exit path emits exactly one, with the same field set.
ONLINE=0
RSS_GIB=unknown
VM_AVAIL_GIB=unknown
HOST_FREE_GIB=unknown
PLATEAU=0

finish() { # <PASS|FAIL> <reason>
  printf 'STANDUP target=%s online=%s rss=%s vmAvailable=%s hostFree=%s plateau=%s verdict=%s reason=%s\n' \
    "$TARGET" "$ONLINE" "$RSS_GIB" "$VM_AVAIL_GIB" "$HOST_FREE_GIB" "$PLATEAU" "$1" "$2" \
    | tee -a "$LOG"
  [ "$1" = "PASS" ] && exit 0
  exit 1
}

# /proc/meminfo, PowerShell interop and a backgrounded sampler are all WSL-side.
# Git Bash would fail obscurely, several minutes in, after editing the live conf.
[ -z "${MSYSTEM:-}" ] || finish FAIL "run_from_wsl_not_git_bash_MSYSTEM=$MSYSTEM"

log "out dir: $OUT"

# --- 1. the image must be ours, and verified -------------------------------
#
# TW_IMAGE as the batch pass leaves it in .env is a FULL tag
# (tortoise-cm:<buildId>); provenance.sh's fallback is the bare repository name.
# Appending ":local" unconditionally would produce "tortoise-cm:abc:local".
resolve_image() {
  local v="$TW_IMAGE_FROM_ENV"
  if [ -z "$v" ] && [ -f "$ROOT/.env" ]; then
    v=$(grep -m1 -E '^[[:space:]]*TW_IMAGE[[:space:]]*=' "$ROOT/.env" 2>/dev/null \
        | cut -d= -f2- | tr -d " \"'\r") || v=""
  fi
  [ -n "$v" ] || v="tortoise-cm"
  case "$v" in
    *:*) printf '%s\n' "$v" ;;
    *)   printf '%s:local\n' "$v" ;;
  esac
}
IMAGE="$(resolve_image)"

log "verifying provenance before standing anything up (image $IMAGE)"
# Captured to a file and then read, rather than `... | tee -a | grep -q`: that
# form keeps only what grep let through in the log, and grep -q closing the pipe
# at its first match can leave the writer with SIGPIPE and hand `pipefail` a 141
# for a pipeline that actually matched (see prov_world_ready's note on the same
# trap). --keep-up because validate-stack.sh otherwise brings the stack down on
# its way out, and this script needs it up.
VALIDATE_OUT="$OUT/validate-stack.log"
"$HERE/validate-stack.sh" --image "$IMAGE" --env-file "$ROOT/.env" --keep-up \
  > "$VALIDATE_OUT" 2>&1
cat "$VALIDATE_OUT" >> "$LOG"
tail -n 20 "$VALIDATE_OUT"
if ! grep -q '^VALIDATE-STACK: PASS$' "$VALIDATE_OUT"; then
  log "FAIL: validate-stack did not report PASS — see $VALIDATE_OUT"
  finish FAIL "stack_validation_failed"
fi
log "provenance, identity and liveness OK"

# --- 2. set the pool target ------------------------------------------------
CONF="${TW_LIVE_ROOT:-$HOME/tortoise-wow-server-V2}/etc/aiplayerbot.conf"
[ -f "$CONF" ] || finish FAIL "no_aiplayerbot_conf_at_$CONF"
cp "$CONF" "$OUT/aiplayerbot.conf.before" 2>/dev/null || true
sed -i "s/^AiPlayerbot.MinRandomBots.*/AiPlayerbot.MinRandomBots = $TARGET/" "$CONF"
sed -i "s/^AiPlayerbot.MaxRandomBots.*/AiPlayerbot.MaxRandomBots = $TARGET/" "$CONF"
# Post-condition BEFORE the restart: `sed -i` exits 0 whether or not it matched,
# so a hand-reformatted conf would otherwise get a restart, a 90-minute wait and
# a measurement labelled with a bot count the server never ran. -F because those
# dots are literal dots.
grep -qxF "AiPlayerbot.MinRandomBots = $TARGET" "$CONF" \
  || finish FAIL "conf_min_random_bots_not_set_mangosd_not_restarted"
grep -qxF "AiPlayerbot.MaxRandomBots = $TARGET" "$CONF" \
  || finish FAIL "conf_max_random_bots_not_set_mangosd_not_restarted"
log "pool target set to $TARGET in $CONF; restarting mangosd to apply"
docker restart "$TW_MANGOSD" >/dev/null 2>&1 || finish FAIL "mangosd_restart_failed"

log "waiting for the world port"
deadline=$(( $(date +%s) + 600 ))
until prov_world_ready; do
  [ "$(date +%s)" -lt "$deadline" ] || finish FAIL "world_port_never_reopened_after_restart"
  sleep 5
done
log "world is up"

# --- 3. trace while it ramps ----------------------------------------------
# Written continuously to disk under --out: a ramp to 1000 is long enough that
# it will sometimes be interrupted, and a trace held in memory until the end
# would be lost entirely.
#
# rss-trace.sh takes NO command-line flags — it is configured entirely by
# TW_RSS_TRACE / TW_RSS_INTERVAL / TW_STACK_ROOT. Passing --out to it does not
# error; it is ignored, and the trace silently lands at that script's own
# default /home/deck/rss-watch.tsv instead of where this one looks for it.
export TW_RSS_TRACE="$OUT/rss-trace.tsv"
export TW_RSS_INTERVAL=30
export TW_STACK_ROOT="${TW_LIVE_ROOT:-$HOME/tortoise-wow-server-V2}"

"$HERE/rss-trace.sh" > "$OUT/rss-trace.err" 2>&1 &
TRACE_PID=$!
trap 'kill "$TRACE_PID" 2>/dev/null || true' EXIT

# Verified alive HERE, before the long wait — not after it. A process
# backgrounded inside a wrapped `wsl.exe -e bash -lc '...'` invocation is torn
# down when that invocation returns, and nohup/setsid do NOT save it (observed
# 2026-08-15). Every gate below reads this trace, so a dead sampler has to cost
# seconds, not 90 minutes.
sleep 5
if ! kill -0 "$TRACE_PID" 2>/dev/null || [ ! -s "$TW_RSS_TRACE" ]; then
  log "FAIL: rss-trace is not running, or is writing nothing to $TW_RSS_TRACE"
  log "      Run this script from an INTERACTIVE WSL shell, not a wrapped"
  log "      'wsl -e bash -lc ...' one-liner — backgrounded processes do not"
  log "      survive that invocation returning."
  if [ -s "$OUT/rss-trace.err" ]; then
    log "      rss-trace said:"
    sed 's/^/      /' "$OUT/rss-trace.err" | tee -a "$LOG"
  fi
  finish FAIL "trace_not_running"
fi
log "rss-trace running (pid $TRACE_PID) -> $TW_RSS_TRACE"

# --- 4. wait for the COUNT, then separately for the PLATEAU ----------------
# Two different things. The count crossing is the START of the measurement, not
# the end of it.
log "waiting for $TARGET bots online"
deadline=$(( $(date +%s) + 5400 ))
while :; do
  ONLINE="$(prov_online_count)"
  [[ "$ONLINE" =~ ^[0-9]+$ ]] || ONLINE=0
  log "online=$ONLINE/$TARGET"
  [ "$ONLINE" -ge "$TARGET" ] && break
  if [ "$(date +%s)" -ge "$deadline" ]; then
    log "FAIL: only $ONLINE/$TARGET online after 90 minutes"
    finish FAIL "ramp_timeout"
  fi
  sleep 60
done
log "count reached; now holding for an RSS plateau"

# rss-plateau.sh's $1 is a WINDOW SIZE IN SAMPLES, not a path — it reads the
# trace from TW_RSS_TRACE (exported above) and rejects a non-integer outright.
# 20 samples at 30 s is the 10-minute window the 2026-08-15 ramp used, with the
# same 0.25% drift criterion. Its exit status IS the verdict (0 PLATEAU,
# 1 RISING / NOT SETTLED, 2 FALLING, 3 INSUFFICIENT), so read that rather than
# grepping its prose: "VERDICT: NOT SETTLED — RSS is flat but bots are still
# logging in" is not a plateau, and a looser grep for the word would take it
# for one.
deadline=$(( $(date +%s) + 3600 ))
while :; do
  "$HERE/rss-plateau.sh" 20 > "$OUT/plateau.last" 2>&1
  rc=$?
  tee -a "$LOG" < "$OUT/plateau.last"
  if [ "$rc" -eq 0 ]; then PLATEAU=1; break; fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    log "WARN: no plateau within 60 min of reaching the count — gating on a still-moving RSS"
    break
  fi
  sleep 120
done

# --- 5. gates --------------------------------------------------------------
# The RSS column is located by READING THE TRACE'S HEADER ROW. rss-trace.sh
# writes one; a hardcoded field position would silently read the wrong column
# the day that schema gains one.
RSS_COL="$(head -1 "$TW_RSS_TRACE" | tr '\t' '\n' | grep -n '^rss_kb$' | cut -d: -f1)"
if [ -z "$RSS_COL" ]; then
  log "FAIL: no rss_kb column in $TW_RSS_TRACE"
  finish FAIL "trace_has_no_rss_column"
fi
# Last row with a non-empty rss_kb: blank cells are mangosd mid-restart or a
# docker exec hiccup, and reading one as zero would report a 0 GiB pass.
RSS_KB="$(awk -v c="$RSS_COL" -F'\t' 'NR>1 && $c ~ /^[0-9]+$/ { v = $c } END { print v }' "$TW_RSS_TRACE")"
if [[ "$RSS_KB" =~ ^[0-9]+$ ]]; then
  RSS_GIB="$(gib $(( RSS_KB * 1024 )))"
else
  log "FAIL: no usable rss_kb sample in $TW_RSS_TRACE"
  finish FAIL "no_rss_sample"
fi

ONLINE="$(prov_online_count)"
[[ "$ONLINE" =~ ^[0-9]+$ ]] || ONLINE=0

VM_AVAIL_GIB="$(awk '/^MemAvailable:/ { printf "%.2f", $2 / 1048576 }' /proc/meminfo 2>/dev/null)"
[[ "$VM_AVAIL_GIB" =~ ^[0-9]+\.[0-9]+$ ]] || VM_AVAIL_GIB=unknown

# Host free is a WINDOWS number and needs PowerShell interop; `free` inside the
# VM cannot see it. This is the gate that actually tripped at 2002 bots, so its
# absence must NOT read as a pass — an unreadable reading fails loudly rather
# than being silently skipped. `timeout` because interop stalling under host
# memory pressure is exactly the condition this gate exists to detect, so an
# unbounded call could turn "gate tripped" into "script hung" at the worst
# moment. FreePhysicalMemory is in KiB; / 1MB gives GiB.
HOST_FREE_GIB="$(timeout 20 powershell.exe -NoProfile -Command \
  '(Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB' 2>/dev/null \
  | tr -d '\r' | awk 'NF { printf "%.2f", $1; exit }')"
[[ "$HOST_FREE_GIB" =~ ^[0-9]+\.[0-9]+$ ]] || HOST_FREE_GIB=unknown

log "gates: rss=$RSS_GIB GiB (max $RSS_MAX_GIB, reference 4.2682 at 1017 bots)"
log "gates: vmAvailable=$VM_AVAIL_GIB GiB (min $VM_AVAIL_MIN_GIB)"
log "gates: hostFree=$HOST_FREE_GIB GiB (min $HOST_FREE_MIN_GIB)"
log "gates: online=$ONLINE/$TARGET, plateau=$PLATEAU"

verdict=PASS; reason="-"
# First failure wins the reason field, but every gate is still evaluated and
# logged above, so one tripped gate never hides another.
fail() { if [ "$verdict" = PASS ]; then verdict=FAIL; reason="$1"; fi; }

awk -v r="$RSS_GIB" -v m="$RSS_MAX_GIB" 'BEGIN { exit !(r > m) }' \
  && fail "rss_above_${RSS_MAX_GIB}GiB"

if [ "$VM_AVAIL_GIB" = unknown ]; then
  log "WARN: /proc/meminfo gave no MemAvailable — the VM memory gate is UNCHECKED"
  fail "vm_available_unreadable"
else
  awk -v v="$VM_AVAIL_GIB" -v m="$VM_AVAIL_MIN_GIB" 'BEGIN { exit !(v < m) }' \
    && fail "vm_available_below_${VM_AVAIL_MIN_GIB}GiB"
fi

if [ "$HOST_FREE_GIB" = unknown ]; then
  log "WARN: *** Windows host free memory could not be read (PowerShell interop) ***"
  log "WARN: *** The gate that TRIPPED at 2002 bots is UNCHECKED. That is not a  ***"
  log "WARN: *** pass: the VM showed 16.80 GiB free at the moment the host was   ***"
  log "WARN: *** down to 2.37 GiB. Re-run from an interactive WSL shell with     ***"
  log "WARN: *** interop working, or read Task Manager before trusting anything. ***"
  fail "host_free_unreadable_gate_unchecked"
else
  awk -v h="$HOST_FREE_GIB" -v m="$HOST_FREE_MIN_GIB" 'BEGIN { exit !(h < m) }' \
    && fail "host_free_below_${HOST_FREE_MIN_GIB}GiB"
fi

[ "$ONLINE" -ge "$TARGET" ] || fail "online_below_target"

finish "$verdict" "$reason"
