#!/usr/bin/env bash
# Run exactly ONE tournament match, end to end, and say what happened in one line.
#
#   ./scripts/tournament/match-run.sh <allianceTeam> <hordeTeam> [--run-dir <dir>]
#
# The sequence below IS the script, in order: log every other team out; ensure
# and log in the two playing teams; gear gate; population gate; assemble; start;
# monitor; read the result; log both teams out; print the MATCH line. One
# invocation issues exactly one `tournament start` and never loops back for a
# second match -- driving a bracket is tournament-run.sh's job, not this one's.
#
# Exit 0 = a match was played and a result determined; a draw is a result. Exit
# 1 = the match could not be run at all. The one thing this script must never do
# is hang or finish without a MATCH line, so every path after the start emits
# one, including the deadline path.
#
# Three properties of this server make the obvious ad-hoc version wrong, and
# each of them is a branch below:
#
#   * A match is hard-capped at 20 minutes (BattleGround.cpp:317-323, custom to
#     this fork: EndBattleGround(GetWinningTeam()) once m_StartTime passes
#     20 * MINUTE). Bot matches frequently run the full clock, so "the clock
#     expired" is an ordinary outcome with a defined result, not a hang.
#   * A finished battleground is DESTROYED, so `result error=no_such_instance`
#     is the normal way a match ends. The winner then has to come out of the
#     line the server already wrote to bg.log.
#   * Only 20 tournament bots may be online at once, so the previous pairing has
#     to be logged out before this one is logged in -- and something has to
#     check that it actually happened.
#
# Run from WSL: jq is not on Git Bash's PATH on this host.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/team.sh
. "$HERE/lib/team.sh"
# shellcheck source=lib/ctl.sh
. "$HERE/lib/ctl.sh"
# shellcheck source=lib/artifacts.sh
. "$HERE/lib/artifacts.sh"
# shellcheck source=../../docs/playerbots/wsg/lib/wsg-bots-common.sh
. "$ROOT/docs/playerbots/wsg/lib/wsg-bots-common.sh"

BG_TYPE=2                 # BATTLEGROUND_WS (SharedDefines.h:1746); its map is 489
BG_MAP=489                # GetMapId(), which is what the "enters" line carries
LEVEL=60                  # only selects the bracket

# The 20-minute cap plus cleanup. Past this the match is stuck, not merely long.
MATCH_DEADLINE_S="${MATCH_DEADLINE_S:-1500}"
MATCH_POLL_S="${MATCH_POLL_S:-30}"
# A world port is not instant, and `add` only reports what was SENT.
MATCH_SETTLE_S="${MATCH_SETTLE_S:-20}"
# One attach carrying twenty commands needs the same room roster.sh gives it.
MATCH_BATCH_WAIT="${MATCH_BATCH_WAIT:-25}"
QUEUE_POP_DEADLINE_S="${QUEUE_POP_DEADLINE_S:-180}"

CHAR_DB="${CHAR_DB:-tw_char}"
DB_CONTAINER="${DB_CONTAINER:-tcm-db}"
BG_LOG="${BG_LOG:-$WSG_SERVER_ROOT/logs/bg.log}"

# How many characters outside the two rosters may be online. One, for a GM
# spectating. Not a tolerance for stray random bots -- see the gate.
MATCH_GM_ALLOWANCE="${MATCH_GM_ALLOWANCE:-1}"
# characters.online is written on save (PlayerSave.Interval, 60 s), so a bot the
# previous pairing just logged out can still read online=1 for a moment. Re-read
# past that interval before calling it a populated world; one stale read is not
# evidence of anything.
MATCH_POP_SETTLE_S="${MATCH_POP_SETTLE_S:-90}"

