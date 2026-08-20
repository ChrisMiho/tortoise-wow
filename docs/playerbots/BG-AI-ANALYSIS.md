# Battleground bot AI — how it actually works

Analysis dated **2026-08-18**, written against commit **`80a7100`**
(`Merge pull request #32 from ChrisMiho/backlog/tournament-match-run`).

**Nothing in this document changes behaviour.** It is a code reading. No file outside
`docs/` was touched. Every claim below carries a `file:line` or cites a measurement
recorded elsewhere in this repo. Where a claim is inference rather than a read, §3
says so and gives it a confidence.

Implements Tasks 1–2 of `docs/superpowers/plans/2026-08-16-07-bg-combat-analysis.md`.
**§4 was added later, by artifact 037**, and implements Tasks 3–4 of the same plan: it
is the measurement half, taken from one live 20-minute match on 2026-08-18, and it
carries the recommendations and their backlog artifacts. §0–§3 are unchanged from the
code-reading pass and are dated against commit `80a7100`; where §4 contradicts a
finding above it, §4 wins and says so.

Unless a path is given, `file:line` references are relative to
`src/modules/PlayerBots/playerbot/`.

---

## 0. Build context — what is actually compiled

Two preprocessor facts decide which half of this code exists at all, and both are set
unconditionally:

| Define | Where | Effect |
|---|---|---|
| `CMANGOS` | `src/modules/PlayerBots/CMakeLists.txt:131` | on |
| `MANGOSBOT_ZERO` | `src/modules/PlayerBots/CMakeLists.txt:132` | on, **unconditionally** — the expansion `if()` blocks at `:135-143` are redundant |
| `MANGOSBOT_ONE` / `MANGOSBOT_TWO` | `:139` / `:142` | only if the CMake project name matches TBC/WoTLK; this is a Classic build, so **off** |
| `MANGOS` | *nowhere in `src/`* | **never defined** — see finding F-09 |

Consequences that matter for everything below:

- Eye of the Storm (`BATTLEGROUND_EY`), Isle of Conquest (`BATTLEGROUND_IC`),
  Random BG (`BATTLEGROUND_RB`) and vehicles are all compiled out. **Arenas are not.**
  This fork's `BattleGroundTypeId` (`src/game/SharedDefines.h:1742-1750`) declares five
  live ids, not three: AV (1), WS (2), AB (3), **`BATTLEGROUND_BR` = 4** (Blood Ring)
  and **`BATTLEGROUND_SV` = 5**. Both of the latter map from real map ids
  (`SharedDefines.h:1760-1761`, maps 26 and 27) and are dispatched throughout
  `BattleGroundMgr.cpp` (`:1319-1322`, `:1358-1361`, `:1599-1601`, `:1690-1692`), and
  Blood Ring is an arena — `BattleGround::IsArena()`
  (`src/game/Battlegrounds/BattleGround.h:296`) is literally
  `GetTypeID() == BATTLEGROUND_BR`.
- What `MANGOSBOT_ZERO` compiles out is not the arenas but the **bot-side code that
  would recognise one**: the `player->InArena()` branch in `AiFactory.cpp:1080-1085`
  and the `bg->IsArena()` early-out in `BattleGroundTactics.cpp:2708-2714` are both
  inside `#ifndef MANGOSBOT_ZERO`. The one line that actually keeps bots out of BR and
  SV is `AiFactory.cpp:1106`, which adds the `battleground` strategy only when
  `bgType <= BATTLEGROUND_AB`; no `warsong`/`arathi`/`alterac` strategy is added for
  them either, so a bot in Blood Ring or SV carries no `bg *` action at all. Read the
  rest of this document as "AV/WS/AB are the BGs the **bot AI** handles", never as
  "AV/WS/AB are the only BG type ids that exist" — F-10 turns on the difference.
- Every `#ifdef MANGOS` block in `strategy/triggers/PvpTriggers.cpp` is compiled out,
  which silently guts three triggers (F-09).

### Which strategies a WSG bot actually carries

`AiFactory.cpp` attaches them, and the split is not what the file names suggest:

| Strategy | Added at | Engine | When |
|---|---|---|---|
| `bg` (`BGStrategy`) | `AiFactory.cpp:1007` | non-combat | only when the bot is **not** in a battleground, and only if `randomBotJoinBG` is set. This is the *queueing* strategy. |
| `battleground` (`BattlegroundStrategy`) | `AiFactory.cpp:1108` (the `MANGOSBOT_ZERO` branch, gated `bgType <= BATTLEGROUND_AB`) | non-combat **only** | in any of AV/WS/AB |
| `warsong` (`WarsongStrategy`) | `AiFactory.cpp:1114` and `AiFactory.cpp:643` | non-combat **and** combat | WSG only |
| `arathi` (`ArathiStrategy`) | `AiFactory.cpp:1124` / `:648` | both | AB only |
| `alterac` (`AlteracStrategy`) | `AiFactory.cpp:1119` / `:653` | both | AV only |

`BattlegroundStrategy` declares no `InitCombatTriggers` override
(`strategy/generic/BattlegroundStrategy.h:38-40`), so it contributes **nothing to the
combat engine**. `WarsongStrategy::InitCombatTriggers` just calls
`InitNonCombatTriggers` (`strategy/generic/BattlegroundStrategy.cpp:95-98`), so its
table is identical in both engines.

---

## 1. Strategy and trigger table

One row per `TriggerNode` in
`strategy/generic/BattlegroundStrategy.cpp` (referred to below as
`BattlegroundStrategy.cpp`).

"Relevance" is the priority the engine sorts the action queue by. The
highest-relevance action whose `isUseful()` and `isPossible()` pass and whose
`Execute()` returns `true` wins the tick and **breaks the loop**
(`strategy/Engine.cpp:253-259`) — everything below it is starved for that tick.

Symbolic relevances (`strategy/Strategy.h:26-39`): `ACTION_NORMAL = 10`,
`ACTION_HIGH = 20`, `ACTION_PASSTROUGH = 100`.

### `BGStrategy` — `getName() == "bg"` (`BattlegroundStrategy.cpp:7-16`)

A `PassTroughStrategy` with the default `relevance = ACTION_PASSTROUGH = 100`
(`strategy/generic/PassTroughStrategy.h:8`).

| # | Line | Trigger | Trigger registered? | Action | Action registered? | Relevance | Live? |
|---|---|---|---|---|---|---|---|
| 1 | `:9-11` | `random` (`RandomTrigger`, 1-in-20, `strategy/triggers/TriggerContext.h:44`) | yes | `bg join` | yes — `strategy/actions/WorldPacketActionContext.h:46` | **100** | active |
| 2 | `:13-15` | `bg invite active` (`TriggerContext.h:184`, 10 s interval) | yes | `bg status check` | yes — `WorldPacketActionContext.h:44` | **100** | active |

### `BattlegroundStrategy` — `getName() == "battleground"` (`BattlegroundStrategy.cpp:18-55`)

Non-combat engine only.

| # | Line | Trigger | Trigger registered? | Action | Action registered? | Relevance | Live? |
|---|---|---|---|---|---|---|---|
| 1 | `:20-22` | `bg waiting` (`TriggerContext.h:181`, 30 s interval) | yes | `bg move to start` | yes — `strategy/actions/ActionContext.h:253` → `BGTactics("move to start")` | **1.0** | active |
| 2 | `:24-26` | `player has flag` (`TriggerContext.h:186`) | yes | `jump::position bg objective` | yes — `strategy/actions/ChatActionContext.h:217` (`JumpAction`; qualifier split at `strategy/NamedObjectContext.h:163`) | **3.0** | active |
| 3 | `:28-30` | `bg active` (`TriggerContext.h:182`, 1 s interval) | yes | `check mount state` | yes — `WorldPacketActionContext.h:71` | **2.0** | active |
| 4 | `:28-30` | `bg active` | yes | `bg move to objective` | yes — `ActionContext.h:254` | **1.0** | active |
| 5 | `:32-34` | `very often` (`TimeTrigger`, **5 s** interval, `IsActive()` hardcoded `true` — `TriggerContext.h:47`, `strategy/triggers/GenericTriggers.h:521-526`) | yes | `bg check objective` | yes — `ActionContext.h:256` | **10.0** | active |
| 6 | `:36-38` | `bg active` | yes | `bg check flag` | yes — `ActionContext.h:261` | **20.0** (`ACTION_HIGH`) | active |
| 7 | `:40-42` | `bg ended` (`TriggerContext.h:183`, 10 s interval) | yes | `bg leave` | yes — `WorldPacketActionContext.h:47` | **20.0** (`ACTION_HIGH`) | active |
| 8 | `:44-46` | `enemy flagcarrier near` (`TriggerContext.h:189`) | yes | `attack enemy flag carrier` | **yes — the action still exists**: `ActionContext.h:260`, class `strategy/actions/ChooseTargetActions.h:61-67`, `isUseful()` at `strategy/actions/ChooseTargetActions.cpp:95-109` | **80.0** | **commented out** |
| 9 | `:48-50` | `team flagcarrier near` — class exists (`strategy/triggers/PvpTriggers.h:42-49`, impl `PvpTriggers.cpp:233-237`) but is **never registered** in `TriggerContext.h` | **no** | `bg protect fc` | **yes — the action still exists**: `ActionContext.h:258` → `BGTactics("protect fc")`, dispatched at `strategy/actions/BattleGroundTactics.cpp:2777-2788`, helper `protectFC()` at `:4635-4646` | **40.0** | **commented out** |
| 10 | `:52-54` | `player has flag` | yes | `bg move to objective` | **yes — the action still exists**: `ActionContext.h:254` | **90.0** | **commented out** |

**Verdict on the three commented-out triggers** — the artifact's "strongest existing
lead". All three name **live** actions; none is a deleted-action dead end. But
re-enabling them changes far less than it looks:

- Row 8 is **duplicated live** in `WarsongStrategy` at `BattlegroundStrategy.cpp:75-77`
  at the *same* relevance 80.0, and again in `EyeStrategy` at `:157-159`. Since
  `BattlegroundStrategy` is attached only for AV/WS/AB (`AiFactory.cpp:1106-1109`) and
  AV/AB have no flag carriers, uncommenting it is a **no-op**.
