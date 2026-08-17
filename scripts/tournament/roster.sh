#!/usr/bin/env bash
# Reconcile a team definition against the characters that actually exist, and
# drive the four things an operator ever does to a roster.
#
#   ./scripts/tournament/roster.sh status <team-id>            # read-only
#   ./scripts/tournament/roster.sh ensure <team-id> [--login]  # create what is missing
#   ./scripts/tournament/roster.sh login  <team-id>            # bring the team online
#   ./scripts/tournament/roster.sh logout <team-id>            # take it offline, keep it
#
# Run from WSL: jq is not on Git Bash's PATH on this host.
#
# This file exists because bringing a team into existence used to be a hand-typed
# console transcript, and three properties make that unsafe to repeat:
#
#   * `rndbot` console replies go to a null player session and vanish, so success
#     can NEVER be inferred from console output. Every subcommand that writes to
#     the console verifies what happened by reading tw_char.characters afterwards.
#   * Console EOF shuts the world down (compose is restart:"no"), so every
#     `docker attach` is another chance to kill the server. Each subcommand
#     therefore batches all of its lines into exactly ONE wsg_console call --
#     twenty attaches would be twenty chances.
#   * A broken row (`at_login != 0`) is indistinguishable from a slow one unless
#     something reads the database. `status` is that something.
#
# `status` is the only thing here that touches the database. `ensure`, `login`
# and `logout` are all defined in terms of its output, so there is exactly one
# place that knows the SQL and exactly one format to keep right.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=lib/team.sh
. "$HERE/lib/team.sh"
# shellcheck source=../../docs/playerbots/wsg/lib/wsg-bots-common.sh
. "$ROOT/docs/playerbots/wsg/lib/wsg-bots-common.sh"

# How long wsg_console holds the attach open before sending the detach keys.
# 20 s is what the WSG match scripts use for a batch this size. Lower it only in
# tests: detaching before mangosd has consumed the block loses the tail of it,
# and nothing would report that, because rndbot replies vanish.
ROSTER_CONSOLE_WAIT="${ROSTER_CONSOLE_WAIT:-20}"

# Creation is asynchronous -- the row appears a beat after the command lands --
# and `characters.online` is written on save, so it lags reality by up to
# PlayerSave.Interval (60 s). Both waits therefore poll to a deadline; reading
# once and concluding is how you get a false "it did not work".
ROSTER_ENSURE_DEADLINE_S=120
ROSTER_LOGIN_DEADLINE_S=180

ROSTER_SLOTS=10

usage() {
    cat >&2 <<'EOF'
usage: roster.sh {status|ensure|login|logout} <team-id> [--login]

  status  read-only reconcile of the definition against tw_char.characters.
          Always exits 0: it reports, it does not judge.
  ensure  create every missing character. Refuses while any row is broken.
          --login asks the create to log the bot in immediately.
  login   rndbot add for every slot, then block until online=10/10.
  logout  rndbot remove for every slot. Never deletes a character.
EOF
    exit 2
}

cmd="${1:-}"; team="${2:-}"
[ -n "$cmd" ] && [ -n "$team" ] || usage

command -v jq >/dev/null 2>&1 || {
    echo "FATAL: jq is not installed (apt-get install jq)" >&2; exit 2; }

# Every subcommand refuses to run on a team that does not validate, including the
# read-only one -- a definition that cannot be trusted cannot be reconciled
# against either. One second here instead of ten character rows to unpick later.
team_validate "$team" || {
    echo "FATAL: $team does not validate; fix the definition before touching the world" >&2
    exit 2
}

# --- status: the only thing here that reads the database ---------------------

# One line per slot:
#     <name> <exists|missing> <online|offline> <level> <at_login>
# then one summary line:
#     ROSTER <team-id> present=<n>/10 online=<n>/10 broken=<n>
#
# A missing slot prints "-" for level and at_login. The fields are positional so
# every line has to carry five of them, and a fabricated 0 would read as a real
# reading of a row that does not exist.
#
# Always returns 0. `broken=2` is a finding for whoever is watching, not a reason
# to fail a pipeline -- callers that care read the count.
roster_status() {
    local names inlist="" rows nm on lvl atl
    names="$(team_names "$team")"

    # ONE query for the whole roster. Ten queries is ten round trips and ten
    # chances to read a different instant of a world that is still moving.
    while IFS= read -r nm; do
        [ -n "$nm" ] || continue
        inlist="$inlist${inlist:+,}'$nm'"
    done <<< "$names"

    rows="$(wsg_mysql \
        "SELECT name, online, level, at_login FROM tw_char.characters WHERE name IN ($inlist);")"

    declare -A r_online=() r_level=() r_login=()
    while IFS=$'\t' read -r nm on lvl atl; do
        [ -n "${nm:-}" ] || continue
        r_online["$nm"]="$on"; r_level["$nm"]="$lvl"; r_login["$nm"]="$atl"
    done <<< "$rows"

    local present=0 online=0 broken=0
    while IFS= read -r nm; do
        [ -n "$nm" ] || continue
        if [ -z "${r_online[$nm]+x}" ]; then
            printf '%s missing offline - -\n' "$nm"
            continue
        fi
        present=$((present + 1))
        on="${r_online[$nm]}"; lvl="${r_level[$nm]}"; atl="${r_login[$nm]}"
        [ "$on" = "1" ] && online=$((online + 1))
        # at_login != 0 means the name was rejected at character load. The row is
        # not "slow", it is unusable: it can never come online, and it has to be
        # deleted by hand rather than created around.
        [ "$atl" != "0" ] && broken=$((broken + 1))
        printf '%s exists %s %s %s\n' \
            "$nm" "$([ "$on" = "1" ] && echo online || echo offline)" "$lvl" "$atl"
    done <<< "$names"

    printf 'ROSTER %s present=%d/%d online=%d/%d broken=%d\n' \
        "$team" "$present" "$ROSTER_SLOTS" "$online" "$ROSTER_SLOTS" "$broken"
    return 0
}

