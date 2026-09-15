#!/bin/sh
# test/run_vm.sh — the end-to-end check: a real `docker` client, mengd, mrun,
# and a container that actually runs.
#
# This has to happen on Linux, because a container is namespaces and mounts.
# Here that is the colima VM; set RUNNER to anything else that takes a shell
# script on stdin and runs it as a user with sudo, and SRC to where this
# repository is visible from there.
#
# The oracle is the client: `docker logs` has to print what the container
# printed, and `docker inspect` has to report the status it exited with.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-}"
[ -n "$MERE" ] || { echo "set MERE=<path to a merelang/mere checkout>" >&2; exit 2; }
M="$MERE/_build/default/bin/mere.exe"
[ -x "$M" ] || { echo "no mere binary at $M" >&2; exit 2; }
MRUN_SRC="${MRUN_SRC:-$here/../mrun}"
[ -f "$MRUN_SRC/mrun.mere" ] || { echo "set MRUN_SRC=<path to a 284km/mrun checkout>" >&2; exit 2; }
RUNNER="${RUNNER:-colima ssh --}"
SRC="${SRC:-$here}"
IMG="${IMG:-gcc:14}"
out="$here/.build"; mkdir -p "$out" "$MRUN_SRC/.build"

echo "== build both for linux, static =="
"$M" -c "$here/mengd.mere" > "$out/mengd.c" 2> "$out/e1" || { echo "FAIL: mengd emit"; sed -n 1,10p "$out/e1"; exit 1; }
"$M" -c "$MRUN_SRC/mrun.mere" > "$MRUN_SRC/.build/mrun.c" 2> "$out/e2" || { echo "FAIL: mrun emit"; sed -n 1,10p "$out/e2"; exit 1; }
docker run --rm -v "$here:/w" -w /w "$IMG" \
  cc -O2 -static -o .build/mengd-linux .build/mengd.c unix_shim.c fs_shim.c store_shim.c || { echo "FAIL: cc mengd"; exit 1; }
docker run --rm -v "$MRUN_SRC:/w" -w /w "$IMG" \
  cc -O2 -static -o .build/mrun-linux .build/mrun.c linux_shim.c || { echo "FAIL: cc mrun"; exit 1; }

echo "== run on linux =="
$RUNNER sudo sh -s <<EOF
set -u
pkill mengd 2>/dev/null; sleep 1
install -m755 $SRC/.build/mengd-linux /usr/local/bin/mengd
install -m755 $(cd "$MRUN_SRC" && pwd)/.build/mrun-linux /usr/local/bin/mrun
rm -rf /var/lib/mengd /var/run/mengd.sock; mkdir -p /var/lib/mengd
(setsid /usr/local/bin/mengd /var/run/mengd.sock /var/lib/mengd /usr/local/bin/mrun >/var/log/mengd.log 2>&1 &)
sleep 1
DOCKER_HOST= docker save alpine:latest -o /var/tmp/mengd-test.tar 2>/dev/null
export DOCKER_HOST=unix:///var/run/mengd.sock
fail=0
say() { [ "\$1" = 0 ] && echo "  ok    \$2" || { echo "  FAIL  \$2"; fail=1; }; }

docker load -i /var/tmp/mengd-test.tar >/dev/null 2>&1; say \$? "docker load"
timeout 60 docker run -d --name ok1 alpine echo hello-from-mengd >/dev/null 2>&1; say \$? "docker run -d"
timeout 60 docker run -d --name bad1 alpine sh -c 'exit 7' >/dev/null 2>&1; say \$? "docker run -d (a command that fails)"
sleep 3

out=\$(timeout 20 docker logs ok1 2>&1)
[ "\$out" = "hello-from-mengd" ]; say \$? "docker logs prints what the container printed (\$out)"

st=\$(timeout 20 docker inspect -f '{{.State.ExitCode}}/{{.State.Status}}' bad1 2>&1)
[ "\$st" = "7/exited" ]; say \$? "the exit status came back through mrun (\$st)"

