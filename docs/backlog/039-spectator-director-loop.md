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

**Base:** cm-main

**Branch:** backlog/spectator-director-loop

**Summary:** Added `scripts/tournament/spectate.sh`, a director loop that polls `tournament camera <spectator> <instance> <height>` on an interval so a match can be followed without a console command per cut, plus `tests/tournament/spectate.test.sh` driving it through the `CTL_STUB` seam. The loop's primary stop is the control plane answering `error=no_such_instance` — a finished battleground is destroyed, so the instance vanishing *is* the end of the match — printed as a plain `match over` line rather than treated as a failure (exit 0). Any other `error=` goes to stderr and also ends the loop (exit 1), and `--max-minutes` (default 25, against the 20-minute hard cap at `BattleGround.cpp:317-323`) is only a backstop for an instance that never disappears (exit 1). It narrates one line per cut — printed only when `reason` changes on a `moved=1` reply — and always ends with `SPECTATE instance=<id> spectator=<name> repositions=<n>`, counting `moved=1` replies only. Arguments are validated as unsigned integers so a bad `--interval` cannot turn the poll into a spin. `CTL_STUB` replaces `lib/ctl.sh` rather than loading alongside it, so the tests need no container and no build. The script header records the two things nothing else would: that this produces broadcast-style *cuts*, not tracking (pointing at `docs/playerbots/TOURNAMENT-STREAMING.md`), and that the one-time in-game setup includes pitching the view downward and zooming out **by hand**, because the teleport preserves the player's orientation and camera pitch cannot be set server-side at all. I deliberately did not create `docs/playerbots/TOURNAMENT-STREAMING.md` — that file is artifact 040's deliverable and creating it here would collide; the header carries the setup warning in full in the meantime. Verified from WSL: `bash tests/tournament/spectate.test.sh` prints `4 passed, 0 failed` and exits 0; the whole `tests/tournament/` suite still passes (bracket 9, ctl 6, gear 12, roster 11, spectate 4, state 10, team 10, all 0 failed). Beyond the committed test I also exercised the narration cadence (centroid → combat → flagcarrier with a `moved=0` poll among them yields exactly three lines and does not count the unmoved poll), the other-error path, the budget backstop, and the argument guards. One live poll went through the real `ctl()`/`wsg_console` path against `tcm-mangosd` on `tortoise-cm:20260818-2` and correctly reported that no `TOURNAMENT camera` record came back, then exited 1 on the budget — expected, since `tournament camera` is artifact 038 and is still pending, so it exists in no image on this host. No build was run.

**In-game check:** Two halves. The scriptable half can be done now against the running stack; the watchable half needs a human at a game client and cannot be faked.

SCRIPTABLE (no human eyes needed, a later batch step can attempt all of this):

1. `bash tests/tournament/spectate.test.sh` from WSL (`wsl -d Ubuntu -- bash -lc 'cd /mnt/c/<worktree> && bash tests/tournament/spectate.test.sh'`). Expect `4 passed, 0 failed`, exit 0. Needs no server, no database, no build.
2. Against the live console with an instance id that does not exist, once the image carries `tournament camera` (artifact 038): `./scripts/tournament/spectate.sh --spectator Astral --instance 999999 --interval 0 --max-minutes 1`. Expect stdout `match over (instance 999999 is gone)` then `SPECTATE instance=999999 spectator=Astral repositions=0`, and exit **0** — this is the whole "a destroyed battleground is not a failure" contract, exercised without needing a match. NOTE: check the exit code from a script FILE, not a wrapped `wsl -d Ubuntu -- bash -lc '...; echo $?'` one-liner — that form silently reported 0 for a run that actually exited 1 while I was testing this.
3. Spectator-not-online path, again once 038 is built: run it naming a character that is not logged in against a real live instance. Expect `camera error: spectator_not_online(<name>)` on **stderr**, the `SPECTATE ... repositions=0` line on stdout, and exit 1.
4. Participant refusal: run it naming a bot that is in the match (e.g. `Wsgaone`). Expect `camera error: spectator_is_a_match_participant(Wsgaone)` on stderr and exit 1 — the loop must stop, not keep polling.
5. Absence check in the server logs: over a full directed match there should be no repeated `tournament camera` traffic after the `match over` line — i.e. the count of `tournament camera` sends in the run's console output must equal `repositions` + 1.

NEEDS A HUMAN AT A CLIENT (this is the part that decides whether the feature is real):