# ASSEMBLE_MODE -- direct or queue. THE CORRECT DEFAULT IS NOT KNOWN YET.
#
# It depends on whether a playerbot ever acknowledges a world port:
# BattleGround::AddPlayer runs in HandleMoveWorldPortAck (MovementHandler.cpp:209),
# not in the port itself (BattleGroundHandler.cpp:523-531), and a bot has a
# WorldSession with no client behind it. That is measurable and unmeasured -- see
# "World-port acknowledgement — measured" in
# docs/playerbots/TOURNAMENT-CONTROL-PLANE.md, which is still marked UNMEASURED.
# Both paths therefore ship. Do not delete either one, and do not change this
# default on anything short of that measurement being carried out and written
# down: `direct` is the better match (it names the instance, so concurrent
# matches stay possible) and `queue` is the one already proven to move bots.
ASSEMBLE_MODE="${ASSEMBLE_MODE:-direct}"

usage() {
    echo "usage: match-run.sh <allianceTeam> <hordeTeam> [--run-dir <dir>]" >&2
    exit 2
}

ATEAM="${1:-}"; HTEAM="${2:-}"
[ -n "$ATEAM" ] && [ -n "$HTEAM" ] || usage
case "$ATEAM" in -*) usage ;; esac
case "$HTEAM" in -*) usage ;; esac
shift 2

RUN_DIR="${WSG_RUN_ROOT:-$ROOT/logs/tournament/adhoc}"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --run-dir) [ -n "${2:-}" ] || usage; RUN_DIR="$2"; shift 2 ;;
        *)         echo "unknown option: $1" >&2; usage ;;
    esac
done
mkdir -p "$RUN_DIR" || { echo "FATAL: cannot create run dir $RUN_DIR" >&2; exit 1; }

# The default run dir is SHARED by every ad-hoc match, and nothing else ever
# removes this file, so a --mark that failed or a run that was aborted after the
# mark leaves an offset from a previous match sitting in it. Section 6b gates the
# capture on the file merely existing, so that stale offset does not take the
# skip branch -- it captures the PREVIOUS match's window and files it under this
# one. Clearing it here is what makes "the file exists" mean "this run marked it".
rm -f "$RUN_DIR/bots.offset" \
    || { echo "FATAL: cannot clear a stale $RUN_DIR/bots.offset" >&2; exit 1; }

# Everything narrating the run goes to stderr AND to match.log; stdout is left
# clean for the MATCH line and for the function that echoes the instance id.
# A log() that wrote to stdout would end up INSIDE "$(assemble_direct)".
log() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$RUN_DIR/match.log" >&2; }
# lib/artifacts.sh narrates through this, so its lines land in match.log too.
artifacts_log() { log "$*"; }

fatal() { log "FATAL: $*"; exit 1; }

match_is_int() { # <string> -- accepts an optional leading minus, so -1 parses
    case "${1:-}" in
        ""|-)  return 1 ;;
        -*)    case "${1#-}" in *[!0-9]*) return 1 ;; esac ;;
        *)     case "$1"      in *[!0-9]*) return 1 ;; esac ;;
    esac
    return 0
}

# Deliberately NOT wsg_mysql: that helper sends mysql's stderr to /dev/null, so
# a query that fails returns an empty string and reads exactly like "nobody is
# online" -- which is the one answer that would make the population gate wave a
# populated world through. Here the error reaches the operator and the status is
# checked. Same reasoning as gear-audit.sh.
match_query() { # <sql> -> rows on stdout, non-zero if mysql failed
    local pass
    pass="$(wsg_db_pass)"
    docker exec -e MYSQL_PWD="$pass" "$DB_CONTAINER" \
        mysql -uroot -N -B -e "$1" | tr -d '\r'
}

# One attach for many commands. Twenty attaches would be twenty chances to send
# the console an EOF, which mangosd reads as "shut down the world".
ctl_batch() { # <newline-separated commands> -> the TOURNAMENT lines they made
    local out prev="$CTL_WAIT"
    CTL_WAIT="$MATCH_BATCH_WAIT"
    out="$(ctl "$1")"
    CTL_WAIT="$prev"
    printf '%s\n' "$out"
}

bg_log_lines() { # -> how long bg.log is right now, 0 if unreadable
    if [ -r "$BG_LOG" ]; then wc -l < "$BG_LOG" | tr -d ' '; else echo 0; fi
}

