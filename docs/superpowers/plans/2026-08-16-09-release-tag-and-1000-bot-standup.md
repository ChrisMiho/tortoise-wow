# Release Tag & 1000-Bot Full Infrastructure Stand-Up — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the tournament work with a tagged, provenance-verified build, and
stand the full stack up at 1000 bots — with the project's compiled defaults raised
to match.

**Architecture:** Recover the measurement instruments stranded on the shelved memory
branch, raise the compiled bot-count fallbacks to agree with the shipped config,
verify the two interactions nobody has measured (a playable client at 1000, and a
tournament match running alongside 1000 alive-world bots), then cut an annotated git
tag and a matching image tag.

**Tech Stack:** C++ config defaults, Bash, Docker, git tags.

**Spec:** `docs/superpowers/specs/2026-08-16-bot-tournament-design.md`

**Depends on:** every other plan in this series (00-08). This is the closing step —
do not start it until they are done.

## Global Constraints

- **Never `docker compose down -v`.** `tortoise-wow-v2_dbdata` is the entire world.
- Tag only a build that `scripts/validate-stack.sh` reports `PASS` for. A tag on an
  unverified image is worse than no tag: it looks authoritative.
- The measurement gates from the 2026-08-15 ramp still apply: **host free ≥ 4 GiB,
  VM available ≥ 2 GiB, no OOM, no unexpected restarts.**
- `PlayerSave.Interval` is 60 s, so online counts lag reality by up to a minute.
- Bot AI is **single-core**. That is why the WSG match profile deliberately shrinks
  the pool to 40 (`docs/playerbots/WSG-BOT-MATCH.md` §2.2). Memory is not the
  constraint at 1000 bots; CPU may be.

---

## What is already known about 1000 bots

**1000 bots is measured-feasible on this host.** From
`docs/playerbots/BOT-MEMORY-INVESTIGATION.md` (2026-08-15, against image
`tortoise-cm:6bace7a`, provenance-verified):

| Fact | Value |
|---|---|
| RSS at **1017 bots online** | **4.2682 GiB**, plateaued (+0.028% drift over 10 min) |
| Bot-free intercept | 3.1409 GiB — 73.6% of the 1017-bot footprint is fixed cost |
| Marginal cost per bot (settled region 417→1017) | **0.63 MiB/bot**, and falling with count |
| VM available at 1017 bots | 17.62 GiB |
| Where the ramp actually stopped | **2002 bots**, on the **Windows host-free** gate (2.37 GiB vs a 4 GiB threshold) — *not* the VM, which still had 16.80 GiB |

So the target is roughly **1.1 GiB above the bot-free intercept**, against a VM with
17+ GiB free at that point. This is not a stretch; it is a little over half the count
the ramp reached before any gate tripped.

**Two things that measurement explicitly did not establish, and this plan must:**

1. **"Client still playable" is UNVERIFIED at every bot count** — the investigation
   says so in bold, because the run was unattended and the check cannot be automated.
   Task 5 is a human check for exactly this.
2. **Nothing has ever measured 1000 alive-world bots *and* a live tournament match at
   the same time.** That is a CPU question on a single-core AI loop, and it is the
   real risk in this plan. Task 6 measures it.

> **The evidence is on one unpushed local branch.** `memory/baseline-measurement`
> exists only in this working copy — `origin` has `memory/baseline-investigation`,
> which does **not** contain the memory documents or the ramp instruments. Task 1
> deals with that before anything else, because a disk failure or a stray
> `git branch -D` currently loses a full night of measurement.

---

## File Structure

| File | Responsibility |
|---|---|
| `scripts/rss-trace.sh`, `scripts/rss-plateau.sh`, `scripts/bot-ramp.sh` (recover) | The ramp and plateau instruments, from the shelved branch |
| `src/modules/PlayerBots/playerbot/PlayerbotAIConfig.cpp` (modify) | Raise the compiled fallbacks |
| `scripts/standup-1000.sh` (create) | The full stand-up with its capacity gates |
| `scripts/release-tag.sh` (create) | Cut the annotated git tag + image tag, provenance-gated |
| `docs/playerbots/TOURNAMENT-RELEASE.md` (create) | What the tag means and how to reproduce it |

---

### Task 1: Rescue the stranded measurement work

**Files:**
- Recover: `scripts/rss-trace.sh`, `scripts/rss-plateau.sh`, `scripts/bot-ramp.sh`

**Interfaces:**
- Produces: the three instruments on this branch, plus the memory evidence pushed
  somewhere durable.

`memory/baseline-measurement` is shelved and unpushed. It holds both the evidence
this plan reasons from and the tools this plan needs. Shelving the *code* is a
decision; losing the *measurements* is an accident waiting to happen.

