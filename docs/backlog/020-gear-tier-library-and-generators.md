---
status: done
risk: low
area: tournament/gear
depends-on: 019-gear-audit.md
---

# There is no format for "what this class and role wears at this tier"

**Problem:** A tournament needs two things the current gear path cannot give: a
kit that is *complete* by construction, and named upgrade tiers so a viewer
donation has something real to promote a bot into. Neither exists. There is no
file format, no validation that a tier has no holes, and no way to propose
candidate items from `tw_world.item_template` for review.

**Suspected cause / area:** Implements
`docs/superpowers/plans/2026-08-16-03-gear-loadouts.md` Tasks 2-3, minus the
execution of the generator (artifact 021).

**Acceptance criteria:**

- `scripts/tournament/lib/gear.sh` is sourceable and provides `gear_file`,
  `gear_tiers` (ordered by `rank`), `gear_items` (`slotName|itemId` lines),
  `gear_next_tier` and `gear_validate`.
- `gear_next_tier` returns the tier exactly one rank above the current one and
  **empty at the top** — an upgrade that has run out of tiers is a no-op, never a
  wrap-around to base.
- `gear_validate` rejects, naming the fault: invalid JSON; a `.class` or `.role`
  that disagrees with the filename; fewer than two tiers; duplicate `rank` values
  (which would make `gear_next_tier` arbitrary); any required slot missing from
  any tier; and any slot whose id is a placeholder `0`.
- `GEAR_REQUIRED_NAMES` in `lib/gear.sh` matches `GEAR_REQUIRED_SLOTS` in
  `scripts/tournament/gear-audit.sh` — the same 13 slots. A tier that validates
  but audits as incomplete is worse than either failure alone; state that
  coupling in a comment in both files.
- `scripts/tournament/gear-derive.sh <classId> <quality> [maxItemLevel]` prints
  TSV `slot<TAB>entry<TAB>name<TAB>itemLevel<TAB>quality`, a few candidates per
  required slot. It **proposes only** and never writes a tier file.
- `scripts/tournament/gear-generate.sh [<class> <role>]` writes complete
  **provisional** tier files (`"provisional": true`) with `base` = **white
  (`quality = 1`)** and `upgrade` = **green (`quality = 2`)**, failing loudly if
  some slot has no item at all for a class. Uniform basic white in every slot is
  the goal for the first tournament: completeness and fairness by construction,
  with refinement deferred until matches are running.
- **Every query uses this server's real column names, which are snake_case, not
  the CamelCase the plan text assumes.** Measured 2026-08-16 against
  `tw_world.item_template` (26,009 rows): the columns are `entry`, `class`,
  `subclass`, `name`, `quality`, `inventory_type`, `allowable_class`,
  `item_level`, `required_level`. `SELECT ... WHERE InventoryType = 1` fails
  outright with `Unknown column 'InventoryType'` — as do `Quality`, `ItemLevel`,
  `RequiredLevel` and `AllowableClass`. A comment at the top of each querying
  script records this.
- **Class fit is decided by armor `subclass`, not by `allowable_class`.**
  Measured: of 1,940 white items in equippable slots, **1,818 are
  `allowable_class = -1` (every class)** and only 122 are restricted. So
  filtering on the bitmask alone would happily hand a mage a plate chest, which
  then fails `CanEquipNewItem` on armor proficiency. Armor is `class = 4` with
  `subclass` 1=cloth, 2=leather, 3=mail, 4=plate; map each class to what it can
  actually wear — warrior/paladin plate, hunter/shaman mail, rogue/druid leather,
  priest/mage/warlock cloth — and filter on that. Weapons (`class = 2`) are
  filtered by weapon `subclass` for the same reason.
- `allowable_class` is still honoured where it *is* restrictive: it is a bitmask,
  class *N* is bit `1 << (N-1)`, and `-1` means all classes.
- `inventory_type` 5 (chest) and 20 (robe) are the same slot and both must be
  tried; 13 (one-hand), 17 (two-hand) and 21 (main-hand) all map to `mainhand`.
