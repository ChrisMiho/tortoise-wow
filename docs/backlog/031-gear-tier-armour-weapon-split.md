---
status: pending
risk: low
area: tournament/gear
depends-on: 020-gear-tier-library-and-generators.md
---

# "Upgrade armour" and "upgrade weapon" would be the same effect

**Problem:** `upgrade_armor_*` and `upgrade_weapon_*` are separate viewer effects
with separate prices, but a gear tier is a single flat map of slot to item id.
Without a way to split it, both effects would apply the whole kit and be
indistinguishable to a viewer who paid for one of them.

**Suspected cause / area:** Implements
`docs/superpowers/plans/2026-08-16-06-viewer-effects.md` Task 2.

**Acceptance criteria:**

- `scripts/tournament/lib/gear.sh` gains `gear_items_armor <class> <role> <tier>`
  and `gear_items_weapon <class> <role> <tier>`, both emitting `slot|itemId` lines
  in the same shape as `gear_items`.
- The weapon set is exactly `mainhand offhand ranged` (per `Player.h:590-610`),
  named in one constant. Everything else in a tier — including neck, rings,
  trinkets and back, which are not "armour" in the item-class sense — belongs to
  the armour set, because that is what an "upgrade my armour" effect means to a
  viewer. Say so in a comment.
- `tests/tournament/effects.test.sh` exists and prints `5 passed, 0 failed`,
  exit 0, asserting: the armour set excludes `mainhand`; the weapon set includes
  it; the armour set includes `chest`; the weapon set excludes `chest`; and — the
  one that matters — **the two halves reconstitute the whole**, so no slot in a
  tier can ever be unreachable by any effect.
- The test points `GEAR_DIR` at `tests/fixtures/gear`, the same fixture artifact
  020 committed, not at `config/tournament/gear/`.

**Notes:**

- **Run the test from WSL** —
  `wsl -d Ubuntu -- bash -lc 'cd /mnt/c/<worktree path> && bash tests/tournament/effects.test.sh'`.
  `jq` is absent from Git Bash on this host and `require_cmd jq` hard-exits 1.
- **The plan's version of this test uses `GEAR_DIR="$ROOT/config/tournament/gear"`,
  which is empty until artifact 021 has been run against a live database.** Using
  the committed fixture instead keeps this artifact's criteria satisfiable in a
  worktree with no server, and changes nothing about what is being tested.
- This artifact edits `scripts/tournament/lib/gear.sh`, which is why it stacks on
  artifact 020. `bash tests/tournament/gear.test.sh` must still pass unchanged.
- Careful with the implementation shape: a `while read` loop on the right-hand
  side of a pipe runs in a subshell, so anything accumulated in a variable inside
  it is lost. Print, do not accumulate.
