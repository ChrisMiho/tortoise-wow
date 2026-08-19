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
