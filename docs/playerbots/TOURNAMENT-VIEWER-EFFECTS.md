# Viewer effects

Eight interventions a viewer can trigger against a **live** match: heal, kill, or
upgrade one bot or a whole team, mid-fight, applied exactly once.

In-game a viewer types a command in chat (or donates); a Warsong Gulch bot drops
dead, gets resurrected at full health, or visibly re-equips into the next gear
tier. Technically that action is appended to an NDJSON queue file, and a consumer
loop running for the duration of the match drains it and applies each command
through the `.tournament` control plane.

## The eight effects, and their caps

| Effect | Target | Applied by | Default cap per match |
|---|---|---|---|
| `heal_player` | one bot | `tournament heal <name>` | 50 |
| `heal_team` | all ten | ten `tournament heal` calls | 10 |
| `kill_player` | one bot | `tournament kill <name>` | 20 |
| `kill_team` | all ten | ten `tournament kill` calls | 2 |
| `upgrade_armor_player` | one bot | `tournament equip`, next tier's armour slots | 20 |
| `upgrade_armor_team` | all ten | as above, ten bots | 2 |
| `upgrade_weapon_player` | one bot | `tournament equip`, next tier's weapon slots | 20 |
| `upgrade_weapon_team` | all ten | as above, ten bots | 2 |

**Why caps exist:** `kill_team` is match-deciding — it ends a game outright. With
no cap, one script hammering the queue decides every match in the bracket and the
tournament stops being a contest. The caps are per effect class, counted per match
in `<run-dir>/effects/counts.txt`, and a command refused by a cap is recorded as
handled so it is not retried forever. Override any of them per run:

```bash
EFFECT_LIMIT_KILL_TEAM=1 EFFECT_LIMIT_HEAL_TEAM=20 ./scripts/tournament/match-run.sh ...
```

The variable name is `EFFECT_LIMIT_` plus the effect name upper-cased:
`EFFECT_LIMIT_KILL_PLAYER`, `EFFECT_LIMIT_UPGRADE_ARMOR_TEAM`, and so on.

## The queue

Append-only NDJSON, one command per line:

```json
{"id":"1755381791123456789-4821","ts":"2026-08-16T21:03:11Z","effect":"heal_player","target":{"team":"stormwind-sentinels","slot":"three"},"source":"mock"}
```

| Field | Meaning |
|---|---|
| `id` | **the dedupe key** — unique per command |
| `ts` | UTC enqueue time, for the audit trail |
| `effect` | one of the eight names above |
| `target.team` | team id, matched against a file in `config/tournament/teams/` |
| `target.slot` | slot name; required by the four `_player` effects, absent on `_team` |
| `source` | which adapter produced it (`mock`, later a channel name) |

`id` is what makes an effect fire exactly once. The consumer records every id it
has handled in `<run-dir>/effects/applied.txt` and skips any id already there, so
a queue replayed after a crash — or an adapter that delivers the same command
twice — still applies it once. An effect a viewer paid for must not fire twice,
and a team must not be wiped twice for one `kill_team`.

That ledger is **per match** — it sits under `--state`, which `match-run.sh` sets
to `<run-dir>/effects` — while the queue may be a single long-lived file shared by
every match in a bracket. A new match's consumer therefore starts with an empty
ledger in front of an append-only queue it re-reads from the top, so
`match-run.sh` seeds `applied.txt` with every id already queued before the
consumer's first pass. See *Safety* below for why neither of the other two guards
catches that.

The file is **append-only**. Never rewrite it in place: the consumer may be
reading it at that moment.

## Adapters

`scripts/tournament/effect-queue.sh` is the **mock** adapter — a CLI that
validates a command and appends one line:

```bash
./scripts/tournament/effect-queue.sh --queue "$Q" \
    --effect kill_player --team orgrimmar-warsong --slot five
```