# Only ever read the part of bg.log this run wrote. Instance ids are reused
# after a restart and the log is never truncated, so an unbounded grep can hand
# back a previous match's winner with total confidence.
bg_log_since() { # <baseline-line-count>
    [ -r "$BG_LOG" ] || return 0
    tail -n "+$(( $1 + 1 ))" "$BG_LOG"
}

# --- 0. the two teams --------------------------------------------------------

team_validate "$ATEAM" || fatal "$ATEAM does not validate"
team_validate "$HTEAM" || fatal "$HTEAM does not validate"

# Argument ORDER is part of the contract, not a convenience. Every match is
# Alliance versus Horde: SetBGTeam sets scoring and spawn side but not
# hostility, which resolves through the faction templates (Unit.cpp:5189), so a
# same-faction "match" is twenty bots standing around unable to fight each
# other. Refusing here is cheaper than watching that for twenty minutes.
[ "$(team_field "$ATEAM" '.faction')" = "A" ] \
    || fatal "$ATEAM is not an Alliance team; argument one must be faction A"
[ "$(team_field "$HTEAM" '.faction')" = "H" ] \
    || fatal "$HTEAM is not a Horde team; argument two must be faction H"
[ "$ATEAM" != "$HTEAM" ] || fatal "a team cannot play itself"

NAMES=()
while IFS= read -r n; do [ -n "$n" ] && NAMES+=("$n"); done < <(team_names "$ATEAM")
while IFS= read -r n; do [ -n "$n" ] && NAMES+=("$n"); done < <(team_names "$HTEAM")
# Ten bots a side by construction (TEAM_SLOTS in lib/team.sh), so twenty here.
MATCH_PLAYERS=20
[ "${#NAMES[@]}" -eq "$MATCH_PLAYERS" ] \
    || fatal "expected $MATCH_PLAYERS players, the two rosters name ${#NAMES[@]}"

ROSTER_LIST="$(printf '%s\n' "${NAMES[@]}")"

log "match $ATEAM (A) vs $HTEAM (H), run dir $RUN_DIR"

# Baseline before anything is assembled, so every later read of bg.log sees only
# this match's lines.
BG_BASE="$(bg_log_lines)"

# --- 1. swap rosters ---------------------------------------------------------

