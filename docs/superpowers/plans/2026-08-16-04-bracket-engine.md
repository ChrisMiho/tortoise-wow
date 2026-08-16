# Bracket Engine & Tournament Runner — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run a whole tournament unattended — teams swap in, play, a winner is
recorded, the bracket advances — and survive a mangosd restart mid-run.

**Architecture:** A bracket is JSON. Run state is a separate JSON file written after
**every** state change, so a crash resumes rather than restarts. One match is one
invocation of `match-run.sh`; the tournament driver is a loop over pairings that
calls it. Only the two teams playing are ever logged in.

**Tech Stack:** Bash (WSL), `jq`, the `.tournament` control plane, `wsg_mysql`.

**Spec:** `docs/superpowers/specs/2026-08-16-bot-tournament-design.md` (§2.3, §4.3)

**Depends on:** `2026-08-16-01-team-definitions-and-rosters.md`,
`2026-08-16-02-tournament-control-plane.md`,
`2026-08-16-03-gear-loadouts.md`.

## Global Constraints

- **Cross-faction only.** Every match pairs one Alliance team against one Horde
  team. The two-ladder structure exists to guarantee that without any faction
  manipulation — see spec §2.2 for why a faction override is off the table.
- **A match lasts at most 20 minutes** (`BattleGround.cpp:317-323`, custom to this
  server) and bot matches frequently run the full clock. The runner must treat "the
  clock expired" as a normal outcome with a defined result, not a hang.
- **Only 20 tournament bots online at a time.** Log the previous pairing out before
  logging the next in.
- **Write state to disk after every change.** Overnight runs on this host die to
  Windows Update; a run that only persists at the end loses everything.
- **`characters.map` lags reality by up to 60 s** (`PlayerSave.Interval`). Never
  conclude a match ended from a single stale read; and expect phantom `map=489`
  rows for a minute or two after any restart.
- Never party a bot to a GM — `HasActivePlayerMaster()` is a hard gate in the bot's
  queue logic (`BattleGroundJoinAction.cpp:568`).

---

## Assembly depends on a Plan 02 measurement

`match-run.sh` needs one step — "put both teams into this instance" — whose
implementation depends on what
`2026-08-16-02-tournament-control-plane.md` Task 3 **measured**:

| Measured outcome | Assembly step |
|---|---|
| Bots ack world ports (`members count` rose) | `tournament create` then `tournament add` per bot |
| Bots do not ack | `wsg_bgjoin_lines` — set each bot's `bg type` to 2 and issue `bg join`, then read the popped instance id out of `bg.log` |

Task 3 below builds **both** behind one function so the rest of the runner does not
care which is in use. Read
`docs/playerbots/TOURNAMENT-CONTROL-PLANE.md` before implementing it and set the
default to whichever was measured to work.

---

## File Structure

| File | Responsibility |
|---|---|
| `config/tournament/brackets/wsg-open.json` (create) | The shipped bracket definition |
| `scripts/tournament/lib/bracket.sh` (create) | Load, validate, and compute pairings |
| `scripts/tournament/lib/state.sh` (create) | Read/write run state atomically |
| `scripts/tournament/match-run.sh` (create) | Run exactly one match, end to end |
| `scripts/tournament/tournament-run.sh` (create) | Drive a whole bracket, resumable |
| `tests/tournament/bracket.test.sh` (create) | Pairing and validation tests |
| `tests/tournament/state.test.sh` (create) | Persistence and resume tests |

---

### Task 1: Bracket definition and pairing logic

**Files:**
- Create: `config/tournament/brackets/wsg-open.json`
- Create: `scripts/tournament/lib/bracket.sh`
- Test: `tests/tournament/bracket.test.sh`

**Interfaces:**
- Produces:
  - `bracket_validate <bracket-id>` → exit 0 if valid, else print faults
  - `bracket_ladder <bracket-id> <A|H>` → team ids, seed order, one per line
  - `bracket_pairings <bracket-id> <allianceSurvivors> <hordeSurvivors>` →
    `allianceTeam|hordeTeam` lines for one round, given two space-separated
    survivor lists
  - `bracket_rounds <bracket-id>` → the number of rounds implied by ladder size

- [ ] **Step 1: Write the failing test**

```bash
# tests/tournament/bracket.test.sh
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
. "$HERE/../lib/assert.sh"
. "$ROOT/scripts/tournament/lib/bracket.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
export BRACKET_DIR="$ROOT/config/tournament/brackets"

assert_exit 0 "the shipped bracket validates" -- bracket_validate wsg-open
assert_eq "2" "$(bracket_ladder wsg-open A | wc -l | tr -d ' ')" "alliance ladder size"
assert_eq "2" "$(bracket_ladder wsg-open H | wc -l | tr -d ' ')" "horde ladder size"
assert_eq "1" "$(bracket_rounds wsg-open)" "two-team ladders imply one round"

# Positional pairing: nth alliance survivor plays nth horde survivor. Every
# pairing is cross-faction by construction, which is the whole point.
P="$(bracket_pairings wsg-open "alpha beta" "gamma delta")"
assert_eq "alpha|gamma" "$(printf '%s\n' "$P" | head -1)" "first pairing"
assert_eq "beta|delta"  "$(printf '%s\n' "$P" | tail -1)" "second pairing"
assert_eq "2" "$(printf '%s\n' "$P" | wc -l | tr -d ' ')" "one pairing per surviving pair"

# Unequal ladders cannot produce cross-faction pairings for every team.
assert_exit 1 "unequal survivor lists are rejected" -- bracket_pairings wsg-open "alpha beta" "gamma"

tmp="$(mktemp -d)"; export BRACKET_DIR="$tmp"
jq '.allianceLadder = ["a","b","c"] | .hordeLadder = ["d","e","f"]' \
   "$ROOT/config/tournament/brackets/wsg-open.json" > "$tmp/notpow2.json"
assert_exit 1 "a non-power-of-two ladder is rejected" -- bracket_validate notpow2
assert_contains "$(bracket_validate notpow2 2>&1)" "power of two" "and says why"

jq '.hordeLadder = ["d"]' "$ROOT/config/tournament/brackets/wsg-open.json" > "$tmp/lopsided.json"
assert_exit 1 "ladders of different lengths are rejected" -- bracket_validate lopsided
rm -rf "$tmp"

assert_summary
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/tournament/bracket.test.sh`
Expected: FAIL — `scripts/tournament/lib/bracket.sh: No such file or directory`

