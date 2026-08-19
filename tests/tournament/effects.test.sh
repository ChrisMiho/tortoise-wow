#!/usr/bin/env bash
# Unit tests for viewer effects: the two halves of a gear tier
# (gear_items_armor / gear_items_weapon in scripts/tournament/lib/gear.sh), and
# the effect library itself (scripts/tournament/lib/effects.sh) -- what makes a
# command well formed and which characters it is allowed to touch -- and the
# append-only queue the mock adapter (scripts/tournament/effect-queue.sh) files
# commands into.
#
# No server and no database. GEAR_DIR points at tests/fixtures/gear -- the
# committed hand-written fixture -- NOT at config/tournament/gear, which is
# written by gear-generate.sh against a live item_template and is empty in every
# checkout where that generator has not been run, including this one.
#
# Run from WSL, not Git Bash: jq is not on Git Bash's PATH on this host and
# require_cmd is a hard exit, not a skip.
#
#   wsl -d Ubuntu -- bash -lc 'cd /mnt/c/... && bash tests/tournament/effects.test.sh'
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/../lib/assert.sh"

require_cmd jq

. "$ROOT/scripts/tournament/lib/gear.sh"
export GEAR_DIR="$ROOT/tests/fixtures/gear"

A="$(gear_items_armor warrior tank base)"
W="$(gear_items_weapon warrior tank base)"

# `upgrade_armor_player` and `upgrade_weapon_player` are separately priced
# effects. If either half leaked the other's slots, a viewer who paid for one
# would get both and the two effects would be indistinguishable.
assert_eq "0" "$(printf '%s\n' "$A" | grep -c '^mainhand|')" \
  "the armour half excludes mainhand -- buying armour does not re-arm the bot"

assert_eq "1" "$(printf '%s\n' "$W" | grep -c '^mainhand|')" \
  "the weapon half includes mainhand -- buying a weapon actually arms the bot"

assert_contains "$A" "chest|" \
  "the armour half includes chest"

assert_eq "0" "$(printf '%s\n' "$W" | grep -c '^chest|')" \
  "the weapon half excludes chest"

# The one that matters. Not a line count: comparing the sorted union against the
# sorted whole also catches a slot that landed in BOTH halves (a viewer paying
# for armour would silently get the weapon too) as well as one that landed in
# neither -- a slot no effect in the catalogue could ever upgrade, which no
# amount of buying would ever fix.
whole="$(gear_items warrior tank base | sort)"
halves="$({ printf '%s\n' "$A"; printf '%s\n' "$W"; } | grep . | sort)"
assert_eq "$whole" "$halves" \
  "armour + weapons reconstitute the tier exactly -- no slot in both, none in neither"

# --- effect validation and targeting ----------------------------------------
#
# Validation and targeting only. effect_apply's own path talks to the control
# plane, which needs a running world, so it is deliberately not exercised here:
# these cases are the half that must hold before any command is allowed near a
# live match, and they hold with nothing standing up.
. "$ROOT/scripts/tournament/lib/team.sh"
. "$ROOT/scripts/tournament/lib/effects.sh"
export TEAM_DIR="$ROOT/config/tournament/teams"

OK='{"id":"a1","ts":"2026-08-16T21:00:00Z","effect":"heal_player","target":{"team":"stormwind-sentinels","slot":"three"},"source":"mock"}'
assert_exit 0 "a well-formed command validates" -- effect_validate "$OK"

# The name is prefix+slot, the same rule roster creation used, so this is also
# the assertion that an effect and the character it means cannot drift apart.
assert_eq "Wsgathree" "$(effect_targets "$OK" stormwind-sentinels orgrimmar-warsong)" \
  "resolves a single-slot target to a character name"

TEAMFX='{"id":"a2","ts":"2026-08-16T21:00:00Z","effect":"heal_team","target":{"team":"orgrimmar-warsong"},"source":"mock"}'
assert_eq "10" "$(effect_targets "$TEAMFX" stormwind-sentinels orgrimmar-warsong | wc -l | tr -d ' ')" \
  "a team effect targets all ten"

