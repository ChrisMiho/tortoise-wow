# Battleground Telemetry & Bot Log Capture — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove bots actually reach the battleground, see where they go while they
are in it, and capture per-bot behaviour in a form that can be analysed afterwards —
without letting the logs eat the disk.

**Architecture:** A config-gated sampler inside `BattleGround::Update()` emits one
`TELEMETRY` line per player per interval into `bg.log`. Shell tooling extracts those
into per-match CSV, produces an entry report and a movement report, and a filtered
capture pulls only the playing bots' lines out of `bots.log` for the match window.

**Tech Stack:** C++ (`BattleGround::Update`), `mangosd.conf`, Bash, `awk`.

**Spec:** `docs/superpowers/specs/2026-08-16-bot-tournament-design.md` (§1.5)

**Depends on:** `2026-08-16-02-tournament-control-plane.md` (build + validate cycle),
`2026-08-16-04-bracket-engine.md` (match run directories to write artifacts into).

## Global Constraints

- **`bots.log` is ~10 GB. Never `cat` it, never `grep` it unbounded.** Every read in
  this plan is bounded by byte offset or line count.
- Telemetry goes to **`bg.log` via `LOG_BG`** with a `TELEMETRY ` prefix, not a new
  log file. Adding a `LogFile` enum entry means touching the log table and the config
  schema; `bg.log` is small, already rotated, and already the file the WSG tooling
  reads.
- **Sampling must be off by default.** A per-tick loop over every battleground player
  that is always on is a permanent cost paid by a server that mostly is not running a
  tournament.
- `BattleGround::Update(uint32 diff)` (`BattleGround.cpp:262`) is called every world
  tick per live battleground. Anything added there runs on the main loop — keep it to
  a bounded loop with no allocation beyond the formatted line.
- The `diff` accumulator must be per-battleground, not static — two live instances
  sharing one counter would interleave their sampling.
- Config is read with `sConfig.GetIntDefault(...)` (`Config.h:57`).

---

## File Structure

| File | Responsibility |
|---|---|
| `src/game/Battlegrounds/BattleGround.h` (modify) | The sampler's accumulator member |
| `src/game/Battlegrounds/BattleGround.cpp` (modify) | The sampler itself, in `Update()` |
| `scripts/tournament/telemetry-extract.sh` (create) | `bg.log` → per-match CSV |
| `scripts/tournament/telemetry-report.sh` (create) | Entry + movement reports from the CSV |
| `scripts/tournament/bot-log-capture.sh` (create) | Bounded extraction of a match window from `bots.log` |
| `tests/tournament/telemetry.test.sh` (create) | Parser and report tests against fixture logs |

---

### Task 1: The in-battleground sampler

**Files:**
- Modify: `src/game/Battlegrounds/BattleGround.h` (private members, near the other
  timer state)
- Modify: `src/game/Battlegrounds/BattleGround.cpp:262` (top of `Update`)

**Interfaces:**
- Produces, once per interval per live battleground, one line per player:
  `TELEMETRY tick instance=<id> map=<n> t=<elapsedSec> player=<name> team=<n> x=<f> y=<f> z=<f> hp=<n> maxhp=<n> alive=<0|1> combat=<0|1>`

- [ ] **Step 1: Add the accumulator**

In `src/game/Battlegrounds/BattleGround.h`, in the protected/private member block:

```cpp
        // Telemetry sampling. Per-instance, deliberately not static: two live
        // battlegrounds sharing one accumulator would interleave their samples
        // and neither trace would be readable.
        uint32 m_telemetryTimer = 0;
```

- [ ] **Step 2: Add the sampler**

At the very top of `BattleGround::Update(uint32 diff)` in
`src/game/Battlegrounds/BattleGround.cpp:262`, before the ending-system block:

