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
  cc -O2 -static -o .build/mengd-linux .build/mengd.c unix_shim.c fs_shim.c store_shim.c net_shim.c \
     -lssl -lcrypto -lz -lzstd -ldl -lpthread || { echo "FAIL: cc mengd"; exit 1; }
docker run --rm -v "$MRUN_SRC:/w" -w /w "$IMG" \
  cc -O2 -static -o .build/mrun-linux .build/mrun.c linux_shim.c || { echo "FAIL: cc mrun"; exit 1; }

# BACKTICKS IN A COMMENT ARE A COMMAND. Everything below goes into an unquoted
# heredoc, so the shell runs whatever a comment quotes -- this has bitten twice,
# and the second time the output of one was parsed as a redirection three
# checks later. Caught here rather than in the middle of a run.
if awk 'f && /^#/ && /`/ {bad=1} /^\$RUNNER sudo sh -s <<EOF/ {f=1} END {exit !bad}' "$0"; then
  echo "FAIL: a comment inside the runner heredoc contains a backtick" >&2; exit 1
fi

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

  # An image with a DELETION in it. A tar archive cannot say "delete", so the
  # image format says it with a filename -- .wh.x beside x -- and a daemon that
  # reads those as files hands back a rootfs with the deleted file still in it,
  # plus a stray .wh. file. Nothing fails in that case, which is why it needs
  # its own image: alpine:latest has no whiteouts, so the pull check above is
  # green either way.
  DOCKER_HOST= docker build -q -t localhost:5000/gate/wh:v1 - >/dev/null 2>&1 <<'WHDF'
FROM alpine:latest
RUN echo kept > /kept.txt && mkdir -p /d && echo a > /d/a && echo b > /d/b
RUN rm /etc/motd && rm /d/a
WHDF
  DOCKER_HOST= docker push localhost:5000/gate/wh:v1 >/dev/null 2>&1; say \$? "seed: an image whose top layer deletes files"
  DOCKER_HOST= docker rmi localhost:5000/gate/wh:v1 >/dev/null 2>&1
  timeout 120 docker pull localhost:5000/gate/wh:v1 >/dev/null 2>&1; say \$? "pulled it"
  o=\$(timeout 90 docker run --rm localhost:5000/gate/wh:v1 sh -c 'cat /kept.txt; ls /etc/motd /d/a >/dev/null 2>&1 && echo STILL-THERE; ls /d; ls -a /etc | grep -c "^\.wh\."' 2>/dev/null | tr '\n' ' ')
  echo "\$o" | grep -q "kept" && ! echo "\$o" | grep -q "STILL-THERE"
  say \$? "the deleted files are gone in the container (\$o)"
  echo "\$o" | grep -q " b " || echo "\$o" | grep -q "b 0"
  say \$? "its sibling and the lower layers survived"
  # PUSH, with the strongest oracle there is: the REAL docker pulls back what
  # this daemon pushed, and runs it. Everything in between -- the blob uploads,
  # the manifest this wrote from what was on disk, the media types -- has to be
  # right for that to work, and none of it is checked by looking at our own
  # answers.
  rm -rf /var/tmp/pctx && mkdir -p /var/tmp/pctx
  printf 'FROM alpine:latest\nRUN echo pushed-by-mengd > /p.txt\nCMD ["cat","/p.txt"]\n' > /var/tmp/pctx/Dockerfile
  DOCKER_BUILDKIT=0 timeout 180 docker build -t localhost:5000/gate/pushed:v1 /var/tmp/pctx >/dev/null 2>&1
  say \$? "built an image to push"
  timeout 120 docker push localhost:5000/gate/pushed:v1 > /var/tmp/push.log 2>&1
  say \$? "docker push"
  grep -q "Pushed" /var/tmp/push.log; say \$? "it reported the layers it sent"
  grep -q "digest: sha256:" /var/tmp/push.log; say \$? "and the manifest digest"
  DOCKER_HOST= docker rmi localhost:5000/gate/pushed:v1 >/dev/null 2>&1
  DOCKER_HOST= timeout 120 docker pull localhost:5000/gate/pushed:v1 >/dev/null 2>&1
  say \$? "the REAL docker pulls it back out of the registry"
  o=\$(DOCKER_HOST= timeout 60 docker run --rm localhost:5000/gate/pushed:v1 2>/dev/null | tr -d '\\r\\n')
  [ "\$o" = "pushed-by-mengd" ]; say \$? "and runs it (\$o)"
  DOCKER_HOST= docker rmi localhost:5000/gate/pushed:v1 >/dev/null 2>&1

  pkill mreg 2>/dev/null || true
else
  echo "  SKIP  mreg not installed: the pull path is untested"
  fail=1
fi