# Rejection and reason in one assertion, because a rejection with no reason is
# not much better than none: a queue consumer logs the stderr line beside the
# command it dropped, and "invalid" alone cannot tell a typo'd effect name from
# a team file that has stopped validating.
BADFX='{"id":"a3","ts":"2026-08-16T21:00:00Z","effect":"summon_dragon","target":{"team":"stormwind-sentinels"},"source":"mock"}'
BADOUT="$(effect_validate "$BADFX" 2>&1)"; BADRC=$?
assert_eq "1|unknown effect" "$BADRC|$(printf '%s\n' "$BADOUT" | grep -o 'unknown effect')" \
  "an unknown effect is rejected, and says that is why"

# No id means no dedupe key, so a replayed queue would apply this a second time
# -- a viewer defrauded, or a team wiped twice.
NOID='{"ts":"2026-08-16T21:00:00Z","effect":"heal_team","target":{"team":"stormwind-sentinels"},"source":"mock"}'
assert_exit 1 "a command with no id is rejected" -- effect_validate "$NOID"

# A team not in this match must never be targeted -- the queue outlives a match,
# and those characters are offline, so the effect would report success and do
# nothing at all.
OFFMATCH='{"id":"a4","ts":"2026-08-16T21:00:00Z","effect":"kill_team","target":{"team":"ironforge-anvils"},"source":"mock"}'
assert_exit 1 "a team not playing this match is rejected" -- \
  effect_targets "$OFFMATCH" stormwind-sentinels orgrimmar-warsong

# --- the queue and its mock adapter -----------------------------------------
#
# effect-queue.sh is run as a subprocess, not sourced, because that is how an
# adapter will invoke it. TEAM_DIR is exported above, so the child sees the same
# teams these assertions do.
q="$(mktemp)"

id1="$(bash "$ROOT/scripts/tournament/effect-queue.sh" --queue "$q" \
        --effect heal_team --team stormwind-sentinels --source mock)"
assert_eq "1|1" \
  "$(wc -l < "$q" | tr -d ' ')|$(grep -c '"effect":"heal_team"' "$q")" \
  "one command appends exactly one line, and it carries the effect"

# The echoed id is the only handle the caller gets on the command it just filed;
# if it did not match what was written, a consumer's dedupe list and an adapter's
# idea of what it sent would silently describe different commands.
assert_contains "$(cat "$q")" "\"id\":\"$id1\"" \
  "the id echoed to the caller is the id written to the queue"

first="$(head -1 "$q")"
bash "$ROOT/scripts/tournament/effect-queue.sh" --queue "$q" \
     --effect kill_player --team orgrimmar-warsong --slot five >/dev/null
# Append-only, asserted as such: a line count alone would not catch a rewrite
# that happened to preserve the count, and the consumer may be mid-read.
assert_eq "2|$first" "$(wc -l < "$q" | tr -d ' ')|$(head -1 "$q")" \
  "a second append leaves the first line byte-identical"

assert_contains "$(tail -1 "$q")" '"slot":"five"' \
  "a _player command records the slot it targets"

# Every line independently parseable, not just the file as a whole: the consumer
# reads line by line, and one broken line would poison the file for good.
assert_exit 0 "every queue line is valid JSON on its own" -- \
  bash -c "while IFS= read -r l; do printf '%s' \"\$l\" | jq -e . >/dev/null || exit 1; done < '$q'"

# A command the applier would refuse must never be filed in the first place: in
# the queue it is a landmine the consumer trips over mid-match, with nobody there
# to fix it. So the rejection and the untouched file are one assertion.
BADRC=0
bash "$ROOT/scripts/tournament/effect-queue.sh" --queue "$q" \
     --effect summon_dragon --team stormwind-sentinels >/dev/null 2>&1 || BADRC=$?
assert_eq "1|2" "$BADRC|$(wc -l < "$q" | tr -d ' ')" \
  "an unknown effect is refused at enqueue and nothing is appended"

rm -f "$q"

# --- the consumer: dedupe and rate limits -----------------------------------
#
# effect-consume.sh is the only thing that turns a queued command into something
# that happens in the world, and both properties asserted here are correctness
# requirements rather than polish: the queue is append-only and replayed from
# byte zero after a crash, and `kill_team` decides matches.
#
# No server. The consumer sources $CTL_STUB instead of lib/ctl.sh when that
# variable is set, so `ctl` here is a local function that reports ok=1 for
# everything -- which makes every assertion below about the consumer's own
# bookkeeping, not about the control plane.
q2="$(mktemp)"; st="$(mktemp -d)"
cat > "$st/ctlstub.sh" <<'STUB'
ctl() { printf 'TOURNAMENT %s ok=1\n' "$*"; }
ctl_field() { printf '%s\n' "$1" | sed -n "s/.*[[:space:]]$2=\\([^[:space:]]*\\).*/\\1/p" | head -1; }
STUB

