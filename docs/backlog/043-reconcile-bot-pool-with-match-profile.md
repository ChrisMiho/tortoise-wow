---
status: done
risk: medium
area: playerbots/config
depends-on: 025-tournament-run-driver.md
---

# Raising the bot-pool default changes what the match profile restores

**Problem:** `docs/playerbots/wsg/wsg-mode.sh on` shrinks the bot pool to
`MinRandomBots = MaxRandomBots = 40` **because bot AI is single-core**, and `off`
restores it. Two things are now wrong with that. Raising the compiled default to
1000 changes what gets snapshotted and restored, and a restore that silently
reinstates 1000 bots mid-tournament would be a surprise nobody asked for —
`WSG-BOT-MATCH.md` §9 documents a `--profile alive-world` fallback for when no
snapshot exists, which implies a hardcoded value somewhere that is now stale.

And 40 is no longer the target anyway. **The operating decision is that only the
20 bots playing the current match are online; every other character, including
the entire random pool, is offline.** A tournament profile that leaves 40 random
bots thinking is 40 bots of single-core AI competing with the match nobody
wanted running.

**Suspected cause / area:** `docs/playerbots/wsg/wsg-mode.sh`, plus
`docs/playerbots/TOURNAMENT-RUNNING.md`. Implements
`docs/superpowers/plans/2026-08-16-09-release-tag-and-1000-bot-standup.md` Task 3.

**Acceptance criteria:**

- What `wsg-mode.sh on` actually does is established by reading it and written
  down: whether it snapshots the *current* values or writes a hardcoded
  `alive-world` profile, and where the fallback value lives if both paths exist.
- If a hardcoded fallback value is now inconsistent with the shipped
  `aiplayerbot.conf.dist.in` (1000/1000), it is either corrected to match or made
  to read the shipped conf — and the choice is justified in a comment.
- **A tournament profile that takes the random pool to zero exists** — whether by
  extending `wsg-mode.sh` (e.g. `on --tournament`) or by a documented conf
  setting — so that only the 20 bots playing the current match are online. If
  `MinRandomBots = MaxRandomBots = 0` turns out not to be a legal value for this
  build, record what the lowest workable value actually is and say so rather than
  quietly leaving it at 40.
- **`rndbot add <name>` must still work with the pool at zero.** The tournament
  characters are logged in explicitly by `roster.sh login`, not by the random
  pool's auto-login, so the two should be independent — but that is an assumption
  about this build, not a documented guarantee, and the whole design collapses if
  a zero pool also refuses explicit adds. Verify it before writing it down.
- `bash -n docs/playerbots/wsg/wsg-mode.sh` exits 0.
- `docs/playerbots/TOURNAMENT-RUNNING.md` gains a section stating: the
  alive-world pool defaults to 1000; a tournament runs with it at **zero**, so
  the only characters online are the 20 playing plus a GM spectator; that this is
  a CPU decision, not a memory one — **bot AI is single-core**, while memory at
  1000 bots is comfortable at 4.27 GiB measured, so a degraded match means the
  scheduler, not RSS; that `tournament-run.sh` does **not** manage the pool, so
  setting it before and restoring it after are operator steps; and that
  `wsg-mode.sh status` confirms the restore — a world left at zero looks like a
  healthy server that is mysteriously empty.

**Notes:**

- This artifact edits `docs/playerbots/TOURNAMENT-RUNNING.md`, which artifact 025
  creates — that is the dependency. Artifact 042 (the compiled fallbacks) is the
  change this reconciles with, but it edits a different file, so it is not in this
  chain; treat 1000/1000/500 as the intended values regardless of whether 042 has
  landed on this branch.
- **The round-trip check needs a live conf and cannot be done here.** It reads and
  rewrites the bind-mounted `~/tortoise-wow-server-V2/etc/aiplayerbot.conf`, which
  is not version-controlled. Verify by reading the script, not by running it
  against a real conf, and leave the round-trip as an operator step.
- **Verification needing a live stack (not part of these criteria):**
  `wsg-mode.sh status`, then note the conf's `(Min|Max)RandomBots`, then
  `wsg-mode.sh on` (expect 40), then `wsg-mode.sh off`, and confirm it restores
  **exactly what was there before `on`** — not a hardcoded value. Run it from WSL,
  never Git Bash.
- `PlayerSave.Interval` is 60 s, so online counts lag reality by up to a minute
  when checking whether a pool change took effect.

**Base:** backlog/tournament-run-driver

**Branch:** backlog/reconcile-bot-pool-with-match-profile

