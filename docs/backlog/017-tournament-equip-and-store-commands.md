---
status: done
risk: medium
area: game/commands
depends-on: 016-tournament-instance-lifecycle-commands.md
---

# Nothing can put a specific item on a specific bot

**Problem:** The only way a bot gets gear is `rndbot create ... gear=blue`, which
maps to `PlayerbotFactory(bot, level, ITEM_QUALITY_RARE).EquipGear()` →
`InitEquipment(false, false)`. That function **destroys every equipped item before
choosing replacements** (`PlayerbotFactory.cpp:2999-3003`) and leaves any slot it
then fails to fill empty, with no completeness check anywhere — which is the
observed "bots with weapons and no armour" behaviour. There is no way to say
"put these exact items on this exact bot", and no way to put a consumable in a
bot's bags at all.

**Suspected cause / area:** Implements
`docs/superpowers/plans/2026-08-16-02-tournament-control-plane.md` Task 6 and
`docs/superpowers/plans/2026-08-16-03-gear-loadouts.md` Task 5 Step 2 — the
`store` handler is pulled forward here because it is C++ and belongs with the rest
of the command family rather than in the middle of a shell plan.

**Acceptance criteria:**

- `equip <playerName> <itemId>[,<itemId>...]` emits one
  `equip player=… item=… slot=… ok=<0|1> reason=<text>` line per item, then
  `equip player=… equipped=<n> failed=<n>`. Distinct reasons for `no_such_item`,
  `cannot_equip(<InventoryResult code>)` and `equip_failed`.
- **`CanEquipNewItem` is called with `swap = true`.** The slot is expected to
  already hold the previous tier; passing `false` makes every re-gear of an
  already-dressed bot fail with "slot in use", which is the normal case, not the
  exception.
- `store <playerName> <itemId> <count>` uses `CanStoreNewItem(NULL_BAG,
  NULL_SLOT, dest, itemId, count)` then `StoreNewItem(dest, itemId, true)`, and
  emits `store player=… item=… count=… ok=<0|1> reason=…`, with
  `cannot_store(<code>)` on refusal. `equip` is not the right verb for a
  consumable and must not be made to accept one.
- **Both handlers call `plr->SaveToDB()` before returning.** A bot logged out by
  the runner between rounds would otherwise lose gear applied less than
  `PlayerSave.Interval` (60 s) ago.
- Both refuse a player who is not online, with
  `error=player_not_online(<name>)`.
- The item-id list parser handles a single id, a comma-separated list, a trailing
  comma, and an empty token without emitting a line for the empty token or
  running off the end of the string.
- Both are declared in `Chat.h` and registered in `tournamentCommandTable` with
  `AllowConsole = true`, and both emit exclusively through `TournamentEmit`.

**Notes:**

- **Do not attempt a Docker build here** (~9.5 min, no incremental build); the
  `backlog-batch` pass compiles this branch.
- `InventoryResult` codes are in `SharedDefines.h`. Emitting the numeric code
  rather than a message is deliberate — a class mismatch or a level requirement is
  a bad *item choice* in a tier file, not a broken command, and the caller needs
  to tell those apart.
- These two commands are what `scripts/tournament/gear-apply.sh` (artifact 022)
  and the `upgrade_armor_*` / `upgrade_weapon_*` viewer effects (artifact 032)
  drive. Their emitted-line shape is parsed by
  `scripts/tournament/lib/ctl.sh`, so do not reformat it.
- **Verification needing a live stack (not part of these criteria):** confirm a
  real level-60 item exists (e.g. `SELECT entry, name, class, subclass,
  InventoryType, Quality, ItemLevel FROM tw_world.item_template WHERE
  entry=12640;` — Lionheart Helm), then with a bot online run
  `tournament equip Wsgaone 12640` and read back `character_inventory` joined to
  `item_instance` for `bag=0`, expecting `itemEntry=12640` in the head slot.
  Then `tournament equip Wsgaone 13446` (Major Healing Potion) must report
  `ok=0 reason=cannot_equip(...)`, and `tournament store Wsgaone 13446 5` must
  report `ok=1` with a non-zero row count. An `ok=0 reason=cannot_store(...)`
  most likely means no free bag space — bots ship with small default bags; record
  it rather than working around it.

