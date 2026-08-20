---
status: done
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

**Base:** cm-main

**Branch:** backlog/gear-apply

**Summary:** Added `scripts/tournament/gear-apply.sh` (new, executable) and `docs/playerbots/TOURNAMENT-GEAR.md` (new); commit b2eb5d0 on `backlog/gear-apply`, cut from `origin/cm-main` (80a7100). The script takes three forms, all named in its usage text: `team <team-id> [--tier <name>]`, `player <team-id> <slot> [--tier <name>]` (bot resolved as `namePrefix + slot`), and `--with-consumables` on either. It defaults to the team's `.gearTier`, refuses a team that fails `team_validate`, and validates and reads every tier file through `gear_validate`/`gear_items` BEFORE sending anything — a class whose file is broken or whose requested tier has no items is skipped with a message on stderr and a non-zero overall exit rather than half-applied. It dresses every bot on the team, not only the under-dressed ones, so both teams end up identically kitted. All the resulting `tournament equip` (and, with `--with-consumables`, `tournament store`) commands go out in ONE `ctl` attach — ten separate attaches would be ten chances to EOF the console, the same reason `roster.sh` and `match-run.sh` batch — and each bot is then reported from the console's own `equipped=/failed=` summary line. A missing summary is reported as "no answer, raise GEAR_CONSOLE_WAIT" (default 40s) rather than success; the plan's `${failed:-0}` shorthand would have read a silent console as `failed=0`, which is the one wrong answer available. It ends by re-running `gear-audit.sh` for the team and exits 0 only if that audit passes, passing an unmeasurable audit (exit 2) straight through rather than flattening it to 1. The doc records the `InitEquipment` root cause with file:line (`PlayerbotFactory.cpp:2999-3003` destroys before replacing, visitor on 3001; early returns at `:2974-2979` below level 5 and `:2991-2996` at `specId == 0`), the command list, the 13 required slots and the six deliberately-not-required ones with the three files that must agree on that set, how tiers and `rank` work, and that bots must be online because `equip`/`store` resolve by name through `ObjectAccessor` while both call `SaveToDB()`. Verified with the db container up and no mangosd: `bash -n` clean; argument handling exits 2 with usage for no args, unknown mode, unknown option, `--tier` with no value, a `player` with no slot, an unknown team and a bogus slot word; an empty `GEAR_DIR` produces 10 SKIP lines and sends no command; `--tier platinum` skips every class with `no tier 'platinum'`; a full `team` run plans all 10 bots and a `player ... --tier upgrade` run plans exactly 1. The tier files are generated per-world and not committed (that is artifact 021), so `gear-generate.sh` was run into this checkout for those runs — all nine Alliance class/role pairs generated and passed `gear_validate` — and the generated `config/tournament/gear/` was removed again, leaving the branch with only the two intended files. The equip path itself is NOT verified here: no mangosd is running, this branch is unbuilt (rule 4), and `tournament equip`/`store` are artifact 017, which is not yet merged into cm-main.

**In-game check:** Prerequisite: this needs a build that contains artifact 017's `tournament equip` and `tournament store` handlers. Neither exists on cm-main today, so run this only against an image whose batch includes 017 — check with `docker ps --format '{{.Names}} {{.Image}}'` first. Also run `./scripts/tournament/gear-generate.sh` once on the host if `config/tournament/gear/` is empty; the tier files are picked per world and are not in the repo. Everything below runs from WSL (jq).

Scriptable, no human eyes needed — a later batch step can do all of this and read the exit codes:

1. `./scripts/tournament/roster.sh login stormwind-sentinels`
2. `./scripts/tournament/gear-audit.sh stormwind-sentinels` — the "before". Expected from the baseline, and reproduced against the live tw_char on 2026-08-18: `GEAR-AUDIT stormwind-sentinels complete=4/10 worstMissing=8`, exit 1.
3. `./scripts/tournament/gear-apply.sh team stormwind-sentinels`. Expect one `Wsga<slot> tier=base equipped=13 failed=0` line per bot, a final `GEAR-AUDIT stormwind-sentinels complete=10/10 worstMissing=0`, and **exit 0**. Exit 0 is the whole check: the script gates itself on the audit. Any `FAIL <name>: not online` means step 1 did not take; any `FAIL <name>: no equip summary came back` means raise `GEAR_CONSOLE_WAIT`, not that the gear is wrong.
4. Confirm from the database, not the script's own output — required slots filled per bot must be 13:
   `SELECT c.name, COUNT(ci.slot) FROM tw_char.characters c LEFT JOIN tw_char.character_inventory ci ON ci.guid = c.guid AND ci.bag = 0 AND ci.slot IN (0,1,2,4,5,6,7,8,9,10,12,14,15) WHERE c.name LIKE 'Wsga%' GROUP BY c.name ORDER BY c.name;`
