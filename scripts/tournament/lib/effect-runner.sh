#!/usr/bin/env bash
# The viewer-effect consumer's LIFETIME: start it for one match, and end it hard
# when that match ends. Source, don't execute.
#
# Split out of match-run.sh because every line here is about process groups and
# signals -- the one part of the match sequence a live match cannot exercise
# cheaply and a stub consumer can, in tests/tournament/effect-runner.test.sh. The
# policy (WHY a consumer must never cross into the next match) stays at the call
# site in match-run.sh; the mechanics live here.
#
# The guarantee this file owes its caller: once effect_consumer_stop has
# returned, nothing started by the consumer can still deliver an effect. Not the
# consumer, and not the `docker exec`/console attach it had in flight when the
# signal landed -- that child is a process of its own, and killing only the
# consumer's pid leaves it alive to write into a battleground the script has
# already declared finished.

# Inputs, set by the caller before effect_consumer_start:
#   EFFECT_QUEUE  the NDJSON queue to read (may be shared across matches)
#   EFFECT_STATE  this match's state dir (applied.txt, counts.txt)
EFFECT_PID=""
EFFECT_PGID=""
# How long the group gets to die of SIGTERM before it is SIGKILLed. A console
# attach in flight is a `docker exec` that exits on its own within a second or
# two; anything still standing after this was never going to stop politely.
EFFECT_STOP_GRACE_S="${EFFECT_STOP_GRACE_S:-5}"

# match-run.sh has its own timestamping log() into match.log. A test sourcing
# this file has none, and a missing function must not be what ends the run.
effect_log() {
    if declare -F log >/dev/null 2>&1; then log "$@"; else printf '%s\n' "$*" >&2; fi
}

effect_pgid_of() { # <pid> -> its process group id, or nothing
    ps -o pgid= -p "$1" 2>/dev/null | tr -d ' '
}

# Deliberately `ps -eo pgid=` and not `pgrep -g`: pgrep is procps-only, and this
# is the check that decides whether an effect can still be delivered.
effect_group_alive() { # <pgid> -> 0 while any process is still in that group
    [ -n "${1:-}" ] || return 1
    ps -eo pgid= 2>/dev/null | tr -d ' ' | grep -qx "$1"
}

# Record every id already sitting in the queue as handled, before the consumer's
# first pass.
#
# EFFECT_STATE is per match by design -- the caps in TOURNAMENT-VIEWER-EFFECTS.md
# are per-match allowances -- and applied.txt lives inside it, so a fresh match
# starts with an empty ledger while EFFECT_QUEUE may be one long-lived file the
# viewer adapter appends to all night. Without this seeding the next match's
# consumer re-reads that append-only queue FROM THE TOP and re-applies every
# command an earlier match already handled: a kill_team bought in round one fires
# again, for free, in round three, and both of the consumer's safety checks wave
# it through (the team is playing again, and the bots are in a battleground --
# just not the one the command was aimed at).
#
# This uses the consumer's own mechanism rather than a new one: applied.txt is one
# bare id per line, tested with `grep -qx`, so effect-consume.sh needs no flag and
# no change. An effect is aimed at a LIVE match; anything queued before this one
# started was aimed at a different match or at no match at all, and nothing in the
# line says which, so dropping it is the only safe reading. Lines appended from
# here on -- the ones a viewer is producing while watching THIS match -- are
# untouched.
effect_seed_applied() { # -> 0 once the ledger covers everything already queued
    local ids n
    mkdir -p "$EFFECT_STATE" || return 1
    # -R with fromjson? so one malformed line cannot abort the scan and take every
    # id after it with it; the consumer skips such a line too. `.id? // empty`
    # drops a line that carries no id, which the consumer also ignores.
    ids="$(jq -R -r 'fromjson? | .id? // empty' "$EFFECT_QUEUE")" || return 1
    n="$(printf '%s\n' "$ids" | grep -c .)"
    if [ -n "$ids" ]; then
        printf '%s\n' "$ids" >> "$EFFECT_STATE/applied.txt" || return 1
    fi
    effect_log "queue $EFFECT_QUEUE held $n command(s) before this match -- recorded as already handled in $EFFECT_STATE/applied.txt"
    return 0
}