- [ ] **Step 1: Confirm what is actually at risk**

```bash
git branch -r | grep memory
git ls-tree -r --name-only memory/baseline-measurement -- docs/playerbots scripts \
  | grep -E "bot-memory|rss-|bot-ramp"
```

Expected: `origin/memory/baseline-investigation` exists remotely but
`origin/memory/baseline-measurement` does **not**, while the local branch holds the
`BOT-MEMORY-*` documents, the three raw data files, and the three scripts.

**Note:** use `git ls-tree ... -- <path>` with a pathspec, not
`git cat-file -e <rev>:<path>` — under Git Bash, MSYS rewrites the `rev:path`
argument and the existence check returns silent false negatives.

- [ ] **Step 2: Push the shelved branch so the evidence survives**

```bash
git push -u origin memory/baseline-measurement
```

Pushing a branch is not merging it. It stays shelved and unmerged; it simply stops
being one disk away from gone. If pushing the whole branch is unwanted, at minimum
push a docs-only branch carrying `docs/playerbots/BOT-MEMORY-*` and the three data
files.

- [ ] **Step 3: Recover the three instruments onto this branch**

```bash
git checkout memory/baseline-measurement -- \
  scripts/rss-trace.sh scripts/rss-plateau.sh scripts/bot-ramp.sh
chmod +x scripts/rss-trace.sh scripts/rss-plateau.sh scripts/bot-ramp.sh
```

These are read-only instrumentation — an RSS sampler, a plateau detector, and a ramp
driver. They carry none of the memory branch's conclusions or code changes, so
recovering them does not un-shelve anything.

- [ ] **Step 4: Confirm they run**

```bash
bash -n scripts/rss-trace.sh && bash -n scripts/rss-plateau.sh && bash -n scripts/bot-ramp.sh && echo "syntax ok"
./scripts/rss-trace.sh --help 2>&1 | head -20 || true
./scripts/bot-ramp.sh --help 2>&1 | head -20 || true
```

Read the headers. `bot-ramp.sh`'s `wait` returns `REACHED` the instant the online
count crosses its threshold, which is **not** an RSS plateau — bot inventory and
talent construction continue well past login. `rss-plateau.sh` is the instrument
that answers the plateau question, using a 20-sample (10 min) window with total
drift under 0.25% of the window's opening RSS. Do not substitute one for the other.

- [ ] **Step 5: Commit**

```bash
git add scripts/rss-trace.sh scripts/rss-plateau.sh scripts/bot-ramp.sh
git commit -m "scripts: recover the ramp and plateau instruments from memory/baseline-measurement

Read-only instrumentation only -- none of that branch's conclusions or code
changes come with them. Needed by the 1000-bot stand-up."
```

---

### Task 2: Raise the compiled bot-count defaults

**Files:**
- Modify: `src/modules/PlayerBots/playerbot/PlayerbotAIConfig.cpp:249-250`
- Modify: `src/modules/PlayerBots/playerbot/PlayerbotAIConfig.cpp:542`

**Interfaces:**
- Produces: compiled fallbacks of `minRandomBots = 1000`, `maxRandomBots = 1000`,
  `randomBotAccountCount = 500`.

- [ ] **Step 1: Understand what "the 200 default" actually is before changing it**

There are two layers, and only one of them says 200:

| Layer | Min | Max | Accounts | Applies when |
|---|---|---|---|---|
| `aiplayerbot.conf.dist.in:57-58,64` | **1000** | **1000** | **500** | always — this is the shipped config |
| `PlayerbotAIConfig.cpp:249-250,542` | 50 | **200** | 50 | only when the key is **absent** from the conf |

So the shipped configuration file already asks for 1000/1000. The `200` is the
compiled fallback used when the key is missing entirely — which means a server whose
conf omits `AiPlayerbot.MaxRandomBots` silently runs at 200 instead of the 1000 the
project's own template specifies. Raising it makes the fallback agree with the
shipped config rather than contradicting it by 5×.

Confirm both layers first:

```bash
grep -nE "^AiPlayerbot\.(Min|Max)RandomBots|^AiPlayerbot\.RandomBotAccountCount" \
  src/modules/PlayerBots/playerbot/aiplayerbot.conf.dist.in
grep -n "minRandomBots = config\|maxRandomBots = config\|randomBotAccountCount = config" \
  src/modules/PlayerBots/playerbot/PlayerbotAIConfig.cpp
```

- [ ] **Step 2: Raise the fallbacks**