```cpp
    /*********************************************************/
    /***                    TELEMETRY                      ***/
    /*********************************************************/
    // Off unless Tournament.TelemetryIntervalMs is set. This runs on the main
    // loop for every live battleground, so a server that is not running a
    // tournament must pay nothing for it.
    {
        int32 telemetryInterval = sConfig.GetIntDefault("Tournament.TelemetryIntervalMs", 0);
        if (telemetryInterval > 0 && GetStatus() == STATUS_IN_PROGRESS)
        {
            m_telemetryTimer += diff;
            if (m_telemetryTimer >= uint32(telemetryInterval))
            {
                m_telemetryTimer = 0;
                uint32 elapsed = GetStartTime() / 1000;

                for (const auto& itr : m_Players)
                {
                    Player* plr = sObjectAccessor.FindPlayer(itr.first);
                    if (!plr)
                        continue;

                    sLog.out(LOG_BG,
                        "TELEMETRY tick instance=%u map=%u t=%u player=%s team=%u "
                        "x=%.2f y=%.2f z=%.2f hp=%u maxhp=%u alive=%u combat=%u",
                        GetInstanceID(), GetMapId(), elapsed,
                        plr->GetName(), uint32(itr.second.PlayerTeam),
                        plr->GetPositionX(), plr->GetPositionY(), plr->GetPositionZ(),
                        plr->GetHealth(), plr->GetMaxHealth(),
                        plr->IsAlive() ? 1u : 0u,
                        plr->IsInCombat() ? 1u : 0u);
                }
            }
        }
    }
```

Add the includes `BattleGround.cpp` may not already have:

```cpp
#include "Config/Config.h"
#include "ObjectAccessor.h"
```

Check before adding — a duplicate include is harmless but noise, and a missing one
is a compile error naming the exact symbol.

- [ ] **Step 3: Add the config keys**

In the bind-mounted `~/tortoise-wow-server-V2/etc/mangosd.conf`, add near the other
custom settings:

```ini
###############################################################################
# TOURNAMENT TELEMETRY
#
#    Tournament.TelemetryIntervalMs
#        How often to sample every player in a live battleground into bg.log.
#        0 disables sampling entirely (default). 5000 is a reasonable trace
#        density for pathing debug: 20 players x 20 minutes at 5s is 4800 lines,
#        which is nothing next to bg.log's normal traffic.
#        Default: 0
###############################################################################

Tournament.TelemetryIntervalMs = 0
```

This file is bind-mounted, not baked into the image, so it can be changed without
a rebuild — but it is **only read at startup**, so a change still needs
`docker restart tcm-mangosd`.

- [ ] **Step 4: Build**

Run: `./scripts/rebuild.sh`
Expected: all acceptance checks `ok:`.

- [ ] **Step 5: Prove it is off by default and on when asked**

```bash
./scripts/validate-stack.sh --image tortoise-cm:local --keep-up
```

With the config still at `0`, run a match long enough to have players in progress
and confirm silence:

```bash
grep -ac "TELEMETRY tick" ~/tortoise-wow-server-V2/logs/bg.log
```

Expected: `0` — sampling is genuinely off, not merely quiet.

Now enable it and restart:

```bash
sed -i 's/^Tournament.TelemetryIntervalMs.*/Tournament.TelemetryIntervalMs = 5000/' \
  ~/tortoise-wow-server-V2/etc/mangosd.conf
docker restart tcm-mangosd
```

Wait for the world, then run a match (`match-run.sh`) and check:

```bash
grep -a "TELEMETRY tick" ~/tortoise-wow-server-V2/logs/bg.log | tail -3
```

Expected: lines carrying a real instance id, `map=489`, a rising `t=`, distinct
player names, and coordinates that change between samples. **Coordinates that never
change across the whole match is a finding**, not a broken sampler — record it, it
is exactly the bot-pathing problem this telemetry exists to expose.

- [ ] **Step 6: Commit**

```bash
git add src/game/Battlegrounds/BattleGround.h src/game/Battlegrounds/BattleGround.cpp
git commit -m "feat(telemetry): config-gated per-player sampling inside a live battleground"
```

---

### Task 2: Extract telemetry into per-match CSV

**Files:**
- Create: `scripts/tournament/telemetry-extract.sh`
- Test: `tests/tournament/telemetry.test.sh`

