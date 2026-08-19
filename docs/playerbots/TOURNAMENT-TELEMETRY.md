# Battleground telemetry

A score line says who won. It cannot say whether all twenty bots actually got
into the battleground, where any of them went once they were in, or what the AI
was doing while it stood there. Telemetry answers those three questions, and the
match runner drops the answers into every run directory automatically.

---

## Turning sampling on

One key, in the bind-mounted `~/tortoise-wow-server-V2/etc/mangosd.conf`:

```ini
Tournament.TelemetryIntervalMs = 5000
```

`0` — the default — disables sampling entirely. `5000` samples every player in
every live battleground every five seconds: twenty players over a twenty-minute
match is ~4,800 lines, which is nothing next to `bg.log`'s ordinary traffic.

Two things about that file, both of which have cost time:

- **It is bind-mounted, not baked into the image.** Changing it needs no rebuild,
  so this is not an eight-and-a-half-minute round trip.
- **It is read only at startup.** `sConfig.GetIntDefault` re-reads the cached
  config, not the file, so the running world keeps whatever value it booted with.
  After editing, `docker restart tcm-mangosd` — and never mid-match, because the
  bots take minutes to come back and the roster has to be re-added.

The sampler runs inside `BattleGround::Update()`, on the world's main loop, for
every live battleground. That is precisely why it is off by default: a server
that is not running a tournament must pay nothing for it. The accumulator is a
per-instance member (`m_telemetryTimer`), not a static — two concurrent
battlegrounds sharing one counter would interleave their samples and neither
trace would be readable.

## Where the lines go, and why

`bg.log`, through `LOG_BG`, prefixed `TELEMETRY tick`:

```
TELEMETRY tick instance=101 map=489 t=125 player=Wsgaone team=469 x=1495.00 y=1480.00 z=352.00 hp=3900 maxhp=4000 alive=1 combat=1
```

Not a new log file. Adding one means a new `LogFile` enum entry, a new row in the
log table and a new config key — three edits to core plumbing to gain a file
nobody's tooling reads yet. `bg.log` is already small (tens of KB), already
rotated, and already the file the WSG runbook and `match-run.sh` read for the
winner line, so the telemetry lands where someone is already looking.

`bots.log` is the opposite case and is covered separately below.

## The tools

| Tool | Does |
|---|---|
| `scripts/tournament/telemetry-extract.sh --instance <id> --out <file>` | Pulls one instance's `TELEMETRY tick` lines out of `bg.log` as CSV (`t,player,team,x,y,z,hp,maxhp,alive,combat`). Exit 1 when nothing matched. |
| `scripts/tournament/telemetry-report.sh <csv>` | Entry and movement reports from that CSV. Exit 1 when a bot is stuck or fewer than twenty entered. |
| `scripts/tournament/bot-log-capture.sh --mark <offset-file>` | Records `bots.log`'s current size in bytes, plus a fingerprint of the 4 KB before it so rotation can be detected later. Call before the match. |
| `scripts/tournament/bot-log-capture.sh --since <offset-file> --team <id> [--team <id>] --out <file>` | Extracts only the bytes appended since that offset, filtered to the named teams' character names. |

All of them run from **WSL**, not Git Bash: `jq` (which `lib/team.sh` needs) and
GNU `stat -c '%s'` are both absent there.

`match-run.sh` calls all four itself and writes the results into the run
directory, so the ordinary way to get these artifacts is to run a match:

```
<run-dir>/bots.offset          the byte mark, taken immediately before assembly
<run-dir>/telemetry.csv        one row per player per sample
<run-dir>/telemetry-report.txt the entry + movement report
<run-dir>/bots-match.log       the playing bots' AI trace for the match window
```

Every one of those steps is non-fatal. A match that was played and decided must
report its result even if telemetry was off, so a failure here is logged into
`match.log` and dropped — it never changes the `MATCH` line and never fails the
run.

## Why `bots.log` needs a byte offset

`bots.log` is the bot AI's per-tick decision trace, ~40 lines per bot per tick,
flushed per line. It reached **12.0 GB** before `scripts/cap-logs.sh` installed
5-minute rotation; it is capped now, but capped means the live file still peaks
at **~435 MB between rotations** (measured 2026-08-18: two consecutive
generations at 435 MB and 421 MB, five minutes apart). Reading that from the
start to find one match is not slow, it is impractical — which is exactly why
nobody ever looks at it.

The cap does not soften the rule, it changes which way you get burned: with
rotation on, a match that straddles a 5-minute boundary has its offset cut out
from under it. That is the case handled below — and it is not the shrink it
looks like, because `cap-logs.sh` rotates with `copytruncate`.

`bot-log-capture.sh` never reads it from the beginning. `--mark` stats the file
before the match; `--since` reads with

```bash
tail -c "+$((offset + 1))" "$BOTS_LOG" | grep -aE "\b(Name1|Name2|...)\b"
```

`tail -c +N` is **1-indexed**, so the first byte after the mark is `offset + 1`.
The work is proportional to the match, not to the file. Anything that `cat`s,
`grep`s or `less`es the whole file is a mistake regardless of how it is spelled.

