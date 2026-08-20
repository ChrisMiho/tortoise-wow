---
status: done
risk: medium
area: tournament/rosters
depends-on: 013-tournament-team-definitions.md
---

# Creating and swapping a team's 10 characters is a manual console transcript

**Problem:** Bringing a team into existence, checking it survived, and swapping it
out between rounds are all hand-typed `rndbot` console lines today. Three things
make that unsafe to repeat: **`rndbot` console replies go to a null player session
and vanish**, so success can never be inferred from console output; **console EOF
shuts the world down** (compose is `restart: "no"`), so every extra `docker attach`
is another chance to kill the server; and a broken row (`at_login != 0`) is
indistinguishable from a slow one unless something reads `tw_char.characters`
directly.

**Suspected cause / area:** No reconciliation driver exists. Implements
`docs/superpowers/plans/2026-08-16-01-team-definitions-and-rosters.md` Tasks 3-6.

**Acceptance criteria:**

- `scripts/tournament/roster.sh` provides four subcommands, all taking a team id,
  all refusing to run when `team_validate` fails:
  - `status` — read-only. One line per slot
    (`<name> <exists|missing> <online|offline> <level> <at_login>`) plus
    `ROSTER <team-id> present=<n>/10 online=<n>/10 broken=<n>`. Always exit 0; it
    reports, it does not judge. Every other subcommand is defined in terms of it —
    nothing else queries the database directly.
  - `ensure [--login]` — creates missing characters, **refuses outright while any
    row is broken** (`at_login != 0`), prints `already complete` and exits 0 when
    nothing is missing, and re-runs safely.
  - `login` — `rndbot add <name>` per slot, then blocks until `online=10/10` or a
    180 s deadline.
  - `logout` — `rndbot remove <name>` per slot. **Never deletes a character row.**
- `status` issues **one** SQL query for the whole roster, not ten, and every
  console-writing subcommand batches all its lines into **one** `wsg_console`
  call.
- `bash tests/tournament/roster.test.sh` prints `11 passed, 0 failed` and exits 0.
- **`roster.sh status` has been run once against the live database** and its
  literal output recorded in the commit message, for both shipped teams. This is
  read-only and needs only the database container, not a server image. A
  `broken=` count above zero is a real finding about the current world — report
  it, do not clean it up here.
- `docs/playerbots/TOURNAMENT-ROSTERS.md` exists and states the alphabetic-name
  rule, the four commands, how to add a team, and that the roster does **not**
  come back on its own after a mangosd restart.
- `docs/playerbots/WSG-BOT-MATCH.md` §2.3 carries a pointer to that new doc,
  saying the flat file stays valid and both paths describe the same 20 bots.

**Notes:**

- **Run tests from WSL** —
  `wsl -d Ubuntu -- bash -lc 'cd /mnt/c/<worktree path> && bash tests/tournament/roster.test.sh'`.
  `jq` is absent from Git Bash on this host and `require_cmd jq` hard-exits 1.
- Reuse `wsg_mysql` and `wsg_console` from
  `docs/playerbots/wsg/lib/wsg-bots-common.sh`; do not reimplement DB or console
  access. `wsg_console <lines> <wait_s>` always returns 0 by design — its exit
  status carries no information, which is exactly why the post-check must read
  the database.
- The tests stub `docker` and `script` via `tests/lib/stub.sh`, so no server is
  needed. `wsg_db_pass` falls back to `docker exec tcm-db printenv ...`, which the
  stub absorbs — do not add a second stub for it.
- Creation is asynchronous: the row appears a beat after the command lands, and
  `characters.online` lags reality by up to 60 s (`PlayerSave.Interval`). Poll
  with a deadline; do not read once and conclude.
- A bot account holds at most 9 characters (`PlayerbotMgr.cpp:2325`).
- **Verification needing the full stack, deliberately left out of the criteria:**
  `ensure`, `login` and `logout` need mangosd running, and `ensure` **creates 20
  characters in the live world**. That is wanted eventually, but not as an
  unannounced side effect of implementing a script, so it stays an operator step:
  `logout` → `status` (expect `online=0/10`) → `login` (expect `online=10/10`),
  allowing up to 60 s of stale `online` readings. These use `rndbot`, which
  exists in the rollback-anchor image, so they do not need a fresh build.

**Base:** cm-main

**Branch:** backlog/tournament-roster-lifecycle

