---
status: done
risk: low
area: tournament/spectate
depends-on: 039-spectator-director-loop.md
---

# "Retrieve the bot's POV" is an open question with a definite answer

**Problem:** The streaming plan keeps returning to questions that cannot be
answered by building anything — how to capture video, how many clients this host
can run, how to get a bot's point of view — and leaving them open invites someone
to build plumbing nobody can test. One of them has a definite answer that needs
writing down: **a playerbot is a `WorldSession` with no client process and no
renderer, so there is no framebuffer and no POV to capture.** No amount of server
work creates one.

**Suspected cause / area:** Implements
`docs/superpowers/plans/2026-08-16-08-spectator-camera.md` Task 4. No code.

**Acceptance criteria:**

- `docs/playerbots/TOURNAMENT-STREAMING.md` exists, dated, and states plainly
  that a bot has no POV to capture — **verified**, not asserted, by citing what
  `src/modules/PlayerBots/playerbot/PlayerbotMgr.cpp` actually does to create a
  bot session, with `file:line`.
- It gives the three ways to aim a camera — a human flying the GM; server-side
  teleport (`scripts/tournament/spectate.sh`); a client-side addon — comparing
  them on control, whether they can be verified unattended, and cost. Only the
  middle row can be tested by an unattended run, which is why it is what got
  built; say so.
- It documents what `spectate.sh` actually produces: broadcast-style **cuts**, not
  tracking, because `tournament camera` calls `TeleportTo` and there is no
  server-side API to rotate a client's view. It lists the POI priority order
  (`flagcarrier` → `combat` → `centroid` → `empty`) and notes that a whole match
  at `reason=centroid` is a finding for `BG-AI-ANALYSIS.md`, not a camera bug.
- It records **measured** numbers from this host for the multiboxing question —
  at minimum `nproc`, total and available memory, and `docker stats` for the
  running stack — with the date and what state the host was in when they were
  taken. It states which side is the constraint (each additional client is a full
  game process with its own renderer; the server is not the bottleneck) and says
  plainly if the supported answer is "one client".
- It ends with a recommended path and a setup checklist covering: the GM account
  needing `rank=4` (`rank=3` is refused because `SEC_GAMEMASTER` is `#define`d to
  `SEC_ADMINISTRATOR`=4); **never party the spectator to a bot**
  (`HasActivePlayerMaster()` at `BattleGroundJoinAction.cpp:568` — a partied bot
  never queues again); that `tournament camera` refuses a match participant; and
  that `.appear` into a battleground is supported and only fails if the caller is
  already inside a *different* battleground.
- **Every claim is either measured on this host or attributed to a `file:line` or
  an existing document.** No code is written or changed.

**Notes:**

- **The client-side half of the measurement cannot be done unattended.** The plan
  asks for a before/after delta with a real game client logged in and watching a
  live match; there is no way to start or observe a client from here. Take the
  automated numbers (host and VM memory, core count, `docker stats` for the
  stack), record them as such, and leave the with-a-client delta as an explicitly
  labelled **unfilled human measurement** with the exact commands to run — do not
  estimate it, and do not present an estimate as a measurement. The same applies
  to the observed cut cadence from artifact 039: leave the placeholder marked, do
  not invent an impression of something nobody watched.
- `docs/DOCKER.md` records this host's WSL2 allocation (16 CPU / 24 GB) and is the
  right thing to cite alongside fresh numbers.
- Docker on this host is at a deliberate fresh slate (2026-08-16): every image was
  deleted except the rollback anchor `tortoise-cm:c06b2fb`, so `docker stats` may
  show nothing running. Record that as the state the numbers were taken in rather
  than reporting zeros as a result.
- This artifact depends on 039 only because it documents that script's behaviour;
  it changes no code.
