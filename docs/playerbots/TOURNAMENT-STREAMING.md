# Streaming a bot tournament — what works and what does not

Assessment dated **2026-08-18**, written against `backlog/streaming-feasibility-assessment`
(branched from `backlog/spectator-director-loop`, `7b5e24d`). The buildable half of the
streaming plan is `scripts/tournament/spectate.sh`; this document is the rest of it.

No code is written or changed here. Every claim below is either **measured on this host**
(§3, with the date and the state the host was in) or attributed to a `file:line` in this
tree. Two numbers that could not be measured unattended are labelled as such in §3.3 and
§2 rather than estimated.

---

## 1. There is no bot POV

A playerbot is a `WorldSession` with **no client process and no renderer**. There is no
framebuffer, so there is nothing to capture. Any question of the form "how do we get the
camera from bot X" has no answer, and no amount of server work creates one.

This is verified, not assumed. `PlayerbotHolder::HandlePlayerBotLoginCallback`
(`src/modules/PlayerBots/playerbot/PlayerbotMgr.cpp:168`) is the whole of what "logging a
bot in" means on this server:

```cpp
// PlayerbotMgr.cpp:207-209
WorldSession* botSession = new WorldSession(lqh->GetAccountId(), /*sock*/ nullptr, SEC_PLAYER,
                                            /*mute_time*/ 0, LOCALE_enUS, /*remote_ip*/ "disconnected/bot",
                                            /*binaryIp*/ 0);
```

Three things in that one call settle the question:

- **`sock` is `nullptr`.** There is no socket because there is no client on the other end.
  The second construction site, `PlayerbotHolder::CreateBot`
  (`PlayerbotMgr.cpp:2259`, session at `:2371`), passes `NULL` for the same argument for
  the same reason — every bot session on this server is built this way.
- **`remote_ip` is the literal string `"disconnected/bot"`**, and that string is the
  server's own bot-vs-real-player discriminator:
  `PlayerbotAI::IsRealPlayer()` (`src/modules/PlayerBots/playerbot/PlayerbotAI.h:625-629`)
  is nothing but `addr != "disconnected/bot" && addr != "<BOT>"`. The server identifies a
  bot precisely *by* the absence of a client connection.
- **The session is never added to `sWorld.m_sessions`** — the comment at
  `PlayerbotMgr.cpp:192-193` says so, and `AddPlayerBot` at `:134` notes it deliberately
  does not pre-create one. A bot is a free-floating session owning a `Player`, not a
  connection the world is serving.

The consequence is in the core, not the module. `WorldSession::SendPacket`
(`src/game/WorldSession.cpp:176`) ends with:

```cpp
// WorldSession.cpp:234-238
if (_player && Player_DispatchBotOutgoingPacket(_player, *packet))
    return;

if (m_Socket == nullptr)
    return;
```

Every packet the world would have sent to a bot's client is handed to the bot's AI and
then dropped. Nothing is serialised to a wire, nothing is decoded by a renderer, and no
frame is ever produced. There is no view to extract because nothing in the process ever
draws one.

**Observed live on this host, 2026-08-18, on `tortoise-cm:20260818-4`.** With 998 bots
logged in and fighting, `server info` on the console answered:

```
Players online: 0. Max online: 0.
```

…while `SELECT COUNT(*) FROM tw_char.characters WHERE online=1` returned `998` at the same
moment. That is not a bug and not a stale counter: `World::GetActiveSessionCount` is
`m_sessions.size() - GetQueuedSessionCount()` (`src/game/World.h:967-968`), and a bot
session is never put in `m_sessions` (`PlayerbotMgr.cpp:192-193`). The server's own count
of connections is **zero** while a thousand bots play, because there are zero connections.
Zero connections is zero clients, and zero clients is zero rendered frames.

**Rendered frames on this stack come from real game clients only.** That leaves exactly
three ways to aim a camera:

| Approach | Control | Verifiable unattended? | Cost |
|---|---|---|---|
| A human flies the GM | Full and smooth — pan, pitch, zoom, follow | **No.** Requires a person watching | One person per match, for the whole match |
| Server-side teleport (`scripts/tournament/spectate.sh`) | Cuts only. Position yes, rotation **no** | **Yes** — `tournament camera` emits `moved=`/`reason=` and `spectate.sh` exits 0/1 on them | None beyond the one client already needed |
| Client-side addon | Smooth and scriptable, in principle | **No.** Nothing in this repo can load, drive or observe an addon | Addon development, entirely client-side, plus a human to judge it |

