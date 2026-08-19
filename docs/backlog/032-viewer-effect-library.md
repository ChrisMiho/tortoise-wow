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
