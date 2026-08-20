#!/usr/bin/env bash
# Gates in release-tag.sh, exercised against a throwaway repo and a stubbed
# verify-running-commit.sh.
#
# NEVER points the script at this checkout: a passing gate 3 creates a REAL
# annotated release tag, which is exactly the state the script refuses to move.
# TW_SRC_DIR is a fresh repo under mktemp for every case, so the probe tags go
# away with it, and each case asserts on `git tag -l` there directly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/release-tag.sh"
. "$HERE/lib/assert.sh"
. "$HERE/lib/stub.sh"

require_cmd git

# A clean one-commit repo, so gate 1 (dirty tree) and gate 2 (name taken) pass
# and whatever we are testing is what refuses.
make_repo() { # -> prints path
  local r; r="$(mktemp -d)"
  git -C "$r" init -q
  git -C "$r" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  printf '%s\n' "$r"
}

# <verify-exit-code> <tag-name> -> sets OUT, RC, REPO
run_release() {
  local verify_rc="$1" tag="$2"; shift 2
  local d; d="$(stub_dir)"
  REPO="$(make_repo)"
  stub_cmd "$d" verify-stub "echo 'VERDICT: DRIFT'; exit $verify_rc"
  # docker is stubbed out so the image-tag step never touches this host.
  stub_cmd "$d" docker 'exit 1'
  OUT="$(TW_SRC_DIR="$REPO" TW_IMAGE="tortoise-cm:20260818-4" \
         GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
         GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
         TW_VERIFY="$d/verify-stub" bash "$SCRIPT" "$tag" 2>&1)"
  RC=$?
  stub_cleanup "$d"
}

cleanup_repo() { rm -rf "$REPO"; }

# --- defect 1: the gate-3 remediation command must be runnable -------------
# TW_IMAGE carries a tag (as .env's really does), so printing it raw yields
# tortoise-cm:20260818-4:<short> -- not a valid image reference.
run_release 1 tournament-v1
assert_eq "1" "$RC" "gate 3 refuses when the running server is not HEAD"
SHORT="$(git -C "$REPO" rev-parse --short HEAD)"
assert_contains "$OUT" "--image tortoise-cm:$SHORT --keep-up" \
  "gate 3 prints the stripped IMAGE_REPO"
case "$OUT" in
  *"tortoise-cm:20260818-4:"*) _assert_bad "gate 3 does not print a double-tagged ref" ;;
  *)                           _assert_ok  "gate 3 does not print a double-tagged ref" ;;
esac
assert_eq "" "$(git -C "$REPO" tag -l)" "gate 3 refusal leaves no tag behind"
cleanup_repo

# --- defect 2: a git-legal, docker-illegal name is refused up front --------
# 'release/v1' passes git check-ref-format, so before the fix the annotated tag
# was created and only `docker tag` failed -- a git tag with no image.
run_release 0 'release/v1'
assert_eq "2" "$RC" "'release/v1' is refused as a bad name"
assert_contains "$OUT" "not a valid docker tag" "the refusal says which namespace rejects it"
assert_eq "" "$(git -C "$REPO" tag -l)" "'release/v1' leaves no tag behind"
cleanup_repo

# The old leading-character rule still holds, now as part of the same check.
run_release 0 '-v1'
assert_eq "2" "$RC" "a leading '-' is still refused"
assert_eq "" "$(git -C "$REPO" tag -l)" "'-v1' leaves no tag behind"
cleanup_repo

run_release 0 '.v1'
assert_eq "2" "$RC" "a leading '.' is still refused"
assert_eq "" "$(git -C "$REPO" tag -l)" "'.v1' leaves no tag behind"
cleanup_repo

# A legal name in both namespaces still gets through every gate and tags.
run_release 0 tournament-v1
assert_eq "0" "$RC" "a name legal in both namespaces is tagged"
assert_eq "tournament-v1" "$(git -C "$REPO" tag -l)" "the annotated tag exists in the probe repo"
cleanup_repo

assert_summary
