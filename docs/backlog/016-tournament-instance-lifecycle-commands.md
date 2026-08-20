---
status: done
risk: high
area: game/commands
depends-on: 015-tournament-command-scaffolding.md
---

# An instance can be created but not populated, started, stopped or scored

**Problem:** `tournament create` produces an empty battleground and `tournament
status` observes it, but nothing can put players in it, start it, stop it, or read
its result. A match result today is a scraped `bg.log` line whose `duration` field
includes up to 120 s of post-match cleanup, so it is not the match length.

The population half carries a real unknown. `HandleBattlefieldPortOpcode` is the
only path that puts a player into a battleground today, and it ends
(`BattleGroundHandler.cpp:526-533`) by calling `SetBattleGroundId`, `SetBGTeam`
and `SendToBattleGround` — with `BattleGround::AddPlayer` **deferred until the
client acknowledges the world port**. A playerbot has a `WorldSession` but no
client. Whether a bot ever acks a world port, and so whether it is ever actually
added to the battleground, is **not knowable from the source**. `members` exists
to answer that: `add` reports what was *sent*, `members` reports what the
battleground *holds*.

**Suspected cause / area:** Implements
`docs/superpowers/plans/2026-08-16-02-tournament-control-plane.md` Tasks 3-5, in
`src/game/Commands/TournamentCommands.cpp` plus the `Chat.h` / `Chat.cpp`
declarations and registrations.

**Acceptance criteria:**

- A single file-static helper `TournamentFindInstance(uint32 instanceId)` sweeps
  battleground types and returns the matching `BattleGround*` or `nullptr`, and
  **every** handler that resolves an instance uses it — no duplicated lookup loops
  survive anywhere in the file.
- `add <instanceId> <playerName>` mirrors `HandleBattlefieldPortOpcode` minus the
  queue bookkeeping (`SetBattleGroundId`, `SetBGTeam`, `SendToBattleGround`) and
  emits `add instance=… player=… team=<ALLIANCE|HORDE> sent=1`, or
  `add error=<reason>` for: bad usage, missing player name, player not online,
  no such instance, and player already in a battleground.
- **`add` always uses the player's own `GetTeam()`.** Cross-faction only, by
  design: `SetBGTeam` controls scoring and spawn side but **not** hostility —
  `Unit::IsHostileTo` resolves through faction templates (`Unit.cpp:5189`) and
  never consults `GetBGTeam()`, so a player placed on the opposing side would
  spawn and score correctly and then refuse to fight. There must be no argument
  or code path that overrides the side.
- `members <instanceId>` emits one `member instance=… player=… team=… map=…` line
  per entry in `bg->GetPlayers()`, then `members instance=… count=<n>`.
- `start <instanceId>` collapses the countdown (`SetStartDelayTime(0)`) — the
  countdown *is* the start — and emits `start instance=… ok=1`.
- `stop <instanceId>` calls `StopBattleGround()` and emits `stop instance=… ok=1`.
- `result <instanceId>` emits
  `result instance=… winner=<HORDE|ALLIANCE|NONE> allianceScore=… hordeScore=…
  status=… elapsed=…`. Winner comes from `BattleGround::GetWinner()`
  (`BattleGround.h:323`, on the base class). **Scores come from a downcast**:
  `GetTeamScore` is declared on `BattleGroundWS` (`BattleGroundWS.h:185`), not on
  the base, so `bg->GetTeamScore(ALLIANCE)` through a `BattleGround*` does not
  compile. Guard on `GetTypeID() == BATTLEGROUND_WS`, `static_cast` to
  `BattleGroundWS*`, include `BattleGroundWS.h`, and emit `-1` for any other
  battleground type so "not exposed here" stays distinguishable from a real 0-0.
- **Do not add a base-class virtual `GetTeamScore` as a side effect.**
  `BattleGroundBR` declares its own identical accessor (`BattleGroundBR.h:61`), so
  this is a per-subclass convention, not an oversight.
- `result` on a missing instance emits
  `result error=no_such_instance(finished_or_never_existed)` — a finished
  battleground is destroyed, so this is the normal way to learn a match is over,
  not an error the caller should retry.
- All four subcommands are declared in `Chat.h` and registered in
  `tournamentCommandTable` with `AllowConsole = true`.

**Notes:**

