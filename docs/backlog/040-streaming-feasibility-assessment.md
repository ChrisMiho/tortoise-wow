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

**Base:** backlog/spectator-director-loop

**Branch:** backlog/streaming-feasibility-assessment

**Summary:** Added `docs/playerbots/TOURNAMENT-STREAMING.md` (371 lines, dated 2026-08-18) and changed no code. §1 proves rather than asserts that a bot has no POV: `PlayerbotHolder::HandlePlayerBotLoginCallback` builds the bot's session with `sock=nullptr` and `remote_ip="disconnected/bot"` (`PlayerbotMgr.cpp:207-209`), that string is itself the server's bot-vs-real-player test (`PlayerbotAI.h:625-629`), the session is never added to `sWorld.m_sessions` (`PlayerbotMgr.cpp:192-193`), and `WorldSession::SendPacket` returns on the null socket after handing the packet to the AI (`WorldSession.cpp:234-238`) — plus a live confirmation on `tortoise-cm:20260818-4` where `server info` reported "Players online: 0" while the DB reported 998 characters online, because `GetActiveSessionCount` is `m_sessions.size()` (`World.h:967-968`). §1 then compares the three ways to aim a camera (human GM / server-side teleport / client-side addon) on control, unattended verifiability, and cost, and says why only the middle one got built. §2 documents `spectate.sh` as broadcast-style cuts — `tournament camera` ends in `TeleportTo` with the player's existing orientation (`TournamentCommands.cpp:1364` on `21074a5`) and there is no server-side API to rotate or pitch a client's view — lists the POI priority order against the `reason=` assignments in `TournamentComputePoi`, and records that a whole match at `reason=centroid` is a `BG-AI-ANALYSIS.md` finding, not a camera bug. Both commands were exercised live and refused correctly (`error=no_such_instance`, `error=spectator_not_online(Astral)`). §3 records measured numbers with the host state: stack down at 15:11Z (nproc 16, MemTotal 23.5 GiB, MemAvailable 22.2 GiB); stack up on `tortoise-cm:20260818-4` with the world loaded and 998 bots online, three `docker stats` samples 15:19–15:21Z (mangosd ~172% CPU = 1.7 of 16 cores, 5.6 GiB; db 356 MiB; realmd 28 MiB; ~16.9 GiB still available); and Windows-side physical RAM 31.1 GiB / 24 logical CPUs / ~9.2 GiB free. It states the clients are the constraint and that the supported answer is one client. Two measurements are left explicitly UNFILLED with the exact commands to run — the with-a-client delta and the observed cut cadence from 039 — rather than estimated. §4 gives the recommended path and §5 a setup checklist covering rank=4, never partying the spectator, the participant refusal, and `.appear`. Three stale line references in earlier documents are corrected against this tree while confirming the claims themselves (`HasActivePlayerMaster` is `BattleGroundJoinAction.cpp:635`, not `:568`; the 20-minute match cap is `BattleGround.cpp:333-338`, not `:317-323`). The stack was brought up from WSL for the measurements and returned to the down state it was found in; `tortoise-wow-v2_dbdata` verified intact.

**In-game check:** This artifact changes no code — it adds one Markdown file — so the only build-level check needed is the generic smoke test: the batch image compiles, the world starts, and bots spawn. Nothing in-game can regress from this change.

What IS worth confirming, because the document's job is to be accurate about the live server, is that its claims still hold. Scriptable / log-confirmable parts (a later batch step can do these without a human):

1. `docker exec tcm-db mysql -uroot -p<pass> -N -e "SELECT COUNT(*) FROM tw_char.characters WHERE online=1;"` returns several hundred, while `server info` over `wsg_console` on the same world reports `Players online: 0. Max online: 0.` That pair is §1's live evidence that a bot session is never a connection. If `server info` ever reports a non-zero count with no human logged in, §1's live paragraph is wrong and should be corrected.
2. `wsg_console "tournament poi 1"` against a world with no such instance emits exactly `TOURNAMENT poi error=no_such_instance`, and `wsg_console "tournament camera Astral 1 25"` emits `TOURNAMENT camera error=spectator_not_online(Astral)`. Both were observed on `tortoise-cm:20260818-4`. (If a future image lacks these, that is artifact 038 missing from the batch, not a defect here.)
3. `docker stats --no-stream` on a loaded world stays in the neighbourhood recorded in §3.2 — mangosd ~170% CPU and ~5.6 GiB. A large departure means the §3 numbers need re-taking, not that the conclusion changed.

Genuinely manual, and deliberately left unfilled in the document (a human should fill these in and amend the file, not treat them as pass/fail gates):

