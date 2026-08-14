#!/usr/bin/env bash
# Is the running server built from the committed source?
#
# Read-only, runs in seconds. Exit code is the contract:
#   0  MATCH    the running image was built from HEAD
#   1  DRIFT    it was built from something else in this repo — OR FOREIGN,
#               built from a revision that isn't a commit in this repo at
#               all (a different checkout sharing this image namespace).
#               Both verdicts exit 1; the exit code alone cannot tell them
#               apart — read the printed VERDICT line.
#   2  UNKNOWN  nothing is running, or the image has no provenance labels
#
# This in-repo copy is authoritative. A D:\TurtleWow\scripts\ copy of this
# file predates the FOREIGN verdict and the 2026-08-14 SHA/dirty/Dockerfile
# repairs (see docs/backlog/011-bot-memory-baseline-and-investigation.md);
# do not run that one.
#
# Run from WSL:  /mnt/c/Coding/tortoise-wow/tortoise-wow/scripts/verify-running-commit.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/provenance.sh
. "$HERE/lib/provenance.sh"

[[ -d "$TW_SRC_DIR/.git" ]] || { echo "FATAL: no git repo at $TW_SRC_DIR" >&2; exit 2; }

HEAD_SHA=$(prov_head_sha)
DF_SHA=$(prov_dockerfile_sha)

echo "source:      $TW_SRC_DIR"
echo "branch:      $(prov_branch)"
echo "HEAD:        $HEAD_SHA"
if prov_is_dirty; then
    echo "tree:        DIRTY (uncommitted or untracked changes)"
else
    echo "tree:        clean"
fi
echo

if ! prov_container_exists "$TW_MANGOSD"; then
    echo "container:   $TW_MANGOSD does not exist"
    echo
    echo "VERDICT: UNKNOWN — nothing is running to compare against."
    exit 2
fi

# `docker inspect` succeeds on Exited containers too, and every compose
# service here is restart:"no", so a crashed mangosd is left Exited rather
# than removed. Existence is not liveness — this script answers "is the
# *running* server built from HEAD", and there is no running server to ask.
mangosd_running() { [[ "$(docker inspect -f '{{.State.Running}}' "$TW_MANGOSD" 2>/dev/null)" == "true" ]]; }
if ! mangosd_running; then
    echo "container:   $TW_MANGOSD exists but is NOT running (exited)"
    echo
    echo "VERDICT: UNKNOWN — the container is there but the server is down."
    exit 2
fi

IMAGE_ID=$(prov_running_image_id "$TW_MANGOSD")
IMG_REV=$(prov_image_label "$IMAGE_ID" "$PROV_LABEL_REV")
IMG_DIRTY=$(prov_image_label "$IMAGE_ID" "$PROV_LABEL_DIRTY")
IMG_DF=$(prov_image_label "$IMAGE_ID" "$PROV_LABEL_DOCKERFILE")

echo "container:   $TW_MANGOSD"
echo "image:       $IMAGE_ID"

if [[ -z "$IMG_REV" ]]; then
    echo "revision:    (none)"
    echo
    echo "VERDICT: UNKNOWN — this image carries no provenance labels, so it was"
    echo "         built before SHA stamping existed. That is not drift. Ship once"
    echo "         with ship-cpp-fix.sh and the answer becomes definite."
    exit 2
fi

echo "revision:    $IMG_REV"
echo "built dirty: ${IMG_DIRTY:-unknown}"

rc=0

# Resolve the stamped revision inside this repo before comparing. This both
# normalises short-vs-full SHAs (rebuild.sh stamps --short, HEAD_SHA is full,
# so a raw string compare always differs) and catches an image built by a
# different checkout publishing into the same image namespace.
IMG_REV_FULL=$(prov_resolve_rev "$IMG_REV" || true)

if [[ -z "$IMG_REV_FULL" ]]; then
    echo
    echo "VERDICT: FOREIGN — the running server is stamped with revision"
    echo "           $IMG_REV"
    echo "         which is not a commit in this repository. It was built from a"
    echo "         different checkout that shares this image namespace."
    echo
    echo "  Nothing about this image describes code in this tree. Do not measure"
    echo "  against it, and do not treat a passing smoke test as evidence here."
    echo "  Build from this checkout:  scripts/rebuild.sh"
    exit 1
fi

if [[ "$IMG_REV_FULL" != "$HEAD_SHA" ]]; then
    echo
    echo "VERDICT: DRIFT — the running server was built from"
    echo "           $IMG_REV ($IMG_REV_FULL)"
    echo "         but HEAD is"
    echo "           $HEAD_SHA"
    echo
    echo "  Ship HEAD:  scripts/ship-cpp-fix.sh"
    echo "  Roll back:  docker tag $TW_IMAGE:${IMG_REV:0:7} $TW_IMAGE:local && docker compose up -d"
    rc=1
fi

if [[ -n "$IMG_DF" && "$IMG_DF" != "$DF_SHA" ]]; then
    echo
    echo "WARNING: the Dockerfile changed since this image was built."
    echo "         image: $IMG_DF"
    echo "         now:   $DF_SHA"
    echo "         The same commit can still produce a different binary."
    rc=1
fi

# rebuild.sh stamps this from `git status --porcelain | wc -l`, i.e. a COUNT
# ("0", "3"), never the string "true" this once tested for — so the warning
# never fired on a genuinely dirty build. Anything that is neither empty nor
# zero means uncommitted changes went into the image. Note rebuild.sh counts
# with --untracked-files=no while prov_is_dirty() above counts untracked files
# too: the local check is deliberately stricter than the stamp, because an
# untracked .cpp is still in the build context.
if [[ -n "$IMG_DIRTY" && "$IMG_DIRTY" != "0" && "$IMG_DIRTY" != "unknown" ]]; then
    echo
    echo "WARNING: this image was built from a dirty tree ($IMG_DIRTY uncommitted"
    echo "         file(s)), so its revision label does not fully describe the binary."
fi

if (( rc == 0 )); then
    echo
    echo "VERDICT: MATCH — the running server is built from HEAD."
fi
exit $rc
