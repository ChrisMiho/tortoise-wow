#!/usr/bin/env bash
# Validate, target and apply one viewer effect. Source, don't execute.
#
# A viewer intervention arrives as one JSON object -- an id, a timestamp, an
# effect name, a target and a source -- and this file is the only thing that
# knows what makes such an object well formed, who it may touch, and how it
# reaches the world. Everything downstream (the queue, its consumer, the mock
# adapter) hands objects to these four functions and reads back one EFFECT line.
#
# Two rules are the whole reason it exists, and both are enforced here rather
# than left to callers:
#
#   AN EFFECT NEEDS AN ID. The queue is append-only and is replayed after a
#   crash, and an adapter can deliver the same command twice. The id is the
#   dedupe key, so a command without one cannot be deduplicated at all -- and an
#   effect applied twice is a viewer defrauded or a team wiped twice.
#
#   AN EFFECT MAY ONLY TOUCH THIS MATCH. The queue outlives the match it was
#   filled for. A command naming a team that is not playing would resolve to
#   characters that are offline or in another instance; every control-plane
#   command resolves its player by name through ObjectAccessor, so the result is
#   not an error but silence -- the effect reports success and nothing happens.
#   effect_targets refuses that case instead.
#
# DEPENDENCIES, deliberately not sourced here (same convention as the other
# libs -- the entry script does the sourcing, so a caller that only validates
# never drags in the console):
#   lib/team.sh  team_validate, team_names, team_field, team_rows
#   lib/gear.sh  gear_next_tier, gear_items_armor, gear_items_weapon
#   lib/ctl.sh   ctl                      (apply path only)
#
# Requires jq. Run callers from WSL: jq is not on Git Bash's PATH on this host.

# The eight effects, named once. A viewer-facing catalogue, an adapter and a
# price list all have to agree on this list; anything not on it is rejected by
# name rather than half-applied.
#
# Two axes: what it does (heal / kill / upgrade armour / upgrade weapon) and how
# wide it lands (one bot, or all ten). `_player` needs a target.slot, `_team`
# does not -- which is the only structural difference between them, and is why
# the suffix is load-bearing rather than decoration.
EFFECT_NAMES="heal_player heal_team kill_player kill_team \
upgrade_armor_player upgrade_armor_team upgrade_weapon_player upgrade_weapon_team"

# One scalar out of the command. `// ""` so an absent key reads as empty rather
# than the string "null", which would pass every `[ -n ... ]` test below.
effect_field() { # <json> <jq-path>
    printf '%s' "$1" | jq -r "$2 // \"\""
}

# Every rejection prints its reason on stderr. A queue consumer logs that line
# beside the command it dropped, and "invalid" alone is not enough to tell a
# typo'd effect name from a team file that has stopped validating.
effect_validate() { # <json> -> 0 if well formed, else 1 with a reason on stderr
    local j="$1" id fx team slot
    printf '%s' "$j" | jq -e . >/dev/null 2>&1 || { echo "not valid JSON" >&2; return 1; }

    id="$(effect_field "$j" '.id')"
    [ -n "$id" ] || { echo "command has no id -- without one there is no dedupe key" >&2; return 1; }

    fx="$(effect_field "$j" '.effect')"
    case " $EFFECT_NAMES " in
        *" $fx "*) ;;
        *) echo "unknown effect: '$fx'" >&2; return 1 ;;
    esac

    team="$(effect_field "$j" '.target.team')"
    [ -n "$team" ] || { echo "command has no target team" >&2; return 1; }
    # Not merely "the file exists": a roster with a duplicate slot or an
    # over-long name produces characters that never come online, and an effect
    # aimed at one of those is exactly the silent no-op this library exists to
    # prevent.
    team_validate "$team" >/dev/null || { echo "target team '$team' does not validate" >&2; return 1; }

    case "$fx" in
        *_player)
            slot="$(effect_field "$j" '.target.slot')"
            [ -n "$slot" ] || { echo "a _player effect needs target.slot" >&2; return 1; }
            ;;
    esac
    return 0
}

# The character names this effect applies to, one per line.
effect_targets() { # <json> <allianceTeam> <hordeTeam>
    local j="$1" ateam="$2" hteam="$3" team fx slot
    team="$(effect_field "$j" '.target.team')"

    if [ "$team" != "$ateam" ] && [ "$team" != "$hteam" ]; then
        echo "team '$team' is not in this match ($ateam vs $hteam)" >&2
        return 1
    fi

    fx="$(effect_field "$j" '.effect')"
    case "$fx" in
        *_team)   team_names "$team" ;;
        *_player) slot="$(effect_field "$j" '.target.slot')"
                  # The name IS prefix+slot -- the same rule team_names applies,
                  # so a single-slot target and a team target can never disagree
                  # about what a given bot is called.
                  printf '%s%s\n' "$(team_field "$team" '.namePrefix')" "$slot" ;;
        *)        echo "unknown effect: '$fx'" >&2; return 1 ;;
    esac
}

