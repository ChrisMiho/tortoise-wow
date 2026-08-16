# Team Definitions & Roster Lifecycle — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a team a version-controlled JSON file, and make creating, verifying,
and tearing down its 10 characters a single idempotent command.

**Architecture:** JSON team definitions under `config/tournament/teams/`, validated
by a schema gate that refuses any name a character load would reject. A shell
library reads them with `jq`; a `roster.sh` driver reconciles the definition against
`tw_char.characters` through the mangosd console, and is safe to re-run.

**Tech Stack:** Bash (WSL), `jq`, mangosd console via `docker attach`, MySQL via
`docker exec tcm-db`.

**Spec:** `docs/superpowers/specs/2026-08-16-bot-tournament-design.md` (§4.2)

**Depends on:** `2026-08-16-00-build-provenance-gate.md` (for the test harness in
`tests/lib/`).

## Global Constraints

- **Character names are `^[A-Za-z]+$`, at most 12 characters.** Digits are rejected
  at character *load*, not creation (`Util.h:376-394`); the bot prints
  `"Bot is now online"` before login is even attempted (`PlayerbotMgr.cpp:2505-2506`),
  so a bad name looks like a successful login followed by a mystery disconnect, and
  leaves a permanently broken row with `at_login=1`.
- **`rndbot` console replies go to a null player session and vanish.** Never infer
  success from console output. Verify in `tw_char.characters`, always.
- **Console EOF shuts the world down.** Only send console commands through
  `wsg_console`, which detaches with `ctrl-p,ctrl-q`. Compose is `restart: "no"`.
- **Batch console work into as few attaches as possible.** Forty attaches is forty
  chances to kill the world.
- A bot account holds at most **9 characters** (`PlayerbotMgr.cpp:2325`).
- `at_login` must read `0` after creation. A `1` means the name was rejected and the
  row is unusable — delete it, never reuse it.
- Reuse `docs/playerbots/wsg/lib/wsg-bots-common.sh` (`wsg_mysql`, `wsg_console`)
  rather than reimplementing DB or console access.

---

## File Structure

| File | Responsibility |
|---|---|
| `config/tournament/teams/stormwind-sentinels.json` (create) | The existing Alliance roster, expressed as data |
| `config/tournament/teams/orgrimmar-warsong.json` (create) | The existing Horde roster, expressed as data |
| `scripts/tournament/lib/team.sh` (create) | Load, validate, and expand a team definition |
| `scripts/tournament/team-validate.sh` (create) | Standalone gate: validate every team file, exit non-zero on any fault |
| `scripts/tournament/roster.sh` (create) | `status` / `ensure` / `teardown` for one team |
| `tests/tournament/team.test.sh` (create) | Unit tests for `team.sh`, no server needed |
| `tests/tournament/roster.test.sh` (create) | Tests for `roster.sh` against stubbed console + DB |

---

### Task 1: Team definition files and the validation library

**Files:**
- Create: `config/tournament/teams/stormwind-sentinels.json`
- Create: `config/tournament/teams/orgrimmar-warsong.json`
- Create: `scripts/tournament/lib/team.sh`
- Test: `tests/tournament/team.test.sh`

**Interfaces:**
- Consumes: `jq`.
- Produces:
  - `team_file <team-id>` → absolute path to that team's JSON, exit 1 if absent
  - `team_field <team-id> <jq-path>` → one scalar field
  - `team_names <team-id>` → the 10 character names, one per line, in slot order
  - `team_rows <team-id>` → `name|class|race|role|faction`, one per line (the same
    shape as `wsg-team-roster.txt`, so existing helpers keep working)
  - `team_validate <team-id>` → exit 0 if valid, else print each fault and exit 1

- [ ] **Step 1: Write the failing test**

