# Build Provenance & Stack Validation Gate — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make it impossible for any later tournament work to be validated against
a server that was not built from this repository's committed source.

**Architecture:** A reusable shell test harness, a single `validate-stack.sh` entry
point that brings a named image up and refuses to report success unless provenance,
image identity, and real liveness all check out, and a repair to
`.claude/workflows/backlog-batch.js` so drain-built images actually carry the
provenance labels `verify-running-commit.sh` reads.

**Tech Stack:** Bash (WSL Ubuntu), Docker Compose, MySQL client via `docker exec`,
Node (the workflow script is plain JS).

**Spec:** `docs/superpowers/specs/2026-08-16-bot-tournament-design.md` (§5)

## Global Constraints

- Run every script from **WSL**, never Git Bash. `scripts/rebuild.sh` fails closed
  on `MSYSTEM` because MSYS path rewriting produced five false FAILs on a good
  image once already.
- **Never** `docker compose down -v`. `tortoise-wow-v2_dbdata` is the entire world.
- Compose project name is pinned to `tortoise-cm`; the image namespace is
  `tortoise-cm:<tag>`.
- `.env` is gitignored and exists **only in the main checkout** — no worktree gets
  a copy. Any compose invocation from a worktree must pass
  `--env-file <main-checkout>/.env`.
- `TW_IMAGE` must always be passed explicitly. `docker-compose.yml` defaults it to
  `tortoise-cm:local`; omitting it silently starts a stale image.
- Provenance label keys are fixed: `org.opencontainers.image.revision`,
  `com.turtle.source-dirty`, `com.turtle.dockerfile-sha256`.
- `rebuild.sh` stamps the revision with `git rev-parse --short HEAD` and the
  Dockerfile hash truncated to 12 chars — comparisons must normalise, never
  string-compare raw.
- Exit codes are the contract: `0` MATCH, `1` DRIFT or FOREIGN, `2` UNKNOWN.

---

## File Structure

| File | Responsibility |
|---|---|
| `tests/lib/assert.sh` (create) | Assertion helpers + pass/fail tally for every shell test in this project |
| `tests/lib/stub.sh` (create) | Build a throwaway `PATH` directory of stub executables (`docker`, `nc`) |
| `tests/validate-stack.test.sh` (create) | Tests for `scripts/validate-stack.sh` against stubs |
| `scripts/validate-stack.sh` (create) | Bring a named image up, prove provenance + identity + liveness, report, optionally take it down |
| `scripts/lib/provenance.sh` (modify) | Add `prov_image_id_for_tag` and `prov_realm_ok` helpers |
| `.claude/workflows/backlog-batch.js` (modify) | Port forward two stranded fixes; pass provenance build args; call `validate-stack.sh` in the Validate phase |

> **Branch note.** This work was cut from `origin/cm-main` (`b886a3b`), not from the
> local `cm-main` ref, which is 26 commits behind and does not contain
> `scripts/lib/provenance.sh`, `scripts/verify-running-commit.sh`, or the WSG
> scripts at all. If you are working from a checkout whose `cm-main` looks empty of
> those, `git fetch origin` first and branch from `origin/cm-main`.

---

### Task 1: Shell test harness

**Files:**
- Create: `tests/lib/assert.sh`
- Create: `tests/lib/stub.sh`
- Test: `tests/lib/assert.selftest.sh`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `assert_eq <expected> <actual> <label>`
  - `assert_contains <haystack> <needle> <label>`
  - `assert_exit <expected-code> <label> -- <command...>`
  - `assert_summary` — prints the tally, exits 0 if all passed, 1 otherwise
  - `stub_dir` — creates a temp dir, echoes its path, prepends it to `PATH`
  - `stub_cmd <dir> <name> <body>` — writes an executable stub
  - `stub_cleanup <dir>`

- [ ] **Step 1: Write the failing self-test**

```bash
# tests/lib/assert.selftest.sh
#!/usr/bin/env bash
# Self-test for the assertion helpers. If this fails, no other test can be trusted.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/assert.sh"
. "$HERE/stub.sh"

assert_eq "abc" "abc" "assert_eq matches"
assert_contains "hello world" "lo wo" "assert_contains finds a substring"
assert_exit 3 "assert_exit reads an exit code" -- bash -c 'exit 3'

d="$(stub_dir)"
stub_cmd "$d" faketool 'echo STUBBED; exit 0'
assert_eq "STUBBED" "$(faketool)" "stub_cmd shadows PATH"
assert_exit 0 "stub survives a second call" -- faketool
stub_cleanup "$d"

assert_summary
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/lib/assert.selftest.sh`
Expected: FAIL — `tests/lib/assert.sh: No such file or directory`

- [ ] **Step 3: Write the helpers**

