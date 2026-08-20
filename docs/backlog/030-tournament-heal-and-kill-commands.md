---
status: done
risk: high
area: game/commands
depends-on: 017-tournament-equip-and-store-commands.md
---

# A viewer cannot heal or kill a bot mid-match

**Problem:** The viewer-interaction design needs two interventions the control
plane cannot make: fully heal (and resurrect) a bot, and kill one. Neither exists.
The dangerous half is targeting: **the effect queue outlives the match that
produced it**, so a command that lands on a bot which has already left the
battleground is not a harmless no-op — it is the wrong bot getting the viewer's
effect, and it looks like nothing happened.

**Suspected cause / area:** Implements
`docs/superpowers/plans/2026-08-16-06-viewer-effects.md` Task 1, in
`src/game/Commands/TournamentCommands.cpp` plus the `Chat.h` / `Chat.cpp`
declarations and registrations.

**Acceptance criteria:**

- `heal <playerName>` emits `heal player=<name> hp=<n> resurrected=<0|1> ok=1`.
  If the target is dead it resurrects **and clears the corpse**
  (`ResurrectPlayer(1.0f)` then `SpawnCorpseBones()`, the same pair `.revive` uses
  at `Commands.cpp:3016`) — resurrecting without clearing leaves a corpse the
  client can still run back to.
- `kill <playerName>` emits `kill player=<name> ok=<0|1> reason=<text>`.
- **Both refuse a player who is not currently in a battleground**, with
  `error=not_in_battleground(<name>)`, and refuse one who is not online, with
  `error=player_not_online(<name>)`. That guard is the point of the task, not an
  edge case.
- `kill` reports `ok=0 reason=already_dead` for a corpse, and
  `ok=0 reason=hardcore_character` when `IsHardcore()` — mirroring `.die`'s refusal
  at `Commands.cpp:2805`. Tournament bots are not hardcore, but the alternative is
  a console command that can permanently destroy a character.
- **`kill` applies self-inflicted lethal damage** (`DealDamage(plr,
  plr->GetHealth(), …, DIRECT_DAMAGE, SPELL_SCHOOL_MASK_NORMAL, …)`) rather than
  setting state directly, so normal battleground death handling runs: the death is
  scored, the bot releases, and it respawns at its graveyard like any other kill.
- Both are declared in `Chat.h`, registered in `tournamentCommandTable` with
  `AllowConsole = true`, and emit exclusively through `TournamentEmit`.

**Notes:**

- **Do not attempt a Docker build here** (~9.5 min, no incremental build); the
  `backlog-batch` pass compiles this branch. The criteria above are structural on
  purpose.
- Risk is `high`: `kill` deals lethal damage to a `Player*` resolved by name on a
  server running ~1000 concurrent playerbots, and `heal` mutates health and
  resurrection state. Null-check every lookup, and consider what happens if the
  target dies, leaves, or is despawned between the lookup and the mutation.
- This artifact edits the same three files as artifacts 015-017, which is why it
  stacks on 017 rather than cutting fresh.
- **Verification needing a live stack (not part of these criteria):** with a bot
  online but **not** in a battleground, both commands must return
  `error=not_in_battleground(Wsgaone)` — **that refusal is the success case for
  this step.** Then, during a live match, `tournament kill Wsgaone` → `ok=1`, and
  ~5 s later `tournament heal Wsgaone` → `resurrected=1 ok=1`. Cross-check the
  kill against the telemetry CSV: `alive` should drop to `0` for that bot at the
  matching `t`.

**Base:** backlog/tournament-equip-and-store-commands

**Branch:** backlog/tournament-heal-and-kill-commands

**Summary:** Added two console-callable subcommands to the tournament control plane. `src/game/Commands/TournamentCommands.cpp` gains `HandleTournamentHealCommand` and `HandleTournamentKillCommand`, plus a shared file-static helper `TournamentFindPlayerInBattleGround(name, error)` that resolves the name through `ObjectAccessor::FindPlayerByName` (in-world only) and then requires `Player::GetBattleGround()` to be non-null, handing back the refusal token `player_not_online(<name>)` or `not_in_battleground(<name>)` for the caller to label with its own verb — `TournamentEmit` is a protected member of `ChatHandler`, so the free function cannot emit for itself. I used `GetBattleGround()` rather than the plan's `InBattleGround()` deliberately: the latter is only `m_bgData.bgInstanceID != 0`, which is also true for a bot `tournament add` has invited but whose world port has not landed, and for an id whose instance the manager has already reaped; resolving the instance rejects both, which is what the "effect queue outlives the match" hazard actually needs. `heal` resurrects a corpse with `ResurrectPlayer(1.0f)` then `SpawnCorpseBones()` (the `.revive` pair at `Commands.cpp:3016`, so no runnable-to corpse is left), then `SetHealth(GetMaxHealth())` for the alive-but-hurt case, and emits `heal player=<name> hp=<n> resurrected=<0|1> ok=1`. `kill` refuses a corpse with `ok=0 reason=already_dead` and a hardcore character with `ok=0 reason=hardcore_character` (mirroring `.die` at `Commands.cpp:2805`), then applies self-inflicted lethal damage via `plr->DealDamage(plr, plr->GetHealth(), nullptr, DIRECT_DAMAGE, SPELL_SCHOOL_MASK_NORMAL, nullptr, false)` so normal battleground death handling scores the death and sends the bot to its graveyard, and emits `kill player=<name> ok=1 reason=-`. Both are declared in `src/game/Chat/Chat.h` and registered in `tournamentCommandTable` in `src/game/Chat/Chat.cpp` with `AllowConsole = true` at `SEC_ADMINISTRATOR`, and every record goes out through `TournamentEmit` only. The one departure from the plan's literal snippet is the usage line: it emits the space-free `heal error=usage` / `kill error=usage` and puts the syntax string on its own unprefixed line, because the file's output contract forbids a space inside a value. No build was run (rule 4) and no container was started — nothing was running, and neither new command exists in any image on this host, so there was nothing live to exercise.