```cpp
    // Fallbacks match aiplayerbot.conf.dist.in:57-58, which has shipped 1000/1000
    // since before this change. They previously read 50/200, so a server whose
    // conf omitted these keys ran at a fifth of the population the project's own
    // template asks for, with nothing to indicate why.
    //
    // 1000 is measured-safe on the reference host: 4.2682 GiB RSS at 1017 bots
    // online, plateaued, with 17.62 GiB still available in the VM. See
    // docs/playerbots/BOT-MEMORY-INVESTIGATION.md. The ramp did not trip a gate
    // until 2002 bots, and then on Windows host-free memory, not the VM.
    minRandomBots = config.GetIntDefault("AiPlayerbot.MinRandomBots", 1000);
    maxRandomBots = config.GetIntDefault("AiPlayerbot.MaxRandomBots", 1000);
```

and, at line 542:

```cpp
    // Matches aiplayerbot.conf.dist.in:64. A bot account holds at most 9-10
    // characters (PlayerbotMgr.cpp:2325), so 1000 bots need at least 100-112
    // accounts; 50 cannot hold the default population at all.
    randomBotAccountCount = config.GetIntDefault("AiPlayerbot.RandomBotAccountCount", 500);
```

- [ ] **Step 3: Build**

Run: `./scripts/rebuild.sh`
Expected: all acceptance checks `ok:`.

- [ ] **Step 4: Prove the fallback is what actually changed**

The live `aiplayerbot.conf` sets these keys explicitly, so the new fallback is
invisible unless the key is removed. Test it directly:

```bash
cp ~/tortoise-wow-server-V2/etc/aiplayerbot.conf /tmp/aiplayerbot.conf.bak
sed -i 's/^AiPlayerbot.MaxRandomBots/#AiPlayerbot.MaxRandomBots/' \
  ~/tortoise-wow-server-V2/etc/aiplayerbot.conf
docker restart tcm-mangosd
# wait for the world, then:
docker logs tcm-mangosd 2>&1 | grep -ai "maxrandombots\|random bots" | tail -5
```

Expected: the server reports a 1000 target rather than 200. Then restore:

```bash
cp /tmp/aiplayerbot.conf.bak ~/tortoise-wow-server-V2/etc/aiplayerbot.conf
docker restart tcm-mangosd
```

If the log does not report the effective value, read it back through the running
server instead — `rndbot stats` via `wsg_console` reports the pool target.

- [ ] **Step 5: Commit**

```bash
git add src/modules/PlayerBots/playerbot/PlayerbotAIConfig.cpp
git commit -m "playerbots: raise compiled bot-count fallbacks to match the shipped conf

aiplayerbot.conf.dist.in has shipped MinRandomBots/MaxRandomBots = 1000 and
RandomBotAccountCount = 500; the compiled fallbacks read 50/200/50, so a conf
missing those keys ran at a fifth of the intended population. 1000 is
measured-safe: 4.2682 GiB at 1017 bots online, VM still 17.62 GiB free."
```

---

### Task 3: Reconcile with the tournament match profile

**Files:**
- Modify: `docs/playerbots/TOURNAMENT-RUNNING.md`
- Possibly modify: `docs/playerbots/wsg/wsg-mode.sh`

`wsg-mode.sh on` deliberately shrinks the pool to `MinRandomBots = MaxRandomBots = 40`
**because bot AI is single-core**, and it snapshots the previous values so
`wsg-mode.sh off` can restore them. Raising the default to 1000 changes what gets
snapshotted, and a restore that reinstates 1000 bots mid-tournament would be a
surprise.

- [ ] **Step 1: Read what the profile actually saves and restores**

```bash
grep -n "MinRandomBots\|MaxRandomBots\|snapshot\|restore\|profile" \
  docs/playerbots/wsg/wsg-mode.sh | head -30
```

Establish: does `on` snapshot the *current* values, or write a hardcoded
`alive-world` profile? `WSG-BOT-MATCH.md` §9 documents a `--profile alive-world`
fallback for when no snapshot exists, which implies both paths exist.

- [ ] **Step 2: Round-trip it against the new default**

```bash
MSYS_NO_PATHCONV=1 bash docs/playerbots/wsg/wsg-mode.sh status
grep -nE "^[^#]*(Min|Max)RandomBots" ~/tortoise-wow-server-V2/etc/aiplayerbot.conf
MSYS_NO_PATHCONV=1 bash docs/playerbots/wsg/wsg-mode.sh on
grep -nE "^[^#]*(Min|Max)RandomBots" ~/tortoise-wow-server-V2/etc/aiplayerbot.conf   # expect 40
MSYS_NO_PATHCONV=1 bash docs/playerbots/wsg/wsg-mode.sh off
grep -nE "^[^#]*(Min|Max)RandomBots" ~/tortoise-wow-server-V2/etc/aiplayerbot.conf   # expect the pre-`on` value
```

