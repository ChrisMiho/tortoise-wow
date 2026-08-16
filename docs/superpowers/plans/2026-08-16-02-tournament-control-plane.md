# Tournament Control Plane (C++) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give scripts console-callable control over a battleground instance — create
it, put two named teams in it, start it, stop it, read its result — none of which is
reachable today.

**Architecture:** A `.tournament` command family in **core** (not the PlayerBots
module), registered console-callable, built on `BattleGroundMgr::CreateNewBattleGround`,
`Player::SetBattleGroundId`, `Player::SetBGTeam`, and
`BattleGroundMgr::SendToBattleGround`. Every command prints one machine-parseable
`TOURNAMENT ...` line and mirrors it into `bg.log`. A thin shell library parses those
lines.

**Tech Stack:** C++ (CMaNGOS-derived core), CMake, Docker build, Bash client.

**Spec:** `docs/superpowers/specs/2026-08-16-bot-tournament-design.md` (§2.4, §2.5)

**Depends on:** `2026-08-16-00-build-provenance-gate.md`. Every build in this plan is
validated through `scripts/validate-stack.sh`, so that must exist first.

## Global Constraints

- **Core, not the module.** Everything here uses core APIs (`Player`, `BattleGround`,
  `BattleGroundMgr`, item storage). Implementing in `src/game/` avoids the
  `PlayerbotStubs.cpp` dance entirely and keeps the commands working with
  `BUILD_PLAYERBOTS=OFF`.
- **`src/game/CMakeLists.txt` lists sources explicitly — it does not glob.** A new
  `.cpp` that is not added there compiles into nothing and the command silently does
  not exist. Add it next to `Commands/Commands.cpp` (line 90).
- **Console output is the API.** Every command prints exactly one line starting
  `TOURNAMENT ` with `key=value` fields. Anything else is human commentary.
- **Never send a bare `docker attach`.** Use `wsg_console`; console EOF shuts the
  world down and compose is `restart: "no"`.
- Battleground template rows are read **once at boot** (`World.cpp:2274`). No command
  here may assume a template change can be reloaded.
- WSG is `BATTLEGROUND_WS = 2` (`SharedDefines.h:1746`), map 489. Winner encoding is
  `WINNER_HORDE=0`, `WINNER_ALLIANCE=1`, `WINNER_NONE=2` (`BattleGround.h:187-189`).
- Rebuilds take ~9-10 minutes. Every task that changes C++ ends with
  `./scripts/rebuild.sh` and `./scripts/validate-stack.sh`, and **no task may claim
  success from reading the diff alone.**

---

## The risk this plan exists to retire

`HandleBattlefieldPortOpcode` is the only path that puts a player into a battleground
today, and it ends like this (`BattleGroundHandler.cpp:526-533`):

```cpp
_player->SetBattleGroundId(bg->GetInstanceID(), bgTypeId, queueSlot);
_player->SetBGTeam(ginfo.GroupTeam);
sBattleGroundMgr.SendToBattleGround(_player, ginfo.IsInvitedToBGInstanceGUID, bgTypeId);
// add only in HandleMoveWorldPortAck()
// bg->AddPlayer(_player,team);
```

`BattleGround::AddPlayer` is **deferred until the client acknowledges the world port**.
A playerbot has a `WorldSession` but no client. **Whether a bot ever acks a world port
— and so whether it is ever actually added to the battleground — is unknown.**

Task 3 answers this against the running server before anything is built on top of it.
If bots do not ack, stop and take the documented fallback in Task 3 Step 6 rather
than writing more C++ against a false assumption.

---

## File Structure

| File | Responsibility |
|---|---|
| `src/game/Commands/TournamentCommands.cpp` (create) | Every `.tournament` subcommand handler |
| `src/game/Chat/Chat.h` (modify) | Declare the handlers on `ChatHandler` |
| `src/game/Chat/Chat.cpp` (modify) | Register `tournamentCommandTable`, console-callable |
| `src/game/CMakeLists.txt` (modify) | Add the new source file |
| `scripts/tournament/lib/ctl.sh` (create) | Send a `.tournament` command and parse its `TOURNAMENT` line |
| `tests/tournament/ctl.test.sh` (create) | Tests for the parser, against captured output |

---

### Task 1: Command scaffolding and `tournament status`

The smallest change that proves registration, console-callability, and the output
contract all work — before any battleground state is touched.

**Files:**
- Create: `src/game/Commands/TournamentCommands.cpp`
- Modify: `src/game/Chat/Chat.h` (in the `ChatHandler` public handler declarations,
  near `bool HandleBGStatusCommand(char* args);`)
- Modify: `src/game/Chat/Chat.cpp` (add the table, register `tournament`)
- Modify: `src/game/CMakeLists.txt:90`

**Interfaces:**
- Produces: `tournament status` (console) → one line per live instance:
  `TOURNAMENT instance=<id> type=<n> map=<n> status=<WaitJoin|InProgress|WaitLeave> alliance=<n> horde=<n> elapsed=<s>`
  followed by `TOURNAMENT status count=<n>`.

- [ ] **Step 1: Add the source file**

