# Bot Battleground Tournament — Design Spec

**Status:** design agreed 2026-08-16. Source idea: `docs/liveStreamPlans/gameplan.md`.
**Scope of this spec:** everything needed to run a spectator-facing, bracketed
Warsong Gulch tournament played by playerbots, with viewer-driven interventions.

This spec is the argument the plans in `docs/superpowers/plans/2026-08-16-*.md`
implement. Read it before reading any of them.

---

## 1. What we are building

A repeatable, scriptable pipeline that:

1. Defines **teams** as version-controlled data (roster, class/role composition,
   gear tier), not as ad-hoc console commands.
2. **Gears** every bot deterministically — a defined base kit per class/role, plus
   named upgrade tiers a viewer donation can promote a bot or a whole team into.
3. **Runs a match** between two named teams on demand, deterministically, without
   depending on which bots happen to be in the queue.
4. **Advances a bracket** — sequential matches, winners advance, state survives a
   server restart.
5. **Emits telemetry** proving bots entered the battleground, showing where they
   went, and capturing enough per-bot detail to debug bad behaviour.
6. Accepts **viewer interventions** (heal, kill, upgrade) through a queue, applied
   to a named player or a whole team mid-match.
7. Gives a **spectator camera** something to follow.

WSG 10v10 is the proving ground. Alterac Valley 40v40 is the eventual target, and
nothing in the design may hardcode "10 per side" or "map 489" in a way that blocks
that.

---

## 2. Decisions taken (and why)

These were settled in the 2026-08-16 planning conversation. Plans must not
re-litigate them.

### 2.1 Character names are alphabetic only

The original gameplan proposed `Wsga1…Wsga#`. **Digits in a character name are
rejected at character *load*, not at creation** (`Util.h:376-394` ←
`ObjectMgr.cpp:7049-7067` ← `Player.cpp:16569-16576`). The bot prints
`"Bot is now online"` optimistically *before* the login is attempted
(`PlayerbotMgr.cpp:2505-2506`), so a digit-named bot looks like it logged in and
then vanished, and its `characters` row is permanently broken with `at_login=1`.
This already cost a full debugging session.

**Rule:** every generated name is `^[A-Za-z]+$`, ≤ 12 characters. Alliance names
begin `Wsga`, Horde names begin `Wsgh`. Slot suffixes are spelled words:
`one two three four five six seven eight nine ten`. The existing 20-bot roster
(`Wsgaone…Wsgaten`, `Wsghone…Wsghten`) is the pattern and stays valid.

Name generation must be validated by a regex gate *before* any `rndbot create`
runs. A generator that can emit a digit is a defect regardless of whether the
current team list happens to trigger it.

### 2.2 Cross-faction bracket. No faction override.

`Player::SetBGTeam(Team)` (`Player.h:3196`) overrides which side a player scores
for, and `GetBGTeam()` falls back to real faction when unset (`Player.h:3197`).
But **hostility does not consult it**: `Unit::IsHostileTo` → `GetReactionTo`
resolves through faction templates (`Unit.cpp:5189`), which never read
`GetBGTeam()`. An Alliance character assigned to the Horde side would spawn and
score correctly and then refuse to fight.

**Rule:** every team is permanently Alliance or Horde. Every match pairs one of
each. The bracket structure guarantees this (§4.3). No plan may introduce a
faction override to work around a bracket shape.

### 2.3 One match at a time, 20 bots online

Only one match can be streamed at a time, so concurrency buys nothing. Teams exist
as characters indefinitely; **only the two teams currently playing are logged in.**
Rosters are added before a match and removed after.

**Rule:** concurrent online tournament bots ≤ 20 for WSG. The runner logs a roster
in, plays, logs it out, then logs the next in. This caps memory regardless of how
many teams the bracket holds — which matters, because bot memory is a known
constraint on this host (`docs/playerbots/BOT-MEMORY-INVESTIGATION.md`).

### 2.4 A narrow, console-callable C++ control plane