- **Amendment, made during implementation.** The `add` criterion above
  (`SetBattleGroundId`, `SetBGTeam`, `SendToBattleGround`, nothing else) is not
  sufficient, and code review caught it. Three calls had to be added, and the
  criterion should be read as including them:
  - `bg->IncreaseInvitedCount(team)` — the instance's lifetime. A registered
    instance with no players and nobody invited is `delete this`'d by
    `BattleGround::Update`, so without it the instance dies while the player is
    still in flight. It is also half of a pair: `RemovePlayerAtLeave` calls
    `DecreaseInvitedCount` unconditionally on a `uint32`, so an unpaired leave
    wrapped the counter to ~4.29e9 and leaked the instance and its map forever.
  - `player->SetInviteForBattleGroundQueueType(...)`, behind a claimed
    `AddBattleGroundQueueId` slot — `HandleMoveWorldPortAckOpcode` only calls
    `bg->AddPlayer` when `IsInvitedForBattleGroundInstance` holds
    (`MovementHandler.cpp:208`), so without it `members` could never report the
    player no matter what bots do about world ports.
  - `bg->SetEmptyHoldTime(...)` in `create`, plus the grace window it needs in
    `BattleGround::Update` — the same empty-instance delete meant the id `create`
    printed was already dangling by the time `add` could be typed, so the live
    verification below could never have passed. The window is a countdown, zero on
    every queue-built instance, so the queue path is unchanged.

  Consequent new `add` error reasons: `player_in_bg_queue`, `player_teleporting`,
  `teleport_failed`, `no_free_queue_slot`. All documented in
  `docs/playerbots/TOURNAMENT-CONTROL-PLANE.md`.
- **Do not attempt a Docker build here** (~9.5 min, no incremental build). The
  `backlog-batch` pass compiles this branch; the criteria above are structural on
  purpose.
- Winner encoding is `WINNER_HORDE=0`, `WINNER_ALLIANCE=1`, `WINNER_NONE=2`
  (`BattleGround.h:187-189`).
- **The world-port acknowledgement question is deliberately left open here.** It
  can only be settled against a running server with bots logged in, which this
  phase cannot do. Do not guess an answer, do not write the Task 3 Step 6 fallback
  (`tournament queue`) speculatively, and do not delete `add`. Artifact
  `018-tournament-shell-client.md` ships
  `docs/playerbots/TOURNAMENT-CONTROL-PLANE.md` with an explicitly UNMEASURED
  section and the procedure for settling it, and
  `024-tournament-match-run.md` implements **both** assembly modes behind one
  switch so the runner works either way.
- Risk is `high` because these handlers dereference `Player*` obtained from
  `ObjectAccessor` on a server running ~1000 concurrent playerbots. Check every
  lookup for null before use; `FindPlayerByName` and `FindPlayer` can both return
  `nullptr`, and a player recorded in `GetPlayers()` may not be resolvable.
- **Verification needing a live stack (not part of these criteria):** with a bot
  online, `tournament create 2 60` → `tournament add <inst> Wsgaone` → wait ~20 s
  → `tournament members <inst>`, and read `map` for that bot out of
  `tw_char.characters`. `members count=1` with `map=489` means bots ack world
  ports; `sent=1` with `count=0` and the old map means they do not. Record the
  literal console output and the DB row, not a summary. Then
  `status`→`start`→`status`→`stop` must move the status `WaitJoin` →
  `InProgress` → `WaitLeave` (or the instance vanishes, which is equally correct
  for `stop`), and `result` on a fresh instance must read `winner=NONE
  allianceScore=0 hordeScore=0 status=WaitJoin`.

**Base:** cm-main

**Branch:** backlog/tournament-instance-lifecycle-commands