```bash
# tests/tournament/team.test.sh
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
. "$HERE/../lib/assert.sh"
. "$ROOT/scripts/tournament/lib/team.sh"

require_cmd jq

export TEAM_DIR="$ROOT/config/tournament/teams"

assert_eq "A" "$(team_field stormwind-sentinels '.faction')" "reads faction"
assert_eq "10" "$(team_names stormwind-sentinels | wc -l | tr -d ' ')" "ten names"
assert_eq "Wsgaone" "$(team_names stormwind-sentinels | head -1)" "first name is prefix+slot"
assert_eq "Wsghone" "$(team_names orgrimmar-warsong | head -1)" "horde prefix applies"
assert_contains "$(team_rows stormwind-sentinels | head -1)" "Wsgaone|warrior|Human|tank|A" \
  "rows match the wsg-team-roster.txt shape"

assert_exit 0 "the shipped Alliance team validates" -- team_validate stormwind-sentinels
assert_exit 0 "the shipped Horde team validates"    -- team_validate orgrimmar-warsong

# The regression that cost a full debugging session: a digit in a generated name.
tmp="$(mktemp -d)"; export TEAM_DIR="$tmp"
jq '.namePrefix = "Wsga1"' "$ROOT/config/tournament/teams/stormwind-sentinels.json" \
  > "$tmp/badname.json"
assert_exit 1 "a digit in the name prefix is rejected" -- team_validate badname
assert_contains "$(team_validate badname 2>&1)" "alphabetic" "and says why"

jq '.faction = "H"' "$ROOT/config/tournament/teams/stormwind-sentinels.json" \
  > "$tmp/wrongfaction.json"
assert_exit 1 "faction must agree with the races" -- team_validate wrongfaction

jq 'del(.roster[0])' "$ROOT/config/tournament/teams/stormwind-sentinels.json" \
  > "$tmp/short.json"
assert_exit 1 "a short roster is rejected" -- team_validate short
rm -rf "$tmp"

assert_summary
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/tournament/team.test.sh`
Expected: FAIL — `scripts/tournament/lib/team.sh: No such file or directory`

- [ ] **Step 3: Write the team files**

`config/tournament/teams/stormwind-sentinels.json`:

```json
{
  "id": "stormwind-sentinels",
  "displayName": "Stormwind Sentinels",
  "faction": "A",
  "namePrefix": "Wsga",
  "gearTier": "base",
  "roster": [
    { "slot": "one",   "class": "warrior", "race": "Human",    "role": "tank"   },
    { "slot": "two",   "class": "paladin", "race": "Dwarf",    "role": "tank"   },
    { "slot": "three", "class": "priest",  "race": "Human",    "role": "healer" },
    { "slot": "four",  "class": "druid",   "race": "NightElf", "role": "healer" },
    { "slot": "five",  "class": "mage",    "race": "Gnome",    "role": "dps"    },
    { "slot": "six",   "class": "warlock", "race": "Human",    "role": "dps"    },
    { "slot": "seven", "class": "hunter",  "race": "NightElf", "role": "dps"    },
    { "slot": "eight", "class": "rogue",   "race": "Human",    "role": "dps"    },
    { "slot": "nine",  "class": "warrior", "race": "Dwarf",    "role": "dps"    },
    { "slot": "ten",   "class": "mage",    "race": "Human",    "role": "dps"    }
  ]
}
```

`config/tournament/teams/orgrimmar-warsong.json`:

```json
{
  "id": "orgrimmar-warsong",
  "displayName": "Orgrimmar Warsong",
  "faction": "H",
  "namePrefix": "Wsgh",
  "gearTier": "base",
  "roster": [
    { "slot": "one",   "class": "warrior", "race": "Orc",    "role": "tank"   },
    { "slot": "two",   "class": "druid",   "race": "Tauren", "role": "tank"   },
    { "slot": "three", "class": "priest",  "race": "Undead", "role": "healer" },
    { "slot": "four",  "class": "shaman",  "race": "Troll",  "role": "healer" },
    { "slot": "five",  "class": "mage",    "race": "Undead", "role": "dps"    },
    { "slot": "six",   "class": "warlock", "race": "Orc",    "role": "dps"    },
    { "slot": "seven", "class": "hunter",  "race": "Troll",  "role": "dps"    },
    { "slot": "eight", "class": "rogue",   "race": "Undead", "role": "dps"    },
    { "slot": "nine",  "class": "warrior", "race": "Troll",  "role": "dps"    },
    { "slot": "ten",   "class": "shaman",  "race": "Orc",    "role": "dps"    }
  ]
}
```

These are exactly the 20 bots in `docs/playerbots/wsg/wsg-team-roster.txt`, so the
first tournament match is played by a roster already known to work.

- [ ] **Step 4: Write the library**

