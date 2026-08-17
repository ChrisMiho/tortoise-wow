---
status: pending
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
