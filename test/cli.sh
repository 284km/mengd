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
store_dir="$out/store"
rm -rf "$store_dir"; mkdir -p "$store_dir"

echo "== build =="
"$M" -c "$here/mengd.mere" > "$out/mengd.c" 2> "$out/emit.err" || {
  echo "FAIL: mere -c refused" >&2; sed -n '1,20p' "$out/emit.err" >&2; exit 1; }
[ -s "$out/mengd.c" ] || { echo "FAIL: emitted C is empty" >&2; exit 1; }
SSLPREFIX="$(brew --prefix openssl@3 2>/dev/null || echo /opt/homebrew/opt/openssl@3)"
cc -O1 -o "$out/mengd" "$out/mengd.c" "$here/unix_shim.c" "$here/fs_shim.c" "$here/store_shim.c" "$here/net_shim.c" \
   -I"$SSLPREFIX/include" -L"$SSLPREFIX/lib" -lssl -lcrypto 2> "$out/cc.err" || {
  echo "FAIL: cc" >&2; sed -n '1,20p' "$out/cc.err" >&2; exit 1; }

rm -f "$sock"
"$out/mengd" "$sock" "$store_dir" > "$out/mengd.log" 2>&1 &
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
# This used to ask `docker ps`, from when /containers/json was not implemented.
# It is, and has been for a long time, so the check was asserting the absence
# of a feature that arrived -- red on every run and telling nobody anything.
# A route that really is absent is asked instead, and the answer still has to
# name the method and the path rather than being a bare 404.
# /build used to be the absent route this asked about. It is not absent any
# more, so the question moved to one that is -- and this check exists to make
# sure a refusal NAMES itself, not to record which feature is missing.
curl -s --unix-socket "$sock" -X POST "http://localhost/v1.43/commit" > "$out/refuse.txt" 2>&1
grep -q "POST /commit is not implemented" "$out/refuse.txt"
say $? "an unimplemented route names the method and path"

echo "== images: load, list, and load the same thing again =="
fix="$out/fixture.tar"
if [ ! -f "$fix" ]; then
  # Built against the ambient daemon, before DOCKER_HOST is pointed at mengd.
  docker save alpine:latest -o "$fix" 2>/dev/null || { echo "  SKIP  no alpine:latest to save"; fix=""; }
fi
if [ -n "$fix" ]; then
  DOCKER_HOST="unix://$sock" docker load -i "$fix" > "$out/load.txt" 2>&1
  say $? "docker load exits 0"
  grep -q "Loaded image: alpine:latest" "$out/load.txt"
  say $? "it reports the tag out of the archive's own manifest"

  DOCKER_HOST="unix://$sock" docker images > "$out/images.txt" 2>&1
  say $? "docker images exits 0"
  grep -q "alpine:latest" "$out/images.txt"; say $? "the loaded image is listed"

  # The archive names the image only from INSIDE, so a duplicate can be
  # detected just by unpacking it -- and the unpacked tree has to go away
  # again. It did not, the first time: 7.9 MB per repeated load.
  before=$(ls -A "$store_dir/images" 2>/dev/null | wc -l | tr -d ' ')
  DOCKER_HOST="unix://$sock" docker load -i "$fix" >/dev/null 2>&1
  after=$(ls -A "$store_dir/images" 2>/dev/null | wc -l | tr -d ' ')
  [ "$before" = "$after" ]; say $? "a repeated load leaves no extra directory ($before -> $after)"
  rows=$(grep -c . "$store_dir/images.index" 2>/dev/null || echo 0)
  [ "$rows" = 1 ]; say $? "and no second row in the index ($rows)"

  # file_openrw creates without truncating, so a smaller archive after a larger
  # one leaves the larger one's tail behind. Detecting that needs LARGER THEN
  # SMALLER: the first version of this check loaded the same fixture twice, so
  # both writes were the same length and removing the truncate left it green.
  big=""
  for img in $(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -v '<none>'); do
    [ "$img" = "alpine:latest" ] && continue
    docker save "$img" -o "$out/big.tar" 2>/dev/null || continue
    [ "$(ls -l "$out/big.tar" | awk '{print $5}')" -gt "$(ls -l "$fix" | awk '{print $5}')" ] && { big="$out/big.tar"; break; }
  done
  if [ -z "$big" ]; then
    echo "  SKIP  no image larger than the fixture: cannot test the truncate"
    fail=1   # a check that cannot run is not a check that passed
  else
    DOCKER_HOST="unix://$sock" docker load -i "$big" >/dev/null 2>&1
    DOCKER_HOST="unix://$sock" docker load -i "$fix" > "$out/small.txt" 2>&1
    # The defect this guards: file_openrw does not truncate, so a smaller
    # archive written over a larger one kept the larger one's tail and the
    # manifest at the end was the WRONG one. Staging is per-request now, so the
    # file cannot be reused -- and this asks the two things that would show it
    # if it were: the small archive's own tag comes back, and nothing is left
    # in the store pretending to be an upload.
    grep -q "Loaded image: alpine:latest" "$out/small.txt"
    say $? "a smaller archive after a larger one reports its OWN manifest"
    left=$(ls "$store_dir" 2>/dev/null | grep -c "^incoming" || true)
    [ "$left" = 0 ]
    say $? "and no staging file is left behind ($left)"
  fi

  curl -s --unix-socket "$sock" "http://localhost/v1.54/images/json" > "$out/images.mine.json"
  python3 - "$out/images.mine.json" "$here/oracle/expected/images_json.keys" <<'PY2'
import json, sys
mine = json.load(open(sys.argv[1]))
ref = [l.strip() for l in open(sys.argv[2]) if l.strip()]
if not mine: print("  FAIL  /images/json returned nothing"); sys.exit(1)
missing = sorted(set(ref) - set(mine[0])); extra = sorted(set(mine[0]) - set(ref))
if missing or extra:
    print(f"  FAIL  /images/json entry keys differ: missing {missing} extra {extra}"); sys.exit(1)
print(f"  ok    /images/json entries carry all {len(ref)} keys dockerd's do")
PY2
  [ $? = 0 ] || fail=1
fi

[ "$fail" = 0 ] && echo "mengd PASS" || echo "mengd FAIL"
exit "$fail"
