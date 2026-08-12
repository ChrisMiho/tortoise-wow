# Building and running the server in Docker

Everything below runs **inside WSL Ubuntu**. Docker Desktop's engine is shared,
but relative bind-mount paths only resolve correctly from the WSL side.

    cd /mnt/d/CodingProjects/tortoise-wow/tortoise-wow

## First-time setup

```bash
cp .env.example .env
# paste the password from /home/deck/tortoise-wow-server-V2/.dbpass into DB_PASS
```

`.env` holds the database password in plaintext. It is excluded from commits via
`.git/info/exclude` in this checkout — but that is **local only**. The matching
`.gitignore` line exists in the working tree and is **not yet committed**, so a
fresh clone of this repo does not inherit the protection. Commit it when the
concurrent `fork-migration` work in `.gitignore` has landed.

`.env` also points `TW_DATA`, `TW_ETC` and `TW_LOGS` at the existing stack
directory. That is deliberate: the extracted client data is several gigabytes and
the configs are tuned, so both are reused rather than duplicated.

`DB_PASS` reaches the database container as an environment variable, so anyone
who can run `docker inspect tw2-db` can read the root password in plaintext.
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

Roughly 40 minutes. `scripts/rebuild.sh` builds to `tortoise-v2:candidate`, runs
its acceptance checks, and moves the `:local` tag ONLY if every one passes — so a
broken build cannot take the running server down with it.

```bash
./scripts/rebuild.sh
BUILD_JOBS=1 ./scripts/rebuild.sh    # if the Docker VM OOMs mid-compile
```

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
docker exec -i -e MYSQL_PWD="$P" tw2-db mysql -uroot -N -e \
  "SELECT CONCAT(name,'  port=',port,'  realmflags=',realmflags) FROM tw_logon.realmlist;
   SELECT CONCAT('characters online: ',COUNT(*)) FROM tw_char.characters WHERE online=1;" \
  2>/dev/null
```

`port=8095  realmflags=0` and a rising online count mean the realm is reachable.
`realmflags=2` means offline; `port` disagreeing with `WorldServerPort` in
`mangosd.conf` makes the client hang after login, before character select.

## Rollback

Every build is tagged with its commit, so the previous server is still on disk:

```bash
docker images --filter reference=tortoise-v2

# Point TW_IMAGE at the anchor explicitly. Retagging :local is NOT enough — if
# .env has TW_IMAGE=tortoise-v2:candidate (which .env.example invites for testing
# a fresh build), compose resolves :candidate, sees no change, prints "Running",
# and relaunches the very image you are rolling back from.
sed -i 's|^TW_IMAGE=.*|TW_IMAGE=tortoise-v2:c06b2fb|' .env
docker compose up -d
```

Set `TW_IMAGE` back to `tortoise-v2:local` once you have rebuilt a good image.

## Things that will cost you an afternoon

| | |
|---|---|
| **`docker compose down -v`** | Destroys `tortoise-wow-v2_dbdata` — every character and all progression. The volume is declared `external` so compose cannot recreate it silently, but `-v` still removes it. Never run it. |
| Line endings | This checkout must stay LF (`git config core.autocrlf false`). A CRLF tree compiles, but produces different bytes than the tree the proven image came from. |
| `BUILD_PLAYERBOTS` | Defaults `OFF`. A build without it yields a bot-free server with no warning. Check: `docker run --rm tortoise-v2:local ls /opt/turtle/etc \| grep aiplayerbot`. |
| **A rebuild that produces no binary** | `scripts/rebuild.sh` checks that `mangosd`/`realmd` exist before checking that they link — `ldd` on a missing file writes to stderr, so a naive `ldd \| grep 'not found'` reports a missing binary as healthy. Do not "simplify" the `test -x` check or the `2>&1` out of that loop. |
| `CMAKE_INSTALL_PREFIX` | Compiled in. It must stay `/opt/turtle` or the server logs one line about `aiplayerbot.conf` and runs with no bots. |
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
