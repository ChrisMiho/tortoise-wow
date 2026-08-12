# Warsong Gulch — Bot 10v10 Match Runbook

**Purpose:** stand up two persistent level-60 bot teams and spectate them playing
Warsong Gulch.
**Status:** working end-to-end. First successful match 2026-08-10; a full 10v10
(all 20 roster bots, one instance) ran 15:37–15:58Z.
**Non-goals:** true spectator mode, PvP-set gear, a C++ `.rndbot bg` command.

Background reading, only if something breaks:
- [Root cause of the first-run failure](../evidence/WSG-Debug/2026-08-10-logout-root-cause.md)
- [First live match, run log and evidence](../evidence/WSG-Debug/2026-08-10-overnight-run.md)
- Design: `docs/superpowers/specs/2026-08-09-wsg-bot-match-design.md`

---

## 0. The one thing that will bite you

**A match lasts at most 20 minutes, and bot matches almost always run the full 20 and
end 0–0.** This server carries a custom hard cap (`BattleGround.cpp:317-323`) added
precisely because bots stand around instead of capping flags. When the clock expires
the match ends, everyone teleports out, and the bots scatter to cities and questing
zones.

So if you `.appear <bot>` after the match has ended, you land next to an idle bot in a
city and see nothing. **Confirm the match is live before you teleport** — §5.

---

## 1. Layout and prerequisites

| Thing | Where |
|---|---|
| Compose project | `~/tortoise-wow-server-V2` (WSL Ubuntu, user `deck`) |
| Containers | `tw2-db`, `tw2-realmd`, `tw2-mangosd` |
| Config (bind-mounted `./etc` → `/opt/turtle/etc`) | `~/tortoise-wow-server-V2/etc/{aiplayerbot,mangosd}.conf` |
| Logs | `~/tortoise-wow-server-V2/logs/` — `bg.log` is the one you want |
| C++ source | `~/tortoise-wow-server-V2/src` (**WSL-side**; `D:\TurtleWow\extracted\…` is a slim copy without full source) |
| Databases | `tw_logon` (auth), `tw_char`, `tw_world` |
| Scripts | `D:\TurtleWow\scripts\` → `/mnt/d/TurtleWow/scripts/` |

Requirements:

- Stack up. `docker compose` has `restart: "no"` — nothing self-heals.
- A GM character. `Astral` = account 504 (`MMODAD`). **Needs `rank=4`** for
  `.rndbot reload`, `.hover` and `.bgtest`; `rank=3` is refused
  (`SEC_GAMEMASTER` is `#define`d to `SEC_ADMINISTRATOR`=4).
  `UPDATE tw_logon.account SET rank=4 WHERE id=504;` then relog.
- **Never party the roster bots to your GM.** `HasActivePlayerMaster()` is a hard gate
  in the bot's queue logic (`BattleGroundJoinAction.cpp:568`) — a partied bot will
  never queue.

### Running commands

Windows Git Bash mangles nested quotes through `wsl bash -lc`. Always use a heredoc:

```bash
MSYS_NO_PATHCONV=1 wsl -d Ubuntu -u deck -- bash <<'EOF'
source /mnt/d/TurtleWow/scripts/lib/wsg-bots-common.sh
wsg_mysql "SELECT 1;"
EOF
```

### Helper library — `scripts/lib/wsg-bots-common.sh`

| Function | Does |
|---|---|
| `wsg_mysql "<sql>"` | Query via `docker exec tw2-db`; handles `.dbpass` and strips CR |
| `wsg_console "<cmds>" [wait_s]` | Send commands to the mangosd console (see §7) |
| `wsg_load_roster <file>` | Load `scripts/wsg-team-roster.txt` into `WSG_NAMES`/`WSG_CLASS`/… |
| `wsg_team_status` | Prints `name online map` per roster bot; missing bots get map `-1` |
| `wsg_count_on_wsg A\|H` | Count roster bots of that faction on map 489 |
| `wsg_create_line`, `wsg_print_add_block`, `wsg_print_spectate_block` | Paste-block builders |
| `wsg_ensure_match_conf <conf>` | Writes the match profile; echoes `CHANGED`/`UNCHANGED` |