Expected: `off` restores exactly what was there before `on`. If it restores a
hardcoded `alive-world` value instead, that value is now wrong — record what it is
and fix it to match, or make the fallback read the shipped conf.

- [ ] **Step 3: Document the interaction**

Add to `docs/playerbots/TOURNAMENT-RUNNING.md`:

```markdown
## Bot population and tournaments do not mix freely

The alive-world pool defaults to 1000 bots. `wsg-mode.sh on` drops it to 40 for the
duration of a match, on purpose: **bot AI is single-core**, and 1000 bots thinking
while 20 more play a battleground is a CPU contention problem, not a memory one.
Memory at 1000 bots is comfortable — 4.27 GiB measured — so if a match degrades,
suspect the scheduler, not RSS.

`tournament-run.sh` does not manage the pool. Run `wsg-mode.sh on` before a
tournament and `wsg-mode.sh off` after, and confirm with `wsg-mode.sh status` that
the pool was actually restored — a match left with the pool at 40 looks like a
healthy server with a mysteriously empty world.
```

- [ ] **Step 4: Commit**

```bash
git add docs/playerbots/TOURNAMENT-RUNNING.md docs/playerbots/wsg/wsg-mode.sh
git commit -m "docs(tournament): reconcile the 1000-bot default with the match profile"
```

---

### Task 4: `standup-1000.sh` — the full stand-up with gates

**Files:**
- Create: `scripts/standup-1000.sh`

**Interfaces:**
- Produces: `standup-1000.sh [--target 1000] [--out <dir>]` — brings the stack up,
  ramps to the target, holds to a measured plateau, and reports
  `STANDUP target=<n> online=<n> rss=<GiB> vmAvailable=<GiB> hostFree=<GiB> plateau=<0|1> verdict=<PASS|FAIL>`.
  Exit 0 only on `PASS`.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Stand the full stack up at N bots and prove it settled there.
#
#   ./scripts/standup-1000.sh --target 1000 --out logs/standup/$(date -u +%Y%m%dT%H%M%SZ)
#
# Reference measurement (2026-08-15, image tortoise-cm:6bace7a):
#   1017 bots online -> 4.2682 GiB RSS, plateaued, VM available 17.62 GiB.
#   The ramp did not trip a gate until 2002 bots, and then on WINDOWS HOST free
#   memory (2.37 GiB vs a 4 GiB threshold), not the VM.
# So a result materially above ~4.3 GiB at 1000 is a regression worth chasing,
# not a new normal.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/provenance.sh"

TARGET=1000
OUT="$ROOT/logs/standup/$(date -u +%Y%m%dT%H%M%SZ)"
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --out)    OUT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
mkdir -p "$OUT"

# Gates from the 2026-08-15 ramp. The host gate is the one that actually bit.
HOST_FREE_MIN_GIB=4
VM_AVAIL_MIN_GIB=2
# 4.2682 GiB was measured at 1017 bots. Allow headroom for a larger world and a
# different image, but not so much that a real regression passes.
RSS_MAX_GIB=6.0

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$OUT/standup.log"; }
gib() { awk -v b="$1" 'BEGIN { printf "%.4f", b / 1073741824 }'; }

# --- 1. the image must be ours, and verified -------------------------------
log "verifying provenance before standing anything up"
if ! "$HERE/validate-stack.sh" --image "${TW_IMAGE:-tortoise-cm}:local" \
        --env-file "$ROOT/.env" --keep-up | tee -a "$OUT/standup.log" | grep -q "VALIDATE-STACK: PASS"; then
    echo "STANDUP target=$TARGET verdict=FAIL reason=stack_validation_failed" | tee -a "$OUT/standup.log"
    exit 1
fi

# --- 2. set the pool target ------------------------------------------------
CONF="${TW_LIVE_ROOT:-$HOME/tortoise-wow-server-V2}/etc/aiplayerbot.conf"
cp "$CONF" "$OUT/aiplayerbot.conf.before"
sed -i "s/^AiPlayerbot.MinRandomBots.*/AiPlayerbot.MinRandomBots = $TARGET/" "$CONF"
sed -i "s/^AiPlayerbot.MaxRandomBots.*/AiPlayerbot.MaxRandomBots = $TARGET/" "$CONF"
log "pool target set to $TARGET; restarting mangosd to apply"
docker restart "$TW_MANGOSD" >/dev/null

until prov_world_ready; do sleep 5; done
log "world is up"

