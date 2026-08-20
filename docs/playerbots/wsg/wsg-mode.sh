#!/usr/bin/env bash
# Switch the world between the alive world and WSG match mode.
#
# Snapshot-based, not hardcoded: `on` records the LIVE value of every lever it is
# about to change, and `off` puts back exactly those values. "How it was" is literal.
#
# `on` refuses to run when a snapshot already exists. Without that guard a second
# `on` would snapshot match-mode values and the real world state would be gone.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/wsg-bots-common.sh"

SNAP="${WSG_SERVER_ROOT}/.wsg-mode-snapshot.json"
AICONF="${WSG_SERVER_ROOT}/etc/aiplayerbot.conf"
MGCONF="${WSG_SERVER_ROOT}/etc/mangosd.conf"

# The SHIPPED defaults, read from the source tree rather than hardcoded here.
# Only `off --profile alive-world` uses them — the fallback for when no snapshot
# exists. They were literals in THIS script, and they went stale: the pool literal
# here still read 200 and DisableActivityPriorities 0 long after the project had
# moved on. aiplayerbot.conf.dist.in:57-58 has shipped MinRandomBots =
# MaxRandomBots = 1000 all along; what changed was the compiled fallback in
# PlayerbotAIConfig.cpp:260-261, raised from 200 to 1000 to agree with it. So the
# stale literals here meant the "documented alive-world profile" quietly restored
# a world a fifth of its intended size. Reading the .dist.in means the next
# such change lands here for free. SCRIPT_DIR is docs/playerbots/wsg, so the
# repo root is three up.
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DIST_AICONF="${WSG_DIST_AICONF:-$REPO_ROOT/src/modules/PlayerBots/playerbot/aiplayerbot.conf.dist.in}"
DIST_MGCONF="${WSG_DIST_MGCONF:-$REPO_ROOT/src/mangosd/mangosd.conf.dist.in}"
BAK="tw_world.battleground_template_bak_wsg"
GM_ACCOUNT="${WSG_GM_ACCOUNT:-504}"
RESTART=1

# A key that is commented out in the conf is NOT the same as a key set to empty.
# AiPlayerbot.AutoDoQuests ships commented (compiled default true); restoring it as
# "AutoDoQuests = " would silently mean something else. Absent is recorded as this
# sentinel and restored by re-commenting.
ABSENT="<absent>"

usage() { echo "usage: $0 on|off|status [--no-restart] [--tournament] [--profile alive-world] [--force]" >&2; exit 2; }

VERB="${1:-}"; shift || true
PROFILE=""; FORCE=0; TOURNAMENT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-restart) RESTART=0; shift ;;
    --restart)    RESTART=1; shift ;;
    --profile)    PROFILE="$2"; shift 2 ;;
    --tournament) TOURNAMENT=1; shift ;;
    --force)      FORCE=1; shift ;;
    *) usage ;;
  esac
done

if [[ "$TOURNAMENT" -eq 1 && "$VERB" != "on" ]]; then
  echo "ERROR: --tournament only applies to '$0 on'." >&2
  exit 2
fi

# Random-bot pool for the match session. `on` shrinks it because bot AI is
# single-core: every random bot thinking is time the twenty bots in the match do
# not get. 40 is the WSG-match value that predates the tournament work.
#
# --tournament takes it to ZERO, which is the tournament operating decision: only
# the 20 bots playing the current match are online, plus a GM spectator. Zero is a
# legal value for this build, not a special case — UpdateAIInternal draws the
# target from urand(min,max) and then only logs bots in while
# `availableBotCount < maxAllowedBotCount`, so 0 simply never refills
# (RandomPlayerbotMgr.cpp:671-703). Nothing logs an already-online bot out for
# exceeding the target either; the only logout lever is RandomBotTimedLogout,
# which this profile pins to 0 (RandomPlayerbotMgr.cpp:2316).
#
# `rndbot add <name>` is unaffected by the pool size: AddRandomBot() checks the
# random-account list and the stale-login event and never reads min/maxRandomBots
# (RandomPlayerbotMgr.cpp:2232-2291), which is what lets roster.sh log the twenty
# tournament characters in against an empty pool. Verified live 2026-08-18 against
# tortoise-cm:20260818-5 with the pool at 0/0.
POOL_SIZE=40
[[ "$TOURNAMENT" -eq 1 ]] && POOL_SIZE=0