---

## 2. Cold start (first time, or after a wipe)

### 2.1 Funnel every queue into WSG

Bots pick a queue uniformly at random from all eligible types (Turtle adds Blood Ring
and Sunnyglade Valley), so without this WSG never fills.

```bash
MSYS_NO_PATHCONV=1 wsl -d Ubuntu -u deck -- bash /mnt/d/TurtleWow/scripts/wsg-only-mode.sh on
```

This sets `min_level=61` on every `battleground_template` row except id=2 and snapshots
the originals into `tw_world.battleground_template_bak_wsg`.
**A restart is mandatory** — the template is read once at boot
(`World.cpp:2274` → `CreateInitialBattleGrounds()`); there is no `.reload` for it.

Side effect: humans can't queue non-WSG battlegrounds while this is on.

### 2.2 Match config profile

In `~/tortoise-wow-server-V2/etc/aiplayerbot.conf`:

```
AiPlayerbot.RandomBotJoinBG            = 1
AiPlayerbot.RandomBotAutoJoinBG        = 1
AiPlayerbot.DisableActivityPriorities  = 1    # bypasses the noLag gate that silently stops queueing
AiPlayerbot.RandomBotTimedLogout       = 0
AiPlayerbot.MinRandomBots              = 40   # shrink the alive-world pool; bot AI is single-core
AiPlayerbot.MaxRandomBots              = 40
```

Set the pool size **before** the restart — excess bots only leave via timed logout,
which this profile disables.

```bash
docker restart tw2-mangosd
```

Watch it come up (note the **`Z`** — a naive timestamp is read as local, lands in the
future, and returns zero lines):

```bash
MSYS_NO_PATHCONV=1 wsl -d Ubuntu -u deck -- bash <<'EOF'
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
docker restart tw2-mangosd
until docker logs tw2-mangosd --since "$TS" 2>&1 | grep -qa ai_playerbot_random_bots; do sleep 5; done
echo "world live"
EOF
```

### 2.3 Create the roster

`scripts/wsg-team-roster.txt` is the source of truth (`name|class|race|role|faction`).

> **Names must be alphabetic only.** Digits are rejected at character *load*, not at
> creation, and `"Bot is now online"` prints optimistically before the login is even
> attempted — so digit-named bots look like they log in and instantly vanish. This cost
> a full debugging session. See the [root-cause doc](../evidence/WSG-Debug/2026-08-10-logout-root-cause.md).

Create via the console, in batches of ~5, verifying each batch in the DB:

```bash
MSYS_NO_PATHCONV=1 wsl -d Ubuntu -u deck -- bash <<'EOF'
source /mnt/d/TurtleWow/scripts/lib/wsg-bots-common.sh
wsg_console "rndbot create name=Wsgaone class=warrior race=Human level=60 role=tank gear=blue login=1 group=" 12 >/dev/null
sleep 10
wsg_mysql "SELECT name, online, level, at_login FROM tw_char.characters WHERE name='Wsgaone';"
EOF
```

Expect `Wsgaone  1  60  0`. **`at_login` must be 0** — a `1` means the name was rejected
and the row is permanently broken (delete it; do not try to reuse it).

---

## 3. Running a match

```bash
MSYS_NO_PATHCONV=1 wsl -d Ubuntu -u deck -- bash /mnt/d/TurtleWow/scripts/wsg-mode.sh on
MSYS_NO_PATHCONV=1 wsl -d Ubuntu -u deck -- bash /mnt/d/TurtleWow/scripts/wsg-kickoff.sh
```

`wsg-mode.sh on` is needed once per session. `wsg-kickoff.sh` starts one match, monitors
it, prints the result, and exits — run it again for the next match.

