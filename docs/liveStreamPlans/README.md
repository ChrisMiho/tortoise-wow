# Bot Battleground Tournament — plan index

The gameplan in [`gameplan.md`](gameplan.md) is the raw idea. This index is how it
was decomposed, and how to feed it to `backlog-scope` and `backlog-drain`.

**Read first:** [`docs/superpowers/specs/2026-08-16-bot-tournament-design.md`](../superpowers/specs/2026-08-16-bot-tournament-design.md)
— the decisions taken against the gameplan on 2026-08-16, the constraints inherited
from the server, and the data model. Every plan argues from it.

## The plans

Nine plans, each producing working, testable software on its own. They live in
`docs/superpowers/plans/`.

| # | Plan | Depends on | Shape |
|---|---|---|---|
| 00 | [Build provenance & stack validation gate](../superpowers/plans/2026-08-16-00-build-provenance-gate.md) | — | infrastructure |
| 01 | [Team definitions & roster lifecycle](../superpowers/plans/2026-08-16-01-team-definitions-and-rosters.md) | 00 | shell + data |
| 02 | [Tournament control plane (C++)](../superpowers/plans/2026-08-16-02-tournament-control-plane.md) | 00 | C++ |
| 03 | [Itemized gear loadouts & tiers](../superpowers/plans/2026-08-16-03-gear-loadouts.md) | 01, 02 | shell + data + C++ |
| 04 | [Bracket engine & tournament runner](../superpowers/plans/2026-08-16-04-bracket-engine.md) | 01, 02, 03 | shell |
| 05 | [Battleground telemetry & log capture](../superpowers/plans/2026-08-16-05-bg-telemetry.md) | 02, 04 | C++ + shell |
| 06 | [Viewer interaction effects](../superpowers/plans/2026-08-16-06-viewer-effects.md) | 02, 03, 04 | C++ + shell |
| 07 | [Battleground bot combat analysis](../superpowers/plans/2026-08-16-07-bg-combat-analysis.md) | 05 | investigation |
| 08 | [Spectator camera & streaming feasibility](../superpowers/plans/2026-08-16-08-spectator-camera.md) | 02, 05 | C++ + shell + assessment |
| 09 | [Release tag & 1000-bot stand-up](../superpowers/plans/2026-08-16-09-release-tag-and-1000-bot-standup.md) | all of 00-08 | closing step |

Plan 00 is not optional. Until it lands, batch-built images carry no provenance
labels and `verify-running-commit.sh` can only return `UNKNOWN` — meaning nothing
downstream can prove the server it validated against was built from this repository.

Plan 07 changes no bot AI. It produces an analysis document and one backlog artifact
per actionable finding, so each behavioural change gets reviewed against a
measurement instead of arriving inside an investigation.

Plan 09 is the closing step: raise the compiled bot-count fallbacks to 1000, stand
the full stack up and prove it settles there, then cut `tournament-v1` as an
annotated git tag and a matching image tag. It is gated on a **human** playability
check — the one thing the 2026-08-15 memory run explicitly could not verify.

## One piece of evidence is on an unpushed branch

`memory/baseline-measurement` is shelved **and local-only** — `origin` has
`memory/baseline-investigation`, which does not contain the `BOT-MEMORY-*` documents,
the raw ramp data, or `rss-trace.sh` / `rss-plateau.sh` / `bot-ramp.sh`. Plan 09
reasons from those measurements and needs those instruments. Its Task 1 pushes the
branch (pushing is not merging) and recovers the three scripts. Worth doing early
rather than at the end — right now a stray `git branch -D` costs a full night of
measurement.

## The one measurement everything waits on

Plan 02 Task 3 answers a question the source cannot: **does a playerbot acknowledge a
world port?** `BattleGround::AddPlayer` is deferred until the client acks
(`BattleGroundHandler.cpp:530`), and a bot has a `WorldSession` but no client.

- If bots ack, matches are assembled by direct instance placement.
- If they do not, Plan 02 Task 3 Step 6 documents the fallback — drive the proven
  queue path instead — and Plan 04's `match-run.sh` has both behaviours behind one
  function.

Do not let an implementer build past that task on an assumption. The verdict belongs
in `docs/playerbots/TOURNAMENT-CONTROL-PLANE.md` with literal console output.

## Feeding these to scope and drain

