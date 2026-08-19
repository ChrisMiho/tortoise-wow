---
status: done
risk: low
area: playerbots/battlegrounds
depends-on:
---

# Nobody has written down how the battleground bot AI actually decides anything

**Problem:** WSG bot matches run the full 20-minute cap and end 0-0 often enough
that the cap itself was added to this server because of it. Every theory about why
is currently folklore, because there is no written trace of how a bot in a
battleground gets from trigger to action, and no catalogue of what in that path is
disabled, broken, or was never written. The strongest existing lead is that **three
flag-carrier triggers are commented out** at `BattlegroundStrategy.cpp:44-51`
(`enemy flagcarrier near → attack enemy flag carrier`, relevance 80;
`team flagcarrier near → bg protect fc`, 40; `player has flag → bg move to
objective`, 90) — and nobody has confirmed whether the actions they name still
exist.

**Suspected cause / area:**
`src/modules/PlayerBots/playerbot/strategy/generic/BattlegroundStrategy.cpp` and
`src/modules/PlayerBots/playerbot/strategy/actions/BattleGroundTactics.cpp`.
Implements `docs/superpowers/plans/2026-08-16-07-bg-combat-analysis.md` Tasks 1-2.

**Acceptance criteria:**

- `docs/playerbots/BG-AI-ANALYSIS.md` exists, dated, naming the commit it was
  written against, and stating that nothing here changes behaviour.
- **§1 — a complete strategy/trigger table.** One row per trigger for *every*
  strategy class in `BattlegroundStrategy.cpp` (`BGStrategy`,
  `BattlegroundStrategy`, `WarsongStrategy`, and any others present), giving the
  trigger, the action it fires, its relevance value, and whether it is active or
  commented out. Relevance is the priority that decides which action wins when
  several are eligible, and it explains most observed behaviour — every row must
  carry it.
- For each commented-out trigger, the table records **whether the action it names
  still exists**. A commented-out trigger naming a deleted action is a dead end; one
  naming a live action is a switch someone turned off, and those are different
  findings.
- **§2 — `BGTactics::Execute`'s branch order**, numbered, each hop with a
  `file:line`, and each early `return` annotated with what it starves. Order
  matters more than content: an early `return true` starves everything below it,
  and that is the shape most "bot does nothing" bugs take.
- **§3 — a findings table.** Each row: what, `file:line`, a classification of
  **disabled / broken / absent**, the observable symptom, and a confidence.
  Confidence may be `high` only where the code path was read end to end **and** a
  matching symptom is already recorded somewhere citable; everything else is
  `medium` or `low` and says what would raise it.
- **Every claim in the document carries a `file:line` or a cited measurement.**
  "Bots seem passive" is not a finding.
- Both tables are filled completely. A partially-filled table is worse than none —
  it implies the gaps were checked and found empty.
- **No file outside `docs/` is modified.**

**Notes:**

- `BattleGroundTactics.cpp` is ~4954 lines. Read it in bounded passes by concern
  (early returns; hardcoded probability rolls; distance and range constants;
  map-id and team assumptions; null-deref risk on objective and path lookups; then
  the flag path — `flagTaken`, `teamFlagTaken`, `atFlag`, `protectFC`; then
  `wsgPaths` and the waypoint data), not end to end. The private helpers are
  declared at `BattleGroundTactics.h:60-81`.
- For each flag helper, ask two questions and record both: does it ever return
  true under a realistic match state, and **is it reachable from `Execute`'s
  branch order at all**. An unreachable correct function is the same as a broken
  one from the match's point of view.
- **The symptom is already measured — do not re-derive it, and do not run a match
  to obtain it.** `bg.log` holds 37 completed WSG matches as of 2026-08-16:
  **16 Alliance, 6 Horde, 15 draws.** So 41% end scoreless, and the decisive
  matches carry a 2.7:1 Alliance skew on a 22-match sample. The draw rate is the
  headline evidence for the commented-out flag-carrier triggers. The faction skew
  is a second, independent lead: Step 3's `wsgPaths` question asks whether both
  factions have symmetric waypoint coverage, and asymmetric path data is exactly
  what a persistent one-sided skew would look like. Report the sample size
  alongside any ratio — 22 decisive matches is suggestive, not conclusive.
- Start from the current frontier rather than rediscovering it. Already
  established: `BGJoinAction::isUseful()` re-rolled a hardcoded 20% tank/healer
  gate over a queue choice the operator had already made, and
  `Engine::ExecuteAction` gates every commanded action on `isUseful()`, so
  `bg join` never ran — fixed, measured 0/3 commanded joins before and 8/8 after
  (`docs/playerbots/WSG-BOT-MATCH.md` §3). The queue gates are enumerated at
  `BattleGroundJoinAction.cpp:544-590`. The 20-minute cap is
  `BattleGround.cpp:317-323` and is custom to this server.
- **Change nothing in the bot AI in this artifact.** A behavioural change bundled
  into an investigation is a change nobody reviewed against a measurement. Fixes
  are scoped separately.
- This is a pure code-reading task: no build, no server, no database. It can be
  completed entirely offline.
- The measurement half of the analysis (§4) and the scoping of individual fixes
  are artifact 037, which needs a live match.
