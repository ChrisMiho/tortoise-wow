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
