# Running a tournament

`scripts/tournament/tournament-run.sh` drives a whole bracket: it validates the
bracket, plays every pairing through `match-run.sh`, records each result, and
stops on a champion, a block, or a failure.

Run it from **WSL**, not Git Bash — `jq` is not on Git Bash's PATH on this host
and the script exits 2 without it.

```bash
./scripts/validate-stack.sh --image tortoise-cm:<tag> --keep-up
./scripts/tournament/tournament-run.sh wsg-open --run-dir logs/tournament/friday
```

Budget roughly **25 minutes per match** — a match is hard-capped at 20 minutes
(`BattleGround.cpp:317-323`) and bot matches usually run the full clock, plus the
roster swap either side of it. `wsg-open` is three matches, so about 75 minutes.

## Resuming

Re-run the **same `--run-dir`**. That is the whole interface; there is no
`--resume` flag and no reset flag either (delete the directory to start over).

```bash
./scripts/tournament/tournament-run.sh wsg-open --run-dir logs/tournament/friday
```

Every result is written to `state.json` the moment it is known and **before the
next match starts**, so an interruption — a crash, a power cut, you pressing
Ctrl-C, a mangosd restart — costs the match that was in flight and nothing else.
Each write goes to a temp file and is renamed over the real one, so a kill in the
middle leaves either the old state or the new one, never a truncated file.

Resume matches on the **pairing**, not on a match index, so a half-finished round
resumes to the right match. Already-recorded pairings print

```
skipping stormwind-sentinels vs orgrimmar-warsong — already recorded
```

and the run picks up at the first pairing that has no result. To replay a match,
delete its entry from `.results` in `state.json` — the driver will then see it as
unplayed. (The eliminated team does *not* come back on its own; put it back in
`.survivors` too if that is what you mean.)

## Structure: two mirrored ladders

Every WSG match must be Alliance versus Horde. `SetBGTeam` controls scoring and
spawn side but **not hostility** — `Unit::IsHostileTo` resolves through the
faction templates (`src/game/Unit.cpp:5189`) — so a same-faction "match" is twenty
bots standing in a tunnel refusing to fight, with nothing in any log to explain
it.

So a bracket is two ladders, one per faction, and the *n*th alliance survivor
plays the *n*th horde survivor each round. That makes every pairing cross-faction
by construction rather than by luck. The ladders must be equal in length and a
power of two, which is what `bracket_validate` enforces.

The consequence to plan for: **if both round-one matches go to the same faction,
the bracket cannot continue.** Two alliance survivors have no horde opponents, and
pairing them would produce a match no bot will play. The run stops with

```
TOURNAMENT-RUN bracket=wsg-open status=blocked reason=uneven_survivors(A=2,H=0)
```

That is a human decision, not a bug — reseed, or run a different pairing by hand.
It is not rare: of the 22 decided matches in `bg.log` as of 2026-08-16, 16 went to
Alliance.

## Draws are decided, not blocked — and a decision is not a win

Of the 37 matches recorded in `bg.log` as of 2026-08-16, **15 were draws — 41%**.
The 20-minute cap ends a match whether or not anyone capped a flag, so `winner=NONE`
is ordinary. A driver that stopped on a draw would stall roughly two rounds in
five, unattended, in the middle of the night. So on `winner=NONE` the driver walks
a tiebreak ladder and stops at the first rung that separates the two teams:

| Rung | `decidedBy` | What it compares | When it is skipped |
|---|---|---|---|
| 1 | `tiebreak_score` | `allianceScore` / `hordeScore` from the `MATCH` line. In WSG the score **is** flag captures, so this is "who capped more". | Either score reads `-1` (nothing could be read), or the two are equal. |
| 2 | `tiebreak_deaths` | Deaths counted from the match's `telemetry.csv` — `alive` going `1` → `0`, summed per team. Fewer deaths wins. | No CSV, an empty one, or an equal count. This is the **normal** case: telemetry only exists when `Tournament.TelemetryIntervalMs` is non-zero, and it is `0` by default. |
| 3 | `tiebreak_seed` | Position in `bracket_ladder` — the earlier team wins. | Never. This rung always decides, so the ladder always terminates. Round one pairs seed *n* against seed *n*, and that tie goes to the Alliance seed, because something has to decide it and a stated rule beats a coin. |

