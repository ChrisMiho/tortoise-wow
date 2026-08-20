---
status: done
risk: low
area: tournament/bracket
depends-on: 013-tournament-team-definitions.md
---

# A tournament has no bracket and no state that survives a reboot

**Problem:** There is nothing that says which teams play whom, and nothing that
remembers what already happened. Two properties make this harder than a generic
bracket. First, **every match must be Alliance vs Horde**: `SetBGTeam` controls
scoring and spawn side but not hostility (`Unit::IsHostileTo` resolves through
faction templates, `Unit.cpp:5189`), so a same-faction match is twenty bots
refusing to fight. Second, **a tournament run is hours long and interruptible** —
a crash, a power cut or an operator stopping it — so a run that only persists its
result at the end loses the whole night instead of one match.

**Suspected cause / area:** Implements
`docs/superpowers/plans/2026-08-16-04-bracket-engine.md` Tasks 1, 2 and Task 5
Steps 1-2.

**Acceptance criteria:**

- `config/tournament/teams/ironforge-anvils.json` (Alliance, `namePrefix`
  `Wsgb`) and `config/tournament/teams/thunderbluff-braves.json` (Horde,
  `namePrefix` `Wsgi`) exist, each 10 slots, every race playable by its declared
  faction, every generated name alphabetic and ≤ 12 characters.
- `./scripts/tournament/team-validate.sh` exits 0 and prints four `ok` lines.
- `config/tournament/brackets/wsg-open.json` defines two mirrored ladders of two
  teams each (`allianceLadder`, `hordeLadder`), `bgTypeId` 2, `level` 60.
- `scripts/tournament/lib/bracket.sh` provides `bracket_file`, `bracket_field`,
  `bracket_ladder <id> <A|H>`, `bracket_rounds` (log2 of ladder size) and
  `bracket_pairings <id> "<alliance survivors>" "<horde survivors>"`, which pairs
  the *n*th alliance survivor with the *n*th horde survivor — cross-faction by
  construction rather than by luck — and exits 1 on unequal or empty lists.
- `bracket_validate` rejects, naming the fault: an `.id` that disagrees with the
  filename; ladders of different lengths; a ladder size that is not a power of two
  (message must contain `power of two`); and, **only when `team_validate` is
  available in the shell**, a ladder entry that does not exist or sits on the
  wrong faction.
- `scripts/tournament/lib/state.sh` provides `state_init` (idempotent — re-running
  on an existing run resumes rather than resets), `state_get`, `state_set`,
  `state_survivors <dir> <A|H>`, `state_record_result`, `state_advance_round` and
  `state_finish`.
- **Every write is atomic**: write to a temp file, then rename. A partial write is
  a corrupt run that cannot be resumed, which defeats the point of persisting.
- `state_record_result <run-dir> <round> <allianceTeam> <hordeTeam> <winner>
  [<decidedBy>]` eliminates the loser and records `decidedBy` on the result,
  defaulting to `server`. The recorded `round` is a JSON number, not a string
  (shell interpolation through `jq` program text yields a string unless
  converted, and a string round breaks every later numeric comparison).
- **`decidedBy` is what keeps the record honest.** A tournament that tiebreaks
  0-0 draws produces winners the battleground never declared, and the state file
  must never blur the two. `server` means the battleground returned that winner;
  anything else (`tiebreak_score`, `tiebreak_deaths`, `tiebreak_seed`) means the
  driver chose it. Both eliminate a team; only one is a result.
- A `NONE` winner with no `decidedBy` still eliminates nobody, so the deadlock
  path stays intact for any caller that does not tiebreak.
- `state_get`/`jq` can filter on it — e.g. counting results where
  `decidedBy != "server"` — so a run's report can say how many matches were
  decided rather than won.
- `bash tests/tournament/bracket.test.sh` prints `9 passed, 0 failed` and exits 0.
- `bash tests/tournament/state.test.sh` prints `10 passed, 0 failed` and exits 0.
- With both `lib/team.sh` and `lib/bracket.sh` sourced, `bracket_validate
  wsg-open` exits 0 — the full team-existence and faction path, which
  `bracket.test.sh` deliberately skips.

**Notes:**

