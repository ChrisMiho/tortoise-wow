#!/usr/bin/env bash
# Unit tests for scripts/tournament/gear-audit.sh. No server, no database: the
# docker CLI is stubbed on PATH, so every row the audit sees is written here.
#
# Run from WSL, not Git Bash: jq is not on Git Bash's PATH on this host and
# require_cmd is a hard exit, not a skip.
#
#   wsl -d Ubuntu -- bash -lc 'cd /mnt/c/... && bash tests/tournament/gear.test.sh'
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/../lib/assert.sh"
. "$HERE/../lib/stub.sh"

require_cmd jq

AUDIT="$ROOT/scripts/tournament/gear-audit.sh"
SHIPPED="$ROOT/config/tournament/teams"
export TEAM_DIR="$SHIPPED"

TMP="$(mktemp -d)"
ROWS="$TMP/rows.tsv"
QUERIES="$TMP/queries.log"
SQLTEXT="$TMP/sql.txt"
export ROWS QUERIES SQLTEXT

# One stub for both docker calls the audit makes: the password lookup and the
# query itself. Only the query is logged, because "one SQL query for the whole
# team" is a claim about queries, not about docker invocations.
#
# The tally and the SQL go to separate files ON PURPOSE: the statement spans
# several lines, so counting lines in a log of statements would report one query
# as six and this test would pass for the wrong reason.
STUBS="$(stub_dir)"
stub_cmd "$STUBS" docker '
for a in "$@"; do
  case "$a" in
    printenv) printf "stubpass\n"; exit 0 ;;
    mysql)    printf "q\n" >> "$QUERIES"
              printf "%s\n" "$*" >> "$SQLTEXT"
              cat "$ROWS"; exit 0 ;;
  esac
done
exit 0'

ALL13="0,1,2,4,5,6,7,8,9,10,12,14,15"

rows() { : > "$ROWS"; for r in "$@"; do printf '%s\n' "$r" >> "$ROWS"; done; }

# Exit status and output are one observation: an audit that prints the right
# numbers and then returns the wrong code is useless as a gate, and an audit
# that returns the right code while printing nothing is useless to a human.
audit() { # <team-id> -> the audit's output with "exit=<rc>" appended
    local out rc=0
    : > "$QUERIES"; : > "$SQLTEXT"
    out="$(bash "$AUDIT" "$1" 2>&1)" || rc=$?
    printf '%s\nexit=%d\n' "$out" "$rc"
}

A_NAMES="Wsgaone Wsgatwo Wsgathree Wsgafour Wsgafive Wsgasix Wsgaseven Wsgaeight Wsganine Wsgaten"

# --- a fully dressed team is the only thing that may exit 0 -----------------

dressed=()
for n in $A_NAMES; do dressed+=("$(printf '%s\t%s' "$n" "$ALL13")"); done
rows "${dressed[@]}"

expected=""
for n in $A_NAMES; do expected="$expected$n filled=13/13"$'\n'; done
expected="${expected}GEAR-AUDIT stormwind-sentinels complete=10/10 worstMissing=0"$'\n'"exit=0"

assert_eq "$expected" "$(audit stormwind-sentinels)" \
  "a team with all 13 required slots filled reports complete=10/10 and exits 0"

# --- the shape the live database actually had on 2026-08-16 -----------------
#
# These ten rows are the literal result of the audit's own query against the
# live tw_char, so this test pins the known-correct answer -- complete=4/10,
# worstMissing=8 -- and not merely whatever the script happens to compute. If
# the slot set or the join ever drifts, these counts move and this fails.
rows \
  "$(printf 'Wsgaone\t1,9,10,12,14,15')" \
  "$(printf 'Wsgatwo\t1,10,12,14,15')" \
  "$(printf 'Wsgathree\t0,1,2,4,5,6,7,8,9,10,12,14')" \
  "$(printf 'Wsgafour\t%s' "$ALL13")" \
  "$(printf 'Wsgafive\t0,1,2,4,5,7,8,9,10,12,14')" \
  "$(printf 'Wsgasix\t%s' "$ALL13")" \
  "$(printf 'Wsgaseven\t1,10,12,14,15')" \
  "$(printf 'Wsgaeight\t%s' "$ALL13")" \
  "$(printf 'Wsganine\t0,1,2,5,6,7,8,9,10,12,14,15')" \
  "$(printf 'Wsgaten\t%s' "$ALL13")"

live="$(audit stormwind-sentinels)"

