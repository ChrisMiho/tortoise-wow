# Viewer Interaction Effects — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a viewer action — a chat command or a donation — heal, kill, or upgrade
a bot or a whole team mid-match, applied safely and exactly once.

**Architecture:** Eight effects behind a durable append-only command queue. A consumer
loop drains the queue during a match, deduplicates by command id, rate-limits, and
applies each effect through the `.tournament` control plane. Input comes from a CLI
mock in this pass; a real Twitch/TikTok adapter is later work against the same queue
file, which is the whole reason the queue exists.

**Tech Stack:** Bash (WSL), `jq`, NDJSON, C++ (two new control-plane subcommands).

**Spec:** `docs/superpowers/specs/2026-08-16-bot-tournament-design.md` (§2.7, §4.5)

**Depends on:** `2026-08-16-02-tournament-control-plane.md`,
`2026-08-16-03-gear-loadouts.md`, `2026-08-16-04-bracket-engine.md`.

## Global Constraints

- **Idempotent by command id.** A queue is replayed after a crash and an adapter can
  deliver twice. An effect applied twice is a viewer defrauded or a team wiped
  twice — dedupe is a correctness requirement, not a nicety.
- **Never apply an effect to a bot that is not in the live match.** Healing an
  offline character silently does nothing; killing the wrong bot is worse.
- **Rate-limit per effect class.** `kill_team` is match-deciding. Without a limit,
  one script hammering the queue ends every match instantly.
- Gear upgrades move exactly **one tier by rank**, never wrap. At the top tier an
  upgrade is a no-op that reports itself as such (see `gear_next_tier`).
- Effects need the bot **online**; every control-plane command resolves the player by
  name through `ObjectAccessor`.
- The queue file is append-only NDJSON. Never rewrite it in place — the consumer may
  be reading it.

---

## The effect catalogue

| Effect | Applied by | Notes |
|---|---|---|
| `heal_player` | `tournament heal <name>` | full heal, and resurrect if dead |
| `heal_team` | ten `tournament heal` calls | |
| `kill_player` | `tournament kill <name>` | normal BG death handling — releases and respawns |
| `kill_team` | ten `tournament kill` calls | heavily rate-limited |
| `upgrade_armor_player` | `tournament equip` with the next tier's armour slots | |
| `upgrade_armor_team` | as above, ten bots | |
| `upgrade_weapon_player` | `tournament equip` with the next tier's weapon slots | |
| `upgrade_weapon_team` | as above, ten bots | |

---

## File Structure

| File | Responsibility |
|---|---|
| `src/game/Commands/TournamentCommands.cpp` (modify) | `tournament heal` and `tournament kill` |
| `src/game/Chat/Chat.h` / `Chat.cpp` (modify) | Declare and register them |
| `scripts/tournament/lib/gear.sh` (modify) | Split a tier's items into armour and weapon sets |
| `scripts/tournament/lib/effects.sh` (create) | Validate and apply one effect |
| `scripts/tournament/effect-queue.sh` (create) | Append to the queue (the mock adapter) |
| `scripts/tournament/effect-consume.sh` (create) | Drain the queue during a match |
| `tests/tournament/effects.test.sh` (create) | Validation, dedupe, rate-limit, tier-split tests |

---

### Task 1: `tournament heal` and `tournament kill`

**Files:**
- Modify: `src/game/Commands/TournamentCommands.cpp`
- Modify: `src/game/Chat/Chat.h`
- Modify: `src/game/Chat/Chat.cpp`

**Interfaces:**
- Produces:
  - `tournament heal <playerName>` → `TOURNAMENT heal player=<name> hp=<n> resurrected=<0|1> ok=1`
  - `tournament kill <playerName>` → `TOURNAMENT kill player=<name> ok=<0|1> reason=<text>`

Both refuse a player who is not currently in a battleground — the queue can outlive
a match, and an effect landing on a bot standing in a city is a bug that looks like
a no-op.

- [ ] **Step 1: Add both handlers**

