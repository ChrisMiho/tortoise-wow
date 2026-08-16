# Spectator Camera & Streaming Feasibility — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the part of the broadcast problem that can actually be verified
unattended — a server-side director that keeps a spectator character where the action
is — and answer the part that cannot with a written assessment instead of untested
code.

**Architecture:** The server already knows where every player is (Plan 05's sampler),
so it can compute a point of interest: the flag carrier if there is one, otherwise the
centroid of the largest cluster of players in combat. A `tournament camera` command
moves a named spectator there. A shell director calls it on an interval. Capture,
multiboxing, and POV extraction get an evidence-based assessment, not plumbing nobody
can test overnight.

**Tech Stack:** C++ (control plane), Bash director, existing GM commands.

**Spec:** `docs/superpowers/specs/2026-08-16-bot-tournament-design.md` (§1.7, §2.8)

**Depends on:** `2026-08-16-02-tournament-control-plane.md`,
`2026-08-16-05-bg-telemetry.md`.

## Global Constraints

- **The spectator must never be a battleground member.** Adding them to the BG would
  make it 11v10 and change the match. They are teleported in as a GM, not enrolled —
  which is also why `.bg leave` does not apply to them
  (`docs/playerbots/WSG-BOT-MATCH.md` §5).
- **Never party the spectator to a bot.** `HasActivePlayerMaster()` is a hard gate in
  the bot's queue logic (`BattleGroundJoinAction.cpp:568`) — a partied bot never
  queues again.
- The GM account needs `rank=4` for `.hover` and `.bgtest`; `rank=3` is refused
  because `SEC_GAMEMASTER` is `#define`d to `SEC_ADMINISTRATOR`=4.
- **Server-side camera control is teleportation, not panning.** There is no
  server-side API to rotate a client's view. This produces broadcast-style *cuts*
  between positions, not smooth tracking. Say so plainly in the docs rather than
  implying otherwise.
- `.appear` into a battleground is explicitly supported and only fails if the caller
  is already inside a *different* battleground.
- The director must stop when the match does, or it teleports a spectator around an
  empty map for the next hour.

---

## What this plan does not attempt

Stated up front because the honest boundary is the point of the design:

- **Video capture and encoding.** An unattended run cannot verify that a frame was
  produced. Assessed in Task 4, not built.
- **Multiboxing several clients.** Same reason.
- **Extracting a bot's POV.** A playerbot has a `WorldSession` but no client and no
  camera; there is no view to extract. Task 4 explains what the alternatives actually
  are.
- **Smooth camera motion.** Needs a client-side addon or a human. Out of scope, and
  named as such in the assessment.

---

## File Structure

| File | Responsibility |
|---|---|
| `src/game/Commands/TournamentCommands.cpp` (modify) | `tournament poi` and `tournament camera` |
| `src/game/Chat/Chat.h` / `Chat.cpp` (modify) | Declare and register them |
| `scripts/tournament/spectate.sh` (create) | The director loop |
| `tests/tournament/spectate.test.sh` (create) | Director logic against a stubbed control plane |
| `docs/playerbots/TOURNAMENT-STREAMING.md` (create) | The feasibility assessment |

---

### Task 1: `tournament poi` — where is the action?

**Files:**
- Modify: `src/game/Commands/TournamentCommands.cpp`
- Modify: `src/game/Chat/Chat.h`, `src/game/Chat/Chat.cpp`

**Interfaces:**
- Produces: `tournament poi <instanceId>` →
  `TOURNAMENT poi instance=<id> map=<n> x=<f> y=<f> z=<f> reason=<flagcarrier|combat|centroid|empty> subject=<name|-> players=<n>`

Priority order: a flag carrier is the story; failing that, the biggest knot of players
in combat; failing that, the centroid of everyone alive. Each is a strictly weaker
fallback, so the `reason` field tells a director how much to trust the framing.

- [ ] **Step 1: Use the generic flag-carrier accessor that already exists**

Verified in this tree — no aura sniffing and no WSG-specific special case is needed:

| Accessor | Where | Note |
|---|---|---|
| `BattleGround::GetFlagCarrierGuid(uint32 team_index = 0)` | `BattleGround.h:299` | **base virtual**, returns an empty guid by default |
| `BattleGroundWS::GetFlagCarrierGuid` | `BattleGroundWS.h:147` | the WSG override, reads `m_FlagKeepers[]` |

Because the base declares it virtual with an empty-guid default, the POI code can
call it on any `BattleGround*`: WSG answers properly, and a battleground type with
no flags returns empty and correctly falls through to the combat-cluster branch.
`BG_TEAMS_COUNT` is 2, so index `0` is Alliance and `1` is Horde.

Confirm before writing:

```bash
grep -n "GetFlagCarrierGuid" src/game/Battlegrounds/BattleGround.h src/game/Battlegrounds/BattleGroundWS.h
```

- [ ] **Step 2: Add the handler**

```cpp
bool ChatHandler::HandleTournamentPoiCommand(char* args)
{
    uint32 instanceId = 0;
    if (!ExtractUInt32(&args, instanceId))
    {
        TournamentEmit("poi error=usage(.tournament poi <instanceId>)");
        return true;
    }

    BattleGround* bg = TournamentFindInstance(instanceId);
    if (!bg)
    {
        TournamentEmit("poi error=no_such_instance");
        return true;
    }

    // Collect live players once. Everything below is a different reduction over
    // the same set, so gathering it twice would be both slower and racy.
    std::vector<Player*> alive;
    for (const auto& itr : bg->GetPlayers())
        if (Player* p = sObjectAccessor.FindPlayer(itr.first))
            if (p->IsAlive())
                alive.push_back(p);

    std::ostringstream ss;
    ss << "poi instance=" << instanceId << " map=" << bg->GetMapId();

    if (alive.empty())
    {
        ss << " x=0 y=0 z=0 reason=empty subject=- players=0";
        TournamentEmit(ss.str());
        return true;
    }

    // 1. A flag carrier is the story. GetFlagCarrierGuid is a base virtual
    //    (BattleGround.h:299) returning an empty guid by default, so this works
    //    unchanged for battleground types that have no flags -- they simply fall
    //    through to the combat branch below.
    for (uint32 teamIdx = 0; teamIdx < BG_TEAMS_COUNT; ++teamIdx)
    {
        ObjectGuid carrier = bg->GetFlagCarrierGuid(teamIdx);
        if (carrier.IsEmpty())
            continue;

        Player* p = sObjectAccessor.FindPlayer(carrier);
        // A carrier who just died is still recorded until the flag drops, so
        // check liveness rather than trusting the guid alone.
        if (!p || !p->IsAlive())
            continue;

        ss << " x=" << p->GetPositionX() << " y=" << p->GetPositionY()
           << " z=" << p->GetPositionZ()
           << " reason=flagcarrier subject=" << p->GetName()
           << " players=" << alive.size();
        TournamentEmit(ss.str());
        return true;
    }

    // 2. Otherwise the largest knot of players in combat. O(n^2) over at most 40
    //    players is nothing, and it beats a global centroid, which in a two-sided
    //    fight points at the empty middle of the map.
    float const CLUSTER_RADIUS = 40.0f;
    Player* best = nullptr;
    size_t bestCount = 0;
    for (Player* a : alive)
    {
        if (!a->IsInCombat())
            continue;
        size_t count = 0;
        for (Player* b : alive)
            if (b->IsInCombat() && a->GetDistance(b) <= CLUSTER_RADIUS)
                ++count;
        if (count > bestCount)
        {
            bestCount = count;
            best = a;
        }
    }

    if (best && bestCount >= 2)
    {
        float sx = 0.f, sy = 0.f, sz = 0.f;
        uint32 n = 0;
        for (Player* b : alive)
            if (b->IsInCombat() && best->GetDistance(b) <= CLUSTER_RADIUS)
            {
                sx += b->GetPositionX(); sy += b->GetPositionY(); sz += b->GetPositionZ();
                ++n;
            }
        ss << " x=" << (sx / n) << " y=" << (sy / n) << " z=" << (sz / n)
           << " reason=combat subject=" << best->GetName()
           << " players=" << n;
        TournamentEmit(ss.str());
        return true;
    }

    // 3. Nothing is happening. The centroid of everyone alive at least keeps the
    //    camera on the map, and reason=centroid tells the director the framing is
    //    a guess.
    float sx = 0.f, sy = 0.f, sz = 0.f;
    for (Player* p : alive)
    {
        sx += p->GetPositionX(); sy += p->GetPositionY(); sz += p->GetPositionZ();
    }
    ss << " x=" << (sx / alive.size()) << " y=" << (sy / alive.size())
       << " z=" << (sz / alive.size())
       << " reason=centroid subject=- players=" << alive.size();
    TournamentEmit(ss.str());
    return true;
}
```

No extra predicate is needed — the base virtual does the work, so this handler
compiles against `BattleGround` alone with no subclass include.

- [ ] **Step 3: Declare, register, build**

`Chat.h`: `bool HandleTournamentPoiCommand(char* args);`

`Chat.cpp`: `{ "poi", SEC_ADMINISTRATOR, true, &ChatHandler::HandleTournamentPoiCommand, "", nullptr },`

Run: `./scripts/rebuild.sh`
Expected: all acceptance checks `ok:`.

- [ ] **Step 4: Verify each branch**

```bash
./scripts/validate-stack.sh --image tortoise-cm:local --keep-up
```

Against an **empty** instance:

```bash
MSYS_NO_PATHCONV=1 bash <<'EOF'
source docs/playerbots/wsg/lib/wsg-bots-common.sh
out=$(wsg_console "tournament create 2 60" 10)
inst=$(echo "$out" | sed -n 's/.*instance=\([0-9]*\).*/\1/p' | head -1)
wsg_console "tournament poi $inst" 8
EOF
```

Expected: `reason=empty players=0`.

Then during a live match, poll it and confirm the reason changes as the match
develops:

```bash
MSYS_NO_PATHCONV=1 bash <<'EOF'
source docs/playerbots/wsg/lib/wsg-bots-common.sh
for i in 1 2 3 4 5; do wsg_console "tournament poi <inst>" 8 | grep -a "TOURNAMENT poi"; sleep 30; done
EOF
```

Expected: `reason=centroid` early, then `reason=combat` once the sides meet, and
`reason=flagcarrier` if a flag is ever taken. **If `reason` never leaves `centroid`
across a whole match, that is a finding for
`docs/playerbots/BG-AI-ANALYSIS.md`** — it means the bots never fought — not a bug in
this command.

- [ ] **Step 5: Commit**

```bash
git add src/game/Commands/TournamentCommands.cpp src/game/Chat/Chat.h src/game/Chat/Chat.cpp
git commit -m "feat(spectate): compute a battleground point of interest"
```

---

### Task 2: `tournament camera` — move the spectator there

**Files:**
- Modify: `src/game/Commands/TournamentCommands.cpp`
- Modify: `src/game/Chat/Chat.h`, `src/game/Chat/Chat.cpp`

**Interfaces:**
- Produces: `tournament camera <playerName> <instanceId> [height]` →
  `TOURNAMENT camera player=<name> instance=<id> x=<f> y=<f> z=<f> reason=<poi-reason> moved=<0|1>`

Teleports the named spectator to the current POI plus a vertical offset, without
enrolling them in the battleground.

- [ ] **Step 1: Add the handler**

```cpp
bool ChatHandler::HandleTournamentCameraCommand(char* args)
{
    char* nameStr = ExtractQuotedOrLiteralArg(&args);
    uint32 instanceId = 0;
    if (!nameStr || !ExtractUInt32(&args, instanceId))
    {
        TournamentEmit("camera error=usage(.tournament camera <playerName> <instanceId> [height])");
        return true;
    }
    std::string name = nameStr;

    uint32 height = 0;
    if (!ExtractUInt32(&args, height))
        height = 25;   // high enough to see a skirmish, low enough to read nameplates

    Player* plr = sObjectAccessor.FindPlayerByName(name.c_str());
    if (!plr)
    {
        TournamentEmit("camera error=spectator_not_online(" + name + ")");
        return true;
    }

    BattleGround* bg = TournamentFindInstance(instanceId);
    if (!bg)
    {
        TournamentEmit("camera error=no_such_instance");
        return true;
    }

    // The spectator must NOT be a battleground member -- enrolling them would make
    // the match 11v10 and change its outcome. They are a GM standing on the map,
    // which is also why `.bg leave` does not apply to them.
    for (const auto& itr : bg->GetPlayers())
    {
        if (itr.first == plr->GetObjectGuid())
        {
            TournamentEmit("camera error=spectator_is_a_match_participant(" + name + ")");
            return true;
        }
    }

    float x = 0.f, y = 0.f, z = 0.f;
    std::string reason;
    if (!TournamentComputePoi(bg, x, y, z, reason))
    {
        TournamentEmit("camera player=" + name + " moved=0 reason=no_poi");
        return true;
    }

    plr->TeleportTo(bg->GetMapId(), x, y, z + float(height), plr->GetOrientation());

    std::ostringstream ss;
    ss << "camera player=" << name
       << " instance=" << instanceId
       << " x=" << x << " y=" << y << " z=" << (z + float(height))
       << " reason=" << reason
       << " moved=1";
    TournamentEmit(ss.str());
    return true;
}
```

- [ ] **Step 2: Refactor the POI computation out of Task 1's handler**

`tournament poi` and `tournament camera` must not compute the point of interest two
different ways — they would drift apart on the first edit. Extract Task 1's body
into:

```cpp
// Fills x/y/z and reason. Returns false only when there is nothing to look at.
static bool TournamentComputePoi(BattleGround* bg, float& x, float& y, float& z,
                                 std::string& reason);
```

and make `HandleTournamentPoiCommand` a thin printer over it.

- [ ] **Step 3: Declare, register, build**

`Chat.h`: `bool HandleTournamentCameraCommand(char* args);`

`Chat.cpp`: `{ "camera", SEC_ADMINISTRATOR, true, &ChatHandler::HandleTournamentCameraCommand, "", nullptr },`

Run: `./scripts/rebuild.sh`
Expected: all acceptance checks `ok:`.

- [ ] **Step 4: Verify with a real GM character**

Log in as the GM (`Astral`, account 504, `rank=4`), then during a live match:

```bash
MSYS_NO_PATHCONV=1 bash <<'EOF'
source docs/playerbots/wsg/lib/wsg-bots-common.sh
wsg_console "tournament camera Astral <inst>" 8
EOF
```

Expected: `moved=1` and the character visibly relocates above the action on map 489.

Then prove the participant guard works — pick a bot that is in the match:

```bash
MSYS_NO_PATHCONV=1 bash <<'EOF'
source docs/playerbots/wsg/lib/wsg-bots-common.sh
wsg_console "tournament camera Wsgaone <inst>" 8
EOF
```

Expected: `error=spectator_is_a_match_participant(Wsgaone)`. **This refusal is the
important half of the task** — it is what stops the camera from silently turning the
match into 11v10.

- [ ] **Step 5: Commit**

```bash
git add src/game/Commands/TournamentCommands.cpp src/game/Chat/Chat.h src/game/Chat/Chat.cpp
git commit -m "feat(spectate): move a non-participant spectator to the point of interest"
```

---

### Task 3: The director loop

**Files:**
- Create: `scripts/tournament/spectate.sh`
- Test: `tests/tournament/spectate.test.sh`

**Interfaces:**
- Produces: `spectate.sh --spectator <name> --instance <id> [--interval 15]
  [--height 25] [--max-minutes 25]` — repositions the camera on an interval and stops
  when the instance is gone or the time budget expires.

- [ ] **Step 1: Write the failing test**

```bash
# tests/tournament/spectate.test.sh
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
. "$HERE/../lib/assert.sh"

st="$(mktemp -d)"
# A stub control plane: two successful repositions, then the instance disappears.
cat > "$st/ctlstub.sh" <<'STUB'
CALLS_FILE="${CALLS_FILE:-/dev/null}"
ctl() {
  printf '%s\n' "$*" >> "$CALLS_FILE"
  n=$(grep -c 'tournament camera' "$CALLS_FILE")
  if [ "$n" -ge 3 ]; then
    printf 'TOURNAMENT camera error=no_such_instance\n'
  else
    printf 'TOURNAMENT camera player=Astral instance=101 x=1.0 y=2.0 z=30.0 reason=combat moved=1\n'
  fi
}
ctl_field() { printf '%s\n' "$1" | sed -n "s/.*[[:space:]]$2=\\([^[:space:]]*\\).*/\\1/p" | head -1; }
STUB

CALLS="$st/calls.txt"; : > "$CALLS"
OUT="$(CTL_STUB="$st/ctlstub.sh" CALLS_FILE="$CALLS" \
       bash "$ROOT/scripts/tournament/spectate.sh" \
       --spectator Astral --instance 101 --interval 0 --max-minutes 5 2>&1)"
RC=$?

assert_eq "0" "$RC" "director exits 0 when the match ends"
assert_eq "3" "$(grep -c 'tournament camera' "$CALLS")" "stops as soon as the instance is gone"
assert_contains "$OUT" "SPECTATE" "emits a summary line"
assert_contains "$OUT" "repositions=2" "counts only successful repositions"

rm -rf "$st"
assert_summary
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/tournament/spectate.test.sh`
Expected: FAIL — `scripts/tournament/spectate.sh: No such file or directory`

- [ ] **Step 3: Write the director**

```bash
#!/usr/bin/env bash
# Keep a spectator on the action for the duration of one match.
#
#   ./scripts/tournament/spectate.sh --spectator Astral --instance 101
#
# This produces broadcast-style CUTS, not smooth tracking: the only server-side
# camera control available is teleportation. There is no API to rotate a client's
# view -- see docs/playerbots/TOURNAMENT-STREAMING.md.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
if [ -n "${CTL_STUB:-}" ]; then . "$CTL_STUB"; else
  . "$HERE/lib/ctl.sh"
  # shellcheck source=/dev/null
  . "$ROOT/docs/playerbots/wsg/lib/wsg-bots-common.sh"
fi

SPECTATOR=""; INSTANCE=""; INTERVAL=15; HEIGHT=25; MAXMIN=25
while [ $# -gt 0 ]; do
  case "$1" in
    --spectator)   SPECTATOR="$2"; shift 2 ;;
    --instance)    INSTANCE="$2"; shift 2 ;;
    --interval)    INTERVAL="$2"; shift 2 ;;
    --height)      HEIGHT="$2"; shift 2 ;;
    --max-minutes) MAXMIN="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$SPECTATOR" ] && [ -n "$INSTANCE" ] \
  || { echo "usage: spectate.sh --spectator <name> --instance <id> [--interval 15] [--height 25]" >&2; exit 2; }

# A match is hard-capped at 20 minutes (BattleGround.cpp:317-323). The budget is
# the backstop for the case where the instance somehow never disappears -- without
# it the director teleports a spectator around an empty map indefinitely.
deadline=$(( $(date +%s) + MAXMIN * 60 ))
repositions=0
lastreason=""

while :; do
    out="$(ctl "tournament camera $SPECTATOR $INSTANCE $HEIGHT")"
    err="$(ctl_field "$out" error)"

    if [ -n "$err" ]; then
        case "$err" in
            no_such_instance*)
                echo "match over (instance $INSTANCE is gone)" ;;
            *)
                echo "camera error: $err" >&2 ;;
        esac
        break
    fi

    reason="$(ctl_field "$out" reason)"
    if [ "$(ctl_field "$out" moved)" = "1" ]; then
        repositions=$((repositions + 1))
        # Only narrate when the framing changes -- one line per cut, not per poll.
        if [ "$reason" != "$lastreason" ]; then
            printf '[%s] camera now following: %s\n' "$(date -u +%H:%M:%SZ)" "$reason"
            lastreason="$reason"
        fi
    fi

    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "spectate budget of ${MAXMIN}m reached"
        break
    fi
    [ "$INTERVAL" -gt 0 ] && sleep "$INTERVAL"
done

printf 'SPECTATE instance=%s spectator=%s repositions=%d\n' "$INSTANCE" "$SPECTATOR" "$repositions"
exit 0
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bash tests/tournament/spectate.test.sh`
Expected: `4 passed, 0 failed`, exit 0

- [ ] **Step 5: Run it against a live match**

Log in as the GM first and set up the spectator state by hand, in game:

```
.gm on
.gm visible off
.hover 1
.god on
```

Then, with a match live:

```bash
./scripts/tournament/spectate.sh --spectator Astral --instance <inst>
```

Expected: a line each time the framing changes, and a final
`SPECTATE ... repositions=<n>` when the match ends.

Record what it actually looks like on screen — specifically whether the teleport
cadence is watchable or jarring at `--interval 15`. That observation feeds Task 4.

- [ ] **Step 6: Commit**

```bash
git add scripts/tournament/spectate.sh tests/tournament/spectate.test.sh
git commit -m "feat(spectate): director loop that follows the action for one match"
```

---

### Task 4: The streaming feasibility assessment

**Files:**
- Create: `docs/playerbots/TOURNAMENT-STREAMING.md`

**Deliverable:** an evidence-based assessment of how to get a watchable broadcast out
of this server. No code. Every claim either measured on this host or attributed.

- [ ] **Step 1: Measure what one extra client costs**

The multiboxing question is really a resource question, and this host's limits are
already documented (`docs/DOCKER.md`: WSL2 at 16 CPU / 24 GB). Before speculating:

```bash
free -h
docker stats --no-stream
nproc
```

Run once with no client attached and once with a client logged in and watching a
live match, and record the delta. State the numbers.

- [ ] **Step 2: Answer the POV question honestly**

The gameplan asks about "retrieving the POV of a scripted AI". Establish and write
down the actual situation:

- A playerbot has a `WorldSession` but **no client process and no renderer**. There
  is no framebuffer to capture. "The bot's POV" does not exist as a thing that can be
  read.
- The only sources of rendered frames are real game clients.
- Therefore any camera is a real client, driven either by a human, by an addon, or by
  server-side teleportation (what Task 3 does).

Verify the first claim rather than asserting it — confirm bots are server-side
sessions with no client:

```bash
grep -rn "class PlayerbotAI\|WorldSession\* .*botSession\|CreateBotSession\|AddSession" \
  src/modules/PlayerBots/playerbot/PlayerbotMgr.cpp | head -10
```

- [ ] **Step 3: Write the assessment**

`docs/playerbots/TOURNAMENT-STREAMING.md`:

```markdown
# Streaming a bot tournament — what works and what does not

Assessment dated 2026-08-16. The buildable half is
`scripts/tournament/spectate.sh`; this document is the rest.

## 1. There is no bot POV

A playerbot is a `WorldSession` with no client process and no renderer. There is no
framebuffer, so there is nothing to capture. Any question of the form "how do we get
the camera from bot X" has no answer, and no amount of server work creates one.

Rendered frames come from real game clients only. That leaves three ways to aim a
camera:

| Approach | Control | Verifiable unattended? | Cost |
|---|---|---|---|
| Human flies the GM | full, smooth | no | a person per match |
| Server-side teleport (`spectate.sh`) | cuts only, no rotation | **yes** | none beyond one client |
| Client-side addon | smooth, scriptable | no | addon development; client-side |

Only the middle row can be tested by an unattended run, which is why it is what got
built.

## 2. What `spectate.sh` actually produces

Broadcast-style **cuts**, not tracking. `tournament camera` calls `TeleportTo`;
there is no server API to rotate a client's view, so the camera jumps to each new
point of interest and holds until the next one.

Point-of-interest priority, highest first:

1. `flagcarrier` — someone is carrying a flag
2. `combat` — the centroid of the largest cluster of fighting players within 40 yards
3. `centroid` — everyone alive, when nothing is happening
4. `empty` — nobody alive

The `reason` field is in every emitted line, so a director or an overlay knows how
much to trust the framing. A whole match at `reason=centroid` means the bots never
fought — that is a finding for `BG-AI-ANALYSIS.md`, not a camera bug.

Observed cadence at `--interval 15`: <record what you actually saw in Task 3 Step 5>.

## 3. Multiboxing

Measured on this host (<date>): <the numbers from Step 1 — free memory, docker
stats delta, core count>.

The server is not the constraint; the clients are. Each additional client is a full
game process with its own renderer. State how many the measurements suggest this host
supports alongside the server and a 20-bot match, and say plainly if the answer is
"one".

## 4. Recommended path

1. **Now:** one client, GM account at `rank=4`, `spectate.sh` driving it.
   `.gm on`, `.gm visible off`, `.hover 1`, `.god on` before the match; capture that
   window with OBS.
2. **Next:** an overlay fed by `tournament poi`, `tournament result` and the
   telemetry CSV — score, team names, and who is carrying — since all of it is
   already emitted as parseable lines.
3. **Later, if the cuts prove too jarring:** a client-side addon for smooth tracking.
   That is real client development and cannot be validated by this repo's tooling,
   so it should not be attempted until someone has watched a real match and judged
   the cuts specifically.

## 5. Setup checklist

- GM account `rank=4` — `.hover` and `.bgtest` are refused at `rank=3` because
  `SEC_GAMEMASTER` is `#define`d to `SEC_ADMINISTRATOR`=4.
- **Never party the spectator to a bot.** `HasActivePlayerMaster()` is a hard gate
  in the bot's queue logic (`BattleGroundJoinAction.cpp:568`) and a partied bot never
  queues again.
- The spectator must not be a battleground member — `tournament camera` refuses a
  participant, because enrolling the camera would make the match 11v10.
- `.appear` into a battleground is supported and only fails if you are already inside
  a *different* battleground.
```

- [ ] **Step 4: Commit**

```bash
git add docs/playerbots/TOURNAMENT-STREAMING.md
git commit -m "docs(streaming): feasibility assessment with measured numbers"
```

---

## Done when

- `bash tests/tournament/spectate.test.sh` exits 0.
- `tournament poi` returns `reason=empty` for an empty instance and a real
  coordinate with a `combat` or `centroid` reason during a live match.
- `tournament camera` moves a GM above the action and **refuses** a bot that is a
  match participant.
- `spectate.sh` runs for a whole match and exits with a `SPECTATE ... repositions=<n>`
  line when the instance disappears.
- `docs/playerbots/TOURNAMENT-STREAMING.md` contains **measured** memory and CPU
  numbers from this host, and states plainly that a bot has no POV to capture.
