#!/usr/bin/env bash
# Task 3 staged ramp helper — run as deck in WSL
set -euo pipefail

# Two directories, two jobs — do not collapse them.
#
# ROOT is the live stack dir. It owns etc/aiplayerbot.conf (bind-mounted into
# the container, so editing it here is what the server actually reads) and
# .dbpass. It also contains an OLD docker-compose.yml for the retired
# tortoise-wow-v2 project with tw2-* containers.
#
# REPO is this checkout, and it owns the compose project this stack now runs
# under: tortoise-cm, with tcm-* containers. Running `docker compose` from ROOT
# would drive the retired project — the config edit would land correctly and
# then the restart would target containers that no longer exist, so the ramp
# would silently measure a server that never picked up the new bot count.
ROOT="${TW_STACK_ROOT:-/home/deck/tortoise-wow-server-V2}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:?usage: task3-ramp-step.sh <min/max> [apply|gates|wait]}"
MODE="${2:-apply}"  # apply | wait | gates
PASS=$(tr -d '\r\n' < "$ROOT/.dbpass")

[ -f "$ROOT/etc/aiplayerbot.conf" ] || { echo "FATAL: no aiplayerbot.conf under $ROOT/etc — set TW_STACK_ROOT" >&2; exit 1; }
[ -f "$REPO/docker-compose.yml" ]   || { echo "FATAL: no docker-compose.yml at $REPO" >&2; exit 1; }

# Every compose call goes through this, never a bare `docker compose`.
compose() { docker compose --project-directory "$REPO" "$@"; }

cd "$ROOT"

online_count() {
  docker exec -e MYSQL_PWD="$PASS" tcm-db mysql -uroot -N -B -e \
    "SELECT COUNT(*) FROM tw_char.characters c JOIN tw_logon.account a ON a.id=c.account WHERE a.username LIKE 'RNDBOT%' AND c.online=1;"
}

show_gates() {
  echo "=== WSL free ==="
  free -h
  echo "=== docker stats ==="
  docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}'
  echo "=== compose ps ==="
  compose ps
  echo "=== online RNDBOT ==="
  online_count
  echo "=== dials ==="
  grep -E '^AiPlayerbot\.(Min|Max)RandomBots|^AiPlayerbot\.DisableActivityPriorities|^AiPlayerbot\.botActiveAlone|^AiPlayerbot\.ForceActiveWhenNearPlayer|^AiPlayerbot\.RandomBotTeleportNearPlayer' \
    etc/aiplayerbot.conf || true
}

case "$MODE" in
  gates)
    show_gates
    ;;
  wait)
    THRESH="${3:-90}"
    TIMEOUT_SEC="${4:-900}"
    echo "Waiting for online RNDBOT >= $THRESH (timeout ${TIMEOUT_SEC}s)..."
    start=$(date +%s)
    while true; do
      n=$(online_count)
      now=$(date +%s)
      elapsed=$((now - start))
      echo "$(date +%H:%M:%S) online=$n elapsed=${elapsed}s"
      if [ "$n" -ge "$THRESH" ]; then
        echo "REACHED online=$n"
        show_gates
        exit 0
      fi
      if [ "$elapsed" -ge "$TIMEOUT_SEC" ]; then
        echo "TIMEOUT online=$n (wanted >= $THRESH)"
        show_gates
        exit 2
      fi
      sleep 30
    done
    ;;
  apply)
    echo "Setting Min/MaxRandomBots = $TARGET"
    sed -i "s/^AiPlayerbot.MinRandomBots = .*/AiPlayerbot.MinRandomBots = ${TARGET}/" etc/aiplayerbot.conf
    sed -i "s/^AiPlayerbot.MaxRandomBots = .*/AiPlayerbot.MaxRandomBots = ${TARGET}/" etc/aiplayerbot.conf
    grep -E '^AiPlayerbot\.(Min|Max)RandomBots|^AiPlayerbot\.DisableActivityPriorities|^AiPlayerbot\.botActiveAlone|^AiPlayerbot\.ForceActiveWhenNearPlayer|^AiPlayerbot\.RandomBotTeleportNearPlayer' \
      etc/aiplayerbot.conf
    echo "Restarting mangosd..."
    compose restart mangosd
    sleep 5
    compose ps
    ;;
  *)
    echo "unknown mode: $MODE" >&2
    exit 1
    ;;
esac
