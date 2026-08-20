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

**Base:** cm-main

**Branch:** backlog/recover-ramp-and-plateau-instruments

**Summary:** Cut `backlog/recover-ramp-and-plateau-instruments` from `origin/cm-main` and recovered `scripts/rss-trace.sh`, `scripts/rss-plateau.sh` and `scripts/bot-ramp.sh` verbatim from the local-only `memory/baseline-measurement` branch with `git checkout memory/baseline-measurement -- <paths>`. Confirmed the risk first: `git branch -r | grep memory` shows only `origin/memory/baseline-investigation`, and `git ls-tree -r --name-only origin/memory/baseline-investigation -- docs/playerbots scripts` shows it carries an older `bot-ramp.sh` (23 insertions / 6 deletions behind) and neither `rss-trace.sh` nor `rss-plateau.sh` nor any `BOT-MEMORY-*` doc or raw data file — so both plateau instruments existed on exactly one disk. `bash -n` passes on all three; `rss-trace.sh` and `rss-plateau.sh` came across mode 100644 and were made 100755 with `git update-index --chmod=+x`, so all three commit as executable. File contents are byte-identical to the source branch (`git diff memory/baseline-measurement HEAD` reports mode changes only), and the whole diff against `origin/cm-main` is exactly those three files, 726 insertions — nothing else came across, no docs, no conclusions, no code changes, so the shelved branch stays shelved. Each header was read and the real interface recorded in the commit message: `rss-trace.sh` parses no argv at all (verified — no `getopts`, no `$@`, no top-level positionals; the only `$1` is a function parameter inside `rss_kb()`), so `--out` is silently ignored and the trace lands at `TW_RSS_TRACE`'s default `/home/deck/rss-watch.tsv`; `rss-plateau.sh`'s `$1` is a window size in samples, not a path. Both were exercised locally against a synthetic 5-row trace in the scratchpad: `rss-plateau.sh 5` printed `VERDICT: PLATEAU` and exited 0, and passing a file path as `$1` printed `FATAL: window must be an integer number of samples` and exited 1. The commit message also records the operator follow-up the artifact asks not to be lost — `git push -u origin memory/baseline-measurement` (pushing is not merging), or failing that a docs-only branch carrying `docs/playerbots/BOT-MEMORY-*` plus the three raw data files. No build, no server, and the ramp was not run.

**In-game check:** This change adds no C++ and no SQL — it recovers three shell scripts that run on the WSL host against the containers. In-game, nothing changes: the generic smoke test (server starts, `rndbot` bots spawn and are online) is the whole of the in-game confirmation needed, and any batch build failure would be unrelated to this branch since no translation unit is touched.

What IS worth confirming, all scriptable from WSL with no human eyes needed, and all runnable against whatever image is already up (these scripts read the running stack, they do not depend on this branch being compiled):

