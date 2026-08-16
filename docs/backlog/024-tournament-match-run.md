---
status: pending
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
- **Verification needing a live stack (not part of these criteria):** one real
  match against a validated stack, producing a `MATCH ... winner=... instance=...
  duration=...` line within ~25 minutes and a `<run-dir>/match.log` holding the
  whole sequence.