# Binds. -v /host:/container and compose's volumes: were read by nothing,
# so both did NOTHING -- a container whose source directory was not there, and
# a daemon that said it had started. A silent no-op is the worst of the three
# possible answers.
rm -rf /var/tmp/bind && mkdir -p /var/tmp/bind
printf 'from the host\\n' > /var/tmp/bind/hello.txt
o=\$(timeout 60 docker run --rm --network host -v /var/tmp/bind:/data alpine cat /data/hello.txt 2>/dev/null)
[ "\$o" = "from the host" ]; say \$? "a bind mount is readable in the container (\$o)"
timeout 60 docker run --rm --network host -v /var/tmp/bind:/data alpine \
  sh -c 'echo from-the-container > /data/back.txt' >/dev/null 2>&1
[ "\$(cat /var/tmp/bind/back.txt 2>/dev/null)" = "from-the-container" ]
say \$? "and what the container writes is on the host"

# MS_RDONLY is ignored on the initial bind -- the kernel takes it on a remount
# and not before. Without that second call "ro" means nothing, silently: the
# container writes through and the file appears on the host.
rm -f /var/tmp/bind/x
ro=\$(timeout 60 docker run --rm --network host -v /var/tmp/bind:/data:ro alpine \
        sh -c 'echo nope > /data/x' 2>&1 | head -1)
[ ! -e /var/tmp/bind/x ]; say \$? "a read-only bind is read-only (\$ro)"

# A named volume is a directory this daemon keeps, and it outlives the
# container that wrote it.
timeout 60 docker run --rm --network host -v gatevol:/v alpine sh -c 'echo in-a-volume > /v/f' >/dev/null 2>&1
v=\$(timeout 60 docker run --rm --network host -v gatevol:/v alpine cat /v/f 2>/dev/null)
[ "\$v" = "in-a-volume" ]; say \$? "a named volume outlives the container (\$v)"

# And the client can ask what is mounted. It was told "nothing", which was true
# of the config and not of the ask.
timeout 60 docker run -d --name bm --network host -v /var/tmp/bind:/data alpine sleep 5 >/dev/null 2>&1
timeout 20 docker inspect bm --format '{{json .Mounts}}' 2>/dev/null | grep -q '"Destination":"/data"'
say \$? "docker inspect reports the mount"

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

# What the image SAYS, not what the request says. docker run mine:v1 with no
# command has to find the CMD the Dockerfile set, and the ENV with it.
o=\$(timeout 60 docker run --rm --network host mine:v1 2>/dev/null | tr '\\n' ' ')
[ "\$o" = "built-by-mengd second-step " ]; say \$? "running it with no command runs the image's CMD (\$o)"
e=\$(timeout 60 docker run --rm --network host mine:v1 sh -c 'echo \$GREETING' 2>/dev/null)
[ "\$e" = "hello" ]; say \$? "and the image's ENV is in the container (\$e)"

# ONE LAYER PER STEP. The difference a step made is the upper directory of an
# overlay mount, and the base image's layers are carried rather than rebuilt.
# Before this, a build wrote the whole root filesystem as a single layer: the
# image was correct, ran, and shared nothing with the image it was built FROM.
grep -q "Writing 2 layers" /var/tmp/build.log
say \$? "the two RUN steps wrote two layers (\$(grep -o 'Writing [0-9]* layers' /var/tmp/build.log))"
# From the store's own index, by tag. The first version of this found the
# image by GREPPING ITS LAYERS for a string the build wrote -- which stopped
# working the moment layers were compressed, and reported the image as having
# no layers at all. The instrument broke, not the subject.
img=\$(awk -F'\t' '\$2=="mine:v1"{print \$3}' /var/lib/mengd/images.index | tail -1)
nl=\$(python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))[0]['Layers']))" "\$img/manifest.json" 2>/dev/null)
[ "\$nl" = 3 ]; say \$? "the image has the base's layer plus one per step (\$nl)"
nd=\$(python3 -c "
import json,sys,glob
m=json.load(open(sys.argv[1]+'/manifest.json'))[0]
c=json.load(open(sys.argv[1]+'/'+m['Config']))
print(len(c['rootfs']['diff_ids']))" "\$img" 2>/dev/null)
[ "\$nd" = "\$nl" ]; say \$? "and a diff id for each of them (\$nd)"
# CARRIED, not rebuilt. The base layer in the built image must be the SAME
# blob as in the image it was built FROM -- same digest, byte for byte. A layer
# re-tarred from an unpacked tree has different bytes for the same content, and
# then the two images share nothing however much they have in common.
base=\$(awk -F'\t' '\$2=="alpine:latest"{print \$3}' /var/lib/mengd/images.index | tail -1)
b0=\$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]+'/manifest.json'))[0]['Layers'][0])" "\$base" 2>/dev/null)
m0=\$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]+'/manifest.json'))[0]['Layers'][0])" "\$img" 2>/dev/null)
[ -n "\$b0" ] && [ "\$b0" = "\$m0" ]
say \$? "its first layer is the base image's own blob, not a copy with a new digest"

