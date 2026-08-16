---
status: pending
risk: low
area: tournament/gear
depends-on: 020-gear-tier-library-and-generators.md
---

# Nothing turns a gear tier file into a dressed bot

**Problem:** Tier files describe a kit and `tournament equip` applies one item
list, but nothing connects them: no command takes "this team, this tier" and
dresses all ten bots, and nothing verifies afterwards that it worked. "The
commands were sent" is not success — a filled slot is, and `tournament equip`
reports per-item failures precisely because a class or level restriction is a bad
item choice rather than a broken command.

**Suspected cause / area:** Implements
`docs/superpowers/plans/2026-08-16-03-gear-loadouts.md` Tasks 4-5 (minus the
`store` C++ handler, which is artifact 017).

**Acceptance criteria:**

- `scripts/tournament/gear-apply.sh team <team-id> [--tier <name>]` applies each
  member's class/role tier, defaulting to the team's own `.gearTier`.
- **It applies to every bot on the team, not only the under-dressed ones**, so
  both teams end up identically kitted and no match is decided by gear. Existing
  items are replaced — `tournament equip` calls `CanEquipNewItem` with
  `swap = true` precisely because the slot is expected to be occupied. This is
  intended and is why the tier is uniform basic white: measured 2026-08-16, only
  9 of the 20 existing bots were fully dressed (stormwind-sentinels 4/10,
  orgrimmar-warsong 5/10, worst bots at 5 of 13 required slots), so "top up the
  gaps" would leave two teams wearing materially different gear.
- `scripts/tournament/gear-apply.sh player <team-id> <slot> [--tier <name>]`
  applies to exactly one bot, resolved as `namePrefix + slot`.
- `--with-consumables` additionally issues `tournament store <name> <itemId>
  <count>` for each entry in that tier file's `consumables`, and reports the
  result rather than silently dropping them.
- It refuses a team that fails `team_validate`, and skips (with a message on
  stderr, and a non-zero overall exit) any class/role whose tier file fails
  `gear_validate` or whose requested tier has no items.
- It re-runs `scripts/tournament/gear-audit.sh` for the team at the end and
  **exits 0 only if that audit passes**.
- `bash -n scripts/tournament/gear-apply.sh` exits 0, and the script's usage text
  names all three forms.
- `docs/playerbots/TOURNAMENT-GEAR.md` exists and records: the `InitEquipment`
  root cause with `file:line` references
  (`PlayerbotFactory.cpp:2999` destroys before replacing; early returns below
  level 5 and at `specId == 0`); the command list; the 13 required slots and the
  six deliberately-not-required ones; how tiers and `rank` work; and that bots
  must be **online** because `tournament equip` and `tournament store` resolve the
  player by name through `ObjectAccessor`, both calling `SaveToDB()` so gear
  survives an immediate `roster.sh logout`.

**Notes:**

- This script sources three libraries at runtime:
  `scripts/tournament/lib/team.sh` (artifact 013 — `team_rows` emits
  `name|class|race|role|faction`, `team_field <id> <jq-path>`),
  `scripts/tournament/lib/gear.sh` (artifact 020 — `gear_items <class> <role>
  <tier>` emits `slotName|itemId`, `gear_file`, `gear_validate`), and
  `scripts/tournament/lib/ctl.sh` (artifact **018**, which is *not* in this
  branch's dependency chain — `ctl <command...>` echoes only `TOURNAMENT ` lines,
  `ctl_field <output> <key>` extracts one value). Write against those exact
  signatures; **do not execute `gear-apply.sh` end to end here** — `lib/ctl.sh`
  may be absent from this branch and the script needs a live server regardless.
  Syntax-check only.
- There is no unit test for this script in the plan and none is required; its
  behaviour is only observable against a running server.
- **Live validation checklist.** There is no unit test for this script by
  decision — it is validated by running it and reading the database. Run in
  order, recording each result:
  1. `./scripts/tournament/roster.sh login stormwind-sentinels`
  2. `./scripts/tournament/gear-audit.sh stormwind-sentinels` — the "before".
     Expected from the 2026-08-16 baseline: `complete=4/10`.
  3. `./scripts/tournament/gear-apply.sh team stormwind-sentinels`
  4. Expect a final `GEAR-AUDIT stormwind-sentinels complete=10/10
     worstMissing=0` and exit 0.
  5. **Confirm in the database, not from the script's own output** — filled
     required slots per bot must be 13:
     ```sql
     SELECT c.name, COUNT(ci.slot) FROM tw_char.characters c
       LEFT JOIN tw_char.character_inventory ci ON ci.guid = c.guid AND ci.bag = 0
        AND ci.slot IN (0,1,2,4,5,6,7,8,9,10,12,14,15)
      WHERE c.name LIKE 'Wsga%' GROUP BY c.name ORDER BY c.name;
     ```
  6. **Confirm it is actually the white tier**, which is the whole point of the
     uniform kit — every equipped item should be `quality = 1`:
     ```sql
     SELECT it.quality, COUNT(*) FROM tw_char.character_inventory ci
       JOIN tw_char.item_instance ii ON ii.guid = ci.item
       JOIN tw_char.characters c ON c.guid = ci.guid
       JOIN tw_world.item_template it ON it.entry = ii.itemEntry
      WHERE c.name LIKE 'Wsga%' AND ci.bag = 0 AND ci.slot <= 18
      GROUP BY it.quality;
     ```
     Anything other than `quality = 1` means the generator picked outside its
     tier, or an item failed to equip and the old one survived.
  7. `./scripts/tournament/gear-apply.sh player stormwind-sentinels one --tier
     upgrade` must change that bot's head-slot `itemEntry` — this is the exact
     mechanism the viewer `upgrade_armor_*` effect calls, so it failing here
     means those effects are broken too.
- Any residual missing slot shows up as `reason=cannot_equip(<n>)`. Look the code
  up in `InventoryResult` (`SharedDefines.h`): a class or level restriction is a
  bad item choice in the tier file, not a broken script. **The most likely cause
  is armor proficiency** — 1,818 of 1,940 white items are `allowable_class = -1`,
  so a generator filtering on that bitmask alone will have put plate on a mage.
- Never write to `character_inventory` or `item_instance` directly while a
  character is online — the next player save overwrites it.