- [ ] **Step 3: Write the bracket file**

`config/tournament/brackets/wsg-open.json`:

```json
{
  "id": "wsg-open",
  "displayName": "WSG Open",
  "battleground": "WS",
  "bgTypeId": 2,
  "level": 60,
  "allianceLadder": ["stormwind-sentinels", "ironforge-anvils"],
  "hordeLadder":    ["orgrimmar-warsong",   "thunderbluff-braves"]
}
```

Two teams per ladder is one round — the smallest thing that is still a bracket, and
it exercises every mechanism. `ironforge-anvils` and `thunderbluff-braves` do not
exist yet; Task 5 creates them. Until then `bracket_validate` will report them
missing, which is correct.

- [ ] **Step 4: Write the library**

```bash
#!/usr/bin/env bash
# Bracket definitions and pairing. Source, don't execute.
#
# Every WSG match must be Alliance vs Horde: SetBGTeam controls scoring and spawn
# side but not hostility (Unit.cpp:5189), so a same-faction match is bots refusing
# to fight. The bracket is therefore two mirrored ladders whose survivors meet
# positionally at every round -- the nth alliance survivor plays the nth horde
# survivor -- which makes every pairing cross-faction by construction rather than
# by luck.

BRACKET_DIR="${BRACKET_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/config/tournament/brackets}"

bracket_file() { # <bracket-id>
    local f="$BRACKET_DIR/$1.json"
    [ -f "$f" ] || { echo "no such bracket: $1 (looked in $BRACKET_DIR)" >&2; return 1; }
    printf '%s\n' "$f"
}

bracket_field() { # <bracket-id> <jq-path>
    local f; f="$(bracket_file "$1")" || return 1
    jq -r "$2" < "$f"
}

bracket_ladder() { # <bracket-id> <A|H>
    local f key; f="$(bracket_file "$1")" || return 1
    case "$2" in
        A) key='.allianceLadder' ;;
        H) key='.hordeLadder' ;;
        *) echo "bracket_ladder: faction must be A or H" >&2; return 1 ;;
    esac
    jq -r "$key[]" < "$f"
}

# log2 of the ladder size: 2 teams -> 1 round, 4 -> 2, 8 -> 3.
bracket_rounds() { # <bracket-id>
    local n=0 size
    size="$(bracket_ladder "$1" A | wc -l | tr -d ' ')"
    while [ "$size" -gt 1 ]; do size=$((size / 2)); n=$((n + 1)); done
    printf '%s\n' "$n"
}

bracket_pairings() { # <bracket-id> "<alliance survivors>" "<horde survivors>"
    local a h
    read -r -a a <<< "$2"
    read -r -a h <<< "$3"
    if [ "${#a[@]}" -ne "${#h[@]}" ]; then
        echo "bracket_pairings: ${#a[@]} alliance vs ${#h[@]} horde survivors — every match must be cross-faction, so the ladders must stay equal" >&2
        return 1
    fi
    if [ "${#a[@]}" -eq 0 ]; then
        echo "bracket_pairings: no survivors given" >&2
        return 1
    fi
    local i
    for i in "${!a[@]}"; do
        printf '%s|%s\n' "${a[$i]}" "${h[$i]}"
    done
}

bracket_validate() { # <bracket-id>
    local f faults=0 na nh id t
    f="$(bracket_file "$1")" || return 1
    jq -e . < "$f" >/dev/null 2>&1 || { echo "$1: not valid JSON" >&2; return 1; }

    id="$(jq -r '.id // ""' < "$f")"
    [ "$id" = "$1" ] || { echo "$1: .id is '$id', must match the filename" >&2; faults=1; }

    na="$(bracket_ladder "$1" A | wc -l | tr -d ' ')"
    nh="$(bracket_ladder "$1" H | wc -l | tr -d ' ')"

    if [ "$na" -ne "$nh" ]; then
        echo "$1: allianceLadder has $na teams, hordeLadder has $nh — they must be equal or a round cannot pair every team cross-faction" >&2
        faults=1
    fi

    # Power of two, so every round halves cleanly and no team gets a bye.
    if [ "$na" -lt 1 ] || [ $(( na & (na - 1) )) -ne 0 ]; then
        echo "$1: ladder size $na must be a power of two" >&2
        faults=1
    fi

    # Teams must exist and sit on the faction their ladder claims.
    if command -v team_validate >/dev/null 2>&1; then
        while IFS= read -r t; do
            if ! team_validate "$t" >/dev/null 2>&1; then
                echo "$1: alliance ladder references '$t', which does not exist or does not validate" >&2
                faults=1
            elif [ "$(team_field "$t" '.faction')" != "A" ]; then
                echo "$1: '$t' is in the alliance ladder but its faction is not A" >&2
                faults=1
            fi
        done < <(bracket_ladder "$1" A)

        while IFS= read -r t; do
            if ! team_validate "$t" >/dev/null 2>&1; then
                echo "$1: horde ladder references '$t', which does not exist or does not validate" >&2
                faults=1
            elif [ "$(team_field "$t" '.faction')" != "H" ]; then
                echo "$1: '$t' is in the horde ladder but its faction is not H" >&2
                faults=1
            fi
        done < <(bracket_ladder "$1" H)
    fi

    return "$faults"
}
```

