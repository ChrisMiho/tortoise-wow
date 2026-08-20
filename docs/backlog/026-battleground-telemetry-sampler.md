---
status: done
risk: high
area: game/battlegrounds
depends-on:
---

# A match result says who won, not whether the bots ever played

**Problem:** A `bg.log` score line cannot answer the questions that actually
matter about a bot battleground: did all 20 bots get in, where did they go, and
were they ever in combat. Matches on this server frequently run the full
20-minute cap and end 0-0, and there is currently no way to tell a cautious match
from twenty bots standing on their spawn points.

**Suspected cause / area:** Nothing samples player state inside a live
battleground. Implements
`docs/superpowers/plans/2026-08-16-05-bg-telemetry.md` Task 1.

**Acceptance criteria:**

- `BattleGround` gains a **per-instance** `uint32 m_telemetryTimer = 0` member.
  It must not be `static`: two live battlegrounds sharing one accumulator would
  interleave their samples and neither trace would be readable.
- `BattleGround::Update(uint32 diff)` (`BattleGround.cpp:262`) gains a sampler at
  the very top, before the ending-system block, which emits one line per player
  per interval:
  `TELEMETRY tick instance=<id> map=<n> t=<elapsedSec> player=<name> team=<n>
  x=<f> y=<f> z=<f> hp=<n> maxhp=<n> alive=<0|1> combat=<0|1>`.
- It goes to **`bg.log` via `sLog.out(LOG_BG, ...)`**, not a new log file. Adding a
  `LogFile` enum entry would mean touching the log table and the config schema;
  `bg.log` is small, already rotated, and already what the WSG tooling reads.
- **Sampling is off by default.** It is gated on
  `sConfig.GetIntDefault("Tournament.TelemetryIntervalMs", 0) > 0` **and**
  `GetStatus() == STATUS_IN_PROGRESS`. A per-tick loop over every battleground
  player that is always on is a permanent cost paid by a server that mostly is not
  running a tournament.
- The loop is bounded and allocation-free beyond the formatted line — it runs on
  the main world loop, once per live battleground, per tick.
