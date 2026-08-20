---
status: done
risk: high
area: game/commands
depends-on: 030-tournament-heal-and-kill-commands.md
---

# The server knows where the action is but cannot point a camera at it

**Problem:** The sampler proves the server knows every player's position, but
nothing reduces that to "where is the story right now", and nothing moves a
spectator there. Doing it by hand means a person flying a GM for every match. Two
constraints make a naive implementation actively harmful: **the spectator must
never be a battleground member** — enrolling them would make the match 11v10 and
change its outcome — and computing the point of interest in two places would let
`poi` and `camera` drift apart on the first edit.

**Suspected cause / area:** Implements
`docs/superpowers/plans/2026-08-16-08-spectator-camera.md` Tasks 1-2, in
`src/game/Commands/TournamentCommands.cpp` plus the `Chat.h` / `Chat.cpp`
declarations and registrations.

**Acceptance criteria:**

- A single file-static helper —
  `TournamentComputePoi(BattleGround* bg, float& x, float& y, float& z,
  std::string& reason)` — computes the point of interest, returning false only
  when there is nothing to look at. **Both** `HandleTournamentPoiCommand` and
  `HandleTournamentCameraCommand` call it; neither contains its own copy.
  `HandleTournamentPoiCommand` is a thin printer over it.
- Priority order, each a strictly weaker fallback, with the chosen one named in a
  `reason=` field so a director knows how much to trust the framing:
  1. `flagcarrier` — via `BattleGround::GetFlagCarrierGuid(teamIdx)`, which is a
     **base virtual** (`BattleGround.h:299`) returning an empty guid by default, so
     this works unchanged for battleground types with no flags and needs no
     subclass include and no aura sniffing. `BG_TEAMS_COUNT` is 2. **A carrier who
     just died is still recorded until the flag drops, so liveness is checked, not
     just the guid.**
  2. `combat` — the centroid of the largest cluster of players in combat within
     40 yards of one another. A global centroid in a two-sided fight points at the
     empty middle of the map, which is why this is not that.
  3. `centroid` — everyone alive, when nothing is happening.
  4. `empty` — nobody alive.
- Live players are collected **once** and every branch is a reduction over that
  one set — gathering twice would be both slower and racy.
- `poi <instanceId>` emits
  `poi instance=… map=… x=… y=… z=… reason=… subject=<name|-> players=<n>`.
- `camera <playerName> <instanceId> [height]` teleports the named spectator to the
  POI plus a vertical offset (default 25) and emits
  `camera player=… instance=… x=… y=… z=… reason=… moved=1`.
- **`camera` refuses a player who is in `bg->GetPlayers()`**, with
  `error=spectator_is_a_match_participant(<name>)`. That refusal is the important
  half of the task — it is what stops the camera from silently turning the match
  into 11v10. It also refuses an offline spectator and a missing instance.
- Both are declared in `Chat.h`, registered with `AllowConsole = true`, and emit
  exclusively through `TournamentEmit`.

**Notes:**

- **Do not attempt a Docker build here** (~9.5 min, no incremental build); the
  `backlog-batch` pass compiles this branch. The criteria above are structural on
  purpose.
- Tasks 1 and 2 of the plan are merged here deliberately: the plan writes the POI
  logic inline in Task 1 and then refactors it out in Task 2 Step 2 — and Task 2's
  handler already calls the extracted helper before that step introduces it.
  Writing the helper once avoids both the churn and the ordering defect.
- Risk is `high`: this dereferences `Player*` from `ObjectAccessor` across every
  battleground member and then teleports one, on a server running ~1000
  concurrent playerbots. Null-check every lookup. The cluster scan is O(n²) over
  at most 40 players, which is fine — do not "optimise" it into something with
  worse lifetime behaviour.
- **Server-side camera control is teleportation, not panning.** There is no
  server-side API to rotate a client's view, so this produces broadcast-style
  *cuts*, not smooth tracking. Do not imply otherwise in comments.
- This artifact edits the same three files as artifacts 015-017 and 030, which is
  why it stacks on 030.
