---
status: pending
risk: low
area: playerbots/battlegrounds
depends-on:
---

# An Alliance bot stepping back into the tunnel is immediately re-sent to mid-field

**Problem:** `BGTactics::wsgPaths()`'s westbound (Alliance-attacking) branch
issues a `MoveTo` at `BattleGroundTactics.cpp:2457-2459` and another at
`:2460-2462` and then **falls out of the `else if` chain** instead of returning.
Control reaches `:2471-2478`, which issues a second `MoveTo` to mid-field and
overwrites the first. The eastbound (Horde-attacking) mirror at `:2324-2341`
returns from every branch, so only the Alliance side is affected.

In-game: an Alliance bot with `bg role < 4` standing between roughly `x = 1381`
and `x = 1450` is sent to mid-field instead of stepping back into the tunnel —
the exact manoeuvre the inline comment at `:2457` says is required, because
"moving from the fasty to the gate directly is bugged". Note the direction: this
defect works *against* Alliance, so it is not the cause of the 15-6 Alliance skew
in `bg.log` — it is a straightforward control-flow bug on its own.

**Suspected cause / area:**
`src/modules/PlayerBots/playerbot/strategy/actions/BattleGroundTactics.cpp`,
`wsgPaths()` — the two branches at `:2457-2462`, against the working mirror at
`:2333-2340`, overridden by `:2471-2478`.

**Acceptance criteria:**

- Both branches at `:2457-2459` and `:2460-2462` return `true` after their
  `MoveTo`, matching the eastbound mirror at `:2333-2340`.
- The mid-field fallback at `:2471-2478` is unchanged and still reachable for the
  cases that legitimately fall through to it.
- No other branch of `wsgPaths()` changes.
- The commit message states which two `MoveTo` calls were being discarded and
  quotes the `:2457` comment that says why the tunnel step exists.

**Notes:**

- Source: `docs/playerbots/BG-AI-ANALYSIS.md`, finding **F-06**.
- Like every other movement fix in this set, it is unobservable until bots move
  at all — see `docs/backlog/046-wsg-bots-never-execute-bg-move-to-objective.md`.
