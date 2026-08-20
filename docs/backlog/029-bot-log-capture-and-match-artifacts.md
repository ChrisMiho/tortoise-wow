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

**Base:** cm-main

**Branch:** backlog/bot-log-capture-and-match-artifacts

**Summary:** Added `scripts/tournament/bot-log-capture.sh` with the two modes the artifact specifies: `--mark <file>` records `bots.log`'s current size via GNU `stat -c '%s'`, and `--since <file> --team <id> [--team <id>] --out <file>` reads only the bytes appended since that offset with `tail -c "+$((offset + 1))"` (1-indexed) piped through a `grep -aE "\b(name1|name2|...)\b"` alternation built from the named teams' rosters — nothing in the script reads the file from the beginning. Rotation is handled explicitly: a file now smaller than the mark warns on stderr and captures from 0, because reading on from a stale larger offset returns zero bytes and reads exactly like "the bots were quiet". Teams are run through `team_validate` before the read (an unvalidated team yields blank names, and an empty ERE alternative matches every line, so the filter would silently become no filter), and `--since` is refused without `--out` or without at least one `--team`. It reports `captured <n> line(s) from <m> byte(s) into <file>`. `scripts/tournament/match-run.sh` is wired: `--mark "$RUN_DIR/bots.offset"` immediately before the assemble step, and a new "6b. artifacts" block between the monitor loop breaking and the roster logout that runs `telemetry-extract.sh` → `telemetry-report.sh` into `<run-dir>/telemetry.csv` and `<run-dir>/telemetry-report.txt` plus `--since ... --out <run-dir>/bots-match.log`; every step there is non-fatal and logged, since the match has already been played and decided. Added `docs/playerbots/TOURNAMENT-TELEMETRY.md` covering `Tournament.TelemetryIntervalMs` (bind-mounted, no rebuild, but read only at startup so `docker restart tcm-mangosd` is required), why samples go to `bg.log` rather than a new `LogFile` enum entry, the four-tool list, the byte-offset rationale, and how to read the movement report including the 10-yards-against-a-900-yard-map reasoning for `stuck=1` and the `idleSamples`-vs-`distance` table. Finally, a dated note in `docs/playerbots/BOTS-LOG-GROWTH-HANDOFF.md` correcting the stale 12 GB figure: `scripts/cap-logs.sh` now installs `/etc/logrotate.turtle.conf` plus a 5-minute cron, `AiPlayerbot.BotLogFile` is still `bots.log` so §2's mechanism is unchanged, and measurement on 2026-08-18 shows the live file at 21 MB with two generations of 435 MB and 421 MB uncompressed five minutes apart — a write rate near 87 MB/min, ~4x the doc's 22.6 MB/min. Verified under WSL: `bash -n` exits 0 for both scripts; against a synthetic `bots.log` the capture read only the post-mark bytes (44,368 of a 298 KB file), leaked zero pre-mark lines, zero non-roster names and zero substring matches, warned and restarted from 0 on a shrunk file, and returned rc=2 for a missing `--out`, a missing `--team` and an unknown team; a 100 KB bounded read of the real 21 MB `bots.log` took 0.13 s.

**In-game check:** Nothing here changes the C++ server, so the in-game surface is only "a match still runs and now leaves evidence behind". All of it runs from WSL — `jq` and GNU `stat -c '%s'` are both absent from Git Bash on this host.

**Scriptable, no human eyes needed (a batch step can do all of this):**

1. Offset arithmetic against the live, growing log. With the stack up and bots active:
   `./scripts/tournament/bot-log-capture.sh --mark /tmp/botmark`, `sleep 60`, then
   `./scripts/tournament/bot-log-capture.sh --since /tmp/botmark --team stormwind-sentinels --out /tmp/botcap.log`.
   Expect `captured <n> line(s) from <m> byte(s) into /tmp/botcap.log` where `<m>` is roughly one minute of growth — on this box that is tens of MB, near 87 MB. **If `<m>` is in the gigabytes, or anywhere near the whole file size, the offset logic is wrong — stop.** Cross-check with `stat -c '%s' ~/tortoise-wow-server-V2/logs/bots.log` before and after; the difference should match `<m>`. Note that `/etc/cron.d/turtle-logrotate` fires every 5 minutes, so a run that straddles it prints the `bots.log shrank` warning instead — that is the rotation branch working, not a failure; re-run to get a clean window.
