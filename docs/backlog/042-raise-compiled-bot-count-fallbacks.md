---
status: done
risk: medium
area: playerbots/config
depends-on:
---

# A conf missing one key silently runs the server at a fifth of its intended population

**Problem:** There are two layers of bot-count defaults and they contradict each
other by 5×. `src/modules/PlayerBots/playerbot/aiplayerbot.conf.dist.in:57-58,64`
— the project's own shipped config — asks for `MinRandomBots = 1000`,
`MaxRandomBots = 1000`, `RandomBotAccountCount = 500`. The compiled fallbacks at
`PlayerbotAIConfig.cpp:249-250,542` read `50`, `200` and `50`, and apply whenever
the key is **absent** from the conf. So a server whose conf omits
`AiPlayerbot.MaxRandomBots` runs at 200 instead of 1000, with nothing anywhere
indicating why. The `50` account fallback is worse than a mismatch: a bot account
holds at most 9-10 characters (`PlayerbotMgr.cpp:2325`), so 50 accounts cannot
hold the default population at all.

**Suspected cause / area:**
`src/modules/PlayerBots/playerbot/PlayerbotAIConfig.cpp`, lines 249-250 and 542.
Implements `docs/superpowers/plans/2026-08-16-09-release-tag-and-1000-bot-standup.md`
Task 2.

**Acceptance criteria:**

- Both layers are confirmed as they stand before anything is changed — grep the
  `.dist.in` for the three `AiPlayerbot.*` keys and the `.cpp` for the three
  `config.GetIntDefault` calls — and the actual values found are recorded in the
  commit message.
- `minRandomBots` and `maxRandomBots` fall back to `1000`, and
  `randomBotAccountCount` to `500`.
- A comment at each site states **why**: that these now agree with
  `aiplayerbot.conf.dist.in`, which has shipped 1000/1000/500 all along; that 1000
  is measured-safe on the reference host (4.2682 GiB RSS at 1017 bots online,
  plateaued, VM still 17.62 GiB available, per
  `docs/playerbots/BOT-MEMORY-INVESTIGATION.md`, with the ramp not tripping a gate
  until 2002 bots and then on Windows host-free memory rather than the VM); and,
  for the account count, the 9-10 characters per account limit that makes 500 the
  minimum coherent value.
- Nothing else in `PlayerbotAIConfig.cpp` changes, and no `.conf` file is edited.

**Notes:**

- **Do not attempt a Docker build here** (~9.5 min, no incremental build); the
  `backlog-batch` pass compiles this branch.
- Risk is `medium` not because the diff is complex — it is three integers — but
  because of what it changes for anyone whose conf omits these keys: a fivefold
  population increase at startup. Memory is not the constraint (measured
  comfortable at 1000); **bot AI is single-core**, so CPU may be.
- The new fallback is invisible on this host, whose live `aiplayerbot.conf` sets
  all three keys explicitly. That is not a reason to skip verifying it.
- **Verification needing a live stack (not part of these criteria):** back up the
  live `~/tortoise-wow-server-V2/etc/aiplayerbot.conf`, comment out
  `AiPlayerbot.MaxRandomBots`, `docker restart tcm-mangosd`, and confirm the
  server reports a 1000 target rather than 200 — in `docker logs tcm-mangosd`, or
  through `rndbot stats` via `wsg_console` if the log does not print the effective
  value. **Then restore the conf and restart again.** This is the only check that
  proves the fallback is what actually changed.
- The interaction with `docs/playerbots/wsg/wsg-mode.sh`, which deliberately
  shrinks the pool to 40 for a match, is artifact 043 — do not touch it here.

**Base:** cm-main

**Branch:** backlog/raise-compiled-bot-count-fallbacks