# Only the two playing teams may be online. Written as a case rather than
# `[ "$t" = "$A" ] || [ "$t" = "$B" ] && continue`: that line reads as "skip
# either of the two playing teams" and means "|| ( [ ... ] && continue )", so
# whether the alliance team is skipped depends on shell operator precedence
# rather than on what it says.
log "logging out every team that is not playing"
for f in "$TEAM_DIR"/*.json; do
    [ -e "$f" ] || continue
    t="$(basename "$f" .json)"
    case "$t" in
        "$ATEAM"|"$HTEAM") continue ;;
    esac
    log "  logout $t"
    "$HERE/roster.sh" logout "$t" >> "$RUN_DIR/roster.log" 2>&1 || true
done

log "bringing $ATEAM and $HTEAM online"
for t in "$ATEAM" "$HTEAM"; do
    "$HERE/roster.sh" ensure "$t" >> "$RUN_DIR/roster.log" 2>&1 \
        || fatal "$t could not be brought into existence -- see $RUN_DIR/roster.log"
done
for t in "$ATEAM" "$HTEAM"; do
    "$HERE/roster.sh" login "$t" >> "$RUN_DIR/roster.log" 2>&1 \
        || fatal "$t did not reach online=10/10 -- see $RUN_DIR/roster.log"
done

# --- 2. gear gate ------------------------------------------------------------
# A half-dressed team is a rigged match, and nothing else reports it: a bot with
# eight empty slots looks exactly like a success from the console.
for t in "$ATEAM" "$HTEAM"; do
    if "$HERE/gear-audit.sh" "$t" >> "$RUN_DIR/gear.log" 2>&1; then
        log "gear ok: $t"
        continue
    fi
    log "gear holes in $t -- applying its tier"
    [ -x "$HERE/gear-apply.sh" ] \
        || fatal "$t has gear holes and $HERE/gear-apply.sh is not there to fill them -- see $RUN_DIR/gear.log for which slots"
    "$HERE/gear-apply.sh" team "$t" >> "$RUN_DIR/gear.log" 2>&1 || true
    "$HERE/gear-audit.sh" "$t" >> "$RUN_DIR/gear.log" 2>&1 \
        || fatal "$t is still incomplete after re-gearing -- see $RUN_DIR/gear.log"
    log "gear ok after re-gearing: $t"
done

# --- 3. population gate ------------------------------------------------------
# Only the 20 bots playing this match may be online. This is a PRECONDITION
# check, not a repair: the script does not touch aiplayerbot.conf and does not
# restart mangosd, because either would change the world mid-run. A populated
# world changes the match -- bot AI is single-core, and a random pool sharing it
# slows every bot in the battleground -- so failing here is the correct outcome
# and the fix is upstream, in the alive-world config.
log "population gate: only the ${MATCH_PLAYERS} playing bots may be online (GM allowance $MATCH_GM_ALLOWANCE)"
pop_deadline=$(( $(date +%s) + MATCH_POP_SETTLE_S ))
while :; do
    if ! online_rows="$(match_query "SELECT name FROM ${CHAR_DB}.characters WHERE online = 1 ORDER BY name;")"; then
        fatal "the online-character query failed against $DB_CONTAINER (error above); that is NOT the same as an empty world, so nothing is concluded from it"
    fi

    # The full list goes into match.log every time it is read: when a match turns
    # out strange afterwards, who else was in the world is the first question.
    outsiders=""; onl=0; mine=0
    while IFS= read -r nm; do
        [ -n "$nm" ] || continue
        onl=$((onl + 1))
        case $'\n'"$ROSTER_LIST"$'\n' in
            *$'\n'"$nm"$'\n'*) mine=$((mine + 1)) ;;
            *) outsiders="${outsiders:+$outsiders }$nm" ;;
        esac
    done <<< "$online_rows"

    n_out=0
    for nm in $outsiders; do n_out=$((n_out + 1)); done
    log "online=$onl playing=$mine/$MATCH_PLAYERS other=$n_out${outsiders:+ [$outsiders]}"

    [ "$n_out" -le "$MATCH_GM_ALLOWANCE" ] && break

    if [ "$(date +%s)" -ge "$pop_deadline" ]; then
        fatal "$n_out character(s) outside the two rosters are online after ${MATCH_POP_SETTLE_S}s: $outsiders -- the random bot pool is not off. Turn it off in aiplayerbot.conf and restart mangosd BEFORE running a match; this script will not do it mid-run."
    fi
    log "  still settling (characters.online lags up to 60s on save) -- re-reading"
    sleep 15
done

# --- 4. assemble -------------------------------------------------------------

# `add` reports what was SENT; `members` reports what the battleground HOLDS.
# The two are not redundant -- a run where every add says sent=1 and members
# says count=0 is a match that never starts, never scores and never ends, with
# nothing in the output that looks like an error.
assemble_direct() {
    local inst lines="" nm out sent held
    inst="$(ctl_create "$BG_TYPE" "$LEVEL")" || return 1
    log "instance $inst created"

    for nm in "${NAMES[@]}"; do
        lines="${lines}tournament add $inst $nm"$'\n'
    done
    out="$(ctl_batch "$lines")"
    printf '%s\n' "$out" >> "$RUN_DIR/assemble.log"
    sent="$(printf '%s\n' "$out" | grep -c 'sent=1')"
    log "sent $sent/${MATCH_PLAYERS} adds to instance $inst"

    sleep "$MATCH_SETTLE_S"

    held="$(ctl_field "$(ctl "tournament members $inst")" count)"
    match_is_int "$held" || held=0
    log "instance $inst holds $held player(s)"
    if [ "$held" -lt "$MATCH_PLAYERS" ]; then
        log "only $held/${MATCH_PLAYERS} players entered -- below a full twenty this is not the match the bracket asked for"
        [ "$sent" -ge "$MATCH_PLAYERS" ] && log "every add reported sent=1 and the battleground holds $held: that is the documented world-port acknowledgement failure. Re-run with ASSEMBLE_MODE=queue rather than editing this script."
        return 1
    fi

    printf '%s\n' "$inst"
}

# The measured path: BGJoinAction::Execute reads AI_VALUE(uint32, "bg type") and
# skips bgList entirely when it is non-zero, so setting it to 2 and commanding a
# join queues the bot for Warsong Gulch deterministically. All forty lines go in
# ONE attach.
assemble_queue() {
    local names lines inst="" deadline
    names="$(printf '%s ' "${NAMES[@]}")"
    # shellcheck disable=SC2086
    lines="$(wsg_bgjoin_lines $names)"
    wsg_console "$lines" "$MATCH_BATCH_WAIT" >> "$RUN_DIR/assemble.log" 2>&1

    # The pop lands in bg.log as "[489,<instance>]: <name>:<guid> [...] enters"
    # (BattleGroundHandler.cpp:533 -- that line carries the MAP, 489, where the
    # end-of-match line carries the TYPE, 2).
    deadline=$(( $(date +%s) + QUEUE_POP_DEADLINE_S ))
    while :; do
        inst="$(bg_log_since "$BG_BASE" | grep -a "\[$BG_MAP," | tail -1 \
                | sed -n "s/.*\[$BG_MAP,\([0-9]*\)\].*/\1/p")"
        [ -n "$inst" ] && break
        if [ "$(date +%s)" -ge "$deadline" ]; then
            log "no Warsong pop in $BG_LOG within ${QUEUE_POP_DEADLINE_S}s"
            return 1
        fi
        sleep 10
    done
    log "queue popped instance $inst"
    printf '%s\n' "$inst"
}