**In-game check:** Scriptable from the console alone — no human needs to be in the client for steps 1-5; only step 6 wants eyes on the world.

1. Bring the stack up on the image built from this branch and confirm the subcommands registered at all: through `wsg_console` (docs/playerbots/wsg/lib/wsg-bots-common.sh — never a bare `docker attach`), send `tournament heal` with no argument. Expect two lines: `TOURNAMENT heal error=usage` and an unprefixed `Syntax: .tournament heal <playerName>`. Same for `tournament kill`. "There is no such subcommand" here means the registration in `tournamentCommandTable` did not take.
2. Offline refusal: `tournament heal Nosuchname` → `TOURNAMENT heal error=player_not_online(Nosuchname)`. Same for `kill`.
3. **The success case for this artifact** — the out-of-match refusal. With a tournament bot online but standing in a city (spawn it with `rndbot` and do not add it to an instance), send `tournament heal Wsgaone` and `tournament kill Wsgaone`. Both must answer `TOURNAMENT heal error=not_in_battleground(Wsgaone)` / `TOURNAMENT kill error=not_in_battleground(Wsgaone)`, and the bot must still be alive and at whatever health it had. A bot that dies here is the exact bug this task exists to prevent. Also check `bg.log` for the mirrored `TOURNAMENT ... not_in_battleground` line, since the console session may be detached.
4. In-match kill: run a match with `scripts/tournament/` (create, add both teams, start), then during `status=InProgress` send `tournament kill Wsgaone` → `TOURNAMENT kill player=Wsgaone ok=1 reason=-`. Immediately re-send it: the second call must answer `ok=0 reason=already_dead`, proving the corpse guard and that a replayed queue entry is harmless.
5. In-match heal: ~5 s later, `tournament heal Wsgaone` → `TOURNAMENT heal player=Wsgaone hp=<full> resurrected=1 ok=1`, where `<n>` equals the bot's max health. Then damage it in combat and heal again — expect `resurrected=0 ok=1` with hp back at max.
6. Cross-checks that the kill went through the real death path rather than a state poke: (a) the telemetry CSV from artifact 05 must show `alive` dropping to `0` for that bot at the matching `t` and back to `1` after the heal; (b) `tournament result <instanceId>` / the WSG scoreboard must count the death — a `DealDamage` kill is scored, a `SetHealth(0)` would not be; (c) after the heal, the bot must have no corpse left on the field — confirm by watching the spot in the client, or indirectly by checking the bot never runs a corpse-retrieval path and no second `alive=0` blip appears. (c) is the one part that really wants a human in the client; everything else reads off console output, `bg.log`, and the telemetry CSV.
7. Hardcore refusal is not reachable with tournament bots (they are never hardcore) and needs no live check; the guard is there so `tournament kill` can never permanently destroy a real player's hardcore character if a name from the effect queue ever collides with one.

**Minor findings:**
- src/game/Commands/TournamentCommands.cpp: `heal` reports `resurrected=1 ok=1` even when the resurrect silently did nothing: `Player::ResurrectPlayer` returns early for a hardcore character (Player.cpp:5755, `if (IsHardcore() && !forceHc) return;`), so a dead hardcore target stays a ghost while the handler still sets `resurrected=1` and calls `SetHealth(GetMaxHealth())` on a dead unit — the kill path guards `IsHardcore()` but the heal path does not, and re-checking `plr->IsAlive()` after the call (or refusing hardcore up front) would make the emitted record match reality.
- src/game/Commands/TournamentCommands.cpp: `heal` has no hardcore guard, but `Player::ResurrectPlayer` returns immediately for a hardcore character (Player.cpp:5755), so the handler reports `resurrected=1` and then `SetHealth(GetMaxHealth())` on a unit still in the dead state — a corpse with full health and a record claiming a resurrection that never happened.

**Drain note (both findings are the same real defect; the GetBattleGround departure is sound):** verified against the source on 2026-08-18. (1) The heal/hardcore defect is REAL: src/game/Objects/Player.cpp:5755 reads exactly `if (IsHardcore() && !forceHc) return;` at the top of `Player::ResurrectPlayer(float restore_percent, bool applySickness, bool forceHc)`, and the handler passes no forceHc, so a dead hardcore target stays a ghost while the record claims `resurrected=1` and SetHealth runs on a dead unit. The two findings are one defect seen twice. It is low-impact for tournament bots, which are never hardcore -- but note the asymmetry is exactly the case the artifact already argued for on the kill side: the kill hardcore guard exists so a name collision from the effect queue can never destroy a real hardcore character, and by the same collision argument heal would emit a false resurrection record for one. Guard heal for hardcore, or re-check IsAlive() after the call. (2) SEPARATELY, the Summary's deliberate departure from the plan -- using GetBattleGround() instead of the plan's InBattleGround() -- is CORRECT and should be kept: src/game/Objects/Player.h:3089 defines `bool InBattleGround() const { return m_bgData.bgInstanceID != 0; }`, a bare flag that is also true for a bot invited but not yet ported and for an id whose instance has been reaped. Resolving the instance rejects both, which is precisely the "effect queue outlives the match" hazard this artifact exists to prevent.

**Result:** PR opened at https://github.com/ChrisMiho/tortoise-wow/pull/40, build tortoise-cm:20260818-2.