- Row 10 is **duplicated live** in `WarsongStrategy` at `:79-84` at relevance 80.0
  (plus `jump::position bg objective` at 80.5). Same reasoning: a **no-op**.
- Row 9 is the only genuinely dead one, and it is dead **at the trigger, not the
  action**. `Engine::ProcessTriggers` resolves the trigger by name at
  `strategy/Engine.cpp:611`, gets `nullptr` because `TriggerContext.h` never registers
  `"team flagcarrier near"`, and `continue`s at `:614-615`. Uncommenting it would not
  crash — it would silently never fire, so `protectFC()` stays unreachable (F-03).

### `WarsongStrategy` — `getName() == "warsong"` (`BattlegroundStrategy.cpp:57-98`)

`InitCombatTriggers` (`:95-98`) delegates to `InitNonCombatTriggers`, so this identical
table is installed in **both** engines.

| # | Line | Trigger | Trigger registered? | Action | Action registered? | Relevance | Live? |
|---|---|---|---|---|---|---|---|
| 1 | `:59-61` | `bg active` | yes | `bg check flag` | yes — `ActionContext.h:261` | **70.0** | active |
| 2 | `:63-65` | `often` (`RandomTrigger`, 1-in-5, `TriggerContext.h:46`) | yes | `bg use buff` | yes — `ActionContext.h:259` | **30.0** | active |
| 3 | `:67-69` | `low health` (`TriggerContext.h:52`) | yes | `bg use buff` | yes | **30.0** | active |
| 4 | `:71-73` | `low mana` (`TriggerContext.h:57`) | yes | `bg use buff` | yes | **30.0** | active |
| 5 | `:75-77` | `enemy flagcarrier near` | yes | `attack enemy flag carrier` | yes — `ActionContext.h:260` | **80.0** | active |
| 6 | `:79-84` | `player has flag` | yes | `jump::position bg objective` | yes — `ChatActionContext.h:217` | **80.5** | active |
| 7 | `:79-84` | `player has flag` | yes | `bg move to objective` | yes — `ActionContext.h:254` | **80.0** | active |
| 8 | `:86-88` | `player has flag` | yes | `rocket boots` | yes — `ActionContext.h:245` (`strategy/actions/UseItemAction.h:452`) | **81.0** | active |
| 9 | `:90-92` | `very often` | yes | `bg banner` | yes — `ActionContext.h:243` (`UseItemAction.h:413`) | **10.0** | active |

### `AlteracStrategy` — `getName() == "alterac"` (`BattlegroundStrategy.cpp:100-109`)

| # | Line | Trigger | Trigger registered? | Action | Action registered? | Relevance | Live? |
|---|---|---|---|---|---|---|---|
| — | `:100-102` | *none — `InitNonCombatTriggers` is an empty body* | — | — | — | — | — |
| 1 | `:106-108` | `very often` | yes | `bg banner` | yes — `ActionContext.h:243` | **10.0** (`ACTION_NORMAL`) | active, **combat engine only** |

AV's objective logic is not driven from this strategy at all — it arrives via
`BattlegroundStrategy`'s `bg check flag` (row 6 above) reaching `BGTactics::Execute`'s
`CheckFlagAv()` dispatch at `BattleGroundTactics.cpp:2838`.

### `ArathiStrategy` — `getName() == "arathi"` (`BattlegroundStrategy.cpp:111-137`)

Both engines (`:134-137` delegates).

| # | Line | Trigger | Trigger registered? | Action | Action registered? | Relevance | Live? |
|---|---|---|---|---|---|---|---|
| 1 | `:113-115` | `bg active` | yes | `bg check flag` | yes | **70.0** | active |
| 2 | `:117-119` | `often` | yes | `bg use buff` | yes | **30.0** | active |
| 3 | `:121-123` | `low health` | yes | `bg use buff` | yes | **30.0** | active |
| 4 | `:125-127` | `low mana` | yes | `bg use buff` | yes | **30.0** | active |
| 5 | `:129-131` | `very often` | yes | `bg banner` | yes | **10.0** | active |

### `EyeStrategy` — `getName() == "eye"` (`BattlegroundStrategy.cpp:139-173`)

Never attached in this build: `AiFactory.cpp:1128` and `:657` are both inside
`#ifndef MANGOSBOT_ZERO`. Rows recorded so the table is complete.

| # | Line | Trigger | Trigger registered? | Action | Action registered? | Relevance | Live? |
|---|---|---|---|---|---|---|---|
| 1 | `:141-143` | `bg active` | yes | `bg check flag` | yes | **70.0** | active in source, **strategy never attached** |
| 2 | `:145-147` | `often` | yes | `bg use buff` | yes | **30.0** | same |
| 3 | `:149-151` | `low health` | yes | `bg use buff` | yes | **30.0** | same |
| 4 | `:153-155` | `low mana` | yes | `bg use buff` | yes | **30.0** | same |
| 5 | `:157-159` | `enemy flagcarrier near` | yes | `attack enemy flag carrier` | yes | **80.0** | same |
| 6 | `:161-163` | `player has flag` | yes | `bg move to objective` | yes | **80.0** | same |
| 7 | `:165-167` | `player has flag` | yes | `rocket boots` | yes | **81.0** | same |

### `IsleStrategy` — `getName() == "isle"` (`BattlegroundStrategy.cpp:175-237`)

Never attached: `AiFactory.cpp:1136` / `:637` are inside `#ifdef MANGOSBOT_TWO`.

| # | Line | Trigger | Trigger registered? | Action | Action registered? | Relevance | Live? |
|---|---|---|---|---|---|---|---|
| 1 | `:177-179` | `bg active` | yes | `bg check flag` | yes | **70.0** | active in source, strategy never attached |
| 2 | `:181-183` | `timer` (`TriggerContext.h:43`) | yes | `enter vehicle` | yes — `ActionContext.h:267` | **85.0** | same |
| 3 | `:185-187` | `random` | yes | `leave vehicle` | **yes — the action still exists**: `ActionContext.h:268` | **80.0** | **commented out** |
| 4 | `:189-191` | `in vehicle` (`TriggerContext.h:217`) | yes | `hurl boulder` | yes — `ActionContext.h:269` | **70.0** | active in source |
| 5 | `:193-195` | `in vehicle` | yes | `fire cannon` | yes — `ActionContext.h:274` | **70.0** | same |
| 6 | `:197-199` | `in vehicle` | yes | `napalm` | yes — `ActionContext.h:273` | **70.0** | same |
| 7 | `:201-203` | `enemy is close` (`TriggerContext.h:119`) | yes | `steam blast` | yes — `ActionContext.h:272` | **80.0** | same |
| 8 | `:205-207` | `in vehicle` | yes | `ram` | yes — `ActionContext.h:270` | **70.0** | same |
| 9 | `:209-211` | `enemy is close` | yes | `ram` | yes | **79.0** | same |
| 10 | `:213-215` | `enemy out of melee` (`TriggerContext.h:114`) | yes | `steam rush` | yes — `ActionContext.h:271` | **81.0** | same |
| 11 | `:217-219` | `in vehicle` | yes | `incendiary rocket` | yes — `ActionContext.h:275` | **70.0** | same |
| 12 | `:221-223` | `in vehicle` | yes | `rocket blast` | yes — `ActionContext.h:276` | **70.0** | same |
| 13 | `:225-227` | `in vehicle` | yes | `blade salvo` | yes — `ActionContext.h:277` | **71.0** | same |
| 14 | `:229-231` | `in vehicle` | yes | `glaive throw` | yes — `ActionContext.h:278` | **70.0** | same |

### `ArenaStrategy` — `getName() == "arena"` (`BattlegroundStrategy.cpp:239-249`)

Never attached: `AiFactory.cpp:1088` / `:666` are inside `#ifndef MANGOSBOT_ZERO`.

| # | Line | Trigger | Trigger registered? | Action | Action registered? | Relevance | Live? |
|---|---|---|---|---|---|---|---|
| 1 | `:241-243` | `no possible targets` (`TriggerContext.h:137`) | yes | `arena tactics` | yes — `WorldPacketActionContext.h:48` (`ArenaTactics`, `BattleGroundTactics.cpp:4874`) | **1.0** | active in source, strategy never attached |

### 1.1 The effective WSG priority ladder

Merging the live rows above for a bot standing in a WSG (`battleground` + `warsong`,
both in the non-combat engine), highest relevance first. This single ordering explains
most observed behaviour:

| Relevance | Action | Fires when |
|---|---|---|
| 81.0 | `rocket boots` | carrying the flag |
| 80.5 | `jump::position bg objective` | carrying the flag — but see F-08: `JumpAction::isUseful()` is **false in an all-bot match** |
| 80.0 | `attack enemy flag carrier` | enemy FC within 50 yd (`PvpTriggers.cpp:227-231`, `VISIBILITY_DISTANCE_SMALL`) |
| 80.0 | `bg move to objective` | carrying the flag |
| 70.0 | `bg check flag` | every tick while the match is in progress |
| 30.0 | `bg use buff` | 1-in-5 checks, or low health, or low mana |
| 20.0 | `bg check flag` (duplicate, from `battleground`) | every tick |
| 20.0 | `bg leave` | match has ended |
| 10.0 | `bg check objective` | **every 5 s, unconditionally** |
| 10.0 | `bg banner` | every 5 s |
| 3.0 | `jump::position bg objective` (duplicate) | carrying the flag |
| 2.0 | `check mount state` | every tick |
| **1.0** | **`bg move to objective`** | **every tick — the only thing that moves a non-carrier, and it is at the bottom of the ladder** |
| 1.0 | `bg move to start` | pre-start only |

The load-bearing observation: for a bot that is **not** carrying the flag and has no
enemy carrier in sight — which is every bot for most of a scoreless match — the only
action producing cross-field movement is `bg move to objective` at relevance **1.0**,
below `bg check objective` at **10.0**. See F-01.

---

## 2. `BGTactics::Execute` — order of operations

`strategy/actions/BattleGroundTactics.cpp:2696-2856`.

