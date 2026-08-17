---
status: pending
risk: low
area: tournament/telemetry
depends-on: 027-telemetry-extract.md
---

# A telemetry CSV is 4800 rows nobody can read

**Problem:** The extracted CSV holds every sample of every player, which answers
nothing on its own. The two questions worth asking of a bot match are: did every
bot actually get in, and did it actually go anywhere. **A bot whose position does
not change across the whole match is not playing, whatever the score says** — and
that is the single most likely explanation for the 0-0 draws this server hard-caps
matches at 20 minutes because of.

**Suspected cause / area:** Implements
`docs/superpowers/plans/2026-08-16-05-bg-telemetry.md` Task 3.

**Acceptance criteria:**

- `scripts/tournament/telemetry-report.sh <csv> [--expected 20]` emits, in order:
  - `ENTRY player=<name> team=<n> firstSeen=<t> samples=<n>` per player;
  - `MOVEMENT player=<name> distance=<f> maxStep=<f> idleSamples=<n> stuck=<0|1>`
    per player;
  - `REPORT players=<n> expected=<n> entered=<n> stuck=<n>`.
- `stuck=1` means total travelled distance across the whole match is under 10
  yards. Warsong Gulch is roughly 900 yards end to end, so that is not "played
  cautiously" — it is a bot that never left its spawn. The threshold is a named
  constant with that reasoning in a comment.
- Exit 1 if fewer than `--expected` players entered **or** any bot is flagged
  stuck, so it works as a gate; exit 0 otherwise.
- Player order in the output is stable (first-seen order), not hash order.
- `bash tests/tournament/telemetry.test.sh` prints `12 passed, 0 failed` and
  exits 0. The added cases use a synthesised CSV with one player that moves every
  sample and one whose coordinates are identical throughout, and assert that only
  the second is flagged.

**Notes:**

- **Run the test from WSL** —
  `wsl -d Ubuntu -- bash -lc 'cd /mnt/c/<worktree path> && bash tests/tournament/telemetry.test.sh'`.
  `jq` is absent from Git Bash on this host.
- This artifact extends `tests/tournament/telemetry.test.sh`, which artifact 027
  creates — that is why it depends on it. The existing six assertions must still
  pass.
- `idleSamples` and `stuck` are different signals and the report must keep them
  distinguishable: a high `idleSamples` with a healthy `distance` is a bot that
  moved and then held position — flag carriers and defenders look like that — and
  is not alarming.
- **Verification needing a live stack (not part of these criteria):** run
  `telemetry-extract.sh` then this report against a real match, expecting 20
  `ENTRY` lines and `REPORT ... entered=20 stuck=0`. **A non-zero `stuck` count or
  an `entered` below 20 is the finding this whole plan exists to produce** —
  record the exact output; it feeds directly into artifacts 036-037.
