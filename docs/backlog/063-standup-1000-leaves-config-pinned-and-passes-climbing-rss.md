---
status: implemented
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

**Base:** cm-main

**Branch:** backlog/standup-1000-leaves-config-pinned-and-passes-climbing-rss

**Summary:** Reworked `scripts/standup-1000.sh` on three points. (1) Restore on every exit path: the conf backup is now taken with a hard failure instead of `|| true`, and a `cleanup` EXIT trap — installed *before* the first `sed -i`, so no window exists where the conf is edited and untrapped — kills the RSS sampler and copies `aiplayerbot.conf.before` back over the live `aiplayerbot.conf`. finish() exits, so every gate failure and every early FAIL now restores too; restore is idempotent and logs loudly if the copy itself fails. mangosd is deliberately NOT restarted from the trap (that would drop live sessions of a run that failed for an unrelated reason) — the restored file is picked up at its next restart, and the log line says so. (2) Concurrency: a new section 0 takes an flock on `$TW_LIVE_ROOT/.standup-1000.lock` (same pattern as scripts/tournament/tournament-run.sh) before anything is touched; a second invocation logs the holder's pid line and exits `reason=another_standup_running` without editing the conf. fd 9 is closed for the backgrounded rss-trace child so an orphaned sampler cannot hold the lock. (3) The 60-minute plateau timeout now logs FAIL instead of WARN, and `plateau=0` is a real gate: `[ "$PLATEAU" = 1 ] || fail "no_plateau_rss_still_climbing"`. Verified in a WSL sandbox with stubbed validate-stack/provenance/rss-trace/rss-plateau and a fake `docker`: a run that fails at the sampler check restores the conf byte-identically, a second run under a held lock refuses and leaves the conf untouched, and a run that reaches the count without plateauing prints `plateau=0 ... verdict=FAIL reason=no_plateau_rss_still_climbing` and exits 1 with the conf restored and the sampler dead. No full stand-up was run, per the artifact's note.

**In-game check:** This change touches no server code — no C++, no SQL, no bot behaviour — so the only in-game exposure is that a stand-up run no longer leaves the host's bot pool pinned. The generic smoke test (server starts, bots spawn) plus these three ops checks, all scriptable and none needing a human to watch the world:

1. Restore on failure (fully scriptable, ~1 min). From an interactive WSL shell: `cp ~/tortoise-wow-server-V2/etc/aiplayerbot.conf /tmp/conf.pre`, then with the stack DOWN (so validate-stack fails) run `./scripts/standup-1000.sh --target 1000 --out logs/standup/restore-test`. Expect `STANDUP ... verdict=FAIL reason=stack_validation_failed` and `diff /tmp/conf.pre ~/tortoise-wow-server-V2/etc/aiplayerbot.conf` empty. For a failure that happens AFTER the conf edit (the case the bug was about), bring the stack up, unset PATH to `rss-trace.sh`'s deps or temporarily `chmod -x scripts/rss-trace.sh` and re-run: expect `reason=trace_not_running`, a `restored ...aiplayerbot.conf from ...aiplayerbot.conf.before` line in `logs/standup/<run>/standup.log`, and again an empty diff. Re-`chmod +x` afterwards.
2. Lock refusal (scriptable, ~10 s). Hold the lock in one shell — `exec 9>>~/tortoise-wow-server-V2/.standup-1000.lock; flock -n 9` — then run the script in a second shell. Expect it to exit 1 with `reason=another_standup_running`, a log line naming the holder's pid, and the live conf unchanged (`grep MinRandomBots` still shows the pre-existing value, not 1000).
3. Plateau gate. Grep-confirmable without a run: `grep -n 'no_plateau_rss_still_climbing' scripts/standup-1000.sh` shows it in the gate block. To exercise it end to end without the ~2.5 h stand-up, copy the script, `sed` the plateau `deadline=$(( $(date +%s) + 3600 ))` to `+ 0`, and run it against stubs — expect `plateau=0 ... verdict=FAIL reason=no_plateau_rss_still_climbing` and exit 1 (this is exactly what was run here). The artifact explicitly says a full stand-up is not required and should not be run.

One thing a human should eyeball after any real (non-stubbed) run: `AiPlayerbot.MinRandomBots`/`MaxRandomBots` in `~/tortoise-wow-server-V2/etc/aiplayerbot.conf` are back at the host's normal value, and the world's actual bot population returns to that value after the next `docker restart tcm-mangosd` (the trap restores the file, not the running server, by design).

**Minor findings:**
- scripts/standup-1000.sh: The lock file is opened append-only and a pid line is appended on every successful acquisition, so `head -1 "$LOCK_FILE"` in the refusal message reports the very first run ever recorded rather than the current holder — it should be `tail -1` (and the file grows without bound).
- scripts/standup-1000.sh: `restore_conf` unconditionally logs "mangosd keeps target=$TARGET until its next restart", which is false on the failure paths that exit before the restart (`conf_min_random_bots_not_set_mangosd_not_restarted`, `mangosd_restart_failed`), telling the operator the live world is pinned at the new target when it never was.
- scripts/standup-1000.sh: The lock-refusal message reads `head -1 "$LOCK_FILE"`, but the file is opened append-only (`exec 9>>`) and never truncated, so it reports the pid/out-dir of the first run that ever took the lock instead of the run currently holding it.
- scripts/standup-1000.sh: The flock only excludes other invocations of this script, while scripts/bot-ramp.sh and scripts/task3-ramp-step.sh `sed -i` the same live etc/aiplayerbot.conf and restart mangosd without taking it, so a concurrent ramp can still race the pool target and have its edit silently overwritten by this script's EXIT-trap restore.