**Summary:** Two files changed on `docs/playerbots/wsg/wsg-mode.sh` and `docs/playerbots/TOURNAMENT-RUNNING.md`, one commit (3e3c0c9). `wsg-mode.sh` gains `on --tournament`, which writes `AiPlayerbot.MinRandomBots = MaxRandomBots = 0` instead of 40 (in-game: nothing but the twenty match bots and a GM is in the world; technical: `POOL_SIZE` now feeds the two `wsg_ensure_conf_key` calls), refuses on any verb but `on`, and skips `wsg-roster.sh ensure` because those WSG demo characters are not the tournament roster and `match-run.sh`'s population gate (`MATCH_GM_ALLOWANCE=1`) would refuse to start on them. Zero was checked in the source before it was written down: `RandomPlayerbotMgr::UpdateAIInternal` draws its target from `urand(min,max)` and only logs bots in while `availableBotCount < maxAllowedBotCount` (RandomPlayerbotMgr.cpp:671-703), nothing logs an already-online bot out for exceeding the target (the only lever is `RandomBotTimedLogout`, :2316, which the profile pins to 0), and `AddRandomBot()` never reads the pool size at all (:2232-2291) — so `rndbot add` is independent of it. That was then confirmed live: db + mangosd brought up on `tortoise-cm:20260818-5` with the live conf at 0/0, world up in 47 s with **0 characters online**, `rndbot add Silena` put exactly one character online, still online 90 s later, `rndbot remove` took it out; the live conf was restored to 1000/1000 from a backup and the stack stopped again. The second fix is the no-snapshot fallback `off --profile alive-world`, which hardcoded `MinRandomBots=MaxRandomBots=200` and `DisableActivityPriorities=0` against a shipped `aiplayerbot.conf.dist.in` of 1000/1000 and 1 — it now reads every key out of the shipped `aiplayerbot.conf.dist.in` / `mangosd.conf.dist.in` via a new `dist_default()` (literals kept only as a last resort for a host with no source tree, justified in comment), verified end-to-end against a stubbed fake server root: it restores 1000/1000 and re-comments `AutoDoQuests`. A full `on --tournament` → `status` → `off` round trip against the same fake root snapshots 1000/1000, shows 0/0, and restores 1000/1000. `bash -n docs/playerbots/wsg/wsg-mode.sh` exits 0. `TOURNAMENT-RUNNING.md`'s "Only twenty bots are online" section is rewritten to state that `on` snapshots rather than hardcodes, where the one hardcoded profile lives, that the alive world ships at 1000 and a tournament runs at zero, that this is a CPU decision (single-core bot AI) not a memory one (4.27 GiB at 1000 bots), that `tournament-run.sh` manages neither the shrink nor the restore, and that `wsg-mode.sh status` is how you catch a world left at zero.

**In-game check:** Most of this was already exercised live on 2026-08-18 against tortoise-cm:20260818-5 (see below for what was actually run), so what remains is the round trip against the real bind-mounted conf, which the artifact itself leaves as an operator step. Run everything from WSL, never Git Bash.

Scriptable — no human has to look:
1. `docs/playerbots/wsg/wsg-mode.sh status` and note the two numbers it prints for `AiPlayerbot.MinRandomBots` / `MaxRandomBots` (on this host today: 1000 / 1000). Also note whether it says `MODE: alive-world` or `MODE: wsg-match` — there is a stale `.wsg-mode-snapshot.json` dated 2026-08-11 sitting in `~/tortoise-wow-server-V2/`, so on this host it currently says `wsg-match` on an alive-world conf and `on` will refuse until that file is moved aside.
2. `wsg-mode.sh on --tournament`. Expect the line `WSG match mode ON (tournament profile: random pool 0/0 ...)`, no `wsg-roster.sh ensure` run, and `grep RandomBots ~/tortoise-wow-server-V2/etc/aiplayerbot.conf` reading `0` for both keys.
3. After it restarts mangosd, `docker logs tcm-mangosd | grep "World server is up"` — it should appear in well under a minute (measured 47 s at 0/0, versus the multi-minute 1000-bot login storm), and `SELECT COUNT(*) FROM tw_char.characters WHERE online=1;` should read **0**. A non-zero count here is the failure: the pool refilled.
4. `rndbot add <one of the tournament roster names>` through `wsg_console`, wait ~5 s, then `SELECT name, online FROM tw_char.characters WHERE name='<that name>';` — expect `online = 1`. Wait 90 s and re-read it: still 1, and the total online count still 1. This is the criterion that matters; a zero pool that also refuses explicit adds would break the whole tournament design.
5. `wsg-mode.sh off`, then `wsg-mode.sh status` — the two pool numbers must be **exactly** what step 1 printed (1000/1000), not 40 and not 200. That is the restore check, and it is the one that catches a world left mysteriously empty.
6. Fallback path, with no snapshot present: `wsg-mode.sh off --profile alive-world` must print `no snapshot — applying the shipped alive-world profile` followed by `pool 1000/1000 (from .../aiplayerbot.conf.dist.in)`. If it ever prints 200 again, the dist file is not being found and the literal is being used.

