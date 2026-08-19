---
status: done
risk: low
area: tournament/spectate
depends-on:
---

# Repositioning the camera is a manual console command per cut

**Problem:** `tournament camera` moves a spectator once. Following a match means
issuing it repeatedly for twenty minutes, and stopping at the right moment —
because **the director must stop when the match does**, or it teleports a
spectator around an empty map for the next hour.

**Suspected cause / area:** Implements
`docs/superpowers/plans/2026-08-16-08-spectator-camera.md` Task 3.

**Acceptance criteria:**

- `scripts/tournament/spectate.sh --spectator <name> --instance <id>
  [--interval 15] [--height 25] [--max-minutes 25]` repositions the camera on the
  interval.
- It stops as soon as the control plane reports `error=no_such_instance` — a
  finished battleground is destroyed, so that is how the match ends — printing a
  plain `match over` line rather than treating it as a failure.
- A time budget (default 25 minutes, against a 20-minute hard cap at
  `BattleGround.cpp:317-323`) is the backstop for an instance that somehow never
  disappears.
- Any other `error=` is reported on stderr and also ends the loop.
- **It narrates only when the framing changes** — one line per cut, not per poll —
  naming the new `reason`.
- The final line is always
  `SPECTATE instance=<id> spectator=<name> repositions=<n>`, counting only
  successful repositions (`moved=1`), and the script exits 0 when the match ends
  normally.
- `bash tests/tournament/spectate.test.sh` prints `4 passed, 0 failed` and
  exits 0, driving a stubbed control plane that returns two successful
  repositions and then reports the instance gone, and asserting: exit 0, exactly
  three `tournament camera` calls (it stops as soon as the instance is gone),
  a `SPECTATE` summary line, and `repositions=2`.

**Notes:**

- **Run the test from WSL** —
  `wsl -d Ubuntu -- bash -lc 'cd /mnt/c/<worktree path> && bash tests/tournament/spectate.test.sh'`.
  The tests inject a stub through `CTL_STUB` (the script sources `$CTL_STUB` when
  set, and `lib/ctl.sh` plus `wsg-bots-common.sh` otherwise), so no server is
  needed — but Git Bash is still the wrong shell for this repo's test suite.
- This artifact is independent of the C++ artifact that adds `tournament camera`
  (038), because the stub stands in for it. The contract it drives:
  `tournament camera <playerName> <instanceId> [height]` →
  `camera player=… instance=… x=… y=… z=… reason=… moved=<0|1>`, or
  `camera error=<reason>`.
- **This produces broadcast-style cuts, not smooth tracking.** Say so in the
  script header and point at `docs/playerbots/TOURNAMENT-STREAMING.md`; there is
  no server-side API to rotate a client's view.
- **The one-time in-game setup includes the camera, and the plan omits that.**
  `tournament camera` teleports to the point of interest plus a height offset
  (default 25 yards) while **preserving the player's orientation** — and camera
  *pitch* cannot be set server-side at all. So before a match the operator must
  also **pitch the view downward and zoom out**, not just run `.gm on`,
  `.gm visible off`, `.hover 1`, `.god on`. Without that the director works
  perfectly and every shot is of the horizon. Record this in the script header
  and in `docs/playerbots/TOURNAMENT-STREAMING.md`; it is the difference between
  automation that works and automation that appears to.
- **If overhead framing proves awkward, the alternative is worth trying before
  reaching for a client addon:** place the spectator at a horizontal offset from
  the point of interest at a modest height, and pass a computed orientation
  (yaw toward the POI) to `TeleportTo` rather than the player's current one. Yaw
  *is* settable server-side, so that framing needs no manual pitch at all and
  survives the operator bumping the mouse. It is a change to artifact 038's
  handler, not to this director.
- **Verification needing a live stack and a human (not part of these criteria):**
  run the director against a live match with the setup above. Record what it
  actually looks like on screen — specifically whether the teleport cadence is
  watchable or jarring at `--interval 15`, and whether the framing lands on the
  action or beside it. That observation is an input to artifact 040 and cannot be
  obtained any other way.
