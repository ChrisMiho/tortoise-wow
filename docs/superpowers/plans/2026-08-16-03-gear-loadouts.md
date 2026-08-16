# Itemized Gear Loadouts & Tiers — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every tournament bot wears a known, complete, class-appropriate level-60
kit — and named upgrade tiers exist so a viewer donation has something real to
promote a bot into.

**Architecture:** An audit tool that proves what is actually equipped, a derivation
query that proposes candidate items from `tw_world.item_template`, hand-reviewable
JSON tier files, and an apply script that drives `tournament equip`. The audit is
first because the bug it measures — bots ending up naked or half-dressed — is the
reason this plan exists.

**Tech Stack:** Bash (WSL), `jq`, MySQL via `docker exec tcm-db`, the `.tournament`
control plane.

**Spec:** `docs/superpowers/specs/2026-08-16-bot-tournament-design.md` (§4.4)

**Depends on:** `2026-08-16-01-team-definitions-and-rosters.md` (team JSON and
`roster.sh`) and `2026-08-16-02-tournament-control-plane.md` (`tournament equip`).

## Global Constraints

- Equipment slots are `0..18` (`Player.h:590-610`). `BODY` (3) and `TABARD` (18) are
  cosmetic and are **not** required. `FINGER2` (11) and `TRINKET2` (13) are optional
  duplicates of their siblings.
- `item_template` columns used here: `entry`, `class`, `subclass`, `name`, `Quality`,
  `InventoryType`, `AllowableClass`, `ItemLevel`, `RequiredLevel`
  (`ItemPrototype.h:432-441`). **Verify the schema before trusting it** — Task 2
  Step 1.
- `AllowableClass` is a **bitmask**, not a class id. Class *N* is bit `1 << (N-1)`,
  and `-1` means all classes.
- Gear is applied through `tournament equip <name> <ids>`, which requires the bot to
  be **online**. Offline bots must be logged in with `roster.sh login` first.
- `tournament equip` calls `SaveToDB()` per invocation, so gear survives an immediate
  `roster.sh logout`.
- Never write to `character_inventory` or `item_instance` directly while a character
  is online — the next player save overwrites it.

---

## Why this plan exists

`rndbot create ... gear=blue` maps to
`PlayerbotFactory(bot, level, ITEM_QUALITY_RARE).EquipGear()`
(`RandomPlayerbotMgr.cpp:930-935`), which calls `InitEquipment(false, false)`. That
function (`PlayerbotFactory.cpp:2969`) has three behaviours that together produce the
partially-dressed bots observed during WSG testing:

1. **It destroys everything first.** With `incremental == false` it runs
   `DestroyItemsVisitor` across all equipped items (`PlayerbotFactory.cpp:2999-3003`)
   *before* choosing replacements. Any slot it then fails to fill is left empty — the
   bot is stripped whether or not a replacement was ever found.
2. **It bails out entirely below level 5** (`PlayerbotFactory.cpp:2974-2980`).
3. **It bails out when `specId == 0`** (`PlayerbotFactory.cpp:2988-2994`). Both guards
   carry comments saying they exist *because* the code stripped bots naked.

So "gear=blue" means "destroy everything, then equip whatever rare items happen to
match" — with no completeness check anywhere. This plan does not fix
`InitEquipment`; it replaces reliance on it for tournament bots with explicit item
lists, and adds the audit that would have caught it.

---

## File Structure

| File | Responsibility |
|---|---|
| `scripts/tournament/gear-audit.sh` (create) | Report every empty/mismatched equipment slot for a team |
| `scripts/tournament/gear-derive.sh` (create) | Propose candidate items per class/role/slot from `item_template` |
| `config/tournament/gear/<class>-<role>.json` (create) | Reviewed tier definitions |
| `scripts/tournament/lib/gear.sh` (create) | Load and validate gear tier files |
| `scripts/tournament/gear-apply.sh` (create) | Apply a tier to a bot or a whole team |
| `tests/tournament/gear.test.sh` (create) | Unit tests for the library and slot mapping |

---

### Task 1: Gear audit — measure the problem before fixing it

**Files:**
- Create: `scripts/tournament/gear-audit.sh`
- Test: `tests/tournament/gear.test.sh`

**Interfaces:**
- Consumes: `team_names` from `scripts/tournament/lib/team.sh`, `wsg_mysql`.
- Produces: `scripts/tournament/gear-audit.sh <team-id> [--required-only]` →
  one line per bot: `<name> filled=<n>/<required> missing=<slotname,slotname,...>`,
  then `GEAR-AUDIT <team-id> complete=<n>/10 worstMissing=<n>`.
  Exit 0 if every bot is complete, 1 otherwise.

