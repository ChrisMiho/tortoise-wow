#!/usr/bin/env bash
# Cut a release tag for a build that has been VERIFIED, not merely built.
#
#   ./scripts/release-tag.sh tournament-v1            # create locally
#   ./scripts/release-tag.sh tournament-v1 --push     # create and publish
#
# A tag on an unverified image is worse than no tag: it looks authoritative and
# is not. This repo already has provenance tooling (scripts/verify-running-commit.sh)
# because a commit that does not describe the running binary is the failure mode
# here -- a tag naming such a commit bakes that mismatch in permanently. So this
# refuses, creating nothing, when:
#
#   * the working tree is dirty (untracked files included -- an untracked .cpp is
#     in the build context and changes the binary while `git diff` stays silent);
#   * the tag already exists -- a release tag is never moved;
#   * the running server is not built from HEAD (verify-running-commit.sh != 0).
#
# On success it creates an annotated git tag and, when the image is on this host,
# an image tag ${TW_IMAGE}:<tag> so the rollback path in docs/DOCKER.md works by
# name instead of by remembering a SHA. A missing image is a WARNING, not a
# failure: the git tag is the release record and stands on its own.
#
# Exit codes:  0 tag created | 1 a gate refused | 2 bad usage / cannot check
#
# Run from WSL:  ./scripts/release-tag.sh tournament-v1
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/provenance.sh
. "$HERE/lib/provenance.sh"

RELEASE_DOC="docs/playerbots/TOURNAMENT-RELEASE.md"

usage() {
    cat >&2 <<'USAGE'
usage: release-tag.sh <tag-name> [--push]

  <tag-name>   the release name, e.g. tournament-v1
  --push       publish the tag to origin. Opt-in; without it the script prints
               the exact command to run.
USAGE
}

TAG=""; PUSH=0
while [ $# -gt 0 ]; do
    case "$1" in
        --push)      PUSH=1; shift ;;
        -h|--help)   usage; exit 2 ;;
        -*)          echo "unknown arg: $1" >&2; usage; exit 2 ;;
        *)
            [ -z "$TAG" ] || { echo "FATAL: more than one tag name given ('$TAG', '$1')" >&2; exit 2; }
            TAG="$1"; shift ;;
    esac
done
[ -n "$TAG" ] || { usage; exit 2; }

# Catch a malformed name here rather than letting `git tag` fail halfway through
# a release. Docker refuses a tag starting with '.' or '-' even where git allows
# it, and a git tag with no matching image tag is a half-cut release.
git check-ref-format "refs/tags/$TAG" || {
    echo "FATAL: '$TAG' is not a valid git tag name." >&2; exit 2; }
case "$TAG" in
    .*|-*) echo "FATAL: '$TAG' cannot be a docker tag (it starts with '.' or '-')." >&2; exit 2 ;;
esac

# A worktree's .git is a FILE holding a gitdir: pointer, not a directory, so test
# for both or this refuses to run anywhere but the main checkout.
[ -d "$TW_SRC_DIR/.git" ] || [ -f "$TW_SRC_DIR/.git" ] || {
    echo "FATAL: no git repo at $TW_SRC_DIR" >&2; exit 2; }

# --- gate 1: the tree ------------------------------------------------------
# Cheap gates first, deliberately: refusing a name that is already taken must
# not require docker to be up.
if prov_is_dirty; then
    echo "FATAL: working tree is dirty. Commit or stash before tagging." >&2
    prov_git status --short --untracked-files=all >&2
    exit 1
fi

SHA="$(prov_head_sha)"    || { echo "FATAL: cannot read HEAD" >&2; exit 2; }
SHORT="$(prov_short_sha)" || { echo "FATAL: cannot read HEAD" >&2; exit 2; }
echo "tag:     $TAG"
echo "HEAD:    $SHA ($SHORT) on $(prov_branch)"
echo "tree:    clean"

