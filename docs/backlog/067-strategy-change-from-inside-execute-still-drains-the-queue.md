---
status: pending
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
