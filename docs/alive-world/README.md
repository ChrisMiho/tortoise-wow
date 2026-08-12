# Alive World Population — parked for later

**Status (2026-08-09):** Good enough for now. Local feels populated at **~200** online bots. Revisit later for snappier loads (WSL RAM) or denser worlds (toward stock 1000).

This folder is the durable wrap-up of the research + ops work. Start here when you come back.

## Current Live settings (do not “fix” blindly)

| Knob | Value | Where |
|---|---|---|
| `Min/MaxRandomBots` | **200 / 200** | WSL `~/tortoise-wow-server-V2/etc/aiplayerbot.conf` |
| `ForceActiveWhenNearPlayer` | **1** | same |
| `botActiveAlone` | **25** | same |
| `RandomBotTeleportNearPlayer` | **1** (max **12**, radius **40**) | same |
| `DisableActivityPriorities` | **0** | same — keep at scale |
| `LFT.BotFill.DelaySeconds` | **45** | `etc/mangosd.conf` |
| AhBot | **On**, GUID **4512** (char **Ahbot**) | `etc/ahbot.conf` |
| WSL RAM / CPUs | **8GB / 4** (unchanged) | `C:\Users\mihov\.wslconfig` |
| InnoDB buffer | **512M** (unchanged) | `docker-compose.yml` |

Feel-test: `/who` ≈ **201**. Login/world load a bit slow — WSL was using ~**1.1 Gi swap** with mangosd ~**4.7 GiB**. Host still had ~11 GB free.

## Why a friend’s pack looked denser

Local Windows setup **intentionally** dropped bots **1000 → 50** for a fast first boot (`WINDOWS-SETUP-HANDOFF` Phase 6). Stock / friend stays at **1000**. Nothing else was “broken.”

We did **not** restore full 1000. Activity-first + **200** online was enough for now.

## Docs in this folder

| File | Role |
|---|---|
| [STATUS.md](STATUS.md) | Outcomes, memory table, AhBot notes, deferred next steps |
| [CONTINUE-LATER.md](CONTINUE-LATER.md) | Checklist when you resume (Task 6 WSL expand, or denser counts) |

## Related repo paths

| Path | Role |
|---|---|
| [../superpowers/plans/2026-08-09-alive-world-population.md](../superpowers/plans/2026-08-09-alive-world-population.md) | Full implementation plan (Tasks 1–6) |
| [../../WINDOWS-SETUP-HANDOFF.md](../../WINDOWS-SETUP-HANDOFF.md) §0 | Live topology + session notes |
| [../../tests/playerbot-verify.sh](../../tests/playerbot-verify.sh) | Read-only health (alive dials + memory) |
| [../../scripts/backup-alive-world-pre.sh](../../scripts/backup-alive-world-pre.sh) | Config backup helper |
| [../../scripts/task3-ramp-step.sh](../../scripts/task3-ramp-step.sh) | One staged Min/Max bump + gates |
| [../../scripts/wait-rndbots-online.sh](../../scripts/wait-rndbots-online.sh) | Wait for online RNDBOT count |
| [../../scripts/verify-ahbot-enabled.sh](../../scripts/verify-ahbot-enabled.sh) | Confirm AhBot conf + activity |
| [../../scripts/fix-ahbot-password.sh](../../scripts/fix-ahbot-password.sh) | WoW hash = `SHA1(UPPER:UPPER)` |

## Pre-flight config backup (pre-change snapshot)

| Location | Path |
|---|---|
| WSL | `/home/deck/tortoise-wow-server-V2/backups/pre-alive-world-20260809-110537/` |
| Windows | `D:\TurtleWow\backups\pre-alive-world-20260809-110537\` (`backups/` is gitignored — keep the Windows mirror) |

Restore only if you want to undo alive-world conf changes (returns Min/Max to **50**, AhBot off, LFT delay 90):

```bash
cd /home/deck/tortoise-wow-server-V2
B=backups/pre-alive-world-20260809-110537
cp -a "$B/aiplayerbot.conf" "$B/ahbot.conf" "$B/mangosd.conf" "$B/realmd.conf" etc/
cp -a "$B/docker-compose.yml" .
docker compose restart mangosd
```

## Hard rules (still in force)

- Never `docker compose down -v`
- Never enable `AhBot.GUID = 0`
- Keep `DisableActivityPriorities = 0` at 200+ bots
- Do not log in as `ahbot` while AhBot is running (use `player` / Usagi)
- Live configs live under WSL `~/tortoise-wow-server-V2/etc/`, not `D:\TurtleWow\extracted\...`