- [ ] **Step 1: Write the failing test**

```bash
# tests/tournament/gear.test.sh
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
. "$HERE/../lib/assert.sh"
. "$HERE/../lib/stub.sh"

require_cmd jq

d="$(stub_dir)"
# Every bot has head(0) and chest(4) only -- so 2 filled, the rest missing.
stub_cmd "$d" docker '
for a in "$@"; do last="$a"; done
case "$last" in
  *character_inventory*)
    for n in Wsgaone Wsgatwo Wsgathree Wsgafour Wsgafive Wsgasix Wsgaseven Wsgaeight Wsganine Wsgaten; do
      printf "%s\t0\t12640\n" "$n"
      printf "%s\t4\t11726\n" "$n"
    done ;;
esac
exit 0'

OUT="$(TEAM_DIR="$ROOT/config/tournament/teams" \
       bash "$ROOT/scripts/tournament/gear-audit.sh" stormwind-sentinels 2>&1)"
RC=$?

assert_eq "1" "$RC" "audit exits 1 when bots are incomplete"
assert_contains "$OUT" "complete=0/10" "no bot is complete"
assert_contains "$OUT" "mainhand"      "names the missing weapon slot"
assert_contains "$OUT" "legs"          "names a missing armour slot"
assert_contains "$OUT" "filled=2"      "counts what is actually there"
# Cosmetic slots must never be reported as missing gear.
OUT_NOBODY="$(printf '%s\n' "$OUT" | grep -c 'tabard')"
assert_eq "0" "$OUT_NOBODY" "tabard is not treated as required"

stub_cleanup "$d"
assert_summary
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/tournament/gear.test.sh`
Expected: FAIL — `scripts/tournament/gear-audit.sh: No such file or directory`

- [ ] **Step 3: Write the audit**

```bash
#!/usr/bin/env bash
# What is each bot on this team actually wearing?
#
#   ./scripts/tournament/gear-audit.sh <team-id>
#
# Read-only. Exists because `rndbot create gear=blue` runs InitEquipment, which
# destroys every equipped item BEFORE choosing replacements
# (PlayerbotFactory.cpp:2999) and leaves any slot it cannot fill empty. Nothing
# in that path checks completeness, so a half-dressed bot looks like a success.
#
# Exit 0 = every bot has every required slot filled. Exit 1 = at least one hole.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/lib/team.sh"
# shellcheck source=/dev/null
. "$ROOT/docs/playerbots/wsg/lib/wsg-bots-common.sh"

team="${1:-}"
[ -n "$team" ] || { echo "usage: gear-audit.sh <team-id>" >&2; exit 2; }
team_validate "$team" || exit 2

# Slot id -> name, per Player.h:590-610.
GEAR_SLOT_NAMES="head neck shoulders body chest waist legs feet wrists hands \
finger1 finger2 trinket1 trinket2 back mainhand offhand ranged tabard"

# What a dressed level-60 must have. body(3) and tabard(18) are cosmetic;
# finger2(11) and trinket2(13) are optional duplicates; offhand(16) depends on
# whether the class two-hands, and ranged(17) is empty for several specs -- so
# none of those four are required and their absence is not a defect.
GEAR_REQUIRED_SLOTS="0 1 2 4 5 6 7 8 9 10 12 14 15"

slot_name() { # <slot-id>
    set -- $GEAR_SLOT_NAMES
    eval "printf '%s\n' \"\${$(( $1 + 1 ))}\""
}

required_count() { set -- $GEAR_REQUIRED_SLOTS; echo $#; }

names="$(team_names "$team")"
inlist=""
while IFS= read -r n; do inlist="$inlist${inlist:+,}'$n'"; done <<< "$names"

# One query for the whole team. Equipped items live in bag 0, slots 0-18.
rows="$(wsg_mysql "SELECT c.name, ci.slot, ii.itemEntry
                   FROM tw_char.characters c
                   JOIN tw_char.character_inventory ci ON ci.guid = c.guid
                   JOIN tw_char.item_instance ii ON ii.guid = ci.item
                   WHERE c.name IN ($inlist) AND ci.bag = 0 AND ci.slot <= 18
                   ORDER BY c.name, ci.slot;")"

need="$(required_count)"
complete=0
worst=0
rc=0

while IFS= read -r nm; do
    filled=0
    missing=""
    for s in $GEAR_REQUIRED_SLOTS; do
        if printf '%s\n' "$rows" | awk -F'\t' -v n="$nm" -v sl="$s" \
             '$1 == n && $2 == sl { found = 1 } END { exit !found }'; then
            filled=$((filled + 1))
        else
            missing="$missing${missing:+,}$(slot_name "$s")"
        fi
    done

    gap=$((need - filled))
    [ "$gap" -gt "$worst" ] && worst=$gap
    if [ "$gap" -eq 0 ]; then
        complete=$((complete + 1))
        printf '%-14s filled=%d/%d\n' "$nm" "$filled" "$need"
    else
        rc=1
        printf '%-14s filled=%d/%d missing=%s\n' "$nm" "$filled" "$need" "$missing"
    fi
done <<< "$names"

printf 'GEAR-AUDIT %s complete=%d/10 worstMissing=%d\n' "$team" "$complete" "$worst"
exit $rc
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bash tests/tournament/gear.test.sh`
Expected: `6 passed, 0 failed`, exit 0