Scripts can create bots, gear them, read the DB, and scrape `bg.log`. They cannot:

- call `.bg start` / `.bg stop` / `.bg status` — `Chat.cpp:862` registers `bg` with
  `AllowConsole = false`, and every handler opens with `chr->GetBattleGround()`,
  requiring a GM character standing inside the instance
  (`Commands.cpp:14212-14257`);
- pair two *named* teams — the queue pairs whoever is queued, by faction. Today's
  setup works only because exactly 10 Alliance + 10 Horde are online, so no choice
  is involved;
- read a match result as structured data rather than a scraped log line.

**Rule:** add a `.tournament` command family, registered console-callable, built on
the engine APIs that already exist:

| API | Where | Role |
|---|---|---|
| `BattleGroundMgr::CreateNewBattleGround(typeId, bracketId)` | `BattleGroundMgr.h:223` | make an instance without a queue pop |
| `Player::SetBattleGroundId(instance, typeId, queueSlot)` | `Player.h` | point a player at that instance |
| `Player::SetBGTeam(Team)` | `Player.h:3196` | set the scoring side explicitly |
| `BattleGroundMgr::SendToBattleGround(player, instanceGuid, typeId)` | `BattleGroundMgr.h` | the teleport |
| `BattleGround::SetStartDelayTime(0)` | `BattleGround.h` | start now |
| `BattleGround::StopBattleGround()` | `BattleGround.h` | end now |

C++ changes are explicitly welcome — there are no live players, the dev
environment is unrestricted, and the image builds in ~9-10 minutes
(`docs/DOCKER.md`). Budget is not the constraint; **verification is**. See §2.5.

### 2.5 Engine APIs are probed empirically before anything is built on them

The direct-add path above is assembled from how `HandleBattlefieldPortOpcode`
does it (`BattleGroundHandler.cpp:495-540`), and that handler has a detail that
decides whether the whole approach works:

```cpp
sBattleGroundMgr.SendToBattleGround(_player, ginfo.IsInvitedToBGInstanceGUID, bgTypeId);
// add only in HandleMoveWorldPortAck()
// bg->AddPlayer(_player,team);
```

`BattleGround::AddPlayer` is **deferred until the client acknowledges the world
port**. A playerbot has a `WorldSession` but no client. Whether a bot ever acks a
world port — and therefore whether it is ever really added to the battleground —
is the single largest unknown in this design.

**Rule:** the first task of the control-plane plan is a throwaway probe command
that answers this against the running server and reports what actually happened.
No further C++ is written on top of an unprobed assumption. If bots do not ack,
the fallback is the existing queue path with explicit `bg type` assignment
(`wsg_bgjoin_lines` in `docs/playerbots/wsg/lib/wsg-bots-common.sh`), which is
already proven to work for a single match — the tournament then drives the queue
rather than the instance.

### 2.6 Team, gear and bracket data are JSON

Everything an operator would want to tweak per team lives in version-controlled
JSON, read by scripts with `jq`. **C++ never parses JSON** — the `.tournament`
commands take explicit arguments, and scripts do the reading. This keeps the C++
surface small and keeps per-team iteration free of a 10-minute rebuild.

### 2.7 Viewer input is mocked in this pass

The eight interaction effects are built and tested behind a **command queue** fed
by a CLI/file mock. No Twitch or TikTok credentials are involved, so the drain can
validate every effect end to end unattended. A real chat/donation adapter is later
work against a stable queue interface.

### 2.8 Streaming is a camera plus an assessment

An overnight autonomous run cannot verify video output. The testable half — a GM
spectator character that follows the action, driven by match telemetry — gets
built. The untestable half — capture, multiboxing, POV extraction — gets a written
feasibility assessment with real numbers, not code.

---

## 3. Hard constraints inherited from the server

Every plan's tasks are implicitly subject to these. They are facts about this
server, verified, with sources.