conf_get() { grep -E "^[[:space:]]*${2//./\\.}[[:space:]]*=" "$1" 2>/dev/null | tail -1 | sed 's/.*=[[:space:]]*//' | tr -d '\r'; }

# conf_get, but distinguishing "absent/commented" from "present but empty".
conf_get_opt() {
  if grep -qE "^[[:space:]]*${2//./\\.}[[:space:]]*=" "$1" 2>/dev/null; then
    conf_get "$1" "$2"
  else
    printf '%s' "$ABSENT"
  fi
}

# The value a key ships with, for the no-snapshot fallback. The literal is a last
# resort for when the source tree is not next to the script (this file also gets
# copied onto the server host), and for keys the .dist.in ships commented out.
dist_default() {
  local conf="$1" key="$2" fallback="$3" v=""
  [[ -r "$conf" ]] && v="$(conf_get "$conf" "$key" || true)"
  if [[ -n "$v" ]]; then printf '%s' "$v"; else printf '%s' "$fallback"; fi
}

# Restore a key to a snapshotted value, re-commenting it when it was absent.
conf_restore() {
  local conf="$1" key="$2" value="$3" kre="${2//./\\.}"
  if [[ "$value" == "$ABSENT" ]]; then
    sed -i "s|^[[:space:]]*${kre}[[:space:]]*=|# ${key} =|" "$conf"
  else
    wsg_ensure_conf_key "$conf" "$key" "$value" >/dev/null
  fi
}

