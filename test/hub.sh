#!/bin/sh
# test/hub.sh — pull from Docker Hub, and check it against what docker got.
#
# WHAT IT NEEDS, and why this is not a skip. Docker Hub, over the internet.
# A check that cannot run is not a check that passed, so a missing network
# fails this file rather than quietly leaving the authentication path, the
# redirect to a content network and the chunked token response untested. They
# are only reachable against the real thing: a mock registry would test this
# client against our own idea of a registry, which is the thing being written.
#
# It also needs a working `docker` for the ORACLE -- the image id Hub serves,
# according to a client that is not this one.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-}"
[ -n "$MERE" ] || { echo "set MERE=<path to a merelang/mere checkout>" >&2; exit 2; }
M="$MERE/_build/default/bin/mere.exe"
[ -x "$M" ] || { echo "no mere binary at $M" >&2; exit 2; }
command -v docker >/dev/null 2>&1 || { echo "needs docker, for the oracle" >&2; exit 2; }
out="$here/.build"; mkdir -p "$out"
fail=0
say() { [ "$1" = 0 ] && echo "  ok    $2" || { echo "  FAIL  $2"; fail=1; }; }

REF="${REF:-docker.io/library/alpine:latest}"

echo "== build =="
"$M" -c "$here/mengd.mere" > "$out/mengd.c" 2>"$out/e" || { echo "FAIL: emit"; sed -n 1,8p "$out/e"; exit 1; }
SSLPREFIX="$(brew --prefix openssl@3 2>/dev/null || echo /opt/homebrew/opt/openssl@3)"
cc -O1 -o "$out/mengd-hub" "$out/mengd.c" "$here/unix_shim.c" "$here/fs_shim.c" "$here/store_shim.c" \
   -I"$SSLPREFIX/include" -L"$SSLPREFIX/lib" -lssl -lcrypto 2>"$out/cc.err" \
  || { echo "FAIL: cc"; sed -n 1,10p "$out/cc.err"; exit 1; }
say 0 "mengd builds with TLS"

echo "== the internet is there =="
curl -s -o /dev/null -m 15 -w '%{http_code}' https://registry-1.docker.io/v2/ | grep -q 401
say $? "Docker Hub answers, and asks for authentication"

echo "== pull =="
sock="$out/hub.sock"; store="$out/hub-store"
rm -rf "$store" "$sock"; mkdir -p "$store"
MENGD_TRACE=1 "$out/mengd-hub" "$sock" "$store" /bin/true > "$out/hub.log" 2>&1 &
pid=$!
i=0; while [ "$i" -lt 40 ] && [ ! -S "$sock" ]; do sleep 0.25; i=$((i + 1)); done
[ -S "$sock" ]; say $? "the daemon is listening"

got=$(DOCKER_HOST= docker -H "unix://$sock" pull "$REF" 2>&1 | tail -1)
[ "$got" = "$REF" ]; say $? "docker pull $REF ($got)"
grep -q "got a bearer token" "$out/hub.log"; say $? "it answered a Bearer challenge"
grep -qE "reg: (307|302) to " "$out/hub.log"; say $? "and followed the blob to a content network"

# The oracle: the config digest of the arm64 manifest, out of what the real
# client downloaded for the same reference. Agreeing on it means agreeing on
# the manifest, the platform picked out of the index, and the bytes of the
# config.
#
# NOT `docker image inspect .Id`. That answers the INDEX digest on a daemon
# with a containerd image store and the config digest on one without, so it
# says different things on different machines -- which is an oracle answering
# a different question depending on where it is asked. The saved archive says
# the same thing everywhere.
DOCKER_HOST= docker pull -q "$REF" >/dev/null 2>&1
DOCKER_HOST= docker save "$REF" -o "$out/hub-oracle.tar" 2>/dev/null
cat > "$out/config_digest.py" <<'ORACLE'
import json, sys, tarfile
with tarfile.open(sys.argv[1]) as t:
    blob = lambda d: t.extractfile("blobs/" + d.replace(":", "/")).read()
    top = json.loads(t.extractfile("index.json").read())["manifests"][0]
    doc = json.loads(blob(top["digest"]))
    if "manifests" in doc:
        m = [x for x in doc["manifests"]
             if x.get("platform", {}).get("architecture") == "arm64"
             and x.get("platform", {}).get("os") == "linux"][0]
        doc = json.loads(blob(m["digest"]))
    print(doc["config"]["digest"].split(":")[1][:12])
ORACLE
want=$(python3 "$out/config_digest.py" "$out/hub-oracle.tar" 2>/dev/null)
mine=$(DOCKER_HOST= docker -H "unix://$sock" images --format '{{.ID}}' 2>/dev/null | head -1)
[ -n "$want" ] && [ "$want" = "$mine" ]
say $? "the image id is the config digest docker downloaded for it ($mine vs $want)"

echo "== and the default is still not plaintext =="
plain=$(DOCKER_HOST= docker -H "unix://$sock" pull 127.0.0.1:1/nothing:v1 2>&1 | tail -1)
case "$plain" in *"cannot verify"*|*"cannot reach"*) echo "  ok    a registry with no certificate is not spoken to in the clear";; \
                 *) echo "  FAIL  got: $plain"; fail=1;; esac

kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
[ "$fail" = 0 ] && echo "hub PASS" || echo "hub FAIL"
exit "$fail"
