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
