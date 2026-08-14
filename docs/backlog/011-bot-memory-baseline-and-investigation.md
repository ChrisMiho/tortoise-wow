---
status: pending
risk: medium
area: playerbots/memory
depends-on:
---

# No attribution for bot memory — mangosd burns ~4.67 GiB at 200 bots with no idea where it goes

**Problem:** The stack cannot hold a dense world. `docs/alive-world/STATUS.md`
records mangosd at **~4.67 GiB RSS with ~201 online bots**, on an 8 GB WSL that
was already using ~1.1 GiB of swap, and slow character logins were traced to
that swapping rather than to bot count. **That figure is historical, not the
baseline** — it was taken before the VM was raised to 16 CPUs / 24 GB on
2026-08-14, so the swap pressure in it is an artifact of the old ceiling. Use it
as motivation and as a rough sanity check on the fit, never as a measured "before"
to compare a later run against; this artifact measures its own baseline. The upstream fork's owner reports
**2000 bots in 1 GB** on their Turtle server, so the gap is roughly two orders
of magnitude per bot — but their optimizations have not been shared, and it is
unknown whether the win is configuration, allocation-level code work, or an
architectural difference in how per-bot AI state is held.

Nothing in this repo attributes that 4.67 GiB. There is no per-bot marginal cost
figure and no separation between the bot-free server footprint (maps, mmaps,
DBC/world caches, InnoDB) and what each additional bot actually costs. Without
that split, "optimize memory" has no target and no way to tell a real win from
noise — the current numbers are a single data point taken by hand at one bot
count.

This artifact produces the measurement and the analysis. It ships no functional
change to the server.

**Suspected cause / area:** whole-system, but the likely concentrations are
per-bot AI state in `src/modules/PlayerBots/playerbot/strategy/`
(`AiObjectContext`, `NamedObjectContext.h`, `Engine`, `Action`/`Value` object
graphs — every bot may hold its own full instantiation of objects that could be
shared or lazily built), `PlayerbotAI.{h,cpp}`, `PlayerbotFactory.cpp` and
`RandomPlayerbotMgr.cpp` (per-bot inventory/talent construction), `TravelMgr` /
`TravelNode` / `WorldPosition` (the travel graph and any per-bot copies of it),
`RandomItemMgr.cpp` and `PlayerbotTextMgr.cpp` (large static tables), plus core
`Player`/`WorldSession` cost that a bot pays for even without a client socket.
`PlayerbotLLMInterface.cpp` and the `bots.log` trace path
(`BotLog.cpp`, see `docs/playerbots/BOTS-LOG-GROWTH-HANDOFF.md`) are also worth
pricing since both are optional.

The module already contains an unused instrument:
`src/modules/PlayerBots/playerbot/MemoryMonitor.h` implements a per-class
object census (`Add`/`Rem`/`LogCount`) gated behind a commented-out
`#define MEMORY_MONITOR` at line 3. Enabling it in an instrumented build is the
intended way to attribute object counts by class rather than guessing.

## Existing tooling — restored, do not rewrite

A set of harness scripts was recovered from an older stack tree and landed
under `scripts/` on 2026-08-14. **Extend these; do not write parallel
implementations.** They work, but they were written against a different host
layout and carry the specific defects listed below.

