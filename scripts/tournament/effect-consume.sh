#!/usr/bin/env bash
# Drain the viewer-effect queue during a match. THIS IS THE APPLIER.
#
#   ./scripts/tournament/effect-consume.sh --queue var/effects.ndjson \
#        --alliance stormwind-sentinels --horde orgrimmar-warsong \
#        --state logs/tournament/<run>/effects [--once] [--interval 5]
#
# effect-queue.sh (the adapter) only appends; nothing a viewer buys reaches the
# world until this loop picks it up. It runs beside a live match, re-reading the
# whole queue every pass, and two properties are what make re-reading an
# append-only file safe rather than catastrophic:
#
#   DEDUPE BY COMMAND ID. The queue is replayed from the top after a crash, and
#   an adapter can deliver the same command twice. Every id applied here is
#   appended to <state>/applied.txt and any id already there is skipped, so a
#   pass over the same file applies nothing a second time. Without it, a restart
#   mid-match re-kills every team that was ever killed and every purchase lands
#   twice -- a viewer defrauded, or a team wiped twice.
#
#   RATE LIMIT PER EFFECT CLASS. `kill_team` is match-deciding: ten bots dead at
#   once ends a Warsong Gulch game. Uncapped, one script hammering the adapter
#   decides every match on the bracket. Caps live in <state>/counts.txt, so they
#   are per state dir -- that is, per match.
#
# A rate-limited command is recorded in applied.txt exactly like an applied one.
# Deliberate: the alternative is a command re-examined and re-refused on every
# pass for the rest of the match, which would then fire the instant a cap was
# raised, long after the viewer who bought it stopped watching.
#
# The queue file is READ ONLY here. Never rewrite or truncate it -- the adapter
# may be appending to it in the same instant.
#
# Exit 0 = the pass ran. Exit 2 = called wrong. Nothing here exits non-zero for
# a bad queue line or a failed effect: a landmine mid-queue must not stop the
# commands behind it, and a match with nobody watching the terminal has to keep
# draining.
#
# Run from WSL: jq is not on Git Bash's PATH on this host.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/team.sh
. "$HERE/lib/team.sh"
# shellcheck source=lib/gear.sh
. "$HERE/lib/gear.sh"
# The applier needs a control plane, and CTL_STUB is how the tests supply one
# with no world standing up: when it is set, `ctl` comes from the stub and
# neither lib/ctl.sh nor the console helper is sourced at all. Keep the switch --
# wsg-bots-common.sh expects a server root that does not exist on a test host.
if [ -n "${CTL_STUB:-}" ]; then
    # shellcheck source=/dev/null
    . "$CTL_STUB"
else
    # shellcheck source=lib/ctl.sh
    . "$HERE/lib/ctl.sh"
    # shellcheck source=../../docs/playerbots/wsg/lib/wsg-bots-common.sh
    . "$ROOT/docs/playerbots/wsg/lib/wsg-bots-common.sh"
fi
# shellcheck source=lib/effects.sh
. "$HERE/lib/effects.sh"

# Per-match caps. The two _team wipes are the match-deciding ones and are capped
# hardest. A heal cannot end a game, so its cap only exists to stop one viewer
# flooding the console for twenty minutes.
LIMIT_KILL_TEAM="${EFFECT_LIMIT_KILL_TEAM:-2}"
LIMIT_KILL_PLAYER="${EFFECT_LIMIT_KILL_PLAYER:-20}"
LIMIT_HEAL_TEAM="${EFFECT_LIMIT_HEAL_TEAM:-10}"
LIMIT_HEAL_PLAYER="${EFFECT_LIMIT_HEAL_PLAYER:-50}"
LIMIT_UPGRADE_ARMOR_TEAM="${EFFECT_LIMIT_UPGRADE_ARMOR_TEAM:-2}"
LIMIT_UPGRADE_WEAPON_TEAM="${EFFECT_LIMIT_UPGRADE_WEAPON_TEAM:-2}"
LIMIT_UPGRADE_ARMOR_PLAYER="${EFFECT_LIMIT_UPGRADE_ARMOR_PLAYER:-20}"
LIMIT_UPGRADE_WEAPON_PLAYER="${EFFECT_LIMIT_UPGRADE_WEAPON_PLAYER:-20}"

QUEUE=""; ATEAM=""; HTEAM=""; STATE=""; ONCE=0; INTERVAL="${EFFECT_INTERVAL:-5}"

