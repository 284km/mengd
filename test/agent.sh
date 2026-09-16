#!/bin/sh
# test/agent.sh — the host side: a socket on this machine that reaches the
# daemon in the VM, and a port on this machine that reaches a container's.
#
# THE PORT NUMBER MATTERS. lima forwards the VM's listening ports to the host
# by itself, so a test that publishes 8099 in the VM and curls 8099 here is
# measuring lima. The check uses a host port lima does not claim, and then
# stops the agent and requires the port to go dead -- which is the only way to
# know whose pipe carried the bytes.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-}"
[ -n "$MERE" ] || { echo "set MERE=<path to a merelang/mere checkout>" >&2; exit 2; }
M="$MERE/_build/default/bin/mere.exe"
[ -x "$M" ] || { echo "no mere binary at $M" >&2; exit 2; }
SSH_CONFIG="${SSH_CONFIG:-$HOME/.colima/_lima/colima/ssh.config}"
SSH_HOST="${SSH_HOST:-lima-colima}"
REMOTE="${REMOTE:-/var/run/mengd.sock}"
RUNNER="${RUNNER:-colima ssh --}"
[ -r "$SSH_CONFIG" ] || { echo "no ssh config at $SSH_CONFIG (set SSH_CONFIG=)" >&2; exit 2; }
out="$here/.build"; mkdir -p "$out"
sock="$out/agent.sock"
HOSTPORT="${HOSTPORT:-18099}"
VMPORT="${VMPORT:-8099}"
fail=0
say() { [ "$1" = 0 ] && echo "  ok    $2" || { echo "  FAIL  $2"; fail=1; }; }

echo "== build =="
"$M" -c "$here/magent.mere" > "$out/magent.c" 2> "$out/e" || { echo "FAIL: emit"; sed -n 1,10p "$out/e"; exit 1; }
[ -s "$out/magent.c" ] || { echo "FAIL: emitted C is empty"; exit 1; }
cc -O2 -o "$out/magent" "$out/magent.c" "$here/unix_shim.c" "$here/store_shim.c" \
  2> "$out/cc" || { echo "FAIL: cc"; sed -n 1,10p "$out/cc"; exit 1; }

echo "== a container listening in the VM =="
$RUNNER sudo sh -c "DOCKER_HOST=unix://$REMOTE docker rm -f agenttest >/dev/null 2>&1; \
  DOCKER_HOST=unix://$REMOTE docker run -d --network host --name agenttest alpine \
  sh -c 'while true; do printf \"HTTP/1.1 200 OK\r\nContent-Length: 12\r\n\r\nhello-in-vm\n\" | nc -l -p $VMPORT; done'" >/dev/null 2>&1
say $? "started one with --network host"
sleep 3

echo "== the agent =="
rm -f "$sock"
"$out/magent" "$sock" "$SSH_CONFIG" "$SSH_HOST" "$REMOTE" "$HOSTPORT:$VMPORT" > "$out/agent.log" 2>&1 &
pid=$!
trap 'kill $pid 2>/dev/null; rm -f "$sock"' EXIT
i=0; while [ ! -S "$sock" ] && [ $i -lt 40 ]; do i=$((i+1)); sleep 0.25; done
[ -S "$sock" ]; say $? "it created the socket"
grep -q "cannot listen" "$out/agent.log" && { echo "  FAIL  it could not take port $HOSTPORT (something else has it)"; fail=1; } || echo "  ok    it took port $HOSTPORT"

v=$(DOCKER_HOST="unix://$sock" docker version --format '{{.Server.Version}}' 2>/dev/null)
[ -n "$v" ]; say $? "the docker client reaches the daemon in the VM ($v)"

o=$(DOCKER_HOST="unix://$sock" docker run --rm alpine echo through-the-agent 2>/dev/null)
[ "$o" = "through-the-agent" ]; say $? "a foreground run works through it, hijacked stream and all ($o)"

body=$(curl -s -m 8 "http://127.0.0.1:$HOSTPORT/" 2>/dev/null)
[ "$body" = "hello-in-vm" ]; say $? "the forwarded port reaches the container ($body)"

echo "== whose pipe was that =="
kill $pid 2>/dev/null; wait $pid 2>/dev/null; sleep 1
dead=$(curl -s -m 3 "http://127.0.0.1:$HOSTPORT/" 2>/dev/null)
[ -z "$dead" ]; say $? "with the agent stopped the port is dead, so the agent was carrying it"

$RUNNER sudo sh -c "DOCKER_HOST=unix://$REMOTE docker rm -f agenttest >/dev/null 2>&1" >/dev/null 2>&1
[ "$fail" = 0 ] && echo "magent PASS" || echo "magent FAIL"
exit "$fail"
