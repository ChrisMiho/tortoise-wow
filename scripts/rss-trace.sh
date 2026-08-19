#!/usr/bin/env bash
# Continuous fine-grained RSS trace for mangosd. Run it in the background for
# the whole of a ramp; read it with scripts/rss-plateau.sh.
#
#   ./scripts/rss-trace.sh                    # appends to $TW_RSS_TRACE
#   TW_RSS_TRACE=/tmp/x.tsv ./scripts/rss-trace.sh
#
# WHY THIS EXISTS, when bot-ramp.sh already samples RSS:
#
# bot-ramp.sh's `wait` returns REACHED the instant the online-bot count crosses
# its threshold, and 011 is explicit that this is NOT an RSS plateau — bot
# inventory and talent construction continue well past login, so a ramp row
# taken at REACHED sits on the rising edge, flattening the fit's slope and
# inflating its intercept, with nothing in the row to reveal it. The documented
# remedy is to take samples every ~2 min until RSS stops rising and only then
# record the ramp point. That remedy needs a cheap continuous sampler and
# something that can say "stopped rising" — this file and its sibling.
#
# Deliberately NOT a second implementation of bot-ramp.sh's CSV. The artifact's
# 14-column CSV stays the record of ramp points; this is a dense trace used to
# decide WHEN to take one, and afterwards it documents the shape of the
# approach to each plateau. It skips the PowerShell interop and `docker stats`
# calls that make a full `gates` sample slow, so a 30s cadence stays cheap.
#
# NOTE on running it unattended: `nohup` and `setsid` both die here. A process
# backgrounded inside `wsl.exe -e bash -lc '...'` is torn down with the session
# when that invocation returns (observed 2026-08-15). Run it from a supervisor
# that holds the invocation open, or from an interactive WSL shell.
set -uo pipefail

OUT="${TW_RSS_TRACE:-/home/deck/rss-watch.tsv}"
ROOT="${TW_STACK_ROOT:-/home/deck/tortoise-wow-server-V2}"
INTERVAL="${TW_RSS_INTERVAL:-30}"
CONF="$ROOT/etc/aiplayerbot.conf"

[ -f "$ROOT/.dbpass" ] || { echo "FATAL: no .dbpass under $ROOT — set TW_STACK_ROOT" >&2; exit 1; }
PASS=$(tr -d '\r\n' < "$ROOT/.dbpass")

# Header once per file, so a whole night accumulates into one trace across
# restarts of this script.
[ -s "$OUT" ] || printf 'ts_utc\tconfigured\tonline\trss_kb\tvm_avail_kb\tstatus\n' > "$OUT"

# argv[0], not comm. See scripts/bot-ramp.sh mangosd_pid() for the full note:
# comm is "MainThread" because mangosd renames its main thread, and matching the
# whole cmdline hits tini at PID 1, whose argv contains "./mangosd".
find_pid() {
  docker exec tcm-mangosd sh -c '
    for f in /proc/[0-9]*/cmdline; do
      a0=$(tr "\0" "\n" < "$f" 2>/dev/null | head -n 1) || continue
      case "$a0" in
        */mangosd|mangosd) p=${f#/proc/}; printf "%s" "${p%/cmdline}"; exit 0 ;;
      esac
    done
    exit 1' 2>/dev/null
}

rss_kb() {
  docker exec -e MRSS_PID="$1" tcm-mangosd sh -c '
    while read -r k v _; do
      if [ "$k" = "VmRSS:" ]; then printf "%s" "$v"; exit 0; fi
    done < "/proc/$MRSS_PID/status"
    exit 1' 2>/dev/null
}

# Every field is best-effort and every loop iteration must survive a mangosd
# restart (it is `restart: unless-stopped` and exits 0 on AutoHonorRestart), a
# DB hiccup, or a docker exec landing mid-recreate. A blank cell in one row is
# recoverable; a sampler that exits at 3am is not.
while true; do
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  status=$(docker inspect -f '{{.State.Status}}' tcm-mangosd 2>/dev/null) || status="missing"
  pid=$(find_pid) || pid=""
  rss=""
  [ -n "$pid" ] && { rss=$(rss_kb "$pid") || rss=""; }
  online=$(docker exec -e MYSQL_PWD="$PASS" tcm-db mysql -uroot -N -B -e \
      "SELECT COUNT(*) FROM tw_char.characters c JOIN tw_logon.account a ON a.id=c.account WHERE a.username LIKE 'RNDBOT%' AND c.online=1;" \
      2>/dev/null | tr -d '\r') || online=""
  conf=$(grep -m1 -E '^AiPlayerbot\.MaxRandomBots[[:space:]]*=' "$CONF" 2>/dev/null | tr -dc '0-9') || conf=""
  avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null) || avail=""
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$ts" "$conf" "$online" "$rss" "$avail" "$status" >> "$OUT"
  sleep "$INTERVAL"
done
