#!/usr/bin/env bash
# Unit tests for the equip gate in scripts/tournament/gear-generate.sh and
# itemdb_equip_fault in scripts/tournament/lib/itemdb.sh.
#
# No server, no database: the docker CLI is stubbed on PATH, so every
# item_template row the gate sees is written here, and the tier files are
# fixtures in a temp directory.
#
# WHAT THIS PINS. An item the target class can never wear must be refused AT
# GENERATION TIME, by name. It used to be discovered a day later, on the console,
# as `ok=0 reason=cannot_equip(8)` from `tournament equip` -- an InventoryResult
# number with no indication of which of a dozen requirements it stood for, on a
# tier file that had already been written and shipped to both teams. Every
# assertion below is about the reason token, not merely about the exit code: a
# gate that rejects without naming the requirement leaves an operator exactly
# where the bare number did.
#
# Run from WSL, not Git Bash: jq is not on Git Bash's PATH on this host and
# require_cmd is a hard exit, not a skip.
#
#   wsl -d Ubuntu -- bash -lc 'cd /mnt/c/... && bash tests/tournament/gear-generate.test.sh'
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/../lib/assert.sh"
. "$HERE/../lib/stub.sh"

require_cmd jq

GEN="$ROOT/scripts/tournament/gear-generate.sh"

TMP="$(mktemp -d)"
ITEMS="$TMP/items"          # one file per entry, holding its item_template row
mkdir -p "$ITEMS"
export ITEMS

GEAR_DIR="$TMP/gear"
mkdir -p "$GEAR_DIR"
export GEAR_DIR

# One stub for both docker calls the gate makes: the password lookup and the
# query. The query is answered from $ITEMS/<entry>, so an entry with no file is
# a row that does not exist -- which is the no_such_item case, not a failure.
STUBS="$(stub_dir)"
stub_cmd "$STUBS" docker '
for a in "$@"; do
  case "$a" in
    printenv) printf "stubpass\n"; exit 0 ;;
    mysql)
      sql="${@: -1}"
      entry="$(printf "%s" "$sql" | sed -n "s/.*entry = \([0-9]*\).*/\1/p" | head -1)"
      [ -n "$entry" ] && [ -f "$ITEMS/$entry" ] && cat "$ITEMS/$entry"
      exit 0 ;;
  esac
done
exit 0'

# The 13 columns of ITEMDB_EQUIP_COLUMNS, in that order. Defaults are a plain
# level-60-legal item so each test changes exactly the one column it is about.
item() { # <entry> <class> <subclass> [<col>=<value>...]
    local entry="$1" cls="$2" sub="$3"; shift 3
    local invtype=5 rlvl=55 amask=-1 arace=-1 rskill=0 rspell=0 rhonor=0 rrep=0
    local flags=0 xflags=0 maxcount=0 kv
    for kv in "$@"; do eval "${kv%%=*}=\"${kv#*=}\""; done
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$cls" "$sub" "$invtype" "$rlvl" "$amask" "$arace" "$rskill" "$rspell" \
        "$rhonor" "$rrep" "$flags" "$xflags" "$maxcount" > "$ITEMS/$entry"
}

# A one-slot tier file. Deliberately not a full 13-slot kit: --check judges what
# is in the file and nothing else, so a single slot isolates the reason under
# test instead of burying it among twelve passes.
tier_file() { # <class> <role> <slot> <entry>
    jq -n --arg c "$1" --arg r "$2" --arg s "$3" --argjson e "$4" '
        { class: $c, role: $r, provisional: true,
          tiers: { base: { rank: 0, items: { ($s): $e } } } }' \
        > "$GEAR_DIR/$1-$2.json"
}

check() { # <class> <role> -> the gate's output with "exit=<rc>" appended
    local out rc=0
    out="$(bash "$GEN" --check "$1" "$2" 2>&1)" || rc=$?
    printf '%s\nexit=%d\n' "$out" "$rc"
}