usage() {
    cat >&2 <<USAGE
usage: $(basename "$0") --queue <file> --alliance <team> --horde <team>
                            --state <dir> [--once] [--interval <s>]

  --queue     the NDJSON queue effect-queue.sh appends to; read, never written
  --alliance  the team playing Alliance in THIS match
  --horde     the team playing Horde in THIS match
  --state     per-match dir; holds applied.txt (dedupe) and counts.txt (caps)
  --once      one pass, then exit (default: loop until killed)
  --interval  seconds between passes when looping (default: $INTERVAL)

An effect naming a team other than the two above is refused, not applied: the
queue outlives the match it was filled for, and those characters are offline.

Per-effect caps for one match, each overridable from the environment:
  EFFECT_LIMIT_KILL_TEAM=$LIMIT_KILL_TEAM
  EFFECT_LIMIT_KILL_PLAYER=$LIMIT_KILL_PLAYER
  EFFECT_LIMIT_HEAL_TEAM=$LIMIT_HEAL_TEAM
  EFFECT_LIMIT_HEAL_PLAYER=$LIMIT_HEAL_PLAYER
  EFFECT_LIMIT_UPGRADE_ARMOR_TEAM=$LIMIT_UPGRADE_ARMOR_TEAM
  EFFECT_LIMIT_UPGRADE_WEAPON_TEAM=$LIMIT_UPGRADE_WEAPON_TEAM
  EFFECT_LIMIT_UPGRADE_ARMOR_PLAYER=$LIMIT_UPGRADE_ARMOR_PLAYER
  EFFECT_LIMIT_UPGRADE_WEAPON_PLAYER=$LIMIT_UPGRADE_WEAPON_PLAYER
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --queue)    QUEUE="${2:-}"; shift 2 ;;
        --alliance) ATEAM="${2:-}"; shift 2 ;;
        --horde)    HTEAM="${2:-}"; shift 2 ;;
        --state)    STATE="${2:-}"; shift 2 ;;
        --interval) INTERVAL="${2:-}"; shift 2 ;;
        --once)     ONCE=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
    esac
done

[ -n "$QUEUE" ] && [ -n "$ATEAM" ] && [ -n "$HTEAM" ] && [ -n "$STATE" ] || { usage; exit 2; }

command -v jq >/dev/null 2>&1 || {
    echo "FATAL: jq is not installed (apt-get install jq); run this from WSL" >&2; exit 2; }

mkdir -p "$STATE" || { echo "cannot create state dir $STATE" >&2; exit 2; }
APPLIED="$STATE/applied.txt"
COUNTS="$STATE/counts.txt"
touch "$APPLIED" || { echo "cannot write $APPLIED" >&2; exit 2; }

# A case, not `eval "\$LIMIT_$1"`. The effect name comes off the queue, which an
# adapter fills from chat, and an eval'd one is arbitrary code running as
# whoever operates the tournament. The default arm is fail-closed rather than
# unlimited, and is unreachable in practice: the caller only asks about names in
# $EFFECT_NAMES, and effect_validate refuses everything else by name.
limit_for() { # <effect> -> the cap for that effect class
    case "$1" in
        kill_team)              printf '%s\n' "$LIMIT_KILL_TEAM" ;;
        kill_player)            printf '%s\n' "$LIMIT_KILL_PLAYER" ;;
        heal_team)              printf '%s\n' "$LIMIT_HEAL_TEAM" ;;
        heal_player)            printf '%s\n' "$LIMIT_HEAL_PLAYER" ;;
        upgrade_armor_team)     printf '%s\n' "$LIMIT_UPGRADE_ARMOR_TEAM" ;;
        upgrade_weapon_team)    printf '%s\n' "$LIMIT_UPGRADE_WEAPON_TEAM" ;;
        upgrade_armor_player)   printf '%s\n' "$LIMIT_UPGRADE_ARMOR_PLAYER" ;;
        upgrade_weapon_player)  printf '%s\n' "$LIMIT_UPGRADE_WEAPON_PLAYER" ;;
        *)                      printf '0\n' ;;
    esac
}

