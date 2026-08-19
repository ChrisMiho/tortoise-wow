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
# Validation and targeting first: the half that must hold before any command is
# allowed near a live match, and it holds with nothing standing up. effect_apply
# itself is exercised at the bottom of this file against the stub control plane
# in tests/fixtures/ctl-stub.sh, so no world is needed for that either.
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
cp "$ROOT/tests/fixtures/ctl-stub.sh" "$st/ctlstub.sh"

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

rm -rf "$q2" "$st"

# --- the applier: verdicts, tier bookkeeping and the attach count ------------
#
# effect_apply against the stub control plane in tests/fixtures/ctl-stub.sh,
# which answers in the same shape TournamentCommands.cpp does -- one ok= line per
# item and then an `equipped=<n> failed=<n>` summary. That shape is the point:
# the applier used to call any `ok=1` anywhere in the reply a success, so a bot
# that got one item of thirteen was recorded in applied.txt and deduped away for
# good, and the viewer who paid for it was never told.
. "$ROOT/tests/fixtures/ctl-stub.sh"

st2="$(mktemp -d)"
export EFFECT_STATE_DIR="$st2"
export CTL_ATTACH_LOG="$st2/attaches"
: > "$CTL_ATTACH_LOG"

attaches() { wc -l < "$CTL_ATTACH_LOG" | tr -d ' '; }

UPG='{"id":"u1","ts":"2026-08-16T21:00:00Z","effect":"upgrade_armor_player","target":{"team":"stormwind-sentinels","slot":"one"},"source":"mock"}'

# 1. A PARTIAL EQUIP IS A FAILURE. One item of twelve went on; the summary says
# failed=11. Both halves asserted together, because a non-zero exit with an
# applied=1 line would still have the consumer record it as done.
CTL_EQUIP_OK=1
OUT="$(effect_apply "$UPG" stormwind-sentinels orgrimmar-warsong 2>/dev/null)"; RC=$?
unset CTL_EQUIP_OK
assert_eq "1|applied=0 failed=1" \
  "$RC|$(printf '%s\n' "$OUT" | grep -o 'applied=[0-9]* failed=[0-9]*')" \
  "a partial equip is reported as a failure, not a success"

# And nothing is recorded: a tier the bot never actually got must not advance the
# ladder, or the retry after a refund would skip straight past it.
assert_eq "0" "$(grep -c 'Wsgaone|armor|' "$st2/tiers.txt" 2>/dev/null || echo 0)" \
  "a partial equip records no tier"

# 2. A clean equip succeeds and the tier it reached is written down.
OUT="$(effect_apply "$UPG" stormwind-sentinels orgrimmar-warsong 2>/dev/null)"; RC=$?
assert_eq "0|applied=1 failed=0" \
  "$RC|$(printf '%s\n' "$OUT" | grep -o 'applied=[0-9]* failed=[0-9]*')" \
  "a full equip succeeds"

assert_eq "Wsgaone|armor|upgrade" "$(tail -1 "$st2/tiers.txt")" \
  "and the tier actually reached is recorded per bot and per half"

# 3. THE SECOND UPGRADE IS NOT A SILENT RE-EQUIP. It used to read the current
# tier from the team's .gearTier, which nothing updates, so it re-sent the tier
# the bot was already wearing and answered ok=1. Now the recorded tier is read
# instead: the warrior-tank fixture has nothing above `upgrade`, so this is a
# distinct refusal with no command sent at all.
before="$(attaches)"
ERR="$(effect_apply "$UPG" stormwind-sentinels orgrimmar-warsong 2>&1 >/dev/null)"; RC=$?
assert_contains "$ERR" "already_top_tier(upgrade)" \
  "a second upgrade on the same bot reports the tier it stopped at"

assert_eq "$before" "$(attaches)" \
  "and sends no equip at all -- never the same tier a second time"

# 4. ONE ATTACH FOR TEN TARGETS. mangosd reads console EOF as "shut down the
# world", so ten attaches for one heal_team was ten chances to do exactly that;
# gear-apply.sh and roster.sh both batch, and this is the assertion that says so.
before="$(attaches)"
HEALTEAM='{"id":"h1","ts":"2026-08-16T21:00:00Z","effect":"heal_team","target":{"team":"stormwind-sentinels"},"source":"mock"}'
OUT="$(effect_apply "$HEALTEAM" stormwind-sentinels orgrimmar-warsong 2>/dev/null)"; RC=$?
assert_eq "1" "$(( $(attaches) - before ))" \
  "a _team effect opens exactly ONE console attach for all ten targets"

assert_eq "0|applied=10 failed=0" \
  "$RC|$(printf '%s\n' "$OUT" | grep -o 'applied=[0-9]* failed=[0-9]*')" \
  "and all ten targets are still judged individually from that one reply"

# 5. THE SAME HOLDS WITH NO STATE DIR AT ALL. effect_tier_file's fallback used
# to mktemp into a variable, but every reader reaches it through a command
# substitution, so the assignment died with the subshell and each call got a
# fresh empty record -- two upgrade_armor_player on one bot both answered
# applied=1, re-equipping the tier it already wore, which is defect 2 alive in
# the path the comment promised was safe. Asserted here without EFFECT_STATE_DIR
# because that is the only configuration that exercises the fallback.
unset EFFECT_STATE_DIR
TF="$(effect_tier_file)"
assert_eq "$TF" "$(effect_tier_file)" \
  "with no state dir the tier file has ONE path per run, not one per call"

# And the same path when asked for from inside a subshell -- which is where
# every read of the record actually happens.
assert_eq "$TF" "$( ( effect_tier_file ) )" \
  "and a subshell resolves it to that same path"

rm -f "$TF"
NOSTATE='{"id":"u2","ts":"2026-08-16T21:00:00Z","effect":"upgrade_armor_player","target":{"team":"stormwind-sentinels","slot":"one"},"source":"mock"}'
OUT="$(effect_apply "$NOSTATE" stormwind-sentinels orgrimmar-warsong 2>/dev/null)"; RC=$?
assert_eq "0|applied=1 failed=0" \
  "$RC|$(printf '%s\n' "$OUT" | grep -o 'applied=[0-9]* failed=[0-9]*')" \
  "the first upgrade with no state dir still succeeds"

before="$(attaches)"
ERR="$(effect_apply "$NOSTATE" stormwind-sentinels orgrimmar-warsong 2>&1 >/dev/null)"; RC=$?
assert_contains "$ERR" "already_top_tier(upgrade)" \
  "and the second one is refused, not silently re-equipped, with no state dir"

assert_eq "$before" "$(attaches)" \
  "and it sends no equip either"

rm -f "$TF"
unset CTL_ATTACH_LOG
rm -rf "$st2"

assert_summary