# --- 3. trace while it ramps ----------------------------------------------
# Written continuously to disk: this host reboots itself overnight for Windows
# Update, and a trace held in memory until the end would be lost entirely.
#
# rss-trace.sh takes NO command-line flags -- it is configured entirely by
# TW_RSS_TRACE / TW_RSS_INTERVAL / TW_STACK_ROOT. Passing --out to it does not
# error; it is ignored, and the trace silently lands at the script's default
# /home/deck/rss-watch.tsv instead of where this script expects it.
export TW_RSS_TRACE="$OUT/rss-trace.tsv"
export TW_RSS_INTERVAL=30
export TW_STACK_ROOT="${TW_LIVE_ROOT:-$HOME/tortoise-wow-server-V2}"

"$HERE/rss-trace.sh" >/dev/null 2>&1 &
TRACE_PID=$!
trap 'kill "$TRACE_PID" 2>/dev/null || true' EXIT
sleep 5
if ! kill -0 "$TRACE_PID" 2>/dev/null || [ ! -s "$TW_RSS_TRACE" ]; then
    # rss-trace.sh's own header records this: a process backgrounded inside
    # `wsl.exe -e bash -lc '...'` is torn down when that invocation returns, and
    # nohup/setsid do NOT save it (observed 2026-08-15). Every gate below reads
    # the trace, so a dead sampler must fail here rather than 90 minutes later.
    log "FAIL: rss-trace did not start or is writing nothing to $TW_RSS_TRACE"
    log "      Run this script from an interactive WSL shell, not a wrapped"
    log "      'wsl -e bash -lc' one-liner -- backgrounded processes do not survive that."
    echo "STANDUP target=$TARGET verdict=FAIL reason=trace_not_running" | tee -a "$OUT/standup.log"
    exit 1
fi
log "rss-trace running (pid $TRACE_PID) -> $TW_RSS_TRACE"

# --- 4. wait for the count, then for the PLATEAU ---------------------------
# These are two different things. bot-ramp.sh's `wait` returns REACHED the moment
# the online count crosses the threshold, but inventory and talent construction
# continue well past login, so RSS is still climbing at that point. The count is
# the start of the measurement, not the end of it.
log "waiting for $TARGET bots online"
deadline=$(( $(date +%s) + 5400 ))
while :; do
    online="$(prov_online_count)"
    log "online=${online:-0}/$TARGET"
    [ "${online:-0}" -ge "$TARGET" ] && break
    if [ "$(date +%s)" -ge "$deadline" ]; then
        log "FAIL: only ${online:-0}/$TARGET online after 90 minutes"
        echo "STANDUP target=$TARGET online=${online:-0} verdict=FAIL reason=ramp_timeout" | tee -a "$OUT/standup.log"
        exit 1
    fi
    sleep 60
done
log "count reached; now holding for an RSS plateau"

# rss-plateau.sh's $1 is a WINDOW SIZE IN SAMPLES, not a path -- it reads the
# trace from TW_RSS_TRACE (exported above) and rejects a non-integer argument
# outright. 20 samples at 30s is the 10-minute window the 2026-08-15 ramp used,
# with the same 0.25% drift criterion.
plateau=0
deadline=$(( $(date +%s) + 3600 ))
while :; do
    if "$HERE/rss-plateau.sh" 20 2>&1 | tee -a "$OUT/standup.log" | grep -q "PLATEAU"; then
        plateau=1; break
    fi
    [ "$(date +%s)" -lt "$deadline" ] || { log "WARN: no plateau within 60 min of reaching the count"; break; }
    sleep 120
done

# --- 5. gates --------------------------------------------------------------
# Column index confirmed against the trace's own header before use -- rss-trace.sh
# writes a header row, and hardcoding a position here would silently read the
# wrong field if that schema ever gains a column.
RSS_COL="$(head -1 "$TW_RSS_TRACE" | tr '\t' '\n' | grep -n '^rss_kb$' | cut -d: -f1)"
[ -n "$RSS_COL" ] || { log "FAIL: no rss_kb column in $TW_RSS_TRACE"; exit 1; }
RSS_KB="$(awk -v c="$RSS_COL" -F'\t' 'NR>1 && $c != "" { v = $c } END { print v }' "$TW_RSS_TRACE")"
RSS_B=$(( ${RSS_KB:-0} * 1024 ))
RSS_GIB="$(gib "${RSS_B:-0}")"
online="$(prov_online_count)"

VM_AVAIL_GIB="$(awk '/MemAvailable/ { printf "%.2f", $2 / 1048576 }' /proc/meminfo)"
# Host free is a Windows number and needs PowerShell interop. It is the gate that
# actually tripped at 2002 bots, so its absence must not read as a pass.
HOST_FREE_GIB="$(powershell.exe -NoProfile -Command \
  '(Get-CIMInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB' 2>/dev/null | tr -d '\r' | awk '{printf "%.2f", $1}')"
