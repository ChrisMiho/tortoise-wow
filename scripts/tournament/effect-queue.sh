#!/usr/bin/env bash
# Append one viewer effect to the queue. THIS IS THE MOCK ADAPTER.
#
#   ./scripts/tournament/effect-queue.sh --queue var/effects.ndjson \
#        --effect heal_player --team stormwind-sentinels --slot three
#
# Echoes the id it assigned; the consumer uses that id to dedupe.
#
# WHY A FILE IN THE MIDDLE. A real Twitch or TikTok listener replaces this one
# script and nothing else -- everything downstream reads the queue file, never
# an adapter. That boundary is why this pass builds no OAuth: the whole effect
# path can be exercised end to end with no credentials and no live channel, by
# a human typing the command line above.
#
# It is therefore the primary human interface for validating effects, not merely
# a test fixture, which is why every rejection below names the valid values
# rather than only saying the input was wrong.
#
# APPEND-ONLY. One `>>` of one line, and nothing here ever rewrites the file:
# the consumer may be reading it while this runs, and a rewrite would hand it a
# truncated line or replay commands it had already applied. A single write of a
# line this short is atomic under O_APPEND, so two adapters appending at once
# cannot interleave halves of a command.
#
# VALIDATED BEFORE IT IS APPENDED. A malformed command in the queue is a
# landmine the consumer trips over mid-match, when there is nobody to fix it.
# On rejection: exit 1, and nothing is appended.
#
# Exit 0 = appended. Exit 1 = rejected, file untouched. Exit 2 = called wrong.
#
# Run from WSL: jq is not on Git Bash's PATH on this host.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# Validation alone is wanted here, and that needs team.sh only. lib/gear.sh and
# lib/ctl.sh are the *applier's* dependencies -- an adapter that never applies
# anything has no business opening a console.
# shellcheck source=lib/team.sh
. "$HERE/lib/team.sh"
# shellcheck source=lib/effects.sh
. "$HERE/lib/effects.sh"

usage() {
    cat >&2 <<USAGE
usage: $(basename "$0") --queue <file> --effect <name> --team <id>
                          [--slot <slot>] [--source <name>] [--id <id>]

  --queue   NDJSON file to append to; created if it does not exist
  --effect  one of: $EFFECT_NAMES
  --team    a team id under $TEAM_DIR
  --slot    one of: $TEAM_SLOTS   (required by every _player effect)
  --source  where the command came from (default: mock)
  --id      supply an id instead of generating one (replay / testing)

The four _team effects hit all ten bots; the four _player effects hit the one
bot in --slot.
USAGE
}

known_teams() { # -> the team ids that actually exist, space separated
    local f out=""
    for f in "$TEAM_DIR"/*.json; do
        [ -f "$f" ] || continue
        f="${f##*/}"
        out="${out:+$out }${f%.json}"
    done
    printf '%s' "$out"
}

QUEUE=""; EFFECT=""; TEAM=""; SLOT=""; SOURCE="mock"; ID=""

# A value-taking flag given as the LAST argument used to `shift 2` with one
# argument left. bash refuses to shift past $#, so $# never decreased and this
# loop spun forever -- an adapter's typo becoming a silent hang with no output,
# seen as `timeout` rc=124. Every such flag now checks it has a value first.
need_val() { # <flag> <remaining-argc>
    [ "$2" -ge 2 ] || { echo "$1 requires a value" >&2; usage; exit 2; }
}

while [ $# -gt 0 ]; do
    case "$1" in
        --queue)  need_val "$1" $#; QUEUE="$2"; shift 2 ;;
        --effect) need_val "$1" $#; EFFECT="$2"; shift 2 ;;
        --team)   need_val "$1" $#; TEAM="$2"; shift 2 ;;
        --slot)   need_val "$1" $#; SLOT="$2"; shift 2 ;;
        --source) need_val "$1" $#; SOURCE="$2"; shift 2 ;;
        --id)     need_val "$1" $#; ID="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
    esac
done

[ -n "$QUEUE" ] && [ -n "$EFFECT" ] && [ -n "$TEAM" ] || { usage; exit 2; }

command -v jq >/dev/null 2>&1 || {
    echo "FATAL: jq is not installed (apt-get install jq); run this from WSL" >&2; exit 2; }

# effect_validate below catches all three of these too, but it answers as a
# library ("unknown effect: 'heal_playr'") and this script is what a human
# drives. Saying what WOULD have been accepted is the difference between a typo
# fixed in one attempt and a hunt through the source for the spelling.
case " $EFFECT_NAMES " in
    *" $EFFECT "*) ;;
    *) echo "unknown effect: '$EFFECT'" >&2
       echo "  valid effects: $EFFECT_NAMES" >&2
       exit 1 ;;
esac

case " $(known_teams) " in
    *" $TEAM "*) ;;
    *) echo "unknown team: '$TEAM'" >&2
       echo "  teams in $TEAM_DIR: $(known_teams)" >&2
       exit 1 ;;
esac

if [ -n "$SLOT" ]; then
    case " $TEAM_SLOTS " in
        *" $SLOT "*) ;;
        *) echo "unknown slot: '$SLOT'" >&2
           echo "  valid slots: $TEAM_SLOTS" >&2
           exit 1 ;;
    esac
fi

case "$EFFECT" in
    *_player)
        [ -n "$SLOT" ] || {
            echo "$EFFECT targets one bot, so it needs --slot" >&2
            echo "  valid slots: $TEAM_SLOTS" >&2
            echo "  (or use ${EFFECT%_player}_team to hit all ten)" >&2
            exit 1 ; } ;;
esac

# The id is the consumer's dedupe key, so two commands sharing one would silently
# collapse into one applied effect -- a viewer charged for nothing. $RANDOM alone
# is not enough: it is seeded from the pid and the clock, so two forks in the same
# second routinely draw the same number. Pairing it with nanoseconds makes a
# collision need the same nanosecond AND the same draw.
[ -n "$ID" ] || ID="$(date -u +%s%N)-$RANDOM"

# jq -n --arg, never string interpolation: --source is adapter-supplied and a
# chat handle full of quotes must produce an escaped string, not a broken line
# that the consumer's `jq -e .` rejects for the rest of the file's life.
# target.slot is present only when a slot was given, so a _team command carries
# no vestigial slot for the applier to half-honour.
line="$(jq -nc \
    --arg id "$ID" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg fx "$EFFECT" \
    --arg team "$TEAM" \
    --arg slot "$SLOT" \
    --arg src "$SOURCE" \
    '{id:$id, ts:$ts, effect:$fx,
      target: ({team:$team} + (if $slot == "" then {} else {slot:$slot} end)),
      source:$src}')" || { echo "could not build the command JSON" >&2; exit 1; }

# The real gate, and the same function the applier runs, so nothing can reach the
# queue that the applier would then refuse mid-match. It catches what the checks
# above cannot: a team file that exists but has stopped validating.
effect_validate "$line" || { echo "refusing to enqueue an invalid command" >&2; exit 1; }

dir="$(dirname "$QUEUE")"
[ -d "$dir" ] || mkdir -p "$dir" || { echo "cannot create $dir" >&2; exit 1; }

printf '%s\n' "$line" >> "$QUEUE" || { echo "cannot append to $QUEUE" >&2; exit 1; }
printf '%s\n' "$ID"