2. Refusals: `--since` with no `--out`, `--since` with no `--team`, and `--since --team no-such-team --out /tmp/x` must each exit 2 and print a reason.
3. `bash -n scripts/tournament/bot-log-capture.sh` and `bash -n scripts/tournament/match-run.sh` both exit 0.
4. After a real match, from the run directory: `bots.offset` exists and holds a plain integer; `bots-match.log` exists; `grep -c` for a name from each roster in `bots-match.log` is > 0, and `grep -c` for a name from a team that was NOT playing (e.g. `Ifaone` from ironforge-anvils) is 0. If `bots-match.log` is empty with no shrink warning, check `AiPlayerbot.BotLogFile` in `aiplayerbot.conf` before suspecting the capture — an empty value turns the trace off at the source.
5. Non-fatality, which is the property most worth asserting automatically: `telemetry-extract.sh` and `telemetry-report.sh` are not on this branch, so a match run right now exercises the missing-tool path. `match.log` must contain `telemetry-extract.sh is not present -- skipping telemetry artifacts`, and the run must still end with its normal `MATCH alliance=... winner=...` line and exit 0. Same for a deliberately deleted `bots.offset`: expect `no bots.offset was recorded -- skipping bot log capture` and still a `MATCH` line.

**Needs a human, and only after 027/028 land:** run
`./scripts/tournament/match-run.sh stormwind-sentinels orgrimmar-warsong --run-dir logs/tournament/telemetry-smoke`
with `Tournament.TelemetryIntervalMs = 5000` set in `~/tortoise-wow-server-V2/etc/mangosd.conf` and `docker restart tcm-mangosd` done beforehand, then read `telemetry-report.txt`: it should name 20 players with `REPORT players=20 expected=20 entered=20`. Whatever the `stuck` count turns out to be is the finding this whole telemetry series exists to produce — record it rather than treating a non-zero value as a bug in these scripts.

**Minor findings:**
- scripts/tournament/match-run.sh: match-run.sh gates the capture on `[ -f "$RUN_DIR/bots.offset" ]`, but nothing removes a stale offset file, so when `--mark` fails (or a previous run in the default shared run dir `logs/tournament/adhoc` aborted after marking) the `--since` capture runs against the previous match's offset instead of taking the "no bots.offset was recorded -- skipping" branch the code claims.
- scripts/tournament/match-run.sh: Only `telemetry-extract.sh` is existence-checked; if `telemetry-report.sh` is missing or non-executable the invocation fails with 127 and the code logs "telemetry report flags a problem (stuck bots, or fewer than 20 entered)" while writing the shell's "No such file" error into telemetry-report.txt as if it were the report.
- scripts/tournament/bot-log-capture.sh: If the `> "$OUT"` redirection fails (unwritable path), the pipeline's status is 1, which the code treats as the legitimate "grep matched nothing" case, and the subsequent `wc -l < "$OUT"` also fails — the script then prints `captured  line(s) from <m> byte(s)` with an empty count and exits 0.

**Drain note (bots.log growth claim CONFIRMED):** the Summary's correction to docs/playerbots/BOTS-LOG-GROWTH-HANDOFF.md checks out. Measured independently on the live host 2026-08-18: bots.log is 21,135,398 bytes (~21 MB, matching the claim exactly), with bots.log.1.gz at 38,699,663 bytes mtime 01:55 and bots.log.2.gz at 37,420,643 bytes mtime 01:50 -- rotations exactly five minutes apart, matching the installed cron. Both /etc/logrotate.turtle.conf and /etc/cron.d/turtle-logrotate are present as the Summary states. The ~87 MB/min write rate could not be re-measured directly because mangosd is currently down (0 bytes of growth over a 20s sample), but the rotation evidence corroborates it independently: ~435 MB uncompressed per 5-minute window is 87 MB/min, so the ~4x correction to the doc's stale 22.6 MB/min figure stands. Disk is not at risk: 950G free of 1007G, 1% used.

**Drain note (finding 2 is live TODAY, not hypothetical):** telemetry-report.sh is artifact 028, which is still `pending` -- it does not exist on any branch yet. So the unchecked invocation finding 2 describes is the state a match run hits right now, and it fails in the worst way: the shell's "No such file or directory" gets written into telemetry-report.txt as though it were the report, while the log claims the report merely "flags a problem (stuck bots, or fewer than 20 entered)". Existence-check telemetry-report.sh the same way telemetry-extract.sh already is, before 028 lands.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/39, build tortoise-cm:20260818-2.
