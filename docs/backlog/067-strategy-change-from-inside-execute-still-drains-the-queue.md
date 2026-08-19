---
status: implemented
risk: high
area: playerbots/engine
depends-on: 046-wsg-bots-never-execute-bg-move-to-objective.md
---

# A strategy change from inside `Execute()` still drains the action queue mid-walk

**Problem:** artifact 046 stopped WSG bots standing still by making
`Engine::ChangeStrategy` skip `Init()` when the attached-strategy set does not
actually change. That removed the *trigger* — `BGTactics::Execute` calling
`ChangeStrategy("-buff")` on every tick — but not the defect underneath it.

`Init()` still calls `Reset()`, and `Reset()` still pops and deletes every
`ActionBasket` in `queue`. When that happens from inside an action's `Execute()`,
it runs while `Engine::DoNextAction`'s
`do { ... } while (basket && ++iterations <= iterationsPerTick)` walk is still in
progress: the next `queue.Peek()` returns NULL, `basket` goes null, the loop
exits, and the tick logs `no actions executed`. Every call site that genuinely
moves the strategy set still does this:

- the **first** `BGTactics::Execute` tick after `STATUS_IN_PROGRESS`, when
  `buff` is still attached and `-buff` is therefore a real change;
- any later tick where `PlayerbotAI::ResetStrategies` or
  `RandomPlayerbotMgr::ChangeStrategy` has re-added it;
- `ai->ResetStrategies()` at `BattleGroundTactics.cpp:2701`, two lines above the
  now-guarded call site;
- `ChangeStrategy("-collision")` and `("-arena")` at
  `BattleGroundTactics.cpp:4879-4902`.

Today the survival is **incidental, not safe**. `queue.Pop()` has already
transferred ownership of the current `ActionNode`, and the freed `basket` is only
ever tested for null after `ListenAndExecute` returns — never dereferenced. Any
future edit that reads `basket->` after `Execute()` turns this into a
use-after-free across ~1000 bots.

**Suspected cause / area:**
`src/modules/PlayerBots/playerbot/strategy/Engine.cpp` — `Reset()` (`:79-92`),
`Init()` (`:104`), and the `DoNextAction` walk (`:141-326`). The fix is about
*when* the queue may be mutated relative to that walk, not about which strategies
change.

**Acceptance criteria:**

- A strategy change issued from inside an action's `Execute()` no longer ends the
  current tick early. Demonstrated with a targeted case — e.g. an action that
  calls `ChangeStrategy` on a set that really does change — showing the tick
  continues to the next queued action instead of logging
  `no actions executed`.
- The queue is not deleted out from under an in-progress `DoNextAction` walk.
  Either the re-init is deferred to the end of the tick, or the walk is made to
  tolerate it explicitly; whichever is chosen is stated in a comment at
  `Reset()` naming the re-entrancy it is guarding against.
- The incidental safety is closed, not documented: after the change, reading
  `basket->` after `Execute()` must not be a use-after-free. A comment asserting
  "we never dereference it" is not sufficient — that is exactly the current
  state.
- No regression to artifact 046's result: in a WSG window,
  `A:move to objective - OK` stays non-zero for at least 5 distinct bots, and
  `S:-buff` still appears roughly once per bot near match start rather than once
  per bot per tick.

**Notes:**

- Needs a build. Foreground only, `BUILD_JOBS=14`, `timeout: 600000`, verify
  with `docker images` rather than the exit code.
- The in-world half of the verification needs a WSG match, which
  `match-run.sh` cannot reach until artifact **055** fixes the gear gate
  (`complete=5/10`, aborts before assembly). If 055 has not landed, treat the
  log-based criteria as the gate and record the movement numbers as pending
  rather than inventing them — the same choice artifact 046 made in
  `BG-AI-ANALYSIS.md` §4.2a.
- `risk: high` is deliberate: this is shared engine code on the hot path for
  every bot, not a battleground-only change.

**Base:** cm-main

**Branch:** backlog/strategy-change-from-inside-execute-still-drains-the-queue

