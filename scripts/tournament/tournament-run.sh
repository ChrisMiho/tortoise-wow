#!/usr/bin/env bash
# Drive a whole bracket to a champion, resumably.
#
#   ./scripts/tournament/tournament-run.sh wsg-open
#   ./scripts/tournament/tournament-run.sh wsg-open --run-dir logs/tournament/friday
#
# One match is one invocation of match-run.sh; this script is the loop around it
# and the bookkeeping between matches. It never starts a battleground itself.
#
# Two properties are the whole point of the file, and everything else is in
# service of them:
#
#   * RESUME. A bracket is hours long, so it WILL be interrupted -- a crash, a
#     power cut, an operator stopping it, a stuck match. Every result is written
#     to state.json the moment it is known and before the next match starts, and
#     re-running against the same --run-dir picks up where it left off. Resume
#     matches on the PAIRING, not on a match index, so a half-finished round
#     resumes correctly rather than replaying from the top of the round.
#
#   * A DRAW MUST NOT STOP THE NIGHT. The 20-minute hard cap
#     (BattleGround.cpp:317-323) makes 0-0 ordinary for bot matches: of the 37
#     matches in bg.log as of 2026-08-16, 15 were draws -- 41%. A driver that
#     blocked on winner=NONE would stall roughly two rounds in five, unattended,
#     at 3am. So a draw is broken by the tiebreak ladder below.
#
# What a tiebreak is NOT is a win. state_record_result carries decidedBy, and a
# tiebroken match is recorded as tiebreak_score/tiebreak_deaths/tiebreak_seed,
# never as "server". The final report says how many matches the champion
# actually won and how many it was awarded. Blurring those two would claim wins
# the battleground never declared.
#
# Run from WSL: jq is not on Git Bash's PATH on this host.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/team.sh
. "$HERE/lib/team.sh"
# shellcheck source=lib/bracket.sh
. "$HERE/lib/bracket.sh"
# shellcheck source=lib/state.sh
. "$HERE/lib/state.sh"

# PlayerTeam as the telemetry sampler writes it (SharedDefines.h:230-231).
TEAM_ALLIANCE=469
TEAM_HORDE=67

usage() {
    echo "usage: tournament-run.sh <bracket-id> [--run-dir <dir>]" >&2
    exit 2
}

BRACKET="${1:-}"
[ -n "$BRACKET" ] || usage
case "$BRACKET" in -*) usage ;; esac
shift

RUN_DIR="$ROOT/logs/tournament/$BRACKET"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --run-dir) [ -n "${2:-}" ] || usage; RUN_DIR="$2"; shift 2 ;;
        *)         echo "unknown option: $1" >&2; usage ;;
    esac
done

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is not installed (run this from WSL, not Git Bash)" >&2; exit 2; }
[ -x "$HERE/match-run.sh" ] || { echo "FATAL: $HERE/match-run.sh is not executable" >&2; exit 2; }

mkdir -p "$RUN_DIR" || { echo "FATAL: cannot create run dir $RUN_DIR" >&2; exit 1; }

# Narration is timestamped and teed; terminal lines are not timestamped, because
# they are parsed. Both land in tournament.log so the file is the whole story.
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$RUN_DIR/tournament.log"; }
out() { printf '%s\n' "$*" | tee -a "$RUN_DIR/tournament.log"; }

# --- 0. the bracket ----------------------------------------------------------
# team.sh is sourced above, so this exercises team existence and faction too --
# a ladder naming a team that does not exist fails here, in a second, rather
# than an hour in when match-run.sh cannot find its roster.
bracket_validate "$BRACKET" || { echo "FATAL: bracket $BRACKET does not validate (faults above)" >&2; exit 1; }

state_init "$RUN_DIR" "$BRACKET" \
    "$(bracket_ladder "$BRACKET" A | tr '\n' ' ')" \
    "$(bracket_ladder "$BRACKET" H | tr '\n' ' ')" \
    || { echo "FATAL: could not initialise run state in $RUN_DIR" >&2; exit 1; }

STATE_FILE="$(state_file "$RUN_DIR")"
log "run directory: $RUN_DIR"

# bracket_rounds is log2 of the LADDER size: it counts the rounds one ladder
# takes to halve to one team. The bracket has two ladders, and their last two
# survivors still have to play each other, so a run is one round longer than
# that. 2+2 teams: bracket_rounds 1, two rounds actually played.
LADDER_ROUNDS="$(bracket_rounds "$BRACKET")"
EXPECTED_ROUNDS=$(( LADDER_ROUNDS + 1 ))

