# Tournament control plane

Console-callable battleground control: create an instance, put named players in
it, start it, stop it, read its result, and gear a bot — none of which a script
could reach before.

Implemented in `src/game/Commands/TournamentCommands.cpp`, driven from
`scripts/tournament/lib/ctl.sh`.

---

## Why every command is `AllowConsole = true`

`.bg` already looks like it does this job. It cannot, and the reason is not
policy but the handlers themselves.

`.bg` is registered with `AllowConsole = false` on the parent entry
(`Chat.cpp:862`) and on each of `status`, `start` and `stop`
(`Chat.cpp:743-745`), because every one of those handlers opens with

```cpp
Player* chr = m_session->GetPlayer();
ASSERT(chr);
BattleGround* pBg = chr->GetBattleGround();
```

(`Commands.cpp:14118` for `status`, `14212-14257` for `start`/`stop`). They need
a GM character standing *inside* the instance, and from the console there is no
`m_session` at all. Flipping the flag would not make them work; it would crash
the world.

So the `.tournament` family is a parallel set of handlers that take the instance
id as an argument and never touch `m_session`. `AllowConsole` is `true` on the
`tournament` parent entry **and on every subcommand** — a parent alone is not
enough, `isAvailable` is consulted per command.

## Why it lives in core, not the PlayerBots module

Everything here uses core APIs only: `Player`, `BattleGround`,
`BattleGroundMgr`, and the core item-storage calls. Putting it in
`src/game/Commands/` rather than the PlayerBots module means:

- it needs **no `PlayerbotStubs.cpp` entry** — that file exists to satisfy the
  linker for module symbols the core references, and there are none here;
- it **keeps working with `BUILD_PLAYERBOTS=OFF`**, so a build without bots
  still has a scriptable battleground.

One consequence worth knowing: `src/game/CMakeLists.txt` lists its sources
explicitly and does **not** glob. A `.cpp` that is not listed there compiles
into nothing and the command silently does not exist — which presents as
`There is no such subcommand`, indistinguishable from a typo.

---

## Commands

Every subcommand is `SEC_ADMINISTRATOR`, `AllowConsole = true`. Sent from the
console **without** a leading dot (`tournament status`, not `.tournament
status`); in-game chat keeps the dot.

| Command | Emits |
|---|---|
| `tournament status` | one `instance=… type=… map=… status=<WaitJoin\|InProgress\|WaitLeave> alliance=… horde=… elapsed=…` per live instance, then `status count=<n>` |
| `tournament create <bgTypeId> <level>` | `create instance=… type=… map=… bracket=…`, or `create error=<reason>` |
| `tournament add <instanceId> <playerName>` | `add instance=… player=… team=<ALLIANCE\|HORDE> sent=1`, or `add error=<reason>` |
| `tournament members <instanceId>` | one `member instance=… player=… team=… map=…` per player the battleground actually holds, then `members instance=… count=<n>` |
| `tournament start <instanceId>` | `start instance=… ok=1` |
| `tournament stop <instanceId>` | `stop instance=… ok=1` |
| `tournament result <instanceId>` | `result instance=… winner=<HORDE\|ALLIANCE\|NONE> allianceScore=… hordeScore=… status=… elapsed=…` |
| `tournament equip <playerName> <itemId>[,<itemId>…]` | one `equip player=… item=… slot=… ok=<0\|1> reason=…` per item, then `equip player=… equipped=<n> failed=<n>` |
| `tournament store <playerName> <itemId> <count>` | `store player=… item=… count=… ok=<0\|1> reason=…` |

Notes that are easy to get wrong:

- `bgTypeId` for Warsong Gulch is **`2`** (`SharedDefines.h:1746`); its map is
  489. `<level>` only selects the bracket — use `60`.
- `status` skips instance id `0`: that is the template, not a live battleground.
- **`create` gives you 80 seconds to `add` into the instance.** A battleground
  with nobody in it and nobody invited is normally deleted by
  `BattleGround::Update` on the very next map tick, and there is no queue behind a
  console-created one to invite anyone. `create` therefore arms a grace window
  (`BattleGround::SetEmptyHoldTime`, 80 s = `INVITE_ACCEPT_WAIT_TIME`); the first
  successful `add` clears it, because the invited count takes over as the
  instance's lifetime from then on. Sit on an instance id longer than that and
  `add` answers `no_such_instance` — correctly, the instance reaped itself.
