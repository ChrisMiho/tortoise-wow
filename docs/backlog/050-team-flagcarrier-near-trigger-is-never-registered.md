---
status: pending
risk: low
area: playerbots/battlegrounds
depends-on:
---

# `protectFC()` can never run, and uncommenting its trigger would not change that

**Problem:** `BGTactics::protectFC()`
(`BattleGroundTactics.cpp:4635-4646`) is correct — it `Follow()`s the bot's own
flag carrier within 50 yards — and completely unreachable. Two separate things
block it, and only one of them is visible at the call site:

1. The only trigger that names the `bg protect fc` action is commented out
   (`strategy/generic/BattlegroundStrategy.cpp`, the `"team flagcarrier near"`
   block).
2. The trigger name `"team flagcarrier near"` is **not registered** in
   `TriggerContext.h` at all. The class exists with a working `IsActive()`
   (`PvpTriggers.h:42-49`, `PvpTriggers.cpp:233-237`), but
   `Engine::ProcessTriggers` gets `nullptr` back from `GetTrigger` and
   `continue`s (`Engine.cpp:608-615`).

So uncommenting the trigger — the obvious fix — produces a trigger node that is
silently skipped on every tick, with nothing in any log to say why. In-game: no
bot ever escorts its own flag carrier; a WSG carrier crosses the field alone.

**Suspected cause / area:**
`src/modules/PlayerBots/playerbot/strategy/TriggerContext.h` (missing
registration), `strategy/generic/BattlegroundStrategy.cpp` (commented-out trigger
node), `strategy/triggers/PvpTriggers.h` / `.cpp` (the trigger class itself).

**Acceptance criteria:**

- `"team flagcarrier near"` is registered in `TriggerContext.h` alongside the
  other PvP triggers, so `AiObjectContext::GetTrigger("team flagcarrier near")`
  returns non-null.
- Whether the commented-out trigger node in `BattlegroundStrategy.cpp` is
  restored is a deliberate, stated decision in the commit message, not an
  accident: restoring it adds a relevance-40 action to a ladder that already
  starves its relevance-1 mover (see `046`), so the relevance it is restored at
  must be argued, and "left commented out, registration fixed so the next reader
  is not trapped" is an acceptable outcome of this artifact.
- If the node is restored, one WSG match run with
  `Tournament.TelemetryIntervalMs = 5000` shows `A:protect fc` lines in
  `bots.log` for at least one bot — the action having been reached at all is the
  check, not whether it succeeded.
- If the node is left commented out, a comment above it states that the trigger
  is now registered and what re-enabling it would cost.

**Notes:**

- Source: `docs/playerbots/BG-AI-ANALYSIS.md`, finding **F-03**, and §4.
- §4 **refutes** the "commented-out flag-carrier triggers cause the 0-0 draws"
  hypothesis: those triggers were already commented out on 2026-08-10, when
  `bg.log` records 21 decisive WSG matches and `honor.log` records 184
  flag-capture honour awards. This artifact is a correctness fix for a
  registration hole, not a fix for the draws.
- The same failure shape is already measured on this server: an `isUseful()`
  gate made `bg join` never run — 0/3 commanded joins before the fix, 8/8 after
  (`docs/playerbots/WSG-BOT-MATCH.md` §3).