**Interfaces:**
- Produces: `telemetry-extract.sh --instance <id> [--log <path>] [--out <file>]` →
  CSV with header `t,player,team,x,y,z,hp,maxhp,alive,combat`, one row per sample,
  sorted by `t` then `player`. Exit 1 if no samples matched.

- [ ] **Step 1: Write the failing test**

```bash
# tests/tournament/telemetry.test.sh
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
. "$HERE/../lib/assert.sh"

fix="$(mktemp)"
cat > "$fix" <<'EOF'
2026-08-16 21:00:00 unrelated bg line
TELEMETRY tick instance=101 map=489 t=5 player=Wsgaone team=469 x=1500.10 y=1490.20 z=352.00 hp=4000 maxhp=4000 alive=1 combat=0
TELEMETRY tick instance=101 map=489 t=5 player=Wsghone team=67 x=900.50 y=1440.00 z=345.10 hp=3800 maxhp=4200 alive=1 combat=1
TELEMETRY tick instance=999 map=489 t=5 player=Otherguy team=469 x=1.00 y=2.00 z=3.00 hp=1 maxhp=1 alive=1 combat=0
TELEMETRY tick instance=101 map=489 t=10 player=Wsgaone team=469 x=1495.00 y=1480.00 z=352.00 hp=3900 maxhp=4000 alive=1 combat=1
EOF

out="$(mktemp)"
bash "$ROOT/scripts/tournament/telemetry-extract.sh" --instance 101 --log "$fix" --out "$out"
RC=$?

assert_eq "0" "$RC" "extract exits 0 when samples exist"
assert_eq "t,player,team,x,y,z,hp,maxhp,alive,combat" "$(head -1 "$out")" "writes a header"
assert_eq "3" "$(( $(wc -l < "$out") - 1 ))" "three rows for instance 101"
assert_eq "0" "$(grep -c 'Otherguy' "$out")" "other instances are excluded"
assert_contains "$(sed -n '2p' "$out")" "5,Wsgaone,469,1500.10" "row is sorted and complete"

assert_exit 1 "no matching samples exits 1" -- \
  bash "$ROOT/scripts/tournament/telemetry-extract.sh" --instance 777 --log "$fix" --out "$(mktemp)"

rm -f "$fix" "$out"
assert_summary
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/tournament/telemetry.test.sh`
Expected: FAIL — `scripts/tournament/telemetry-extract.sh: No such file or directory`

- [ ] **Step 3: Write the extractor**

```bash
#!/usr/bin/env bash
# Pull one battleground instance's telemetry out of bg.log as CSV.
#
#   ./scripts/tournament/telemetry-extract.sh --instance 101 [--log <path>] [--out <file>]
#
# bg.log carries every instance's samples interleaved, so filtering by instance
# is not optional -- two concurrent battlegrounds would otherwise produce one
# nonsensical trace.
set -uo pipefail

LOG="${HOME}/tortoise-wow-server-V2/logs/bg.log"
INSTANCE=""; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --instance) INSTANCE="$2"; shift 2 ;;
    --log)      LOG="$2"; shift 2 ;;
    --out)      OUT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$INSTANCE" ] || { echo "usage: telemetry-extract.sh --instance <id> [--log <path>] [--out <file>]" >&2; exit 2; }
[ -f "$LOG" ] || { echo "no such log: $LOG" >&2; exit 2; }
[ -n "$OUT" ] || OUT="telemetry-${INSTANCE}.csv"

# Parse key=value pairs positionally rather than by column index: the line format
# is stable but its field ORDER is not something a downstream reader should
# depend on, and a key-based parse survives a field being added.
awk -v want="instance=$INSTANCE" '
  $0 ~ /^TELEMETRY tick / {
    delete kv
    for (i = 3; i <= NF; i++) {
      split($i, p, "=")
      kv[p[1]] = p[2]
    }
    if (("instance=" kv["instance"]) != want) next
    printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n",
      kv["t"], kv["player"], kv["team"], kv["x"], kv["y"], kv["z"],
      kv["hp"], kv["maxhp"], kv["alive"], kv["combat"]
  }
' "$LOG" | sort -t, -k1,1n -k2,2 > "$OUT.body"

rows=$(wc -l < "$OUT.body" | tr -d ' ')
if [ "$rows" -eq 0 ]; then
    rm -f "$OUT.body"
    echo "no telemetry samples for instance $INSTANCE in $LOG" >&2
    echo "  (is Tournament.TelemetryIntervalMs set, and was mangosd restarted after setting it?)" >&2
    exit 1
fi

{ echo "t,player,team,x,y,z,hp,maxhp,alive,combat"; cat "$OUT.body"; } > "$OUT"
rm -f "$OUT.body"
echo "wrote $rows samples to $OUT"
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bash tests/tournament/telemetry.test.sh`
Expected: `6 passed, 0 failed`, exit 0