- **`add` refuses a player who is already in a battleground queue**
  (`add error=player_in_bg_queue(<name>)`) or mid-teleport
  (`add error=player_teleporting(<name>)`), and reports a teleport the core
  refused as `add error=teleport_failed(<name>)` rather than `sent=1`. Assemble a
  tournament out of idle bots: `add` has to park its invite in one of the player's
  three battleground queue slots, and taking a queued player would overwrite a
  real queue invite.
- An `add` whose port never lands releases itself after 80 s and writes
  `[tournament] invite to instance … expired for …` to `bg.log` — no `TOURNAMENT `
  prefix, so parsers skip it. Without that release the instance and its
  battleground map would be held for the life of the process.
- `start` does not call a "start" method. It collapses the countdown with
  `SetStartDelayTime(0)`, because the countdown **is** the start — the same
  mechanism `.bg start` uses.
- `result` on an unknown id emits
  `result error=no_such_instance(finished_or_never_existed)`. A finished
  battleground is destroyed, so that is the normal way to learn a match is
  over, not an error to retry.
- `result` reports `allianceScore=-1 hordeScore=-1` for any battleground that is
  not WSG. `GetTeamScore` is declared on `BattleGroundWS`
  (`BattleGroundWS.h:185`), not on the base class, so the score is only readable
  behind a downcast. `-1` keeps "not exposed here" distinguishable from a real
  0-0.
- `equip` is for equipment and `store` is for consumables. `store` is not a
  convenience alias — `CanEquipNewItem` refuses a potion, correctly.

---

## Output contract

Every record is **one line**, beginning `TOURNAMENT `, then space-separated
`key=value` pairs. Each line is printed to the console **and** mirrored into
`bg.log` through `TournamentEmit`, because a console session can be detached
mid-command and a log file cannot.

Two properties the parser depends on:

- **A value contains no spaces.** The value is read as everything up to the next
  space. The `error=usage(...)` strings are the one place this is violated, and
  they read truncated at the first space — acceptable, because the caller only
  needs to know an error happened and roughly which.
- **The prompt is not part of the line.** `commandFinished` writes
  `printf("mangos>")` with no trailing newline (`CliRunnable.cpp:66-70`), so with
  more than one command in flight the prompt arrives glued to the front of the
  next command's first output line. Read the marker unanchored.

**`scripts/tournament/lib/ctl.sh` is the only thing that parses this.** Change
the format in `TournamentCommands.cpp` and you change that file in the same
commit; nothing else should ever grep for `TOURNAMENT `.

```bash
source docs/playerbots/wsg/lib/wsg-bots-common.sh   # for wsg_console
source scripts/tournament/lib/ctl.sh                # source, never execute

inst="$(ctl_create 2 60)" || exit 1                 # echoes the new instance id
ctl "tournament add $inst Wsgaone"                  # echoes only TOURNAMENT lines
out="$(ctl "tournament members $inst")"
ctl_field "$out" count                              # -> the member count
```

`ctl_field` is anchored on both sides: the key must be preceded by a space, so
`stance` does not match inside `instance=101`, and must be followed by `=`, so
`ok` does not match a longer `okay=`. A field whose value is `0` reads `0`, not
empty — `slot=0` is the head slot and the most ordinary thing `equip` reports.
`tests/tournament/ctl.test.sh` pins all of that and needs no server.

---

## Cross-faction only

`add` always uses the player's own `GetTeam()`. There is deliberately no
argument and no code path that puts a player on the other side.

`SetBGTeam` controls scoring and spawn side but **not** hostility.
`Unit::IsHostileTo` resolves through `GetReactionTo`, which goes to the faction
templates (`Unit.cpp:5189`) and never consults `GetBGTeam()`. A player forced
onto the opposing side would spawn at the right graveyard, score for the right
team — and then refuse to fight anyone, because everything on the field would
still read as friendly.

So a tournament match is always Alliance characters versus Horde characters.
Team identity is which *roster* a bot belongs to; faction is a property of the
character and is fixed at creation.

---

## World-port acknowledgement — measured

**The answer is UNMEASURED.** Nothing below has been run against a live server
yet. Do not treat the `direct` path as proven, and do not set
`ASSEMBLE_MODE` in `scripts/tournament/match-run.sh` on the strength of this
section until the procedure has actually been carried out and the outcome
written in here, replacing this paragraph.

### Why it matters

`HandleBattlefieldPortOpcode` is the only path that puts a player into a
battleground today, and it ends like this
(`src/game/Handlers/BattleGroundHandler.cpp:523-531`):

