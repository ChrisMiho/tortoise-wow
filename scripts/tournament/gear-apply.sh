#!/usr/bin/env bash
# Dress a tournament team, or one bot, from its gear tier files.
#
#   ./scripts/tournament/gear-apply.sh team   <team-id> [--tier <name>] [--with-consumables]
#   ./scripts/tournament/gear-apply.sh player <team-id> <slot> [--tier <name>] [--with-consumables]
#
# This is the piece that turns config/tournament/gear/<class>-<role>.json into a
# dressed bot. Everything either side of it already existed: gear-generate.sh
# writes the tier files, `tournament equip` puts one item list on one player, and
# gear-audit.sh says whether a team is actually wearing anything. Nothing joined
# them up, so "this team, this tier" was a manual transcription job per bot.
#
# THE COMMANDS BEING SENT IS NOT SUCCESS. A filled slot is. `tournament equip`
# reports per-item failures precisely because a class or level restriction is a
# bad item choice in a tier file rather than a broken command, so this script
# ends by re-running gear-audit.sh and exits 0 ONLY if that audit passes.
#
# IT DRESSES EVERY BOT ON THE TEAM, not only the under-dressed ones. Both teams
# then wear the same grade of kit and no match is decided by gear. Existing items
# are replaced -- `tournament equip` calls CanEquipNewItem with swap = true
# exactly because the slot is expected to be occupied. Topping up only the gaps
# was measured and rejected on 2026-08-16: 9 of the 20 shipped bots were fully
# dressed (stormwind-sentinels 4/10, orgrimmar-warsong 5/10, the worst bots at 5
# of 13 required slots), so a top-up would have left two teams in materially
# different gear and called it fair.
#
# BOTS MUST BE ONLINE. `tournament equip` and `tournament store` resolve the
# player by name through ObjectAccessor; an offline bot is answered
# error=player_not_online(<name>) and nothing is written. Run
# `./scripts/tournament/roster.sh login <team-id>` first. Both handlers call
# SaveToDB(), so the gear survives an immediate `roster.sh logout`.
#
# Exit 0 = every bot was dressed and the follow-up audit reports the team
# complete. Exit 1 = something did not apply, or the audit still finds a hole.
# Exit 2 = it could not run at all (bad arguments, a team that does not validate,
# no jq/docker) -- deliberately a third code, because "could not apply" is not
# "applied and found wanting", the same distinction gear-audit.sh draws.
#
# The tier files are NOT in the repository -- they are picked from this world's
# own item_template, so `./scripts/tournament/gear-generate.sh` has to have been
# run at least once on this host. A class whose file is absent is skipped with
# "no gear file for <class>-<role>", not applied blank.
#
# Run from WSL: jq is not on Git Bash's PATH on this host.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/team.sh
. "$HERE/lib/team.sh"
# shellcheck source=lib/gear.sh
. "$HERE/lib/gear.sh"
# shellcheck source=lib/ctl.sh
. "$HERE/lib/ctl.sh"
# shellcheck source=../../docs/playerbots/wsg/lib/wsg-bots-common.sh
. "$ROOT/docs/playerbots/wsg/lib/wsg-bots-common.sh"

# ONE console attach for the whole run, so it needs the room roster.sh gives a
# batch of the same size and then some: a team is 10 equips of 13 items each, and
# every one of those is queued onto the world thread rather than answered at
# typing speed. Ten separate attaches would be ten chances to send the console an
# EOF, which mangosd reads as "shut down the world".
GEAR_CONSOLE_WAIT="${GEAR_CONSOLE_WAIT:-40}"

usage() {
    echo "usage: $(basename "$0") team   <team-id> [--tier <name>] [--with-consumables]" >&2
    echo "       $(basename "$0") player <team-id> <slot> [--tier <name>] [--with-consumables]" >&2
    echo "       $(basename "$0") team   <team-id> --with-consumables" >&2
    echo "" >&2
    echo "       applies each bot's <class>-<role> tier, defaulting to the team's .gearTier;" >&2
    echo "       <slot> is a roster slot word (one..ten), resolved as namePrefix + slot." >&2
    echo "       Bots must be online: run roster.sh login <team-id> first." >&2
}

