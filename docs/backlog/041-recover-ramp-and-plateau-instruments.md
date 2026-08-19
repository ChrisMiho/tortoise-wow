---
status: done
risk: low
area: ops/measurement
depends-on:
---

# A full night of memory measurement lives on one unpushed local branch

**Problem:** `memory/baseline-measurement` exists only in this working copy.
`origin` has `memory/baseline-investigation`, which does **not** contain the
memory documents or the ramp instruments. That branch holds both the evidence the
1000-bot work reasons from — 4.2682 GiB RSS at 1017 bots online, plateaued, VM
still 17.62 GiB free, the ramp not tripping a gate until 2002 bots and then on
*Windows host-free* memory — and the three scripts needed to reproduce it. Shelving
the *code* was a decision; losing the *measurements* would be an accident, and it
is currently one disk failure or one stray `git branch -D` away.

**Suspected cause / area:** Implements
`docs/superpowers/plans/2026-08-16-09-release-tag-and-1000-bot-standup.md` Task 1,
Steps 1, 3 and 4.

**Acceptance criteria:**

- `scripts/rss-trace.sh`, `scripts/rss-plateau.sh` and `scripts/bot-ramp.sh` are
  present on this branch, recovered with
  `git checkout memory/baseline-measurement -- <paths>`, executable, and
  committed.
- `bash -n` passes on all three.
- Each script's header has been read and its actual interface recorded in the
  commit message or a short comment — specifically these two, which are easy to
  get wrong and are relied on by artifact 044:
  - `rss-trace.sh` takes **no command-line flags**. It is configured entirely by
    `TW_RSS_TRACE` / `TW_RSS_INTERVAL` / `TW_STACK_ROOT`. Passing `--out` does not
    error; it is silently ignored and the trace lands at the script's own default
    path instead of where the caller expects it.
  - `rss-plateau.sh`'s `$1` is a **window size in samples, not a path**. It reads
    the trace from `TW_RSS_TRACE` and rejects a non-integer argument outright.
- **Nothing else comes across from that branch.** These are read-only
  instrumentation — an RSS sampler, a plateau detector and a ramp driver — and
  they carry none of that branch's conclusions or code changes, so recovering them
  does not un-shelve anything.

**Notes:**

- **The plan's Step 2 asks for `git push -u origin memory/baseline-measurement`.
  That is deliberately not part of these acceptance criteria.** The Implement
  phase of `backlog-issue` is explicitly instructed never to push, so an artifact
  whose success depends on a push cannot succeed. Pushing that branch is an
  operator action, and it should still happen: **pushing a branch is not merging
  it** — it stays shelved and unmerged, it simply stops being one disk away from
  gone. If pushing the whole branch is unwanted, push a docs-only branch carrying
  `docs/playerbots/BOT-MEMORY-*` and the three raw data files. Recording this in
  the commit message, so it is not lost, is part of the work.
- Confirm what is at risk with `git branch -r | grep memory` and
  `git ls-tree -r --name-only memory/baseline-measurement -- docs/playerbots scripts`.
  **Use a `--` pathspec, never `git cat-file -e <rev>:<path>`** — under Git Bash,
  MSYS rewrites the `rev:path` argument and the existence check returns silent
  false negatives. That has already fooled one session on this host.
- `bot-ramp.sh`'s `wait` returns `REACHED` the instant the online count crosses
  its threshold, which is **not** an RSS plateau — bot inventory and talent
  construction continue well past login. `rss-plateau.sh` is the instrument that
  answers the plateau question (20 samples at 30 s is a 10-minute window, drift
  under 0.25% of the window's opening RSS). Do not substitute one for the other.
- No build and no server are involved. Do not *run* the ramp here.
