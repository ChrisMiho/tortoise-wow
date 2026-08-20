#!/usr/bin/env bash
# A control plane on paper. Sourced instead of scripts/tournament/lib/ctl.sh
# (effect-consume.sh honours $CTL_STUB, and the effect tests source it directly)
# so the applier can be exercised with no world standing up.
#
# It answers in the SHAPE src/game/Commands/TournamentCommands.cpp answers in,
# which is the whole point: `tournament equip` emits one ok=<0|1> line per item
# and THEN a `equipped=<n> failed=<n>` summary, so a stub that just printed
# "ok=1" once could never catch an applier that reads a partial equip as a clean
# success. Change this file when that output contract changes.
#
# Two knobs, both read at call time:
#   CTL_ATTACH_LOG   a file that gets one line appended per ctl() call -- that
#                    is, per console attach. The batching assertions count it.
#   CTL_EQUIP_OK     how many items of each equip list succeed (default: all).
#                    Set it to 1 to get the partial equip that used to be
#                    reported as success.
#   CTL_KILL_FAIL    one bot name whose `kill` answers ok=0 reason=offline. The
#                    partial-wipe case -- nine of ten bots die because the tenth
#                    logged out -- needs one target to refuse inside a batch the
#                    rest of which succeeds.

ctl() { # <command...>   one call = one console attach
    local line ids id i ok equipped failed reason
    printf 'attach\n' >> "${CTL_ATTACH_LOG:-/dev/null}"

    # The argument may be a whole batch of newline-separated commands -- that is
    # what one attach for ten bots looks like.
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        # shellcheck disable=SC2086
        set -- $line
        case "${2:-}" in
            heal)
                printf 'TOURNAMENT heal player=%s hp=100 resurrected=0 ok=1\n' "${3:-}" ;;
            kill)
                if [ -n "${CTL_KILL_FAIL:-}" ] && [ "${3:-}" = "$CTL_KILL_FAIL" ]; then
                    printf 'TOURNAMENT kill player=%s ok=0 reason=offline\n' "${3:-}"
                else
                    printf 'TOURNAMENT kill player=%s ok=1 reason=-\n' "${3:-}"
                fi ;;
            equip)
                ids="${4:-}"
                i=0; equipped=0; failed=0
                for id in $(printf '%s' "$ids" | tr ',' ' '); do
                    i=$((i + 1))
                    if [ "$i" -le "${CTL_EQUIP_OK:-9999}" ]; then
                        ok=1; reason='-'; equipped=$((equipped + 1))
                    else
                        ok=0; reason='cannot_equip(0)'; failed=$((failed + 1))
                    fi
                    printf 'TOURNAMENT equip player=%s item=%s slot=-1 ok=%s reason=%s\n' \
                        "${3:-}" "$id" "$ok" "$reason"
                done
                printf 'TOURNAMENT equip player=%s equipped=%s failed=%s\n' \
                    "${3:-}" "$equipped" "$failed" ;;
            *)
                printf 'TOURNAMENT %s ok=1\n' "$line" ;;
        esac
    done <<< "$1"
}

# Same contract as ctl_field in lib/ctl.sh: the value of one key= from the first
# line that carries it.
ctl_field() { # <captured-output> <key>
    printf '%s\n' "$1" \
        | sed -n "s/.*[[:space:]]$2=\\([^[:space:]]*\\).*/\\1/p" | head -1
}
