---
status: pending
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
