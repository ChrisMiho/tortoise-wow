---
status: pending
risk: medium
area: ops/standup
depends-on: 044-standup-1000-script.md
---

# `standup-1000.sh` leaves the live config pinned and can pass a still-climbing stack

**Problem:** two defects in `scripts/standup-1000.sh`.

1. It saves `aiplayerbot.conf.before` but never restores it on any exit path —
   the EXIT trap only kills the sampler — so a failed run silently leaves the
   live pool target pinned at 1000 on a host whose config is shared state. It
   also `sed -i`s that live conf and restarts `tcm-mangosd` with no lock
   guarding concurrent runs.
2. If no plateau is reached within the 60-minute hold, the script logs a WARN,
   breaks with `PLATEAU=0`, then applies the remaining gates normally — so a run
   whose RSS is still climbing can print `plateau=0 ... verdict=PASS` and exit 0.
   That contradicts the artifact's own premise that reaching the bot count is not
   proof the stack settled.

**Suspected cause / area:** `scripts/standup-1000.sh`, the EXIT trap and the
plateau branch.

**Acceptance criteria:**

- Every exit path restores `aiplayerbot.conf` from the backup; verified by
  diffing the live conf before and after a deliberately failed run.
- A second concurrent invocation refuses to start rather than racing the first.
- `plateau=0` cannot produce `verdict=PASS` — either it is a gate, or the verdict
  names it as unproven.

**Notes:**

- The restore and lock paths are testable with a **short run that fails early** —
  the script already stops cleanly at `validate-stack`. A full stand-up is ~2.5 h
  and is **not** required to verify either fix; do not run one.
- This script mutates host-global shared state and restarts the world server. Be
  certain the restore path is right before running it at all.
