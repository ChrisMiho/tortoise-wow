---
status: done
risk: medium
area: tournament/effects
depends-on: 031-gear-tier-armour-weapon-split.md
---

# There is no definition of what a viewer effect is or who it may touch

**Problem:** Eight viewer interventions are planned (heal / kill / upgrade-armour /
upgrade-weapon, each for one bot or a whole team) with no shared notion of a
well-formed command, no way to resolve a command to actual character names, and
no rule about who may be targeted. Two failures follow directly: **an effect
naming a team that is not in the current match** resolves to offline characters
and silently does nothing (the queue outlives a match), and **an upgrade at the
top tier** would either wrap back to base or apply nothing without saying so.

**Suspected cause / area:** Implements
`docs/superpowers/plans/2026-08-16-06-viewer-effects.md` Task 3.

**Acceptance criteria:**

- `scripts/tournament/lib/effects.sh` is sourceable and provides
  `effect_validate <json>`, `effect_targets <json> <allianceTeam> <hordeTeam>`,
  `effect_member_meta <team> <name>` and `effect_apply <json> <allianceTeam>
  <hordeTeam>`.
- The eight effect names are enumerated in one constant:
  `heal_player heal_team kill_player kill_team upgrade_armor_player
  upgrade_armor_team upgrade_weapon_player upgrade_weapon_team`.
- `effect_validate` rejects, each with a reason on stderr: invalid JSON; a
  missing `id` (**without an id there is no dedupe key**, so a replayed queue
  would apply the effect again — a viewer defrauded or a team wiped twice); an
  unknown effect name (message must contain `unknown effect`); a missing
  `target.team`; a target team that fails `team_validate`; and a `*_player`
  effect with no `target.slot`.
- `effect_targets` resolves a `*_team` effect to all ten names and a `*_player`
  effect to `namePrefix + slot`, and **exits 1 for a team that is neither the
  alliance nor the horde team of the current match**.
- `effect_apply` validates, resolves, applies per target through the control
  plane, and emits exactly one
  `EFFECT id=<id> effect=<name> team=<id> applied=<n> failed=<n>` line. It exits
  non-zero if any target failed.
- Upgrades move **exactly one tier by `rank`**, via `gear_next_tier`. At the top
  tier the result is an explicit no-op that reports
  `ok=1 reason=already_top_tier` — never a wrap back to base — and a tier with no
  items for the requested half reports `ok=0 reason=no_items_in_tier(<tier>)`.
- `bash tests/tournament/effects.test.sh` prints `11 passed, 0 failed` and
  exits 0. Added cases cover: a well-formed command validating; a single-slot
  target resolving to one character name; a team effect resolving to ten names; an
  unknown effect being rejected with a reason; a command with no id being
  rejected; and a team not in the current match being rejected.

**Notes:**

- **Run the test from WSL** —
  `wsl -d Ubuntu -- bash -lc 'cd /mnt/c/<worktree path> && bash tests/tournament/effects.test.sh'`.
  `jq` is absent from Git Bash on this host.
- This artifact extends `tests/tournament/effects.test.sh` (artifact 031), which
  is why it stacks on it. Point `GEAR_DIR` at `tests/fixtures/gear` and `TEAM_DIR`
  at `config/tournament/teams`.
