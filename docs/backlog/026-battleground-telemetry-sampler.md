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