mode="${1:-}"
team="${2:-}"
want_slot=""
[ -n "$team" ] || { usage; exit 2; }
case "$mode" in
    team)   shift 2 ;;
    player) want_slot="${3:-}"
            [ -n "$want_slot" ] || { usage; exit 2; }
            shift 3 ;;
    *)      usage; exit 2 ;;
esac

tier_override=""
with_consumables=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --tier)              [ -n "${2:-}" ] || { usage; exit 2; }; tier_override="$2"; shift 2 ;;
        --with-consumables)  with_consumables=1; shift ;;
        *)                   echo "unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

command -v jq >/dev/null 2>&1 || {
    echo "FATAL: jq is not installed (apt-get install jq); run this from WSL" >&2; exit 2; }
command -v docker >/dev/null 2>&1 || {
    echo "FATAL: docker is not on PATH" >&2; exit 2; }

# Refuse rather than dress a team we cannot trust. A roster with a duplicate slot
# or an over-long name describes characters that never came online, so every
# equip would answer player_not_online and the failure would be blamed on the
# gear. Same gate, and the same reason, as gear-audit.sh.
team_validate "$team" || {
    echo "FATAL: $team does not validate; refusing to gear it" >&2; exit 2; }

default_tier="$(team_field "$team" '.gearTier // ""')"
if [ -z "$tier_override" ] && [ -z "$default_tier" ]; then
    echo "FATAL: $team has no .gearTier and no --tier was given" >&2; exit 2
fi
tier="${tier_override:-$default_tier}"

prefix="$(team_field "$team" '.namePrefix')"

rc=0

# --- plan -------------------------------------------------------------------
#
# Every tier file is validated and read BEFORE a single command is sent, so a
# class whose file is broken is skipped rather than half-applied and the console
# never sees a command built from a tier that does not exist. The two caches are
# not micro-optimisation: gear_validate is a dozen jq invocations and a ten-bot
# team holds at most six distinct class/role pairs, so without them the plan
# phase costs twice what it needs to and prints every fault twice.

declare -A VALIDATED=()   # class-role -> 0 good, 1 bad
declare -A ITEMS=()       # class-role -> comma-separated item ids for $tier
APPLIED=()                # names that actually got commands
LINES=""

plan_one() { # <name> <class> <role> -> 0 if queued, 1 if skipped
    local nm="$1" cls="$2" role="$3" key="$2-$3" ids item cnt cf

    if [ -z "${VALIDATED[$key]:-}" ]; then
        if gear_validate "$cls" "$role"; then VALIDATED["$key"]=0; else VALIDATED["$key"]=1; fi
    fi
    if [ "${VALIDATED[$key]}" != "0" ]; then
        echo "SKIP $nm: $key does not validate (faults above)" >&2
        return 1
    fi

    if [ -z "${ITEMS[$key]:-}" ]; then
        # A failure here has already said why on stderr, and an empty list is the
        # same skip below either way -- hence NONE rather than a second message.
        ids="$(gear_items "$cls" "$role" "$tier" | cut -d'|' -f2 | paste -sd, -)"
        ITEMS["$key"]="${ids:-NONE}"
    fi
    ids="${ITEMS[$key]}"
    if [ "$ids" = "NONE" ]; then
        echo "SKIP $nm: tier '$tier' has no items for $key" >&2
        return 1
    fi

    LINES="${LINES}tournament equip $nm $ids"$'\n'

    if [ "$with_consumables" = "1" ]; then
        cf="$(gear_file "$cls" "$role")" || return 1
        while IFS='|' read -r item cnt; do
            [ -n "${item:-}" ] || continue
            LINES="${LINES}tournament store $nm $item $cnt"$'\n'
        done < <(jq -r '.consumables[]? | (.itemId|tostring) + "|" + (.count|tostring)' < "$cf")
    fi

    APPLIED+=("$nm")
    return 0
}

matched=0
while IFS='|' read -r nm cls race role fac; do
    [ -n "${nm:-}" ] || continue
    if [ -n "$want_slot" ]; then
        [ "$nm" = "$prefix$want_slot" ] || continue
    fi
    matched=$((matched + 1))
    plan_one "$nm" "$cls" "$role" || rc=1