effect_consumer_start() { # <consumer-script> <allianceTeam> <hordeTeam> <log-file> [interval]
    local consumer="$1" ateam="$2" hteam="$3" logfile="$4" interval="${5:-5}"
    # Before the consumer, never after: it drains on its very first pass, so a
    # ledger seeded a moment too late is a ledger that seeded nothing.
    effect_seed_applied \
        || effect_log "WARNING: could not read $EFFECT_QUEUE to seed $EFFECT_STATE/applied.txt -- if EFFECT_QUEUE is shared between matches, an earlier match's effects may replay onto these bots"
    # `set -m` for exactly this one launch, and off again immediately. Job control
    # is what puts a background child in its OWN process group (pgid == $!);
    # without it the consumer shares this script's group, and the group kill in
    # effect_consumer_stop would be a kill on this script. Nothing else in the
    # match sequence wants job control.
    set -m
    "$consumer" --queue "$EFFECT_QUEUE" --alliance "$ateam" --horde "$hteam" \
        --state "$EFFECT_STATE" --interval "$interval" >> "$logfile" 2>&1 &
    EFFECT_PID=$!
    set +m
    EFFECT_PGID="$(effect_pgid_of "$EFFECT_PID")"
    # A pgid equal to ours means the launch did not get its own group after all
    # (job control unavailable). Blank it rather than remember it: stop() then
    # signals the single pid, which is weaker but survivable, where a group kill
    # on our own group would take the match down mid-run.
    if [ -z "$EFFECT_PGID" ] || [ "$EFFECT_PGID" = "$(effect_pgid_of $$)" ]; then
        EFFECT_PGID=""
        effect_log "WARNING: the effect consumer did not get its own process group -- an in-flight console attach may outlive the stop"
    fi
    effect_log "effect consumer started (pid $EFFECT_PID, pgid ${EFFECT_PGID:-shared}), queue $EFFECT_QUEUE, state $EFFECT_STATE, log $logfile"
}

# Idempotent, and safe to call when the consumer never started or has already
# exited: killing a reaped pid is only an error if it is treated as one.
effect_consumer_stop() {
    # The monitor loop's interruptible sleep, if a signal caught us inside one.
    # Reaped here rather than left to expire because it holds this script's
    # stdout open, and stdout is what the bracket driver reads the MATCH line
    # from -- see effect_sleep below.
    if [ -n "${EFFECT_SLEEP_PID:-}" ]; then
        kill "$EFFECT_SLEEP_PID" 2>/dev/null || true
        EFFECT_SLEEP_PID=""
    fi
    [ -n "$EFFECT_PID" ] || return 0
    local pid="$EFFECT_PID" pgid="$EFFECT_PGID" scope deadline
    # Cleared FIRST, before anything can block: this function runs from a signal
    # handler AND again from the EXIT trap that handler's re-raise reaches, and
    # the second pass has to be a no-op rather than a second kill aimed at a pid
    # the kernel may by then have handed to something else entirely.
    EFFECT_PID=""; EFFECT_PGID=""
    if [ -n "$pgid" ]; then
        scope="group $pgid"
        kill -TERM "-$pgid" 2>/dev/null || true
    else
        scope="pid $pid"
        kill -TERM "$pid" 2>/dev/null || true
    fi
    # `wait` returns the moment the CONSUMER is reaped, which says nothing about
    # the `docker exec` it had in flight -- that child is not ours to wait on and
    # is reparented to init the instant its parent dies. The group is what has to
    # go quiet, so poll the group and escalate.
    wait "$pid" 2>/dev/null || true
    if [ -n "$pgid" ]; then
        deadline=$(( $(date +%s) + EFFECT_STOP_GRACE_S ))
        while effect_group_alive "$pgid"; do
            if [ "$(date +%s)" -ge "$deadline" ]; then
                effect_log "effect consumer group $pgid ignored SIGTERM for ${EFFECT_STOP_GRACE_S}s -- SIGKILL"
                kill -KILL "-$pgid" 2>/dev/null || true
                sleep 1
                break
            fi
            sleep 1
        done
    fi
    effect_log "effect consumer stopped ($scope)"
}

