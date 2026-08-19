---
status: implemented
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

**Base:** cm-main

**Branch:** backlog/debug-say-left-in-the-arathi-objective-path

**Summary:** Replaced the player-visible debug chat line in `BGTactics::selectObjective()`'s Arathi Basin branch with a server-side log line. In-game: a bot that dies while holding a selected AB node objective no longer emits `Say("I'm dead, guess I'll reset my objective.", LANG_UNIVERSAL)` into /say range — nothing appears in chat at all. Technical: `src/modules/PlayerBots/playerbot/strategy/actions/BattleGroundTactics.cpp:3162` now calls `sLog.outDetail("Bot #%d %s:%d <%s>: died with an AB objective selected, resetting it", ...)`, matching the "Bot #%d %s:%d <%s>: ..." format already used by the other (commented-out) trace lines in this file. The surrounding branch is untouched: it still clears `botSelectedObjectives[botGUID]` and zeroes `botObjectiveSelectionTime[botGUID]` exactly as before. `grep -rn "guess I'll reset my objective" src/` now returns nothing. No new includes were needed — `sLog` reaches this translation unit through `playerbot/playerbot.h`, the same way it does in sibling actions like `BattleGroundJoinAction.cpp`. Not compiled here per the no-Docker-build rule; the batch pass is the compile gate.

**In-game check:** Scriptable, no human eyes needed for the primary check: `grep -rn "guess I'll reset my objective" src/` must return nothing, and the built server binary must contain no such string (`docker run --rm <image> sh -c "strings /path/to/mangosd | grep -c \"guess I'll reset\""` should print 0). That alone proves the chat line cannot fire.

Manual in-game confirmation, if wanted: (1) start the stack and spawn bots, (2) run an Arathi Basin match with bots on both sides (`.bg` / rndbot flow already on cm-main), (3) log in a player character, join the AB match, and stand near a contested node — Blacksmith is the busiest — with the chat window filtered to Say, (4) let bots die repeatedly at that node for a couple of minutes; no bot should ever say "I'm dead, guess I'll reset my objective." Previously that line appeared in white Say text within ~25 yards of any bot that died holding a node objective. (5) With mangosd's log level raised to detail (`LogLevel = 3` in `mangosd.conf`), the replacement trace `Bot #<guid> A:<level> <name>: died with an AB objective selected, resetting it` should appear in the server log instead — its presence there confirms the branch does run and that the reset behaviour is unchanged; its absence is not a failure, since the original author doubted the branch executes at all.

Beyond that this is a one-line change with no control-flow impact, so the generic "server starts, bots spawn, an AB match completes" smoke test covers the rest.