**Summary:** Confirmed both layers first: `src/modules/PlayerBots/playerbot/aiplayerbot.conf.dist.in` lines 57/58/64 ship `AiPlayerbot.MinRandomBots = 1000`, `AiPlayerbot.MaxRandomBots = 1000`, `AiPlayerbot.RandomBotAccountCount = 500`, while `src/modules/PlayerBots/playerbot/PlayerbotAIConfig.cpp` lines 249/250/542 read `config.GetIntDefault(..., 50)`, `(..., 200)` and `(..., 50)` — a 5x contradiction that only bites a conf omitting the keys. Raised the three compiled fallbacks to 1000/1000/500 and added a comment at each of the two sites explaining why: that they now agree with the shipped `.dist.in`, that 1000 is measured-safe on the reference host (4.2682 GiB RSS at 1017 bots online, plateaued, VM still 17.62 GiB available, ramp not gating until 2002 bots and then on Windows host-free memory rather than the VM), and that a bot account holds at most 9-10 characters (`PlayerbotMgr.cpp:2325`) so 500 accounts is the minimum coherent value for a 1000-bot default. Nothing else in `PlayerbotAIConfig.cpp` changed and no `.conf` file was touched — the diff is 19 insertions / 3 deletions in one file. One deviation worth flagging: the artifact and the source plan both cite `docs/playerbots/BOT-MEMORY-INVESTIGATION.md` as the measurement reference, but that file does not exist in the repo (recovering it is artifact 041), so the comment points at `docs/superpowers/plans/2026-08-16-09-release-tag-and-1000-bot-standup.md`, which does hold the measurement table, rather than at a dead path. No build was run (rule 4) and nothing was exercised against the live stack: this is a compiled fallback, so no image on this host contains it. Committed as 3ea5b42.

**In-game check:** The change is invisible on this host unless the conf key is removed, because the live `~/tortoise-wow-server-V2/etc/aiplayerbot.conf` sets all three keys explicitly. So the check has two halves.

A. Smoke test (scriptable, no human eyes needed). After the batch build, `docker restart tcm-mangosd`, wait for the world to come up, and confirm `docker logs tcm-mangosd` shows the world loading with no `AiPlayerbot` config error and no crash; then `rndbot stats` through `wsg_console` (docs/playerbots/wsg/lib/wsg-bots-common.sh — never a bare `docker attach`) should print "<N> Random Bots online" with N in the usual live range. With the conf untouched, N must NOT jump: the live conf still pins the pool, so a population change here would mean the conf stopped being read.

B. The check that actually proves the fallback changed (this is the only one that does; the artifact scopes it as out-of-criteria verification, and it needs the batch-built image, not the currently running one):
  1. `cp ~/tortoise-wow-server-V2/etc/aiplayerbot.conf /tmp/aiplayerbot.conf.bak` — take the backup first, this is a live server's config.
  2. Comment out all three keys: `sed -i 's/^AiPlayerbot\.\(Min\|Max\)RandomBots/#&/; s/^AiPlayerbot\.RandomBotAccountCount/#&/' ~/tortoise-wow-server-V2/etc/aiplayerbot.conf`.
  3. `docker restart tcm-mangosd`, wait for the world.
  4. Read the effective target from the DB rather than the log — `rndbot stats` prints only the online count, not the target. The target lives in `tw_characters.ai_playerbot_random_bots`: `SELECT value FROM ai_playerbot_random_bots WHERE owner = 0 AND event = 'bot_count';` (run it through a bare `docker exec tcm-db mysql ...`, not `wsg_mysql`, which swallows stderr and makes a failed query look like an empty result). PASS = `1000`. FAIL = `200`, or the old persisted value unchanged. This is deterministic: `RandomPlayerbotMgr.cpp:671-676` re-rolls the persisted `bot_count` whenever it falls outside `[minRandomBots, maxRandomBots]`, and with both at 1000 `urand(1000,1000)` can only yield 1000.
  5. Watch the bot population ramp for a few minutes — `rndbot stats` repeatedly, and `docker stats tcm-mangosd` for RSS. In-game, log a character in and confirm the world visibly fills with `rndbot`-prefixed players rather than staying sparse. Expect RSS to climb toward the ~4.27 GiB reference and plateau; materially above that is a regression. Bot AI is single-core, so also watch that the mangosd container's CPU does not sit pinned and that bots keep moving and casting rather than freezing in place.
  6. **Restore:** `cp /tmp/aiplayerbot.conf.bak ~/tortoise-wow-server-V2/etc/aiplayerbot.conf && docker restart tcm-mangosd`, then re-run step 4 and confirm the target is back to whatever the live conf specifies. Do not leave the server on the commented-out conf.

