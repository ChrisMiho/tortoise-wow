---
status: done
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

**Base:** backlog/strategy-change-from-inside-execute-still-drains-the-queue

**Branch:** backlog/strategysignature-rebuilds-a-string-twice-per-call

**Summary:** Replaced `Engine::StrategySignature()` — an ordered join of every attached strategy name that allocated a fresh std::string twice per `addStrategy`/`ChangeStrategy` — with an allocation-free set token. `Engine` now carries a `uint64 strategiesHash` that is the XOR of `std::hash<std::string>` over every attached strategy name; `addStrategy` XORs a name in when the insert actually happens, `removeStrategy` XORs it out before erasing, and `removeAllStrategies` zeroes it. `StrategySetToken()` (inline, header) mixes that hash with `strategies.size()`. The two guards in `addStrategy` and `ChangeStrategy` now compare tokens instead of strings, so the common no-op case (`ChangeStrategy("-buff")` when "buff" is already gone, issued per bot per non-combat BG tick from BattleGroundTactics.cpp:2718) does no allocation at all. XOR is order-independent and exactly undone on removal, so add-then-remove of the same name returns the identical token — behaviour matches the string comparison, including `addStrategy`'s internal remove-then-re-add of the same strategy, which stays a no-op. `StrategySignature()` is deleted; no other call sites existed. Files: src/modules/PlayerBots/playerbot/strategy/Engine.h and Engine.cpp. Branch cut from origin/backlog/strategy-change-from-inside-execute-still-drains-the-queue (artifact 067), whose Reset()-deferral is present and unmodified — 067 kept the guard rather than removing it, so this artifact did not reduce to a no-op. No build was run (drain rule 4); no SQL migration needed.

**In-game check:** This is a pure performance change with no new in-game symptom; the check is a no-regression re-run of artifact 046's two log checks, and both are fully scriptable from the bot action log — no human needs to watch the battleground.

1. Build the branch and start the stack; confirm the world comes up and bots spawn (`rndbot start`), the generic smoke test.
2. Run a Warsong Gulch window with bots (the same standup the 046 validation used, e.g. `.bg` / the WSG scripts under docs/playerbots/wsg/), and let a match run past the starting gates for a few minutes.
3. Scriptable log check A — behaviour preserved: grep the bot action log for `A:move to objective - OK` and count distinct bot names. It must be non-zero for at least 5 distinct bots. If it is zero, the guard has regressed to re-initing (or not re-initing) wrongly and the queue is being wiped again.
4. Scriptable log check B — the guard still fires as a no-op: grep for `S:-buff` and count occurrences per bot. It must appear roughly once per bot near match start, not once per bot per tick. A per-tick count means the token comparison is reporting a change where the string comparison did not, i.e. the hash bookkeeping is out of sync with the map.
5. Scriptable log check C — a real change still re-inits: pick one bot and confirm its log shows an `S:+...` / `S:-...` pair for an actual strategy transition (e.g. entering combat) followed by fresh `PUSH:` lines for that state, proving `Init()` still runs exactly once when the set really moves.
6. Optional, human/console: `.bot strategy` (PrintStrategies) on a bot before and after `.bot co -buff` style toggles should list the same strategies it always did — the token affects only whether Init() runs, never the listed set. Note rule 5 of the drain: the only server image on this host predates these changes, so any of this must run against a freshly built image, not the rollback anchor.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/81, build tortoise-cm:20260819-6.