**Summary:** On `backlog/strategy-change-from-inside-execute-still-drains-the-queue` (cut from origin/cm-main), commit 2c1fd22 changes two files: `src/modules/PlayerBots/playerbot/strategy/Engine.cpp` and `Engine.h`. In-game, a bot whose action calls `ChangeStrategy` from inside `Execute()` — the first BGTactics tick after STATUS_IN_PROGRESS while `buff` is still attached, `ai->ResetStrategies()` at BattleGroundTactics.cpp:2701, `ChangeStrategy("-collision")`/`("-arena")` at :4879-4902 — no longer loses the rest of that tick and stands still; the tick continues to the next queued action. Technically: `Engine::Reset()` now returns `bool` and, when the new `inDoNextAction` flag is set, sets `reinitPending` and returns false without touching `queue`; `Engine::Init()` bails on that false; `Engine::DoNextAction` sets/restores `inDoNextAction` around the whole walk and, after `queue.RemoveExpired()`, runs the owed `Init()` once. The comment at `Reset()` names the re-entrancy it guards (an action's `Execute()` reaching `Init()->Reset()` mid-walk). The incidental safety is closed rather than documented: the `ActionBasket* basket` that `queue.Pop()` frees is no longer declared outside the loop and no longer used as the loop condition — it is scoped inside the loop body and the `do/while` now tests a plain `bool hasBasket`, so a future `basket->` after `Execute()` cannot be a use-after-free. A greppable `LogAction("S:reinit deferred")` marks each deferral. Artifact 046's signature guard in `addStrategy`/`ChangeStrategy` is untouched, so `S:-buff` still fires roughly once per bot rather than once per tick; its stale comment was updated to say the guard is now only the cheap-no-op optimisation, not the safety. Per rule 4 no Docker build was run, so the runtime/WSG numbers are pending the batch build — nothing was fabricated.

**In-game check:** Most of this is scriptable from the bot action log; only the last item needs eyes on the world.

SCRIPTABLE (no human needed — a batch step can run these against the bot action log written under the mangosd container, the same log 046 read for `A:... - OK` / `no actions executed`):

1. Smoke: start the stack on the newly built image, `rndbot init` / spawn the usual pool, confirm mangosd reaches "World initialized" and bots log AI ticks. No crash, no assertion.
2. Deferral fires at all: grep the bot action log for `S:reinit deferred`. It must appear at least once (a random-bot pool alone triggers it via `RandomPlayerbotMgr::ChangeStrategy` and `PlayerbotAI::ResetStrategies`). Zero occurrences over a 10-minute window with ~50+ bots online means the new path is never being reached and the run proves nothing.
3. The tick actually continues (acceptance criterion 1). For every tick block that contains `S:reinit deferred` — a block is the text between two `--- AI Tick ---` lines for the same bot — assert that the block does NOT end with `no actions executed`, and that it contains at least one `A:<something> - OK` after the `S:reinit deferred` line. Before this fix that block always ended `no actions executed`. Any block that still does is a failure.
4. No use-after-free (acceptance criterion 3): run the window under ASAN if the batch has an ASAN image, otherwise just confirm no mangosd segfault/restart during the window (`docker inspect` restart count unchanged, no "Crash" in the log). The pointer-scoping change is compile-enforced — `basket` no longer exists after the loop body, so a `basket->` after `Execute()` would not compile.
5. 046 regression, `-buff` half (acceptance criterion 4): count `S:-buff` lines per bot over a WSG window. It must be roughly one per bot near match start, not one per bot per tick. If it is thousands per bot, 046's signature guard was broken by this change.

MANUAL / WSG-DEPENDENT (blocked on artifact 055's gear gate, which makes `match-run.sh` abort at `complete=5/10` before assembly — if 055 has not landed, record this as pending rather than inventing numbers, exactly as 046 did in BG-AI-ANALYSIS.md 4.2a):

6. Start a Warsong Gulch match with bots on both sides. Watch from a GM character at the Alliance flag room: after the gates open, bots must walk out and head for the enemy base rather than standing at the tunnel. Confirm in the log that `A:move to objective - OK` is non-zero for at least 5 distinct bot names during the match (acceptance criterion 4, movement half).
7. In the same window, spot-check the very first BGTactics tick after the match goes to STATUS_IN_PROGRESS — that is the tick where `-buff` is a genuine change. It should show `S:-buff`, then `S:reinit deferred`, then the walk carrying on to further actions, and never `no actions executed`.

**Minor findings:**
- src/modules/PlayerBots/playerbot/strategy/Engine.cpp: `Engine::~Engine()` still calls `Reset()` and ignores its new bool return, so if an engine is ever destroyed while a `DoNextAction` walk is in progress (e.g. an action's `Execute()` that logs the bot out and tears down `PlayerbotAI`), `Reset()` now takes the `inDoNextAction` branch and returns false, leaking every remaining `ActionBasket` plus all triggers and multipliers instead of draining them as it did before.
- src/modules/PlayerBots/playerbot/strategy/Engine.cpp: Acceptance criterion 1 asks for the fix to be "demonstrated with a targeted case — e.g. an action that calls `ChangeStrategy` on a set that really does change — showing the tick continues to the next queued action", but the diff contains only the two engine source files and adds no test, harness action, or recorded log evidence of that demonstration.
- src/modules/PlayerBots/playerbot/strategy/Engine.cpp: `~Engine()` still calls `Reset()` and discards the new bool, but the destructor is the one caller that can never honour the "DoNextAction will replay it" contract — if an engine is ever destroyed with `inDoNextAction` still set, Reset() takes the deferral branch, logs through a half-torn-down `ai`, and silently leaks the whole queue, triggers and multipliers instead of freeing them.
- src/modules/PlayerBots/playerbot/strategy/Engine.cpp: `inDoNextAction` is set and restored by hand across the ~230-line body of `DoNextAction` with no RAII guard, so any future early `return` (or an exception escaping `ListenAndExecute` — nothing in `PlayerbotAI::UpdateAIInternal`/`World::UpdatePlayerbotsTick` catches one) leaves the flag stuck true for that bot's engine forever, after which every `Reset()`/`Init()` silently defers and the engine never rebuilds its triggers again.
- src/modules/PlayerBots/playerbot/strategy/ReactionEngine.cpp: The new deferral contract covers only `Engine::DoNextAction`; `ReactionEngine::FindReaction` walks the same `queue` with the same Peek/Pop pattern without ever setting `inDoNextAction`, so a strategy change reaching the reaction engine during that walk still drains the queue underneath it — and that walk additionally binds `const Event& reactionEvent` into the basket that `queue.Pop(reactionItem)` then deletes and reads it afterwards, which is exactly the use-after-free shape the artifact set out to close.
