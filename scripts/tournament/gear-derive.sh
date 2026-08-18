#!/usr/bin/env bash
# Propose candidate items per required equipment slot, for hand review.
#
#   ./scripts/tournament/gear-derive.sh <classId> <quality> [maxItemLevel]
#
#   classId : 1 warrior 2 paladin 3 hunter 4 rogue 5 priest
#             7 shaman 8 mage 9 warlock 11 druid
#   quality : 1 common(white) 2 uncommon(green) 3 rare(blue) 4 epic(purple)
#
#   slot       entry  name                  itemLevel  quality
#   head       7357   Sentry's Surcoat...   52         1
#   ...
#
# This PROPOSES ONLY. It never writes a tier file and never touches
# config/tournament/gear/ -- an auto-picked, unreviewed kit is the outcome this
# whole gear path exists to replace. Use gear-generate.sh when you want files.
#
# COLUMN NAMES ON THIS SERVER ARE snake_case -- entry, class, subclass, name,
# quality, inventory_type, allowable_class, item_level, required_level -- not the
# CamelCase (Quality, InventoryType, ItemLevel, RequiredLevel, AllowableClass)
# that the plan text assumes; those fail outright with `Unknown column`. The
# measurement and the full column list are in lib/itemdb.sh, which owns every
# query here.
#
# Read-only: one SELECT per slot, nothing written, no console, no server image.
# Run from WSL, not Git Bash.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/itemdb.sh
. "$HERE/lib/itemdb.sh"

# How many candidates to show per slot. A few, not one: the point of this script
# is that a human picks, so one row would be a decision rather than a proposal.
LIMIT="${GEAR_DERIVE_LIMIT:-5}"

usage() {
    echo "usage: $(basename "$0") <classId> <quality> [maxItemLevel]" >&2
    echo "       classId 1 warrior 2 paladin 3 hunter 4 rogue 5 priest" >&2
    echo "               7 shaman 8 mage 9 warlock 11 druid" >&2
    echo "       quality 1 white 2 green 3 blue 4 purple" >&2
    echo "       proposes candidates only; writes nothing" >&2
}

# maxItemLevel defaults to no effective cap: required_level <= 60 is what decides
# whether a level-60 bot can wear the thing, and lib/itemdb.sh already excludes
# the deprecated/unobtainable dev sets. Pass one when you want to see what a
# deliberately modest kit would look like.
cls="${1:-}"; quality="${2:-}"; maxIlvl="${3:-999}"
[ -n "$cls" ] && [ -n "$quality" ] || { usage; exit 2; }
[ "$#" -le 3 ] || { usage; exit 2; }
for n in "$cls" "$quality" "$maxIlvl"; do
    case "$n" in
        ''|*[!0-9]*) echo "FATAL: '$n' is not a number" >&2; usage; exit 2 ;;
    esac
done

command -v docker >/dev/null 2>&1 || {
    echo "FATAL: docker is not on PATH" >&2; exit 2; }

# Fail on an unknown class id before running thirteen queries that would all
# return nothing and read as "this server has no gear".
itemdb_armor_subclasses "$cls" >/dev/null || exit 2
itemdb_weapon_subclasses "$cls" >/dev/null || exit 2

printf 'slot\tentry\tname\titemLevel\tquality\n'

rc=0
while IFS= read -r slot; do
    [ -n "${slot:-}" ] || continue
    rows="$(itemdb_candidates "$cls" "$slot" "$quality" "$maxIlvl" "$LIMIT")" || {
        echo "FATAL: the item_template query failed for slot '$slot' (see the error above);" >&2
        echo "       that is NOT the same as the slot having no candidate, so nothing is claimed" >&2
        exit 2; }
    if [ -z "$rows" ]; then
        # Information, not failure: this script proposes, and "nothing at this
        # quality" is a real answer a reviewer needs to see. gear-generate.sh is
        # the one that treats an empty slot as fatal.
        echo "note: no candidate for '$slot' at quality $quality for class $cls" >&2
        rc=1
        continue
    fi
    printf '%s\n' "$rows"
done < <(itemdb_slots)

exit "$rc"
