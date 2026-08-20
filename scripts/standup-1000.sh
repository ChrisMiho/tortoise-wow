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
# standing anything up, set the pool, start the trace and PROVE IT IS ALIVE —
# and KEEP proving it, on every pass of both waits, because everything after
# this reads the trace's tail and a frozen tail reads as a plateau — wait for
# the count, then SEPARATELY hold for a plateau, then gate. Reaching the count
# is not reaching a plateau — bot inventory and talent construction continue
# well past login, so RSS is still climbing when the count crosses.
#
# Exactly one STANDUP line is printed, on every exit path, and exit 0 happens
# only on PASS. Reaching the count without a plateau is NOT a pass either — an
# RSS that is still climbing has not been measured, it has been sampled mid-ramp.
#
# The live aiplayerbot.conf is HOST-GLOBAL shared state: this script rewrites the
# pool target in it and restarts the world. So it takes an flock for the whole
# run (a second invocation refuses rather than racing), and it restores the conf
# from its backup on EVERY exit path, including the failing ones — leaving the
# host pinned at 1000 bots after a failed run is how the next unrelated stand-up
# gets measured against a pool it never asked for.
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

# --- 0. one run at a time --------------------------------------------------
# The contended resource is not $OUT (every run has its own) — it is the single
# live aiplayerbot.conf below and the single mangosd that reads it. Two runs
# interleaving `sed -i` and `docker restart` produce a server running one target
# while the other run waits for a different one, and whichever finishes first
# restores the conf out from under the one still measuring.
#
# flock, not a pidfile: the kernel drops it when the holder exits, however it
# exits, so a crashed run leaves nothing stale behind. The pid line is for the
# refusal message only — nothing decides anything from it.
LIVE_ROOT="${TW_LIVE_ROOT:-$HOME/tortoise-wow-server-V2}"
LOCK_FILE="$LIVE_ROOT/.standup-1000.lock"
command -v flock >/dev/null 2>&1 || finish FAIL "flock_not_installed_run_from_wsl"
# Opened append, not truncating: > would wipe the current holder's pid line out
# from under it, since the fd is opened before the lock is taken.
exec 9>>"$LOCK_FILE" || finish FAIL "cannot_open_lock_$LOCK_FILE"
if ! flock -n 9; then
  holder="$(head -1 "$LOCK_FILE" 2>/dev/null)"
  log "FAIL: another standup-1000.sh already holds $LOCK_FILE (${holder:-holder unknown})"
  log "      It is editing the live aiplayerbot.conf and restarting mangosd."
  log "      Wait for it, or stop it — two runs cannot share one world."
  finish FAIL "another_standup_running"
fi
printf 'pid %s started %s out %s
' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$OUT" >&9
log "lock held: $LOCK_FILE (pid $$)"

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
CONF="$LIVE_ROOT/etc/aiplayerbot.conf"
[ -f "$CONF" ] || finish FAIL "no_aiplayerbot_conf_at_$CONF"
CONF_BACKUP="$OUT/aiplayerbot.conf.before"
# Hard-fail, not `|| true`: without a readable backup there is nothing to
# restore, and the old form would have gone on to edit the conf anyway.
cp "$CONF" "$CONF_BACKUP" || finish FAIL "cannot_back_up_$CONF"

# Installed BEFORE the first `sed -i`, so there is no window in which the conf is
# modified and no trap would put it back. finish() exits, so this fires on every
# gate failure too, and the shell's own EXIT covers a kill or a set -e death.
#
# The conf is restored on disk; mangosd keeps the target it was restarted with
# until something restarts it again. That is deliberate — restarting the world
# from an exit trap would drop every session of a run that failed for an
# unrelated reason. The next restart reads the restored file.
CONF_RESTORED=0
restore_conf() {
  [ "$CONF_RESTORED" = 0 ] || return 0
  [ -n "${CONF_BACKUP:-}" ] && [ -f "$CONF_BACKUP" ] || return 0
  CONF_RESTORED=1
  if cp "$CONF_BACKUP" "$CONF"; then
    log "restored $CONF from $CONF_BACKUP (mangosd keeps target=$TARGET until its next restart)"
  else
    log "WARN: *** could not restore $CONF from $CONF_BACKUP — the live pool  ***"
    log "WARN: *** target is STILL PINNED at $TARGET. Put it back by hand.    ***"
  fi
}
cleanup() {
  [ -n "${TRACE_PID:-}" ] && kill "$TRACE_PID" 2>/dev/null
  restore_conf
  return 0
}
trap cleanup EXIT

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
export TW_STACK_ROOT="$LIVE_ROOT"

