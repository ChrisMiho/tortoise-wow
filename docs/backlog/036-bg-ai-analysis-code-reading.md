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

**Base:** cm-main

**Branch:** backlog/bg-ai-analysis-code-reading

**Summary:** Created `docs/playerbots/BG-AI-ANALYSIS.md` (415 lines, one commit `d9fc473`, no file outside `docs/` touched), a pure code reading of the battleground bot AI dated 2026-08-18 against commit `80a7100`. §0 pins the build context (`MANGOSBOT_ZERO` and `CMANGOS` are set unconditionally at `src/modules/PlayerBots/CMakeLists.txt:131-132`, `MANGOS` is never defined anywhere in `src/`, so EY/IC/arena/vehicles are compiled out and only AV/WS/AB exist) and records which strategies `AiFactory.cpp` actually attaches — `bg` only *outside* a battleground, `battleground` in the non-combat engine only, `warsong` in both. §1 is a complete trigger table: every `TriggerNode` in all eight strategy classes in `BattlegroundStrategy.cpp` (`BGStrategy`, `BattlegroundStrategy`, `WarsongStrategy`, `AlteracStrategy`, `ArathiStrategy`, `EyeStrategy`, `IsleStrategy`, `ArenaStrategy`), each row carrying the trigger, its registration line in `TriggerContext.h`, the action, its registration line in `ActionContext.h`/`WorldPacketActionContext.h`, the relevance, and active/commented-out — plus a merged effective WSG priority ladder. **The artifact's headline lead is refuted:** all four commented-out triggers name actions that still exist, but `enemy flagcarrier near → attack enemy flag carrier` (80) and `player has flag → bg move to objective` (90) are already live at the same relevance in `WarsongStrategy` (`:75-77`, `:79-84`), so uncommenting them is a no-op; only `team flagcarrier near → bg protect fc` (40) is genuinely dead, and it is dead at the *trigger*, not the action — `TriggerContext.h` never registers that name, so `Engine::ProcessTriggers` (`strategy/Engine.cpp:611-615`) resolves `nullptr` and skips it, leaving `protectFC()` (`BattleGroundTactics.cpp:4635-4646`) unreachable from any live strategy. §2 numbers `BGTactics::Execute`'s 21 branch hops with `file:line`, annotating what each early `return` starves, plus a reachability table for all 21 private helpers and the finding that `vPaths_WS` is entirely dead in WSG. §3 is a 16-row findings table, each row classified disabled/broken/absent with a `file:line`, an observable symptom and a confidence — the strongest being F-01 (`bg check objective` at relevance 10 starves `bg move to objective` at relevance 1 every 5 s while re-rolling `bg role` 1-in-4), F-02 (`wsgRoofJump:2642` repeats the `UPPER` constant where the Horde mirror uses `LOWER`, so `WS_FLAG_ALLIANCE_FLOOR_JUMP_LOWER` is never referenced and Horde attackers never get the drop into the Alliance flag room — the direction of the recorded 16-6 Alliance skew), F-03, F-08 (`JumpAction::isUseful()` needs a *real* player nearby, so the 80.5-relevance flag-carrier jump is dead in every all-bot match) and F-14 (`BgTeamHasRealPlayer` makes bot behaviour depend on which faction a human observer joined — a faction-asymmetric confound for the skew). §3.1 states explicitly what was *not* explained, so no gap reads as "checked and empty".

**In-game check:** **This change needs no in-game confirmation.** It adds exactly one Markdown file under `docs/` and touches no C++, no SQL, no config, and no script. The compiled server binary is byte-identical to the one built from the parent commit, so the generic "server starts, bots spawn" smoke test is the whole of the runtime verification required — and even that only proves the build was unaffected, which it necessarily was.

What *is* worth verifying is the document's accuracy, and all of it is scriptable — no human needs to look at the game world:

1. **Diff scope (fully scriptable).** `git diff --stat 80a7100..HEAD` must show exactly one file, `docs/playerbots/BG-AI-ANALYSIS.md`, and `git diff --name-only 80a7100..HEAD | grep -v '^docs/'` must produce no output. This is the "No file outside `docs/` is modified" criterion and it is machine-checkable.

2. **Build is unaffected (scriptable, but only as a side effect of a batch build).** The batch pass that compiles this branch alongside its batch should produce an image whose behaviour is indistinguishable from the previous one. If the batch build fails, this branch is not the cause — no compilation unit changed. Do not build on this branch's account.

3. **Citation spot-checks (fully scriptable, and the only check with real value).** Each of these should print the quoted text; a miss means a line reference drifted and the document needs a correction, not the server:
   - `sed -n '44,54p' src/modules/PlayerBots/playerbot/strategy/generic/BattlegroundStrategy.cpp` — must show the three commented-out `triggers.push_back` blocks (`attack enemy flag carrier` 80.0f, `bg protect fc` 40.0f, `bg move to objective` 90.0f).
   - `grep -n 'team flagcarrier near' src/modules/PlayerBots/playerbot/strategy/triggers/TriggerContext.h` — must return **nothing**. That absence is finding F-03 and is the single most load-bearing claim in the document.
   - `grep -c 'WS_FLAG_ALLIANCE_FLOOR_JUMP_LOWER' src/modules/PlayerBots/playerbot/strategy/actions/BattleGroundTactics.cpp` — must return `1` (the declaration at line 36 only, zero uses). That is finding F-02.
   - `grep -rn 'add_definitions(-DMANGOS)' src/` — must return nothing, confirming F-09's claim that the `#ifdef MANGOS` trigger bodies are compiled out.
   - `sed -n '2696,2700p;2852,2856p' src/modules/PlayerBots/playerbot/strategy/actions/BattleGroundTactics.cpp` — must bracket `BGTactics::Execute` as §2 describes.