```bash
#!/usr/bin/env bash
# Read and validate team definitions. Source, don't execute.
#
# A team is data, not a console transcript. Everything an operator would tweak
# per team lives in config/tournament/teams/<id>.json; this file is the only
# thing that knows its shape.

TEAM_DIR="${TEAM_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/config/tournament/teams}"

# Races legal for each faction. A roster whose races straddle factions cannot
# play as one team, and the failure would only surface as bots on the wrong side
# of a battleground.
TEAM_RACES_A="Human Dwarf NightElf Gnome"
TEAM_RACES_H="Orc Undead Tauren Troll"

TEAM_SLOTS="one two three four five six seven eight nine ten"

team_file() { # <team-id>
    local f="$TEAM_DIR/$1.json"
    [ -f "$f" ] || { echo "no such team: $1 (looked in $TEAM_DIR)" >&2; return 1; }
    printf '%s\n' "$f"
}

team_field() { # <team-id> <jq-path>
    local f; f="$(team_file "$1")" || return 1
    jq -r "$2" < "$f"
}

team_names() { # <team-id>
    local f; f="$(team_file "$1")" || return 1
    jq -r '.namePrefix as $p | .roster[] | $p + .slot' < "$f"
}

# name|class|race|role|faction — deliberately the same shape as
# docs/playerbots/wsg/wsg-team-roster.txt so wsg_load_roster keeps working.
team_rows() { # <team-id>
    local f; f="$(team_file "$1")" || return 1
    jq -r '.namePrefix as $p | .faction as $fac | .roster[]
           | ($p + .slot) + "|" + .class + "|" + .race + "|" + .role + "|" + $fac' < "$f"
}

team_validate() { # <team-id>
    local f faults=0 id faction prefix n races legal
    f="$(team_file "$1")" || return 1

    jq -e . < "$f" >/dev/null 2>&1 || { echo "$1: not valid JSON" >&2; return 1; }

    id="$(jq -r '.id // ""' < "$f")"
    [ "$id" = "$1" ] || { echo "$1: .id is '$id', must match the filename" >&2; faults=1; }

    faction="$(jq -r '.faction // ""' < "$f")"
    case "$faction" in
        A) legal="$TEAM_RACES_A" ;;
        H) legal="$TEAM_RACES_H" ;;
        *) echo "$1: .faction must be A or H, got '$faction'" >&2; return 1 ;;
    esac

    prefix="$(jq -r '.namePrefix // ""' < "$f")"
    # The whole reason this gate exists. A digit here is not a typo, it is a
    # permanently broken character row that looks like a successful login.
    case "$prefix" in
        *[!A-Za-z]*|"") echo "$1: .namePrefix '$prefix' must be alphabetic only — digits are rejected at character load, not creation" >&2; faults=1 ;;
    esac

    n="$(jq -r '.roster | length' < "$f")"
    [ "$n" -eq 10 ] || { echo "$1: roster has $n entries, expected 10" >&2; faults=1; }

    # Slots must be the canonical words, in order, with no repeats: the character
    # name is prefix+slot, so a duplicate slot is a duplicate name and the second
    # create silently fails with "Name already exists".
    local want got
    want="$(printf '%s\n' $TEAM_SLOTS)"
    got="$(jq -r '.roster[].slot' < "$f")"
    [ "$want" = "$got" ] || { echo "$1: slots must be exactly: $TEAM_SLOTS (in order)" >&2; faults=1; }

    while IFS= read -r race; do
        case " $legal " in
            *" $race "*) ;;
            *) echo "$1: race '$race' is not playable by faction $faction" >&2; faults=1 ;;
        esac
    done < <(jq -r '.roster[].race' < "$f")

    while IFS= read -r nm; do
        case "$nm" in
            *[!A-Za-z]*) echo "$1: generated name '$nm' is not alphabetic" >&2; faults=1 ;;
        esac
        [ "${#nm}" -le 12 ] || { echo "$1: generated name '$nm' exceeds 12 characters" >&2; faults=1; }
    done < <(team_names "$1")

    while IFS= read -r role; do
        case "$role" in
            tank|healer|dps) ;;
            *) echo "$1: role '$role' must be tank, healer or dps" >&2; faults=1 ;;
        esac
    done < <(jq -r '.roster[].role' < "$f")

    return "$faults"
}
```

- [ ] **Step 5: Run it to verify it passes**

Run: `bash tests/tournament/team.test.sh`
Expected: `10 passed, 0 failed`, exit 0

- [ ] **Step 6: Commit**

