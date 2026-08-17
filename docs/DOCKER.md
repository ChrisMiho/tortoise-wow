# Building and running the server in Docker

Everything below runs **inside WSL Ubuntu**. Docker Desktop's engine is shared,
but relative bind-mount paths only resolve correctly from the WSL side.

    cd /mnt/c/Coding/tortoise-wow/tortoise-wow

## First-time setup

```bash
cp .env.example .env
# paste the password from /home/deck/tortoise-wow-server-V2/.dbpass into DB_PASS
```

`.env` holds the database password in plaintext. It is excluded two ways: by
`.gitignore:27`, which is committed and so inherited by a fresh clone, and by
`.git/info/exclude` in this checkout, which is local only. Both are deliberate —
the local rule predates the committed one and is harmless to keep.

`.env` also points `TW_DATA`, `TW_ETC` and `TW_LOGS` at the existing stack
directory. That is deliberate: the extracted client data is several gigabytes and
the configs are tuned, so both are reused rather than duplicated.

`DB_PASS` reaches the database container as an environment variable, so anyone
who can run `docker inspect tcm-db` can read the root password in plaintext.
Treat docker access as equivalent to database access.

The verify command below deliberately passes the secret via `MYSQL_PWD` rather
than as a `--password` CLI flag. A secret given on a command line is visible to
`ps` inside the container and lands in shell history; `MYSQL_PWD` avoids both.

The repo's public-safety gate (`turtle-ops/scripts/audit-public-safe.sh`) blocks
that flag form outright, so reintroducing it will fail the next push — correctly.
Note the gate matches on the literal flag text, so even *writing it out* in a doc
trips it; that is why this paragraph describes the flag instead of spelling it.

## Start / stop

```bash
docker compose up -d
docker compose down          # NEVER -v — see below
```

## Rebuild after a C++ change

Roughly 9-10 minutes with the WSL2 VM at 16 CPU / 24GB
(`C:\Users\mihov\.wslconfig`) and `BUILD_JOBS=10` (the `Dockerfile` default —
see `Dockerfile:23-33`). Previously ~40 minutes at the VM's original 4 CPU /
8GB allocation with `BUILD_JOBS=2`. `scripts/rebuild.sh` builds to
`tortoise-cm:candidate`, runs its acceptance checks, and moves the `:local`
tag ONLY if every one passes — so a broken build cannot take the running
server down with it.

```bash
./scripts/rebuild.sh
BUILD_JOBS=4 ./scripts/rebuild.sh    # if the Docker VM OOMs mid-compile
```

**Run this in the foreground and wait for it.** Do not background it, `nohup` it,
or detach it — see "Things that will cost you an afternoon" below. A backgrounded
build is cancelled partway through and leaves nothing behind.

Every build recompiles the entire tree — **1169 translation units, every time,
regardless of what changed**. That is why the time is ~9.5 minutes whether you
changed one file or a hundred.

The cause, verified directly on 2026-08-16: **`COPY . /src` does not cache-hit
across separate builds.** Build the build stage twice with an unchanged context
and the second run re-executes the copy (~42s) instead of printing `CACHED`, so
every instruction after it — the compile — misses too. The `apt-get` layer
*above* the COPY does cache (`CACHED`, usage count 2), which is what makes this
easy to misread as "caching is fine".

`docker buildx du --verbose` shows it plainly: the compile step accumulates a
separate multi-GB cache record per build, every one at **`Usage count: 0`**.
They are written and never read.

A caveat that cost an hour here: a small throwaway `COPY . /ctx` probe run twice
back-to-back *does* cache, which looks like a contradiction. It is not — it just
means the miss does not reproduce within seconds on a trivial image. Test this
against the real build stage, minutes apart, or you will measure the wrong thing.

Because the miss is at the COPY, **no layer-level or compiler-level cache can
help** — everything downstream of the COPY is invalidated before it is consulted.
That is why ccache scored zero (below), and why the warm-builder approach is the
one worth trying.

**ccache does not fix this — it was measured and rejected on 2026-08-16.** Adding
`ccache` on a BuildKit cache mount (`CMAKE_CXX_COMPILER_LAUNCHER=ccache`) produced:

| Build | Wall time | TUs compiled | ccache hits |
|---|---|---|---|
| cold | 9m07s | 1169 | 0 / 177 |
| no-op (no source change at all) | 9m24s | 1169 | 0 / 177 |
| one-file change | 9m05s | 1169 | 0 / 177 |