```cpp
bool ChatHandler::HandleTournamentHealCommand(char* args)
{
    char* nameStr = ExtractQuotedOrLiteralArg(&args);
    if (!nameStr)
    {
        TournamentEmit("heal error=usage(.tournament heal <playerName>)");
        return true;
    }
    std::string name = nameStr;

    Player* plr = sObjectAccessor.FindPlayerByName(name.c_str());
    if (!plr)
    {
        TournamentEmit("heal error=player_not_online(" + name + ")");
        return true;
    }

    // A queued effect can outlive the match that produced it. Healing a bot idling
    // in a city is not a no-op, it is the wrong bot getting the viewer's effect.
    if (!plr->InBattleGround())
    {
        TournamentEmit("heal error=not_in_battleground(" + name + ")");
        return true;
    }

    uint32 resurrected = 0;
    if (!plr->IsAlive())
    {
        // Same pair .revive uses (Commands.cpp:3016): resurrect, then clear the
        // corpse, or the client is left with a corpse it can still run back to.
        plr->ResurrectPlayer(1.0f);
        plr->SpawnCorpseBones();
        resurrected = 1;
    }
    plr->SetHealth(plr->GetMaxHealth());

    std::ostringstream ss;
    ss << "heal player=" << name
       << " hp=" << plr->GetHealth()
       << " resurrected=" << resurrected
       << " ok=1";
    TournamentEmit(ss.str());
    return true;
}

bool ChatHandler::HandleTournamentKillCommand(char* args)
{
    char* nameStr = ExtractQuotedOrLiteralArg(&args);
    if (!nameStr)
    {
        TournamentEmit("kill error=usage(.tournament kill <playerName>)");
        return true;
    }
    std::string name = nameStr;

    Player* plr = sObjectAccessor.FindPlayerByName(name.c_str());
    if (!plr)
    {
        TournamentEmit("kill error=player_not_online(" + name + ")");
        return true;
    }

    if (!plr->InBattleGround())
    {
        TournamentEmit("kill error=not_in_battleground(" + name + ")");
        return true;
    }

    if (!plr->IsAlive())
    {
        TournamentEmit("kill player=" + name + " ok=0 reason=already_dead");
        return true;
    }

    // .die refuses hardcore characters (Commands.cpp:2805). Tournament bots are
    // not hardcore, but the guard costs nothing and the alternative is a command
    // that can permanently destroy a character.
    if (plr->IsHardcore())
    {
        TournamentEmit("kill player=" + name + " ok=0 reason=hardcore_character");
        return true;
    }

    // Self-inflicted lethal damage rather than a direct state change, so normal
    // battleground death handling runs: the death is scored, the bot releases,
    // and it respawns at its graveyard like any other kill.
    plr->DealDamage(plr, plr->GetHealth(), nullptr, DIRECT_DAMAGE,
                    SPELL_SCHOOL_MASK_NORMAL, nullptr, false);

    std::ostringstream ss;
    ss << "kill player=" << name << " ok=1 reason=-";
    TournamentEmit(ss.str());
    return true;
}
```

- [ ] **Step 2: Declare and register**

`Chat.h`:

```cpp
        bool HandleTournamentHealCommand(char* args);
        bool HandleTournamentKillCommand(char* args);
```

`Chat.cpp`, in `tournamentCommandTable`:

```cpp
        { "heal",    SEC_ADMINISTRATOR, true,  &ChatHandler::HandleTournamentHealCommand,    "", nullptr },
        { "kill",    SEC_ADMINISTRATOR, true,  &ChatHandler::HandleTournamentKillCommand,    "", nullptr },
```

- [ ] **Step 3: Build**

Run: `./scripts/rebuild.sh`
Expected: all acceptance checks `ok:`.

- [ ] **Step 4: Verify both, including the guard**

```bash
./scripts/validate-stack.sh --image tortoise-cm:local --keep-up
./scripts/tournament/roster.sh login stormwind-sentinels
```

First prove the guard fires for a bot that is *not* in a battleground:

```bash
MSYS_NO_PATHCONV=1 bash <<'EOF'
source docs/playerbots/wsg/lib/wsg-bots-common.sh
wsg_console "tournament heal Wsgaone" 8
wsg_console "tournament kill Wsgaone" 8
EOF
```

Expected: `error=not_in_battleground(Wsgaone)` for both. **This is the success
case for this step** — the guard is the interesting behaviour.

Then start a real match and, while it is live:

```bash
MSYS_NO_PATHCONV=1 bash <<'EOF'
source docs/playerbots/wsg/lib/wsg-bots-common.sh
wsg_console "tournament kill Wsgaone" 8
sleep 5
wsg_console "tournament heal Wsgaone" 8
EOF
```

Expected: `kill ... ok=1`, then `heal ... resurrected=1 ok=1`.

- [ ] **Step 5: Commit**

```bash
git add src/game/Commands/TournamentCommands.cpp src/game/Chat/Chat.h src/game/Chat/Chat.cpp
git commit -m "feat(effects): tournament heal and kill, gated on being in a battleground"
```

---

### Task 2: Split a gear tier into armour and weapons

**Files:**
- Modify: `scripts/tournament/lib/gear.sh`
- Test: `tests/tournament/effects.test.sh` (create)

**Interfaces:**
- Produces:
  - `gear_items_armor <class> <role> <tier>` → `slot|itemId` for armour slots only
  - `gear_items_weapon <class> <role> <tier>` → `slot|itemId` for weapon slots only