Needs a human in the world (one match, ~25 min):
7. With the tournament profile on and a bracket running, log a GM in and `.appear` to a bot mid-match: the only characters anywhere in the world should be the twenty in the Warsong Gulch instance. Fly over Stormwind or Orgrimmar and confirm the cities are empty — no random bots questing, grinding or running the roads. A populated city with the pool at 0/0 means the conf change did not take (the pool is read at boot, so the usual cause is skipping the restart).
8. Watch one full 20-minute match and confirm the bots behave — flag runs, combat, a score — rather than moving in visible stutters. That is the whole point of the zero pool: no other bot AI is competing for the single core.

Already done, for reference: db + mangosd were brought up on tortoise-cm:20260818-5 with the live conf hand-set to 0/0; the world came up in 47 s with 0 characters online; `rndbot add Silena` put exactly one character online; it was still online after 90 s; `rndbot remove Silena` logged it out; the conf was restored to 1000/1000 from `~/tortoise-wow-server-V2/backups/aiplayerbot.conf.pre043` and the stack stopped. Steps 2, 5 and 6 were also run end-to-end against a fake `WSG_SERVER_ROOT` with docker stubbed, which is what proves the snapshot round trip; they have not been run against the real bind-mounted conf.

**Minor findings:**
- docs/playerbots/wsg/wsg-mode.sh: The no-snapshot fallback prints "pool 1000/1000 (from <DIST_AICONF>)" unconditionally, so on a server host where the script was copied without the source tree — the exact case the literals exist for — it names a file it never read and attributes hardcoded values to it.
- docs/playerbots/wsg/wsg-mode.sh: The new header comment says "the compiled pool default moved from 200 to 1000 (aiplayerbot.conf.dist.in:57-58)", but the .dist.in has shipped 1000 all along (per artifact 042); what moved was PlayerbotAIConfig.cpp:250's compiled fallback, and the stale 200 was this script's own literal, so the comment points a future maintainer at the wrong file for the history.

**Drain note (this tick VERIFIED its load-bearing assumption live, which the artifact explicitly demanded):** the artifact required that `rndbot add` still work with the random pool at zero, and said plainly that this was "an assumption about this build, not a documented guarantee, and the whole design collapses if a zero pool also refuses explicit adds. Verify it before writing it down." The tick did exactly that rather than reasoning about it: db + mangosd up on tortoise-cm:20260818-5 with the live conf at 0/0, world up in 47s with 0 characters online, `rndbot add Silena` produced exactly one character online, still online 90s later, `rndbot remove` took it out; the live conf was then restored to 1000/1000 from a backup and the stack stopped. That is the correct discipline for a criterion phrased as an assumption.

**Drain note (no contradiction with artifact 042 — they are complementary, and finding 2 is right about which is which):** the drain flagged before this tick that 042 (raising compiled fallbacks to 1000/1000/500) and this artifact (taking the pool to zero for a match) might pull in opposite directions. They do not. 042 fixed the COMPILED fallback in PlayerbotAIConfig.cpp, which applies when a conf omits the key; this fixes wsg-mode.sh's own hardcoded no-snapshot literal, which was 200. After both, every layer agrees on the alive-world value of 1000/1000, and zero is an explicit operator-selected tournament profile rather than a default. Finding 2 is correct that the new header comment misattributes the history: it says "the compiled pool default moved from 200 to 1000 (aiplayerbot.conf.dist.in:57-58)", but the drain verified independently on artifact 042 that .dist.in has shipped 1000/1000/500 at :57/:58/:64 all along -- what moved from 200 to 1000 was PlayerbotAIConfig.cpp:250, and the other stale 200 was this script's own literal. The comment sends a future maintainer to the wrong file.

**Drain note (finding 1 is real and worth fixing before anyone copies this script to a server host):** the no-snapshot fallback prints "pool 1000/1000 (from <DIST_AICONF>)" unconditionally, including on the one host shape the literals exist to serve -- a machine with the script but no source tree. There it names a file it never read and attributes hardcoded numbers to it, which is precisely the case where a reader most needs to know the value came from a literal. Print the provenance conditionally.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/53, build tortoise-cm:20260818-6.