- [ ] **Step 5: Commit**

```bash
git add scripts/tournament/telemetry-extract.sh tests/tournament/telemetry.test.sh
git commit -m "feat(telemetry): extract a single instance's samples as CSV"
```

---

### Task 3: Entry and movement reports

**Files:**
- Create: `scripts/tournament/telemetry-report.sh`
- Modify: `tests/tournament/telemetry.test.sh`

**Interfaces:**
- Consumes: the CSV from Task 2.
- Produces: `telemetry-report.sh <csv>` →
  - `ENTRY player=<name> team=<n> firstSeen=<t> samples=<n>` per player
  - `MOVEMENT player=<name> distance=<f> maxStep=<f> idleSamples=<n> stuck=<0|1>`
  - `REPORT players=<n> expected=20 entered=<n> stuck=<n>`
  - Exit 1 if fewer than 20 players entered, or any bot is flagged stuck.

`stuck` is the pathing signal: a bot whose position does not change across a long
run of samples is not playing, whatever the score says.

- [ ] **Step 1: Write the failing test**

Append to `tests/tournament/telemetry.test.sh` before `assert_summary`:

```bash
# --- reports --------------------------------------------------------------
csv="$(mktemp)"
{
  echo "t,player,team,x,y,z,hp,maxhp,alive,combat"
  # Mover: travels a clear distance every sample.
  for t in 5 10 15 20 25; do
    echo "$t,Mover,469,$((1500 - t)).00,1490.00,352.00,4000,4000,1,0"
  done
  # Stuck: identical coordinates for every sample.
  for t in 5 10 15 20 25; do
    echo "$t,Stuck,67,900.00,1440.00,345.00,4000,4000,1,0"
  done
} > "$csv"

OUT="$(bash "$ROOT/scripts/tournament/telemetry-report.sh" "$csv" 2>&1)"
assert_contains "$OUT" "ENTRY player=Mover"  "reports entry per player"
assert_contains "$OUT" "firstSeen=5"          "reports first sighting"
assert_contains "$OUT" "stuck=1"              "flags a bot that never moves"
assert_contains "$OUT" "MOVEMENT player=Mover" "reports movement per player"
assert_eq "1" "$(printf '%s\n' "$OUT" | grep -c 'MOVEMENT player=Stuck.*stuck=1')" "only the stuck bot is flagged"
assert_contains "$OUT" "entered=2" "counts distinct players"
rm -f "$csv"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/tournament/telemetry.test.sh`
Expected: FAIL — `scripts/tournament/telemetry-report.sh: No such file or directory`

- [ ] **Step 3: Write the report**

