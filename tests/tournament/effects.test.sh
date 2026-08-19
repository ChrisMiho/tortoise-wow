#!/usr/bin/env bash
# Unit tests for viewer effects: the two halves of a gear tier
# (gear_items_armor / gear_items_weapon in scripts/tournament/lib/gear.sh), and
# the effect library itself (scripts/tournament/lib/effects.sh) -- what makes a
# command well formed and which characters it is allowed to touch -- and the
# append-only queue the mock adapter (scripts/tournament/effect-queue.sh) files
# commands into.
#
# No server and no database. GEAR_DIR points at tests/fixtures/gear -- the
# committed hand-written fixture -- NOT at config/tournament/gear, which is
# written by gear-generate.sh against a live item_template and is empty in every
# checkout where that generator has not been run, including this one.
#
# Run from WSL, not Git Bash: jq is not on Git Bash's PATH on this host and
# require_cmd is a hard exit, not a skip.
#
#   wsl -d Ubuntu -- bash -lc 'cd /mnt/c/... && bash tests/tournament/effects.test.sh'
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/../lib/assert.sh"

require_cmd jq

. "$ROOT/scripts/tournament/lib/gear.sh"
export GEAR_DIR="$ROOT/tests/fixtures/gear"

A="$(gear_items_armor warrior tank base)"
W="$(gear_items_weapon warrior tank base)"

# `upgrade_armor_player` and `upgrade_weapon_player` are separately priced
# effects. If either half leaked the other's slots, a viewer who paid for one
# would get both and the two effects would be indistinguishable.
assert_eq "0" "$(printf '%s\n' "$A" | grep -c '^mainhand|')" \
  "the armour half excludes mainhand -- buying armour does not re-arm the bot"

assert_eq "1" "$(printf '%s\n' "$W" | grep -c '^mainhand|')" \
  "the weapon half includes mainhand -- buying a weapon actually arms the bot"

assert_contains "$A" "chest|" \
  "the armour half includes chest"

assert_eq "0" "$(printf '%s\n' "$W" | grep -c '^chest|')" \
  "the weapon half excludes chest"

# The one that matters. Not a line count: comparing the sorted union against the
# sorted whole also catches a slot that landed in BOTH halves (a viewer paying
# for armour would silently get the weapon too) as well as one that landed in
# neither -- a slot no effect in the catalogue could ever upgrade, which no
# amount of buying would ever fix.
whole="$(gear_items warrior tank base | sort)"
halves="$({ printf '%s\n' "$A"; printf '%s\n' "$W"; } | grep . | sort)"
assert_eq "$whole" "$halves" \
  "armour + weapons reconstitute the tier exactly -- no slot in both, none in neither"

# --- effect validation and targeting ----------------------------------------
#
# Validation and targeting only. effect_apply's own path talks to the control
# plane, which needs a running world, so it is deliberately not exercised here:
# these cases are the half that must hold before any command is allowed near a
# live match, and they hold with nothing standing up.
. "$ROOT/scripts/tournament/lib/team.sh"
. "$ROOT/scripts/tournament/lib/effects.sh"
export TEAM_DIR="$ROOT/config/tournament/teams"

OK='{"id":"a1","ts":"2026-08-16T21:00:00Z","effect":"heal_player","target":{"team":"stormwind-sentinels","slot":"three"},"source":"mock"}'
assert_exit 0 "a well-formed command validates" -- effect_validate "$OK"

# The name is prefix+slot, the same rule roster creation used, so this is also
# the assertion that an effect and the character it means cannot drift apart.
assert_eq "Wsgathree" "$(effect_targets "$OK" stormwind-sentinels orgrimmar-warsong)" \
  "resolves a single-slot target to a character name"

TEAMFX='{"id":"a2","ts":"2026-08-16T21:00:00Z","effect":"heal_team","target":{"team":"orgrimmar-warsong"},"source":"mock"}'
assert_eq "10" "$(effect_targets "$TEAMFX" stormwind-sentinels orgrimmar-warsong | wc -l | tr -d ' ')" \
  "a team effect targets all ten"

