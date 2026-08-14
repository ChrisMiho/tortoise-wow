#!/usr/bin/env bash
#
# playerbot-verify.sh — read-only health check for the Turtle WoW V2 playerbot stack.
#
# Run from Windows:  MSYS_NO_PATHCONV=1 wsl -d Ubuntu -u deck -- bash /mnt/c/Coding/tortoise-wow/tortoise-wow/tests/playerbot-verify.sh [player-name]
# Run inside WSL:    bash /mnt/c/Coding/tortoise-wow/tortoise-wow/tests/playerbot-verify.sh [player-name]
#
# Everything here is SELECT-only plus log reads. It never writes to the DB and never
# restarts a container.
#
# Sections:
#   1. stack     — containers, mangosd uptime
#   2. config    — the aiplayerbot.conf keys that gate bot login
#   3. orphans   — characters stuck in the "created mid-session" failure mode
#   4. spam      — growth rate of bots.log (a proxy for the retry loop firing)
#   5. picks     — online random bots you can actually invite right now
#   6. alive     — activity/teleport dials + online RNDBOT + LFT fill
#   7. memory    — WSL free + docker stats snapshot
#   8. invites   — AcceptInvitationAction events this session
#
set -uo pipefail

PLAYER="${1:-Usagi}"
ROOT="$HOME/tortoise-wow-server-V2"
LOGS="$ROOT/logs"
PASS=$(tr -d '\r\n' < "$ROOT/.dbpass")

q() { docker exec -e MYSQL_PWD="$PASS" tcm-db mysql -uroot -N -B -e "$1" 2>&1 | grep -v '^mysql:' | tr -d '\r'; }
hdr() { printf '\n\033[1m=== %s ===\033[0m\n' "$1"; }

hdr "1. stack"
docker ps --format '{{.Names}}\t{{.Status}}' | grep '^tcm-' || echo "NO tcm-* CONTAINERS RUNNING"
printf 'mangosd started: %s\n' "$(docker inspect -f '{{.State.StartedAt}}' tcm-mangosd 2>/dev/null)"
printf 'now:             %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

hdr "2. config gates"
grep -inE '^[^#]*(AiPlayerbot\.Enabled|RandomBotAutologin|^[^#]*BotAutologin|RandomBotAccountCount|RandomBotAccountPrefix|MinRandomBots|MaxRandomBots|LevelCheck|GearScoreCheck)' \
  "$ROOT/etc/aiplayerbot.conf"
echo "(BotAutologin 0=DISABLED 1=LOGIN_ALL_WITH_MASTER 2=LOGIN_ONLY_ALWAYS_ACTIVE)"

hdr "3. orphaned bots (created mid-session, absent from the player cache)"
# The signature: AddPlayerBot cannot resolve an account for the guid, so the bot
# never logs in and the freeAltBots entry is never retired -> infinite retry.
ORPHANS=$(grep -oE 'AddPlayerBot: no account for guid [0-9]+' "$LOGS/bots.log" 2>/dev/null \
          | awk '{print $NF}' | sort -un | tr '\n' ',' | sed 's/,$//')
if [ -z "$ORPHANS" ]; then
  echo "none — no 'no account for guid' errors in bots.log"
else
  echo "guids stuck in the retry loop: $ORPHANS"
  q "SELECT c.guid, c.name, c.level, c.online, a.username
     FROM tw_char.characters c JOIN tw_logon.account a ON a.id=c.account
     WHERE c.guid IN ($ORPHANS);"
  echo "retry-loop error count: $(grep -c 'no account for guid' "$LOGS/bots.log")"
fi

hdr "4. bots.log growth (retry-loop cost)"
S1=$(stat -c %s "$LOGS/bots.log"); sleep 5; S2=$(stat -c %s "$LOGS/bots.log")
awk -v a="$S1" -v b="$S2" 'BEGIN{
  r=(b-a)/5;
  printf "size: %.1f MB   rate: %.0f KB/s (~%.0f MB/hour)\n", b/1048576, r/1024, r*3600/1048576;
}'
df -h "$HOME" | tail -1

hdr "5. invitable bots near $PLAYER"
# A bot accepts a player's /invite only when PlayerbotSecurity::LevelFor returns
# PLAYERBOT_SECURITY_INVITE (3): it must be ungrouped or its group's leader, and
# botLevel - playerLevel must be <= AiPlayerbot.LevelCheck.
q "SELECT b.name, b.level,
      CASE b.class WHEN 1 THEN 'Warrior' WHEN 2 THEN 'Paladin' WHEN 3 THEN 'Hunter'
                   WHEN 4 THEN 'Rogue'   WHEN 5 THEN 'Priest'  WHEN 7 THEN 'Shaman'
                   WHEN 8 THEN 'Mage'    WHEN 9 THEN 'Warlock' WHEN 11 THEN 'Druid'
                   ELSE CONCAT('cls',b.class) END AS class_name,
      ROUND(SQRT(POW(b.position_x-u.position_x,2)+POW(b.position_y-u.position_y,2))) AS dist_yd,
      CASE WHEN gm.memberGuid IS NULL THEN 'ungrouped'
           WHEN g.leaderGuid = b.guid THEN 'leader' ELSE 'in-group' END AS grp
   FROM tw_char.characters b
   JOIN tw_char.characters u ON u.name='${PLAYER}'
   JOIN tw_logon.account a ON a.id=b.account
   LEFT JOIN tw_char.group_member gm ON gm.memberGuid=b.guid
   LEFT JOIN tw_char.\`groups\` g ON g.groupId=gm.groupId
   WHERE b.online=1 AND a.username LIKE 'RNDBOT%' AND b.map=u.map
   HAVING grp IN ('ungrouped','leader')
   ORDER BY dist_yd ASC LIMIT 15;"

hdr "6. alive dials"
grep -E '^AiPlayerbot\.(Min|Max)RandomBots|^AiPlayerbot\.DisableActivityPriorities|^AiPlayerbot\.botActiveAlone|^AiPlayerbot\.ForceActiveWhenNearPlayer|^AiPlayerbot\.RandomBotTeleportNearPlayer' \
  "$ROOT/etc/aiplayerbot.conf" || true
ONLINE=$(q "SELECT COUNT(*) FROM tw_char.characters c JOIN tw_logon.account a ON a.id=c.account WHERE a.username LIKE 'RNDBOT%' AND c.online=1;")
echo "online RNDBOT: $ONLINE"
grep -E '^LFT\.BotFill\.' "$ROOT/etc/mangosd.conf" || true

hdr "7. memory snapshot"
free -h
docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}' | grep -E 'NAME|tcm-' || true

hdr "8. invite-accept events so far this session"
grep -c 'AcceptInvitationAction' "$LOGS/bot_events.csv" 2>/dev/null || echo 0
grep 'AcceptInvitationAction' "$LOGS/bot_events.csv" 2>/dev/null | tail -5