Zero hits in every case, including a build with no source change whatsoever, and
**85% of compiler invocations reported as uncacheable** (1016 / 1193). The change
was reverted. Do not re-attempt it before working out why the compile layer never
survives between builds — until that is fixed, no compiler-level cache can help.

A more promising route is keeping the **build stage itself** warm rather than
caching individual compiler calls. The other project on this host does exactly
that: `tortoise-v2:builder` is a saved builder-stage image carrying 1,188 `.o`
files and 14 GB of objects under `/build`, so its compiled output survives
between builds instead of being rebuilt from nothing. Untested here, but it
attacks the actual problem — no reuse of compiled objects — instead of layering
a second cache on top of it.

If the VM's own resource ceiling ever needs raising again — this is what
actually controls build parallelism, not any per-container Docker setting —
edit `C:\Users\mihov\.wslconfig`, then `wsl --shutdown` from PowerShell (not
from inside WSL) to apply it, and reopen a WSL terminal to pick up the new
limits. `docker info | grep -i -E "cpus|total memory"` confirms what Docker
Desktop is actually running with.

It does not restart anything. Apply the new image when you are ready:

```bash
docker compose up -d
```

For the fuller stop → build → up → verify → push cycle, including a world-volume
fingerprint taken before the restart and compared after, see
`D:\TurtleWow\scripts\ship-cpp-fix.sh`.

## Verify it actually works

A bound port only proves `docker-proxy` answered. Check the population:

```bash
P=$(tr -d '\r\n' < /home/deck/tortoise-wow-server-V2/.dbpass)
docker exec -i -e MYSQL_PWD="$P" tcm-db mysql -uroot -N -e \
  "SELECT CONCAT(name,'  port=',port,'  realmflags=',realmflags) FROM tw_logon.realmlist;
   SELECT CONCAT('characters online: ',COUNT(*)) FROM tw_char.characters WHERE online=1;" \
  2>/dev/null
```

`port=8095  realmflags=0` and a rising online count mean the realm is reachable.
`realmflags=2` means offline; `port` disagreeing with `WorldServerPort` in
`mangosd.conf` makes the client hang after login, before character select.

## Prove the running server is this repo's code

`scripts/verify-running-commit.sh` answers "is what's running built from HEAD?"
against whatever is already up. `scripts/validate-stack.sh` is the stronger,
scriptable form: give it an image tag and it brings that image up and refuses to
report success unless three gates pass.

```bash
./scripts/validate-stack.sh --image tortoise-cm:local
./scripts/validate-stack.sh --image tortoise-cm:local --keep-up   # leave it running
```

| Gate | What it proves |
|---|---|
| provenance | the image's stamped revision resolves in this repo **and** equals HEAD — catches both DRIFT and FOREIGN |
| identity | `tcm-mangosd` is running the image ID that tag resolves to. Tags are mutable; `:local` lies the moment anything is rebuilt |
| liveness | world port open, `realmlist` reads `port=8095 realmflags=0`, and at least one character is online |

The last stdout line is always `VALIDATE-STACK: PASS` or
`VALIDATE-STACK: FAIL <reason>`. Exit codes: `0` pass, `1` a gate failed, `2` the
checks could not run (docker down, missing `.env`, unlabelled image).

An image built without `--build-arg GIT_SHA` carries no provenance labels and can
only ever return `UNKNOWN`. Both `scripts/rebuild.sh` and the `backlog-batch`
workflow pass them; anything else you build by hand must too.

## Rollback

Every build is tagged with its commit, so the previous server is still on disk:

```bash
docker images --filter reference=tortoise-cm

# Point TW_IMAGE at the anchor explicitly. Retagging :local is NOT enough — if
# .env has TW_IMAGE=tortoise-cm:candidate (which .env.example invites for testing
# a fresh build), compose resolves :candidate, sees no change, prints "Running",
# and relaunches the very image you are rolling back from.
sed -i 's|^TW_IMAGE=.*|TW_IMAGE=tortoise-cm:c06b2fb|' .env
docker compose up -d
```

Set `TW_IMAGE` back to `tortoise-cm:local` once you have rebuilt a good image.

### Current state: fresh slate as of 2026-08-16

Every image was deleted to start the tournament work clean — 30 images and one
stale build container, ~75 GB. **`tortoise-cm:c06b2fb` is the only image left**,
kept deliberately as the rollback anchor, and `.env` points `TW_IMAGE` at it
because `tortoise-cm:local` no longer exists.

Consequences worth knowing before the first build:

- The first build re-pulls `debian:trixie` and `mariadb:10.6`. Data is unaffected
  — characters live in the `tortoise-wow-v2_dbdata` volume, not in any image —
  but it needs internet and adds a few minutes.