- Only `required_level <= 60` is eligible. This world carries items with
  `required_level` up to 100, so an unfiltered "highest item level" pick returns
  gear no level-60 bot can equip.
- `tests/fixtures/gear/warrior-tank.json` is committed: a complete, hand-written
  two-tier file used only by the tests.
- `bash tests/tournament/gear.test.sh` prints `12 passed, 0 failed` and exits 0.
  The new assertions point `GEAR_DIR` at `tests/fixtures/gear`, and cover: the
  fixture validating; tiers ordered by rank; `gear_next_tier` returning `upgrade`
  after `base` and empty after `upgrade`; the base tier having a `mainhand`; and a
  tier with `mainhand` deleted being rejected with `mainhand` named in the
  message.
- `bash -n scripts/tournament/gear-derive.sh` and
  `bash -n scripts/tournament/gear-generate.sh` both exit 0.

**Notes:**

- **The plan's version of this test validates against
  `config/tournament/gear/warrior-tank.json`, which does not exist until the
  generator has been run against a live database.** That would make this
  artifact's own acceptance criteria unsatisfiable in a worktree with no server.
  Hence the committed fixture: it is the same format, its item ids are plausible
  but unverified, and `gear_validate` only requires them to be non-zero. Do not
  write anything into `config/tournament/gear/` here — artifact 021 does that.
- **Run tests from WSL** —
  `wsl -d Ubuntu -- bash -lc 'cd /mnt/c/<worktree path> && bash tests/tournament/gear.test.sh'`.
  `jq` is absent from Git Bash.
- The generators query the database, so they cannot be *executed* here — only
  syntax-checked and reviewed. That is deliberate and is why running them is a
  separate artifact.
- Curation of the item ids is explicitly deferred and is **not** part of this
  work; see the "Deferred work" section at the end of
  `docs/superpowers/plans/2026-08-16-03-gear-loadouts.md`. Nothing downstream
  reads item ids — it reads the *file* — so provisional and curated files behave
  identically.
- Item ids `13446` (Major Healing Potion) and `8952` (Roasted Quail) appear as
  the hardcoded consumables. They are unverified on this server; artifact 021's
  bulk existence check is where that gets settled.
- **White gear coverage is measured and sufficient — do not re-derive it.**
  Survey of `tw_world.item_template`, 2026-08-16, white items per slot:
  head 134, neck 11, shoulders 85, chest 328 (+52 robe), waist 135, legs 165,
  feet 208, wrists 154, hands 188, finger 18, trinket 42, back 93, one-hand
  weapon 101 (+132 two-hand, +94 main-hand). Every armor slot has at least one
  white item in **every** armor class, so all nine classes in the four shipped
  teams can be fully dressed. The thinnest cell is white **plate waist: exactly
  one item** — a generator that picks "best per slot" will select it for both
  warriors and paladins, which is fine, but a generator that excludes it for any
  reason leaves plate wearers with an empty belt. Neck, finger and trinket carry
  no armor proficiency, so their low counts are not a constraint.

**Base:** cm-main

**Branch:** backlog/gear-tier-library-and-generators