One `BGTactics` object exists per registered action name (`ActionContext.h:252-261`),
and `Execute` dispatches on `getName()`. The name tests are **sequential `if`s, not
`else if`** — but since an instance has exactly one name, only one branch body ever
runs. The preamble, however, runs for **every** one of them.

### Preamble — before any name dispatch

| # | `file:line` | What happens | What an early return starves |
|---|---|---|---|
| 1 | `:2698-2703` | `bot->GetBattleGround()` is null → `ai->ResetStrategies()`, **`return false`** | Everything. Also tears the BG strategies off the bot mid-action. |
| 2 | `:2705-2706` | `bg->GetStatus() == STATUS_WAIT_LEAVE` → **`return false`** | Every `BGTactics` variant during the post-match window. `bg leave` is unaffected — it is `BGLeaveAction`, not `BGTactics` (`WorldPacketActionContext.h:47`). |
| 3 | `:2708-2714` | `bg->IsArena()` → `ResetStrategies()`, **`return false`** | Everything. Compiled out here (`#ifndef MANGOSBOT_ZERO`). |
| 4 | `:2716-2718` | Match in progress → `ai->ChangeStrategy("-buff", BOT_STATE_NON_COMBAT)` | Nothing directly, but this **re-strips the `buff` strategy on every `BGTactics` tick** (F-11). |
| 5 | `:2720-2721` | `vPaths` / `vFlagIds` declared **uninitialised** | — |
| 6 | `:2723-2767` | `switch (bgType)` assigns them: AB → `vPaths_AB` + `vFlagsAB`; AV → `vPaths_AV` only, **`vFlagIds` left uninitialised**; WS → `vPaths_WS` + `vFlagsWS`; `default: break` leaves **both** uninitialised | An unhandled `bgType` leaves `vPaths` indeterminate, and it is dereferenced at `:2810`. `BATTLEGROUND_BR` and `BATTLEGROUND_SV` **are** unhandled `bgType`s in this build; what keeps the `default` arm unreached is the strategy gate at `AiFactory.cpp:1106`, not the `switch` (F-10). |

### Name dispatch

| # | `file:line` | Branch | Calls | Return, and what it starves |
|---|---|---|---|---|
| 7 | `:2769-2770` | `"move to start"` | `moveToStart()` (`:2858-2959`) | Returns its value. `moveToStart` **always returns `true`** (`:2958`) once the BG type matched, even when it issued no `MoveTo` — `bg role` 4–6 maps to `BB_WSG_WAIT_SPOT_SPAWN` at `:2877` and neither movement branch runs (F-12). |
| 8 | `:2772-2775` | `"select objective"` | `selectObjective()` (`:2982`) | Returns directly. **No strategy in `BattlegroundStrategy.cpp` fires `bg select objective`**; the creator at `ActionContext.h:255` is reachable only from a console/chat command. |
| 9 | `:2777-2788` | `"protect fc"` | `check mount state`, then `protectFC()` (`:4635`) if `bg role < 5` | `return true` at `:2781` if the mount check acted — **that starves `protectFC()` itself**. The whole branch is unreachable anyway: `bg protect fc` is named only by the commented-out trigger at `BattlegroundStrategy.cpp:48-50`, whose trigger is unregistered (F-03). Falls through to `return false` at `:2855` when `protectFC()` fails. |
| 10 | `:2790-2793` | `"move to objective"` — status gate | — | `STATUS_WAIT_JOIN` → `return false`. Correct: `bg move to start` owns the pre-match phase. |
| 11 | `:2795-2796` | `useBuff()` (`:4648-4709`) | — | `return true` if a buff GameObject is within 20 yd (speed) or 50 yd (regen/berserk) — `:4683`. **Starves the entire rest of `move to objective`**: objective movement, waypoints, everything below. |
| 12 | `:2798-2806` | In combat **and** not carrying a WSG flag → `return false` | — | **Starves all objective movement while in combat.** With §1.1, an engaged non-carrier does nothing battleground-specific until combat drops. |
| 13 | `:2808-2814` | `moveToObjective()` (`:4022-4077`); on failure `selectObjectiveWp()` (`:4079-4209`) | — | `return true` on either success. For **WSG this is the terminal hop**: `selectObjectiveWp` short-circuits at `:4097-4103` to `wsgRoofJump() || wsgPaths()`, and `wsgPaths()` **always returns `true`** — every branch of `:2324-2589` ends in `return true`, making the `return false` at `:2590` unreachable. |
| 14 | `:2816-2822` | Carrying a WSG flag → `return false` ("bot with flag should only move to objective") | — | Unreachable in WSG: step 13 always returned. |
| 15 | `:2824-2825` | `startNewPathBegin(*vPaths)` (`:4281-4337`) | — | Unreachable in WSG, same reason. Live for AB/AV. |
| 16 | `:2827-2828` | `startNewPathFree(*vPaths)` (`:4339-4388`) | — | Unreachable in WSG. Live for AB/AV. |
| 17 | `:2831-2832` | `"use buff"` | `useBuff()` | Returns directly. Reached from `WarsongStrategy` rows 2–4 (relevance 30) and the `arathi`/`eye` equivalents. |
| 18 | `:2834-2839` | `"check flag"`, AV branch | `CheckFlagAv()` | `switch` with a single `case BATTLEGROUND_AV: return …` and **no `default`** — WS and AB fall out of the switch into step 19. |
| 19 | `:2841-2849` | `"check flag"`, flag-id branch | `atFlag(*vPaths, *vFlagIds)` (`:4390-4615`) | `return true` on success, else `return false`. The `if (vFlagIds)` guard at `:2841` reads a pointer that is **uninitialised for AV** — harmless only because AV already returned at `:2838` (F-10). |
| 20 | `:2852-2853` | `"check objective"` | `resetObjective()` (`:4211-4237`) | Returns directly. `resetObjective` wipes `bg objective` and calls `selectObjective(true)`, which **returns `true` whenever it sets a position** (`:3144-3148` for WSG). So this action succeeds essentially every time it runs, and it runs every 5 s (F-01). |
| 21 | `:2855` | Fall-through | — | `return false`. This is what `"attack fc"` (`ActionContext.h:257`) and the bare `"bg tactics"` (`:252`) hit — **`Execute` has no branch for either name** (F-04). |

### 2.1 Where the WSG flag helpers actually sit

`strategy/actions/BattleGroundTactics.h:60-80` declares 21 private members.
Reachability from `Execute` in a **WSG** match:

| Helper | Defined | Called from | Reachable in WSG? |
|---|---|---|---|
| `moveToStart` | `:2858` | `Execute:2770` | yes |
| `selectObjective` | `:2982` | `Execute:2774`, `moveToObjective:4036`, `resetObjective:4236` | yes |
| `moveToObjective` | `:4022` | `Execute:2808` | yes |
| `selectObjectiveWp` | `:4079` | `Execute:2810` | yes — but only its `:4097-4103` WSG short-circuit |
| `wsgRoofJump` | `:2593` | `selectObjectiveWp:4099` | yes |
| `wsgPaths` | `:2311` | `selectObjectiveWp:4102`; also `moveToObjective:4055-4057`, which is **commented out** | yes |
| `resetObjective` | `:4211` | `Execute:2853`, `moveToObjective:4062`, `atFlag:4446/4518/4557`, `moveToObjectiveWp:4256` | yes |
| `atFlag` | `:4390` | `Execute:2843` | yes |
| `useBuff` | `:4648` | `Execute:2795`, `Execute:2832` | yes |
| `flagTaken` | `:4617` | **only** `useBuff:4667` | yes, but only as one term of a speed-buff predicate |
| `teamFlagTaken` | `:4626` | `resetObjective:4228`, `useBuff:4667` | yes |
| `protectFC` | `:4635` | **only** `Execute:2786` (`"protect fc"`) | **no** — F-03 |
| `moveToObjectiveWp` | `:4239` | `selectObjectiveWp:4206`, `startNewPathBegin:4336`, `startNewPathFree:4387` | **no** — all three call sites are WSG-unreachable |
| `startNewPathBegin` | `:4281` | `Execute:2824`, `atFlag:4447` | **no** — F-05 |
| `startNewPathFree` | `:4339` | `Execute:2827` | **no** — F-05 |
| `getDefendersCount` | `:4711` | `:3528`, `:3529`, `:3789`, `:3790` — all IC code | **no** (compiled out) |
| `IsLockedInsideKeep` | `:4742` | `moveToObjective:4043`, inside `#ifdef MANGOSBOT_TWO` | **no** (compiled out) |
| `CheckFlagAv` | — | `Execute:2838` | AV only |
| `SelectAvObjectiveAlliance` / `SelectAvObjectiveHorde` | — | `selectObjective:3011-3012` | AV only |
| `eotsJump` | `:2648` | `selectObjectiveWp:4108`, inside `#ifndef MANGOSBOT_ZERO` | **no** (compiled out) |

The plan asks two questions of each flag helper — does it ever return true under a
realistic match state, and is it reachable at all:

- **`flagTaken()`** (`:4617-4624`) means "*my* team is carrying the *enemy* flag".
  `GetFlagCarrierGuid(idx)` indexes by the flag's **owning** team
  (`src/game/Battlegrounds/BattleGroundWS.h:144-155`; `m_FlagKeepers[BG_TEAM_ALLIANCE]`
  is filled with a **Horde** player at `BattleGroundWS.cpp:364`, and vice-versa at
  `:380`). It returns true under normal play and is reachable — but its only consumer
  is the `needSpeed` predicate in `useBuff` (`:4667`). It drives nothing tactical.
- **`teamFlagTaken()`** (`:4626-4633`) means "the *enemy* is carrying *my* flag". Same
  index semantics, plus one real consumer at `resetObjective:4228`. Both names read
  backwards relative to their meaning; both call sites use them correctly (F-13).
- **`atFlag()`** (`:4390-4615`) is reachable and functional, but engages only within
  `VISIBILITY_DISTANCE_TINY = 25 yd` (`:4431`, `src/game/Objects/Object.h:60`) and
  interacts only within `INTERACTION_DISTANCE = 5 yd` (`:4524`, `Object.h:44`). Getting
  the bot into that 25-yard bubble is entirely `wsgPaths()`'s job.
