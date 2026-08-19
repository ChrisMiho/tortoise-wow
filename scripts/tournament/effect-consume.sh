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
# An id is CLAIMED BEFORE the first ctl call, and the claim, the apply and the
# cap arithmetic all happen under one flock on <state>/lock. A `kill_team` is ten
# console round trips, so recording it afterwards means a consumer killed on the
# fourth leaves it unrecorded and the next pass wipes the team a second time; and
# an unlocked read-then-append means two consumers sharing one state dir both
# miss the id and both apply it.
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

# Every cap above can be overridden from the environment, which is where an
# operator typos one. Unvalidated, EFFECT_LIMIT_KILL_TEAM=abc makes the
# `[ "$used" -ge "$lim" ]` below die with "integer expression expected" and
# evaluate FALSE -- the cap silently stops biting and one script decides every
# match on the bracket. That is the same failure count_for is already defended
# against, one variable over. So it is named and fatal, never absorbed.
check_limit() { # <env-var-name> <value>
    case "$2" in
        ''|*[!0-9]*)
            echo "FATAL: $1 must be a non-negative integer, got '$2'" >&2
            exit 2 ;;
    esac
}
check_limit EFFECT_LIMIT_KILL_TEAM             "$LIMIT_KILL_TEAM"
check_limit EFFECT_LIMIT_KILL_PLAYER           "$LIMIT_KILL_PLAYER"
check_limit EFFECT_LIMIT_HEAL_TEAM             "$LIMIT_HEAL_TEAM"
check_limit EFFECT_LIMIT_HEAL_PLAYER           "$LIMIT_HEAL_PLAYER"
check_limit EFFECT_LIMIT_UPGRADE_ARMOR_TEAM    "$LIMIT_UPGRADE_ARMOR_TEAM"
check_limit EFFECT_LIMIT_UPGRADE_WEAPON_TEAM   "$LIMIT_UPGRADE_WEAPON_TEAM"
check_limit EFFECT_LIMIT_UPGRADE_ARMOR_PLAYER  "$LIMIT_UPGRADE_ARMOR_PLAYER"
check_limit EFFECT_LIMIT_UPGRADE_WEAPON_PLAYER "$LIMIT_UPGRADE_WEAPON_PLAYER"

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

# A value-taking flag given as the LAST argument used to `shift 2` with one
# argument left. bash refuses to shift past $#, so $# never decreased and this
# loop spun forever -- an operator's typo becoming a silent hang with no output,
# seen as `timeout` rc=124. Every such flag now checks it has a value first.
need_val() { # <flag> <remaining-argc>
    [ "$2" -ge 2 ] || { echo "$1 requires a value" >&2; usage; exit 2; }
}

while [ $# -gt 0 ]; do
    case "$1" in
        --queue)    need_val "$1" $#; QUEUE="$2"; shift 2 ;;
        --alliance) need_val "$1" $#; ATEAM="$2"; shift 2 ;;
        --horde)    need_val "$1" $#; HTEAM="$2"; shift 2 ;;
        --state)    need_val "$1" $#; STATE="$2"; shift 2 ;;
        --interval) need_val "$1" $#; INTERVAL="$2"; shift 2 ;;
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

# One lock per state dir -- that is, per match. Two consumers on one --state dir
# is not exotic: it is an operator restarting the loop without killing the old
# one. Unlocked, both read applied.txt before either appends, both miss the id,
# and both apply the same kill_team. The lock is held across the whole
# claim-and-apply section rather than only the read, so the cap arithmetic is
# serialised too and a second consumer cannot slip a command past a full cap.
LOCK="$STATE/lock"
HAVE_FLOCK=0
if command -v flock >/dev/null 2>&1 && exec 9>"$LOCK"; then
    HAVE_FLOCK=1
else
    echo "WARN: flock is unavailable, so two consumers sharing $STATE could" >&2
    echo "      apply the same command twice; run one consumer per match" >&2
fi
lock_hold()    { [ "$HAVE_FLOCK" -eq 1 ] && flock 9; return 0; }
lock_release() { [ "$HAVE_FLOCK" -eq 1 ] && flock -u 9; return 0; }

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
    local applied=0 skipped=0 limited=0 line id fx used lim eff_out eff_rc landed
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
            fx="$(printf '%s' "$line" | jq -r '.effect // ""')"

            # Everything from here to lock_release touches applied.txt and
            # counts.txt, which another consumer may be reading in the same
            # instant. jq and the queue line itself are process-local, so they
            # stay outside.
            lock_hold

            if grep -qxF -- "$id" "$APPLIED"; then
                lock_release
                skipped=$((skipped + 1))
                continue
            fi

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
                        lock_release
                        echo "WARN: $fx is over its cap of $lim for this match, dropping id=$id" >&2
                        continue
                    fi
                    ;;
            esac

            # CLAIMED BEFORE THE FIRST ctl CALL. A command that failed against
            # the world is spent, not pending -- retrying it forever is how one
            # bot that logged out mid-match becomes an endless console loop --
            # and a *_team effect is ten round trips, so recording it afterwards
            # means a consumer killed on the fourth replays all ten next pass.
            printf '%s\n' "$id" >> "$APPLIED"

            # effect_apply's stdout is captured and reprinted unchanged: its
            # EFFECT line carries applied=<n>, and that <n> -- not the exit
            # status -- is what says whether the world was touched. The rc is
            # all-or-nothing (1 if ANY single target failed), so keying cap on
            # it makes a wipe free the moment one bot is offline: nine bots
            # dead, counts.txt untouched, and the same command lands again on
            # the next purchase for the rest of the match.
            eff_out=""; eff_rc=0
            eff_out="$(effect_apply "$line" "$ATEAM" "$HTEAM")" || eff_rc=$?
            [ -z "$eff_out" ] || printf '%s\n' "$eff_out"

            # MUST yield exactly one integer, same discipline as count_for: a
            # refusal before effect_apply reaches its loop prints no EFFECT
            # line at all, and "" is not a number.
            landed="$(printf '%s\n' "$eff_out" \
                | sed -n 's/^EFFECT .*[[:space:]]applied=\([0-9][0-9]*\).*/\1/p' \
                | tail -1)"
            case "$landed" in
                ''|*[!0-9]*) landed=0 ;;
            esac

            if [ "$eff_rc" -eq 0 ]; then
                applied=$((applied + 1))
            else
                # Refused outright, or landed on some targets and not others --
                # effect_apply has already said which, on stdout and stderr.
                echo "WARN: id=$id ($fx) did not fully apply" >&2
            fi

            # AT LEAST ONE TARGET LANDED is what spends cap, and only a real
            # effect class goes in the counts file. A refusal -- a team not in
            # this match, say -- reaches no bot at all (applied=0, or no EFFECT
            # line), so counting it would let two stale queue lines exhaust
            # kill_team's cap of 2 before a single legitimate command reached a
            # bot. A partial wipe is the mirror case: it killed bots, so it
            # spends its one unit of cap exactly like a clean one.
            if [ "$landed" -gt 0 ]; then
                case " $EFFECT_NAMES " in
                    *" $fx "*) printf '%s\n' "$fx" >> "$COUNTS" ;;
                esac
            fi
            lock_release
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