- [ ] **Step 5: Run it to verify it passes**

Run: `bash tests/tournament/bracket.test.sh`
Expected: `9 passed, 0 failed`, exit 0.

The `bracket_validate wsg-open` case passes because `team_validate` is not sourced
in this test file, so the team-existence check is skipped — that guard is
deliberate, and Task 5 exercises the full path once all four teams exist.

- [ ] **Step 6: Commit**

```bash
git add config/tournament/brackets scripts/tournament/lib/bracket.sh tests/tournament/bracket.test.sh
git commit -m "feat(tournament): bracket definitions and cross-faction pairing"
```

---

### Task 2: Run state that survives a crash

**Files:**
- Create: `scripts/tournament/lib/state.sh`
- Test: `tests/tournament/state.test.sh`

**Interfaces:**
- Produces:
  - `state_init <run-dir> <bracket-id>` — create the run directory and initial state
  - `state_get <run-dir> <jq-path>` — read one field
  - `state_set <run-dir> <jq-expression>` — apply a jq mutation **atomically**
  - `state_record_result <run-dir> <round> <allianceTeam> <hordeTeam> <winner>` —
    append a match result and recompute survivors
  - `state_survivors <run-dir> <A|H>` — current survivors, space separated

- [ ] **Step 1: Write the failing test**

```bash
# tests/tournament/state.test.sh
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
. "$HERE/../lib/assert.sh"
. "$ROOT/scripts/tournament/lib/state.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

run="$(mktemp -d)/run1"
state_init "$run" wsg-open "swa swb" "hoa hob"

assert_eq "wsg-open" "$(state_get "$run" '.bracketId')" "records the bracket"
assert_eq "1"        "$(state_get "$run" '.round')"     "starts at round 1"
assert_eq "swa swb"  "$(state_survivors "$run" A)"      "seeds alliance survivors"

state_record_result "$run" 1 swa hoa ALLIANCE
assert_eq "swa" "$(state_survivors "$run" A)" "alliance winner survives"
assert_eq ""    "$(state_survivors "$run" H)" "horde loser is eliminated"

state_record_result "$run" 1 swb hob HORDE
assert_eq "swa" "$(state_survivors "$run" A)" "alliance list unchanged by a horde win"
assert_eq "hob" "$(state_survivors "$run" H)" "horde winner survives"
assert_eq "2"   "$(state_get "$run" '.results | length')" "both results recorded"

# A draw eliminates nobody, which would deadlock the bracket -- it must be
# recorded but flagged, never silently advanced.
state_record_result "$run" 1 swa hob NONE
assert_eq "3" "$(state_get "$run" '.results | length')" "a draw is still recorded"
assert_eq "1" "$(state_get "$run" '[.results[] | select(.winner=="NONE")] | length')" "draw is queryable"

# Resume: a fresh read of the same directory sees everything.
assert_eq "swa" "$(state_survivors "$run" A)" "state survives re-read"
assert_exit 0 "state_init on an existing run is a no-op" -- state_init "$run" wsg-open "x" "y"
assert_eq "wsg-open" "$(state_get "$run" '.bracketId')" "and does not clobber it"

rm -rf "$run"
assert_summary
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/tournament/state.test.sh`
Expected: FAIL — `scripts/tournament/lib/state.sh: No such file or directory`

- [ ] **Step 3: Write the library**