Two handoff prompts exist, both self-contained for a fresh agent:

- [`HANDOFF.md`](HANDOFF.md) — **scoping**: turn the plans into `docs/backlog/`
  artifacts. Carries the environment prerequisites (`jq` is not installed), the
  artifact split table, the human-only steps, and every trap found during planning.
- [`HANDOFF-PLAN-00.md`](HANDOFF-PLAN-00.md) — **executing Plan 00 directly**, as
  the supervised pilot. Plan 00 is the right first thing to run by hand: pure
  infrastructure, no live-match dependency, and everything else depends on it.

The rest of this section is the summary.

These are implementation plans, not backlog artifacts. `backlog-drain` picks up
artifacts in `docs/backlog/`, so each plan (or each task group within one) needs to
become one.

Suggested flow per plan:

1. Read the plan and adjust it — the item IDs in Plan 03, the team names in Plan 04,
   and the rate limits in Plan 06 are all opinions worth changing.
2. Run `/backlog-scope` and describe the work, pointing **Notes** at the plan file
   and section. The plan carries the detail; the artifact carries the scope,
   acceptance criteria, and dependency.
3. Set `depends-on` to match the table above. `backlog-drain` skips a pending
   artifact whose dependency has not reached `status: done`, so the chain is what
   keeps the drain from building Plan 04 before Plan 02 exists.

Splitting rule of thumb: one artifact per plan works for 00, 01, 07 and 08. Plans 02,
03, 04, 05 and 06 are each large enough that one artifact per two or three tasks
drains better, because a failed artifact is retried whole.

### Before an unattended overnight run

- `docs/backlog/README.md`'s prerequisites still apply: authenticated `gh`, a
  supervised pilot run, and a human watching the first real ticks and the first
  batch.
- These plans invoke `./scripts/rebuild.sh` **12 times** (6 in Plan 02, 1 each in
  03/05/06, 2 in Plan 08), before retries — roughly 1h54m of compiling at the
  current ~9m20s per build.

### About build times

The fast build profile is **already on and already the default**: `.wslconfig` at
16 CPU / 24 GB, `ARG BUILD_JOBS=10` (`Dockerfile:30`), and `backlog-batch.js`
already tells agents not to override it. That took the build from ~40 minutes to a
measured 9m20s — see
[`2026-08-14-docker-build-speedup-handoff.md`](../superpowers/plans/2026-08-14-docker-build-speedup-handoff.md).
There is nothing to switch on, and **nothing should pass `--build-arg BUILD_JOBS`**
unless a build OOMs, in which case retry at 4. The bound is memory per translation
unit (~1-2 GB), not CPU count.

Two further levers, both in Plan 00:

- **Task 8 (required):** `config/`, `tests/` and `logs/` — all created by these
  plans — are not in `.dockerignore`, so editing a team JSON or a test would
  invalidate `COPY . /src` and force a full recompile for a change that cannot
  affect the binary. This must land before Plan 01.
- **Task 9 (optional):** there is no ccache and no object reuse, so every rebuild
  compiles the whole tree even for a one-line change. Task 9 adds ccache on a
  BuildKit cache mount and measures whether it actually helps. Do it before
  starting the sequence or not at all — retrofitting mid-run changes
  `DOCKERFILE_SHA` and makes every earlier image report drift.
- Plan 04's live verification runs real matches at up to 25 minutes each.
- **Long-running steps write results to disk as they go**, and Plan 04's tournament
  state is explicitly resumable — a multi-hour run should never be one interruption
  away from losing everything. Note that a drain tick interrupted mid-artifact
  leaves it at `status: in-progress`, which is a human reset, not an automatic retry.

## What is deliberately not here

- Same-faction matches, and any faction override to enable them. `SetBGTeam` does not
  affect hostility (`Unit.cpp:5189`); bots placed on the wrong side spawn correctly
  and then refuse to fight. The bracket's two-ladder structure exists to avoid this.
- Concurrent matches. Only one can be streamed, so the design assumes one.
- Real Twitch/TikTok adapters. Plan 06 builds the queue and a mock; the real listener
  replaces one script.
- Video capture. Plan 08 assesses it with measured numbers rather than shipping
  plumbing an unattended run cannot verify.
- Alterac Valley. Nothing here hardcodes 10-per-side or map 489 in a way that blocks
  40v40 later, but no AV work is planned yet.