**Summary:** Added the five remaining `.tournament` subcommands to `src/game/Commands/TournamentCommands.cpp` (+ declarations in `src/game/Chat/Chat.h`, registrations in `tournamentCommandTable` in `src/game/Chat/Chat.cpp`, all `AllowConsole = true`), so a script can populate, start, stop and score a battleground instance it created. One file-static `TournamentFindInstance(uint32 instanceId)` sweeps battleground types and is the only place an id becomes a `BattleGround*` — every handler taking an `<instanceId>` uses it, and it rejects id 0 because the manager registers the mapless template under 0. `add <instanceId> <playerName>` mirrors `HandleBattlefieldPortOpcode` (`BattleGroundHandler.cpp:524-531`) minus the queue bookkeeping — `SetBattleGroundId`, `SetBGTeam`, `SendToBattleGround` — always with the player's own `GetTeam()` and no override path, and emits `sent=1` rather than `ok=1` because `bg->AddPlayer` is deferred to `HandleMoveWorldPortAck`; the world-port acknowledgement question is left open exactly as the artifact requires, with no speculative `tournament queue` fallback. `members` walks `bg->GetPlayers()` and emits one `member …` line per entry (raw `PlayerTeam`, `map=-1` when the guid no longer resolves to a `Player`) then `members instance=… count=<n>`. `start` collapses the countdown with `SetStartDelayTime(0)`, `stop` calls `StopBattleGround()`, and `result` reads `GetWinner()` off the base class but the scores off a `static_cast<BattleGroundWS const*>` guarded on `GetTypeID() == BATTLEGROUND_WS` (emitting `-1/-1` for any other type, and adding no base-class virtual), answering `result error=no_such_instance(finished_or_never_existed)` when the instance is gone. Every `Player*` from `ObjectAccessor` is null-checked before use. No SQL migration, no build run here (the batch pass compiles it). Beyond the artifact's scope, and not planned in it: base-class `BattleGround` gains a `uint32 m_EmptyHoldTimer` member plus a non-virtual `SetEmptyHoldTime(uint32 ms)` setter (`src/game/Battlegrounds/BattleGround.h`), zero-initialised in the constructor, and `BattleGround::Update`'s empty-instance reap (`src/game/Battlegrounds/BattleGround.cpp`) now counts that grace window down instead of deleting unconditionally, deleting only once it expires. This exists because `tournament create` registers an instance a full console round-trip before `tournament add` can invite anyone into it, so the unconditional `delete this` destroyed it on the next map tick and the instance id `create` had just printed was already dangling; `create` sets the window to `INVITE_ACCEPT_WAIT_TIME` (the core's own limit on how long an invite may sit unredeemed) and `add` clears it back to 0 once a player is actually sent, so normal reaping resumes. Every queue-built instance leaves the timer at 0, where the new code is behaviourally identical to the `delete this` it replaces, and no new base-class virtual is added. Reviewer note: this deliberately changes shared battleground code that every instance type runs, and the artifact's own in-game check step 4 treats that reap as expected 015 lifecycle behaviour rather than a defect to fix, so it needs agreement rather than only a green build. `docs/playerbots/TOURNAMENT-CONTROL-PLANE.md` is also updated (+29 lines) to document the new subcommands.

**In-game check:** This needs more than the generic smoke test, and it needs the batch-built image: none of these five subcommands exist in the rollback anchor `tortoise-cm:c06b2fb`, so `There is no such subcommand` against the currently running world proves nothing.

SCRIPTABLE — no human eyes needed. Use `wsg_console` from `docs/playerbots/wsg/lib/wsg-bots-common.sh` (never a bare `docker attach`) and batch commands into as few attaches as possible; `scripts/tournament/lib/ctl.sh` already parses the output (`ctl`, `ctl_field`, `ctl_create`).

1. Registration did not break: `tournament status` answers `TOURNAMENT status count=0` (or a real count). `Incorrect syntax`/`no such subcommand` for any of `add|members|start|stop|result` means the `Chat.cpp` table or the `Chat.h` declarations did not land.
2. Argument errors, one attach: `tournament add` alone → `TOURNAMENT add error=usage` plus an unprefixed `Syntax: .tournament add <instanceId> <playerName>` line; `tournament add 999999 Wsgaone` → `add error=no_such_instance`; `tournament add 999999 Notarealname` → `add error=player_not_online(Notarealname)`; `tournament members 999999` → `members error=no_such_instance`; `tournament start 999999` / `tournament stop 999999` → `error=no_such_instance`.
3. The template guard: `tournament result 0` and `tournament members 0` must answer `no_such_instance…`, never a line describing map 489 with `count=0`. A `TOURNAMENT result instance=0 …` line means the instance-0 rejection in `TournamentFindInstance` is gone and the mapless template is being handed to callers.
4. Fresh-instance result, in ONE attach so the instance is not reaped between round-trips: `tournament create 2 60` then `tournament result <inst>` must read `winner=NONE allianceScore=0 hordeScore=0 status=WaitJoin`. `error=no_such_instance(finished_or_never_existed)` here is the known 015 lifecycle behaviour — `BattleGround::Update` deletes an empty instance with no invited count on the next map tick (`BattleGround.cpp:290-303`) — not a defect in these handlers; retry with both commands in the same attach before concluding anything.
5. Log mirroring: `tail -40 ~/tortoise-wow-server-V2/logs/bg.log | grep TOURNAMENT` shows exactly one line per record emitted above, matching the console text.
6. No crash: after every step, `docker inspect --format '{{.State.Health.Status}}' tcm-cm` (or whichever the mangosd container is) still reads healthy, `Server.log` has no new `ASSERT`/backtrace, and the container's restart count has not moved. `stop` can delete the instance, and `result` on a bot that logged out mid-match is the null-deref path the artifact flags as `risk: high`.

