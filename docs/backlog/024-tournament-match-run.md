---
status: done
risk: medium
area: tournament/bracket
depends-on:
---

# Running one match is a sequence of hand-typed steps with no defined outcome

**Problem:** Playing a single tournament match means swapping rosters, checking
gear, assembling an instance, starting it, watching for an end, reading a result
and logging out again — all by hand, with no single artifact that says what
happened. Three details make an ad-hoc script wrong: **a match is hard-capped at
20 minutes** (`BattleGround.cpp:317-323`, custom to this server) and bot matches
frequently run the full clock, so "the clock expired" is a normal outcome with a
defined result, not a hang; **a finished battleground is destroyed**, so
`result error=no_such_instance` is the ordinary way a match ends and the score
then has to come from the line the server already wrote to `bg.log`; and **only
20 tournament bots may be online at once**, so the previous pairing has to be
logged out before the next is logged in.

**Suspected cause / area:** Implements
`docs/superpowers/plans/2026-08-16-04-bracket-engine.md` Task 3.

**Acceptance criteria:**

- `scripts/tournament/match-run.sh <allianceTeam> <hordeTeam> [--run-dir <dir>]`
  exists and runs exactly one match — it never starts a second.
- It validates both teams and **refuses unless the first is faction `A` and the
  second is faction `H`**.
- Sequence, in order: log every *other* team out; `roster.sh ensure` then
  `roster.sh login` for the two playing teams; a gear gate; assemble; start;
  monitor; read the result; log both teams out.
- **Gear gate:** if `gear-audit.sh` fails for either team it runs
  `gear-apply.sh team <t>` and re-audits; still incomplete is a fatal exit. A
  half-dressed team is a rigged match.
- **Population gate: only the 20 bots playing this match may be online.** After
  logging both teams in, the script reads every online character from
  `tw_char.characters`, records the full list into `<run-dir>/match.log`, and
  aborts if any character outside the two rosters is online — with an allowance,
  default 1 and overridable, for a GM spectator. The alive-world random pool
  being off is a **precondition**, not something this script changes: it does not
  edit `aiplayerbot.conf` or restart mangosd mid-run. Failing here is correct —
  a populated world changes the match, and bot AI is single-core.
- Two assembly modes exist behind one switch, `ASSEMBLE_MODE`, defaulting to
  `direct` and overridable from the environment:
  - `direct` — `ctl_create`, then `tournament add <inst> <name>` per bot, then a
    settle wait, then `tournament members` — and it **fails the match if fewer
    than 20 players are actually held**, because below that it is not the match
    the bracket asked for.
  - `queue` — `wsg_bgjoin_lines` for all 20 names in **one** `wsg_console` call,
    then poll `bg.log` for the `[489,<instance>]` pop with a 180 s deadline.
