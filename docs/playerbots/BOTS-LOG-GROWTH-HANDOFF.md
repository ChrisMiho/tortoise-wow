# `bots.log` Runaway Growth — Handoff (2026-08-10)

**Applies to:** any TurtleWoW V2 server running the PlayerBots module (`src/modules/PlayerBots`).
Nothing here is specific to this machine except §7, which is marked Windows/WSL-only.

**One-line version:** `logs/bots.log` records the bot AI's per-tick decision trace at
`DETAIL` level and **ignores your `LogFileLevel` setting**, so it grows without bound.
Set `AiPlayerbot.BotLogFile = ""` in `etc/aiplayerbot.conf`, restart mangosd, done.

Everything below is verified against the live stack or the WSL-side source unless
marked HYPOTHESIS.

---

## 1. The numbers (measured on this box, 2026-08-10)

| Measurement | Value |
|---|---|
| `logs/bots.log` size | **12.0 GB** (12,002,649,251 bytes) |
| File created | 2026-08-09 02:56:21 — first boot of this server instance |
| Age at measurement | ~36.5 h |
| **Lifetime average** | **~7.8 GB/day** (includes idle time and restarts) |
| **Live rate, 20 WSG bots + random bots active** | **22.6 MB/min = ~32 GB/day** |
| Second live sample (228 s) | 485 KB/s = ~42 GB/day |
| Whole `logs/` directory | 12 GB — of which `bots.log` is 11.9 GB |
| Next-largest log (`loot.log`) | 5.8 MB |

The "~5 GB/day" figure from the earlier investigation is the right shape but
conservative. **The rate is proportional to bot activity, not to wall-clock time** —
an idle server barely writes, a server running a 10v10 WSG match writes ~30–40 GB/day.
Every other log in the directory is in the low megabytes. This one file is 99.9% of
the log volume.

### What is actually in it

Measured over a 50 MB tail sample (848,570 lines):

| Category | Bytes | Share |
|---|---|---|
| Action-engine trace (`A:`, `PUSH:`, `T:`, `--- AI Tick`, `no actions executed`) | 45.9 MB | **96.4%** |
| Item stat-weight scoring (`stat: int, val: 1, weight: 33, …`) | 0.7 MB | 1.5% |
| Everything else (lifecycle, errors, real events) | 1.0 MB | 2.1% |

Sample of the dominant shape — one bot, one AI tick:

```
[21:26:47] [DETAIL] Wsgaone A:demoralizing shout - PREREQ
[21:26:47] [DETAIL] Wsgaone PUSH:reach melee::{demoralizing shout::current target} - 26.020000 (prereq)
[21:26:47] [DETAIL] Wsgaone A:reach melee - USELESS
[21:26:47] [DETAIL] Wsgaone A:demoralizing shout - IMPOSSIBLE
...
[21:26:47] [DETAIL] Wsgaone no actions executed
```

That is ~40 lines per bot per tick, for every bot, forever.

---

## 2. The nuance — why `LogFileLevel` does not stop it

This is the part that makes it non-obvious. `etc/mangosd.conf` has:

```
LogLevel     = 1     # LOG_LVL_BASIC
LogFileLevel = 1     # LOG_LVL_BASIC
```

`LOG_LVL_DETAIL` is **2** (`src/shared/Log.h:38-41`). So by the server's own settings,
`DETAIL` output should be discarded. It is not, because the bot subsystem has its own
logger that never consults those settings.

The chain, all paths relative to `src/src/modules/PlayerBots/playerbot/`:

