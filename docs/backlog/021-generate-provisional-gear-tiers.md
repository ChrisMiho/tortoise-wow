---
status: pending
risk: low
area: tournament/gear
depends-on: 020-gear-tier-library-and-generators.md
---

# The gear tier directory is empty, so no bot can be dressed from a tier

**Problem:** `scripts/tournament/gear-generate.sh` exists but has never been run,
so `config/tournament/gear/` holds nothing. Until it does, `gear-apply.sh` has no
item lists, the `upgrade_armor_*` / `upgrade_weapon_*` viewer effects have no
tier to move into, and `match-run.sh`'s gear gate can never pass — which blocks
telemetry, effects testing, combat analysis, the camera and the release.

**Suspected cause / area:** Not a defect — an unexecuted generation step.
Implements `docs/superpowers/plans/2026-08-16-03-gear-loadouts.md` Task 3 Step 3
(the run) and Task 4 Step 1 (the existence check).

**Acceptance criteria:**

- `./scripts/tournament/gear-generate.sh` has been run and
  `config/tournament/gear/` holds one file per class/role combination used by the
  four shipped teams: `warrior-tank`, `warrior-dps`, `paladin-tank`,
  `hunter-dps`, `rogue-dps`, `priest-healer`, `shaman-healer`, `shaman-dps`,
  `mage-dps`, `warlock-dps`, `druid-tank`, `druid-healer` — 12 files.
- Every file is valid JSON, carries `"provisional": true`, and contains all 13
  required slots in both the `base` and `upgrade` tiers with no `0` values.
- `gear_validate <class> <role>` exits 0 for all 12.
- Every distinct item id referenced across all 12 files (including
  `.consumables[].itemId`) resolves in `tw_world.item_template`: the returned row
  count from a bulk `WHERE entry IN (...)` equals the number of distinct ids.
  Any shortfall is identified with a `NOT IN` query and the offending tier file
  fixed before this is considered done.
- The generated files are committed.

**Notes:**

- **This artifact requires a running `tcm-db` container.** `gear-generate.sh`
  reads `tw_world.item_template` through
  `wsg_mysql` → `docker exec ... tcm-db mysql ...`. There is no offline substitute:
  the whole point is to select real item ids from this server's world data, and
  fabricating ids would produce files that validate and then fail to equip.
  **If `tcm-db` is not reachable, report this artifact blocked rather than
  inventing item ids or committing an empty/partial set.** That is the correct
  outcome, not a failure — a human can bring the stack up and re-run.
- The Docker state on this host is at a deliberate fresh slate (2026-08-16): only
  the rollback anchor image survives and `.env` points `TW_IMAGE` at it. The
  database **volume** (`tortoise-wow-v2_dbdata`) is untouched, so the world data
  is intact — but the stack still has to be brought up for this to work, and
  **never with `docker compose down -v`**; plain `down` only.
- **Run from WSL, not Git Bash** (`jq` and MSYS path rewriting both bite here).
- These ids are mechanically chosen — highest ItemLevel per slot at the tier's
  quality — and are *meant* to stay `"provisional": true` at the end of this work.
  Curation is deferred and scoped separately; see the "Deferred work" section of
  `docs/superpowers/plans/2026-08-16-03-gear-loadouts.md`. Do not hand-pick ids
  here.
- **Sanity gate:** if a cloth robe appears under a warrior's `chest`, the
  `AllowableClass` bitmask is being applied wrongly in `gear-generate.sh` — stop
  and fix that in artifact 020's code rather than editing the generated file.
- Nothing else in the backlog depends on this artifact, deliberately: it is a
  leaf, so a `blocked` outcome here does not stall the rest of the drain.