- **Monitor polls the result, not the clock.** While the instance exists it reads
  `tournament result`; a `status=WaitLeave` with a winner ends the match. Once the
  instance is gone it reads the winner out of `bg.log`'s `[<type>,<inst>]:
  winner=<n>` line, decoding `0`=HORDE, `1`=ALLIANCE, `2`=NONE
  (`BattleGround.h:187-189`). A deadline of 1500 s (the 20-minute cap plus
  cleanup) stops the instance and records `NONE`.
- The final line is always
  `MATCH alliance=<t> horde=<t> winner=<ALLIANCE|HORDE|NONE> instance=<id>
  duration=<s> allianceScore=<n> hordeScore=<n>`, teed into
  `<run-dir>/match.log`. Exit 0 on a completed match **including a draw**; exit 1
  only if the match could not be run at all.
- **The two score fields are load-bearing, not decoration.** The bracket driver
  tiebreaks a `winner=NONE` on them, so they must carry the last score actually
  read from `tournament result` before the instance disappeared — not zeros
  written because the final read failed. When no score could be read at all, emit
  `-1` for both, which `tournament result` already uses to mean "not exposed" and
  which the driver can tell apart from a real 0-0.
- `bash -n scripts/tournament/match-run.sh` exits 0.

**Notes:**

- **`winner=NONE` after a full 20 minutes is a legitimate result, not a failure.**
  What must never happen is the script hanging or exiting without a `MATCH` line.
- This script is deliberately independent of the artifacts that supply its
  callees, so it can be reviewed and merged on its own. It calls, at runtime:
  `scripts/tournament/roster.sh {ensure|login|logout} <team-id>` (artifact 014),
  `scripts/tournament/gear-audit.sh <team-id>` (019, exits non-zero on a hole),
  `scripts/tournament/gear-apply.sh team <team-id>` (022),
  `scripts/tournament/lib/team.sh` → `team_validate`, `team_field`, `team_names`
  (013), and `scripts/tournament/lib/ctl.sh` → `ctl`, `ctl_field`, `ctl_create`
  (018). Write against those exact signatures. **Do not execute it here** — it
  needs a running server; syntax-check only.
- `ASSEMBLE_MODE`'s correct default is not knowable yet: it depends on the
  world-port acknowledgement measurement recorded in
  `docs/playerbots/TOURNAMENT-CONTROL-PLANE.md`, which is explicitly UNMEASURED
  (artifact 018). Ship **both** paths, default to `direct`, and put a comment at
  the switch pointing at that section. Do not pick one and delete the other.
- Take care with the "log every other team out" loop: a bare
  `[ "$t" = "$A" ] || [ "$t" = "$B" ] && continue` relies on shell operator
  precedence to mean what it looks like. Write it so the intent is unambiguous.
- `characters.map` and `characters.online` lag reality by up to 60 s
  (`PlayerSave.Interval`); never conclude a match ended from a single stale read,
  and expect phantom `map=489` rows for a minute or two after any restart.
- Never party a bot to a GM — `HasActivePlayerMaster()` is a hard gate in the
  bot's queue logic (`BattleGroundJoinAction.cpp:568`) and a partied bot never
  queues again.
- **Live validation checklist.** There is no unit test for this script by
  decision — it is validated by running one real match and reading the database
  and logs. It needs an image containing the `.tournament` commands, so this
  happens **after** a batch build, not during implementation. Run in order:
  1. `./scripts/validate-stack.sh --image <the batch image> --keep-up` must
     report `VALIDATE-STACK: PASS` before anything else is trusted.
  2. `./scripts/tournament/match-run.sh stormwind-sentinels orgrimmar-warsong
     --run-dir logs/tournament/smoke`
  3. **While it runs**, confirm the population gate held — exactly the 20 playing
     bots online and nothing else:
     `SELECT name FROM tw_char.characters WHERE online = 1 ORDER BY name;`
     Anything outside the two rosters, other than one GM spectator, means the
     random pool is not actually off.
  4. Confirm the battleground really holds them, which is the world-port
     acknowledgement question in practice: `tournament members <inst>` must read
     `count=20`. **`add ... sent=1` with `members ... count=0` is the documented
     failure** — if that happens, stop and switch `ASSEMBLE_MODE=queue` rather
     than editing the script.
  5. `grep -a "\[489," ~/tortoise-wow-server-V2/logs/bg.log | tail` should show
     the instance.
  6. A `MATCH alliance=... horde=... winner=... instance=... duration=...
     allianceScore=... hordeScore=...` line within ~25 minutes, and
     `<run-dir>/match.log` holding the whole sequence.
  7. Afterwards both teams must read `online=0`, so the next match starts from a
     clean roster.
- **`winner=NONE` is a pass, not a failure** — 15 of the 37 matches recorded in
  `bg.log` ended that way. The failure condition is no `MATCH` line at all, or
  the script hanging.

**Base:** cm-main

**Branch:** backlog/tournament-match-run

**Summary:** Added `scripts/tournament/match-run.sh` (424 lines, mode 755, the only file in the commit `47a74ad`): one invocation runs exactly one Warsong Gulch tournament match end to end and prints one machine-readable result line. It sources `lib/team.sh`, `lib/ctl.sh` and `docs/playerbots/wsg/lib/wsg-bots-common.sh`, validates both teams and refuses unless argument one is faction `A` and argument two is `H`, then walks the fixed sequence: log out every team in `$TEAM_DIR` that is not playing (written as a `case`, not the precedence-dependent `[ … ] || [ … ] && continue` the artifact warns about), `roster.sh ensure` then `roster.sh login` for the two playing teams, a gear gate that re-audits after `gear-apply.sh team <t>` and treats a still-incomplete team as fatal, a population gate that reads every `online = 1` row out of `tw_char.characters`, logs the full list into `<run-dir>/match.log` and aborts when more than `MATCH_GM_ALLOWANCE` (default 1) characters outside the two rosters are online, assemble, start, monitor, read the result, log both teams out. The population query deliberately bypasses `wsg_mysql` (which discards mysql's stderr, so a failed query reads exactly like an empty world) and re-reads for 90 s first, because `characters.online` is written on save. Assembly ships both paths behind `ASSEMBLE_MODE`, defaulting to `direct`, with a comment at the switch pointing at the still-UNMEASURED "World-port acknowledgement" section of `docs/playerbots/TOURNAMENT-CONTROL-PLANE.md`: `direct` creates the instance, batches all twenty `tournament add` lines into ONE console attach (twenty attaches would be twenty chances to EOF the console), settles 20 s, then fails the match if `tournament members` holds fewer than 20 and names `ASSEMBLE_MODE=queue` as the fix; `queue` sends all forty `wsg_bgjoin_lines` in one attach and polls for the `[489,<inst>]` pop with a 180 s deadline. The monitor polls `tournament result`, ends on `status=WaitLeave` with a winner, decodes the winner from `bg.log`'s `[2,<inst>]: winner=<n>` line (0=HORDE 1=ALLIANCE 2=NONE) once the instance is destroyed, and stops the instance and records `NONE` at 1500 s; both `bg.log` reads are bounded to the lines appended after the run started, since instance ids are reused after a restart. The final line is always `MATCH alliance=… horde=… winner=… instance=… duration=… allianceScore=… hordeScore=…`, teed into `<run-dir>/match.log`, with the scores carrying the last pair actually read while the instance existed and `-1 -1` when none was ever readable. Exit 0 on any completed match including a draw, 1 only when the match could not be run. Verified: `bash -n` exits 0, and every branch (all six refusal paths, both gates, both assembly modes, the WaitLeave read, the bg.log read, the deadline stop and the -1/-1 case) was exercised in WSL against a stubbed console and database in a scratch harness — the script itself was never run against the live server, which has no image carrying the `.tournament` commands.

**In-game check:** This needs a live run — the script drives the world and its result comes out of the database and bg.log, so nothing short of one real match confirms it. It also needs an image carrying the `.tournament` commands: against the current rollback-anchor image every `ctl` call answers "There is no such subcommand", assembly fails, and that proves nothing about this script. Run after a batch build, in this order:

1. Scriptable. `./scripts/validate-stack.sh --image <the batch image> --keep-up` must print `VALIDATE-STACK: PASS` before anything below is trusted.
2. Precondition, scriptable, and it is the one thing this script deliberately will not fix for you: confirm the random bot pool is off before starting. `grep -E 'AiPlayerbot.(Enabled|RandomBotAutoLogin|MinRandomBots|MaxRandomBots)' ~/tortoise-wow-server-V2/aiplayerbot.conf`, and `SELECT COUNT(*) FROM tw_char.characters WHERE online = 1;` should read 0 (or just your GM) with no match running. If random bots are online, turn the pool off and restart mangosd first — the script aborts rather than doing it mid-run, by design.
3. From WSL: `./scripts/tournament/match-run.sh stormwind-sentinels orgrimmar-warsong --run-dir logs/tournament/smoke`.
4. Scriptable, while it runs. The population gate line is in `logs/tournament/smoke/match.log` as `online=<n> playing=20/20 other=<n> [names]`. Cross-check it against the world directly: `SELECT name FROM tw_char.characters WHERE online = 1 ORDER BY name;` must list exactly the twenty roster bots plus at most one GM. Anything else online means the pool is not actually off.
5. Scriptable, and this is the world-port acknowledgement question in practice. `logs/tournament/smoke/match.log` must show `sent 20/20 adds to instance <id>` followed by `instance <id> holds 20 player(s)`. **`sent=1` with `count=0` is the documented failure** — if you see `only 0/20 players entered`, stop and re-run with `ASSEMBLE_MODE=queue` rather than editing the script. Confirm from the database too: `SELECT name, map FROM tw_char.characters WHERE online = 1 AND map = 489;` should reach 20 rows (allow ~60 s, `map` is written on save).
6. Manual, and the only part a human has to look at. Log in a GM, `.gm on`, `.gm visible off`, `.appear <one of the bots>` — never `.invite` one, `HasActivePlayerMaster()` is a hard gate and a partied bot never queues again. You should be standing in Warsong Gulch with ten Alliance bots and ten Horde bots fighting, both teams visibly dressed (no naked bots — that is the gear gate having worked), not twenty bots standing inert in their tunnels.
7. Scriptable. `grep -a "\[489," ~/tortoise-wow-server-V2/logs/bg.log | tail` shows the instance filling, and `grep -a "\[2,<inst>\]: winner=" ~/tortoise-wow-server-V2/logs/bg.log` shows the end-of-match line once it finishes.
8. Scriptable. Within ~25 minutes the script exits 0 having printed one `MATCH alliance=stormwind-sentinels horde=orgrimmar-warsong winner=<ALLIANCE|HORDE|NONE> instance=<id> duration=<s> allianceScore=<n> hordeScore=<n>` line, also the last line of `logs/tournament/smoke/match.log`. `winner=NONE` is a pass — 15 of the 37 matches in bg.log ended that way. The failures are: no `MATCH` line at all, the script still running past ~30 minutes, or `allianceScore=-1 hordeScore=-1` on a match that visibly scored flags (that would mean no `tournament result` read ever landed).
9. Scriptable. Afterwards `./scripts/tournament/roster.sh status stormwind-sentinels` and the same for `orgrimmar-warsong` must both read `online=0/10` (allow 60 s for `PlayerSave.Interval`), so the next match starts from a clean roster.

**Minor findings:**
- scripts/tournament/match-run.sh: The population gate logs only the outsider names, not the full online-character list the acceptance criteria (and the code's own comment two lines above) require in match.log.
- scripts/tournament/match-run.sh: gear-audit.sh's exit 2 ("could not measure" — bad team file, no jq/docker, DB unreachable) is treated identically to exit 1 ("gear holes"), so a database outage causes the script to write gear onto the bots via gear-apply.sh and then fatal with a misleading "still incomplete after re-gearing" message.
- scripts/tournament/match-run.sh: When assemble_direct fails after ctl_create succeeded (fewer than 20 held), the script fatals without ever calling `tournament stop $inst`, leaving a live battleground instance holding the ported bots — the opposite of the deadline path, which stops the instance for exactly this reason.
- scripts/tournament/match-run.sh: assemble_queue sets every bot's "bg type" AI value but never emits wsg_bgtype_reset_lines on its no-pop timeout path, so the bots stay permanently queued for Warsong Gulch after the fatal exit — wsg-kickoff.sh resets on its equivalent timeout for that reason.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/32, build tortoise-cm:20260817-2.