```bash
git add config/tournament/teams scripts/tournament/lib/team.sh tests/tournament/team.test.sh
git commit -m "feat(tournament): team definitions as validated JSON"
```

---

### Task 2: The standalone validation gate

**Files:**
- Create: `scripts/tournament/team-validate.sh`

**Interfaces:**
- Consumes: `team_validate` from `scripts/tournament/lib/team.sh`.
- Produces: `scripts/tournament/team-validate.sh [team-id...]` — validates the named
  teams, or every team in `config/tournament/teams/` when given none. Exit 0 if all
  valid, 1 otherwise.

This exists so every later script can call one thing before touching the server,
and so a bad team file fails in under a second instead of after 10 bot creations.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Validate team definitions. Nothing here touches the server — run it freely.
#
#   ./scripts/tournament/team-validate.sh                    # all teams
#   ./scripts/tournament/team-validate.sh stormwind-sentinels
#
# Exit 0 = every team checked is valid. Exit 1 = at least one fault (printed).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/team.sh"

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is not installed (apt-get install jq)" >&2; exit 2; }

teams=("$@")
if [ "${#teams[@]}" -eq 0 ]; then
    while IFS= read -r f; do
        teams+=("$(basename "$f" .json)")
    done < <(find "$TEAM_DIR" -maxdepth 1 -name '*.json' | sort)
fi

[ "${#teams[@]}" -gt 0 ] || { echo "no team definitions found in $TEAM_DIR" >&2; exit 1; }

rc=0
for t in "${teams[@]}"; do
    if team_validate "$t"; then
        printf 'ok    %s (%s, %s)\n' "$t" "$(team_field "$t" '.faction')" "$(team_field "$t" '.displayName')"
    else
        printf 'FAULT %s\n' "$t"
        rc=1
    fi
done
exit $rc
```

- [ ] **Step 2: Run it against the shipped teams**

Run: `./scripts/tournament/team-validate.sh`
Expected:

```
ok    orgrimmar-warsong (H, Orgrimmar Warsong)
ok    stormwind-sentinels (A, Stormwind Sentinels)
```

exit 0.

- [ ] **Step 3: Prove it actually catches a fault**

```bash
cp config/tournament/teams/stormwind-sentinels.json /tmp/backup.json
jq '.namePrefix = "Wsga1"' /tmp/backup.json > config/tournament/teams/stormwind-sentinels.json
./scripts/tournament/team-validate.sh stormwind-sentinels; echo "exit=$?"
cp /tmp/backup.json config/tournament/teams/stormwind-sentinels.json
```

Expected: a message naming `.namePrefix` and the alphabetic rule, then `exit=1`.
Confirm the file is restored (`./scripts/tournament/team-validate.sh` exits 0).

- [ ] **Step 4: Commit**

```bash
git add scripts/tournament/team-validate.sh
git commit -m "feat(tournament): add team-validate.sh gate"
```

---

### Task 3: Roster status — read the world without changing it

**Files:**
- Create: `scripts/tournament/roster.sh` (the `status` subcommand only)
- Test: `tests/tournament/roster.test.sh`

**Interfaces:**
- Consumes: `team_names`, `team_rows`, and `wsg_mysql` from
  `docs/playerbots/wsg/lib/wsg-bots-common.sh`.
- Produces: `scripts/tournament/roster.sh status <team-id>` printing one line per
  slot — `<name> <exists|missing> <online|offline> <level> <at_login>` — and a
  summary line `ROSTER <team-id> present=<n>/10 online=<n>/10 broken=<n>`.
  Exit 0 always; this command reports, it does not judge.

Status comes first, and alone, because every other subcommand is defined in terms
of it: `ensure` creates what status says is missing, `teardown` removes what status
says is present.

- [ ] **Step 1: Write the failing test**

```bash
# tests/tournament/roster.test.sh
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
. "$HERE/../lib/assert.sh"
. "$HERE/../lib/stub.sh"

require_cmd jq

d="$(stub_dir)"
# Stand in for `docker exec ... mysql -e "<sql>"`. Returns 8 of the 10 bots
# present, one of them broken (at_login=1), two missing entirely.
stub_cmd "$d" docker '
for a in "$@"; do prev="$last"; last="$a"; done
case "$last" in
  *characters*)
    for n in Wsgaone Wsgatwo Wsgathree Wsgafour Wsgafive Wsgasix Wsgaseven; do
      printf "%s\t1\t60\t0\n" "$n"
    done
    printf "Wsgaeight\t0\t60\t1\n"
    ;;
