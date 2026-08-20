---
status: done
risk: low
area: tournament/control-plane
depends-on:
---

# Nothing parses the control plane's output, and the format is undocumented

**Problem:** The `.tournament` commands emit machine-parseable `TOURNAMENT `
lines, but every caller would have to re-invent the parsing, and the console
prints a great deal besides — `rndbot`-style replies vanish into a null player
session entirely. Without one parser there is no single place that breaks when the
C++ output format changes, so it would drift silently. The output contract itself
is also unwritten, and so is the one open question the whole design hangs on.

**Suspected cause / area:** Implements
`docs/superpowers/plans/2026-08-16-02-tournament-control-plane.md` Task 7.

**Acceptance criteria:**

- `scripts/tournament/lib/ctl.sh` is sourceable (never executed) and provides:
  - `ctl <command...>` — sends one console command via `wsg_console` and echoes
    **only** lines beginning `TOURNAMENT `, never failing the caller when there
    are none.
  - `ctl_field <captured-output> <key>` — the value of one `key=` field.
  - `ctl_create <bgTypeId> <level>` — echoes the new instance id; exit 1 with the
    reason on stderr if the server reported an `error=` instead, and exit 1 with
    the raw output on stderr if no instance id came back.
- `ctl_field` is anchored so a key that is a prefix of another does not match the
  wrong one, and so a field whose value is `0` reads as `0`, not as empty.
- `bash tests/tournament/ctl.test.sh` prints `6 passed, 0 failed` and exits 0,
  covering at minimum: extracting `instance` and `map` from a line surrounded by
  unrelated console noise; a missing key returning empty; `ok=1` not being
  confused with a longer key; `slot=0` reading `0`; and extracting an `error=`
  reason.
- `docs/playerbots/TOURNAMENT-CONTROL-PLANE.md` exists and contains:
  - why every command is `AllowConsole = true` (`.bg start`/`stop`/`status` are
    `false` and need a GM inside the instance — `Chat.cpp:862`,
    `Commands.cpp:14212-14257`);
  - that it lives in core, not the PlayerBots module, so it needs no
    `PlayerbotStubs.cpp` entry and works with `BUILD_PLAYERBOTS=OFF`;
  - a command table covering `status`, `create`, `add`, `members`, `start`,
    `stop`, `result`, `equip`, `store`, and what each emits;
  - the output contract, naming `scripts/tournament/lib/ctl.sh` as the thing that
    must change with it;
  - the cross-faction-only rule and why (`Unit::IsHostileTo` resolves through
    faction templates at `Unit.cpp:5189` and never consults `GetBGTeam()`);
  - a section headed exactly `## World-port acknowledgement — measured`, stating
    plainly that the answer is **UNMEASURED**, why it matters (`add` reports what
    was *sent*, `members` reports what the battleground *holds*), the exact
    procedure that settles it, and the three possible outcomes and what each
    means.

**Notes:**

- **Run the test from WSL** —
  `wsl -d Ubuntu -- bash -lc 'cd /mnt/c/<worktree path> && bash tests/tournament/ctl.test.sh'`.
  `jq` is absent from Git Bash on this host; `require_cmd` is a hard `exit 1`.
- This artifact is deliberately independent of the C++ artifacts (015-017): the
  test asserts against captured sample strings, so it needs neither a build nor a
  server. `ctl.sh` calls `wsg_console` only inside `ctl()`, never at source time.
- Do **not** fill in the acknowledgement measurement, and do not implement the
  `tournament queue` fallback. Leaving the section explicitly UNMEASURED is the
  deliverable; a fabricated answer here would silently mis-set `ASSEMBLE_MODE` in
  `scripts/tournament/match-run.sh`.
- `bgTypeId` for Warsong Gulch is `2` (`SharedDefines.h:1746`).

**Base:** cm-main

**Branch:** backlog/tournament-shell-client

**Summary:** Added `scripts/tournament/lib/ctl.sh` — the one place that knows the `.tournament` output format — plus its test suite and the control-plane document, as commit `af51538` on `backlog/tournament-shell-client` (cut from `origin/cm-main` at `927859f`). `ctl()` sends one console command through `wsg_console` and echoes only the `TOURNAMENT ` records, never failing the caller when a command produced none; `ctl_field()` extracts one `key=` value from captured output; `ctl_create()` echoes the new instance id and returns 1 with the reason on stderr for a server-reported `error=`, or with the raw capture when no id came back. Two implementation choices differ from the plan's sketch and are documented in the file with their evidence. First, `ctl()` deliberately does **not** anchor on `^TOURNAMENT `: `commandFinished` writes the prompt as `printf("mangos>")` with no trailing newline (`src/mangosd/CliRunnable.cpp:66-70`), so with more than one command in flight the prompt arrives glued to the front of the next command's first output line — an anchored grep would silently drop exactly those records, whereas `grep -ao 'TOURNAMENT .*'` finds them and strips the prompt, so every line it echoes genuinely begins `TOURNAMENT `. Second, `ctl_field` is bash parameter expansion rather than sed, because the key is interpolated: quoted inside a glob it cannot turn into a regex pattern, and it takes the first occurrence where sed's greedy `.*` takes the last. Both of its anchors are load-bearing — the leading space stops `stance` matching inside `instance=101`, the required `=` stops `ok` matching a longer `okay=` — and the value is read up to the next space so `slot=0` reads `0`, not empty. `tests/tournament/ctl.test.sh` prints `6 passed, 0 failed` and exits 0 against captured strings only (no server, no database, no build), and every rule was mutation-checked: dropping the leading-space anchor, the `=` requirement, or the zero-is-a-value handling each turns the suite red. `docs/playerbots/TOURNAMENT-CONTROL-PLANE.md` records why every command is `AllowConsole = true` (`.bg`'s handlers open with `m_session->GetPlayer()` and `ASSERT(chr)` at `Commands.cpp:14118` and `14212-14257` and are registered false at `Chat.cpp:862` and `743-745`, so flipping the flag would crash the world rather than help), why it is core and not the PlayerBots module, the nine-command table, the output contract naming `ctl.sh` as the thing that must change with it, the cross-faction-only rule (`Unit::IsHostileTo` resolves through faction templates at `Unit.cpp:5189` and never consults `GetBGTeam()`), and a `## World-port acknowledgement — measured` section left explicitly **UNMEASURED** with the exact settling procedure and the three outcomes. No C++ changed, no SQL migration was needed, and no container was started.