- [ ] **Step 5: Measure the real problem**

```bash
./scripts/tournament/roster.sh login stormwind-sentinels
./scripts/tournament/gear-audit.sh stormwind-sentinels; echo "exit=$?"
./scripts/tournament/gear-audit.sh orgrimmar-warsong;   echo "exit=$?"
```

Record the literal output in the commit message. This is the measurement of the
naked-bot behaviour, and it is the baseline every later task is judged against.
An `exit=0` here would mean the current roster is fully geared and the problem is
narrower than believed — that is a valid and useful result, so report it honestly
either way.

- [ ] **Step 6: Commit**

```bash
git add scripts/tournament/gear-audit.sh tests/tournament/gear.test.sh
git commit -m "feat(tournament): gear-audit.sh reports empty equipment slots

Baseline measured on the existing roster:
<paste the two GEAR-AUDIT lines here>"
```

---

### Task 2: Candidate derivation from `item_template`

**Files:**
- Create: `scripts/tournament/gear-derive.sh`

**Interfaces:**
- Produces: `scripts/tournament/gear-derive.sh <classId> <quality> [maxItemLevel]` →
  TSV `slotName<TAB>entry<TAB>name<TAB>itemLevel<TAB>quality`, the best few
  candidates per required slot, for hand review.

This proposes; a human (or a reviewing agent) chooses. It never writes a tier file
directly — an auto-picked kit is exactly the unreviewed outcome this plan is
replacing.

- [ ] **Step 1: Verify the schema before relying on it**

```bash
MSYS_NO_PATHCONV=1 bash <<'EOF'
source docs/playerbots/wsg/lib/wsg-bots-common.sh
wsg_mysql "SHOW COLUMNS FROM tw_world.item_template;" | awk '{print $1}' | tr '\n' ' '
EOF
```

Expected to include: `entry class subclass name Quality InventoryType
AllowableClass ItemLevel RequiredLevel`. If any name differs on this server, use
the real name and note the difference at the top of the script — do not guess.

- [ ] **Step 2: Write the script**

```bash
#!/usr/bin/env bash
# Propose candidate items per equipment slot, for hand review.
#
#   ./scripts/tournament/gear-derive.sh <classId> <quality> [maxItemLevel]
#
#   classId : 1 warrior 2 paladin 3 hunter 4 rogue 5 priest
#             7 shaman 8 mage 9 warlock 11 druid
#   quality : 2 uncommon(green) 3 rare(blue) 4 epic(purple)
#
# This PROPOSES. It never writes a tier file -- an auto-picked kit is exactly the
# unreviewed outcome that produced half-dressed bots in the first place.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/docs/playerbots/wsg/lib/wsg-bots-common.sh"

cls="${1:-}"; quality="${2:-3}"; maxIlvl="${3:-70}"
[ -n "$cls" ] || { echo "usage: gear-derive.sh <classId> <quality> [maxItemLevel]" >&2; exit 2; }

# InventoryType -> equipment slot name. Only the required slots; a type that maps
# to two slots (rings, trinkets) is reported once under its first.
# INVTYPE values are ItemPrototype.h:109.
map_rows() {
cat <<'MAP'
1|head
2|neck
3|shoulders
5|chest
20|chest
6|waist
7|legs
8|feet
9|wrists
10|hands
11|finger1
12|trinket1
16|back
13|mainhand
17|mainhand
21|mainhand
MAP
}

# AllowableClass is a BITMASK, not a class id: class N is bit 1<<(N-1), and -1
# means every class. Comparing it to the class id directly returns nonsense.
mask=$(( 1 << (cls - 1) ))

printf 'slot\tentry\tname\titemLevel\tquality\n'
while IFS='|' read -r invtype slot; do
    wsg_mysql "SELECT '$slot', entry, name, ItemLevel, Quality
               FROM tw_world.item_template
               WHERE InventoryType = $invtype
                 AND Quality = $quality
                 AND RequiredLevel BETWEEN 55 AND 60
                 AND ItemLevel <= $maxIlvl
                 AND (AllowableClass = -1 OR (AllowableClass & $mask) > 0)
               ORDER BY ItemLevel DESC, entry ASC
               LIMIT 5;"
done < <(map_rows)
```