```bash
#!/usr/bin/env bash
# Tournament run state. Source, don't execute.
#
# Written to disk after EVERY change, via write-to-temp-then-rename so a kill
# between the two never leaves a truncated file. Overnight runs on this host die
# to Windows Update; a run that only persists at the end loses the whole night.

state_file() { printf '%s/state.json\n' "$1"; }

# Idempotent: re-running on an existing run resumes it rather than resetting it.
# The resume path is the one that matters, so it is the default.
state_init() { # <run-dir> <bracket-id> "<alliance seeds>" "<horde seeds>"
    local dir="$1" bracket="$2" a="$3" h="$4" f
    mkdir -p "$dir"
    f="$(state_file "$dir")"
    [ -f "$f" ] && return 0

    jq -n --arg b "$bracket" --arg a "$a" --arg h "$h" '{
        bracketId: $b,
        round: 1,
        status: "running",
        survivors: { A: ($a | split(" ") | map(select(. != ""))),
                     H: ($h | split(" ") | map(select(. != ""))) },
        results: []
    }' > "$f.tmp" && mv "$f.tmp" "$f"
}

state_get() { # <run-dir> <jq-path>
    jq -r "$2" < "$(state_file "$1")"
}

# Atomic: temp file then rename. A partial write here is a corrupt run that
# cannot be resumed, which defeats the point of persisting at all.
state_set() { # <run-dir> <jq-expression>
    local f; f="$(state_file "$1")"
    jq "$2" < "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

state_survivors() { # <run-dir> <A|H>
    jq -r --arg s "$2" '.survivors[$s] | join(" ")' < "$(state_file "$1")"
}

# Records the match and eliminates the loser. A NONE (draw) result eliminates
# nobody: the 20-minute cap makes scoreless draws common, and silently advancing
# one side would fabricate a winner. The driver decides what to do about it.
state_record_result() { # <run-dir> <round> <allianceTeam> <hordeTeam> <winner>
    local dir="$1" round="$2" ateam="$3" hteam="$4" winner="$5"

    state_set "$dir" "$(cat <<JQ
.results += [{
    round: ($round | tonumber),
    alliance: "$ateam",
    horde: "$hteam",
    winner: "$winner",
    recordedRound: .round
}]
| if "$winner" == "ALLIANCE" then
      .survivors.H |= map(select(. != "$hteam"))
  elif "$winner" == "HORDE" then
      .survivors.A |= map(select(. != "$ateam"))
  else . end
JQ
)"
}

state_advance_round() { # <run-dir>
    state_set "$1" '.round += 1'
}

state_finish() { # <run-dir> <status>
    state_set "$1" ".status = \"$2\""
}
```

Note `$round | tonumber` — a shell-interpolated number still arrives as a JSON
string through `jq`'s program text unless converted, and a string round number
breaks any later numeric comparison.

- [ ] **Step 4: Run it to verify it passes**

Run: `bash tests/tournament/state.test.sh`
Expected: `10 passed, 0 failed`, exit 0

- [ ] **Step 5: Commit**

```bash
git add scripts/tournament/lib/state.sh tests/tournament/state.test.sh
git commit -m "feat(tournament): crash-resumable run state"
```

---

### Task 3: `match-run.sh` — one match, end to end

**Files:**
- Create: `scripts/tournament/match-run.sh`

**Interfaces:**
- Consumes: `roster.sh`, `gear-audit.sh`, `ctl.sh`, `team.sh`.
- Produces: `match-run.sh <allianceTeam> <hordeTeam> [--run-dir <dir>]` →
  a final line `MATCH alliance=<t> horde=<t> winner=<ALLIANCE|HORDE|NONE> instance=<id> duration=<s>`.
  Exit 0 on a completed match (including a draw), 1 if the match could not be run.

- [ ] **Step 1: Read the Plan 02 measurement first**

Open `docs/playerbots/TOURNAMENT-CONTROL-PLANE.md` and find the
"World-port acknowledgement — measured" section. Set `ASSEMBLE_MODE` in Step 2 to
`direct` if bots acked, `queue` if they did not. **Do not guess** — the fallback
exists precisely because this is not knowable from the source.

- [ ] **Step 2: Write the script**

