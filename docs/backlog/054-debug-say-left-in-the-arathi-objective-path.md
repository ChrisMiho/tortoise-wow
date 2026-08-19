---
status: pending
risk: low
area: playerbots/battlegrounds
depends-on:
---

# Bots announce "I'm dead, guess I'll reset my objective" in Arathi Basin

**Problem:** `BGTactics::selectObjective()` contains a debug
`bot->Say("I'm dead, guess I'll reset my objective.", LANG_UNIVERSAL)`
(`BattleGroundTactics.cpp:3162-3163`). It fires whenever a dead bot with a
stored objective runs `selectObjective`, which is the Arathi Basin path. The
author's own trailing comment doubts the branch ever runs, so nobody has
noticed.

In-game: any player inside `/say` range in an Arathi Basin match sees bot chat
spam in a language everyone understands (`LANG_UNIVERSAL`, so it is not even
faction-filtered). On a server that intends to stream tournament matches, this
is visible on camera.

**Suspected cause / area:**
`src/modules/PlayerBots/playerbot/strategy/actions/BattleGroundTactics.cpp:3162-3163`.

**Acceptance criteria:**

- The `bot->Say(...)` call is removed. If the branch is worth tracing, it is
  traced through `sLog.outDetail`/the bot action log instead of player-visible
  chat — not left as `Say`.
- `grep -n "guess I'll reset my objective" src/` returns nothing.
- No surrounding logic changes: the branch still resets the objective exactly as
  it does now.

**Notes:**

- Source: `docs/playerbots/BG-AI-ANALYSIS.md`, finding **F-16**.
- Ranked last in §4 on expected match-quality gain, but it is the cheapest and
  lowest-risk item in the whole set — one line, no control flow.