Expect 20/20 queued within ~15 s and a pop within ~30 s. During the match the terminal
shows elapsed time, roster count, score, and kills. Artifacts land in
`logs/wsg-matches/<timestamp>/`.

Measured 2026-08-11: `queued=20/20` at 16 s, pop immediately after, a true 10v10.

When you are done:

```bash
MSYS_NO_PATHCONV=1 wsl -d Ubuntu -u deck -- bash /mnt/d/TurtleWow/scripts/wsg-mode.sh off
```

### Why it is deterministic now

`BGJoinAction::isUseful()` used to re-roll a hardcoded 20% tank/healer gate over a
queue choice the operator had already made, and `Engine::ExecuteAction` gates every
commanded action on `isUseful()` — so `bg join` simply never ran. A two-line guard
makes `isUseful()` honour an explicitly-set `bg type`, after the free-slot check and
before the roll, so every real safety gate still applies. Applied by
`scripts/apply-bgjoin-bgtype-fix.sh`; measured 0/3 commanded joins before, 8/8 after.

`wsg-mode.sh on` also strips the wander strategies. Bots grind and cross continents
between matches, and `isUseful()` gates on `IsInCombat()`, so a busy bot silently
cannot be queued — one priest refused 15 commanded joins until this was applied.

## 4. After any mangosd restart: re-add the roster

**The roster does not come back on its own.** The random pool re-logs its own bots
(~60 of them) while your roster sits at 0/20 — the pool's login list does not include
it.

```bash
MSYS_NO_PATHCONV=1 wsl -d Ubuntu -u deck -- bash <<'EOF'
source /mnt/d/TurtleWow/scripts/lib/wsg-bots-common.sh
for nm in Wsgaone Wsgatwo Wsgathree Wsgafour Wsgafive Wsgasix Wsgaseven Wsgaeight Wsganine Wsgaten \
          Wsghone Wsghtwo Wsghthree Wsghfour Wsghfive Wsghsix Wsghseven Wsgheight Wsghnine Wsghten; do
  wsg_console "rndbot add $nm" 6 >/dev/null
done
sleep 5
wsg_mysql "SELECT COUNT(*) FROM tw_char.characters WHERE name LIKE 'Wsg%' AND online=1;"   # expect 20

> `Wsgprobe` is a leftover probe character that also matches `LIKE 'Wsg%'`. Prefer
> `wsg_team_status`, or `wsg-roster.sh verify`, which use `scripts/wsg-team-roster.txt`
> as the definition of membership.
EOF
```

Also expect `characters.map` to read a stale `489` for a minute or two after a restart:
bots log in at the position saved inside the *old* battleground before being teleported
out. Those are phantom counts that fall to zero.

---

## 5. Catching the match (read this before you teleport)

The window is 20 minutes from the pop. Don't teleport blind.

**Step 1 — block until the match actually starts**, then get the exact deadline:

```bash
MSYS_NO_PATHCONV=1 wsl -d Ubuntu -u deck -- bash <<'EOF'
source /mnt/d/TurtleWow/scripts/lib/wsg-bots-common.sh
while :; do
  n=$(wsg_mysql "SELECT COUNT(*) FROM tw_char.characters WHERE name LIKE 'Wsg%' AND online=1 AND map=489;")
  [ "${n:-0}" -ge 16 ] && break
  sleep 15
done
echo "MATCH LIVE — $n/20 in Warsong Gulch at $(date -u +%H:%M:%SZ)"
echo "ends by      $(date -u -d '+20 minutes' +%H:%M:%SZ) (hard cap)"
echo "spectate:    .appear $(wsg_mysql "SELECT name FROM tw_char.characters WHERE name LIKE 'Wsga%' AND online=1 AND map=489 LIMIT 1;")"
EOF
```

**Step 2 — be logged in already**, then paste:

```
.gm on
.gm visible off
.appear Wsgaone
.hover 1
.god on
```

