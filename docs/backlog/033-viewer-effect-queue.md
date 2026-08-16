---
status: pending
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
