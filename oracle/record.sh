#!/bin/sh
# oracle/record.sh — record the SHAPE of a real dockerd's responses.
#
# Only the top-level key NAMES are kept. The values of a live `/info` include
# the daemon's own unique ID, the host's name and kernel, and the current time:
# machine-identifying data that the check does not need and that has no business
# in a repository. The shape is the thing being copied.
#
#   DOCKER_SOCK=~/.docker/run/docker.sock sh oracle/record.sh
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
S="${DOCKER_SOCK:-/var/run/docker.sock}"
[ -S "$S" ] || { echo "no docker socket at $S (set DOCKER_SOCK=)" >&2; exit 2; }
V="${API:-v1.54}"
for ep in version info; do
  curl -s --unix-socket "$S" "http://localhost/$V/$ep" \
    | python3 -c 'import json,sys; print("\n".join(sorted(json.load(sys.stdin))))' \
    > "$here/oracle/expected/$ep.keys" || { echo "FAIL: /$ep" >&2; exit 1; }
  echo "$ep: $(grep -c . "$here/oracle/expected/$ep.keys") keys"
done