esac
exit 0'

OUT="$(TEAM_DIR="$ROOT/config/tournament/teams" \
       bash "$ROOT/scripts/tournament/roster.sh" status stormwind-sentinels 2>&1)"

assert_contains "$OUT" "present=8/10" "counts present characters"
assert_contains "$OUT" "online=7/10"  "counts online characters"
assert_contains "$OUT" "broken=1"     "counts at_login=1 rows as broken"
assert_contains "$OUT" "Wsganine missing" "names a missing slot"
assert_contains "$OUT" "Wsgaeight" "names the broken slot"

stub_cleanup "$d"
assert_summary
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/tournament/roster.test.sh`
Expected: FAIL — `scripts/tournament/roster.sh: No such file or directory`

- [ ] **Step 3: Write the script**

```bash
#!/usr/bin/env bash
# Reconcile a team definition against the characters that actually exist.
#
#   ./scripts/tournament/roster.sh status <team-id>
#
# `status` is read-only. It is the source of truth for every other subcommand:
# nothing else queries the database directly.
#
# Run from WSL.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/lib/team.sh"
# shellcheck source=/dev/null
. "$ROOT/docs/playerbots/wsg/lib/wsg-bots-common.sh"

usage() { echo "usage: roster.sh status <team-id>" >&2; exit 2; }

cmd="${1:-}"; team="${2:-}"
[ -n "$cmd" ] && [ -n "$team" ] || usage
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is not installed" >&2; exit 2; }

team_validate "$team" || { echo "FATAL: $team does not validate; fix the definition before touching the server" >&2; exit 2; }

roster_status() {
    local names sql rows present=0 online=0 broken=0
    names="$(team_names "$team")"

    # One query for the whole roster. Ten queries is ten round trips and ten
    # chances to read a different instant.
    local inlist=""
    while IFS= read -r n; do
        inlist="$inlist${inlist:+,}'$n'"
    done <<< "$names"

    sql="SELECT name, online, level, at_login FROM tw_char.characters WHERE name IN ($inlist);"
    rows="$(wsg_mysql "$sql")"

    while IFS= read -r n; do
        local row on lvl atl
        row="$(printf '%s\n' "$rows" | awk -v want="$n" -F'\t' '$1 == want {print; exit}')"
        if [ -z "$row" ]; then
            printf '%-14s missing\n' "$n"
            continue
        fi
        present=$((present + 1))
        on="$(printf '%s' "$row"  | cut -f2)"
        lvl="$(printf '%s' "$row" | cut -f3)"
        atl="$(printf '%s' "$row" | cut -f4)"
        [ "$on" = "1" ] && online=$((online + 1))
        # at_login=1 means the name was rejected at load. The row is permanently
        # unusable -- it is not "will come online later", it is garbage.
        if [ "$atl" != "0" ]; then
            broken=$((broken + 1))
            printf '%-14s present %-7s level=%s at_login=%s BROKEN\n' \
                "$n" "$([ "$on" = 1 ] && echo online || echo offline)" "$lvl" "$atl"
        else
            printf '%-14s present %-7s level=%s\n' \
                "$n" "$([ "$on" = 1 ] && echo online || echo offline)" "$lvl"
        fi
    done <<< "$names"

    printf 'ROSTER %s present=%d/10 online=%d/10 broken=%d\n' "$team" "$present" "$online" "$broken"
}

case "$cmd" in
    status) roster_status ;;
    *)      usage ;;
