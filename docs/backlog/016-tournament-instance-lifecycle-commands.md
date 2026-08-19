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