Only the middle row can be tested by an unattended run, **which is why it is the one that
got built**. The other two rows are not worse ideas; they are ideas this repo's tooling
cannot verify, and an unverifiable camera is how you end up with plumbing nobody can test.

---

## 2. What `spectate.sh` actually produces

**Broadcast-style cuts, not tracking.** The camera jumps to each new point of interest and
holds there until the next cut.

That is a property of the only server-side camera control that exists, which is
teleportation. `HandleTournamentCameraCommand`
(`src/game/Commands/TournamentCommands.cpp:1244`, on
`backlog/tournament-poi-and-camera-commands` @ `21074a5` — artifact 038, compiled into
`tortoise-cm:20260818-4` but not yet merged to `cm-main`) ends in:

```cpp
// TournamentCommands.cpp:1364
if (!plr->TeleportTo(bg->GetMapId(), x, y, cameraZ, plr->GetOrientation(), teleFlags))
```

The orientation argument is the player's *existing* orientation, because there is no
server-side API to set it to anything meaningful and none at all to set camera **pitch**.
The server can say where the camera stands. It cannot say where it looks.

Two operational consequences follow directly, and both are already in `spectate.sh`'s
header:

- The one-time in-game setup includes **pitching the view down and zooming out by hand**.
  Skip it and the director works perfectly while every single shot is of the horizon.
- Cadence is a cut every `--interval` seconds at most, not motion. A fight that moves
  across the map is followed in steps, not smoothly.

### 2.1 Point-of-interest priority

Computed once, by the file-static `TournamentComputePoi`
(`TournamentCommands.cpp:1058`), and shared by `tournament poi` and `tournament camera`
so the two can never disagree. Highest priority first, each a strictly weaker fallback:

| # | `reason=` | What it means | Where |
|---|---|---|---|
| 1 | `flagcarrier` | Someone is carrying a flag, and is alive — a carrier who just died stays recorded until the flag drops, so liveness is checked, not just the guid | `TournamentCommands.cpp:1112`, via the base virtual `BattleGround::GetFlagCarrierGuid` (`src/game/Battlegrounds/BattleGround.h:299`, empty guid by default, so flagless battleground types fall through correctly) |
| 2 | `combat` | Centroid of the largest cluster of players in combat within 40 yards of one another — not a global centroid, which in a two-sided fight points at the empty middle of the map | `TournamentCommands.cpp:1169` |
| 3 | `centroid` | Everyone alive, when nothing is happening | `TournamentCommands.cpp:1192` |
| 4 | `empty` | Nobody alive | `TournamentCommands.cpp:1064` |

`reason=` is on every emitted line, so a director — or an overlay — knows how much to
trust the framing without inspecting the match.

Both commands were exercised live on `tortoise-cm:20260818-4` on 2026-08-18 with no
tournament instance created, and both refused correctly rather than crashing or going
silent:

```
mangos>TOURNAMENT poi error=no_such_instance
mangos>TOURNAMENT camera error=spectator_not_online(Astral)
```

**A whole match at `reason=centroid` is a finding for `docs/playerbots/BG-AI-ANALYSIS.md`
(artifacts 036/037; not yet written), not a camera bug.** It means the bots never fought:
the camera correctly reported that there was no fight to point at. The same rule already
governs `tournament run` (`docs/backlog/025-tournament-run-driver.md:117`). Do not "fix"
the camera in response to it.

### 2.2 What the director does with that

`spectate.sh` polls `tournament camera` on `--interval` (default 15s) and prints **one
line per cut**, not per poll — a framing change is the only thing in eighty polls worth a
human's attention. It stops on `error=no_such_instance`, because a finished battleground
is destroyed and the instance going away *is* the end of the match. Its last line on every
path is `SPECTATE instance=… spectator=… repositions=<n>`, counting `moved=1` replies
only.

