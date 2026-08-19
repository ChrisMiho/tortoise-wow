#!/usr/bin/env bash
# Unit tests for the viewer-effect halves of a gear tier:
# gear_items_armor / gear_items_weapon in scripts/tournament/lib/gear.sh.
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

assert_summary