`upgrade_armor_*` and `upgrade_weapon_*` are separate effects, so a tier has to be
splittable. Without this, both effects would apply the whole kit and be
indistinguishable to a viewer who paid for one.

- [ ] **Step 1: Write the failing test**

```bash
# tests/tournament/effects.test.sh
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
. "$HERE/../lib/assert.sh"
. "$ROOT/scripts/tournament/lib/gear.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
export GEAR_DIR="$ROOT/config/tournament/gear"

A="$(gear_items_armor warrior tank base)"
W="$(gear_items_weapon warrior tank base)"

assert_eq "0" "$(printf '%s\n' "$A" | grep -c '^mainhand|')" "armour set excludes the weapon"
assert_eq "1" "$(printf '%s\n' "$W" | grep -c '^mainhand|')" "weapon set includes the weapon"
assert_contains "$A" "chest|" "armour set includes chest"
assert_eq "0" "$(printf '%s\n' "$W" | grep -c 'chest|')" "weapon set excludes chest"

# The two halves must reconstitute the whole -- a slot in neither set can never
# be upgraded by any effect.
total="$(gear_items warrior tank base | wc -l | tr -d ' ')"
split="$(( $(printf '%s\n' "$A" | grep -c .) + $(printf '%s\n' "$W" | grep -c .) ))"
assert_eq "$total" "$split" "armour + weapons covers every slot in the tier"

assert_summary
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/tournament/effects.test.sh`
Expected: FAIL — `gear_items_armor: command not found`

- [ ] **Step 3: Add the splitters**

Append to `scripts/tournament/lib/gear.sh`:

```bash
# Weapon slots, per Player.h:590-610. Everything else in a tier is armour --
# including neck, rings, trinkets and back, which are not "armour" in the
# item-class sense but belong to the armour upgrade for a viewer's purposes.
GEAR_WEAPON_SLOTS="mainhand offhand ranged"

gear_items_weapon() { # <class> <role> <tier>
    local slot id
    gear_items "$1" "$2" "$3" | while IFS='|' read -r slot id; do
        case " $GEAR_WEAPON_SLOTS " in
            *" $slot "*) printf '%s|%s\n' "$slot" "$id" ;;
        esac
    done
}

gear_items_armor() { # <class> <role> <tier>
    local slot id
    gear_items "$1" "$2" "$3" | while IFS='|' read -r slot id; do
        case " $GEAR_WEAPON_SLOTS " in
            *" $slot "*) ;;
            *) printf '%s|%s\n' "$slot" "$id" ;;
        esac
    done
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bash tests/tournament/effects.test.sh`
Expected: `5 passed, 0 failed`, exit 0

- [ ] **Step 5: Commit**

```bash
git add scripts/tournament/lib/gear.sh tests/tournament/effects.test.sh
git commit -m "feat(effects): split a gear tier into armour and weapon sets"
```

---

### Task 3: The effect library

**Files:**
- Create: `scripts/tournament/lib/effects.sh`
- Modify: `tests/tournament/effects.test.sh`

**Interfaces:**
- Produces:
  - `effect_validate <json>` → exit 0 if the command is well formed and names a
    known effect and a resolvable target
  - `effect_targets <json> <allianceTeam> <hordeTeam>` → the character names an
    effect applies to, one per line
  - `effect_apply <json> <allianceTeam> <hordeTeam>` → applies it, echoing one
    `EFFECT ...` line; exit non-zero on failure

- [ ] **Step 1: Write the failing test**

Append to `tests/tournament/effects.test.sh` before `assert_summary`:

```bash
# --- effect validation and targeting --------------------------------------
. "$ROOT/scripts/tournament/lib/team.sh"
. "$ROOT/scripts/tournament/lib/effects.sh"
export TEAM_DIR="$ROOT/config/tournament/teams"

OK='{"id":"a1","ts":"2026-08-16T21:00:00Z","effect":"heal_player","target":{"team":"stormwind-sentinels","slot":"three"},"source":"mock"}'
assert_exit 0 "a well-formed command validates" -- effect_validate "$OK"
assert_eq "Wsgathree" "$(effect_targets "$OK" stormwind-sentinels orgrimmar-warsong)" \
  "resolves a single-slot target to a character name"

TEAMFX='{"id":"a2","ts":"2026-08-16T21:00:00Z","effect":"heal_team","target":{"team":"orgrimmar-warsong"},"source":"mock"}'
assert_eq "10" "$(effect_targets "$TEAMFX" stormwind-sentinels orgrimmar-warsong | wc -l | tr -d ' ')" \
  "a team effect targets all ten"

BADFX='{"id":"a3","ts":"2026-08-16T21:00:00Z","effect":"summon_dragon","target":{"team":"stormwind-sentinels"},"source":"mock"}'
assert_exit 1 "an unknown effect is rejected" -- effect_validate "$BADFX"
assert_contains "$(effect_validate "$BADFX" 2>&1)" "unknown effect" "and says why"

NOID='{"ts":"2026-08-16T21:00:00Z","effect":"heal_team","target":{"team":"stormwind-sentinels"},"source":"mock"}'
assert_exit 1 "a command with no id is rejected" -- effect_validate "$NOID"

# A team not in this match must never be targeted -- the queue outlives a match.
OFFMATCH='{"id":"a4","ts":"2026-08-16T21:00:00Z","effect":"kill_team","target":{"team":"ironforge-anvils"},"source":"mock"}'
assert_exit 1 "a team not playing this match is rejected" -- \
  effect_targets "$OFFMATCH" stormwind-sentinels orgrimmar-warsong
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/tournament/effects.test.sh`
Expected: FAIL — `scripts/tournament/lib/effects.sh: No such file or directory`