- **`protectFC()`** (`:4635-4646`) is correct — it `Follow()`s the team flag carrier
  within 50 yd — and **completely unreachable**. This is precisely the plan's "an
  unreachable correct function is the same as a broken one" case.

### 2.2 Where WSG movement actually comes from

Because step 13 always terminates, **`vPaths_WS` — all 16 waypoint paths defined at
`BattleGroundTactics.cpp:123-478` and listed at `:2098-2116` — is never traversed
during a WSG match.** The only other WSG call site is `atFlag:4447`'s
`startNewPathBegin`, gated at `:4443-4444` on a nearby friendly casting
`SPELL_CAPTURE_BANNER` (21651, `BattleGroundTactics.h:19`) — the Arathi/EotS banner
spell, which nobody casts in WSG.

All WSG cross-field movement therefore comes from the hand-written corridor cascade in
`wsgPaths()` (`:2311-2591`) plus `wsgRoofJump()` (`:2593-2645`). That is where the
faction-asymmetry question has to be asked, not in the path data. For the record, the
path data's own symmetry (waypoint counts measured from the literals):

| | Horde-anchored | Alliance-anchored |
|---|---|---|
| Intra-base paths | 5 | 5 |
| Cross-field paths, forward direction | 4 — `HordeTunnel_to_AllianceTunnel_1` (14 wp, `:174`), `_2` (15 wp, `:192`), `HordeGYJump_to_AllianceTunnel` (16 wp, `:222`), `HordeGYJump_to_AllianceFlagRoom` (35 wp, `:340`) | 2 — `AllianceGYJump_to_HordeTunnel` (24 wp, `:312`), `AllianceGYJump_to_HordeFlagRoom` (29 wp, `:379`) |

There is no `AllianceTunnel_to_HordeTunnel` counterpart to the two
`HordeTunnel_to_AllianceTunnel` paths. Paths are reversible unless listed in
`vPaths_NoReverseAllowed` (`:2260-2272`, which contains **no** WS path), and both
`selectObjectiveWp:4163-4184` and `startNewPathBegin:4321-4323` do consider the reverse
direction — but `startNewPathFree:4384` hardcodes `reverse = false`, so a bot picked up
mid-path is always pushed along the authored direction. **None of this affects WSG**,
because none of it runs there. It does affect AB and AV.

---

## 3. Findings

Classification per the plan: **disabled** (commented out or gated off), **broken**
(runs and does the wrong thing), **absent** (never written).

Confidence is `high` only where the path was read end to end **and** a matching symptom
is already recorded somewhere citable in this repo. Everything else is `medium` or
`low`, and says what would raise it.

The symptom baseline, quoted from artifact 036 and deliberately **not** re-derived
here: `bg.log` held **37 completed WSG matches as of 2026-08-16 — 16 Alliance, 6 Horde,
15 draws**, i.e. 41% scoreless with a 2.7:1 Alliance skew across **22 decisive
matches**. Twenty-two is suggestive, not conclusive. Log-line semantics are in
`docs/playerbots/WSG-BOT-MATCH.md` §6 (`winner=0` HORDE, `1` ALLIANCE, `2` draw, from
`BattleGround.h:187-189`). The 20-minute cap is `BattleGround.cpp:317-323` and is
custom to this server (`WSG-BOT-MATCH.md` §10).

