#!/bin/sh
# test/cli.sh — the oracle is the real `docker` CLI plus the real dockerd's
# response shape.
#
# Two checks, and they catch different things:
#   1. STRUCTURAL -- mengd's JSON has the same top-level keys as a real
#      dockerd's, recorded as NAMES ONLY in oracle/expected/*.keys. A missing
#      field the CLI happens not to render today is still a missing field.
#   2. BEHAVIOURAL -- the real client accepts what mengd returns and renders it.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-}"
[ -n "$MERE" ] || { echo "set MERE=<path to a merelang/mere checkout>" >&2; exit 2; }
M="$MERE/_build/default/bin/mere.exe"
[ -x "$M" ] || { echo "no mere binary at $M" >&2; exit 2; }
command -v docker >/dev/null || { echo "docker CLI not found" >&2; exit 2; }
out="$here/.build"; mkdir -p "$out"
sock="${SOCK:-/tmp/mengd-test.sock}"

echo "== build =="
"$M" -c "$here/mengd.mere" > "$out/mengd.c" 2> "$out/emit.err" || {
  echo "FAIL: mere -c refused" >&2; sed -n '1,20p' "$out/emit.err" >&2; exit 1; }
[ -s "$out/mengd.c" ] || { echo "FAIL: emitted C is empty" >&2; exit 1; }
cc -O1 -o "$out/mengd" "$out/mengd.c" "$here/unix_shim.c" 2> "$out/cc.err" || {
  echo "FAIL: cc" >&2; sed -n '1,20p' "$out/cc.err" >&2; exit 1; }

rm -f "$sock"
"$out/mengd" "$sock" > "$out/mengd.log" 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null; rm -f "$sock"' EXIT
i=0; while [ ! -S "$sock" ] && [ $i -lt 50 ]; do i=$((i+1)); sleep 0.1; done
[ -S "$sock" ] || { echo "FAIL: mengd never created $sock"; cat "$out/mengd.log"; exit 1; }

fail=0
say() { if [ "$1" = 0 ]; then echo "  ok    $2"; else echo "  FAIL  $2"; fail=1; fi; }

echo "== structural: same top-level keys as the recorded dockerd =="
for ep in version info; do
  curl -s --unix-socket "$sock" "http://localhost/v1.54/$ep" > "$out/$ep.mine.json" || true
  python3 - "$out/$ep.mine.json" "$here/oracle/expected/$ep.keys" "$ep" <<'PY'
import json, sys
mine_p, ref_p, name = sys.argv[1], sys.argv[2], sys.argv[3]
try: mine = json.load(open(mine_p))
except Exception as e: print(f"  FAIL  /{name} is not JSON: {e}"); sys.exit(1)
# Key NAMES only. A live /info's values carry the daemon's unique ID, the host
# name and the current time; the check needs none of that and the repository
# should not hold it. oracle/record.sh regenerates these from any daemon.
ref = [l.strip() for l in open(ref_p) if l.strip()]
missing = sorted(set(ref) - set(mine)); extra = sorted(set(mine) - set(ref))
if missing or extra:
    if missing: print(f"  FAIL  /{name} missing {len(missing)} key(s): {' '.join(missing[:8])}")
    if extra:   print(f"  FAIL  /{name} has {len(extra)} key(s) dockerd does not: {' '.join(extra[:8])}")
    sys.exit(1)
print(f"  ok    /{name} has all {len(ref)} top-level keys and no extras")
PY
  [ $? = 0 ] || fail=1
done

echo "== behavioural: the real client =="
DOCKER_HOST="unix://$sock" docker version > "$out/version.txt" 2>&1
say $? "docker version exits 0"
grep -q "Server: mengd" "$out/version.txt"; say $? "it renders 'Server: mengd'"
# The CLIENT's line, with "downgraded from" -- that is what the Api-Version
# RESPONSE HEADER controls. The Server section's "API version" comes from the
# JSON body instead, so asserting on it passes whether or not the header is
# sent: a poison that removed the header left this green until the assertion
# was aimed at the line the header actually moves. Without the header the
# client keeps its own newest version (1.56 here) and sends requests in a
# shape this daemon never agreed to.
grep -q "downgraded from" "$out/version.txt"; say $? "the client downgraded itself to our Api-Version header"
DOCKER_HOST="unix://$sock" docker info > "$out/info.txt" 2>&1
say $? "docker info exits 0"
grep -q "Server Version: 0.1.0" "$out/info.txt"; say $? "it renders the server version"

echo "== refusals name themselves =="
DOCKER_HOST="unix://$sock" docker ps > "$out/ps.txt" 2>&1
if [ $? = 0 ]; then echo "  FAIL  docker ps should not have succeeded"; fail=1
else grep -q "GET /containers/json is not implemented" "$out/ps.txt"
     say $? "an unimplemented route names the method and path"; fi

[ "$fail" = 0 ] && echo "mengd PASS" || echo "mengd FAIL"
exit "$fail"
