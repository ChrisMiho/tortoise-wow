# Handoff: kicking off the bot-memory work, and when the drain comes back

Written 2026-08-14. The pick-up point for artifact
`docs/backlog/011-bot-memory-baseline-and-investigation.md`, which is run **by
hand, with a human present** — not by `backlog-drain`. Everything the drain
needs before it can be trusted again is listed at the end.

Branch: **`memory/baseline-investigation`**, cut from `cm-main` at `b886a3b`
(the merge of PR #19).

## Why 011 is not a drain artifact

The drain implements one artifact per tick inside a git worktree, then a batch
pass builds and validates. 011 fits none of that:

- Its deliverable is a measurement, so it needs the **live stack** for hours —
  the ramp alone is five bot counts each held to an RSS plateau.
- It needs the stack *during Implement*, which is where the worktree has no
  `.env` (see "Fixed already" below — the batch phase is fixed, Implement is
  not, and never needed to be for code artifacts).
- Its output is a markdown doc and shell scripts. There is no C++ to compile,
  but `backlog-batch` builds unconditionally, so it would spend a full Docker
  build to ship a document.
- Judgement calls land mid-run: which gate tripped, whether a number is a
  plateau or a login artifact, whether an optimization is capability-affecting.

Run it yourself. The drain gets the artifacts 011 *produces*.

## Fixed already — do not redo these

All landed on `cm-main` via PR #19 or on this branch. Artifact 011's tooling
table is annotated to match, so an implementer reading only the artifact will
not re-fix them either.

| Fix | Why it mattered |
|---|---|
| `scripts/task3-ramp-step.sh` compose project | It ran `docker compose` from the live stack dir, driving the **retired** `tortoise-wow-v2` project with `tw2-*` containers. Config edits landed correctly and then restarts hit containers that no longer exist — the ramp would have measured a server that never picked up the new bot count. Now every compose call goes through a `compose()` wrapper pinned to this repo via `--project-directory`. |
| `scripts/lib/provenance.sh` × 3 | Full-vs-short SHA and a dirty-count-vs-boolean would have made every verdict read `DRIFT`. The third — hashing the diverged checkout's `Dockerfile` — killed the script under `set -e` before printing anything, and was invisible until the script was actually executed. |
| `FOREIGN` verdict | Another checkout on this host publishes into the same image namespace. A foreign image passes a liveness smoke test perfectly while containing none of your code. Now rejected rather than reported as `UNKNOWN`. |
| Image/project/container rename | `tortoise-cm`, project `tortoise-cm`, containers `tcm-*`. The DB volume deliberately keeps `tortoise-wow-v2_dbdata` — it is `external: true` with an explicit `name:`, so it is pinned independently and the rename cannot strand the world. |
| `backlog-batch.js` `.env` gap | Validate ran `docker compose up -d` from a worktree where `.env` does not exist (gitignored), so it died on `${DB_PASS:?}`. Now passes `--env-file <main-checkout>/.env`, resolved via `git worktree list`. |
| `backlog-batch.js` image tag | Batch builds were tagged `tortoise-wow:<buildId>` — a third namespace belonging to nothing, so a batch image could never be rolled back to or recognised by `verify-running-commit.sh`. Now `tortoise-cm:`. |
| `backup-alive-world-pre.sh` | The off-host mirror at `/mnt/d` aborted the whole backup under `set -e` when absent — losing the primary copy at exactly the moment before configs get mutated. Mirror is now optional. |
| `check-build-progress.sh` | Was hardcoded to one closed investigation's log. Takes an argument now, else the newest `*build*.log`. |

## Running 011

All on `memory/baseline-investigation`. Steps 2–5 are the long pole; 6 and 7
are cheap once the data exists.

### 1. Claim the artifact

Set `011`'s frontmatter to `status: in-progress` **before you start**. If a
drain ever runs while you are working it, `pending` means it gets picked up
underneath you; `in-progress` is reported but never re-picked.

### 2. Back up, build, and prove identity

```bash
./scripts/backup-alive-world-pre.sh          # before anything mutates a conf
./scripts/rebuild.sh                         # ~10 min; from WSL, NOT Git Bash
docker compose up -d
./scripts/verify-running-commit.sh           # must print MATCH
```

`rebuild.sh` fails closed on Git Bash on purpose — MSYS path rewriting once
produced five false FAILs after a real 40-minute compile. Respect the guard.

`:local` currently points at `17bb757`, days behind this branch. Baseline
against HEAD, not that. **`MATCH` is the gate for every number that follows** —
this is also the first real exercise of that path, so if it reports something
unexpected, believe the script and investigate before measuring.

### 3. Intercept first

`MaxRandomBots = 0`, let the world finish loading, record RSS. This is the
single number nobody has ever taken, and the whole linear fit hangs off it —
without it you cannot separate the bot-free server footprint from per-bot cost,
which is the entire point of the artifact.

### 4. Start the capability baseline early

```bash
./scripts/bot-progression/snapshot.sh        # before
```

`report.sh` needs hours of bots actually playing to accrue levels. Start it
now and let it run underneath the ramp rather than serially after it. This is
what turns "capability-neutral" from an argument into a measurement.

### 5. Ramp

50 → 200 → 400 → 800 → 1000, each held until RSS plateaus. A sample taken
mid-login is not a plateau — bot login is staggered.

```bash
./scripts/task3-ramp-step.sh 200 apply
./scripts/task3-ramp-step.sh 200 wait 190
./scripts/task3-ramp-step.sh 200 gates
```

Stop gates: **host free ≥ 4 GB** (the tight one now — the VM holds 24 of the
host's 32 GB), VM available ≥ 2 GB, no Docker OOM or container restarts, client
still playable. Stop at the first trip and record which gate tripped at what
count.

1000 is expected to fit and is required, not optional. It was genuinely
impossible at 8 GB; at 23.5 GiB the estimate lands near 15–16 GiB. If the ramp
gates out earlier, that is a finding — record where and why.

The script still emits human-readable tables rather than CSV. Adding CSV is
part of 011's own acceptance criteria; do it before the ramp if you want the
fit to be mechanical rather than hand-transcribed.

### 6. Object census

Uncomment `MEMORY_MONITOR` at `src/modules/PlayerBots/playerbot/MemoryMonitor.h:3`,
rebuild, run at a comfortable bot count. Bring the stack down first
(`./scripts/ai-dev-profile.sh on`) — at `-j10` the build can want ~20 GB and
mangosd is holding several. This image is instrumented and carries the
monitor's overhead: **never promote it to `:local`.**

### 7. Write the doc

`docs/playerbots/BOT-MEMORY-INVESTIGATION.md`, structured like
`BOT-TRANSPORT-INVESTIGATION.md`. The plan's code items must be specific enough
that `/backlog-scope` can turn each into an artifact without re-deriving the
analysis — name the files and the mechanism, not just the subsystem. That
specificity is what makes the drain useful afterwards; a vague plan produces
vague artifacts and the loop grinds them into `failed`.

Finish with the "what we did not determine" section. It is not optional
throat-clearing — it is what stops the next reader treating an estimate as a
measurement.

## When the drain comes back

**Two separate points, in this order.**

**012 can drain independently, whenever you want.** It has no `depends-on`, it
is a conventional code change, and the `.env` blocker that would have broken
its batch pass is fixed. It still needs the pilot run below.

**The main return is after 011 lands.** Its plan's code items become artifacts
013, 014, 015… via `/backlog-scope`, and *those* are what the loop grinds
through. That is the payoff for running 011 by hand: the drain gets a queue of
bounded, individually-reviewable optimizations instead of one unbounded "make
it use less memory."

### Still required before any unattended run

- **The pilot run has never happened.** `docs/backlog/README.md` requires it:
  one throwaway artifact scoping a trivial change, one implement tick and one
  batch pass run by hand with a human watching, ending in a real PR URL. Then
  close the throwaway PR and delete its branch, worktree, and artifact. The
  two-phase flow has never completed end to end — PR #19 is the first time its
  code has even been on `cm-main`.
- **The `--env-file` fix is untested.** It is the right shape, but no batch pass
  has run since. Watch the first one.
- **`verify-running-commit.sh`'s `MATCH` path is untested** against a live
  container. Step 2 above is its first real exercise.

### Ordering note

The drain picks the lowest-numbered `pending` artifact. With 011 at
`in-progress` and 012 `pending`, 012 is what a tick would take — which is the
intended order. If you set 011 back to `pending` without finishing it, it goes
first again.

## Things that will cost you an afternoon

- **Never `docker compose down -v`.** That volume is the entire world and has
  been lost once already.
- **Do not resize the VM mid-run.** Every figure either side of a resize comes
  from a different machine and cannot be compared. If a ramp exhausts 24 GB,
  record it and stop.
- **Do not build from `/home/deck/tortoise-wow-server-V2/src`.** It is a
  diverged checkout sharing ancestor `c06b2fb`. That directory *is* still
  authoritative for `etc/`, `data/`, `logs/` and `.dbpass`, which the containers
  bind-mount — only its source tree is wrong.
- **`docker compose build` is a silent no-op** — `docker-compose.yml` pins
  `image:` with no `build:` key. Use `./scripts/rebuild.sh`.
- **The 4.67 GiB / 200-bot figure is historical**, taken under the old 8 GB
  ceiling with swap pressure that was an artifact of it. It is motivation, not
  a "before" to compare against.