# 9>&- so the sampler does not inherit the run lock: if this script dies the
# kernel must free the lock at once, not once an orphaned sampler notices.
# The EXIT trap installed above kills it and restores the conf.
"$HERE/rss-trace.sh" > "$OUT/rss-trace.err" 2>&1 9>&- &
TRACE_PID=$!

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

# ...and re-verified on every pass of both long waits below. The check above
# only proves the sampler STARTED. Nothing downstream knows how old the trace
# is: rss-plateau.sh reads a window of the tail with no recency test, so a
# sampler that dies mid-ramp leaves 20 identical rows, which read as 0% drift —
# a PLATEAU — and the gate then measures a stale rss_kb from minutes or hours
# earlier. That is a silent PASS off dead data, and the likeliest thing to kill
# the sampler is the very memory pressure this run exists to detect.
#
# Two failure modes, so two checks: the sampler exiting (kill -0), and the
# sampler alive but wedged in a docker exec that never returns, which leaves the
# trace just as frozen (file mtime). The staleness ceiling is 10 sampling
# intervals with a 300 s floor — loose enough that a slow docker exec under load
# is not mistaken for death, tight enough that it costs one loop iteration
# rather than the remaining 90 minutes.
TRACE_STALE_S=$(( TW_RSS_INTERVAL * 10 ))
[ "$TRACE_STALE_S" -ge 300 ] || TRACE_STALE_S=300

# Echoes a reason and returns 0 when the sampler can no longer be trusted.
trace_dead_reason() {
  local mtime now age
  if ! kill -0 "$TRACE_PID" 2>/dev/null; then
    echo "trace_sampler_died"; return 0
  fi
  mtime="$(stat -c %Y "$TW_RSS_TRACE" 2>/dev/null)" || mtime=""
  if ! [[ "$mtime" =~ ^[0-9]+$ ]]; then
    echo "trace_file_unreadable"; return 0
  fi
  now="$(date +%s)"
  age=$(( now - mtime ))
  if [ "$age" -gt "$TRACE_STALE_S" ]; then
    echo "trace_stale_${age}s"; return 0
  fi
  return 1
}

check_trace() {
  local why
  if why="$(trace_dead_reason)"; then
    log "FAIL: the RSS sampler has stopped producing samples ($why)"
    log "      Every gate below reads the tail of $TW_RSS_TRACE. A frozen tail"
    log "      reads as a plateau and would gate on a stale RSS, so this fails"
    log "      here rather than passing on data of unknown age."
    if [ -s "$OUT/rss-trace.err" ]; then
      log "      rss-trace said:"
      sed 's/^/      /' "$OUT/rss-trace.err" | tee -a "$LOG"
    fi
    finish FAIL "$why"
  fi
}

# --- 4. wait for the COUNT, then separately for the PLATEAU ----------------
# Two different things. The count crossing is the START of the measurement, not
# the end of it.
log "waiting for $TARGET bots online"
deadline=$(( $(date +%s) + 5400 ))
while :; do
  check_trace
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
  # Before rss-plateau.sh runs, not after: its verdict is only as trustworthy as
  # the freshness of the rows it is about to read.
  check_trace
  "$HERE/rss-plateau.sh" 20 > "$OUT/plateau.last" 2>&1
  rc=$?
  tee -a "$LOG" < "$OUT/plateau.last"
  if [ "$rc" -eq 0 ]; then PLATEAU=1; break; fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    log "FAIL: no plateau within 60 min of reaching the count — RSS is still moving"
    log "      Reaching $TARGET bots is not the measurement; settling there is."
    log "      An RSS sampled mid-climb is a lower bound, not a result, so this"
    log "      is reported as a failure rather than gated as if it had settled."
    break
  fi
  sleep 120
done

# --- 5. gates --------------------------------------------------------------
# Once more before anything is measured. Both loops above can leave by a path
# that does not re-check (the count crossing, the 60-minute plateau timeout),
# and the number this run is judged on is read from the trace right here.
check_trace

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

# plateau=0 means every number above was read off a still-climbing RSS. It is a
# gate, not a warning: the whole premise of this script is that reaching the
# count is not proof the stack settled, so a run that never settled cannot pass.
[ "$PLATEAU" = 1 ] || fail "no_plateau_rss_still_climbing"

finish "$verdict" "$reason"