```cpp
_player->SetBattleGroundId(bg->GetInstanceID(), bgTypeId, queueSlot);
_player->SetBGTeam(ginfo.GroupTeam);
sBattleGroundMgr.SendToBattleGround(_player, ginfo.IsInvitedToBGInstanceGUID, bgTypeId);
// add only in HandleMoveWorldPortAck()
// bg->AddPlayer(_player,team);
```

`BattleGround::AddPlayer` is **deferred until the client acknowledges the world
port** — it runs in `HandleMoveWorldPortAck`
(`src/game/Handlers/MovementHandler.cpp:209`). A playerbot has a `WorldSession`
but no client behind it. Whether a bot ever sends that acknowledgement, and so
whether it is ever actually added to the battleground, **is not knowable from
reading the source.**

`AddPlayer` is also **guarded**: `HandleMoveWorldPortAckOpcode` only calls it if
`_player->IsInvitedForBattleGroundInstance(_player->GetBattleGroundId())`
(`src/game/Handlers/MovementHandler.cpp:208`) — the guard that stops someone who
walked in with `.goname` from joining the match. So `add` records the invite
(`SetInviteForBattleGroundQueueType`) and takes out the matching
`IncreaseInvitedCount` before it teleports; without both, outcome 3 in the table
below is guaranteed no matter what bots do about world ports, which would make the
measurement meaningless. If you are reading a `count=0` result, first confirm the
build you measured on contains those two calls in `HandleTournamentAddCommand`.

`add` mirrors that same sequence, which is exactly why the two read commands are
not redundant:

- **`add` reports what was _sent_.** `sent=1` means the teleport went out.
- **`members` reports what the battleground _holds_.** It walks
  `bg->GetPlayers()`, which is populated only by `AddPlayer`.

A run where every `add` says `sent=1` and `members` says `count=0` is a match
that will never start, never score, and never end — with nothing in the output
that looks like an error.

### The procedure that settles it

Needs a build containing the `.tournament` commands (artifacts 015-017) and one
bot online. Roughly two minutes once the stack is up.

1. Stand up a validated stack and leave it running:

   ```bash
   ./scripts/validate-stack.sh --image tortoise-cm:local --keep-up
   ```

2. Get one Alliance bot online — `scripts/tournament/roster.sh login
   stormwind-sentinels` once artifact 014 lands, or today
   `docs/playerbots/wsg/wsg-roster.sh ensure`. Confirm `Wsgaone` reads
   `online=1` before continuing; the rest of this measures nothing if it is not.

3. From WSL, in **one** console attach per step (never a bare `docker attach`):

   ```bash
   source docs/playerbots/wsg/lib/wsg-bots-common.sh
   source scripts/tournament/lib/ctl.sh

   inst="$(ctl_create 2 60)" || exit 1
   echo "instance=$inst"

   ctl "tournament add $inst Wsgaone"      # expect ... sent=1
   sleep 20                                # a world port is not instant
   ctl "tournament members $inst"          # the actual question
   wsg_mysql "SELECT name, map, online FROM tw_char.characters WHERE name='Wsgaone';"
   ```

   The 20 s wait is not padding. `map` in `characters` is only rewritten on
   save, so read it *after* the port has had time to land.

4. Record the **literal console output and the literal DB row** in this section,
   not a summary of them. Then delete the UNMEASURED paragraph above and state
   which outcome occurred.

### The three possible outcomes

| Observation | Meaning | What to do |
|---|---|---|
| `members … count=1` **and** the bot's `map` reads `489` | **Direct add works.** Bots do acknowledge world ports. | `ASSEMBLE_MODE=direct`. Concurrent matches are possible, because each instance is populated by name. |
| `add … sent=1` but `members … count=0`, and `map` is still the old one | **Bots do not acknowledge.** The teleport was sent and dropped on the floor. | `ASSEMBLE_MODE=queue`. Keep `create`, `status`, `members`, `start`, `stop`, `result`; assemble via the measured `bg join` path (`wsg_bgjoin_lines`) instead of `add`. |
| `members … count=0` but `map` **is** `489` | The bot moved but was never registered — the port landed and `AddPlayer` still never ran. | Same fallback as above. Worse than it looks: a bot standing in the battleground that the battleground does not know about will not score, will not respawn at the right graveyard, and will not be removed at the end. |

The second and third outcomes both cost the same thing, and it is worth writing
down before the measurement rather than after: the queue pairs whoever happens
to be queued, so **only one match can be assembled at a time**. That matches the
agreed design today, so it costs nothing now — but it permanently rules out
concurrent matches, which the direct path would have allowed.

Do not implement the `tournament queue` fallback speculatively. Measure first.