```cpp
/* Tournament control plane.
 *
 * Console-callable battleground control, so an external runner can pair two
 * named teams deterministically instead of hoping the queue does it.
 *
 * Deliberately in core rather than the PlayerBots module: everything here uses
 * core APIs only, so it needs no PlayerbotStubs.cpp entry and keeps working with
 * BUILD_PLAYERBOTS=OFF.
 *
 * OUTPUT CONTRACT. Every subcommand prints exactly one line per record, starting
 * "TOURNAMENT " and continuing as space-separated key=value pairs, and mirrors it
 * into bg.log. Scripts parse those lines and nothing else -- do not reformat them
 * without updating scripts/tournament/lib/ctl.sh.
 */

#include "Chat.h"
#include "Language.h"
#include "World.h"
#include "ObjectMgr.h"
#include "ObjectAccessor.h"
#include "Player.h"
#include "BattleGround.h"
#include "BattleGroundMgr.h"
#include "Log.h"

// One place that both prints to the caller and durably records the same line.
// Console sessions can be detached mid-command; bg.log cannot.
void ChatHandler::TournamentEmit(std::string const& line)
{
    PSendSysMessage("TOURNAMENT %s", line.c_str());
    sLog.out(LOG_BG, "TOURNAMENT %s", line.c_str());
}

static char const* TournamentStatusName(BattleGroundStatus s)
{
    switch (s)
    {
        case STATUS_WAIT_JOIN:  return "WaitJoin";
        case STATUS_IN_PROGRESS: return "InProgress";
        case STATUS_WAIT_LEAVE: return "WaitLeave";
        default:                return "None";
    }
}

bool ChatHandler::HandleTournamentStatusCommand(char* /*args*/)
{
    uint32 count = 0;

    for (uint8 bgTypeId = BATTLEGROUND_AV; bgTypeId < MAX_BATTLEGROUND_TYPE_ID; ++bgTypeId)
    {
        for (BattleGroundSet::const_iterator it = sBattleGroundMgr.GetBattleGroundsBegin(BattleGroundTypeId(bgTypeId));
             it != sBattleGroundMgr.GetBattleGroundsEnd(BattleGroundTypeId(bgTypeId)); ++it)
        {
            // Instance id 0 is the template, not a live battleground.
            if (!it->first)
                continue;

            BattleGround* bg = it->second;
            uint32 ally = 0, horde = 0;
            for (const auto& p : bg->GetPlayers())
            {
                if (p.second.PlayerTeam == HORDE) ++horde;
                else                              ++ally;
            }

            std::ostringstream ss;
            ss << "instance=" << it->first
               << " type=" << uint32(bgTypeId)
               << " map=" << bg->GetMapId()
               << " status=" << TournamentStatusName(bg->GetStatus())
               << " alliance=" << ally
               << " horde=" << horde
               << " elapsed=" << (bg->GetStartTime() / 1000);
            TournamentEmit(ss.str());
            ++count;
        }
    }

    std::ostringstream ss;
    ss << "status count=" << count;
    TournamentEmit(ss.str());
    return true;
}
```

- [ ] **Step 2: Declare the handlers**

In `src/game/Chat/Chat.h`, in the same public block as `HandleBGStatusCommand`:

```cpp
        // Tournament control plane -- see src/game/Commands/TournamentCommands.cpp
        void TournamentEmit(std::string const& line);
        bool HandleTournamentStatusCommand(char* args);
```

- [ ] **Step 3: Register the command table**

In `src/game/Chat/Chat.cpp`, next to `bgCommandTable` (around line 741):

```cpp
    static ChatCommand tournamentCommandTable[] =
    {
        { "status",  SEC_ADMINISTRATOR, true,  &ChatHandler::HandleTournamentStatusCommand, "", nullptr },
        { nullptr,   0,                 false, nullptr,                                     "", nullptr }
    };
```

and in the main command table, next to the `bg` entry (around line 862):

```cpp
        // AllowConsole = true on BOTH the parent and every subcommand: `.bg` is
        // false and that is exactly why a script cannot drive a battleground.
        { "tournament",     SEC_ADMINISTRATOR,   true,  nullptr,                            "", tournamentCommandTable},
```

- [ ] **Step 4: Add the source to the build**

In `src/game/CMakeLists.txt`, immediately after the `Commands/Commands.cpp` line
(line 90):

```cmake
    Commands/TournamentCommands.cpp
```

This file is an explicit source list, not a glob. Omitting this line compiles
nothing and the command silently will not exist.

- [ ] **Step 5: Build**

Run: `./scripts/rebuild.sh`
Expected: `==> building <sha>` then every acceptance check `ok:`, ending with the
`:local` tag moved. ~9-10 minutes. A compile error here is almost always a missing
include or a `Chat.h` declaration that does not match the definition.

- [ ] **Step 6: Stand it up and verify the command exists**

```bash
./scripts/validate-stack.sh --image tortoise-cm:local --keep-up
```

Expected: `VALIDATE-STACK: PASS`.

Then, from WSL:

```bash
MSYS_NO_PATHCONV=1 bash <<'EOF'
source docs/playerbots/wsg/lib/wsg-bots-common.sh
wsg_console "tournament status" 8
EOF
```

Expected: at least `TOURNAMENT status count=0` (or a count matching any live
battleground). **`There is no such subcommand` or `Incorrect syntax` means the
table registration or the CMake line did not land** — fix that before continuing.

- [ ] **Step 7: Commit**

```bash
git add src/game/Commands/TournamentCommands.cpp src/game/Chat/Chat.h src/game/Chat/Chat.cpp src/game/CMakeLists.txt
git commit -m "feat(tournament): console-callable .tournament status"
```

---

### Task 2: `tournament create` — an instance with no queue

**Files:**
- Modify: `src/game/Commands/TournamentCommands.cpp`
- Modify: `src/game/Chat/Chat.h`
- Modify: `src/game/Chat/Chat.cpp` (`tournamentCommandTable`)

