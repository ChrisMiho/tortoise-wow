#!/usr/bin/env bash
# Bracket definitions and pairing. Source, don't execute.
#
# Every WSG match must be Alliance vs Horde. SetBGTeam controls scoring and spawn
# side but not hostility -- Unit::IsHostileTo resolves through faction templates
# (src/game/Unit.cpp:5189) -- so a same-faction match is twenty bots standing in a
# tunnel refusing to fight, with no error anywhere to explain it.
#
# The bracket is therefore two mirrored ladders, one per faction, whose survivors
# meet positionally at every round: the nth alliance survivor plays the nth horde
# survivor. That makes every pairing cross-faction by construction rather than by
# luck, and it is why the ladders must stay equal in length and a power of two.

BRACKET_DIR="${BRACKET_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/config/tournament/brackets}"

bracket_file() { # <bracket-id> -> path to its JSON
    local f="$BRACKET_DIR/$1.json"
    [ -f "$f" ] || { echo "no such bracket: $1 (looked in $BRACKET_DIR)" >&2; return 1; }
    printf '%s\n' "$f"
}

bracket_field() { # <bracket-id> <jq-path> -> one scalar field
    local f; f="$(bracket_file "$1")" || return 1
    jq -r "$2" < "$f"
}

bracket_ladder() { # <bracket-id> <A|H> -> team ids in seed order, one per line
    local f key; f="$(bracket_file "$1")" || return 1
    case "$2" in
        A) key='.allianceLadder' ;;
        H) key='.hordeLadder' ;;
        *) echo "bracket_ladder: faction must be A or H, got '$2'" >&2; return 1 ;;
    esac
    jq -r "$key // [] | .[]" < "$f"
}

# log2 of the ladder size: 2 teams -> 1 round, 4 -> 2, 8 -> 3. bracket_validate
# is what guarantees the size is a power of two, so this can just halve.
bracket_rounds() { # <bracket-id>
    local n=0 size
    size="$(bracket_ladder "$1" A | grep -c . || true)"
    while [ "$size" -gt 1 ]; do size=$((size / 2)); n=$((n + 1)); done
    printf '%s\n' "$n"
}

# One round's matches, as <allianceTeam>|<hordeTeam> lines. Positional by design:
# see the header. Refuses rather than improvises, because the only ways to pair
# uneven lists are a bye or a same-faction match, and the second one silently
# produces a match no bot will play.
bracket_pairings() { # <bracket-id> "<alliance survivors>" "<horde survivors>"
    local -a a=() h=()
    read -r -a a <<< "${2:-}"
    read -r -a h <<< "${3:-}"
    if [ "${#a[@]}" -ne "${#h[@]}" ]; then
        echo "bracket_pairings: ${#a[@]} alliance vs ${#h[@]} horde survivors -- every match must be cross-faction, so the two lists must stay equal" >&2
        return 1
    fi
    if [ "${#a[@]}" -eq 0 ]; then
        echo "bracket_pairings: no survivors given -- there is nothing to pair" >&2
        return 1
    fi
    local i
    for i in "${!a[@]}"; do
        printf '%s|%s\n' "${a[$i]}" "${h[$i]}"
    done
}

# Prints every fault it finds rather than stopping at the first, so one run tells
# an operator everything wrong with the bracket.
bracket_validate() { # <bracket-id> -> 0 if valid, else 1 with faults on stderr
    local f faults=0 na nh id t
    f="$(bracket_file "$1")" || return 1

    jq -e . < "$f" >/dev/null 2>&1 || { echo "$1: not valid JSON" >&2; return 1; }

    id="$(jq -r '.id // ""' < "$f")"
    [ "$id" = "$1" ] || { echo "$1: .id is '$id', must match the filename" >&2; faults=1; }

    na="$(bracket_ladder "$1" A | grep -c . || true)"
    nh="$(bracket_ladder "$1" H | grep -c . || true)"

    if [ "$na" -ne "$nh" ]; then
        echo "$1: allianceLadder has $na teams, hordeLadder has $nh -- they must be equal or a round cannot pair every team cross-faction" >&2
        faults=1
    fi

    # A power of two, so every round halves cleanly and no team gets a bye. A bye
    # would leave one faction's survivor list longer than the other's, and the
    # next round could not be paired cross-faction at all.
    if [ "$na" -lt 1 ] || [ $(( na & (na - 1) )) -ne 0 ]; then
        echo "$1: ladder size $na must be a power of two" >&2
        faults=1
    fi

    # Teams must exist and sit on the faction their ladder claims. Skipped when
    # team.sh is not sourced, so bracket.sh stays usable on its own -- callers
    # that care source both, which is what tournament-run.sh does.
    if command -v team_validate >/dev/null 2>&1; then
        while IFS= read -r t; do
            [ -n "$t" ] || continue
            if ! team_validate "$t" >/dev/null 2>&1; then
                echo "$1: alliance ladder references '$t', which does not exist or does not validate" >&2
                faults=1
            elif [ "$(team_field "$t" '.faction')" != "A" ]; then
                echo "$1: '$t' is in the alliance ladder but its faction is not A" >&2
                faults=1
            fi
        done < <(bracket_ladder "$1" A)

        while IFS= read -r t; do
            [ -n "$t" ] || continue
            if ! team_validate "$t" >/dev/null 2>&1; then
                echo "$1: horde ladder references '$t', which does not exist or does not validate" >&2
                faults=1
            elif [ "$(team_field "$t" '.faction')" != "H" ]; then
                echo "$1: '$t' is in the horde ladder but its faction is not H" >&2
                faults=1
            fi
        done < <(bracket_ladder "$1" H)
    fi

    return "$faults"
}