- [ ] **Step 3: Write the library**

```bash
#!/usr/bin/env bash
# Validate, target, and apply one viewer effect. Source, don't execute.

EFFECT_NAMES="heal_player heal_team kill_player kill_team \
upgrade_armor_player upgrade_armor_team upgrade_weapon_player upgrade_weapon_team"

effect_field() { printf '%s' "$1" | jq -r "$2 // \"\""; }

effect_validate() { # <json>
    local j="$1" id fx team slot
    printf '%s' "$j" | jq -e . >/dev/null 2>&1 || { echo "not valid JSON" >&2; return 1; }

    id="$(effect_field "$j" '.id')"
    # Without an id there is no dedupe key, so a replayed queue would apply the
    # effect again. That is a viewer defrauded or a team wiped twice.
    [ -n "$id" ] || { echo "command has no id" >&2; return 1; }

    fx="$(effect_field "$j" '.effect')"
    case " $EFFECT_NAMES " in
        *" $fx "*) ;;
        *) echo "unknown effect: '$fx'" >&2; return 1 ;;
    esac

    team="$(effect_field "$j" '.target.team')"
    [ -n "$team" ] || { echo "command has no target team" >&2; return 1; }
    team_validate "$team" >/dev/null || { echo "target team '$team' does not validate" >&2; return 1; }

    case "$fx" in
        *_player)
            slot="$(effect_field "$j" '.target.slot')"
            [ -n "$slot" ] || { echo "a _player effect needs target.slot" >&2; return 1; }
            ;;
    esac
    return 0
}

effect_targets() { # <json> <allianceTeam> <hordeTeam>
    local j="$1" ateam="$2" hteam="$3" team fx slot
    team="$(effect_field "$j" '.target.team')"

    # The queue outlives a match. An effect naming a team that is not playing
    # would otherwise resolve to offline characters and silently do nothing.
    if [ "$team" != "$ateam" ] && [ "$team" != "$hteam" ]; then
        echo "team '$team' is not in this match ($ateam vs $hteam)" >&2
        return 1
    fi

    fx="$(effect_field "$j" '.effect')"
    case "$fx" in
        *_team)   team_names "$team" ;;
        *_player) slot="$(effect_field "$j" '.target.slot')"
                  printf '%s%s\n' "$(team_field "$team" '.namePrefix')" "$slot" ;;
    esac
}

# Class and role for one character, needed to pick the right gear file.
effect_member_meta() { # <team> <name>  -> "class|role"
    team_rows "$1" | awk -F'|' -v n="$2" '$1 == n { print $2 "|" $4; exit }'
}

effect_apply() { # <json> <allianceTeam> <hordeTeam>
    local j="$1" ateam="$2" hteam="$3" fx id team targets nm rc=0
    effect_validate "$j" || return 1
    fx="$(effect_field "$j" '.effect')"
    id="$(effect_field "$j" '.id')"
    team="$(effect_field "$j" '.target.team')"
    targets="$(effect_targets "$j" "$ateam" "$hteam")" || return 1

    local applied=0 failed=0
    while IFS= read -r nm; do
        [ -n "$nm" ] || continue
        case "$fx" in
            heal_player|heal_team)
                out="$(ctl "tournament heal $nm")" ;;
            kill_player|kill_team)
                out="$(ctl "tournament kill $nm")" ;;
            upgrade_armor_player|upgrade_armor_team|upgrade_weapon_player|upgrade_weapon_team)
                out="$(effect_upgrade_one "$team" "$nm" "$fx")" ;;
        esac

        if printf '%s\n' "$out" | grep -q "ok=1"; then
            applied=$((applied + 1))
        else
            failed=$((failed + 1))
            rc=1
        fi
    done <<< "$targets"

    printf 'EFFECT id=%s effect=%s team=%s applied=%d failed=%d\n' "$id" "$fx" "$team" "$applied" "$failed"
    return $rc
}

effect_upgrade_one() { # <team> <name> <effect>
    local team="$1" nm="$2" fx="$3" meta cls role cur next ids
    meta="$(effect_member_meta "$team" "$nm")"
    cls="${meta%%|*}"; role="${meta##*|}"

    cur="$(team_field "$team" '.gearTier')"
    next="$(gear_next_tier "$cls" "$role" "$cur")"
    if [ -z "$next" ]; then
        # Already at the top. A no-op that says so, never a wrap back to base.
        printf 'TOURNAMENT upgrade player=%s ok=1 reason=already_top_tier\n' "$nm"
        return 0
    fi

    case "$fx" in
        upgrade_armor_*)  ids="$(gear_items_armor  "$cls" "$role" "$next" | cut -d'|' -f2 | paste -sd, -)" ;;
        upgrade_weapon_*) ids="$(gear_items_weapon "$cls" "$role" "$next" | cut -d'|' -f2 | paste -sd, -)" ;;
    esac

    if [ -z "$ids" ]; then
        printf 'TOURNAMENT upgrade player=%s ok=0 reason=no_items_in_tier(%s)\n' "$nm" "$next"
        return 1
    fi

    ctl "tournament equip $nm $ids"
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bash tests/tournament/effects.test.sh`
Expected: `11 passed, 0 failed`, exit 0