```bash
#!/usr/bin/env bash
# Turn a telemetry CSV into the two questions worth asking:
#   did every bot actually get in, and did it actually go anywhere?
#
#   ./scripts/tournament/telemetry-report.sh <csv> [--expected 20]
#
# Exit 0 = the expected number of players entered and none is stuck.
set -uo pipefail
CSV="${1:-}"
[ -n "$CSV" ] && [ -f "$CSV" ] || { echo "usage: telemetry-report.sh <csv> [--expected N]" >&2; exit 2; }
shift
EXPECTED=20
[ "${1:-}" = "--expected" ] && EXPECTED="$2"

# A bot that never crosses this much distance across the whole match never left
# its spawn. Warsong Gulch is roughly 900 yards end to end, so 10 yards total is
# unambiguously "did not play" rather than "played cautiously".
STUCK_TOTAL_DISTANCE=10

awk -F, -v expected="$EXPECTED" -v stuckdist="$STUCK_TOTAL_DISTANCE" '
NR == 1 { next }
{
  p = $2
  if (!(p in first)) { first[p] = $1; team[p] = $3; order[++n] = p }
  samples[p]++

  if (p in px) {
    dx = $4 - px[p]; dy = $5 - py[p]; dz = $6 - pz[p]
    step = sqrt(dx*dx + dy*dy + dz*dz)
    dist[p] += step
    if (step > maxstep[p]) maxstep[p] = step
    if (step < 0.01) idle[p]++
  }
  px[p] = $4; py[p] = $5; pz[p] = $6
}
END {
  stuckcount = 0
  for (i = 1; i <= n; i++) {
    p = order[i]
    printf "ENTRY player=%s team=%s firstSeen=%s samples=%d\n", p, team[p], first[p], samples[p]
  }
  for (i = 1; i <= n; i++) {
    p = order[i]
    st = (dist[p] < stuckdist) ? 1 : 0
    stuckcount += st
    printf "MOVEMENT player=%s distance=%.1f maxStep=%.1f idleSamples=%d stuck=%d\n",
           p, dist[p], maxstep[p], idle[p], st
  }
  printf "REPORT players=%d expected=%d entered=%d stuck=%d\n", n, expected, n, stuckcount
  exit (n < expected || stuckcount > 0) ? 1 : 0
}
' "$CSV"
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bash tests/tournament/telemetry.test.sh`
Expected: `12 passed, 0 failed`, exit 0

- [ ] **Step 5: Run it against a real match**

```bash
./scripts/tournament/telemetry-extract.sh --instance <inst> --out /tmp/m.csv
./scripts/tournament/telemetry-report.sh /tmp/m.csv
```

Expected: 20 `ENTRY` lines and a `REPORT ... entered=20 stuck=0`.

A non-zero `stuck` count, or `entered` below 20, is **the finding this whole plan
exists to produce** — record the exact output. It feeds directly into
`2026-08-16-07-bg-combat-analysis.md`.

- [ ] **Step 6: Commit**

```bash
git add scripts/tournament/telemetry-report.sh tests/tournament/telemetry.test.sh
git commit -m "feat(telemetry): entry and movement reports, with a stuck-bot gate"
```

---

### Task 4: Bounded bot-log capture

**Files:**
- Create: `scripts/tournament/bot-log-capture.sh`

**Interfaces:**
- Produces: `bot-log-capture.sh --team <team-id> [--team <team-id>] --out <file>` —
  records `bots.log`'s size, waits to be called again, and extracts only the bytes
  appended since, filtered to the named teams' bots.
  Two modes: `--mark <file>` records the offset; `--since <file>` extracts from it.

`bots.log` is ~10 GB. Reading it from the start to find a match window is not an
option, so the capture is anchored on a byte offset taken before the match.

- [ ] **Step 1: Check the current size before designing around it**

```bash
ls -lh ~/tortoise-wow-server-V2/logs/bots.log
```

Record the number. If it has been rotated or truncated since
`docs/playerbots/BOTS-LOG-GROWTH-HANDOFF.md` was written, say so — the constraint
is real either way, but the doc should not claim a stale figure.

- [ ] **Step 2: Write the script**

