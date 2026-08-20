---
status: done
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

**Base:** cm-main

**Branch:** backlog/tournament-command-scaffolding

**Summary:** Added the console-callable `.tournament` command family scaffolding (Tasks 1-2 of the control-plane plan) in one commit, e941d7d on `backlog/tournament-command-scaffolding`, cut from `origin/cm-main` (927859f). New file `src/game/Commands/TournamentCommands.cpp` holds `ChatHandler::TournamentEmit` (which both `PSendSysMessage`s the record and mirrors it to `sLog.out(LOG_BG, ...)`, each prefixed `TOURNAMENT `), a static `TournamentStatusName` helper, `HandleTournamentStatusCommand` (walks every `BattleGroundTypeId` from `BATTLEGROUND_AV`, skips instance id 0 as the template, emits `instance= type= map= status= alliance= horde= elapsed=` per live instance then `status count=<n>`) and `HandleTournamentCreateCommand` (emits `create instance= type= map= bracket=`, or `create error=` with four distinct reasons — `usage(...)`, `bad_type_id`, `no_template`, `create_failed` — and never attempts a template reload). Every record goes through `TournamentEmit`; no handler writes a `TOURNAMENT ` line by any other route. `src/game/CMakeLists.txt` gained `Commands/TournamentCommands.cpp` immediately after `Commands/Commands.cpp` (that list is explicit, not a glob); `src/game/Chat/Chat.h` declares all three members directly beside `HandleBGStatusCommand`; `src/game/Chat/Chat.cpp` defines `tournamentCommandTable` with `status` and `create` and registers a `tournament` parent entry right after `bg`, with `AllowConsole = true` on the parent and on both subcommands. The file uses only core APIs (Chat/Log/BattleGround/BattleGroundMgr) so it needs no `PlayerbotStubs.cpp` entry and compiles with `BUILD_PLAYERBOTS=OFF` — `game_SRCS` is not gated on that option. Two things I found in the tree that the plan's snippets did not account for, both handled: (1) `CreateNewBattleGround` builds the instance and its map but never registers it with the manager — on the queue path that is `StartBattleGround`'s job (BattleGround.cpp:1069) — so without an explicit `sBattleGroundMgr.AddBattleGround(...)` the emitted instance id would be invisible to `status` (which walks `m_BattleGrounds`) and unreachable via `GetBattleGround`; `create` now registers it, and `~BattleGround` already calls `RemoveBattleGround` so no teardown was needed. (2) `BattleGround::Update` deletes any instance with no players and no invited count on the very next map tick (BattleGround.cpp:290-303), so an empty instance created by `create` is reaped almost immediately — holding one open is a core lifecycle change this scaffolding deliberately does not make, and it is recorded in the source comment and the commit body for whoever writes `tournament add`. No SQL migration was required. Per the artifact's own instruction I ran no Docker build; the batch pass is the compile gate. Two notes for the reviewer: the artifact says to declare the handlers "in the same public block as `HandleBGStatusCommand`" — that block is in fact `protected:` (Chat.h:161), which is fine since `getCommandTable()` is a `ChatHandler` member and every existing `bg` handler sits there too, so I kept the declarations adjacent to `HandleBGStatusCommand` rather than relocating them; and the artifact's `Chat.cpp:862` / `Commands.cpp:14212-14257` line references are slightly off in this tree (the `bg` parent entry is Chat.cpp:862 pre-change and the subcommand table is 741-748; `HandleBGStatusCommand` starts at Commands.cpp:14118), but the substance — `AllowConsole = false` plus an `m_session->GetPlayer()` + `ASSERT` opening — is exactly as described.

**In-game check:** Almost all of this is scriptable from the console and bg.log; only steps 7-8 need a human at a client. Run everything through `wsg_console` (from `docs/playerbots/wsg/lib/wsg-bots-common.sh`), never a bare `docker attach`, and batch commands into as few attaches as possible.

SCRIPTABLE — no human needed:

1. Server boots. `docker inspect --format '{{.State.Health.Status}}' tcm-cm` reads healthy and the mangosd log reaches its normal "World initialized" banner. This change cannot break boot, but a static-table typo would show up as the world never coming up.

2. The command exists at all. `wsg_console "tournament status" 8` returns at least `TOURNAMENT status count=0`. THIS IS THE LOAD-BEARING CHECK: `There is no such subcommand`, `Incorrect syntax`, or `There is no such command` means the `Commands/TournamentCommands.cpp` line in `src/game/CMakeLists.txt` or the `tournament` entry in the main command table did not land. Empty output (no `TOURNAMENT` line at all) means the same thing.

3. Console-callability specifically. Step 2 succeeding through `wsg_console` — i.e. with no `WorldSession` and no GM standing anywhere — is itself the proof that `AllowConsole = true` took effect. For contrast, `wsg_console "bg status" 8` should still produce nothing usable; that is the unchanged pre-existing behaviour this artifact exists to route around, not a regression.

