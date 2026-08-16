---
status: pending
risk: medium
area: playerbots/config
depends-on: 025-tournament-run-driver.md
---

# Raising the bot-pool default changes what the match profile restores

**Problem:** `docs/playerbots/wsg/wsg-mode.sh on` deliberately shrinks the bot
pool to `MinRandomBots = MaxRandomBots = 40` **because bot AI is single-core**,
and `off` restores it. Raising the compiled default to 1000 changes what gets
snapshotted and restored — and a restore that silently reinstates 1000 bots
mid-tournament would be a surprise nobody asked for. `WSG-BOT-MATCH.md` §9
documents a `--profile alive-world` fallback for when no snapshot exists, which
implies there is a hardcoded value somewhere that is now wrong.

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
- `bash -n docs/playerbots/wsg/wsg-mode.sh` exits 0.
- `docs/playerbots/TOURNAMENT-RUNNING.md` gains a section stating: the alive-world
  pool defaults to 1000; `wsg-mode.sh on` drops it to 40 for the duration of a
  match on purpose, because **bot AI is single-core** and 1000 bots thinking while
  20 more play a battleground is a CPU contention problem, not a memory one
  (memory at 1000 is comfortable — 4.27 GiB measured — so if a match degrades,
  suspect the scheduler, not RSS); that `tournament-run.sh` does **not** manage
  the pool, so `wsg-mode.sh on` before and `off` after are operator steps; and
  that `wsg-mode.sh status` should be used to confirm the pool was actually
  restored — a match left with the pool at 40 looks like a healthy server with a
  mysteriously empty world.

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