- [ ] **Step 5: Commit**

```bash
git add scripts/tournament/lib/effects.sh tests/tournament/effects.test.sh
git commit -m "feat(effects): validate, target and apply one viewer effect"
```

---

### Task 4: The queue and its mock adapter

**Files:**
- Create: `scripts/tournament/effect-queue.sh`
- Modify: `tests/tournament/effects.test.sh`

**Interfaces:**
- Produces:
  `effect-queue.sh --queue <file> --effect <name> --team <id> [--slot <slot>] [--source <name>] [--id <id>]`
  — appends one NDJSON line and echoes the id it assigned.

This is the mock adapter. A real Twitch or TikTok listener replaces only this
script; everything downstream reads the file.

- [ ] **Step 1: Write the failing test**

Append before `assert_summary`:

```bash
# --- queue ----------------------------------------------------------------
q="$(mktemp)"
id1="$(bash "$ROOT/scripts/tournament/effect-queue.sh" --queue "$q" \
        --effect heal_team --team stormwind-sentinels --source mock)"
assert_eq "1" "$(wc -l < "$q" | tr -d ' ')" "appends one line"
assert_contains "$(cat "$q")" '"effect":"heal_team"' "writes the effect"
assert_contains "$(cat "$q")" "\"id\":\"$id1\"" "writes the id it echoed"

bash "$ROOT/scripts/tournament/effect-queue.sh" --queue "$q" \
     --effect kill_player --team orgrimmar-warsong --slot five >/dev/null
assert_eq "2" "$(wc -l < "$q" | tr -d ' ')" "appends without rewriting"
assert_contains "$(tail -1 "$q")" '"slot":"five"' "writes the slot"

# Every line must be independently parseable -- the consumer reads line by line.
assert_exit 0 "every queue line is valid JSON" -- \
  bash -c "while IFS= read -r l; do printf '%s' \"\$l\" | jq -e . >/dev/null || exit 1; done < '$q'"

# A rejected effect must never reach the queue.
assert_exit 1 "an unknown effect is refused at enqueue" -- \
  bash "$ROOT/scripts/tournament/effect-queue.sh" --queue "$q" --effect summon_dragon --team stormwind-sentinels
assert_eq "2" "$(wc -l < "$q" | tr -d ' ')" "and nothing was appended"
rm -f "$q"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/tournament/effects.test.sh`
Expected: FAIL — `scripts/tournament/effect-queue.sh: No such file or directory`

- [ ] **Step 3: Write the script**

