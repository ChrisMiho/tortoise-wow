---
status: pending
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
creation** (`Util.h:376-394`). `PlayerbotMgr.cpp:2505-2506` prints
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