- `effect_apply` calls `ctl "tournament heal|kill|equip …"` from
  `scripts/tournament/lib/ctl.sh` (artifact **018**, not in this branch's chain):
  `ctl <command...>` echoes only `TOURNAMENT ` lines, `ctl_field <output> <key>`
  extracts one value. The apply path is not exercised by these tests — they cover
  validation and targeting only — so no server or stub is needed here.
- The commands it drives (`tournament heal`, `tournament kill`) come from artifact
  030 and `tournament equip` from 017. Neither is present on this branch; write
  against the emitted-line contracts documented in those artifacts.
- Effects need the bot **online and in the battleground**; every control-plane
  command resolves the player by name through `ObjectAccessor`, and heal/kill
  additionally refuse a bot outside a battleground.

**Base:** backlog/gear-tier-armour-weapon-split

**Branch:** backlog/viewer-effect-library

**Summary:** Added `scripts/tournament/lib/effects.sh` (new, 199 lines) and extended `tests/tournament/effects.test.sh` with six cases. The library names the eight viewer effects once in `EFFECT_NAMES` (`heal_player heal_team kill_player kill_team upgrade_armor_player upgrade_armor_team upgrade_weapon_player upgrade_weapon_team`) and provides four functions. `effect_validate <json>` rejects, each with a reason on stderr, invalid JSON, a missing `id` (no id means no dedupe key, so a replayed queue applies the effect twice), an unknown effect name (message contains `unknown effect`), a missing `target.team`, a team that fails `team_validate`, and a `*_player` effect with no `target.slot`. `effect_targets <json> <allianceTeam> <hordeTeam>` resolves a `*_team` effect to all ten `team_names` and a `*_player` effect to `namePrefix + slot`, and exits 1 for any team that is neither side of the current match — the queue outlives a match, and those characters would be offline, so the control plane's `ObjectAccessor` lookup would fail silently rather than erroring. `effect_member_meta <team> <name>` reads `class|role` out of `team_rows` (needed to pick the gear file). `effect_apply` validates, resolves, dispatches per target through `ctl` (`tournament heal|kill|equip`), and always emits exactly one `EFFECT id=<id> effect=<name> team=<id> applied=<n> failed=<n>` line, exiting non-zero if any target failed; the per-target loop uses a here-string so the counters survive. A helper `effect_upgrade_one` steps exactly one tier by `rank` via `gear_next_tier` and emits `ok=1 reason=already_top_tier` at the top (never a wrap back to base), `ok=0 reason=no_items_in_tier(<tier>)` when the requested half is empty, plus `ok=0 reason=no_tier_above(<cur>)` and `ok=0 reason=not_on_team(<team>)` for the two error paths `gear_next_tier`/`effect_member_meta` can return — distinguishing "at the top" from "the gear file is missing" matters because the latter reported as the former lies to a paying viewer. Like every other lib in `scripts/tournament/lib/`, it sources nothing; the entry script does that, so a caller that only validates never drags in the console. `bash tests/tournament/effects.test.sh` prints `11 passed, 0 failed` and exits 0 (verified from WSL); all seven files under `tests/tournament/` still exit 0. The apply path is not exercised by the test suite (it needs a world), but I confirmed it out of band against a stubbed `ctl`: a team heal produced `applied=10 failed=0` rc=0, a failing `ctl` produced `applied=0 failed=1` rc=1, and the top-tier case produced `already_top_tier` rc=0.

**In-game check:** Nothing in this branch changes the server binary — it is one new sourceable bash library plus test cases, so the C++ smoke test is just "server starts, bots spawn". Everything specific to this change is scriptable and needs no human eyes for the first two steps.

SCRIPTABLE, no world required (a batch step can run these verbatim from WSL; jq is absent from Git Bash on this host):
1. `wsl -d Ubuntu -- bash -lc 'cd /mnt/c/<worktree> && bash tests/tournament/effects.test.sh'` must print `11 passed, 0 failed` and exit 0.
2. Sourcing check — `bash -c '. scripts/tournament/lib/team.sh; . scripts/tournament/lib/gear.sh; . scripts/tournament/lib/effects.sh; echo "$EFFECT_NAMES"'` must print all eight names and exit 0. This is the whole "is sourceable" criterion.

SCRIPTABLE against a live world, once `tournament heal`/`tournament kill` (artifact 030) and `tournament equip` (017) exist in the running image — none of them are in any image on this host today, so a "no such subcommand" here proves nothing about this branch:
3. Stand up a match with two teams (`scripts/tournament/match-run.sh` with `stormwind-sentinels` vs `orgrimmar-warsong`), then source the three libs and run
   `effect_apply '{"id":"live1","effect":"heal_team","target":{"team":"stormwind-sentinels"},"source":"manual"}' stormwind-sentinels orgrimmar-warsong`.
   Expect exactly one line, `EFFECT id=live1 effect=heal_team team=stormwind-sentinels applied=10 failed=0`, and exit 0 — grep the output for `applied=10 failed=0`; one `EFFECT ` line and no more is itself part of the contract.
4. Re-run the same call naming `ironforge-anvils` (a team that exists but is not in this match). It must exit 1 with `is not in this match` on stderr and must NOT emit an `EFFECT ` line, and no bot in the world may be healed. This is the failure the artifact exists to prevent, and it is fully checkable from the exit code plus the absence of the line.

HUMAN EYES IN-GAME, the part that cannot be read off a log:
5. With the WSG match running, log in as a GM and `.gm on`, `.go` to the Warsong Gulch instance, and target `Wsgaone` (Stormwind's slot-one warrior). Damage it below full — `.damage 500` or let the match do it — then run
   `effect_apply '{"id":"live2","effect":"heal_player","target":{"team":"stormwind-sentinels","slot":"one"},"source":"manual"}' stormwind-sentinels orgrimmar-warsong`
   and confirm Wsgaone's health bar snaps to full in the target frame, and that no other Stormwind bot's health moved.
6. Inspect Wsgaone (right-click → Inspect) and note its mainhand and chest. Run the `upgrade_armor_player` command for the same slot, then re-inspect: the chest must have changed to the next tier's item and the **mainhand must be unchanged**. Then run `upgrade_weapon_player` and confirm the reverse — mainhand changes, chest does not. That armour/weapon separation is what a viewer is paying separately for, and only the character sheet shows it.
7. Set the team's `.gearTier` in `config/tournament/teams/stormwind-sentinels.json` to the highest-rank tier in that class-role's gear file and run `upgrade_armor_player` again. The console must print `ok=1 reason=already_top_tier` and the bot's gear must be **unchanged** — specifically it must not revert to the white/base kit. A visible drop to base here is the wrap-around bug and is a hard fail.
8. Kill check: `effect_apply` with `kill_player` on slot ten, and confirm that bot (and only that bot) dies and releases in the battleground; a bot standing outside a battleground must be refused by the control plane rather than killed.

**Minor findings:**
- scripts/tournament/lib/effects.sh: In `effect_apply` a target is counted as applied whenever ANY line of the ctl reply contains `ok=1`, so a partially failed upgrade is reported as a success: with `tournament equip`'s real output (one `ok=<0|1>` line per item plus an `equipped=n failed=n` summary), a reply of `item=1 ok=1` / `item=2 ok=0` / `equipped=1 failed=12` yields `EFFECT ... applied=1 failed=0` and exit 0 (verified with a stub), when the AC requires a non-zero exit if any target failed — the summary's `failed=` count (via `ctl_field`) is the field that actually decides per-bot success.
- scripts/tournament/lib/effects.sh: `effect_upgrade_one` always reads the current tier from the team's `.gearTier`, which nothing ever updates, so a second `upgrade_armor_player` on the same bot re-equips the tier it is already wearing and reports `ok=1` — a viewer who pays twice gets nothing the second time and no line says so.
- scripts/tournament/lib/effects.sh: `effect_apply` opens one `ctl` (console attach) per target, so a `heal_team`/`kill_team` costs ten attaches and ~10x`CTL_WAIT` seconds, against this repo's explicit convention of batching into a single attach (gear-apply.sh, roster.sh, and the `wsg_console` comment "Forty attaches is forty chances to EOF the console, which shuts the world down").

**Drain note (GOOD NEWS: artifact 031's swallowed exit status does NOT propagate here):** the drain recorded on 031 that gear_items_armor and gear_items_weapon both return rc=0 with empty output when the underlying lookup fails (reproduced: gear_items returns rc=1, both splitters return rc=0). The obvious way that becomes a defrauded viewer is a caller that trusts the exit status. This library does not. effect_upgrade_one captures the ids and tests the OUTPUT, not the status:

```
ids="$(gear_items_armor "$cls" "$role" "$next" | cut -d'|' -f2 | paste -sd, -)"
if [ -z "$ids" ]; then
    printf 'TOURNAMENT upgrade player=%s ok=0 reason=no_items_in_tier(%s)
' "$nm" "$next"
    return 1
fi
```

So a failed lookup is caught and reported rather than silently equipping nothing. 031's bug is still worth fixing at source, because the next caller may not be this careful, but it is contained at this call site. One caveat, by this library's own stated principle: it argues that distinguishing "at the top tier" from "the gear file is missing" matters "because the latter reported as the former lies to a paying viewer" — yet an outright failed lookup and a genuinely empty half both surface here as no_items_in_tier(<tier>), which is the same conflation one level down.

**Drain note (finding 3 verified — it breaks a convention a SIBLING artifact established this session, and the stated failure mode is severe):** confirmed by reading both files. effect_apply issues its ctl call INSIDE the per-target loop (`while IFS= read -r nm; do ... out="$(ctl "tournament heal $nm")"`), so heal_team/kill_team costs ten console attaches. Artifact 022's gear-apply.sh — already merged to a PR this session as #35 — documents the opposite at its head: "ONE console attach for the whole run". 022's own summary spelled out why: "ten separate attaches would be ten chances to EOF the console, the same reason roster.sh and match-run.sh batch", and the repo's wsg_console comment puts it harder still ("Forty attaches is forty chances to EOF the console, which shuts the world down"). This is a world-stability risk rather than a style preference, and the two artifacts should not ship disagreeing about it.

**Drain note (finding 1 is the correctness one to fix first):** a target counts as applied whenever ANY line of the ctl reply contains ok=1. Against `tournament equip`'s real output shape — one `ok=<0|1>` line per item plus an `equipped=n failed=n` summary — a reply of `item=1 ok=1` / `item=2 ok=0` / `equipped=1 failed=12` yields `EFFECT ... applied=1 failed=0` and exit 0. That directly violates this artifact's own acceptance criterion that effect_apply "exits non-zero if any target failed", and it is the shape a paid upgrade actually returns, not a corner case. The summary line's `failed=` field (via ctl_field) is what should decide per-bot success. Note this interacts with a real, already-observed number: bg.log on 2026-08-18 recorded `TOURNAMENT equip player=Wsgaten equipped=10 failed=3` from the live image — a partial equip exactly like the one this finding says would be reported as a clean success.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/45, build tortoise-cm:20260818-4.