# --- gate 2: the name is free ----------------------------------------------
if prov_git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "FATAL: tag '$TAG' already exists at $(prov_git rev-parse "refs/tags/$TAG^{commit}")." >&2
    echo "       Pick another name. A release tag is never moved -- whatever was" >&2
    echo "       shipped under this name stays reachable under this name." >&2
    exit 1
fi

# --- gate 3: the running server is this commit -----------------------------
echo
echo "==> verifying the running server is built from HEAD"
if ! "$HERE/verify-running-commit.sh"; then
    echo >&2
    echo "FATAL: the running server is not built from HEAD (see the verdict above)." >&2
    echo "       DRIFT means build and validate this commit first; UNKNOWN means" >&2
    echo "       nothing is running to check, and an unchecked build is exactly" >&2
    echo "       what this gate exists to keep out of a release tag." >&2
    echo "         ./scripts/rebuild.sh" >&2
    echo "         ./scripts/validate-stack.sh --image ${TW_IMAGE}:${SHORT} --keep-up" >&2
    echo "       No tag was created." >&2
    exit 1
fi

# --- create the tag --------------------------------------------------------
# .env sets TW_IMAGE to a full ref (tortoise-cm:c06b2fb) while lib/provenance.sh
# defaults it to the bare repository (tortoise-cm). Accept both: strip a trailing
# :tag, or "${IMAGE_REPO}:${SHORT}" comes out as tortoise-cm:c06b2fb:9a1b2c3,
# which is not a valid reference and would miss the image lookup every time. The
# ##*/ guard keeps a registry port (host:5000/repo) from being read as a tag.
IMAGE_REPO="$TW_IMAGE"
case "${IMAGE_REPO##*/}" in
    *:*) IMAGE_REPO="${IMAGE_REPO%:*}" ;;
esac

prov_git tag -a "$TAG" -F - <<EOF || { echo "FATAL: git tag failed; nothing was created." >&2; exit 1; }
$TAG

Bot battleground tournament, end of the 2026-08-16 plan series.

Commit: $SHA
Image:  ${IMAGE_REPO}:${SHORT}

Verified by scripts/verify-running-commit.sh at tag time: the server running
when this tag was cut was built from this commit, from a clean tree.

See $RELEASE_DOC for what this build was verified
to do, the capacity measurements behind it, and how to roll back to it.
EOF
echo
echo "==> created annotated tag $TAG at $SHORT"

# --- tag the image to match ------------------------------------------------
# Best effort by design. Docker on this host is at a deliberate fresh slate
# (docs/DOCKER.md, "Current state"), so this branch takes its warning path until
# a real build of this commit exists. A missing image does not invalidate the git
# tag, which is the release record.
if ! command -v docker >/dev/null 2>&1; then
    echo "WARNING: docker is not on PATH, so no image tag was made." >&2
    echo "         Complete the pair with: docker tag ${IMAGE_REPO}:${SHORT} ${IMAGE_REPO}:${TAG}" >&2
elif docker image inspect "${IMAGE_REPO}:${SHORT}" >/dev/null 2>&1; then
    if docker tag "${IMAGE_REPO}:${SHORT}" "${IMAGE_REPO}:${TAG}"; then
        echo "==> tagged image ${IMAGE_REPO}:${TAG}"
    else
        echo "WARNING: docker tag failed; the git tag stands but the image is untagged." >&2
    fi
else
    echo "WARNING: no image ${IMAGE_REPO}:${SHORT} on this host, so no image tag was made." >&2
    echo "         The git tag stands. Rebuild this commit and complete the pair:" >&2
    echo "           docker tag ${IMAGE_REPO}:${SHORT} ${IMAGE_REPO}:${TAG}" >&2
fi

# --- publish, only if asked ------------------------------------------------
if [ "$PUSH" -eq 1 ]; then
    prov_git push origin "refs/tags/$TAG" || {
        echo "FATAL: push failed. The tag exists locally; publish it with:" >&2
        echo "         git push origin refs/tags/$TAG" >&2
        exit 1; }
    echo "==> pushed $TAG to origin"
else
    echo
    echo "not pushed. To publish:  git push origin refs/tags/$TAG"
fi