# The point of all of it: a step that writes one line costs one line, not 8 MB.
top=\$(python3 -c "
import json,os,sys
m=json.load(open(sys.argv[1]+'/manifest.json'))[0]
print(os.path.getsize(sys.argv[1]+'/'+m['Layers'][-1]))" "\$img" 2>/dev/null)
[ -n "\$top" ] && [ "\$top" -lt 20480 ]
say \$? "the last step's layer is \$top bytes, not the whole root filesystem"

# A step that DELETES. The layer has to carry the deletion, and it can only say
# so with a name -- there is no other way to write it down in a tar.
rm -rf /var/tmp/dctx && mkdir -p /var/tmp/dctx
cat > /var/tmp/dctx/Dockerfile <<'DF'
FROM alpine:latest
RUN echo here > /gone.txt && echo stays > /stays.txt
RUN rm /gone.txt /etc/motd
CMD ["sh", "-c", "ls /gone.txt /etc/motd 2>/dev/null; cat /stays.txt"]
DF
DOCKER_BUILDKIT=0 timeout 180 docker build -t deleted:v1 /var/tmp/dctx > /var/tmp/build6.log 2>&1
say \$? "a build whose last step deletes files"
o=\$(timeout 60 docker run --rm --network host deleted:v1 2>/dev/null | tr '\\n' ' ')
[ "\$o" = "stays " ]; say \$? "the deleted files are gone in a container from it (\$o)"

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
VOLUME /data
DF
DOCKER_BUILDKIT=0 timeout 120 docker build -t bad:v2 /var/tmp/bctx > /var/tmp/build3.log 2>&1
grep -q "VOLUME is not implemented" /var/tmp/build3.log; say \$? "an instruction it cannot do is refused by name"

# COMPRESSED LAYERS. A built layer is stored gzipped, and that splits one
# digest into two: diff_ids name the UNCOMPRESSED layer -- what a rootfs is
# built from, and what two images share when they share a layer -- while the
# blob is named by what is on disk. Using one for both was correct exactly as
# long as nothing was compressed.
lay=\$(python3 -c "
import json,sys
m=json.load(open(sys.argv[1]+'/manifest.json'))[0]
c=json.load(open(sys.argv[1]+'/'+m['Config']))
print(m['Layers'][-1].split('/')[-1], c['rootfs']['diff_ids'][-1].split(':')[-1])" "\$img" 2>/dev/null)
set -- \$lay
[ -n "\$1" ] && [ "\$1" != "\$2" ]
say \$? "the blob digest and the diff id differ, because one is compressed"
head -c2 "\$img/blobs/sha256/\$1" | od -An -tx1 | tr -d ' \n' | grep -q "1f8b"
say \$? "and the blob is a gzip member"
# Correct AND smaller: a compressor that silently emitted stored blocks would
# pass the first two checks.
z=\$(stat -c%s "\$img/blobs/sha256/\$1")
o=\$(timeout 60 docker run --rm mine:v1 2>/dev/null | tr '\\n' ' ')
[ "\$o" = "built-by-mengd second-step " ]
say \$? "a container from the compressed image still runs (\$o)"

# THE BUILD CACHE. A step's layer is the upper directory of an overlay mount,
# so the cache can BE that directory: a step that has run before is one whose
# upper directory is already sitting there, and using it copies and unpacks
# nothing at all.
#
# The sleeps are the instrument. A cache that is not working still produces the
# right image, so the only thing that can tell them apart is TIME -- and two
# seconds a step is enough to be unmistakable without making the gate slow.
rm -rf /var/tmp/kctx && mkdir -p /var/tmp/kctx
printf 'first\n' > /var/tmp/kctx/data.txt
cat > /var/tmp/kctx/Dockerfile <<'DF'
FROM alpine:latest
RUN sleep 2; echo one > /1
COPY data.txt /data.txt
RUN sleep 2; echo two > /2
CMD ["sh","-c","cat /1 /2 /data.txt"]
DF
t0=\$(date +%s)
DOCKER_BUILDKIT=0 timeout 300 docker build -t k:v1 /var/tmp/kctx > /var/tmp/k1.log 2>&1
t1=\$(date +%s); cold=\$((t1-t0))
say \$? "a build with two slow steps (\${cold}s)"
DOCKER_BUILDKIT=0 timeout 300 docker build -t k:v2 /var/tmp/kctx > /var/tmp/k2.log 2>&1
t2=\$(date +%s); warm=\$((t2-t1))
c=\$(grep -c "Using cache" /var/tmp/k2.log)
[ "\$c" = 3 ]; say \$? "building it again uses the cache for every step (\$c of 3)"
[ "\$warm" -lt "\$cold" ] && [ "\$warm" -le 2 ]
say \$? "and takes \${warm}s instead of \${cold}s"

# A changed step invalidates itself and everything after it, and NOTHING
# before it. That is what a chained key buys.
sed -i 's/echo two/echo TWO/' /var/tmp/kctx/Dockerfile
DOCKER_BUILDKIT=0 timeout 300 docker build -t k:v3 /var/tmp/kctx > /var/tmp/k3.log 2>&1
c=\$(grep -c "Using cache" /var/tmp/k3.log)
[ "\$c" = 2 ]; say \$? "changing the last step keeps the two before it (\$c of 3)"
o=\$(timeout 60 docker run --rm k:v3 2>/dev/null | tr '\\n' ' ')
[ "\$o" = "one TWO first " ]; say \$? "and the image has the new answer (\$o)"

# THE CACHE BUG EVERYBODY HAS MET. The COPY line does not change when the file
# does. Keyed on the line alone, the build hands back the old file forever --
# it says "Using cache", it is fast, and it is wrong.
printf 'second\n' > /var/tmp/kctx/data.txt
DOCKER_BUILDKIT=0 timeout 300 docker build -t k:v4 /var/tmp/kctx > /var/tmp/k4.log 2>&1
o=\$(timeout 60 docker run --rm k:v4 2>/dev/null | tr '\\n' ' ')
[ "\$o" = "one TWO second " ]; say \$? "a changed FILE with an unchanged COPY line busts the cache (\$o)"
c=\$(grep -c "Using cache" /var/tmp/k4.log)
[ "\$c" = 1 ]; say \$? "and only the step before it stayed cached (\$c of 3)"

# ADD. It is COPY plus one thing: a local ARCHIVE is unpacked into the
# destination. Docker decides that by content and not by the name, so the check
# gives it an archive whose name says nothing.
rm -rf /var/tmp/actx && mkdir -p /var/tmp/actx/src/inner
printf 'plain\n' > /var/tmp/actx/plain.txt
printf 'from-the-archive\n' > /var/tmp/actx/src/inner/deep.txt
( cd /var/tmp/actx/src && tar czf ../payload.bin . ) 2>/dev/null
( cd /var/tmp/actx/src && tar cf ../payload.notar . ) 2>/dev/null
printf 'BZh9fake\n' > /var/tmp/actx/fake.bz2
cat > /var/tmp/actx/Dockerfile <<'DF'
FROM alpine:latest
ADD plain.txt /plain.txt
ADD payload.bin /unpacked
ADD payload.notar /also
CMD ["sh","-c","cat /plain.txt; cat /unpacked/inner/deep.txt; cat /also/inner/deep.txt"]
DF
DOCKER_BUILDKIT=0 timeout 180 docker build -t added:v1 /var/tmp/actx > /var/tmp/build7.log 2>&1
say \$? "docker build with ADD"
o=\$(timeout 60 docker run --rm added:v1 2>/dev/null | tr '\\n' ' ')
[ "\$o" = "plain from-the-archive from-the-archive " ]
say \$? "a file was copied and both archives were unpacked (\$o)"

# What it CANNOT unpack is refused by name. Docker unpacks bzip2, so copying it
# would be a different Dockerfile with the same text: the image would hold an
# archive where the build said a tree.
printf 'FROM alpine:latest\nADD fake.bz2 /x\n' > /var/tmp/actx/Dockerfile
DOCKER_BUILDKIT=0 timeout 120 docker build -t bad:v4 /var/tmp/actx > /var/tmp/build8.log 2>&1
grep -q "ADD cannot unpack bzip2" /var/tmp/build8.log; say \$? "a compression it cannot unpack is refused by name"
printf 'FROM alpine:latest\nADD https://example.com/x /x\n' > /var/tmp/actx/Dockerfile
DOCKER_BUILDKIT=0 timeout 120 docker build -t bad:v5 /var/tmp/actx > /var/tmp/build9.log 2>&1
grep -q "ADD does not fetch a URL" /var/tmp/build9.log; say \$? "and a URL says it is a URL, not a missing file"

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
# The project's network is gone and the DEFAULT BRIDGE is not. This asked for
# zero networks before there was a default one; now a container that names no
# network goes on the bridge, and compose down tries to remove it and is
# refused -- which is what docker does with a pre-defined network.
n=\$(timeout 20 docker network ls --format '{{.Name}}' 2>/dev/null | grep -c "^mengdtest_default\$" || true)
[ "\$n" = 0 ]; say \$? "down removed its own network (\$n left)"
b=\$(timeout 20 docker network ls --format '{{.Name}}' 2>/dev/null | grep -c "^bridge\$" || true)
[ "\$b" = 1 ]; say \$? "and not the default bridge (\$b)"

# A CGROUP OF ITS OWN. A container in the daemon's cgroup cannot be limited,
# cannot be measured and cannot be frozen -- three things that are one missing
# directory.
timeout 60 docker run -d --name cg --memory 64m --pids-limit 50 alpine:latest \
  sh -c 'sleep 120' >/dev/null 2>&1
sleep 3
# From the container's OWN id, not by catting every container's field: the
# store has more than one container in it and those files have no trailing
# newline, so the glob ran them together into one path that does not exist.
cgp="mengd/\$(timeout 20 docker inspect -f '{{.Id}}' cg 2>/dev/null | cut -c1-12)"
mm=\$(cat /sys/fs/cgroup/\$cgp/memory.max 2>/dev/null)
[ "\$mm" = 67108864 ]; say \$? "the limit the client asked for is on the cgroup (\$mm)"
pm=\$(cat /sys/fs/cgroup/\$cgp/pids.max 2>/dev/null)
[ "\$pm" = 50 ]; say \$? "and so is the process limit (\$pm)"

# Read through the API, which is the part a person uses -- and the part that
# read zero from files that had the numbers in them, because everything under
# /sys/fs/cgroup reports a size of zero and then hands over bytes.
o=\$(timeout 20 docker stats --no-stream --format '{{.MemUsage}} {{.PIDs}}' cg 2>/dev/null | tr -d '\\r\\n')
echo "\$o" | grep -q "64MiB"; say \$? "docker stats reports the limit (\$o)"
echo "\$o" | grep -qv "^0B"; say \$? "and a usage that is not zero"

timeout 20 docker pause cg >/dev/null 2>&1
f=\$(cat /sys/fs/cgroup/\$cgp/cgroup.freeze 2>/dev/null)
[ "\$f" = 1 ]; say \$? "docker pause freezes it (\$f)"
timeout 20 docker unpause cg >/dev/null 2>&1
f=\$(cat /sys/fs/cgroup/\$cgp/cgroup.freeze 2>/dev/null)
[ "\$f" = 0 ]; say \$? "and unpause lets it go (\$f)"

# top reads the HOST's process table, because the image may have no ps in it.
t=\$(timeout 20 docker top cg 2>/dev/null | tail -1)
echo "\$t" | grep -q "sleep 120"; say \$? "docker top lists the container's own process (\$t)"

timeout 20 docker rename cg cg2 >/dev/null 2>&1
timeout 20 docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^cg2\$"
say \$? "docker rename"
timeout 20 docker rm -f cg2 >/dev/null 2>&1

# PRUNING. /containers/prune fell into the id table and answered "No such
# container: prune", which reads like the client asked for something silly.
timeout 60 docker run --name gone alpine:latest true >/dev/null 2>&1
timeout 30 docker container prune -f > /var/tmp/prune.log 2>&1
say \$? "docker container prune"
timeout 20 docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^gone\$"
[ \$? != 0 ]; say \$? "and the exited container is gone"

# rmi. An image store that only grows is a machine that fills up.
DOCKER_HOST= docker save alpine:latest -o /var/tmp/again.tar 2>/dev/null
timeout 60 docker load -i /var/tmp/again.tar >/dev/null 2>&1
timeout 30 docker rmi alpine:latest > /var/tmp/rmi.log 2>&1
say \$? "docker rmi"
grep -q "Untagged: alpine:latest" /var/tmp/rmi.log; say \$? "it said what it untagged"
timeout 20 docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q "^alpine:latest\$"
[ \$? != 0 ]; say \$? "and the image is not listed any more"
timeout 60 docker load -i /var/tmp/again.tar >/dev/null 2>&1
say \$? "it can be loaded again afterwards"

# HEALTHCHECKS. A container says whether it is WELL by answering a command
# inside itself. compose waits on it -- depends_on: condition:
# service_healthy is how a file says "not until the database is up" -- and a
# daemon that ignores it makes that wait fail with "container has no
# healthcheck configured" about a container that has one.
timeout 60 docker run -d --name hc --health-cmd 'test -f /tmp/ready' \
  --health-interval 2s --health-retries 2 alpine:latest \
  sh -c 'sleep 6; touch /tmp/ready; sleep 120' >/dev/null 2>&1
sleep 4
h1=\$(timeout 20 docker inspect -f '{{.State.Health.Status}}' hc 2>/dev/null)
[ "\$h1" != "healthy" ]; say \$? "a container that cannot answer yet is not healthy (\$h1)"
sleep 8
h2=\$(timeout 20 docker inspect -f '{{.State.Health.Status}}' hc 2>/dev/null)
[ "\$h2" = "healthy" ]; say \$? "and is once it can (\$h2)"
timeout 20 docker rm -f hc >/dev/null 2>&1

# A container with NO healthcheck must not report one. The mirror of the bug:
# a client that sees a health state believes there is a probe behind it.
timeout 60 docker run -d --name nohc alpine:latest sh -c 'sleep 60' >/dev/null 2>&1
sleep 2
hn=\$(timeout 20 docker inspect -f '{{json .State.Health}}' nohc 2>/dev/null)
[ "\$hn" = "null" ]; say \$? "a container without one reports no health at all (\$hn)"
timeout 20 docker rm -f nohc >/dev/null 2>&1

# RESTART POLICIES. restart: unless-stopped is a container that comes back
# when it falls over, and it was a container that exited once and stayed
# exited. Counted through a BIND MOUNT, not through the log: the log is
# truncated on each start, so counting its lines says "1" however many times
# the container ran -- which is what the first measurement of this said.
rm -rf /var/tmp/rstate && mkdir -p /var/tmp/rstate
timeout 60 docker run -d --name rp --restart unless-stopped -v /var/tmp/rstate:/s \
  alpine:latest sh -c 'echo run >> /s/runs; sleep 1' >/dev/null 2>&1
sleep 8
n=\$(wc -l < /var/tmp/rstate/runs 2>/dev/null | tr -d ' ')
[ -n "\$n" ] && [ "\$n" -ge 3 ]; say \$? "a container with restart: unless-stopped came back (\$n runs)"
timeout 20 docker stop rp >/dev/null 2>&1
sleep 4
n2=\$(wc -l < /var/tmp/rstate/runs 2>/dev/null | tr -d ' ')
sleep 3
n3=\$(wc -l < /var/tmp/rstate/runs 2>/dev/null | tr -d ' ')
[ "\$n2" = "\$n3" ]; say \$? "and stopping it stops that (\$n2 then \$n3)"
st=\$(timeout 20 docker inspect -f '{{.State.Status}}' rp 2>/dev/null)
[ "\$st" = "exited" ]; say \$? "the container the user stopped stays stopped (\$st)"
timeout 20 docker rm -f rp >/dev/null 2>&1

# no is the default, and it has to mean no.
rm -rf /var/tmp/rstate2 && mkdir -p /var/tmp/rstate2
timeout 60 docker run -d --name rp0 -v /var/tmp/rstate2:/s alpine:latest \
  sh -c 'echo run >> /s/runs; sleep 1' >/dev/null 2>&1
sleep 6
n0=\$(wc -l < /var/tmp/rstate2/runs 2>/dev/null | tr -d ' ')
[ "\$n0" = 1 ]; say \$? "a container with no policy runs once (\$n0)"
timeout 20 docker rm -f rp0 >/dev/null 2>&1

# docker ps means the ones that are RUNNING. Ignoring the all= parameter
# gives both commands the same answer, so one of them is always wrong.
timeout 60 docker run --name pssrun -d alpine:latest sh -c 'sleep 60' >/dev/null 2>&1
timeout 60 docker run --name psgone alpine:latest true >/dev/null 2>&1
sleep 1
r=\$(timeout 20 docker ps --format '{{.Names}}' 2>/dev/null | tr '\\n' ' ')
a=\$(timeout 20 docker ps -a --format '{{.Names}}' 2>/dev/null | tr '\\n' ' ')
echo "\$r" | grep -q pssrun && ! echo "\$r" | grep -q psgone
say \$? "docker ps lists the running one and not the finished one (\$r)"
echo "\$a" | grep -q pssrun && echo "\$a" | grep -q psgone
say \$? "docker ps -a lists both (\$a)"
timeout 20 docker rm -f pssrun psgone >/dev/null 2>&1

# docker exec. A second process inside a container that is already running,
# which is three requests: one to say what to run, one to run it, one to ask
# how it went.
timeout 60 docker run -d --name exc alpine:latest sh -c 'echo marker > /tmp/here; sleep 120' >/dev/null 2>&1
sleep 2
o=\$(timeout 30 docker exec exc echo from-exec 2>/dev/null | tr -d '\\r\\n')
[ "\$o" = "from-exec" ]; say \$? "docker exec runs a command and returns its output (\$o)"
o=\$(timeout 30 docker exec exc cat /tmp/here 2>/dev/null | tr -d '\\r\\n')
[ "\$o" = "marker" ]; say \$? "it sees the container's filesystem (\$o)"
timeout 30 docker exec exc sh -c 'exit 7' >/dev/null 2>&1
[ \$? = 7 ]; say \$? "and its exit status comes back"
e=\$(timeout 30 docker exec exc sh -c 'echo to-err 1>&2' 2>&1 | tr -d '\\r\\n')
[ "\$e" = "to-err" ]; say \$? "stderr arrives on its own stream (\$e)"

# INSIDE, not merely on the same machine. Entering the mount namespace alone
# would pass the two checks above while leaving the process in the host's
# process table and on the host's network.
n=\$(timeout 30 docker exec exc sh -c 'ls /proc | grep -c "^[0-9]*\$"' 2>/dev/null | tr -d '\\r\\n')
[ -n "\$n" ] && [ "\$n" -lt 20 ]; say \$? "it is in the container's process table (\$n processes)"
a=\$(timeout 30 docker exec exc sh -c 'ip -o addr show eth0 | grep -c "10\\.88\\."' 2>/dev/null | tr -d '\\r\\n')
[ "\$a" = 1 ]; say \$? "and on the container's network (\$a)"

# STDIN. docker exec -i sends the command's input as RAW BYTES on the upgraded
# connection, after the 101. With nowhere to put them the daemon finished,
# closed the socket, and the client -- still writing -- got "connection reset
# by peer": the failure looked like a network fault and was a missing pipe.
o=\$(echo hello-stdin | timeout 30 docker exec -i exc cat 2>/dev/null | tr -d '\\r\\n')
[ "\$o" = "hello-stdin" ]; say \$? "docker exec -i feeds the command its input (\$o)"

# Big enough that it cannot arrive in one read, and cannot sit in one buffer.
n=\$(head -c 300000 /dev/urandom | base64 | timeout 60 docker exec -i exc wc -c 2>/dev/null | tr -d ' \\r\\n')
[ -n "\$n" ] && [ "\$n" -gt 400000 ]; say \$? "a large input arrives whole (\$n bytes)"

# The shape people actually use: a script down the pipe.
o=\$(printf 'echo one\necho two\n' | timeout 30 docker exec -i exc sh 2>/dev/null | tr '\\n' ' ')
[ "\$o" = "one two " ]; say \$? "a script piped into a shell runs (\$o)"

# A terminal is a pty in the container and a bidirectional stream. Refused by
# name rather than half-answered.
timeout 30 docker exec -t exc echo x >/var/tmp/tty.log 2>&1
grep -q "terminal is not implemented" /var/tmp/tty.log
say \$? "exec with a terminal is refused by name"
timeout 20 docker rm -f exc >/dev/null 2>&1

# docker cp, both ways. A container's filesystem is a directory on this
# machine, so this is tar out and tar in -- which the daemon already had in
# both directions.
timeout 60 docker run -d --name cpc alpine:latest \
  sh -c 'mkdir -p /d/sub; echo IN-CONTAINER > /d/f.txt; echo deep > /d/sub/g.txt; sleep 120' >/dev/null 2>&1
sleep 2
rm -f /var/tmp/got.txt
timeout 30 docker cp cpc:/d/f.txt /var/tmp/got.txt >/dev/null 2>&1
[ "\$(cat /var/tmp/got.txt 2>/dev/null)" = "IN-CONTAINER" ]
say \$? "docker cp a file out (\$(cat /var/tmp/got.txt 2>/dev/null))"

# THE ORACLE IS THE REAL DOCKER. A directory copied out has to arrive in the
# same SHAPE -- the archive is named relative to the parent, because the client
# renames that one top-level name. Getting it wrong produces an empty
# destination and no error at all, which is exactly what the first version did.
rm -rf /var/tmp/gotd; timeout 30 docker cp cpc:/d /var/tmp/gotd >/dev/null 2>&1
DOCKER_HOST= docker run -d --name cporacle alpine:latest \
  sh -c 'mkdir -p /d/sub; echo IN-CONTAINER > /d/f.txt; echo deep > /d/sub/g.txt; sleep 60' >/dev/null 2>&1
rm -rf /var/tmp/oracd; DOCKER_HOST= docker cp cporacle:/d /var/tmp/oracd >/dev/null 2>&1
DOCKER_HOST= docker rm -f cporacle >/dev/null 2>&1
( cd /var/tmp/oracd 2>/dev/null && find . | sort ) > /var/tmp/o.txt
( cd /var/tmp/gotd 2>/dev/null && find . | sort ) > /var/tmp/g.txt
[ -s /var/tmp/o.txt ] && diff -q /var/tmp/o.txt /var/tmp/g.txt >/dev/null 2>&1
say \$? "a directory arrives in the same shape as the real docker gives (\$(wc -l < /var/tmp/g.txt | tr -d ' ') entries)"

echo FROM-THE-HOST > /var/tmp/put.txt
timeout 30 docker cp /var/tmp/put.txt cpc:/d/put.txt >/dev/null 2>&1
say \$? "docker cp a file in"
rm -f /var/tmp/back.txt
timeout 30 docker cp cpc:/d/put.txt /var/tmp/back.txt >/dev/null 2>&1
[ "\$(cat /var/tmp/back.txt 2>/dev/null)" = "FROM-THE-HOST" ]
say \$? "and it comes back out again (\$(cat /var/tmp/back.txt 2>/dev/null))"

# A path that climbs out of the container is refused, not clamped: a copy that
# silently lands somewhere else is worse than one that does not happen.
timeout 30 docker cp cpc:/../../etc/passwd /var/tmp/escape.txt >/var/tmp/esc.log 2>&1
[ \$? != 0 ] && [ ! -s /var/tmp/escape.txt ]
say \$? "a source that climbs out of the container is refused"
timeout 20 docker rm -f cpc >/dev/null 2>&1

# THE DEFAULT BRIDGE. A container that names no network used to get a namespace
# with a loopback in it and no way to reach anything -- docker puts it on the
# default bridge, and so does this now. Names are NOT resolved there, which is
# also what docker does: that difference is the reason to create a network.
a=\$(timeout 60 docker run --rm alpine:latest sh -c 'ip -o addr show eth0 2>/dev/null | grep -c "10\.88\."' 2>/dev/null)
[ "\$a" = 1 ]; say \$? "a plain docker run gets an address on the default bridge (\$a)"
timeout 60 docker run -d --name br1 alpine:latest sh -c 'while true; do echo ON-THE-BRIDGE | nc -l -p 7000; done' >/dev/null 2>&1
sleep 2
ip1=\$(timeout 20 docker inspect -f '{{.NetworkSettings.IPAddress}}' br1 2>/dev/null)
o=\$(timeout 60 docker run --rm alpine:latest sh -c "(echo probe | nc -w 3 \$ip1 7000) || echo NO" 2>/dev/null | tr -d '\\r\\n')
[ "\$o" = "ON-THE-BRIDGE" ]; say \$? "and can reach another container on it (\$o)"
timeout 20 docker rm -f br1 >/dev/null 2>&1

# IPv6 ON THE SAME NETWORK. One lease, two addresses: the v6 address ends in
# the same number as the v4 one, so a container's two addresses can never
# disagree about which container it is. Unique-local, because there is nothing
# upstream to be global for -- this network reaches the containers on it, and
# says so rather than implying more.
timeout 30 docker network create sixnet >/dev/null 2>&1
timeout 60 docker run -d --name six --network sixnet alpine:latest \
  sh -c 'while true; do echo V6-SERVED | nc -l -p 9000; done' >/dev/null 2>&1
sleep 3
v4=\$(timeout 20 docker inspect -f '{{.NetworkSettings.IPAddress}}' six 2>/dev/null)
v6=\$(timeout 20 docker inspect -f '{{.NetworkSettings.GlobalIPv6Address}}' six 2>/dev/null)
echo "\$v6" | grep -q "^fd00:"; say \$? "inspect reports a v6 address (\$v4 \$v6)"
[ "\${v6##*:}" = "\${v4##*.}" ]; say \$? "and it ends in the same number as the v4 one"
o=\$(timeout 30 docker exec six ip -6 -o addr show eth0 2>/dev/null | grep -c "\$v6/64")
[ "\$o" = 1 ]; say \$? "the container has it on eth0 (\$o)"

# The only question that matters, and it is asked the moment the container
# starts: an address that is still TENTATIVE from duplicate detection answers
# nothing, and a container that connects immediately would lose that race
# sometimes -- which is worse than always.
o=\$(timeout 60 docker run --rm --network sixnet alpine:latest \
       sh -c "(echo probe | nc -w 3 \$v6 9000) || echo NO-V6" 2>/dev/null | tr -d '\\r\\n')
[ "\$o" = "V6-SERVED" ]; say \$? "one container reaches another over IPv6 (\$o)"
h=\$(timeout 60 docker run --rm --network sixnet alpine:latest \
       sh -c 'grep -c "^fd00:" /etc/hosts' 2>/dev/null | tr -d '\\r\\n')
[ -n "\$h" ] && [ "\$h" -ge 1 ]; say \$? "and the names on it resolve to v6 as well (\$h lines)"
timeout 20 docker rm -f six >/dev/null 2>&1
timeout 20 docker network rm sixnet >/dev/null 2>&1

# ONE SERVICE REACHING ANOTHER. A network was a directory with an id in it, so
# up succeeded, said nothing, and the services could not find each other --
# the failure this whole daemon keeps producing: correct-looking and silent.
#
# The question is asked the way an application asks it: connect to the OTHER
# SERVICE BY ITS NAME. An address would not be enough (the name is what a
# compose file contains) and a ping would not be enough (it says a host is
# there, not that anything answers).
mkdir -p /var/tmp/mengd-net
cat > /var/tmp/mengd-net/compose.yaml <<'YAML'
services:
  store:
    image: alpine:latest
    command: ["sh", "-c", "while true; do echo SERVED | nc -l -p 6379; done"]
  app:
    image: alpine:latest
    command: ["sh", "-c", "sleep 3; (echo probe | nc -w 3 store 6379) || echo CANNOT-REACH-store; sleep 20"]
YAML
cd /var/tmp/mengd-net
timeout 120 docker compose -p mengdnet up -d > /var/tmp/net.out 2>&1
say \$? "docker compose up on a network with two services"
sleep 9
timeout 30 docker compose -p mengdnet logs app > /var/tmp/netlog.out 2>&1
grep -q "SERVED" /var/tmp/netlog.out
say \$? "one service reached the other BY NAME (\$(grep -o 'SERVED\|CANNOT-REACH-store' /var/tmp/netlog.out | head -1))"

# The parts that make it true, each named, so a failure says which one broke.
ipa=\$(timeout 20 docker inspect -f '{{.NetworkSettings.IPAddress}}' mengdnet-app-1 2>/dev/null)
ips=\$(timeout 20 docker inspect -f '{{.NetworkSettings.IPAddress}}' mengdnet-store-1 2>/dev/null)
[ -n "\$ipa" ] && [ -n "\$ips" ] && [ "\$ipa" != "\$ips" ]
say \$? "each container has its own address (\$ipa, \$ips)"
o=\$(timeout 60 docker run --rm --network mengdnet_default alpine:latest sh -c 'ip -o addr show eth0 | grep -c "10\.88\." ; ip route | grep -c "^default via 10\.88\."' 2>/dev/null | tr '\\n' ' ')
[ "\$o" = "1 1 " ]; say \$? "a container joining later gets an address and a way out (\$o)"
# A container that joined LATER has to know the names of the ones already
# there. The table is rewritten for everybody on each start, because compose
# decides the order and the one that came up first would otherwise never learn
# the name of the one that came up second. Asked by USING the name, not by
# grepping for it: a line in a file is not a resolution.
h=\$(timeout 60 docker run --rm --network mengdnet_default alpine:latest \
       sh -c '(echo probe | nc -w 3 store 6379) || echo NO' 2>/dev/null | tr -d '\\r\\n')
[ "\$h" = "SERVED" ]; say \$? "a container that joined later resolves the others (\$h)"
timeout 90 docker compose -p mengdnet down >> /var/tmp/net.out 2>&1
say \$? "compose down took the network with it"
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
