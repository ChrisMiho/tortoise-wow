---
status: implemented
risk: low
area: playerbots/battlegrounds
depends-on:
---

# A Horde bot on the Alliance roof is never told to drop into the flag room

**Problem:** `BGTactics::wsgRoofJump()` has a Horde arm and an Alliance arm that
are meant to mirror each other. The Horde arm works: its guard
(`BattleGroundTactics.cpp:2603`, `y > 1450.f`) and its inner test (`:2630`,
`y > 1452.f`) differ by two yards, so both branches of the inner `if` are live
and a bot on the Horde base's second floor is eventually sent to
`WS_FLAG_HORDE_FLOOR_JUMP_LOWER` with the jump flag set. The Alliance arm does
not. Its guard (`:2604`) requires `GetPositionY() < 1468.f` and its inner test
(`:2639`) is that *same* `GetPositionY() < 1468.f`, so the `if` always wins, the
`else` at `:2642` is dead code, and `WS_FLAG_ALLIANCE_FLOOR_JUMP_LOWER`
(declared at `:36`) has zero references anywhere in the file. Line `:2642`
repeats the `UPPER` constant where the Horde mirror correctly uses `LOWER`.

In-game: a Horde bot that reaches the Alliance base's upper walkway
(`x > 1522, y < 1468, z > 361`) is unconditionally re-sent to the ledge it is
already standing on, without the jump flag, and never drops the last hop into
the Alliance flag room. That is the final step of the Horde attack route, and
its absence biases WSG toward Alliance — the direction of the 15-6 Alliance skew
`bg.log` records for 2026-08-10.

**Suspected cause / area:**
`src/modules/PlayerBots/playerbot/strategy/actions/BattleGroundTactics.cpp`,
`wsgRoofJump()` — guard `:2604`, inner test `:2639`, wrong constant `:2642`,
unused constant declaration `:36`.

**Acceptance criteria:**

- `:2642` uses `WS_FLAG_ALLIANCE_FLOOR_JUMP_LOWER`, so the constant declared at
  `:36` has at least one reference.
- The inner test at `:2639` uses a threshold strictly inside the guard at
  `:2604`, so both arms of the inner `if` are reachable — mirroring the Horde
  arm's 1450/1452 two-yard gap, with the number justified in the commit message
  from the geometry (the Alliance flag object stands at
  `(1540.42, 1481.32, 351.83)` in `tw_world.gameobject`), not assumed by
  symmetry alone.
- Swapping only the constant, without also fixing `:2639`, is explicitly *not*
  accepted: the `else` stays dead and nothing changes.
- The Horde arm (`:2603`, `:2627-2634`) is not touched.
- No other behaviour changes.

**Notes:**

- Source: `docs/playerbots/BG-AI-ANALYSIS.md`, finding **F-02** and §4.
- This fix is only observable once bots move at all in WSG. As of the §4
  measurement they do not — see
  `docs/backlog/046-wsg-bots-never-execute-bg-move-to-objective.md`. Landing
  this one first changes nothing anybody can see.

**Base:** cm-main

**Branch:** backlog/wsg-alliance-flag-room-drop-unreachable

**Summary:** On branch backlog/wsg-alliance-flag-room-drop-unreachable (cut from origin/cm-main), a two-line fix in src/modules/PlayerBots/playerbot/strategy/actions/BattleGroundTactics.cpp, BGTactics::wsgRoofJump(), Alliance second-floor arm. The inner test changed from `bot->GetPositionY() < 1468.f` (identical to the enclosing guard, so the `if` always won and the `else` was dead) to `< 1466.f`, and the `else` now moves to WS_FLAG_ALLIANCE_FLOOR_JUMP_LOWER with the jump flag instead of repeating WS_FLAG_ALLIANCE_FLOOR_JUMP_UPPER — giving that previously unreferenced constant its first use. The 1466 threshold comes from the geometry, verified against the live DB: WS_FLAG_ALLIANCE_FLOOR_JUMP_UPPER (1529, 1468, 362) is the ledge lip and _LOWER (1531, 1475, 352) is the flag-room floor, on the same z plane as the Alliance flag gameobject 179830 at (1540.42, 1481.32, 351.83) in tw_world.gameobject. The bot travels +y along the ledge, so 1466 <= y < 1468 is the live two-yard band immediately before the lip — the mirror of the Horde arm's 1450/1452 gap. The Horde arm and everything else in the file are untouched; no SQL migration, no other behaviour change. Not built (per the no-Docker-build rule) and not pushed.

**In-game check:** Prerequisite: this is only observable once bots actually execute BG movement in WSG (backlog 046). If bots still stand at the tunnel gate, the check cannot distinguish fixed from broken — confirm bots move first.

Checklist for a human on a live server running an image built from this branch:
1. Start a WSG match with bots on both sides (`.bg` / rndbot flow, or wait for a queue to pop). Join as a Horde character so you can spectate from inside the Alliance base.
2. Position yourself in the Alliance keep — stand in the flag room on the ground floor at roughly (1540, 1481, 352), next to the silverwing flag.
3. Watch a Horde bot run the attack route: through the Alliance courtyard, up the ramps to the roof, then along the upper walkway. Follow it with `.go xyz` or just watch from the flag room.
4. The specific behaviour to confirm: once the bot is on the second-floor walkway around (1529, 1466-1468, 362) it should JUMP down into the flag room, landing near (1531, 1475, 352), rather than pacing back and forth on the ledge. Before this fix it would loop on the ledge indefinitely and never descend that last 10 yards.
5. Confirm it then picks up the Alliance flag and runs it out. Over 3-4 matches, Horde should score flag captures at all; a run of matches where only Alliance ever captures is the symptom returning.
6. Regression check on the untouched Horde arm: as an Alliance character, stand in the Horde flag room (916, 1434, 345) and confirm Alliance bots still drop off the Horde second floor around (925, 1444, 345) exactly as before.

Scriptable portion: partly. The drop itself is not logged, but bot positions are queryable — with the match running, sampling `characters.position_x/position_y/position_z` (or a console `.pinfo`-style dump) for Horde bots on map 489 and confirming at least one bot registers a z near 352 with y > 1470 and x > 1525 (i.e. inside the Alliance flag room) proves the drop happened; before the fix no Horde bot would ever appear at that z inside those bounds. Flag captures are also observable without a human: `bg.log` records match results, so a scripted run can check that Horde capture counts are no longer uniformly zero across several matches. Steps 2-4 (visually confirming the jump animation and no ledge-pacing) still need eyes on the game.

Beyond that, the generic smoke test applies: the server starts, bots spawn, no new crash in mangosd's log around BGTactics.

**Minor findings:**
- src/modules/PlayerBots/playerbot/strategy/actions/BattleGroundTactics.cpp: The Alliance arm's waypoint `WS_FLAG_ALLIANCE_FLOOR_JUMP_UPPER` sits at y = 1468.0, exactly on (not inside) the arm's guard `GetPositionY() < 1468.f`, so a bot that actually arrives at or slightly overshoots the lip falls out of `atAllianceSecondFloorJump` entirely and stalls without jumping — whereas the Horde mirror's `_UPPER` at y = 1451 lies strictly inside its `y > 1450` guard and therefore always re-enters the else branch; the new 1466 test only saves the bot if it happens to be re-evaluated while still in the 1466–1468 band.
