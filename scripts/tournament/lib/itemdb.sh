#!/usr/bin/env bash
# Read-only candidate lookup in tw_world.item_template, for the gear generators.
# Source, don't execute. Requires docker; the database container must be up.
#
# COLUMN NAMES ON THIS SERVER ARE snake_case. Measured 2026-08-17 against
# tw_world.item_template (26,009 rows): the columns are `entry`, `class`,
# `subclass`, `name`, `quality`, `inventory_type`, `allowable_class`,
# `allowable_race`, `item_level`, `required_level`, `required_skill`,
# `required_spell`, `required_honor_rank`, `required_reputation_faction`.
#
# The CamelCase spellings in docs/superpowers/plans/2026-08-16-03-gear-loadouts.md
# -- Quality, InventoryType, ItemLevel, RequiredLevel, AllowableClass -- do not
# exist here. `SELECT ... WHERE InventoryType = 1` fails outright with
# `Unknown column 'InventoryType'`. Do not reintroduce them.

ITEMDB_CONTAINER="${ITEMDB_CONTAINER:-${DB_CONTAINER:-tcm-db}}"
ITEMDB_WORLD="${ITEMDB_WORLD:-tw_world}"

# Deliberately NOT wsg_mysql from docs/playerbots/wsg/lib/wsg-bots-common.sh:
# that helper sends mysql's stderr to /dev/null, so a query that fails returns an
# empty string and reads exactly like "this server has no item for that slot".
# The generator's response to an empty result is to abort with "no item at all",
# so a swallowed error would abort for entirely the wrong reason and send whoever
# reads it hunting the item database instead of the typo. Here stderr reaches the
# operator and the exit status is checked by every caller.
itemdb_query() { # <sql> -> tab-separated rows on stdout, non-zero if mysql failed
    local sql="$1" pass
    pass="$(docker exec "$ITEMDB_CONTAINER" printenv MARIADB_ROOT_PASSWORD 2>/dev/null | tr -d '\r\n')"
    docker exec -e MYSQL_PWD="$pass" "$ITEMDB_CONTAINER" \
        mysql -uroot -N -B -e "$sql" | tr -d '\r'
}

# required slot | item_template.class | the inventory_type values that fill it.
#
# The slot column is exactly GEAR_REQUIRED_NAMES in lib/gear.sh, in the same
# order -- 13 slots -- and must stay that way; see the coupling note there.
#
# inventory_type 5 (chest) and 20 (robe) are the SAME slot and both must be
# tried: cloth casters mostly wear 20 and plate wearers only 5, so a query that
# asks for 5 alone leaves every mage bare-chested. 13 (one-hand), 17 (two-hand)
# and 21 (main-hand) all map to `mainhand`. INVTYPE_* values are
# src/game/Objects/ItemPrototype.h; item class 4 is armor, 2 is weapon.
ITEMDB_SLOT_MAP='head|4|1
neck|4|2
shoulders|4|3
chest|4|5,20
waist|4|6
legs|4|7
feet|4|8
wrists|4|9
hands|4|10
finger1|4|11
trinket1|4|12
back|4|16
mainhand|2|13,17,21'

# ARMOR PROFICIENCY, heaviest first. Class fit is decided HERE, by armor
# `subclass`, and not by `allowable_class`: measured 2026-08-16, of the 1,940
# white items in equippable slots 1,818 are `allowable_class = -1` (every class)
# and only 122 are restricted at all. So a bitmask filter on its own happily
# hands a mage a plate chest, which then fails CanEquipNewItem on armor
# proficiency at apply time -- long after the tier file looked complete.
#
# subclass 4=plate 3=mail 2=leather 1=cloth 0=misc.
#
# Cloth and misc appear in EVERY class's list because every class has cloth
# proficiency and misc armor requires none, and that is not academic: measured
# 2026-08-17, every white and every green cloak on this server (inventory_type
# 16) is `subclass = 1`, so a warrior filtered to plate alone would have an empty
# back slot -- and necks, rings and trinkets are all `subclass = 0` for the same
# reason. The order is a PREFERENCE, not a permission list: the query below takes
# the heaviest subclass that this slot actually has an item in.
itemdb_armor_subclasses() { # <classId> -> subclass ids, heaviest first
    case "$1" in
        1|2)   echo "4 3 2 1 0" ;;  # warrior, paladin      -- plate
        3|7)   echo "3 2 1 0"   ;;  # hunter, shaman        -- mail
        4|11)  echo "2 1 0"     ;;  # rogue, druid          -- leather
        5|8|9) echo "1 0"       ;;  # priest, mage, warlock -- cloth
        *) echo "itemdb: no armor proficiency known for class id '$1'" >&2; return 1 ;;
    esac
}

