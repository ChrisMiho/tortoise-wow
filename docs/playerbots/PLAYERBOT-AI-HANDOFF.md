# Turtle WoW V2 — Playerbot AI Handoff

**Topic:** how the bot AI works, how to enhance it, and how to summon bots to fill a party.

**Companion to** `WINDOWS-SETUP-HANDOFF.md` (getting the server running) and
`~/TURTLE-WOW-V2-HANDOFF.md` on the Deck (the pack author's own doc). This file covers
only the *bot AI*. For the closed mid-session `.rndbot create` / `.rndbot group` cache-fix
story, see [`PLAYERBOT-COMMAND-FIX-HANDOFF.md`](PLAYERBOT-COMMAND-FIX-HANDOFF.md).

**Status:** source extracted and read in full. §8 `.rndbot group` / CreateBot cache issues are
closed — see `PLAYERBOT-COMMAND-FIX-HANDOFF.md`. Nothing else in this document has been
verified against a running server; every claim is read from source, and the line references
let you re-check any of it.

---

## 1. Where the code is

The playerbot source ships inside the pack but is **not** part of the normal restore, since
`server-dir.tar.zst` is usually extracted whole into WSL. To get just the source on Windows
without unpacking the 3.1 GB of map data:

```bash
cd /d/TurtleWow/TurtleV2/server
/c/Windows/System32/tar.exe -xf server-dir.tar.zst -C /d/TurtleWow/extracted \
  --exclude '*/.git/*' 'tortoise-wow-server-V2/src'
```

Takes about 6 seconds and yields 396 MB. `C:\Windows\System32\tar.exe` is bsdtar and reads
`.tar.zst` natively — no `zstd` needed. It is already extracted to:

```
D:\TurtleWow\extracted\tortoise-wow-server-V2\src\
```

All paths below are relative to that directory. The module itself lives at
`src/modules/PlayerBots/`, and every file reference in this document is of the form
`src/modules/PlayerBots/playerbot/...`.

⚠️ This is a **read-only reference copy**. The server reads its source from
`~/tortoise-wow-server-V2/src` inside WSL (compose bind-mounts only `./src/sql`, not the
C++). Editing the copy on `D:` changes nothing. See §7.

### Scale

| | |
|---|---|
| C++ files | 449 `.cpp`, 514 `.h` |
| Actions | 299 files under `strategy/actions/` |
| Values | 195 files under `strategy/values/` |
| Triggers | 48 files under `strategy/triggers/` |
| Registered strategies | ~150 names in `strategy/StrategyContext.h` |

---

## 2. What this AI actually is

celguar-lineage CMaNGOS playerbots (the ike3 descendant), ported onto Turtle WoW 1.18.1
build 7272 by Shyalya on branch `playerbots-integration-gh`. It is **not** stock MaNGOS
playerbot and **not** AzerothCore `mod-playerbots`, so guides for those will differ —
notably, `mod-playerbots`' `.playerbots bot addclass <class>` does **not** exist here. See
§4 for what does.

`BUILD_PLAYERBOTS` defaults to `OFF` in CMake and produces **no warning** when off. The
shipped image was built with it `ON`. There is also a compat layer for the port:
`cmangos-compat-shim.h` (39 KB) plus `cmangos-compat-stubs/`.

The repo ships its own `src/PLAYERBOTS_QUICKSTART.md`, which is worth reading for the DB
side (playerbot tables are **not** in the base SQL dump; they live in
`src/modules/PlayerBots/sql/`).

---

## 3. How the engine works

It is a **priority-queue reactive planner** — not a behaviour tree, not a state machine.

Each bot owns a `PlayerbotAI` holding **one `Engine` per `BotState`**: combat, non-combat,
dead, and reaction are genuinely separate engines with separate action sets (`BotState.h`).

Each engine holds a list of **Strategies**. A strategy's only real job is to contribute
**trigger nodes**, each binding a trigger to one or more actions with a priority:

```
trigger > action!priority
```

Per tick:

1. Evaluate all triggers in the active engine.
2. Every trigger that fires pushes its actions into a priority queue (`ActionBasket`).
3. **Multipliers** get a pass to scale or veto those priorities. This is how cross-cutting
   rules ("don't cast while silenced", "healing outranks damage") are expressed without any
   strategy knowing about any other. See `PassiveMultiplier.cpp` for the pattern.
4. The highest-priority action that reports itself executable runs.

**Values** (195 of them) are the lazily-evaluated, cached world-state accessors that both
triggers and actions read — "current target", "party member to heal", and so on — so state
is computed once per tick rather than once per consumer.

Priorities are a fixed ladder in `strategy/Strategy.h`:

```
ACTION_IDLE = 1, ACTION_NORMAL = 10, ACTION_HIGH = 20, ACTION_MOVE = 30,
ACTION_INTERRUPT = 40, ACTION_DISPEL = 50,
ACTION_LIGHT_HEAL = 60, ACTION_MEDIUM_HEAL = 70, ACTION_CRITICAL_HEAL = 80,
ACTION_EMERGENCY = 90, ACTION_PASSTROUGH = 100
```

Strategies are toggled by name with `+` / `-`, which is exactly what the config does:

```
AiPlayerbot.CombatStrategies    = +custom::say,+dps,+dps assist,-threat
AiPlayerbot.NonCombatStrategies = +grind,+loot,+custom::say,+return,+delayed roll,+tfish,+wander,+rpg craft
```

Registered names include per-boss strategies (`magmadar`, `netherspite`, `four horseman`,
`onyxia`, `molten core`, `naxxramas`), a full `debug ...` family, and `ai chat` (§6.1).

---

## 4. The command surface

For a short “spawn a teammate and start a party” walkthrough, see
[`docs/playerbots/SPAWN-AND-PARTY-STARTER.md`](docs/playerbots/SPAWN-AND-PARTY-STARTER.md).

Two chat commands, both registered in `src/game/Chat/Chat.cpp:999-1000`, **both
`SEC_PLAYER`** — no GM rank needed:

| Command | Console-allowed | Bots created on |
|---|---|---|
| `.bot` | no | **your own account** |
| `.rndbot` | yes | the **`RNDBOT0..N` pool** |

They share every subcommand. The difference that matters is account ownership:

- `PlayerbotHolder::GetOrCreateAccount` (`PlayerbotMgr.cpp:2801`) simply returns the
  master's account id.
- `RandomPlayerbotMgr::GetOrCreateAccount` (`RandomPlayerbotMgr.cpp:4691`) walks the
  `RNDBOT` pool from 0 and picks the first account with a free character slot.

Accounts cap at **9 characters** (`PlayerbotMgr.cpp:2324`; 10 only on `MANGOSBOT_TWO`). So
`.bot create` permanently eats your own character slots and you get at most 8 personal bots.

> **Rule of thumb: use `.rndbot` for creating bots, always.**

Dispatch is a clean two-table registry built in the `PlayerbotHolder` constructor
(`PlayerbotMgr.cpp:231-289`):

- `m_holderHandlers` — commands acting on *you*: `list`, `help`, `reload`, `tweak`, `self`,
  `spoof`, `p`, `g`, `r`, `rl`, `create`, `group`.
- `m_botCommandHandlers` — commands acting on a *named bot*: `add`/`login`,
  `remove`/`logout`/`rm`, `delete`, `gear`/`equip`, `train`/`learn`, `food`/`drink`,
  `potions`/`pots`, `consumes`, `regs`/`reagents`, `prepare`/`prep`, `init`, `enchants`,
  `ammo`, `pet`, `levelup`/`level`, `random`, `summon`/`recall`/`come`, `always`, `debug`,
  `c`, `w`, `cmd`, `do`, `record`, `read`, `clear`.

Built-in help lives in `PlayerbotHolder::GetCommandTexts()` (`PlayerbotMgr.cpp:3064`), so
`.rndbot help <command>` is authoritative and self-updating.

Target selectors, resolved in `HandlePlayerbotCommand` (`PlayerbotMgr.cpp:908`):

| Selector | Meaning |
|---|---|
| *(none)* | your current target, if it's a bot |
| `<name>` | that character; comma-separated lists work |
| `*` | every member of your group |
| `guild` | every member of your guild |
| `!` | every loaded bot — requires **above** `SEC_GAMEMASTER` |

### 4.1 Filling a party

**`.rndbot group`** is the built-in party-filler (`PlayerbotMgr.cpp:2479`). It defaults to
`size=5`, counts you as one, and creates the rest with roles complementary to your own
class, at your level, flagged to group with you. `size=N` overrides.

⚠️ **Add `login=1` yourself: `.rndbot group login=1`.** The command never sets it
internally, so without it every bot it makes just sits in the DB — created, but never
logged in or grouped. See §8 for the full trace.

Composition targets come from `LfgAction::AllowedClassRoleNr`
(`strategy/actions/InviteToGroupAction.cpp:89`), which defines real raid compositions:

| Size | Tanks | Healers | DPS |
|---|---|---|---|
| 5 | 1 | 1 | 3 |
| 25 | 3 | … | … |
| 40 | 4 | 16 | 20 (with per-class caps) |

It also skips faction-illegal picks on classic — Horde paladins, Alliance shamans
(`PlayerbotMgr.cpp:2543-2554`).

`HandleGroup` writes a summary line to the **server log** on every run, which is the first
thing to check when it misbehaves:

```
DEBUG group: target=5, created=4, continues: role=.., race=.., class=.., classes: ..
```

**`.rndbot create`** makes one bespoke bot. Parameters parsed at `PlayerbotMgr.cpp:2287`:

| Key | Values |
|---|---|
| `name=` | must not already exist |
| `class=` `race=` `gender=` `faction=` | names, parsed by `ChatHelper` |
| `level=` | **see the trap in §8** |
| `role=` | tank / healer / dps |
| `gear=` | `default`, `empty`, `green`/`uncommon`, `blue`/`rare`, `purple`/`epic`, `best`, `partial`, `upgrade`, `sync` |
| `group=` | character name to auto-group with |
| `login=` | `1`/`true`/`yes` to bring online immediately |
| `temporary=` | mark for cleanup |

Example: `.rndbot create class=priest race=dwarf level=60 role=heal gear=blue`

### 4.2 Manual grouping always works

Independent of any auto-group logic, **`/invite <botname>` is reliable**. The binding is
permanent and lives in the always-on `WorldPacketHandlerStrategy`
(`strategy/generic/WorldPacketHandlerStrategy.cpp:35-37`):

```cpp
triggers.push_back(new TriggerNode(
    "group invite",
    NextAction::array(0, new NextAction("accept invitation", relevance), NULL)));
```

`join` is also an unsecured chat command (`PlayerbotAI.cpp:1449`), so whispering a bot
`join` works too.

**`.bot add <name>` attaches an existing character — it does not create one.** This is why
`.bot add rogue` fails with "character not found": it wants a character name, not a class.

---

## 5. Three ways to enhance the AI

Ordered by cost. Know which tier you're in before starting.

| Tier | Mechanism | Cost to apply |
|---|---|---|
| 1 | `aiplayerbot.conf` | live reload, or container restart |
| 2 | `ai_playerbot_custom_strategy` SQL table | bot AI reset |
| 3 | C++ | **full image rebuild, ~30 minutes measured** |

### 5.1 Tier 1 — config

`docker-compose.yml` bind-mounts `./etc` into both `realmd` and `mangosd`, so
`aiplayerbot.conf` is **not** baked into the image. Better still, `.rndbot reload` (this one
*is* `SEC_GAMEMASTER`) calls `sPlayerbotAIConfig.Initialize()` and re-reads the file live
(`PlayerbotMgr.cpp:1504`). No restart needed for most tuning.

The file is large — 277 KB, ~5000 lines — and heavily commented. Main dials:

- Strategy lists: `CombatStrategies`, `NonCombatStrategies`, and the `RandomBot*` variants.
- Distances: `SightDistance` 60, `SpellDistance` 26, `HealDistance` 30, `RpgDistance` 200.
- Timing: `GlobalCooldown` 1500, `ReactDelay` 100, `RepeatDelay` 5000.
- Population: `MinRandomBots`/`MaxRandomBots`, `RandomBotAccountCount` 500.
- `DisableActivityPriorities` — see the warning in the pack author's §8. At 1000 bots this
  must stay `0`.

### 5.2 The LLM integration (currently off)

The single highest-leverage change available with **no compilation**. Config block at
`etc/aiplayerbot.conf:1186-1257`, implementation in `PlayerbotLLMInterface.cpp`, exposed as
the `ai chat` strategy.

```
AiPlayerbot.LLMEnabled = 1
# 0 = off, 1 = on via 'ai chat' strategy, 2 = default for all bots, 3 = on without the strategy
AiPlayerbot.LLMApiEndpoint = http://127.0.0.1:5001/api/v1/generate
AiPlayerbot.LLMApiKey =
AiPlayerbot.LLMContextLength = 4096
AiPlayerbot.LLMGenerationTimeout = 600
AiPlayerbot.LLMMaxSimultaniousGenerations = 100
```

It speaks **KoboldCPP or any OpenAI-compatible** `/v1/chat/completions` endpoint; both
example configs are in the file. Prompts support substitution tokens for bot name, race,
class, level, zone/subzone, and the speaker's details. Response parsing is four regexes
(`LLMResponseStartPattern`, `EndPattern`, `DeletePattern`, `SplitPattern`) — for OpenAI the
start pattern becomes `("content":\s*")`.

Extras: `llm_character_card.txt` for per-bot personalities, `LLMRpgPrompt` for bots talking
to NPCs, `LLMBotToBotChatChance`, and `LLMBlockedReplyChannels`.

⚠️ Note the endpoint runs from **inside the mangosd container**. `127.0.0.1` there is the
container, not your PC — use `host.docker.internal` or the LAN IP for a model running on
Windows.

### 5.3 Tier 2 — database-driven strategies

`custom::<name>` strategies are **not** hardcoded. `CustomStrategy::LoadActionLines`
(`strategy/CustomStrategy.cpp:98`) reads them from the **characters DB**:

```sql
SELECT action_line FROM ai_playerbot_custom_strategy
WHERE name = '<qualifier>' AND owner = '<guid>' ORDER BY idx
```

Each `action_line` is one `trigger>action!priority` binding, parsed by `toTriggerNode`.
The `owner` column is the lever:

- `owner = 0` → the strategy applies globally.
- `owner = <bot guid>` → that one character only. Per-bot lookup is tried **first**, with
  the global row as fallback.

So you can compose new behaviour from the existing 299 actions and 48 triggers entirely in
SQL, then enable it with `+custom::myname` in the config. This is already in use — the
shipped strategy lists include `+custom::say`.

`CustomStrategy::Reset()` clears the cache, so changes need a bot AI reset, not a rebuild.

### 5.4 Tier 3 — C++

Adding a command is genuinely small: one entry in `m_holderHandlers` (acts on you) or
`m_botCommandHandlers` (acts on a bot), plus one function. Holder handlers have the
signature:

```cpp
std::list<std::string> Handler(Player* master, const std::string param, AccountTypes security);
```

The cost is not the code, it's the **~30-minute rebuild** (measured: 1599 s compile at `-j2` plus stack restart; `-j$(nproc)` OOMs WSL). Batch all C++ work into one
build. See §7 before you start.

---

## 6. Config reference (as packaged)

From `deploy/etc/aiplayerbot.conf.template`, a redacted snapshot of the live conf
refreshed by `scripts/stage-deploy.sh`. **The live server's copy may differ** if it has
been edited since — check `~/tortoise-wow-server-V2/etc/aiplayerbot.conf` on the Deck
before trusting these.

```
AiPlayerbot.Enabled              = 1     (line 12)
AiPlayerbot.RandomBotAutologin   = 1     (line 18)   <- gates the whole update loop, see §8
AiPlayerbot.BotAutologin         = 0     (line 39)   <- 0 = DISABLED, 1 = ALL_WITH_MASTER, 2 = ONLY_ALWAYS_ACTIVE
AiPlayerbot.MinRandomBots        = 1000  (line 61)
AiPlayerbot.MaxRandomBots        = 1000  (line 62)
AiPlayerbot.RandomBotAccountCount= 500   (line 68)
AiPlayerbot.AllowMultiAccountAltBots = 1 (line 942)
AiPlayerbot.RandomBotsMaxLoginsPerInterval = 30
AiPlayerbot.RandomBotUpdateInterval = 500
```

`BotAutoLogin` enum is at `PlayerbotAIConfig.h:38`.

---

## 7. Rebuilding — read before touching C++

The compiled server lives **inside the image** `tortoise-v2:local`, which the setup handoff
correctly calls irreplaceable (expected ID
`sha256:0a13a2be94fca3ce5cebc4f9968fb92a6e7c0e1900419b7b16ce110f92935ff5`). A rebuild
overwrites that tag.

**Tag a backup first, before any build:**

```bash
docker tag tortoise-v2:local tortoise-v2:pristine
```

Then edit the C++ under `~/tortoise-wow-server-V2/src` **inside WSL** — not the reference
copy on `D:`. Build settings that must not change (`Dockerfile:34-41`):

```
-DCMAKE_INSTALL_PREFIX=/opt/turtle   # compiled in; moving it breaks aiplayerbot.conf lookup
-DBUILD_PLAYERBOTS=ON                # OFF by default, silently produces no bots
-DUSE_EXTRACTORS=ON
-DALLOW_TURTLE_ADDONS=ON             # off = client "interface corrupt" on entering world
```

Do not hand-pick runtime libraries; the list came from `ldd` in the build stage and a
previous attempt died on a missing `libboost_thread`.

---

## 8. 🟢 ROOT CAUSE FOUND: `.rndbot group` never passes `login=1` to its own bots

**Observed 2026-08-09.** `.rndbot group` printed `Bot created: Floto` and `Bot is now
online` for several characters. None joined the party. `/who Floto` then returned **no
player online**.

**Found 2026-08-09 (source read, not yet live-confirmed).** `HandleGroup`
(`PlayerbotMgr.cpp:2479`) builds each teammate's create params itself and calls the same
`HandleCreate` that `.rndbot create` uses:

```cpp
// PlayerbotMgr.cpp:2562-2565
std::ostringstream paramStr;
paramStr << "level=" << masterLevel << " class=" << ChatHelper::formatClass(cls)
          << " group=" << master->GetName() << " " << passThroughParam; //Passthrough will override.

auto result = HandleCreate(master, paramStr.str(), security);
```

It never puts `login=1` into that string itself. In `CreateBot`, going online at all is
gated purely on that flag:

```cpp
// PlayerbotMgr.cpp:2456-2464
if (autoAdd)   // autoAdd == (parsed "login" key was 1/true/yes)
{
    sPlayerbotAIConfig.freeAltBots.push_back(std::make_pair(accountId, botGuid));
    messages.push_back("Bot is now online");
}
else
{
    messages.push_back("Use '.rndbot add " + name + "' to bring this bot online");
}
```

So a bare `.rndbot group` **only ever writes rows to the `characters` table.** It never
queues login, so `LoginFreeBots()` never sees the bot, so the deferred `"create group"` flag
that would auto-invite/auto-accept it (§ below) is never even attempted. `"Bot is now
online"` printing before was misleading — this bug is worse than misleading: for a bare
`.rndbot group` that message **never prints at all**, and the actual message
(`"Use '.rndbot add <name>' to bring this bot online"`) is easy to miss in a wall of bot
creation spam.

**The one-line fix (no rebuild): pass it yourself.** `HandleGroup`'s own arg parser passes
through any `key=value` that isn't `size=` verbatim into `passThroughParam`
(`PlayerbotMgr.cpp:2499-2515`), so:

```
.rndbot group login=1
.rndbot group size=5 login=1
```

should create the full role-balanced team, log every bot in, and run the deferred `join`
(source `"create group"`) which both invites **and** self-accepts
(`InviteToGroupAction.cpp:78-84`) — no `/invite` required. Fix closed — see
`PLAYERBOT-COMMAND-FIX-HANDOFF.md`.

### The mechanism

`.rndbot group` does **not** group anything itself. It calls `HandleCreate` per bot with
`group=<yourname>`, and the actual invite is deferred to a later pass of the login loop.

`CreateBot` (`PlayerbotMgr.cpp:2406-2428`) stores three deferred flags — **all inside a
single `if (level > 1)` block**:

```cpp
if (level > 1)
{
    // InitStatsForLevel / InitTalentForLevel / AutoSelectTalents
    sRandomPlayerbotMgr.SetValue(botGuid, "create levelup", 1);
    sRandomPlayerbotMgr.SetValue(botGuid, "create group", 1, groupWith);
    sRandomPlayerbotMgr.SetValue(botGuid, "create gear",  1, gear);
}
else
    newBot->SetLevel(1);
```

The bot is then saved, logged out, deleted, and pushed onto the in-memory
`sPlayerbotAIConfig.freeAltBots` list. **`"Bot is now online"` is printed at this point,
before any login is attempted — it proves nothing.**

`RandomPlayerbotMgr::LoginFreeBots()` (`RandomPlayerbotMgr.cpp:873`) later drains that list.
First pass calls `AddPlayerBot`; a subsequent pass consumes the flags
(`RandomPlayerbotMgr.cpp:901-915`):

```cpp
if (sRandomPlayerbotMgr.GetValue(botGuid, "create group"))
{
    std::string groupWith = sRandomPlayerbotMgr.GetData(botGuid, "create group");
    if (!groupWith.empty())
    {
        master = sObjectAccessor.FindPlayerByName(groupWith.c_str());
        if (master)
            bot->GetPlayerbotAI()->DoSpecificAction("join", Event("create group", "", master));
    }
    sRandomPlayerbotMgr.SetValue(botGuid, "create group", 0);   // <-- unconditional
}
```

Then the bot is teleported to the master (line 1000) and removed from `freeAltBots`
(line 1006).

### Two real design faults

1. **The flag is cleared unconditionally** — outside `if (master)`, and ignoring whether
   `DoSpecificAction` succeeded. One attempt per bot, ever. Any timing hiccup and that bot
   is silently never grouped, with no retry and no message.
2. **`level > 1` gates grouping, gear, and talents together.** `.rndbot group` passes
   `level=<your level>`, so running it on a **level 1 character** creates level 1 bots with
   no gear, no talents, and no grouping flag — while still printing success.

### Candidate causes, in order (■ confirmed by source read)

| # | Hypothesis | Status |
|---|---|---|
| **0** | **`login=1` never gets set by `HandleGroup` itself, so bots are never queued to log in at all** | **■ Confirmed — this is the bug. See fix above.** |
| 1 | Login itself failed — consistent with `/who` finding nothing | Subsumed by #0: login was never attempted, not merely failed |
| 2 | Master was level 1, so `level > 1` never fired | Still possible as a *separate* issue — check your own character's level too |
| 3 | `DoSpecificAction("join")` returned impossible/useless | Only relevant once `login=1` is passed and login succeeds |
| 4 | Update loop early-returned before `LoginFreeBots()` | Ruled out unless `RandomBotAutologin`/`enabled` were hand-edited off |

On #4: `LoginFreeBots()` is called at `RandomPlayerbotMgr.cpp:772`, which is **after** this
early return at line 657:

```cpp
if (!sPlayerbotAIConfig.randomBotAutologin || !sPlayerbotAIConfig.enabled)
    return;
```

The packaged config has `RandomBotAutologin = 1`, so this should pass — but verify against
the live file. Separately, `LoginFreeBots` itself no-ops when
`botAutologin == LOGIN_ONLY_ALWAYS_ACTIVE` (value **2**); the packaged value is `0`, which
is fine.

If `.rndbot group login=1` *still* doesn't group a bot, hypotheses 2/3 are cleanly separable
because grouping and gear share the same `level > 1` gate: **level 1 and naked → cause 2;
correct level and geared but ungrouped → cause 3 (the unconditional-flag-clear fault below).**

### Diagnostics to run

The login path is heavily instrumented and logs every failure explicitly
(`PlayerbotMgr.cpp:54-227`):

```bash
docker logs tw2-mangosd 2>&1 | grep -E "\[PlayerBots\]|DEBUG group:"
```

Strings worth knowing:

- `[PlayerBots] AddPlayerBot: no account for guid %u`
- `[PlayerBots] AddPlayerBot: holder Initialize() failed for guid %u`
- `[PlayerBots] AddPlayerBot: bot %u is in HashMapHolder but not in world ... refusing to retry login`
- `[PlayerBots] HandlePlayerBotLoginCallback: bot %u failed to enter world`
- `DEBUG group: target=..., created=...`

In-game:

```
.rndbot list                  # what the server thinks is online
.rndbot add Floto             # force one bot online explicitly
```

SQL — does the character even exist?

```bash
cd ~/tortoise-wow-server-V2
docker exec tw2-db mariadb -uroot -p"$(cat .dbpass)" -N -B -e \
  "SELECT guid,name,race,class,level,account FROM tw_char.characters WHERE name='Floto';"
```

### Workarounds right now

- **Use `.rndbot group login=1` (or `size=N login=1`)** — no rebuild needed, see the fix above.
- If one bot out of the batch still doesn't join: `.rndbot add <name>` (if not already online)
  then `/invite <name>` — reliable, see §4.2.
- **Do not re-run `.rndbot group` hoping a straggler retries.** It creates four *more*
  characters each time, and the existing bots' grouping flags are already consumed.

### Second bug found 2026-08-09: fresh bots are unresolvable by name

**Observed:** `.rndbot group login=1` (or `.rndbot create ... login=1`) prints `Bot created:
Steranu` and `Bot is now online`, but `.rndbot add Steranu`, `.rndbot summon Steranu`, and any
other name-based lookup immediately return `"character not found"` / `"Cannot find
'Steranu'."` — even though the character genuinely exists in the DB and (per `login=1`) is
queued to log in.

**Cause:** every name-based bot command resolves through
`sObjectMgr.GetPlayerGuidByName()` (`PlayerbotMgr.cpp:1062`), which reads a pure in-memory
cache (`ObjectMgr::m_playerNameToGuid`). That cache is populated at server boot (bulk load of
every existing character) and updated on real login/logout via
`ObjectMgr::UpdatePlayerCache`/`InsertPlayerInCache`. `PlayerbotHolder::CreateBot`
(`PlayerbotMgr.cpp:2371-2454`) never registers the new bot at all:

```cpp
Player* newBot = new Player(botSession);
newBot->Create(...);
...
newBot->SaveToDB();
botSession->LogoutPlayer();
```

`Player::Player(WorldSession*)` (`Objects/Player.cpp:627`) only sets `m_session = session` —
it never calls `session->SetPlayer(this)`. `WorldSession::LogoutPlayer` (`WorldSession.cpp:604`)
guards almost its entire body, including the `sObjectMgr.UpdatePlayerCache(_player)` call at
line 811, behind `if (_player) { ... }` — and since `botSession->_player` was never set via
`SetPlayer()`, that whole block silently no-ops. The character is saved to the DB but its name
never enters the lookup cache, so it stays permanently unresolvable by name until a full
server restart (which reloads the cache from the DB for every character that exists by then).

Bots that already existed before the current server session started aren't affected — they
were bulk-loaded into the cache at boot. Only bots created fresh via `.rndbot create` /
`.rndbot group` during the *current* session hit this.

**Workaround (no rebuild):** name resolution is broken, but targeting isn't. Bots spawn at
your exact position, so Tab-target or click the bot, then `/invite` with **no name** —
vanilla `/invite` with no argument invites your current target and never touches the broken
cache. Use `.rndbot list` instead of `/who <name>` to confirm a bot is online — it walks a
live in-memory bot map (`playerBots`), not the name cache, so it isn't affected.

**Proper fix (one line, Tier 3, verified):** in `CreateBot`, call
`sObjectMgr.LoadPlayerCacheData(botGuid);` immediately after `newBot->SaveToDB();`.
`ObjectMgr.h` is already included. This repairs name lookup *and* the bot login path at
once — `AddPlayerBot` resolves the bot's account through the same cache, so without it the
bot can never come online no matter what `login=` is set to. Prefer this over
`botSession->SetPlayer(newBot)`, which would drag the whole `LogoutPlayer` teardown into a
session that was never really logged in. Applied on Local 2026-08-09
(`tortoise-v2:local` `27b6f334c6ff…`; see `PLAYERBOT-COMMAND-FIX-HANDOFF.md`).

### Proper fix (Tier 3, only needed for full robustness)

`login=1` closes the main gap, but two smaller design faults remain for anyone who wants
`.rndbot group` to be fully retry-safe without a rebuild-free workaround:

In `RandomPlayerbotMgr.cpp:901-915`: only clear `create group` when `DoSpecificAction`
actually returns true, and allow a bounded number of retries while the bot finishes
entering the world. The `create group` flag was lifted out of the `level > 1` block on
2026-08-09 (level-1 masters can auto-invite). Optionally batch a new `.rndbot fillparty`
command that also defaults `login=1` in a later build.

---

## 9. Hard rules

- `.rndbot` for creating bots, not `.bot` — otherwise bots consume your own 9 character slots.
- `docker tag tortoise-v2:local tortoise-v2:pristine` **before** any rebuild.
- Edit C++ in WSL at `~/tortoise-wow-server-V2/src`, not the reference copy on `D:`.
- Config and SQL changes never need a rebuild. Exhaust tiers 1 and 2 first.
- `BUILD_PLAYERBOTS=ON` and `ALLOW_TURTLE_ADDONS=ON` must survive any CMake change.
- `"Bot is now online"` is not evidence a bot logged in. `/who` or `.rndbot list` is.
- `.rndbot group` needs `login=1` added by hand (`.rndbot group login=1`) or nothing comes
  online — see §8.
- Never `docker compose down -v` (from the setup handoff — it deletes the database volume).
