#!/bin/sh
# probe/run_threads.sh — can the daemon serve two connections at once?
#
# `docker run` sends /wait BEFORE /start, on its own connection, and /wait does
# not return until the container exits. A server that finishes one connection
# before accepting the next deadlocks on the simplest possible run. That is an
# architectural question, so it is measured before the container routes exist.
#
# Runs the probe twice: as written, and with `spawn` removed. The second one
# must deadlock. A "concurrent" result from a harness that cannot report
# "serial" is not a measurement.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-}"
[ -n "$MERE" ] || { echo "set MERE=<path to a merelang/mere checkout>" >&2; exit 2; }
M="$MERE/_build/default/bin/mere.exe"
[ -x "$M" ] || { echo "no mere binary at $M" >&2; exit 2; }
out="$here/.build"; mkdir -p "$out"

build() { # src out
  "$M" -c "$1" > "$out/t.c" 2> "$out/t.err" || { echo "FAIL: mere -c refused" >&2; sed -n 1,10p "$out/t.err" >&2; return 1; }
  [ -s "$out/t.c" ] || { echo "FAIL: emitted C is empty" >&2; return 1; }
  cc -O1 -o "$2" "$out/t.c" "$here/unix_shim.c" 2> "$out/cc.err" || { echo "FAIL: cc" >&2; sed -n 1,10p "$out/cc.err" >&2; return 1; }
}

# The poison: the same program with the handler called inline instead of spawned.
sed 's|let _ = spawn (fn (u: unit) ->|let _ = (fn (u: unit) ->|; s|if n == 0 then slow c marker else fast c marker) in|if n == 0 then slow c marker else fast c marker) () in|' \
  "$here/probe/probe_threads.mere" > "$out/probe_threads_serial.mere"
grep -q "spawn" "$out/probe_threads_serial.mere" && { echo "FAIL: the poison did not remove spawn" >&2; exit 1; }

build "$here/probe/probe_threads.mere" "$out/probe_threads" || exit 1
build "$out/probe_threads_serial.mere" "$out/probe_threads_serial" || exit 1

run() { # binary -> prints CONCURRENT or SERIAL
  rm -f /tmp/mengd-probe.sock /tmp/mengd-probe.marker
  "$1" /tmp/mengd-probe.sock /tmp/mengd-probe.marker >/dev/null 2>&1 &
  p=$!
  i=0; while [ ! -S /tmp/mengd-probe.sock ] && [ $i -lt 50 ]; do i=$((i+1)); sleep 0.1; done
  python3 - <<'PY'
import socket, threading, time
res = {}
def call(tag, delay):
    time.sleep(delay)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(8)
    data = b""
    try:
        s.connect("/tmp/mengd-probe.sock")
        s.sendall(b"GET /" + tag.encode() + b" HTTP/1.1\r\n\r\n")
        while True:
            d = s.recv(4096)
            if not d: break
            data += d
    except Exception: data = b"<no reply>"
    res[tag] = data.split(b"\r\n\r\n")[-1].decode("latin1")
    s.close()
t = [threading.Thread(target=call, args=("slow", 0)), threading.Thread(target=call, args=("fast", 0.5))]
for x in t: x.start()
for x in t: x.join()
print("CONCURRENT" if res.get("slow") == "slow-after-fast" else "SERIAL")
PY
  kill $p 2>/dev/null; wait $p 2>/dev/null
}

fail=0
a=$(run "$out/probe_threads")
[ "$a" = CONCURRENT ] && echo "  ok    spawn per connection: the second client is served while the first blocks" \
                      || { echo "  FAIL  expected CONCURRENT, got $a"; fail=1; }
b=$(run "$out/probe_threads_serial")
[ "$b" = SERIAL ] && echo "  ok    without spawn it deadlocks, so the check can tell the difference" \
                  || { echo "  FAIL  poison expected SERIAL, got $b"; fail=1; }
[ "$fail" = 0 ] && echo "threads PASS" || echo "threads FAIL"
exit "$fail"
