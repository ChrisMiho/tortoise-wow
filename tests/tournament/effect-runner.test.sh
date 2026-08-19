#!/usr/bin/env bash
# The viewer-effect consumer's lifetime: scripts/tournament/lib/effect-runner.sh.
#
# No server, no database, no world. The consumer here is a stub that spawns a
# child of its own and then sleeps -- that child stands in for the `docker exec`
# a real console attach leaves in flight, which is the process that used to
# survive the stop and go on to deliver its effect into the NEXT match.
#
# The signal cases run a real bash in a child process, signal it, and then look
# at what is left in the process table. Asserting on the process table is the
# only honest form of this test: the bug it pins is precisely a stop that returns
# while a process it claimed to have killed is still alive.
#
# Run from WSL, not Git Bash: jq is absent from Git Bash's PATH on this host, and
# the group check needs a real procps `ps`.
#
#   wsl -d Ubuntu -- bash -lc 'cd /mnt/c/... && bash tests/tournament/effect-runner.test.sh'
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/../lib/assert.sh"

require_cmd jq ps

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ATEAM=stormwind-sentinels
HTEAM=orgrimmar-warsong

# A stub consumer with the real one's argument shape. It records its own pid and
# its child's, then both sleep far longer than this file runs, so nothing here
# can pass by simply outwaiting them.
cat > "$TMP/effect-consume.sh" <<'STUB'
#!/usr/bin/env bash
# stub: same flags as scripts/tournament/effect-consume.sh, no world
out=""
while [ $# -gt 0 ]; do
    case "$1" in
        --state) out="$2"; shift 2 ;;
        --queue|--alliance|--horde|--interval) shift 2 ;;
        *) shift ;;
    esac
done
mkdir -p "$out"
sleep 300 &                       # stands in for an in-flight `docker exec`
printf '%s\n' "$$" > "$out/stub.pid"
printf '%s\n' "$!" > "$out/child.pid"
wait
STUB
chmod +x "$TMP/effect-consume.sh"

alive()     { kill -0 "$1" 2>/dev/null; }
alive_flag() { if alive "${1:-1}"; then echo 1; else echo 0; fi; }

runner_script() { # <file> <state-dir> <log> <tail-command...>
    local f="$1" st="$2" lg="$3"; shift 3
    cat > "$f" <<EOF
set -uo pipefail
. "$ROOT/scripts/tournament/lib/effect-runner.sh"
EFFECT_QUEUE="$st.ndjson"; : >> "\$EFFECT_QUEUE"
EFFECT_STATE="$st"
effect_consumer_install_traps
effect_consumer_start "$TMP/effect-consume.sh" $ATEAM $HTEAM "$lg" 5
$*
EOF
}

# --- 1. an ordinary stop takes the whole group, and the caller survives -------
#
# The parent surviving its own cleanup is half the assertion: a group kill aimed
# one group too high takes the match down together with the consumer.
runner_script "$TMP/ordinary.sh" "$TMP/s1" "$TMP/l1.log" \
    'sleep 1; effect_consumer_stop; echo PARENT-SURVIVED'
OUT="$(bash "$TMP/ordinary.sh" 2>"$TMP/e1")"
assert_contains "$OUT" "PARENT-SURVIVED" \
  "the script outlives its own consumer cleanup -- the group kill did not take the parent"
assert_eq "0" "$(alive_flag "$(cat "$TMP/s1/stub.pid" 2>/dev/null)")" \
  "the consumer itself is gone after effect_consumer_stop"
assert_eq "0" "$(alive_flag "$(cat "$TMP/s1/child.pid" 2>/dev/null)")" \
  "the consumer's in-flight child is gone too -- it cannot deliver into the next match"
assert_contains "$(cat "$TMP/e1")" "effect consumer stopped" \
  "the stop says so on the log"