| Script | Role here | Known defect to repair |
|---|---|---|
| `scripts/bot-ramp.sh` | The ramp itself: `apply` sets Min/MaxRandomBots and restarts mangosd, `gates` dumps `free -h` + `docker stats` + `compose ps` + online count + the `AiPlayerbot.*` activity dials, `wait [threshold] [timeout_sec]` blocks until a threshold (plateau detection — a sample taken mid-login is not a plateau), `csv FILE [--note TXT]` appends a CSV sample and `gates`/`csv` share the same writer. | **Fixed 2026-08-14:** `TW_STACK_ROOT` override, no longer drives the retired `tortoise-wow-v2` compose project, renamed off its previous leftover-task-number name, merged with the sibling script that used to duplicate its `wait` mode (now deleted from `scripts/` — its container-status handling is folded into `wait`), and gained a 12-column CSV mode (`timestamp_utc,image_rev,target_bots,online_bots,mangosd_rss_bytes,mem_source,vm_total_bytes,vm_available_bytes,host_free_bytes,container_restarts,oom_killed,notes`) via `gates --csv FILE [--note TXT]` or standalone `csv FILE [--note TXT]`, header written once per file so a whole ramp accumulates into one CSV. Nothing left to do. |
| `scripts/lib/botdb.sh` | Read-only queries against `tcm-db`. Env-overridable already. | None known. |
| `scripts/lib/provenance.sh`, `scripts/verify-running-commit.sh` | Proves the running image was built from the commit under test. **Before/after memory numbers are meaningless without this.** | **Fixed 2026-08-14** — all three, see below. Nothing to repair; use it. |
| `scripts/ai-dev-profile.sh` | Stops mangosd + realmd, keeps `tcm-db` up. This is how the **bot-free intercept** gets measured, and how RAM is freed for a build. | **Fixed 2026-08-14** by the `tw2-*` → `tcm-*` container rename; it uses plain `docker stop/start`, so nothing else was path-dependent. |
| `scripts/backup-alive-world-pre.sh` | Snapshots `aiplayerbot.conf` and friends before the ramp mutates them. | **Fixed 2026-08-14** — the off-host mirror is now optional (`TW_BACKUP_MIRROR`) and its absence no longer aborts the primary backup. |
| `scripts/check-build-progress.sh` | Progress on a multi-hour unattended build. | **Fixed 2026-08-14** — takes a log path argument / `BUILD_LOG`, else picks the newest `*build*.log`. |
| `scripts/bot-progression/{snapshot,report,churn-report,describe}.sh` | **The capability-regression instrument** — levels gained per logged-in hour, pool churn ratio, level bands, with pass/fail thresholds. | None known. |

### What was already repaired on 2026-08-14 — do not redo it

`verify-running-commit.sh` *would* have reported **DRIFT** against every image
`rebuild.sh` produces. Three defects, all fixed:

1. `prov_head_sha()` returned the **full** SHA while `rebuild.sh` stamps
   `git rev-parse --short HEAD`, so the equality test could never pass. Now
   `prov_resolve_rev()` resolves the label through git, which normalises any
   abbreviation.
2. `prov_is_dirty()` tested the label for the string `"true"`, but
   `com.turtle.source-dirty` is stamped from `git status --porcelain | wc -l` —
   a count, never `true`, so the warning never fired on a genuinely dirty build.
3. `prov_dockerfile_sha()` hashed `$TW_LIVE_ROOT/Dockerfile` — the **diverged**
   checkout's — and returned a full digest where `rebuild.sh` stamps 12 chars.
   On a host without that path it killed the script under `set -e` before any
   verdict printed. This one was invisible to reading and only appeared on
   execution.

The same change added a **`FOREIGN`** verdict: the revision label is now
resolved *inside this repo*, so an image built by another checkout sharing the
`tortoise-*` namespace is rejected rather than passing as `UNKNOWN`. That
matters here because a foreign image can pass a liveness smoke test perfectly
while containing none of this tree's code — see `docs/DOCKER.md`, "Names are
this repo's; the Docker daemon is not". Verified against real images; the
`MATCH` path against a live container is the one case still untested.

**Acceptance criteria:**
- A new `docs/playerbots/BOT-MEMORY-INVESTIGATION.md` exists, in the same voice
  and structure as `docs/playerbots/BOT-TRANSPORT-INVESTIGATION.md`.
- `scripts/verify-running-commit.sh` reports `MATCH` against a freshly built
  image, and every measurement recorded in the doc names the image revision it
  was taken against. (Its three defects were **already fixed on 2026-08-14** —
  full-vs-short SHA, dirty-count-vs-boolean, and a Dockerfile path that pointed
  at the diverged checkout. Do not re-fix them; the remaining work is confirming
  `MATCH` against a live container, which has never been exercised.)
- `scripts/task3-ramp-step.sh` gains **CSV output** and its `wait` mode is
  merged with `wait-rndbots-online.sh`, and it is renamed to something that
  isn't a leftover task number. (Its `TW_STACK_ROOT` override and its
  wrong-compose-project bug were **already fixed on 2026-08-14** — it drove the
  retired `tortoise-wow-v2` project, so config edits landed but restarts hit
  containers that no longer exist.) **Fixed 2026-08-14:** the rename, the
  `wait` merge, and the CSV mode itself all landed too — see
  `scripts/bot-ramp.sh`. `docs/alive-world/README.md`'s reference is
  updated to the new name. That doc's other reference,
  `tests/playerbot-verify.sh`, was **also fixed 2026-08-14**: restored to this
  repo and repaired for the current `tcm-*` container names — it was missing
  entirely before.
