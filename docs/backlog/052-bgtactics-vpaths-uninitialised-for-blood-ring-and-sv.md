---
status: implemented
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

**Base:** cm-main

**Branch:** backlog/bgtactics-vpaths-uninitialised-for-blood-ring-and-sv

**Summary:** In `src/modules/PlayerBots/playerbot/strategy/actions/BattleGroundTactics.cpp`, `BGTactics::Execute` now declares `vPaths` and `vFlagIds` as `nullptr` instead of leaving them indeterminate, with a comment naming the two arms that leave them unset (`default: break` for BATTLEGROUND_BR/BATTLEGROUND_SV, and the AV case which assigns `vPaths` only). The `"move to objective"` branch — which holds the `selectObjectiveWp(*vPaths)`, `startNewPathBegin(*vPaths)` and `startNewPathFree(*vPaths)` dereferences — returns false immediately when `vPaths` is null, right after the existing `STATUS_WAIT_JOIN` check. The `"check flag"` branch's existing `if (vFlagIds)` test is widened to `if (vPaths && vFlagIds)`, so the `atFlag(*vPaths, *vFlagIds)` call is covered on both pointers while AV still short-circuits to `CheckFlagAv()` before reaching it. No `case` was added for BR or SV and `AiFactory.cpp:1106` is untouched, so behaviour is byte-for-byte identical for AB/AV/WS/EY/IC — the change only removes the latent indeterminate-pointer dereference. Single file, 10 insertions / 3 deletions; no SQL migration and no config change.

**In-game check:** This is a defensive hardening change with no intended visible in-game effect, so the check is a no-regression check on the battlegrounds that DO have a case, not a demonstration of new behaviour.

Scriptable / log-observable (a later batch step can do this unattended):
1. Server starts and stays up on the built image — no crash, no assertion in the mangosd log at startup.
2. Bring up a WSG match with bots (`.bg` / `rndbot` as usual for this stack) and let it run to completion. Watch the mangosd console/log for a clean match lifecycle and, critically, the ABSENCE of any crash or `Aborted`/stack-trace output from the world thread. The regression risk of this diff is exactly one thing: bots in WSG/AB/AV suddenly refusing to move, which would show up as a match that never scores and bots idling at the graveyard.
3. Grep the log for the usual playerbot BG chatter (bots announcing objectives / flag pickups) to confirm `bg move to objective` and `bg check flag` still fire — if `vPaths` had been wrongly nulled for a supported BG, those would go silent.

Manual, requires a human eye:
4. Log in as a GM, `.go` into the running WSG instance, and confirm bots still run the flag: Horde bots leave the Warsong tunnel, path to the Silverwing flag room, pick up the flag, and carry it back. Same spot-check in AB (bots fan out to capture Stables/Blacksmith/etc.) and AV (bots move up the field and cap towers) — AV is the one worth checking specifically, since it is the case that assigns `vPaths` but leaves `vFlagIds` null and therefore exercises the widened `vPaths && vFlagIds` test.
5. Blood Ring / SV (maps 26, 27) cannot be used to confirm the fix positively: `AiFactory.cpp:1106` still withholds the `battleground` strategy for those type ids, so bots there remain inert exactly as before. Confirming "bots stand around in Blood Ring and the server does not crash" is the expected outcome both before and after this commit — it proves nothing, and no one should chase it.
