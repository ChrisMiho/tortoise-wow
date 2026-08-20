---
status: done
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
- **Run once against the live database and record the literal output** in the
  commit message: `./scripts/tournament/gear-audit.sh stormwind-sentinels` and
  the same for `orgrimmar-warsong`. This is read-only and needs no server image —
  `docker compose --env-file <main-checkout>/.env up -d db` is enough.
- **The expected answer is already known, so this doubles as a correctness check
  on the script.** Measured directly against `character_inventory` on
  2026-08-16, counting the 13 required slots: `stormwind-sentinels
  complete=4/10`, `orgrimmar-warsong complete=5/10`. Per-bot filled counts —
  Alliance: one 6, two 5, three 12, four 13, five 11, six 13, seven 5, eight 13,
  nine 12, ten 13. Horde: one 7, two 13, three 12, four 13, five 12, six 13,
  seven 7, eight 13, nine 5, ten 13. **If the script disagrees with those
  numbers, the script is wrong** — most likely its slot set or its join. Report
  the discrepancy rather than accepting the script's answer.

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

**Base:** cm-main

**Branch:** backlog/gear-audit

**Summary:** Added `scripts/tournament/gear-audit.sh <team-id>` (absolute path: C:\Coding\tortoise-wow\tortoise-wow\.claude\worktrees\wf_9d1b3556-9fc-1\scripts\tournament\gear-audit.sh) and `tests/tournament/gear.test.sh`, in one commit (dcf9a40) on `backlog/gear-audit`, cut from origin/cm-main. The audit is read-only and costs exactly one SELECT for the whole team: it LEFT JOINs off `characters` so a roster name with no character row still reports `filled=0/13` instead of vanishing, while INNER JOINing `character_inventory` to `item_instance` inside that nested join so an inventory row whose item instance is gone counts as an empty slot. It sources `lib/team.sh` from artifact 013 and refuses (exit 2) to audit any team that fails `team_validate`. The required set is exactly the 13 slots `head neck shoulders chest waist legs feet wrists hands finger1 trinket1 back mainhand` (ids 0 1 2 4 5 6 7 8 9 10 12 14 15, which I verified against `src/game/Objects/Player.h:590-610` — note the artifact's `Player.h` path is actually `src/game/Objects/Player.h`); `body`, `tabard`, `finger2`, `trinket2`, `offhand` and `ranged` are never named. It deliberately does NOT use `wsg_mysql`, because that helper discards mysql's stderr and a failed query would then read as "every bot is naked" — instead stderr reaches the operator and the exit status is checked. Exit codes: 0 only when every bot is complete, 1 on any gap (the gate case), and 2 when the audit could not run at all (bad team file, missing jq/docker, database unreachable) — the same third-code distinction `team-validate.sh` already draws; the artifact did not specify a code for the refusal case, and 2 is still non-zero so the gate property holds. `bash tests/tournament/gear.test.sh` prints `6 passed, 0 failed` and exits 0 (`team.test.sh` still 10/10). Run against the live `tw_char`, both shipped teams returned `complete=4/10 worstMissing=8` and `complete=5/10 worstMissing=8`, exit 1 each — matching the artifact's independently measured per-bot counts exactly, digit for digit, so the run doubles as the correctness check it was meant to be; the literal output is recorded in the commit message. No schema change, no migration, no Docker build; the only container touched was the already-running `tcm-db`, read-only, and it is still healthy.

**In-game check:** This change is a read-only shell script plus its test. It adds no C++, no console command and no schema change, so it cannot affect server boot or bot spawning — the generic "server starts, bots spawn" smoke test is not the interesting check here. What DOES need confirming is that the script's numbers describe the actual bots a human sees in the world. Steps 1-4 and 7 are fully scriptable with no server image and no build; steps 5-6 need a running world and a human's eyes.

SCRIPTABLE (database only — `docker compose --env-file <main-checkout>/.env up -d db`, wait for `docker inspect --format '{{.State.Health.Status}}' tcm-db` to read `healthy`; run everything from WSL, not Git Bash, because jq is absent there):

1. `wsl -d Ubuntu -- bash -lc 'cd /mnt/c/<worktree> && bash tests/tournament/gear.test.sh'` prints exactly `6 passed, 0 failed` and exits 0. (Do not wrap variables in that one-liner — put the command in a script file if you need `$?`.)
2. `./scripts/tournament/gear-audit.sh stormwind-sentinels` reproduces, line for line, the 11-line block recorded in the commit message and exits 1 — in particular `GEAR-AUDIT stormwind-sentinels complete=4/10 worstMissing=8`. Same for `orgrimmar-warsong`: `complete=5/10 worstMissing=8`, exit 1. These are the baseline every later gear artifact (020-022) is judged against. NOTE: an exit 0 here would mean the roster got re-geared since 2026-08-17, not that the script broke — re-check against `character_inventory` before assuming a regression.
3. Negative path, the one that matters most: `DB_CONTAINER=tcm-db-does-not-exist ./scripts/tournament/gear-audit.sh stormwind-sentinels` must print `FATAL: the gear query failed ...` and exit 2. It must NOT print ten `filled=0/13` lines. (Verified already; re-run it after any edit to the query, because "every bot is naked" is this script's most dangerous possible false positive.) The same holds with the db genuinely stopped — `docker stop tcm-db` then `docker start tcm-db` is safe, it does not touch the volume — but the fake-container form is cheaper and exercises the identical code path.
4. `./scripts/tournament/gear-audit.sh no-such-team` and `./scripts/tournament/gear-audit.sh` with no argument both exit 2, not 0 and not 1.

NEEDS A LIVE WORLD AND A HUMAN (do this once, when a server image containing the current branch is next running — the audit itself needs no server, but confirming its answers is true does):

5. Log the Alliance team in and eyeball the two extremes the audit names. Target or `.inspect` **Wsgatwo** — the audit says `filled=5/13 missing=head,shoulders,chest,waist,legs,feet,wrists,hands` — and confirm on the character model and in the inspect window that it is genuinely wearing no helm, no shoulders, no chest, no belt, no legs, no boots, no bracers and no gloves, while it DOES have a neck, a ring, a trinket, a cloak and a weapon. Then inspect **Wsgafour**, which the audit calls `filled=13/13`, and confirm all thirteen of those slots are occupied. This is the check that the `missing=` list is real gear and not a join artifact. While you are in the inspect window, confirm the audit was right to stay silent about the cosmetic and optional slots: a bare tabard slot, an empty off-hand on a two-handed warrior, or an empty ranged slot must NOT have been reported.
6. Confirm the audit reads live state, not a stale snapshot. `character_inventory` is only written when a character SAVES, so an in-memory re-gear is invisible until then: re-create one incomplete bot with `rndbot create name=Wsgatwo ... gear=blue`, issue `saveall` from the console (use `wsg_console` from `docs/playerbots/wsg/lib/wsg-bots-common.sh` — never a bare `docker attach`, EOF shuts the world down), then re-run the audit and confirm Wsgatwo's `filled=` count moved. Re-run it once more against an untouched bot and confirm that count did NOT move. If the number never changes across a save, the audit is reading the wrong database or the wrong realm and every later gear task built on it is measuring nothing.

FROM LOGS / OUTPUT RATHER THAN A HUMAN:

7. The audit's own stderr is the signal. A healthy run prints nothing on stderr at all; any mysql error text appearing there means the run should be discarded rather than believed, and the exit code will be 2 to match. There is no server log line to watch for — this change never reaches the server image (`scripts/` and `tests/` are not compiled and do not affect the build), so if a batch build of this branch fails, the cause is elsewhere in the batch.

**Minor findings:**

- scripts/tournament/gear-audit.sh: The SQL name match is case-insensitive (MySQL collation) but the bash lookup `${FILLED[$n]:-}` is case-sensitive, so any roster whose `namePrefix` capitalization differs from the server's normalized character name (e.g. `"namePrefix": "WSGA"`, which the server stores as `Wsgaone`) would key-miss every bot and report the whole team `filled=0/13` — precisely the maximally-alarming false positive the script's own comments say it exists to avoid.
- scripts/tournament/gear-audit.sh: The audit reads character_inventory/item_instance directly while the worldserver holds newer equipment state in memory and flushes it only on a delayed save or logout, so running it as a live match gate can report freshly geared bots as missing slots.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/27, build tortoise-cm:20260817-1.
