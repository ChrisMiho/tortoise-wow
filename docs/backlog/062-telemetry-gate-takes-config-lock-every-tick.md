---
status: pending
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
