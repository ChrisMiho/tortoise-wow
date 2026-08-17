---
status: pending
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
refusing to fight. Second, **this host reboots itself overnight for Windows
Update**, so a run that only persists its result at the end loses the whole night.

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
