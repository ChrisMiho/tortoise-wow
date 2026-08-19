# Tournament gear

Tournament bots do not use `rndbot ... gear=blue`. Their kit is an explicit item
list per class, role and tier, in `config/tournament/gear/<class>-<role>.json`,
applied by `scripts/tournament/gear-apply.sh` and proved by
`scripts/tournament/gear-audit.sh`.

---

## Why not the built-in gear system

`gear=blue` maps to `PlayerbotFactory(bot, level, ITEM_QUALITY_RARE).EquipGear()`
(`RandomPlayerbotMgr.cpp:935-939`) → `InitEquipment(false, false)`
(`src/modules/PlayerBots/playerbot/PlayerbotFactory.cpp:2969`). Three behaviours
of that one function produce the half-dressed bots this whole path exists to fix:

| Behaviour | Where |
|---|---|
| **It destroys every equipped item before choosing replacements.** With `incremental == false` it runs `DestroyItemsVisitor` across the equipment slots first; any slot it then fails to fill is simply left empty, so the bot is stripped whether or not a replacement was ever found. | `PlayerbotFactory.cpp:2999-3003` (the `if (!incremental)` block; the visitor itself is line 3001) |
| **It equips nothing at all below level 5** and returns early. | `PlayerbotFactory.cpp:2974-2979` |
| **It equips nothing at all when `specId == 0`** and returns early. | `PlayerbotFactory.cpp:2991-2996` |

Both early returns carry comments saying they exist *because* the code stripped
bots naked. Nothing anywhere in that path checks completeness afterwards, so a
half-dressed bot is indistinguishable from a success — and a match between a
dressed team and a stripped one is rigged with nobody the wiser.

This system does not fix `InitEquipment`. It stops tournament bots depending on
it, and adds the audit that catches it.

---

## Commands

```bash
./scripts/tournament/gear-generate.sh                              # write the tier files (once per world)
./scripts/tournament/gear-derive.sh <classId> <quality>            # propose candidates, for hand review
./scripts/tournament/gear-audit.sh  <team-id>                      # what is actually worn
./scripts/tournament/gear-apply.sh  team <team-id>                 # dress the team in its .gearTier
./scripts/tournament/gear-apply.sh  team <team-id> --with-consumables
./scripts/tournament/gear-apply.sh  player <team-id> <slot> --tier upgrade
```

`gear-audit.sh` exits non-zero while any required slot is empty, so it drops into
a match runner as a gate. `gear-apply.sh` ends by re-running it and **exits 0
only if that audit passes** — "the commands were sent" is not success, a filled
slot is.

The tier files are **not in the repository**. They are picked from this world's
own `tw_world.item_template`, so `gear-generate.sh` must have run at least once
on the host before `gear-apply.sh` has anything to apply. A class whose file is
absent, whose file fails `gear_validate`, or whose requested tier holds no items
is **skipped with a message on stderr and a non-zero overall exit** — never
applied blank.

### `gear-apply.sh` dresses every bot, not only the under-dressed ones

Both teams then wear the same grade of kit and no match is decided by gear.
Existing items are replaced: `tournament equip` calls `CanEquipNewItem` with
`swap = true` precisely because the slot is expected to be occupied.

This is why the base tier is uniform basic white rather than anything nicer.
Measured 2026-08-16, only 9 of the 20 shipped bots were fully dressed
(`stormwind-sentinels` `complete=4/10`, `orgrimmar-warsong` `complete=5/10`, the
worst bots holding 5 of the 13 required slots), so "top up the gaps" would have
left the two teams in materially different gear and called it fair.

### Reading a failure

A residual empty slot shows up in the audit, and the equip line that caused it
reads `ok=0 reason=cannot_equip(<n>)`. Look `<n>` up in `InventoryResult`
(`SharedDefines.h`): a class or level restriction is a **bad item choice in the
tier file, not a broken script**. The likeliest cause is armour proficiency —
1,818 of 1,940 white items are `allowable_class = -1`, so a generator filtering
on that bitmask alone will have put plate on a mage. Fix the tier and re-run.

---

## Required slots

Thirteen of the nineteen equipment slots (`src/game/Objects/Player.h:590-610`):

```
head neck shoulders chest waist legs feet wrists hands finger1 trinket1 back mainhand
```

The other six are **not required and are never reported as missing**:

| Slot | Why not |
|---|---|
| `body` (3), `tabard` (18) | cosmetic |
| `finger2` (11), `trinket2` (13) | optional duplicates of slots already required |
| `offhand` (16) | legitimately empty for every two-handed spec |
| `ranged` (17) | legitimately empty for several specs |

Counting any of those would make a correctly geared warrior look broken, and a
gate that cries wolf gets switched off.

That list is written down in three places and they must not drift:
`GEAR_REQUIRED_NAMES` in `scripts/tournament/lib/gear.sh`, `GEAR_SLOT_NAMES` /
`GEAR_SLOT_IDS` in `scripts/tournament/gear-audit.sh`, and the slot column of
`ITEMDB_SLOT_MAP` in `scripts/tournament/lib/itemdb.sh`. A tier that validates in
one and audits as incomplete in another is worse than either failure alone — it
looks like a working kit right up to the moment a match is gated on it.

---

## Tiers and `rank`

Each file holds at least two named tiers, each with a **unique numeric `rank`**:

```json
{
  "class": "warrior", "role": "tank", "provisional": true,
  "tiers": {
    "base":    { "rank": 0, "items": { "head": <entry>, ... one per required slot } },
    "upgrade": { "rank": 1, "items": { "head": <entry>, ... one per required slot } }
  },
  "consumables": [ { "itemId": 13446, "count": 20 } ]
}
```

(Shape only — the entries are whatever `gear-generate.sh` picked out of this
world's `item_template`, which is why no ids are quoted here.)

- **Complete.** Every required slot present in every tier. A tier with a hole
  reproduces the `InitEquipment` bug by hand, so `gear_validate` rejects it, and
  a placeholder `0` is rejected the same way.
- **Ordered.** `rank` is the single axis an upgrade moves along. `gear_next_tier`
  returns the tier exactly one rank above the current one, and **empty at the
  top** — an upgrade that has run out of tiers is a no-op, never a wrap-around
  back to `base`. Handing a viewer who paid for an upgrade a downgrade to white
  is worse than handing them nothing. An unrecognised current tier is an error
  for the same reason.
- A team picks its default with `.gearTier` in
  `config/tournament/teams/<id>.json`; `--tier <name>` overrides it for one run.

`"provisional": true` marks a mechanically generated file — highest `item_level`
the class can equip in each slot at the tier's quality. Curated and provisional
files behave identically everywhere, because the only thing that differs is which
integers sit in `.tiers[].items`.

---

## Bots must be ONLINE

`tournament equip` and `tournament store` resolve the player **by name through
`ObjectAccessor`**. An offline bot is answered `error=player_not_online(<name>)`
and nothing is written — there is no offline path, and writing to
`character_inventory` or `item_instance` by hand is not one either (the next
player save overwrites it, and it is silently destructive while the character is
online).

So the order is always:

```bash
./scripts/tournament/roster.sh   login stormwind-sentinels
./scripts/tournament/gear-apply.sh team  stormwind-sentinels
./scripts/tournament/roster.sh   logout stormwind-sentinels    # optional, and safe
```

Both handlers call `SaveToDB()` per invocation, so the gear survives an immediate
`roster.sh logout` — there is no need to leave the team online waiting for the
60-second player save.

`gear-apply.sh` sends the whole run in **one console attach**: ten equips of
thirteen items each, plus any `store` lines. Ten separate attaches would be ten
chances to send `mangosd` an EOF, which it reads as "shut down the world". Every
one of those commands is queued onto the world thread rather than answered at
typing speed, so if bots come back as `no equip summary came back`, raise
`GEAR_CONSOLE_WAIT` (default 40 s) before suspecting the gear.

---

## Consumables

`--with-consumables` additionally issues `tournament store <name> <itemId>
<count>` for each entry in the tier file's `consumables`, and **reports each
result rather than silently dropping it**. `equip` is not an alias for `store`:
`CanEquipNewItem` refuses a potion, correctly.

An `ok=0 reason=cannot_store(<n>)` is most often no free bag space — bots ship
with small default bags — and `gear-apply.sh` exits non-zero when it happens
rather than pretending the run was clean.

The shipped consumables are the same pair for every class (13446 Major Healing
Potion, 8952 Roasted Quail). A mage wants mana potions and a warrior does not;
per-class consumables are deferred into the same curation artifact as the item
ids.