**Interfaces:**
- Consumes: `TournamentEmit` from Task 1.
- Produces: `tournament create <bgTypeId> <level>` →
  `TOURNAMENT create instance=<id> type=<n> map=<n> bracket=<n>` on success, or
  `TOURNAMENT create error=<reason>` on failure. `<level>` selects the bracket
  (use 60).

- [ ] **Step 1: Add the handler**

```cpp
bool ChatHandler::HandleTournamentCreateCommand(char* args)
{
    uint32 typeId = 0, level = 0;
    if (!ExtractUInt32(&args, typeId) || !ExtractUInt32(&args, level))
    {
        TournamentEmit("create error=usage(.tournament create <bgTypeId> <level>)");
        return true;
    }

    if (typeId == 0 || typeId >= MAX_BATTLEGROUND_TYPE_ID)
    {
        TournamentEmit("create error=bad_type_id");
        return true;
    }

    BattleGroundTypeId bgTypeId = BattleGroundTypeId(typeId);

    // The template is loaded once at boot (World.cpp:2274). If it is missing
    // there is nothing a command can do about it at runtime.
    if (!sBattleGroundMgr.GetBattleGroundTemplate(bgTypeId))
    {
        TournamentEmit("create error=no_template");
        return true;
    }

    BattleGroundBracketId bracketId =
        sBattleGroundMgr.GetBattleGroundBracketIdFromLevel(bgTypeId, level);

    BattleGround* bg = sBattleGroundMgr.CreateNewBattleGround(bgTypeId, bracketId);
    if (!bg)
    {
        TournamentEmit("create error=create_failed");
        return true;
    }

    std::ostringstream ss;
    ss << "create instance=" << bg->GetInstanceID()
       << " type=" << uint32(bgTypeId)
       << " map=" << bg->GetMapId()
       << " bracket=" << uint32(bracketId);
    TournamentEmit(ss.str());
    return true;
}
```

- [ ] **Step 2: Declare and register it**

`Chat.h`, beside the Task 1 declaration:

```cpp
        bool HandleTournamentCreateCommand(char* args);
```

`Chat.cpp`, in `tournamentCommandTable` before the terminator:

```cpp
        { "create",  SEC_ADMINISTRATOR, true,  &ChatHandler::HandleTournamentCreateCommand, "", nullptr },
```

- [ ] **Step 3: Build**

Run: `./scripts/rebuild.sh`
Expected: all acceptance checks `ok:`.

- [ ] **Step 4: Verify against the running server**

```bash
./scripts/validate-stack.sh --image tortoise-cm:local --keep-up
MSYS_NO_PATHCONV=1 bash <<'EOF'
source docs/playerbots/wsg/lib/wsg-bots-common.sh
wsg_console $'tournament create 2 60\ntournament status' 10
EOF
```

Expected: `TOURNAMENT create instance=<n> type=2 map=489 bracket=<n>`, then a
`TOURNAMENT instance=<same n> ... alliance=0 horde=0` line from `status`.

**An empty instance is the point of this task** — it proves a battleground can be
brought into existence with nobody queued, which the queue path cannot do.

Also confirm it landed in the log:

```bash
tail -5 ~/tortoise-wow-server-V2/logs/bg.log
```

Expected: the same `TOURNAMENT create ...` line.

- [ ] **Step 5: Commit**

```bash
git add src/game/Commands/TournamentCommands.cpp src/game/Chat/Chat.h src/game/Chat/Chat.cpp
git commit -m "feat(tournament): create a battleground instance without a queue"
```

---

### Task 3: `tournament add` — the world-port acknowledgement question

**This is the task the whole design hinges on.** Read "The risk this plan exists to
retire" above before starting.

**Files:**
- Modify: `src/game/Commands/TournamentCommands.cpp`
- Modify: `src/game/Chat/Chat.h`
- Modify: `src/game/Chat/Chat.cpp`

**Interfaces:**
- Produces: `tournament add <instanceId> <playerName>` →
  `TOURNAMENT add instance=<id> player=<name> team=<ALLIANCE|HORDE> sent=1`, or
  `TOURNAMENT add error=<reason>`.
- Produces: `tournament members <instanceId>` →
  `TOURNAMENT member instance=<id> player=<name> team=<n> map=<n>` per player
  actually inside `bg->GetPlayers()`, then
  `TOURNAMENT members instance=<id> count=<n>`.

`members` exists specifically to answer the acknowledgement question: `add` reports
what was *sent*, `members` reports who the battleground *actually holds*.

- [ ] **Step 1: Add both handlers**

