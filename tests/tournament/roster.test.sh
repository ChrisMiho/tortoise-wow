#!/usr/bin/env bash
# Tests for scripts/tournament/roster.sh. No server and no database: `docker` and
# `script` are stubbed onto PATH, so every "query" and every console attach is a
# file this file can read back.
#
# Run from WSL, not Git Bash: jq is not on Git Bash's PATH on this host and
# require_cmd is a hard exit, not a skip.
#
#   wsl -d Ubuntu -- bash -lc 'cd /mnt/c/<worktree> && bash tests/tournament/roster.test.sh'
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/../lib/assert.sh"
. "$HERE/../lib/stub.sh"

require_cmd jq

ROSTER="$ROOT/scripts/tournament/roster.sh"
export TEAM_DIR="$ROOT/config/tournament/teams"
. "$ROOT/scripts/tournament/lib/team.sh"

# One second, not twenty: wsg_console really does sleep this long before sending
# the detach keys, and a stub does not need the time.
export ROSTER_CONSOLE_WAIT=1

# Stubs docker and script for one scenario, and sets WORK.
#   $WORK/rows.tsv      what the roster SELECT answers with (name/online/level/at_login)
#   $WORK/queries.log   one line per SQL round trip -- lets a test count them
#   $WORK/console.log   every attach, and the block that was piped into it
setup() {
  WORK="$(stub_dir)"
  export STUB_WORK="$WORK"
  : > "$WORK/rows.tsv"; : > "$WORK/queries.log"; : > "$WORK/console.log"

  # The roster SELECT is the last argument of `docker exec ... mysql -e "<sql>"`.
  # wsg_db_pass's own `docker exec tcm-db printenv ...` falls through to a silent
  # exit 0, which is right: the password never reaches a real mysql anyway. Do
  # not add a second stub for it.
  stub_cmd "$WORK" docker '
last=
for a in "$@"; do last="$a"; done
case "$last" in
  *tw_char.characters*)
    printf "%s\n" "$last" >> "$STUB_WORK/queries.log"
    cat "$STUB_WORK/rows.tsv"
    ;;
esac
exit 0'

  # wsg_console pipes its whole block through `script -qec "docker attach ..."`.
  # The ATTACH marker is what makes the batching rule testable: one marker per
  # attach, and an EOF on any one of them is what shuts the world down.
  stub_cmd "$WORK" script '
printf "\nATTACH\n" >> "$STUB_WORK/console.log"
cat >> "$STUB_WORK/console.log"
exit 0'
}

teardown() { stub_cleanup "$WORK"; }

row() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$WORK/rows.tsv"; }

full_roster() { # ten slots, present, online, level 60, at_login 0
  local n
  while IFS= read -r n; do row "$n" 1 60 0; done < <(team_names stormwind-sentinels)
}

# --- status ------------------------------------------------------------------
#
# Eight of ten slots exist: seven healthy and online, one with at_login=1 (so
# offline, and permanently unusable), and Wsganine/Wsgaten missing entirely.
# One fixture, because these counts only mean anything relative to each other.
setup
for n in Wsgaone Wsgatwo Wsgathree Wsgafour Wsgafive Wsgasix Wsgaseven; do row "$n" 1 60 0; done
row Wsgaeight 0 60 1

OUT="$(bash "$ROSTER" status stormwind-sentinels 2>&1)"; RC=$?

assert_contains "$OUT" "ROSTER stormwind-sentinels present=8/10 online=7/10 broken=1" \
  "status summarises present, online and broken in one line"
assert_contains "$OUT" "Wsganine missing offline - -" \
  "a missing slot still prints five fields, with no invented level or at_login"
assert_contains "$OUT" "Wsgaeight exists offline 60 1" \
  "a row with at_login=1 is reported as it is, not folded into 'offline'"
# The whole roster in one round trip. Ten queries would be ten instants of a
# world that is still moving, and ten times the cost per poll.
assert_eq "1" "$(wc -l < "$WORK/queries.log" | tr -d ' ')" \
  "status asks the database exactly once for the whole roster, not once per slot"
assert_eq "0" "$RC" \
  "status exits 0 even with a broken row -- it reports, it does not judge"
teardown

# --- ensure ------------------------------------------------------------------

setup
full_roster
OUT="$(bash "$ROSTER" ensure stormwind-sentinels 2>&1)"; RC=$?
assert_contains "$OUT" "already complete" "ensure is a no-op when nothing is missing"
assert_eq "0" "$RC" "ensure exits 0 on a complete roster, so it is safe to re-run"
teardown

# Nothing missing, one row broken. ensure must still refuse: "refuses outright"
# is the point, and this fixture is the only one that can tell that apart from
# "had nothing to do anyway".
setup
i=0
while IFS= read -r n; do
  i=$((i + 1))
  if [ "$i" -eq 4 ]; then row "$n" 0 60 1; else row "$n" 1 60 0; fi
done < <(team_names stormwind-sentinels)

OUT="$(bash "$ROSTER" ensure stormwind-sentinels 2>&1)"; RC=$?
# Exit code and message are one observation. A refusal that never says at_login
# sends the operator off waiting for a creation that is never coming.
obs="exit=$RC"
case "$OUT" in
  *at_login*) obs="$obs names-at_login" ;;
  *)          obs="$obs SILENT-ABOUT-WHY" ;;
esac
assert_eq "exit=1 names-at_login" "$obs" \
  "ensure refuses while any row is broken, and the refusal names at_login"
teardown

# --- login / logout ----------------------------------------------------------
#
# The assertion is not just "the right lines went out" but "they went out through
# exactly one attach". Console EOF shuts the world down and compose is
# restart:"no", so ten attaches would be ten chances to kill the server.
console_obs() { # <grep-pattern> -> "lines=<n> attaches=<n>"
  printf 'lines=%s attaches=%s\n' \
    "$(grep -c "$1" "$WORK/console.log")" \
    "$(grep -c '^ATTACH$' "$WORK/console.log")"
}

setup
full_roster
bash "$ROSTER" login stormwind-sentinels >/dev/null 2>&1
assert_eq "lines=10 attaches=1" "$(console_obs 'rndbot add Wsga')" \
  "login sends one rndbot add per slot, batched into a single console attach"
teardown

setup
full_roster
bash "$ROSTER" logout stormwind-sentinels >/dev/null 2>&1
assert_eq "lines=10 attaches=1" "$(console_obs 'rndbot remove Wsga')" \
  "logout sends one rndbot remove per slot, batched into a single console attach"
# logout is the between-rounds swap, not a teardown: the characters have to still
# be there next round. Checks the SQL too, not just the console -- a DELETE could
# come from either side.
assert_eq "0" "$(cat "$WORK/console.log" "$WORK/queries.log" | grep -ci 'delete')" \
  "logout never deletes a character row, from the console or from SQL"
teardown

assert_summary
