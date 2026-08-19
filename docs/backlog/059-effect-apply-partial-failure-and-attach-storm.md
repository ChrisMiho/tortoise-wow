---
status: pending
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