# --- 2. SIGTERM, SIGHUP, SIGINT ----------------------------------------------
#
# The case that motivated the artifact: a tournament runner terminating
# match-run.sh. A non-interactive bash with no handler for one of these dies
# WITHOUT running its EXIT trap, so the consumer is orphaned and keeps draining
# into the following match.
signal_case() { # <signal> <expected-exit-code>
    local sig="$1" want="$2" pid stub child rc=0 i=0 st
    st="$TMP/s-$sig"
    # effect_sleep, because that is what the monitor loop waits on: a plain
    # `sleep` here would defer the trap for its whole duration and the case would
    # hang rather than fail, which is what match-run.sh used to do under SIGTERM.
    runner_script "$TMP/sig-$sig.sh" "$st" "$TMP/l-$sig.log" 'effect_sleep 300'
    # `set -m` for the launch, and it is load-bearing for the SIGINT case rather
    # than tidiness: a non-interactive shell starts an asynchronous child with
    # SIGINT and SIGQUIT set to IGNORE, and a signal ignored at startup cannot be
    # trapped afterwards -- so without job control here the INT case would test a
    # process that can never see the signal, and hang. Job control gives the
    # child its own process group and the default dispositions a real operator's
    # Ctrl-C would find.
    set -m
    bash "$TMP/sig-$sig.sh" 2>/dev/null &
    pid=$!
    set +m
    # Wait for the stub to have recorded both pids, so the signal lands on a run
    # whose consumer is actually up rather than on one still starting.
    while [ ! -s "$st/child.pid" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
    stub="$(cat "$st/stub.pid" 2>/dev/null)"
    child="$(cat "$st/child.pid" 2>/dev/null)"
    kill -"$sig" "$pid" 2>/dev/null
    # Bounded, not a bare `wait`: a signal the run never acts on must read as a
    # failure in seconds rather than as a test that never returns.
    i=0
    while alive "$pid" && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
    if alive "$pid"; then
        assert_eq "exited" "still running" \
          "SIG$sig: the run acts on the signal instead of finishing its poll first"
        kill -KILL "$pid" 2>/dev/null
    fi
    wait "$pid" 2>/dev/null || rc=$?
    sleep 1   # the shell is reaped; let the group finish dying
    assert_eq "0" "$(alive_flag "$stub")" \
      "SIG$sig: no consumer process remains"
    assert_eq "0" "$(alive_flag "$child")" \
      "SIG$sig: no descendant of the consumer remains"
    # A 0 here would be indistinguishable to a bracket driver from a match played
    # to a result, so the handler re-raises rather than exiting on its own.
    assert_eq "$want" "$rc" \
      "SIG$sig: the run still exits 128+$sig rather than swallowing the signal"
}

signal_case TERM 143
signal_case HUP  129
signal_case INT  130

# --- 2b. nothing left behind holds the caller's stdout ------------------------
#
# tournament-run.sh reads a match through `line="$(match-run.sh ... | tail -1)"`,
# and a command substitution returns only once EVERY writer has closed the pipe.
# A consumer or a poll-sleep still holding an inherited stdout therefore stalls
# the whole bracket after the match is already decided. Timed, because that
# failure is a delay and not an error: the substitution below would sit there for
# the sleep's full 300s.
runner_script "$TMP/stray.sh" "$TMP/s-stray" "$TMP/l-stray.log" 'echo MARK; effect_sleep 300'
T0="$(date +%s)"
STRAY="$(timeout -s TERM 3 bash "$TMP/stray.sh" 2>/dev/null)"
T1="$(date +%s)"
assert_contains "$STRAY" "MARK" \
  "the run's stdout is captured"
assert_eq "prompt" "$( [ $((T1 - T0)) -lt 30 ] && echo prompt || echo "stalled $((T1 - T0))s" )" \
  "capturing the run's stdout returns as soon as it exits -- nothing inherited the pipe"

# --- 3. a shared queue across two consecutive matches ------------------------
#
# EFFECT_QUEUE overridden to one long-lived file with EFFECT_STATE per match:
# exactly the shape a bracket runs, and the one where match two would otherwise
# re-apply everything match one already handled. `ctl` comes from a stub, so
# every count below is about the consumer's bookkeeping and not the world.
QUEUE="$TMP/shared.ndjson"; : > "$QUEUE"
cat > "$TMP/ctlstub.sh" <<'CTL'
ctl() { printf 'TOURNAMENT %s ok=1\n' "$*"; }
ctl_field() { printf '%s\n' "$1" | sed -n "s/.*[[:space:]]$2=\\([^[:space:]]*\\).*/\\1/p" | head -1; }
CTL

bash "$ROOT/scripts/tournament/effect-queue.sh" --queue "$QUEUE" \
     --effect heal_player --team "$ATEAM" --slot one >/dev/null
bash "$ROOT/scripts/tournament/effect-queue.sh" --queue "$QUEUE" \
     --effect heal_player --team "$ATEAM" --slot two >/dev/null

M1="$TMP/m1"; M2="$TMP/m2"
OUT1="$(CTL_STUB="$TMP/ctlstub.sh" bash "$ROOT/scripts/tournament/effect-consume.sh" \
        --queue "$QUEUE" --alliance "$ATEAM" --horde "$HTEAM" \
        --state "$M1" --once 2>/dev/null)"
assert_contains "$OUT1" "applied=2" \
  "match one applies both queued commands"

# Match two, seeded the way effect_consumer_start seeds it.
( . "$ROOT/scripts/tournament/lib/effect-runner.sh"
  EFFECT_QUEUE="$QUEUE" EFFECT_STATE="$M2" effect_seed_applied ) 2>/dev/null
OUT2="$(CTL_STUB="$TMP/ctlstub.sh" bash "$ROOT/scripts/tournament/effect-consume.sh" \
        --queue "$QUEUE" --alliance "$ATEAM" --horde "$HTEAM" \
        --state "$M2" --once 2>/dev/null)"
assert_contains "$OUT2" "applied=0" \
  "match two re-applies nothing from match one over the shared queue"

# The seeding must drop the backlog, not deafen the consumer: a command a viewer
# files DURING match two is still that match's to apply.
bash "$ROOT/scripts/tournament/effect-queue.sh" --queue "$QUEUE" \
     --effect heal_player --team "$ATEAM" --slot three >/dev/null
OUT3="$(CTL_STUB="$TMP/ctlstub.sh" bash "$ROOT/scripts/tournament/effect-consume.sh" \
        --queue "$QUEUE" --alliance "$ATEAM" --horde "$HTEAM" \
        --state "$M2" --once 2>/dev/null)"
assert_contains "$OUT3" "applied=1" \
  "a command queued during match two is still applied by match two"

assert_summary
