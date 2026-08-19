---
status: pending
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
