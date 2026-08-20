---
status: done
risk: low
area: docs/tournament
depends-on: 040-streaming-feasibility-assessment.md
---

# Documentation claims that point the next reader at the wrong thing

**Problem:** four load-bearing-but-false statements left by the 18 Aug drain,
each of the kind that survives because it reads plausibly.

1. `spectate.sh`'s header justifies "run from WSL" with "jq is not on Git Bash's
   PATH on this host" — but `spectate.sh`, `lib/ctl.sh` and
   `wsg-bots-common.sh` contain no `jq` call at all. A correct instruction rests
   on a dependency that does not exist, and will be "corrected" away by the first
   person who checks.
2. The same header points twice at `docs/playerbots/TOURNAMENT-STREAMING.md`,
   which artifact 040 creates. The reference dangles until that work is on the
   base branch, and if the merge wave order changes it dangles on `cm-main`.
3. `wsg-mode.sh`'s new header comment says "the compiled pool default moved from
   200 to 1000 (`aiplayerbot.conf.dist.in:57-58`)", but the `.dist.in` has
   shipped 1000 all along. What moved was `PlayerbotAIConfig.cpp:250`, and the
   stale 200 was this script's own literal — so the comment points a maintainer
   at the wrong file for the history.
4. `wsg-mode.sh`'s no-snapshot fallback prints "pool 1000/1000 (from
   `<DIST_AICONF>`)" unconditionally, naming a file it never read — on a server
   host where the script was copied without the source tree, which is the exact
   case those literals exist for.

**Suspected cause / area:** `scripts/tournament/spectate.sh`,
`docs/playerbots/wsg/wsg-mode.sh`.

**Acceptance criteria:**

- Each of the four statements is either corrected to match the code or removed.
- The `TOURNAMENT-STREAMING.md` reference resolves on the base branch.
- The fallback's provenance string distinguishes "read from the file" from
  "compiled-in literal".

**Notes:**

- No build, no world.
- `depends-on` names artifact 040 rather than 039 deliberately: 040's branch
  descends from 039's, so branching from 040 supplies both `spectate.sh` (from
  039) **and** `TOURNAMENT-STREAMING.md` (from 040). Branching from 039 alone
  would leave acceptance criterion 2 unsatisfiable.
- Keep the "run from WSL" instruction itself — it is correct for other reasons.
  Only the `jq` justification is false.

**Base:** cm-main

**Branch:** backlog/correct-four-false-documentation-claims

**Summary:** Documentation-only fix across two shell scripts, no C++ and no SQL. In `scripts/tournament/spectate.sh` the "Run from WSL" header note justified itself with "jq is not on Git Bash's PATH", but neither spectate.sh nor lib/ctl.sh nor wsg-bots-common.sh calls jq; the instruction is now grounded in the dependency that actually exists — `wsg_console` wraps `docker attach` in util-linux `script` for a pty (wsg-bots-common.sh:106), which Git Bash does not ship. The file's single `docs/playerbots/TOURNAMENT-STREAMING.md` reference already resolves: artifact 040 landed on cm-main in PR #49, so the file exists on the base branch this branch was cut from (verified with `git ls-tree origin/cm-main`); no change was needed there. In `docs/playerbots/wsg/wsg-mode.sh` the header blamed `aiplayerbot.conf.dist.in:57-58` for the pool default moving 200 -> 1000, but that file has shipped MinRandomBots = MaxRandomBots = 1000 all along; the comment now points at the compiled fallback in `PlayerbotAIConfig.cpp:260-261`, which is what actually moved, and says plainly that the stale 200 was this script's own literal. Finally the `off --profile alive-world` no-snapshot fallback printed "pool 1000/1000 (from <DIST_AICONF>)" unconditionally, naming a file it never opened on a server host where the script was copied without the source tree; it now probes the .dist.in for AiPlayerbot.MinRandomBots and prints either "read from <path>" or "compiled-in literal; no value in <path>". Both branches were exercised directly (real path -> "read from", nonexistent path -> "compiled-in literal"); `bash -n` passes on both scripts and tests/tournament/spectate.test.sh is 4 passed, 0 failed.

**In-game check:** No in-game confirmation is needed beyond the generic "server starts, bots spawn" smoke test — this change touches only shell comments and one echoed status string, and no C++, no conf, no SQL. Everything meaningful here is scriptable and needs no human eyes:

1. Provenance string, source tree present (scriptable). From WSL, in a checkout with no `.wsg-mode-snapshot.json` at `$WSG_SERVER_ROOT`, run `docs/playerbots/wsg/wsg-mode.sh off --profile alive-world` and confirm the pool line reads `pool 1000/1000 (read from /.../src/modules/PlayerBots/playerbot/aiplayerbot.conf.dist.in)` — not the old `(from ...)`.
2. Provenance string, source tree absent (scriptable, no server needed). Same command with `WSG_DIST_AICONF=/nonexistent/aiplayerbot.conf.dist.in` set; the line must read `pool 1000/1000 (compiled-in literal; no value in /nonexistent/aiplayerbot.conf.dist.in)`. This is the server-host case the criterion is about. Both branches were already exercised in isolation on this branch.
3. Dangling reference (scriptable). `test -f docs/playerbots/TOURNAMENT-STREAMING.md` from the repo root must succeed on the merged branch; the spectate.sh header's only reference to it then resolves.
4. Claim-vs-code checks (scriptable greps). `grep -rn jq scripts/tournament docs/playerbots/wsg` must return nothing, confirming spectate.sh's header no longer rests on a nonexistent dependency. `grep -n 'MinRandomBots' src/modules/PlayerBots/playerbot/aiplayerbot.conf.dist.in` must show 1000, and `grep -n 'GetIntDefault("AiPlayerbot.MinRandomBots"' src/modules/PlayerBots/playerbot/PlayerbotAIConfig.cpp` must show 1000 at line ~260 — the two facts the corrected header now asserts.
5. Regression guard (scriptable). `bash tests/tournament/spectate.test.sh` — 4 passed, 0 failed.

Nothing here requires logging into the world. If anyone wants a live sanity pass, running `spectate.sh` from WSL against a match and seeing it cut the camera normally is sufficient; the only WSL-specific claim changed is why WSL is required, not whether it is.

**Minor findings:**
- docs/playerbots/wsg/wsg-mode.sh: The new header says the compiled fallback was "raised from 200 to 1000", but PlayerbotAIConfig.cpp's own comment records the previous values as 50 (min) and 200 (max), so the single "200" misdescribes the min default in a comment whose whole purpose is doc accuracy.
- docs/playerbots/wsg/wsg-mode.sh: Twelve lines below the edited block, the RandomBotTimedLogout comment still cites `PlayerbotAIConfig.cpp:254` when that call is at line 265 (254 is a bare `//`) — the same class of stale file reference this artifact corrects, left in place inside the touched region.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/79, build tortoise-cm:20260819-5.
