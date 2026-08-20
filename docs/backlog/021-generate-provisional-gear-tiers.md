---
status: done
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

**Base:** cm-main

**Branch:** backlog/generate-provisional-gear-tiers

**Summary:** Cut `backlog/generate-provisional-gear-tiers` from `origin/cm-main` and ran `./scripts/tournament/gear-generate.sh` from WSL against the already-running `tcm-db` (mariadb:10.6, `tw_world`), committing the 12 files it wrote into `config/tournament/gear/`. No code changed — this artifact is the generation step, executed. The generated set is exactly the set the four shipped teams need: the class-role pairs across `config/tournament/teams/*.json` diff empty against the filenames in both directions. Every file is valid JSON, carries `"provisional": true`, and fills all 13 required slots in both `base` and `upgrade` with no `0` — 312 picks total — and `gear_validate` exits 0 for all 12 (the generator runs it per file, and it was re-run standalone afterwards). Verification went past the artifact's spot-check requirement: all 312 picks were checked programmatically against `tw_world.item_template` for item class (4 armor / 2 weapon), armor-or-weapon `subclass` inside the class's proficiency list, `required_level <= 60`, `allowable_class` (-1 or the class's bit), `allowable_race = -1`, the four `required_*` guards at 0, and both `ITEM_FLAG_DEPRECATED` (0x10) and `ITEM_EXTRA_NOT_OBTAINABLE` (0x04) clear — zero violations. Quality is uniform: every `base` id is `quality = 1`, every `upgrade` id `quality = 2`, checked per id. Concretely in chest/legs/hands, warrior and paladin get Platemail/Hyperion (subclass 4), hunter and shaman Brigandine/Masterwork (3), rogue and druid Reinforced Leather/Adventurer's (2), mage/priest/warlock Embroidered/Master's (1) — no cloth robe on a warrior, so the artifact's sanity gate does not fire and artifact 020's `lib/itemdb.sh` needs no change. All 80 distinct ids including `.consumables[].itemId` (13446 Major Healing Potion, 8952 Roasted Quail) resolve: a bulk `WHERE entry IN (...)` over the 80 returns 80 rows, so the `NOT IN` fallback was never needed. All six tournament test suites are green (gear 12/12, bracket 9, ctl 6, roster 11, state 10, team 10). One finding worth carrying forward: warrior and paladin `base` shoulders resolve to 83543 "Hidden Plate Shoulders" (item_level 22, armor 1) — a display-hiding item, so a base-tier plate bot will look bare-shouldered. It is not a filter bug: a direct query shows it is the *only* white plate shoulder on this server that passes the equip guards at all, so the alternative is an aborted tier with a hole, and plate still leads on armor (base totals 2303 plate / 1444 mail / 709 leather / 357 cloth). All three plate files get the same item, so nothing is skewed between classes. Fixing the look belongs to the deferred curation artifact, and the notes explicitly forbid hand-picking ids here.

**In-game check:** This artifact adds only data files — no C++ and no SQL migration — so the generic "server starts, bots spawn" smoke test covers the build side. Everything specific to it is checkable without a human looking at a screen, except the last item.

SCRIPTABLE NOW (needs only `tcm-db` up; no server image, no build; run every command from WSL, not Git Bash — `jq` is absent there):

1. Re-run the generator and confirm it is idempotent and still exits 0:
   `cd <checkout> && ./scripts/tournament/gear-generate.sh` — expect 12 `wrote .../config/tournament/gear/<class>-<role>.json` lines, exit 0, and `git status --short config/tournament/gear` empty afterwards. A non-empty diff means the item database changed under the tier files and they need regenerating, not that the run failed.
2. Validate all 12 through the library everything downstream reads them with:
   source `scripts/tournament/lib/gear.sh` and call `gear_validate <class> <role>` for each of the 12 pairs. Expect exit 0 and no output for all 12. Any line matching `has no item for required slot` or `is still a placeholder 0` is a hard failure.
3. Confirm every referenced id still resolves. Collect `jq -r '[.tiers[].items[], (.consumables[].itemId)] | .[]' config/tournament/gear/*.json | sort -nu` (80 ids today) and run `SELECT COUNT(*) FROM tw_world.item_template WHERE entry IN (...)` through a bare `docker exec -e MYSQL_PWD=... tcm-db mysql -uroot -N -B -e ...`. The count must equal the number of distinct ids. Do NOT use `wsg_mysql` here — it sends stderr to `/dev/null`, so a broken query returns silence that reads exactly like a shortfall.
4. Confirm quality and wearability still hold: for every id, `quality` must be 1 for `base` and 2 for `upgrade`; every non-`mainhand` pick must be `class = 4` with `subclass` in the class's armor proficiency list and every `mainhand` pick `class = 2` with `subclass` in its weapon list (both lists are `itemdb_armor_subclasses` / `itemdb_weapon_subclasses` in `scripts/tournament/lib/itemdb.sh`); and `required_level <= 60`, `allowable_race = -1`, all four `required_*` columns 0, `flags & 0x10 = 0`, `extra_flags & 0x04 = 0`. All 312 picks passed on 2026-08-18.
5. `bash tests/tournament/gear.test.sh` — expect `12 passed, 0 failed`.

NEEDS A HUMAN IN THE WORLD, and only once `gear-apply.sh` exists (it is a later artifact; `match-run.sh:221` already guards for its absence, so today the gear gate reports holes rather than filling them):

6. Log in as a GM, spawn or select a level-60 warrior bot, and apply `warrior-tank` `base`. Confirm the bot ends up with something in all 13 slots — head, neck, shoulders, chest, waist, legs, feet, wrists, hands, ring 1, trinket 1, back, main hand — and that the server log carries no `cannot_equip` / `CanEquipNewItem` failure for any of them. Character sheet chest should read `Platemail Armor`, legs `Platemail Leggings`, hands `Platemail Gloves`, main hand `Gamemaster's Blade of Silence`.
7. Repeat for a mage with `mage-dps` `base` and confirm chest/legs/hands read `Embroidered Armor` / `Embroidered Pants` / `Embroidered Gloves` — cloth, not plate. This is the check that catches the `allowable_class`-only bug, which never surfaces until apply time.
8. Trigger `upgrade_armor_*` on the warrior and confirm the tier moves `base` → `upgrade` and the items visibly change to the Hyperion set (`Hyperion Armor` / `Hyperion Legplates` / `Hyperion Gauntlets`, green, item_level 63), and that a second upgrade is a no-op rather than a wrap-around back to white.
9. Cosmetic, expected, not a bug: the warrior and paladin `base` shoulder slot holds `Hidden Plate Shoulders` (83543), which is a display-hiding item — the bot will look bare-shouldered while the slot is genuinely filled. It is the only white plate shoulder on this server that passes the equip guards. If someone files that as a bug, it belongs to the deferred gear-curation artifact.

**Minor findings:**
- config/tournament/gear/warrior-tank.json: Base `shoulders` for warrior-tank, warrior-dps and paladin-tank is 83543 "Hidden Plate Shoulders" (armor 1, item_level 22) — the heaviest-subclass-first FIELD() ordering in scripts/tournament/lib/itemdb.sh picks a cosmetic 1-armor item over any real shoulder, so plate bots start with an effectively empty slot while a hunter gets 128 armor and a mage 27; the fix belongs in artifact 020's ordering, not in the generated file.
- config/tournament/gear/mage-dps.json: The mechanical pick lands on GM-only items — 2543 "Gamemaster's Medallion" as the base neck in all 12 files and 2540 "Gamemaster's Blade of Silence" as the base mainhand in 7 — which is harmless mechanically (both effects are spelltrigger 0 / on-use and UseTrinketAction only fires for INVTYPE_TRINKET) but puts GM gear on every bot on stream; the flag guards cannot catch them since neither carries ITEM_FLAG_DEPRECATED or ITEM_EXTRA_NOT_OBTAINABLE.

**Drain note:** The first minor finding above misstates its mechanism and should not be acted on as written. Verified against tw_world.item_template on 2026-08-18: among white (quality=1) shoulders passing every equip guard, plate (subclass 4) has exactly ONE candidate — 83543 Hidden Plate Shoulders, armor 1 — so the FIELD() ordering did not pass over "any real shoulder"; there is no other plate shoulder to pick. The Summary line is correct on this point and the finding is not. The real lever is that heaviest-subclass-first in artifact 020 never falls back to a lighter subclass when the heavier one has any candidate at all, even a 1-armor cosmetic: mail (subclass 3) offers 10 white shoulders up to 128 armor that a plate class could legally wear. Any follow-up artifact should be scoped to that fallback rule, not to reordering within plate.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/34, build tortoise-cm:20260818-1.
