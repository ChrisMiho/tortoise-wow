---
status: done
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

**Base:** cm-main

**Branch:** backlog/three-scripts-report-success-on-a-failure-path

**Summary:** Closed three failure paths that reached the caller as clean output, all in host-side tournament tooling (no C++ change, no migration). `scripts/tournament/telemetry-extract.sh` now removes a stale CSV sitting at `--out` before exiting 1 on the no-samples path, so an earlier instance's telemetry can no longer be read as this instance's. `scripts/tournament/bot-log-capture.sh` opens `$OUT` on its own (`: > "$OUT"`) before the capture pipeline, so an unwritable path exits 2 with "cannot write <path>" instead of being mistaken for grep's legitimate "matched nothing" status 1, and a line count that is not a number is now a failure rather than the empty middle of "captured  line(s)"; it exited 0 before. `scripts/tournament/match-run.sh` clears a stale `bots.offset` at run start (the shared `logs/tournament/adhoc` dir is never cleaned, so an aborted run made the capture gate fire on the previous match's mark), and its telemetry artifact step moved into a new `scripts/tournament/lib/artifacts.sh`, where `telemetry-report.sh` is existence-checked like its sibling and an exit 127 or 126 is reported as `MISSING SCRIPT` with the bogus `telemetry-report.txt` removed, instead of being narrated as "stuck bots, or fewer than 20 entered". One regression test per case: an added case in `tests/tournament/telemetry.test.sh`, plus new `tests/tournament/botlog.test.sh` and `tests/tournament/artifacts.test.sh` (the last also drives `match-run.sh` with a non-existent team so it fails at validation before touching docker). All three new checks fail against the pre-fix scripts and pass after; the whole `tests/tournament/` suite is green (108 assertions, 0 failed).

**In-game check:** Nothing here touches mangosd, so the generic "server starts, bots spawn" smoke test covers the in-game risk; the real confirmation is host-side and almost entirely scriptable.

Fully scriptable (a later batch step can run these; no world, no build, no database):
1. From WSL: `cd <checkout> && bash tests/tournament/telemetry.test.sh && bash tests/tournament/botlog.test.sh && bash tests/tournament/artifacts.test.sh`. Expect `13 passed, 0 failed`, `4 passed, 0 failed`, `6 passed, 0 failed`, exit 0 each. Run from WSL, not Git Bash: `jq` is absent there and `require_cmd` hard-exits.
2. Regression value, also scriptable: `git stash push -u -- scripts/tournament`, re-run the three files (they report 1, 1 and 6 failures respectively), `git stash pop`.
3. Whole suite unaffected: run every `tests/tournament/*.test.sh`; all eleven must print `0 failed`.

Needs a live world, one 20-minute ad-hoc match (`scripts/tournament/match-run.sh stormwind-sentinels orgrimmar-warsong`), and someone reading `logs/tournament/adhoc/match.log` afterwards:
4. Before starting, drop a junk `logs/tournament/adhoc/bots.offset` (e.g. `printf '123456\nfp 4096 deadbeef\n'`). After the run, `bots-match.log` must hold only names from the two playing teams and its first lines must be from this match's window — not the earlier one. If the mark step fails, `match.log` must carry "no bots.offset was recorded -- skipping bot log capture" and there must be no `bots-match.log` at all.
5. With `Tournament.TelemetryIntervalMs` unset (sampling off), run a match and confirm `match.log` says "telemetry unavailable for instance <n>" and that `logs/tournament/adhoc/telemetry.csv` is absent — specifically not a CSV left over from a previous match.
6. Rename `scripts/tournament/telemetry-report.sh` aside and run a match: `match.log` must carry a line beginning "MISSING SCRIPT: .../telemetry-report.sh", must NOT carry "telemetry report flags a problem (stuck bots, or fewer than 20 entered)", and `telemetry-report.txt` must not exist. Grepping match.log for those two strings is scriptable; setting up the match is not.
7. Point `--out` at a directory (`bash scripts/tournament/bot-log-capture.sh --since <mark> --team stormwind-sentinels --out /tmp` on the live host): expect a non-zero exit and "cannot write /tmp", never "captured  line(s)". This one needs only the live bots.log, not a match.

**Minor findings:**
- scripts/tournament/telemetry-extract.sh: telemetry-extract.sh only removes a pre-existing $OUT on the no-samples path, so its exit-2 paths (missing bg.log, awk/sort failure) still leave a previous match's telemetry.csv sitting in the shared logs/tournament/adhoc run dir while match-run.sh logs "telemetry unavailable" — the same stale-artifact shape the diff fixes for bots.offset.
- scripts/tournament/bot-log-capture.sh: In capture_from, `rc=$?` after the pipeline still conflates a tail failure (deleted or unreadable bots.log mid-run, status 1 under pipefail) with grep's legitimate "no lines matched", so a failed read is reported as a clean "captured 0 line(s)" and exit 0 — the redirection case is now covered but the read case is not.
- scripts/tournament/match-run.sh: The new unconditional `rm -f "$RUN_DIR/bots.offset"` at startup mutates a run dir the diff's own comment calls SHARED by every ad-hoc match, so a second match-run launched while a first is still playing deletes the first run's offset and the first run then silently takes the "no offset file" skip branch instead of capturing its bot log — there is no lock or per-run dir guarding it.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/78, build tortoise-cm:20260819-5.
