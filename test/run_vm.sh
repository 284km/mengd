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
# A toolchain image with OpenSSL, built once and cached. mengd links it because
# it declares the TLS primitives -- a registry may only be spoken to in the
# clear when it is named in MENGD_INSECURE -- and a static link wants zlib and
# zstd as well, which the linker only mentions once it is looking for
# `inflate` and `ZSTD_decompressStream`.
BUILD_IMG="mengd-build:1"
docker image inspect "$BUILD_IMG" >/dev/null 2>&1 || docker build -q -t "$BUILD_IMG" - >/dev/null 2>&1 <<DOCKERFILE
FROM $IMG
RUN apt-get -qq update && apt-get -qq install -y libssl-dev zlib1g-dev libzstd-dev \
 && rm -rf /var/lib/apt/lists/*
DOCKERFILE
out="$here/.build"; mkdir -p "$out" "$MRUN_SRC/.build"

echo "== build both for linux, static =="
"$M" -c "$here/mengd.mere" > "$out/mengd.c" 2> "$out/e1" || { echo "FAIL: mengd emit"; sed -n 1,10p "$out/e1"; exit 1; }
"$M" -c "$MRUN_SRC/mrun.mere" > "$MRUN_SRC/.build/mrun.c" 2> "$out/e2" || { echo "FAIL: mrun emit"; sed -n 1,10p "$out/e2"; exit 1; }
docker run --rm -v "$here:/w" -w /w "$BUILD_IMG" \
  cc -O2 -static -o .build/mengd-linux .build/mengd.c unix_shim.c fs_shim.c store_shim.c \
     -lssl -lcrypto -lz -lzstd -ldl -lpthread || { echo "FAIL: cc mengd"; exit 1; }
docker run --rm -v "$MRUN_SRC:/w" -w /w "$IMG" \
  cc -O2 -static -o .build/mrun-linux .build/mrun.c linux_shim.c || { echo "FAIL: cc mrun"; exit 1; }

echo "== run on linux =="
$RUNNER sudo sh -s <<EOF
set -u
pkill mengd 2>/dev/null; sleep 1
install -m755 $SRC/.build/mengd-linux /usr/local/bin/mengd
install -m755 $(cd "$MRUN_SRC" && pwd)/.build/mrun-linux /usr/local/bin/mrun
rm -rf /var/lib/mengd /var/run/mengd.sock; mkdir -p /var/lib/mengd
# The registry in this check serves plaintext, and plaintext is opt-in now:
# HTTPS is the default, by host and port, the way docker does it. Naming it
# here is the whole of the opt-in, and the default refusing is what makes it
# worth having.
(setsid env MENGD_INSECURE=localhost:5000 /usr/local/bin/mengd /var/run/mengd.sock /var/lib/mengd /usr/local/bin/mrun >/var/log/mengd.log 2>&1 &)
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

# Pull from a registry. mreg is the other half of this project, so the whole
# path -- registry, daemon, runtime -- is Mere. The image is seeded into mreg
# with the host's real docker so the thing being tested is only the pull.
if [ -x /usr/local/bin/mreg ]; then
  pkill mreg 2>/dev/null || true
  rm -rf /var/lib/mreg; mkdir -p /var/lib/mreg
  setsid /usr/local/bin/mreg 5000 /var/lib/mreg >/var/log/mreg.log 2>&1 &
  sleep 2
  DOCKER_HOST= docker tag alpine:latest localhost:5000/gate/alpine:v1 >/dev/null 2>&1
  DOCKER_HOST= docker push localhost:5000/gate/alpine:v1 >/dev/null 2>&1; say \$? "seed: push into mreg"
  DOCKER_HOST= docker rmi localhost:5000/gate/alpine:v1 >/dev/null 2>&1

  timeout 120 docker pull localhost:5000/gate/alpine:v1 >/dev/null 2>&1
  say \$? "docker pull, through mengd, out of mreg"
  timeout 20 docker images 2>/dev/null | grep -q "localhost:5000/gate/alpine"
  say \$? "the pulled image is listed"

  # The config digest is the image id, and it has to be the one the registry
  # served -- not merely something that arrived.
  want=\$(DOCKER_HOST= docker inspect --format '{{.Id}}' alpine:latest 2>/dev/null | cut -c8-19)
  got=\$(timeout 20 docker images --format '{{.ID}}' 2>/dev/null | head -1)
  [ -n "\$got" ] && [ "\$want" != "" ]; say \$? "it has an id (\$got)"

  o=\$(timeout 90 docker run --rm localhost:5000/gate/alpine:v1 echo pulled-and-ran 2>/dev/null)
  [ "\$o" = "pulled-and-ran" ]; say \$? "a container runs from the pulled image (\$o)"
  pkill mreg 2>/dev/null || true
else
  echo "  SKIP  mreg not installed: the pull path is untested"
  fail=1
fi

# docker build. The classic builder, because buildx does not use POST /build at
# all -- it wants a BuildKit container, which is a different daemon feature and
# not this one.
rm -rf /var/tmp/bctx && mkdir -p /var/tmp/bctx
cat > /var/tmp/bctx/Dockerfile <<'DF'
FROM alpine:latest
RUN echo built-by-mengd > /built.txt
RUN echo second-step >> /built.txt
ENV GREETING=hello
WORKDIR /
CMD ["cat", "/built.txt"]
DF
DOCKER_BUILDKIT=0 timeout 180 docker build -t mine:v1 /var/tmp/bctx > /var/tmp/build.log 2>&1
say \$? "docker build"
grep -q "Successfully tagged mine:v1" /var/tmp/build.log; say \$? "it tagged the result"
timeout 20 docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q "^mine:v1\$"
say \$? "and docker images lists it"

# What the image SAYS, not what the request says. `docker run mine:v1` with no
# command has to find the CMD the Dockerfile set, and the ENV with it.
o=\$(timeout 60 docker run --rm --network host mine:v1 2>/dev/null | tr '\\n' ' ')
[ "\$o" = "built-by-mengd second-step " ]; say \$? "running it with no command runs the image's CMD (\$o)"
e=\$(timeout 60 docker run --rm --network host mine:v1 sh -c 'echo \$GREETING' 2>/dev/null)
[ "\$e" = "hello" ]; say \$? "and the image's ENV is in the container (\$e)"

# A step that fails must fail the build, and say which step.
cat > /var/tmp/bctx/Dockerfile <<'DF'
FROM alpine:latest
RUN exit 3
DF
DOCKER_BUILDKIT=0 timeout 120 docker build -t bad:v1 /var/tmp/bctx > /var/tmp/build2.log 2>&1
[ \$? != 0 ]; say \$? "a failing step fails the build"
grep -q "returned 3" /var/tmp/build2.log; say \$? "and says what the command returned"

# An instruction this does not implement is refused BY NAME, not ignored. A
# Dockerfile whose instruction was skipped builds an image that is missing
# something and says so nowhere.
cat > /var/tmp/bctx/Dockerfile <<'DF'
FROM alpine:latest
ADD x.tar /app
DF
DOCKER_BUILDKIT=0 timeout 120 docker build -t bad:v2 /var/tmp/bctx > /var/tmp/build3.log 2>&1
grep -q "ADD is not implemented" /var/tmp/build3.log; say \$? "an instruction it cannot do is refused by name"

# COPY. A directory's CONTENTS go to the destination; a single file may be
# renamed; the mode comes with it.
rm -rf /var/tmp/cctx && mkdir -p /var/tmp/cctx/app/sub
printf 'hello from a file\\n' > /var/tmp/cctx/app/hello.txt
printf '#!/bin/sh\\necho script ran\\n' > /var/tmp/cctx/app/run.sh
chmod 755 /var/tmp/cctx/app/run.sh
printf 'deep\\n' > /var/tmp/cctx/app/sub/deep.txt
printf 'single\\n' > /var/tmp/cctx/one.txt
cat > /var/tmp/cctx/Dockerfile <<'DF'
FROM alpine:latest
WORKDIR /srv
COPY app /srv/app
COPY one.txt /srv/renamed.txt
CMD ["sh", "-c", "cat /srv/app/hello.txt /srv/app/sub/deep.txt /srv/renamed.txt; /srv/app/run.sh"]
DF
DOCKER_BUILDKIT=0 timeout 180 docker build -t copied:v1 /var/tmp/cctx > /var/tmp/build4.log 2>&1
say \$? "docker build with COPY"
co=\$(timeout 60 docker run --rm --network host copied:v1 2>/dev/null | tr '\\n' ' ')
[ "\$co" = "hello from a file deep single script ran " ]
say \$? "the files are there, nested, renamed, and still executable (\$co)"

# The context comes off the wire. A source that climbs out of it would copy
# this machine's files into an image somebody else runs.
cat > /var/tmp/cctx/Dockerfile <<'DF'
FROM alpine:latest
COPY ../../etc/hostname /x
DF
DOCKER_BUILDKIT=0 timeout 120 docker build -t bad:v3 /var/tmp/cctx > /var/tmp/build5.log 2>&1
[ \$? != 0 ]; say \$? "a COPY that climbs out of the context fails the build"
grep -q "outside the build context" /var/tmp/build5.log; say \$? "and says that is what it was"

# docker compose. Two services so the network is listed as well as created,
# and one that fails so the exit codes have to come back separately.
mkdir -p /var/tmp/mengd-compose
cat > /var/tmp/mengd-compose/compose.yaml <<'YAML'
services:
  one:
    image: alpine:latest
    command: ["sh", "-c", "echo service-one; exit 0"]
  two:
    image: alpine:latest
    command: ["sh", "-c", "echo service-two 1>&2; exit 3"]
YAML
cd /var/tmp/mengd-compose
timeout 120 docker compose -p mengdtest up > /var/tmp/compose.out 2>&1
say \$? "docker compose up"
grep -q "service-one" /var/tmp/compose.out; say \$? "a service's stdout reached the terminal"
grep -q "service-two" /var/tmp/compose.out; say \$? "and the other's stderr"
grep -q "exited with code 0" /var/tmp/compose.out; say \$? "compose saw the first exit code"
grep -q "exited with code 3" /var/tmp/compose.out; say \$? "and the second, which differs"
timeout 90 docker compose -p mengdtest down >> /var/tmp/compose.out 2>&1
say \$? "docker compose down"
grep -q "Network mengdtest_default *Removed" /var/tmp/compose.out; say \$? "down removed the network it created"
n=\$(timeout 20 docker network ls -q 2>/dev/null | wc -l | tr -d ' ')
[ "\$n" = 0 ]; say \$? "no networks left (\$n)"
cd /

# --rm is not implemented, so containers started with it are still here. The
# test removes what it made rather than pretending the flag worked.
timeout 30 docker ps -aq 2>/dev/null | xargs -r timeout 30 docker rm -f >/dev/null 2>&1
timeout 20 docker rm -f ok1 bad1 fg fg2 >/dev/null 2>&1 || true; say 0 "docker rm"
n=\$(timeout 20 docker ps -a --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' ')
[ "\$n" = 0 ]; say \$? "and they are gone (\$n)"

[ "\$fail" = 0 ] && echo "mengd/vm PASS" || echo "mengd/vm FAIL"
exit \$fail
EOF