# --- an item the class CAN wear is not rejected ------------------------------
#
# The negative case first, and it matters as much as the rest: a gate that
# rejects everything would pass every test below and stop the tournament dead.
item 100 4 1                       # cloth chest
tier_file mage dps chest 100
assert_eq "ok mage-dps
exit=0" "$(check mage dps)" \
  "a cloth chest for a mage passes the gate"

# --- armour proficiency: the cannot_equip(8) that actually happened ----------
item 200 4 4                       # plate chest
tier_file mage dps chest 200
assert_contains "$(check mage dps)" \
  "REJECT mage-dps tier 'base' slot 'chest': entry 200 -- no_armor_proficiency(subclass=4)" \
  "a plate chest in a mage tier is rejected by name, not as cannot_equip(8)"
assert_contains "$(check mage dps)" "exit=1" \
  "a rejected tier exits 1"

# --- weapon proficiency ------------------------------------------------------
item 500 2 6 invtype=17            # polearm, two-hand
tier_file mage dps mainhand 500
assert_contains "$(check mage dps)" \
  "entry 500 -- no_weapon_proficiency(subclass=6)" \
  "a polearm in a mage tier is rejected by name"

# A warrior may carry the same polearm, so the reason is about the class and not
# about the item.
tier_file warrior tank mainhand 500
assert_eq "ok warrior-tank
exit=0" "$(check warrior tank)" \
  "the same polearm passes for a warrior"

# --- the remaining equip requirements, each named separately -----------------

item 300 2 7 invtype=13 amask=1     # warrior-only sword
tier_file mage dps mainhand 300
assert_contains "$(check mage dps)" "entry 300 -- class_restricted(allowable_class=1)" \
  "an allowable_class bitmask that excludes the class is named"

item 400 4 1 rlvl=70
tier_file mage dps chest 400
assert_contains "$(check mage dps)" "entry 400 -- required_level(70)" \
  "an item above the level cap is named"

item 410 4 1 arace=1
tier_file mage dps chest 410
assert_contains "$(check mage dps)" "entry 410 -- race_restricted(allowable_race=1)" \
  "a race-locked item is named"

item 420 4 1 rskill=164
tier_file mage dps chest 420
assert_contains "$(check mage dps)" "entry 420 -- required_skill(164)" \
  "a profession-locked item is named"

item 430 4 1 rhonor=7
tier_file mage dps chest 430
assert_contains "$(check mage dps)" "entry 430 -- required_honor_rank(7)" \
  "an honor-rank item is named"

item 440 4 1 flags=16
tier_file mage dps chest 440
assert_contains "$(check mage dps)" "entry 440 -- deprecated_flag" \
  "a deprecated dev item is named"

item 450 4 1 xflags=4
tier_file mage dps chest 450
assert_contains "$(check mage dps)" "entry 450 -- not_obtainable_flag" \
  "an item never obtainable in vanilla is named"

item 460 0 0 invtype=0             # a potion
tier_file mage dps chest 460
assert_contains "$(check mage dps)" "entry 460 -- not_equippable(inventory_type=0)" \
  "a consumable is named as not equippable"

# No row at all: a typo'd id must not read as a silent pass.
tier_file mage dps chest 999
assert_contains "$(check mage dps)" "entry 999 -- no_such_item" \
  "an entry that is not in item_template is named"

# --- a unique item is NOT a generation-time fault ----------------------------
#
# max_count > 0 is deliberately not judged here. 12846 Argent Dawn Commission is
# the only white trinket on this world, so rejecting uniques empties the trinket
# slot for every class and aborts generation outright. Re-applying one to a bot
# that already wears it is `tournament equip`'s problem and is handled there, by
# destroying the bot's existing copies first.
item 700 4 0 invtype=12 maxcount=1
tier_file mage dps trinket1 700
assert_eq "ok mage-dps
exit=0" "$(check mage dps)" \
  "a unique trinket passes the gate -- re-application is the equip command's job"

stub_cleanup "$STUBS"
rm -rf "$TMP"
assert_summary