**Base:** cm-main

**Branch:** backlog/tournament-equip-and-store-commands

**Summary:** Added two console-callable subcommands to the tournament control plane in src/game/Commands/TournamentCommands.cpp — `tournament equip <playerName> <itemId>[,<itemId>...]` and `tournament store <playerName> <itemId> <count>` — declared in src/game/Chat/Chat.h and registered in `tournamentCommandTable` (src/game/Chat/Chat.cpp) with AllowConsole = true, emitting exclusively through TournamentEmit. `equip` resolves each id with `CanEquipNewItem(NULL_SLOT, dest, itemId, true)` — swap = true is load-bearing, because with swap = false FindEquipSlot (Player.cpp:10349-10377) refuses any occupied slot and every re-gear of an already-dressed bot would fail — then destroys whatever occupies the resolved slot before calling `EquipNewItem`, because `Player::EquipItem` does not replace a slot's contents but stacks onto the old item and returns it (Player.cpp:12336-12409), which would have reported ok=1 while leaving the previous tier in place; a successful equip is followed by `AutoUnequipOffhandIfNeed()` so a two-hander does not leave an illegally equipped offhand. It emits `equip player=… item=… slot=… ok=<0|1> reason=…` per item (reasons `ok`, `no_such_item`, `cannot_equip(<InventoryResult>)`, `equip_failed`; `slot=-1` when none was resolved, since 0 is EQUIPMENT_SLOT_HEAD) and then `equip player=… equipped=<n> failed=<n>`. `store` uses `CanStoreNewItem(NULL_BAG, NULL_SLOT, dest, itemId, count)` / `StoreNewItem(dest, itemId, true)` and emits `store player=… item=… count=… ok=<0|1> reason=…` with `cannot_store(<code>)` on refusal. Both call `SaveToDB()` before returning (equip before its summary line) and both refuse an offline player with `error=player_not_online(<name>)`. A file-static `TournamentParseItemIds` handles a single id, a comma-separated list, and leading/doubled/trailing commas without emitting a line for an empty token or walking past the string's terminator; a non-numeric token becomes id 0 and surfaces as `no_such_item`. No build was run (rule 4); the parser's walk was transcribed line-for-line and exercised over all seven listed cases, tests/tournament/ctl.test.sh still passes 6/6, and the two items the artifact names for live verification were confirmed present in tw_world.item_template (12640 Lionheart Helm, inventory_type 1, required_level 56; 13446 Major Healing Potion, class 0, inventory_type 0). No SQL migration was needed. docs/playerbots/TOURNAMENT-CONTROL-PLANE.md already documented both commands in exactly this emitted shape, so no doc change was required.

**In-game check:** Needs a running world built from this branch (no image on this host has these commands yet — an "unknown subcommand" reply from the current stack proves nothing). Bring the stack up, log in the tournament bots, and drive the console with `wsg_console` from docs/playerbots/wsg/lib/wsg-bots-common.sh (never a bare `docker attach`).

Scriptable from console output alone (a later batch step can do all of this and diff the emitted lines):