**Summary:** Added the gear tier format, its library, and the two generators that fill it, all on `backlog/gear-tier-library-and-generators` (cut from `origin/cm-main` at b30bca6; one commit, a85d872). `scripts/tournament/lib/gear.sh` is a pure file library over `config/tournament/gear/<class>-<role>.json` providing `gear_file`, `gear_tiers` (ordered by `rank`), `gear_items` (`slotName|itemId`), `gear_next_tier` (the tier one rank up, empty at the top, and an explicit error for an unrecognised current tier so a typo can never print `base`) and `gear_validate`, which prints every fault and rejects invalid JSON, a `.class`/`.role` that disagrees with the filename, fewer than two tiers, a non-numeric or duplicate `rank`, any required slot missing from any tier, and any placeholder `0`. `GEAR_REQUIRED_NAMES` is the same 13 slots as `GEAR_SLOT_NAMES` in `gear-audit.sh` (the plan text calls that list `GEAR_REQUIRED_SLOTS`; the shipped audit spells it `GEAR_SLOT_NAMES`, beside the equipment-slot ids its query needs) and as the slot column of `ITEMDB_SLOT_MAP`, with the coupling stated in a comment in all three files. `scripts/tournament/gear-derive.sh <classId> <quality> [maxItemLevel]` prints TSV `slot/entry/name/itemLevel/quality`, five candidates per required slot, and writes nothing. `scripts/tournament/gear-generate.sh [<class> <role>]` writes complete `"provisional": true` two-tier files — base white (`quality = 1`), upgrade green (`quality = 2`) — validates each through the same library before claiming success, and aborts rather than emit a hole, reporting "the query failed" separately from "this world has no such item". A new `scripts/tournament/lib/itemdb.sh` owns every query so the class→subclass maps and the snake_case column note exist once instead of drifting between the two generators (the plan itself flags that three-way drift). Measured against the live `tw_world.item_template` (26,009 rows, 2026-08-17): the columns are snake_case; class fit is armor `subclass`, not `allowable_class` (the bitmask is still honoured where restrictive); cloth and misc are in every class's proficiency list because every white and green cloak on this server is `subclass = 1` and a warrior filtered to plate alone would have an empty back slot; `required_level <= 60` is the equippability gate. Two flag guards were added after measurement, `ITEM_FLAG_DEPRECATED` (0x10) and `ITEM_EXTRA_NOT_OBTAINABLE` (0x04, `ItemPrototype.h:77,385`) — without them a warrior's upgrade tier came back as the item_level-90 dev set while a paladin, correctly excluded by the bitmask, got real item_level 63-65 Hyperion plate: two kits 25 item levels apart under one tier name, which is the opposite of "fair by construction". `tests/fixtures/gear/warrior-tank.json` is committed with real, verified ids and is what the tests point `GEAR_DIR` at; `config/tournament/gear/` is deliberately still empty (artifact 021 writes it). `bash tests/tournament/gear.test.sh` prints `12 passed, 0 failed` and exits 0; `bash -n` on both generators exits 0; the generator was exercised against the live database into a scratch `GEAR_DIR` (12 files, all provisional, 13 slots in both tiers, no `0` ids, all 80 distinct ids resolving) and both failure paths were driven, neither of which wrote a file.

**In-game check:** Nothing in this artifact runs inside mangosd. It adds no console command, no C++, and no file the server reads — `gear-derive.sh`, `gear-generate.sh` and `lib/gear.sh` are host-side shell that talk only to `tw_world.item_template` read-only. So the generic "server starts, bots spawn" smoke test is untouched and passing it says nothing either way, and a `there is no such subcommand` reply from the rollback-anchor image is expected and irrelevant here.

SCRIPTABLE — no human needs to watch any of this. All of it was run and passed on this branch; a batch step can re-run it verbatim. Everything below is from WSL, not Git Bash (`jq` is absent there), from the branch checkout:

1. `bash tests/tournament/gear.test.sh` → prints `12 passed, 0 failed`, exits 0.
2. `bash -n scripts/tournament/gear-derive.sh` and `bash -n scripts/tournament/gear-generate.sh` → both exit 0.
3. Bring up only the database (`docker compose --env-file <main-checkout>/.env up -d db`, wait for `docker inspect --format '{{.State.Health.Status}}' tcm-db` to read `healthy`; no server image, no build), then `D=$(mktemp -d); GEAR_DIR=$D ./scripts/tournament/gear-generate.sh` → 12 `wrote ...` lines and exit 0. Do NOT point `GEAR_DIR` at `config/tournament/gear` — artifact 021 owns that directory. Then assert on `$D`: `ls -1 $D | wc -l` is 12; `grep -l '"provisional": true' $D/*.json | wc -l` is 12; `jq -r '.tiers[].items | length' $D/*.json | sort -u` is exactly `13`; `jq -r '.tiers[].items[]' $D/*.json | grep -c '^0$'` is 0.
4. Class fit, the criterion that fails silently and only surfaces as `cannot_equip` much later. For the chest/legs/hands ids in each file, `SELECT subclass FROM tw_world.item_template WHERE entry IN (...)` must be 1 for mage-dps/priest-healer/warlock-dps, 2 for rogue-dps/druid-tank/druid-healer, 3 for hunter-dps/shaman-dps/shaman-healer, 4 for warrior-tank/warrior-dps/paladin-tank. A cloth robe under a warrior's chest means the filter regressed.
5. Fairness invariant, which is what the two flag guards buy: `jq -S '.tiers' $D/warrior-tank.json` and `jq -S '.tiers' $D/paladin-tank.json` must be identical. They diverge by ~25 item levels if `ITEM_FLAG_DEPRECATED`/`ITEM_EXTRA_NOT_OBTAINABLE` are dropped from `lib/itemdb.sh`.
6. Bulk existence: the count of distinct ids across `jq -r '.tiers[].items[], (.consumables[]?.itemId)' $D/*.json | sort -un` must equal the row count from `SELECT COUNT(*) ... WHERE entry IN (<those ids>)`. It was 80 of 80 here. Use a bare `docker exec ... mysql`, not `wsg_mysql` — that helper discards stderr, so a failed query reads exactly like "no rows".
7. `./scripts/tournament/gear-derive.sh 1 1 | head -30` → a TSV whose every `slot` value is one of the 13 required names, and whose warrior `chest` rows are plate first.

