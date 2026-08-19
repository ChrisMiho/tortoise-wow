---
status: implemented
risk: low
area: game/tournament
depends-on: 030-tournament-heal-and-kill-commands.md
---

# `tournament heal` reports a resurrection that never happened

**Problem:** `Player::ResurrectPlayer` begins
`if (IsHardcore() && !forceHc) return;` (`src/game/Objects/Player.cpp:5755`), and
the heal handler passes no `forceHc`. A dead hardcore target therefore stays a
ghost while the command's record claims `resurrected=1`, and `SetHealth` then
runs on a dead unit.

Tournament bots are never hardcore, so the impact is not the bots — it is the
name-collision case the artifact already argued on the kill side: the kill path
has a hardcore guard precisely so a collision from the viewer-effect queue
cannot destroy a real hardcore character. By the same argument, heal emits a
false resurrection record for one.

**Suspected cause / area:** the `tournament heal` handler added by artifact 030.
The kill path's existing hardcore guard is the model.

**Acceptance criteria:**

- A hardcore target is either refused with a named reason, or the result is
  re-checked with `IsAlive()` after the call. In neither case does the record
  read `resurrected=1` for a character still a ghost.

**Notes:**

- Needs a build; verifiable with any hardcore test character, no match required.
- Docker builds run in the foreground at ~8.5 min — `timeout: 600000`,
  `BUILD_JOBS=14`, and verify with `docker images` rather than the exit code.

**Base:** cm-main

**Branch:** backlog/tournament-heal-false-resurrection-on-hardcore

**Summary:** In `ChatHandler::HandleTournamentHealCommand` (src/game/Commands/TournamentCommands.cpp), the dead-target branch now refuses a hardcore character before touching it, emitting `heal player=<name> ok=0 reason=hardcore_character` — the same guard shape the `tournament kill` handler already carries, and the same reason string. It also re-checks `plr->IsAlive()` immediately after `plr->ResurrectPlayer(1.0f)`; if the target is still a ghost (any other silent decline inside ResurrectPlayer), the handler skips `SpawnCorpseBones()` and `SetHealth()` and emits `ok=0 reason=resurrect_refused` instead. `resurrected=1` is now only ever written after the server has confirmed the target is actually alive, and `SetHealth` can no longer run on a dead unit. Live-player and dead-non-hardcore behaviour is unchanged: the alive path still full-heals and reports `resurrected=0 ok=1`, a normal dead bot still revives with corpse bones cleared and reports `resurrected=1 ok=1`. No SQL migration, no schema or config change; one file, 24 added lines.

**In-game check:** Needs a build — this command does not exist in the rollback-anchor image on this host, so "no such subcommand" against the currently running server proves nothing.

Once a server built from this branch is up, the whole check is readable from the mangosd console output (the `TOURNAMENT ...` records the handler emits), so no visual in-world observation is required beyond watching a ghost stay a ghost:

1. Start a match the normal way: `rndbot start` / `.bg` per the existing tournament flow, so at least two bots are in a WSG battleground instance. Note one bot's name, e.g. `Wsgaone`.
2. Regression, non-hardcore dead target: console `.tournament kill Wsgaone` → expect `TOURNAMENT kill player=Wsgaone ok=1 reason=-`. Wait ~5 s, then `.tournament heal Wsgaone` → expect `TOURNAMENT heal player=Wsgaone hp=<max> resurrected=1 ok=1`, and the bot is visibly alive and running again (not a ghost). This is the path that must NOT have regressed.
3. Regression, alive target: with the bot alive, `.tournament heal Wsgaone` → expect `resurrected=0 ok=1` and `hp=` equal to its max health.
4. The actual fix. Create or use a hardcore test character — a character whose `IsHardcore()` is true (hardcore is set at character creation on this fork; a GM can also flag one in `characters` and relog it). Get that character into a battleground instance so the handler's `TournamentFindPlayerInBattleGround` accepts it, then kill it by normal means (mob damage, or `.die` on a non-hardcore stand-in will not work here — the hardcore character must actually be dead and a ghost).
5. Console `.tournament heal <hardcoreName>` → expect exactly `TOURNAMENT heal player=<hardcoreName> ok=0 reason=hardcore_character`. Confirm three things: the record does NOT contain `resurrected=1`, the record does NOT contain `ok=1`, and the character is still a ghost in-world (release/spirit form, corpse still on the ground, corpse bones NOT spawned).
6. Absence check in the logs: `docker logs tcm-mangos 2>&1 | grep 'TOURNAMENT heal'` should contain no line pairing a `resurrected=1` with a character that is still dead, and no `reason=resurrect_refused` line for an ordinary bot — that reason firing for a non-hardcore target would mean `ResurrectPlayer` is declining for some other reason and is worth investigating.

Steps 2, 3, 5 and 6 are fully scriptable from console output alone. Step 4's prerequisite (obtaining a dead hardcore character inside a battleground) is the only part that plausibly needs a human, since hardcore flagging and getting that character into a BG is not something the bot harness does.