esac
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bash tests/tournament/roster.test.sh`
Expected: `5 passed, 0 failed`, exit 0

- [ ] **Step 5: Run it against the real server**

Run: `./scripts/tournament/roster.sh status stormwind-sentinels`
Expected: 10 lines plus a `ROSTER` summary. If the existing 20-bot roster is
intact this reads `present=10/10 broken=0`. Record the actual output — a
`broken=` count above zero is a real finding about the current world.

- [ ] **Step 6: Commit**

```bash
git add scripts/tournament/roster.sh tests/tournament/roster.test.sh
git commit -m "feat(tournament): roster.sh status reconciles a team against the DB"
```

---

### Task 4: Roster ensure — create what is missing, idempotently

**Files:**
- Modify: `scripts/tournament/roster.sh` (add the `ensure` subcommand)
- Modify: `tests/tournament/roster.test.sh` (add ensure cases)

**Interfaces:**
- Consumes: `roster_status` output from Task 3, `wsg_console`.
- Produces: `scripts/tournament/roster.sh ensure <team-id> [--login]` — creates every
  missing character, refuses to touch broken rows, and re-runs safely. Exit 0 when
  the roster reads `present=10/10 broken=0` afterwards, 1 otherwise.

- [ ] **Step 1: Write the failing test**

Append to `tests/tournament/roster.test.sh`, before `assert_summary`:

```bash
# --- ensure ---------------------------------------------------------------
d2="$(stub_dir)"
CALLS="$(mktemp)"
# Record what gets sent to the console, and report a full roster afterwards so
# ensure's post-check passes.
stub_cmd "$d2" docker "
printf '%s\n' \"\$*\" >> $CALLS
for a in \"\$@\"; do last=\"\$a\"; done
case \"\$last\" in
  *characters*)
    for n in Wsgaone Wsgatwo Wsgathree Wsgafour Wsgafive Wsgasix Wsgaseven Wsgaeight Wsganine Wsgaten; do
      printf '%s\t1\t60\t0\n' \"\$n\"
    done ;;
esac
exit 0"
stub_cmd "$d2" script 'exec "$@" >/dev/null 2>&1 || true'

OUT="$(TEAM_DIR="$ROOT/config/tournament/teams" \
       bash "$ROOT/scripts/tournament/roster.sh" ensure stormwind-sentinels 2>&1)"
RC=$?
assert_eq "0" "$RC" "ensure exits 0 on a full roster"
assert_contains "$OUT" "already complete" "ensure is a no-op when nothing is missing"
rm -f "$CALLS"
stub_cleanup "$d2"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/tournament/roster.test.sh`
Expected: FAIL — `usage: roster.sh status <team-id>` and exit 2, because `ensure`
is not a recognised subcommand yet.

- [ ] **Step 3: Add the subcommand**

Insert before the `case "$cmd" in` block:

```bash
# Slots that need creating, as `name|class|race|role` lines. Reads status rather
# than the DB directly so there is exactly one place that knows how to ask.
roster_missing() {
    local status names
    status="$(roster_status)"
    while IFS='|' read -r nm cls race role _fac; do
        printf '%s\n' "$status" | grep -q "^$nm  *missing" && printf '%s|%s|%s|%s\n' "$nm" "$cls" "$race" "$role"
    done < <(team_rows "$team")
}

roster_ensure() {
    local login="${1:-0}" missing broken lines n=0

    broken="$(roster_status | sed -n 's/.*ROSTER .*broken=\([0-9]*\).*/\1/p')"
    if [ "${broken:-0}" -gt 0 ]; then
        echo "FATAL: $team has $broken broken row(s) (at_login != 0)." >&2
        echo "       Those names were rejected at character load and can never come online." >&2
        echo "       Delete them by hand before re-running:" >&2
        echo "         DELETE FROM tw_char.characters WHERE name='<name>' AND at_login<>0;" >&2
        return 1
    fi

    missing="$(roster_missing)"
    if [ -z "$missing" ]; then
        echo "ROSTER $team already complete — nothing to create"
        return 0
    fi

    # Build every create into ONE console attach. Each attach is a chance to EOF
    # the console, and an EOF shuts the world down (compose is restart:"no").
    lines=""
    while IFS='|' read -r nm cls race role; do
        [ -n "$nm" ] || continue
        lines="${lines}rndbot create name=$nm class=$cls race=$race level=60 role=$role gear=blue login=$login group="$'\n'
        n=$((n + 1))
    done <<< "$missing"

    echo "creating $n character(s) for $team"
    # rndbot replies go to a null player session and vanish, so this return value
    # carries no information. The DB check below is the actual verification.
    wsg_console "$lines" 20 >/dev/null

    # Creation is asynchronous: the row appears a beat after the command lands.
    local deadline=$(( $(date +%s) + 120 ))
    while :; do
        local st; st="$(roster_status)"
        if printf '%s\n' "$st" | grep -q "present=10/10"; then
            printf '%s\n' "$st"
            return 0
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
            printf '%s\n' "$st"
            echo "FATAL: roster still incomplete 120s after creation" >&2
            return 1
        fi
        sleep 5
    done
}
```

and extend the dispatcher:

```bash
case "$cmd" in
    status) roster_status ;;
    ensure) shift 2; login=0; [ "${1:-}" = "--login" ] && login=1; roster_ensure "$login" ;;
    *)      usage ;;
