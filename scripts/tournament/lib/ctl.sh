#!/usr/bin/env bash
# Talk to the .tournament control plane. Source, don't execute.
#
# The console prints a great deal besides these lines, and rndbot-style replies
# vanish into a null player session entirely, so every read here filters for the
# "TOURNAMENT " marker and parses the space-separated key=value pairs behind it.
#
# This file is the ONE place that knows that format. When the output contract in
# src/game/Commands/TournamentCommands.cpp changes, this file changes with it and
# nothing else has to -- which is the entire reason it exists rather than each
# caller re-inventing the same grep. See docs/playerbots/TOURNAMENT-CONTROL-PLANE.md.
#
# wsg_console (docs/playerbots/wsg/lib/wsg-bots-common.sh) is required, but only
# inside ctl(). Sourcing this file touches no server and no database, which is
# what lets tests/tournament/ctl.test.sh run against captured strings with
# nothing standing up.

# How long each console attach stays open. Commands are queued onto the world
# thread (QueueCliCommand), so the answer does not come back at typing speed.
CTL_WAIT="${CTL_WAIT:-10}"

# Sends one command and echoes only the TOURNAMENT records it produced.
#
# Deliberately not `grep '^TOURNAMENT '`. commandFinished writes the prompt as
# printf("mangos>") with NO trailing newline (src/mangosd/CliRunnable.cpp:66-70),
# so as soon as more than one command is in flight the prompt arrives glued to
# the front of the next command's first output line. An anchored match would
# silently drop exactly those records. Matching from the marker to end of line
# finds them and strips the prompt, so every line this echoes does begin
# "TOURNAMENT " even when the raw console line did not.
#
# Never fails the caller: grep exits 1 when a command produced no records, and
# no records is an ordinary answer -- `status` on an idle world is the usual one.
ctl() { # <command...>
    wsg_console "$*" "$CTL_WAIT" | grep -ao 'TOURNAMENT .*' || true
}

# The value of one key= field, from the first captured line that carries it.
#
# Anchored on both sides, and each anchor is load-bearing:
#   - the leading space stops the key `stance` matching inside `instance=101`;
#   - requiring the `=` stops the key `ok` matching a longer `okay=...`;
#   - the value is everything up to the NEXT space, so `slot=0` reads "0" and
#     not "" -- slot zero is the head slot, the most ordinary result `equip` has.
#
# Parameter expansion rather than sed, because the key is interpolated: quoted
# inside a glob it cannot turn into a pattern, and `#` takes the FIRST occurrence
# where sed's greedy `.*` would have taken the last.
ctl_field() { # <captured-output> <key>
    local line padded rest
    while IFS= read -r line; do
        # Padded so a key at either end of the line is still surrounded.
        padded=" $line "
        case "$padded" in
            *" $2="*) ;;
            *)        continue ;;
        esac
        rest="${padded#*" $2="}"
        printf '%s\n' "${rest%%[[:space:]]*}"
        return 0
    done <<< "$1"
    return 0
}

# Create an instance and echo its id.
#
# Returns 1 on either kind of failure, and says which on stderr: an error= the
# server reported (bad type id, missing template, create failed) is a diagnosis,
# whereas no instance id at all means the command never reached the world or the
# output contract moved -- so that case prints the raw capture rather than a
# summary of it.
ctl_create() { # <bgTypeId> <level>
    local out err inst
    out="$(ctl "tournament create $1 $2")"

    err="$(ctl_field "$out" error)"
    if [ -n "$err" ]; then
        echo "tournament create failed: $err" >&2
        return 1
    fi

    inst="$(ctl_field "$out" instance)"
    if [ -z "$inst" ]; then
        echo "tournament create returned no instance id; raw output:" >&2
        printf '%s\n' "$out" >&2
        return 1
    fi

    printf '%s\n' "$inst"
}