- **Verification needing a live stack (not part of these criteria):** against a
  freshly created empty instance, `poi` must read `reason=empty players=0`. During
  a live match, polling `poi` should show `reason=centroid` early, `reason=combat`
  once the sides meet, and `reason=flagcarrier` if a flag is ever taken. **If
  `reason` never leaves `centroid` across a whole match that is a finding for
  `docs/playerbots/BG-AI-ANALYSIS.md` — the bots never fought — not a bug in this
  command.** Then `camera Astral <inst>` must report `moved=1` and visibly
  relocate the GM above the action on map 489, and `camera Wsgaone <inst>` (a
  participant) must report `error=spectator_is_a_match_participant(Wsgaone)`.
- The GM account needs `rank=4`; `rank=3` is refused because `SEC_GAMEMASTER` is
  `#define`d to `SEC_ADMINISTRATOR`=4. **Never party the spectator to a bot** —
  `HasActivePlayerMaster()` is a hard gate at `BattleGroundJoinAction.cpp:568` and
  a partied bot never queues again.

**Base:** backlog/tournament-heal-and-kill-commands

**Branch:** backlog/tournament-poi-and-camera-commands

**Summary:** Added `tournament poi` and `tournament camera` to `src/game/Commands/TournamentCommands.cpp`, declared in `src/game/Chat/Chat.h` and registered `AllowConsole = true` in `src/game/Chat/Chat.cpp`. A single file-static `TournamentComputePoi(BattleGround*, float& x, float& y, float& z, std::string& reason, std::string& subject, uint32& players)` computes the point of interest once and both handlers call it — `poi` is a thin printer over it, `camera` is the only caller that branches on the return. It collects live players once via `ObjectAccessor::FindPlayer` (null-checked, in-world only) and every branch is a reduction over that one vector: `flagcarrier` from the base virtual `BattleGround::GetFlagCarrierGuid(teamIdx)` over `BG_TEAMS_COUNT`, with the carrier's liveness checked because a dead carrier stays recorded until the flag drops; `combat`, the centroid of the largest 40-yard cluster of players in combat (O(n²), min cluster size 2); `centroid` of everyone alive; `empty` when nobody is. `poi <instanceId>` emits `poi instance=… map=… x=… y=… z=… reason=… subject=<name|-> players=<n>`; `camera <playerName> <instanceId> [height=25]` emits `camera player=… instance=… x=… y=… z=… reason=… moved=1`. `camera` refuses a player the battleground still lists in `m_Players` with `error=spectator_is_a_match_participant(<name>)`, plus `error=spectator_not_online(<name>)` and `error=no_such_instance`. Two things the plan's snippet omitted and the code needs to actually work: `Player::TeleportTo` returns false for a battleground map unless the traveller already carries a battleground id (`Player.cpp:2617`) and the world-port ack resolves the destination as `FindMap(mapId, GetBattleGroundId())` (`MovementHandler.cpp:133`), so the handler sets `SetBattleGroundId(instance, type, PLAYER_MAX_BATTLEGROUND_QUEUES)` with `TELE_TO_GM_MODE | TELE_TO_FORCE_MAP_CHANGE` exactly as `.appear` does — no invite is taken out, so `HandleMoveWorldportAckOpcode` never calls `bg->AddPlayer` and the match stays 10v10. It also refuses a spectator who is a real participant of a *different* battleground (`error=spectator_in_another_battleground(<name>)`) rather than clobbering their bgData, and reports `moved=0` when `TeleportTo` itself fails. Everything emits exclusively through `TournamentEmit`. No SQL migration, no build run (the running image `tortoise-cm:20260818-2` was probed: `tournament status` answers `count=0` and `poi` is absent from the subcommand list, as expected for an uncompiled branch).

**In-game check:** Needs a live match on map 489 (Warsong Gulch) plus one GM character. Console output is enough for steps 1, 2, 3 and 5; only step 4 needs human eyes.

SCRIPTABLE (console + `bg.log` — every line below is emitted through `TournamentEmit`, so it appears both on the console and in `bg.log` prefixed `TOURNAMENT `):