A real Twitch or TikTok listener **replaces that script and nothing else**.
Everything downstream — the consumer, the effect library, the control-plane
commands — reads the file, not the network. That boundary is why this pass builds
no OAuth and no chat client: the whole path can be tested end to end with no
credentials and no live channel.

## Running during a match

`scripts/tournament/match-run.sh` starts the consumer immediately after
`tournament start` and stops it the instant the monitor loop breaks:

```
[21:03:04Z] match started, instance 3
[21:03:04Z] queue logs/tournament/<run>/effects.ndjson held 0 command(s) before this match -- recorded as already handled in logs/tournament/<run>/effects/applied.txt
[21:03:04Z] effect consumer started (pid 41277), queue logs/tournament/<run>/effects.ndjson, state logs/tournament/<run>/effects, log logs/tournament/<run>/effects.log
...
[21:21:38Z] effect consumer stopped (pid 41277)
```

Defaults, all under the run directory:

| Path | Contents |
|---|---|
| `<run-dir>/effects.ndjson` | the queue (override with `EFFECT_QUEUE`) |
| `<run-dir>/effects.log` | the consumer's `EFFECT` and `CONSUME` lines |
| `<run-dir>/effects/applied.txt` | every id already handled — seeded at match start with every id already in the queue |
| `<run-dir>/effects/counts.txt` | one line per applied effect, for the caps |

The queue file is created if it does not exist, so a match nobody interacts with
runs exactly like one that is flooded.

## Safety

Four properties, each of which exists because its absence is a real failure mode:

- **Effects refuse a bot that is not in a battleground.** `tournament heal` and
  `tournament kill` check `Player::InBattleGround()` and answer
  `error=not_in_battleground(<name>)` otherwise. The queue outlives a match; a
  stale command must not resurrect or execute a bot idling in Stormwind.
- **A team not in the current match is rejected.** The consumer is started with
  `--alliance` and `--horde` set to the two teams actually playing, and
  `effect_targets` refuses any other team by name rather than resolving it to
  offline characters and silently doing nothing.
- **Upgrades move exactly one tier, by `rank`, and never wrap.** At the top tier
  the effect is a no-op that reports `already_top_tier` — it does not fall back to
  the base tier, which would be a downgrade sold to a viewer as an upgrade.
- **The consumer never crosses into the next match.** Two mechanisms, because the
  obvious one is only half of it. `match-run.sh` kills the consumer the moment the
  monitor loop breaks, before the two rosters are logged out, and an `EXIT` trap
  kills it as well so a `fatal`, the deadline path, or a Ctrl-C cannot leave it
  running. Without that, the next effect off the queue would land on the
  *following* match's bots. Lifetime alone still leaks when `EFFECT_QUEUE` names
  one file shared by every match: `applied.txt` is per match, so the next
  consumer's ledger is empty and the append-only queue is read from the top again.
  Neither other guard stops the replay — the team check passes whenever that team
  is playing again, which in a bracket is ordinary, and `InBattleGround()` passes
  because the bots are in a battleground, just not the one the command was aimed
  at. So `match-run.sh` also records every id already in the queue as handled
  before the consumer starts. An effect is aimed at a *live* match; anything
  queued before this one started was aimed at a different match, or at none.

## Smoke test against a live match

With a match running:

```bash
Q=logs/tournament/<run>/effects.ndjson
./scripts/tournament/effect-queue.sh --queue "$Q" --effect kill_player \
    --team orgrimmar-warsong --slot five
sleep 10
./scripts/tournament/effect-queue.sh --queue "$Q" --effect heal_team \
    --team orgrimmar-warsong
```

`logs/tournament/<run>/effects.log` should show
`EFFECT id=… effect=kill_player … applied=1 failed=0`, then
`EFFECT id=… effect=heal_team … applied=10 failed=0`. Cross-check the kill in
`telemetry.csv`: `alive` reads `0` for that bot at the matching `t`.
