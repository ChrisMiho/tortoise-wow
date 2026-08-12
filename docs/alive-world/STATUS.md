# Alive World — session status (2026-08-09)

## Verdict

Parked as **good enough**. Local reports ~**201** players in `/who` with activity dials + AhBot. Optional follow-ups are about **load time / WSL RAM**, not about “world feels empty.”

## What we changed (ops only — no C++ rebuild)

1. **Activity dials at 50** then kept through the ramp  
   - `ForceActiveWhenNearPlayer = 1`  
   - `botActiveAlone = 25`  
   - `RandomBotTeleportNearPlayer = 1` (12 @ 40 yd)  
   - `DisableActivityPriorities = 0`  
   - `LFT.BotFill.DelaySeconds = 45`
2. **Staged online count:** 50 → 100 → 150 → **200** (soft ceiling without WSL expand)
3. **AhBot** enabled with character **Ahbot** guid **4512** on account `AHBOT` / `ahbot` (id 507)
4. **WSL / InnoDB left at 8GB / 512M** on purpose (host had ~10GB free while gaming)

## Friend vs Local mystery (closed)

| Host | Min/Max | Explanation |
|---|---|---|
| Friend / stock pack | 1000 / 1000 | Pack design |
| Local after Windows setup | 50 / 50 | Intentional first-boot shrink; backup `aiplayerbot.conf.orig1000` |
| Local after this work | **200 / 200** | Activity-first compromise |

Diff of live vs `orig1000` at the start of the work was **only** those two Min/Max lines.

## Memory / gate table (Task 3)

| Online target | Host free | WSL available | mangosd MEM | online RNDBOT | Gate |
|---|---|---|---|---|---|
| Baseline (~50, pre-dials) | 11404 MB | 2.8–3.1 Gi | 4.34–4.74 GiB | 50 | — |
| 50 + activity | 11387 MB | 3.2 Gi | 3.77 GiB (fresh restart) | 50 | PASS |
| 100 | 11675 MB | 3.1 Gi | 4.21 GiB | 119 | PASS |
| 150 | 11585 MB | 3.1 Gi | 4.17 GiB | 149 | PASS |
| 200 | 11564 MB | 3.0 Gi | 4.34 GiB | 209 | PASS |

Hard stop gates used: host free ≥ 4 GB; WSL available ≥ 800 MB; no docker OOM/restarts; playable client.

### Feel-test memory (later same day)

- `/who` **201**; online RNDBOT ~199  
- Host free ~**11.1 GB**  
- WSL: available **2.4 Gi**, **swap ~1.1 Gi used**, mangosd **~4.67 GiB** @ ~112% CPU  
- Slow character load attributed to **WSL 8GB swap**, not to needing more bots

## AhBot notes

- Password must be stored as `UPPER(SHA1('AHBOT:AHBOT'))` (WoW `UPPER:UPPER`). Creating with `AHBOT:ahbot` caused “handshaking” / wrong password in `Realmd.log`.
- Fix script: [`../../scripts/fix-ahbot-password.sh`](../../scripts/fix-ahbot-password.sh)
- Never set `AhBot.Enabled = 1` with `GUID = 0` (pack warns of crash).
- Character name was **Ahbot**, not plan’s `AuctioneerBot` — GUID is what matters.
- Stay logged out of `ahbot` while the bot runs; play as `player`.

## Pre-flight backup

Taken before execution:

- WSL: `/home/deck/tortoise-wow-server-V2/backups/pre-alive-world-20260809-110537/`
- Windows mirror: `D:\TurtleWow\backups\pre-alive-world-20260809-110537\` (gitignored)

Also: live `etc/aiplayerbot.conf.bak-alive-20260809`, `etc/ahbot.conf.bak-task4-*`.

## Git commits from this workstream (local `main`)

Useful landmarks (newest last in session):

- `2495dff` docs: plan activity-first population within current RAM  
- `f5f32b4` test: snapshot alive dials and memory before bot ramp  
- `14ba309` chore: gitignore local config backups directory  
- `b54c58e` docs: record staged bot ramp memory gates  
- `8b51a81` docs: record AhBot account ready; character create blocked  
- `9dbee7f` docs: enable AhBot on character Ahbot guid 4512  
- `1a89f2e` docs: record feel-test 201 online and WSL swap on load  

Plus this wrap-up commit under `docs/alive-world/`.

## Out of scope / not done

- Task 6 WSL → 12GB / InnoDB → 768M (deferred)  
- Restoring `orig1000` / pushing past 200  
- Fake realmlist population spoof  
- LLM bot chat  
- CreateBot cache orphan loop (separate handoff stream; verify script may still exit 1 on orphan guids)
