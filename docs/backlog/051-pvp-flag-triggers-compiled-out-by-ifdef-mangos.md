---
status: pending
risk: low
area: playerbots/battlegrounds
depends-on:
---

# Three PvP flag triggers are silently always-false because `MANGOS` is never defined

**Problem:** `PlayerHasNoFlag` (`strategy/triggers/PvpTriggers.cpp:35-55`),
`PlayerIsInBattlegroundWithoutFlag` (`:124-143`) and `TeamHasFlag` (`:177-198`)
each have their entire body inside `#ifdef MANGOS`. This build defines
`CMANGOS`, not `MANGOS` (`src/modules/PlayerBots/CMakeLists.txt:131`), and
`MANGOS` appears nowhere in `src/`. All three therefore compile down to
"return false" and can never fire, while still being registered under real names
in `TriggerContext.h:185`, `:187`, `:191`.

Worse, the excluded bodies call `GetAllianceFlagCarrierGuid()` and
`GetHordeFlagCarrierGuid()`, which **exist nowhere in `src/`**. The file only
compiles because the blocks are excluded, so anyone who flips the `#ifdef`
expecting the triggers to start working gets a build break instead.

In-game there is no symptom today: no strategy in this repo fires
`"player has no flag"`, `"team has flag"` or `"in battleground without flag"`.
This is a trap, not a live defect — the next person to write a flag strategy
gets a trigger that never fires and no way to tell from a log.

**Suspected cause / area:**
`src/modules/PlayerBots/playerbot/strategy/triggers/PvpTriggers.cpp` and the
matching registrations in `strategy/TriggerContext.h`.

**Acceptance criteria:**

- The three triggers are made honest, by one of these two routes, chosen and
  argued in the commit message:
  - the bodies are ported to this fork's API — `BattleGroundWS::GetFlagCarrierGuid(idx)`
    (`src/game/Battlegrounds/BattleGroundWS.h:144-155`), indexed by the flag's
    **owning** team — and the `#ifdef MANGOS` guards removed; or
  - the dead bodies and the three `TriggerContext.h` registrations are removed
    outright, so a future strategy naming one of them fails loudly at
    registration rather than silently at runtime.
- Whichever route is taken, `grep -rn "ifdef MANGOS\b" src/` returns nothing for
  these three triggers afterwards.
- `grep -rn "GetAllianceFlagCarrierGuid\|GetHordeFlagCarrierGuid" src/` returns
  nothing, or returns definitions that exist.
- The build compiles. No behaviour changes: no strategy fires any of these three
  trigger names today, and none is added here.

**Notes:**

- Source: `docs/playerbots/BG-AI-ANALYSIS.md`, finding **F-09**.
- The index semantics are the easy thing to get backwards — see finding **F-13**
  in the same document: `flagTaken()` means "*my* team holds the *enemy* flag"
  and `teamFlagTaken()` means "the *enemy* holds *my* flag", both named
  backwards relative to what they return.