Each rung logs the pairing, the rung and the numbers that decided it, at the time
it decides:

```
tiebreak ironforge-anvils vs thunderbluff-braves: deaths 1-0 -> HORDE (rung: fewer deaths)
```

**A tiebroken match is a decision, not a result.** The battleground did not
declare that winner; the driver did. `decidedBy` in `state.json` is where the two
are told apart — `"server"` means the server declared it, anything beginning
`tiebreak_` means the driver chose:

```bash
jq '.results' logs/tournament/friday/state.json
jq '[.results[] | select(.decidedBy != "server")]' logs/tournament/friday/state.json
```

The run's final report says the same thing in one line, so nobody has to open the
file:

```
TOURNAMENT-REPORT bracket=wsg-open matches=3 outright=1 tiebreak=2 tiebreak_score=1 tiebreak_deaths=1 tiebreak_seed=0
TOURNAMENT-REPORT bracket=wsg-open champion=stormwind-sentinels won_outright=1 won_on_tiebreak=1
TOURNAMENT-RUN bracket=wsg-open champion=stormwind-sentinels rounds=2
```

A champion crowned entirely on tiebreaks is a legitimate outcome — it is not the
same as one that won its matches, and the report adds
`note=champion_won_no_match_outright` when that happens.

If most of a bracket settles on `tiebreak_seed`, the bots are not scoring at all.
That is a finding for `docs/playerbots/BG-AI-ANALYSIS.md`, not a tournament that
worked.

A match that produced **no `MATCH` line at all** is still a failure, not something
to tiebreak — two teams that never played have nothing to compare:

```
TOURNAMENT-RUN bracket=wsg-open status=failed reason=no_result(ironforge-anvils vs thunderbluff-braves)
```

## Only twenty bots are online

**Exactly the 20 bots playing the current match are in the world.** Before each
match `match-run.sh` logs every other team out, brings the two playing teams in,
and then gates on the population: if more than one character outside the two
rosters is online, it refuses to start the match.

That includes the alive-world random bot pool, which **must be off before you
start a run**. Bot AI is single-core, so a random pool sharing it slows every bot
in the battleground and changes the match you are trying to measure. Turn it off
in `aiplayerbot.conf` and restart mangosd *first* — no script here will do it
mid-run, because that would change the world underneath a match in progress.
`tournament-run.sh` does not manage that pool at all.

## Terminal lines

Every one of these is the last line of the run, and every one is also in
`<run-dir>/tournament.log`:

```
TOURNAMENT-RUN bracket=<id> champion=<team-id> rounds=<n>
TOURNAMENT-RUN bracket=<id> status=blocked reason=uneven_survivors(A=<n>,H=<n>)
TOURNAMENT-RUN bracket=<id> status=blocked reason=exceeded_expected_rounds
TOURNAMENT-RUN bracket=<id> status=failed reason=no_result(<a> vs <h>)
```

`exceeded_expected_rounds` means the rounds kept advancing without resolving to a
champion — most often a run resumed onto results recorded as `winner=NONE`, which
eliminate nobody. Exit status is 0 for a champion, 1 for blocked or failed.

## Artifacts

```
logs/tournament/<run>/state.json                          the resumable run state
logs/tournament/<run>/tournament.log                      the driver's narration and every terminal line
logs/tournament/<run>/r<N>-<a>-vs-<h>/match.log           one directory per match: match-run.sh's narration
logs/tournament/<run>/r<N>-<a>-vs-<h>/roster.log          the logout/login swap for that match
logs/tournament/<run>/r<N>-<a>-vs-<h>/gear.log            the gear gate's findings
logs/tournament/<run>/r<N>-<a>-vs-<h>/assemble.log        the console replies that put bots in the instance
logs/tournament/<run>/r<N>-<a>-vs-<h>/telemetry.csv       per-player samples, when telemetry is enabled
```

The match directory is named for the round and the pairing, so it survives a
resume: a replayed match writes into the same directory rather than a new one.

## Related

- `docs/playerbots/TOURNAMENT-ROSTERS.md` — team files and `roster.sh`
- `docs/playerbots/TOURNAMENT-CONTROL-PLANE.md` — the `tournament` console commands
