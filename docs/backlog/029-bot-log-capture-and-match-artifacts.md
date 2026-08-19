---
status: done
risk: medium
area: tournament/telemetry
depends-on: 024-tournament-match-run.md
---

# A match leaves no per-bot log, and bots.log is too big to search

**Problem:** `bots.log` is ~10 GB. Finding what the playing bots did during one
20-minute match by reading it from the start is not an option, so today nobody
looks. And even when telemetry exists, a match run produces no artifacts unless
something calls the extractor and the report — so the evidence is discarded the
moment the next match starts.

**Suspected cause / area:** Implements
`docs/superpowers/plans/2026-08-16-05-bg-telemetry.md` Tasks 4-5.

**Acceptance criteria:**

- `scripts/tournament/bot-log-capture.sh` has two modes:
  - `--mark <file>` records `bots.log`'s current size in bytes;
  - `--since <file> --team <id> [--team <id>] --out <file>` extracts **only the
    bytes appended since that offset**, filtered to the named teams' character
    names.
- The read is anchored with `tail -c "+$((offset + 1))"` — 1-indexed — so the
  work is proportional to the match, not to the file. **Nothing in this script may
  read `bots.log` from the beginning.**
- Log rotation is handled explicitly: if the file is now *smaller* than the
  recorded offset it warns and captures from 0, because silently reading from a
  stale larger offset produces nothing and reads as "the bots were quiet".
- It refuses a team that fails `team_validate`, and `--since` without `--out` or
  without at least one `--team`.
- It reports `captured <n> line(s) from <m> byte(s) into <file>`.
- `scripts/tournament/match-run.sh` is wired: `--mark` immediately before the
  assemble step, and immediately after the monitor loop breaks (before the roster
  logout) `telemetry-extract.sh` → `telemetry-report.sh` into
  `<run-dir>/telemetry.csv` and `<run-dir>/telemetry-report.txt`, plus
  `--since ... --out <run-dir>/bots-match.log`.
- **Both additions are non-fatal.** Missing telemetry must never fail a match that
  was otherwise played and decided; a failure is logged, not propagated.
- `bash -n scripts/tournament/bot-log-capture.sh` and
  `bash -n scripts/tournament/match-run.sh` both exit 0.
- `docs/playerbots/TOURNAMENT-TELEMETRY.md` exists and covers: how to turn
  sampling on (`Tournament.TelemetryIntervalMs`, bind-mounted so no rebuild, but
  read only at startup so `docker restart tcm-mangosd` is required); where the
  lines go and why it is `bg.log` rather than a new log file; the tool list; and
  how to read the movement report, including the `stuck` threshold's reasoning
  and the `idleSamples`-vs-`distance` distinction.

**Notes:**

- **Run syntax checks from WSL** — `jq` is absent from Git Bash on this host, and
  `bot-log-capture.sh` sources `scripts/tournament/lib/team.sh`, which needs it at
  call time.
- This artifact edits `scripts/tournament/match-run.sh`, which is why it depends
  on artifact 024. `scripts/tournament/telemetry-extract.sh` (027) and
  `telemetry-report.sh` (028) are **not** in this branch's chain; their contracts
  are `telemetry-extract.sh --instance <id> --out <file>` (exit 1 when no samples
  matched) and `telemetry-report.sh <csv>` (exit 1 when a bot is stuck or too few
  entered). Write against those; do not execute them here.
- `stat -c '%s'` is the size read. That is GNU `stat` — another reason this runs
  under WSL rather than Git Bash.
- **Verification needing a live stack (not part of these criteria):**
  `--mark`, wait 60 s, `--since`, and confirm the reported byte count is the
  growth over that minute and **not** the whole file size. If it is in the
  gigabytes the offset logic is wrong — stop and fix it. Then run a real match and
  confirm `telemetry.csv`, `telemetry-report.txt` and `bots-match.log` are all
  present and non-empty, with the report naming 20 players.
- Record `bots.log`'s current size while doing that, and correct
  `docs/playerbots/BOTS-LOG-GROWTH-HANDOFF.md` if the ~10 GB figure is now stale —
  the constraint is real either way, but the doc should not claim a stale number.
