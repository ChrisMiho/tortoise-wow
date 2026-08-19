---
status: pending
risk: low
area: playerbots/engine
depends-on: 046-wsg-bots-never-execute-bg-move-to-objective.md
---

# `StrategySignature()` rebuilds a whole string twice per strategy change

**Problem:** artifact 046 added `Engine::StrategySignature()` — an ordered join
of every attached strategy name — and calls it **twice** per
`addStrategy`/`ChangeStrategy` (once before the change, once after) to decide
whether `Init()` is needed. Each call walks the entire strategy map and builds
and concatenates a fresh `std::string`.

The call site that made 046 necessary is
`BattleGroundTactics.cpp:2718`, which issues `ChangeStrategy("-buff")` on **every
non-combat tick of every bot in a battleground**. So the guard that removed the
per-tick queue rebuild reintroduces a per-tick string build in its place —
smaller, but on exactly the same hot path, and at ~1000 bots that is the
allocation pattern `Action.h`'s `NextAction::getName()` comment already records
as the server's top allocation source.

The comparison does not need a string. Any cheap change-detector gives the same
guard: a `size()` early-out (a `-name` that removes nothing cannot change the
set), or a dirty flag set by `addStrategy`/`removeStrategy` and cleared by
`Init()`.

**Suspected cause / area:**
`src/modules/PlayerBots/playerbot/strategy/Engine.cpp` and `Engine.h` —
`StrategySignature()` and its two call sites in `addStrategy` and
`ChangeStrategy`, both added by artifact 046.

**Acceptance criteria:**

- The no-op strategy-change guard no longer allocates on the hot path. No
  `std::string` is built for the common case where the strategy set is unchanged.
- The guard's behaviour is unchanged from 046: a `-buff` that removes nothing is
  still a no-op that leaves the queue intact, and a change that really does move
  the set still re-inits exactly once.
- `A:move to objective - OK` remains non-zero for at least 5 distinct bots in a
  WSG window, and `S:-buff` appears roughly once per bot near match start rather
  than once per bot per tick — the same two log checks artifact 046 used.

**Notes:**

- Needs a build. Foreground only, `BUILD_JOBS=14`, `timeout: 600000`, verify with
  `docker images`.
- Overlaps artifact **067**, which rewrites the same two functions for a
  different reason (queue re-entrancy). If 067 lands first and its fix already
  removes the signature comparison, this artifact may reduce to confirming that
  and closing it — check before writing code.
- Purely a performance change; there is no in-game symptom to reproduce. Do not
  spend a WSG match on it beyond the no-regression log checks above.
