#!/usr/bin/env bash
# Backup live Turtle WoW V2 configs before alive-world population changes.
#
# CONFIG FILES ONLY -- this does NOT back up the databases.
#
# The name reads like protection before a risky operation, and it is not: this
# copies etc/*.conf, docker-compose.yml and .env, and never touches tw_char,
# tw_logon or tw_world. It is no defence whatever against
# `docker compose down -v`, which destroys the tortoise-wow-v2_dbdata volume and
# with it every character on the server. That volume has been lost once already.
#
# Before anything that could touch the volume -- an unattended agent with docker
# access, a compose change, a disk operation -- dump the irreplaceable databases
# as well:
#
#   . docs/playerbots/wsg/lib/wsg-bots-common.sh
#   docker exec -e MYSQL_PWD="$(wsg_db_pass)" tcm-db \
#     mysqldump -uroot --single-transaction --databases tw_char tw_logon \
#     > ~/tortoise-wow-server-V2/backups/pre-drain-$(date +%Y%m%d-%H%M%S).sql
#
# tw_char (characters) and tw_logon (accounts) are irreplaceable. tw_world is
# reconstructible from sql/base/ in this repo, so it can be skipped if the dump
# is unwieldy.
set -euo pipefail

ROOT="${HOME}/tortoise-wow-server-V2"
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="${ROOT}/backups/pre-alive-world-${STAMP}"
WIN="/mnt/d/TurtleWow/backups/pre-alive-world-${STAMP}"

mkdir -p "$DEST" "$WIN"

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

cp -a "${DEST}/." "$WIN/"

echo "WSL_BACKUP=${DEST}"
echo "WIN_BACKUP=D:/TurtleWow/backups/pre-alive-world-${STAMP}"