# Class and role for one character, which is what picks its gear file. Read out
# of the roster rather than inferred from the name: the name carries the slot,
# and nothing else about the bot.
effect_member_meta() { # <team> <name> -> "class|role", 1 if that name is not on the team
    local meta
    meta="$(team_rows "$1" | awk -F'|' -v n="$2" '$1 == n { print $2 "|" $4; exit }')" || return 1
    [ -n "$meta" ] || { echo "no roster entry for '$2' on team '$1'" >&2; return 1; }
    printf '%s\n' "$meta"
}

# Validate, resolve, apply per target, and say exactly what happened -- one
# EFFECT line, always, even when every target failed. A consumer that took this
# command off a queue needs a single parseable record to close it out with.
effect_apply() { # <json> <allianceTeam> <hordeTeam>
    local j="$1" ateam="$2" hteam="$3" fx id team targets nm out rc=0 applied=0 failed=0
    effect_validate "$j" || return 1
    fx="$(effect_field "$j" '.effect')"
    id="$(effect_field "$j" '.id')"
    team="$(effect_field "$j" '.target.team')"
    targets="$(effect_targets "$j" "$ateam" "$hteam")" || return 1

    # A here-string, not a pipe: the loop has to run in THIS shell or the two
    # counters it keeps are discarded with the subshell and every EFFECT line
    # reads applied=0 failed=0.
    while IFS= read -r nm; do
        [ -n "$nm" ] || continue
        out=""
        case "$fx" in
            heal_player|heal_team) out="$(ctl "tournament heal $nm")" ;;
            kill_player|kill_team) out="$(ctl "tournament kill $nm")" ;;
            upgrade_armor_player|upgrade_armor_team|\
            upgrade_weapon_player|upgrade_weapon_team)
                out="$(effect_upgrade_one "$team" "$nm" "$fx")" ;;
        esac

        # ok=1 is the control plane's own verdict. Treating an empty capture as
        # success would report a world that never received the command -- a
        # console attach that timed out, say -- as a successful heal.
        if printf '%s\n' "$out" | grep -q 'ok=1'; then
            applied=$((applied + 1))
        else
            failed=$((failed + 1))
            rc=1
        fi
    done <<< "$targets"

    printf 'EFFECT id=%s effect=%s team=%s applied=%d failed=%d\n' \
        "$id" "$fx" "$team" "$applied" "$failed"
    return "$rc"
}

# One bot, exactly one tier up. Emits a TOURNAMENT-shaped line either way, so
# the caller above can judge a local refusal exactly as it judges a real reply.
effect_upgrade_one() { # <team> <name> <effect>
    local team="$1" nm="$2" fx="$3" meta cls role cur next ids rc=0

    meta="$(effect_member_meta "$team" "$nm")" || {
        printf 'TOURNAMENT upgrade player=%s ok=0 reason=not_on_team(%s)\n' "$nm" "$team"; return 1; }
    cls="${meta%%|*}"; role="${meta##*|}"

    cur="$(team_field "$team" '.gearTier')"

    # gear_next_tier prints nothing in two very different cases: at the top tier
    # (exit 0) and when the gear file or the current tier does not exist (exit
    # 1). Keeping the exit code is what stops a missing gear file being reported
    # to a paying viewer as "you were already at the top".
    next="$(gear_next_tier "$cls" "$role" "$cur")" || rc=1
    if [ "$rc" -ne 0 ]; then
        printf 'TOURNAMENT upgrade player=%s ok=0 reason=no_tier_above(%s)\n' "$nm" "$cur"
        return 1
    fi
    if [ -z "$next" ]; then
        # Already at the top. A no-op that says so, never a wrap back to base:
        # handing someone who paid for an upgrade a downgrade to white is worse
        # than handing them nothing.
        printf 'TOURNAMENT upgrade player=%s ok=1 reason=already_top_tier\n' "$nm"
        return 0
    fi

    case "$fx" in
        upgrade_armor_*)  ids="$(gear_items_armor  "$cls" "$role" "$next" | cut -d'|' -f2 | paste -sd, -)" ;;
        upgrade_weapon_*) ids="$(gear_items_weapon "$cls" "$role" "$next" | cut -d'|' -f2 | paste -sd, -)" ;;
    esac

    # A tier that exists but holds nothing in the half being bought. Reported,
    # not silently skipped: `tournament equip <name>` with an empty item list
    # would otherwise look like a successful upgrade that changed nothing.
    if [ -z "$ids" ]; then
        printf 'TOURNAMENT upgrade player=%s ok=0 reason=no_items_in_tier(%s)\n' "$nm" "$next"
        return 1
    fi

    ctl "tournament equip $nm $ids"
}