- [ ] **Step 3: Run it for one class and sanity-check the output**

```bash
./scripts/tournament/gear-derive.sh 1 3 | head -30
```

Expected: a TSV where every `slot` value is a required slot name, every
`itemLevel` is ≤ 70, and the names are plausible level-60 warrior rare items.

**Sanity gate:** if a cloth robe appears under a warrior's `chest`, the
`AllowableClass` bitmask is being applied wrongly — stop and fix the mask before
building tiers on the output.

- [ ] **Step 4: Commit**

```bash
git add scripts/tournament/gear-derive.sh
git commit -m "feat(tournament): derive candidate gear per class from item_template"
```

---

### Task 3: Gear tier files and their validation library

**Files:**
- Create: `config/tournament/gear/warrior-tank.json` (and one file per class/role in
  the two shipped teams — 12 combinations, listed in Step 3)
- Create: `scripts/tournament/lib/gear.sh`
- Modify: `tests/tournament/gear.test.sh`

**Interfaces:**
- Produces:
  - `gear_file <class> <role>` → path, exit 1 if absent
  - `gear_tiers <class> <role>` → tier names ordered by `rank`, one per line
  - `gear_items <class> <role> <tier>` → `slotName|itemId` lines
  - `gear_next_tier <class> <role> <current>` → the next tier by rank, empty at the top
  - `gear_validate <class> <role>` → exit 0 if valid, else print faults

- [ ] **Step 1: Write the failing test**

Append to `tests/tournament/gear.test.sh` before `assert_summary`:

```bash
# --- gear tier library ----------------------------------------------------
. "$ROOT/scripts/tournament/lib/gear.sh"
export GEAR_DIR="$ROOT/config/tournament/gear"

assert_exit 0 "warrior-tank validates" -- gear_validate warrior tank
assert_eq "base"    "$(gear_tiers warrior tank | head -1)" "tiers are ordered by rank"
assert_eq "upgrade" "$(gear_next_tier warrior tank base)"  "next tier after base"
assert_eq ""        "$(gear_next_tier warrior tank upgrade)" "no tier above the top"
assert_contains "$(gear_items warrior tank base)" "mainhand|" "base tier has a weapon"

# Every required slot must be present in every tier -- a tier with a hole is the
# bug being fixed, not a tier.
tmp="$(mktemp -d)"; export GEAR_DIR="$tmp"
jq 'del(.tiers.base.items.mainhand)' "$ROOT/config/tournament/gear/warrior-tank.json" \
  > "$tmp/warrior-tank.json"
assert_exit 1 "a tier missing a required slot is rejected" -- gear_validate warrior tank
assert_contains "$(gear_validate warrior tank 2>&1)" "mainhand" "and names the slot"
rm -rf "$tmp"
export GEAR_DIR="$ROOT/config/tournament/gear"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/tournament/gear.test.sh`
Expected: FAIL — `scripts/tournament/lib/gear.sh: No such file or directory`

- [ ] **Step 3: Write the tier files**

Create one file per class/role combination appearing in the two shipped teams:

`warrior-tank`, `warrior-dps`, `paladin-tank`, `priest-healer`, `druid-healer`,
`druid-tank`, `mage-dps`, `warlock-dps`, `hunter-dps`, `rogue-dps`,
`shaman-healer`, `shaman-dps`.

Each follows this shape. Fill the item IDs from `gear-derive.sh` output for that
class, reviewing each pick — `base` from quality 3 (rare), `upgrade` from quality 4
(epic) where one exists at level 60, otherwise the highest-item-level rare:

```json
{
  "class": "warrior",
  "role": "tank",
  "tiers": {
    "base": {
      "rank": 0,
      "items": {
        "head": 0, "neck": 0, "shoulders": 0, "chest": 0, "waist": 0,
        "legs": 0, "feet": 0, "wrists": 0, "hands": 0, "finger1": 0,
        "trinket1": 0, "back": 0, "mainhand": 0
      }
    },
    "upgrade": {
      "rank": 1,
      "items": {
        "head": 0, "neck": 0, "shoulders": 0, "chest": 0, "waist": 0,
        "legs": 0, "feet": 0, "wrists": 0, "hands": 0, "finger1": 0,
        "trinket1": 0, "back": 0, "mainhand": 0
      }
    }
  },
  "consumables": [
    { "itemId": 13446, "count": 20 },
    { "itemId": 8952,  "count": 20 }
  ]
}
```