```bash
#!/usr/bin/env bash
# Append one viewer effect to the queue. This is the MOCK adapter -- a real
# Twitch/TikTok listener replaces this script and nothing else.
#
#   ./scripts/tournament/effect-queue.sh --queue q.ndjson \
#        --effect heal_player --team stormwind-sentinels --slot three
#
# Echoes the command id. Validates before appending: a malformed command in the
# queue is a landmine the consumer trips over mid-match.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/team.sh"
. "$HERE/lib/gear.sh"
. "$HERE/lib/effects.sh"

QUEUE=""; EFFECT=""; TEAM=""; SLOT=""; SOURCE="mock"; ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --queue)  QUEUE="$2"; shift 2 ;;
    --effect) EFFECT="$2"; shift 2 ;;
    --team)   TEAM="$2"; shift 2 ;;
    --slot)   SLOT="$2"; shift 2 ;;
    --source) SOURCE="$2"; shift 2 ;;
    --id)     ID="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$QUEUE" ] && [ -n "$EFFECT" ] && [ -n "$TEAM" ] \
  || { echo "usage: effect-queue.sh --queue <file> --effect <name> --team <id> [--slot <slot>] [--source <name>] [--id <id>]" >&2; exit 2; }

# Ids must be unique per command. $RANDOM alone repeats within a second across
# forks, so pair it with nanoseconds.
[ -n "$ID" ] || ID="$(date -u +%s%N)-$RANDOM"

line="$(jq -nc \
  --arg id "$ID" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg fx "$EFFECT" \
  --arg team "$TEAM" \
  --arg slot "$SLOT" \
  --arg src "$SOURCE" \
  '{id:$id, ts:$ts, effect:$fx,
    target: ({team:$team} + (if $slot == "" then {} else {slot:$slot} end)),
    source:$src}')"

effect_validate "$line" || { echo "refusing to enqueue an invalid command" >&2; exit 1; }

mkdir -p "$(dirname "$QUEUE")"
printf '%s\n' "$line" >> "$QUEUE"
printf '%s\n' "$ID"
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bash tests/tournament/effects.test.sh`
Expected: `17 passed, 0 failed`, exit 0

- [ ] **Step 5: Commit**

```bash
git add scripts/tournament/effect-queue.sh tests/tournament/effects.test.sh
git commit -m "feat(effects): append-only effect queue with a mock adapter"
```

---

### Task 5: The consumer — dedupe and rate limits

**Files:**
- Create: `scripts/tournament/effect-consume.sh`
- Modify: `tests/tournament/effects.test.sh`

**Interfaces:**
- Produces: `effect-consume.sh --queue <file> --alliance <team> --horde <team>
  --state <dir> [--once]` — drains new commands, skipping any id already in
  `<state>/applied.txt`, enforcing per-effect-class rate limits, appending each
  applied id.

- [ ] **Step 1: Write the failing test**

Append before `assert_summary`:

```bash
# --- consumer: dedupe and rate limits -------------------------------------
q2="$(mktemp)"; st="$(mktemp -d)"
# A stub ctl so no server is needed; every command "succeeds".
cat > "$st/ctlstub.sh" <<'STUB'
ctl() { printf 'TOURNAMENT %s ok=1\n' "$*"; }
ctl_field() { printf '%s\n' "$1" | sed -n "s/.*[[:space:]]$2=\\([^[:space:]]*\\).*/\\1/p" | head -1; }
STUB

idA="$(bash "$ROOT/scripts/tournament/effect-queue.sh" --queue "$q2" \
        --effect heal_player --team stormwind-sentinels --slot one)"
# The same id twice: an adapter double-delivery, or a replayed queue.
bash "$ROOT/scripts/tournament/effect-queue.sh" --queue "$q2" \
     --effect heal_player --team stormwind-sentinels --slot one --id "$idA" >/dev/null

OUT="$(CTL_STUB="$st/ctlstub.sh" bash "$ROOT/scripts/tournament/effect-consume.sh" \
        --queue "$q2" --alliance stormwind-sentinels --horde orgrimmar-warsong \
        --state "$st" --once 2>&1)"

assert_eq "1" "$(grep -c "^EFFECT id=$idA" <<< "$OUT")" "a duplicate id is applied once"
assert_contains "$OUT" "skipped=1" "and the duplicate is reported as skipped"
assert_eq "1" "$(grep -c "^$idA\$" "$st/applied.txt")" "applied ids are recorded once"

# Re-running must apply nothing new.
OUT2="$(CTL_STUB="$st/ctlstub.sh" bash "$ROOT/scripts/tournament/effect-consume.sh" \
         --queue "$q2" --alliance stormwind-sentinels --horde orgrimmar-warsong \
         --state "$st" --once 2>&1)"
assert_eq "0" "$(grep -c "^EFFECT " <<< "$OUT2")" "a second pass applies nothing"

# kill_team is match-deciding; the limit must bite.
for i in 1 2 3; do
  bash "$ROOT/scripts/tournament/effect-queue.sh" --queue "$q2" \
       --effect kill_team --team orgrimmar-warsong >/dev/null
done
OUT3="$(CTL_STUB="$st/ctlstub.sh" EFFECT_LIMIT_KILL_TEAM=1 \
        bash "$ROOT/scripts/tournament/effect-consume.sh" \
        --queue "$q2" --alliance stormwind-sentinels --horde orgrimmar-warsong \
        --state "$st" --once 2>&1)"
assert_eq "1" "$(grep -c 'effect=kill_team' <<< "$OUT3")" "kill_team is rate limited to one"
assert_contains "$OUT3" "ratelimited=2" "and the rest are reported as limited"

rm -rf "$q2" "$st"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/tournament/effects.test.sh`
Expected: FAIL — `scripts/tournament/effect-consume.sh: No such file or directory`