# Rejection and reason in one assertion, because a rejection with no reason is
# not much better than none: a queue consumer logs the stderr line beside the
# command it dropped, and "invalid" alone cannot tell a typo'd effect name from
# a team file that has stopped validating.
BADFX='{"id":"a3","ts":"2026-08-16T21:00:00Z","effect":"summon_dragon","target":{"team":"stormwind-sentinels"},"source":"mock"}'
BADOUT="$(effect_validate "$BADFX" 2>&1)"; BADRC=$?
assert_eq "1|unknown effect" "$BADRC|$(printf '%s\n' "$BADOUT" | grep -o 'unknown effect')" \
  "an unknown effect is rejected, and says that is why"

# No id means no dedupe key, so a replayed queue would apply this a second time
# -- a viewer defrauded, or a team wiped twice.
NOID='{"ts":"2026-08-16T21:00:00Z","effect":"heal_team","target":{"team":"stormwind-sentinels"},"source":"mock"}'
assert_exit 1 "a command with no id is rejected" -- effect_validate "$NOID"

# A team not in this match must never be targeted -- the queue outlives a match,
# and those characters are offline, so the effect would report success and do
# nothing at all.
OFFMATCH='{"id":"a4","ts":"2026-08-16T21:00:00Z","effect":"kill_team","target":{"team":"ironforge-anvils"},"source":"mock"}'
assert_exit 1 "a team not playing this match is rejected" -- \
  effect_targets "$OFFMATCH" stormwind-sentinels orgrimmar-warsong

# --- the queue and its mock adapter -----------------------------------------
#
# effect-queue.sh is run as a subprocess, not sourced, because that is how an
# adapter will invoke it. TEAM_DIR is exported above, so the child sees the same
# teams these assertions do.
q="$(mktemp)"

id1="$(bash "$ROOT/scripts/tournament/effect-queue.sh" --queue "$q" \
        --effect heal_team --team stormwind-sentinels --source mock)"
assert_eq "1|1" \
  "$(wc -l < "$q" | tr -d ' ')|$(grep -c '"effect":"heal_team"' "$q")" \
  "one command appends exactly one line, and it carries the effect"

# The echoed id is the only handle the caller gets on the command it just filed;
# if it did not match what was written, a consumer's dedupe list and an adapter's
# idea of what it sent would silently describe different commands.
assert_contains "$(cat "$q")" "\"id\":\"$id1\"" \
  "the id echoed to the caller is the id written to the queue"

first="$(head -1 "$q")"
bash "$ROOT/scripts/tournament/effect-queue.sh" --queue "$q" \
     --effect kill_player --team orgrimmar-warsong --slot five >/dev/null
# Append-only, asserted as such: a line count alone would not catch a rewrite
# that happened to preserve the count, and the consumer may be mid-read.
assert_eq "2|$first" "$(wc -l < "$q" | tr -d ' ')|$(head -1 "$q")" \
  "a second append leaves the first line byte-identical"

assert_contains "$(tail -1 "$q")" '"slot":"five"' \
  "a _player command records the slot it targets"

# Every line independently parseable, not just the file as a whole: the consumer
# reads line by line, and one broken line would poison the file for good.
assert_exit 0 "every queue line is valid JSON on its own" -- \
  bash -c "while IFS= read -r l; do printf '%s' \"\$l\" | jq -e . >/dev/null || exit 1; done < '$q'"

# A command the applier would refuse must never be filed in the first place: in
# the queue it is a landmine the consumer trips over mid-match, with nobody there
# to fix it. So the rejection and the untouched file are one assertion.
BADRC=0
bash "$ROOT/scripts/tournament/effect-queue.sh" --queue "$q" \
     --effect summon_dragon --team stormwind-sentinels >/dev/null 2>&1 || BADRC=$?
assert_eq "1|2" "$BADRC|$(wc -l < "$q" | tr -d ' ')" \
  "an unknown effect is refused at enqueue and nothing is appended"

rm -f "$q"

assert_summary
