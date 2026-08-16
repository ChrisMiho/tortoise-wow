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
