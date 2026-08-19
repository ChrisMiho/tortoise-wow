#!/usr/bin/env bash
# Keep a spectator on the action for the duration of ONE match.
#
#   ./scripts/tournament/spectate.sh --spectator Astral --instance 101 \
#       [--interval 15] [--height 25] [--max-minutes 25]
#
# Replaces running `tournament camera` by hand every fifteen seconds for twenty
# minutes -- and, more importantly, replaces having to notice when to stop.
#
# THIS PRODUCES BROADCAST-STYLE *CUTS*, NOT SMOOTH TRACKING. The only
# server-side camera control that exists is teleportation: `tournament camera`
# calls TeleportTo, and there is no API to rotate a client's view. The camera
# jumps to each new point of interest and holds there until the next cut. See
# docs/playerbots/TOURNAMENT-STREAMING.md.
#
# THE ONE-TIME IN-GAME SETUP INCLUDES THE CAMERA ITSELF. Before starting this
# script, logged in as the GM (rank=4 -- .hover and .bgtest are refused at
# rank=3 because SEC_GAMEMASTER is #defined to SEC_ADMINISTRATOR=4):
#
#   .gm on
#   .gm visible off
#   .hover 1
#   .god on
#   ...and then, WITH THE MOUSE: pitch the view downward and zoom out.
#
# That last line is not optional and nothing here can do it for you.
# `tournament camera` teleports the spectator to the point of interest plus a
# height offset (--height, 25 yards by default) while PRESERVING the player's
# orientation, and camera *pitch* cannot be set server-side at all. Skip the
# manual pitch and this director works perfectly while every single shot is of
# the horizon -- the difference between automation that works and automation
# that appears to.
#
# Never party the spectator to a bot: HasActivePlayerMaster() is a hard gate in
# BattleGroundJoinAction.cpp:568 and a partied bot never queues again. The
# spectator is also not a battleground member -- `tournament camera` refuses a
# match participant, because enrolling the camera would make the match 11v10.
#
# Exit 0 = the match ended and the director stopped with it. Exit 1 = it stopped
# for a reason that wants looking at (an unexpected error, or the time budget).
# Either way the last line on stdout is the SPECTATE summary.
#
# Run from WSL. `ctl()` sends every console command through `wsg_console`, which
# wraps `docker attach` in util-linux `script` for a pty
# (docs/playerbots/wsg/lib/wsg-bots-common.sh:106); Git Bash ships no `script`,
# so the whole pipeline dies on the first cut.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

# CTL_STUB is the test seam, and it replaces lib/ctl.sh rather than loading
# alongside it: the real ctl() reaches for wsg_console, so sourcing it would tie
# tests/tournament/spectate.test.sh to a running container for no benefit.
if [ -n "${CTL_STUB:-}" ]; then
    # shellcheck source=/dev/null
    . "$CTL_STUB"
else
    # shellcheck source=lib/ctl.sh
    . "$HERE/lib/ctl.sh"
    # shellcheck source=../../docs/playerbots/wsg/lib/wsg-bots-common.sh
    . "$ROOT/docs/playerbots/wsg/lib/wsg-bots-common.sh"
fi

SPECTATOR=""; INSTANCE=""; INTERVAL=15; HEIGHT=25; MAXMIN=25

usage() {
    echo "usage: spectate.sh --spectator <name> --instance <id> [--interval 15] [--height 25] [--max-minutes 25]" >&2
    exit 2
}

is_uint() { # <string>
    case "${1:-}" in
        ""|*[!0-9]*) return 1 ;;
    esac
    return 0
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --spectator)   [ -n "${2:-}" ] || usage; SPECTATOR="$2"; shift 2 ;;
        --instance)    [ -n "${2:-}" ] || usage; INSTANCE="$2";  shift 2 ;;
        --interval)    [ -n "${2:-}" ] || usage; INTERVAL="$2";  shift 2 ;;
        --height)      [ -n "${2:-}" ] || usage; HEIGHT="$2";    shift 2 ;;
        --max-minutes) [ -n "${2:-}" ] || usage; MAXMIN="$2";    shift 2 ;;
        *) echo "unknown arg: $1" >&2; usage ;;
    esac
