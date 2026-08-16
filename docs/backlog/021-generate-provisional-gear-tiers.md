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
- **`base` is white (`quality = 1`) in every slot and `upgrade` is green
  (`quality = 2`).** Uniform basic white for the first tournament: complete and
  fair by construction, refined later once matches are running.
- **Every generated item is one the class can actually wear.** Spot-check at
  least one cloth class (mage/priest/warlock), one leather (rogue/druid), one
  mail (hunter/shaman) and one plate (warrior/paladin) and confirm the chosen
  chest, legs and hands are of that armor `subclass` — not merely
  `allowable_class = -1`. 1,818 of the 1,940 white items are unrestricted by
  class, so the bitmask alone permits a plate chest on a mage and the error only
  surfaces later as `cannot_equip` at apply time.
- `gear_validate <class> <role>` exits 0 for all 12.
- Every distinct item id referenced across all 12 files (including
  `.consumables[].itemId`) resolves in `tw_world.item_template`: the returned row
  count from a bulk `WHERE entry IN (...)` equals the number of distinct ids.
  Any shortfall is identified with a `NOT IN` query and the offending tier file
  fixed before this is considered done.
- The generated files are committed.

**Notes:**

- **This artifact requires a running `tcm-db` container, and you are authorised
  to start one.** `gear-generate.sh` reads `tw_world.item_template` through
  `wsg_mysql` → `docker exec ... tcm-db mysql ...`. There is no offline
  substitute: fabricating ids produces files that validate and then fail to
  equip. Bring up **only the database** — it needs no server image and no build:

  ```
  docker compose --env-file <main-checkout>/.env up -d db
  ```

  Run it from **WSL**, not Git Bash: `.env` holds POSIX bind-mount paths
  (`/home/deck/...`) that Git Bash rewrites into `C:\` paths. Wait for
  `docker inspect --format '{{.State.Health.Status}}' tcm-db` to read `healthy`
  (about 20 s). The world data survived the image fresh-slate — the
  `tortoise-wow-v2_dbdata` volume is intact and holds `tw_world`, `tw_char`,
  `tw_logon`, `tw_logs`.
- **Never `docker compose down -v`.** That volume is the entire world. Plain
  `down`, or leave the db running.
- **`wsg_mysql` sends stderr to `/dev/null`, so a failing query returns silence,
  not an error.** A survey run on 2026-08-16 produced empty output for six
  consecutive queries and looked like "no matching items" when in fact every one
  had failed on an unknown column. When a query returns nothing unexpectedly,
  re-run it through a bare `docker exec ... mysql` with stderr visible before
  concluding anything about the data.
- **Do not put a variable inside a wrapped `wsl -d Ubuntu -- bash -lc '...'`
  one-liner.** It returns plausible-but-wrong output silently — on this host it
  reported an empty log directory and a wrong `du` total in the same command.
  Write a script file and invoke that instead.
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
