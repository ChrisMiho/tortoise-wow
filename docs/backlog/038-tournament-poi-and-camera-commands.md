---
status: pending
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