```bash
#!/usr/bin/env bash
# Run exactly one tournament match, end to end.
#
#   ./scripts/tournament/match-run.sh <allianceTeam> <hordeTeam> [--run-dir <dir>]
#
# Sequence: swap rosters -> gear gate -> assemble -> start -> monitor -> result
# -> log out. One invocation is one match; it never starts a second.
#
# Exit 0 = a match completed and a result was determined (a draw counts).
# Exit 1 = the match could not be run at all.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/lib/team.sh"
. "$HERE/lib/ctl.sh"
# shellcheck source=/dev/null
. "$ROOT/docs/playerbots/wsg/lib/wsg-bots-common.sh"

ATEAM="${1:-}"; HTEAM="${2:-}"
[ -n "$ATEAM" ] && [ -n "$HTEAM" ] || { echo "usage: match-run.sh <allianceTeam> <hordeTeam> [--run-dir <dir>]" >&2; exit 2; }
shift 2
RUN_DIR="${WSG_RUN_ROOT:-$ROOT/logs/tournament/adhoc}"
[ "${1:-}" = "--run-dir" ] && RUN_DIR="$2"
mkdir -p "$RUN_DIR"

BG_TYPE=2          # BATTLEGROUND_WS (SharedDefines.h:1746)
LEVEL=60
# The server hard-caps a match at 20 minutes (BattleGround.cpp:317-323). Allow
# the cap plus cleanup before declaring the match stuck rather than merely long.
MATCH_DEADLINE=1500

# Set from the Plan 02 measurement in docs/playerbots/TOURNAMENT-CONTROL-PLANE.md.
ASSEMBLE_MODE="${ASSEMBLE_MODE:-direct}"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$RUN_DIR/match.log"; }

team_validate "$ATEAM" || exit 1
team_validate "$HTEAM" || exit 1
[ "$(team_field "$ATEAM" '.faction')" = "A" ] || { echo "FATAL: $ATEAM is not an Alliance team" >&2; exit 1; }
[ "$(team_field "$HTEAM" '.faction')" = "H" ] || { echo "FATAL: $HTEAM is not a Horde team" >&2; exit 1; }

# --- 1. swap rosters ---------------------------------------------------------
# Everything else logs out first: only the two playing teams may be online.
log "logging out every other team"
for f in "$ROOT"/config/tournament/teams/*.json; do
    t="$(basename "$f" .json)"
    [ "$t" = "$ATEAM" ] || [ "$t" = "$HTEAM" ] && continue
    "$HERE/roster.sh" logout "$t" >/dev/null 2>&1 || true
done

log "bringing $ATEAM and $HTEAM online"
"$HERE/roster.sh" ensure "$ATEAM" || exit 1
"$HERE/roster.sh" ensure "$HTEAM" || exit 1
"$HERE/roster.sh" login  "$ATEAM" || exit 1
"$HERE/roster.sh" login  "$HTEAM" || exit 1

# --- 2. gear gate ------------------------------------------------------------
# A half-dressed team is a rigged match. Fix it before playing, not after.
for t in "$ATEAM" "$HTEAM"; do
    if ! "$HERE/gear-audit.sh" "$t" >> "$RUN_DIR/gear.log" 2>&1; then
        log "$t has gear holes — applying its tier"
        "$HERE/gear-apply.sh" team "$t" >> "$RUN_DIR/gear.log" 2>&1 || true
        if ! "$HERE/gear-audit.sh" "$t" >> "$RUN_DIR/gear.log" 2>&1; then
            log "FATAL: $t is still incomplete after re-gearing — see $RUN_DIR/gear.log"
            exit 1
        fi
    fi
done

# --- 3. assemble -------------------------------------------------------------
assemble_direct() {
    local inst nm
    inst="$(ctl_create "$BG_TYPE" "$LEVEL")" || return 1
    log "instance $inst created"
    for nm in $(team_names "$ATEAM") $(team_names "$HTEAM"); do
        ctl "tournament add $inst $nm" >> "$RUN_DIR/assemble.log"
    done
    sleep 20
    local held; held="$(ctl_field "$(ctl "tournament members $inst")" count)"
    log "instance $inst holds ${held:-0} players"
    # Below a full 20 the match is not the match the bracket asked for.
    [ "${held:-0}" -ge 20 ] || { log "FATAL: only ${held:-0}/20 players entered"; return 1; }
    printf '%s\n' "$inst"
}

assemble_queue() {
    # The proven path: set each bot's `bg type` to WSG and command a join.
    # BGJoinAction::Execute reads AI_VALUE(uint32, "bg type") and skips bgList
    # entirely when it is non-zero.
    local lines names
    names="$(team_names "$ATEAM") $(team_names "$HTEAM")"
    # shellcheck disable=SC2086
    lines="$(wsg_bgjoin_lines $names)"
    wsg_console "$lines" 25 >/dev/null

    # The pop shows up in bg.log as "[489,<instance>]: <name> ... enters".
    local deadline=$(( $(date +%s) + 180 )) inst=""
    while [ -z "$inst" ]; do
        inst="$(tail -200 "$HOME/tortoise-wow-server-V2/logs/bg.log" \
                | grep -a "\[489," | tail -1 \
                | sed -n 's/.*\[489,\([0-9]*\)\].*/\1/p')"
        [ -n "$inst" ] && break
        [ "$(date +%s)" -lt "$deadline" ] || { log "FATAL: no WSG pop within 180s"; return 1; }
        sleep 10
    done
    log "queue popped instance $inst"
    printf '%s\n' "$inst"
}

log "assembling ($ASSEMBLE_MODE)"
if [ "$ASSEMBLE_MODE" = "queue" ]; then
    INST="$(assemble_queue)" || exit 1
else
    INST="$(assemble_direct)" || exit 1
fi

# --- 4. start ----------------------------------------------------------------
ctl "tournament start $INST" >> "$RUN_DIR/match.log"
START_TS=$(date +%s)
log "match started, instance $INST"

# --- 5. monitor --------------------------------------------------------------
# Poll the result rather than the clock. A finished battleground is destroyed, so
# `result error=no_such_instance` is the normal way a match ends -- at which
# point the score has to come from the log line the server already wrote.
WINNER=""
while :; do
    out="$(ctl "tournament result $INST")"
    err="$(ctl_field "$out" error)"
    if [ -z "$err" ]; then
        st="$(ctl_field "$out" status)"
        w="$(ctl_field "$out" winner)"
        printf '%s\n' "$out" >> "$RUN_DIR/match.log"
        if [ "$st" = "WaitLeave" ] && [ -n "$w" ]; then
            WINNER="$w"; break
        fi
    else
        # Instance gone: read the winner out of bg.log's "[<type>,<inst>]:
        # winner=<n>" line. 0=HORDE 1=ALLIANCE 2=draw (BattleGround.h:187-189).
        code="$(grep -a "\[$BG_TYPE,$INST\]: winner=" "$HOME/tortoise-wow-server-V2/logs/bg.log" \
                | tail -1 | sed -n 's/.*winner=\([0-9]*\).*/\1/p')"
        case "${code:-}" in
            0) WINNER="HORDE" ;;
            1) WINNER="ALLIANCE" ;;
            2) WINNER="NONE" ;;
            *) WINNER="NONE" ;;
        esac
        break
    fi

    if [ $(( $(date +%s) - START_TS )) -ge "$MATCH_DEADLINE" ]; then
        log "match exceeded ${MATCH_DEADLINE}s — stopping it"
        ctl "tournament stop $INST" >> "$RUN_DIR/match.log"
        WINNER="NONE"
        break
    fi
    sleep 30
done

DURATION=$(( $(date +%s) - START_TS ))

# --- 6. log out --------------------------------------------------------------
"$HERE/roster.sh" logout "$ATEAM" >/dev/null 2>&1 || true
"$HERE/roster.sh" logout "$HTEAM" >/dev/null 2>&1 || true

printf 'MATCH alliance=%s horde=%s winner=%s instance=%s duration=%s\n' \
    "$ATEAM" "$HTEAM" "$WINNER" "$INST" "$DURATION" | tee -a "$RUN_DIR/match.log"
exit 0
```