- Every `sObjectAccessor.FindPlayer` result is null-checked before use.
- `src/mangosd/mangosd.conf.dist.in` documents and defaults the new key:
  `Tournament.TelemetryIntervalMs = 0`, with a comment saying `0` disables
  sampling entirely and `5000` is a reasonable trace density (20 players ×
  20 minutes at 5 s is 4800 lines, nothing next to `bg.log`'s normal traffic).
- Any include the file needs (`Config/Config.h`, `ObjectAccessor.h`) is added only
  if not already present.

**Notes:**

- **Do not attempt a Docker build here** (~9.5 minutes, no incremental build —
  `COPY . /src` never cache-hits, so every build recompiles all ~1169 translation
  units). The `backlog-batch` pass compiles this branch; the criteria above are
  structural on purpose.
- Risk is `high` because this is the only change in the whole tournament series
  that runs on the main world loop on a server carrying ~1000 concurrent
  playerbots. The default-off gate is the mitigation and must be checked first,
  before the accumulator is even touched.
- **The plan edits the live `~/tortoise-wow-server-V2/etc/mangosd.conf`. That file
  is bind-mounted and not version-controlled**, so it cannot be part of this
  artifact's acceptance. Add the key to the in-repo `.dist.in` template here;
  setting it on the live server is an operator step. The live conf is read **only
  at startup**, so a change there needs `docker restart tcm-mangosd` — no rebuild.
- **Verification needing a live stack (not part of these criteria):** with the
  live conf still at `0`, `grep -ac "TELEMETRY tick" ~/tortoise-wow-server-V2/logs/bg.log`
  during a live match must return `0` — proving sampling is genuinely off, not
  merely quiet. Then set it to `5000`, restart mangosd, run a match, and confirm
  lines carrying a real instance id, `map=489`, a rising `t=`, distinct player
  names, and coordinates that change between samples. **Coordinates that never
  change across a whole match is a finding, not a broken sampler** — it is exactly
  the bot-pathing problem this telemetry exists to expose.

**Base:** cm-main

**Branch:** backlog/battleground-telemetry-sampler

**Summary:** Added a config-gated per-player sampler to `BattleGround::Update`. `src/game/Battlegrounds/BattleGround.h` gains a private, non-static, per-instance `uint32 m_telemetryTimer = 0` next to the other timer state (`m_EmptyHoldTimer`). `src/game/Battlegrounds/BattleGround.cpp` gains a TELEMETRY block at the very top of `Update(uint32 diff)`, before the ending-system block: it reads `sConfig.GetIntDefault("Tournament.TelemetryIntervalMs", 0)` first and only touches the accumulator when that is `> 0` and `GetStatus() == STATUS_IN_PROGRESS`, so a non-tournament server pays one config read per live battleground per tick and nothing else. When the accumulator crosses the interval it resets and walks `m_Players` once, null-checking every `sObjectAccessor.FindPlayer` result (a guid outlives its session until `RemovePlayerAtLeave` runs) and emitting one `sLog.out(LOG_BG, "TELEMETRY tick instance=%u map=%u t=%u player=%s team=%u x=%.2f y=%.2f z=%.2f hp=%u maxhp=%u alive=%u combat=%u", ...)` line per player, with `t=` taken from `GetStartTime() / 1000`. No new log file and no `LogFile` enum entry. The two includes the file lacked, `Config/Config.h` and `ObjectAccessor.h`, were added (`Log.h`/`Player.h` were already reachable). `src/mangosd/mangosd.conf.dist.in` documents and defaults `Tournament.TelemetryIntervalMs = 0`, noting that `0` disables sampling entirely and `5000` is a reasonable trace density (20 players x 20 minutes = 4800 lines). The live bind-mounted `~/tortoise-wow-server-V2/etc/mangosd.conf` is deliberately untouched — it is not version-controlled and is an operator step. No build was run (rule 4); the stack was down at the time (`docker ps` empty), and nothing on this host has compiled this branch, so there was nothing runtime-testable here.

**In-game check:** Two phases; phase 1 is fully scriptable from logs, phase 2 needs a match to be run but is also judged entirely from `bg.log`, with no human eyes in the world required.

Phase 1 — prove it is genuinely off by default (scriptable, no config edit):
1. Confirm the live bind-mounted `~/tortoise-wow-server-V2/etc/mangosd.conf` has no `Tournament.TelemetryIntervalMs` line at all, or has it at `0`.
2. Boot the new image and run any WSG match (the existing `scripts/tournament/match-run.sh <allianceTeam> <hordeTeam>` from WSL is enough).
3. `grep -ac "TELEMETRY tick" ~/tortoise-wow-server-V2/logs/bg.log` must return exactly `0`. Non-zero means the default gate is broken. Absence alone is not the whole check — the `[<type>,<inst>]: winner=<n>` line for that match must be present in the same file, proving the log was being written and the sampler was quiet by choice, not because nothing ran.

Phase 2 — prove it samples when switched on:
4. Add `Tournament.TelemetryIntervalMs = 5000` to the live `~/tortoise-wow-server-V2/etc/mangosd.conf` (it is bind-mounted and read only at startup) and `docker restart tcm-mangosd`. No rebuild.
5. Run one WSG match with 20 bots.
6. `grep "TELEMETRY tick" ~/tortoise-wow-server-V2/logs/bg.log` and check, on the lines from that match only (bound the grep to the tail written after the run started — instance ids are reused across restarts):
   - `map=489` (Warsong Gulch) and a single non-zero `instance=` matching the instance id in that run's `TOURNAMENT` lines;
   - `t=` rises monotonically in roughly 5-second steps and stops at the match end, not before;
   - 20 distinct `player=` names appear per sample block, split roughly 10/10 across two distinct `team=` values — fewer than 20 is the "did all the bots get in" answer this exists to produce, and is a real finding about assembly, not a sampler bug;
   - `hp=`/`maxhp=` are plausible non-zero numbers and `alive=`/`combat=` are only ever `0` or `1`;
   - lines stop entirely once the match ends (status leaves `STATUS_IN_PROGRESS`) and none appear during the pre-start gates-closed period.
7. Coordinates: `x=`/`y=`/`z=` should differ between consecutive samples for at least some players. **Coordinates that never change for the whole match is a finding about bot pathing, not a broken sampler** — that is precisely what this telemetry was built to expose, so do not treat it as a failed check.
8. Cost check, the one risk that matters here: with sampling on and ~1000 playerbots online, watch the server's tick/diff (mangosd console `.server info` or the usual diff warnings in the server log) across the match and confirm no new diff spikes appear. Then set the key back to `0`, restart, and confirm the diff returns to its baseline.

Beyond that, the generic smoke test applies: server starts, bots spawn, a battleground can still be created and ended normally — the change adds no new command and alters no existing behaviour while the key is `0`.

**Minor findings:**
- src/game/Battlegrounds/BattleGround.cpp: The default-off gate calls sConfig.GetIntDefault every world tick per live battleground, and Config::GetValueHelper takes an exclusive unique_lock on the config shared_mutex and linearly enumerates sections doing a string key lookup, so the "costs nothing when off" claim in the conf comment understates it — caching the value (e.g. a world-config entry or a value refreshed on reload) would make the disabled path genuinely free.
- src/game/Battlegrounds/BattleGround.cpp: The sampler's comment (and the config comment) assert it "runs on the main world loop", but `BattleGround::Update` is reached from `BattleGroundMap::Update` inside the instance thread pool in `MapManager::Update`, not from `World::Update`; the wrong claim is exactly what makes the cross-thread player access above look safe to a future reader.
- src/game/Battlegrounds/BattleGround.cpp: `sConfig.GetIntDefault("Tournament.TelemetryIntervalMs", 0)` is called every tick for every live battleground from parallel map threads, and `Config::GetValueHelper` takes the process-wide `m_configLock` and linearly enumerates every config section per call, so the always-on gate serializes instance-map threads against every other `sConfig` reader even when telemetry is disabled -- cache the value (read once per instance or on config load) instead of hitting the global lock per tick.

**Drain note:** Findings 1 and 3 are the same defect seen by two lenses, and together with finding 2 they are a must-fix for this PR rather than a nit, because they falsify this artifact's own acceptance criterion that the disabled path costs a non-tournament server nothing. Verified against the branch on 2026-08-18, and the real mechanism is worse than the findings state: Config.h:80-81 defines `using LockType = std::mutex; using GuardType = std::unique_lock<LockType>;` and Config::GetValueHelper takes `GuardType guard(m_configLock)` unconditionally at Config.cpp:32 before any lookup, so this is a plain PROCESS-WIDE EXCLUSIVE mutex, not a shared/reader lock. Finding 2 is also correct and compounds it: battlegrounds are instance maps, and MapManager.cpp:47 constructs `m_threads(new ThreadPool(CONFIG_UINT32_MAPUPDATE_INSTANCED_UPDATE_THREADS, "MapManager"))` with instance updates dispatched at MapManager.cpp:390 via `m_threads->processWorkload(instancesUpdaters, ...)`, so BattleGround::Update runs on pooled instance threads and NOT on the main world loop as the new code comment claims. Net effect with telemetry switched OFF: every live battleground takes a global exclusive mutex once per tick from a parallel map thread, serialising instance threads against each other and against every other sConfig reader. That is precisely the diff-spike regression the in-game check's step 8 cost test is designed to catch. Fix by reading the interval once (world-config entry or a value refreshed on config reload) instead of calling sConfig per tick, and correct the threading comment.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/37, build tortoise-cm:20260818-2.


**Drain note (FIRST LIVE RUN — the sampler works, and its answer is that the bots are inert):** measured from bg.log on 2026-08-18 during this batch's own validate match, image tortoise-cm:20260818-2, instance=101 map=489, Tournament.TelemetryIntervalMs = 5000. The sampler emitted 3320 TELEMETRY tick lines in exactly the specified format, so this artifact is confirmed working in-world for the first time (its own implement tick could only reason about it, having compiled nothing). What it measured:

- All 20 bots assembled correctly: 10 team=469 (Alliance) and 10 team=67 (Horde), full HP.
- **Every one of the 20 moved 0.0 yards total across 172 samples (~14 minutes).** Not approximately zero — summing the per-sample euclidean delta in x/y gives exactly 0.0 for every bot, with idle=171 of 171 sample transitions.
- combat=0 for all 20 for the entire match. Not one bot ever entered combat.
- Three bots (Wsgafour, Wsgaeight, Wsghsix) had alive=0 in all 172 samples: dead from the first sample and never released or respawned.
- Match ended winner=NONE allianceScore=0 hordeScore=0 after the full cap.

Per this artifact's own in-game check step 7, unchanging coordinates are a finding about bot pathing rather than a broken sampler — that is the case here. The tournament is currently twenty statues standing on their spawn points.

This bears directly on other artifacts and should be read alongside them: it explains the 41% draw rate that artifact 025 built its tiebreak ladder around (those are not cautious matches), and it escalates the Alliance-bias defect recorded on 025 from theoretical to certain — if every match is a 0-0 draw with no telemetry deaths, rung 1 and rung 2 are both skipped, every equal-seed round-one pairing resolves to ALLIANCE, and the first bracket run stalls at round 2 with status=blocked reason=uneven_survivors. It is also direct evidence for the still-pending 036/037 bg-AI analysis artifacts.