```cpp
bool ChatHandler::HandleTournamentAddCommand(char* args)
{
    uint32 instanceId = 0;
    if (!ExtractUInt32(&args, instanceId))
    {
        TournamentEmit("add error=usage(.tournament add <instanceId> <playerName>)");
        return true;
    }

    char* nameStr = ExtractQuotedOrLiteralArg(&args);
    if (!nameStr)
    {
        TournamentEmit("add error=no_player_name");
        return true;
    }

    std::string name = nameStr;
    Player* plr = sObjectAccessor.FindPlayerByName(name.c_str());
    if (!plr)
    {
        TournamentEmit("add error=player_not_online(" + name + ")");
        return true;
    }

    // The instance has to be found through the same type the caller created it
    // with; GetBattleGround wants both.
    BattleGround* bg = nullptr;
    for (uint8 t = BATTLEGROUND_AV; t < MAX_BATTLEGROUND_TYPE_ID && !bg; ++t)
        bg = sBattleGroundMgr.GetBattleGround(instanceId, BattleGroundTypeId(t));

    if (!bg)
    {
        TournamentEmit("add error=no_such_instance");
        return true;
    }

    if (plr->InBattleGround())
    {
        TournamentEmit("add error=already_in_a_battleground(" + name + ")");
        return true;
    }

    // Cross-faction only, by design: SetBGTeam controls scoring and spawn side but
    // NOT hostility -- Unit::IsHostileTo resolves through faction templates
    // (Unit.cpp:5189) and never consults GetBGTeam(). A player put on the opposing
    // side would spawn correctly and then refuse to fight. So the side is always
    // the player's real team.
    Team team = plr->GetTeam();

    // This mirrors HandleBattlefieldPortOpcode (BattleGroundHandler.cpp:522-531)
    // minus the queue bookkeeping, since there is no queue entry to retire.
    plr->SetBattleGroundId(bg->GetInstanceID(), bg->GetTypeID(), 0);
    plr->SetBGTeam(team);
    sBattleGroundMgr.SendToBattleGround(plr, bg->GetInstanceID(), bg->GetTypeID());

    std::ostringstream ss;
    ss << "add instance=" << bg->GetInstanceID()
       << " player=" << name
       << " team=" << (team == HORDE ? "HORDE" : "ALLIANCE")
       << " sent=1";
    TournamentEmit(ss.str());
    return true;
}

bool ChatHandler::HandleTournamentMembersCommand(char* args)
{
    uint32 instanceId = 0;
    if (!ExtractUInt32(&args, instanceId))
    {
        TournamentEmit("members error=usage(.tournament members <instanceId>)");
        return true;
    }

    BattleGround* bg = nullptr;
    for (uint8 t = BATTLEGROUND_AV; t < MAX_BATTLEGROUND_TYPE_ID && !bg; ++t)
        bg = sBattleGroundMgr.GetBattleGround(instanceId, BattleGroundTypeId(t));

    if (!bg)
    {
        TournamentEmit("members error=no_such_instance");
        return true;
    }

    uint32 count = 0;
    for (const auto& p : bg->GetPlayers())
    {
        std::string nm;
        if (!sObjectMgr.GetPlayerNameByGUID(p.first, nm))
            nm = "?";

        Player* plr = sObjectAccessor.FindPlayer(p.first);

        std::ostringstream ss;
        ss << "member instance=" << instanceId
           << " player=" << nm
           << " team=" << uint32(p.second.PlayerTeam)
           << " map=" << (plr ? plr->GetMapId() : 0);
        TournamentEmit(ss.str());
        ++count;
    }

    std::ostringstream ss;
    ss << "members instance=" << instanceId << " count=" << count;
    TournamentEmit(ss.str());
    return true;
}
```

- [ ] **Step 2: Declare and register**

`Chat.h`:

```cpp
        bool HandleTournamentAddCommand(char* args);
        bool HandleTournamentMembersCommand(char* args);
```

`Chat.cpp`, in `tournamentCommandTable`:

```cpp
        { "add",     SEC_ADMINISTRATOR, true,  &ChatHandler::HandleTournamentAddCommand,     "", nullptr },
        { "members", SEC_ADMINISTRATOR, true,  &ChatHandler::HandleTournamentMembersCommand, "", nullptr },
```

- [ ] **Step 3: Build**

Run: `./scripts/rebuild.sh`
Expected: all acceptance checks `ok:`.

- [ ] **Step 4: Run the acknowledgement experiment**

```bash
./scripts/validate-stack.sh --image tortoise-cm:local --keep-up
./scripts/tournament/roster.sh login stormwind-sentinels    # need a bot online
```

Then:

```bash
MSYS_NO_PATHCONV=1 bash <<'EOF'
source docs/playerbots/wsg/lib/wsg-bots-common.sh
out=$(wsg_console $'tournament create 2 60' 10)
echo "$out" | grep -a "TOURNAMENT create"
inst=$(echo "$out" | sed -n 's/.*TOURNAMENT create instance=\([0-9]*\).*/\1/p' | head -1)
echo "instance=$inst"
wsg_console "tournament add $inst Wsgaone" 10
sleep 20
wsg_console "tournament members $inst" 10
wsg_mysql "SELECT name, map, online FROM tw_char.characters WHERE name='Wsgaone';"
EOF
```

- [ ] **Step 5: Record the verdict explicitly**

Write the outcome into `docs/playerbots/TOURNAMENT-CONTROL-PLANE.md` under a
heading `## World-port acknowledgement — measured`. State which of these happened:

| Observation | Meaning |
|---|---|
| `members ... count=1` **and** the bot's `map` reads 489 | **Direct add works.** Bots ack world ports. Continue to Task 4. |
| `add ... sent=1` but `members ... count=0`, map still the old one | **Bots do not ack.** The teleport was sent and dropped. Take the fallback in Step 6. |
| `members count=0` but map *is* 489 | Bot moved but was never registered — `AddPlayer` never ran. Same fallback. |

Record the literal console output and the DB row, not a summary. This measurement
is the reason the task exists.

- [ ] **Step 6: If bots do not acknowledge — take the fallback**

Do **not** keep writing C++ against a teleport that does not land. The proven path
already exists: `wsg_bgjoin_lines` in `docs/playerbots/wsg/lib/wsg-bots-common.sh`
sets each bot's `bg type` to `2` and issues `bg join`, which is measured at 8/8
commanded joins after the `BGJoinAction::isUseful()` fix.

In that case:

1. Keep `create`, `status` and `members` — they are still how the runner observes a
   match.
2. Replace `add` with `tournament queue <playerName> <bgTypeId>`, which sets the
   bot's `bg type` value and triggers its `bg join` action server-side, so the
   runner still has one command rather than two console round-trips per bot.
