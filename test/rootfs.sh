#!/bin/sh
# test/rootfs.sh — the oracle is `docker export`: the real daemon's own answer
# to "what filesystem does this image describe".
#
# They are not expected to be identical. `docker export` dumps a CONTAINER, so
# it carries what the runtime added on top of the image -- .dockerenv, the
# device nodes, and the three files a container gets bind-mounted over. Those
# are listed by name below. Anything else that differs is a defect, and the
# list is checked for staleness too: an entry that stops differing is removed
# rather than left as cover for the next difference.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-}"
[ -n "$MERE" ] || { echo "set MERE=<path to a merelang/mere checkout>" >&2; exit 2; }
M="$MERE/_build/default/bin/mere.exe"
[ -x "$M" ] || { echo "no mere binary at $M" >&2; exit 2; }
IMAGE="${IMAGE:-alpine:latest}"
out="$here/.build"; mkdir -p "$out"
store="$out/rootfs-store"

echo "== build =="
"$M" -c "$here/mkrootfs.mere" > "$out/mkrootfs.c" 2> "$out/emit.err" || {
  echo "FAIL: mere -c refused" >&2; sed -n 1,20p "$out/emit.err" >&2; exit 1; }
[ -s "$out/mkrootfs.c" ] || { echo "FAIL: emitted C is empty" >&2; exit 1; }
SSLPREFIX="$(brew --prefix openssl@3 2>/dev/null || echo /opt/homebrew/opt/openssl@3)"
cc -O2 -o "$out/mkrootfs" "$out/mkrootfs.c" "$here/fs_shim.c" "$here/store_shim.c" \
  2> "$out/cc.err" || { echo "FAIL: cc" >&2; sed -n 1,20p "$out/cc.err" >&2; exit 1; }

echo "== unpack $IMAGE with mgz + mtar =="
rm -rf "$store"; mkdir -p "$store"
docker save "$IMAGE" -o "$store/img.tar" || { echo "FAIL: docker save"; exit 1; }
mkdir -p "$store/img"; tar xf "$store/img.tar" -C "$store/img"
rm -rf "$out/rfs"
"$out/mkrootfs" "$store/img" "$out/rfs" || { echo "FAIL: mkrootfs"; exit 1; }

echo "== the oracle: docker export =="
rm -rf "$out/rfs_ref"; mkdir -p "$out/rfs_ref"
cid=$(docker create "$IMAGE" true) || { echo "FAIL: docker create"; exit 1; }
# -p, or the umask silently drops the sticky bit on /tmp and every symlink's
# own mode, and the comparison starts measuring the extracting shell instead.
docker export "$cid" | tar xp -C "$out/rfs_ref"
docker rm -f "$cid" >/dev/null

python3 "$here/test/rootfs_diff.py" "$out/rfs" "$out/rfs_ref"
