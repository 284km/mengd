#!/bin/sh
# probe/region_reclaim.sh — run the probe three ways and print the three shapes.
#
# What it found, on this machine, 2 million elements a round:
#
#   inline        19 MB -> 103 MB over five rounds     nothing comes back
#   region        17 MB ->  32 MB, then flat           reclaimed
#   region-call   19 MB -> 103 MB over five rounds     nothing comes back
#
# So reclamation is LEXICAL: a `region R { }` gives back what was allocated
# inside the BLOCK, and a helper called from inside it allocates somewhere
# else. Every real program is helpers, which is why this daemon's rootfs
# unpacking still grows -- the inflate is a function.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-}"
[ -n "$MERE" ] || { echo "set MERE=<path to a merelang/mere checkout>" >&2; exit 2; }
M="$MERE/_build/default/bin/mere.exe"
[ -x "$M" ] || { echo "no mere binary at $M" >&2; exit 2; }
command -v docker >/dev/null 2>&1 || { echo "needs a container runtime (the probe reads /proc)" >&2; exit 2; }
IMG="${IMG:-gcc:14}"
out="$here/.build"; mkdir -p "$out"
"$M" -c "$here/probe/region_reclaim.mere" > "$out/region_reclaim.c" || exit 1
docker run --rm -v "$here:/w" -w /w "$IMG" \
  cc -O2 -o .build/region_reclaim .build/region_reclaim.c probe/rss_shim.c || exit 1
for mode in inline region region-call; do
  docker run --rm -v "$here:/w" -w /w "$IMG" ./.build/region_reclaim "${1:-5}" "${2:-2000000}" "$mode" 2>&1
  echo
done
