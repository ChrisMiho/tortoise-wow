# CLAUDE.md

## Communication style

Be concise. Short, direct sentences, one idea each. Cut preamble, hedging, and
restatement of the question — lead with the answer.

## Explaining technical topics

Cover both layers, in-game first, then the mechanism behind it:

- **In-game** — what a player, GM, or bot actually sees or does in the world.
- **Technical** — the code, packet, DB table, or config that produces it.

Name the concrete thing on each side: the spell, quest, or bot behaviour on the
in-game side; the file, function, table, or `mangosd.conf` setting on the technical
side. Don't explain one layer and leave the other implied.

Example: "Bots stop casting mid-fight after ~20 minutes (in-game) because the
playerbot AI's spell cooldown map is keyed on a 32-bit tick that wraps, so every
cooldown reads as still-pending (technical)."

## Environment invariants

Short version of things that have each cost a session here. Fuller detail in
`docs/DOCKER.md` and `.claude/skills/backlog-drain/SKILL.md`.

**The game world is a Docker volume, `tortoise-wow-v2_dbdata`.** It has been lost
once. `docker compose down -v` **from this repo cannot destroy it** — the volume
is declared `external: true` and compose never removes an external volume. What
does destroy it: `docker volume prune`, `docker system prune --volumes`, Docker
Desktop's cleanup (with the stack down Docker calls the volume **100%
reclaimable**), and `docker compose down -v` run from `~/tortoise-wow-server-V2`,
where the same volume is compose-*managed*. `docker image prune -a` is a separate
loss — it takes `tortoise-cm:c06b2fb`, the rollback anchor.

**`node` is Windows-only; `jq` is WSL-only.** Neither exists in the other shell.
`scripts/check-*.js` must run from Git Bash; anything in `scripts/tournament/`
must run from WSL. The blanket rule "run scripts from WSL" is wrong for the
former and gives `node: command not found`.

**Docker builds run in the foreground and take ~8.5 minutes.** Use
`timeout: 600000` — that is the Bash tool's maximum and it silently clamps
anything larger, so `900000` buys nothing. The build fits with ~90s to spare at
`BUILD_JOBS=14` (8m15s measured 2026-08-17; it was 10m11s at `-j10` and got
killed at 10m00s with **exit 143** every time). Verify with `docker images`, not
the exit code. If you ever see exit 143 at 10m00s again, the build has crept
back over the ceiling — report it. Backgrounded or `nohup`'d builds are silently
cancelled by BuildKit — no image, no error. Full recompilation every build is
expected; `COPY . /src` never cache-hits.

**Calling WSL from Git Bash:** prefix with `MSYS_NO_PATHCONV=1`, and never put a
`$VAR` inside a wrapped `wsl -d Ubuntu -- bash -lc '...'` one-liner — the Windows
layer blanks it silently and returns plausible, wrong output. Write a script file.

**`wsg_mysql` discards stderr**, so a failed query is indistinguishable from "no
rows matched". Re-run through a bare `docker exec ... mysql` before concluding
anything from an empty result.

**`tw_world.item_template` is snake_case** on this server (`inventory_type`,
`item_level`, `required_level`). The CamelCase names in older plans fail with
`Unknown column`.

**Branches that must never be deleted:** any `backlog/*` on origin (the backlog
drain resolves dependencies against them and treats a missing branch as "not
ready", producing a false deadlock) and any `integration/*` (that ref is the only
thing keeping a built image's stamped commit reachable).
