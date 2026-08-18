---
status: pending
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