Every `0` must be replaced with a real `entry`. Task 4 Step 2 verifies that every
id exists and is equippable, so a leftover `0` fails there rather than silently
shipping.

`13446` is Major Healing Potion and `8952` is Roasted Quail — confirm both exist on
this server with the query in Task 4 Step 2 before relying on them.

- [ ] **Step 4: Write the library**

```bash
#!/usr/bin/env bash
# Read and validate gear tier definitions. Source, don't execute.

GEAR_DIR="${GEAR_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/config/tournament/gear}"

# Must match GEAR_REQUIRED_SLOTS in gear-audit.sh. If one changes, change both --
# a tier that validates but audits as incomplete is worse than either alone.
GEAR_REQUIRED_NAMES="head neck shoulders chest waist legs feet wrists hands finger1 trinket1 back mainhand"

gear_file() { # <class> <role>
    local f="$GEAR_DIR/$1-$2.json"
    [ -f "$f" ] || { echo "no gear file for $1-$2 (looked in $GEAR_DIR)" >&2; return 1; }
    printf '%s\n' "$f"
}

gear_tiers() { # <class> <role>
    local f; f="$(gear_file "$1" "$2")" || return 1
    jq -r '.tiers | to_entries | sort_by(.value.rank) | .[].key' < "$f"
}

gear_items() { # <class> <role> <tier>
    local f; f="$(gear_file "$1" "$2")" || return 1
    jq -r --arg t "$3" '.tiers[$t].items | to_entries[] | .key + "|" + (.value|tostring)' < "$f"
}

# The tier one rank above the current one. Empty at the top -- an upgrade effect
# that has run out of tiers is a no-op, never a wrap-around to base.
gear_next_tier() { # <class> <role> <current-tier>
    local f; f="$(gear_file "$1" "$2")" || return 1
    jq -r --arg c "$3" '
        (.tiers[$c].rank // -1) as $r
        | .tiers | to_entries | map(select(.value.rank > $r)) | sort_by(.value.rank)
        | if length > 0 then .[0].key else "" end' < "$f"
}

gear_validate() { # <class> <role>
    local f faults=0 t
    f="$(gear_file "$1" "$2")" || return 1
    jq -e . < "$f" >/dev/null 2>&1 || { echo "$1-$2: not valid JSON" >&2; return 1; }

    [ "$(jq -r '.class' < "$f")" = "$1" ] || { echo "$1-$2: .class does not match the filename" >&2; faults=1; }
    [ "$(jq -r '.role'  < "$f")" = "$2" ] || { echo "$1-$2: .role does not match the filename" >&2; faults=1; }

    local n; n="$(jq -r '.tiers | length' < "$f")"
    [ "$n" -ge 2 ] || { echo "$1-$2: needs at least two tiers, has $n" >&2; faults=1; }

    # Ranks must be unique, or gear_next_tier's ordering is arbitrary.
    local ranks uniq
    ranks="$(jq -r '.tiers[].rank' < "$f" | sort)"
    uniq="$(printf '%s\n' "$ranks" | sort -u)"
    [ "$ranks" = "$uniq" ] || { echo "$1-$2: tier ranks must be unique" >&2; faults=1; }

    while IFS= read -r t; do
        local slot id
        for slot in $GEAR_REQUIRED_NAMES; do
            id="$(jq -r --arg t "$t" --arg s "$slot" '.tiers[$t].items[$s] // "MISSING"' < "$f")"
            if [ "$id" = "MISSING" ] || [ "$id" = "null" ]; then
                echo "$1-$2: tier '$t' has no item for required slot '$slot'" >&2
                faults=1
            elif [ "$id" = "0" ]; then
                echo "$1-$2: tier '$t' slot '$slot' is still a placeholder 0" >&2
                faults=1
            fi
        done
    done < <(jq -r '.tiers | keys[]' < "$f")

    return "$faults"
}
```

- [ ] **Step 5: Run it to verify it passes**

Run: `bash tests/tournament/gear.test.sh`
Expected: `12 passed, 0 failed`, exit 0

- [ ] **Step 6: Commit**

```bash
git add config/tournament/gear scripts/tournament/lib/gear.sh tests/tournament/gear.test.sh
git commit -m "feat(tournament): itemized gear tiers per class and role"
```

