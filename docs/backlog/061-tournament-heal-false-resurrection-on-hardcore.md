---
status: pending
risk: low
area: game/tournament
depends-on: 030-tournament-heal-and-kill-commands.md
---

# `tournament heal` reports a resurrection that never happened

**Problem:** `Player::ResurrectPlayer` begins
`if (IsHardcore() && !forceHc) return;` (`src/game/Objects/Player.cpp:5755`), and
the heal handler passes no `forceHc`. A dead hardcore target therefore stays a
ghost while the command's record claims `resurrected=1`, and `SetHealth` then
runs on a dead unit.

Tournament bots are never hardcore, so the impact is not the bots — it is the
name-collision case the artifact already argued on the kill side: the kill path
has a hardcore guard precisely so a collision from the viewer-effect queue
cannot destroy a real hardcore character. By the same argument, heal emits a
false resurrection record for one.

**Suspected cause / area:** the `tournament heal` handler added by artifact 030.
The kill path's existing hardcore guard is the model.

**Acceptance criteria:**

- A hardcore target is either refused with a named reason, or the result is
  re-checked with `IsAlive()` after the call. In neither case does the record
  read `resurrected=1` for a character still a ghost.

**Notes:**

- Needs a build; verifiable with any hardcore test character, no match required.
- Docker builds run in the foreground at ~8.5 min — `timeout: 600000`,
  `BUILD_JOBS=14`, and verify with `docker images` rather than the exit code.