- A **baseline ramp** is captured across at least five bot counts — 50, 200,
  400, 800, 1000 at minimum, continuing upward while stop gates hold — each
  held long enough for RSS to plateau. Stop gates: host free ≥ 4 GB (now the
  tight one — see *Environment*), VM available ≥ 2 GB, no Docker OOM or
  container restarts, client still playable. The ramp stops at the first gate
  trip and the doc records which gate tripped at what count.

  **A 1000-bot baseline is expected to fit now and is no longer optional.** The
  original idea asked for exactly that and an earlier version of this artifact
  ruled it out as impossible — correctly, against the 8 GB VM this stack ran on
  until 2026-08-14. At 23.5 GiB it is reachable: extrapolating the one figure we
  have (~4.67 GiB at ~201 bots) over a plausible 2 GiB intercept gives roughly
  13-14 MB/bot, so ~1000 bots lands near 15-16 GiB — comfortably inside the VM,
  with the host-free gate more likely to bind than the VM's own memory. Treat
  that as the estimate it is, not a prediction to defend: the measured fit
  replaces it, and if the ramp gates out earlier, record where and why.
- The **bot-free intercept** is measured, not inferred: mangosd up with
  `MaxRandomBots = 0` (or the stack under `ai-dev-profile.sh off` with bots
  disabled), RSS recorded once the world has finished loading.
- From intercept plus ramp the doc reports a **linear fit** giving the per-bot
  marginal cost in MB, and restates the 2000-in-1-GB goal as a concrete budget
  — `intercept + 2000 x slope <= 1024 MB` — with the current numbers plugged in
  so the size of the gap is stated as a number, not an adjective.
- An **object census** from an instrumented build with `MEMORY_MONITOR` enabled
  (`MemoryMonitor.h:3`) at a bot count that fits comfortably, attributing live
  object counts by class, plus per-object sizes for the top classes (`sizeof`
  from the headers, noting where the real cost is in owned heap allocations
  rather than the object itself). The doc states what fraction of the measured
  per-bot cost this census actually accounts for, and says so plainly if a
  large share is unattributed.
- A **capability baseline** is captured with `scripts/bot-progression/`:
  snapshots either side of a run long enough for `report.sh` to produce a
  meaningful levels-per-logged-in-hour figure, plus a churn ratio. This is the
  reference any later optimization is measured against.
- A **prioritized optimization plan**, each item carrying: estimated MB/bot
  saved with the reasoning behind the estimate, blast radius, risk (low/medium/
  high), and whether it is configuration-only or a code change. Items are
  ordered by saving-per-unit-risk and split into two clearly separated groups:
  **config-only wins** applicable to a running server today, and **code
  changes** that need their own artifacts. Each code item is written
  specifically enough that `/backlog-scope` can turn it into a standalone
  artifact without re-deriving the analysis — name the files and the mechanism,
  not just the subsystem.
- Every plan item is labelled **capability-neutral** or **capability-affecting**
  against the constraint below, with what the bot would lose spelled out for the
  latter, and states how `bot-progression/report.sh` would detect the
  regression. A capability-affecting item is not automatically excluded, but it
  must be ranked separately so it is never applied by accident.
- The doc ends with an explicit **"what we did not determine"** section — the
  measurements attempted and failed, the numbers that are estimates rather than
  observations, and what the upstream fork owner would need to share to close
  the remaining unknowns.
- `MaxRandomBots` in the stack's `aiplayerbot.conf` is restored to `200` and the
  stack is left running and healthy at the end of the run, whatever happened
  during the ramp.

**Notes:**

*Capability constraint — the point of the whole exercise.* Memory savings must
not cost the bots their ability to play the game like a real player would.
Rewriting a system to remove waste while preserving behaviour is explicitly in
scope, including large rewrites. Trimming what bots are allowed to think about
or do — fewer strategies, coarser decisions, shallower travel graphs, longer
update intervals that make bots visibly sluggish — is not a win and must not be
proposed as one without being labelled capability-affecting. Making bots
*smarter* is a separate goal that later work will pursue, so the plan should
prefer optimizations that leave headroom for that rather than spend it.