assert_eq "$(cat <<'EOF'
Wsgaone filled=6/13 missing=head,shoulders,chest,waist,legs,feet,wrists
Wsgatwo filled=5/13 missing=head,shoulders,chest,waist,legs,feet,wrists,hands
Wsgathree filled=12/13 missing=mainhand
Wsgafour filled=13/13
Wsgafive filled=11/13 missing=legs,mainhand
Wsgasix filled=13/13
Wsgaseven filled=5/13 missing=head,shoulders,chest,waist,legs,feet,wrists,hands
Wsgaeight filled=13/13
Wsganine filled=12/13 missing=chest
Wsgaten filled=13/13
GEAR-AUDIT stormwind-sentinels complete=4/10 worstMissing=8
exit=1
EOF
)" "$live" \
  "the live 2026-08-16 roster reports complete=4/10 worstMissing=8 and exits 1"

# The criterion that matters most for trust: a slot the audit is not allowed to
# want must never be named, however empty it is. tabard(18) and body(3) are
# cosmetic, finger2(11) and trinket2(13) are optional duplicates, offhand(16) is
# empty for every two-handed spec and ranged(17) for several others. None of the
# ten bots above has any of the six, so a wrong slot set would print all of them.
forbidden=""
for s in tabard body finger2 trinket2 offhand ranged; do
    case "$live" in
        *"$s"*) forbidden="$forbidden$s: PRESENT, " ;;
        *)      forbidden="$forbidden$s: absent, " ;;
    esac
done
assert_eq "tabard: absent, body: absent, finger2: absent, trinket2: absent, offhand: absent, ranged: absent, " \
  "$forbidden" \
  "tabard never appears in the output, nor do the five other non-required slots"

# --- one query, and it asks for exactly the 13 required slots ---------------
#
# Ten round trips would be ten chances to half-fail, and a partial answer is
# worse than none. The IN list is checked in the same breath because the count
# and the slot set are the two ways this single query can be wrong.
sql="$(cat "$SQLTEXT")"
q_report="queries=$(wc -l < "$QUERIES" | tr -d ' ')"
case "$sql" in
    *"IN ($ALL13)"*) q_report="$q_report slots=ok" ;;
    *)               q_report="$q_report slots=WRONG" ;;
esac
assert_eq "queries=1 slots=ok" "$q_report" \
  "the whole team costs exactly one SQL query, over exactly the 13 required slots"

# --- a bot that was never created is naked, not absent ----------------------
#
# InitEquipment's level<5 and specId==0 guards return before equipping anything,
# and a create that failed outright leaves no character row at all. Dropping such
# a bot from the report would hide the worst case the audit exists to catch.
rows \
  "$(printf 'Wsgaone\t%s' "$ALL13")" \
  "$(printf 'Wsgatwo\t%s' "$ALL13")" \
  "$(printf 'Wsgathree\t%s' "$ALL13")" \
  "$(printf 'Wsgafour\t%s' "$ALL13")" \
  "$(printf 'Wsgafive\t%s' "$ALL13")" \
  "$(printf 'Wsgasix\t%s' "$ALL13")" \
  "$(printf 'Wsgaeight\t%s' "$ALL13")" \
  "$(printf 'Wsganine\t%s' "$ALL13")" \
  "$(printf 'Wsgaten\t%s' "$ALL13")"

ghost="$(audit stormwind-sentinels | grep -E '^Wsgaseven |^GEAR-AUDIT |^exit=')"
assert_eq "$(cat <<'EOF'
Wsgaseven filled=0/13 missing=head,neck,shoulders,chest,waist,legs,feet,wrists,hands,finger1,trinket1,back,mainhand
GEAR-AUDIT stormwind-sentinels complete=9/10 worstMissing=13
exit=1
EOF
)" "$ghost" \
  "a roster name with no character row is reported filled=0/13, not silently dropped"

# --- it refuses to audit a team it cannot trust -----------------------------
#
# A duplicate slot is a duplicate name, so the second character never got
# created; auditing that roster would count a definition bug as a gear bug.
BADDIR="$TMP/teams"
mkdir -p "$BADDIR"
jq '.roster[1].slot = "one"' < "$SHIPPED/stormwind-sentinels.json" \
    > "$BADDIR/stormwind-sentinels.json"

# An explicit export and restore, not an assignment prefixed to the call: bash
# keeps a prefix assignment on a *function* only in POSIX mode, so that form
# would silently audit the shipped team instead of the broken one.
export TEAM_DIR="$BADDIR"
bad="$(audit stormwind-sentinels)"
export TEAM_DIR="$SHIPPED"
case "$bad" in
    *"refusing to audit"*exit=2) bad="refused, exit 2" ;;
esac
assert_eq "refused, exit 2" "$bad" \
  "a team that fails team_validate is refused with exit 2, not measured"

stub_cleanup "$STUBS"
rm -rf "$TMP"
assert_summary
