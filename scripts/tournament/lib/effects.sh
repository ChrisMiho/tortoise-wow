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
#   lib/ctl.sh   ctl, ctl_field           (apply path only)
#
# EFFECT_STATE_DIR, when set, is the per-match state dir the applied tier record
# (tiers.txt) lives in -- effect-consume.sh points it at its own --state dir.
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

# --- where an upgrade remembers what it already bought -----------------------
#
# `.gearTier` in the team file is the tier the roster was DRESSED in, and nothing
# writes it back -- so reading the current tier from it made every upgrade after
# the first re-equip the same tier and report ok=1. A viewer paid twice for one
# tier and nothing said so.
#
# The tier a bot actually reached is therefore recorded here, per bot AND per
# half: `upgrade_armor_*` and `upgrade_weapon_*` are separately priced effects
# walking the same ladder, so one shared record would let a paid-for armour
# upgrade silently consume the weapon upgrade's step.
#
# EFFECT_STATE_DIR is the match's state dir (effect-consume.sh passes its own),
# which is what makes the record survive a consumer restart mid-match -- exactly
# like applied.txt beside it. With no state dir the fallback is a per-process
# file: still no silent re-equip within a run, but nothing to reconcile after
# one.
#
# That fallback path is DERIVED, never allocated. Every reader arrives here from
# inside a command substitution -- effect_tier_current is called as
# `cur="$(effect_tier_current ...)"` by effect_plan_upgrade_one, which effect_apply
# in turn calls as `plan="$(effect_plan_upgrade_one ...)"` -- and an assignment
# made in a subshell dies with it. So an mktemp cached in a variable cached
# nothing: every call minted a fresh EMPTY record, reader and writer never saw
# the same file, and the second upgrade_armor_player on a bot read no tier,
# re-equipped the one it was already wearing and answered applied=1. That is
# precisely the defect this record exists to prevent, so the path has to come
# out identical for every call in the process rather than be handed out once.
# $$ is what makes it so: a subshell inherits the invoking shell's PID unchanged.
#
# The name is therefore predictable, so it lives in a private 0700 per-user
# directory instead of straight in a shared /tmp -- otherwise anyone could
# pre-create the path as a symlink and have an upgrade append tiers through it.
effect_tier_file() { # -> path to the tier record, creating nothing
    local dir
    if [ -n "${EFFECT_STATE_DIR:-}" ]; then
        printf '%s\n' "$EFFECT_STATE_DIR/tiers.txt"
        return 0
    fi
    dir="${TMPDIR:-/tmp}/effect-tiers-${UID:-$(id -u)}"
    mkdir -p -m 700 "$dir" 2>/dev/null || return 1
    # A real directory and ours, or nothing gets written there at all.
    [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ] || return 1
    printf '%s/run-%s.txt\n' "$dir" "$$"
}

# Which ladder half an effect walks. `-` for heal/kill, which have no tier.
effect_tier_half() { # <effect>
    case "$1" in
        upgrade_armor_*)  printf 'armor\n' ;;
        upgrade_weapon_*) printf 'weapon\n' ;;
        *)                printf -- '-\n' ;;
    esac
}

# The tier this bot is at for this half: the last one recorded, or the team's
# dressed tier if it has never been upgraded.
effect_tier_current() { # <team> <name> <half>
    local f rec=""
    f="$(effect_tier_file)" || { team_field "$1" '.gearTier'; return 0; }
    if [ -f "$f" ]; then
        # Last line wins, and the fields are compared whole -- a substring match
        # would let "Wsgaone" read another bot's tier.
        rec="$(awk -F'|' -v n="$2" -v h="$3" '$1 == n && $2 == h { v = $3 } END { print v }' "$f")"
    fi
    if [ -n "$rec" ]; then
        printf '%s\n' "$rec"
    else
        team_field "$1" '.gearTier'
    fi
}

# Append-only, and written ONLY after the world confirmed the equip with
# failed=0. Recording an intent rather than a result would advance the ladder
# past a tier the bot never actually got.
effect_tier_record() { # <name> <half> <tier>
    local f
    f="$(effect_tier_file)" || return 1
    printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$f"
}

# --- planning one upgrade ----------------------------------------------------
#
# Plans, never sends: effect_apply batches every target's command into ONE
# console attach, so nothing below may talk to the world itself.
#
# Three exits, because the caller has to tell them apart:
#   0  -> stdout is "<tier>|<console command>"; send it, and record <tier> if
#         the world answers failed=0.
#   2  -> stdout is a TOURNAMENT-shaped ok=1 line for a local no-op (already at
#         the top tier). Success, and no command to send.
#   1  -> stdout is a TOURNAMENT-shaped ok=0 line saying why it was refused.
effect_plan_upgrade_one() { # <team> <name> <effect>
    local team="$1" nm="$2" fx="$3" meta cls role half cur next ids rc=0

    half="$(effect_tier_half "$fx")"

    meta="$(effect_member_meta "$team" "$nm")" || {
        printf 'TOURNAMENT upgrade player=%s ok=0 reason=not_on_team(%s)\n' "$nm" "$team"; return 1; }
    cls="${meta%%|*}"; role="${meta##*|}"

    cur="$(effect_tier_current "$team" "$nm" "$half")"

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
        # than handing them nothing. The tier it stopped at is named, so the
        # second purchase reads differently from the first rather than repeating
        # an identical ok=1 line.
        printf 'TOURNAMENT upgrade player=%s ok=1 reason=already_top_tier(%s)\n' "$nm" "$cur"
        return 2
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

    printf '%s|tournament equip %s %s\n' "$next" "$nm" "$ids"
}