- **Run tests from WSL** —
  `wsl -d Ubuntu -- bash -lc 'cd /mnt/c/<worktree path> && bash tests/tournament/bracket.test.sh'`
  and likewise for `state.test.sh`. `jq` is absent from Git Bash on this host and
  `require_cmd jq` hard-exits 1.
- `bracket.test.sh` does **not** source `lib/team.sh`, so its
  `bracket_validate wsg-open` case passes with the team-existence check skipped.
  That guard is deliberate — keep it, and cover the full path with the separate
  criterion above rather than by changing the test.
- The two extra teams are created here rather than in the runner artifact because
  `wsg-open.json` references them and `bracket_validate` would otherwise report
  them missing, which is correct but leaves the shipped bracket permanently
  invalid.
- `Wsgb`/`Wsgi` are chosen so every joined name stays alphabetic and short
  (`Wsgbthree` is 9, `Wsgieight` is 9). Avoid a prefix ending in a vowel that
  would read as a different word when joined to `one`.
- Nothing here touches the server or the database. **No characters are created by
  this artifact** — `roster.sh ensure` does that later, against a live server.

**Base:** cm-main

**Branch:** backlog/bracket-and-run-state-libraries

**Summary:** Adds the two data structures a tournament was missing: a bracket that says who plays whom, and run state that survives a reboot. `config/tournament/brackets/wsg-open.json` defines two mirrored two-team ladders (`allianceLadder`, `hordeLadder`) with `bgTypeId` 2 and `level` 60; `scripts/tournament/lib/bracket.sh` loads it and provides `bracket_file`, `bracket_field`, `bracket_ladder`, `bracket_rounds` (log2 of ladder size) and `bracket_pairings`, which pairs the nth alliance survivor with the nth horde survivor so every match is Alliance vs Horde by construction rather than by luck, and refuses (exit 1) on unequal or empty survivor lists instead of improvising a bye or a same-faction match. `bracket_validate` reports every fault it finds, naming each: an `.id` that disagrees with the filename, unequal ladder lengths, a ladder size that is not a power of two, and — only when `team_validate` is in scope, so `bracket.sh` stays usable alone — a ladder entry that does not exist or sits on the wrong faction. `scripts/tournament/lib/state.sh` provides `state_init` (idempotent, so re-running on an existing run directory resumes rather than resets), `state_get`, `state_set`, `state_survivors`, `state_record_result`, `state_advance_round` and `state_finish`; every write goes to `state.json.tmp` and is renamed over the real file, and the temp file is removed rather than stranded when `jq` fails, so an interruption leaves either the old state or the new one and never a corrupt run. `state_record_result` records `round` as a JSON number (`$round | tonumber`, since a shell value arrives through `--arg` as a string and a string round breaks every later numeric comparison) plus a `decidedBy` field defaulting to `server`; `server` means the battleground declared that winner, anything else (`tiebreak_score`, `tiebreak_deaths`, `tiebreak_seed`) means the driver chose it, and both eliminate a team while only one is a result. A `NONE` winner eliminates nobody, so the deadlock path stays intact for callers that do not tiebreak. `config/tournament/teams/ironforge-anvils.json` (Alliance, prefix `Wsgb`) and `config/tournament/teams/thunderbluff-braves.json` (Horde, prefix `Wsgi`) are added because `wsg-open.json` references them; no characters are created and nothing here touches the server or the database. Verified from WSL: `tests/tournament/bracket.test.sh` prints `9 passed, 0 failed`, `tests/tournament/state.test.sh` prints `10 passed, 0 failed`, `scripts/tournament/team-validate.sh` exits 0 with four `ok` lines, `bracket_validate wsg-open` exits 0 with both `lib/team.sh` and `lib/bracket.sh` sourced, and the pre-existing `tests/tournament/team.test.sh` still prints `10 passed, 0 failed`.

**In-game check:** This artifact ships only JSON data and two sourced bash libraries. It adds no console command, no C++, no SQL, and creates no characters, so the server-side smoke test is just the generic one (server starts, `rndbot` bots spawn) — and per rule 5 the only image on this host predates all of this anyway.

