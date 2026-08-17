---
status: done
risk: low
area: tournament/teams
depends-on:
---

# Tournament teams are console transcripts, not data

**Problem:** The only definition of the 20 WSG bots is
`docs/playerbots/wsg/wsg-team-roster.txt` plus the `rndbot create` lines a human
types. Nothing validates a roster before it touches the server, and the one fault
that matters is invisible until it is permanent: **character names are
`^[A-Za-z]+$`, max 12 chars, and a digit is rejected at character *load*, not
creation**. The gate is `ObjectMgr::CheckPlayerName` (`ObjectMgr.cpp:7051-7069`):
the length limit is `MAX_PLAYER_NAME` = 12 (`ObjectMgr.h:472`), and digits are
rejected by its `isValidString(wname, strictMask, /*numericOrSpace=*/false,
create)` call, which resolves down to `isBasicLatinString` (`Util.h:376-394`) —
that hardcoded `false` is the whole reason a digit fails.
`PlayerbotMgr.cpp:2505-2506` prints
`"Bot is now online"` before login is even attempted, so a digit-named bot looks
like a successful login followed by a mystery disconnect, and leaves a row with
`at_login=1` that can never come online and must be deleted by hand. That cost a
full debugging session.

**Suspected cause / area:** No structured team definition exists. Implements
`docs/superpowers/plans/2026-08-16-01-team-definitions-and-rosters.md` Tasks 1-2.

**Acceptance criteria:**

- `config/tournament/teams/stormwind-sentinels.json` and
  `config/tournament/teams/orgrimmar-warsong.json` exist, holding exactly the 20
  bots already listed in `docs/playerbots/wsg/wsg-team-roster.txt` (same names,
  classes, races, roles, factions).
- `scripts/tournament/lib/team.sh` is sourceable (never executed) and provides
  `team_file`, `team_field`, `team_names`, `team_rows`, `team_validate`.
  `team_rows` emits `name|class|race|role|faction`, deliberately the same shape as
  `wsg-team-roster.txt`, so `wsg_load_roster` keeps working.
- `scripts/tournament/team-validate.sh` validates the named teams, or every team
  in `config/tournament/teams/` when given none; exit 0 if all valid, 1 otherwise.
- `bash tests/tournament/team.test.sh` prints `10 passed, 0 failed` and exits 0.
- `./scripts/tournament/team-validate.sh` exits 0 and prints one `ok` line per
  shipped team.
- `team_validate` rejects, each with a message naming the fault: a non-alphabetic
  `namePrefix` (message must contain the word `alphabetic`), a `faction` that
  disagrees with the roster's races, a roster that is not exactly the 10 canonical
  slots `one`…`ten` in order, a generated name over 12 characters, and a `role`
  outside `tank|healer|dps`.

**Notes:**

- **Run the test from WSL, not Git Bash.** `jq` is not on Git Bash's `PATH` on
  this host, and `require_cmd jq` in `tests/lib/assert.sh` is a hard `exit 1`, not
  a skip — so a Git Bash run reports a failure that has nothing to do with this
  code. Proven form:
  `wsl -d Ubuntu -- bash -lc 'cd /mnt/c/<worktree path> && bash tests/tournament/team.test.sh'`.
  Write it as a literal path with no shell variables interpolated into the
  `bash -lc` string.
- The test harness (`tests/lib/assert.sh`, `tests/lib/stub.sh`) already exists on
  `cm-main` from the build-provenance work. `assert_exit`'s signature is
  `assert_exit <expected-code> <label> -- <command...>`.
- `config/` and `tests/` are already in `.dockerignore`, so nothing here enters a
  Docker layer or invalidates the `COPY . /src` cache.
- Nothing in this artifact touches the server or the database. No build is
  needed and none should be attempted.
- Plan 01 Task 3 Step 5 (`roster.sh status` against the live server) belongs to
  the next artifact, not this one.

**Base:** cm-main

**Branch:** backlog/tournament-team-definitions

**Summary:** Turned the 20 WSG bots from a flat text file plus typed console lines into version-controlled data with a validation gate in front of it. Added `config/tournament/teams/stormwind-sentinels.json` and `config/tournament/teams/orgrimmar-warsong.json` holding exactly the 20 bots already in `docs/playerbots/wsg/wsg-team-roster.txt`; `scripts/tournament/lib/team.sh` (sourceable, mode 644, never executed) providing `team_file`, `team_field`, `team_names`, `team_rows` and `team_validate`, where `team_rows` emits `name|class|race|role|faction` so `wsg_load_roster` in `docs/playerbots/wsg/lib/wsg-bots-common.sh` keeps working unchanged; and `scripts/tournament/team-validate.sh` (mode 755) as the standalone gate that validates the named teams or every team in the directory, exiting 0 when all are valid and 1 otherwise. `team_validate` refuses a non-alphabetic `namePrefix`, a `faction` that disagrees with the roster's races, a roster that is not the ten canonical slots `one`…`ten` in order, a generated name over 12 characters, and a `role` outside `tank|healer|dps`, printing a message naming each fault rather than stopping at the first. `tests/tournament/team.test.sh` prints `10 passed, 0 failed` and exits 0, and its strongest assertion compares `team_rows` for both teams against `wsg-team-roster.txt` byte for byte, so the JSON and the flat file cannot drift apart. I mutation-checked every rule by neutering each one in turn and re-running the suite: each of the race/faction, slot-order, name-length and role rules turns the suite red on its own when removed, and the two alphabetic checks (on the prefix and on the generated name) are deliberately redundant and fail only when both are removed. This is Tasks 1-2 of `docs/superpowers/plans/2026-08-16-01-team-definitions-and-rosters.md`; Task 3 onward (`roster.sh`) is explicitly the next artifact and was not touched. No C++, no SQL migration, and no server or database access is involved, and `config/` and `tests/` are already in `.dockerignore`, so no build is needed. Branch cut from `origin/cm-main` (55cff54) and is exactly one commit ahead.

