---
status: done
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

**Base:** cm-main

**Branch:** backlog/gear-tier-armour-weapon-split

**Summary:** Added the tier splitters to `scripts/tournament/lib/gear.sh`: a single `GEAR_WEAPON_SLOTS="mainhand offhand ranged"` constant (the three EQUIPMENT_SLOT_MAINHAND/OFFHAND/RANGED entries in `src/game/Objects/Player.h:590-610`), plus `gear_items_weapon <class> <role> <tier>` and `gear_items_armor <class> <role> <tier>`, which filter `gear_items`' output and emit the identical `slot|itemId` lines. Both print from inside the `while read` loop rather than accumulating, since that loop is the right-hand side of a pipe and runs in a subshell. A comment states explicitly that everything not in the weapon set — neck, finger1, trinket1 and back included, none of which are "armour" in the item-class sense — belongs to the armour half, because "upgrade my armour" means "everything but the weapon" to the viewer paying for it, and a slot in neither half would be unreachable by any effect. New `tests/tournament/effects.test.sh` sources the library with `GEAR_DIR` pointed at `tests/fixtures/gear` (the fixture artifact 020 committed, not `config/tournament/gear/`, which is empty until the generator runs against a live `item_template`) and asserts five things: armour excludes `mainhand`, weapon includes it, armour includes `chest`, weapon excludes it, and — comparing the sorted union of the halves against the sorted whole rather than just counting lines, so a slot in *both* halves fails too — that the halves reconstitute the tier exactly. It prints `5 passed, 0 failed` and exits 0; `tests/tournament/gear.test.sh` still prints `12 passed, 0 failed` and exits 0. Files: C:\Coding\tortoise-wow\tortoise-wow\.claude\worktrees\wf_fbe37348-e36-1\scripts\tournament\lib\gear.sh and C:\Coding\tortoise-wow\tortoise-wow\.claude\worktrees\wf_fbe37348-e36-1\tests\tournament\effects.test.sh. Committed as fe9a9cd. No SQL migration and no C++ change; nothing was built.

**In-game check:** Nothing here changes in-world behaviour yet, and it is honest to say so: this artifact adds two shell functions and a test to `scripts/tournament/lib/gear.sh`. No C++ was touched, no new console command exists, and no caller consumes the splitters until the `upgrade_armor_*` / `upgrade_weapon_*` effects land in a later artifact of this plan — there is no `tournament equip` subcommand in `Chat.cpp`'s `tournamentCommandTable` today (only status/create/add/members/start/stop/result). So the beyond-smoke-test in-game confirmation is deferred, and the meaningful confirmation now is scriptable.

Fully scriptable, no human eyes needed (a batch step can run all of this):

1. From WSL: `wsl -d Ubuntu -- bash -lc 'cd /mnt/c/<worktree> && bash tests/tournament/effects.test.sh'` — expect the last line `5 passed, 0 failed` and exit 0. Do NOT run it from Git Bash; `jq` is absent there and `require_cmd jq` hard-exits 1 with "FATAL: missing required tool(s): jq", which is a tooling failure, not a code failure.
2. Same shell: `bash tests/tournament/gear.test.sh` — expect `12 passed, 0 failed`, exit 0, unchanged from before this branch. This is the regression gate; the splitters were appended to a file the audit and tier tests both source.
3. Optional, and the one thing that exercises `offhand` and `ranged` (the committed fixture has neither, only `mainhand`): source `scripts/tournament/lib/gear.sh` in WSL, point `GEAR_DIR` at a temp copy of `tests/fixtures/gear/warrior-tank.json` with `offhand` and `ranged` added via `jq`, then check `gear_items_weapon warrior tank base` prints exactly those three lines and `gear_items_armor ... | wc -l` plus 3 equals `gear_items ... | wc -l`. Measured here: 12 + 3 = 15.

Requires a human, but only once the live server has real tier files (after artifact 021's generator has been run against `tw_world.item_template`): with `GEAR_DIR=config/tournament/gear`, run `gear_items_armor <class> <role> <tier>` for a real class/role and eyeball that the printed slot list is the character sheet minus the weapon — no `mainhand`, no `offhand`, no `ranged` — while `gear_items_weapon` prints only those, and that the two lists concatenated match `gear_items` line for line. That is the same property the test asserts, checked against generated rather than fixture data, and it is the only check the fixture cannot cover.

Generic smoke test otherwise: the server starts and bots spawn. This branch cannot affect that — it adds no compiled code, so the only way it could break a build is if it did not exist, and it changes no file mangosd reads.

**Minor findings:**
- scripts/tournament/lib/gear.sh: gear_items_armor / gear_items_weapon swallow gear_items' failure: because gear_items is on the left of a pipe and the function returns the while loop's status, an unknown class/role/tier yields exit 0 with empty output instead of the exit 1 gear_items itself returns, so a future upgrade_armor_*/upgrade_weapon_* caller would read a silent no-op as a successful purchase.

**Drain note (the minor finding is REPRODUCED, and is worth more than "minor" given what consumes this):** verified empirically on 2026-08-18 by sourcing the branch's gear.sh with GEAR_DIR=tests/fixtures/gear and calling it with a bogus class:

```
gear_items        nosuchclass tank base  -> rc=1  output_len=0
gear_items_armor  nosuchclass tank base  -> rc=0  output_len=0
gear_items_weapon nosuchclass tank base  -> rc=0  output_len=0
```

The underlying lookup correctly reports failure and both splitters convert it to success. Cause is as the finding states: `gear_items ... | while ...` makes the loop the last command in the pipeline, so without `set -o pipefail` the function returns the loop's status, and a loop that reads zero lines exits 0. Both valid-input cases return rc=0 as expected, so the bug is only on the failure path.

This is a payment-correctness issue rather than a cosmetic one, because of what these functions exist to feed: the whole purpose of this artifact is to back the `upgrade_armor_*` and `upgrade_weapon_*` viewer effects, which are separately priced. A viewer pays for an armour upgrade, a typo or a missing tier file makes the lookup fail, the caller sees rc=0 with no items, and nothing is applied while the purchase reads as fulfilled. Worth fixing before any effect consumer lands (artifacts 032-034). Options: `set -o pipefail` around the pipeline, or capture `gear_items` output first and check its status before filtering.

**Also confirmed:** GEAR_WEAPON_SLOTS="mainhand offhand ranged" matches src/game/Objects/Player.h, where EQUIPMENT_SLOT_MAINHAND/OFFHAND/RANGED are 15/16/17 — inside the cited :590-610 range and the complete set of weapon slots.

**One stale statement to ignore in the In-game check above:** it asserts there is no `tournament equip` subcommand in Chat.cpp's tournamentCommandTable "today". That is true of this branch's base (cm-main) but stale project-wide — artifact 017 added `equip` and `store`, is status done, ships in tortoise-cm:20260818-1 and -2, and was observed working in bg.log. It is simply awaiting the merge of PR #33.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/42, build tortoise-cm:20260818-3.
