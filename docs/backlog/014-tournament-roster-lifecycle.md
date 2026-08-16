---
status: pending
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
- **Verification needing a live stack (not part of these criteria):**
  `roster.sh status stormwind-sentinels` reporting `present=10/10 broken=0`
  against the real world, and a `logout` → `status` (`online=0/10`) → `login`
  (`online=10/10`) cycle. Allow up to 60 s of stale `online` readings. Record the
  real `broken=` count — anything above zero is a genuine finding about the
  current world, not a test failure.