Half of B is scriptable — steps 1-4 and 6 are shell and SQL, and a batch step can do them unattended. Step 5's "the world visibly fills and the bots still behave" part is the piece that wants a human in-game.

**Minor findings:** none reported by the review lenses.

**Drain note (every claim VERIFIED, and the account-count argument can be made sharper):** checked independently on 2026-08-18.

- The 5x contradiction is real. aiplayerbot.conf.dist.in ships `AiPlayerbot.MinRandomBots = 1000` (:57), `MaxRandomBots = 1000` (:58), `RandomBotAccountCount = 500` (:64), while origin/cm-main's PlayerbotAIConfig.cpp compiled `GetIntDefault(..., 50)` (:249), `(..., 200)` (:250) and `(..., 50)` (:542). The branch sets all three to 1000/1000/500.
- Scope is clean: the diff is one file, 19 insertions / 3 deletions, zero .conf files touched. The adjacent MinRandomBotsPriceChangeInterval / MaxRandomBotsPriceChangeInterval fallbacks are byte-unchanged, confirming "nothing else in PlayerbotAIConfig.cpp changed".
- The 9-10 characters-per-account limit is exact: PlayerbotMgr.cpp:2324-2326 reads `uint32 maxCharsPerAccount = 9;` with `#ifdef MANGOSBOT_TWO maxCharsPerAccount = 10;`.

The account argument is stronger than the artifact states, and worth recording as arithmetic rather than assertion. This build defines MANGOSBOT_ZERO, not MANGOSBOT_TWO (CMakeLists.txt sets `add_definitions(-DMANGOSBOT_ZERO)` unconditionally, verified while checking artifact 036), so maxCharsPerAccount is 9 here. The old fallback of 50 accounts therefore caps the population at 50 x 9 = 450 characters -- less than half the 1000-bot default it was supposed to support. So "50 accounts cannot hold the default population at all" is not a judgement call: it is 450 < 1000. The new 500 accounts gives 4500 slots, comfortably above the 112 accounts (1000 / 9, rounded up) that 1000 bots strictly require.

**Drain note (the missing citation is the SAME gap artifact 041 exposed, hit independently):** the artifact and its source plan both cite docs/playerbots/BOT-MEMORY-INVESTIGATION.md as the measurement reference. That file does not exist in this repo, so the tick pointed its code comment at docs/superpowers/plans/2026-08-16-09-release-tag-and-1000-bot-standup.md instead, which does hold the table. That was the right call. It is also the second independent encounter with the same problem in consecutive ticks: the drain established on artifact 041 that BOT-MEMORY-INVESTIGATION.md and every raw measurement file exist ONLY on the local-only branch memory/baseline-measurement and on NO remote branch at all. So a code comment in a shipping C++ file was about to cite a path that exists on one disk. Pushing that branch (`git push -u origin memory/baseline-measurement` -- pushing is not merging) would fix both this dangling citation and the underlying data-loss exposure.

**Cross-check of the safety numbers:** the justification (4.2682 GiB RSS at 1017 bots, plateaued, VM 17.62 GiB still available, ramp not gating until 2002 bots) is consistent with what artifact 040 measured independently on this host earlier the same day on tortoise-cm:20260818-4: mangosd ~172% CPU (1.7 of 16 cores) and 5.6 GiB RSS with 998 bots online, ~16.9 GiB available. Two separate measurements, same order of magnitude, both leaving ample headroom at ~1000 bots. Nothing here contradicts raising the fallback to 1000.

**Note:** this is a COMPILED fallback, so it takes effect only in an image built from this branch, and it is invisible on this host regardless while the live aiplayerbot.conf sets all three keys explicitly. Per the image-accumulation finding recorded on artifact 037, that image is whichever batch carries this branch -- not necessarily the newest tortoise-cm tag.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/51, build tortoise-cm:20260818-5.
