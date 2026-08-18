#!/usr/bin/env bash
# Tournament run state. Source, don't execute.
#
# A tournament run is hours long and interruptible -- a crash, a power cut, or an
# operator stopping it. So state is written to disk after EVERY change, and every
# write goes to a temp file and is then renamed over the real one. rename(2) is
# atomic, so a kill between the two leaves either the old state or the new one and
# never a truncated file. A run that only persists its result at the end loses the
# whole night to a single interruption; a run that persists non-atomically loses it
# to a corrupt file, which is worse because it looks resumable.

state_file() { printf '%s/state.json\n' "$1"; }

# Idempotent: re-running on an existing run resumes it rather than resetting it.
# The resume path is the one that matters overnight, so it is the default and
# there is deliberately no flag to reset -- delete the directory for that.
state_init() { # <run-dir> <bracket-id> "<alliance seeds>" "<horde seeds>"
    local dir="$1" bracket="$2" a="${3:-}" h="${4:-}" f
    mkdir -p "$dir" || return 1
    f="$(state_file "$dir")"
    if [ -f "$f" ]; then return 0; fi

    jq -n --arg b "$bracket" --arg a "$a" --arg h "$h" '{
        bracketId: $b,
        round: 1,
        status: "running",
        survivors: { A: ($a | split(" ") | map(select(. != ""))),
                     H: ($h | split(" ") | map(select(. != ""))) },
        results: []
    }' > "$f.tmp" && mv -f "$f.tmp" "$f" && return 0

    rm -f "$f.tmp"
    return 1
}

state_get() { # <run-dir> <jq-path>
    local f; f="$(state_file "$1")"
    [ -f "$f" ] || { echo "no run state at $f" >&2; return 1; }
    jq -r "$2" < "$f"
}

# Atomic: temp file then rename, and the temp file is removed rather than left
# behind when jq fails. A partial write here is a corrupt run that cannot be
# resumed, which defeats the point of persisting at all.
#
# Extra arguments are passed to jq, so callers pass values with --arg instead of
# interpolating them into the program text.
state_set() { # <run-dir> <jq-expression> [jq args...]
    local f expr
    f="$(state_file "$1")"
    [ -f "$f" ] || { echo "no run state at $f" >&2; return 1; }
    expr="$2"; shift 2
    if jq "$@" "$expr" < "$f" > "$f.tmp"; then
        mv -f "$f.tmp" "$f"
    else
        rm -f "$f.tmp"
        return 1
    fi
}

state_survivors() { # <run-dir> <A|H> -> surviving team ids, space separated
    case "$2" in
        A|H) ;;
        *) echo "state_survivors: faction must be A or H, got '$2'" >&2; return 1 ;;
    esac
    state_get "$1" "$(printf '.survivors["%s"] | join(" ")' "$2")"
}

# Records the match and eliminates the loser.
#
# decidedBy is what keeps the record honest. "server" means the battleground
# itself returned that winner. Anything else -- tiebreak_score, tiebreak_deaths,
# tiebreak_seed -- means the driver chose the winner because the battleground
# didn't declare one, which the 20-minute hard cap (BattleGround.cpp:317-323)
# makes routine for bot matches. Both eliminate a team; only one is a result, and
# a report that blurs them claims wins the server never awarded.
#
# A NONE winner eliminates nobody, whatever decidedBy says. That is what leaves
# the survivor lists uneven and deadlocks the bracket, which is the correct
# outcome for any caller that does not tiebreak: advancing a side the server never
# declared would fabricate a winner.
state_record_result() { # <run-dir> <round> <allianceTeam> <hordeTeam> <winner> [<decidedBy>]
    local dir="$1" round="$2" ateam="$3" hteam="$4" winner="$5" decided="${6:-server}"

    # $round | tonumber: a shell value arrives through jq's --arg as a JSON
    # string, and a string round breaks every later numeric comparison -- the
    # driver's "is this round done" test silently compares "2" to 2.
    state_set "$dir" '
        .results += [{
            round: ($round | tonumber),
            alliance: $a,
            horde: $h,
            winner: $w,
            decidedBy: $d,
            recordedRound: .round
        }]
        | if   $w == "ALLIANCE" then .survivors.H |= map(select(. != $h))
          elif $w == "HORDE"    then .survivors.A |= map(select(. != $a))
          else . end
    ' --arg round "$round" --arg a "$ateam" --arg h "$hteam" \
      --arg w "$winner" --arg d "$decided"
}

state_advance_round() { # <run-dir>
    state_set "$1" '.round += 1'
}

state_finish() { # <run-dir> <status>
    state_set "$1" '.status = $s' --arg s "$2"
}