n=\$(timeout 20 docker ps -a --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' ')
[ "\$n" = 2 ]; say \$? "docker ps -a lists both (\$n)"

# One buffer per connection exhausted the FFI arena at the 231st request and
# killed the daemon. A thousand is well past that.
i=0; while [ \$i -lt 1000 ]; do curl -s --unix-socket /var/run/mengd.sock http://localhost/_ping >/dev/null 2>&1 || break; i=\$((i+1)); done
[ "\$i" = 1000 ]; say \$? "1000 connections (\$i) without exhausting the buffer pool"
pgrep mengd >/dev/null; say \$? "the daemon is still alive"

# Foreground run: the client hijacks the connection with Upgrade: tcp and reads
# the framed stream. Exit status has to come back through it too.
o=\$(timeout 60 docker run --name fg alpine sh -c 'echo to-stdout; echo to-stderr 1>&2; exit 5' 2>/dev/null)
rc=\$?
[ "\$o" = "to-stdout" ]; say \$? "foreground run: stdout is stdout (\$o)"
[ "\$rc" = 5 ]; say \$? "foreground run: the exit status reaches the shell (\$rc)"
e=\$(timeout 60 docker run --name fg2 alpine sh -c 'echo O; echo E 1>&2' 2>&1 1>/dev/null)
[ "\$e" = "E" ]; say \$? "foreground run: stderr is stderr (\$e)"

# Go's encoding/json escapes < > and & by default, so the command above arrives
# as "1\\u003e\\u00262". A JSON parser without \\u took the daemon down on it.
pgrep mengd >/dev/null; say \$? "a command containing > and & did not kill the daemon"

# Four at once: one shared staging directory had them deleting each other's files.
for i in 1 2 3 4; do (timeout 60 docker load -i /var/tmp/mengd-test.tar >/dev/null 2>&1) & done; wait
n=\$(timeout 20 docker images -q 2>/dev/null | wc -l | tr -d ' ')
[ "\$n" = 1 ]; say \$? "four concurrent loads leave one image (\$n)"
pgrep mengd >/dev/null; say \$? "and the daemon survived them"

# A malformed archive used to take the daemon down: the vendored reader refused
# by calling exit. Any client could stop the service by uploading junk.
head -c 300 /var/tmp/mengd-test.tar > /var/tmp/trunc.tar
head -c 100000 /dev/urandom > /var/tmp/junk.tar
printf 'not a tar at all' > /var/tmp/tiny.tar
badok=1
for f in trunc junk tiny; do
  msg=\$(timeout 30 docker load -i /var/tmp/\$f.tar 2>&1 | head -1)
  case "\$msg" in *"cannot read that archive"*) ;; *) badok=0 ;; esac
  pgrep mengd >/dev/null || badok=0
done
[ "\$badok" = 1 ]; say \$? "three malformed archives are refused and the daemon survives"

# The reason quotes the archive, which is attacker-controlled bytes, and the
# path it was reading, which is the daemon's own storage layout.
msg=\$(timeout 30 docker load -i /var/tmp/junk.tar 2>&1 | head -1)
case "\$msg" in *"/var/lib/mengd"*) false ;; *) true ;; esac
say \$? "the error does not hand back the daemon's internal path"
printf '%s' "\$msg" | LC_ALL=C grep -q '[^[:print:][:space:]]' && false || true
say \$? "and does not reflect raw bytes from the archive"

timeout 30 docker load -i /var/tmp/mengd-test.tar >/dev/null 2>&1; say \$? "a good archive still loads afterwards"

timeout 20 docker rm -f ok1 bad1 fg fg2 >/dev/null 2>&1; say \$? "docker rm"
n=\$(timeout 20 docker ps -a --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' ')
[ "\$n" = 0 ]; say \$? "and they are gone (\$n)"

[ "\$fail" = 0 ] && echo "mengd/vm PASS" || echo "mengd/vm FAIL"
exit \$fail
EOF