```bash
# tests/lib/assert.sh
# Assertion helpers for this repo's shell tests. Source, don't execute.
#
# Deliberately does NOT set -e: a failing assertion must record itself and let
# the rest of the file run, so one run reports every failure rather than the
# first one. Callers that want fail-fast can check $ASSERT_FAILED themselves.

ASSERT_PASSED=0
ASSERT_FAILED=0

_assert_ok()   { ASSERT_PASSED=$((ASSERT_PASSED + 1)); printf '  ok   %s\n' "$1"; }
_assert_bad()  { ASSERT_FAILED=$((ASSERT_FAILED + 1)); printf '  FAIL %s\n' "$1"; }

assert_eq() { # <expected> <actual> <label>
  if [ "$1" = "$2" ]; then
    _assert_ok "$3"
  else
    _assert_bad "$3"
    printf '       expected: %s\n       actual:   %s\n' "$1" "$2"
  fi
}

assert_contains() { # <haystack> <needle> <label>
  case "$1" in
    *"$2"*) _assert_ok "$3" ;;
    *)      _assert_bad "$3"
            printf '       looking for: %s\n       in:          %s\n' "$2" "$1" ;;
  esac
}

# Usage: assert_exit 2 "label" -- some command --with args
# Runs the command with errexit disabled so a non-zero code is data, not death.
assert_exit() { # <expected-code> <label> -- <command...>
  local expected="$1" label="$2"; shift 2
  [ "${1:-}" = "--" ] && shift
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  assert_eq "$expected" "$rc" "$label"
}

assert_summary() {
  printf '\n%d passed, %d failed\n' "$ASSERT_PASSED" "$ASSERT_FAILED"
  [ "$ASSERT_FAILED" -eq 0 ]
}
```

```bash
# tests/lib/stub.sh
# Throwaway PATH stubs, so a test can exercise a script that shells out to
# docker/mysql/nc without a running stack. Source, don't execute.
#
# stub_dir prepends to PATH in the CALLER's shell, which is why this is sourced
# rather than run.

stub_dir() {
  local d
  d="$(mktemp -d)"
  PATH="$d:$PATH"
  export PATH
  printf '%s\n' "$d"
}

# Writes an executable stub. The body is a bash script fragment; "$@" inside it
# receives the stub's own arguments, so a stub can branch on how it was called.
stub_cmd() { # <dir> <name> <body>
  local dir="$1" name="$2" body="$3"
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s\n' "$body"
  } > "$dir/$name"
  chmod +x "$dir/$name"
}

stub_cleanup() { # <dir>
  [ -n "${1:-}" ] && [ -d "$1" ] && rm -rf "$1"
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bash tests/lib/assert.selftest.sh`
Expected: `5 passed, 0 failed`, exit 0

- [ ] **Step 5: Commit**

```bash
git add tests/lib/assert.sh tests/lib/stub.sh tests/lib/assert.selftest.sh
git commit -m "test: add shell assertion and PATH-stub helpers"
```

---

### Task 2: Provenance helpers for tag identity and realm health

**Files:**
- Modify: `scripts/lib/provenance.sh`
- Test: `tests/provenance.test.sh` (create)

**Interfaces:**
- Consumes: existing `prov_*` helpers in `scripts/lib/provenance.sh`.
- Produces:
  - `prov_image_id_for_tag <tag>` → the image ID a tag currently resolves to, or empty
  - `prov_realm_ok` → exit 0 when `tw_logon.realmlist` reads `port=$TW_WORLD_PORT` and `realmflags=0`
  - `prov_online_count` → number of `tw_char.characters` rows with `online=1`

- [ ] **Step 1: Write the failing test**

```bash
# tests/provenance.test.sh
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/lib/stub.sh"

d="$(stub_dir)"

# `docker image inspect -f {{.Id}} <tag>` is the only call prov_image_id_for_tag
# should make. Anything else means it grew a dependency the tests don't cover.
stub_cmd "$d" docker '
if [ "$1" = "image" ] && [ "$2" = "inspect" ]; then
  case "$*" in
    *tortoise-cm:present*) echo "sha256:aaaa"; exit 0 ;;
    *)                     echo "Error: No such image" >&2; exit 1 ;;
  esac
fi
exit 1'

. "$HERE/../scripts/lib/provenance.sh"

assert_eq "sha256:aaaa" "$(prov_image_id_for_tag tortoise-cm:present)" \
  "prov_image_id_for_tag resolves an existing tag"
assert_eq "" "$(prov_image_id_for_tag tortoise-cm:absent)" \
  "prov_image_id_for_tag is empty for a missing tag"

stub_cleanup "$d"
assert_summary
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/provenance.test.sh`
Expected: FAIL — `prov_image_id_for_tag: command not found`

- [ ] **Step 3: Add the helpers**

Append to `scripts/lib/provenance.sh`:

```bash
# The image ID a tag resolves to right now. Empty when the tag does not exist.
# Tags are mutable: comparing the tag a container was started with against the
# tag you just built proves nothing, comparing IDs does.
prov_image_id_for_tag() { # <tag>
    local v
    v=$(docker image inspect --format '{{.Id}}' "$1" 2>/dev/null) || return 0
    printf '%s\n' "$v"
}

# A bound port only proves docker-proxy answered. The realm row is what the
# client actually reads: realmflags=2 means offline, and a port disagreeing with
# WorldServerPort makes the client hang after login, before character select.
prov_realm_ok() {
    local pass row
    pass=$(tr -d '\r\n' < "$TW_LIVE_ROOT/.dbpass" 2>/dev/null) || return 1
    [ -n "$pass" ] || return 1
    row=$(docker exec -e MYSQL_PWD="$pass" "$TW_DB" mysql -uroot -N -B -e \
            "SELECT CONCAT(port,':',realmflags) FROM tw_logon.realmlist LIMIT 1;" \
            2>/dev/null | tr -d '\r')
    [ "$row" = "${TW_WORLD_PORT}:0" ]
}

prov_online_count() {
    local pass
    pass=$(tr -d '\r\n' < "$TW_LIVE_ROOT/.dbpass" 2>/dev/null) || { echo 0; return 0; }
    docker exec -e MYSQL_PWD="$pass" "$TW_DB" mysql -uroot -N -B -e \
        "SELECT COUNT(*) FROM tw_char.characters WHERE online=1;" 2>/dev/null \
        | tr -d '\r' | head -1
}
```

