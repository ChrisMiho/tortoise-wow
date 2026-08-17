# Handoff: refine the tournament plans into backlog artifacts

Paste the section below to a fresh agent. Everything it needs to know is in it —
it assumes no memory of the planning conversation.

---

## Your task

Turn `docs/liveStreamPlans/gameplan.md` and the ten implementation plans in
`docs/superpowers/plans/2026-08-16-*.md` into **scoped backlog artifacts** under
`docs/backlog/`, so `backlog-drain` can implement them unattended.

You are refining and scoping, **not implementing**. Do not write tournament code.

**Branch:** `feature/bot-tournament-plans`, cut from `origin/cm-main`. Work there.

**Read first, in this order:**

1. `docs/superpowers/specs/2026-08-16-bot-tournament-design.md` — the decisions
   taken and the server constraints. Every plan argues from it.
2. `docs/liveStreamPlans/README.md` — the plan index and the dependency chain.
3. `docs/backlog/README.md` — the artifact format and lifecycle. Follow it exactly.
4. The plan you are scoping.

---

## Step 0 — do this before anything else

**`jq` is not installed in WSL Ubuntu.** Plans 01, 03, 04 and 06 read all their
JSON through it. Without it those plans cannot run at all.

```bash
sudo apt-get update && sudo apt-get install -y jq
jq --version
```

This is a host prerequisite, not a repo change — nothing to commit. It is also
Plan 00 Task 1 Step 0, so if you scope Plan 00 first the drain will hit it anyway;
doing it now avoids a wasted tick.

While you are at it, confirm the rest of the environment:

```bash
docker info >/dev/null && echo "docker ok"
git -C . status --short
gh auth status
```

---

## The single most important thing to preserve

**Plan 02 Task 3 is a measurement, not an implementation.** It answers a question
the source cannot: *does a playerbot acknowledge a world port?*
`BattleGround::AddPlayer` is deferred until the client acks
(`BattleGroundHandler.cpp:530`), and a bot has a `WorldSession` but no client.

- If bots ack → matches are assembled by direct instance placement.
- If they do not → Plan 02 Task 3 Step 6 documents a fallback (drive the proven
  queue path), and Plan 04's `match-run.sh` already has both behaviours behind one
  function.

When you scope Plan 02, make the artifact's acceptance criteria say the verdict
must be recorded in `docs/playerbots/TOURNAMENT-CONTROL-PLANE.md` **with literal
console output**, and that no further C++ may be written on an unmeasured
assumption. An implementer who guesses here builds the wrong thing for four plans.

---

## How to split the plans into artifacts

A failed artifact is retried *whole*, so size them to that.

| Plan | Artifacts | Why |
|---|---|---|
| 00 build provenance | 1 | small, infrastructural, all one concern |
| 01 rosters | 1 | six tasks but tightly coupled |
| **02 control plane** | **3** | Tasks 1-2 (scaffold + create), Task 3 (the measurement — its own artifact, it gates the rest), Tasks 4-7 |
| **03 gear** | **2** | Tasks 1-2 (audit + derive), Tasks 3-5 (tiers + apply) |
| **04 bracket** | **2** | Tasks 1-2 (bracket + state, pure logic), Tasks 3-5 (runner, needs live matches) |
| **05 telemetry** | **2** | Task 1 (C++ sampler), Tasks 2-5 (shell tooling) |
| **06 effects** | **2** | Task 1 (C++ heal/kill), Tasks 2-6 (queue + consumer) |
| 07 combat analysis | 1 | investigation; it *produces* artifacts of its own |
| 08 spectator | 1 | |
| 09 release + 1000 bots | 1 | but see "human-only steps" below |

Set `depends-on` to match `docs/liveStreamPlans/README.md`'s table. Where you split
a plan, chain the pieces in order.

---

## Notes from the planning session — carry these into the artifacts

### Things already found and fixed — do not "rediscover" them

- **Character names must be alphabetic.** The gameplan's `Wsga1…` cannot work:
  digits are rejected at character *load*, not creation, and the bot prints
  "is now online" before login is attempted. Roster names are `Wsgaone…Wsgaten`.
- **Cross-faction bracket only.** `SetBGTeam` controls scoring and spawn side but
  **not** hostility (`Unit::IsHostileTo` → faction templates, `Unit.cpp:5189`), so
  a same-faction match is bots refusing to fight. Do not scope a faction override.
- `GetTeamScore` is on `BattleGroundWS`, not the `BattleGround` base — Plan 02
  downcasts. `GetFlagCarrierGuid` **is** a base virtual, so Plan 08 needs no
  WSG-specific check.
- `backlog-batch.js` on this branch still builds into `tortoise-wow:` and cannot
  start compose from a worktree. Plan 00 Task 4 re-applies both fixes; they were
  stranded on the shelved `memory/baseline-measurement` branch.

### Things that are genuinely still open

- **Nothing in these plans has ever been executed.** Every C++ snippet is written
  against source that was read but never compiled. Expect compile errors on the
  first `./scripts/rebuild.sh` — missing includes, signature drift. That is normal
  and is **not** grounds for marking an artifact `failed`; fix and continue.
