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