```bash
#!/usr/bin/env bash
# Capture only the bots.log written during one match, for only the bots playing.
#
#   ./scripts/tournament/bot-log-capture.sh --mark  /path/to/offset
#   ...run the match...
#   ./scripts/tournament/bot-log-capture.sh --since /path/to/offset \
#        --team stormwind-sentinels --team orgrimmar-warsong --out match-bots.log
#
# bots.log is ~10 GB. Anything that reads it from the beginning is a mistake --
# `tail -c +<offset>` starts at the byte where the match did, so the read is
# proportional to the match, not to the file.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/lib/team.sh"

BOTS_LOG="${BOTS_LOG:-$HOME/tortoise-wow-server-V2/logs/bots.log}"
MODE=""; MARKFILE=""; OUT=""; TEAMS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --mark)  MODE=mark;  MARKFILE="$2"; shift 2 ;;
    --since) MODE=since; MARKFILE="$2"; shift 2 ;;
    --team)  TEAMS+=("$2"); shift 2 ;;
    --out)   OUT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -f "$BOTS_LOG" ] || { echo "no bots.log at $BOTS_LOG" >&2; exit 2; }

if [ "$MODE" = "mark" ]; then
    [ -n "$MARKFILE" ] || { echo "--mark needs a path" >&2; exit 2; }
    stat -c '%s' "$BOTS_LOG" > "$MARKFILE"
    echo "marked bots.log at $(cat "$MARKFILE") bytes"
    exit 0
fi

[ "$MODE" = "since" ] || { echo "usage: bot-log-capture.sh --mark <file> | --since <file> --team <id>... --out <file>" >&2; exit 2; }
[ -f "$MARKFILE" ] || { echo "no mark file at $MARKFILE — call --mark before the match" >&2; exit 2; }
[ -n "$OUT" ] || { echo "--since needs --out" >&2; exit 2; }
[ "${#TEAMS[@]}" -gt 0 ] || { echo "--since needs at least one --team" >&2; exit 2; }

start="$(cat "$MARKFILE")"
now="$(stat -c '%s' "$BOTS_LOG")"

# Log rotation resets the size. Restarting from 0 reads the whole new file, which
# is correct and bounded; silently reading from a stale, larger offset would
# produce nothing and look like "the bots were quiet".
if [ "$now" -lt "$start" ]; then
    echo "WARNING: bots.log shrank ($start -> $now) — it was rotated mid-match; capturing from the start of the new file" >&2
    start=0
fi

# One alternation of every playing bot's name.
pattern=""
for t in "${TEAMS[@]}"; do
    team_validate "$t" >/dev/null || { echo "team $t does not validate" >&2; exit 2; }
    while IFS= read -r nm; do
        pattern="$pattern${pattern:+|}$nm"
    done < <(team_names "$t")
done

# +N is 1-indexed in tail -c, so the byte after the mark is start+1.
tail -c "+$((start + 1))" "$BOTS_LOG" | grep -aE "$pattern" > "$OUT" || true

echo "captured $(wc -l < "$OUT") line(s) from $((now - start)) byte(s) into $OUT"
```

- [ ] **Step 3: Verify the bounded read**

```bash
./scripts/tournament/bot-log-capture.sh --mark /tmp/botmark
sleep 60
./scripts/tournament/bot-log-capture.sh --since /tmp/botmark \
  --team stormwind-sentinels --out /tmp/botcap.log
```

Expected: a `captured <n> line(s) from <m> byte(s)` message where `<m>` is the
growth over that minute, **not** the whole file size. If `<m>` is in the gigabytes,
the offset logic is wrong — stop and fix it.

- [ ] **Step 4: Wire both into `match-run.sh`**

In `scripts/tournament/match-run.sh`, immediately before the assemble step:

```bash
"$HERE/bot-log-capture.sh" --mark "$RUN_DIR/bots.offset"
```

and immediately after the monitor loop breaks, before the roster logout:

```bash
"$HERE/telemetry-extract.sh" --instance "$INST" --out "$RUN_DIR/telemetry.csv" \
    && "$HERE/telemetry-report.sh" "$RUN_DIR/telemetry.csv" > "$RUN_DIR/telemetry-report.txt" 2>&1 \
    || log "telemetry unavailable (is Tournament.TelemetryIntervalMs set?)"

"$HERE/bot-log-capture.sh" --since "$RUN_DIR/bots.offset" \
    --team "$ATEAM" --team "$HTEAM" --out "$RUN_DIR/bots-match.log" || true
```