4. Create a tournament instance, populate it, and start a match. Log in a GM at `rank=4`. Run `.gm on`, `.gm visible off`, `.hover 1`, `.god on`, then **with the mouse pitch the view down and zoom out**. Run `scripts/tournament/spectate.sh --spectator <GMName> --instance <id>` from WSL for the whole match. Watch the client and record, in §2.2's "Unfilled human measurement" box: how many cuts happened (the final `SPECTATE ... repositions=<n>` line gives this), the longest gap between `camera now following:` lines, and whether the jumps were watchable or disorienting. Confirm the camera lands above the fight and does not rotate on its own — the cuts-not-tracking claim is exactly what should be visible.
5. While that match runs, confirm the spectator never appears on either team's scoreboard (they are a GM standing on the map, not a participant), and that `tournament camera <a participating bot's name> <id>` is refused with `error=spectator_is_a_match_participant(...)`.
6. With the stack up and a match running, run `Get-Process -Name WoW | Select-Object Name,WS,CPU` in PowerShell with one client logged in, then two, and record the working-set-per-client and free physical memory at each step into §3.3's "Unfilled human measurement" box. That is the number that decides whether this host supports more than one camera; §3 says "one" only because nobody has measured a second.

**Minor findings:**
- docs/playerbots/TOURNAMENT-STREAMING.md: §3.1 is headed "Measured, stack down" but the Windows table inside it is explicitly labelled "with the stack up", so the state annotation for the ~9.2 GiB free figure — the single number §3.3's "one client" conclusion rests on — contradicts its own section heading.
- docs/playerbots/TOURNAMENT-STREAMING.md: The derivation "31.1 GiB physical, of which the WSL2 VM holds 23.5 GiB, leaving roughly 9 GiB free" does not add up (31.1 − 23.5 = 7.6) and treats the VM's 23.5 GiB `.wslconfig` ceiling as a held reservation, when the same section's own `free -m` shows the VM using ~7 GiB — the 9 GiB is a measurement, not a consequence of that subtraction.
- docs/playerbots/TOURNAMENT-STREAMING.md: §2.2 says `spectate.sh` "prints one line per cut" and tells the human filling the cadence measurement to read cut timestamps off the `camera now following:` lines, but the script prints only when `reason` changes (`spectate.sh:141-149`), so consecutive cuts sharing a reason emit nothing and those timestamps undercount cuts.
- docs/playerbots/TOURNAMENT-STREAMING.md: §4 cites `tournament result` at `TournamentCommands.cpp:570`, which is its line on the 038 branch `21074a5`; in this branch's tree the command is at :568, and unlike the camera/POI citations this one carries no branch caveat, so it silently mixes two trees' line numbers.

**Drain note (the line-reference corrections are CONFIRMED, and one of them is propagated across four files including a shipped doc):** this tick corrected three stale citations in earlier documents. The drain verified the two load-bearing ones:

1. The 20-minute match cap is at src/game/Battlegrounds/BattleGround.cpp:333-338, NOT :317-323. Confirmed by reading both ranges. :333-338 is unambiguously the cap:
```
if (!IsArena() && GetStatus() == STATUS_IN_PROGRESS &&
    (GetTypeID() == BATTLEGROUND_WS || GetTypeID() == BATTLEGROUND_AB) &&
    m_StartTime > 20 * MINUTE * IN_MILLISECONDS)
{ EndBattleGround(GetWinningTeam()); }
```
while :317-323 is an unrelated queue-update block about a bg remaining indefinitely after a logout. The wrong citation is not isolated -- `grep -rl "BattleGround.cpp:317-323"` finds it in FOUR files: docs/backlog/024-tournament-match-run.md, docs/backlog/036-bg-ai-analysis-code-reading.md, docs/backlog/039-spectator-director-loop.md, and the shipped docs/playerbots/WSG-BOT-MATCH.md. Anyone following it lands on the wrong code. Worth a sweep beyond the files this branch touches.

2. HasActivePlayerMaster is at BattleGroundJoinAction.cpp:635, NOT :568. Confirmed by grep. Note this one is wrong in THIS ARTIFACT'S OWN acceptance criteria -- the artifact text instructed the citation that the implementation then had to correct.

**Drain note (this tick was honest about what it could not measure, which is the right call here):** streaming presumes there is something to watch, and the drain has established across three independent measurements that the bots never move, never fight and never take the flag. A feasibility assessment claiming the director frames the action well would have been asserting something nobody can currently observe. Instead this tick left two measurements explicitly UNFILLED with the exact commands to run -- the with-a-client memory delta and the observed cut cadence from 039 -- rather than estimating them, and recorded that a whole match at reason=centroid is a BG-AI-ANALYSIS.md finding rather than a camera bug. It also closed the dangling reference the drain flagged on artifact 039: docs/playerbots/TOURNAMENT-STREAMING.md now exists, so 039's two pointers at it resolve.

**Drain note (findings are all documentation-accuracy in the new file; finding 3 is the one that would mislead a human):** finding 3 says §2.2 tells the human to count cuts from the `camera now following:` timestamps, but spectate.sh prints only when `reason` CHANGES -- which is 039's own acceptance criterion ("narrates only when the framing changes"), so consecutive cuts sharing a reason emit nothing and the instruction undercounts. Since §2.2 is one of the two deliberately-unfilled human measurements, following it as written would produce a wrong number recorded as measured. The `SPECTATE ... repositions=<n>` summary line is the correct source and the document already names it elsewhere. Findings 1 and 2 are internal inconsistencies around the ~9.2 GiB free figure that §3.3's "one client" conclusion rests on -- the state annotation contradicts its section heading, and the 31.1 - 23.5 = 9 derivation does not arithmetically hold (it is 7.6, and the figure is a measurement rather than a consequence). Finding 4 mixes line numbers from two trees without a caveat.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/49, build tortoise-cm:20260818-5.