- [ ] **Step 3: Write the consumer**

```bash
#!/usr/bin/env bash
# Drain the effect queue during a match.
#
#   ./scripts/tournament/effect-consume.sh --queue q.ndjson \
#        --alliance stormwind-sentinels --horde orgrimmar-warsong \
#        --state logs/tournament/<run>/effects [--once] [--interval 5]
#
# Idempotent by command id: the queue is append-only and may be replayed after a
# crash, and an adapter can deliver the same command twice. Applying a paid-for
# effect twice is a defect, so dedupe is a correctness requirement.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
. "$HERE/lib/team.sh"
. "$HERE/lib/gear.sh"
if [ -n "${CTL_STUB:-}" ]; then . "$CTL_STUB"; else
  . "$HERE/lib/ctl.sh"
  # shellcheck source=/dev/null
  . "$ROOT/docs/playerbots/wsg/lib/wsg-bots-common.sh"
fi
. "$HERE/lib/effects.sh"

QUEUE=""; ATEAM=""; HTEAM=""; STATE=""; ONCE=0; INTERVAL=5
while [ $# -gt 0 ]; do
  case "$1" in
    --queue)    QUEUE="$2"; shift 2 ;;
    --alliance) ATEAM="$2"; shift 2 ;;
    --horde)    HTEAM="$2"; shift 2 ;;
    --state)    STATE="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --once)     ONCE=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$QUEUE" ] && [ -n "$ATEAM" ] && [ -n "$HTEAM" ] && [ -n "$STATE" ] \
  || { echo "usage: effect-consume.sh --queue <f> --alliance <t> --horde <t> --state <dir> [--once]" >&2; exit 2; }

mkdir -p "$STATE"
APPLIED="$STATE/applied.txt"
touch "$APPLIED"

# Per-match caps. kill_team ends a match; without a cap one script hammering the
# queue decides every game. Overridable so the tests can pin them.
LIMIT_kill_team="${EFFECT_LIMIT_KILL_TEAM:-2}"
LIMIT_kill_player="${EFFECT_LIMIT_KILL_PLAYER:-20}"
LIMIT_heal_team="${EFFECT_LIMIT_HEAL_TEAM:-10}"
LIMIT_heal_player="${EFFECT_LIMIT_HEAL_PLAYER:-50}"
LIMIT_upgrade_armor_team="${EFFECT_LIMIT_UPGRADE_ARMOR_TEAM:-2}"
LIMIT_upgrade_weapon_team="${EFFECT_LIMIT_UPGRADE_WEAPON_TEAM:-2}"
LIMIT_upgrade_armor_player="${EFFECT_LIMIT_UPGRADE_ARMOR_PLAYER:-20}"
LIMIT_upgrade_weapon_player="${EFFECT_LIMIT_UPGRADE_WEAPON_PLAYER:-20}"

limit_for() { eval "printf '%s\n' \"\${LIMIT_$1:-999}\""; }
count_for() { grep -c "^$1\$" "$STATE/counts.txt" 2>/dev/null || echo 0; }

drain_once() {
    local applied=0 skipped=0 limited=0 line id fx used lim
    [ -f "$QUEUE" ] || return 0

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf '%s' "$line" | jq -e . >/dev/null 2>&1 || { echo "WARN: unparseable queue line skipped" >&2; continue; }

        id="$(printf '%s' "$line" | jq -r '.id // ""')"
        [ -n "$id" ] || continue
        if grep -qx "$id" "$APPLIED"; then
            skipped=$((skipped + 1))
            continue
        fi

        fx="$(printf '%s' "$line" | jq -r '.effect // ""')"
        used="$(count_for "$fx")"
        lim="$(limit_for "$fx")"
        if [ "$used" -ge "$lim" ]; then
            limited=$((limited + 1))
            # Recorded as applied so a limited command is not retried forever.
            printf '%s\n' "$id" >> "$APPLIED"
            continue
        fi

        if effect_apply "$line" "$ATEAM" "$HTEAM"; then
            applied=$((applied + 1))
        else
            echo "WARN: effect $id ($fx) reported failures" >&2
        fi
        printf '%s\n' "$id" >> "$APPLIED"
        printf '%s\n' "$fx" >> "$STATE/counts.txt"
    done < "$QUEUE"

    printf 'CONSUME applied=%d skipped=%d ratelimited=%d\n' "$applied" "$skipped" "$limited"
}

if [ "$ONCE" -eq 1 ]; then
    drain_once
else
    while :; do
        drain_once
        sleep "$INTERVAL"
    done
fi
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bash tests/tournament/effects.test.sh`
Expected: `23 passed, 0 failed`, exit 0

- [ ] **Step 5: Commit**