- [ ] **Step 3: Run one real match**

```bash
./scripts/validate-stack.sh --image tortoise-cm:local --keep-up
./scripts/tournament/match-run.sh stormwind-sentinels orgrimmar-warsong \
  --run-dir logs/tournament/smoke
```

Expected: a `MATCH ... winner=<ALLIANCE|HORDE|NONE> instance=<n> duration=<s>` line
within ~25 minutes, and `logs/tournament/smoke/match.log` containing the whole
sequence.

**`winner=NONE` after a full 20 minutes is a legitimate result, not a failure** —
bot matches frequently run the clock out. What must not happen is the script
hanging or exiting without a `MATCH` line.

- [ ] **Step 4: Commit**

```bash
git add scripts/tournament/match-run.sh
git commit -m "feat(tournament): match-run.sh runs one match end to end

First live run: <paste the MATCH line>"
```

---

### Task 4: `tournament-run.sh` — drive the bracket, resumably

**Files:**
- Create: `scripts/tournament/tournament-run.sh`

**Interfaces:**
- Consumes: `bracket.sh`, `state.sh`, `match-run.sh`.
- Produces: `tournament-run.sh <bracket-id> [--run-dir <dir>] [--resume]` →
  runs every round to a champion, writing state after each match. Final line:
  `TOURNAMENT-RUN bracket=<id> champion=<team-id> rounds=<n>` or
  `TOURNAMENT-RUN bracket=<id> status=<blocked|failed> reason=<text>`.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Drive a whole bracket. Resumable: state is written after every match, so a
# reboot mid-tournament costs one match, not the night.
#
#   ./scripts/tournament/tournament-run.sh wsg-open
#   ./scripts/tournament/tournament-run.sh wsg-open --run-dir logs/tournament/friday
#
# Re-running against an existing run directory resumes it.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/lib/team.sh"
. "$HERE/lib/bracket.sh"
. "$HERE/lib/state.sh"

BRACKET="${1:-}"
[ -n "$BRACKET" ] || { echo "usage: tournament-run.sh <bracket-id> [--run-dir <dir>]" >&2; exit 2; }
shift
RUN_DIR="$ROOT/logs/tournament/$BRACKET"
[ "${1:-}" = "--run-dir" ] && RUN_DIR="$2"

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is not installed" >&2; exit 2; }
bracket_validate "$BRACKET" || { echo "FATAL: bracket does not validate" >&2; exit 1; }

state_init "$RUN_DIR" "$BRACKET" \
    "$(bracket_ladder "$BRACKET" A | tr '\n' ' ')" \
    "$(bracket_ladder "$BRACKET" H | tr '\n' ' ')"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$RUN_DIR/tournament.log"; }
log "run directory: $RUN_DIR"

