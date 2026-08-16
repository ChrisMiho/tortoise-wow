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
  **provisional** tier files (`"provisional": true`) with a `base` and an
  `upgrade` tier, falling back from rare to uncommon rather than leaving a slot
  empty, and failing loudly if some slot has no item at all for a class.
- **`AllowableClass` is treated as a bitmask in every query**: class *N* is bit
  `1 << (N-1)`, and `-1` means all classes. Comparing it against a class id
  returns nonsense. `INVTYPE` 5 (chest) and 20 (robe) are the same slot and both
  must be tried.
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