# --- resume ------------------------------------------------------------------
# By pairing, not by index. A round is a list of matches and an interruption can
# land between any two of them; keying on "have these two teams already played"
# is the only form that resumes a half-finished round to the right match. An
# index would replay or skip depending on where the crash landed.
#
# Losers are eliminated, so a pairing can never legitimately recur in a later
# round -- which is what makes the pair a safe key.
already_played() { # <alliance> <horde>
    local n
    n="$(jq -r --arg a "$1" --arg h "$2" \
            '[.results[] | select(.alliance == $a and .horde == $h)] | length' \
            < "$STATE_FILE")" || return 1
    [ "${n:-0}" -gt 0 ]
}

# A round's pairings come from the survivors AS THEY WERE WHEN THE ROUND
# STARTED, not from the survivors right now. The difference is the whole resume
# story: half way through a round some of this round's losers have already been
# eliminated, so pairing off the live survivor list produces lists of unequal
# length and the run stops with uneven_survivors -- on a run that is merely
# half finished, which is exactly the state an interruption leaves behind.
#
# So the round's losers are put back: everything the ladder holds that is either
# still surviving or was eliminated by a result recorded IN THIS ROUND. Filtering
# the ladder rather than appending keeps seed order, which positional pairing
# depends on.
round_survivors() { # <A|H> <round> -> team ids, space separated, in seed order
    local fac="$1" rnd="$2" ladder
    ladder="$(bracket_ladder "$BRACKET" "$fac" | tr '\n' ' ')" || return 1
    jq -r --arg f "$fac" --arg r "$rnd" --arg l "$ladder" '
        ($r | tonumber) as $rn
        | [ .results[] | select(.round == $rn)
            | if   .winner == "ALLIANCE" then .horde
              elif .winner == "HORDE"    then .alliance
              else empty end ] as $elim
        | (.survivors[$f] + $elim) as $keep
        | ($l | split(" ") | map(select(. != "")))
        | map(select(. as $t | $keep | index($t)))
        | join(" ")' < "$STATE_FILE"
}

# --- the MATCH line ----------------------------------------------------------
# Parsed by KEY, not by column. match-run.sh's last line is
#   MATCH alliance=... horde=... winner=... instance=... duration=... allianceScore=... hordeScore=...
# and a positional parse would break the first time a field is added -- silently,
# by reading a duration as a score.
match_field() { # <line> <key> -> the value, non-zero if the key is absent
    local -a toks=(); local t
    read -r -a toks <<< "$1"
    for t in "${toks[@]}"; do
        case "$t" in "$2="*) printf '%s\n' "${t#*=}"; return 0 ;; esac
    done
    return 1
}

is_int() { # accepts a leading minus, so the -1 "no score" sentinel parses
    case "${1:-}" in
        ""|-)  return 1 ;;
        -*)    case "${1#-}" in *[!0-9]*) return 1 ;; esac ;;
        *)     case "$1"      in *[!0-9]*) return 1 ;; esac ;;
    esac
    return 0
}

# --- the tiebreak ladder -----------------------------------------------------
# Walked only on winner=NONE, in order, stopping at the first rung that
# separates the two teams. Results land in TB_WINNER and TB_RUNG rather than on
# stdout, because every rung logs as it goes and a function that returned
# through stdout would swallow its own narration into the caller's $( ).

TB_WINNER=""
TB_RUNG=""

# Deaths, from the telemetry CSV artifact 027 writes next to the match:
# t,player,team,x,y,z,hp,maxhp,alive,combat, sorted by t then player, so each
# player's samples are already in time order. A death is an alive 1 -> 0
# transition; a battleground resurrection back to 1 makes the next 1 -> 0 count
# again, which is what "deaths" means here.
tb_deaths() { # <match-run-dir> -> "<allianceDeaths> <hordeDeaths>", non-zero if unusable
    local csv="$1/telemetry.csv"
    [ -s "$csv" ] || return 1
    awk -F, -v A="$TEAM_ALLIANCE" -v H="$TEAM_HORDE" '
        NR == 1 { next }                       # header
        NF < 9  { next }
        {
            p = $2; team = $3; alive = $9 + 0
            if ((p in prev) && prev[p] == 1 && alive == 0) d[team]++
            prev[p] = alive
            rows++
        }
        END {
            if (rows == 0) exit 1
            printf "%d %d\n", d[A] + 0, d[H] + 0
        }' "$csv"
}

tb_seed_index() { # <team-id> <A|H> -> 0-based position in its ladder
    local want="$1" fac="$2" i=0 t
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        [ "$t" = "$want" ] && { printf '%s\n' "$i"; return 0; }
        i=$(( i + 1 ))
    done < <(bracket_ladder "$BRACKET" "$fac")
    return 1
}