esac
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bash tests/tournament/roster.test.sh`
Expected: `7 passed, 0 failed`, exit 0

- [ ] **Step 5: Commit**

```bash
git add scripts/tournament/roster.sh tests/tournament/roster.test.sh
git commit -m "feat(tournament): roster.sh ensure creates missing characters idempotently"
```

---

### Task 5: Roster login and teardown

**Files:**
- Modify: `scripts/tournament/roster.sh` (add `login` and `logout`)
- Modify: `tests/tournament/roster.test.sh`

**Interfaces:**
- Produces:
  - `roster.sh login <team-id>` — `rndbot add <name>` for each slot, then blocks
    until `online=10/10` or a 180 s deadline
  - `roster.sh logout <team-id>` — `rndbot remove <name>` for each slot. Does **not**
    delete characters.

This is the swap mechanism §2.3 of the spec depends on: only the two teams playing
are ever logged in.

- [ ] **Step 1: Write the failing test**

Append before `assert_summary`:

```bash
# --- login / logout -------------------------------------------------------
d3="$(stub_dir)"
SENT="$(mktemp)"
stub_cmd "$d3" docker "
for a in \"\$@\"; do last=\"\$a\"; done
case \"\$last\" in
  *characters*)
    for n in Wsgaone Wsgatwo Wsgathree Wsgafour Wsgafive Wsgasix Wsgaseven Wsgaeight Wsganine Wsgaten; do
      printf '%s\t1\t60\t0\n' \"\$n\"
    done ;;
esac
exit 0"
# wsg_console pipes its command block into `script`; capture it.
stub_cmd "$d3" script "cat >> $SENT; exit 0"

TEAM_DIR="$ROOT/config/tournament/teams" \
  bash "$ROOT/scripts/tournament/roster.sh" login stormwind-sentinels >/dev/null 2>&1
assert_eq "10" "$(grep -c 'rndbot add Wsga' "$SENT")" "login sends one add per slot"
assert_eq "1"  "$(grep -c 'rndbot add Wsgaone$' "$SENT")" "adds are one per line"

: > "$SENT"
TEAM_DIR="$ROOT/config/tournament/teams" \
  bash "$ROOT/scripts/tournament/roster.sh" logout stormwind-sentinels >/dev/null 2>&1
assert_eq "10" "$(grep -c 'rndbot remove Wsga' "$SENT")" "logout sends one remove per slot"
assert_eq "0"  "$(grep -c 'delete\|DELETE' "$SENT")" "logout never deletes characters"
rm -f "$SENT"
stub_cleanup "$d3"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/tournament/roster.test.sh`
Expected: FAIL — the `grep -c` assertions read `0`, because `login` falls through
to `usage`.

- [ ] **Step 3: Add the subcommands**

```bash
# The roster does NOT come back on its own after a mangosd restart: the random
# pool re-logs its own bots but its login list does not include these.
roster_login() {
    local lines="" nm
    while IFS= read -r nm; do
        lines="${lines}rndbot add $nm"$'\n'
    done < <(team_names "$team")

    echo "logging in $team"
    wsg_console "$lines" 20 >/dev/null

    local deadline=$(( $(date +%s) + 180 ))
    while :; do
        local st; st="$(roster_status)"
        if printf '%s\n' "$st" | grep -q "online=10/10"; then
            printf '%s\n' "$st"; return 0
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
            printf '%s\n' "$st"
            echo "FATAL: $team did not reach 10/10 online within 180s" >&2
            return 1
        fi
        sleep 10
    done
}

# `rndbot remove` unmanages and logs the bot out. It never deletes the
# characters row -- which is exactly what we want between rounds.
roster_logout() {
    local lines="" nm
    while IFS= read -r nm; do
        lines="${lines}rndbot remove $nm"$'\n'
    done < <(team_names "$team")

    echo "logging out $team"
    wsg_console "$lines" 20 >/dev/null
    sleep 5
    roster_status
}
```

and extend the dispatcher:

```bash
case "$cmd" in
    status) roster_status ;;
    ensure) shift 2; login=0; [ "${1:-}" = "--login" ] && login=1; roster_ensure "$login" ;;
    login)  roster_login ;;
    logout) roster_logout ;;
    *)      usage ;;