---

### Task 4: Apply a tier to a bot or a team

**Files:**
- Create: `scripts/tournament/gear-apply.sh`

**Interfaces:**
- Consumes: `gear_items`, `team_rows`, `ctl` from
  `scripts/tournament/lib/ctl.sh`.
- Produces:
  - `gear-apply.sh team <team-id> [--tier <name>]` — applies each member's
    class/role tier, defaulting to the team's `gearTier`
  - `gear-apply.sh player <team-id> <slot> [--tier <name>]` — one bot
  - Exit 0 only if a follow-up `gear-audit.sh` reports the team complete.

- [ ] **Step 1: Verify every item id exists and is equippable**

Before applying anything, prove the tier files reference real items. Run:

```bash
MSYS_NO_PATHCONV=1 bash <<'EOF'
source docs/playerbots/wsg/lib/wsg-bots-common.sh
source scripts/tournament/lib/gear.sh
ids=$(for f in config/tournament/gear/*.json; do
        jq -r '.tiers[].items[], (.consumables[]?.itemId)' "$f"
      done | sort -un | grep -v '^0$' | paste -sd, -)
echo "checking $(echo "$ids" | tr ',' '\n' | wc -l) distinct item ids"
wsg_mysql "SELECT entry, name, Quality, RequiredLevel, InventoryType
           FROM tw_world.item_template WHERE entry IN ($ids);" | wc -l
EOF
```

Expected: the returned row count equals the number of distinct ids. A shortfall
means at least one id does not exist on this server — find which with a
`NOT IN` query and fix the tier file before continuing.

- [ ] **Step 2: Write the script**

```bash
#!/usr/bin/env bash
# Apply a gear tier to a bot or a whole team.
#
#   ./scripts/tournament/gear-apply.sh team   <team-id> [--tier <name>]
#   ./scripts/tournament/gear-apply.sh player <team-id> <slot> [--tier <name>]
#
# Bots must be ONLINE -- `tournament equip` resolves the player by name through
# ObjectAccessor. Run roster.sh login first.
#
# Exit 0 only if the follow-up audit reports the team complete. "The commands
# were sent" is not success; a filled slot is.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/lib/team.sh"
. "$HERE/lib/gear.sh"
. "$HERE/lib/ctl.sh"
# shellcheck source=/dev/null
. "$ROOT/docs/playerbots/wsg/lib/wsg-bots-common.sh"

mode="${1:-}"; team="${2:-}"
[ -n "$mode" ] && [ -n "$team" ] || { echo "usage: gear-apply.sh {team|player} <team-id> [slot] [--tier <name>]" >&2; exit 2; }
team_validate "$team" || exit 2

want_slot=""
[ "$mode" = "player" ] && { want_slot="${3:-}"; shift 3; } || shift 2
tier_override=""
[ "${1:-}" = "--tier" ] && tier_override="${2:-}"

default_tier="$(team_field "$team" '.gearTier')"

apply_one() { # <name> <class> <role>
    local nm="$1" cls="$2" role="$3" tier ids out
    tier="${tier_override:-$default_tier}"

    gear_validate "$cls" "$role" || { echo "SKIP $nm: $cls-$role does not validate" >&2; return 1; }

    ids="$(gear_items "$cls" "$role" "$tier" | cut -d'|' -f2 | paste -sd, -)"
    if [ -z "$ids" ]; then
        echo "SKIP $nm: tier '$tier' has no items for $cls-$role" >&2
        return 1
    fi

    out="$(ctl "tournament equip $nm $ids")"
    printf '%s\n' "$out" | grep -a "equipped=" || printf '%s\n' "$out"

    local failed; failed="$(ctl_field "$out" failed)"
    [ "${failed:-0}" = "0" ]
}

rc=0
while IFS='|' read -r nm cls race role fac; do
    [ -n "$nm" ] || continue
    if [ -n "$want_slot" ]; then
        [ "$nm" = "$(team_field "$team" '.namePrefix')$want_slot" ] || continue
    fi
    apply_one "$nm" "$cls" "$role" || rc=1
done < <(team_rows "$team")

echo "==> re-auditing"
"$HERE/gear-audit.sh" "$team" || rc=1
exit $rc
```

- [ ] **Step 3: Apply and prove it closed the gap**

```bash
./scripts/tournament/roster.sh login stormwind-sentinels
./scripts/tournament/gear-audit.sh stormwind-sentinels          # the "before"
./scripts/tournament/gear-apply.sh team stormwind-sentinels
```