**Summary:** Added `scripts/tournament/roster.sh`, the reconciliation driver that replaces the hand-typed `rndbot` transcript with four subcommands (`status`, `ensure [--login]`, `login`, `logout`), all of which refuse to run when `team_validate` fails on the named team. `status` is the only one that touches the database: it issues one query for the whole roster (not ten), prints `<name> <exists|missing> <online|offline> <level> <at_login>` per slot plus `ROSTER <team-id> present=<n>/10 online=<n>/10 broken=<n>`, uses `-` rather than a fabricated `0` for a missing slot's level/at_login, and always exits 0 because it reports rather than judges. `ensure`, `login` and `logout` are defined in terms of its output, so one place knows the SQL: `ensure` creates what status calls missing and refuses outright while any row is broken (`at_login != 0`) even when nothing is missing, prints `already complete` and exits 0 when there is nothing to do, and re-runs safely; `login` sends `rndbot add` per slot then polls to `online=10/10` or a 180 s deadline; `logout` sends `rndbot remove` per slot and never deletes a character row. Every console-writing subcommand batches its whole block into exactly one `wsg_console` call — the test counts attaches, not just lines, because console EOF shuts the world down — and every one verifies by re-reading the database afterwards, since `wsg_console` always returns 0 by design. `logout` deliberately omits a settle sleep and instead prints a note that `characters.online` trails reality by up to `PlayerSave.Interval` (60 s). `tests/tournament/roster.test.sh` prints `11 passed, 0 failed` and exits 0 under stubbed `docker`/`script` (verified from WSL; `tests/tournament/team.test.sh` still prints `10 passed, 0 failed`, `team-validate.sh` still exits 0, and shellcheck at warning level is clean). `docs/playerbots/TOURNAMENT-ROSTERS.md` documents the alphabetic-name rule, the four commands, how to add a team, and that the roster does not come back on its own after a mangosd restart; `docs/playerbots/WSG-BOT-MATCH.md` §2.3 now points at it and states the flat file stays valid because `team_rows` emits the same rows for the same 20 bots. `status` was run once against the live database (tcm-db brought up alone, no server image, no build) for both shipped teams and the literal output is recorded in the commit message: both read `present=10/10 online=0/10 broken=0`. **broken=0 for both — the existing 20-bot roster is intact and nothing needs cleaning up**; `online=0/10` is expected and not a finding, since only the database container was running. Key files: `C:\Coding\tortoise-wow\tortoise-wow\.claude\worktrees\wf_036774d1-505-1\scripts\tournament\roster.sh`, `C:\Coding\tortoise-wow\tortoise-wow\.claude\worktrees\wf_036774d1-505-1\tests\tournament\roster.test.sh`, `C:\Coding\tortoise-wow\tortoise-wow\.claude\worktrees\wf_036774d1-505-1\docs\playerbots\TOURNAMENT-ROSTERS.md`. One commit, `005369f`; nothing pushed, no PR. The tcm-db container was left running (never `down -v`).

**In-game check:** This change is shell scripts and docs only — no C++, and `scripts/`, `tests/` and `docs/` are all in `.dockerignore` — so it needs **no fresh build**. All four subcommands drive `rndbot`, which already exists in the rollback-anchor image, so the existing image is enough. Bring the full stack up (`docker compose --env-file <main-checkout>/.env up -d`, wait for `tcm-db` healthy and for `ai_playerbot_random_bots` in `docker logs tcm-mangosd`), then run everything below from WSL inside the branch checkout.

SCRIPTABLE (a later batch step can automate these end to end; each is an exact string to match):

1. `./scripts/tournament/roster.sh status stormwind-sentinels` → 10 lines then `ROSTER stormwind-sentinels present=10/10 online=0/10 broken=0`, exit 0. Same for `orgrimmar-warsong` with the `Wsgh*` names. `broken=0` is the important field: anything above 0 means a name was rejected at character load and that row can never come online.
2. `./scripts/tournament/roster.sh login stormwind-sentinels` → blocks, then prints a status ending `online=10/10` and exits 0 within 180 s. A `FATAL: ... did not reach online=10/10` is the failure signal.
3. `./scripts/tournament/roster.sh logout stormwind-sentinels` → prints removes sent, a status, and the `characters.online lags by up to 60s` note. **Wait 60 s** (`PlayerSave.Interval`), then `./scripts/tournament/roster.sh status stormwind-sentinels` → must read `present=10/10 online=0/10`. The `present=10/10` half is the real assertion: `logout` must not have deleted anything, so the team still exists for the next round.
4. Repeat step 2. Getting back to `online=10/10` with the same ten names is the between-rounds swap working.
5. Idempotence: with the roster intact, `./scripts/tournament/roster.sh ensure stormwind-sentinels` → prints `already complete` and exits 0. Confirm it did not touch the console: `docker logs tcm-mangosd --since 1m` shows no new `rndbot create` activity.
6. Restart behaviour the doc claims: `docker restart tcm-mangosd`, wait for `ai_playerbot_random_bots` in the log, then `status` → `present=10/10 online=0/10`. The roster genuinely does not come back on its own; if it reads `online=10/10` the doc is wrong and needs correcting.
7. The console-EOF hazard, checked after every step above: `docker ps --filter name=tcm-mangosd` still shows it `Up`, and `docker logs tcm-mangosd --tail 50` contains no `Halting process` / shutdown line. If the world ever goes down during a `roster.sh` run, the batching is wrong and that is a hard failure regardless of what else passed.

NEEDS A HUMAN AT A CLIENT (the database says `online=1`, which is not the same as "in the world"):

8. After step 2, log in as a GM and `/who Wsgaone` — the character should be listed, level 60, Alliance. Then `.gm on` and `.appear Wsgaone`: you should arrive next to a real level-60 human warrior standing in the world, not fall onto an empty spot. Spot-check one Horde slot too (`.appear Wsghone`).
9. After step 3, `/who Wsgaone` should return nothing — the bot is actually gone from the world, not merely flagged offline in a table.

DELIBERATELY NOT TESTED LIVE: do not manufacture a broken (`at_login != 0`) row in the live world just to watch `ensure` refuse it. That path is covered by `tests/tournament/roster.test.sh`; on a live server, confirming `broken=0` in step 1 is the right check.

**Minor findings:**

- C:/Coding/tortoise-wow/tortoise-wow/scripts/tournament/roster.sh: roster_ensure checks broken rows only before creating; its post-creation poll succeeds on present=10/10 without re-checking at_login, so a newly created broken row is reported as a successful ensure (exit 0).

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/24, build tortoise-cm:20260817-1.