# MUST yield exactly one integer, in all three states the counts file can be in:
# missing, present but empty, and present with no matching line.
#
# The obvious one-liner does not:
#   count_for() { grep -c "^$1\$" "$COUNTS" 2>/dev/null || echo 0; }
# `grep -c` with no match prints `0` AND exits 1, so the `|| echo 0` fires too
# and the function returns the two-line string "0\n0". The `[ "$used" -ge "$lim" ]`
# below then dies with "integer expression expected" and evaluates FALSE -- so
# the rate limit silently never bites, which is the single failure this script
# exists to prevent. The third state is not exotic: it is reached the first time
# any OTHER effect is applied, because that is what creates counts.txt.
#
# Hence: guard the missing file, keep grep's stdout, discard its exit status,
# and force anything non-numeric to 0.
count_for() { # <effect> -> how many of that class have already been applied
    local n=0
    if [ -f "$COUNTS" ]; then
        n="$(grep -cxF -- "$1" "$COUNTS" 2>/dev/null)"
    fi
    case "$n" in
        ''|*[!0-9]*) n=0 ;;
    esac
    printf '%s\n' "$n"
}

drain_once() {
    local applied=0 skipped=0 limited=0 line id fx used lim
    if [ -f "$QUEUE" ]; then
        # fd 3, not stdin. effect_apply reaches the world through wsg_console,
        # which attaches to the mangosd container and reads stdin; on the loop's
        # own stdin that attach swallows the rest of the queue and every command
        # behind the first vanishes -- silently, because a short read is
        # indistinguishable from the end of the file.
        while IFS= read -r line <&3; do
            [ -n "$line" ] || continue

            # Warned about and stepped over, never fatal. The line is already in
            # an append-only file nobody can edit mid-match, so dying here would
            # strand every command behind it for the rest of the game.
            if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
                echo "WARN: skipping unparseable queue line: $line" >&2
                continue
            fi

            id="$(printf '%s' "$line" | jq -r '.id // ""')"
            if [ -z "$id" ]; then
                echo "WARN: skipping queue line with no id, nothing to dedupe on: $line" >&2
                continue
            fi

            # -x -F: an id is a literal, and an unanchored match would let the
            # recorded id "12" suppress "123" -- a viewer's command dropped as a
            # duplicate of one it merely shares digits with.
            if grep -qxF -- "$id" "$APPLIED"; then
                skipped=$((skipped + 1))
                continue
            fi

            fx="$(printf '%s' "$line" | jq -r '.effect // ""')"
            # The cap check only applies to an effect that HAS a class. An
            # unknown or missing effect name is not "over its cap of 0" -- it is
            # a malformed command, and saying so is effect_validate's job. Left
            # to fall through, it gets rejected below with the library's own
            # reason on stderr instead of a nonsense rate-limit line.
            case " $EFFECT_NAMES " in
                *" $fx "*)
                    used="$(count_for "$fx")"
                    lim="$(limit_for "$fx")"
                    if [ "$used" -ge "$lim" ]; then
                        limited=$((limited + 1))
                        # Recorded as applied, and counted apart from a
                        # duplicate: the command is closed out for good rather
                        # than re-refused every pass, and the CONSUME line can
                        # still tell "viewers are over the cap" from "the
                        # adapter is double-delivering".
                        printf '%s\n' "$id" >> "$APPLIED"
                        echo "WARN: $fx is over its cap of $lim for this match, dropping id=$id" >&2
                        continue
                    fi
                    ;;
            esac

            if effect_apply "$line" "$ATEAM" "$HTEAM"; then
                applied=$((applied + 1))
            else
                # Refused outright, or landed on some targets and not others --
                # effect_apply has already said which, on stdout and stderr.
                echo "WARN: id=$id ($fx) did not fully apply" >&2
            fi
            # Both branches record it. A command that failed against the world
            # is spent, not pending: retrying it forever is how one bot that
            # logged out mid-match becomes an endless console loop.
            printf '%s\n' "$id" >> "$APPLIED"
            # Only a real effect class goes in the counts file. A refused
            # command never touched the world, and a blank line in there is a
            # line count_for has to be defended against for the rest of the match.
            case " $EFFECT_NAMES " in
                *" $fx "*) printf '%s\n' "$fx" >> "$COUNTS" ;;
            esac
        done 3< "$QUEUE"
    fi

    printf 'CONSUME applied=%d skipped=%d ratelimited=%d\n' "$applied" "$skipped" "$limited"
}

if [ "$ONCE" -eq 1 ]; then
    drain_once
else
    while :; do
        drain_once
        sleep "$INTERVAL"
    done
fi