Optional: `.modify speed 2` to keep up with flag carriers, `.bg status`,
`.list battlegrounds`.

`.appear` into a battleground is explicitly supported (it sets the BG id and forces the
map change) and only fails if you are already inside a *different* battleground.

**If you land next to an idle bot in a city, the match already ended.** Re-run the
waiter above and catch the next one.

**Leaving:** `.tele <hub>` then `.gm off`. You are not a real BG member, so `.bg leave`
does not apply.

---

## 6. Monitoring — `logs/bg.log`

`docker logs tw2-mangosd` carries **no** battleground lifecycle lines at the live log
level, so it looks like nothing is happening even when the queue is filling. Use the
dedicated log instead:

```bash
MSYS_NO_PATHCONV=1 wsl -d Ubuntu -u deck -- bash -c 'tail -20 ~/tortoise-wow-server-V2/logs/bg.log'
```

| Line | Meaning |
|---|---|
| `Wsgaseven:4535 [510:<BOT>] tag BG=2` | queued for WSG (id 2) |
| `[489,101]: Wsgaone:4529 … enters` | the pop — instance 101 on map 489 |
| `[489,101]: … leaves` | left the instance |
| `[2,101]: winner=0, duration=20m46s` | match over. **`0`=HORDE, `1`=ALLIANCE, `2`=draw** (`BattleGround.h:187-189`). The leading `2` is the battleground *type* id, not the map id. `duration` is measured when the BattleGround object is destroyed, so it includes up to 120 s of post-match cleanup and is **not** the match length |

> The first recorded match, logged `[2,101]: winner=0`, was previously described here as
> a scoreless draw. It was not — Horde won it 2-0, with flag captures at 15:53:28Z and
> 15:57:08Z visible as 495-honor bursts in `honor.log`.

Count who is queued since a given time:

```bash
MSYS_NO_PATHCONV=1 wsl -d Ubuntu -u deck -- bash <<'EOF'
awk '$2 >= "15:11:00"' ~/tortoise-wow-server-V2/logs/bg.log \
  | grep -a "tag BG=2" | grep -a Wsg | awk '{print $3}' | sed 's/:.*//' | sort -u
EOF
```

> `bots.log` in the same directory is ~10 GB. Never `cat` it.

---

## 7. The mangosd console

`wsg_console "<cmds>" [wait_s]` attaches to the container with
`--detach-keys "ctrl-p,ctrl-q"`.

- **No leading dot.** `server info`, `rndbot add Wsgaone`. (In-game chat keeps the dot.)
- **EOF on the attach stream shuts the world down.** This has happened. Compose sets
  `restart: "no"`, so recovery is `docker start tw2-mangosd` (~1 min to load).
  Always detach with the detach keys; never Ctrl-C the stream.
- Console-aware commands print normally (`server info`), but **`rndbot` replies go to a
  null player session and vanish.** Verify everything in the DB, not from console output.
- `rndbot remove <name>`: offline = no-op; online = unmanage + logout. It never deletes
  the `characters` row.

---

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Bot "is now online" then offline within minutes | Digit in the name — rejected at `LoadFromDB`, message printed optimistically | Alphabetic-only names. Delete the broken rows (`at_login=1`) |
| `.rndbot reload` → no permission | Account `rank=3`; the subcommand needs 4 | `UPDATE tw_logon.account SET rank=4 WHERE id=504;` + relog |
| Roster at 0/20 after a restart | Pool login list excludes the roster | §4 re-add loop |
| Fill stalls at 8v8–9v9 | Floor of 4 pops small matches; 20-min cap resets the cycle | §3.2 forced 10v10 |
| One or two bots never queue | tank/healer 20% roll, or `IsInCombat()`, or partied to a player | Wait; un-party the bot |
| Queue stalls at 16–19/20 for an hour, holdouts alive and unblocked | Bots wedged in a world-activity loop; per-bot reset does **not** fix it | Reset the **whole** roster (§4), or fall back to fast mode |
| `wsg_count_on_wsg` shows phantom numbers post-restart | Stale saved `map=489`, bots not yet teleported out | Wait ~60 s (`PlayerSave.Interval`) |
| `docker logs --since` returns nothing | Timestamp read as local time, lands in the future | Suffix the timestamp with `Z` |
| `docker logs` is enormous | SQL debug logging is on | `grep -v "SQL:"` |
| Teleport lands next to an AFK bot in a city | Match already ended | §5 waiter, then teleport |
| Nothing in `docker logs` about battlegrounds | BG lifecycle isn't logged there | Use `logs/bg.log` (§6) |