3. Accept the consequence and write it into the doc: **only one match can be
   assembled at a time**, because the queue pairs whoever is queued. That is
   already the agreed design (spec §2.3), so it costs nothing today — but it does
   permanently rule out concurrent matches, which the direct-add path would have
   allowed.
4. Mark Task 4's `start`/`stop` as still applicable — they operate on the instance
   the queue produced, and the queue pop gives you its id from `bg.log`.

- [ ] **Step 7: Commit**

```bash
git add src/game/Commands/TournamentCommands.cpp src/game/Chat/Chat.h src/game/Chat/Chat.cpp docs/playerbots/TOURNAMENT-CONTROL-PLANE.md
git commit -m "feat(tournament): add players to an instance directly, and measure whether it lands"
```

---

### Task 4: `tournament start` and `tournament stop`

**Files:**
- Modify: `src/game/Commands/TournamentCommands.cpp`
- Modify: `src/game/Chat/Chat.h`
- Modify: `src/game/Chat/Chat.cpp`

**Interfaces:**
- Produces:
  - `tournament start <instanceId>` → `TOURNAMENT start instance=<id> ok=1`
  - `tournament stop <instanceId>` → `TOURNAMENT stop instance=<id> ok=1`

These are the console-callable equivalents of `.bg start` / `.bg stop`, which
require a GM standing inside the instance (`Commands.cpp:14212-14257`) and are
registered `AllowConsole = false` (`Chat.cpp:862`).

- [ ] **Step 1: Add a lookup helper and both handlers**

Replace the duplicated instance-lookup loops with one static helper, and add the
two commands:

```cpp
// Instance ids are unique across types in practice, but GetBattleGround wants a
// type, so sweep. Three duplicated copies of this loop was two too many.
static BattleGround* TournamentFindInstance(uint32 instanceId)
{
    for (uint8 t = BATTLEGROUND_AV; t < MAX_BATTLEGROUND_TYPE_ID; ++t)
        if (BattleGround* bg = sBattleGroundMgr.GetBattleGround(instanceId, BattleGroundTypeId(t)))
            return bg;
    return nullptr;
}

bool ChatHandler::HandleTournamentStartCommand(char* args)
{
    uint32 instanceId = 0;
    if (!ExtractUInt32(&args, instanceId))
    {
        TournamentEmit("start error=usage(.tournament start <instanceId>)");
        return true;
    }

    BattleGround* bg = TournamentFindInstance(instanceId);
    if (!bg)
    {
        TournamentEmit("start error=no_such_instance");
        return true;
    }

    // Same mechanism as .bg start (Commands.cpp:14212) -- collapse the countdown
    // rather than calling a start method, because the countdown IS the start.
    bg->SetStartDelayTime(0);

    std::ostringstream ss;
    ss << "start instance=" << instanceId << " ok=1";
    TournamentEmit(ss.str());
    return true;
}

bool ChatHandler::HandleTournamentStopCommand(char* args)
{
    uint32 instanceId = 0;
    if (!ExtractUInt32(&args, instanceId))
    {
        TournamentEmit("stop error=usage(.tournament stop <instanceId>)");
        return true;
    }

    BattleGround* bg = TournamentFindInstance(instanceId);
    if (!bg)
    {
        TournamentEmit("stop error=no_such_instance");
        return true;
    }

    bg->StopBattleGround();

    std::ostringstream ss;
    ss << "stop instance=" << instanceId << " ok=1";
    TournamentEmit(ss.str());
    return true;
}
```

Then replace the inline lookup loops in `HandleTournamentAddCommand` and
`HandleTournamentMembersCommand` with `TournamentFindInstance(instanceId)`.

- [ ] **Step 2: Declare and register**

`Chat.h`:

```cpp
        bool HandleTournamentStartCommand(char* args);
        bool HandleTournamentStopCommand(char* args);
```

`Chat.cpp`:

```cpp
        { "start",   SEC_ADMINISTRATOR, true,  &ChatHandler::HandleTournamentStartCommand,   "", nullptr },
        { "stop",    SEC_ADMINISTRATOR, true,  &ChatHandler::HandleTournamentStopCommand,    "", nullptr },
```

- [ ] **Step 3: Build**

Run: `./scripts/rebuild.sh`
Expected: all acceptance checks `ok:`.

- [ ] **Step 4: Verify the lifecycle end to end**

```bash
./scripts/validate-stack.sh --image tortoise-cm:local --keep-up
MSYS_NO_PATHCONV=1 bash <<'EOF'
source docs/playerbots/wsg/lib/wsg-bots-common.sh
out=$(wsg_console "tournament create 2 60" 10)
inst=$(echo "$out" | sed -n 's/.*TOURNAMENT create instance=\([0-9]*\).*/\1/p' | head -1)
wsg_console $"tournament status" 8 | grep -a "instance=$inst"
wsg_console "tournament start $inst" 8
sleep 5
wsg_console "tournament status" 8 | grep -a "instance=$inst"
wsg_console "tournament stop $inst" 8
EOF
```

Expected: `status` reads `status=WaitJoin` before `start`, `status=InProgress`
after, and after `stop` either `status=WaitLeave` or the instance is gone from
`status` entirely. Both are correct outcomes for `stop`.

- [ ] **Step 5: Commit**

```bash
git add src/game/Commands/TournamentCommands.cpp src/game/Chat/Chat.h src/game/Chat/Chat.cpp
git commit -m "feat(tournament): console-callable start/stop for an instance"
```

---