| ID | Finding | `file:line` | Class | Observable symptom | Confidence |
|---|---|---|---|---|---|
| **F-01** | **`bg check objective` (relevance 10) starves `bg move to objective` (relevance 1) every 5 seconds, and re-rolls the bot's objective while doing it.** `very often` is a `TimeTrigger` with a 5 s interval whose `IsActive()` is hardcoded `true`. It fires `bg check objective` → `resetObjective()`, which wipes `bg objective` and calls `selectObjective(true)`, returning `true` whenever a position gets set. A successful action **breaks** the engine loop, ending the tick. On top of that, `resetObjective` re-randomises `bg role` with probability 1/4 on **every** call. | `BattlegroundStrategy.cpp:32-34` (rel. 10) vs `:28-30` (rel. 1); `TriggerContext.h:47`; `GenericTriggers.h:521-526`; `BattleGroundTactics.cpp:2852-2853`, `:4211-4237`, `:4219-4223`; `Engine.cpp:253-259` | **broken** | Every 5 s a bot spends its action re-deciding where to go instead of going there, and roughly every 20 s its `bg role` changes — flipping it between "supporter" (follow the team FC, `BattleGroundTactics.cpp:3063-3074`) and "attacker" (chase the enemy FC, `:3111-3121`), and between the tunnel / graveyard / ramp routes in `wsgPaths` (`:2326`, `:2342`, `:2364`). In-game this reads as bots milling around mid-field and reversing direction for no visible reason. | **medium** — the code path was read end to end; the 41% draw rate is consistent with it but not attributed to it. Raises to `high` with a per-bot action log over one match showing `A:bg check objective - OK` (`Engine.cpp:255`) interleaved with a never-executed `bg move to objective`. |
| **F-02** | **`wsgRoofJump` never uses `WS_FLAG_ALLIANCE_FLOOR_JUMP_LOWER`, and the `else` that should have used it is dead code.** Line `:2642` repeats the `UPPER` constant where the Horde mirror at `:2633` correctly uses `LOWER`; `WS_FLAG_ALLIANCE_FLOOR_JUMP_LOWER`, declared at `:36`, has **zero references** in the file. The wrong constant is not the whole defect, and swapping `LOWER` back in on its own would change nothing: the block's guard `atAllianceSecondFloorJump` (`:2604`) already requires `GetPositionY() < 1468.f`, and the inner test at `:2639` is that *same* `GetPositionY() < 1468.f`, so the `if` always wins and the `else` at `:2642` is unreachable. The Horde mirror is not degenerate — its guard (`:2603`, `y > 1450.f`) and its inner test (`:2630`, `y > 1452.f`) differ by 2 yards, leaving both arms live. A fix therefore needs **two** edits: restore `LOWER` at `:2642` *and* give `:2639` a threshold strictly inside the guard (Horde's 1450/1452 gap mirrored is ~`y < 1466.f`), with the number taken from the geometry rather than assumed by symmetry. | `BattleGroundTactics.cpp:2636-2643`, guard `:2604`, inner test `:2639`; constants `:35-38`; Horde mirror `:2603`, `:2627-2634`, `:2630` | **broken** | A bot on the Alliance base's second floor (`x>1522, y<1468, z>361`) never receives the "drop into the flag room" waypoint. It is unconditionally re-sent to `WS_FLAG_ALLIANCE_FLOOR_JUMP_UPPER` — the ledge it is already on — and *without* the jump flag, since the only call that sets that flag is the unreachable `else`. That is the last hop of the **Horde attack route into the Alliance flag room**; its absence biases matches toward Alliance, which is the direction of the recorded 16-6 skew. | **medium** — the dead `else` and the wrong constant are both unambiguous in source, and the unused symmetric partner constant proves intent; the *link* to the skew is inference over 22 decisive matches. Raises to `high` by watching a Horde bot at ~`(1529, 1468, 362)` during a live match, or from a per-faction flag-pickup count in artifact 037. |
| **F-03** | **`protectFC()` is unreachable from any live strategy, and re-enabling its trigger would not fix that.** The only trigger naming `bg protect fc` is commented out, *and* its trigger name `"team flagcarrier near"` is never registered — the class exists with a working `IsActive()`, but `Engine::ProcessTriggers` gets `nullptr` from `GetTrigger` and `continue`s. | `BattlegroundStrategy.cpp:48-50`; `PvpTriggers.h:42-49`; `PvpTriggers.cpp:233-237`; `TriggerContext.h:181-190` (no such entry); `Engine.cpp:608-615`; `BattleGroundTactics.cpp:2777-2788`, `:4635-4646` | **disabled** (trigger) + **absent** (registration) | No bot ever escorts its own flag carrier; a WSG carrier crosses the field alone. Partly compensated by `selectObjective:3063-3074`, where a `bg role < 4` bot sets its objective to the team FC's position and `Follow()`s within 50 yd — but that path is itself starved by F-01. | **high** — both halves read end to end, and the missing registration is a grep-complete absence. The same failure shape is already measured on this server: an `isUseful()` gate made `bg join` never run, 0/3 commanded joins before the fix and 8/8 after (`WSG-BOT-MATCH.md` §3). |
| **F-04** | **`bg attack fc` and the bare `bg tactics` are registered actions with no `Execute` branch.** `ActionContext.h:252` and `:257` construct `BGTactics` with names `"bg tactics"` and `"attack fc"`; `Execute` tests only for `"move to start"`, `"select objective"`, `"protect fc"`, `"move to objective"`, `"use buff"`, `"check flag"` and `"check objective"`, then falls to `return false`. | `ActionContext.h:252`, `:257`; `BattleGroundTactics.cpp:2769-2855` | **absent** | Nothing in-game today — no strategy fires them — but any future trigger or console command wired to `bg attack fc` will silently no-op and look like a broken trigger rather than a missing branch. | **high** — grep-complete over the file; no in-game symptom is claimed. |
| **F-05** | **The entire `vPaths_WS` waypoint system is dead in WSG.** `selectObjectiveWp` short-circuits for `BATTLEGROUND_WS` before reaching the path-selection loop, and `wsgPaths()` always returns `true`, so `Execute`'s `startNewPathBegin` / `startNewPathFree` are never reached. The one remaining WSG call site is gated on a spell nobody casts in WSG. | `BattleGroundTactics.cpp:4097-4103`, `:2808-2828`, `:2311-2591`, `:4439-4451`; data `:123-478`, `:2098-2116` | **absent** (dead code) | All WSG movement runs through a hardcoded x-coordinate cascade, not pathfinding: bots take one of three authored routes per `bg role` and cannot route around a blocked corridor. It also means the asymmetry in the WS path data (4 Horde-forward cross-field paths vs 2 Alliance-forward) is **not** a cause of the faction skew. | **medium** — the reachability chain was read end to end; "`wsgPaths` always returns true" rests on every branch of `:2324-2589` terminating in `return true`, checked branch by branch. Raises to `high` with a log line in `startNewPathFree` that is never hit during a WSG match. |
| **F-06** | **`wsgPaths`'s westbound (Alliance-attacking) tunnel branch is missing two `return true`s**, so two of its `MoveTo` calls are immediately overridden. `:2457-2459` and `:2460-2462` issue a `MoveTo` and then fall out of the `else if` chain into `:2471-2478`, which issues a second `MoveTo` to mid-field. The eastbound (Horde-attacking) mirror at `:2324-2341` returns from every branch. | `BattleGroundTactics.cpp:2457-2462` vs `:2333-2340`; override at `:2471-2478` | **broken** | An Alliance bot with `bg role < 4` between x≈1381 and x≈1450 is sent to mid-field instead of stepping back into the tunnel — the exact manoeuvre the inline comment at `:2457` says is required because "moving from the fasty to the gate directly is bugged". Note this defect biases *against* Alliance, i.e. against the observed skew, so it is not the skew's cause. | **medium** — the control flow is unambiguous; the in-game consequence is inferred from the author's own comment. Raises to `high` by watching an Alliance bot at x≈1445 during a live match. |
| **F-07** | **REFUTED by measurement — see §4.7. The route works, and is the best of the three base exits; only the comments were wrong, and they are fixed.** Originally recorded as: **the graveyard route is annotated `BUGGED` in the source and is still assigned to 30% of bots.** `bg role` is `urand(0,9)`, and `Preference` 4–6 selects the graveyard branch (comment at `:2342`: "`preference < 7 = move through graveyard (BUGGED)`") and its mirror at `:2480`. The comment at `:2326` claims the graveyard is disabled ("`< 6 becuse GY disabled`"), but the code does not disable it. | `BattleGroundTactics.cpp:2342`, `:2480`, `:2326`; role assignment `strategy/actions/BattleGroundJoinAction.cpp:1520`; re-roll `BattleGroundTactics.cpp:4219-4223` | **broken** | Roughly 3 in 10 bots take a route the author marked broken, and F-01's 1-in-4 role re-roll every 5 s can move a bot onto it mid-run. | **medium** — the assignment arithmetic is exact; *what* the bug is is not stated anywhere in the source. Raises to `high` by tailing one bot's position with `bg role` pinned to 5. |
| **F-08** | **`jump::position bg objective` (relevance 80.5, the highest live flag-carrier action after `rocket boots`) has `isUseful() == false` in an all-bot match.** `JumpAction::isUseful()` requires `ai->HasPlayerNearby()`, which iterates `sRandomPlayerbotMgr.GetPlayers()` — **real players only**. | `strategy/actions/MovementActions.cpp:3517-3519`; `PlayerbotAI.cpp:5991-6026`; triggers `BattlegroundStrategy.cpp:79-84` (80.5) and `:24-26` (3.0) | **broken** (in the bot-vs-bot case) | No functional loss — `bg move to objective` at 80.0 sits directly below and does the travelling — but the tournament (all-bot) configuration silently runs a *different* action ladder from a match with a human present. Anything observed with a GM in the instance is therefore not the same code path, which matters for how artifact 037 measures. | **high** — both functions read end to end, and `HasPlayerNearby` draws from the real-player map. The same "an `isUseful()` gate silently disables an action" shape is already measured here for `bg join` (`WSG-BOT-MATCH.md` §3). |
| **F-09** | **Three PvP triggers are unconditionally `false` because their entire body sits inside `#ifdef MANGOS`, and `MANGOS` is never defined** (this build defines `CMANGOS`). Affected: `PlayerHasNoFlag` (`:35-55`), `PlayerIsInBattlegroundWithoutFlag` (`:124-143`), `TeamHasFlag` (`:177-198`). Those bodies also call `GetAllianceFlagCarrierGuid()` / `GetHordeFlagCarrierGuid()`, which **exist nowhere in `src/`** — the file only compiles because the blocks are excluded. | `PvpTriggers.cpp:35-55`, `:124-143`, `:177-198`; `src/modules/PlayerBots/CMakeLists.txt:131`; registrations `TriggerContext.h:185`, `:187`, `:191` | **broken** (silently disabled by a define) | Nothing today: no strategy in this repo fires `"player has no flag"`, `"team has flag"` or `"in battleground without flag"`. It is a trap — a future strategy using one gets a trigger that never fires, and the code will not compile if the `#ifdef` is ever flipped. | **high** — grep-complete: the define is absent from all of `src/`, and the three trigger names appear nowhere outside their own declaration and registration. |
| **F-10** | **`vPaths` and `vFlagIds` are declared uninitialised and are dereferenced without a guaranteed assignment.** `:2720-2721` declares them with no initialiser; the `switch` at `:2729-2767` has a `default: break` assigning neither, and the AV case assigns `vPaths` only. `*vPaths` is dereferenced at `:2810`, `:2824`, `:2827`, `:2843`; `vFlagIds` is null-tested at `:2841` while possibly indeterminate. | `BattleGroundTactics.cpp:2720-2721`, `:2737-2742`, `:2765-2766`, `:2810`, `:2841` | **broken** (latent) | Latent, but not for the reason a first reading gives. Two of this fork's five live BG type ids — `BATTLEGROUND_BR` = 4 (Blood Ring) and `BATTLEGROUND_SV` = 5, `SharedDefines.h:1748-1749`, both dispatched throughout `BattleGroundMgr.cpp` — have **no `case`** in this `switch` and fall to `default: break` with `vPaths` indeterminate. The `IsArena()` early-out at `:2708-2714` that would have caught Blood Ring before the `switch` is itself inside `#ifndef MANGOSBOT_ZERO`, i.e. compiled out of exactly this build. The **only** thing keeping the `default` arm unreached today is one line in another file: `AiFactory.cpp:1106` adds the `battleground` strategy — and with it every `bg *` action — only when `bgType <= BATTLEGROUND_AB`, and nothing else adds them, so `BGTactics::Execute` never runs in a BR or SV instance. Widening that gate, restoring a bot-side arena path, or adding a BG type dereferences an indeterminate pointer. The AV `vFlagIds` read at `:2841` is separately unreachable because `:2838` returns first. | **high** for the code fact and for the BR/SV gap — both read directly. **medium** that no current symptom exists: it rests on `AiFactory.cpp:1106` being the sole route to these actions, which is grep-complete over `src/` for all nine `bg *` action names (only `BattlegroundStrategy.cpp` fires them; `RogueStrategy.cpp:1439-1442` only name-tests them) but is one config change or refactor away from being false. |
| **F-11** | **`ai->ChangeStrategy("-buff", BOT_STATE_NON_COMBAT)` runs on every `BGTactics::Execute` call** — once per action tick per bot for the whole match — rather than once at match start. | `BattleGroundTactics.cpp:2716-2718` | **broken** (efficiency) | 20 bots × several ticks per second × a strategy-list mutation each. **"No behavioural difference is expected" was wrong — see §4.2a.** `Engine::ChangeStrategy` used to call `Init()` unconditionally, and `Init()` → `Reset()` drains the action queue, so this no-op call destroyed the rest of the tick from inside `BGTactics::Execute`. That is why `bg move to objective` never ran. Fixed by guarding the rebuild on an actual change of the strategy set. | **medium** — the code fact is certain; "no behavioural difference" is inference. A `PERF_MON_ACTION` sample over one match would settle the cost. |
| **F-12** | **`moveToStart()` returns `true` even when it issues no movement, and swallows every `MoveTo` result.** For WSG, `bg role` 4–6 maps to `BB_WSG_WAIT_SPOT_SPAWN` at `:2877`, neither the `RIGHT` nor `LEFT` branch runs, and control falls through to the unconditional `return true` at `:2958`. | `BattleGroundTactics.cpp:2858-2959`, specifically `:2877-2891` and `:2958` | **broken** | ~30% of bots do not reposition during the pre-match gate phase (arguably intended — that *is* the "spawn" wait spot), but the engine is told the action succeeded either way, so `bg move to start` always wins its tick and logs OK. Any genuine failure to move is invisible in the action log. The same masking applies to `wsgPaths()` (F-05), which returns `true` regardless of what `MoveTo` returned. | **medium** — the control flow was read directly; whether the spawn-spot case is intended is recorded nowhere. Raises to `high` from the upstream vmangos source this was lifted from, or a note from the author. |
| **F-13** | **`flagTaken()` and `teamFlagTaken()` are named backwards relative to what they return.** `flagTaken()` (`:4617-4624`) indexes the *other* team's slot and so means "*my* team holds the *enemy* flag"; `teamFlagTaken()` (`:4626-4633`) indexes *my* team's slot and means "the *enemy* holds *my* flag". The index is the flag's **owning** team, and the carrier stored there is of the opposite faction. | `BattleGroundTactics.cpp:4617-4633`; `src/game/Battlegrounds/BattleGroundWS.h:144-155`; `src/game/Battlegrounds/BattleGroundWS.cpp:356-386` | **broken** (naming only) | No behavioural symptom — both live call sites (`:4228`, `:4667`) use them with the correct meaning. It is a trap for the next reader, and the commented-out condition at `:3031` (`if (!flagTaken() && !teamFlagTaken()) break;`) is exactly the edit that would go in inverted. | **high** — verified against the core's own setters, end to end. |
| **F-14** | **`selectObjective`'s WSG branch refuses to fetch the enemy flag whenever a real player is on the bot's own team.** `BgTeamHasRealPlayer(bg, bot->GetTeam())` gates the flag-fetch in both the supporter and attacker branches; when it is true the bot instead patrols a random point around `(1227.4, 1476.2, 307.5)`. Deliberate, dated 2026-07-27 in the inline comment. | `BattleGroundTactics.cpp:2961-2980`, `:3086-3108`, `:3122-3141` | **disabled** (deliberate) | Bot behaviour depends on whether a human is in the match **and on which team they joined**. A GM who joins Alliance to observe turns Alliance bots into pure defenders while Horde bots keep attacking. Any observation made with an observer present is not the all-bot behaviour, and observer presence is itself a faction-asymmetric confound for the 16-6 skew. | **high** — the gate, its team scoping and its consequences are all read directly, and the code's own comment at `:2961-2970` documents the intent. |
| **F-15** | **`botSelectedObjectives` / `botObjectiveSelectionTime` are file-static maps of raw `GameObject*` keyed by bot GUID and are never erased.** Entries outlive the battleground instance whose GameObjects they point at. | `BattleGroundTactics.cpp:83-84`, `:3160-3164`, `:3193-3214` | **broken** (latent) | AB only, and guarded in practice: `:3193-3194` uses the stored pointer only if it is still present in a set rebuilt from the live map, and that is a pointer comparison with no dereference. A freed-and-reallocated `GameObject` landing on the same address would defeat it. The maps also grow without bound over a server's lifetime. | **low** — the leak and the dangling pointer are certain from the declaration; the reallocation collision is speculative. Raises with an ASan run across two consecutive AB matches. |
| **F-16** | **A debug `bot->Say()` is left in the AB objective path.** `bot->Say("I'm dead, guess I'll reset my objective.", LANG_UNIVERSAL)` fires whenever a dead bot with a stored objective runs `selectObjective`; the author's own trailing comment doubts the branch ever runs. | `BattleGroundTactics.cpp:3162-3163` | **broken** (debug residue) | Bot chat spam in Arathi Basin, visible to any player in `/say` range. | **high** — reading the line is the whole finding. |

