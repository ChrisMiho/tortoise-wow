#!/usr/bin/env bash
# Is this team actually dressed? Read-only: one SELECT, nothing written, no
# console, no server image needed.
#
#   ./scripts/tournament/gear-audit.sh stormwind-sentinels
#
#   Wsgaone filled=6/13 missing=head,shoulders,chest,waist,legs,feet,wrists
#   Wsgafour filled=13/13
#   ...
#   GEAR-AUDIT stormwind-sentinels complete=4/10 worstMissing=8
#
# Exit 0 = every bot has every required slot filled. Exit 1 = at least one gap,
# so this drops into a match runner as a gate. Exit 2 = the audit could not run
# at all (bad team file, no jq/docker, database unreachable) -- deliberately a
# third code, because "could not measure" is not "measured and found nothing",
# the same distinction team-validate.sh draws.
#
# WHY THIS EXISTS. `rndbot create ... gear=blue` runs InitEquipment(false,false),
# which destroys every equipped item before picking replacements
# (PlayerbotFactory.cpp:2999-3003) and leaves any slot it cannot fill empty. It
# also equips nothing at all below level 5 (PlayerbotFactory.cpp:2974-2980) or
# when specId == 0 (PlayerbotFactory.cpp:2988-2994). Nothing reports any of
# that, so a half-dressed bot looks exactly like a success and a match between a
# dressed team and a stripped one is rigged with no one the wiser. This script
# does not fix that -- it makes it visible and countable.
#
# Run from WSL: jq is not on Git Bash's PATH on this host.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/team.sh
. "$HERE/lib/team.sh"

CHAR_DB="${CHAR_DB:-tw_char}"
DB_CONTAINER="${DB_CONTAINER:-tcm-db}"

# The slots a bot must have filled to count as dressed, with the names printed
# in missing=. Ids are EQUIPMENT_SLOT_* from src/game/Objects/Player.h:590-610.
#
# The six absentees are absent on purpose, and none of them may ever be reported
# as missing: body(3) and tabard(18) are cosmetic, finger2(11) and trinket2(13)
# are optional duplicates of slots already required, offhand(16) is legitimately
# empty for every two-handed spec and ranged(17) for several others. Counting any
# of those would make a correctly geared warrior look broken, and a gate that
# cries wolf gets switched off.
GEAR_SLOT_IDS=(0 1 2 4 5 6 7 8 9 10 12 14 15)
GEAR_SLOT_NAMES=(head neck shoulders chest waist legs feet wrists hands finger1 trinket1 back mainhand)
GEAR_REQUIRED=${#GEAR_SLOT_IDS[@]}

usage() {
    echo "usage: $(basename "$0") <team-id>" >&2
    echo "       audits one team's equipped gear; read-only" >&2
}

# Deliberately NOT wsg_mysql from docs/playerbots/wsg/lib/wsg-bots-common.sh:
# that helper sends mysql's stderr to /dev/null, so a query that fails returns an
# empty string and reads exactly like "every bot is naked". An audit whose
# failure mode is a maximally alarming false positive is worse than no audit, so
# here stderr reaches the operator and the exit status is checked.
gear_query() { # <sql> -> tab-separated rows on stdout, non-zero if mysql failed
    local sql="$1" pass
    pass="$(docker exec "$DB_CONTAINER" printenv MARIADB_ROOT_PASSWORD 2>/dev/null | tr -d '\r\n')"
    docker exec -e MYSQL_PWD="$pass" "$DB_CONTAINER" \
        mysql -uroot -N -B -e "$sql" | tr -d '\r'
}

team="${1:-}"
[ -n "$team" ] || { usage; exit 2; }
[ "$#" -eq 1 ] || { usage; exit 2; }

command -v jq >/dev/null 2>&1 || {
    echo "FATAL: jq is not installed (apt-get install jq)" >&2; exit 2; }
command -v docker >/dev/null 2>&1 || {
    echo "FATAL: docker is not on PATH" >&2; exit 2; }

# Refuse rather than measure a team we cannot trust. A roster with a duplicate
# slot or an over-long name describes characters that do not exist or never came
# online, and every one of those would be counted as naked -- an audit failure
# indistinguishable from a gear failure.
team_validate "$team" || {
    echo "FATAL: $team does not validate; refusing to audit it" >&2; exit 2; }

names=()
while IFS= read -r n; do names+=("$n"); done < <(team_names "$team")
[ "${#names[@]}" -gt 0 ] || { echo "FATAL: $team has no roster" >&2; exit 2; }

# ONE query for the whole team. Ten round trips to the database would be ten
# chances to half-fail, and a partial answer here is worse than none.
#
# The nested join is the point of it: LEFT JOIN off characters so a bot with no
# character row at all still comes back (as no slots) instead of vanishing from
# the report, but INNER JOIN character_inventory to item_instance inside that,
# so an inventory row whose item instance is gone counts as an empty slot rather
# than a filled one. Names are safe to interpolate -- team_validate above proved
# every one of them is alphabetic.
in_list=""
for n in "${names[@]}"; do in_list="${in_list:+$in_list,}'$n'"; done
slot_list="$(IFS=,; echo "${GEAR_SLOT_IDS[*]}")"

sql="SELECT c.name, IFNULL(GROUP_CONCAT(DISTINCT ci.slot ORDER BY ci.slot),'')
     FROM ${CHAR_DB}.characters c
     LEFT JOIN (${CHAR_DB}.character_inventory ci
                JOIN ${CHAR_DB}.item_instance ii ON ii.guid = ci.item)
       ON ci.guid = c.guid AND ci.bag = 0 AND ci.slot IN ($slot_list)
     WHERE c.name IN ($in_list)
     GROUP BY c.name;"

rows="$(gear_query "$sql")" || {
    echo "FATAL: the gear query failed against $DB_CONTAINER (see the error above);" >&2
    echo "       this is NOT the same as every bot being naked, so nothing is reported" >&2
    exit 2; }

declare -A FILLED=()
while IFS=$'\t' read -r rname rslots; do
    [ -n "${rname:-}" ] || continue
    FILLED["$rname"]="${rslots:-}"
done <<< "$rows"

complete=0
worst=0
for n in "${names[@]}"; do
    # Unset, not empty: a name with no character row is a bot that was never
    # created. It has every slot missing, and saying so is the whole job.
    have=",${FILLED[$n]:-},"
    missing=""
    count=0
    for i in "${!GEAR_SLOT_IDS[@]}"; do
        case "$have" in
            *",${GEAR_SLOT_IDS[$i]},"*) count=$((count + 1)) ;;
            *) missing="${missing:+$missing,}${GEAR_SLOT_NAMES[$i]}" ;;
        esac
    done
    gap=$((GEAR_REQUIRED - count))
    [ "$gap" -gt "$worst" ] && worst="$gap"
    if [ -z "$missing" ]; then
        complete=$((complete + 1))
        printf '%s filled=%d/%d\n' "$n" "$count" "$GEAR_REQUIRED"
    else
        printf '%s filled=%d/%d missing=%s\n' "$n" "$count" "$GEAR_REQUIRED" "$missing"
    fi
done

printf 'GEAR-AUDIT %s complete=%d/%d worstMissing=%d\n' \
    "$team" "$complete" "${#names[@]}" "$worst"

[ "$complete" -eq "${#names[@]}" ]