**In-game check:** Nothing on this branch changes gameplay, bot behaviour, or the world — no C++, no SQL, no config. There is no visual in-game symptom to look for, so the generic "server starts, bots spawn" smoke test covers the risk of regression. What DOES need confirming is that the parser agrees with the C++ output it was written against, and almost all of that is scriptable rather than human.

FULLY SCRIPTABLE TODAY, NO SERVER NEEDED:
1. From WSL (not Git Bash): `wsl -d Ubuntu -- bash -lc 'cd /mnt/c/<worktree> && bash tests/tournament/ctl.test.sh'` must print exactly `6 passed, 0 failed` and exit 0.
2. Sourcing must be side-effect free. With the stack DOWN, run `bash -c 'source scripts/tournament/lib/ctl.sh && echo sourced-ok'`. It must print `sourced-ok` immediately and must NOT hang, attach to a container, or error — this is the property that lets the test run without a build.

IMPORTANT PRE-CONDITION FOR EVERYTHING BELOW: the only server image on this host (`tortoise-cm:c06b2fb`) predates the `.tournament` command family entirely. Running `tournament status` against it returns `There is no such subcommand`, and that proves NOTHING about this branch — do not read it as a failure. The live checks below only become meaningful once a backlog-batch build has produced an image containing artifacts 015-017.

SCRIPTABLE ONCE THAT IMAGE EXISTS (validate-stack up, one Alliance bot online, all from one WSL script that sources `docs/playerbots/wsg/lib/wsg-bots-common.sh` then `scripts/tournament/lib/ctl.sh`):
3. `inst="$(ctl_create 2 60)"; echo "[$inst]"` must print a bare integer and nothing else. Empty, non-numeric, or extra text means the parser and the C++ output have drifted — that is the single highest-value check in this list.
4. `out="$(ctl "tournament status")"; printf '%s\n' "$out"` — every line must begin literally `TOURNAMENT `. If any line reads `mangos>TOURNAMENT ...`, the prompt strip regressed; if `status` returns nothing at all while an instance exists, the marker match regressed.
5. `ctl_field "$out" instance` must equal the id from step 3, and `ctl_field "$out" count` must be a number >= 1.
6. Error path: `ctl_create 99 60 >/tmp/o 2>/tmp/e; echo "rc=$?"` must give `rc=1`, `/tmp/o` must be empty, and `/tmp/e` must contain `tournament create failed:` with the server's reason (`bad_type_id`). A create that fails but returns 0, or that leaks a partial id to stdout, is the bug this criterion exists to prevent.
7. The zero-value path, which is the one a naive parser silently breaks: with `Wsgaone` online, `out="$(ctl "tournament equip Wsgaone 12640")"; ctl_field "$out" slot` must print `0` (Lionheart Helm goes in the head slot), NOT empty.
8. Log cross-check, also scriptable and worth doing because it catches a truncated console capture that otherwise looks like a clean empty result: `TournamentEmit` mirrors every record into `bg.log`, so `grep -c '^TOURNAMENT ' "$TW_LOGS/bg.log"` must rise by the number of records the script above consumed. If ctl() returned fewer lines than bg.log gained, the console read dropped records.

THE ONE GENUINELY HUMAN STEP: read `docs/playerbots/TOURNAMENT-CONTROL-PLANE.md` and confirm the `## World-port acknowledgement — measured` section still says UNMEASURED. Leaving it unmeasured is the deliverable of this artifact, not an omission — a fabricated answer would silently mis-set `ASSEMBLE_MODE` in `scripts/tournament/match-run.sh`. When someone eventually runs the procedure written in that section (create an instance, `add` a bot, wait 20 s, `members`, then read `map`/`online` for that bot out of `tw_char.characters`), the human judgement required is matching what they saw to one of the three documented outcomes and pasting the literal console output and DB row into the file — not a summary. That measurement belongs to whoever has a built image and a bot online; it is explicitly out of scope here.

**Minor findings:**

- scripts/tournament/lib/ctl.sh: ctl_create scans the whole capture for error= and instance= without checking those fields belong to the create record, so if the same attach window picks up a record from another in-flight command (the very interleaving the ctl() comment says to expect), it can report a foreign error= as a create failure or echo a foreign instance= as the new id.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/26, build tortoise-cm:20260817-1.