FULLY SCRIPTABLE — no human eyes needed, all from WSL in the worktree:
1. `bash tests/tournament/bracket.test.sh` → last line `9 passed, 0 failed`, exit 0.
2. `bash tests/tournament/state.test.sh` → last line `10 passed, 0 failed`, exit 0.
3. `./scripts/tournament/team-validate.sh` → exactly four `ok` lines (ironforge-anvils A, orgrimmar-warsong H, stormwind-sentinels A, thunderbluff-braves H), exit 0.
4. `bash -c '. scripts/tournament/lib/team.sh; . scripts/tournament/lib/bracket.sh; bracket_validate wsg-open && echo BRACKET-OK'` → prints `BRACKET-OK`, exit 0. This is the full team-existence + faction path the unit test skips.
5. `bash tests/tournament/team.test.sh` → still `10 passed, 0 failed`; the two new team files must not disturb the existing roster-file equality assertion.
6. Crash-resume, without a real 20-minute match: `rm -rf /tmp/tr && mkdir -p /tmp/tr`, then in one bash: source `scripts/tournament/lib/state.sh`, `state_init /tmp/tr wsg-open "stormwind-sentinels ironforge-anvils" "orgrimmar-warsong thunderbluff-braves"`, `state_record_result /tmp/tr 1 stormwind-sentinels orgrimmar-warsong ALLIANCE`, `cat /tmp/tr/state.json`. Confirm: `.results` has one entry, `.results[0].round` prints as `1` with no quotes, `.results[0].decidedBy` is `"server"`, `.survivors.H` no longer contains `orgrimmar-warsong`, and no `/tmp/tr/state.json.tmp` exists. Then re-run the same `state_init` and confirm `.results` still has one entry — that is the resume property.
7. Tiebreak honesty: `state_record_result /tmp/tr 1 ironforge-anvils thunderbluff-braves HORDE tiebreak_deaths`, then `jq '[.results[]|select(.decidedBy!="server")]|length' /tmp/tr/state.json` → `1`. A run report can therefore distinguish matches won on the field from matches the driver decided.

REQUIRES A LIVE SERVER, and belongs to the next artifact (the runner) rather than this one — but it is the check that proves this data is actually playable, so record it:
8. `./scripts/tournament/roster.sh ensure ironforge-anvils --login` and the same for `thunderbluff-braves`. Watch for the failure mode the name rules exist to prevent: the console prints "Bot is now online" and the character then never appears, leaving a `characters` row with `at_login=1`. It must not happen — `Wsgbthree` and `Wsgieight` are 9 characters and alphabetic. Scriptable check: `SELECT name, race, class, at_login FROM tw_characters.characters WHERE name LIKE 'Wsgb%' OR name LIKE 'Wsgi%';` must return 20 rows, all with `at_login=0`.
9. Log in as a GM, `.go` to one of the Wsgb bots, and confirm with `.pinfo Wsgbone` that it is a Dwarf Warrior on Alliance and `.pinfo Wsgione` that it is a Tauren Warrior on Horde. Then, in the same place, confirm a Wsgb bot and a Wsgi bot will actually attack each other (red nameplate, `/target` shows hostile) — that is the in-game observation the two-ladder structure exists to guarantee, and the one thing `SetBGTeam` cannot deliver.

**Minor findings:**
- scripts/tournament/lib/state.sh: `state_record_result` treats any winner token other than the exact strings `ALLIANCE`/`HORDE` as the eliminate-nobody branch, so a mis-cased or unexpected token (`Alliance`, `A`, `alliance`) is silently recorded as a result that deadlocks the bracket, indistinguishable from a genuine `NONE` draw — rejecting unknown tokens would keep the record as honest as `decidedBy` is meant to.
- scripts/tournament/lib/state.sh: `state_record_result` appends to `.results` unconditionally, so a resumed run that replays a match already present double-records it (and inflates the `decidedBy != "server"` count the artifact wants for reporting), which undercuts the resume property `state_init` exists to provide.
- scripts/tournament/lib/bracket.sh: `bracket_rounds` swallows a failed bracket load — `bracket_ladder ... | grep -c . || true` yields `0` for a nonexistent or unreadable bracket, so the function prints `0` and exits 0 instead of failing, and a caller looping over rounds silently runs none (verified: `bracket_rounds nosuch` prints `0`, RC=0).

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/31, build tortoise-cm:20260817-2.