| Step | Location | What happens |
|---|---|---|
| 1 | `strategy/Engine.cpp:783` `Engine::LogAction` | Called once per action node evaluated, per bot, per AI tick |
| 2 | `strategy/Engine.cpp:810` | Only gate: `if (logInGroupOnly && !bot->GetGroup()) return;` |
| 3 | `strategy/Engine.cpp:813` | `sLog.outDetail("%s %s", bot->GetName(), buf)` — **calls `outDetail` directly, not through the `DETAIL_LOG` macro**, so the macro's level guard never runs |
| 4 | `playerbot.h:40` | `#define sLog BotLog::Instance()` — every bot translation unit is rerouted |
| 5 | `BotLog.h:43` | `bool HasLogLevelOrHigher(LogLevel) const { return true; }` — **hardcoded true**, so even code that *does* use `DETAIL_LOG` gets through |
| 6 | `BotLog.cpp:123` `BotLog::outDetail` | Writes to `m_file` whenever the file is open. It never reads `LogLevel` or `LogFileLevel` |
| 7 | `BotLog.cpp:73` (`BOTLOG_IMPL`) | `fflush(m_file)` after **every single line** — no buffering, so this is also a steady stream of tiny syscalls |

`BotLog` was added to keep bot chatter out of `server.log`. It succeeded at that, and
in the process it took the bot subsystem out from under the core logger's level
filtering entirely.

### The gate that looks like it should save you, and doesn't

`AiPlayerbot.LogInGroupOnly` (`PlayerbotAIConfig.cpp:264`) defaults to **`true`** and is
commented out in the shipped conf (line 1123), so it is already active. It suppresses
the trace for bots that are not in a group.

It gates almost nothing in practice:

- Battleground participants are in a **raid group** for the duration of the match — so
  every WSG bot logs its full trace.
- `AiPlayerbot.RandomBotGroupNearby` / `RandomBotRaidNearby` put roaming random bots
  into groups too.

Turning this knob is not the fix; it is already turned.

### Not the culprit

`AiPlayerbot.EnableActionLog` (default `0`, off here — `logs/bots/` does not exist) is a
*separate* per-bot file logger. `AiPlayerbot.BotLogDebug` (default `0`) only adds
`DEBUG` on top. Neither is why the file is 12 GB.

---

## 3. Why it goes unnoticed

- Nothing errors. Disk here still shows 940 GB free on the WSL rootfs.
- The file is bind-mounted in from the host (`./logs:/opt/turtle/logs`, `LogsDir = "../logs"`),
  so it doesn't show up as container bloat either.
- Docker's own json log driver has **no** `max-size` set in `docker-compose.yml`, so
  that's a second unbounded file — but at `LogLevel = 1` it grows slowly and is not
  the problem today. Worth capping while you're in there (§6).
- On Windows/WSL, the real cost is invisible from inside Linux: see §7.

> Existing warning in `docs/playerbots/WSG-BOT-MATCH.md:329` — **never `cat` this file.**
> Use `tail -c` if you need to look at it.

---

## 4. The fix (3 commands)

Adjust the path if your server lives somewhere other than `~/tortoise-wow-server-V2`.

### Step 1 — reclaim the space now, without restarting

```bash
sudo truncate -s 0 ~/tortoise-wow-server-V2/logs/bots.log
```

Safe on a running server: `BotLog::Initialize` opens the file with `fopen(path, "a")`
(`BotLog.cpp:35`), i.e. `O_APPEND`, so every write recomputes the offset from the end.
After truncation the next line lands at byte 0 — no sparse-file hole, no crash.

**Do not `rm` it.** mangosd holds the `FILE*` open; deleting the directory entry keeps
the inode (and all 12 GB) alive until the process exits, and new output vanishes into
the unlinked file.

### Step 2 — stop the growth permanently

Edit `etc/aiplayerbot.conf`, change line 267 from:

```
AiPlayerbot.BotLogFile = bots.log
```

to:

```
AiPlayerbot.BotLogFile = ""
```

With an empty value, `BotLog::Initialize` returns before opening anything
(`BotLog.cpp:17-18`), `m_file` stays `nullptr`, and every `out*` call falls through to
`Log::Instance()`. There, `Log::outDetail` (`src/shared/Log.cpp:846-873`) checks
`m_logLevel >= LOG_LVL_DETAIL` for console and `m_logFileLevel >= LOG_LVL_DETAIL` for
file — both are 1, `LOG_LVL_DETAIL` is 2, so the trace is dropped at the source.
`outError` / `outBasic` / `outInfo` keep working and land in `server.log` / `errors.log`
as they did before `BotLog` existed.