# Mark bots.log HERE, not at the top of the script: everything above is roster
# churn -- logging twenty bots out and twenty more in -- and that chatter is not
# the match. The offset has to be the last thing taken before the players are
# assembled, or the capture is padded with the previous pairing's logout trace.
#
# Non-fatal, like every artifact step in this script. A missing offset file
# costs a bots-match.log; it must not cost a match that was actually played.
"$HERE/bot-log-capture.sh" --mark "$RUN_DIR/bots.offset" >> "$RUN_DIR/match.log" 2>&1 \
    || log "could not mark bots.log -- no bot log capture for this match"

log "assembling (ASSEMBLE_MODE=$ASSEMBLE_MODE)"
case "$ASSEMBLE_MODE" in
    direct) INST="$(assemble_direct)" || fatal "assembly failed" ;;
    queue)  INST="$(assemble_queue)"  || fatal "assembly failed" ;;
    *)      fatal "ASSEMBLE_MODE must be direct or queue, got '$ASSEMBLE_MODE'" ;;
esac
[ -n "$INST" ] || fatal "assembly produced no instance id"

# --- 5. start ----------------------------------------------------------------
# Exactly one start, and the only one in this script. `start` does not call a
# start method -- it collapses the countdown with SetStartDelayTime(0), which is
# what .bg start does and what the countdown IS.
ctl "tournament start $INST" >> "$RUN_DIR/match.log"
START_TS="$(date +%s)"
log "match started, instance $INST"

# --- 5b. viewer effect consumer ----------------------------------------------
# Started HERE, immediately after `tournament start`, and killed the moment the
# monitor loop breaks. That window is deliberately exactly the match: the queue
# is append-only and outlives any single match, so a consumer still draining
# after section 7 has logged the rosters out would apply the next queued effect
# to the FOLLOWING pairing's bots -- a viewer's kill landing on a team that was
# never targeted. effect-consume.sh does reject a team that is not one of the two
# it was started with, but that check alone does not stop it from being handed the
# next match's two teams' worth of queued commands. Two things do: this process's
# lifetime, and the ledger seeded below.
EFFECT_QUEUE="${EFFECT_QUEUE:-$RUN_DIR/effects.ndjson}"
# The consumer's dedupe ledger and cap counters. Per match, deliberately: the
# caps in TOURNAMENT-VIEWER-EFFECTS.md are per-match allowances and must reset
# when the match does. That reset is also what makes the seeding below necessary.
EFFECT_STATE="$RUN_DIR/effects"
# Create the queue if it is not there. The consumer reads it line by line and a
# zero-line file drains to nothing, so a match with no viewer activity then takes
# exactly the same path as one with it, instead of a path where the consumer
# starts by tripping over a missing file.
mkdir -p "$(dirname "$EFFECT_QUEUE")" && : >> "$EFFECT_QUEUE" \
    || log "cannot create effect queue $EFFECT_QUEUE -- viewer effects are off for this match"