1. Scriptable, no stack needed: `bash -n scripts/rss-trace.sh scripts/rss-plateau.sh scripts/bot-ramp.sh` exits 0, and `test -x` passes on all three after checkout.
2. Scriptable, no stack needed — the two interface facts artifact 044 depends on. Write a synthetic tab-separated trace with header `ts_utc configured online rss_kb vm_avail_kb status` and ~5 rows of constant `rss_kb`/`online`, point `TW_RSS_TRACE` at it, then: `./scripts/rss-plateau.sh 5` must print a `window:` / `online:` / `rss:` block ending in `VERDICT: PLATEAU` and exit 0; `./scripts/rss-plateau.sh /path/to/that/trace` must print exactly `FATAL: window must be an integer number of samples` and exit 1 (proving `$1` is a sample count, not a path). Both were run here and behaved exactly so.
3. Scriptable against the live stack, read-only: with `tcm-mangosd` and `tcm-db` up and `TW_STACK_ROOT=/home/deck/tortoise-wow-server-V2`, run `./scripts/rss-trace.sh` from an interactive WSL shell (NOT `nohup`/`setsid` — the script's own header records that a process backgrounded inside `wsl.exe -e bash -lc` is torn down with the invocation). After ~3 minutes, `/home/deck/rss-watch.tsv` should have a header plus ~6 rows whose `rss_kb` column is a plain integer and whose `status` column reads `running`, not `missing`. Then `./scripts/rss-plateau.sh 5` against that real trace should print a verdict rather than `INSUFFICIENT`. Ctrl-C the sampler; it loops forever by design.
4. Scriptable, read-only, live stack: `./scripts/bot-ramp.sh 500 gates` should print the gates block without editing anything (`gates` is a read path; only `apply` writes `etc/aiplayerbot.conf` and restarts mangosd). Do NOT run `apply` or `wait` as part of verifying this artifact — the artifact explicitly says do not run the ramp here, and `apply` restarts the world.
5. Manual, operator-only, and NOT part of this branch: `git push -u origin memory/baseline-measurement` (or a docs-only branch carrying `docs/playerbots/BOT-MEMORY-*` and the three raw data files). Until that happens the measurements this artifact protects — the 4.2682 GiB at 1017 bots run log — are still one disk away from gone, even though the instruments are now safe. The commit message records this so it is not lost.

Note for whoever runs 3 and 4: paths like `/home/deck/rss-watch.tsv` and `/home/deck/tortoise-wow-server-V2` are WSL-side, and these scripts must be invoked from WSL, never Git Bash — from Git Bash MSYS rewrites the standalone POSIX path and the invocation dies naming a `C:/Program Files/Git/...` path you never typed.

**Minor findings:** none reported by the review lenses.

**Drain note (premise and recovery both VERIFIED):** independently checked on 2026-08-18.

- The data-loss premise is real. `git branch --list memory/*` shows memory/baseline-measurement locally; `git branch -r --list origin/memory/*` shows only origin/memory/baseline-investigation. Searching that remote branch for the three instruments finds bot-ramp.sh (1) but rss-trace.sh (0) and rss-plateau.sh (0). Both plateau instruments genuinely existed on exactly one disk before this branch.
- The recovery is exact. `git diff --name-status origin/cm-main...HEAD` is precisely the three script files and nothing else, so the shelved branch stays shelved and none of its conclusions or code changes came across. All three are mode 100755. Diffing the recovered files against memory/baseline-measurement reports 0 insertions and 0 deletions -- byte-identical, mode changes only, exactly as the Summary claims.

**Drain note (THE MEASUREMENTS ARE STILL UNPROTECTED -- this is the residual risk and it is worse than the artifact implies):** this artifact saved the INSTRUMENTS. It did not save the EVIDENCE, and the artifact itself flags that as operator follow-up. The drain checked how exposed that evidence actually is, and the answer is completely:

```
docs/playerbots/BOT-MEMORY-INVESTIGATION.md          origin/cm-main:0  origin/memory/baseline-investigation:0
docs/playerbots/BOT-MEMORY-MEASUREMENT-RUN-LOG.md    origin/cm-main:0  origin/memory/baseline-investigation:0
docs/playerbots/BOT-MEMORY-STATIC-ANALYSIS.md        origin/cm-main:0  origin/memory/baseline-investigation:0
docs/playerbots/BOT-MEMORY-STATIC-ANALYSIS-BRIEF.md  origin/cm-main:0  origin/memory/baseline-investigation:0
```

plus the raw data files -- bot-memory-ramp-20260815.csv, bot-memory-rss-trace-20260815.tsv, bot-memory-rss-trace-postreboot-20260815.tsv, bot-memory-boot-profile-20260815.tsv and progression-baseline-20260815/ -- none of which exist on any remote branch. Only docs/backlog/011-bot-memory-baseline-and-investigation.md reached origin. So the 4.2682 GiB-at-1017-bots run log and the ramp data that the whole 1000-bot effort reasons from are on ONE disk, one `git branch -D` or one drive failure from gone. The fix is a single operator command and does NOT un-shelve anything, because pushing is not merging:

```
git push -u origin memory/baseline-measurement
```

The drain deliberately did not run it: pushing a branch outside this artifact's scope is an outward-facing action the drain is not authorised to take on its own.

**Cross-check against a same-day measurement:** artifact 040 measured this host under load a few hours earlier on tortoise-cm:20260818-4 -- mangosd ~172% CPU (1.7 of 16 cores) and 5.6 GiB RSS with 998 bots online, ~16.9 GiB still available. That is consistent in shape with the recovered instruments' premise (RSS plateauing well inside available memory at ~1000 bots) and nothing in this tick contradicts it.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/50, build tortoise-cm:20260818-5.
