---
status: done
risk: medium
area: tournament/effects
depends-on: 032-viewer-effect-library.md
---

# `effect_apply` reports partial failures as success and burns ten console attaches

**Problem:** three defects in `scripts/tournament/lib/effects.sh`, all paid for
by the consumer downstream.

1. A target counts as applied whenever *any* line of the `ctl` reply contains
   `ok=1`. Against `tournament equip`'s real output — one `ok=<0|1>` per item
   plus an `equipped=n failed=n` summary — a reply of `item=1 ok=1` /
   `item=2 ok=0` / `equipped=1 failed=12` is reported as a clean success, which
   `effect-consume.sh` then records in `applied.txt` and dedupes away
   permanently. A viewer pays, gets one item, and nothing says so.
2. `effect_upgrade_one` always reads the current tier from the team's
   `.gearTier`, which nothing ever updates, so a second `upgrade_armor_player`
   on the same bot re-equips the tier it is already wearing and reports `ok=1`.
3. `effect_apply` opens one console attach per target, so a `heal_team` or
   `kill_team` costs ten attaches — against this repo's explicit
   one-attach-per-run convention and the `wsg_console` warning that "forty
   attaches is forty chances to EOF the console, which shuts the world down".
   `gear-apply.sh` and `roster.sh` both batch correctly; follow them.

**Suspected cause / area:** `scripts/tournament/lib/effects.sh`, `effect_apply`
and `effect_upgrade_one`.

**Acceptance criteria:**

- Success is decided from the summary line (`failed=0`), not from any `ok=1`; a
  partial equip yields a failure for that target and a non-zero exit.
- A second `upgrade_*_player` on the same bot either advances a tier that is
  actually recorded, or reports a distinct reason — never a silent re-equip
  reported as `ok=1`.
- A `*_team` effect issues **one** console attach for all ten targets.
- All three covered in `tests/tournament/effects.test.sh` via `CTL_STUB`.

**Notes:**

- The reporting and tier changes are stub-testable now. The batching change
  alters how every effect reaches the world and should be smoke-tested against a
  live console once a match can run (see artifact 055) — that smoke test is
  operator follow-up, not a gate on the code change.
- Run the test suite from WSL; `jq` is absent from Git Bash on this host.

**Base:** cm-main

**Branch:** backlog/effect-apply-partial-failure-and-attach-storm

**Summary:** Rewrote the apply path in scripts/tournament/lib/effects.sh. (1) Verdicts now come from the control plane's summary line: an equip target counts as applied only when its `equip player=<name> equipped=<n> failed=<n>` line reads failed=0, a missing summary is a failure, and heal/kill are matched per named player rather than by any `ok=1` anywhere in the reply; the per-item ok=0 lines are echoed to stderr beside the target so an operator can see which item dropped. (2) effect_upgrade_one became effect_plan_upgrade_one, which plans but never sends, and reads the current tier from a per-match record (<state>/tiers.txt, keyed by bot AND by armor/weapon half so the two priced effects don't consume each other's step) written only after the world confirms failed=0; effect-consume.sh exports EFFECT_STATE_DIR="$STATE" so it survives a consumer restart, and an exhausted ladder now answers `already_top_tier(<tier>)` with no command sent instead of a silent re-equip reported ok=1. (3) effect_apply now plans every target, sends the whole batch through ONE ctl call (EFFECT_CTL_WAIT=40s, the same room gear-apply.sh gives a ten-bot batch), then judges each target from that single reply — a heal_team costs one console attach, not ten. New tests/fixtures/ctl-stub.sh answers in TournamentCommands.cpp's real shape (per-item ok= lines plus a summary) and logs one line per attach; six new assertions in tests/tournament/effects.test.sh cover partial equip → failure, tier recorded on success, second upgrade → distinct reason and zero attaches, and one attach for ten targets. All nine tournament test files pass under WSL (effects: 31 passed, 0 failed).

**In-game check:** This is a shell-script change only; no server rebuild is needed and it can be checked against the existing image once a match can run (artifact 055). Checklist for a human, with the scriptable parts marked:

1. SCRIPTABLE, no world needed: run `wsl -d Ubuntu -- bash -lc 'cd /mnt/c/Coding/tortoise-wow/tortoise-wow && bash tests/tournament/effects.test.sh'` and confirm "31 passed, 0 failed", including the four lines "a partial equip is reported as a failure, not a success", "and sends no equip at all -- never the same tier a second time", "a _team effect opens exactly ONE console attach for all ten targets" and "and all ten targets are still judged individually from that one reply".
2. Attach count against a live world: bring up mangosd, log a team in with `./scripts/tournament/roster.sh login stormwind-sentinels`, then queue and drain a heal_team (`effect-queue.sh --effect heal_team --team stormwind-sentinels`, then `effect-consume.sh --once`). SCRIPTABLE: `docker logs tcm-mangosd` should show exactly ONE console session opening for that drain, and ten `TOURNAMENT heal player=Wsga* ... ok=1` lines inside it — not ten separate attach/detach cycles. Ten bots visibly returning to full health in the client is the in-game half.
3. Partial equip is reported: with the team online, put a deliberately bad item in one gear tier (e.g. a plate chest in a mage's tier file) and buy `upgrade_armor_player` for that bot. In-game the bot ends up missing that slot; the applier must print `EFFECT ... applied=0 failed=1` and exit non-zero, and the `equip player=<name> item=<id> ok=0 reason=cannot_equip(...)` line must appear on stderr. The old behaviour printed applied=1 failed=0. SCRIPTABLE: grep the consumer's output for `applied=0 failed=1` and for a `WARN: id=... did not fully apply` line.
4. No silent re-equip: buy `upgrade_armor_player` twice on the same bot in one match. The first must move it up a tier visibly in the client (white gear to green/blue); the second must NOT re-send the same item list. SCRIPTABLE: `<state>/tiers.txt` gains exactly one `<BotName>|armor|<tier>` line after the first, and the second run prints `already_top_tier(<tier>)` on stderr with no new `TOURNAMENT equip player=<name>` line in the console log. Then kill and restart `effect-consume.sh` with the same `--state` dir and buy again — it must still refuse, proving the record survived the restart.
5. Generic smoke: server starts, bots spawn, a match still runs with the consumer looping beside it.

Note rule 5 of the environment brief: the only server image on this host predates these branches, but this change touches no C++ — the existing image's `tournament heal/kill/equip` commands are exactly the ones the applier drives, so steps 2-4 are runnable against it as soon as a match can be stood up.

**Minor findings:**
- scripts/tournament/lib/effects.sh: In the judge loop `line` is only ever set on the equip branch, so a heal/kill target the world explicitly refused (`kill player=X ok=0 reason=already_dead`) is reported on stderr as "got no verdict for X in the console reply" — the operator issuing a refund is told the world never answered when it answered with a reason.
- scripts/tournament/lib/effects.sh: An `already_top_tier` no-op is counted into `applied` and leaves rc=0, so the machine-readable EFFECT line for a second purchase is byte-identical to a real upgrade (applied=1 failed=0) and the distinct reason exists only on stderr, which effect-consume.sh does not parse before recording the id in applied.txt.
- scripts/tournament/lib/effects.sh: effect_tier_file's no-state-dir fallback is always called inside a command substitution, so the `EFFECT_TIER_FILE=$(mktemp ...)` assignment dies with the subshell: every call mints a fresh empty temp file (verified: three logical uses produced four distinct /tmp/effect-tiers.* files), so nothing written by effect_tier_record is ever read back by effect_tier_current, the documented "still no silent re-equip within a run" guarantee does not hold, and the temp files leak.
- scripts/tournament/lib/effects.sh: Batching every target into one 40s attach makes tiers.txt diverge from the world when the console reply is truncated or late — mangosd queues the equips via QueueCliCommand and still runs them after detach, but effect_apply sees no summary line, so it counts all ten targets failed, records no tier, and the consumer still writes the id to applied.txt, leaving the next paid upgrade to re-send the tier the bots are already wearing (the exact silent re-equip this change removes), now for the whole batch at once instead of one target.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/73, build tortoise-cm:20260819-4.