And add the container name alongside the other overridable defaults, next to
`TW_MANGOSD`:

```bash
TW_DB="${TW_DB:-tcm-db}"
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bash tests/provenance.test.sh`
Expected: `2 passed, 0 failed`, exit 0

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/provenance.sh tests/provenance.test.sh
git commit -m "feat(provenance): add tag-identity and realm-health helpers"
```

---

### Task 3: `validate-stack.sh`

**Files:**
- Create: `scripts/validate-stack.sh`
- Test: `tests/validate-stack.test.sh` (create)

**Interfaces:**
- Consumes: `prov_head_sha`, `prov_resolve_rev`, `prov_image_label`,
  `prov_running_image_id`, `prov_image_id_for_tag`, `prov_world_ready`,
  `prov_realm_ok`, `prov_online_count`.
- Produces: `scripts/validate-stack.sh --image <tag> [--env-file <path>] [--keep-up]`
  - exit `0` = every gate passed
  - exit `1` = a gate failed (provenance, identity, or liveness)
  - exit `2` = could not run the checks at all (docker down, no `.env`)
  - stdout ends with exactly one line beginning `VALIDATE-STACK: ` followed by
    `PASS` or `FAIL <reason>` — this line is what an automated caller parses.

- [ ] **Step 1: Write the failing test**

```bash
# tests/validate-stack.test.sh
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/validate-stack.sh"
. "$HERE/lib/assert.sh"
. "$HERE/lib/stub.sh"

run_with_stub() { # <docker-body>  -> prints combined output, sets RC
  local d body="$1"; shift
  d="$(stub_dir)"
  stub_cmd "$d" docker "$body"
  stub_cmd "$d" nc 'exit 0'
  local envfile="$d/.env"; printf 'DB_PASS=x\n' > "$envfile"
  OUT="$(TW_LIVE_ROOT="$d" bash "$SCRIPT" --image tortoise-cm:test --env-file "$envfile" 2>&1)"
  RC=$?
  stub_cleanup "$d"
}

# A missing docker daemon is UNKNOWN (2), never a silent pass.
run_with_stub 'if [ "$1" = "info" ]; then exit 1; fi; exit 0'
assert_eq "2" "$RC" "docker down exits 2"
assert_contains "$OUT" "VALIDATE-STACK: FAIL" "docker down reports FAIL"

# An image with no provenance labels is UNKNOWN, not a pass.
run_with_stub '
case "$1 $2" in
  "info "*)            exit 0 ;;
  "image inspect")     case "$*" in *Id*) echo "sha256:same";; *) echo "";; esac; exit 0 ;;
  "compose "*)         exit 0 ;;
  "inspect "*)         echo "sha256:same"; exit 0 ;;
esac
exit 0'
assert_eq "2" "$RC" "unlabelled image exits 2"
assert_contains "$OUT" "no provenance labels" "unlabelled image says why"

assert_summary
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/validate-stack.test.sh`
Expected: FAIL — `scripts/validate-stack.sh: No such file or directory`, and both
`assert_eq` lines report the wrong code.

- [ ] **Step 3: Write the script**

```bash
#!/usr/bin/env bash
# Bring a named image up and refuse to call it good unless all three gates pass:
#
#   1. PROVENANCE — the image is stamped with a revision that resolves in THIS
#      repository, and that revision is HEAD.
#   2. IDENTITY   — the container is running the image ID the tag resolves to,
#      not whatever :local happened to point at. Tags are mutable.
#   3. LIVENESS   — the world port answers, the realm row is reachable and not
#      flagged offline, and bots are actually online.
#
# The last line of stdout is always "VALIDATE-STACK: PASS" or
# "VALIDATE-STACK: FAIL <reason>". Automated callers parse that line and nothing
# else.
#
# Exit codes:  0 all gates passed | 1 a gate failed | 2 could not check
#
# Run from WSL:  ./scripts/validate-stack.sh --image tortoise-cm:local
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/provenance.sh
. "$HERE/lib/provenance.sh"

IMAGE=""; ENV_FILE="$HERE/../.env"; KEEP_UP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --image)    IMAGE="$2"; shift 2 ;;
    --env-file) ENV_FILE="$2"; shift 2 ;;
    --keep-up)  KEEP_UP=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

verdict() { printf 'VALIDATE-STACK: %s\n' "$1"; }
die_unknown() { verdict "FAIL $1"; exit 2; }
die_failed()  { verdict "FAIL $1"; exit 1; }

[ -n "$IMAGE" ] || die_unknown "no --image given"
[ -z "${MSYSTEM:-}" ] || die_unknown "run this from WSL, not Git Bash (MSYSTEM=$MSYSTEM)"
command -v docker >/dev/null 2>&1 || die_unknown "docker is not on PATH"
docker info >/dev/null 2>&1 || die_unknown "docker is not responding"
[ -f "$ENV_FILE" ] || die_unknown "no .env at $ENV_FILE (it is gitignored and lives only in the main checkout)"

