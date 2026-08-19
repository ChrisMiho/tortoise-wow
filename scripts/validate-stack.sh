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

# Pin --env-file to the ORIGINAL working directory before the cd below moves
# us; a relative path would otherwise silently resolve somewhere else.
case "$ENV_FILE" in
  /*) ;;
  *)  ENV_FILE="$PWD/$ENV_FILE" ;;
esac
[ -f "$ENV_FILE" ] || die_unknown "no .env at $ENV_FILE (it is gitignored and lives only in the main checkout)"

# docker-compose.yml lives at the repo root. Without this the script only works
# when $PWD happens to contain it, and exits 2 (UNKNOWN) everywhere else --
# which is the exact state this gate exists to eliminate.
cd "$HERE/.." || die_unknown "cannot cd to the repo root at $HERE/.."

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

# Boot takes about a minute warm. Poll rather than sleep-and-hope; a fixed sleep
# is either too short on a cold cache or wasted time on a warm one.
#
# This window is deliberately much larger than the bot window below. prov_world_
# ready now waits for mangosd to really listen rather than for docker-proxy to
# bind the host port, so the whole cold-boot world load lands here instead of
# silently leaking into the bot window and failing THAT gate. Measured warm on
# 2026-08-18: mangosd listening at 57s, world port answering at 67s. The first
# boot straight off a freshly built 2.3 GiB image reads its layers and map data
# from disk and took over 300s, which is what this budget is sized for.
WORLD_WINDOW="${TW_WORLD_WINDOW:-900}"
echo "==> waiting for the world port (up to ${WORLD_WINDOW}s)"
deadline=$(( $(date +%s) + WORLD_WINDOW ))
until prov_world_ready; do
  [ "$(date +%s)" -lt "$deadline" ] || die_failed "LIVENESS — world port $TW_WORLD_PORT never opened within ${WORLD_WINDOW}s"
  sleep 5
done

prov_realm_ok || die_failed "LIVENESS — realmlist is not ${TW_WORLD_PORT}:0 (realmflags=2 means offline; a mismatched port hangs the client after login)"
echo "gate 3a:  realm OK (port=$TW_WORLD_PORT realmflags=0)"

# Bots trickle in after the world is up, so this gets its own window. It starts
# from a real world-ready, so 300s is generous: measured 2026-08-18, 717
# characters were already online at the first poll after the port opened.
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