# Killing the process at the end of the match is only HALF of "the consumer never
# crosses into the next match", and the missing half is the one that is easy to
# miss: the ledger that makes an effect fire exactly once is applied.txt under
# --state, which is per-match, while EFFECT_QUEUE may name one long-lived file
# shared by every match in a bracket -- that override exists precisely so a single
# viewer adapter can append to one queue all night. Put those together and the
# next match's consumer would start with an EMPTY applied.txt and re-read the
# append-only queue FROM THE TOP: every command an earlier match already handled,
# unhandled again. Neither of the consumer's safety checks stops that -- the team
# check passes whenever the targeted team is playing again, which in a bracket is
# the ordinary case, and Player::InBattleGround() passes because the bots ARE in a
# battleground, just not the one the command was aimed at.
#
# Both halves -- the lifetime and the ledger -- are in lib/effect-runner.sh, and
# the traps that make the lifetime hold on every exit path come from there too.
# shellcheck source=lib/effect-runner.sh
. "$HERE/lib/effect-runner.sh"
effect_consumer_install_traps

if [ -x "$HERE/effect-consume.sh" ]; then
    effect_consumer_start "$HERE/effect-consume.sh" "$ATEAM" "$HTEAM" \
        "$RUN_DIR/effects.log" 5
else
    # The consumer ships separately from this file. Its absence is "no viewer
    # effects today", not a match that cannot be played.
    log "$HERE/effect-consume.sh is not present -- no viewer effects for this match"
fi

# --- 6. monitor --------------------------------------------------------------
# Poll the RESULT, not the clock. A finished battleground is destroyed, so
# `result error=no_such_instance` is the ordinary end of a match and the score
# then has to come from bg.log.
#
# The two scores are load-bearing: the bracket driver tiebreaks a winner=NONE on
# them. They carry the last score actually read while the instance existed, and
# -1/-1 -- which `tournament result` already uses for "not exposed" -- when none
# could be read at all. Zeros here would be indistinguishable from a real 0-0
# draw and would silently decide a tie the wrong way.
WINNER=""
ASCORE=-1
HSCORE=-1
while :; do
    out="$(ctl "tournament result $INST")"
    printf '%s\n' "$out" >> "$RUN_DIR/match.log"
    err="$(ctl_field "$out" error)"

    if [ -z "$err" ]; then
        st="$(ctl_field "$out" status)"
        w="$(ctl_field "$out" winner)"
        a="$(ctl_field "$out" allianceScore)"
        h="$(ctl_field "$out" hordeScore)"
        # Both or neither: a half-updated pair would report one team's score
        # from this read and the other's from a read minutes older.
        if match_is_int "$a" && match_is_int "$h"; then
            ASCORE="$a"; HSCORE="$h"
        fi
        if [ "$st" = "WaitLeave" ]; then
            case "$w" in
                ALLIANCE|HORDE|NONE) WINNER="$w" ;;
                *) log "status=WaitLeave with winner='$w', which is none of ALLIANCE/HORDE/NONE -- recording NONE"
                   WINNER="NONE" ;;
            esac
            log "result read from the live instance: winner=$WINNER alliance=$ASCORE horde=$HSCORE"
            break
        fi
    else
        # Gone, which is how a match normally ends. EndBattleGround wrote
        # "[<type>,<inst>]: winner=<n>" to bg.log (BattleGround.cpp:242);
        # 0=HORDE 1=ALLIANCE 2=NONE (BattleGround.h:187-189).
        log "instance $INST is gone ($err) -- reading the winner out of $BG_LOG"
        code="$(bg_log_since "$BG_BASE" | grep -a "\[$BG_TYPE,$INST\]: winner=" | tail -1 \
                | sed -n 's/.*winner=\([0-9]*\).*/\1/p')"
        case "${code:-}" in
            0) WINNER="HORDE" ;;
            1) WINNER="ALLIANCE" ;;
            2) WINNER="NONE" ;;
            *) log "no '[$BG_TYPE,$INST]: winner=' line in $BG_LOG -- recording NONE"
               WINNER="NONE" ;;
        esac
        log "result read from bg.log: winner=$WINNER (code=${code:-none}) alliance=$ASCORE horde=$HSCORE"
        break
    fi

    if [ $(( $(date +%s) - START_TS )) -ge "$MATCH_DEADLINE_S" ]; then
        # Past the 20-minute cap plus cleanup the battleground should have ended
        # itself. It did not, so stop it rather than leave it holding twenty bots.
        log "match exceeded ${MATCH_DEADLINE_S}s without a result -- stopping instance $INST"
        ctl "tournament stop $INST" >> "$RUN_DIR/match.log"
        WINNER="NONE"
        break
    fi

    # effect_sleep, not sleep: this is the one long wait with a consumer running,
    # and a trap fires only once the foreground command finishes. A plain sleep
    # would leave a SIGTERM unhandled -- and the consumer draining -- for the rest
    # of the poll interval. See lib/effect-runner.sh.
    effect_sleep "$MATCH_POLL_S"