[ -n "$HOST_FREE_GIB" ] || HOST_FREE_GIB="unknown"

verdict=PASS; reason="-"
awk -v r="$RSS_GIB" -v m="$RSS_MAX_GIB" 'BEGIN { exit !(r > m) }' \
    && { verdict=FAIL; reason="rss_above_${RSS_MAX_GIB}GiB"; }
awk -v v="$VM_AVAIL_GIB" -v m="$VM_AVAIL_MIN_GIB" 'BEGIN { exit !(v < m) }' \
    && { verdict=FAIL; reason="vm_available_below_${VM_AVAIL_MIN_GIB}GiB"; }
if [ "$HOST_FREE_GIB" != "unknown" ]; then
    awk -v h="$HOST_FREE_GIB" -v m="$HOST_FREE_MIN_GIB" 'BEGIN { exit !(h < m) }' \
        && { verdict=FAIL; reason="host_free_below_${HOST_FREE_MIN_GIB}GiB"; }
else
    log "WARN: host free memory could not be read — the gate that tripped at 2002 bots is UNCHECKED"
fi
[ "$online" -ge "$TARGET" ] || { verdict=FAIL; reason="online_below_target"; }

printf 'STANDUP target=%s online=%s rss=%s vmAvailable=%s hostFree=%s plateau=%s verdict=%s reason=%s\n' \
    "$TARGET" "$online" "$RSS_GIB" "$VM_AVAIL_GIB" "$HOST_FREE_GIB" "$plateau" "$verdict" "$reason" \
    | tee -a "$OUT/standup.log"

[ "$verdict" = "PASS" ]
```

- [ ] **Step 2: Run it**

```bash
./scripts/standup-1000.sh --target 1000 --out logs/standup/first
```

Expected: `STANDUP target=1000 online=~1000 rss=~4.3 ... plateau=1 verdict=PASS`.

Budget up to 2.5 hours — the ramp alone took the reference run a long time, and the
plateau hold is deliberately patient.

**Compare `rss` against 4.2682 GiB.** Materially above that at 1000 bots is a
regression introduced somewhere in Plans 00-08, not a new baseline — the tournament
work adds a per-battleground telemetry sampler and a handful of commands, none of
which should move a 3.14 GiB intercept.

- [ ] **Step 3: Commit**

```bash
git add scripts/standup-1000.sh
git commit -m "scripts: 1000-bot stand-up with the ramp's own capacity gates

First run: <paste the STANDUP line>"
```

---

### Task 5: Verify the thing that has never been verified

**Files:**
- Create: `docs/playerbots/TOURNAMENT-RELEASE.md` (the capacity section)

`BOT-MEMORY-INVESTIGATION.md` states in bold that **"client still playable" is
UNVERIFIED at every bot count**, because the run was unattended and the check cannot
be automated. It still cannot. This task is explicitly a **human** step.

- [ ] **Step 1: With 1000 bots online, log in and use the client**

Connect a real client to the realm and check, writing down what you observe:

| Check | What to record |
|---|---|
| Character select loads | time in seconds |
| Enter world | time in seconds |
| Frame rate in a capital city | approximate fps, and whether it is playable |
| Frame rate in an empty zone | approximate fps |
| Movement responsiveness | any rubber-banding? |
| `.gm on` + `.appear <bot>` | does it complete? |
| Chat / spell response latency | subjective, but say which |

- [ ] **Step 2: Record the answer honestly**

Write it into `docs/playerbots/TOURNAMENT-RELEASE.md`:

```markdown
## Capacity at 1000 bots

Memory (automated): <paste the STANDUP line>. Reference from 2026-08-15 was
4.2682 GiB at 1017 bots.

Playability (human check, <date>): <the table from Step 1>.

Verdict: <playable / degraded but usable / not playable>.
```

**If the client is not playable at 1000, say so and stop.** Do not tag a release
whose headline claim is a population nobody can join. The correct response is to
find the highest playable count by bisecting with `standup-1000.sh --target N` and
record *that* as the supported figure — the compiled default can stay at 1000 while
the documented supported population is lower, as long as the document says which is
which and why.

- [ ] **Step 3: Commit**

```bash
git add docs/playerbots/TOURNAMENT-RELEASE.md
git commit -m "docs(release): record the 1000-bot playability check"
```

---

### Task 6: Measure a tournament match against a full world

**Files:**
- Modify: `docs/playerbots/TOURNAMENT-RELEASE.md`

This is the interaction nobody has measured, and the one most likely to disappoint:
**bot AI is single-core.** The WSG match profile shrinks the pool to 40 for exactly
this reason. Whether a tournament match is watchable with 1000 bots also thinking is
an open question, and the whole point of the tournament is that it is watchable.

- [ ] **Step 1: Baseline a match at the tournament profile**

```bash
MSYS_NO_PATHCONV=1 bash docs/playerbots/wsg/wsg-mode.sh on     # pool -> 40
./scripts/tournament/match-run.sh stormwind-sentinels orgrimmar-warsong \
  --run-dir logs/tournament/cap-baseline
