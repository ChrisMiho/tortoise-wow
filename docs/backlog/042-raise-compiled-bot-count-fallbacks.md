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
