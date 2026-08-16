---
status: pending
risk: medium
area: game/commands
depends-on:
---

# No script can create or observe a battleground instance

**Problem:** `.bg status` / `.bg start` / `.bg stop` are registered
`AllowConsole = false` (`Chat.cpp:862`) and require a GM standing inside the
instance (`Commands.cpp:14212-14257`), so nothing external can drive a
battleground. The only way an instance comes into existence today is a queue pop,
which means a runner cannot pair two named teams deterministically — it can only
hope the queue does it.

**Suspected cause / area:** There is no console-callable battleground control.
Implements `docs/superpowers/plans/2026-08-16-02-tournament-control-plane.md`
Tasks 1-2.

**Acceptance criteria:**

- `src/game/Commands/TournamentCommands.cpp` exists and holds
  `ChatHandler::TournamentEmit`, `HandleTournamentStatusCommand` and
  `HandleTournamentCreateCommand`. It is in **core**, not the PlayerBots module —
  it must use only core APIs so it needs no `PlayerbotStubs.cpp` entry and keeps
  working with `BUILD_PLAYERBOTS=OFF`.
- `src/game/CMakeLists.txt` lists `Commands/TournamentCommands.cpp` immediately
  after the `Commands/Commands.cpp` line. **That list is explicit, not a glob** —
  without this line the file compiles into nothing and the command silently does
  not exist.
- `src/game/Chat/Chat.h` declares `TournamentEmit` and both handlers in the same
  public block as `HandleBGStatusCommand`, with signatures that match the
  definitions exactly.
- `src/game/Chat/Chat.cpp` defines `tournamentCommandTable` with `status` and
  `create`, and registers a `tournament` entry in the main command table.
  **`AllowConsole` is `true` on the parent entry and on every subcommand** — `.bg`
  has it false and that is precisely why no script can drive a battleground.
- `TournamentEmit` both `PSendSysMessage`s the line and mirrors it to
  `sLog.out(LOG_BG, ...)`, each prefixed `TOURNAMENT `. A console session can be
  detached mid-command; `bg.log` cannot.
- Every record a handler emits goes through `TournamentEmit` — no handler writes
  a `TOURNAMENT ` line by any other route.
- `status` skips instance id `0` (that is the template, not a live battleground),
  emits one `instance=… type=… map=… status=<WaitJoin|InProgress|WaitLeave>
  alliance=… horde=… elapsed=…` line per live instance, then
  `status count=<n>`.
- `create <bgTypeId> <level>` emits
  `create instance=… type=… map=… bracket=…` on success, or
  `create error=<reason>` with distinct reasons for a bad usage string, an
  out-of-range type id, a missing template, and a failed create. It must not
  attempt to reload a battleground template — those are read once at boot
  (`World.cpp:2274`).

**Notes:**

- **Do not attempt a Docker build in this worktree.** There is no incremental
  build here: `COPY . /src` never cache-hits, so every build recompiles all ~1169
  translation units and takes ~9.5 minutes regardless of what changed. The
  `backlog-batch` pass compiles this branch together with the rest of its batch —
  that is the compile gate, and it is the only one. The criteria above are
  deliberately structural for that reason.
- WSG is `BATTLEGROUND_WS = 2` (`SharedDefines.h:1746`), map 489.
- Emitted lines are the API. Format is `TOURNAMENT ` followed by space-separated
  `key=value` pairs. `scripts/tournament/lib/ctl.sh` parses exactly that and
  nothing else, so the format must not drift.
- **Verification needing a live stack (not part of these criteria):** after the
  batch build, `wsg_console "tournament status" 8` returns at least
  `TOURNAMENT status count=0`; `tournament create 2 60` returns an instance id and
  `tournament status` then shows that instance with `alliance=0 horde=0`; the same
  `create` line appears in `~/tortoise-wow-server-V2/logs/bg.log`. **`There is no
  such subcommand` or `Incorrect syntax` means the table registration or the CMake
  line did not land** — that is the failure mode this artifact exists to prevent.
- Never send a bare `docker attach`; use `wsg_console`, which detaches with
  `ctrl-p,ctrl-q`. Console EOF shuts the world down.
