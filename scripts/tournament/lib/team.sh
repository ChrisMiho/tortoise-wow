#!/usr/bin/env bash
# Read and validate tournament team definitions. Source, don't execute.
#
# A team is data, not a console transcript. Everything an operator would tweak
# per team lives in config/tournament/teams/<id>.json, and this file is the only
# thing that knows its shape.
#
# The validation below is not bureaucracy, it is the whole point. A character
# name must be alphabetic and at most 12 characters
# (MAX_PLAYER_NAME, src/game/ObjectMgr.h:472; CheckPlayerName calls
# isValidString with numericOrSpace=false, src/game/ObjectMgr.cpp:7051-7069), and
# that check runs at character *load*, not at creation. PlayerbotMgr.cpp:2506
# pushes "Bot is now online" before login is even attempted, so a rejected name
# looks like a successful login followed by a mystery disconnect and leaves a row
# with at_login=1 that can never come online and has to be deleted by hand.
# Catching that here costs a second; catching it in the world cost a full
# debugging session.

TEAM_DIR="${TEAM_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/config/tournament/teams}"

# Races legal for each faction. A roster whose races straddle factions cannot
# play as one team, and the fault would not surface until bots turned up on the
# wrong side of a battleground.
TEAM_RACES_A="Human Dwarf NightElf Gnome"
TEAM_RACES_H="Orc Undead Tauren Troll"

# A character's name is namePrefix + slot, so these words are part of the name
# budget and not merely an ordering key. Ten slots because a team is ten bots and
# a bot account holds at most nine characters (PlayerbotMgr.cpp:2325) -- the
# roster is deliberately not something a caller gets to resize.
TEAM_SLOTS="one two three four five six seven eight nine ten"

TEAM_NAME_MAX=12

team_file() { # <team-id> -> path to its JSON
    local f="$TEAM_DIR/$1.json"
    [ -f "$f" ] || { echo "no such team: $1 (looked in $TEAM_DIR)" >&2; return 1; }
    printf '%s\n' "$f"
}

team_field() { # <team-id> <jq-path> -> one scalar field
    local f; f="$(team_file "$1")" || return 1
    jq -r "$2" < "$f"
}

team_names() { # <team-id> -> the ten character names, one per line, in slot order
    local f; f="$(team_file "$1")" || return 1
    jq -r '.namePrefix as $p | .roster[] | $p + .slot' < "$f"
}

# name|class|race|role|faction -- deliberately the same shape as
# docs/playerbots/wsg/wsg-team-roster.txt, so wsg_load_roster in
# docs/playerbots/wsg/lib/wsg-bots-common.sh keeps working unchanged and the two
# descriptions of these bots cannot drift apart.
team_rows() { # <team-id>
    local f; f="$(team_file "$1")" || return 1
    jq -r '.namePrefix as $p | .faction as $fac | .roster[]
           | ($p + .slot) + "|" + .class + "|" + .race + "|" + .role + "|" + $fac' < "$f"
}

# Prints every fault it finds rather than stopping at the first, so one run tells
# an operator everything wrong with the file.
team_validate() { # <team-id> -> 0 if valid, else 1 with faults on stderr
    local f faults=0 id faction prefix n legal want got race nm role
    f="$(team_file "$1")" || return 1

    jq -e . < "$f" >/dev/null 2>&1 || { echo "$1: not valid JSON" >&2; return 1; }

    id="$(jq -r '.id // ""' < "$f")"
    [ "$id" = "$1" ] || { echo "$1: .id is '$id', must match the filename" >&2; faults=1; }

    # Faction first: without it there is no way to judge the races, so this one
    # fault is fatal rather than merely counted.
    faction="$(jq -r '.faction // ""' < "$f")"
    case "$faction" in
        A) legal="$TEAM_RACES_A" ;;
        H) legal="$TEAM_RACES_H" ;;
        *) echo "$1: .faction must be A or H, got '$faction'" >&2; return 1 ;;
    esac

    prefix="$(jq -r '.namePrefix // ""' < "$f")"
    case "$prefix" in
        *[!A-Za-z]*|"")
            echo "$1: .namePrefix '$prefix' must be alphabetic only -- a digit is rejected at character load, not creation, leaving an at_login=1 row that can never come online" >&2
            faults=1 ;;
    esac

    n="$(jq -r '.roster // [] | length' < "$f")"
    [ "$n" -eq 10 ] || { echo "$1: roster has $n entries, expected 10" >&2; faults=1; }

    # Slots must be the canonical words, in order, with no repeats: the name is
    # prefix+slot, so a duplicate slot is a duplicate name and the second create
    # fails with "Name already exists" while the console reports nothing.
    want="$(printf '%s\n' $TEAM_SLOTS)"
    got="$(jq -r '.roster // [] | .[].slot' < "$f")"
    [ "$want" = "$got" ] || { echo "$1: slots must be exactly '$TEAM_SLOTS', in order" >&2; faults=1; }

    while IFS= read -r race; do
        case " $legal " in
            *" $race "*) ;;
            *) echo "$1: race '$race' is not playable by faction $faction" >&2; faults=1 ;;
        esac
    done < <(jq -r '.roster // [] | .[].race' < "$f")

    # The generated name, not the prefix, is what the server has to accept.
    while IFS= read -r nm; do
        case "$nm" in
            *[!A-Za-z]*) echo "$1: generated name '$nm' is not alphabetic" >&2; faults=1 ;;
        esac
        [ "${#nm}" -le "$TEAM_NAME_MAX" ] || {
            echo "$1: generated name '$nm' exceeds $TEAM_NAME_MAX characters" >&2; faults=1; }
    done < <(team_names "$1")

    while IFS= read -r role; do
        case "$role" in
            tank|healer|dps) ;;
            *) echo "$1: role '$role' must be tank, healer or dps" >&2; faults=1 ;;
        esac
    done < <(jq -r '.roster // [] | .[].role' < "$f")

    return "$faults"
}