```bash
git add scripts/tournament/effect-consume.sh tests/tournament/effects.test.sh
git commit -m "feat(effects): consumer with id dedupe and per-effect rate limits"
```

---

### Task 6: Run the consumer during a match, and document it

**Files:**
- Modify: `scripts/tournament/match-run.sh`
- Create: `docs/playerbots/TOURNAMENT-VIEWER-EFFECTS.md`

- [ ] **Step 1: Start and stop the consumer around the monitor loop**

In `match-run.sh`, immediately after the `tournament start` call:

```bash
EFFECT_QUEUE="${EFFECT_QUEUE:-$RUN_DIR/effects.ndjson}"
touch "$EFFECT_QUEUE"
"$HERE/effect-consume.sh" --queue "$EFFECT_QUEUE" \
    --alliance "$ATEAM" --horde "$HTEAM" \
    --state "$RUN_DIR/effects" --interval 5 >> "$RUN_DIR/effects.log" 2>&1 &
EFFECT_PID=$!
# The consumer must never outlive the match: after the teams log out its next
# effect would land on the following match's bots.
trap 'kill "$EFFECT_PID" 2>/dev/null || true' EXIT
log "effect consumer started (pid $EFFECT_PID), queue $EFFECT_QUEUE"
```

and immediately after the monitor loop breaks:

```bash
kill "$EFFECT_PID" 2>/dev/null || true
wait "$EFFECT_PID" 2>/dev/null || true
log "effect consumer stopped"
```

- [ ] **Step 2: Verify against a live match**

Start a match in one terminal, and in another:

```bash
Q=logs/tournament/effect-smoke/effects.ndjson
./scripts/tournament/effect-queue.sh --queue "$Q" --effect kill_player \
    --team orgrimmar-warsong --slot five
sleep 10
./scripts/tournament/effect-queue.sh --queue "$Q" --effect heal_team \
    --team orgrimmar-warsong
```

Then:

```bash
cat logs/tournament/effect-smoke/effects.log
```

Expected: an `EFFECT id=... effect=kill_player ... applied=1 failed=0`, then
`effect=heal_team ... applied=10`. Cross-check the kill in the telemetry CSV —
`alive` should drop to `0` for that bot at the matching `t`.

- [ ] **Step 3: Write the doc**

`docs/playerbots/TOURNAMENT-VIEWER-EFFECTS.md`:

```markdown
# Viewer effects

Eight interventions a viewer can trigger against a live match.

| Effect | Target | Default cap per match |
|---|---|---|
| `heal_player` / `heal_team` | one bot / all ten | 50 / 10 |
| `kill_player` / `kill_team` | one bot / all ten | 20 / 2 |
| `upgrade_armor_player` / `_team` | one bot / all ten | 20 / 2 |
| `upgrade_weapon_player` / `_team` | one bot / all ten | 20 / 2 |

Caps exist because `kill_team` decides a match. Override with
`EFFECT_LIMIT_KILL_TEAM=1` and friends.

## The queue

Append-only NDJSON, one command per line:

```json
{"id":"1755...","ts":"2026-08-16T21:03:11Z","effect":"heal_player","target":{"team":"stormwind-sentinels","slot":"three"},"source":"mock"}
```

`id` is the dedupe key. The consumer records every applied id, so a replayed
queue or a double-delivering adapter applies each command exactly once — an
effect a viewer paid for must not fire twice.

## Adapters

`effect-queue.sh` is the **mock** adapter. A real Twitch or TikTok listener
replaces that script alone; everything downstream reads the file. That boundary is
why this pass builds no OAuth: the effects can be tested end to end with no
credentials and no live channel.

## Safety

- Every effect resolves the bot by name and refuses if it is not currently in a
  battleground — the queue outlives a match, and a stale effect must not land on
  an idle bot in a city.
- A command naming a team that is not in the current match is rejected.
- Upgrades move exactly one tier by `rank`. At the top tier the effect is a no-op
  reporting `already_top_tier`, never a wrap back to base.
- `match-run.sh` kills the consumer when the match ends, so no effect crosses into
  the next match.
```

- [ ] **Step 4: Commit**

```bash
git add scripts/tournament/match-run.sh docs/playerbots/TOURNAMENT-VIEWER-EFFECTS.md
git commit -m "feat(effects): run the consumer for the duration of a match"
```

---

## Done when

- `bash tests/tournament/effects.test.sh` exits 0.
- A duplicate command id is demonstrably applied once, and a second consumer pass
  over the same queue applies nothing.
- `kill_team` is demonstrably capped.
- Against a live match: a queued `kill_player` shows up as `alive=0` for that bot
  in the telemetry CSV, and a queued `heal_team` reports `applied=10`.
- `tournament heal` / `tournament kill` refuse a bot that is not in a battleground.
