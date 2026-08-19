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

### One driver at a time

A run directory takes an exclusive `flock` on `<run-dir>/.lock` before it touches
`state.json`, and holds it until the process exits. A second invocation on a run
dir that is still live refuses:

```
FATAL: another tournament-run.sh is already driving logs/tournament/friday (pid 4711 on TORTOISE since 2026-08-17T23:04:11Z)
```

That refusal is the point of the lock. "Re-run the same `--run-dir`" is also what
an operator does when a run merely *looks* stuck, and if the first process is
alive two drivers would read the same pairing as unplayed, run `match-run.sh`
over the same twenty bots twice, and interleave their `jq` writes in
`state.json.tmp` — publishing a corrupt or silently-losing `state.json` and
costing the night rather than one match.

The kernel drops the lock when the holder exits, however it exits, so a crash or
a power cut leaves nothing to clean up: just re-run. There is no stale lock to
delete, and deleting `.lock` by hand does not free anything — it only gives the
next arrival a different file to lock. If a run is genuinely stuck, kill the
driver (and the `match-run.sh` it started) and re-invoke.

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
rosters is online, it refuses to start the match. The one it allows for is the GM
spectator.

### The random pool runs at zero — and that is an operator step

The alive world ships with **1000** random bots — `AiPlayerbot.MinRandomBots` and
`MaxRandomBots`, both `1000` in `aiplayerbot.conf.dist.in:57-58`. A tournament
runs with that pool at **zero**, so the only characters online are the twenty
playing plus a GM spectator.

**That is a CPU decision, not a memory one.** Bot AI is single-core, so every
random bot that thinks is time the twenty bots in the battleground do not get.
Memory at 1000 bots is comfortable — **4.27 GiB measured** — so a match that
degrades is telling you about the scheduler, not about RSS, and giving the box
more RAM will not fix it.

Zero is a legal value for this build, not a special case that has to be rounded up
to 40. `RandomPlayerbotMgr::UpdateAIInternal` draws its target from
`urand(minRandomBots, maxRandomBots)` and then only logs bots in while
`availableBotCount < maxAllowedBotCount` (`RandomPlayerbotMgr.cpp:671-703`), so a
target of 0 simply never refills. Nothing logs an *already online* bot out for
exceeding the target either — the only logout lever is `RandomBotTimedLogout`
(`RandomPlayerbotMgr.cpp:2316`), which the match profile pins to `0`.

**`rndbot add <name>` still works with the pool at zero**, which is what the whole
design rests on: the tournament characters are logged in explicitly by
`roster.sh login`, never by the pool's auto-login. `AddRandomBot()` checks the
random-account list and the stale-login event and never reads `minRandomBots` or
`maxRandomBots` at all (`RandomPlayerbotMgr.cpp:2232-2291`). Verified live on
2026-08-18 against `tortoise-cm:20260818-5` booted with `0/0`: `rndbot add` brought
the named character online and it stayed online.

### Setting it, and putting it back

`tournament-run.sh` does **not** manage the pool. It will not shrink it before a
run and will not restore it after, because doing either mid-run would change the
world underneath a match in progress. Both are operator steps, and both need a
mangosd restart — the pool size is read at boot.

```bash
# before the run
docs/playerbots/wsg/wsg-mode.sh on --tournament     # pool 0/0, restarts mangosd
./scripts/tournament/tournament-run.sh wsg-open --run-dir logs/tournament/friday
# after the run
docs/playerbots/wsg/wsg-mode.sh off                 # restores what was there before `on`
```

Run both from **WSL**, not Git Bash. `--tournament` also skips `wsg-roster.sh
ensure`, which plain `on` runs: that is the WSG demo roster, not the tournament
roster, and every one of those characters online is a character `match-run.sh`'s
population gate counts and refuses to start on.

What `on` actually does is **snapshot, not hardcode**: it records the live value of
every lever it is about to change into
`~/tortoise-wow-server-V2/.wsg-mode-snapshot.json`, and `off` writes back exactly
those values. So `off` restores the pool you had, whatever it was — 1000 or
anything else. Plain `on` uses 40, the WSG-match value; `on --tournament` uses 0.
`on` refuses to run when a snapshot already exists, because a second `on` would
snapshot match-mode values as "how it was". If `status` says `wsg-match` on a world
whose conf looks like the alive world, that is a leftover snapshot from an
abandoned session — check the file's timestamp before trusting either.

The one hardcoded profile is the fallback in the `off` path, used only when there
is no snapshot: `wsg-mode.sh off --profile alive-world`. It no longer carries
literals for the conf keys; it reads them out of the shipped
`aiplayerbot.conf.dist.in` and `mangosd.conf.dist.in` (with literals kept only as a
last resort for a host that has no source tree). It used to say `200` bots, from
before the compiled default became 1000, so the "documented alive-world profile"
quietly restored a world a fifth of its intended size.

**Confirm the restore.** A world left at zero is the failure mode that does not
announce itself — mangosd is healthy, realmd answers, nothing errors, and the world
is simply empty:

```bash
docs/playerbots/wsg/wsg-mode.sh status     # prints Min/MaxRandomBots from the live conf
```

`PlayerSave.Interval` is 60 s, so counting online characters in `tw_char.characters`
lags reality by up to a minute; the conf values in `status` are immediate.

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
logs/tournament/<run>/.lock                                the one-driver-at-a-time lock; never deleted, never stale
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