# A sleep the traps above can actually cut short.
#
# bash runs a trap for a caught signal only when the FOREGROUND command finishes,
# and `sleep 30` is a foreground external command: a SIGTERM arriving one second
# into the monitor loop's poll would otherwise sit unhandled for the remaining
# 29 while the consumer went on draining. `wait` is a builtin, and a trapped
# signal interrupts it at once -- so the monitor loop sleeps on a background
# child instead, and a terminating runner is obeyed immediately.
#
# The redirections are not tidiness. tournament-run.sh reads this script through
# `line="$(match-run.sh ... | tail -1)"`, and a command substitution returns only
# when EVERY writer has closed the pipe -- so a background sleep holding an
# inherited stdout would stall the bracket driver for the rest of the interval
# after the match had already printed its MATCH line. It gets no pipe to hold.
# Its pid is remembered so the stop path can reap it as well; a trap interrupts
# `wait` and never reaches the kill below.
EFFECT_SLEEP_PID=""
effect_sleep() { # <seconds>
    sleep "$1" >/dev/null 2>&1 </dev/null &
    EFFECT_SLEEP_PID=$!
    wait "$EFFECT_SLEEP_PID" 2>/dev/null || true
    kill "$EFFECT_SLEEP_PID" 2>/dev/null || true
    EFFECT_SLEEP_PID=""
}

effect_consumer_trap() { # <signal-name>
    local sig="$1"
    effect_consumer_stop
    # Re-raise with the default disposition rather than exiting here, so the exit
    # status still says which signal ended the run -- a bracket driver reading $?
    # sees 143 for SIGTERM, not a 0 that reads like a match played to a result.
    # The EXIT trap fires on the way out; effect_consumer_stop is idempotent.
    trap - "$sig"
    kill -"$sig" $$
}

# EXIT alone is not enough, which is the whole reason this function exists. A
# non-interactive bash with no TERM handler dies on SIGTERM WITHOUT running its
# EXIT trap, so a tournament runner terminating match-run.sh would orphan the
# consumer to keep draining into the following match. SIGINT needs a handler for
# the mirror-image reason: the consumer now runs in its own process group, so a
# terminal Ctrl-C no longer reaches it the way it used to by accident.
#
# What EXIT actually covers in match-run.sh is narrower than it looks, and worth
# stating exactly because the comment this replaces got both halves wrong:
#   - the deadline path does NOT exit. It `break`s the monitor loop like every
#     other outcome and falls into the explicit effect_consumer_stop below it, so
#     EXIT finds nothing left to do there;
#   - every `fatal` in match-run.sh is upstream of the consumer's start, so no
#     `fatal` can reach EXIT with a consumer running either.
# EXIT's real job is the plain end of the script -- belt to the explicit stop's
# braces, and cover for any `fatal` a future edit adds after section 5b. These
# are the ONLY traps in match-run.sh; a later `trap ... EXIT` there would REPLACE
# this one rather than chain with it, so anything else needing to run at exit
# belongs inside effect_consumer_stop.
effect_consumer_install_traps() {
    trap 'effect_consumer_stop' EXIT
    trap 'effect_consumer_trap TERM' TERM
    trap 'effect_consumer_trap HUP' HUP
    trap 'effect_consumer_trap INT' INT
}
