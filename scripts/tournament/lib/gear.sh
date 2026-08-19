#!/usr/bin/env bash
# Read and validate gear tier definitions. Source, don't execute.
#
# A bot's kit is data, not a console transcript: config/tournament/gear/<class>-<role>.json
# holds one entry per required slot per named tier. Nothing downstream reads item
# ids out of a database -- it reads this file -- which is why a mechanically
# generated ("provisional": true) file and a hand-curated one behave identically
# everywhere, and why curation can be deferred without blocking a match.
#
# Two properties are the whole point of the format, and gear_validate is where
# they are enforced:
#
#   COMPLETE. Every required slot present in every tier. `rndbot create gear=blue`
#   runs InitEquipment(false,false), which destroys every equipped item before
#   choosing replacements (PlayerbotFactory.cpp:2999-3003) and leaves any slot it
#   cannot fill empty. A tier file with a hole reproduces exactly that bug by
#   hand, so a hole is not a tier.
#
#   ORDERED. Unique numeric `rank` per tier, so "upgrade this bot" is a single
#   deterministic step along one axis and a no-op at the top.
#
# Requires jq. Run callers from WSL: jq is not on Git Bash's PATH on this host.

GEAR_DIR="${GEAR_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/config/tournament/gear}"

# The slots a tier must fill. COUPLED to GEAR_SLOT_NAMES / GEAR_SLOT_IDS in
# scripts/tournament/gear-audit.sh -- the same 13 slots, in the same order (the
# plan text calls the audit's list GEAR_REQUIRED_SLOTS; on this server it is
# spelled GEAR_SLOT_NAMES, beside the equipment-slot ids it needs for its query).
# If one list changes, change both: a tier that validates here but audits as
# incomplete there is worse than either failure alone, because it looks like a
# working kit right up to the moment a match is gated on the audit.
#
# The six absentees are absent on purpose and are documented in gear-audit.sh:
# body(3) and tabard(18) are cosmetic, finger2(11) and trinket2(13) are optional
# duplicates, offhand(16) is legitimately empty for every two-handed spec and
# ranged(17) for several others.
GEAR_REQUIRED_NAMES="head neck shoulders chest waist legs feet wrists hands finger1 trinket1 back mainhand"

gear_file() { # <class> <role> -> path to its JSON, 1 if there isn't one
    local f="$GEAR_DIR/$1-$2.json"
    [ -f "$f" ] || { echo "no gear file for $1-$2 (looked in $GEAR_DIR)" >&2; return 1; }
    printf '%s\n' "$f"
}

gear_tiers() { # <class> <role> -> tier names, one per line, ordered by rank
    local f; f="$(gear_file "$1" "$2")" || return 1
    jq -r '.tiers // {} | to_entries | sort_by(.value.rank) | .[].key' < "$f"
}

gear_items() { # <class> <role> <tier> -> slotName|itemId lines, in file order
    local f; f="$(gear_file "$1" "$2")" || return 1
    jq -e --arg t "$3" '(.tiers // {}) | has($t)' < "$f" >/dev/null 2>&1 || {
        echo "$1-$2: no tier '$3'" >&2; return 1; }
    jq -r --arg t "$3" '.tiers[$t].items // {} | to_entries[]
                        | .key + "|" + (.value|tostring)' < "$f"
}

# The tier exactly one rank above the current one, and EMPTY at the top: an
# upgrade that has run out of tiers is a no-op, never a wrap-around to base.
# Handing a viewer who paid for an upgrade a downgrade to white is worse than
# handing them nothing.
gear_next_tier() { # <class> <role> <current-tier>
    local f; f="$(gear_file "$1" "$2")" || return 1
    # An unrecognised current tier is an error, not "start from the bottom". The
    # obvious shorthand -- treating a missing rank as -1 -- makes a typo'd tier
    # name print `base`, which is the same wrap-around this function exists to
    # rule out, only harder to notice.
    jq -e --arg c "$3" '.tiers[$c].rank | numbers' < "$f" >/dev/null 2>&1 || {
        echo "$1-$2: no tier '$3' with a numeric rank" >&2; return 1; }
    jq -r --arg c "$3" '
        .tiers[$c].rank as $r
        | .tiers | to_entries | map(select(.value.rank > $r)) | sort_by(.value.rank)
        | if length > 0 then .[0].key else "" end' < "$f"
}