echo "image:    $IMAGE"
echo "env-file: $ENV_FILE"

# Gate 1 runs BEFORE the stack comes up. Standing up an image we already know is
# foreign wastes a full boot and, worse, leaves a wrong server running.
WANT_ID="$(prov_image_id_for_tag "$IMAGE")"
[ -n "$WANT_ID" ] || die_unknown "image $IMAGE does not exist locally"

IMG_REV="$(prov_image_label "$IMAGE" "$PROV_LABEL_REV")"
if [ -z "$IMG_REV" ]; then
  die_unknown "image $IMAGE carries no provenance labels — it was not built by scripts/rebuild.sh or an equivalent that passes --build-arg GIT_SHA"
fi

HEAD_SHA="$(prov_head_sha)"
IMG_REV_FULL="$(prov_resolve_rev "$IMG_REV" || true)"
if [ -z "$IMG_REV_FULL" ]; then
  die_failed "FOREIGN — revision $IMG_REV is not a commit in this repository; the image was built from a different checkout sharing this image namespace"
fi
if [ "$IMG_REV_FULL" != "$HEAD_SHA" ]; then
  die_failed "DRIFT — image was built from $IMG_REV ($IMG_REV_FULL) but HEAD is $HEAD_SHA"
fi
echo "gate 1:   provenance OK ($IMG_REV == HEAD)"

IMG_DIRTY="$(prov_image_label "$IMAGE" "$PROV_LABEL_DIRTY")"
if [ -n "$IMG_DIRTY" ] && [ "$IMG_DIRTY" != "0" ]; then
  echo "WARNING:  built from a dirty tree ($IMG_DIRTY uncommitted file(s)); the revision label does not fully describe this binary"
fi

# NEVER -v. That volume is the entire world.
echo "==> starting stack"
TW_IMAGE="$IMAGE" docker compose --env-file "$ENV_FILE" up -d \
  || die_unknown "docker compose up failed"