NEEDS A HUMAN / BOTS ONLINE — the world-port question, which is the only thing here that cannot be settled from source.

7. Bring at least one bot online (`scripts/tournament/roster.sh login stormwind-sentinels`, or `docs/playerbots/wsg/wsg-roster.sh ensure`) and confirm `SELECT name, map, online FROM tw_char.characters WHERE name='Wsgaone';` reads `online=1` first — through a bare `docker exec … mysql`, not `wsg_mysql`, since that helper hides stderr.
8. In one attach: `tournament create 2 60` → `tournament add <inst> Wsgaone`. Expect `TOURNAMENT add instance=<inst> player=Wsgaone team=ALLIANCE sent=1`. Wait ~20 s (a world port is not instant, and `characters.map` is only rewritten on save), then `tournament members <inst>` and re-read that DB row. Record the literal console lines and the literal row, not a summary. `members … count=1` with `map=489` means bots do ack world ports and direct add works; `sent=1` with `count=0` and the old map means the teleport was dropped; `count=0` with `map=489` means the bot moved but `AddPlayer` never ran. Write whichever happened into the UNMEASURED section of `docs/playerbots/TOURNAMENT-CONTROL-PLANE.md`.
9. Only if step 8 shows bots inside: log a GM character into that instance (or `.go` to Warsong Gulch on map 489) and watch with your own eyes. `tournament start <inst>` should produce the in-game battle-start — the Warsong starting-room gates open, the "Let the battle begin!" announcement fires, and bots leave the tunnels — and `tournament status` for that instance flips `WaitJoin` → `InProgress`. Let a bot cap a flag and confirm `tournament result <inst>` reports the score climbing on the correct side (Alliance caps raise `allianceScore`, not `hordeScore`) with `winner=NONE` until three caps. Then `tournament stop <inst>`: in-game the match ends and players are sent out; `tournament status` shows `status=WaitLeave` or the instance is gone entirely — both are correct for `stop`.
10. Cross-faction sanity, the one thing a human must actually look at: a bot added by `add` must be hostile to the other side. Stand a GM next to an added Horde bot and an added Alliance bot and confirm they attack each other rather than standing peacefully — that is what "always the player's own `GetTeam()`" is protecting, and no console line can show it.

**Minor findings:**
- src/game/Commands/TournamentCommands.cpp: `add` omits the non-queue parts of `HandleBattlefieldPortOpcode` — `SetBattleGroundEntryPoint()` (BattleGroundHandler.cpp:491), the resurrect-if-dead block, and the taxi-flight cleanup — so a player placed by `add` keeps a stale `m_bgData.joinPos` and on leaving the battleground is teleported to a previous bg's entry point or homebind, and a dead bot is ported in still dead.
- src/game/Commands/TournamentCommands.cpp: `tournament add` never calls `player->SetBattleGroundEntryPoint()` before the teleport, so when the battleground map is torn down (`BattleGroundMap::UnloadAll` → `TeleportAllPlayersTo(TELEPORT_LOCATION_BG_ENTRY_POINT)` → `Player::TeleportToBGEntryPoint`, src/game/Objects/Player.cpp:2898) the added player is flung to whatever stale `m_bgData.joinPos` a previous battleground left in their bgData, or to homebind, rather than back to where they were standing.
- src/game/Commands/TournamentCommands.cpp: `start` and `stop` both emit `ok=1` unconditionally, but `SetStartDelayTime(0)` is only consumed when `GetStatus() == STATUS_WAIT_JOIN && GetPlayersSize()` (src/game/Battlegrounds/BattleGround.cpp:365) and `StopBattleGround`'s premature countdown is cleared again on the next tick unless the battleground is `STATUS_IN_PROGRESS` (src/game/Battlegrounds/BattleGround.cpp:326,357), so on an empty or not-yet-started instance the mutation is silently discarded while the control plane reports success.
- src/game/Commands/TournamentCommands.cpp: `TournamentFindInstance` reads `BattleGroundMgr::m_BattleGrounds` through the unlocked `GetBattleGround` accessor while the container's writers hold `m_BattleGroundsMutex` (src/game/Battlegrounds/BattleGroundMgr.cpp:1904-1914, called from `~BattleGround` on instance-map update threads); it happens to be safe only because chat commands are `PACKET_PROCESS_WORLD` and CLI commands run in `World::ProcessCliCommands` after `MapManager::Update` has joined its thread pools, an invariant this file relies on without stating or asserting it.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/29, build tortoise-cm:20260817-2.
