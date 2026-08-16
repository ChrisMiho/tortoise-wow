# Handoff: scope the tournament plans into backlog artifacts

Paste the section below to a fresh agent. It assumes no memory of the planning
or Plan 00 execution conversations.

---

## Your task

Convert the nine tournament plans in `docs/superpowers/plans/` into scoped
backlog artifacts under `docs/backlog/`, using the **`backlog-scope`** skill, so
that **`backlog-drain`** can implement them unattended afterwards.

Work on branch `feature/bot-tournament-plans`. It is clean and pushed.

**Scope only. Do NOT run `backlog-drain` in this session**, and do not implement
any of the work.

The nine plans, and their task counts:

| Plan | Tasks | Lines |
|---|---|---|
| `2026-08-16-01-team-definitions-and-rosters.md` | 6 | 902 |
| `2026-08-16-02-tournament-control-plane.md` | 7 | 1194 |
| `2026-08-16-03-gear-loadouts.md` | 5 | 1119 |
| `2026-08-16-04-bracket-engine.md` | 5 | 1002 |
| `2026-08-16-05-bg-telemetry.md` | 5 | 689 |
| `2026-08-16-06-viewer-effects.md` | 6 | 951 |
| `2026-08-16-07-bg-combat-analysis.md` | 4 | 441 |
| `2026-08-16-08-spectator-camera.md` | 4 | 728 |
| `2026-08-16-09-release-tag-and-1000-bot-standup.md` | 7 | 842 |

**Plan `00` (build provenance gate) is already implemented and merged into this
branch. Do not scope it.** It produced `scripts/validate-stack.sh`, the
provenance helpers, and the test harness under `tests/`.

## Read before starting

1. `docs/backlog/README.md` — the artifact format and the full status model.
2. `.claude/skills/backlog-scope/SKILL.md` — the procedure you are running.
3. `.claude/skills/backlog-drain/SKILL.md` — what will consume your output. Read
   this *before* scoping, not after; it determines what a good artifact is.
4. At least one plan end-to-end (start with `01`) before scoping anything.

---

## The decision that matters most: granularity

**A 900-line, 6-task plan is not one backlog artifact.** The artifact format is a
single scoped issue — Problem, Suspected cause, Acceptance criteria, Notes — and
`backlog-issue` implements one artifact on one branch.

Decide a rule, state it explicitly in your first message, and apply it
consistently. The suggested default:

- **One artifact per plan Task**, where that task is independently shippable.
- **Merge** tasks that are trivial on their own or meaningless when separated
  (a task that only adds a test for the task before it belongs with it).
- **Split** any task that turns out to contain two unrelated deliverables.

Do not mechanically emit 49 artifacts without judgement, and do not collapse a
plan into one artifact to save effort. Both fail — the first floods the drain
with fragments that cannot be validated independently, the second produces an
artifact no unattended agent can finish.

Report your final count and the reasoning before writing any files.

## Sequencing — this is easy to get wrong

`backlog-drain` picks **the lowest-numbered `pending` artifact** each tick. It
does not read the plans and does not infer order. So:

- **Number artifacts in dependency order.** Plan 01 creates `config/`, which
  later plans read; Plan 09 (release tag + 1000-bot stand-up) must be last.
- **Also set `depends-on:`** in the frontmatter wherever a real dependency
  exists. Numbering alone is not enough — the drain halts when every remaining
  `pending` artifact is blocked on an unready dependency, and that is the
  behaviour you want protecting you, not a silent out-of-order run.

## Numbering

- **Next artifact number is `013`.** Numbers are **never reused**, even though
  `docs/backlog/` currently holds only `README.md` — `001-012` are spent and were
  deleted after their work landed.
- `backlog-scope` derives this from git history, the `<!-- BACKLOG-COUNTER -->`
  block in `docs/backlog/README.md`, and files present, taking the highest.
- **Bump the counter block** as you go, in the same commit as the artifact.

## Acceptance criteria must be checkable without a human

The drain runs unattended. Every acceptance criterion must be something an agent
can verify from a command's output, a log line, or a file's contents.

Where a plan step genuinely needs human judgement or a human's eyes in-game, say
so plainly in **Notes**, so `backlog-issue` marks the artifact `blocked` rather
than thrashing on it or — far worse — declaring success it did not earn.

---

## What executing Plan 00 taught. Take this seriously.

**Plans contain defects.** Three of Plan 00's steps were wrong in ways that only
surfaced on execution:

- a test helper that could never work as written (it exported `PATH` from inside
  a command substitution, so the stubs never took effect),
- a measurement step that measured nothing (a `FROM scratch` probe with no
  `COPY` never loads the build context, so before/after were identical),
- an environment check that fails on this host's Docker version and, read
  literally, would have aborted the task for no reason.

So **do not transcribe plan text into acceptance criteria as gospel.** Restate
each criterion in terms of what can actually be observed. If a plan step's
expected output looks unverifiable or wrong, note it in the artifact rather than
passing the defect downstream to an unattended agent.

**Builds:**

- **Foreground only.** Backgrounded, detached or `nohup`'d builds get killed and
  BuildKit cancels them, leaving no image and no error. This cost three failed
  attempts during Plan 00 and has hit another project on this host.
- **~9.5 minutes, every time.** There is no incremental build: `COPY . /src`
  never cache-hits, so every build recompiles all ~1169 translation units
  regardless of what changed. Do not scope any work that assumes fast rebuilds,
  and do not scope a "speed up the build with ccache" artifact — it was measured
  (cold 9m07s / no-op 9m24s / one-file 9m05s, zero cache hits) and reverted.
- The batch pass now validates through `scripts/validate-stack.sh`, which
  requires `TW_SRC_DIR=<worktree>` so it compares against the branch the image
  was built from. This is already wired into `.claude/workflows/backlog-batch.js`.

## Environment rules

- **Run scripts from WSL, never Git Bash.** `rebuild.sh` fails closed on
  `$MSYSTEM` because MSYS path rewriting once produced five false FAILs on a
  good image after a 40-minute compile.
- **Never `docker compose down -v`.** `tortoise-wow-v2_dbdata` is the entire
  world. Plain `down` only.
- **`docker compose` needs `--env-file`** anywhere other than the main checkout;
  `.env` is gitignored and exists only there.
- **Always pass `TW_IMAGE` explicitly** — it defaults to `tortoise-cm:local`.
- **This host reboots itself overnight for Windows Update.** Commit as you go.

## What not to do

- Do not run `backlog-drain`. Scope only.
- Do not modify the plans themselves.
- Do not re-scope Plan 00.
- Do not implement any of the work.

## Before you finish

Report back:

1. The granularity rule you applied, and the final artifact count.
2. The dependency ordering, and which artifacts have `depends-on:` set.
3. Any plan step you could not turn into a checkable acceptance criterion —
   this matters most, because it is what an unattended drain will choke on.
4. Anything in the plans that looks wrong or already stale.

**Flag for the human before any drain starts:** Plan 00 needed human judgement
three times across nine tasks. A drain running unattended across ~49 tasks will
meet the same class of problem without anyone watching. Recommend the first
drain tick be supervised before letting it run in the background.