```

Record from `telemetry-report.txt`: `entered`, `stuck`, and the match duration and
winner. This is the control.

- [ ] **Step 2: Run the same match against the full world**

```bash
MSYS_NO_PATHCONV=1 bash docs/playerbots/wsg/wsg-mode.sh off    # pool back to 1000
./scripts/standup-1000.sh --target 1000 --out logs/standup/withmatch
# once it reports PASS, WITHOUT shrinking the pool:
./scripts/tournament/match-run.sh stormwind-sentinels orgrimmar-warsong \
  --run-dir logs/tournament/cap-full
```

While it runs, sample CPU:

```bash
docker stats --no-stream tcm-mangosd
```

- [ ] **Step 3: Compare the two, on the numbers that matter**

```bash
diff <(cat logs/tournament/cap-baseline/telemetry-report.txt) \
     <(cat logs/tournament/cap-full/telemetry-report.txt) || true
```

The telemetry sampler from Plan 05 makes this measurable rather than subjective. The
questions:

| Question | Where to read it |
|---|---|
| Did all 20 bots still enter? | `REPORT ... entered=` |
| Did more bots go stuck? | `REPORT ... stuck=` |
| Did bots move less? | `MOVEMENT ... distance=` per bot, compared |
| Was mangosd CPU-saturated? | `docker stats` during the match |
| Did the match still reach a result? | the `MATCH ... winner=` line |

- [ ] **Step 4: Write the recommendation**

```markdown
## Running a tournament against a full world

Baseline (pool 40): <numbers>.
Full world (pool 1000): <numbers>.
mangosd CPU during the full-world match: <number>.

Recommendation: <run tournaments with `wsg-mode.sh on`, or the full world is fine>.
```

A degradation here is not a failure of this plan — it is the answer, and it is worth
knowing before a stream depends on it. If matches degrade, the operational answer is
already built: `wsg-mode.sh on` before a tournament, `off` after.

- [ ] **Step 5: Commit**

```bash
git add docs/playerbots/TOURNAMENT-RELEASE.md
git commit -m "docs(release): measure a tournament match against a 1000-bot world"
```

---

### Task 7: Cut the release tag

**Files:**
- Create: `scripts/release-tag.sh`
- Modify: `docs/playerbots/TOURNAMENT-RELEASE.md`

**Interfaces:**
- Produces: `release-tag.sh <tag-name> [--push]` — refuses unless the tree is clean
  and the running image is provenance-verified at HEAD, then creates an annotated
  git tag and an image tag pointing at the same commit.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Cut a release tag for a build that has been verified, not merely built.
#
#   ./scripts/release-tag.sh tournament-v1 --push
#
# Refuses on a dirty tree or an unverified image. A tag on an unverified build is
# worse than no tag: it looks authoritative and is not.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/provenance.sh"

TAG="${1:-}"; PUSH=0
[ -n "$TAG" ] || { echo "usage: release-tag.sh <tag-name> [--push]" >&2; exit 2; }
[ "${2:-}" = "--push" ] && PUSH=1

# A tag naming a commit that does not describe the binary is the exact failure
# this repo already built provenance tooling to prevent.
if prov_is_dirty; then
    echo "FATAL: working tree is dirty. Commit or stash before tagging." >&2
    prov_git status --short >&2
    exit 1
fi

SHA="$(prov_head_sha)"
SHORT="$(prov_short_sha)"
echo "HEAD: $SHA ($SHORT) on $(prov_branch)"

echo "==> verifying the running server is built from HEAD"
if ! "$HERE/verify-running-commit.sh"; then
    echo "FATAL: the running server is not built from HEAD. Ship it first, then tag." >&2
    exit 1
fi

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "FATAL: tag '$TAG' already exists. Pick another name; never move a release tag." >&2
    exit 1
fi

git tag -a "$TAG" -m "$(cat <<EOF
$TAG

Bot battleground tournament, end of the 2026-08-16 plan series.

Commit:  $SHA
Image:   ${TW_IMAGE}:$SHORT
Verified by scripts/verify-running-commit.sh at tag time.

See docs/playerbots/TOURNAMENT-RELEASE.md for the capacity measurements and
what this build was verified to do.
EOF
)"
echo "==> created annotated tag $TAG"

# Tag the image with the release name too, so the rollback path in docs/DOCKER.md
# works by name rather than by remembering a SHA.
if docker image inspect "${TW_IMAGE}:${SHORT}" >/dev/null 2>&1; then
    docker tag "${TW_IMAGE}:${SHORT}" "${TW_IMAGE}:${TAG}"
    echo "==> tagged image ${TW_IMAGE}:${TAG}"
else
    echo "WARNING: no image ${TW_IMAGE}:${SHORT} on this host, so no image tag was made." >&2
    echo "         The git tag stands; rebuild and 'docker tag' it by hand to complete the pair." >&2
fi

if [ "$PUSH" -eq 1 ]; then
    git push origin "refs/tags/$TAG"
    echo "==> pushed $TAG"
else
    echo "not pushed. To publish:  git push origin refs/tags/$TAG"
fi
```