| Constraint | Value | Source |
|---|---|---|
| Character names | alphabetic only, digits rejected at load | `Util.h:376-394` |
| WSG battleground type id | `BATTLEGROUND_WS = 2` | `SharedDefines.h:1746` |
| WSG queue type id | `BATTLEGROUND_QUEUE_WS = 2` | `BattleGround.h:149` |
| WSG map id | 489 | `battleground_template` |
| Winner encoding | `WINNER_HORDE=0`, `WINNER_ALLIANCE=1`, `WINNER_NONE=2` | `BattleGround.h:187-189` |
| Match hard cap | 20 minutes, **custom to this server** | `BattleGround.cpp:317-323` |
| BG template load | once at boot; **no reload command** | `World.cpp:2274` |
| Character save interval | 60 s — how stale a `characters.map` read can be | `mangosd.conf` |
| Console EOF | shuts the world down; compose is `restart: "no"` | `docs/playerbots/WSG-BOT-MATCH.md` §7 |
| `rndbot` replies | go to a null player session and vanish — verify in the DB | ibid. |
| `.rndbot reload`/`.hover`/`.bgtest` | need account `rank=4` | `Common.h:184-193` |
| Bots partied to a player | never queue (`HasActivePlayerMaster()`) | `BattleGroundJoinAction.cpp:568` |
| `bots.log` | ~10 GB. Never `cat` it | `docs/playerbots/WSG-BOT-MATCH.md` §6 |
| `LoginFreeBots` | never removes a failed login from its queue — a broken bot is retried every world tick | ibid., "Known upstream defect" |

**Never `docker compose down -v`.** `tortoise-wow-v2_dbdata` is the entire world.

**Anything long-running writes results to disk incrementally** so a partial run
still yields evidence. A tournament run is hours long and can be ended by a crash,
a power cut, or an operator stopping it — none of which are worth losing a night's
matches to.

---

## 4. Data model

### 4.1 Layout

```
config/tournament/teams/<team-id>.json       team definition (version controlled)
config/tournament/gear/<class>-<role>.json   gear tiers per class/role
config/tournament/brackets/<bracket-id>.json bracket definition
scripts/tournament/*.sh                      the runner and its subcommands
scripts/tournament/lib/*.sh                  shared shell helpers
logs/tournament/<tournament-id>/             runtime state and artifacts (gitignored)
```

Config is separated from code and from runtime state deliberately: a team's
composition is reviewable in a diff, the runner is testable without it, and a
crashed run leaves its evidence behind without dirtying the tree.

### 4.2 Team definition

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

- Character name is `namePrefix + slot`, e.g. `Wsgaone`. Both halves are
  alphabetic, so the concatenation always is.
- `faction` is `A` or `H` and must agree with every race in the roster.
- `race` values are exactly what `ChatHelper::parseRace` accepts (the strings used
  in `docs/playerbots/wsg/wsg-team-roster.txt`).
- `gearTier` names a tier defined in the gear files (§4.4).

The existing `wsg-team-roster.txt` is the seed for the first two teams and stays
in place until the JSON path is proven.

### 4.3 Bracket definition

Because every match must be cross-faction (§2.2), the bracket is structured as two
mirrored ladders — an Alliance ladder and a Horde ladder — whose survivors meet at
every round. Concretely: at each round, the *n*th surviving Alliance team plays the
*n*th surviving Horde team. Winners of those matches advance within their own
ladder. This guarantees a cross-faction pairing at every round without any faction
manipulation, at the cost of the bracket not being a conventional single
elimination tree.

```json
{
  "id": "wsg-open-2026",
  "displayName": "WSG Open 2026",
  "battleground": "WS",
  "allianceLadder": ["stormwind-sentinels", "ironforge-anvils"],
  "hordeLadder":    ["orgrimmar-warsong",   "thunderbluff-braves"],
  "rounds": [
    { "id": "semis", "pairings": "positional" },
    { "id": "final", "pairings": "positional" }
  ]
}
```