1. Empty instance. `tournament create 2 60`, note the `instance=` id, then `tournament poi <inst>` with nobody added. Expect exactly `TOURNAMENT poi instance=<inst> map=489 x=0 y=0 z=0 reason=empty subject=- players=0`. Any other `reason` here means the live-player collection is wrong.
2. Participant refusal — the important half. During a live match, `tournament camera Wsgaone <inst>` where `Wsgaone` is a bot the match actually holds. Expect `TOURNAMENT camera error=spectator_is_a_match_participant(Wsgaone)`. Then `tournament members <inst>` and confirm the count is unchanged (10 per side, never 11) and that the bot's `map=` is unchanged — i.e. it was not moved.
3. Reason progression. Poll `tournament poi <inst>` every 30s across a whole match. Expect `reason=centroid` before the gates open, `reason=combat` (with `subject=<some bot>` and a `players=` count smaller than the full roster) once the sides meet, and `reason=flagcarrier` if a flag is ever picked up. Note the artifact's own caveat: if `reason` never leaves `centroid` for an entire match, that is a bot-AI finding for `docs/playerbots/BG-AI-ANALYSIS.md` (the bots never fought), not a bug in this command.
4. Bad arguments: `tournament camera` with no args, and `tournament poi 999999`, must answer `camera error=usage` / `poi error=no_such_instance` — not crash, and not print a bare `TOURNAMENT ` line with an unparseable value.

MANUAL (a human at a client):

5. Log in the GM `Astral` (account 504, **`rank=4`** — `rank=3` is refused because `SEC_GAMEMASTER` is `#define`d to `SEC_ADMINISTRATOR`=4) somewhere outside any battleground. During a live match run `tournament camera Astral <inst>`. Expect `TOURNAMENT camera player=Astral instance=<inst> x=… y=… z=… reason=… moved=1`, and on screen: a loading screen, then Astral hanging ~25 yards above the fight inside that same Warsong instance — the bots he sees must be the ones `tournament members <inst>` lists, not a different WSG copy. Run it again 60s later and confirm he cuts to the new position (cuts, not smooth panning — that is expected; there is no server-side view rotation).
6. While he is up there, run `tournament members <inst>` and confirm Astral is **not** in the list and the per-side counts are still 10/10, and check the scoreboard in-client shows 10v10. That is the 11v10 guard proving itself end to end.
7. Server log check for step 5/6: `mangosd`'s error log must contain no `TeleportTo: invalid map` line and no `was teleported far to nonexisten battleground instance` line for Astral. Either one means the battleground-id handoff before the teleport is wrong.
8. Let the match end with Astral still inside. He should be returned to where he was standing when `camera` first moved him (the entry point the handler records), not to his homebind, and not left standing in a dead instance.

Beyond that, the generic smoke test applies: server starts, bots spawn, `.tournament status` still answers.

**Minor findings:**
- src/game/Commands/TournamentCommands.cpp: In `HandleTournamentCameraCommand`, `SetBattleGroundId(bg->GetInstanceID(), ...)` is set before `TeleportTo`, but the `moved=0` failure path returns without rolling it back, so a spectator whose teleport was refused (invalid coords from an absurd `height`) is left permanently reading as `InBattleGround()` — which then makes `tournament add` refuse them with `already_in_a_battleground` and suppresses the later `SetBattleGroundEntryPoint()`; `add` rolls its own state back on the same kind of failure (`TournamentReleaseInvite`), this does not.
- src/game/Commands/TournamentCommands.cpp: The participant guard only tests `bg->IsPlayerInBattleGround()` (i.e. `m_Players`), so a player `tournament add` has already invited and sent — who carries this instance's battleground id but has not yet landed and been inserted by `HandleMoveWorldPortAckOpcode` — passes the guard, gets teleported mid-port (with no `IsBeingTeleported()` check, which `add` does make), and is still invited, so the world-port ack calls `bg->AddPlayer` anyway and the camera has produced exactly the 11v10 the refusal exists to prevent.
- src/game/Commands/TournamentCommands.cpp: The `camera` record shape is inconsistent across paths: the nobody-alive path emits `camera player=… instance=… moved=0 reason=empty` with no `x=`/`y=`/`z=` fields and with `moved=` before `reason=`, whereas the success and teleport-failure paths emit coordinates and put `moved=` last, so a positional or field-count-sensitive reader of the one-line output contract sees three different shapes from one command.
- src/game/Commands/TournamentCommands.cpp: On the failed-teleport path the spectator keeps the battleground id and rewritten entry point that were set before `TeleportTo`: `SetBattleGroundEntryPoint()` and `SetBattleGroundId(bg->GetInstanceID(), ...)` both set `m_bgData.m_needSave`, so a `moved=0` refusal (an absurd `height` failing `IsValidMapCoord`) leaves a GM persistently marked as being in a match they never entered, and the next login resolves that stale id and relocates them to the recorded entry point.
- src/game/Commands/TournamentCommands.cpp: The `flagcarrier` branch resolves the carrier guid through a second, independent `ObjectAccessor::FindPlayer` and never confirms the resolved player is still in this battleground or on its map, so a carrier guid that outlives the player's membership yields a POI in a foreign map's coordinate space that `camera` then teleports the spectator to on `bg->GetMapId()` — every other branch is drawn from `bg->GetPlayers()` and cannot do this.
- src/game/Commands/TournamentCommands.cpp: The participant guard only tests `bg->IsPlayerInBattleGround` and `GetBattleGround()` membership, so a spectator who is merely queued or invited for another battleground still has `SetBattleGroundId(..., PLAYER_MAX_BATTLEGROUND_QUEUES)` overwrite their `m_bgData` instance id, type and queue slot, desynchronising them from the pending invite the queue still holds.