# Prints every fault it finds rather than stopping at the first, so one run tells
# an operator everything wrong with the file -- same contract as team_validate.
gear_validate() { # <class> <role> -> 0 if valid, else 1 with faults on stderr
    local f faults=0 got n ranked ranks uniq t kind slot
    f="$(gear_file "$1" "$2")" || return 1

    # Fatal rather than counted: every check below is a jq query, and jq on a
    # malformed file reports its own parse error once per call.
    jq -e . < "$f" >/dev/null 2>&1 || { echo "$1-$2: not valid JSON" >&2; return 1; }

    # The filename is what gear_file resolves and what gear-apply.sh derives from
    # a roster row, so a file whose .class disagrees with its name silently
    # dresses the wrong class.
    got="$(jq -r '.class // ""' < "$f")"
    [ "$got" = "$1" ] || { echo "$1-$2: .class is '$got', must match the filename" >&2; faults=1; }
    got="$(jq -r '.role // ""' < "$f")"
    [ "$got" = "$2" ] || { echo "$1-$2: .role is '$got', must match the filename" >&2; faults=1; }

    n="$(jq -r '.tiers // {} | length' < "$f")"
    [ "$n" -ge 2 ] || {
        echo "$1-$2: needs at least two tiers, has $n -- one tier means nothing to upgrade into" >&2
        faults=1; }

    # Ranks must all be numbers and all be distinct, or gear_next_tier's ordering
    # is arbitrary and an upgrade lands somewhere nobody chose.
    ranked="$(jq -r '[.tiers // {} | .[].rank | numbers] | length' < "$f")"
    [ "$ranked" = "$n" ] || {
        echo "$1-$2: every tier needs a numeric .rank ($ranked of $n have one)" >&2; faults=1; }
    ranks="$(jq -r '.tiers // {} | .[].rank' < "$f" | sort)"
    uniq="$(printf '%s\n' "$ranks" | sort -u)"
    [ "$ranks" = "$uniq" ] || {
        echo "$1-$2: tier ranks must be unique, got $(printf '%s' "$ranks" | tr '\n' ' ')" >&2
        faults=1; }

    # One jq call per tier emits every fault in that tier, so the loop stays
    # readable without paying 13 process spawns per tier.
    while IFS= read -r t; do
        [ -n "${t:-}" ] || continue
        while IFS='|' read -r kind slot; do
            [ -n "${slot:-}" ] || continue
            case "$kind" in
                MISSING)     echo "$1-$2: tier '$t' has no item for required slot '$slot'" >&2 ;;
                PLACEHOLDER) echo "$1-$2: tier '$t' slot '$slot' is still a placeholder 0" >&2 ;;
            esac
            faults=1
        done < <(jq -r --arg t "$t" --arg req "$GEAR_REQUIRED_NAMES" '
                    (.tiers[$t].items // {}) as $it
                    | ($req | split(" "))[]
                    | . as $s
                    | $it[$s] as $v
                    | if   $v == null            then "MISSING|" + $s
                      elif ($v|tostring) == "0"  then "PLACEHOLDER|" + $s
                      else empty end' < "$f")
    done < <(jq -r '.tiers // {} | keys[]' < "$f")

    return "$faults"
}

# --- splitting a tier into the two things a viewer can buy -------------------
#
# `upgrade_armor_*` and `upgrade_weapon_*` are separate effects with separate
# prices, so a tier -- a single flat slot->itemId map -- has to be splittable.
# Without this, both effects apply the whole kit and a viewer cannot tell which
# one they paid for.
#
# The weapon slots, and only these three, per EQUIPMENT_SLOT_MAINHAND / OFFHAND /
# RANGED in src/game/Objects/Player.h:590-610. Named once, here, because the two
# splitters must agree by construction: a slot they disagree about is a slot no
# effect can ever upgrade.
#
# EVERYTHING ELSE IN A TIER IS ARMOUR -- including neck, finger1, trinket1 and
# back, which are not "armour" in the item-class sense at all. They go in the
# armour half anyway, because "upgrade my armour" means "upgrade everything that
# is not the weapon" to the viewer paying for it, and a slot in neither half
# would be permanently unreachable by any effect.
GEAR_WEAPON_SLOTS="mainhand offhand ranged"

# Both splitters print from inside the `while` rather than accumulating into a
# variable: the loop is the right-hand side of a pipe, so it runs in a subshell
# and anything it assigns is gone by the time the function returns.
gear_items_weapon() { # <class> <role> <tier> -> slotName|itemId lines, weapons only
    local slot id
    gear_items "$1" "$2" "$3" | while IFS='|' read -r slot id; do
        case " $GEAR_WEAPON_SLOTS " in
            *" $slot "*) printf '%s|%s\n' "$slot" "$id" ;;
        esac
    done
}

gear_items_armor() { # <class> <role> <tier> -> slotName|itemId lines, all the rest
    local slot id
    gear_items "$1" "$2" "$3" | while IFS='|' read -r slot id; do
        case " $GEAR_WEAPON_SLOTS " in
            *" $slot "*) ;;
            *) printf '%s|%s\n' "$slot" "$id" ;;
        esac
    done
}