idA="$(bash "$ROOT/scripts/tournament/effect-queue.sh" --queue "$q2" \
        --effect heal_player --team stormwind-sentinels --slot one)"
# The same id twice: an adapter double-delivery, or a queue replayed after a
# crash. Both are ordinary, and both must land on the bot exactly once.
bash "$ROOT/scripts/tournament/effect-queue.sh" --queue "$q2" \
     --effect heal_player --team stormwind-sentinels --slot one --id "$idA" >/dev/null

OUT="$(CTL_STUB="$st/ctlstub.sh" bash "$ROOT/scripts/tournament/effect-consume.sh" \
        --queue "$q2" --alliance stormwind-sentinels --horde orgrimmar-warsong \
        --state "$st" --once 2>&1)"

assert_eq "1" "$(grep -c "^EFFECT id=$idA" <<< "$OUT")" \
  "a duplicate id is applied exactly once"

# Reported, not merely dropped: silently swallowing a repeat makes an adapter
# that double-delivers every command indistinguishable from a healthy one.
assert_contains "$OUT" "skipped=1" \
  "and the duplicate is counted as skipped on the CONSUME line"

assert_eq "1" "$(grep -c "^$idA\$" "$st/applied.txt")" \
  "an applied id is recorded once, which is what makes the next pass a no-op"

OUT2="$(CTL_STUB="$st/ctlstub.sh" bash "$ROOT/scripts/tournament/effect-consume.sh" \
         --queue "$q2" --alliance stormwind-sentinels --horde orgrimmar-warsong \
         --state "$st" --once 2>&1)"
assert_eq "0" "$(grep -c "^EFFECT " <<< "$OUT2")" \
  "a second pass over the same queue applies nothing"

# kill_team wipes ten bots and ends a Warsong Gulch match, so the cap has to
# bite on the very next command, not eventually. Note that counts.txt already
# exists by now, holding heal_player and no kill_team line -- the exact state a
# naive `grep -c ... || echo 0` counter returns "0\n0" for, which makes the
# comparison below fail as a non-integer and never limit anything.
for i in 1 2 3; do
  bash "$ROOT/scripts/tournament/effect-queue.sh" --queue "$q2" \
       --effect kill_team --team orgrimmar-warsong >/dev/null
done
OUT3="$(CTL_STUB="$st/ctlstub.sh" EFFECT_LIMIT_KILL_TEAM=1 \
        bash "$ROOT/scripts/tournament/effect-consume.sh" \
        --queue "$q2" --alliance stormwind-sentinels --horde orgrimmar-warsong \
        --state "$st" --once 2>&1)"
assert_eq "1" "$(grep -c 'effect=kill_team' <<< "$OUT3")" \
  "kill_team is rate limited to one under EFFECT_LIMIT_KILL_TEAM=1"

# Counted apart from a duplicate, because the two mean opposite things: one says
# viewers are over the cap, the other says the adapter is delivering twice.
assert_contains "$OUT3" "ratelimited=2" \
  "and the two over the cap are reported as rate limited, not skipped"

# --- the consumer: bad caps, refusals, crash safety, two consumers ----------
#
# Each of these was a way to defeat one of the two guarantees above: the cap and
# the dedupe. All five run against CTL_STUB, so no world stands up.

q3="$(mktemp)"; st3="$(mktemp -d)"
cat > "$st3/ctlstub.sh" <<'STUB'
ctl() { printf 'TOURNAMENT %s ok=1\n' "$*"; }
ctl_field() { printf '%s\n' "$1" | sed -n "s/.*[[:space:]]$2=\\([^[:space:]]*\\).*/\\1/p" | head -1; }
STUB

bash "$ROOT/scripts/tournament/effect-queue.sh" --queue "$q3" \
     --effect kill_team --team orgrimmar-warsong >/dev/null

# A cap override comes from the environment, which is where an operator typos
# one. Unvalidated it does not merely misbehave -- `[ "$used" -ge abc ]` errors
# and evaluates FALSE, so the cap stops biting entirely and every kill_team in
# the queue lands. It has to be named and refused, not absorbed.
BADLIM=0
BADLIMOUT="$(CTL_STUB="$st3/ctlstub.sh" EFFECT_LIMIT_KILL_TEAM=abc \
    bash "$ROOT/scripts/tournament/effect-consume.sh" --queue "$q3" \
    --alliance stormwind-sentinels --horde orgrimmar-warsong \
    --state "$st3" --once 2>&1)" || BADLIM=$?
