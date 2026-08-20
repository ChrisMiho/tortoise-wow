---
status: done
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
- The trace is written continuously to disk under `--out`; a ramp to 1000 bots is
  long enough that it will sometimes be interrupted, and a trace held in memory
  until the end would be lost entirely.
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

**Base:** backlog/recover-ramp-and-plateau-instruments

**Branch:** backlog/standup-1000-script

**Summary:** Added `scripts/standup-1000.sh` (302 lines, exec bit set, one commit 17d5e93 on `backlog/standup-1000-script` cut from `origin/backlog/recover-ramp-and-plateau-instruments`). It takes `[--target 1000] [--out <dir>]` and runs the stand-up in the order the artifact specifies: refuse to run from Git Bash; resolve the image tag (TW_IMAGE from the environment or `.env` — `:local` is appended only when the value carries no tag, so a `tortoise-cm:20260818-5` from the batch pass is not mangled into `...:local`); run `scripts/validate-stack.sh --keep-up`, capture its output to `$OUT/validate-stack.log` and fail immediately unless it contains `VALIDATE-STACK: PASS`; back up and sed the live `aiplayerbot.conf`, assert the Min/MaxRandomBots post-condition before restarting mangosd (sed exits 0 whether or not it matched); wait for the world port; start `rss-trace.sh` with `TW_RSS_TRACE=$OUT/rss-trace.tsv` / `TW_RSS_INTERVAL=30` / `TW_STACK_ROOT` (no flags — it ignores them) and prove within 5 s that the sampler is alive and writing, echoing its captured stderr and telling the operator to use an interactive WSL shell if it is not; wait for the online count; then *separately* hold for a plateau by calling `rss-plateau.sh 20` (a window in samples) and reading its exit status rather than grepping its prose, so "NOT SETTLED" is never mistaken for a plateau. Gates are host free ≥ 4 GiB (PowerShell interop, `timeout 20`; an unreadable reading is a loud FAIL, not a skipped gate, because that is the gate that tripped at 2002 bots while the VM still showed 16.80 GiB), VM available ≥ 2 GiB, RSS < 6.0 GiB with the 4.2682 GiB / 1017-bot reference named in comments, and online ≥ target. The rss_kb column is located from the trace's header row and blank cells are skipped. A single `finish()` prints exactly one `STANDUP target= online= rss= vmAvailable= hostFree= plateau= verdict= reason=` line on every exit path and exits 0 only on PASS. Verified: `bash -n` passes; the Git Bash guard emits one STANDUP line and exit 1; a WSL smoke run reached validate-stack, read its FAIL verdict, emitted one STANDUP line and stopped without touching the live conf or bringing the stack up; header-column lookup and the plateau contract (rc=0 PLATEAU, rc=1 RISING) exercised against synthetic traces; the host-free and VM-available samplers read 15.42 / 22.08 GiB on this host. Per the artifact's Notes, the script was not actually run to completion (a real stand-up is ~2.5 h and needs a live conf edit); no build, no server changes.

**In-game check:** This is an ops script, not a gameplay change, so nothing in the world looks different — the confirmation is one real run against a live stack. Budget ~2.5 hours and do it from an INTERACTIVE WSL shell (`wsl -d Ubuntu`, then run it), never a wrapped `wsl -e bash -lc '...'` one-liner, or the backgrounded RSS sampler dies with the invocation.

Checklist:
1. With this branch's image built and the stack's `.env` TW_IMAGE pointing at it, run `./scripts/standup-1000.sh --target 1000 --out logs/standup/first` from the repo root in WSL.
2. Within ~2 minutes, confirm the log shows, in this order: `verifying provenance before standing anything up (image tortoise-cm:<tag>)`, `provenance, identity and liveness OK`, `pool target set to 1000 in .../etc/aiplayerbot.conf; restarting mangosd to apply`, `world is up`, and `rss-trace running (pid N) -> <out>/rss-trace.tsv`. That last line is the sampler-liveness gate — if it instead prints `FAIL: rss-trace is not running` and `reason=trace_not_running` within ~10 seconds, the script did its job and you are in the wrong kind of shell.
3. Confirm `<out>/rss-trace.tsv` is growing on disk while the ramp runs: `wc -l <out>/rss-trace.tsv` twice, a minute apart, must increase (~2 rows/min at the 30 s cadence). This is the "trace survives an interruption" property.
4. Log a real client into the realm mid-ramp if you want the human playability check from the plan's Task 5 — this script does not test that.
5. Watch for the count/plateau split in the log: repeated `online=N/1000` lines, then `count reached; now holding for an RSS plateau`, then one or more `VERDICT: RISING`/`NOT SETTLED` blocks from `rss-plateau.sh` before `VERDICT: PLATEAU`. If it went straight from the count to the gates with no plateau block, the two loops have collapsed into one and that is the bug this artifact exists to prevent.
6. The whole verdict is scriptable and needs no human eye: the run's final line is exactly one `STANDUP target=1000 online=<n> rss=<GiB> vmAvailable=<GiB> hostFree=<GiB> plateau=1 verdict=PASS reason=-`, and `echo $?` is 0. `grep -c '^STANDUP ' logs/standup/first/standup.log` must be exactly 1. A later batch step can assert both without a human.
7. Read the numbers, not just the verdict: `rss` should land near 4.2682 GiB (the 2026-08-15 reference at 1017 bots). Materially above that at 1000 bots is a regression from this plan series, not a new baseline, even though the 6.0 GiB ceiling still passes it. `hostFree` must be a number, never `unknown` — an `unknown` is a FAIL with a five-line WARN banner and means PowerShell interop is broken, not that the host is fine (measured working on this host today: hostFree=15.42, vmAvailable=22.08).
8. Afterwards, note the pool is left at 1000 in the live `etc/aiplayerbot.conf`; the pre-edit copy is saved at `<out>/aiplayerbot.conf.before`. Restore it (and restart mangosd) before running a tournament, since `wsg-mode.sh on` expects to manage the pool.