tiebreak() { # <ateam> <hteam> <allianceScore> <hordeScore> <match-run-dir>
    local ateam="$1" hteam="$2" as="$3" hs="$4" mdir="$5"
    local deaths ad hd ai hi
    TB_WINNER=""; TB_RUNG=""

    # Rung 1: higher score. In WSG the score IS flag captures, so this rung is
    # "who capped more". -1 is match-run.sh's "no score could be read" sentinel,
    # and treating it as a zero would decide a match on a number nobody measured.
    if is_int "$as" && is_int "$hs" && [ "$as" -ne -1 ] && [ "$hs" -ne -1 ] && [ "$as" -ne "$hs" ]; then
        if [ "$as" -gt "$hs" ]; then TB_WINNER="ALLIANCE"; else TB_WINNER="HORDE"; fi
        TB_RUNG="tiebreak_score"
        log "tiebreak $ateam vs $hteam: no winner declared; score $as-$hs -> $TB_WINNER (rung: higher score)"
        return 0
    fi
    log "tiebreak $ateam vs $hteam: score rung skipped (alliance=$as horde=$hs -- equal, or no score was readable)"

    # Rung 2: fewer deaths. Normally skipped: telemetry only exists when
    # Tournament.TelemetryIntervalMs is non-zero, and it is 0 by default.
    if deaths="$(tb_deaths "$mdir")"; then
        ad="${deaths%% *}"; hd="${deaths##* }"
        if [ "$ad" -ne "$hd" ]; then
            if [ "$ad" -lt "$hd" ]; then TB_WINNER="ALLIANCE"; else TB_WINNER="HORDE"; fi
            TB_RUNG="tiebreak_deaths"
            log "tiebreak $ateam vs $hteam: deaths $ad-$hd -> $TB_WINNER (rung: fewer deaths)"
            return 0
        fi
        log "tiebreak $ateam vs $hteam: deaths rung skipped (both sides died $ad times)"
    else
        log "tiebreak $ateam vs $hteam: deaths rung skipped (no usable $mdir/telemetry.csv -- the normal state with Tournament.TelemetryIntervalMs = 0)"
    fi

    # Rung 3: higher seed -- the earlier team in its own ladder. This rung must
    # always separate or an unattended run could still stall, so the equal-index
    # case is resolved for the Alliance seed rather than left open. Round one
    # pairs seed n against seed n, so that case is the common one, not a corner.
    ai="$(tb_seed_index "$ateam" A)" || ai=9999
    hi="$(tb_seed_index "$hteam" H)" || hi=9999
    if [ "$ai" -le "$hi" ]; then TB_WINNER="ALLIANCE"; else TB_WINNER="HORDE"; fi
    TB_RUNG="tiebreak_seed"
    log "tiebreak $ateam vs $hteam: seeds A#$(( ai + 1 )) vs H#$(( hi + 1 )) -> $TB_WINNER (rung: higher seed)"
    return 0
}

# --- the run's final report --------------------------------------------------
# A champion crowned entirely on tiebreaks is a legitimate outcome and not the
# same thing as one that won its matches. The report is where that difference is
# stated out loud, so nobody has to open state.json to find out.
report() { # [<champion team id>]
    local champ="${1:-}" total srv sc de se tb cw ct
    total="$(jq -r '.results | length' < "$STATE_FILE")"
    srv="$(jq -r '[.results[] | select(.decidedBy == "server")]          | length' < "$STATE_FILE")"
    sc="$(jq  -r '[.results[] | select(.decidedBy == "tiebreak_score")]  | length' < "$STATE_FILE")"
    de="$(jq  -r '[.results[] | select(.decidedBy == "tiebreak_deaths")] | length' < "$STATE_FILE")"
    se="$(jq  -r '[.results[] | select(.decidedBy == "tiebreak_seed")]   | length' < "$STATE_FILE")"
    tb=$(( sc + de + se ))
    out "TOURNAMENT-REPORT bracket=$BRACKET matches=$total outright=$srv tiebreak=$tb tiebreak_score=$sc tiebreak_deaths=$de tiebreak_seed=$se"

    [ -n "$champ" ] || return 0
    cw="$(jq -r --arg c "$champ" '[.results[]
            | select((.winner == "ALLIANCE" and .alliance == $c) or (.winner == "HORDE" and .horde == $c))
            | select(.decidedBy == "server")] | length' < "$STATE_FILE")"
    ct="$(jq -r --arg c "$champ" '[.results[]
            | select((.winner == "ALLIANCE" and .alliance == $c) or (.winner == "HORDE" and .horde == $c))
            | select(.decidedBy != "server")] | length' < "$STATE_FILE")"
    out "TOURNAMENT-REPORT bracket=$BRACKET champion=$champ won_outright=$cw won_on_tiebreak=$ct"
    if [ "${cw:-0}" -eq 0 ] && [ "${ct:-0}" -gt 0 ]; then
        out "TOURNAMENT-REPORT bracket=$BRACKET note=champion_won_no_match_outright"
    fi
}

rounds_played() { jq -r '[.results[].round] | max // 0' < "$STATE_FILE"; }