- Build time is unchanged at ~9.5 minutes. Nothing deleted was making builds
  faster: the build cache was already empty, and `COPY . /src` never cache-hits
  regardless.
- Point `TW_IMAGE` back at `tortoise-cm:local` after the first successful
  `scripts/rebuild.sh`, which recreates that tag.

**Retire the anchor once, deliberately.** When the tournament work produces an
image that passes `./scripts/validate-stack.sh --image <tag>`, `c06b2fb` has done
its job and the last 2.3 GB can go. Until then it is the only way back to a
working server — do not delete it to save space.

## Things that will cost you an afternoon

| | |
|---|---|
| **`docker compose down -v`** | **From this repo, inert — and that is the one people get wrong.** `dbdata` is declared `external: true` here, and compose never creates *or removes* an external volume. Measured 2026-08-17 against throwaway stacks: the external volume survived `down -v`; a compose-managed control volume was destroyed by the same command. This entry previously claimed `-v` still removed it, which is false for this stack and sent the guardrails after the wrong command. Keep using plain `down` anyway — the habit is what protects you if anyone edits that `external:` line out. |
| **`docker compose down -v` from `~/tortoise-wow-server-V2`** | **This one really does destroy it.** That stack is compose project `tortoise-wow-v2` and declares the same volume as *managed*, which is where the name `tortoise-wow-v2_dbdata` comes from — and almost certainly how the world was lost the first time. The volume outlived that stack and is adopted here by reference. Don't run compose from that directory. |
| **Any "clean up unused volumes"** | Same destruction, different door: `docker volume prune`, `docker system prune --volumes`, or Docker Desktop's cleanup button. When the stack is down, Docker reports `tortoise-wow-v2_dbdata` as **100% reclaimable**, because "unused" means "no running container", not "no data". Deleting *images* is always safe; deleting volumes is never safe. Prune images with `docker image prune` (no `-a`, which would take the rollback anchor). |
| Line endings | This checkout must stay LF (`git config core.autocrlf false`). A CRLF tree compiles, but produces different bytes than the tree the proven image came from. |
| `BUILD_PLAYERBOTS` | Defaults `OFF`. A build without it yields a bot-free server with no warning. Check: `docker run --rm tortoise-cm:local ls /opt/turtle/etc \| grep aiplayerbot`. |
| **A rebuild that produces no binary** | `scripts/rebuild.sh` checks that `mangosd`/`realmd` exist before checking that they link — `ldd` on a missing file writes to stderr, so a naive `ldd \| grep 'not found'` reports a missing binary as healthy. Do not "simplify" the `test -x` check or the `2>&1` out of that loop. |
| `CMAKE_INSTALL_PREFIX` | Compiled in. It must stay `/opt/turtle` or the server logs one line about `aiplayerbot.conf` and runs with no bots. |
| **Running a build in the background** | `docker build` streams from a client the daemon watches: kill the client and BuildKit **cancels the build**. Backgrounded, detached and `nohup`'d invocations all die partway through — `nohup` does not help, because WSL tears down the session's processes when `wsl.exe` exits. Observed repeatedly here, and independently on another project on this host. **Run builds in the foreground and wait.** A build killed this way leaves no image and no error — just a truncated log that looks like it stopped for no reason. |
| Ports 3724 / 8095 | Shared with the older V1 stack. They cannot run together. |
| `Release: 1970-01-01` in the log | Expected. `.git` is excluded from the build context, so the revision falls back; the real commit is on the image's `org.opencontainers.image.revision` label. |

## Log growth

Two separate things grow, in two separate places, and neither is bounded by default.

The whole budget is **~500 MB**, split across the two. Capping only one leaves the
larger problem running.

### Half one — the logs the server writes into `TW_LOGS`

`scripts/cap-logs.sh` installs a `logrotate` rule covering **every `*.log`** in that
directory. Run it once per machine, and again after changing `TW_LOGS`:

```bash
sudo ./scripts/cap-logs.sh
./scripts/cap-logs.sh --dry-run     # show what it would write, change nothing
```

| | |
|---|---|
| Config | `/etc/logrotate.turtle.conf` (standalone — *not* in `/etc/logrotate.d/`) |
| Schedule | `/etc/cron.d/turtle-logrotate`, every 5 minutes |
| Rule | 50 MB threshold, keep 2, compressed, `copytruncate` |
| Ceiling | ~163 MB live + 2 compressed ≈ **185 MB** for `bots.log`, ~220 MB for the directory |