**Drain note (finding 2 is a MUST-FIX: it reopens the exact 11v10 hole this artifact exists to close):** verified against the branch on 2026-08-18. This artifact's headline acceptance criterion is that camera must refuse a match participant, "what stops the camera from silently turning the match into 11v10". The guard as written is:

```
if (bg->IsPlayerInBattleGround(plr->GetObjectGuid()))
```

That is the m_Players lookup only. A player whom `tournament add` has already invited and sent, but who has not yet landed and been inserted by HandleMoveWorldPortAckOpcode, is NOT in m_Players — so they pass the guard, get teleported by camera, and are still invited, so the world-port ack calls bg->AddPlayer anyway. The result is precisely the 11v10 the refusal was written to prevent. What makes this worth fixing rather than debating: the code's OWN comment three lines above the guard already names the state that defeats it — "GetBattleGround() is still non-null for a bot mid-port" — so the mid-port case was known and the narrow test was chosen anyway. `tournament add` additionally makes an IsBeingTeleported() check that this handler does not.

**Drain note (the two departures from the plan are CORRECT and should be kept — verified):** the Summary reports two things the artifact's snippet omitted, and both check out exactly:
- src/game/Objects/Player.cpp:2617 reads `if (!InBattleGround() && mEntry->IsBattleGround()) return false;` — so TeleportTo genuinely refuses a battleground map unless the traveller already carries a battleground id. Setting SetBattleGroundId before the teleport is required, not optional.
- src/game/Server/MovementHandler.cpp:133 reads `map = sMapMgr.FindMap(loc.mapId, GetPlayer()->GetBattleGroundId());` — so the world-port ack really does resolve the destination through the battleground id, which is why the spectator must carry the right instance id to land in the right copy of Warsong Gulch rather than a different one.
A reviewer comparing the code against the artifact text would otherwise read both as unexplained deviations.

**Drain note (findings 1/4 and 6 share one root cause worth fixing together):** all three are the same omission — state is written before TeleportTo and never rolled back when it fails. SetBattleGroundEntryPoint() and SetBattleGroundId() both set m_bgData.m_needSave, so a moved=0 refusal leaves a GM persistently marked as being in a match they never entered, which survives logout and relocates them on next login, and makes a later `tournament add` refuse them with already_in_a_battleground. `tournament add` already models the correct pattern with TournamentReleaseInvite. One rollback on the failure path closes 1, 4 and 6.

**Note on what cannot be verified in-world yet, and the tick got this right:** the reason= progression check (centroid -> combat -> flagcarrier) cannot currently reach anything past `centroid`, because the drain has established across three independent measurements that the bots never move, never fight and never take the flag (98.3% and 98.8% of AI ticks executing no action; `bg move to objective` popped zero times in 23908 queues). The tick anticipated this correctly rather than claiming verification it could not have: its in-game check step 3 states that a reason= stuck at centroid for a whole match is a bot-AI finding for docs/playerbots/BG-AI-ANALYSIS.md, not a bug in this command. That is the right call and it should not be read as a gap in this artifact.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/47, build tortoise-cm:20260818-4.