cleanup() {
  if [ "$KEEP_UP" -eq 0 ]; then
    echo "==> stopping stack"
    docker compose --env-file "$ENV_FILE" down >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

RUN_ID="$(prov_running_image_id "$TW_MANGOSD")"
if [ "$RUN_ID" != "$WANT_ID" ]; then
  die_failed "IDENTITY — $TW_MANGOSD is running image $RUN_ID but $IMAGE resolves to $WANT_ID"
fi
echo "gate 2:   identity OK ($RUN_ID)"

# Boot takes about a minute. Poll rather than sleep-and-hope; a fixed sleep is
# either too short on a cold cache or wasted time on a warm one.
echo "==> waiting for the world port"
deadline=$(( $(date +%s) + 300 ))
until prov_world_ready; do
  [ "$(date +%s)" -lt "$deadline" ] || die_failed "LIVENESS — world port $TW_WORLD_PORT never opened within 300s"
  sleep 5
done

prov_realm_ok || die_failed "LIVENESS — realmlist is not ${TW_WORLD_PORT}:0 (realmflags=2 means offline; a mismatched port hangs the client after login)"
echo "gate 3a:  realm OK (port=$TW_WORLD_PORT realmflags=0)"

# Bots trickle in after the world is up, so this gets its own window.
echo "==> waiting for bots to log in"
deadline=$(( $(date +%s) + 300 ))
online=0
while :; do
  online="$(prov_online_count)"
  [ "${online:-0}" -gt 0 ] && break
  [ "$(date +%s)" -lt "$deadline" ] || die_failed "LIVENESS — no characters came online within 300s of the world port opening"
  sleep 10
done
echo "gate 3b:  liveness OK ($online character(s) online)"

verdict "PASS"
exit 0
```

- [ ] **Step 4: Run it to verify it passes**

Run: `bash tests/validate-stack.test.sh`
Expected: `4 passed, 0 failed`, exit 0

- [ ] **Step 5: Run it for real against the live stack**

Run: `./scripts/validate-stack.sh --image tortoise-cm:local --keep-up`
Expected: either `VALIDATE-STACK: PASS`, or a `FAIL` naming which gate and why.
Both outcomes are informative — record the actual output in the commit message if
it fails, because a `FAIL` here is a real finding about the current stack, not a
bug in the script.

- [ ] **Step 6: Commit**

```bash
git add scripts/validate-stack.sh tests/validate-stack.test.sh
git commit -m "feat: add validate-stack.sh provenance/identity/liveness gate"
```

---

### Task 4: Port forward two stranded `backlog-batch.js` fixes

**Files:**
- Modify: `.claude/workflows/backlog-batch.js:155` (the `imageTag` assignment)
- Modify: `.claude/workflows/backlog-batch.js:203-215` (the Validate phase compose instruction)

**Interfaces:**
- Consumes: nothing.
- Produces: a `backlog-batch.js` that builds into the `tortoise-cm` namespace and
  can actually start a stack from a worktree — both preconditions for Tasks 5-6.

Two unrelated-to-memory fixes were made to this file on the `memory/*` branch,
which has been shelved. They are prerequisites for everything below, so they are
re-applied here rather than resurrected by cherry-pick.

- [ ] **Step 1: Fix the image namespace**

`tortoise-wow:` is a third image namespace belonging to nothing. `TW_IMAGE`
defaults to `tortoise-cm` (`scripts/lib/provenance.sh:19`) and
`docker-compose.yml` resolves `tortoise-cm:local`, so a batch image built into
`tortoise-wow:` can never be compared against, rolled back to, or recognised by
`scripts/verify-running-commit.sh`.

Replace:

```js
const imageTag = `tortoise-wow:${buildId}`
```

with:

```js
// tortoise-cm, matching docker-compose.yml's TW_IMAGE default and the rest of
// this repo's images. It was `tortoise-wow:` -- a third namespace belonging to
// nothing, which meant a batch build could never be compared against, rolled
// back to, or recognised by scripts/verify-running-commit.sh.
const imageTag = `tortoise-cm:${buildId}`
```

- [ ] **Step 2: Fix the worktree `.env` failure**

`docker-compose.yml` opens with `${DB_PASS:?set DB_PASS in .env}`. `.env` is
gitignored, so it exists only in the main checkout and **no worktree ever receives
a copy** — a bare `docker compose up -d` from the batch worktree dies immediately
on the missing variable and never starts anything.

In the `validated` agent prompt, replace this paragraph:

```
   If Docker is ready: bring the stack up with the ${imageTag} image by
   running "TW_IMAGE=${imageTag} docker compose up -d" -- docker-compose.yml
   resolves the server image via the TW_IMAGE env var (default
   tortoise-cm:local), so a bare "docker compose up" silently reuses whatever
   was built previously instead of this batch's image. (Compose project name
   is pinned to tortoise-cm; tortoise-wow-v2_dbdata is an external
   volume -- never use "docker compose down -v", that volume is the entire
   world.) This is a single-developer, no-live-players development server --
   you are not simulating a player, just confirming the server comes up
   correctly.
```

with:

```
   If Docker is ready: bring the stack up with the ${imageTag} image.

   CRITICAL -- you are in a git worktree, and .env IS NOT THERE. It is
   gitignored, so it exists only in the main checkout and no worktree ever
   receives a copy. docker-compose.yml opens with
   "\${DB_PASS:?set DB_PASS in .env}" and resolves TW_ETC / TW_DATA / TW_LOGS
   the same way, so a bare "docker compose up -d" from this worktree dies
   immediately on the missing variable and never starts anything. Point it at
   the main checkout's .env explicitly:

     TW_IMAGE=${imageTag} docker compose --env-file <main-checkout>/.env up -d

   where <main-checkout> is the repository root of the ORIGINAL session
   directory, not this worktree. Resolve it with
   "git -C <worktree> worktree list" -- the FIRST entry is the main checkout.
   Verify the file exists before running compose; if it does not, return
   dockerReady: false with that as the reason rather than guessing at values.

   TW_IMAGE must be set explicitly: docker-compose.yml defaults it to
   tortoise-cm:local, so omitting it silently reuses whatever was built
   previously instead of this batch's image. (Compose project name is pinned
   to tortoise-cm; tortoise-wow-v2_dbdata is an external volume -- never use
   "docker compose down -v", that volume is the entire world.) This is a
   single-developer, no-live-players development server -- you are not
   simulating a player, just confirming the server comes up correctly.
```

Note the `\${DB_PASS...}` escape — this text sits inside a JS template literal, so
an unescaped `${` would be interpolated and throw a `ReferenceError` at parse time.

- [ ] **Step 3: Fix the teardown to carry the same `--env-file`**

`docker compose down` from the worktree fails for exactly the same reason as `up`.
Replace:

```
   stack back down (plain "docker compose down", never with -v) before you
```

with:

```
   stack back down (plain "docker compose down" with the SAME --env-file, never
   with -v) before you
```

- [ ] **Step 4: Verify the file still parses**

The workflow script is plain JS and a broken template literal fails at load, not
at run — which would surface as a confusing systemic drain failure hours later.

Run: `node --check .claude/workflows/backlog-batch.js`
Expected: no output, exit 0.

Then confirm the three edits landed:

Run: `grep -n "tortoise-cm:\${buildId}\|--env-file\|SAME --env-file" .claude/workflows/backlog-batch.js`
Expected: the `imageTag` line, at least two `--env-file` mentions in the Validate
prompt, and the teardown line.

- [ ] **Step 5: Commit**

```bash
git add .claude/workflows/backlog-batch.js
git commit -m "fix(backlog-batch): build into tortoise-cm and pass --env-file from worktrees"
```

---

### Task 5: Make drain-built images carry provenance labels

**Files:**
- Modify: `.claude/workflows/backlog-batch.js` (the `Build` phase agent prompt)

**Interfaces:**
- Consumes: `scripts/rebuild.sh`'s build-arg contract — `GIT_SHA`, `GIT_DIRTY`,
  `DOCKERFILE_SHA`, `BUILD_JOBS`.
- Produces: batch images tagged `tortoise-cm:<buildId>` that carry
  `org.opencontainers.image.revision`, `com.turtle.source-dirty`, and
  `com.turtle.dockerfile-sha256`, so `validate-stack.sh` can reach a verdict
  other than `UNKNOWN`.

- [ ] **Step 1: Confirm the gap is real before fixing it**

Run:

```bash
docker images --filter reference=tortoise-cm --format '{{.Repository}}:{{.Tag}}'
```

Then, for any tag a previous batch produced:

```bash
docker image inspect <tag> --format '{{index .Config.Labels "org.opencontainers.image.revision"}}'
```

Expected: `<no value>` or empty for batch-built tags, and a short SHA for tags
`scripts/rebuild.sh` produced. That difference is the bug.

If no batch-built image exists on this host yet, the gap is still real — confirm
it in the source instead:

```bash
grep -c "build-arg GIT_SHA" .claude/workflows/backlog-batch.js
```

Expected: `0`. Record which way you confirmed it.

- [ ] **Step 2: Rewrite the Build phase prompt**

In `.claude/workflows/backlog-batch.js`, replace the build instruction paragraph
inside the `built` agent call so it reads:

```js
const built = await agent(
  `On branch "${integrated.integrationBranch}" (in its own worktree), build the
   Docker image per docs/superpowers/plans/2026-08-11-docker-build-from-this-checkout.md:
   "docker build" from the repo root of that worktree. The Dockerfile already
   bakes in -DBUILD_PLAYERBOTS=ON -DCMAKE_INSTALL_PREFIX=/opt/turtle and a
   BUILD_JOBS default of 10 (the Docker VM is now 16 CPUs/24GB, see
   docs/DOCKER.md) -- do not pass --build-arg BUILD_JOBS unless the build
   OOMs, in which case retry with --build-arg BUILD_JOBS=4.

   You MUST pass the three provenance build args, exactly as scripts/rebuild.sh
   does. Without them the image carries no provenance labels, and
   scripts/validate-stack.sh can only ever return UNKNOWN against it -- meaning
   nobody can prove the server that gets validated was built from this repo:

     GIT_SHA        = git -C <worktree> rev-parse --short HEAD
     GIT_DIRTY      = git -C <worktree> status --porcelain --untracked-files=no | wc -l
     DOCKERFILE_SHA = sha256sum <worktree>/Dockerfile | cut -c1-12

   So the command is:

     docker build -t ${imageTag} \\
       --build-arg GIT_SHA=<sha> \\
       --build-arg GIT_DIRTY=<count> \\
       --build-arg DOCKERFILE_SHA=<dfsha> \\
       <worktree>

   An empty GIT_SHA stamps the image "unknown" -- check it is non-empty BEFORE
   starting a ~10 minute compile, and fail immediately if it is empty.

   Run "docker build" itself from Windows PowerShell directly against that
   worktree's path -- the build context is just the repo directory and needs
   no WSL path semantics. Do NOT use a wrapped "wsl -d Ubuntu -- bash -lc
   '...'" one-liner containing any variable -- that has previously returned
   plausible-but-wrong output silently rather than failing. If a WSL step is
   unavoidable for any part of this, write it to a script file first and
   invoke that file from PowerShell, never an inline wrapped one-liner.

   Report whether it built successfully. If it failed, report the actual
   compiler/linker error, not just "build failed" -- this feeds a bisection
   decision, not just a status flag.`,
  { phase: 'Build', label: 'build', schema: BUILD_SCHEMA }
)
```

- [ ] **Step 3: Verify the label lands, on a real build**

Run a build by hand exactly as the prompt now specifies, tagging it
`tortoise-cm:provtest`, then:

```bash
docker image inspect tortoise-cm:provtest \
  --format '{{index .Config.Labels "org.opencontainers.image.revision"}} {{index .Config.Labels "com.turtle.dockerfile-sha256"}}'
```

Expected: a short SHA and a 12-char hash, neither empty.

Then prove the gate now reaches a real verdict:

```bash
./scripts/validate-stack.sh --image tortoise-cm:provtest
```

Expected: `VALIDATE-STACK: PASS` if that build is at HEAD, or an explicit
`DRIFT`/`IDENTITY`/`LIVENESS` reason. **Not** `UNKNOWN`. Reaching a definite
verdict is the point of this task.

- [ ] **Step 4: Clean up the probe image**

```bash
docker rmi tortoise-cm:provtest
```

- [ ] **Step 5: Commit**

```bash
git add .claude/workflows/backlog-batch.js
git commit -m "fix(backlog-batch): stamp provenance build args so batch images are verifiable"
```

---

### Task 6: Wire `validate-stack.sh` into the batch Validate phase

**Files:**
- Modify: `.claude/workflows/backlog-batch.js` (the `validated` agent prompt)

**Interfaces:**
- Consumes: `scripts/validate-stack.sh --image <tag> --env-file <main-checkout>/.env`
  and its `VALIDATE-STACK:` line.
- Produces: a Validate phase that cannot report success on an unverified image.

- [ ] **Step 1: Replace the ad-hoc compose instructions**

In the `validated` agent prompt, replace the block that begins
`If Docker is ready: bring the stack up with the ${imageTag} image.` and ends at
`Confirm the baseline liveness smoke test...` with:

```js
  `If Docker is ready: do NOT hand-roll the compose invocation. Run the repo's
   gate script, which brings the stack up and refuses to report success unless
   provenance, image identity, and real liveness all pass:

     <main-checkout>/scripts/validate-stack.sh --image ${imageTag} \\
       --env-file <main-checkout>/.env --keep-up

   where <main-checkout> is the repository root of the ORIGINAL session
   directory, not this worktree -- .env is gitignored and exists only there.
   Resolve it with "git -C <worktree> worktree list": the FIRST entry is the
   main checkout. The script must be run from WSL, not Git Bash.

   Its last stdout line is "VALIDATE-STACK: PASS" or
   "VALIDATE-STACK: FAIL <reason>". Report that line verbatim in liveness.
   If it is FAIL, set dockerReady false and do not attempt any per-artifact
   check -- an unverified server cannot confirm anything, and a check that
   "passed" against a foreign or drifted image is worse than no check at all.`
```

- [ ] **Step 2: Replace the teardown instruction**

The gate script is invoked with `--keep-up` so per-artifact checks can run against
the live stack. Replace the closing teardown paragraph with:

```js
  `Whether or not the build/validation was clean, finish by bringing the stack
   back down before you return, so it is never left running unattended:

     docker compose --env-file <main-checkout>/.env down

   Plain "down". NEVER "down -v" -- tortoise-wow-v2_dbdata is the entire world.
   This must happen even if something above failed or looked wrong.`
```

- [ ] **Step 3: Verify by reading, not by running**

A full batch run costs a ~10 minute build plus a stack cycle, and this task
changed only prompt text. Confirm by inspection:

```bash
grep -n "validate-stack.sh\|VALIDATE-STACK\|down -v" .claude/workflows/backlog-batch.js
```

Expected: `validate-stack.sh` referenced in the Validate prompt, `VALIDATE-STACK`
named as the line to report, and the only `down -v` occurrence is the warning
telling the agent never to use it.

- [ ] **Step 4: Commit**

```bash
git add .claude/workflows/backlog-batch.js
git commit -m "feat(backlog-batch): validate through validate-stack.sh instead of ad-hoc compose"
```

---

### Task 7: Document the gate

**Files:**
- Modify: `docs/DOCKER.md` (after the "Verify it actually works" section)

- [ ] **Step 1: Add the section**

```markdown
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
```

- [ ] **Step 2: Commit**

```bash
git add docs/DOCKER.md
git commit -m "docs: document the validate-stack.sh provenance gate"
```

---

### Task 8: Keep the new directories out of the build context

**Files:**
- Modify: `.dockerignore`

**Interfaces:**
- Consumes: nothing.
- Produces: a build context that does not include `config/`, `tests/`, or `logs/`.

The tournament plans create three new root directories. None affects the compiled
binary, and none is currently excluded — so editing a team JSON or a test script
would invalidate the `COPY . /src` layer and cost a full ~10 minute recompile. This
task must land **before** Plan 01, which creates the first of them.

`logs/` is the urgent one: `logs/tournament/` accumulates telemetry CSVs and
captured `bots-match.log` files, so leaving it in the context means uploading a
growing pile of match artifacts on every single build.

- [ ] **Step 1: Confirm none of the three is excluded yet**

```bash
grep -nE "^(config|tests|logs)/?$" .dockerignore; echo "exit=$?"
```

Expected: no output and `exit=1` — nothing matched, which is the gap.

- [ ] **Step 2: Add them**

In `.dockerignore`, in the block that already begins
`# Churny paths that have no business in the build context:`, add:

```
config/
tests/
logs/
```

The existing comment in that block already states the rationale — "anything here
that changes still forces a full recompile of the `COPY . /src` layer even though
none of it affects the compiled binary" — and these three are exactly that.
`config/tournament/` is read by shell scripts at runtime, `tests/` never enters the
image, and `logs/` is runtime output.

- [ ] **Step 3: Prove the context actually shrank**

Create something in each directory, then measure what the build context sends:

```bash
mkdir -p config/tournament/teams tests/tournament logs/tournament
head -c 5000000 /dev/zero > logs/tournament/fake-bots.log
docker build -t tortoise-cm:ctxtest --progress=plain . 2>&1 | grep -i "transferring context" | tail -2
```

Expected: the transferred context size does **not** include the 5 MB file. Compare
against the same command with `logs/` temporarily removed from `.dockerignore` if
you want the before/after directly.

Clean up:

```bash
rm -rf logs/tournament/fake-bots.log
docker rmi tortoise-cm:ctxtest 2>/dev/null || true
```

- [ ] **Step 4: Commit**

```bash
git add .dockerignore
git commit -m "build: keep config/, tests/ and logs/ out of the build context

None affects the compiled binary, but all three would invalidate the
COPY . /src layer and force a full ~10 minute recompile on every edit."
```

---

### Task 9 (optional): ccache, for the ~12 rebuilds these plans require

**Files:**
- Modify: `Dockerfile` (build stage)
- Modify: `docs/DOCKER.md`

**Interfaces:**
- Produces: a build stage that reuses compiled objects across builds via a BuildKit
  cache mount, so a one-file C++ change does not recompile the whole tree.

**This task is a genuine speedup, not a cleanup — but it is optional, and it must
be measured rather than assumed.** Skip it if the plan sequence is already
underway; do not retrofit it mid-run, because it changes `DOCKERFILE_SHA` and every
image built before it will then report the "Dockerfile changed" warning from
`verify-running-commit.sh`.

The case for it: the tournament plans invoke `./scripts/rebuild.sh` **12 times**
(6 in Plan 02, 1 each in Plans 03/05/06, 2 in Plan 08), before any retries. At
~9.5 minutes each that is ~1h54m of compiling, and almost all of it is recompiling
translation units that did not change — because `COPY . /src` invalidates the build
layer on any source edit, and there is currently no object reuse of any kind.

- [ ] **Step 1: Confirm BuildKit is active**

Cache mounts are a BuildKit feature. It is the default in Docker 23+, but confirm
rather than assume:

```bash
docker version --format '{{.Server.Version}}'
DOCKER_BUILDKIT=1 docker build --help | grep -c "mount"
```

If BuildKit is not available, **stop** — the rest of this task does not apply, and
the fallback (a persistent named volume for ccache) does not work with
`docker build` at all.

- [ ] **Step 2: Add ccache to the build stage**

In `Dockerfile`, add `ccache` to the builder's `apt-get install` list:

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential cmake git ccache \
      libace-dev libboost-all-dev \
      default-libmysqlclient-dev libssl-dev zlib1g-dev libbz2-dev \
 && rm -rf /var/lib/apt/lists/*
```

and replace the configure/build `RUN` with a cache-mounted version:

```dockerfile
# ccache on a BuildKit cache mount. COPY . /src invalidates this layer on ANY
# source edit, so without object reuse every rebuild recompiles the entire tree
# -- ~9.5 minutes to apply a one-line change. The cache mount survives layer
# invalidation, so unchanged translation units become cache hits.
#
# The cache lives in the BuildKit builder, NOT in the image: it adds nothing to
# the shipped layers and never reaches the runtime stage.
ENV CCACHE_DIR=/ccache
RUN --mount=type=cache,target=/ccache \
    cmake -B /build -S /src \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/opt/turtle \
      -DBUILD_PLAYERBOTS=ON \
      -DUSE_EXTRACTORS=ON \
      -DALLOW_TURTLE_ADDONS=ON \
      -DCMAKE_C_COMPILER_LAUNCHER=ccache \
      -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
 && ccache --zero-stats \
 && cmake --build /build -j"${BUILD_JOBS}" \
 && cmake --install /build \
 && ccache --show-stats
```

`ccache --show-stats` at the end is not decoration: it is how the next step gets
its measurement, and it is printed in the build log where a reviewing agent can
read it.

- [ ] **Step 3: Measure it — three builds, not one**

A single build proves nothing; the first build populates the cache and will be
*slower* than the current baseline, not faster.

```bash
# 1. cold — populates the cache. Expect roughly baseline, or a little worse.
time ./scripts/rebuild.sh

# 2. no-op — same source. Should be near-total cache hits.
time ./scripts/rebuild.sh

# 3. one-file change — the case that actually matters.
touch src/game/Commands/Commands.cpp
time ./scripts/rebuild.sh
```

Record all three wall times and the `cache hit rate` line from each build's
`ccache --show-stats` output.

**Decide from the third number.** If a one-file change still takes close to the
~9.5 minute baseline, ccache is not helping here — revert the Dockerfile change
rather than keeping a complication that buys nothing. Report the measured numbers
either way; "it should be faster" is not a result.

- [ ] **Step 4: If kept, document it**

Add to `docs/DOCKER.md`, in the "Rebuild after a C++ change" section:

```markdown
Builds use ccache on a BuildKit cache mount, so a rebuild that changes one file
recompiles only what depends on it. Measured on this host: cold <X>, no-op <Y>,
one-file change <Z>. The cache lives in the BuildKit builder, not in the image.

Clear it if you ever suspect a stale object:

    docker builder prune --filter type=exec.cachemount
```

Fill in the real measured numbers from Step 3 — do not ship the placeholders.

- [ ] **Step 5: Expect one Dockerfile-drift warning, once**

`scripts/rebuild.sh` stamps `com.turtle.dockerfile-sha256`, and
`verify-running-commit.sh` warns when a running image's stamp differs from the
current file. Changing the Dockerfile means the **currently running** server now
trips that warning until it is rebuilt. That is correct behaviour, not a
regression — note it in the commit message so the next person does not chase it.

- [ ] **Step 6: Commit**

```bash
git add Dockerfile docs/DOCKER.md
git commit -m "build: ccache on a BuildKit cache mount

Cold <X>, no-op <Y>, one-file change <Z> (was ~9m20s for every build
regardless of what changed). The running server will report a Dockerfile
drift warning until it is next rebuilt; that is expected."
```

---

## Done when

- `bash tests/lib/assert.selftest.sh`, `bash tests/provenance.test.sh`, and
  `bash tests/validate-stack.test.sh` all exit 0.
- `.dockerignore` excludes `config/`, `tests/` and `logs/`, verified by a build
  whose transferred context does not include a file planted under `logs/`.
- `./scripts/validate-stack.sh --image tortoise-cm:local` reaches a **definite**
  verdict — `PASS`, or a `FAIL` naming a specific gate. Never `UNKNOWN`.
- A hand-run build following the new Build-phase instructions produces an image
  whose `org.opencontainers.image.revision` label is a real short SHA.
- `node --check .claude/workflows/backlog-batch.js` exits 0, and the file builds
  into `tortoise-cm:` and passes `--env-file` on both `up` and `down`.
- `docs/DOCKER.md` documents the gate.
