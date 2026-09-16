#!/bin/sh
# tools/vendor-mgz.sh — copy the vendored packages in, rather than editing them
# here. mgz's decompressor, and mtar's reader if MTAR_SRC is given too.
#
#   MGZ_SRC=<a 284km/mgz checkout> [MTAR_SRC=<a 284km/mtar checkout>] sh tools/vendor-mgz.sh
#
# Mere has no package manager. The only edit is the import path, because the
# vendored files sit beside each other under different names -- doing it with a
# script rather than by hand is what keeps "unmodified" true.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
MGZ_SRC="${MGZ_SRC:-}"
[ -n "$MGZ_SRC" ] && [ -f "$MGZ_SRC/inflate.mere" ] || { echo "set MGZ_SRC=<path to a 284km/mgz checkout>" >&2; exit 2; }
{
  echo "// Vendored from 284km/mgz crc32.mere by tools/vendor-mgz.sh. Do not edit here."
  cat "$MGZ_SRC/crc32.mere"
} > "$here/vendor_crc32.mere"
{
  echo "// Vendored from 284km/mgz inflate.mere by tools/vendor-mgz.sh. Do not edit here."
  echo "// The only change is the import path: the vendored files sit beside each"
  echo "// other here under different names."
  sed 's|import "./crc32.mere";|import "./vendor_crc32.mere";|' "$MGZ_SRC/inflate.mere"
} > "$here/vendor_inflate.mere"
grep -q 'import "./vendor_crc32.mere";' "$here/vendor_inflate.mere" \
  || { echo "vendor-mgz.sh: the import was not rewritten" >&2; exit 1; }
MTAR_SRC="${MTAR_SRC:-}"
if [ -n "$MTAR_SRC" ]; then
  [ -f "$MTAR_SRC/tar.mere" ] || { echo "MTAR_SRC has no tar.mere" >&2; exit 2; }
  { echo "// Vendored from 284km/mtar tar.mere by tools/vendor-mgz.sh. Do not edit here."
    cat "$MTAR_SRC/tar.mere"; } > "$here/vendor_tar.mere"
fi
wc -l "$here/vendor_inflate.mere" "$here/vendor_crc32.mere" "$here/vendor_tar.mere"
