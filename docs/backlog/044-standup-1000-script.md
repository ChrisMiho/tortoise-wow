---
status: pending
risk: medium
area: ops/measurement
depends-on: 041-recover-ramp-and-plateau-instruments.md
---

# Standing the stack up at 1000 bots is a manual sequence with no gates

**Problem:** Bringing the server to 1000 bots and proving it actually settled
there is currently a sequence of hand-run commands with no defined verdict.
Reaching the *count* is not the same as reaching a *plateau* — `bot-ramp.sh`'s
`wait` returns `REACHED` the instant the online count crosses its threshold, but
bot inventory and talent construction continue well past login, so RSS is still
climbing at that point. And the gate that actually tripped during the 2026-08-15
ramp was **Windows host-free memory** (2.37 GiB against a 4 GiB threshold at 2002
bots), not the VM, which still had 16.80 GiB — so a run that only watches the VM
would report a pass on a host about to fall over.

**Suspected cause / area:** Implements
`docs/superpowers/plans/2026-08-16-09-release-tag-and-1000-bot-standup.md` Task 4,
Step 1 (writing the script).

**Acceptance criteria:**

- `scripts/standup-1000.sh [--target 1000] [--out <dir>]` exists and, in order:
  validates provenance before standing anything up (via
  `scripts/validate-stack.sh`, failing immediately unless it reports
  `VALIDATE-STACK: PASS`); sets the pool target in the live conf and restarts
  mangosd; starts an RSS trace; waits for the count; then **separately** holds for
  a plateau; then applies the gates.
- It emits exactly one summary line:
  `STANDUP target=<n> online=<n> rss=<GiB> vmAvailable=<GiB> hostFree=<GiB>
  plateau=<0|1> verdict=<PASS|FAIL> reason=<text>`, and exits 0 only on `PASS`.
- Gates, from the 2026-08-15 ramp: host free ≥ 4 GiB, VM available ≥ 2 GiB, RSS
  under a stated ceiling with the 4.2682 GiB reference named in a comment, and
  online ≥ target.
- **A host-free reading that cannot be taken is not a pass.** It needs PowerShell
  interop; if it comes back empty the script warns loudly that the gate which
  tripped at 2002 bots is UNCHECKED, rather than silently skipping it.
- **The trace is verified to be alive before the long wait, not after.** A
  backgrounded process inside a wrapped `wsl.exe -e bash -lc '...'` invocation is
  torn down when that invocation returns, and `nohup`/`setsid` do **not** save it
  (observed 2026-08-15). Every gate reads the trace, so a dead sampler must fail
  within seconds, with a message saying to run the script from an interactive WSL
  shell — not 90 minutes later.
- **`rss-trace.sh` is invoked correctly**: it takes no flags and is configured by
  `TW_RSS_TRACE` / `TW_RSS_INTERVAL` / `TW_STACK_ROOT`. Passing `--out` to it does
  not error — it is ignored, and the trace silently lands at the script's own
  default path instead. **`rss-plateau.sh` is invoked correctly**: its `$1` is a
  window size in samples, not a path (20 samples at 30 s is the 10-minute window
  the reference ramp used, with the same 0.25% drift criterion).
- **The RSS column is located by reading the trace's header row**, not by a
  hardcoded field position — the schema could gain a column and a hardcoded index
  would then silently read the wrong field.
- The trace is written continuously to disk under `--out`; **this host reboots
  itself overnight for Windows Update**, and a trace held in memory until the end
  would be lost entirely.
- `bash -n scripts/standup-1000.sh` exits 0.

**Notes:**

- **Writing the script is this artifact. Running it is not.** A real run takes up
  to 2.5 hours (the ramp alone is long and the plateau hold is deliberately
  patient), needs the full stack up, and needs a live conf edit — none of which is
  available to an unattended implement phase. Do not attempt a stand-up here.
- It sources `scripts/lib/provenance.sh` (already on `cm-main`: `prov_world_ready`,
  `prov_online_count`) and calls `scripts/rss-trace.sh` and
  `scripts/rss-plateau.sh` from artifact 041, which is why it depends on it.
- **Never `docker compose down -v`.** `tortoise-wow-v2_dbdata` is the entire
  world. Plain `down` only. `docker compose` needs `--env-file` anywhere other
  than the main checkout, and `TW_IMAGE` should always be passed explicitly.
- **Verification needing a live stack (not part of these criteria):**
  `./scripts/standup-1000.sh --target 1000 --out logs/standup/first`, expecting
  `online≈1000 rss≈4.3 plateau=1 verdict=PASS`. **Compare `rss` against
  4.2682 GiB**: materially above that at 1000 bots is a regression introduced
  somewhere in this plan series, not a new baseline — the tournament work adds a
  per-battleground telemetry sampler and a handful of commands, none of which
  should move a 3.14 GiB bot-free intercept.
