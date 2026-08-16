---
status: pending
risk: low
area: tournament/gear
depends-on: 013-tournament-team-definitions.md
---

# Nothing measures whether a bot is actually dressed

**Problem:** `rndbot create ... gear=blue` runs `InitEquipment(false, false)`,
which **destroys every equipped item before choosing replacements**
(`PlayerbotFactory.cpp:2999-3003`) and leaves any slot it cannot fill empty. It
also returns early — equipping nothing at all — below level 5
(`PlayerbotFactory.cpp:2974-2980`) and whenever `specId == 0`
(`PlayerbotFactory.cpp:2988-2994`); both guards carry comments saying they exist
*because* the code stripped bots naked. Nothing anywhere checks completeness, so a
half-dressed bot is indistinguishable from a success, and a match between a
dressed team and a half-dressed one is rigged without anyone noticing.

**Suspected cause / area:** No audit exists. Implements
`docs/superpowers/plans/2026-08-16-03-gear-loadouts.md` Task 1.

**Acceptance criteria:**

- `scripts/tournament/gear-audit.sh <team-id>` is read-only, prints one line per
  bot — `<name> filled=<n>/<required>` plus `missing=<slot,slot,...>` when
  incomplete — then `GEAR-AUDIT <team-id> complete=<n>/10 worstMissing=<n>`.
  Exit 0 only if every bot has every required slot filled; exit 1 otherwise, so it
  works as a gate in a match runner.
- It refuses to run when `team_validate` fails, and issues **one** SQL query for
  the whole team, not one per bot.
- The required set is exactly the 13 slots
  `head neck shoulders chest waist legs feet wrists hands finger1 trinket1 back
  mainhand` (ids `0 1 2 4 5 6 7 8 9 10 12 14 15`, per `Player.h:590-610`).
  `body`(3) and `tabard`(18) are cosmetic, `finger2`(11) and `trinket2`(13) are
  optional duplicates, `offhand`(16) is empty for two-handed specs and
  `ranged`(17) for several others — none of those six may ever be reported as
  missing.
- `bash tests/tournament/gear.test.sh` prints `6 passed, 0 failed` and exits 0,
  and includes an assertion that `tabard` never appears in the output.

**Notes:**

- **Run the test from WSL** —
  `wsl -d Ubuntu -- bash -lc 'cd /mnt/c/<worktree path> && bash tests/tournament/gear.test.sh'`.
  `jq` is absent from Git Bash on this host; `require_cmd jq` hard-exits 1.
- The test stubs `docker` through `tests/lib/stub.sh`, so no database is needed.
  Equipped items live in `character_inventory` at `bag = 0`, `slot <= 18`, joined
  to `item_instance` for `itemEntry`.
- This artifact deliberately does **not** fix `InitEquipment`. It measures the
  problem; artifacts 020-022 replace reliance on it for tournament bots.
- `scripts/tournament/lib/team.sh` (`team_names`, `team_validate`) comes from
  artifact 013 and is present on this branch by dependency.
- **Verification needing a live stack (not part of these criteria):** with a team
  logged in, run the audit against both shipped teams and record the literal
  `GEAR-AUDIT` lines — this is the baseline every later gear task is judged
  against. An `exit=0` here would mean the current roster is already fully geared
  and the problem is narrower than believed; that is a valid and useful result,
  so report it honestly either way.