assert_eq "2|1|0" \
  "$BADLIM|$(grep -c 'EFFECT_LIMIT_KILL_TEAM' <<< "$BADLIMOUT")|$(grep -c '^EFFECT ' <<< "$BADLIMOUT")" \
  "EFFECT_LIMIT_KILL_TEAM=abc is refused by name and nothing is applied"

# A team not in this match is refused by effect_targets and never reaches a bot,
# so it must not spend cap. It used to: five stale queue lines naming a team
# from another match exhausted kill_team's cap of 2 before a single legitimate
# command landed.
q4="$(mktemp)"; st4="$(mktemp -d)"
cp "$st3/ctlstub.sh" "$st4/ctlstub.sh"
for i in 1 2 3 4 5; do
  bash "$ROOT/scripts/tournament/effect-queue.sh" --queue "$q4" \
       --effect kill_team --team ironforge-anvils >/dev/null
done
for i in 1 2; do
  bash "$ROOT/scripts/tournament/effect-queue.sh" --queue "$q4" \
       --effect kill_team --team orgrimmar-warsong >/dev/null
done
OUT4="$(CTL_STUB="$st4/ctlstub.sh" bash "$ROOT/scripts/tournament/effect-consume.sh" \
        --queue "$q4" --alliance stormwind-sentinels --horde orgrimmar-warsong \
        --state "$st4" --once 2>&1)"
assert_eq "2|0" \
  "$(grep -c 'effect=kill_team team=orgrimmar-warsong' <<< "$OUT4")|$(grep -c 'ratelimited=[1-9]' <<< "$OUT4")" \
  "five refused kill_team leave the default cap of 2 intact for the real ones"

assert_eq "2" "$(grep -cxF kill_team "$st4/counts.txt")" \
  "and only the two that actually landed are counted against the cap"

# The mirror of the case above, and the one that matters more: a wipe that
# landed on NINE of ten bots because the tenth logged out. effect_apply returns
# 1 for that -- its rc is all-or-nothing -- so keying the count on the rc made
# every partial wipe free. In game: nine Horde bots dead, five times over, with
# kill_team's cap of 2 never engaging. The count keys on "at least one target
# landed" instead, which is the applied=<n> on effect_apply's own EFFECT line.
q7="$(mktemp)"; st7="$(mktemp -d)"
cat > "$st7/ctlstub.sh" <<'STUB'
ctl() {
    case "$*" in
        *one) printf 'TOURNAMENT %s ok=0 reason=offline\n' "$*" ;;
        *)    printf 'TOURNAMENT %s ok=1\n' "$*" ;;
    esac
}
ctl_field() { printf '%s\n' "$1" | sed -n "s/.*[[:space:]]$2=\\([^[:space:]]*\\).*/\\1/p" | head -1; }
STUB
for i in 1 2 3 4 5; do
  bash "$ROOT/scripts/tournament/effect-queue.sh" --queue "$q7" \
       --effect kill_team --team orgrimmar-warsong >/dev/null
done
OUT7="$(CTL_STUB="$st7/ctlstub.sh" bash "$ROOT/scripts/tournament/effect-consume.sh" \
        --queue "$q7" --alliance stormwind-sentinels --horde orgrimmar-warsong \
        --state "$st7" --once 2>&1)"
assert_eq "2|2|ratelimited=3" \
  "$(grep -c 'applied=9 failed=1' <<< "$OUT7")|$(grep -cxF kill_team "$st7/counts.txt")|$(sed -n 's/^CONSUME .*\(ratelimited=[0-9]*\).*/\1/p' <<< "$OUT7")" \
  "a wipe that landed on nine of ten bots spends cap: the third is rate limited"

# A consumer killed partway through a kill_team's ten ctl calls. The id used to
# be appended only after effect_apply returned, so the next pass replayed the
# whole wipe -- ten bots killed twice off one purchase.
q5="$(mktemp)"; st5="$(mktemp -d)"
cat > "$st5/ctlstub.sh" <<'STUB'
ctl() {
    n=$(cat "$CTL_COUNT" 2>/dev/null || echo 0); n=$((n + 1))
    printf '%s\n' "$n" > "$CTL_COUNT"
    [ "$n" -lt 4 ] || kill -9 $$
    printf 'TOURNAMENT %s ok=1\n' "$*"
}
ctl_field() { printf '%s\n' "$1" | sed -n "s/.*[[:space:]]$2=\\([^[:space:]]*\\).*/\\1/p" | head -1; }
STUB
id5="$(bash "$ROOT/scripts/tournament/effect-queue.sh" --queue "$q5" \
        --effect kill_team --team orgrimmar-warsong)"