Both ladders must be the same length, and that length must be a power of two.
A bracket that fails either check is rejected before a single bot is created.

### 4.4 Gear tiers

One file per class/role combination, tiers named and ordered:

```json
{
  "class": "warrior",
  "role": "tank",
  "tiers": {
    "base":    { "rank": 0, "items": { "head": 12640, "chest": 11726, "mainhand": 12784 } },
    "upgrade": { "rank": 1, "items": { "head": 16963, "chest": 16966, "mainhand": 17075 } }
  },
  "consumables": [
    { "itemId": 13446, "count": 20 },
    { "itemId": 8952,  "count": 20 }
  ]
}
```

- Slot keys are the `EQUIPMENT_SLOT_*` names, lowercased.
- `rank` orders tiers so an "upgrade" effect can move a bot up exactly one step and
  a "downgrade" is impossible.
- Item IDs are real `tw_world.item_template.entry` values, validated to exist and
  to be equippable by that class before the file is accepted.
- Every armour and weapon slot appropriate to the class must be present in every
  tier. A tier with a hole in it is the bug we are fixing, not a tier.

### 4.5 Viewer effect commands

The queue is a newline-delimited JSON file, appended by adapters and consumed by
the runner:

```json
{"id":"a1b2c3","ts":"2026-08-16T21:03:11Z","effect":"heal_player","target":{"team":"stormwind-sentinels","slot":"three"},"source":"mock","amount":null}
```

`effect` is one of: `heal_player`, `heal_team`, `kill_player`, `kill_team`,
`upgrade_armor_player`, `upgrade_armor_team`, `upgrade_weapon_player`,
`upgrade_weapon_team`.

`id` makes application idempotent — the same command applied twice is applied once.

---

## 5. Verification requirements

The operator's standing requirement, applying to every plan:

1. **The running server must be provably built from this repository.**
   `scripts/verify-running-commit.sh` already answers this with
   `MATCH` / `DRIFT` / `FOREIGN` / `UNKNOWN` and an exit code
   (0 / 1 / 1 / 2). A `FOREIGN` verdict means the image came from a different
   checkout sharing the image namespace — which has genuinely happened on this
   host.

2. **The image that was stood up must be the image that was built.**
   `docker-compose.yml` defaults `TW_IMAGE` to `tortoise-cm:local`, so omitting it
   silently reuses whatever was built previously. The tag is mutable; the image ID
   is not.

3. **A bound port is not a working server.** Liveness means the realm row reads
   `port=8095 realmflags=0`, the world port accepts a connection, and bots are
   actually online — not that `docker ps` printed a line.

**Known gap this must close:** `.claude/workflows/backlog-batch.js` builds with a
plain `docker build` and passes no `--build-arg GIT_SHA` / `GIT_DIRTY` /
`DOCKERFILE_SHA`. `scripts/rebuild.sh` does pass them. So batch-built images carry
**no provenance labels at all**, and `verify-running-commit.sh` returns `UNKNOWN`
against them — the drain currently cannot prove its own image came from this repo.
Plan 00 closes this, and every other plan depends on Plan 00.

---

## 6. Out of scope

- True client-side spectator mode.
- Real Twitch/TikTok adapters (interface only).
- Video capture and encoding (assessment only).
- Alterac Valley (design must not block it; no AV work in these plans).
- Same-faction matches.
- Concurrent matches.

---

## 7. Glossary

| Term | Meaning |
|---|---|
| **Roster** | the 10 characters belonging to one team |
| **Team** | a named, factioned roster with a gear tier — the unit that appears in a bracket |
| **Ladder** | all teams of one faction, in seed order |
| **Match** | one battleground instance between exactly two teams |
| **Round** | one set of matches; every surviving team plays exactly once |
| **Tournament run** | one execution of a bracket from first round to final |
| **Effect** | one viewer-triggered in-game intervention |
| **Control plane** | the `.tournament` C++ command family |
| **Runner** | the shell orchestrator that drives the control plane and the DB |
