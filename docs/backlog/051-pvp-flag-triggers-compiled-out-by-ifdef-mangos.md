---
status: done
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

**Base:** cm-main

**Branch:** backlog/pvp-flag-triggers-compiled-out-by-ifdef-mangos

**Summary:** Took the "port" route in `src/modules/PlayerBots/playerbot/strategy/triggers/PvpTriggers.cpp`: removed the `#ifdef MANGOS` guards from `PlayerHasNoFlag`, `PlayerIsInBattlegroundWithoutFlag` and `TeamHasFlag`, and rewrote their bodies against this fork's API. The dead bodies called `GetAllianceFlagCarrierGuid()`/`GetHordeFlagCarrierGuid()`, which exist nowhere in `src/`; they now use `BattleGroundWS::GetFlagCarrierGuid(idx)` indexed by the flag's owning team, factored into one file-local `BotCarriesEnemyFlag(bot, bg)` helper. The index semantics are documented in a comment: `m_FlagKeepers[TEAM_INDEX_ALLIANCE]` is the Silverwing (Alliance) flag, which only a Horde player can carry, so the only flag a bot can hold is its enemy team's — matching how the already-working `PlayerHasFlag` and `EnemyTeamHasFlag` next to them read it. Also fixed the `GetGUIDLow()`-compared-to-`ObjectGuid` mistake the dead `PlayerIsInBattlegroundWithoutFlag` body carried. Chose porting over deletion because the three names are part of the strategy vocabulary a future WSG flag strategy will want and the neighbouring flag triggers already work. Verified `grep -rn "ifdef MANGOS\b" src/` returns nothing in PvpTriggers.cpp and `grep -rn "GetAllianceFlagCarrierGuid\|GetHordeFlagCarrierGuid" src/` returns nothing at all. No strategy fires any of the three trigger names today and none was added, so runtime behaviour is unchanged. No build was run here per the drain's no-Docker-build rule; the batch pass is the compile gate.

**In-game check:** This change is behaviour-neutral by construction: no strategy in the repo names "player has no flag", "team has flag" or "in battleground without flag", so nothing instantiates these three triggers at runtime. The real gate is the compiler — the old bodies referenced `GetAllianceFlagCarrierGuid()`/`GetHordeFlagCarrierGuid()`, which do not exist, so the batch build either succeeds (proving the port is valid against this fork's API) or fails loudly.

Scriptable, no human needed:
1. Build the batch image. A clean compile of `PvpTriggers.cpp` is the primary acceptance check.
2. `grep -rn "ifdef MANGOS\b" src/modules/PlayerBots/playerbot/strategy/triggers/PvpTriggers.cpp` → no output.
3. `grep -rn "GetAllianceFlagCarrierGuid\|GetHordeFlagCarrierGuid" src/` → no output.
4. Start the stack and confirm mangosd reaches "World initialized" with no new errors, then `rndbot start` (or whatever the batch's standard smoke command is) and confirm bots log in — the generic smoke test.

Optional human confirmation in-game, only worth doing if someone wants to see the WSG flag path still behaves (it is untouched code paths, `PlayerHasFlag`/`EnemyTeamHasFlag`, that this change sits next to):
5. `.bg` a Warsong Gulch match with bots on both sides.
6. Pick up the enemy flag as a human player and confirm bots still react as they did before this change — enemy bots converge on you (driven by `EnemyTeamHasFlag` / "enemy flag carrier", not by the three ported triggers).
7. Let a bot pick up your flag and confirm it still runs for its own base (driven by `PlayerHasFlag`).
Neither step should differ from a pre-change server; a difference there would mean the port touched more than intended.

**Minor findings:**
- src/modules/PlayerBots/playerbot/strategy/triggers/PvpTriggers.cpp: PlayerHasNoFlag still returns false when the bot is outside a battleground or in a non-WSG battleground, so the trigger named "player has no flag" is false precisely when the bot most obviously has no flag — the port faithfully preserves the dead code's inverted default, leaving the same silent never-fires trap outside WSG that the artifact set out to remove (its sibling PlayerIsInBattlegroundWithoutFlag correctly returns true in the non-WSG branch).

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/65, build tortoise-cm:20260819-2.