### 3.1 What this reading does *not* explain

Stated explicitly so the next reader does not assume these were checked and found
empty. **§4 has since answered the second of these and reframed the first** — read
§4.2 and §4.3 before acting on anything here.

- **The 2.7:1 Alliance skew is not attributed.** F-02 points the right way, F-06 points
  the wrong way, and F-14 is a confound of unknown size. `wsgPaths` and `wsgRoofJump`
  are hand-written mirrors rather than a mirrored transform, and their thresholds
  diverge in ways this pass did not exhaustively check — for example the in-combat gate
  at `:2636` uses `pos.x < 1421.f`, where the Horde mirror at `:2627` uses its own base
  boundary `pos.x > 933.f` and the Alliance mirror of that would be `1522.f`. F-02 is
  the one member of that class chased to the end, where the divergence collapses the
  guard and the inner test onto the same threshold and kills a branch; the remaining
  thresholds in `wsgRoofJump` and `wsgPaths` were not given the same treatment. Settling
  this needs the per-faction flag-pickup and flag-capture counts from artifact 037, not
  more code reading.
- **The 41% draw rate is not attributed either.** F-01 is the strongest candidate and
  F-03 supports it, but neither has a measurement attached yet.
- **`CheckFlagAv`, `SelectAvObjectiveAlliance`/`Horde` and the AB objective selector
  (`:3151-3260`) were read only for the specific sweeps listed in the plan** — early
  returns, `urand` rolls, uninitialised pointers, container indexing — not end to end.
  AB's random objective index at `:3242` *is* correctly guarded by the
  `!uniqueObjectives.empty()` test at `:3237`.
- **The combat engine's own strategies were not analysed** — `boost`, `racials`,
  `default`, `aoe`, `dps assist`, `pvp` (`AiFactory.cpp:669`). They sit alongside
  `warsong` in the combat engine and their relevances compete with the §1.1 ladder.

---

## 4. Measured — one live WSG match, 2026-08-18

Everything above §4 is a code reading. Everything in §4 is a measurement, and every
number says where it was read from. Artifact 037.

### 4.0 The run

| | |
|---|---|
| Run directory | `/home/deck/tournament-runs/037-wsg-2` (`match.log`, `gear.log`, `assemble.log`, `bg-slice.log`, `telemetry.csv`, `report.txt`, `bots-window.log`) |
| Command | `scripts/tournament/match-run.sh stormwind-sentinels orgrimmar-warsong`, `ASSEMBLE_MODE=direct` |
| Image running | **`tortoise-cm:20260818-2`** — see the note below |
| Config | `Tournament.TelemetryIntervalMs = 5000` in `~/tortoise-wow-server-V2/etc/mangosd.conf`, `docker restart tcm-mangosd`; `AiPlayerbot.MinRandomBots`/`MaxRandomBots` set to 0 so the population gate could pass |
| Started / ended | 2026-08-18 13:12:46Z / 13:32:06Z |
| Duration | **20m21s** — the full 20-minute cap (`BattleGround.cpp:317-323`) |
| Result | `[2,101]: winner=2, duration=20m21s` in `bg.log` — a **0-0 draw**; `MATCH ... winner=NONE ... allianceScore=0 hordeScore=0` |
| Telemetry | 4540 samples, 20 players × 227 samples, `t` = 61 s to 1199 s |

**Which image, and why not the newest.** `Tournament.TelemetryIntervalMs` is read by
the C++ sampler from artifact 026, so it only exists in a binary built after 026 was
batched. `docker ps` found the stack down; of the images on this host, 026's commit
(`41e15e4`) is reachable only from `integration/20260818-2`, **not** from
`integration/20260818-3`, which `.env`'s `TW_IMAGE` points at. The measurement was
therefore taken on `tortoise-cm:20260818-2`. That image contains everything up to and
including 026/027/029 but not the three artifacts batched into `-3`, none of which
touch bot AI.

**Two caveats, stated up front.**

1. **The gear gate was bypassed.** `gear-audit.sh` reports
   `stormwind-sentinels complete=5/10 worstMissing=8` and
   `orgrimmar-warsong complete=6/10 worstMissing=8`, and `gear-apply.sh` cannot close
   the gaps — the provisional tier files pick items the bots answer with
   `cannot_equip(8)` / `cannot_equip(17)`. The match was run through a local copy of
   `match-run.sh` with the gate demoted from `fatal` to a log line. This matters for
   any claim about who would win a fight. It does **not** touch anything §4 actually
   concludes, because no fight happened: bare-handed bots still walk.
2. **No human was in the instance.** That is deliberate — `selectObjective`'s
   `BgTeamHasRealPlayer` gate (F-14) makes bot behaviour depend on whether a player is
   present and on which team they joined, so an observed match is not an all-bot match.

### 4.1 The four questions

**Do bots leave their base at all? No. Not one of them moved.**

```
REPORT players=20 expected=20 entered=20 stuck=20
MOVEMENT player=Wsgaone   distance=0.0 maxStep=0.0 idleSamples=226 stuck=1
... identical for all 20 ...
```

(`scripts/tournament/telemetry-report.sh` over `telemetry.csv`.) Read independently
out of the CSV, every player has exactly **one distinct `(x, y)`** across all 227 of
its samples. All 20 entered — assembly is not the problem — and all 20 stood on their
spawn point for the entire 20 minutes.

One bot, `Wsgaeight`, is `alive=0` for **all 227** of its samples: it was dead before
the first sample and never released, never ran to its corpse, never resurrected.

**Do the two sides ever occupy the same ground? Never — they stay half a map apart.**

| | x range across the whole match |
|---|---|
| Horde (`team=67`) | 943.1 … 950.2 |
| Alliance (`team=469`) | 1495.0 … 1519.5 |

- Closest Alliance-Horde pair at any sample: **544.8 yd**, at `t=61` (the first sample).
- Closest any Alliance bot came to the Warsong (Horde) flag at `(916.02, 1434.40)`: **579.5 yd**.
- Closest any Horde bot came to the Silverwing (Alliance) flag at `(1540.42, 1481.32)`: **590.6 yd**.

Flag positions are the live spawns in `tw_world.gameobject` for map 489, not literals
from the bot code. Sustained separation of this size is not "fighting badly" — it is a
different problem, exactly as the artifact anticipated.

**How much of the match is spent in combat? 0.00%.**

`combat=1` appears in **0 of 4540** samples. `alive=1` in 4313 of 4540 (95.0%), and
every one of the 227 dead samples belongs to `Wsgaeight`.

**Was the flag ever picked up? No.**

`honor.log` holds **zero** 495-honor bursts dated 2026-08-18 — the marker that showed
the first recorded match was really a 2-0 Horde win (`WSG-BOT-MATCH.md` §6). With the
closest approach to either flag at ~580 yd, and `atFlag()` engaging only inside
`VISIBILITY_DISTANCE_TINY` = 25 yd (`BattleGroundTactics.cpp:4431`), no pickup was
geometrically possible.

### 4.2 Why the bots stand still — from `bots.log`, not from reasoning

`bots-window.log` is `bots.log` sliced to 13:12:46Z–13:32:06Z and filtered to the 20
`Wsg*` bots: 403,139 lines, **25,476 AI ticks**. The AI is running and the
battleground strategies are attached — `T:bg active` fires every tick. What it does
with those ticks:

| line | count |
|---|---|
| `PUSH:bg move to objective - 1.000000 (trigger)` | 23,908 |
| **`A:move to objective - <anything>`** | **0** |
| `PUSH:bg check flag - 70.000000 (trigger)` | 23,908 |
| `PUSH:bg check flag - 20.000000 (trigger)` | 23,908 |
| `A:check flag - PREREQ` / `A:check flag - FAILED` | 23,681 / 23,681 |
| `PUSH:bg check objective - 10.000000 (trigger)` | 4,370 |
| `A:check objective - PREREQ` / `A:check objective - FAILED` | 16 / 16 |
| `A:select objective` / `A:protect fc` / `A:attack fc` / `A:move to start` | 0 / 0 / 0 / 0 |
| ticks ending `no actions executed` | **25,175 of 25,476 (98.8%)** |

`bg move to objective` is the only action that carries a WSG bot across the field. It
was queued 23,908 times and **popped zero times**. The tick is spent on `bg check
flag`, whose action returns `atFlag(...)` == false (`BattleGroundTactics.cpp:2834-2850`)
and is logged `FAILED`, after which the tick ends.

The relevance ladder that produces this is `BattlegroundStrategy.cpp`:

| trigger | action | relevance | line |
|---|---|---|---|
| `bg active` | `check mount state` / **`bg move to objective`** | 2.0 / **1.0** | `:28-30` |
| `very often` | `bg check objective` | 10.0 | `:32-34` |
| `bg active` | `bg check flag` | `ACTION_HIGH` = 20.0 (`strategy/Strategy.h:30`) | `:36-38` |
| `bg active` (`WarsongStrategy`) | `bg check flag` | **70.0** | `:59-61` |