Its `--max-minutes` budget (default 25) is only a backstop, because a WSG or AB match on
this fork is hard-capped at 20 minutes: `m_StartTime > 20 * MINUTE * IN_MILLISECONDS` →
`EndBattleGround(GetWinningTeam())` at
`src/game/Battlegrounds/BattleGround.cpp:333-338`. *(Line correction: `spectate.sh`'s
header and artifact 039's commit message cite `BattleGround.cpp:317-323` for this cap. In
this tree that range is the unrelated empty-instance hold timer that keeps a
console-created instance alive on its first tick; the 20-minute cap is at `:333-338`.)*

> **Unfilled human measurement — observed cut cadence.** Whether the cadence at
> `--interval 15` is watchable or jarring is a judgement about something on a screen, and
> nobody has watched a match yet. It is deliberately left blank rather than guessed at.
> To fill it: run one full match with `spectate.sh --spectator <GM> --instance <id>`, watch
> the client, and record here how many cuts happened, what the longest gap between cuts
> was, and whether the jumps were disorienting. `repositions=<n>` on the final SPECTATE
> line and the timestamps on the `camera now following:` lines give the numeric half
> automatically; only the "was it watchable" half needs eyes.

---

## 3. Multiboxing: how many clients does this host support?

### 3.1 Measured, stack down

Taken **2026-08-18 15:11 UTC**, from inside the WSL2 VM, with the Docker stack **not
running** (`docker ps` empty; `docker stats --no-stream` printed nothing). Docker on this
host was left at a deliberate fresh slate on 2026-08-16, and the images present are the
backlog drain's batch images plus the rollback anchor `tortoise-cm:c06b2fb`.

| Measure | Value | Source |
|---|---|---|
| `nproc` | **16** | inside WSL2 |
| `MemTotal` | **24608408 kB ≈ 23.5 GiB** | `/proc/meminfo` |
| `MemAvailable` | **23235680 kB ≈ 22.2 GiB** | `/proc/meminfo` |
| `SwapTotal` / `SwapFree` | 6291456 kB / 6284620 kB | `/proc/meminfo` |
| Kernel | `6.18.33.2-microsoft-standard-WSL2` | `uname -a` |
| Docker images | 9 (8 × `tortoise-cm` @ 2.3 GB, `mariadb:10.6` @ 440 MB), 17.91 GB total | `docker system df` |

This matches `docs/DOCKER.md:46-47`, which records the WSL2 VM at **16 CPU / 24 GB** via
`C:\Users\mihov\.wslconfig`.

That allocation is the ceiling for the *server* only. Game clients run on **Windows**,
outside this VM, so the numbers that decide the multiboxing question are the Windows ones.
Measured the same day, from PowerShell, with the stack up:

| Measure | Value | Source |
|---|---|---|
| Physical RAM | **33395494912 B ≈ 31.1 GiB** | `(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory` |
| Logical processors | **24** | `(Get-CimInstance Win32_Processor).NumberOfLogicalProcessors` |
| Total visible / free physical memory | 32612788 kB / **9671728 kB ≈ 9.2 GiB free** | `Get-CimInstance Win32_OperatingSystem` |

So: 31.1 GiB physical, of which the WSL2 VM holds 23.5 GiB, leaving roughly **9 GiB free
on the Windows side for clients** while the server is running — and 24 logical processors
against the VM's 16, which are shared, not additional.

### 3.2 Measured, stack up, world loaded, 998 bots

Same day, stack brought up on `TW_IMAGE=tortoise-cm:20260818-4` (`docker compose --env-file
<main>/.env up -d` from WSL — the bind mounts in `.env` are WSL paths, so bringing the
stack up from Git Bash silently mounts empty directories and mangosd restart-loops on
`Could not find configuration file /opt/turtle/etc/mangosd.conf`).

World fully loaded, **998 bots online** and running their AI — confirmed against the
database, not assumed: `SELECT COUNT(*) FROM tw_char.characters WHERE online=1` returned
`998` at 15:21 UTC. The world is configured for 1000
(`AiPlayerbot.MinRandomBots`/`MaxRandomBots = 1000`, `RandomBotAutologin = 1`, in
`/home/deck/tortoise-wow-server-V2/etc/aiplayerbot.conf:18,78-79`). No human player was
logged in, and no match was running.

Three `docker stats --no-stream` samples, 45 s apart, 15:19–15:21 UTC:

| Container | Image | CPU | Memory |
|---|---|---|---|
| `tcm-mangosd` | `tortoise-cm:20260818-4` | 170.9% / 178.4% / 172.2% | 5.633 / 5.639 / 5.659 GiB of 23.47 GiB (≈24%) |
| `tcm-db` | `mariadb:10.6` | 6.3% / 10.7% / 4.7% | ≈356 MiB (1.48%) |
| `tcm-realmd` | `tortoise-cm:20260818-4` | ≈0.5% | ≈28 MiB (0.12%) |

`free -m` inside the VM at the same moments: `total 24031, used ~7060, available ~16960`.

Read that CPU column carefully: `docker stats` reports percent-of-one-core, so **172% is
about 1.7 of the VM's 16 cores** — roughly 11% of the machine. A thousand bots, a full
world, and the database together leave ~14 cores and ~16.9 GiB idle inside the VM.

### 3.3 Which side is the constraint

**The clients are. The server is not.**

`tcm-mangosd` is one process, and the bots inside it cost it a `Player`, an AI, and a
socketless `WorldSession` each (§1) — no renderer, no GPU work, no video memory, and no
per-bot process. Its footprint above is what the *whole* world costs, all thousand bots
included. Adding a twenty-first bot to a match costs a fraction of a percent of that.

Every additional **client**, by contrast, is a full game process with its own renderer:
its own address space, its own GPU context and video memory, its own draw calls, and — if
it is being captured — its own encoder load in OBS on top. The server does not get more
expensive when you add a camera; the desktop does.

> **Unfilled human measurement — the with-a-client delta.** The plan asks for a before/
> after comparison with a real game client logged in and watching a live match. There is
> no way to start, log in, or observe a game client from an unattended agent on this host,
> so this row is blank rather than estimated. **Do not fill it with a guess.**
>
> To fill it, with the stack up and a match running:
>
> ```bash
> # 1. Before, from WSL — the VM side (server only):
> free -h; nproc; docker stats --no-stream
> # 2. Then, on Windows, in Task Manager / PowerShell — the host side, which is
> #    where the client actually lives:
> #    Get-Process -Name WoW | Select-Object Name,WS,CPU
> # 3. Log in one client as the GM, .appear into the match, and repeat 1 and 2.
> # 4. Repeat with a second client logged in, and a third.
> ```
>
> Record working-set MB per client and total host memory pressure at each step. The number
> that matters is the **Windows** one; `docker stats` will barely move, and that is itself
> the finding.

**The supported answer today is one client.**

That is a statement about evidence, not a hard limit. The measured budget a client has to
fit into is the ~9 GiB of Windows-side physical memory free with the stack up (§3.1), plus
whatever GPU headroom the desktop has — and the per-client cost on this host **has not
been measured**, because it cannot be measured unattended. One client is what
`spectate.sh` drives, one is what a single-camera broadcast needs, and one is the only
count anything here has evidence for. Anyone who wants two should run the measurement in
the box above *first*, rather than reason from the 16 CPU / 24 GB in §3.1: those are the
VM's resources, and a second client spends resources that number does not describe.

---

## 4. Recommended path

1. **Now — one client, driven by `spectate.sh`.** A GM account at `rank=4` (§5), the
   in-game setup below, `spectate.sh` cutting between points of interest for the length of
   one match, and OBS capturing that client's window. Nothing else in the stack changes.
2. **Next — an overlay, not a camera.** Score, team names, and who is carrying are already
   emitted as parseable lines: `tournament poi` (`subject=`, `reason=`, `players=`),
   `tournament result` (`TournamentCommands.cpp:570`, consumed by
   `scripts/tournament/match-run.sh:360`), and the telemetry CSV from artifact 027. An
   overlay fed by those adds most of what a viewer is missing and needs no new server code
   and no client code at all. It is also the only item here that can be developed and
   tested unattended.
3. **Later, and only if the cuts prove too jarring — a client-side addon.** That is real
   client development, cannot be validated by this repo's tooling, and should not be
   started until someone has watched a real match and judged the cuts *specifically*
   (§2.2). Building it before that is building for a problem nobody has confirmed exists.

---

## 5. Setup checklist

Once per spectator account, before the first match:

- [ ] **GM account at `rank=4`.** `rank=3` is refused. `SEC_GAMEMASTER` is `#define`d to
      `SEC_ADMINISTRATOR` (`src/modules/PlayerBots/cmangos-compat-shim.h:640`) and
      `SEC_ADMINISTRATOR = 4` (`src/shared/Common.h:190`). Both `.hover`
      (`src/game/Chat/Chat.cpp:926`) and `.bgtest` (`Chat.cpp:964`) are registered at
      `SEC_ADMINISTRATOR`, so at `rank=3` they simply do not exist for that session.
- [ ] **Never party the spectator to a bot.** `HasActivePlayerMaster()`
      (`src/modules/PlayerBots/playerbot/PlayerbotAI.h:640` — `master && !master->GetPlayerbotAI()`)
      is a hard gate in the bot's queue logic at
      `src/modules/PlayerBots/playerbot/strategy/actions/BattleGroundJoinAction.cpp:635`:
      a bot with a real-player master returns `false` and **never queues again**. Inviting
      the camera to a party is how you quietly remove a bot from the tournament.
      *(Line correction: earlier documents — `docs/backlog/038`, `039`, and the header of
      `spectate.sh` — cite `BattleGroundJoinAction.cpp:568` for this gate. In this tree it
      is at `:635`; line 568 is unrelated bot-count arithmetic. The gate itself is exactly
      as described.)*
- [ ] **The spectator must not be a match participant.** `tournament camera` refuses one
      outright with `error=spectator_is_a_match_participant(<name>)`
      (`TournamentCommands.cpp:1288`), because enrolling the camera would make the match
      11v10 and change its outcome. A player `tournament add` has already invited but whose
      port has not landed yet is refused the same way, with
      `error=spectator_is_invited_to_the_match(<name>)` — they are not in `m_Players` yet,
      but the world-port ack will enrol them on arrival. Both are permanent facts about that
      character for the length of the match: the answer is a different character, not a
      workaround.
- [ ] **`error=spectator_teleporting(<name>)` is not one of those — it is transient.** A
      player already mid-teleport is refused because `TeleportTo` would silently drop the
      second destination. The camera *is* a teleport, so the commonest way to see this is a
      cut issued while the spectator is still on the loading screen from the previous cut,
      and it clears itself the instant the world-port ack lands. Retry; do not change
      character. `spectate.sh` already does — it treats this token as non-fatal, says so once
      per streak, and keeps polling until either a cut lands or the `--max-minutes` budget
      runs out.
- [ ] **`.appear` into a battleground is supported.** `.appear` is `HandleGonameCommand`
      (`src/game/Chat/Chat.cpp:892`, `SEC_OBSERVER`), and its battleground branch
      (`src/game/Commands/Commands.cpp:7018-7032`) sets the caller's battleground id and
      adds `TELE_TO_FORCE_MAP_CHANGE`. It fails on exactly one condition: the caller is
      already inside a **different** battleground
      (`Commands.cpp:7020-7025`, `LANG_CANNOT_GO_TO_BG_FROM_BG`). Being outside any
      battleground is fine. `tournament camera` does the same thing for the same reason
      (`TournamentCommands.cpp:1329-1351`), which is why it lands rather than silently
      doing nothing.

Then, at the keyboard, before starting the director:

```
.gm on
.gm visible off      (Chat.cpp:215 — SEC_MODERATOR)
.hover 1             (Chat.cpp:926 — SEC_ADMINISTRATOR, hence rank=4)
.god on              (Chat.cpp:884 — SEC_DEVELOPER)
```

…and then, **with the mouse: pitch the view downward and zoom out.** That step is not
optional and nothing server-side can do it (§2).

Finally, from WSL (`jq` is not on Git Bash's PATH on this host):

```bash
./scripts/tournament/spectate.sh --spectator <GMName> --instance <id>
```

---

## 6. Related

| Document | What it covers |
|---|---|
| `docs/playerbots/TOURNAMENT-CONTROL-PLANE.md` | The `.tournament` command family and why it is console-callable |
| `docs/playerbots/BG-AI-ANALYSIS.md` | Where a match spent entirely at `reason=centroid` gets reported. **Does not exist yet** on this branch — artifacts 036 and 037 create it |
| `docs/DOCKER.md` | This host's WSL2 allocation and the stack's build/runtime shape |
| `scripts/tournament/spectate.sh` | The director loop, and the in-game setup in its header |