Expected: the final `GEAR-AUDIT stormwind-sentinels complete=10/10 worstMissing=0`
and exit 0.

If a bot still reports missing slots, the `reason=cannot_equip(<n>)` lines from
`tournament equip` say why — look the code up in `InventoryResult`
(`SharedDefines.h`). A class or level restriction is a bad item choice in the tier
file, not a broken script; fix the tier and re-run.

- [ ] **Step 4: Prove an upgrade tier moves the bot**

```bash
./scripts/tournament/gear-apply.sh player stormwind-sentinels one --tier upgrade
```

Then confirm the head slot changed:

```bash
MSYS_NO_PATHCONV=1 bash <<'EOF'
source docs/playerbots/wsg/lib/wsg-bots-common.sh
wsg_mysql "SELECT ci.slot, ii.itemEntry FROM tw_char.character_inventory ci
           JOIN tw_char.item_instance ii ON ii.guid=ci.item
           JOIN tw_char.characters c ON c.guid=ci.guid
           WHERE c.name='Wsgaone' AND ci.bag=0 AND ci.slot=0;"
EOF
```

Expected: the `upgrade` tier's head item id, not the `base` one. This is the
mechanism the viewer "upgrade armor" effect will call.

- [ ] **Step 5: Commit**

```bash
git add scripts/tournament/gear-apply.sh
git commit -m "feat(tournament): apply itemized gear tiers to a bot or a team

Before: <paste the baseline GEAR-AUDIT line>
After:  <paste the post-apply GEAR-AUDIT line>"
```

---

### Task 5: Consumables, and document the gear model

**Files:**
- Modify: `scripts/tournament/gear-apply.sh` (add `--with-consumables`)
- Create: `docs/playerbots/TOURNAMENT-GEAR.md`

**Interfaces:**
- Produces: `gear-apply.sh team <team-id> --with-consumables` — additionally puts
  each tier file's `consumables` into the bot's bags.

- [ ] **Step 1: Check whether the control plane can put items in bags**

`tournament equip` equips; it does not store. Confirm which of these is true on
this build:

```bash
MSYS_NO_PATHCONV=1 bash <<'EOF'
source docs/playerbots/wsg/lib/wsg-bots-common.sh
wsg_console "tournament equip Wsgaone 13446" 8
EOF
```

Expected: `ok=0 reason=cannot_equip(...)` — a potion is not equippable, which is
correct behaviour and proves `equip` is the wrong verb for consumables.

- [ ] **Step 2: Add a `store` subcommand to the control plane**

In `src/game/Commands/TournamentCommands.cpp`, add alongside the equip handler:

```cpp
bool ChatHandler::HandleTournamentStoreCommand(char* args)
{
    char* nameStr = ExtractQuotedOrLiteralArg(&args);
    uint32 itemId = 0, count = 0;
    if (!nameStr || !ExtractUInt32(&args, itemId) || !ExtractUInt32(&args, count))
    {
        TournamentEmit("store error=usage(.tournament store <playerName> <itemId> <count>)");
        return true;
    }

    std::string name = nameStr;
    Player* plr = sObjectAccessor.FindPlayerByName(name.c_str());
    if (!plr)
    {
        TournamentEmit("store error=player_not_online(" + name + ")");
        return true;
    }

    ItemPosCountVec dest;
    InventoryResult res = plr->CanStoreNewItem(NULL_BAG, NULL_SLOT, dest, itemId, count);
    std::ostringstream ss;
    ss << "store player=" << name << " item=" << itemId << " count=" << count;

    if (res != EQUIP_ERR_OK)
    {
        ss << " ok=0 reason=cannot_store(" << uint32(res) << ")";
        TournamentEmit(ss.str());
        return true;
    }

    plr->StoreNewItem(dest, itemId, true);
    plr->SaveToDB();
    ss << " ok=1 reason=-";
    TournamentEmit(ss.str());
    return true;
}
```

Declare it in `Chat.h` and register it in `tournamentCommandTable`:

```cpp
        { "store",   SEC_ADMINISTRATOR, true,  &ChatHandler::HandleTournamentStoreCommand,   "", nullptr },
```

- [ ] **Step 3: Build and verify**

Run: `./scripts/rebuild.sh` then `./scripts/validate-stack.sh --image tortoise-cm:local --keep-up`

