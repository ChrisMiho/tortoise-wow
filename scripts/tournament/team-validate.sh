#!/usr/bin/env bash
# Validate team definitions. Nothing here touches the server or the database --
# run it as often as you like.
#
#   ./scripts/tournament/team-validate.sh                     # every team
#   ./scripts/tournament/team-validate.sh stormwind-sentinels
#
# Exit 0 = every team checked is valid. Exit 1 = at least one fault, printed.
# Exit 2 = could not run the check at all, which is not the same as passing.
#
# This exists so every later script has one thing to call before it touches the
# world, and so a bad team file fails in under a second instead of after ten
# character creations that have to be unpicked by hand.
#
# Run from WSL: jq is not on Git Bash's PATH on this host.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/team.sh
. "$HERE/lib/team.sh"

command -v jq >/dev/null 2>&1 || {
    echo "FATAL: jq is not installed (apt-get install jq)" >&2; exit 2; }

teams=("$@")
if [ "${#teams[@]}" -eq 0 ]; then
    [ -d "$TEAM_DIR" ] || { echo "FATAL: no team directory at $TEAM_DIR" >&2; exit 2; }
    while IFS= read -r f; do
        teams+=("$(basename "$f" .json)")
    done < <(find "$TEAM_DIR" -maxdepth 1 -name '*.json' | sort)
fi

[ "${#teams[@]}" -gt 0 ] || { echo "no team definitions found in $TEAM_DIR" >&2; exit 1; }

rc=0
for t in "${teams[@]}"; do
    if team_validate "$t"; then
        printf 'ok    %s (%s, %s)\n' \
            "$t" "$(team_field "$t" '.faction')" "$(team_field "$t" '.displayName')"
    else
        printf 'FAULT %s\n' "$t"
        rc=1
    fi
done
exit $rc