# How long the one attach stays open. A ten-bot upgrade is ten equips of up to
# thirteen items each, all queued onto the world thread, so it needs the room
# gear-apply.sh gives a batch of the same size rather than ctl.sh's 10 s default.
EFFECT_CTL_WAIT="${EFFECT_CTL_WAIT:-40}"

# Validate, resolve, apply, and say exactly what happened -- one EFFECT line,
# always, even when every target failed. A consumer that took this command off a
# queue needs a single parseable record to close it out with.
#
# PLAN, THEN ONE ATTACH, THEN JUDGE. Every target's command is built first and
# sent in a single console batch, the way gear-apply.sh and roster.sh already do
# it: a `heal_team` used to cost ten attaches, and wsg_console's own warning is
# that "forty attaches is forty chances to EOF the console, which shuts the world
# down". mangosd reads console EOF as "shut down the world", so the attach count
# is a safety property here, not a performance one.
#
# SUCCESS IS THE SUMMARY LINE, NOT ANY ok=1. `tournament equip` emits one
# ok=<0|1> per item and then `equipped=<n> failed=<n>`; a scan for "ok=1"
# anywhere therefore called `item=1 ok=1 / item=2 ok=0 / equipped=1 failed=12` a
# clean success, which the consumer then recorded in applied.txt and deduped away
# for good. The equip verdict is read from failed=0 on the summary line, and a
# missing summary is a failure (the bot was offline, or the world never
# answered) -- never a pass.
effect_apply() { # <json> <allianceTeam> <hordeTeam>
    local j="$1" ateam="$2" hteam="$3" fx id team targets nm out="" rc=0 applied=0 failed=0
    local lines="" plan prc half verdict line
    local -a planned=()
    local -A want_tier=()

    effect_validate "$j" || return 1
    fx="$(effect_field "$j" '.effect')"
    id="$(effect_field "$j" '.id')"
    team="$(effect_field "$j" '.target.team')"
    targets="$(effect_targets "$j" "$ateam" "$hteam")" || return 1
    half="$(effect_tier_half "$fx")"

    # --- plan ---------------------------------------------------------------
    #
    # A here-string, not a pipe: the loop has to run in THIS shell or the plan it
    # builds and the counters it keeps are discarded with the subshell.
    while IFS= read -r nm; do
        [ -n "$nm" ] || continue
        case "$fx" in
            heal_player|heal_team)
                lines="${lines}tournament heal $nm"$'\n'; planned+=("$nm") ;;
            kill_player|kill_team)
                lines="${lines}tournament kill $nm"$'\n'; planned+=("$nm") ;;
            upgrade_armor_player|upgrade_armor_team|\
            upgrade_weapon_player|upgrade_weapon_team)
                plan="$(effect_plan_upgrade_one "$team" "$nm" "$fx")"; prc=$?
                case "$prc" in
                    0)  want_tier["$nm"]="${plan%%|*}"
                        lines="${lines}${plan#*|}"$'\n'
                        planned+=("$nm") ;;
                    2)  # A local no-op that succeeded. No command, no attach.
                        printf '%s\n' "$plan" >&2
                        applied=$((applied + 1)) ;;
                    *)  printf '%s\n' "$plan" >&2
                        failed=$((failed + 1)); rc=1 ;;
                esac ;;
        esac
    done <<< "$targets"

    # --- send: ONE attach for every target ----------------------------------
    if [ -n "$lines" ]; then
        local CTL_WAIT="$EFFECT_CTL_WAIT"
        out="$(ctl "$lines")"
    fi

    # --- judge, per target, from the control plane's own answer -------------
    for nm in ${planned[@]+"${planned[@]}"}; do
        verdict=1
        line=""
        case "$fx" in
            heal_player|heal_team)
                printf '%s\n' "$out" | grep -qa "heal player=$nm .*ok=1" && verdict=0 ;;
            kill_player|kill_team)
                printf '%s\n' "$out" | grep -qa "kill player=$nm .*ok=1" && verdict=0 ;;
            *)
                # The summary line, and only it. The per-item ok= lines say WHICH
                # item failed; they never decide the target.
                line="$(printf '%s\n' "$out" | grep -a "equip player=$nm equipped=" | head -1)"
                if [ -n "$line" ] && [ "$(ctl_field "$line" failed)" = "0" ]; then
                    verdict=0
                fi ;;
        esac

        if [ "$verdict" -eq 0 ]; then
            applied=$((applied + 1))
            # Only now, with the world's confirmation in hand.
            if [ -n "${want_tier[$nm]:-}" ]; then
                effect_tier_record "$nm" "$half" "${want_tier[$nm]}"
            fi
        else
            failed=$((failed + 1))
            rc=1
            # The reason goes to stderr beside the target it belongs to: an
            # EFFECT line counting failures cannot say which item a partial equip
            # dropped, and that is what an operator issuing a refund needs.
            if [ -n "$line" ]; then
                printf '%s\n' "$out" | grep -a "equip player=$nm " | grep -a 'ok=0' >&2
            else
                printf 'effect: %s got no verdict for %s in the console reply\n' "$fx" "$nm" >&2
            fi
        fi
    done

    printf 'EFFECT id=%s effect=%s team=%s applied=%d failed=%d\n' \
        "$id" "$fx" "$team" "$applied" "$failed"
    return "$rc"
}