```bash
MSYS_NO_PATHCONV=1 bash <<'EOF'
source docs/playerbots/wsg/lib/wsg-bots-common.sh
wsg_console "tournament store Wsgaone 13446 5" 8
sleep 3
wsg_mysql "SELECT COUNT(*) FROM tw_char.character_inventory ci
           JOIN tw_char.item_instance ii ON ii.guid=ci.item
           JOIN tw_char.characters c ON c.guid=ci.guid
           WHERE c.name='Wsgaone' AND ii.itemEntry=13446;"
EOF
```

Expected: `TOURNAMENT store ... ok=1`, then a non-zero count.

An `ok=0 reason=cannot_store(...)` most likely means no free bag space — bots ship
with small default bags. If so, note it in the doc and have `gear-apply.sh` report
it rather than silently dropping consumables.

- [ ] **Step 4: Wire consumables into `gear-apply.sh`**

Add to the argument parsing:

```bash
with_consumables=0
for a in "$@"; do [ "$a" = "--with-consumables" ] && with_consumables=1; done
```

and inside `apply_one`, after the equip block:

```bash
    if [ "$with_consumables" = "1" ]; then
        local cf; cf="$(gear_file "$cls" "$role")" || return 1
        while IFS='|' read -r item cnt; do
            [ -n "$item" ] || continue
            ctl "tournament store $nm $item $cnt" | grep -a "store player=" || true
        done < <(jq -r '.consumables[]? | (.itemId|tostring) + "|" + (.count|tostring)' < "$cf")
    fi
```

- [ ] **Step 5: Write the doc**

`docs/playerbots/TOURNAMENT-GEAR.md`:

```markdown
# Tournament gear

Tournament bots do not use `rndbot ... gear=blue`. Their kit is an explicit item
list per class, role, and tier, in `config/tournament/gear/<class>-<role>.json`.

## Why not the built-in gear system

`gear=blue` maps to `PlayerbotFactory(bot, level, ITEM_QUALITY_RARE).EquipGear()`
→ `InitEquipment(false, false)`. That function **destroys every equipped item
before choosing replacements** (`PlayerbotFactory.cpp:2999`), and leaves any slot
it cannot fill empty. It also returns early — equipping nothing at all — below
level 5 and whenever `specId == 0`. Nothing in the path checks completeness, so a
half-dressed bot is indistinguishable from a success.

That is the observed "bots with weapons and no armour" behaviour. This system
replaces it for tournament bots and adds the audit that catches it.

## Commands

```bash
./scripts/tournament/gear-audit.sh  <team-id>                      # what is actually worn
./scripts/tournament/gear-derive.sh <classId> <quality>            # propose candidates
./scripts/tournament/gear-apply.sh  team <team-id>                 # apply the team's tier
./scripts/tournament/gear-apply.sh  team <team-id> --with-consumables
./scripts/tournament/gear-apply.sh  player <team-id> <slot> --tier upgrade
```

`gear-audit.sh` exits non-zero while any required slot is empty, so it works as a
gate in a match runner.

## Required slots

`head neck shoulders chest waist legs feet wrists hands finger1 trinket1 back
mainhand` — 13 of the 19 equipment slots (`Player.h:590-610`).

Not required, and never reported as missing: `body` and `tabard` (cosmetic),
`finger2` and `trinket2` (optional duplicates), `offhand` (empty for two-handed
specs), `ranged` (empty for several specs).

## Tiers

Each file defines at least two tiers with unique `rank` values. `rank` ordering is
what "upgrade the armour of this player" moves along — one step per effect, never
wrapping. At the top tier an upgrade is a no-op, not a reset to base.

Bots must be **online** for gear to apply: `tournament equip` and
`tournament store` resolve the player by name through `ObjectAccessor`. Both call
`SaveToDB()`, so gear survives an immediate `roster.sh logout`.
```

- [ ] **Step 6: Commit**

```bash
git add src/game/Commands/TournamentCommands.cpp src/game/Chat/Chat.h src/game/Chat/Chat.cpp \
        scripts/tournament/gear-apply.sh docs/playerbots/TOURNAMENT-GEAR.md
git commit -m "feat(tournament): consumables via tournament store, and document the gear model"
```

---

## Done when

- `bash tests/tournament/gear.test.sh` exits 0.
- `./scripts/tournament/gear-audit.sh <team>` exits **1** on the pre-existing
  roster (the measured baseline) and **0** after `gear-apply.sh team <team>`.
- Every item id in `config/tournament/gear/` resolves in `tw_world.item_template`
  — no placeholder `0` survives validation.
- `gear-apply.sh player <team> one --tier upgrade` demonstrably changes the head
  slot's `itemEntry` in `character_inventory`.
- `docs/playerbots/TOURNAMENT-GEAR.md` records the `InitEquipment` root cause with
  file:line references.
