# Tournament release record

The release record for the bot battleground tournament build. It is written
*before* the tag is cut, so that cutting the tag is a matter of filling in
measurements rather than reconstructing what a name meant months later.

**No tag has been cut yet.** Three sections below are deliberately empty and
marked as such. An empty section marked "unfilled" is honest; a plausible-looking
filled one is a fabricated release record, and this document is the only thing
that gives a rollback target any meaning. Fill them from real runs, or leave them.

Cut the tag with:

```bash
./scripts/release-tag.sh tournament-v1          # then --push to publish
```

That script refuses on a dirty tree, on a tag name already in use, and when
`scripts/verify-running-commit.sh` says the running server was not built from
HEAD. A tag on an unverified image looks authoritative and is not.

---

## What this build is

The bot battleground tournament, delivered by the plan series
`docs/superpowers/plans/2026-08-16-00` through `-09`:

| Plan | What it delivers |
|---|---|
| `-00` Build provenance & stack validation gate | `scripts/lib/provenance.sh`, `verify-running-commit.sh`, `validate-stack.sh` — every image stamped with the commit it was built from, and a stack that refuses to be called good unless provenance, identity and liveness all pass |
| `-01` Team definitions & roster lifecycle | JSON team files and `scripts/tournament/roster.sh`, which reconciles a team against the world |
| `-02` Tournament control plane | The console-callable `tournament` command family: instance create/populate/start/stop/score, team, add |
| `-03` Itemized gear loadouts & tiers | Gear tier files with armour/weapon splits, the generators that fill them, and `gear-audit.sh` to check a team is actually dressed |
| `-04` Bracket engine & tournament runner | A bracket plus run state that survives a reboot, and `match-run.sh` to run one match end to end |
| `-05` Battleground telemetry & bot log capture | Per-match telemetry sampling, entry and movement reports, and per-match log artifacts |
| `-06` Viewer interaction effects | The effect library, queue, and the consumer that applies them during a live match |
| `-07` Battleground bot combat analysis | Code reading and measurement of what the bots actually do in a battleground |
| `-08` Spectator camera & streaming feasibility | POI and camera commands, the spectator director loop, and the streaming assessment |
| `-09` Release tag & 1000-bot stand-up | `scripts/standup-1000.sh`, the raised compiled bot-count fallbacks, `scripts/release-tag.sh`, and this document |

Operator entry points: `docs/playerbots/TOURNAMENT-CONTROL-PLANE.md` for the
console commands and shell client, `docs/playerbots/TOURNAMENT-ROSTERS.md` for
teams and rosters, `docs/DOCKER.md` for building, validating and rolling back.

## Defaults changed in this release

| Setting | Compiled fallback before | After |
|---|---|---|
| `AiPlayerbot.MinRandomBots` | 50 | **1000** |
| `AiPlayerbot.MaxRandomBots` | 200 | **1000** |
| `AiPlayerbot.RandomBotAccountCount` | 50 | **500** |

These are the values in `src/modules/PlayerBots/playerbot/PlayerbotAIConfig.cpp`,
used only when the key is **absent** from the conf. They now agree with
`src/modules/PlayerBots/playerbot/aiplayerbot.conf.dist.in`, which has shipped
1000 / 1000 / 500 all along — so a server whose conf omitted those keys
previously ran at a fifth of the population the project's own template asks for,
silently. Nothing changes for a server that sets the keys explicitly, which
includes this one.

---

## 1. Capacity at 1000 bots

> **UNFILLED — one automated number and one human check.** The memory figure is
> produced by a script; the playability figure cannot be, and that is the whole
> reason this section exists. `docs/playerbots/BOT-MEMORY-INVESTIGATION.md`
> states in bold that **"client still playable" is UNVERIFIED at every bot
> count**, because every ramp so far ran unattended. Do not fill this in from the
> memory numbers alone — RSS says nothing about frame rate.
>
> That investigation document is **not on this branch**: it lives on the shelved
> `memory/baseline-measurement` branch, which at the time of writing exists only
> in one working copy and not on `origin` (`origin/memory/baseline-investigation`
> is a different branch and does not carry it). The figures quoted below are
> reproduced here so this record stands on its own if that branch is ever lost.

**Memory (automated).** Run:

```bash
./scripts/standup-1000.sh --target 1000 --out logs/standup/first
```

Paste its final `STANDUP` line here verbatim:

```
STANDUP target= online= rss= vmAvailable= hostFree= plateau= verdict= reason=
```

Reference for comparison: **4.2682 GiB at 1017 bots online**, plateaued
(2026-08-15, image `tortoise-cm:6bace7a`, provenance-verified). Materially above
that at 1000 bots is a regression introduced somewhere in plans 00-08, not a new
baseline.

**Playability (human check).** With the stand-up reporting `verdict=PASS` and the
bots still online, connect a real client to the realm and record what you see:

| Check | What to record | Observed |
|---|---|---|
| Character select loads | time in seconds | |
| Enter world | time in seconds | |
| Frame rate in a capital city (Stormwind or Orgrimmar) | approximate fps | |
| Frame rate in an empty zone | approximate fps | |
| Movement responsiveness | any rubber-banding? | |
| `.gm on` then `.appear <bot name>` | does it complete, and how fast? | |
| Chat latency | say something, time the echo | |
| Spell latency | cast something, subjective delay | |

Date of check: _(unfilled)_
Verdict: _(unfilled — one of: playable / degraded but usable / not playable)_