### Task 5: `tournament result` — the score as data

**Files:**
- Modify: `src/game/Commands/TournamentCommands.cpp`
- Modify: `src/game/Chat/Chat.h`
- Modify: `src/game/Chat/Chat.cpp`

**Interfaces:**
- Produces: `tournament result <instanceId>` →
  `TOURNAMENT result instance=<id> winner=<HORDE|ALLIANCE|NONE> allianceScore=<n> hordeScore=<n> status=<name> elapsed=<s>`

Today a result is a scraped `bg.log` line whose `duration` field includes up to
120 s of post-match cleanup and therefore is not the match length. This makes the
score a first-class read.

- [ ] **Step 1: Confirm the score accessors before writing against them**

The winner accessor and the per-team score accessor differ between forks. Check
this tree:

```bash
grep -n "GetWinner\|GetStatus\|WINNER_" src/game/Battlegrounds/BattleGround.h | head -20
grep -n "GetTeamScore\|m_TeamScores" src/game/Battlegrounds/BattleGround.h | head -10
```

Use whatever this tree actually declares. If a per-team score accessor does not
exist on the base class, emit `allianceScore=-1 hordeScore=-1` and note in the doc
that flag captures must come from `bg.log` honor bursts instead — do **not** invent
an accessor.

- [ ] **Step 2: Add the handler**

```cpp
bool ChatHandler::HandleTournamentResultCommand(char* args)
{
    uint32 instanceId = 0;
    if (!ExtractUInt32(&args, instanceId))
    {
        TournamentEmit("result error=usage(.tournament result <instanceId>)");
        return true;
    }

    BattleGround* bg = TournamentFindInstance(instanceId);
    if (!bg)
    {
        // A finished battleground is destroyed, so this is the normal way to
        // learn a match is over -- not an error the caller should retry.
        TournamentEmit("result error=no_such_instance(finished_or_never_existed)");
        return true;
    }

    char const* winner = "NONE";
    switch (bg->GetWinner())
    {
        case WINNER_HORDE:    winner = "HORDE";    break;
        case WINNER_ALLIANCE: winner = "ALLIANCE"; break;
        default:              winner = "NONE";     break;
    }

    std::ostringstream ss;
    ss << "result instance=" << instanceId
       << " winner=" << winner
       << " allianceScore=" << bg->GetTeamScore(ALLIANCE)
       << " hordeScore=" << bg->GetTeamScore(HORDE)
       << " status=" << TournamentStatusName(bg->GetStatus())
       << " elapsed=" << (bg->GetStartTime() / 1000);
    TournamentEmit(ss.str());
    return true;
}
```

Adjust `GetWinner()` / `GetTeamScore()` to the names Step 1 found.

- [ ] **Step 3: Declare, register, build**

`Chat.h`: `bool HandleTournamentResultCommand(char* args);`

`Chat.cpp`: `{ "result", SEC_ADMINISTRATOR, true, &ChatHandler::HandleTournamentResultCommand, "", nullptr },`

Run: `./scripts/rebuild.sh`
Expected: all acceptance checks `ok:`.

- [ ] **Step 4: Verify**

```bash
./scripts/validate-stack.sh --image tortoise-cm:local --keep-up
MSYS_NO_PATHCONV=1 bash <<'EOF'
source docs/playerbots/wsg/lib/wsg-bots-common.sh
out=$(wsg_console "tournament create 2 60" 10)
inst=$(echo "$out" | sed -n 's/.*instance=\([0-9]*\).*/\1/p' | head -1)
wsg_console "tournament result $inst" 8
EOF
```

Expected: `TOURNAMENT result instance=<n> winner=NONE allianceScore=0 hordeScore=0
status=WaitJoin elapsed=<n>` — a fresh instance has no winner, and that is the
correct answer, not a failure.

- [ ] **Step 5: Commit**

```bash
git add src/game/Commands/TournamentCommands.cpp src/game/Chat/Chat.h src/game/Chat/Chat.cpp
git commit -m "feat(tournament): read a match result as structured data"
```

---

### Task 6: `tournament equip` — itemized gear application

**Files:**
- Modify: `src/game/Commands/TournamentCommands.cpp`
- Modify: `src/game/Chat/Chat.h`
- Modify: `src/game/Chat/Chat.cpp`

**Interfaces:**
- Produces: `tournament equip <playerName> <itemId>[,<itemId>...]` →
  one `TOURNAMENT equip player=<name> item=<id> slot=<n> ok=<0|1> reason=<text>`
  line per item, then `TOURNAMENT equip player=<name> equipped=<n> failed=<n>`.

This is what the gear plan (`2026-08-16-03-gear-loadouts.md`) calls to apply a
tier, and what the viewer-effects plan calls to upgrade a bot mid-match. It is
here rather than there because it is C++ and belongs with the rest of the command
family.

- [ ] **Step 1: Add the handler**