# --- the loop ----------------------------------------------------------------
while :; do
    round="$(state_get "$RUN_DIR" '.round')" || { echo "FATAL: run state is unreadable" >&2; exit 1; }
    # A round with no results recorded yet -- which is every round at its start,
    # and the state a finished bracket is left in -- reduces to the live
    # survivor lists, so the champion check below reads them correctly too.
    a="$(round_survivors A "$round")" || { echo "FATAL: run state is unreadable" >&2; exit 1; }
    h="$(round_survivors H "$round")" || { echo "FATAL: run state is unreadable" >&2; exit 1; }
    acount=0; for t in $a; do acount=$(( acount + 1 )); done
    hcount=0; for t in $h; do hcount=$(( hcount + 1 )); done
    log "round $round: alliance=[$a] horde=[$h]"

    # One side left standing and the other empty: that is a champion.
    if { [ "$acount" -eq 1 ] && [ "$hcount" -eq 0 ]; } || { [ "$hcount" -eq 1 ] && [ "$acount" -eq 0 ]; }; then
        champion="$a$h"
        state_finish "$RUN_DIR" "complete"
        report "$champion"
        out "TOURNAMENT-RUN bracket=$BRACKET champion=$champion rounds=$(rounds_played)"
        exit 0
    fi

    # Every pairing of this round is already recorded and the survivors still do
    # not resolve to a champion, round after round. Something in the state is
    # not advancing -- most often results recorded as winner=NONE by an older
    # driver, which eliminate nobody. Stop rather than spin.
    if [ "$round" -gt "$EXPECTED_ROUNDS" ]; then
        state_finish "$RUN_DIR" "blocked"
        report
        out "TOURNAMENT-RUN bracket=$BRACKET status=blocked reason=exceeded_expected_rounds"
        exit 1
    fi

    # Uneven survivors. Still reachable, and still a human's problem: the two
    # ladders can only be paired one-to-one, so if both round-one matches went to
    # the same faction there is no cross-faction opponent left for anyone. A
    # tiebreak cannot fix that -- it is the bracket's shape, not a missing result.
    if ! pairings="$(bracket_pairings "$BRACKET" "$a" "$h")"; then
        state_finish "$RUN_DIR" "blocked"
        report
        out "TOURNAMENT-RUN bracket=$BRACKET status=blocked reason=uneven_survivors(A=$acount,H=$hcount)"
        exit 1
    fi

    while IFS='|' read -r ateam hteam; do
        [ -n "$ateam" ] || continue
        if already_played "$ateam" "$hteam"; then
            log "skipping $ateam vs $hteam — already recorded"
            continue
        fi

        log "playing $ateam vs $hteam"
        mdir="$RUN_DIR/r${round}-${ateam}-vs-${hteam}"
        line="$("$HERE/match-run.sh" "$ateam" "$hteam" --run-dir "$mdir" | tail -1)"
        rc=$?
        # Both halves are logged, because a missing MATCH line is the interesting
        # failure and an empty log entry says nothing about why. match-run.sh's
        # own narration is in $mdir/match.log.
        log "match-run.sh exit=$rc, last line: ${line:-<no output>}"

        winner="$(match_field "$line" winner)" || winner=""
        case "$winner" in ALLIANCE|HORDE|NONE) ;; *) winner="" ;; esac

        # No MATCH line at all means the match did not happen -- assembly failed,
        # the population gate refused, a roster would not log in. There is
        # nothing to tiebreak between two teams that never played, so this fails
        # the run rather than awarding it to somebody.
        if [ -z "$winner" ]; then
            state_finish "$RUN_DIR" "failed"
            report
            out "TOURNAMENT-RUN bracket=$BRACKET status=failed reason=no_result($ateam vs $hteam)"
            exit 1
        fi

        decided="server"
        if [ "$winner" = "NONE" ]; then
            ascore="$(match_field "$line" allianceScore)" || ascore=-1
            hscore="$(match_field "$line" hordeScore)"    || hscore=-1
            tiebreak "$ateam" "$hteam" "$ascore" "$hscore" "$mdir"
            winner="$TB_WINNER"
            decided="$TB_RUNG"
        fi

        # Written the moment the result is known and BEFORE the next match
        # starts. This one line is what makes an interruption cost one match
        # instead of the night.
        state_record_result "$RUN_DIR" "$round" "$ateam" "$hteam" "$winner" "$decided" \
            || { echo "FATAL: could not record $ateam vs $hteam -- refusing to play on with unrecorded results" >&2; exit 1; }
        log "recorded $ateam vs $hteam: winner=$winner decidedBy=$decided"
    done <<< "$pairings"

    # Every pairing this round has a result. Advance, and let the top of the
    # loop decide whether that produced a champion.
    state_advance_round "$RUN_DIR" || { echo "FATAL: could not advance the round" >&2; exit 1; }
done
