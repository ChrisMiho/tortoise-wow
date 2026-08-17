---
status: pending
risk: low
area: playerbots/battlegrounds
depends-on: 036-bg-ai-analysis-code-reading.md
---

# The flag-carrier lead is reasoning, not evidence

**Problem:** `docs/playerbots/BG-AI-ANALYSIS.md` ends with a findings table built
entirely from reading code. The strongest lead — three commented-out flag-carrier
triggers at `BattlegroundStrategy.cpp:44-51` — *predicts* 0-0 draws, but nothing
has measured whether that is what actually happens. Until it is confirmed or
refuted with data, re-enabling those triggers would be a change made on a hunch,
and relevance interacts globally: raising one action starves others.

**Suspected cause / area:** Implements
`docs/superpowers/plans/2026-08-16-07-bg-combat-analysis.md` Tasks 3-4.

**Acceptance criteria:**

- A real WSG match has been run with `Tournament.TelemetryIntervalMs = 5000`, and
  `docs/playerbots/BG-AI-ANALYSIS.md` gains **§4** naming the run directory,
  duration and result.
- §4 answers four questions with numbers, not adjectives, each with where it was
  read from:
  - Do bots leave their base at all? (`REPORT ... entered=<n> stuck=<n>`)
  - Do the two sides ever occupy the same ground? Sustained separation means they
    are not fighting, which is a **different** problem from fighting badly.
  - How much of the match is spent in combat? (share of samples with `combat=1`)
  - Was the flag ever picked up? Honor bursts of 495 in `honor.log` mark flag
    captures — that is how the first recorded match was eventually shown to be a
    2-0 Horde win rather than the scoreless draw it was first reported as
    (`docs/playerbots/WSG-BOT-MATCH.md` §6).
- §4 states plainly whether the commented-out flag-carrier triggers are
  **confirmed** as the cause of 0-0 draws with supporting telemetry, or
  **explicitly refuted**, naming the measurement that refuted them.
- §4 ranks recommendations by expected match-quality improvement per unit of
  risk, saying so explicitly — a change touching shared pathing is higher risk
  than one re-enabling a trigger.
- One `docs/backlog/<NNN>-<slug>.md` artifact exists per **actionable** finding,
  in the format `docs/backlog/README.md` specifies, each with acceptance criteria
  that are checkable. A finding that is interesting but not actionable stays in
  the analysis and gets no artifact — the backlog is work, not a notebook.
- The analysis and the artifacts cross-link: every §4 recommendation names its
  artifact path, and every artifact's **Notes** names
  `docs/playerbots/BG-AI-ANALYSIS.md` as its source.
- **No bot AI behaviour is changed by this artifact.**

**Notes:**

- **This artifact requires a running stack and a full ~25-minute match.** It needs
  `Tournament.TelemetryIntervalMs = 5000` in the live bind-mounted
  `~/tortoise-wow-server-V2/etc/mangosd.conf` followed by
  `docker restart tcm-mangosd` (the conf is read only at startup), then
  `scripts/tournament/match-run.sh` end to end, which itself needs teams created,
  geared and logged in. **If a live stack is not available, report this artifact
  blocked rather than writing §4 from reasoning.** A §4 that reads like a
  measurement but was inferred is worse than an empty §4 — the whole point of the
  section is that it is evidence.
- **`bots.log` is ~10 GB.** Use `scripts/tournament/bot-log-capture.sh --mark` /
  `--since` (artifact 029) for the match window; never an unbounded read.
- Number any new backlog artifacts by the method in `docs/backlog/README.md` —
  the highest of the git-history high-water mark, the `<!-- BACKLOG-COUNTER -->`
  block, and the files present, plus one. **Numbers are never reused.** Bump the
  counter block in the same commit.
- Leave every new artifact at `status: pending` and do not run any drain against
  them. They have not been reviewed by a human, and they were scoped by an agent
  from its own findings — that is exactly the case that wants a person to read
  them first.
- Faction skew is worth checking against `bg.log`'s winner history
  (`0`=HORDE, `1`=ALLIANCE, `2`=draw, `BattleGround.h:187-189`), but report the
  sample count alongside the ratio — a strong skew on a small sample is not
  evidence.