done < <(team_rows "$team")

if [ -n "$want_slot" ] && [ "$matched" -eq 0 ]; then
    echo "FATAL: $team has no roster slot '$want_slot' (expected one of: $TEAM_SLOTS)" >&2
    exit 2
fi

# --- send -------------------------------------------------------------------

out=""
if [ -n "$LINES" ]; then
    echo "==> applying tier '$tier' to ${#APPLIED[@]} bot(s) on $team" >&2
    CTL_WAIT="$GEAR_CONSOLE_WAIT"
    out="$(ctl "$LINES")"
else
    echo "==> nothing to apply" >&2
fi

# --- report -----------------------------------------------------------------
#
# Reported per bot from the console's own answer, not from "the command was
# sent". Three outcomes are distinguished on purpose:
#
#   equipped=<n> failed=0    applied.
#   equipped=<n> failed=<m>  applied in part -- the ok=0 lines printed under it
#                            say which item and why. Look reason=cannot_equip(<n>)
#                            up in InventoryResult (src/game/Objects/Item.h:45,
#                            NOT SharedDefines.h). The two that used to account
#                            for every failure here -- 8 (no proficiency) and 17
#                            (already carrying a unique) -- are handled inside
#                            `tournament equip` now, so either one reappearing
#                            means a bot the server would not grant, not a tier
#                            file. Anything else IS a bad item choice, and
#                            `gear-generate.sh --check <class> <role>` names the
#                            requirement it fails.
#   no summary line          the bot is offline, or the world did not answer
#                            within GEAR_CONSOLE_WAIT. NOT "it worked": treating
#                            a missing failed= as zero reads a silent console as
#                            a clean run, which is the one wrong answer here.

for nm in ${APPLIED[@]+"${APPLIED[@]}"}; do
    line="$(printf '%s\n' "$out" | grep -a "equip player=$nm equipped=" | head -1)"
    if [ -z "$line" ]; then
        if printf '%s\n' "$out" | grep -qa "player_not_online($nm)"; then
            echo "FAIL $nm: not online -- run ./scripts/tournament/roster.sh login $team first" >&2
        else
            echo "FAIL $nm: no equip summary came back within ${GEAR_CONSOLE_WAIT}s (raise GEAR_CONSOLE_WAIT)" >&2
        fi
        rc=1
        continue
    fi

    equipped="$(ctl_field "$line" equipped)"
    failed="$(ctl_field "$line" failed)"
    printf '%s tier=%s equipped=%s failed=%s\n' "$nm" "$tier" "${equipped:-?}" "${failed:-?}"
    if [ "${failed:-1}" != "0" ]; then
        printf '%s\n' "$out" | grep -a "equip player=$nm " | grep -a "ok=0" >&2
        rc=1
    fi

    if [ "$with_consumables" = "1" ]; then
        # Reported, never silently dropped. cannot_store is usually no free bag
        # space -- bots ship with small default bags -- and that is a real result
        # an operator has to see, not a rounding error.
        stores="$(printf '%s\n' "$out" | grep -a "store player=$nm ")"
        if [ -z "$stores" ]; then
            echo "FAIL $nm: --with-consumables was asked for and no store line came back" >&2
            rc=1
        else
            while IFS= read -r sline; do
                [ -n "${sline:-}" ] || continue
                printf '%s\n' "$sline"
                [ "$(ctl_field "$sline" ok)" = "1" ] || rc=1
            done <<< "$stores"
        fi
    fi
done

# --- verify -----------------------------------------------------------------
#
# The audit is the gate, not this script's own transcript. It stays team-scoped
# in player mode too: gear-audit.sh audits a team, and one dressed bot on an
# otherwise naked team is not a team ready for a match.

echo "==> re-auditing $team" >&2
"$HERE/gear-audit.sh" "$team"
audit_rc=$?

# The audit's verdict outranks the transcript in both directions: a run whose
# commands all reported ok is still a failure if the slots are empty, and an
# unmeasurable audit (2) is reported as unmeasurable rather than flattened into a
# plain failure.
[ "$audit_rc" -eq 0 ] || exit "$audit_rc"
exit "$rc"