4. **Nothing to test in-world.** In particular, do **not** run a WSG match to validate this artifact. The artifact explicitly forbids re-deriving the symptom (`bg.log`'s 16/6/15 split as of 2026-08-16 is the cited measurement), and every behavioural claim in §3 is deliberately left at `medium`/`low` confidence with the specific measurement that would raise it recorded in the row. Obtaining those measurements is artifact 037's job, not this one's.

**Minor findings:**
- docs/playerbots/BG-AI-ANALYSIS.md: §3's own stated rule — "Confidence is `high` only where the path was read end to end **and** a matching symptom is already recorded somewhere citable in this repo" — is violated by six rows rated `high` that explicitly claim no symptom and cite no measurement (F-04 "no in-game symptom is claimed", F-09 "Nothing today", F-10 "low for any current symptom" yet labelled high, F-13 "No behavioural symptom", F-14, F-16 "reading the line is the whole finding").
- docs/playerbots/BG-AI-ANALYSIS.md: The `ArenaStrategy` section's mechanism is wrong: `AiFactory.cpp:1088` is not inside `#ifndef MANGOSBOT_ZERO` — it sits in the plain `if (isArena)` at `:1086`, and the strategy is unattached only because the sole `isArena = true` assignment (`:1083`) is inside the `#ifndef` while the declaration at `:1078` initialises it to false.
- docs/playerbots/BG-AI-ANALYSIS.md: §0's justification "this is a Classic build, so [MANGOSBOT_ONE/TWO are] off" is inaccurate — `CMakeLists.txt:22` sets `project(TurtleWoW)`, which matches none of the `Classic`/`TBC`/`WoTLK` string tests, so the `MANGOSBOT_ZERO` block at `src/modules/PlayerBots/CMakeLists.txt:134-137` never fires either and ZERO is on solely because of the unconditional `:132`.

**Drain note (all four of the document's own citation spot-checks PASS):** re-run independently on 2026-08-18.

- F-03, the document's self-declared most load-bearing claim: `grep -n "team flagcarrier near" .../triggers/TriggerContext.h` returns nothing. The trigger name really is unregistered, so Engine::ProcessTriggers resolves nullptr and protectFC() is unreachable. HOLDS.
- F-02: `grep -c WS_FLAG_ALLIANCE_FLOOR_JUMP_LOWER .../BattleGroundTactics.cpp` returns exactly 1 — the declaration, zero uses. HOLDS.
- F-09: `grep -rn "add_definitions(-DMANGOS)" src/` returns nothing, and CMakeLists.txt sets `add_definitions(-DCMANGOS)` and `add_definitions(-DMANGOSBOT_ZERO)` unconditionally. HOLDS.
- Diff scope: `git diff --name-only origin/cm-main...HEAD | grep -v "^docs/"` is empty. The "no file outside docs/" criterion is met.

The headline refutation also holds on inspection: WarsongStrategy really does register `enemy flagcarrier near -> attack enemy flag carrier` at 80.0f (:75-77) and `player has flag -> jump::position bg objective` 80.5f + `bg move to objective` 80.0f (:79-84), so uncommenting the block at :44-54 is indeed close to a no-op.

**Two corrections to the Summary text (the PR body quotes it verbatim):**
1. It says the commented pair are "already live at the same relevance". That is exact for `attack enemy flag carrier` (80 commented, 80.0f live) but NOT for `bg move to objective`, which is commented at 90.0f and live at 80.0f. The refutation survives — the action is live and reachable from a live trigger — but the relevance is not identical, and relevance is the very quantity this artifact says explains most behaviour.
2. It states the document is 415 lines; it is 434.

**Drain note (RUNTIME CORROBORATION — this document is a pure code reading, and the live trace agrees with its conclusion):** while this tick ran, the drain measured the actual bot AI trace from the batch 20260818-2 validate match (bots.log.1.gz/.2.gz, window 10:30:02-10:38:32, tournament bots only). Counts:

```
--- AI Tick ---            8708
no actions executed        8564     (98.3% of ticks)
PUSH:bg check flag        13772
A:check flag - PREREQ      6810
A:check flag - FAILED      6810     (100% failure rate)
PUSH:bg move to objective  6886
A:spirit healer - USELESS  1586
T:bg active               20658
```

This is measurement rather than folklore, and it settles the question this artifact opens. The bot AI is NOT idle or detached — it ticks 8708 times and evaluates triggers constantly — yet 8564 of those 8708 ticks execute no action at all, and `check flag` fails its prerequisite on every one of 6810 attempts. That is the runtime shape of the starvation the document describes in §2/§3, observed independently of the code reading. `bg move to objective` being PUSHed 6886 times while the bots register 0.0 yards of movement (see artifacts 026 and 028) is the same phenomenon from the other side: the action reaches the queue and never executes.

It also explains a detail 026 recorded but could not account for: `spirit healer` is pushed 1586 times and judged USELESS every time, which is why three bots stayed dead for the entire match and never released.

Caution for whoever picks up 037: `bots.log` itself currently reads 0 bytes and would look like "no AI trace exists". It is not — the 5-minute logrotate cron had just rotated it and mangosd was down. The trace lives in bots.log.N.gz. Reading the empty live file as evidence is a false negative waiting to happen.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/44, build tortoise-cm:20260818-3.