### Step 3 — restart mangosd and verify

```bash
docker restart tw2-mangosd     # ~1 min to load; don't do this mid-match
```

Wait ~5 minutes with bots active, then:

```bash
ls -l ~/tortoise-wow-server-V2/logs/bots.log     # expect: still 0 bytes, or absent
tail -5 ~/tortoise-wow-server-V2/logs/server.log # expect: normal boot lines, no [DETAIL] flood
```

**Confirm the file is not growing** — this is the real gate, run it twice a minute apart:

```bash
stat -c %s ~/tortoise-wow-server-V2/logs/bots.log
```

> HYPOTHESIS — the one thing not tested live: that ACE's ini parser turns `""` into an
> empty string rather than falling back to the `"bots.log"` default. The evidence it
> does: `mangosd.conf:423` is `LogFile = "server.log"` and the resulting file is named
> `server.log`, not `"server.log"`, so surrounding quotes are stripped. If after the
> restart the file *is* still growing, the parser kept the default — fall back to §5,
> which does not depend on this.

---

## 5. Alternative / belt-and-braces — keep a capped `bots.log`

Use this if you want to keep the trace for debugging, or as a safety net alongside §4.

**Do not rely on the distro's default logrotate run.** `logrotate.timer` fires **once a
day** (verified: next run 00:06). At 22 MB/min this file gains ~30 GB between checks.
Size-based rotation only rotates *when logrotate happens to run*, so the cadence is the
whole ballgame.

```bash
sudo tee /etc/logrotate.turtle-bots.conf >/dev/null <<'CONF'
/home/deck/tortoise-wow-server-V2/logs/bots.log {
    size 200M
    rotate 2
    compress
    missingok
    notifempty
    copytruncate
    su root root
}
CONF

echo '*/15 * * * * root /usr/sbin/logrotate -s /var/lib/logrotate/turtle-bots.status /etc/logrotate.turtle-bots.conf' \
  | sudo tee /etc/cron.d/turtle-bots-logrotate >/dev/null
sudo chmod 644 /etc/cron.d/turtle-bots-logrotate
```

Notes on the choices:

- `copytruncate` is required and is **safe here** for the same `O_APPEND` reason as §4
  step 1. Without it logrotate would rename the file and mangosd would keep writing to
  the renamed inode forever.
- `su root root` — the log files are owned by `root` (written from inside the container)
  while the `logs/` directory is owned by your user; logrotate refuses to rotate in that
  situation unless you tell it whose identity to use.
- Separate config file + own status file, deliberately **not** in `/etc/logrotate.d/`,
  so the 15-minute cron run only touches this one file and doesn't rotate your system
  logs 96× a day.
- Ceiling: 200 MB live + up to ~330 MB accumulated between checks + 2 compressed
  rotations ≈ **under 1 GB steady state**.
- Dry run before trusting it: `sudo logrotate -d /etc/logrotate.turtle-bots.conf`
- Sanity check the cron file name has **no dots** — `cron.d` silently ignores files
  containing them.

---

## 6. While you're in there — cap the Docker json logs

`docker-compose.yml` sets no `logging:` block, so all three containers use the default
`json-file` driver with **no size limit**. Not urgent (small at `LogLevel = 1`), but a
two-line insurance policy per service:

```yaml
    logging:
      driver: json-file
      options: { max-size: "50m", max-file: "3" }
```

Takes effect on container recreate (`docker compose up -d`), not on `docker restart`.

---

## 7. Windows / WSL only — reclaim the disk for real

Deleting the file inside Linux does **not** give the space back to Windows. The distro
lives in a VHDX that grows and never auto-shrinks:

| | |
|---|---|
| VHDX | `C:\Users\<you>\AppData\Local\wsl\{<guid>}\ext4.vhdx` |
| Size here | **17.7 GB** — ~12 GB of it is this one log file |

Find yours:

```powershell
Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' |
  ForEach-Object { (Get-ItemProperty $_.PSPath) | Select-Object DistributionName, BasePath }
```

After truncating the log, shrink it. On WSL 2.0+ (this box: 2.7.11) the clean route is
to enable sparse mode so the VHDX releases freed blocks automatically from then on:

```powershell
wsl --shutdown
wsl --manage Ubuntu --set-sparse true
```

That is a one-time change and it also prevents the next slow leak from costing you
Windows disk. Stop the server cleanly before `wsl --shutdown`.

---

## 8. What you give up, and when to turn it back on

Applying §4 means `bots.log` no longer exists. In exchange:

- Bot **errors** still reach `logs/errors.log`, and lifecycle/INFO lines reach
  `server.log` — the same place they went before the redirect feature was added.
- **Battleground diagnosis is unaffected.** `logs/bg.log` is the log the WSG runbook
  actually uses (`docs/playerbots/WSG-BOT-MATCH.md` §6) and it is untouched — 85 KB, not 12 GB.
- `logs/bot_events.csv` and `logs/deaths.csv` (`AiPlayerbot.AllowedLogFiles`, conf line
  1173) are also untouched.

You lose the per-tick action trace. That trace is genuinely useful when you're debugging
*why a specific bot won't do a specific thing* — so when you need it, turn it back on
deliberately and scoped:

1. Set `AiPlayerbot.BotLogFile = bots.log` again, restart.
2. Reproduce the problem within a few minutes.
3. Set it back to `""` and restart.

If you leave §5's logrotate in place, you can skip the round-trip: the trace is always
there, always capped at the last ~200 MB, which is more than enough history to debug a
live repro.

---

## 9. Do-nots

| Don't | Why |
|---|---|
| `cat` / `less` / `grep` the untruncated file | 12 GB. Use `tail -c 50000000 <file> > /tmp/sample` and work on the sample |
| `rm bots.log` on a running server | Inode stays alive; space is not returned and new output disappears |
| Rely on `logrotate.timer`'s daily run alone | 30 GB of growth between checks |
| Assume `LogLevel` / `LogFileLevel` control this | §2 — `BotLog` bypasses both |
| Assume `LogInGroupOnly` will fix it | Already on by default; BG bots are grouped |
| `docker restart tw2-mangosd` mid-match | Bots take minutes to come back and the roster needs re-adding |

---

## 10. Source references

All under `~/tortoise-wow-server-V2/` (note the nested `src/src/` path):

| File | Lines | Relevance |
|---|---|---|
| `src/src/modules/PlayerBots/playerbot/strategy/Engine.cpp` | 783, 810, 813 | `LogAction` — the emitter, the `logInGroupOnly` gate, the direct `outDetail` call |
| `src/src/modules/PlayerBots/playerbot/playerbot.h` | 40 | `#define sLog BotLog::Instance()` |
| `src/src/modules/PlayerBots/playerbot/BotLog.h` | 43 | `HasLogLevelOrHigher` hardcoded `true` |
| `src/src/modules/PlayerBots/playerbot/BotLog.cpp` | 17-18, 35, 73, 123 | Empty-path early return; `fopen("a")`; per-line `fflush`; `outDetail` |
| `src/src/modules/PlayerBots/playerbot/PlayerbotAIConfig.cpp` | 264, 502-506 | `LogInGroupOnly` default `true`; `BotLogFile` / `BotLogDebug` read + `Initialize` |
| `src/src/shared/Log.cpp` | 846-873 | `Log::outDetail` — the level checks `BotLog` skips |
| `src/src/shared/Log.h` | 38-41, 330 | `LOG_LVL_DETAIL = 2`; the `DETAIL_LOG` macro guard |
| `etc/mangosd.conf` | 16, 415, 431 | `LogsDir`, `LogLevel`, `LogFileLevel` |
| `etc/aiplayerbot.conf` | 264-270, 1123, 1173 | `BotLogFile`, `BotLogDebug`, `LogInGroupOnly`, `AllowedLogFiles` |