*Build path.* `scripts/rebuild.sh` is the only supported build: it builds from
**this** checkout to `tortoise-cm:candidate`, runs five acceptance checks, and
moves the `:local` tag only if all pass. It must run **from WSL, not Git Bash**
(it fails closed on `MSYSTEM`, because MSYS path rewriting once produced five
false FAILs after a successful compile). Budget ~10 minutes — the Docker VM
is now 16 CPUs/24GB (`C:\Users\mihov\.wslconfig`) with `BUILD_JOBS=10` as the
`Dockerfile` default (previously 4 CPUs/8GB and `BUILD_JOBS=2`, a ~40-minute
build; see `docs/DOCKER.md`). `docker compose build` is a silent no-op —
`docker-compose.yml` pins `image: tortoise-cm:local` with no `build:` key.
The instrumented `MEMORY_MONITOR` build therefore costs a full cold compile.
The heavy playerbot translation units still want 1.5-2.5 GiB per `g++`, so a
build run while the server stack is also up and consuming memory can still
OOM at `-j10` — if that happens, bring the stack down with
`ai-dev-profile.sh on` first, or drop to `BUILD_JOBS=4`.

*Source tree.* This checkout (`/mnt/c/Coding/tortoise-wow/tortoise-wow` from
WSL) is what `rebuild.sh` builds. A second, **diverged** checkout exists at
`/home/deck/tortoise-wow-server-V2/src` sharing ancestor `c06b2fb` — see
`docs/DOCKER.md` "Where the source of truth is". Do not build from it. That
directory is still live for everything else, though: `.env` bind-mounts its
`etc/`, `data/` and `logs/` into the containers and its `.dbpass` is the
database password, so the recovered scripts pointing at
`$HOME/tortoise-wow-server-V2` for **configs and logs** are correct as long as
`$HOME` resolves to `/home/deck`. Only their *source* and *build* paths are
wrong.

*Environment.* The drain has full control of the stack for this run: it may
stop/start the compose stack, edit `Min/MaxRandomBots`, and restart mangosd
repeatedly. Run `scripts/backup-alive-world-pre.sh` before the first config
change. Never `docker compose down -v` — that volume is the entire world and
has been lost once already.

**No WSL restart is needed, and none should be performed.** An earlier version
of this artifact authorised raising WSL from 8 GB to 12 GB per
`docs/alive-world/CONTINUE-LATER.md`; that is obsolete. The VM was raised to
**16 CPUs / 24 GB** on 2026-08-14 (`docker info` confirms 16 CPUs / 23.5 GiB) —
see `docs/superpowers/plans/2026-08-14-docker-build-speedup-handoff.md`. The
headroom this artifact needed already exists, so the one genuinely dangerous
step in the original scope — a `wsl --shutdown` that takes Docker's engine down
mid-run — is off the table. If a ramp ever does exhaust 24 GB, record that as a
finding and stop; do not resize the VM to push further, because every figure
either side of a resize is from a different machine and cannot be compared.

Note the host keeps only ~8 GB of its 32 GB while the VM holds 24 GB, so the
existing **host free ≥ 4 GB** stop gate is now the tight one rather than a
formality. Report host free alongside VM figures at every ramp point.

*Feasibility.* This needs a working stack per `docs/DOCKER.md` and enough bot
accounts for the ramp — `RandomBotAccountCount` is 500 per
`docs/playerbots/PLAYERBOT-AI-HANDOFF.md`, which may cap the achievable bot
count before memory does; if it does, that is a finding to record, not a
failure. If the stack cannot be brought up at all, this artifact is **blocked**,
not failed — but the static half (code analysis, object sizes, script repairs,
plan) should still be delivered, with the doc stating clearly that no
measurement was taken and every number in it is an estimate.

*Scope.* The **1000-bot** run the original idea asks for is now **in scope** —
see the ramp criterion above. The 24 GB VM changed this; it was genuinely
impossible at 8 GB.

The **2000- and 3000-bot** runs stay out of scope, and for an unchanged reason:
at an estimated ~13-14 MB/bot, 2000 bots needs roughly 29 GiB against a 23.5 GiB
ceiling. More headroom would not fix that — closing it is what the optimizations
are *for*, which is the whole point of measuring first. Those runs belong in a
follow-up artifact scoped after the plan's items land, at which point the same
ramp script re-runs and the before/after comparison is apples to apples. Note
that requirement in the doc so the CSV format is designed to make the later
comparison possible.

If the measured fit comes back materially cheaper per bot than the estimate
above, say so explicitly — it would mean 2000 bots is closer than assumed, and
that changes how ambitious the optimization plan needs to be.

*Source.* `docs/memory-efficiency/idea.md`.