`bots.log` is the reason any of this exists: the bot AI's per-tick decision trace,
written at `DETAIL`, which **ignores `LogFileLevel`** — nothing in `mangosd.conf` slows
it down. Idle it is trivial (~14 KB/min); during a battleground it is **22.6 MB/min**,
and it reached **12 GB** once. Measured here: 139 MB compressed to 8.2 MB, a 17:1 ratio,
because the trace is enormously repetitive.

Three details that are load-bearing, not stylistic:

- **The 5-minute cadence matters more than the threshold.** Size-based rotation only
  rotates when logrotate *runs*, so the real ceiling is threshold + rate × interval —
  here 50 MB + ~113 MB. The distro's own timer fires once a day, which at this rate is
  ~32 GB between checks, so it is useless and this rule brings its own cron.
- **`copytruncate`, because mangosd holds the file open `O_APPEND`** (`BotLog.cpp:35`).
  Renaming would leave the server writing to an orphaned inode forever.
- **No `delaycompress`.** It is copytruncate's usual companion but wrong here — it holds
  the newest rotation uncompressed for a whole cycle, which for this file means ~163 MB
  instead of ~10 MB. It protects writers still holding the old inode; copytruncate has
  already truncated in place, so there is no such writer.

The script also removes `/etc/logrotate.turtle-bots.conf` and its cron entry if present
— an earlier, narrower rule that covered only `bots.log` at 250 MB. Two uncoordinated
rotators on one file keep independent `.1`/`.2` sequences and independent status files,
so the pair has no predictable ceiling at all.

To turn the trace off entirely instead of capping it, set `AiPlayerbot.BotLogFile = ""`
in `aiplayerbot.conf` and restart. You lose only the per-tick action trace — bot errors
still reach `errors.log`, and `bg.log`, `bot_events.csv` and `deaths.csv` are untouched.
See `docs/playerbots/BOTS-LOG-GROWTH-HANDOFF.md` for the full analysis.

### Half two — the container logs

Easy to forget, because they are not in `logs/` at all — they live inside the Docker VM,
so `du` on this repo never shows them. `mangosd` writes every SQL statement to stdout.
`docker-compose.yml` caps each service at **20 MB × 2 files**, so all three cost at most
120 MB. That takes effect on `docker compose up -d`, **not** `restart`.

## Where the source of truth is

This checkout is **not** the only tree of this repo on the machine. A second,
diverged checkout lives at `/home/deck/tortoise-wow-server-V2/src` and shares
ancestor `c06b2fb`. Before building, confirm which tree you mean to ship —
building the wrong one silently produces a server without the change you made.

### Names are this repo's; the Docker daemon is not

`docker images` is host-global. Every checkout on this machine publishes into
one image namespace, so a name is a claim, not a guarantee. On 2026-08-14 a
different tree built `tortoise-v2:baseline` and `tortoise-v2:elevator-fix` on
this host, carrying no provenance labels — which is why this repo moved off
`tortoise-v2` entirely:

| What | Was | Now |
|---|---|---|
| Image | `tortoise-v2` | `tortoise-cm` |
| Compose project | `tortoise-wow-v2` | `tortoise-cm` |
| Containers | `tw2-db`, `tw2-realmd`, `tw2-mangosd` | `tcm-db`, `tcm-realmd`, `tcm-mangosd` |
| DB volume | `tortoise-wow-v2_dbdata` | **unchanged — this is the world** |

The volume keeps its old name deliberately. It is declared `external: true` with
an explicit `name:` (`docker-compose.yml:124-126`), so it is pinned independently
of the project name and the rename cannot strand it. Never rename it, and never
`docker compose down -v`.

Renaming reduces collisions; it does not detect them. The check that does is
`scripts/verify-running-commit.sh`, which resolves the running image's
`org.opencontainers.image.revision` label **inside this repo**:

```bash
./scripts/verify-running-commit.sh
```

| Verdict | Exit | Meaning |
|---|---|---|
| `MATCH` | 0 | Running image was built from HEAD. |
| `DRIFT` | 1 | Built from another commit *of this repo*. Rebuild or roll back. |
| `FOREIGN` | 1 | Stamped with a revision this repo does not contain — built by a different checkout. Nothing about it describes your code. |
| `UNKNOWN` | 2 | Nothing running, or the image predates label stamping. |

`FOREIGN` is the one worth internalising: a foreign image can pass a liveness
smoke test perfectly while containing none of your changes. Run this before
trusting any measurement taken against a running stack.