6. Log in the GM character `Astral` (account 504, `rank=4` — `.hover` is refused at `rank=3`). In game run `.gm on`, `.gm visible off`, `.hover 1`, `.god on`, and then **with the mouse, pitch the camera down toward the ground and zoom all the way out**. That last step is manual and load-bearing: `tournament camera` preserves the player's orientation and cannot set pitch, so without it every shot is of the horizon and the director will look broken while working perfectly.
7. Start a match (`scripts/tournament/match-run.sh <allianceTeam> <hordeTeam>`), take its instance id, and run `./scripts/tournament/spectate.sh --spectator Astral --instance <inst>` in another shell.
8. Confirm on screen that the character actually relocates above the fighting — not beside it, not under the terrain — each time a `[HH:MM:SSZ] camera now following: <reason>` line prints, and that lines print only when the reason changes (typically `centroid` early, `combat` once the sides meet, `flagcarrier` if a flag is taken), not once every fifteen seconds.
9. Confirm the director stops on its own within a poll interval of the match ending, printing `match over (instance <inst> is gone)` and `SPECTATE instance=<inst> spectator=Astral repositions=<n>` with `n` roughly matching the match length divided by `--interval`, and that the GM is left standing on map 489 rather than being teleported around an empty map afterwards.
10. Record whether the teleport cadence at `--interval 15` is watchable or jarring, and whether the framing lands on the action. That observation cannot be obtained any other way and is an explicit input to artifact 040 — leave it as an unfilled placeholder there rather than guessing.

**Minor findings:**
- scripts/tournament/spectate.sh: The script header points twice at `docs/playerbots/TOURNAMENT-STREAMING.md`, but that file does not exist on origin/cm-main and is not added here (artifact 040 creates it), so the artifact's note to record the cuts-not-tracking caveat and the manual pitch/zoom setup "in the script header and in docs/playerbots/TOURNAMENT-STREAMING.md" is only half done and the reference dangles until 040 lands.
- scripts/tournament/spectate.sh: The header line "Run from WSL: jq is not on Git Bash's PATH on this host" gives a false rationale — spectate.sh, lib/ctl.sh and wsg-bots-common.sh contain no jq call at all, so the (correct) instruction is justified by a dependency that does not exist.

**Drain note (both findings verified, both are documentation-accuracy only):** confirmed 2026-08-18. (1) `git ls-tree -r origin/cm-main` finds no docs/playerbots/TOURNAMENT-STREAMING.md, so the header's two references to it dangle until artifact 040 lands. Not creating that file was the RIGHT call — it is 040's deliverable and creating it here would collide — but the artifact asked for the cuts-not-tracking caveat and the manual pitch/zoom setup to be recorded in both places, and only one exists today. (2) The only occurrence of "jq" anywhere in spectate.sh is line 43, the comment asserting the dependency: `# Run from WSL: jq is not on Git Bash's PATH on this host.` There is no jq call. The instruction to run from WSL is still correct (the script drives ctl/wsg_console against docker), but the stated reason is false and would mislead anyone trying to relax it.

**Drain note (NEW ENVIRONMENT TRAP, verified — worth adding to CLAUDE.md):** this tick reported that checking an exit code through a wrapped WSL one-liner silently reports success for a run that actually failed. The drain reproduced it and can now characterise it exactly:

```
MSYS_NO_PATHCONV=1 wsl -d Ubuntu -- bash -lc 'false; echo $?'   ->  prints 0, wrapper exits 0   WRONG
MSYS_NO_PATHCONV=1 wsl -d Ubuntu -- bash -lc 'false'            ->  wrapper exits 1             correct
```

The mechanism is the already-documented $VAR blanking, but in its most dangerous form: `$?` is expanded by the OUTER Git Bash shell before the inner shell ever sees the string, so the inner bash literally runs `false; echo 0` — it prints the previous outer command's status, not the inner one's. The trailing `echo` then succeeds, so the wrapper's own exit code is 0 as well. The failure is invisible twice over, and `$?` is exactly the variable one reaches for to detect failure. CLAUDE.md documents the general "$VAR inside a wrapped wsl -lc one-liner is blanked" rule; this is the specific instance most likely to turn a red test into a green one. Use a script file, or omit the trailing echo and read the wrapper's own exit status.

**Note on the undeclared dependency (third instance of a pattern this session):** 039 declares `depends-on:` empty, yet it exists solely to drive `tournament camera`, which is artifact 038 and lives on an unmerged branch three PRs deep. The tick handled this honestly — it ran one live poll through the real ctl()/wsg_console path against tortoise-cm:20260818-2, correctly reported that no TOURNAMENT camera record came back, and attributed it to 038 being unbuilt rather than to its own loop. Steps 2, 3, 4 and 6-10 of its in-game check are all unrunnable until 038 is in an image. This is the same shape as 035 (needed effect-consume.sh from 034) and 038 itself (its reason= progression needs bots that move). The backlog's depends-on: field tracks DATA lineage well and consistently misses COMMAND lineage; artifacts that consume a console subcommand from another artifact do not declare it.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/48, build tortoise-cm:20260818-4.