- [ ] **Step 2: Dry-run the refusals before trusting the accept path**

A gate that has never been seen to refuse is not known to work:

```bash
touch /tmp/dirt && cp /tmp/dirt ./dirty-probe
./scripts/release-tag.sh probe-tag; echo "exit=$?"     # expect FATAL dirty tree, exit 1
rm -f ./dirty-probe
```

Expected: refusal on the dirty tree, exit 1, and **no tag created**
(`git tag -l probe-tag` is empty).

- [ ] **Step 3: Cut the real tag**

Only after Tasks 4, 5 and 6 have all passed and been committed:

```bash
./scripts/rebuild.sh
docker compose --env-file .env up -d
./scripts/validate-stack.sh --image tortoise-cm:local --keep-up
./scripts/release-tag.sh tournament-v1 --push
```

Expected: `VALIDATE-STACK: PASS`, then `created annotated tag tournament-v1`,
`tagged image tortoise-cm:tournament-v1`, and a successful push.

- [ ] **Step 4: Finish the release document**

```markdown
# Tournament release — `tournament-v1`

Cut <date> from `<commit sha>`.

## What this build is

The bot battleground tournament: JSON-defined teams, itemized gear tiers, a
console-callable `.tournament` control plane, a resumable bracket runner,
battleground telemetry, viewer-triggered effects, and a spectator camera. Plans
`docs/superpowers/plans/2026-08-16-00` through `-09`.

## What was verified at tag time

| Check | Result |
|---|---|
| Tree clean, image built from HEAD | `verify-running-commit.sh` → MATCH |
| Stack stands up correctly | `validate-stack.sh` → PASS |
| 1000-bot capacity | <the STANDUP line> |
| Client playable at 1000 | <the human check verdict> |
| Tournament match against a full world | <the comparison verdict> |

## Rolling back to it

```bash
sed -i 's|^TW_IMAGE=.*|TW_IMAGE=tortoise-cm:tournament-v1|' .env
docker compose --env-file .env up -d
```

Set `TW_IMAGE` back to `tortoise-cm:local` once you have rebuilt a good image.
Retagging `:local` is not enough — if `.env` names a different tag, compose
resolves that one, sees no change, and relaunches the very image you are rolling
back from.

## Defaults changed in this release

`AiPlayerbot.MinRandomBots` / `MaxRandomBots` compiled fallbacks: 50 / 200 → 1000 /
1000. `RandomBotAccountCount`: 50 → 500. These now agree with
`aiplayerbot.conf.dist.in`, which has shipped 1000/1000/500 all along — a conf
missing those keys previously ran at a fifth of the intended population.
```

- [ ] **Step 5: Commit**

```bash
git add scripts/release-tag.sh docs/playerbots/TOURNAMENT-RELEASE.md
git commit -m "release: tournament-v1 tagging script and release record"
```

---

## Done when

- `memory/baseline-measurement` is pushed, so the 2026-08-15 measurements are no
  longer one disk failure from gone.
- The compiled fallbacks read 1000 / 1000 / 500, verified by removing the key from
  the live conf and observing the new value take effect.
- `wsg-mode.sh on` → `off` round-trips the pool size correctly against the new
  default.
- `standup-1000.sh --target 1000` reports `verdict=PASS`, with RSS in the region of
  the 4.2682 GiB reference rather than materially above it.
- The **human** playability check at 1000 bots is recorded with a plain verdict.
- A tournament match has been run against a 1000-bot world and compared against the
  pool-40 baseline, with a stated recommendation.
- `tournament-v1` exists as an annotated git tag **and** a `tortoise-cm:tournament-v1`
  image tag, both cut from a clean tree whose running image verified as `MATCH`.
- `release-tag.sh` has been *seen* to refuse a dirty tree.
