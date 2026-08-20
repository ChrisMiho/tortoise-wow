---
status: done
risk: low
area: tournament/effects
depends-on: 032-viewer-effect-library.md
---

# There is no durable place for a viewer command to land

**Problem:** Effects can be validated and applied, but nothing accepts one from
outside. Without a durable queue there is no boundary between "where commands come
from" and "what they do", so a real Twitch or TikTok adapter would have to be
written against the applier directly — and the whole pass would then need OAuth
and a live channel before any of it could be tested.

**Suspected cause / area:** Implements
`docs/superpowers/plans/2026-08-16-06-viewer-effects.md` Task 4.

**Acceptance criteria:**

- `scripts/tournament/effect-queue.sh --queue <file> --effect <name> --team <id>
  [--slot <slot>] [--source <name>] [--id <id>]` appends **one NDJSON line** and
  echoes the id it assigned.
- The queue is **append-only**. Nothing rewrites it in place — the consumer may
  be reading it.
- Each line is independently parseable JSON with the shape
  `{id, ts, effect, target:{team[, slot]}, source}`. `target.slot` is present only
  when a slot was given.
- Generated ids are unique per command. `$RANDOM` alone repeats within a second
  across forks, so it is paired with a nanosecond timestamp.
- **The command is validated before it is appended** — `effect_validate` must
  pass. A malformed command in the queue is a landmine the consumer trips over
  mid-match. On rejection: exit 1 and **nothing is appended**.
- `bash tests/tournament/effects.test.sh` prints `17 passed, 0 failed` and
  exits 0. Added cases cover: one line appended and the effect written; the echoed
  id matching the written id; a second append not rewriting the first; the slot
  written; every line in the queue being valid JSON on its own; and an unknown
  effect being refused at enqueue with the file left unchanged.

**Notes:**

- **Run the test from WSL** —
  `wsl -d Ubuntu -- bash -lc 'cd /mnt/c/<worktree path> && bash tests/tournament/effects.test.sh'`.
  `jq` is absent from Git Bash on this host.
- This is the **mock adapter**, and saying so in the script header is part of the
  deliverable. A real Twitch or TikTok listener replaces this one script and
  nothing else; everything downstream reads the file. That boundary is exactly why
  this pass builds no OAuth — the effects can be tested end to end with no
  credentials and no live channel.
- **It is also the primary human interface for validating effects, not just a
  test fixture**, so it has to be pleasant to drive by hand: a usage line that
  names all eight effects, and an error on a bad `--effect`, `--team` or `--slot`
  that says what the valid values are rather than only that the input was
  rejected. Platform integration comes later, once the idea has been exercised
  locally — this script is what that exercising is done with.
- This artifact extends `tests/tournament/effects.test.sh` (artifacts 031-032),
  which is why it stacks on 032. All 11 existing assertions must still pass.
- No server and no build are involved.

**Base:** backlog/viewer-effect-library

**Branch:** backlog/viewer-effect-queue

**Summary:** Added `scripts/tournament/effect-queue.sh`, the mock adapter that gives viewer commands a durable place to land, and extended `tests/tournament/effects.test.sh` with six assertions covering it (17 passed, 0 failed, exit 0, run from WSL). The script takes `--queue <file> --effect <name> --team <id> [--slot <slot>] [--source <name>] [--id <id>]`, builds one NDJSON object of the shape `{id, ts, effect, target:{team[, slot]}, source}` with `jq -nc --arg` (so an adapter-supplied `--source` full of quotes escapes rather than breaking the line, and `target.slot` is emitted only when a slot was given), runs it through `effect_validate` from `lib/effects.sh`, and only then appends a single line with `>>` — nothing rewrites the file, since the consumer may be reading it. On rejection it exits 1 and the file is untouched; the echoed id is the same id written to the file. Ids pair `date -u +%s%N` with `$RANDOM` because `$RANDOM` alone is seeded from pid+clock and repeats across forks within a second — a duplicate id is a command the consumer would dedupe away unapplied; a 200-way parallel append produced 200 distinct ids and 200 independently parseable lines. Because this is also the human interface for exercising effects rather than just a test fixture, `--help`/usage names all eight effects and the ten slots, and a bad `--effect`, `--team` or `--slot` prints the valid values (the effect list, the team ids actually present in `TEAM_DIR`, the slot words) instead of only saying the input was rejected; a `_player` effect given no `--slot` is told to use `--slot` or the matching `_team` effect. The script sources only `lib/team.sh` and `lib/effects.sh` — validation needs no gear file and no console. No C++, no SQL migration, no build, and no server involvement.

**In-game check:** This change is a WSL shell script plus its unit tests — no C++, no SQL, no new console command, and nothing that runs inside mangosd — so it needs no in-game confirmation beyond the generic "server starts, bots spawn" smoke test. Everything that can go wrong with it is confirmable off-server, and ALL of the following is scriptable with no human watching a game client:

1. `wsl -d Ubuntu -- bash -lc 'cd /mnt/c/<checkout> && bash tests/tournament/effects.test.sh'` prints `17 passed, 0 failed` and exits 0. (Must be WSL — jq is absent from Git Bash on this host and `require_cmd` hard-exits.)
2. `bash scripts/tournament/effect-queue.sh --help` prints all eight effect names (heal_player, heal_team, kill_player, kill_team, upgrade_armor_player, upgrade_armor_team, upgrade_weapon_player, upgrade_weapon_team) and the ten slot words, and exits 0.
3. Rejections name the valid values, and leave the file alone. Against a fresh `q=$(mktemp)`: `--team stormwynd` prints `unknown team: 'stormwynd'` followed by the four ids in config/tournament/teams and exits 1; `--effect heal_player --slot eleven` prints `unknown slot: 'eleven'` and the ten valid slots and exits 1; `--effect kill_player` with no `--slot` says it needs one and suggests `kill_team`; after all three, `wc -c < "$q"` is 0.
4. Uniqueness under the condition that actually breaks `$RANDOM`: fire 200 backgrounded appends into one queue file, then `wc -l` is 200 and `jq -r .id < q | sort -u | wc -l` is also 200 — anything less means two viewer commands would collapse into one applied effect.
5. Append-only and per-line parseability: `while IFS= read -r l; do printf '%s' "$l" | jq -e . >/dev/null || echo BAD; done < q` prints nothing, and the first line of the file is byte-identical before and after later appends.
6. Shape: `jq -c .target` on a `_team` line is exactly `{"team":"..."}` with no `slot` key, and on a `_player` line carries `slot`.

The only part that is not confirmable yet is the end-to-end one — a queued command actually healing or killing a bot inside a running Warsong Gulch — because the consumer that reads this file (`effect-consume.sh`, Task 5 of the plan) does not exist on any branch yet. Once it does, the in-game check is: start a match with `scripts/tournament/match-run.sh`, run `effect-queue.sh --queue <q> --effect kill_player --team orgrimmar-warsong --slot five`, and watch Wsghfive drop to a corpse in the client while the consumer prints one `EFFECT id=<the echoed id> effect=kill_player team=orgrimmar-warsong applied=1 failed=0` line. Nothing in this artifact is required to wait for that.

**Minor findings:**
- scripts/tournament/effect-queue.sh: A flag given without its value (e.g. `--queue` as the final argument) makes the argument loop spin forever instead of exiting 2, because `${2:-}` supplies an empty value while `shift 2` fails to shift with only one argument left, leaving `$#` unchanged — confirmed by running `effect-queue.sh --effect heal_team --team stormwind-sentinels --queue`, which had to be killed by `timeout` (rc=124).
- scripts/tournament/effect-queue.sh: The header's claim that concurrent appends cannot interleave rests on O_APPEND atomicity that does not hold on the drvfs/9p `/mnt/c` path where artifact 035 places the queue, and the line length is caller-controlled via the unbounded `--source`/`--id` values, so a long line can be split across multiple write() calls even on ext4.

**Drain note (finding 1 REPRODUCED — it is a HANG, and "minor" undersells it):** independently confirmed on 2026-08-18 by running the branch's script under `timeout 8` from WSL with lib/team.sh and lib/effects.sh present:

```
control, well-formed:                     exit=0    1 line written, id 1787065464062719380-32223
--effect heal_team --team ... --queue :   exit=124  (timed out -- infinite loop)
```

So the happy path is correct and the id format is exactly as described (nanosecond timestamp paired with $RANDOM), but a flag supplied without its value spins forever instead of exiting 2. Cause is as the finding states: `${2:-}` yields an empty value while `shift 2` fails with only one argument remaining, so $# never decreases and the while loop never terminates.

This deserves more than minor severity for two reasons specific to what this script IS. First, the artifact itself frames it as "the human interface for exercising effects" -- a hand-typed command line, where a trailing flag is an ordinary typo rather than an exotic input. Second, it is the adapter boundary: a real Twitch or TikTok listener replaces THIS script and nothing else, so the failure mode a future adapter author inherits is a silently wedged process rather than a non-zero exit they would notice. A hang is worse than an error here because nothing reports it. One `[ $# -ge 2 ] || usage_error` in the flag branch closes it.

**Drain note (finding 2 is a sound cross-artifact observation worth keeping):** the header claims concurrent appends cannot interleave, resting on O_APPEND write atomicity. Artifact 035 places the queue at `${EFFECT_QUEUE:-$RUN_DIR/effects.ndjson}` under the repo, i.e. on `/mnt/c`, which on this host is a drvfs/9p mount where that guarantee does not hold as it does on ext4. The line length is also caller-controlled through the unbounded `--source` and `--id` values, so a sufficiently long line can be split across write() calls even on a native filesystem. The 200-way parallel test the Summary cites passed, but a passing race test demonstrates the race did not occur, not that it cannot -- and the consumer treats a torn line as a malformed command mid-match. Worth either bounding --source/--id length or documenting the filesystem assumption rather than asserting atomicity unconditionally.

**Note on inherited exposure (not this artifact's bug, but this is where its blast radius is set):** the drain recorded two defects on artifact 032, the consumer this queue feeds. (1) effect_apply opens ONE console attach PER TARGET, against the "ONE console attach for the whole run" convention gear-apply.sh documents and the repo's warning that repeated attaches risk EOF-ing the console and shutting the world down -- so every `*_team` effect this queue accepts costs ten attaches. (2) effect_apply counts a target as applied if ANY reply line contains ok=1, so a partial equip reports clean success -- which this queue will then faithfully record as delivered and dedupe away, making the false success permanent. Fixing 032 is the right place for both; noting them here so the queue's throughput is not raised before they are.

**Batch note:** PR phase did not return a pull request URL, got: null The branch was integrated into 20260818-5 and the build and VALIDATE-STACK both passed; only the PR call failed, on an API server error mid-response. Verified 2026-08-18 that no PR exists for this branch (`gh pr list --head backlog/viewer-effect-queue --state all` returns []), so a retry will create one rather than duplicating. Artifact deliberately left at status: implemented so the next batch picks it up.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/52, build tortoise-cm:20260818-6.

**Batch note (retry succeeded):** the PR for this branch failed on an API server error during batch 20260818-5 and the artifact was held at status: implemented. Batch 20260818-6 retried it and opened PR #52. Verified no duplicate was created: `gh pr list --head backlog/viewer-effect-queue --state all` returns exactly 1.