```cpp
bool ChatHandler::HandleTournamentEquipCommand(char* args)
{
    char* nameStr = ExtractQuotedOrLiteralArg(&args);
    if (!nameStr)
    {
        TournamentEmit("equip error=usage(.tournament equip <playerName> <itemId>[,<itemId>...])");
        return true;
    }
    std::string name = nameStr;

    char* itemStr = ExtractLiteralArg(&args);
    if (!itemStr)
    {
        TournamentEmit("equip error=no_items");
        return true;
    }

    Player* plr = sObjectAccessor.FindPlayerByName(name.c_str());
    if (!plr)
    {
        TournamentEmit("equip error=player_not_online(" + name + ")");
        return true;
    }

    uint32 equipped = 0, failed = 0;
    std::string list(itemStr);
    size_t pos = 0;

    while (pos <= list.size())
    {
        size_t comma = list.find(',', pos);
        std::string tok = list.substr(pos, comma == std::string::npos ? std::string::npos : comma - pos);
        pos = (comma == std::string::npos) ? list.size() + 1 : comma + 1;
        if (tok.empty())
            continue;

        uint32 itemId = uint32(atoi(tok.c_str()));
        std::ostringstream ss;
        ss << "equip player=" << name << " item=" << itemId;

        ItemPrototype const* proto = sObjectMgr.GetItemPrototype(itemId);
        if (!proto)
        {
            ss << " slot=-1 ok=0 reason=no_such_item";
            TournamentEmit(ss.str());
            ++failed;
            continue;
        }

        uint16 dest = 0;
        // swap=true: the slot is expected to be occupied by the previous tier.
        // Passing false makes every re-gear of an already-dressed bot fail with
        // "slot in use", which is the normal case, not the exception.
        InventoryResult res = plr->CanEquipNewItem(NULL_SLOT, dest, itemId, true);
        if (res != EQUIP_ERR_OK)
        {
            ss << " slot=-1 ok=0 reason=cannot_equip(" << uint32(res) << ")";
            TournamentEmit(ss.str());
            ++failed;
            continue;
        }

        if (!plr->EquipNewItem(dest, itemId, true))
        {
            ss << " slot=" << uint32(dest & 255) << " ok=0 reason=equip_failed";
            TournamentEmit(ss.str());
            ++failed;
            continue;
        }

        ss << " slot=" << uint32(dest & 255) << " ok=1 reason=-";
        TournamentEmit(ss.str());
        ++equipped;
    }

    // Persist immediately. A bot logged out by the runner between rounds would
    // otherwise lose gear applied less than PlayerSave.Interval (60s) ago.
    plr->SaveToDB();

    std::ostringstream ss;
    ss << "equip player=" << name << " equipped=" << equipped << " failed=" << failed;
    TournamentEmit(ss.str());
    return true;
}
```

- [ ] **Step 2: Declare, register, build**

`Chat.h`: `bool HandleTournamentEquipCommand(char* args);`

`Chat.cpp`: `{ "equip", SEC_ADMINISTRATOR, true, &ChatHandler::HandleTournamentEquipCommand, "", nullptr },`

Run: `./scripts/rebuild.sh`
Expected: all acceptance checks `ok:`.

- [ ] **Step 3: Verify with a known-good item**

Item 12640 is *Lionheart Helm* (level 60 plate head). Pick any real level-60 item
appropriate to a warrior; confirm it exists first:

```bash
MSYS_NO_PATHCONV=1 bash <<'EOF'
source docs/playerbots/wsg/lib/wsg-bots-common.sh
wsg_mysql "SELECT entry, name, class, subclass, InventoryType, Quality, ItemLevel
           FROM tw_world.item_template WHERE entry=12640;"
EOF
```

Then:

```bash
./scripts/tournament/roster.sh login stormwind-sentinels
MSYS_NO_PATHCONV=1 bash <<'EOF'
source docs/playerbots/wsg/lib/wsg-bots-common.sh
wsg_console "tournament equip Wsgaone 12640" 10
sleep 3
wsg_mysql "SELECT ci.slot, ii.itemEntry
           FROM tw_char.character_inventory ci
           JOIN tw_char.item_instance ii ON ii.guid = ci.item
           JOIN tw_char.characters c ON c.guid = ci.guid
           WHERE c.name='Wsgaone' AND ci.bag=0 ORDER BY ci.slot;"
EOF
```

Expected: `TOURNAMENT equip player=Wsgaone item=12640 slot=0 ok=1`, then
`equipped=1 failed=0`, and the DB shows `itemEntry=12640` in the head slot.

A `reason=cannot_equip(<n>)` is still a useful result — look the code up in
`InventoryResult` (`SharedDefines.h`) and record what it was. A class mismatch or
a level requirement is a bad *item choice*, not a broken command.

- [ ] **Step 4: Commit**

```bash
git add src/game/Commands/TournamentCommands.cpp src/game/Chat/Chat.h src/game/Chat/Chat.cpp
git commit -m "feat(tournament): equip itemized gear onto a named bot"
```

---

### Task 7: Shell client and documentation

**Files:**
- Create: `scripts/tournament/lib/ctl.sh`
- Test: `tests/tournament/ctl.test.sh`
- Modify: `docs/playerbots/TOURNAMENT-CONTROL-PLANE.md`

**Interfaces:**
- Consumes: `wsg_console`.
- Produces:
  - `ctl <command...>` → sends one console command, echoes only `TOURNAMENT ` lines
  - `ctl_field <output> <key>` → the value of one `key=` field from a captured line
  - `ctl_create <bgTypeId> <level>` → echoes the new instance id, exit 1 on error

- [ ] **Step 1: Write the failing test**

```bash
# tests/tournament/ctl.test.sh
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../.."
. "$HERE/../lib/assert.sh"
. "$ROOT/scripts/tournament/lib/ctl.sh"

SAMPLE='some console noise
TOURNAMENT create instance=101 type=2 map=489 bracket=5
more noise'

assert_eq "101" "$(ctl_field "$SAMPLE" instance)" "extracts instance"
assert_eq "489" "$(ctl_field "$SAMPLE" map)"      "extracts map"
assert_eq ""    "$(ctl_field "$SAMPLE" nosuch)"   "missing key is empty"

# A key that is a prefix of another must not match the wrong one.
SAMPLE2='TOURNAMENT equip player=Wsgaone item=12640 slot=0 ok=1'
assert_eq "1" "$(ctl_field "$SAMPLE2" ok)"   "ok is not confused with a longer key"
assert_eq "0" "$(ctl_field "$SAMPLE2" slot)" "slot reads 0, not empty"

ERR='TOURNAMENT create error=no_template'
assert_eq "no_template" "$(ctl_field "$ERR" error)" "extracts an error reason"

assert_summary
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/tournament/ctl.test.sh`
Expected: FAIL — `scripts/tournament/lib/ctl.sh: No such file or directory`

