---
status: done
risk: medium
area: game/battlegrounds
depends-on: 026-battleground-telemetry-sampler.md
---

# The telemetry gate takes a process-wide lock on every tick of every battleground

**Problem:** the sampler's default-off gate calls
`sConfig.GetIntDefault("Tournament.TelemetryIntervalMs", 0)` every world tick for
every live battleground. `Config::GetValueHelper` takes an exclusive
`unique_lock` on the process-wide config mutex and linearly enumerates every
section doing a string key lookup. The conf comment's claim that it "costs
nothing when off" understates the cost: the gate serialises the instance-map
threads against every other `sConfig` reader in the process even when telemetry
is disabled.

Compounding it, the sampler's comment asserts it "runs on the main world loop",
but `BattleGround::Update` is reached from `BattleGroundMap::Update` inside the
instance thread pool in `MapManager::Update` — and that wrong claim is exactly
what makes the cross-thread player access above it look safe to the next reader.

**Suspected cause / area:** `src/game/Battlegrounds/BattleGround.cpp`, the
artifact-026 sampler block.

**Acceptance criteria:**

- The interval is read **once** (a cached world-config entry or equivalent), not
  per tick per battleground; the config lock is not taken on the hot path.
- The comments name the instance thread pool rather than the main world loop,
  and the thread-safety of the player access is **stated explicitly** rather than
  implied by a wrong claim.
- With telemetry off, a 1000-bot stand-up shows no regression against the
  4.2682 GiB / 1017-bot reference.

**Notes:**

- Needs a build. Docker builds run in the foreground at ~8.5 min —
  `timeout: 600000`, `BUILD_JOBS=14`, verify with `docker images`.
- The stand-up comparison is a ~2.5 h run (`scripts/standup-1000.sh`) and also
  edits the live conf. **Treat it as operator follow-up, not a gate on the code
  change** — do not attempt it inside the drain.
- Correcting the comment is not cosmetic here: the wrong claim is load-bearing
  for what a future reader believes about thread safety.

**Base:** cm-main

**Branch:** backlog/telemetry-gate-takes-config-lock-every-tick

**Summary:** Replaced the per-tick `sConfig.GetIntDefault("Tournament.TelemetryIntervalMs", 0)` in the artifact-026 sampler block of `src/game/Battlegrounds/BattleGround.cpp` with a cached world-config read. Added `CONFIG_UINT32_TOURNAMENT_TELEMETRY_INTERVAL_MS` to `eConfigUInt32Values` in `src/game/World.h` and populated it via `setConfig(..., "Tournament.TelemetryIntervalMs", 0)` in `World::LoadConfigSettingsFromFile` (`src/game/World.cpp`), which also runs on `.reload config`, so runtime reconfiguration is preserved. The hot path is now `sWorld.getConfig(...)` — a plain array read plus an integer compare — so the disabled gate no longer takes the exclusive `unique_lock` on the process-wide config mutex nor linearly enumerates config sections on every instance-map thread tick. Rewrote both comments in the block: the header now states that `BattleGround::Update` is reached from `BattleGroundMap::Update` on MapManager's instance map update threads and *not* the main world loop, and explains why that makes the cached read necessary; the inner comment now states the thread-safety constraint explicitly (every Player field read is only safe on a Player this map's thread owns, which is why the lookup is `GetBgMap()->GetPlayer` rather than `sObjectAccessor.FindPlayer`, and why a null return is the routine case) rather than leaning on the wrong "main world loop" claim. Also corrected the `Tournament.TelemetryIntervalMs` block in `src/mangosd/mangosd.conf.dist.in`, which claimed the disabled sampler "costs one config read per live battleground per world tick", and noted that the value is cached at load/`.reload config`. No SQL migration, no build run (per drain rule 4); the 1000-bot stand-up comparison is operator follow-up per the artifact's own Notes.

**In-game check:** The change is behaviour-preserving for telemetry output; what must be confirmed is that the cached value is still read correctly, including after a reload.

Scriptable from logs/console (a later batch step can do all of this without a human watching):
1. Start the server with `Tournament.TelemetryIntervalMs = 0` in mangosd.conf. Confirm normal startup and that `bg.log` contains **zero** lines matching `TELEMETRY tick` after a full battleground runs to completion. Run a match with `rndbot` + `.bg` (or the tournament console path) and grep: `grep -c "TELEMETRY tick" bg.log` must be 0.
2. Stop the server, set `Tournament.TelemetryIntervalMs = 5000`, restart, and run one Warsong Gulch match with bots. `grep -c "TELEMETRY tick" bg.log` must now be non-zero, and the lines must appear roughly every 5 seconds per player while the match status is IN_PROGRESS — check timestamps on consecutive `t=` values for one player name: they should step by ~5. Also confirm no `TELEMETRY tick` lines appear before the gates open or during the 2-minute leave window after the match ends.
3. Reload path: with the server up and the conf set back to `0`, edit the live mangosd.conf to `5000` and issue `.reload config` on the console (via `wsg_console`, never a bare `docker attach`). Sampling must **start** without a restart; set it back to `0`, `.reload config` again, and sampling must **stop**. This is the one behaviour the caching could have broken, and it is the most important check.
4. Absence-of-error check: no new warnings or errors in `Server.log` at startup mentioning the config key or an out-of-range config index.

Requires a human only for: nothing functional. The remaining acceptance criterion — "with telemetry off, a 1000-bot stand-up shows no regression against the 4.2682 GiB / 1017-bot reference" — is a ~2.5 h `scripts/standup-1000.sh` run that the artifact itself designates operator follow-up, not a gate; an operator should run it at their convenience and compare peak RSS and bot count against 4.2682 GiB / 1017 bots. Beyond that, the generic smoke test (server starts, bots spawn, a battleground runs to a score) is sufficient.

**Minor findings:**
- src/game/Battlegrounds/BattleGround.cpp: `#include "Config/Config.h"` in BattleGround.cpp was added solely for the sampler's `sConfig.GetIntDefault` call (commit 41e15e4) and is now dead after the gate moved to `sWorld.getConfig` — no other `sConfig` use remains in the file.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/76, build tortoise-cm:20260819-4.