# MELEE MAIN-HAND PROFICIENCY per class (vanilla 1.12). Weapons carry no armor
# subclass, so the same reasoning applies for the same reason: filtering only on
# `allowable_class` would hand a rogue a polearm.
#
# subclass 0=axe1H 1=axe2H 4=mace1H 5=mace2H 6=polearm 7=sword1H 8=sword2H
# 10=staff 13=fist 15=dagger.
#
# Deliberately excluded: 2/3/18 (bow, gun, crossbow), 16/25 (thrown) and 19
# (wand) are the RANGED slot, which is not required; 14 (misc) and 20 (fishing
# pole) are tools no class has proficiency in, and this world has 13 white ones
# that would otherwise outrank a real weapon on item_level. No preference order
# is applied within a class -- the highest item_level the class can wield wins.
# Which of those a role should actually carry (a tank's shield, a hunter's bow)
# is a curation question, not a completeness one.
itemdb_weapon_subclasses() { # <classId> -> subclass ids
    case "$1" in
        1)  echo "0 1 4 5 6 7 8 10 13 15" ;;  # warrior
        2)  echo "0 1 4 5 6 7 8"          ;;  # paladin
        3)  echo "0 1 6 7 8 10 13 15"     ;;  # hunter
        4)  echo "4 7 13 15"              ;;  # rogue
        5)  echo "4 10 15"                ;;  # priest
        7)  echo "0 1 4 5 10 13 15"       ;;  # shaman
        8)  echo "7 10 15"                ;;  # mage
        9)  echo "7 10 15"                ;;  # warlock
        11) echo "4 5 6 10 13 15"         ;;  # druid
        *) echo "itemdb: no weapon proficiency known for class id '$1'" >&2; return 1 ;;
    esac
}

itemdb_slots() { # -> the required slot names, in map order
    printf '%s\n' "$ITEMDB_SLOT_MAP" | cut -d'|' -f1
}

# Candidate items for one required slot, best first.
#
# Returns TSV: slot, entry, name, item_level, quality. Empty output means this
# server has no eligible item -- but only if the exit status is 0; a non-zero
# status means the query failed and the emptiness means nothing.
itemdb_candidates() { # <classId> <slot> <quality> <maxItemLevel> <limit>
    local cls="$1" slot="$2" quality="$3" maxIlvl="$4" limit="$5"
    local iclass invtypes subs inlist order mask

    iclass="$(printf '%s\n' "$ITEMDB_SLOT_MAP" | awk -F'|' -v s="$slot" '$1 == s { print $2; exit }')"
    invtypes="$(printf '%s\n' "$ITEMDB_SLOT_MAP" | awk -F'|' -v s="$slot" '$1 == s { print $3; exit }')"
    [ -n "$iclass" ] || { echo "itemdb: '$slot' is not a required slot" >&2; return 1; }

    if [ "$iclass" = "2" ]; then
        subs="$(itemdb_weapon_subclasses "$cls")" || return 1
        order="item_level DESC, entry ASC"
    else
        subs="$(itemdb_armor_subclasses "$cls")" || return 1
        # FIELD() turns the preference order into a sort key -- 1 for the first
        # subclass listed, 2 for the second -- so ordering by it ascending takes
        # the heaviest armor the class can wear that this slot actually stocks,
        # and falls through to cloth only where nothing heavier exists (cloaks).
        order="FIELD(subclass,$(printf '%s' "$subs" | tr ' ' ',')), item_level DESC, entry ASC"
    fi
    inlist="$(printf '%s' "$subs" | tr ' ' ',')"

    # allowable_class is still honoured where it IS restrictive: it is a bitmask,
    # class N is bit 1 << (N-1), and -1 means every class.
    mask=$(( 1 << (cls - 1) ))

    # required_level <= 60, not item_level: this world carries items with
    # required_level up to 100, so an unfiltered "highest item level" pick returns
    # gear no level-60 bot can equip.
    #
    # The required_* guards are the remaining equip blockers, each of which would
    # otherwise surface only as cannot_equip() at apply time. Measured 2026-08-17,
    # applying all four still leaves every one of the 13 slots stocked in every
    # armor class -- including the thinnest cell on the server, white plate waist,
    # which is exactly one item (8088 Platemail Belt) -- so they cost nothing and
    # rule out a profession-locked, race-locked, honor-locked or
    # reputation-locked pick.
    #
    # THE TWO FLAG GUARDS ARE WHAT KEEPS THE TOURNAMENT FAIR, and they are not
    # cosmetic. ITEM_FLAG_DEPRECATED (0x10) and ITEM_EXTRA_NOT_OBTAINABLE (0x04,
    # "Never obtainable by players in vanilla") are both
    # src/game/Objects/ItemPrototype.h:77,385. Measured 2026-08-17 without them:
    # a warrior's upgrade tier came back as the flags=0x10 dev set
    # ("90 Green Warrior Helm" and friends, item_level 90, required_level 60,
    # allowable_class = 1) while a paladin -- correctly excluded from it by the
    # bitmask -- got real item_level 63-65 Hyperion plate. Same tier name, two
    # kits 25 item levels apart: a rigged match, produced by construction, in the
    # one place this whole gear path exists to make fair. The same guards drop
    # `Test Defense Chest` and the `PVP Plate * Alliance` set, which are
    # extra_flags=0x04 for the same reason.
    itemdb_query "SELECT '$slot', entry, name, item_level, quality
                  FROM ${ITEMDB_WORLD}.item_template
                  WHERE class = $iclass
                    AND subclass IN ($inlist)
                    AND inventory_type IN ($invtypes)
                    AND quality = $quality
                    AND required_level <= 60
                    AND item_level <= $maxIlvl
                    AND (allowable_class = -1 OR (allowable_class & $mask) > 0)
                    AND allowable_race = -1
                    AND required_skill = 0
                    AND required_spell = 0
                    AND required_honor_rank = 0
                    AND required_reputation_faction = 0
                    AND (flags & 0x10) = 0
                    AND (extra_flags & 0x04) = 0
                  ORDER BY $order
                  LIMIT $limit;"
}