# Pull one counter out of a captured status block. Parsing status instead of
# re-querying is the point: one place knows the SQL, and every subcommand sees
# the same instant of the world it just acted on.
roster_count() { # <status-text> <key> -> the numerator
    printf '%s\n' "$1" | awk -v k="$2" '
        $1 == "ROSTER" {
            for (i = 3; i <= NF; i++) {
                split($i, kv, "=")
                if (kv[1] == k) { split(kv[2], v, "/"); print v[1]; exit }
            }
        }'
}

roster_missing_names() { # <status-text> -> the names status called missing
    printf '%s\n' "$1" | awk '$2 == "missing" { print $1 }'
}

# --- ensure ------------------------------------------------------------------

roster_ensure() {
    local login_flag="$1" st broken missing lines="" n=0 nm cls race role _fac

    st="$(roster_status)"
    broken="$(roster_count "$st" broken)"
    if [ "${broken:-0}" -gt 0 ]; then
        printf '%s\n' "$st"
        {
            echo "FATAL: $team has ${broken} row(s) with at_login != 0."
            echo "       Those names were rejected at character load. They can never come"
            echo "       online, and creating around them hides the fault instead of fixing"
            echo "       it. Delete them by hand, then re-run:"
            echo "         DELETE FROM tw_char.characters WHERE name='<name>' AND at_login<>0;"
        } >&2
        return 1
    fi

    missing="$(roster_missing_names "$st")"
    if [ -z "$missing" ]; then
        printf '%s\n' "$st"
        echo "ROSTER $team already complete - nothing to create"
        return 0
    fi

    # No leading dot: wsg_console runs at console security, where the dot form is
    # a syntax error. wsg_create_line in wsg-bots-common.sh emits the dotted line
    # on purpose -- that one is for a GM to paste in-game -- so it is deliberately
    # not reused here. gearTier in the team file is not consumed yet; every bot is
    # created at the gear=blue the existing 20-bot roster was built with.
    while IFS='|' read -r nm cls race role _fac; do
        [ -n "$nm" ] || continue
        case $'\n'"$missing"$'\n' in
            *$'\n'"$nm"$'\n'*) ;;
            *) continue ;;
        esac
        lines="${lines}rndbot create name=$nm class=$cls race=$race level=60 role=$role gear=blue login=$login_flag group="$'\n'
        n=$((n + 1))
    done < <(team_rows "$team")

    echo "creating $n character(s) for $team"
    # ONE attach for the whole batch. wsg_console always returns 0 by design and
    # its output is discarded, so the poll below is the only verification there is.
    wsg_console "$lines" "$ROSTER_CONSOLE_WAIT" >/dev/null

    local deadline=$(( $(date +%s) + ROSTER_ENSURE_DEADLINE_S ))
    while :; do
        st="$(roster_status)"
        if [ "$(roster_count "$st" present)" = "$ROSTER_SLOTS" ]; then
            printf '%s\n' "$st"
            return 0
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
            printf '%s\n' "$st"
            echo "FATAL: $team still incomplete ${ROSTER_ENSURE_DEADLINE_S}s after creation" >&2
            return 1
        fi
        sleep 5
    done
}

# --- login / logout ----------------------------------------------------------

# The roster does NOT come back on its own after a mangosd restart: the random
# bot pool re-logs its own bots, and these are not in its login list.
roster_login() {
    local lines="" nm st
    while IFS= read -r nm; do
        [ -n "$nm" ] || continue
        lines="${lines}rndbot add $nm"$'\n'
    done < <(team_names "$team")

    echo "logging in $team"
    wsg_console "$lines" "$ROSTER_CONSOLE_WAIT" >/dev/null

    local deadline=$(( $(date +%s) + ROSTER_LOGIN_DEADLINE_S ))
    while :; do
        st="$(roster_status)"
        if [ "$(roster_count "$st" online)" = "$ROSTER_SLOTS" ]; then
            printf '%s\n' "$st"
            return 0
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
            printf '%s\n' "$st"
            echo "FATAL: $team did not reach online=$ROSTER_SLOTS/$ROSTER_SLOTS within ${ROSTER_LOGIN_DEADLINE_S}s" >&2
            return 1
        fi
        sleep 10
    done
}

# `rndbot remove` unmanages the bot and logs it out. It never touches the
# characters row, which is exactly what a between-rounds swap wants: the team
# still exists, it is just not in the world.
roster_logout() {
    local lines="" nm
    while IFS= read -r nm; do
        [ -n "$nm" ] || continue
        lines="${lines}rndbot remove $nm"$'\n'
    done < <(team_names "$team")

    echo "logging out $team"
    wsg_console "$lines" "$ROSTER_CONSOLE_WAIT" >/dev/null

    roster_status
    # Deliberately no sleep before that status. characters.online is written on
    # save, so it trails reality by up to PlayerSave.Interval (60 s) -- a five
    # second pause would only make a stale reading look considered.
    echo "note: characters.online lags by up to 60s (PlayerSave.Interval); re-run status before concluding"
}

case "$cmd" in
    status) roster_status ;;
    ensure)
        shift 2
        login_flag=0
        case "${1:-}" in
            --login) login_flag=1 ;;
            "")      ;;
            *)       echo "unknown option: $1" >&2; usage ;;
        esac
        roster_ensure "$login_flag"
        ;;
    login)  roster_login ;;
    logout) roster_logout ;;
    *)      usage ;;
esac
