---
status: pending
risk: medium
area: playerbots/battlegrounds
depends-on:
---

# `BGTactics::Execute` dereferences an uninitialised pointer for Blood Ring and SV

**Problem:** `BGTactics::Execute` declares `vPaths` and `vFlagIds` with no
initialiser (`BattleGroundTactics.cpp:2720-2721`) and fills them from a `switch`
on the battleground type (`:2729-2767`). The `switch` has a
`default: break` that assigns **neither**, and the AV case assigns `vPaths`
only. `*vPaths` is then dereferenced at `:2810`, `:2824`, `:2827` and `:2843`,
and `vFlagIds` is null-tested at `:2841` while possibly indeterminate.

This fork has five live `BattleGroundTypeId` values, not three:
`BATTLEGROUND_BR` = 4 (Blood Ring) and `BATTLEGROUND_SV` = 5
(`src/game/SharedDefines.h:1748-1749`), both mapped from real map ids
(`:1760-1761`, maps 26 and 27) and dispatched throughout `BattleGroundMgr.cpp`.
Neither has a `case`, so both fall to `default: break`.

The only thing keeping that arm unreached today is one line in another file:
`AiFactory.cpp:1106` adds the `battleground` strategy — and with it every `bg *`
action — only when `bgType <= BATTLEGROUND_AB`. The `bg->IsArena()` early-out
that would otherwise have caught Blood Ring (`:2708-2714`) is inside
`#ifndef MANGOSBOT_ZERO`, i.e. compiled out of exactly this build.

In-game: nothing today — bots carry no `bg *` action in a Blood Ring or SV
instance, so they stand inert there. The moment anyone widens the
`AiFactory.cpp:1106` gate, restores a bot-side arena path, or adds a BG type, a
bot in that instance dereferences an indeterminate pointer and the world thread
crashes.

**Suspected cause / area:**
`src/modules/PlayerBots/playerbot/strategy/actions/BattleGroundTactics.cpp`
`:2720-2721`, `:2729-2767`, `:2810`, `:2841`.

**Acceptance criteria:**

- `vPaths` and `vFlagIds` are initialised to `nullptr` at their declaration.
- Every dereference of `vPaths` (`:2810`, `:2824`, `:2827`, `:2843`) is guarded
  by a null test, or `Execute` returns early when `vPaths` is null after the
  `switch`.
- The AV case, which legitimately assigns `vPaths` but not `vFlagIds`, still
  works: the `vFlagIds` read at `:2841` stays behind its existing null test.
- The commit message names `BATTLEGROUND_BR` and `BATTLEGROUND_SV` as the two
  type ids that reach `default: break`, and states that `AiFactory.cpp:1106` is
  the only thing keeping that arm unreached today.
- No `case` is added for BR or SV, and `AiFactory.cpp:1106` is not widened —
  giving bots a Blood Ring path is separate work with its own artifact.

**Notes:**

- Source: `docs/playerbots/BG-AI-ANALYSIS.md`, finding **F-10**.
- Ranked in §4 as low expected match-quality gain (it changes nothing visible)
  but very low risk and a real crash removed, which is why it earns an artifact
  while several other latent findings do not.
