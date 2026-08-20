---
status: done
risk: low
area: tournament/telemetry
depends-on:
---

# Telemetry lands in bg.log interleaved across every instance

**Problem:** The sampler writes `TELEMETRY tick` lines into `bg.log` alongside
every other battleground's samples and every other kind of `bg.log` traffic.
Filtering by instance is not optional: two concurrent battlegrounds would
otherwise produce one nonsensical trace, and there is no way to feed the result
to anything that expects tabular data.

**Suspected cause / area:** Implements
`docs/superpowers/plans/2026-08-16-05-bg-telemetry.md` Task 2.

**Acceptance criteria:**

- `scripts/tournament/telemetry-extract.sh --instance <id> [--log <path>]
  [--out <file>]` writes CSV with the header
  `t,player,team,x,y,z,hp,maxhp,alive,combat`, one row per sample, sorted by `t`
  then `player`.
- It **parses `key=value` pairs by key, not by column index.** The line format is
  stable but its field order is not something a downstream reader should depend
  on, and a key-based parse survives a field being added.
- Samples belonging to any other instance are excluded.
- Exit 1, with a message on stderr naming the instance and the log, when no
  samples matched — and the message points at the likely cause
  (`Tournament.TelemetryIntervalMs` unset, or mangosd not restarted after setting
  it). No partial or header-only output file is left behind in that case.
- `--log` defaults to `~/tortoise-wow-server-V2/logs/bg.log`; a missing log file
  is exit 2, not exit 1.
- `bash tests/tournament/telemetry.test.sh` prints `6 passed, 0 failed` and exits
  0, asserting against a committed-in-test fixture log that includes: an
  unrelated `bg.log` line, samples for the wanted instance at two different `t`
  values, and a sample for a different instance that must not appear in the
  output.

**Notes:**

- **Run the test from WSL** —
  `wsl -d Ubuntu -- bash -lc 'cd /mnt/c/<worktree path> && bash tests/tournament/telemetry.test.sh'`.
  `jq` is absent from Git Bash on this host, and `tests/lib/assert.sh`'s
  `require_cmd` is a hard `exit 1`, not a skip.
- This artifact is independent of the C++ sampler (artifact 026): the test builds
  its own fixture log, so it needs neither a build nor a server. The line format
  it parses is specified in 026's acceptance criteria — match it exactly.
- **`bots.log` is ~10 GB. Never `cat` it and never `grep` it unbounded.** This
  script reads `bg.log`, which is small and rotated — but the same discipline
  applies to anything added here later.

**Base:** cm-main

**Branch:** backlog/telemetry-extract

**Summary:** Added `scripts/tournament/telemetry-extract.sh` and `tests/tournament/telemetry.test.sh` (two new files, no C++ touched, commit 81abda4). The script takes `--instance <id> [--log <path>] [--out <file>]`, filters `bg.log` down to one battleground instance's `TELEMETRY tick` samples and writes `t,player,team,x,y,z,hp,maxhp,alive,combat`, sorted numerically by `t` then lexically by `player` (`LC_ALL=C sort -t, -k1,1n -k2,2`). The awk parse walks every whitespace field and splits on the first `=`, keying by name — never by column index — and deliberately does not anchor on `^TELEMETRY`: I checked the live `~/tortoise-wow-server-V2/logs/bg.log` (145K, 0 TELEMETRY lines as expected since 026 is not in any built image) and found `BgLogTimestamp` is ON there, so every line carries a `YYYY-MM-DD HH:MM:SS ` prefix that the plan's `^TELEMETRY tick` anchor would have silently dropped, returning zero rows and reading exactly like an unset `Tournament.TelemetryIntervalMs`. The body is assembled in a `mktemp` file and `$OUT` is only written once the row count is known, so a failed run leaves no partial or header-only CSV; a sample line missing one of the ten keys (torn write during rotation) is reported on stderr rather than silently dropped. Exit 0 = samples written, exit 1 = log readable but no samples for that instance (stderr names the instance, the log, and points at `Tournament.TelemetryIntervalMs` being unset or mangosd not restarted), exit 2 = could not run at all (bad args, non-numeric instance, missing log, unreadable log). `--log` defaults to `$HOME/tortoise-wow-server-V2/logs/bg.log`, `--out` to `telemetry-<id>.csv`. `bash tests/tournament/telemetry.test.sh` from WSL prints `6 passed, 0 failed` and exits 0 against a committed fixture holding an unrelated bg.log line, samples at t=5 and t=10, a sample for instance 999 that must not appear, and one timestamp-prefixed line whose keys are in a different order and which carries an extra `zone=` field. I also mutation-tested the suite: anchoring the match, dropping the instance filter, using a lexical sort on `t`, and writing the header before the row count is known each produce failures (2, 3, 1 and 1 respectively), so every rule the criteria name is actually pinned. No build was run (rule 4) and none is needed — this is a shell script, not compiled in.

**In-game check:** Almost all of this is judged from files and logs; only step 5 wants a human in the world, and it is optional. Note this artifact adds no server code, so the generic "server starts, bots spawn" smoke test is unaffected — nothing here is compiled in.

SCRIPTABLE, needs no server at all:
1. From WSL: `wsl -d Ubuntu -- bash -lc 'cd /mnt/c/Coding/tortoise-wow/tortoise-wow && bash tests/tournament/telemetry.test.sh'`. Expect the six `ok` lines, `6 passed, 0 failed`, exit 0. Not from Git Bash — MSYS rewrites the paths the test builds.
2. `bash scripts/tournament/telemetry-extract.sh --instance 1 --log /nonexistent.log` must exit 2 and say `FATAL: no such log:`; `--instance abc` must exit 2 and say `--instance must be a number`. Neither may exit 1.