**In-game check:** This change adds no C++, no SQL migration, and nothing the server reads at runtime — it is shell and JSON under `config/` and `tests/`, both already in `.dockerignore`. So there is no new in-game behaviour to observe and no new log line to grep for. The generic "server starts, bots spawn" smoke test is sufficient as a regression check. What IS worth confirming on a live server is that the data these files assert is true of the real world, and almost all of it is scriptable.

FULLY SCRIPTABLE, no running server needed (a later batch step should just run these):
1. `wsl -d Ubuntu -- bash -lc 'cd /mnt/c/Coding/tortoise-wow/tortoise-wow && bash tests/tournament/team.test.sh'` → last line must read `10 passed, 0 failed`, exit 0.
2. `wsl -d Ubuntu -- bash -lc 'cd /mnt/c/Coding/tortoise-wow/tortoise-wow && ./scripts/tournament/team-validate.sh'` → exactly two lines, `ok    orgrimmar-warsong (H, Orgrimmar Warsong)` and `ok    stormwind-sentinels (A, Stormwind Sentinels)`, exit 0.
3. Negative check, proving the gate is live rather than decorative: copy `stormwind-sentinels.json` into a temp dir with `jq '.namePrefix = "Wsga1"'`, run `TEAM_DIR=<tmp> ./scripts/tournament/team-validate.sh stormwind-sentinels`, and confirm it prints a message containing `alphabetic` and exits 1. Confirm `git status --porcelain config/` is empty afterwards.
   Run all three from WSL, not Git Bash — `jq` is not on Git Bash's PATH on this host and `require_cmd jq` is a hard `exit 1`, not a skip. Also do not interpolate `$?` or any shell variable into the `wsl -- bash -lc '...'` string: the Windows layer expands it before WSL sees it, which made a correct `exit 1` report as `EXIT=0` while I was testing. Use `{ cmd && echo ok; } || echo nonzero` instead.

SCRIPTABLE, needs the stack up (`tcm-db` running) — the one claim that cannot be checked offline, namely that the JSON describes bots that actually exist and are healthy:
4. Query the character table for all 20 generated names at once:
   `docker exec -e MYSQL_PWD="$(wsg_db_pass)" tcm-db mysql -uroot -N -B -e "SELECT name, at_login FROM tw_char.characters WHERE name IN ('Wsgaone','Wsgatwo','Wsgathree','Wsgafour','Wsgafive','Wsgasix','Wsgaseven','Wsgaeight','Wsganine','Wsgaten','Wsghone','Wsghtwo','Wsghthree','Wsghfour','Wsghfive','Wsghsix','Wsghseven','Wsgheight','Wsghnine','Wsghten') ORDER BY name;"`
   Expect exactly 20 rows, and `at_login` = 0 on every one. Fewer than 20 rows means the JSON names a bot that was never created (the JSON is wrong, not the server). Any `at_login` = 1 is a live instance of the exact fault this artifact exists to prevent — that row was rejected at character load, can never come online, and must be deleted by hand.
5. Cross-check class/race, which the JSON also asserts and step 4 does not cover:
   `docker exec -e MYSQL_PWD="$(wsg_db_pass)" tcm-db mysql -uroot -N -B -e "SELECT name, class, race FROM tw_char.characters WHERE name IN ('Wsgaone','Wsghtwo');"`
   `Wsgaone` must come back class 1 (warrior) race 1 (Human); `Wsghtwo` must come back class 11 (druid) race 6 (Tauren). Those are the two rows where the JSON and the old flat file would most obviously disagree if someone had transcribed a slot wrong.

MANUAL, and genuinely optional — only if steps 4-5 cannot be run:
6. Log in as a GM, `.go creature` is not needed; just `.lookup player Wsgaone`, then target it and confirm the tooltip reads Human Warrior, and repeat for `Wsghtwo` reading Tauren Druid. This is the eyeball version of step 5 and adds nothing if the SQL ran.

No log line should change as a result of this branch. If a rebuilt image or the mangosd log differs in any way after merging this, that is itself the finding — `config/` and `tests/` are `.dockerignore`d and no CMakeLists references either path, so the compiled binary must be identical.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/22, build tortoise-cm:20260816-1.
