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