done

[ -n "$SPECTATOR" ] && [ -n "$INSTANCE" ] || usage
# Checked rather than trusted: a non-numeric --interval would make the `-gt`
# below an error on every pass and the loop would spin flat out, hammering the
# console instead of polling it.
is_uint "$INSTANCE" || { echo "--instance must be a number, got '$INSTANCE'" >&2; exit 2; }
is_uint "$INTERVAL" || { echo "--interval must be a whole number of seconds, got '$INTERVAL'" >&2; exit 2; }
is_uint "$HEIGHT"   || { echo "--height must be a whole number of yards, got '$HEIGHT'" >&2; exit 2; }
is_uint "$MAXMIN"   || { echo "--max-minutes must be a whole number of minutes, got '$MAXMIN'" >&2; exit 2; }

# A match is hard-capped at 20 minutes (BattleGround.cpp:317-323, custom to this
# fork), so the ordinary end of this loop is the instance disappearing. The
# budget is only the backstop for an instance that somehow never does -- without
# it the director teleports a spectator around an empty map for the next hour.
deadline=$(( $(date +%s) + MAXMIN * 60 ))
repositions=0
lastreason=""
silent_reported=0
rc=0

while :; do
    out="$(ctl "tournament camera $SPECTATOR $INSTANCE $HEIGHT")"
    err="$(ctl_field "$out" error)"

    if [ -n "$err" ]; then
        case "$err" in
            # Not a failure. A finished battleground is DESTROYED, so this is
            # what the end of a match looks like from out here -- and it is the
            # signal the whole loop is waiting for.
            no_such_instance*)
                echo "match over (instance $INSTANCE is gone)"
                ;;
            # Anything else -- spectator_not_online, a participant guard, a
            # usage error -- is the operator's problem, and continuing to poll
            # would only bury it under twenty more minutes of the same.
            *)
                echo "camera error: $err" >&2
                rc=1
                ;;
        esac
        break
    fi

    if [ -z "$out" ]; then
        # No error= and no record at all: the command never reached the world,
        # or it is not in the running build. Said once, not once per poll, and
        # not fatal -- an attach occasionally comes back empty. The time budget
        # is what stops this case.
        if [ "$silent_reported" -eq 0 ]; then
            echo "no TOURNAMENT camera record came back -- the command may not exist in the running build; still polling until the ${MAXMIN}m budget" >&2
            silent_reported=1
        fi
    fi

    reason="$(ctl_field "$out" reason)"
    if [ "$(ctl_field "$out" moved)" = "1" ]; then
        repositions=$((repositions + 1))
        # One line per CUT, not per poll. Fifteen-second polling over a
        # twenty-minute match is eighty lines of "still watching the same
        # fight", which is eighty lines nobody reads; a framing change is the
        # only thing here worth a human's attention.
        if [ "$reason" != "$lastreason" ]; then
            printf '[%s] camera now following: %s\n' "$(date -u +%H:%M:%SZ)" "$reason"
            lastreason="$reason"
        fi
    fi

    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "spectate budget of ${MAXMIN}m reached without instance $INSTANCE disappearing" >&2
        rc=1
        break
    fi

    [ "$INTERVAL" -gt 0 ] && sleep "$INTERVAL"
done

# Always the last line, on every path, so a caller that reads only the tail of
# this script's output still learns whether the camera ever actually moved.
# repositions counts moved=1 replies only: a poll the server answered with
# moved=0 produced no shot.
printf 'SPECTATE instance=%s spectator=%s repositions=%d\n' "$INSTANCE" "$SPECTATOR" "$repositions"
exit "$rc"