- **Gear tier files start provisional.** Plan 03 now *generates* them mechanically
  (`gear-generate.sh`) rather than requiring ~312 hand-picked item IDs up front.
  Curation is deferred and Plan 03 ends with a ready-to-use follow-up artifact in
  its "Deferred work" section — scope that one as `pending` too, with
  `depends-on` pointing at the Plan 03 artifact. Do not treat `"provisional": true`
  as an incomplete implementation.
- **A supervised pilot has never been run.** `docs/backlog/README.md` requires one
  before trusting an unattended drain. Plan 00 is a good candidate: pure
  infrastructure, no live-match dependency.

### Steps a drain fundamentally cannot do

Mark these clearly in the artifact **Notes** so `backlog-issue` recognises an
infeasible criterion instead of reporting a failure:

- **Plan 09 Task 5** — the client playability check at 1000 bots. The memory
  investigation states in bold that this is unverifiable without a human at a game
  client. It cannot be automated.
- **Plan 08 Task 2 Step 4 / Task 3 Step 5** — logging in as the GM and judging
  whether the camera cuts are watchable.
- **Plan 09 Task 7 Step 3** — cutting the actual release tag. Leave it to a human.

Scope these as artifacts that do everything automatable and then **stop and hand
back**, rather than ones that will be marked `blocked` after wasting a tick.

### Build-time guidance

- The fast profile is **already on and already the default**: `.wslconfig` at
  16 CPU / 24 GB, `ARG BUILD_JOBS=10` (`Dockerfile:30`). It took the build from
  ~40 min to a measured 9m20s.
- **Never pass `--build-arg BUILD_JOBS`** unless a build OOMs; retry at 4 if so.
  The bound is ~1-2 GB memory per translation unit, not CPU count.
- Run `rebuild.sh` from **WSL, never Git Bash** — it fails closed on `$MSYSTEM`,
  because MSYS path rewriting once made all five acceptance checks report FAIL on
  a good image after a full 40-minute compile.
- These plans call `rebuild.sh` **12 times** — roughly 1h54m of compiling. Plan 00
  Task 8 (required) and Task 9 (optional ccache) both reduce that; Task 9 must be
  done *before* the sequence starts or not at all, since it changes
  `DOCKERFILE_SHA` and makes earlier images report drift.

### Environment traps that have already cost time here

- **Git Bash mangles `rev:path` arguments.** `git cat-file -e <rev>:<path>` returns
  silent false negatives — MSYS rewrites it to `rev\path`. Use
  `git ls-tree -r --name-only <ref> -- <path>` instead, or prefix with
  `MSYS_NO_PATHCONV=1`.
- **`bots.log` is ~10 GB.** Never `cat` or unbounded-`grep` it. Plan 05 provides
  `bot-log-capture.sh`, which reads from a byte offset.
- **Console EOF shuts the world down**, and compose is `restart: "no"`. Only send
  console commands via `wsg_console`, which detaches with `ctrl-p,ctrl-q`.
- **Never `docker compose down -v`** — `tortoise-wow-v2_dbdata` is the entire world.
- **A backgrounded process does not survive `wsl -e bash -lc '...'`**; `nohup` and
  `setsid` do not save it. Anything long-running must come from an interactive WSL
  shell or a supervisor that holds the invocation open.
- **Long-running steps must write results to disk as they go**, so an interruption
  costs one unit of work rather than the whole run. A drain tick interrupted
  mid-artifact leaves it at `status: in-progress`, which needs a human reset — it
  is never retried automatically.

### One piece of evidence is on an unpushed branch

`memory/baseline-measurement` is shelved **and local-only**. It holds the
`BOT-MEMORY-*` documents, the raw ramp data, and `rss-trace.sh` / `rss-plateau.sh`
/ `bot-ramp.sh`, which Plan 09 both reasons from and needs. Plan 09 Task 1 pushes
it and recovers the three scripts. **Pushing is not merging** — the branch stays
shelved. Do this early; right now a stray `git branch -D` costs a full night of
measurement.

---

## What "done" looks like for you

- `jq` installed and verified.
- One `docs/backlog/NNN-<slug>.md` per row of the split table above, each following
  `docs/backlog/README.md` exactly: frontmatter with `status: pending`, `risk`,
  `area`, `depends-on`; then **Problem**, **Suspected cause / area**, **Acceptance
  criteria**, **Notes**.
- Every artifact's **Notes** names the plan file *and section* it implements. The
  plan carries the detail; the artifact carries the scope and the criteria.
- Acceptance criteria are **checkable**. "Bots are geared" is not; "`gear-audit.sh
  <team>` exits 0 and reports `complete=10/10`" is. Every plan already ends with a
  "Done when" section — mine it, do not invent new criteria.
- The `depends-on` chain is complete and acyclic. `backlog-drain` reports every
  remaining artifact as ineligible and stops if a chain never resolves.
- Numbering continues from the highest existing `NNN-` in `docs/backlog/`.

## What not to do

- Do not implement any tournament code.
- Do not re-litigate the spec's decisions (§2 of the design spec). They were
  settled with the user on 2026-08-16.
- Do not merge or delete `memory/baseline-measurement`.
- Do not scope Plan 09 before 00-08 have artifacts — it depends on all of them.
- Do not start an unattended drain without a supervised pilot first.