**Minor findings:**
- scripts/standup-1000.sh: If no plateau is reached within the 60-minute hold the script only logs a WARN and breaks with PLATEAU=0, then applies the gates normally, so a run whose RSS is still climbing can print `plateau=0 ... verdict=PASS` and exit 0 — which contradicts the artifact's premise that reaching the count is not proof the stack settled, even though plateau is not in the enumerated gate list.
- scripts/standup-1000.sh: The script mutates host-global shared state — sed -i on the live aiplayerbot.conf plus a docker restart of tcm-mangosd — with no lock guarding concurrent runs, and although it saves aiplayerbot.conf.before it never restores it on any exit path (the EXIT trap only kills the sampler), so a failed run silently leaves the live pool target pinned.

**Drain note (finding 1 CONFIRMED, and it is a spec gap as much as a bug — this defeats the artifact's headline premise):** verified against the branch on 2026-08-18. The gate block at :333-362 calls fail() for exactly four conditions -- rss_above_<N>GiB, vm_available_below/unreadable, host_free_below/unreadable, and online_below_target. The string PLATEAU does not appear anywhere in it. Meanwhile :278 sets PLATEAU=1 only when rss-plateau.sh exits 0, and the 60-minute hold otherwise logs a WARN and breaks with PLATEAU=0. So a run whose RSS is still climbing after an hour can print `plateau=0 ... verdict=PASS` and exit 0.

That contradicts this artifact's own Problem statement in as many words: "Reaching the count is not the same as reaching a plateau -- bot-ramp.sh's wait returns REACHED the instant the online count crosses its threshold, but bot inventory and talent construction continue well past login, so RSS is still climbing at that point." The whole reason the script separates the count wait from the plateau wait is to make that distinction, and then the verdict ignores it.

Worth being fair about where the fault lies: the acceptance criteria enumerate the gates as "host free >= 4 GiB, VM available >= 2 GiB, RSS under a stated ceiling with the 4.2682 GiB reference named in a comment, and online >= target" -- plateau is not in that list. The implementation follows the letter of the criteria while defeating their purpose. The fix is one line (`[ "$PLATEAU" -eq 1 ] || fail "no_plateau"`), and the artifact text should be amended to enumerate plateau as a gate so the next reader is not misled by the same omission.

**Drain note (finding 2 is a real operational hazard and echoes a warning artifact 043 just made):** the script sed -i's the live aiplayerbot.conf and docker-restarts tcm-mangosd, saves aiplayerbot.conf.before, and then never restores it on any exit path -- the EXIT trap only kills the sampler. So any FAIL (and there are a dozen finish FAIL paths, several before the ramp even starts) leaves the live pool target pinned at whatever the run set. Artifact 043 recorded the symptom of exactly this class of mistake one tick earlier: "a world left at zero looks like a healthy server that is mysteriously empty". Same failure mode, opposite direction. There is also no lock, so two concurrent runs would fight over one host-global conf.

**Drain note (the 041 hand-off WORKED — this was the specific thing the drain was watching for):** artifact 041 recovered these instruments and recorded two interface facts it called out as easy to get wrong, because this artifact is their only consumer: rss-trace.sh takes NO flags (a passed --out is silently ignored and the trace lands at TW_RSS_TRACE's default), and rss-plateau.sh's $1 is a window size in samples, not a path. Both are honoured in the code, not just the prose. Verified: :170 is `"$HERE/rss-trace.sh" > "$OUT/rss-trace.err" 2>&1 &` with no arguments at all, commented at :162 with the reason; :275 is `"$HERE/rss-plateau.sh" 20` with an integer, commented at :262 with the reason. Had either been got wrong the failure would have been silent -- a trace written to the wrong path, or a plateau check that rejected its own argument -- and it would have surfaced 90 minutes into a 2.5-hour run.

**Also worth noting:** this is the first of three consecutive ticks that needed a memory-measurement citation and did NOT cite docs/playerbots/BOT-MEMORY-INVESTIGATION.md (grep count 0), the file the drain established on artifact 041 exists on no remote branch. 042 and 043 both had to route around it.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/54, build tortoise-cm:20260818-6.
