# Continue later — alive world

Use this when you want snappier loads or a denser world. Do **not** start here for day-to-day play; current **200** + dials is the parked baseline.

## Before you touch anything

1. Read [README.md](README.md) and [STATUS.md](STATUS.md).
2. Confirm Live dials still match STATUS (or re-apply intentionally):

```bash
MSYS_NO_PATHCONV=1 wsl -d Ubuntu -u deck -- bash /mnt/d/TurtleWow/tests/playerbot-verify.sh Usagi
```

3. Optional safety backup:

```bash
MSYS_NO_PATHCONV=1 wsl -d Ubuntu -u deck -- bash /mnt/d/TurtleWow/scripts/backup-alive-world-pre.sh
```

## Path A — faster loads (recommended first)

WSL is at **8GB** and was swapping (~1.1 Gi) with 200 bots. Host still had ~11 GB free while gaming.

From the plan Task 6 (modest expand):

1. Edit `C:\Users\mihov\.wslconfig`:

```ini
[wsl2]
memory=12GB
processors=4
```

2. Optional: InnoDB `512M` → `768M` in `/home/deck/tortoise-wow-server-V2/docker-compose.yml`.
3. `wsl --shutdown`, then `docker compose up -d` from the server dir (**never** `down -v`).
4. Keep **Min/MaxRandomBots = 200** first; re-test login speed + `free -h` / swap.
5. Only then consider Path B.

## Path B — denser than 200

Only after Path A (or if memory gates are clearly green with no swap).

| Step | Min/Max | Notes |
|---|---|---|
| Next | 250 | Re-apply activity dials if you overwrite conf |
| Then | 400 | Watch host free ≥ 4 GB, WSL available, swap |
| Stock | 1000 | `cp etc/aiplayerbot.conf.orig1000 etc/aiplayerbot.conf` then **re-apply** ForceActive / teleport / botActiveAlone lines; long login wave |

Keep `DisableActivityPriorities = 0`. Helper: [`../../scripts/task3-ramp-step.sh`](../../scripts/task3-ramp-step.sh).

Full task text: [../superpowers/plans/2026-08-09-alive-world-population.md](../superpowers/plans/2026-08-09-alive-world-population.md) Task 6+.

## Path C — undo alive-world changes

Restore the pre-flight backup (returns **50** bots, AhBot off). See [README.md](README.md) restore block.

## AhBot reminders

- Account `ahbot` / `ahbot`, char **Ahbot** guid **4512**
- Hash formula: `UPPER(SHA1('AHBOT:AHBOT'))`
- If handshaking fails again: check `logs/Realmd.log` for `wrong password`, run [`../../scripts/fix-ahbot-password.sh`](../../scripts/fix-ahbot-password.sh)
- Verify: [`../../scripts/verify-ahbot-enabled.sh`](../../scripts/verify-ahbot-enabled.sh)