done

# The FIRST thing after the loop, ahead of the artifact collection and well ahead
# of section 7's logout: the match is decided, so nothing else may be applied to
# these twenty bots, and in a few seconds they will not be in a battleground at
# all. Every path out of the loop above -- a live result, a destroyed instance,
# the deadline -- reaches this line.
effect_consumer_stop

DURATION=$(( $(date +%s) - START_TS ))

# --- 6b. artifacts -----------------------------------------------------------
# The evidence has to be collected NOW, between the result and the logout: the
# next match's population gate starts by logging these twenty bots out, and
# bots.log keeps growing the whole time (~87 MB/min measured 2026-08-18), so
# every minute of delay is another minute of unrelated trace inside the capture
# window -- and one more chance of crossing the 5-minute rotation that would
# throw the older part of it away.
#
# EVERY LINE BELOW IS NON-FATAL. The match has already been played and decided;
# a missing telemetry sample is a missing artifact, not a void result, and a
# script that exited 1 here would tell the bracket driver the match never
# happened. Failures are logged and dropped.
# telemetry-report.sh exits 1 when a bot is stuck or fewer than twenty entered.
# That is a finding about the bots, not a failure of this run -- but only when the
# script actually ran, which is why the branching lives in lib/artifacts.sh and is
# tested there.
telemetry_artifacts "$HERE" "$RUN_DIR" "$INST"

if [ -f "$RUN_DIR/bots.offset" ]; then
    "$HERE/bot-log-capture.sh" --since "$RUN_DIR/bots.offset" \
        --team "$ATEAM" --team "$HTEAM" --out "$RUN_DIR/bots-match.log" \
        >> "$RUN_DIR/match.log" 2>&1 \
        || log "bot log capture failed -- see $RUN_DIR/match.log"
else
    log "no bots.offset was recorded -- skipping bot log capture"
fi

# --- 7. log both teams out ---------------------------------------------------
# The next match starts from a clean roster, or its own population gate fails.
for t in "$ATEAM" "$HTEAM"; do
    "$HERE/roster.sh" logout "$t" >> "$RUN_DIR/roster.log" 2>&1 || true
done

printf 'MATCH alliance=%s horde=%s winner=%s instance=%s duration=%s allianceScore=%s hordeScore=%s\n' \
    "$ATEAM" "$HTEAM" "$WINNER" "$INST" "$DURATION" "$ASCORE" "$HSCORE" \
    | tee -a "$RUN_DIR/match.log"
exit 0