Two failure modes are handled explicitly rather than silently:

- **Rotation, which a size check alone does not see.** `cap-logs.sh` rotates with
  `copytruncate`: mangosd holds `bots.log` open, so logrotate copies it aside and
  truncates it **in place** — same path, same inode, size back to 0 — and it then
  regrows at ~87 MB/min. Test "is the file smaller than the mark?" and you catch
  only a capture that lands in the first seconds after a truncate. Twenty minutes
  and four rotations later the file is normally *larger* than the mark again, the
  test passes, and `tail -c "+$((offset + 1))"` returns an arbitrary slice of the
  **new** file — with a plausible byte count and no warning at all. Reproduced:
  a 466 KB mark, truncate, regrow to 1.5 MB, and the capture began mid-line at
  tick 5924 of a file whose tick 0 was the start of the match window.

  So the mark carries a **fingerprint** as well as a size: the sha256 of the
  4 KB before the offset, read with `dd skip=… count=…`, which is O(4 KB) and
  does not touch the rest of the file. Those bytes are immutable in an
  append-only log, so if they still hash the same the offset still means what it
  meant. Both checks are kept — the size test catches a shrink the fingerprint
  cannot see (a mark taken at offset 0, when the log was empty), and the
  fingerprint catches the regrowth the size test cannot see. The check runs
  again *after* the capture, because a rotation can also land during the read
  itself; if it did, the capture is redone from 0.

  Either way the script warns on stderr and captures from 0 — the whole new
  file, which is still bounded. Reading on from an offset into a file that was
  replaced underneath it is the one wrong answer that looks like a finding:
  zero bytes reads exactly like "the bots were quiet", and a later slice reads
  like a match that never happened.

  Know what this costs: rotation runs every five minutes, so a twenty-minute
  match crosses it about four times, and the capture then covers only the window
  since the last rotation. `bots-match.log` is a **sample of the match, not the
  whole of it**, whenever that warning appears. The rest is in
  `logs/bots.log.1.gz` / `.2.gz`, which is a deliberate non-goal here: reaching
  into rotated generations means decompressing hundreds of megabytes, which is
  the unbounded read this tool exists to avoid. If you need a full trace for one
  match, raise `size` in `/etc/logrotate.turtle.conf` (via `scripts/cap-logs.sh`,
  which owns that file) for the duration and put it back afterwards.
- **A team that does not validate** is refused before the read. `team_names` on a
  malformed file emits blank lines, and an empty alternative in an ERE matches
  *every* line — the filter would silently become no filter.

It reports `captured <n> line(s) from <m> byte(s) into <file>`. Sanity-check `<m>`
against the match: a twenty-minute match should be a few hundred MB at most. **If
`<m>` is in the gigabytes the offset logic is wrong** — stop and fix it rather
than reading the output.

If `bots-match.log` is empty and no warning was printed, the likely cause is not
the capture but `AiPlayerbot.BotLogFile = ""` in `aiplayerbot.conf`, which turns
the trace off at the source (see `BOTS-LOG-GROWTH-HANDOFF.md` §4).

## Reading the movement report

```
ENTRY player=Wsgaone team=469 firstSeen=5 samples=239
MOVEMENT player=Wsgaone distance=2841.3 maxStep=31.4 idleSamples=44 stuck=0
REPORT players=20 expected=20 entered=20 stuck=0
```

`ENTRY` answers the first question: a bot with no `ENTRY` line never appeared in
a single sample, so it never entered the battleground at all — whatever `add`
reported. `firstSeen` is how many seconds into the match it showed up.

`MOVEMENT` answers the second. `distance` is the total path length summed across
consecutive samples; `maxStep` is the largest single-sample jump.

**`stuck=1` means total travelled distance across the entire match was under 10
yards.** The threshold is deliberately not a judgement call: Warsong Gulch is
roughly 900 yards end to end, and a bot that plays badly for twenty minutes still
covers hundreds of yards flinching, turning and being knocked around. Ten yards
total is not "played cautiously" — it is a bot that never left its spawn point.
Anything in that range is a pathing or AI-activation failure, not a tactical one.

**`idleSamples` is a different measurement and much less alarming.** It counts
samples where the bot moved less than 0.01 yards since the previous one. A flag
carrier parked in the tunnel, or a defender holding the flag room, racks up a
high `idleSamples` while still showing a large `distance` — it moved, then chose
to hold position. The pair is what matters:

| `distance` | `idleSamples` | Reading |
|---|---|---|
| high | low | Roaming; normal offence |
| high | high | Moved, then held a position; a defender or flag carrier |
| low | high | **Stuck.** Never left spawn; `stuck=1` fires here |
| low | low | Rare — jittering in place, e.g. blocked pathing against geometry |

`REPORT` is the gate. `telemetry-report.sh` exits non-zero when `entered` is below
`expected` or `stuck` is above zero, so it can be used as a pass/fail check on a
match rather than only as a document. `match-run.sh` logs that non-zero status but
does not act on it — a match with stuck bots still has a real winner, and the
report is the evidence, not the verdict.