1. `tournament equip Wsgaone 12640` (Lionheart Helm — confirmed present: inventory_type 1 = head, required_level 56, plate). Expect exactly two lines: `TOURNAMENT equip player=Wsgaone item=12640 slot=0 ok=1 reason=ok` and `TOURNAMENT equip player=Wsgaone equipped=1 failed=0`. `slot=0` is EQUIPMENT_SLOT_HEAD; `slot=-1` there means no slot resolved. If Wsgaone is not a plate class the correct answer is `ok=0 reason=cannot_equip(10)` (never usable) or `cannot_equip(8)` (no proficiency) — pick a warrior or paladin bot for the positive case.
2. Re-run the same command against the now-dressed bot. It must still report `ok=1 slot=0` — this is the swap = true criterion, and a `cannot_equip(9)` (EQUIP_ERR_NO_EQUIPMENT_SLOT_AVAILABLE) here is the exact regression the change exists to prevent.
3. `tournament equip Wsgaone 12640,,13446,` — expect exactly TWO per-item lines (12640 and 13446) plus the summary, and `equipped=1 failed=1`. Zero lines for the empty tokens is the parser criterion. `tournament equip Wsgaone ,,,` must answer `equip error=no_item_ids`.
4. `tournament equip Wsgaone 99999999` → `ok=0 reason=no_such_item`, not a numeric code.
5. `tournament equip Wsgaone 13446` (Major Healing Potion) → `ok=0 reason=cannot_equip(20)` (EQUIP_ERR_ITEM_CANT_BE_EQUIPPED — a consumable has inventory_type 0, so FindEquipSlot returns NULL_SLOT). This is the "store is not an alias for equip" criterion.
6. `tournament store Wsgaone 13446 5` → `TOURNAMENT store player=Wsgaone item=13446 count=5 ok=1 reason=ok`. An `ok=0 reason=cannot_store(50)` is EQUIP_ERR_INVENTORY_FULL — bots ship with small default bags. Record it rather than working around it; it is a bag-space fact, not a command failure.
7. `tournament equip Nosuchbot 12640` and `tournament store Nosuchbot 13446 1` → `equip error=player_not_online(Nosuchbot)` / `store error=player_not_online(Nosuchbot)`.
8. Persistence (the SaveToDB criterion), checkable without a human looking: immediately after step 1 and step 6 — well inside the 60 s PlayerSave.Interval — query the database directly (`docker exec tcm-db mysql ...`, not `wsg_mysql`, which discards stderr) with `SELECT ci.bag, ci.slot, ii.itemEntry, ii.count FROM tw_char.character_inventory ci JOIN tw_char.item_instance ii ON ii.guid = ci.item JOIN tw_char.characters c ON c.guid = ci.guid WHERE c.name='Wsgaone';`. Expect a row with `bag=0 slot=0 itemEntry=12640` and a row with `itemEntry=13446 count=5`. Doing this without waiting a minute is the whole point — if the rows are absent the save is missing.
9. Regression on the pre-existing head item: after step 1 the previously equipped head item must be GONE from that query, not still sitting at bag=0 slot=0. A stale itemEntry there with `ok=1` reported is the EquipItem-stacks-instead-of-replacing bug.

Needs a human in the client for one thing only: log a GM in, `.goname Wsgaone`, and look at the bot — the Lionheart Helm should be visibly on its head and the model should not be naked in the other slots. Also worth one eyeball: after equipping a two-handed weapon on a bot that had a shield, confirm the shield moved into the bot's bags rather than staying equipped (that is the AutoUnequipOffhandIfNeed path, and step 8's inventory query will show it as a bag row, so this too is largely scriptable).

Beyond that, the generic smoke test applies: server starts, `tournament status` answers, bots spawn.

**Minor findings:**
- src/game/Commands/TournamentCommands.cpp: In the equip handler the unconditional `DestroyItem(occupant...)` before `EquipNewItem` also wipes the contents of the replaced item when that occupant is an equipped bag -- `Player::DestroyItem` recurses over all MAX_BAG_SIZE slots of an equipped bag (src/game/Objects/Player.cpp:12604-12613) -- so `tournament equip <bot> <containerItemId>` silently deletes anything `tournament store` had just put in that bag.
- src/game/Commands/TournamentCommands.cpp: In the equip loop, if the item id names a container and all four bag slots are occupied, FindEquipSlot with swap=true returns an in-use bag slot (Player.cpp:10373-10378) and the unconditional DestroyItem on that occupant recursively destroys every item inside the equipped bag (Player.cpp:12604-12610) while the command still reports ok=1 — worth either refusing INVTYPE_BAG or checking CanUnequipItem on the destination before destroying it.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/33, build tortoise-cm:20260818-1.