The mover sits at the bottom of the ladder, under a check action at 70 that fails on
every tick without yielding. This is **F-01's mechanism confirmed and its attribution
corrected**: the starving action is `bg check flag` at 70, not `bg check objective` at
10. What is *not* settled is whether `Engine::DoNextAction`'s queue walk is
*defective* — ending the tick early — or behaving exactly as designed, with a failing
relevance-70 action legitimately consuming the tick and relevance 1 simply unreachable
underneath it. The gate phase is the contrast to explain: sliced from the same
`bots.log` to **13:11:38Z–13:12:34Z**, before `TOURNAMENT start instance=101 ok=1`
fires (`bg-slice.log`, 13:12:35Z), the same bots tick 1,414 times with **nothing at
relevance 70 in the queue** — no `PUSH:bg check flag` at all — and execute
`check values` (relevance 1.0) **188 times OK** and `move to start` **34 times OK**.
Across the 25,476 match ticks, with `bg check flag` at 70 pushed and failing every
tick, `A:check values - OK` appears **12** times and `A:move to start` never. Same
bots, same instance, same relevance table; the variable is the failing relevance-70
action. That question is
`docs/backlog/046-wsg-bots-never-execute-bg-move-to-objective.md`, and it wants an
instrumented build, not more reading.

#### 4.2a After — the tick was ended early, by the action itself

Artifact 046 settled it by reading, and the answer is (a), an engine defect: the queue
walk is fine, but the queue is destroyed underneath it. `BGTactics::Execute` runs
`ai->ChangeStrategy("-buff", BOT_STATE_NON_COMBAT)` on **every** tick of a battleground
in progress (`BattleGroundTactics.cpp:2716-2718`, the preamble step §2 lists as F-11 and
scores "nothing directly"). `Engine::ChangeStrategy` ended with an **unconditional**
`Init()` (`Engine::ChangeStrategy`, `strategy/Engine.cpp:871-872` before this change),
and `Init()` calls `Reset()` (`strategy/Engine.cpp:104`, `:79-92`), which pops and deletes every `ActionBasket` still
in `queue`. Because that call is made from inside `ListenAndExecute`, it lands in the
middle of `DoNextAction`'s `do { ... } while (basket && ...)` loop (`:141-326`): the next
`queue.Peek()` returns `NULL`, `basket` goes null, the loop exits, and the tick reports
`no actions executed` (`:352`). `bg check flag` at relevance 70 is simply the first
`BGTactics` action popped each tick, so it is the one that detonates the queue —
everything below it, `bg check objective` at 10, `check mount state` at 2 and
`bg move to objective` at **1.0**, is deleted before it can be popped.

That accounts for the asymmetry exactly. In the 1,414 gate-phase ticks
`bg->GetStatus()` is `STATUS_WAIT_JOIN`, not `STATUS_IN_PROGRESS`, so the
`ChangeStrategy` line never runs, the queue survives the tick, and relevance 1.0 is
reached **188** times. In the 25,476 match ticks it runs every tick and relevance 1.0 is
reached **12** times — the residue of the ticks where no `BGTactics` action was popped
at all. The relevance table in `BattlegroundStrategy.cpp:18-91` is *not* the fault and is
left untouched: re-ordering it would only move which action detonates the queue.

The fix guards the rebuild on an actual change of the strategy set
(`Engine::StrategySignature`, `strategy/Engine.cpp`): `addStrategy` and `ChangeStrategy`
now call `Init()` only when the set of attached strategies really moved. `-buff` moves it
once, on the first `BGTactics` tick after the gates open; every tick after that is a
no-op and the queue survives to the bottom of the ladder.

**The "after" match numbers are not filled in yet.** Re-running the 037-wsg-2 procedure
with `Tournament.TelemetryIntervalMs = 5000` against a build carrying this change is the
gate in artifact 046's acceptance criteria — at least 15 of 20 bots with
`distance > 100` yd, at least one Alliance/Horde sample inside 30 yd, and
`A:move to objective - OK` for at least five distinct bots. This paragraph is to be
amended with the measured values when that run lands; nothing is claimed here that was
not measured.

### 4.3 The flag-carrier lead is **explicitly refuted**

The lead this artifact existed to test — that the three commented-out flag-carrier
triggers at `BattlegroundStrategy.cpp:44-56` cause the 0-0 draws — is refuted by two
independent measurements.

1. **Sequence.** A flag-carrier trigger fires on a flag carrier. In the measured match
   no bot moved, no bot came within 579 yd of a flag, and no flag was picked up. There
   is no state in which any of those three triggers could have fired, so they cannot
   be what ended the match 0-0.
2. **History.** Those triggers were already commented out during the period when this
   server's bots played WSG properly. `strategy/generic/BattlegroundStrategy.cpp` has
   not been modified since commit `0af2567`, 2026-05-10. Over that unchanged file,
   `bg.log` and `honor.log` record:

| date | Horde wins | Alliance wins | draws | 495-honor flag-capture awards |
|---|---|---|---|---|
| 2026-08-10 | 6 | 15 | 14 | 184 |
| 2026-08-11 | 0 | 1 | 1 | 30 |
| 2026-08-17 | 0 | 0 | 2 | 0 |
| 2026-08-18 | 0 | 0 | 5 | 0 |

  (`[2,<instance>]: winner=<n>` in `bg.log`, `0`=HORDE `1`=ALLIANCE `2`=draw,
  `BattleGround.h:187-189`; `Player <name> ... got 495.000000 honor for type 3` in
  `honor.log`, ten per capture.) Every one of the **22 decisive matches** on this
  server, and every flag capture ever recorded on it, falls on 2026-08-10/11 — with
  the triggers commented out the whole time. Every match since 2026-08-17 is a
  scoreless draw.

The same table refutes a second thing worth stating plainly: **the 2.7:1 Alliance skew
and the current all-draw regime are not the same phenomenon.** The skew is 15-6 over
21 decisive matches, all on 2026-08-10; §3.1 was right not to attribute it. Twenty-one
is still a small sample and a single day's configuration.

What the table *does* point at is a regression between 2026-08-11 and 2026-08-17, in a
window where the bot AI source did not change but `aiplayerbot.conf` did — that is
`docs/backlog/047-find-the-playerbot-config-change-that-froze-wsg-bots.md`, and it is
config-only.

### 4.4 Recommendations, ranked by expected match-quality gain per unit of risk

Ranked deliberately on that ratio, not on gain alone: a change touching shared pathing
or the engine's relevance queue is higher risk than one re-enabling a trigger or
deleting a debug line, because relevance interacts globally — raising one action
starves others, which is precisely how the state measured above was reached.

| # | Recommendation | Expected gain | Risk | Artifact |
|---|---|---|---|---|
| 1 | Bisect the `aiplayerbot.conf` deltas across the 2026-08-11 → 2026-08-17 regression window against a real match | **Very high** — plausibly restores a working match outright | **Very low** — config only, no build, revertible by copying a backup back | `docs/backlog/047-find-the-playerbot-config-change-that-froze-wsg-bots.md` |
| 2 | Establish why `bg move to objective` is never popped, and fix it | **Very high** — nothing else in this list is observable until bots move | **Medium** — the candidate sites are `Engine::DoNextAction` and the relevance table, both global to every bot on the server, not just BG bots | `docs/backlog/046-wsg-bots-never-execute-bg-move-to-objective.md` |
| 3 | Register `"team flagcarrier near"` so `protectFC()` is reachable at all | Medium — a carrier gets an escort, once carriers exist | Low — one registration; restoring the trigger node itself is a separate, argued decision | `docs/backlog/050-team-flagcarrier-near-trigger-is-never-registered.md` |
| 4 | Fix `wsgRoofJump`'s dead Alliance `else` and the unused `LOWER` constant (F-02) | Medium — restores the last hop of the Horde attack route, the one defect pointing the same way as the recorded skew | Low — WSG-only, one function, no shared pathing | `docs/backlog/048-wsg-alliance-flag-room-drop-unreachable.md` |
| 5 | Add the two missing `return true`s in `wsgPaths`'s westbound branch (F-06) | Low-medium — stops Alliance tunnel bots being dragged back to mid-field | Low — two statements inside one `else if` chain | `docs/backlog/049-wsg-westbound-tunnel-move-is-overridden.md` |
| 6 | Characterise the graveyard route marked `BUGGED`, then fix or actually disable it (F-07) | Medium — it is assigned to ~30% of bots | **Medium-high** — it is shared pathing, and what the bug *is* is written down nowhere; needs measuring before touching | `docs/backlog/053-wsg-graveyard-route-is-marked-bugged-and-still-assigned.md` |
| 7 | Initialise `vPaths`/`vFlagIds` and guard their dereference (F-10) | None visible today | Very low — and it removes a real crash one config change away | `docs/backlog/052-bgtactics-vpaths-uninitialised-for-blood-ring-and-sv.md` |
| 8 | Resolve the three `#ifdef MANGOS` PvP triggers — port or delete (F-09) | None today | Very low — no strategy fires them | `docs/backlog/051-pvp-flag-triggers-compiled-out-by-ifdef-mangos.md` |
| 9 | Delete the debug `bot->Say()` in the AB objective path (F-16) | Cosmetic, but player-visible in Arathi Basin | Lowest in the list — one line, no control flow | `docs/backlog/054-debug-say-left-in-the-arathi-objective-path.md` |

Items 3-9 are all **unobservable in-game until 1 or 2 lands**, and each artifact says so.

### 4.5 Findings that got no artifact, and why

The backlog is work, not a notebook. These stay here:

- **F-04** (`bg attack fc` / bare `bg tactics` have no `Execute` branch) — no strategy
  fires them; nothing to observe and nothing a user could ask for.
- **F-05** (`vPaths_WS` is dead in WSG) — a true and important fact about where WSG
  movement comes from, but the fix is "delete 350 lines of data nobody reads", which
  is not an improvement to a match.