---

## 9. Post-match restore

```bash
MSYS_NO_PATHCONV=1 wsl -d Ubuntu -u deck -- bash /mnt/d/TurtleWow/scripts/wsg-mode.sh off
```

Restores every lever to the value it held when `on` was run — pool size, activity
priorities, timed logout, premature finish, the non-combat strategies, quest
behaviour, all `battleground_template` columns, and the GM rank — then logs the roster
out without deleting the characters. Verify with `wsg-mode.sh status`. The bot pool
climbs back to its target over ~20 minutes.

> The old manual checklist was wrong in one way worth knowing: `wsg-only-mode.sh off`
> restored `min_level` but **not** `min_players_per_team`, so the 10v10 floor silently
> survived. `wsg-mode.sh` restores the whole row.

If no snapshot exists — the world was configured by hand — use the documented fallback,
which applies the alive-world profile explicitly:

```bash
MSYS_NO_PATHCONV=1 wsl -d Ubuntu -u deck -- bash /mnt/d/TurtleWow/scripts/wsg-mode.sh off --profile alive-world
```

## 10. Reference — verified numbers and source refs

| Fact | Value | Source |
|---|---|---|
| WSG template | id=2, min 4 / max 10 per team, level 0–60 | `tw_world.battleground_template` |
| Hard match cap | 20 min for WSG/AB, **custom to this server** | `BattleGround.cpp:317-323` |
| Premature finish | arms below `min_players_per_team`, timer 300000 ms | `BattleGround.cpp:326` |
| Testing mode | forces `MinPlayersPerTeam = 1` | `BattleGroundMgr.cpp:867` |
| Queue gates | `randomBotJoinBG`, already in BG, <30 s since login, level<10, player master (568), in combat (574), Deserter (578), no free slot (582), tank/healer 20% roll (586) | `BattleGroundJoinAction.cpp:544-590` |
| Name validation | digits rejected, `numericOrSpace=false` hardcoded | `Util.h:376-394` ← `ObjectMgr.cpp:7049-7067` ← `Player.cpp:16569-16576` |
| "Bot is now online" | printed before login is attempted | `PlayerbotMgr.cpp:2505-2506` |
| Template load | once at boot, no reload command | `World.cpp:2274` |
| Character save interval | 60 s (`PlayerSave.Interval`) — how stale `map` reads can be | `mangosd.conf` |
| Alive-world pool | 40/40 during matches, all level 1–13 | `aiplayerbot.conf`, DB |
| Level-60 population | roster only — no pool bot can enter your match | verified 2026-08-10 |
| GM command ranks | `.appear` OBSERVER, `.god` DEVELOPER, `.hover`/`.bgtest` ADMINISTRATOR | `Chat.cpp` |
| Account ranks | 0 PLAYER, 1 OBSERVER, 2 MODERATOR, 3 DEVELOPER, 4 ADMINISTRATOR, 5 SIGMACHAD, 6 CONSOLE | `Common.h:184-193` |

### Known upstream defect

`LoginFreeBots` never removes a failed login from its queue, so any bot that cannot load
is retried every world tick. The digit-name incident produced **10,558**
`at_login` writes in 39 minutes over two bots. Not patched — it will recur under any
future login failure.
