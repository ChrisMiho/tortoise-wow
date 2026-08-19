---
status: pending
risk: low
area: tournament/telemetry
depends-on: 029-bot-log-capture-and-match-artifacts.md
---

# Three scripts report success on a failure path

**Problem:** a cluster of the same shape — an error that reaches the caller as
clean output.

1. `telemetry-extract.sh` exits 1 on the no-samples path without touching
   `$OUT`, so a pre-existing CSV from an earlier successful run at the same path
   survives and a downstream reader that checks only the file consumes stale
   telemetry. Reproduced: a second run with `--instance 202` exits 1 while the
   earlier `--instance 101` CSV remains.
2. `bot-log-capture.sh` — if the `> "$OUT"` redirection fails on an unwritable
   path, the pipeline status is 1, which the code treats as the legitimate "grep
   matched nothing" case. The subsequent `wc -l < "$OUT"` also fails and the
   script prints `captured  line(s) from <m> byte(s)` with an empty count and
   exits 0.
3. `match-run.sh` — the bot-log capture is gated on
   `[ -f "$RUN_DIR/bots.offset" ]` but nothing removes a stale offset file, so a
   failed `--mark` or an aborted previous run in the shared
   `logs/tournament/adhoc` dir captures against the *previous* match's offset
   instead of taking the skip branch. And only `telemetry-extract.sh` is
   existence-checked, so a missing `telemetry-report.sh` fails with 127 while the
   code logs "telemetry report flags a problem (stuck bots, or fewer than 20
   entered)" and writes the shell's "No such file" error into
   `telemetry-report.txt` as if it were the report.

**Suspected cause / area:** `scripts/tournament/telemetry-extract.sh`,
`scripts/tournament/bot-log-capture.sh`, `scripts/tournament/match-run.sh`.

**Acceptance criteria:**

- A no-samples extract removes or truncates `$OUT` so no stale CSV can be read as
  current.
- An unwritable output path makes `bot-log-capture.sh` exit non-zero with a named
  error, never `exit 0` with an empty count.
- A stale `bots.offset` is cleared at run start; `telemetry-report.sh` is
  existence-checked like its sibling, and a 127 is reported as a **missing
  script**, not as a telemetry finding.
- One regression test per case.

**Notes:**

- All three are reproducible without a world and without a build.
- Run the tests from WSL; `jq` is absent from Git Bash on this host.