- **F-08** (`jump::position bg objective` is `isUseful() == false` in an all-bot match)
  — no functional loss; it is a constraint on how to measure, and §4.0 already applies
  it by keeping observers out of the instance.
- **F-11** (`ChangeStrategy("-buff")` every tick) — the analysis expects no
  behavioural difference, and the measurement gives no reason to revisit that.
- **F-12** (`moveToStart()` returns `true` without moving) and **F-13** (`flagTaken()`
  / `teamFlagTaken()` named backwards) — both are traps for the next reader with no
  live symptom; both are called out inside the artifacts that touch their code.
- **F-14** (`BgTeamHasRealPlayer` gate) — deliberate and dated in the source. It is a
  measurement constraint, not a defect.
- **F-15** (`botSelectedObjectives` never erased) — AB only, guarded in practice,
  `low` confidence; it wants an ASan run before it wants a fix.

One thing found *while* measuring, recorded here because it blocks the next
measurement rather than the bot AI: **`match-run.sh`'s gear gate currently fails every
match on this host.** `gear-apply.sh` cannot dress 9 of the 20 tournament bots — the
provisional tier files pick items that come back `cannot_equip(8)` / `cannot_equip(17)`
— so `gear-audit.sh` never passes and the run aborts before assembly. Anyone repeating
this measurement will hit it. It belongs to the gear track
(`docs/backlog/031-gear-tier-armour-weapon-split.md`), not to this analysis.

### 4.6 Refuted — the regression is **not** in `aiplayerbot.conf`

Artifact 047 existed to bisect the six-day config window that `bg.log` and `honor.log`
bracket (§4.3's table: every decisive match and every flag capture on this server falls
on 2026-08-10/11). The bisect never got past its first round, because its first round is
also its stop condition: **restore the whole `aiplayerbot.conf.bak-alive-20260809`
backup wholesale, and the bots still do not move a single yard.**

| | |
|---|---|
| Date | 2026-08-19 |
| Image | `tortoise-cm:20260818-2` — the same image §4.0 measured on, and it predates artifact 046's `Engine::StrategySignature` fix (`74d2ace`) |
| Config | `~/tortoise-wow-server-V2/etc/aiplayerbot.conf` = `aiplayerbot.conf.bak-alive-20260809` copied over wholesale, with only `AiPlayerbot.MinRandomBots`/`MaxRandomBots` forced to 0 so `match-run.sh`'s population gate could pass; `Tournament.TelemetryIntervalMs = 5000`; `docker restart tcm-mangosd` |
| Matches | two, `scripts/tournament/match-run.sh stormwind-sentinels orgrimmar-warsong`, `ASSEMBLE_MODE=direct` — 14:00–14:18Z (19 bots entered) and 14:30–14:49Z (20 bots entered, `MATCH ... winner=NONE ... allianceScore=0 hordeScore=0 duration=1118`) |
| Result | **0 of 20** bots with `distance > 100` in either match. 39 of 39 bot-slots read `distance=0.0 maxStep=0.0 stuck=1`; `combat=1` in 0 samples |

The pass/fail signal was fixed in advance by the artifact — at least 15 of 20 bots with
`distance > 100` on `telemetry-report.sh`'s `MOVEMENT` lines — and the 2026-08-09 config
scores zero. Under the artifact's own stop rule the bisect ends here: none of the keys
listed in it (`DisableActivityPriorities`, `botActiveAlone`, `AreaLevelGateEnabled`,
`DestinationDangerEnabled`, `TravelPreemptiveLevelGap`, `DisableBotOptimizations`,
`GlobalCooldown`, `RepeatDelay`, the `+pull` / `+rpg` strategy additions) was tested
individually, and none needs to be: the config that predates all of them reproduces the
freeze exactly. The order those keys would have been tried in, had round one passed, was
the movement and activity gates first, then the timing keys, then the strategy strings —
it was never reached.

That leaves §4.2a's engine defect as the whole explanation, which is consistent: the
`Engine::ChangeStrategy` → `Init()` → `Reset()` queue wipe is in `strategy/Engine.cpp`
and no `aiplayerbot.conf` key can reach it. The six-day window in the logs is a
coincidence of when matches were *run*, not of when behaviour changed.

**A trap for anyone repeating this.** Battleground instance ids are reused — every run
here got `instance=101` — and `telemetry-extract.sh` filters `bg.log` by instance id
alone, over the whole file. Extracting "instance 101" therefore silently interleaves
today's match with 2026-08-18's, and the interleaved position stream reports invented
`distance=16080.3 maxStep=38.4` for bots that never left their spawn point. Slice
`bg.log` to the match's wall-clock window *first* and pass the slice with `--log`; the
run directory's own `telemetry.csv` has the same defect, since `match-run.sh:539` passes
only `--instance`.

**State left behind.** The live `aiplayerbot.conf` and `mangosd.conf` are byte-identical
to the backups taken before this run — `aiplayerbot.conf.pre-047-bisect-20260819` and
`mangosd.conf.pre-047-20260819`. `MinRandomBots`/`MaxRandomBots` are back at **1000**
and `Tournament.TelemetryIntervalMs` is back at **0**; anyone measuring telemetry again
must set it to 5000 and restart mangosd, as §4.0 did.

### 4.7 Refuted — the graveyard route (F-07) is **not** bugged, and is the best of the three exits

F-07 recorded that `wsgPaths()`'s graveyard branch is annotated `BUGGED`
(`BattleGroundTactics.cpp:2342`, mirror `:2480`), that a second comment at `:2326`
claims the graveyard is disabled when the code does not disable it, and that
**nothing in the repository says what the bug is**. Artifact
`docs/backlog/053-wsg-graveyard-route-is-marked-bugged-and-still-assigned.md`
asked for that to be characterised before the branch was either fixed or turned
off. It was measured, and the annotation does not survive the measurement.

| | |
|---|---|
| Date | 2026-08-19, instance 101, 16:57:12Z–17:18:00Z (`bg.log`: `winner=1, duration=22m`) |
| Image | `tortoise-cm:20260819-1` (revision `2593df6`) — contains artifact 046's `Engine::StrategySignature` fix, without which no bot moves and no route can be told from another |
| Config | `Tournament.TelemetryIntervalMs = 5000`; WSG match mode on (`wsg-mode.sh on --tournament`), random pool 0 |
| Assembly | `tournament create` / `tournament add` / `tournament start` driven directly, **not** `match-run.sh` — its gear gate still fails on this host (see the note at the end of §4.5), and gear has no bearing on pathing |
| Sample | 4,500 `TELEMETRY tick` lines, 20 bots × 225 samples |

**Route attribution.** `bg role` cannot be read back — `rndbot debug <bot> values bg`
crashes the world — so routes are attributed geometrically, from the band just
outside each base where the three branches run at clearly different `y`. Only the
**outbound** leg is counted: the return leg through the same band is chosen by a
different test (`Preference < 5`), and counting it would conflate the two. Bands:
Horde side `x ∈ [1035, 1115]` heading east, Alliance side `x ∈ [1345, 1385]`
heading west; within a band, graveyard / tunnel / ramp separate on `y` cleanly.
This measures corridor traffic, not per-bot roles — `resetObjective()` re-rolls
`bg role` one tick in four (F-01), so no bot holds one role for a whole match.

| Base exit | Outbound samples | Share | Crossings begun | Reached the middle within 90 s |
|---|---|---|---|---|
| tunnel (`Preference` 0-3) | 148 | 36.4% | 81 | 57 — **70.4%** |
| graveyard (`Preference` 4-6) | 89 | 21.9% | 49 | 38 — **77.6%** |
| ramp (`Preference` 7-9) | 170 | 41.8% | 94 | 58 — **61.7%** |

`urand(0, 9)` predicts 40 / 30 / 30. The graveyard is under-used relative to that
and the ramp over-used, which is expected rather than a defect: the mid-field
fallback and the `atHordeGY` / `atAllyGY` escape clauses both push traffic onto
the ramp.

**What graveyard traffic does differently — the numbers the artifact asked for.**
17 of the 20 bots took the graveyard exit at least once. Those 17 travelled
**5,765 yd** on average and **17 of 17** came within 20 yd of the enemy flag room
(mean closest approach 1.4 yd), with 30 stalled samples each. The 3 that never took
it travelled **3,950 yd**, 2 of 3 reached the flag room, and averaged 87 stalled
samples — a figure dominated by `Wsgasix`, which never moved at all (0.0 yd over
225 samples, parked at `(1520, 1482, 352)`; that is F-12's `moveToStart` spawn-wait
case, not a routing failure).

**Where bots stop, and it is not the graveyard.** Stalled samples (< 1 yd between
consecutive 5 s samples) cluster at `(1520, 1480)` 145 — the one frozen bot —
`(1050, 1540)` 66 at the Horde **ramp** top, `(920, 1430)` 49 in the Horde flag
room, and `(990, 1420-1430)` 50 at the Horde upper gate, of which 46 are in combat.
Neither graveyard waypoint appears: the busiest bucket within 30 yd of one holds 5
samples. The two `noPath` drops the branch uses — `(1076.8, 1396, 324)` and
`(1398.7, 1534.6, 322.5)` — caused **no** non-combat health loss anywhere in the
match (the only two such samples in 4,500 are at `(1130, 1540)` and `(1530, 1480)`,
neither near a drop) and no deaths; deaths cluster at `(1440, 1480)` (4) and on the
Horde ramp (4).

**Conclusion, and what changed.** The route is not corrected and the branch is not
disabled, because the measurement the artifact required first says there is nothing
to correct and nothing worth turning off: on completion rate the graveyard is the
**best** of the three exits. What was wrong was the two comments, and they are what
changed — `:2326` no longer claims the graveyard is disabled, and the branch itself
now carries these numbers instead of a bare `BUGGED`. **`bg role`'s `urand(0, 9)`
is untouched**, as the artifact required.

**A lead this run turned up, out of scope here.** The Horde ramp top
`(1050, 1538, 332)` holds 66 stalled samples, only 8 of them in combat, and the ramp
has the worst completion rate of the three exits at 61.7%. That is the branch worth
the next look, not the graveyard.