SCRIPTABLE against the live stack, proving sampling really is off by default (needs artifact 026 in the running image; as of 2026-08-18 no image on this host has it, so this step is for after the next batch build):
3. With `Tournament.TelemetryIntervalMs` still absent/0 in `~/tortoise-wow-server-V2/etc/mangosd.conf`, run a match and then `grep -ac 'TELEMETRY tick' ~/tortoise-wow-server-V2/logs/bg.log` — it must print `0`. Then `bash scripts/tournament/telemetry-extract.sh --instance <that match's instance id>` must exit **1** (not 2, not 0) and its stderr must name the instance, name `.../logs/bg.log`, and mention `Tournament.TelemetryIntervalMs`. That exact triple is the whole diagnostic value of the exit-1 path.

SCRIPTABLE, the real end-to-end run:
4. Set `Tournament.TelemetryIntervalMs = 5000` in `~/tortoise-wow-server-V2/etc/mangosd.conf` and `docker restart tcm-mangosd` — that conf is bind-mounted and read only at startup, so no rebuild. Run `./scripts/tournament/match-run.sh stormwind-sentinels orgrimmar-warsong`, note the instance id it reports, and then:
   `./scripts/tournament/telemetry-extract.sh --instance <id> --out /tmp/m.csv`
   Expect exit 0 and a `TELEMETRY-EXTRACT instance=<id> samples=<n> out=/tmp/m.csv` line on stderr. Then check the CSV itself:
   - `head -1 /tmp/m.csv` is exactly `t,player,team,x,y,z,hp,maxhp,alive,combat`.
   - `cut -d, -f2 /tmp/m.csv | tail -n +2 | sort -u | wc -l` is 20 (fewer means bots never entered — a real finding about the bots, not about this script).
   - `cut -d, -f1 /tmp/m.csv | tail -n +2 | sort -un | head -3` rises 5, 10, 15 — and crucially `awk -F, 'NR>1{print $1}' /tmp/m.csv | uniq` must show `5` before `10`, which only a numeric sort produces.
   - No `WARNING: ... sample skipped` lines on stderr (a few after a log rotation are benign; a stream of them is a malformed sampler line).
   - The coordinates must actually change for at least some players between samples: `awk -F, 'NR>1&&$2=="Wsgaone"{print $4,$5}' /tmp/m.csv | uniq | wc -l` greater than 1. If it is 1 for every player, that is the stuck-bot pathing finding artifact 026 exists to expose, not a bug in the extractor.
5. The one genuinely in-world confirmation, and it is optional: take any row from `/tmp/m.csv`, and as a GM `.go xy <x> <y> 489` to those coordinates. You should land inside Warsong Gulch — roughly x 900-1500, y 1400-1500, z ~345-355 — rather than under the map or in Azeroth. This confirms the columns really are x,y,z in that order and were not shuffled by the key parse.

SCRIPTABLE, the criterion this artifact actually exists for:
6. Start two Warsong Gulch instances at once (two `match-run.sh` invocations, or `tournament instance` twice), extract each separately, and confirm no player name appears in both CSVs and that `wc -l` of the two files sums to the total `TELEMETRY tick` count for those two instances. One interleaved, nonsensical trace is exactly the failure this change prevents, and two concurrent battlegrounds is the only way to see it.

**Minor findings:**
- scripts/tournament/telemetry-extract.sh: On the no-samples path the script exits 1 without touching $OUT, so a pre-existing CSV from an earlier successful run at the same path survives and a downstream reader that only looks at the file (not the exit code) silently consumes stale telemetry — verified: a second run with --instance 202 exits 1 while the earlier --instance 101 CSV remains on disk with its old rows.

**Drain note:** The Summary's decision NOT to anchor the match on `^TELEMETRY tick` is correct and should be kept, but its stated cause is wrong — do not act on the reason as written. Verified against the live host on 2026-08-18: every one of the 2349 lines in /home/deck/tortoise-wow-server-V2/logs/bg.log carries a `YYYY-MM-DD HH:MM:SS ` prefix (2349 of 2349 match `^[0-9]{4}-[0-9]{2}-[0-9]{2} `), so an anchored pattern would indeed have matched zero lines and read exactly like an unset Tournament.TelemetryIntervalMs. But the Summary attributes that prefix to `BgLogTimestamp` being ON, and in the live etc/mangosd.conf `BgLogTimestamp = 0`. The prefix comes from the GLOBAL `LogTimestamp = 1`, which applies to bg.log regardless of the per-log switch (every other per-log *LogTimestamp is also 0). This matters because the intuitive "fix" for a timestamp that breaks a parser is to turn BgLogTimestamp off — it is already off, and doing so changes nothing. Anyone revisiting the parse should target LogTimestamp, or better, keep the unanchored key-based parse that tolerates either setting.

**Live evidence for artifact 017:** the same bg.log tail shows 017's commands running against the batch image tortoise-cm:20260818-1 on 2026-08-18 07:53:27 — `TOURNAMENT equip player=Wsgaten equipped=10 failed=3`, `TOURNAMENT store player=Wsgaten item=13446 count=20 ok=1 reason=ok`, `TOURNAMENT store player=Wsgaten item=8952 count=20 ok=1 reason=ok`. That is in-world confirmation that equip/store work in the built image and that store succeeds. The `failed=3` on equip is unexplained here and is worth a look when 019/gear-audit next runs: 10 of 13 required slots filled on that bot.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/38, build tortoise-cm:20260818-2.