# The SIGKILL is deliberate -- it is the whole point of the case -- so the
# "Killed" notice this shell prints when it reaps the subshell is expected
# output, not a failure. The subshell keeps the consumer's own output quiet.
( CTL_COUNT="$st5/ctl.count" CTL_STUB="$st5/ctlstub.sh" \
  bash "$ROOT/scripts/tournament/effect-consume.sh" --queue "$q5" \
  --alliance stormwind-sentinels --horde orgrimmar-warsong \
  --state "$st5" --once ) >/dev/null 2>&1

assert_eq "1" "$(grep -cxF -- "$id5" "$st5/applied.txt" 2>/dev/null)" \
  "an id is claimed BEFORE the first ctl call, so a kill cut short is still recorded"

OUT5="$(CTL_STUB="$st3/ctlstub.sh" bash "$ROOT/scripts/tournament/effect-consume.sh" \
        --queue "$q5" --alliance stormwind-sentinels --horde orgrimmar-warsong \
        --state "$st5" --once 2>&1)"
assert_eq "0" "$(grep -c '^EFFECT ' <<< "$OUT5")" \
  "and the pass after the crash does not replay the interrupted wipe"

# Two consumers on one --state dir: an operator restarting the loop without
# killing the old one. Unlocked, both read applied.txt before either appends to
# it, both miss the id, and both wipe the same team. The stub logs every ctl
# call and sleeps, so the window the two overlap in is wide, not theoretical.
q6="$(mktemp)"; st6="$(mktemp -d)"
cat > "$st6/ctlstub.sh" <<'STUB'
ctl() { printf '%s\n' "$*" >> "$CTL_LOG"; sleep 0.05; printf 'TOURNAMENT %s ok=1\n' "$*"; }
ctl_field() { printf '%s\n' "$1" | sed -n "s/.*[[:space:]]$2=\\([^[:space:]]*\\).*/\\1/p" | head -1; }
STUB
: > "$st6/ctl.log"
bash "$ROOT/scripts/tournament/effect-queue.sh" --queue "$q6" \
     --effect kill_team --team orgrimmar-warsong >/dev/null
for i in 1 2; do
  CTL_LOG="$st6/ctl.log" CTL_STUB="$st6/ctlstub.sh" \
      bash "$ROOT/scripts/tournament/effect-consume.sh" --queue "$q6" \
      --alliance stormwind-sentinels --horde orgrimmar-warsong \
      --state "$st6" --once >/dev/null 2>&1 &
done
wait
assert_eq "10|1" \
  "$(wc -l < "$st6/ctl.log" | tr -d ' ')|$(wc -l < "$st6/applied.txt" | tr -d ' ')" \
  "two consumers on one state dir apply the kill exactly once: ten ctl calls, one id"

# A value-taking flag as the final argument used to spin the argument loop
# forever -- `shift 2` cannot shift with one argument left, so $# never
# decreased. rc=124 below is `timeout` killing a hung script, which is the bug;
# rc=2 is the script saying it was called wrong, which is the fix.
CRC=0
timeout 10 bash "$ROOT/scripts/tournament/effect-consume.sh" \
    --queue /dev/null --alliance stormwind-sentinels --horde orgrimmar-warsong \
    --state "$st6" --interval >/dev/null 2>&1 || CRC=$?
assert_eq "2" "$CRC" \
  "effect-consume.sh exits 2 on a trailing valueless flag instead of spinning"

QRC=0
timeout 10 bash "$ROOT/scripts/tournament/effect-queue.sh" \
    --queue "$q6" --effect heal_team --team stormwind-sentinels --source \
    >/dev/null 2>&1 || QRC=$?
assert_eq "2" "$QRC" \
  "effect-queue.sh exits 2 on a trailing valueless flag instead of spinning"

rm -rf "$q3" "$st3" "$q4" "$st4" "$q5" "$st5" "$q6" "$st6"

rm -rf "$q2" "$st"

assert_summary
