#!/usr/bin/env bash
# Backup live Turtle WoW V2 configs before alive-world population changes.
set -euo pipefail

ROOT="${TW_STACK_ROOT:-${HOME}/tortoise-wow-server-V2}"
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="${ROOT}/backups/pre-alive-world-${STAMP}"

# Optional second copy on another filesystem. /mnt/d does not exist on every
# host this runs on, and `mkdir -p` failing there under `set -e` used to abort
# the whole backup — losing the primary copy too, at exactly the moment before
# configs get mutated. The mirror is a bonus; the backup is not.
WIN="${TW_BACKUP_MIRROR:-/mnt/d/TurtleWow/backups}/pre-alive-world-${STAMP}"

[ -d "$ROOT/etc" ] || { echo "FATAL: no $ROOT/etc — set TW_STACK_ROOT" >&2; exit 1; }
mkdir -p "$DEST"

MIRROR_OK=1
mkdir -p "$WIN" 2>/dev/null || { MIRROR_OK=0; echo "note: mirror unavailable ($WIN) — primary backup only" >&2; }

cp -a "${ROOT}/etc/aiplayerbot.conf" "$DEST/"
cp -a "${ROOT}/etc/aiplayerbot.conf.orig1000" "$DEST/" 2>/dev/null || true
cp -a "${ROOT}/etc/ahbot.conf" "$DEST/"
cp -a "${ROOT}/etc/mangosd.conf" "$DEST/"
cp -a "${ROOT}/etc/realmd.conf" "$DEST/"
cp -a "${ROOT}/docker-compose.yml" "$DEST/"
cp -a "${ROOT}/.env" "$DEST/" 2>/dev/null || true

{
  echo "stamp=${STAMP}"
  echo "source=${ROOT}"
  echo "host_time=$(date -Iseconds)"
  echo "---"
  grep -nE '^AiPlayerbot\.(Min|Max)RandomBots|^AiPlayerbot\.DisableActivityPriorities|^AiPlayerbot\.botActiveAlone|^AiPlayerbot\.ForceActiveWhenNearPlayer|^AiPlayerbot\.RandomBotTeleportNearPlayer|^AhBot\.(Enabled|GUID)|^LFT\.BotFill\.DelaySeconds|^PlayerHardLimit' \
    "${DEST}/aiplayerbot.conf" "${DEST}/ahbot.conf" "${DEST}/mangosd.conf" 2>/dev/null || true
  echo "---"
  ls -la "$DEST"
} | tee "${DEST}/MANIFEST.txt"

if [ "$MIRROR_OK" -eq 1 ]; then
  cp -a "${DEST}/." "$WIN/"
  echo "MIRROR_BACKUP=${WIN}"
else
  echo "MIRROR_BACKUP=(skipped — mirror path unavailable)"
fi

echo "WSL_BACKUP=${DEST}"