- [ ] **Step 3: Write the library**

```bash
#!/usr/bin/env bash
# Talk to the .tournament control plane. Source, don't execute.
#
# The console prints a lot besides our lines, and rndbot-style replies vanish
# entirely -- so every read here filters for the "TOURNAMENT " prefix and parses
# key=value pairs. If the C++ output format changes, this file changes with it.

CTL_WAIT="${CTL_WAIT:-10}"

# Sends one command and echoes only the TOURNAMENT lines it produced.
ctl() { # <command...>
    wsg_console "$*" "$CTL_WAIT" | grep -a '^TOURNAMENT ' || true
}

# One key's value out of captured output. Anchored on a word boundary so `ok`
# does not match inside `okay` and `slot=0` does not read as empty.
ctl_field() { # <captured-output> <key>
    printf '%s\n' "$1" | sed -n "s/.*[[:space:]]$2=\\([^[:space:]]*\\).*/\\1/p" | head -1
}

# Create an instance and echo its id. Exit 1 (with the reason on stderr) if the
# server reported an error instead.
ctl_create() { # <bgTypeId> <level>
    local out err inst
    out="$(ctl "tournament create $1 $2")"
    err="$(ctl_field "$out" error)"
    if [ -n "$err" ]; then
        echo "tournament create failed: $err" >&2
        return 1
    fi
    inst="$(ctl_field "$out" instance)"
    if [ -z "$inst" ]; then
        echo "tournament create returned no instance id; raw output:" >&2
        printf '%s\n' "$out" >&2
        return 1
    fi
    printf '%s\n' "$inst"
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bash tests/tournament/ctl.test.sh`
Expected: `6 passed, 0 failed`, exit 0

- [ ] **Step 5: Finish the doc**

Complete `docs/playerbots/TOURNAMENT-CONTROL-PLANE.md` — it already holds the
Task 3 measurement. Add:

```markdown
# Tournament control plane

Console-callable battleground control. Everything here is `AllowConsole = true`,
which is the entire point: `.bg start`/`.bg stop`/`.bg status` are
`AllowConsole = false` and require a GM standing inside the instance
(`Chat.cpp:862`, `Commands.cpp:14212-14257`), so no script can drive them.

Implemented in **core** (`src/game/Commands/TournamentCommands.cpp`), not the
PlayerBots module — it uses only core APIs, needs no `PlayerbotStubs.cpp` entry,
and works with `BUILD_PLAYERBOTS=OFF`.

## Commands

| Command | Emits |
|---|---|
| `tournament status` | one line per live instance, then `status count=<n>` |
| `tournament create <bgTypeId> <level>` | `create instance=<id> type=<n> map=<n> bracket=<n>` |
| `tournament add <instanceId> <playerName>` | `add instance=<id> player=<name> team=<side> sent=1` |
| `tournament members <instanceId>` | one line per player the BG actually holds, then a count |
| `tournament start <instanceId>` | `start instance=<id> ok=1` |
| `tournament stop <instanceId>` | `stop instance=<id> ok=1` |
| `tournament result <instanceId>` | `result instance=<id> winner=<side> ...` |
| `tournament equip <playerName> <ids>` | one line per item, then `equipped=<n> failed=<n>` |

`bgTypeId` for Warsong Gulch is `2` (`SharedDefines.h:1746`).

## Output contract

Every record is one line beginning `TOURNAMENT `, then space-separated
`key=value` pairs, printed to the console **and** mirrored into `bg.log`. Parse
with `scripts/tournament/lib/ctl.sh`; do not change the format without changing
that file.

`add` reports what was *sent*. `members` reports what the battleground *holds*.
They are different questions — see the measurement section above for why that
distinction is load-bearing.

## Cross-faction only

`add` always uses the player's real team. `SetBGTeam` controls scoring and spawn
side but **not** hostility: `Unit::IsHostileTo` resolves through faction templates
(`Unit.cpp:5189`) and never consults `GetBGTeam()`. A bot placed on the opposing
side spawns and scores correctly, then refuses to fight.
```

- [ ] **Step 6: Commit**

```bash
git add scripts/tournament/lib/ctl.sh tests/tournament/ctl.test.sh docs/playerbots/TOURNAMENT-CONTROL-PLANE.md
git commit -m "feat(tournament): shell client for the control plane, and document it"
```

---

## Done when

- `bash tests/tournament/ctl.test.sh` exits 0.
- Against a stack validated by `scripts/validate-stack.sh`:
  `tournament create 2 60` returns an instance id, `tournament status` shows it,
  `tournament start`/`stop` move its status, and `tournament result` returns a
  structured line.
- `docs/playerbots/TOURNAMENT-CONTROL-PLANE.md` records the **measured** answer to
  the world-port acknowledgement question, with literal console output — and, if
  the answer was "bots do not ack", the fallback in Task 3 Step 6 has been taken
  and the concurrency consequence written down.
- `tournament equip` puts a real item into a real slot, confirmed in
  `character_inventory`.