REQUIRES A HUMAN, IN THE WORLD — but only after artifact 021 commits the tier files and artifact 022 lands `gear-apply.sh`; there is no in-game surface before then, and that is by design. When both exist:

1. `./scripts/tournament/roster.sh login stormwind-sentinels`, then `./scripts/tournament/gear-apply.sh team stormwind-sentinels`, then `./scripts/tournament/gear-audit.sh stormwind-sentinels`. Log-checkable, no eyes needed: the audit must print `GEAR-AUDIT stormwind-sentinels complete=10/10 worstMissing=0` and exit 0, and the control-plane lines from `tournament equip` must read `equipped=13 failed=0` per bot with no `ok=0 reason=cannot_equip(<n>)` anywhere in the console output. A `cannot_equip` code is a bad tier pick, i.e. a bug in `lib/itemdb.sh`'s subclass filter, not in the apply script.
2. Eyes on the world: log a GM character in, `.go name Wsgaone`, target the bot, and inspect it. Every one of head, neck, shoulders, chest, waist, legs, feet, wrists, hands, ring, trinket, back and main hand holds an item — no empty squares in the inspect window. Then inspect the mage on the same roster and the warrior: the warrior is in plate (Platemail-grade), the mage in a cloth robe, and never the reverse. Both wearing a cloak is the specific thing that would have broken had the back slot been filtered to plate.
3. The upgrade tier, which is the mechanism a viewer donation drives: `./scripts/tournament/gear-apply.sh player stormwind-sentinels one --tier upgrade`, then inspect Wsgaone again — the head item has changed and its name is green (uncommon), not white. Run the exact same command a second time: the bot must be unchanged and, critically, must NOT be back in white gear. That is `gear_next_tier` returning empty at the top, and a wrap-around to base is the one failure here that looks like a working feature.

**Minor findings:**
- scripts/tournament/lib/itemdb.sh: The exclusion guards (`flags & 0x10`, `extra_flags & 0x04`) do not catch GM-only items, so the base tier picks `2540 Gamemaster's Blade of Silence` (item_level 62, on-use spell 1852) as mainhand for 6 of 9 classes and `2543 Gamemaster's Medallion` as neck for warrior/paladin -- the same "a dev item wins on item_level" outcome the comment says these guards exist to prevent, and it opens a 62-vs-55 base mainhand item_level split between sword-capable classes and the mace-only priest/shaman (verified by running itemdb_candidates against tcm-db).
- scripts/tournament/lib/itemdb.sh: `itemdb_candidates` returns 1 both for "this server stocks nothing eligible" and for a caller error (unrecognised slot name, or a class id with no proficiency entry), so `best_entry`/`pick_or_die` report a bad slot or class id as "no quality-N item at all for slot X" -- exactly the conflation the separate rc=2 path was written to avoid.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/30, build tortoise-cm:20260817-2.