Both are `|| true` / `|| log`: missing telemetry must never fail a match that was
otherwise played and decided.

- [ ] **Step 5: Run a match and check the artifacts**

```bash
./scripts/tournament/match-run.sh stormwind-sentinels orgrimmar-warsong \
  --run-dir logs/tournament/telemetry-smoke
ls -la logs/tournament/telemetry-smoke/
cat logs/tournament/telemetry-smoke/telemetry-report.txt
```

Expected: `telemetry.csv`, `telemetry-report.txt`, and `bots-match.log` all
present and non-empty, and the report naming 20 players.

- [ ] **Step 6: Commit**

```bash
git add scripts/tournament/bot-log-capture.sh scripts/tournament/match-run.sh
git commit -m "feat(telemetry): bounded bots.log capture, wired into the match runner"
```

---

### Task 5: Document the telemetry model

**Files:**
- Create: `docs/playerbots/TOURNAMENT-TELEMETRY.md`

- [ ] **Step 1: Write the doc**

```markdown
# Battleground telemetry

Answers three questions a score line cannot: did every bot get in, where did it
go, and what was it doing.

## Turning it on

`Tournament.TelemetryIntervalMs` in `~/tortoise-wow-server-V2/etc/mangosd.conf`.
`0` (the default) disables it entirely; `5000` samples every player in every live
battleground every 5 seconds. The config is bind-mounted so no rebuild is needed,
but it is read **only at startup** — `docker restart tcm-mangosd` after changing
it.

Sampling runs inside `BattleGround::Update()` on the main loop, which is why it is
off by default: a server that is not running a tournament should pay nothing.

## Where it goes

`bg.log`, prefixed `TELEMETRY tick`, one line per player per interval:

```
TELEMETRY tick instance=101 map=489 t=125 player=Wsgaone team=469 x=1495.00 y=1480.00 z=352.00 hp=3900 maxhp=4000 alive=1 combat=1
```

Not a new log file: adding a `LogFile` enum entry means touching the log table and
the config schema, and `bg.log` is already small, already rotated, and already
what the WSG tooling reads. `bots.log`, by contrast, is ~10 GB — never read it
unbounded.

## Tools

```bash
./scripts/tournament/telemetry-extract.sh --instance 101 --out m.csv
./scripts/tournament/telemetry-report.sh m.csv
./scripts/tournament/bot-log-capture.sh --mark  logs/.../bots.offset   # before
./scripts/tournament/bot-log-capture.sh --since logs/.../bots.offset \
    --team stormwind-sentinels --team orgrimmar-warsong --out bots-match.log
```

`match-run.sh` calls all of these automatically and drops the artifacts in the
match's run directory.

## Reading the movement report

`stuck=1` means a bot's total travelled distance across the entire match was under
10 yards. Warsong Gulch is roughly 900 yards end to end, so that is not "played
cautiously" — it is a bot that never left its spawn. `telemetry-report.sh` exits
non-zero when any bot is stuck or fewer than 20 entered, so it works as a gate.

A high `idleSamples` with a healthy `distance` is different and less alarming: the
bot moved, then held a position. Flag carriers and defenders look like that.
```

- [ ] **Step 2: Commit**

```bash
git add docs/playerbots/TOURNAMENT-TELEMETRY.md
git commit -m "docs(telemetry): how sampling works and how to read the reports"
```

---

## Done when

- `bash tests/tournament/telemetry.test.sh` exits 0.
- With `Tournament.TelemetryIntervalMs = 0`, `grep -c "TELEMETRY tick" bg.log`
  returns 0 during a live match — proving the default really is off.
- With it set to 5000, a real match produces a `telemetry.csv`, a
  `telemetry-report.txt` naming 20 players, and a `bots-match.log` captured from a
  byte offset rather than a full-file scan.
- The movement report's `stuck` count for a real match is recorded, whatever it
  turns out to be.
