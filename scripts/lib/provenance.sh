#!/usr/bin/env bash
# Shared provenance helpers — what commit a tree is at, what commit an image was
# built from, and whether those two agree.
#
# Sourced by verify-running-commit.sh and scripts/bot-ramp.sh (for the CSV
# `image_rev` column); not executable alone. It is NOT sourced by
# `D:\TurtleWow\scripts\ship-cpp-fix.sh`, which this comment used to name —
# that script does not ship in this repo and pulls in its own stale copy of
# this file, one that predates the 2026-08-14 repairs below. See docs/DOCKER.md.
# Every path is an env-var override with a live default, so the tests can point
# these at stubs without touching the real server.

TW_LIVE_ROOT="${TW_LIVE_ROOT:-$HOME/tortoise-wow-server-V2}"

# THIS checkout is the build tree — scripts/lib/ is two levels below the repo
# root. It is deliberately NOT $TW_LIVE_ROOT/src: that path holds a second,
# diverged checkout sharing ancestor c06b2fb (see docs/DOCKER.md, "Where the
# source of truth is"). Pointing provenance at it would compare a running image
# against a tree nobody builds from, and every verdict would be noise.
# $TW_LIVE_ROOT is still correct for etc/, data/, logs/ and .dbpass, which the
# containers bind-mount from there.
TW_SRC_DIR="${TW_SRC_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
TW_IMAGE="${TW_IMAGE:-tortoise-cm}"
TW_MANGOSD="${TW_MANGOSD:-tcm-mangosd}"
TW_DB_VOLUME="${TW_DB_VOLUME:-tortoise-wow-v2_dbdata}"
TW_WORLD_PORT="${TW_WORLD_PORT:-8095}"

PROV_LABEL_REV="org.opencontainers.image.revision"
PROV_LABEL_DIRTY="com.turtle.source-dirty"
PROV_LABEL_DOCKERFILE="com.turtle.dockerfile-sha256"

prov_git() { git -C "$TW_SRC_DIR" "$@"; }

prov_head_sha()  { prov_git rev-parse HEAD; }
prov_short_sha() { prov_git rev-parse --short HEAD; }
prov_branch()    { prov_git rev-parse --abbrev-ref HEAD; }

# Resolve a stamped revision label to a full SHA *in this repo*, or fail.
#
# Two jobs in one call. It normalises abbreviation — rebuild.sh stamps
# `rev-parse --short HEAD`, so comparing the label to a full `rev-parse HEAD`
# string is guaranteed to differ and report DRIFT on a perfectly matched image.
# And it doubles as the identity check: a revision that does not resolve here
# was not built from this repo. Another checkout on the same host publishing
# into the same image namespace is not hypothetical — tortoise-v2:baseline and
# :elevator-fix were built on this machine by a different tree on 2026-08-14,
# carrying no provenance labels at all.
prov_resolve_rev() { # <revision-label>
    [[ -n "$1" ]] || return 1
    prov_git rev-parse --verify --quiet "$1^{commit}" 2>/dev/null
}

# An image is ours only if its stamped revision names a commit we hold. Absent
# label => not ours (or predates stamping); unresolvable => built elsewhere.
prov_rev_is_ours() { prov_resolve_rev "$1" >/dev/null; }

# Untracked files count as dirty. An untracked .cpp is in the build context and
# changes the binary while `git diff` stays silent.
prov_is_dirty() {
    [[ -n "$(prov_git status --porcelain --untracked-files=all)" ]]
}

# The Dockerfile that gets built is this repo's, so hash this repo's — reading
# $TW_LIVE_ROOT/Dockerfile hashed a file belonging to the diverged checkout (and
# on a host where that path doesn't exist, killed the script outright under
# `set -e` before it printed any verdict at all).
#
# rebuild.sh stamps com.turtle.dockerfile-sha256 with `sha256sum Dockerfile |
# cut -c1-12` from the repo root — 12 chars, not the full digest — so truncate
# to match or every comparison reports a spurious Dockerfile change.
prov_dockerfile_sha() {
    sha256sum "$TW_SRC_DIR/Dockerfile" | cut -c1-12
}

# A label off an image ref. Prints the empty string when the label is absent,
# which is how images built before provenance stamping are recognised.
prov_image_label() { # <image-ref> <label-key>
    local v
    v=$(docker image inspect "$1" --format "{{index .Config.Labels \"$2\"}}" 2>/dev/null) || return 0
    [[ "$v" == "<no value>" ]] && v=""
    printf '%s\n' "$v"
}

# The image a container actually runs, by ID — not the tag it was started with.
# :local is mutable, so the tag lies the moment anything is rebuilt.
prov_running_image_id() { # <container>
    docker inspect "$1" --format '{{.Image}}' 2>/dev/null
}

prov_container_exists() { docker inspect "$1" >/dev/null 2>&1; }
prov_volume_exists()    { docker volume inspect "$1" >/dev/null 2>&1; }

# Ready means the world port accepts a connection. This deliberately avoids
# grepping docker logs: `grep -q` closes the pipe at its first match, the
# still-writing producer dies of SIGPIPE, and under `set -o pipefail` the
# pipeline yields 141 — so an `until ... grep -q` loop never terminates.
prov_world_ready() {
    nc -z -w 3 127.0.0.1 "$TW_WORLD_PORT" >/dev/null 2>&1
}