esac
```

and update `usage`:

```bash
usage() { echo "usage: roster.sh {status|ensure|login|logout} <team-id>" >&2; exit 2; }
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bash tests/tournament/roster.test.sh`
Expected: `11 passed, 0 failed`, exit 0

- [ ] **Step 5: Prove the swap works against the real server**

```bash
./scripts/tournament/roster.sh logout stormwind-sentinels
./scripts/tournament/roster.sh status stormwind-sentinels    # expect online=0/10
./scripts/tournament/roster.sh login  stormwind-sentinels    # expect online=10/10
```

Expected: `online=0/10` after logout, `online=10/10` after login. Allow up to
60 s of stale `online` readings — `PlayerSave.Interval` is 60 s, so the column
lags reality.

- [ ] **Step 6: Commit**

```bash
git add scripts/tournament/roster.sh tests/tournament/roster.test.sh
git commit -m "feat(tournament): roster.sh login/logout for between-round swaps"
```

---

### Task 6: Document the roster workflow

**Files:**
- Create: `docs/playerbots/TOURNAMENT-ROSTERS.md`
- Modify: `docs/playerbots/WSG-BOT-MATCH.md` (a pointer in §2.3)

- [ ] **Step 1: Write the doc**

`docs/playerbots/TOURNAMENT-ROSTERS.md`:

```markdown
# Tournament rosters

A team is a JSON file, not a console transcript. Everything you would tweak per
team lives in `config/tournament/teams/<id>.json`; `scripts/tournament/roster.sh`
reconciles that file against the world.

## The one thing that will bite you

**Character names must be alphabetic.** Digits are rejected at character *load*,
not creation, and `"Bot is now online"` prints before the login is even attempted
— so a digit-named bot looks like it logged in and instantly vanished, and leaves
a row with `at_login=1` that can never come online. `team-validate.sh` gates this;
do not bypass it.

## Commands

```bash
./scripts/tournament/team-validate.sh                       # validate every team file
./scripts/tournament/roster.sh status  stormwind-sentinels  # read-only reconcile
./scripts/tournament/roster.sh ensure  stormwind-sentinels  # create what is missing
./scripts/tournament/roster.sh login   stormwind-sentinels  # bring the team online
./scripts/tournament/roster.sh logout  stormwind-sentinels  # take it offline (keeps characters)
```

`ensure` is idempotent and refuses to run while any row is broken. `logout` never
deletes a character — it is the between-rounds swap, not a teardown.

## Adding a team

1. Copy an existing file in `config/tournament/teams/`, change `id`,
   `displayName`, `namePrefix`, and the roster.
2. `namePrefix` must be alphabetic and produce names ≤ 12 characters when
   concatenated with the slot words (`one`…`ten`).
3. Every race must be playable by the declared faction.
4. `./scripts/tournament/team-validate.sh <new-id>` must exit 0 **before** you run
   `ensure`.

## After a mangosd restart

The roster does not come back on its own — the random bot pool re-logs its own
bots, but its login list does not include these. Run `roster.sh login <team>` for
whichever teams should be up.
```

- [ ] **Step 2: Point the old runbook at it**

In `docs/playerbots/WSG-BOT-MATCH.md` §2.3, after the line
`` `scripts/wsg-team-roster.txt` is the source of truth (`name|class|race|role|faction`). ``
add:

```markdown
> Superseded for tournament work by `config/tournament/teams/*.json` — see
> [TOURNAMENT-ROSTERS.md](TOURNAMENT-ROSTERS.md). The flat file stays valid and
> the JSON emits the same `name|class|race|role|faction` rows, so both paths
> describe the same 20 bots.
```

- [ ] **Step 3: Commit**

```bash
git add docs/playerbots/TOURNAMENT-ROSTERS.md docs/playerbots/WSG-BOT-MATCH.md
git commit -m "docs(tournament): roster workflow and the alphabetic-name gate"
```

---

## Done when

- `bash tests/tournament/team.test.sh` and `bash tests/tournament/roster.test.sh`
  both exit 0.
- `./scripts/tournament/team-validate.sh` exits 0 for both shipped teams and
  exits 1 with a clear message when a digit is injected into a name prefix.
- Against the live server: `roster.sh status` reports `present=10/10 broken=0` for
  both teams, and a `logout` → `login` cycle returns `online=10/10`.