case "$VERB" in
  status)
    if [[ -f "$SNAP" ]]; then echo "MODE: wsg-match (snapshot: $SNAP)"; else echo "MODE: alive-world (no snapshot)"; fi
    printf '%-40s %s\n' "AiPlayerbot.MinRandomBots"             "$(conf_get "$AICONF" AiPlayerbot.MinRandomBots)"
    printf '%-40s %s\n' "AiPlayerbot.MaxRandomBots"             "$(conf_get "$AICONF" AiPlayerbot.MaxRandomBots)"
    printf '%-40s %s\n' "AiPlayerbot.RandomBotAutoJoinBG"       "$(conf_get "$AICONF" AiPlayerbot.RandomBotAutoJoinBG)"
    printf '%-40s %s\n' "AiPlayerbot.DisableActivityPriorities" "$(conf_get "$AICONF" AiPlayerbot.DisableActivityPriorities)"
    printf '%-40s %s\n' "AiPlayerbot.RandomBotTimedLogout"      "$(conf_get "$AICONF" AiPlayerbot.RandomBotTimedLogout)"
    printf '%-40s %s\n' "AiPlayerbot.RandomBotNonCombatStrategies" "$(conf_get_opt "$AICONF" AiPlayerbot.RandomBotNonCombatStrategies)"
    printf '%-40s %s\n' "AiPlayerbot.AutoDoQuests"              "$(conf_get_opt "$AICONF" AiPlayerbot.AutoDoQuests)"
    printf '%-40s %s\n' "BattleGround.PrematureFinishTimer"     "$(conf_get "$MGCONF" BattleGround.PrematureFinishTimer)"
    wsg_check_db && wsg_mysql "SELECT id, min_level, min_players_per_team FROM tw_world.battleground_template ORDER BY id;"
    ;;

  on)
    if [[ -f "$SNAP" && "$FORCE" -eq 0 ]]; then
      echo "ERROR: mode is already ON — a snapshot exists at $SNAP." >&2
      echo "Re-snapshotting would capture match-mode values as 'how it was' and the real" >&2
      echo "world state would be unrecoverable. Run '$0 off' first, or --force if you are sure." >&2
      exit 1
    fi
    wsg_check_db || { echo "FATAL: DB unreachable" >&2; exit 1; }

    cat > "$SNAP" <<JSON
{
  "taken": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "MinRandomBots": "$(conf_get "$AICONF" AiPlayerbot.MinRandomBots)",
  "MaxRandomBots": "$(conf_get "$AICONF" AiPlayerbot.MaxRandomBots)",
  "RandomBotAutoJoinBG": "$(conf_get "$AICONF" AiPlayerbot.RandomBotAutoJoinBG)",
  "RandomBotJoinBG": "$(conf_get "$AICONF" AiPlayerbot.RandomBotJoinBG)",
  "DisableActivityPriorities": "$(conf_get "$AICONF" AiPlayerbot.DisableActivityPriorities)",
  "RandomBotTimedLogout": "$(conf_get "$AICONF" AiPlayerbot.RandomBotTimedLogout)",
  "RandomBotNonCombatStrategies": "$(conf_get_opt "$AICONF" AiPlayerbot.RandomBotNonCombatStrategies)",
  "AutoDoQuests": "$(conf_get_opt "$AICONF" AiPlayerbot.AutoDoQuests)",
  "PrematureFinishTimer": "$(conf_get "$MGCONF" BattleGround.PrematureFinishTimer)",
  "GmRank": "$(wsg_mysql "SELECT rank FROM tw_logon.account WHERE id=${GM_ACCOUNT};")"
}
JSON
    echo "snapshot written: $SNAP"

    # battleground_template is snapshotted as a whole table so every column can be
    # restored — the old wsg-only-mode.sh only ever restored min_level.
    wsg_mysql "DROP TABLE IF EXISTS ${BAK};"
    wsg_mysql "CREATE TABLE ${BAK} AS SELECT * FROM tw_world.battleground_template;"
    wsg_mysql "UPDATE tw_world.battleground_template SET min_level = 61 WHERE id <> 2;"
    wsg_mysql "UPDATE tw_world.battleground_template SET min_players_per_team = 10 WHERE id = 2;"
    wsg_mysql "UPDATE tw_logon.account SET rank=4 WHERE id=${GM_ACCOUNT};"

    wsg_ensure_conf_key "$AICONF" AiPlayerbot.MinRandomBots "$POOL_SIZE" >/dev/null
    wsg_ensure_conf_key "$AICONF" AiPlayerbot.MaxRandomBots "$POOL_SIZE" >/dev/null
    wsg_ensure_conf_key "$AICONF" AiPlayerbot.RandomBotJoinBG 1 >/dev/null
    wsg_ensure_conf_key "$AICONF" AiPlayerbot.RandomBotAutoJoinBG 0 >/dev/null
    wsg_ensure_conf_key "$AICONF" AiPlayerbot.DisableActivityPriorities 1 >/dev/null
    wsg_ensure_conf_key "$AICONF" AiPlayerbot.RandomBotTimedLogout 0 >/dev/null
    wsg_ensure_conf_key "$MGCONF" BattleGround.PrematureFinishTimer 0 >/dev/null

    # Settle the roster. Bots are not idle between matches — they grind, quest and
    # cross continents, and isUseful() gates on IsInCombat(), so a busy bot silently
    # cannot be queued. AiFactory applies this string AFTER adding grind/travel/rpg,
    # so a '-' prefix removes them. Measured: one priest went from 0/15 commanded
    # joins to queueing in the same second as everyone else.
    # This does not touch in-BG behaviour — AiFactory:1099 strips the same strategies
    # on BG entry anyway and adds "battleground" and "warsong" in their place.
    wsg_ensure_conf_key "$AICONF" AiPlayerbot.RandomBotNonCombatStrategies \
      "-grind,-travel,-rpg,-wander,-tfish,+custom::say" >/dev/null
    wsg_ensure_conf_key "$AICONF" AiPlayerbot.AutoDoQuests 0 >/dev/null

    if [[ "$TOURNAMENT" -eq 1 ]]; then
      echo "WSG match mode ON (tournament profile: random pool 0/0 — nothing but the roster comes online)."
    else
      echo "WSG match mode ON (random pool ${POOL_SIZE}/${POOL_SIZE})."
    fi
    echo "Recommended before large world-DB changes: Backup-TurtleDatabase -IncludeWorld"
    if [[ "$RESTART" -eq 1 ]]; then
      docker restart tcm-mangosd
      wsg_wait_world_ready || exit 1
      # --tournament skips the WSG demo roster on purpose. Those characters are not
      # the tournament roster — scripts/tournament/roster.sh owns that — and every
      # one of them online is a character match-run.sh's population gate will count
      # and refuse to start on.
      if [[ "$TOURNAMENT" -eq 1 ]]; then
        echo "tournament profile: skipping wsg-roster.sh (roster.sh owns the tournament roster)"
      elif [[ "${WSG_SKIP_ROSTER:-0}" != "1" ]]; then
        bash "$SCRIPT_DIR/wsg-roster.sh" ensure
        # Park the roster in towns. rndbot rpg targets race-appropriate RPG
        # locations rather than the mob grind spots that `teleport`/`grind` pick,
        # and it puts travel on a 10-minute cooldown. WSG does not heal on entry,
        # so a bot mauled while parked in Winterspring would be ported in hurt.
        wsg_load_roster "$SCRIPT_DIR/wsg-team-roster.txt"
        wsg_console "$(printf 'rndbot rpg %s\n' "${WSG_NAMES[@]}")" 20 >/dev/null
      fi
    else
      echo "ACTION REQUIRED: docker restart tcm-mangosd   (battleground_template is read at boot)"
      [[ "$TOURNAMENT" -eq 1 ]] || echo "Then: wsg-roster.sh ensure"
    fi
    ;;

  off)
    if [[ ! -f "$SNAP" ]]; then
      if [[ "$PROFILE" != "alive-world" ]]; then
        echo "mode is already off (no snapshot at $SNAP)"
        exit 0
      fi
      echo "no snapshot — applying the shipped alive-world profile"
      MinRandomBots="$(dist_default "$DIST_AICONF" AiPlayerbot.MinRandomBots 1000)"
      MaxRandomBots="$(dist_default "$DIST_AICONF" AiPlayerbot.MaxRandomBots 1000)"
      RandomBotAutoJoinBG="$(dist_default "$DIST_AICONF" AiPlayerbot.RandomBotAutoJoinBG 0)"
      RandomBotJoinBG="$(dist_default "$DIST_AICONF" AiPlayerbot.RandomBotJoinBG 1)"
      DisableActivityPriorities="$(dist_default "$DIST_AICONF" AiPlayerbot.DisableActivityPriorities 1)"
      # Ships commented out; the literal is the compiled default
      # (PlayerbotAIConfig.cpp:254 GetBoolDefault "...RandomBotTimedLogout", true).
      RandomBotTimedLogout="$(dist_default "$DIST_AICONF" AiPlayerbot.RandomBotTimedLogout 1)"
      RandomBotNonCombatStrategies="$(dist_default "$DIST_AICONF" \
        AiPlayerbot.RandomBotNonCombatStrategies "+grind,+loot,+custom::say,+tfish,+wander,+rpg craft")"
      PrematureFinishTimer="$(dist_default "$DIST_MGCONF" BattleGround.PrematureFinishTimer 300000)"
      # Ships commented out; ABSENT re-comments it, restoring the compiled default.
      AutoDoQuests="$ABSENT"
      # Not a conf key — tw_logon.account.rank. 3 = DEVELOPER, the everyday value.
      GmRank=3
      # Say which of the two sources the numbers actually came from. dist_default
      # silently falls back to its literal when the source tree is not next to
      # the script — the copied-to-the-server-host case these literals exist
      # for — and naming the .dist.in there claims a read that never happened.
      if [[ -n "$(conf_get "$DIST_AICONF" AiPlayerbot.MinRandomBots)" ]]; then
        POOL_SRC="read from ${DIST_AICONF}"
      else
        POOL_SRC="compiled-in literal; no value in ${DIST_AICONF}"
      fi
      echo "  pool ${MinRandomBots}/${MaxRandomBots} (${POOL_SRC})"
    else
      get() { grep -o "\"$1\": *\"[^\"]*\"" "$SNAP" | sed 's/.*: *"//; s/"$//'; }
      MinRandomBots="$(get MinRandomBots)";           MaxRandomBots="$(get MaxRandomBots)"
      RandomBotAutoJoinBG="$(get RandomBotAutoJoinBG)"; RandomBotJoinBG="$(get RandomBotJoinBG)"
      DisableActivityPriorities="$(get DisableActivityPriorities)"
      RandomBotTimedLogout="$(get RandomBotTimedLogout)"
      RandomBotNonCombatStrategies="$(get RandomBotNonCombatStrategies)"
      AutoDoQuests="$(get AutoDoQuests)"
      PrematureFinishTimer="$(get PrematureFinishTimer)"; GmRank="$(get GmRank)"
    fi
    wsg_check_db || { echo "FATAL: DB unreachable" >&2; exit 1; }

    # Log the roster out; never delete the characters.
    if [[ "${WSG_SKIP_ROSTER:-0}" != "1" ]]; then
      wsg_load_roster "$SCRIPT_DIR/wsg-team-roster.txt"
      wsg_console "$(printf 'rndbot remove %s\n' "${WSG_NAMES[@]}")" 15 >/dev/null || true
    fi

    if [[ "$(wsg_mysql "SHOW TABLES IN tw_world LIKE 'battleground_template_bak_wsg';")" == "battleground_template_bak_wsg" ]]; then
      wsg_mysql "UPDATE tw_world.battleground_template t JOIN ${BAK} b ON t.id=b.id SET t.min_level=b.min_level, t.min_players_per_team=b.min_players_per_team, t.max_players_per_team=b.max_players_per_team;"
    else
      echo "WARNING: ${BAK} missing — battleground_template left as-is" >&2
    fi

    conf_restore "$AICONF" AiPlayerbot.MinRandomBots "$MinRandomBots"
    conf_restore "$AICONF" AiPlayerbot.MaxRandomBots "$MaxRandomBots"
    conf_restore "$AICONF" AiPlayerbot.RandomBotJoinBG "$RandomBotJoinBG"
    conf_restore "$AICONF" AiPlayerbot.RandomBotAutoJoinBG "$RandomBotAutoJoinBG"
    conf_restore "$AICONF" AiPlayerbot.DisableActivityPriorities "$DisableActivityPriorities"
    conf_restore "$AICONF" AiPlayerbot.RandomBotTimedLogout "$RandomBotTimedLogout"
    conf_restore "$AICONF" AiPlayerbot.RandomBotNonCombatStrategies "$RandomBotNonCombatStrategies"
    conf_restore "$AICONF" AiPlayerbot.AutoDoQuests "$AutoDoQuests"
    conf_restore "$MGCONF" BattleGround.PrematureFinishTimer "$PrematureFinishTimer"
    wsg_mysql "UPDATE tw_logon.account SET rank=${GmRank} WHERE id=${GM_ACCOUNT};"

    # Archive rather than delete, so a mistaken `off` is still recoverable.
    [[ -f "$SNAP" ]] && mv "$SNAP" "${SNAP%.json}.$(date -u +%Y%m%dT%H%M%SZ).json"

    echo "Alive world restored. The pool climbs back to ${MaxRandomBots} over ~20 minutes."
    if [[ "$RESTART" -eq 1 ]]; then docker restart tcm-mangosd
    else echo "ACTION REQUIRED: docker restart tcm-mangosd"; fi
    ;;

  *) usage ;;
esac