# Already-played pairings are skipped on resume. Matching on the pair rather than
# a match index means a partially-completed round resumes correctly.
already_played() { # <alliance> <horde>
    local n
    n="$(state_get "$RUN_DIR" "[.results[] | select(.alliance==\"$1\" and .horde==\"$2\")] | length")"
    [ "${n:-0}" -gt 0 ]
}

total_rounds="$(bracket_rounds "$BRACKET")"

while :; do
    round="$(state_get "$RUN_DIR" '.round')"
    a="$(state_survivors "$RUN_DIR" A)"
    h="$(state_survivors "$RUN_DIR" H)"
    log "round $round: alliance=[$a] horde=[$h]"

    acount="$(printf '%s\n' $a | grep -c . || true)"
    hcount="$(printf '%s\n' $h | grep -c . || true)"

    if [ "$acount" -eq 1 ] && [ "$hcount" -eq 0 ]; then
        state_finish "$RUN_DIR" "complete"
        printf 'TOURNAMENT-RUN bracket=%s champion=%s rounds=%s\n' "$BRACKET" "$a" "$round" | tee -a "$RUN_DIR/tournament.log"
        exit 0
    fi
    if [ "$hcount" -eq 1 ] && [ "$acount" -eq 0 ]; then
        state_finish "$RUN_DIR" "complete"
        printf 'TOURNAMENT-RUN bracket=%s champion=%s rounds=%s\n' "$BRACKET" "$h" "$round" | tee -a "$RUN_DIR/tournament.log"
        exit 0
    fi

    if ! pairings="$(bracket_pairings "$BRACKET" "$a" "$h")"; then
        # Unequal survivor lists mean a draw eliminated nobody, or a team is
        # stranded with no cross-faction opponent. Both need a human.
        state_finish "$RUN_DIR" "blocked"
        printf 'TOURNAMENT-RUN bracket=%s status=blocked reason=uneven_survivors(A=%s,H=%s)\n' \
            "$BRACKET" "$acount" "$hcount" | tee -a "$RUN_DIR/tournament.log"
        exit 1
    fi

    played_any=0
    while IFS='|' read -r ateam hteam; do
        [ -n "$ateam" ] || continue
        if already_played "$ateam" "$hteam"; then
            log "skipping $ateam vs $hteam — already recorded"
            continue
        fi

        log "playing $ateam vs $hteam"
        out="$("$HERE/match-run.sh" "$ateam" "$hteam" --run-dir "$RUN_DIR/r${round}-${ateam}-vs-${hteam}" | tail -1)"
        log "$out"

        winner="$(printf '%s\n' "$out" | sed -n 's/.*winner=\([A-Z]*\).*/\1/p')"
        if [ -z "$winner" ]; then
            state_finish "$RUN_DIR" "failed"
            printf 'TOURNAMENT-RUN bracket=%s status=failed reason=no_result(%s vs %s)\n' \
                "$BRACKET" "$ateam" "$hteam" | tee -a "$RUN_DIR/tournament.log"
            exit 1
        fi

        # Written immediately, before the next match starts. This is the line
        # that makes a reboot cost one match instead of the whole run.
        state_record_result "$RUN_DIR" "$round" "$ateam" "$hteam" "$winner"
        played_any=1

        if [ "$winner" = "NONE" ]; then
            log "WARNING: $ateam vs $hteam was a draw — nobody eliminated. The bracket cannot advance past this without a replay or a human decision."
        fi
    done <<< "$pairings"

    if [ "$played_any" -eq 0 ]; then
        # Every pairing this round is already recorded, so the round is done.
        state_advance_round "$RUN_DIR"
        newround="$(state_get "$RUN_DIR" '.round')"
        if [ "$newround" -gt $(( total_rounds + 1 )) ]; then
            state_finish "$RUN_DIR" "blocked"
            printf 'TOURNAMENT-RUN bracket=%s status=blocked reason=exceeded_expected_rounds\n' "$BRACKET" \
                | tee -a "$RUN_DIR/tournament.log"
            exit 1
        fi
    fi
done
```

- [ ] **Step 2: Prove resume works before running it for real**

Resume is the property that matters overnight, so test it with fabricated state
rather than by killing a real 20-minute match:

```bash
rm -rf /tmp/tr && mkdir -p /tmp/tr
MSYS_NO_PATHCONV=1 bash <<'EOF'
. scripts/tournament/lib/state.sh
state_init /tmp/tr wsg-open "stormwind-sentinels ironforge-anvils" "orgrimmar-warsong thunderbluff-braves"
state_record_result /tmp/tr 1 stormwind-sentinels orgrimmar-warsong ALLIANCE
cat /tmp/tr/state.json
EOF
```

Expected: `results` has one entry, `survivors.H` no longer contains
`orgrimmar-warsong`.

Now run the driver against that directory and confirm it **skips** the recorded
match:

```bash
./scripts/tournament/tournament-run.sh wsg-open --run-dir /tmp/tr 2>&1 | head -20
```

Expected: a line `skipping stormwind-sentinels vs orgrimmar-warsong — already
recorded`, and it proceeds to the other pairing instead of replaying.

- [ ] **Step 3: Commit**

```bash
git add scripts/tournament/tournament-run.sh
git commit -m "feat(tournament): resumable bracket driver"
```

---

### Task 5: The remaining two teams, and a full bracket run

**Files:**
- Create: `config/tournament/teams/ironforge-anvils.json`
- Create: `config/tournament/teams/thunderbluff-braves.json`
- Create: `docs/playerbots/TOURNAMENT-RUNNING.md`

- [ ] **Step 1: Write the two team files**

`ironforge-anvils.json` — Alliance, `namePrefix` `Wsgb`:

```json
{
  "id": "ironforge-anvils",
  "displayName": "Ironforge Anvils",
  "faction": "A",
  "namePrefix": "Wsgb",
  "gearTier": "base",
  "roster": [
    { "slot": "one",   "class": "warrior", "race": "Dwarf",    "role": "tank"   },
    { "slot": "two",   "class": "paladin", "race": "Human",    "role": "tank"   },
    { "slot": "three", "class": "priest",  "race": "Dwarf",    "role": "healer" },
    { "slot": "four",  "class": "druid",   "race": "NightElf", "role": "healer" },
    { "slot": "five",  "class": "mage",    "race": "Human",    "role": "dps"    },
    { "slot": "six",   "class": "warlock", "race": "Gnome",    "role": "dps"    },
    { "slot": "seven", "class": "hunter",  "race": "Dwarf",    "role": "dps"    },
    { "slot": "eight", "class": "rogue",   "race": "NightElf", "role": "dps"    },
    { "slot": "nine",  "class": "warrior", "race": "Human",    "role": "dps"    },
    { "slot": "ten",   "class": "mage",    "race": "Gnome",    "role": "dps"    }
  ]
}
```

`thunderbluff-braves.json` — Horde, `namePrefix` `Wsgi`:

```json
{
  "id": "thunderbluff-braves",
  "displayName": "Thunderbluff Braves",
  "faction": "H",
  "namePrefix": "Wsgi",
  "gearTier": "base",
  "roster": [
    { "slot": "one",   "class": "warrior", "race": "Tauren", "role": "tank"   },
    { "slot": "two",   "class": "druid",   "race": "Tauren", "role": "tank"   },
    { "slot": "three", "class": "priest",  "race": "Troll",  "role": "healer" },
    { "slot": "four",  "class": "shaman",  "race": "Orc",    "role": "healer" },
    { "slot": "five",  "class": "mage",    "race": "Undead", "role": "dps"    },
    { "slot": "six",   "class": "warlock", "race": "Undead", "role": "dps"    },
    { "slot": "seven", "class": "hunter",  "race": "Orc",    "role": "dps"    },
    { "slot": "eight", "class": "rogue",   "race": "Troll",  "role": "dps"    },
    { "slot": "nine",  "class": "warrior", "race": "Orc",    "role": "dps"    },
    { "slot": "ten",   "class": "shaman",  "race": "Tauren", "role": "dps"    }
  ]
}
```

`Wsgb`/`Wsgi` keep every generated name alphabetic and under 12 characters
(`Wsgbthree` is 9, `Wsgieight` is 9). Avoid a prefix ending in a vowel that would
read as a different word when joined to `one`.

- [ ] **Step 2: Validate everything before creating 20 more characters**

```bash
./scripts/tournament/team-validate.sh
MSYS_NO_PATHCONV=1 bash -c '. scripts/tournament/lib/team.sh; . scripts/tournament/lib/bracket.sh; bracket_validate wsg-open && echo BRACKET-OK'
```

Expected: four `ok` lines and `BRACKET-OK`. The bracket check now exercises the
team-existence and faction path that Task 1's unit test deliberately skipped.

- [ ] **Step 3: Create the new rosters and gear them**

```bash
./scripts/tournament/roster.sh ensure ironforge-anvils --login
./scripts/tournament/roster.sh ensure thunderbluff-braves --login
./scripts/tournament/gear-apply.sh team ironforge-anvils
./scripts/tournament/gear-apply.sh team thunderbluff-braves
./scripts/tournament/gear-audit.sh ironforge-anvils
./scripts/tournament/gear-audit.sh thunderbluff-braves
```

Expected: both audits report `complete=10/10`.

Then log them out — only the playing pair may be online:

```bash
./scripts/tournament/roster.sh logout ironforge-anvils
./scripts/tournament/roster.sh logout thunderbluff-braves
```

- [ ] **Step 4: Run the whole bracket**

```bash
./scripts/validate-stack.sh --image tortoise-cm:local --keep-up
./scripts/tournament/tournament-run.sh wsg-open --run-dir logs/tournament/first
```

Expected: two round-1 matches, then a final, ending in
`TOURNAMENT-RUN bracket=wsg-open champion=<team-id> rounds=<n>`.

Budget ~25 minutes per match, so up to ~75 minutes. If a draw blocks the bracket,
the run exits with `status=blocked reason=uneven_survivors` — that is the designed
behaviour, and the fix is a human decision (replay or seed advance), not a code
change. Record which happened.

- [ ] **Step 5: Write the doc**

`docs/playerbots/TOURNAMENT-RUNNING.md`:

```markdown
# Running a tournament

```bash
./scripts/validate-stack.sh --image tortoise-cm:local --keep-up
./scripts/tournament/tournament-run.sh wsg-open --run-dir logs/tournament/friday
```

Re-running the same `--run-dir` **resumes**: every match result is written to
`state.json` the moment it is known, so a reboot mid-tournament costs one match,
not the night. Already-recorded pairings are skipped by pair, not by index, so a
half-finished round resumes correctly.

## Structure

Every WSG match must be Alliance vs Horde, because `SetBGTeam` does not affect
hostility (`Unit.cpp:5189`). So the bracket is two mirrored ladders and the *n*th
alliance survivor plays the *n*th horde survivor each round. Ladders must be equal
in length and a power of two.

## Draws block the bracket, by design

The 20-minute hard cap (`BattleGround.cpp:317-323`) means bot matches often end
0–0. A draw eliminates nobody, so the survivor lists go uneven and the run stops
with `status=blocked reason=uneven_survivors`. That is deliberate — advancing a
side the server did not declare would fabricate a result. Replay the match by
deleting its entry from `state.json` `.results`, or record a decision by hand.

## One match at a time

Only the two playing teams are ever logged in. `match-run.sh` logs every other
team out first, so concurrent population stays at 20 regardless of bracket size.

## Artifacts

```
logs/tournament/<run>/state.json                     the resumable run state
logs/tournament/<run>/tournament.log                 the driver's narration
logs/tournament/<run>/r<N>-<a>-vs-<h>/match.log      one directory per match
logs/tournament/<run>/r<N>-<a>-vs-<h>/gear.log       the gear gate's findings
```
```

- [ ] **Step 6: Commit**

```bash
git add config/tournament/teams docs/playerbots/TOURNAMENT-RUNNING.md
git commit -m "feat(tournament): two more teams and a full bracket run

First tournament: <paste the TOURNAMENT-RUN line>"
```

---

## Done when

- `bash tests/tournament/bracket.test.sh` and `bash tests/tournament/state.test.sh`
  both exit 0.
- `bracket_validate wsg-open` exits 0 with all four teams present, and rejects a
  lopsided or non-power-of-two ladder.
- `match-run.sh` produces a `MATCH ... winner=...` line for a real match.
- `tournament-run.sh` completes a bracket to a champion, or exits `blocked` with a
  stated reason — and re-running against the same run directory demonstrably skips
  matches already recorded.