**If the client is not playable at 1000, do not tag a release whose headline
claim is a population nobody can join.** Bisect with
`./scripts/standup-1000.sh --target N` for the highest playable count and record
*that* as the supported population. The compiled fallback may stay at 1000 while
the documented supported figure is lower — as long as this document says which is
which, and why.

## 2. Bot population during a tournament

> **UNFILLED BY DECISION, not by omission.** This section records a decision
> rather than a measurement, and it records what would have to be measured if the
> decision were ever reversed. The comparison below is deliberately **not** run.

**Tournaments run with the random bot pool at zero.** The only characters online
during a match are the 20 bots playing it plus a GM spectator. Set that up with:

```bash
MSYS_NO_PATHCONV=1 bash docs/playerbots/wsg/wsg-mode.sh on     # shrink the pool
# ... run the tournament ...
MSYS_NO_PATHCONV=1 bash docs/playerbots/wsg/wsg-mode.sh off    # restore the world
```

**Why.** The concern is CPU contention, not memory. Bot AI is single-core, and
1000 bots thinking share that core with the 20 that are actually being watched.
Memory is comfortable at that count — 4.27 GiB RSS at 1017 bots, against a VM
with 17.62 GiB still available — so RSS was never the reason to shrink the pool.
This is the same reasoning that already shrinks the pool to 40 for a WSG match
(`docs/playerbots/WSG-BOT-MATCH.md` §2.2).

**What is therefore not measured.** Nothing has ever run a tournament match
against a full 1000-bot world, and this release does not do so, because the
operating configuration does not call for one. The plan's original Task 6 asked
whether a match is watchable with 1000 bots also thinking; that question is
closed by decision instead of by measurement.

**If a populated backdrop is ever wanted for the stream** — an alive-looking
world behind the arena — this comparison is the first thing to run, and this
table is the thing to fill in:

```bash
# control: the tournament profile
MSYS_NO_PATHCONV=1 bash docs/playerbots/wsg/wsg-mode.sh on
./scripts/tournament/match-run.sh stormwind-sentinels orgrimmar-warsong \
  --run-dir logs/tournament/cap-baseline

# treatment: the same match, full world
MSYS_NO_PATHCONV=1 bash docs/playerbots/wsg/wsg-mode.sh off
./scripts/standup-1000.sh --target 1000 --out logs/standup/withmatch
./scripts/tournament/match-run.sh stormwind-sentinels orgrimmar-warsong \
  --run-dir logs/tournament/cap-full

# and while the second one runs:
docker stats --no-stream tcm-mangosd
```

| Question | Where to read it | Pool 40 | Pool 1000 |
|---|---|---|---|
| Did all 20 bots still enter? | `REPORT ... entered=` | | |
| Did more bots go stuck? | `REPORT ... stuck=` | | |
| Did bots move less? | `MOVEMENT ... distance=` per bot | | |
| Was mangosd CPU-saturated? | `docker stats` during the match | | |
| Did the match reach a result? | `MATCH ... winner=` | | |

Recommendation if it is ever run: _(unfilled)_

## 3. Verified at tag time

> **UNFILLED — fill this in when the tag is actually cut, from the output of the
> commands that cut it.** Every row is a command that either passed or did not;
> none of them is a judgement call. `release-tag.sh` will not create the tag at
> all unless the first row passes, so a filled-in table with a failing first row
> means someone tagged by hand.

| Check | Command | Result |
|---|---|---|
| Tree clean, running image built from HEAD | `./scripts/verify-running-commit.sh` | _(unfilled — expect `VERDICT: MATCH`)_ |
| Stack stands up correctly | `./scripts/validate-stack.sh --image tortoise-cm:local --keep-up` | _(unfilled — expect `VALIDATE-STACK: PASS`)_ |
| 1000-bot capacity | `./scripts/standup-1000.sh --target 1000` | _(unfilled — the `STANDUP` line from §1)_ |
| Client playable at 1000 | human check | _(unfilled — the verdict from §1)_ |
| Tournament population | decision, see §2 | pool at zero; no full-world comparison run |
| A match runs end to end | `./scripts/tournament/match-run.sh <alliance> <horde>` | _(unfilled — the `MATCH` line)_ |

Tag name: _(unfilled)_
Commit: _(unfilled — full sha)_
Image tag: _(unfilled — `tortoise-cm:<tag>`)_
Date cut: _(unfilled)_

---

## Rolling back to this release

Every build is tagged with its commit, and `release-tag.sh` adds an image tag
matching the release name so this works from the name rather than from a
remembered sha:

```bash
docker images --filter reference=tortoise-cm

sed -i 's|^TW_IMAGE=.*|TW_IMAGE=tortoise-cm:tournament-v1|' .env
docker compose --env-file .env up -d
```

Retagging `:local` is **not** enough. If `.env` names a different tag, compose
resolves that one, sees no change, prints "Running", and relaunches the very
image you are rolling back from. Set `TW_IMAGE` back to `tortoise-cm:local` once
you have rebuilt a good image.

If `release-tag.sh` printed its "no image on this host" warning, the git tag
exists without a matching image. Rebuild that commit and complete the pair:

```bash
git checkout tournament-v1
./scripts/rebuild.sh
docker tag tortoise-cm:$(git rev-parse --short HEAD) tortoise-cm:tournament-v1
```

**Never `docker compose down -v` from `~/tortoise-wow-server-V2`, and never
`docker volume prune` or `docker system prune --volumes`.**
`tortoise-wow-v2_dbdata` is the entire world, and with the stack down Docker
reports it 100% reclaimable. See `docs/DOCKER.md`, "Things that will cost you an
afternoon".
