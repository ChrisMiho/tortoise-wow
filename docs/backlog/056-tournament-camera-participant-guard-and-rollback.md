---
status: implemented
risk: medium
area: game/tournament
depends-on: 038-tournament-poi-and-camera-commands.md
---

# `tournament camera` can still turn a match into 11v10

**Problem:** the camera command's participant refusal tests
`bg->IsPlayerInBattleGround(plr->GetObjectGuid())`, which is the `m_Players`
lookup only. A player whom `tournament add` has already invited and sent, but who
has not yet been inserted by `HandleMoveWorldPortAckOpcode`, is not in
`m_Players` — so they pass the guard, get teleported as a spectator, and are then
added anyway when the world-port ack arrives. That is exactly the 11v10 the
refusal exists to prevent, and the code's own comment three lines above already
names the mid-port state that defeats it.

Separately, the same handler writes `SetBattleGroundEntryPoint()` and
`SetBattleGroundId()` *before* `TeleportTo` and never rolls them back on failure.
Both set `m_bgData.m_needSave`, so a `moved=0` refusal leaves a GM persistently
marked as being in a match they never entered — it survives logout, relocates
them on next login, and makes a later `tournament add` refuse them with
`already_in_a_battleground`.

**Suspected cause / area:** the `tournament camera` handler added by artifact
038. `tournament add` already models both correct patterns: an
`IsBeingTeleported()` check, and `TournamentReleaseInvite` for rollback — follow
those rather than inventing new ones.

**Acceptance criteria:**

- A player invited to the match but not yet ported is refused by `camera` with a
  named reason; the match ends 10v10.
- A `camera` call whose `TeleportTo` fails leaves `m_bgData` exactly as it was —
  a subsequent `tournament add` for that player succeeds rather than reporting
  `already_in_a_battleground`.
- **One** rollback on the failure path closes both the entry-point and the
  battleground-id writes.

**Notes:**

- Needs a build and a live instance to verify the mid-port race. The rollback
  half can be proven by forcing `TeleportTo` to fail without a match at all.
- Docker builds run in the foreground and take ~8.5 min — use `timeout: 600000`
  and `BUILD_JOBS=14`. Backgrounded builds are silently cancelled by BuildKit.
  Verify with `docker images`, not the exit code.
- `m_needSave` is what makes a mistake here persistent across logout, so a wrong
  fix is worse than none.

**Base:** cm-main

**Branch:** backlog/tournament-camera-participant-guard-and-rollback

**Summary:** On `src/game/Commands/TournamentCommands.cpp`, `HandleTournamentCameraCommand` gained two refusals and one rollback. After the existing `m_Players` participant check it now also refuses `plr->IsInvitedForBattleGroundInstance(bg->GetInstanceID())` with `camera error=spectator_is_invited_to_the_match(<name>)` — the invite is the state that exists for the whole flight, since `tournament add` takes it out before `SendToBattleGround` and only `TournamentReleaseInvite`/`RemovePlayerAtLeave` gives it back, so it catches the mid-port window where `m_Players` is still empty — and refuses `plr->IsBeingTeleported()` with `camera error=spectator_teleporting(<name>)`, mirroring `tournament add`'s own check. Before the `SetBattleGroundEntryPoint()` / `SetBattleGroundId()` writes the handler now captures `GetBattleGroundEntryPoint()`, `GetBattleGroundId()`, `GetBattleGroundTypeId()` and `GetCurrentBattlegroundQueueSlot()`; the single `TeleportTo`-failed branch restores all of them in one place before emitting `moved=0`, so a refused camera leaves `m_bgData` at the values it found (`m_needSave` has no setter and stays true, which only costs a save of identical values). `docs/playerbots/TOURNAMENT-STREAMING.md` was updated to name the two new refusal tokens in the checklist that already documented `spectator_is_a_match_participant`. No SQL migration, no build run (rule 4).

**In-game check:** Needs a build; the rollback anchor image predates these commands, so `.tournament` there proves nothing.

1. Mid-port refusal (the main fix, scriptable from console output). Create a Warsong instance with `.tournament create`, fill it with `.tournament add` until it is 10v10 and the match runs. Then, in a single console attach, issue `.tournament add <Bot> <instanceId>` for an 11th character immediately followed by `.tournament camera <Bot> <instanceId>`, so the camera call lands while the port is still in flight. Expect the console to print `TOURNAMENT camera error=spectator_is_invited_to_the_match(<Bot>)` (or `...spectator_teleporting(<Bot>)` if the semaphore is what catches it first) and NOT a `moved=1` line. Then `.tournament members <instanceId>` must still report 10 per side, and the score at match end must be a 10v10 — never 11v10. On the old code the same sequence prints `moved=1` and `members` later shows 11 on one side; that difference is the whole test.
2. Legitimate camera still works: `.tournament camera <GMName> <instanceId>` for an uninvolved GM prints `moved=1` with the `reason=` token, and the GM is standing above the fight in the right Warsong copy (not an empty one) with the action visible below.
3. Rollback (provable without a match). On a live server pick a GM standing in Stormwind, note their position, and run `.tournament camera <GMName> <instanceId> 100000` — the absurd height makes `IsValidMapCoord` reject the destination and `TeleportTo` return false. Expect `TOURNAMENT camera ... moved=0` and the GM still in Stormwind. Then, and this is the part that fails on the old code: run `.tournament add <GMName> <someOtherInstanceId>` and it must succeed (`sent=1`) instead of printing `add error=already_in_a_battleground(<GMName>)`. For the persistence half, after the failed camera call log the GM out, log back in, and confirm they log in in Stormwind rather than inside the arena; optionally `SELECT bgInstanceID, joinPos... FROM characters WHERE name='<GMName>'` (or the equivalent column set) after a `.save` and confirm the battleground id is unchanged from before the camera call.
4. Scriptable subset for a later batch step: everything in step 1 and step 3 that is a console line — the presence of `camera error=spectator_is_invited_to_the_match(...)`, the absence of `moved=1` on that call, `members` counting 10/10, `moved=0` on the bad-height call, and the following `add` reporting `sent=1` rather than `already_in_a_battleground`. Only the visual "the camera is over the fight" in step 2 and the log-out/log-in relocation in step 3 need a human at a client. Server startup must also show no new errors and bots must spawn as usual.

**Minor findings:**
- src/game/Commands/TournamentCommands.cpp: `Player::TeleportTo` returns true as soon as a far teleport is *scheduled* (`sMapMgr.ScheduleFarTeleport`), and `MapManager::ExecuteSingleDelayedTeleport` silently swallows a later `ExecuteTeleportFar` failure, so a camera cut whose port never starts still emits `moved=1` and keeps the freshly-written `m_bgData` (bgInstanceID + joinPos, `m_needSave=true`) with no rollback — the exact persistent `already_in_a_battleground` state the artifact targets; `tournament add` closes this with a post-send `IsBeingTeleported()` check that the camera handler does not mirror.