5. Confirm it is actually the white tier — every equipped item should be `quality = 1`:
   `SELECT it.quality, COUNT(*) FROM tw_char.character_inventory ci JOIN tw_char.item_instance ii ON ii.guid = ci.item JOIN tw_char.characters c ON c.guid = ci.guid JOIN tw_world.item_template it ON it.entry = ii.itemEntry WHERE c.name LIKE 'Wsga%' AND ci.bag = 0 AND ci.slot <= 18 GROUP BY it.quality;`
   Anything other than `quality = 1` means the generator picked outside its tier, or an item failed to equip and the old one survived in the slot.
6. Note Wsgaone's head-slot `itemEntry` (`SELECT ii.itemEntry FROM tw_char.character_inventory ci JOIN tw_char.item_instance ii ON ii.guid=ci.item JOIN tw_char.characters c ON c.guid=ci.guid WHERE c.name='Wsgaone' AND ci.bag=0 AND ci.slot=0;`), then run `./scripts/tournament/gear-apply.sh player stormwind-sentinels one --tier upgrade` and re-read it. It must have **changed**, and the new entry's `quality` must be 2. This is the exact mechanism the viewer `upgrade_armor_*` effect calls, so it failing here means those effects are broken too.
7. `./scripts/tournament/roster.sh logout stormwind-sentinels`, then re-run step 4. The counts must still be 13 — both handlers call `SaveToDB()`, so gear survives an immediate logout. A drop here means the save is not happening and the gear only ever existed in memory.
8. `./scripts/tournament/gear-apply.sh team stormwind-sentinels --with-consumables` (bots logged back in). Every `store player=... ok=1` line is a pass; `ok=0 reason=cannot_store(<n>)` is almost certainly no free bag space, and the script exits non-zero rather than dropping it silently. Confirm with `SELECT COUNT(*) FROM tw_char.character_inventory ci JOIN tw_char.item_instance ii ON ii.guid=ci.item JOIN tw_char.characters c ON c.guid=ci.guid WHERE c.name='Wsgaone' AND ii.itemEntry=13446;` — non-zero.

What a human still has to look at: nothing about correctness, but worth one glance — log a GM in, `.go` to a geared bot and confirm it visibly has a weapon and armour on rather than the naked-model look that started this work. Any residual missing slot appears as `reason=cannot_equip(<n>)` in step 3's stderr; look `<n>` up in `InventoryResult` (`SharedDefines.h`). That is a bad item choice in the tier file, not a broken script — the likeliest cause is armour proficiency, since 1,818 of 1,940 white items are `allowable_class = -1` and a generator filtering on that bitmask alone will have put plate on a mage.

**Minor findings:**
- scripts/tournament/gear-apply.sh: With `--with-consumables`, a tier file whose `consumables` array is absent or empty queues no `store` lines, but the report loop treats "no store line came back" as a failure and forces a non-zero exit -- a legitimately consumable-free curated file can never exit 0.
- scripts/tournament/gear-apply.sh: In `plan_one`, the `tournament equip` line is appended to `LINES` before the consumables block, so a `gear_file` failure there returns 1 without adding the bot to `APPLIED` -- the equip command is still sent to the console but that bot is never reported on or checked.
- docs/playerbots/TOURNAMENT-GEAR.md: Both the script header and the doc tell the operator to look `reason=cannot_equip(<n>)` up in `InventoryResult` in `SharedDefines.h`, but that enum is declared in `src/game/Objects/Item.h:45` (the `equip` handler's own comment says so explicitly), so the one file:line pointer for diagnosing a failed equip sends the reader to the wrong header.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/35, build tortoise-cm:20260818-1.