4. Create returns an instance. `wsg_console "tournament create 2 60" 10` returns exactly one line matching `TOURNAMENT create instance=<n> type=2 map=489 bracket=<n>`, with `<n>` a non-zero instance id. `map=489` confirms the WSG template was found; a `map=0` or `instance=0` would mean `sMapMgr.CreateBgMap` did not attach a map and is a real failure.

5. The bg.log mirror. `tail -20 ~/tortoise-wow-server-V2/logs/bg.log` contains the same `TOURNAMENT create instance=<n> type=2 map=489 bracket=<n>` line, and a `TOURNAMENT status count=` line from step 2. If the console line appeared but the log line did not, `TournamentEmit` is only doing half its job.

6. Error paths, each a distinct reason. In one attach: `tournament create` alone returns `TOURNAMENT create error=usage(.tournament create <bgTypeId> <level>)`; `tournament create 2` (level missing) returns the same usage line; `tournament create 0 60` returns `TOURNAMENT create error=bad_type_id`; `tournament create 9 60` returns `TOURNAMENT create error=bad_type_id`. For `no_template`, first find a type id in 1..5 with no row: `wsg_mysql "SELECT id FROM tw_world.battleground_template ORDER BY id;"` — any id in 1..5 absent from that result, passed as `tournament create <thatId> 60`, must return `TOURNAMENT create error=no_template`. If all five have rows, record that `no_template` is unreachable on this world rather than reporting it as a failure. Every one of these four must be a different string.

EXPECTED, AND NOT A FAILURE — read this before diagnosing step 7:

7. Running `tournament status` right after step 4 will most likely report `status count=0` and NOT show the instance just created. That is correct behaviour for this change, not a broken registration. `BattleGround::Update` (BattleGround.cpp:290-303) deletes any instance holding no players and no invited count on the very next map tick, so an empty instance created from the console is reaped within a fraction of a second. The proof that `create` worked is the `TOURNAMENT create instance=<n>` line itself, plus its bg.log mirror. Holding an empty instance open is a core lifecycle change deliberately left to whoever implements `tournament add`.

8. To actually confirm `status` reports a live instance, drive a real match through the proven path instead: use `wsg_bgjoin_lines` to set each bot's `bg type` to `2` and issue `bg join` for at least two bots per side, wait for the queue pop, then `wsg_console "tournament status" 8`. It must emit one line reading `instance=<n> type=2 map=489 status=<WaitJoin|InProgress> alliance=<a> horde=<h> elapsed=<s>` followed by `status count=1`, with `<a>` and `<h>` matching the number of bots actually inside and `elapsed` increasing between two calls a few seconds apart. It must NOT emit a line with `instance=0` — that would mean the template is being reported as a live battleground.

NEEDS A HUMAN AT A CLIENT:

9. Log in a GM account (SEC_ADMINISTRATOR) and type `.tournament status` in chat while the step-8 match is running. It should print the same `TOURNAMENT ...` lines into the chat frame that the console printed. This confirms the command is reachable from both paths, not console-only.

10. With that same GM, walk into the running Warsong Gulch instance and run `.bg status`, `.bg start`, `.bg stop`. They must behave exactly as they did before this branch — this change adds a table and a file and touches no existing handler, so any difference here is a regression worth stopping for. Also compare the `alliance=`/`horde=` counts from step 8 against the WSG scoreboard the GM can see; they should agree.

**Minor findings:**

- src/game/Commands/TournamentCommands.cpp: `tournament create` registers the new instance but, as the code comment itself notes, `BattleGround::Update` does `delete this` on the very next map tick for an instance with no players and no invited count, so the artifact's documented live-stack verification (`tournament status` afterwards showing that instance with `alliance=0 horde=0`) will report `status count=0` instead.
- src/game/Commands/TournamentCommands.cpp: `sBattleGroundMgr.AddBattleGround(bg->GetInstanceID(), ...)` is called without checking the instance id is non-zero, so if map creation ever left the instance id at 0 the call would overwrite the key-0 entry that `GetBattleGroundTemplate` returns (it is just `begin()->second`), silently replacing the template for that battleground type.
- src/game/Commands/TournamentCommands.cpp: HandleTournamentStatusCommand iterates the mutex-guarded m_BattleGrounds via the raw GetBattleGroundsBegin/End accessors without holding BattleGroundMgr::m_BattleGroundsMutex (writers RemoveBattleGround/AddBattleGround do hold it, and ~BattleGround runs on map-update threads), so it is safe only by the unstated invariant that console/chat commands execute on the world thread after the map thread pools have joined; the locked ApplyAllBattleGrounds accessor already exists for this.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/25, build tortoise-cm:20260817-1.
