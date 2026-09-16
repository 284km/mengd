# mengd

A Docker Engine API daemon written in [Mere](https://merelang.org/), speaking
to the real `docker` client over a Unix socket.

```sh
export MERE=/path/to/a/merelang/mere/checkout
mere -c mengd.mere > d.c && cc -O2 d.c unix_shim.c -o mengd
./mengd /tmp/mengd.sock &

DOCKER_HOST=unix:///tmp/mengd.sock docker version
```

```
Client: Docker Engine - Community
 API version:       1.54 (downgraded from 1.56)
 ...
Server: mengd
 Engine:
  Version:          0.1.0
  API version:      1.54 (minimum version 1.40)
  OS/Arch:          linux/arm64
```

```sh
docker load -i alpine.tar   # Loaded image: alpine:latest
docker images               # alpine:latest  1991bd789d71  4.18MB
```

Five routes: `/_ping`, `/version`, `/info`, `/images/load`, `/images/json`.
Images are unpacked by [mtar](https://github.com/284km/mtar), vendored here —
the same tar reader that is checked against bsdtar and GNU tar in its own
repository.

`docker load` arrives as `Transfer-Encoding: chunked` with no length, and the
body is **streamed to a file**. The FFI arena is 16 MiB and a real image is
larger than that — postgres:17-alpine is 415 MB — so anything that buffered the
body would work on alpine and fail on the first image anyone actually uses.

**This is not Docker and does not claim to be.** It reports its own name, its
own version, and zero containers, because it has none yet. Only the protocol is
copied — the values are mengd's.

## What an unimplemented route says

```
$ DOCKER_HOST=unix:///tmp/mengd.sock docker ps
Error response from daemon: mengd: GET /containers/json is not implemented
```

A 404 that names the method and the path. The next route to write is whatever
the client just asked for.

## Testing

```sh
sh test/cli.sh
```

Two checks, catching different things.

**Structural** — mengd's `/version` and `/info` JSON must have exactly the
top-level keys a real dockerd returns, recorded as **names only** in
`oracle/expected/*.keys` — 11 and 59 of them. Names only on purpose: a live
`/info`'s values carry the daemon's own unique ID, the host's name and kernel,
and the current time. The check needs none of that, so the repository does not
hold it. `sh oracle/record.sh` regenerates the lists from any daemon. A poison that drops a single field from `/info` is caught
here, and **the client does not notice it at all** — which is the reason this
check exists separately.

**Behavioural** — the real `docker` CLI accepts the responses, renders them, and
negotiates the API version down to the one in our header.

### The assertion that was aimed at the wrong line

The version-negotiation check originally grepped for `API version:      1.54`,
which passed — and kept passing when the `Api-Version` response header was
removed entirely. That string comes from the JSON body's `ApiVersion` field, in
the *Server* section. The header controls the *Client* section instead:

| | client line |
|---|---|
| with the header | `API version: 1.54 (downgraded from 1.56)` |
| without it | `API version: 1.56` |

Without the header the client keeps its own newest version and sends requests in
a shape this daemon never agreed to. The check now looks for `downgraded from`,
and the poison that removes the header turns it red.

### Three defects the checks found, and one they did not

**A duplicate load left the whole unpacked tree behind.** An archive names its
image only from the inside — the id is the digest of a config blob within it —
so nothing can be decided before unpacking, and the first version simply did not
clean up: 7.9 MB per repeated `docker load`. It now stages the unpack and either
renames it into place or deletes it.

**`file_openrw` creates without truncating.** A smaller archive written after a
larger one kept the larger one's tail. It read correctly anyway, because a tar
ends in zero blocks and the walk stops there — so nothing was visibly wrong
while `incoming.tar` grew to the size of the biggest image ever loaded. With the
truncate removed as a poison, it reaches 801 MB where the archive is 8 MB.

**The JSON writer escaped only quotes and backslashes.** The `docker load` reply
ends in a newline, because that is what the client prints, and the client
answered `invalid character '\n' in string`.

And the one they did not: **the truncate check was aimed at the wrong thing.**
It loaded the same fixture twice, so both writes were the same length and
removing the truncate left it green. It now loads a larger archive first, and
fails loudly when there is no larger image available rather than reporting a
check that could not run as one that passed. That is the third assertion in this
project to pass for a reason other than the one it was written for; the poison
is what caught all three.

## The host side

```sh
magent ~/.mengd/docker.sock ~/.colima/_lima/colima/ssh.config lima-colima \
       /var/run/mengd.sock 18099:8099

DOCKER_HOST=unix://~/.mengd/docker.sock docker run alpine echo hello
curl http://127.0.0.1:18099/          # a container's port, from this machine
```

`magent` listens on this machine and hands each connection to the daemon in the
VM. **It does not copy bytes.** The connection becomes a child process's stdin
and stdout and the child is `ssh <host> socat`, so the kernel moves them. A
proxy that read and re-wrote every byte would be a second place for the framing
to be wrong — and the framing here includes a hijacked attach stream, which
does survive the trip: a foreground `docker run` from the host prints its output
and returns its exit status.

`--network host` shares the VM's network namespace. Containers on a user-defined
network get one of their own, wired to a bridge — see **A network between
containers** below.

### The test was measuring lima

The first port-forward check published 8099 in the VM and curled 8099 here, and
it passed before the agent could even take the port — **lima forwards the VM's
listening ports to the host by itself**, and the agent had logged `cannot listen
on port 8099` while the curl went through lima's pipe.

The check uses a host port lima does not claim, requires the agent to have
actually taken it, and then **stops the agent and requires the port to go
dead**. That last step is the only one that says whose pipe carried the bytes.

## `docker pull`, from a registry that is also Mere

```
$ docker pull localhost:5000/lib/alpine:v1
Downloaded newer image for localhost:5000/lib/alpine:v1
$ docker run --rm localhost:5000/lib/alpine:v1 echo pulled-and-ran
pulled-and-ran
```

`/images/create` fetches the manifest, follows an index to the linux/arm64
manifest inside it, and downloads the config and layer blobs. The registry on
the other end is [mreg](https://github.com/284km/mreg) and the container is run
by [mrun](https://github.com/284km/mrun), so nothing in that line is Go.

What it writes is the **same on-disk shape `docker save` produces** —
`blobs/sha256/<hex>` and a `manifest.json` — so registering it, building a
rootfs from it and running it are the code paths that already existed. A pulled
image and a loaded one are indistinguishable downstream.

### Two off-by-a-colon bugs in one route

`docker pull localhost:5000/lib/alpine:v1` sends
`fromImage=localhost%3A5000%2Flib%2Falpine` and `tag=v1`. **Percent-encoded**,
so a reader that does not decode sees no registry host at all — the same bug
class that cost eleven conformance specs in mreg, in a different codebase, a day
apart.

And then: a tag is a colon **after the last slash**. Taking any colon as "already
tagged" makes `localhost:5000/lib/alpine` look tagged by its own port number,
so the pull asked for `latest` and reported the manifest missing.

### Same content, different name

The first version returned early when the config digest was already in the
store, so `docker pull` succeeded and `docker images` did not list what it had
just pulled. Content that is already here under another name is still a new
name.

## `docker compose up`

```
$ docker compose up
 Network mengdtest_default  Created
 Container mengdtest-one-1  Started
 Container mengdtest-two-1  Started
one-1  | service-one
two-1  | service-two
one-1 exited with code 0
two-1 exited with code 3
$ docker compose down
 Container mengdtest-one-1  Removed
 Network mengdtest_default  Removed
```

Two services, their streams kept apart, their exit codes kept apart, and the
network created and removed. Fifteen routes: `_ping`, `version`, `info`,
`images/load`, `images/json`, `images/{name}/json`, `containers/create`,
`containers/{id}/` json, start, stop, kill, wait, logs, attach and delete, plus
`networks/*`, `volumes/*` and `events`.

### What compose needed that a single `docker run` did not

**Label filters.** compose finds its own containers with
`?filters={"label":{"com.docker.compose.project=x":true}}`, percent-encoded. A
daemon that ignores the filter hands compose every container on the host and it
adopts them all.

**Events with labels in them.** compose attaches and then waits for a `die`
event to know the service finished. An events stream that published nothing
left it printing the container's output and then sitting there until its own
timeout — the container had been gone for a minute. And the events have to
carry the container's labels, because compose filters those too: an event
without them is an event compose does not believe is its own.

**Docker's vocabulary, not the store's.** The first working event stream sent
`Action: "running"`. A client filters for `start` and throws the rest away.

**A parseable timestamp.** `Created: ""` is not an empty field to a Go client,
it is `parsing time "" as "2006-01-02T15:04:05Z07:00"` and a fatal error before
a single network is listed. RFC 3339 on the inspect routes, a Unix integer in
the list ones — the API uses both and the client has two decoders.

**Resolving a network by id.** The store is keyed by name and compose removes by
id, so `down` reported "No resource found to remove" for a network that was
right there.

**`/volumes`.** `docker compose down` will not finish without listing them,
even for a project that has none.

## It runs containers

```
$ docker run alpine sh -c 'echo to-stdout; echo to-stderr 1>&2; exit 5'
to-stdout
to-stderr
$ echo $?
5
```

Foreground and detached, with stdout and stderr kept apart and the exit status
coming back through both.

```sh
export MERE=/path/to/mere MRUN_SRC=/path/to/mrun
sh test/run_vm.sh
```

```
  ok    docker load
  ok    docker run -d
  ok    docker logs prints what the container printed (hello-from-mengd)
  ok    the exit status came back through mrun (7/exited)
  ok    docker ps -a lists both (2)
  ok    1000 connections (1000) without exhausting the buffer pool
  ok    the daemon is still alive
  ok    docker rm
```

`docker run -d`, `ps`, `logs`, `inspect` and `rm` work against mengd, with the
container itself run by [mrun](https://github.com/284km/mrun). It has to happen
on Linux, because a container is namespaces and mounts.

### The attach upgrade, and a probe that asked for less than the client does

`/attach` hijacks the connection. Which response it gets depends on the request:
a client sending `Upgrade: tcp` gets `101 UPGRADED` with
`Content-Type: application/vnd.docker.multiplexed-stream`; one that does not
gets `200 OK` with `raw-stream`.

This was implemented wrong first, because the probe used to measure it was a
hand-written request that omitted `Upgrade: tcp`. The real daemon answered 200,
so 200 is what got built, and the real client said **`unable to upgrade to tcp,
received 200`**. A probe that asks for less than the client asks for gets an
answer to a different question.

### Go escapes `>` and `&`, and it took the daemon down

`docker run alpine sh -c 'echo x 1>&2'` sends the command as
`"echo x 1\u003e\u00262"`: Go's `encoding/json` escapes `<`, `>` and `&` by
default. The vendored JSON parser delegated unescaping to the `str_unescape`
builtin, which does not know `\u` and **aborts the process** — so any command
containing one of those three characters killed the daemon. Not an edge case;
most shell commands.

`vendor_json.mere` now decodes `\uXXXX` itself, surrogate pairs included, and
says in its header that it diverges from upstream and why. The fix belongs in
`contrib/json` rather than here.

### The bug that looked intermittent and was not

The same crash looked timing-dependent for an afternoon — it appeared, then five
runs in a row passed. The passing runs used `echo x`; the failing ones used
`1>&2`. It was perfectly deterministic and the variable was the test input, not
the schedule. Chasing it as a race did find a real race, though: four concurrent
`docker load`s unpacked into one shared staging directory and deleted each
other's files, which showed up as `lchown(2) failed` on a file that had just
vanished. Paths are per-request now, and four-at-once is in the test.

### Three bugs only the real client could find

**`/wait` has to answer in two parts.** The client sends it *before* `/start`
and will not send `/start` until the response headers arrive; the JSON body
comes when the container exits. A wait that says nothing until it has an answer
deadlocks the simplest `docker run`, and did. The real daemon sends the headers
in 0.00 s with `Transfer-Encoding: chunked` and the body minutes later, which is
what this does now.

**The daemon died of SIGPIPE.** `docker run -d` closes its `/wait` connection as
soon as it has the id, and the next write killed the process — exit status 141,
which is 128 + SIGPIPE and named the cause exactly.

**A buffer per connection exhausted the FFI arena at the 231st request.** The
arena is a bump allocator with no free, and the runtime's own message said what
to do instead. There is now a fixed pool of 32, acquired and released around
each connection, so a 33rd concurrent connection waits rather than corrupting
anything. The first attempt kept the pool in a `Vec` and the compiler refused
it — *"cannot capture `pool` : Vec['a, int] across a thread boundary (it is
neither Send nor Sync)"* — which was right, and one block plus arithmetic on an
`int` is both correct and simpler.

## Turning an image into a root filesystem

```sh
sh test/rootfs.sh              # alpine
IMAGE=redis:7-alpine sh test/rootfs.sh
```

```
  ok    nothing in the built rootfs that the image did not describe
  ok    the only paths missing are the 5 the runtime adds
  ok    1160 shared paths match exactly (type, mode, content, link target)
  ok    every allowed exception is still an actual difference
```

Layers are gzipped tars applied in the order `manifest.json` gives them, so
mengd vendors [mgz](https://github.com/284km/mgz) for the gzip and
[mtar](https://github.com/284km/mtar) for the tar — three Mere libraries in a
row, each checked against a system tool in its own repository. mgz takes 0.4 s
on a 4 MB layer against the system `gunzip`'s 0.01 s, and produces the same
8,939,520 bytes with the same sha256.

The oracle is `docker export`, which is not expected to be identical: it dumps a
CONTAINER, so it carries what the runtime added on top of the image. Those eight
paths are listed by name — five added (`.dockerenv`, the device nodes,
`etc/resolv.conf`) and three replaced (`etc/hostname`, `etc/hosts`, `etc/mtab`).
Anything else is a defect, **and the list is checked for staleness**: an entry
that stops differing is a failure too, because a stale allowance is cover for
the next real difference.

### The comparison measured the shell first

The first run reported 340 differing paths, which looked like a serious bug in
the layer application and was not. The reference was extracted with `tar x`
rather than `tar xp`, so the umask had dropped the sticky bit on `/tmp` and the
mode of every one of the image's 335 symlinks. The built rootfs was right and
the oracle was wrong.

## The next slice needs concurrency, and that was measured first

`docker run` sends `/containers/{id}/wait` **before** `/containers/{id}/start`,
on its own connection, and `/wait` does not return until the container exits. A
server that finishes one connection before accepting the next therefore
deadlocks on the simplest possible run — the wait cannot return because the
start is never accepted. Detached (`-d`) does not avoid it:

```
POST /v1.54/containers/create?name=p23
POST /v1.54/containers/<id>/wait?condition=next-exit     <- sent first
POST /v1.54/containers/<id>/start
```

So the architecture question was measured before any container route was
written:

```sh
sh probe/run_threads.sh
```

```
  ok    spawn per connection: the second client is served while the first blocks
  ok    without spawn it deadlocks, so the check can tell the difference
```

Mere's `spawn` is a real `pthread_create` on the C backend, and a thread per
connection does it. The second line is the poison: the same probe with `spawn`
removed, where both clients time out. A "concurrent" result from a harness that
cannot report "serial" would not be a measurement.

## What is next

`/attach`, which hijacks the connection and multiplexes stdout and stderr, for a
foreground `docker run`. Then `/networks/*`, `/volumes/*` and `/events`, which is
what `docker compose up` needs.

Known gaps: the interleaving between stdout and stderr is not preserved (they
are separate files, so each stream's own order survives and the order between
them does not); no cgroup accounting, no `--rm`, no ports, and no networking
beyond the namespace mrun creates.

### The denial of service that was in the README before it was in the code

The vendored tar reader refused a malformed archive by calling `exit` — correct
for a CLI, and a way for any client to stop the daemon by uploading junk.
`walk` now returns -1 and leaves the reason behind, mtar's own CLI turns that
back into a message and exit 3, and `/images/load` answers 400. Three malformed
archives are in the test and the daemon has to still be serving afterwards.

Returning the reason needed two more fixes. It quotes the entry it choked on,
which is **attacker-controlled bytes** — a junk archive reflected raw control
characters into whatever terminal read the error — and the path it was reading,
which is the daemon's own storage layout. The reason is now printable-only,
length-capped, and says "the uploaded archive" where the path was.


## Where it listens

A path is an `AF_UNIX` socket, which is what `docker.sock` is:

```sh
mengd /var/run/mengd.sock /var/lib/mengd /usr/local/bin/mrun
```

`vsock://<port>` is `AF_VSOCK`, which is how a daemon **inside a virtual
machine** is reached — there is no path on the host's filesystem that leads
there, so the VMM carries the stream to a port instead:

```sh
mengd vsock://1024 /var/lib/mengd /usr/local/bin/mrun
```

The accept loop does not change: `accept(2)` does not care which family the
listening fd came from, so this is one call rather than a second socket layer.
[mvm](https://github.com/284km/mvm) is the VMM on the other end of it, and its
`test/stack.sh` runs a real `docker` client against a mengd started this way.


## Published ports

A container that listens is reached through a forwarder, one per published
port, started when the container starts and stopped when it exits:

```
mengd: forwarding vsock 18080 to 8080 in the container (pid 115)
```

The forwarder runs **inside the container's own network namespace**, which is
why it needs the container's pid and not the runtime's — the runtime
supervises, and the namespaces belong to its child. `mrun` writes that pid to a
file for the same reason nothing else could find it.

The vsock port is the published **host** port. That convention needs no
agreement between the two ends: whoever opened the host's end already chose
that number. What cannot be done is refused by name in the create response
rather than accepted and dropped — a `udp` publish comes back as
`mengd cannot publish 9999/udp (only tcp is forwarded)`, where before it came
back as success with nothing listening.

## Memory: where Mere gives it back

This daemon had run for months in a virtual machine with 10 GB. In one with
1 GiB it died on the fourth container. The measurement was unambiguous:

```
after load:        17776 kB
after container 1: 214776 kB
after container 2: 477224 kB
...
after container 6: 1461420 kB
```

**+246 MB per container, linear, never returned.** A big machine could not have
shown it: nothing was wrong that a few more gigabytes did not hide.

Two things cause it, and only one is fixable here.

The size was the vendored inflate's doing: it decompressed into a vector of
ints, one per byte, so a 4 MB layer became about 71 MB of vector — plus the
doubling as it grows — before a single file was written. It holds bytes one per
byte now (`284km/mgz`, and this repository re-vendored it), which took the cost
from **246 MB per container to 34 MB**.

The lifetime is the language's model, used wrongly. Mere gives memory back at a
`region R { }` boundary and nowhere else, and `probe/region_reclaim.sh`
measures exactly where:

| | five rounds of 2M elements |
|---|---|
| plain | 19 MB → 103 MB, nothing returned |
| inside a `region` block | 17 MB → 32 MB, then flat |
| a helper CALLED from inside a `region` block | 19 MB → 103 MB, nothing returned |

**Reclamation is lexical.** A region gives back what the block allocates; a
function called from inside it allocates somewhere else. Every real program is
functions, which is why wrapping `apply_layer` in a region took the cost from
246 MB to about 204 MB and no further: the inflate is a helper.

Then the decompressor stopped holding the layer at all — it writes to the file
as it goes, behind a 32 KiB window — and mtar's extractor started reading each
entry inside a region. **246 MB per container becomes 9.4 MB**, twenty-six
times less:

```
after load:         9816 kB
after container 1: 23636 kB
...
after container 6: 76612 kB     (7.6 MB a container, steady)
```

It is still linear, and what is left is measured rather than guessed. Per
layer, roughly: **one copy of the compressed input**, which survives the region
it is read inside — not every builtin allocates in the current one — and
**the Huffman tables of each DEFLATE block**, which `huff_build` makes and
which are therefore a helper's allocations, where a lexical region cannot reach
them.

Both are the same shape as the ones already fixed and neither is reachable from
this daemon: they are the decompressor's, and the next step for them is either
a region inside `huff_build` or a language that carries the current region
through a call.


## Registries are HTTPS

The default is a verified TLS handshake — certificate chain and hostname — and
plaintext is opt-in by host and port, the way docker does it:

```sh
MENGD_INSECURE=127.0.0.1:5000,localhost:5001 mengd /var/run/mengd.sock ...
MENGD_CA=/etc/ssl/my-ca.pem                  # empty means the system store
```

The wrong default here is not a slower pull. It is a manifest anyone on the
path can replace, and the image that comes out of it runs as root.

**A certificate that does not check out is a refusal, not a fallback.** Falling
back to plaintext when verification fails is the same as not verifying:
whoever can break the handshake can make it fail. The message names both ways
out — the authority to trust, or the host and port to speak to in the clear —
because a daemon that says "cannot fetch the manifest" has told nobody
anything.

Declaring the TLS primitives is what makes the C backend link OpenSSL. A static
build wants zlib and zstd with it, which the linker only mentions once it is
looking for `inflate` and `ZSTD_decompressStream`.


## Docker Hub

```sh
docker -H unix://... pull docker.io/library/alpine:latest
```

Three things had to be there and none of them was:

**The challenge.** A registry answers `401` with
`WWW-Authenticate: Bearer realm=...,service=...,scope=...`; the token comes
from that realm and the request goes again with it. The challenge names the
scope, so nothing here has to know what Hub wants — which is the point of the
challenge existing. The realm must be `https`: a token handed over in the clear
is a token anyone on the path can use.

**The redirect.** Blobs are served from a content network, as `307` with a
`Location`. The token is **not** carried across — it was issued for the
registry, and handing it to whoever a `Location` names is handing it to a third
party.

**Chunked.** The token endpoint answers `Transfer-Encoding: chunked` with no
`Content-Length`, and a reader that only knows `Content-Length` reads zero
bytes and reports an empty document — which looks exactly like a server that
said nothing.

Two smaller ones, both found the same way:

- Header names are case-insensitive and Hub means it: `www-authenticate:` in
  lower case. Searching for `WWW-Authenticate:` found nothing, and the daemon
  reported an empty challenge, which is what a missing header looks like when
  the *search* is the thing that is wrong.
- A 401 and a redirect are not the same permission. One flag for both meant
  answering the challenge spent the right to follow the redirect that came
  next — which is exactly the shape of a blob fetch at Hub: 401, token, 307.
  There is a budget now, so each step costs one and a loop still cannot run
  away.

`test/hub.sh` checks it against an oracle that is not this client: the config
digest of the arm64 manifest out of what `docker` downloaded for the same
reference. It needs the internet, and **fails rather than skips** without it —
a check that cannot run is not a check that passed, and the authentication
path, the redirect and the chunked response are only reachable against the real
thing.

## Through a proxy

`MENGD_PROXY=host:port` tunnels every registry connection with HTTP `CONNECT`.
It exists for a machine with no route to the internet that cannot be given one
as a table: a registry redirects blobs to a content network whose host nobody
knows when the machine starts, and a route cannot follow a name it was never
given.

**The handshake still happens here**, with the real host, through the tunnel.
The proxy sees the name in the CONNECT line and ciphertext after it.

## Where to dial, and what to verify

`MENGD_DIAL=<registry host:port>=<host:port>` separates the socket from the
name. They are the same thing almost always — and they cannot be inside a
machine with no resolver and no route, which reaches the outside through a port
on its own loopback. The certificate is still checked against the name the
image was asked for.


## docker build

```sh
DOCKER_BUILDKIT=0 docker build -t mine:v1 .
```

`FROM`, `RUN`, `COPY`, `ENV`, `WORKDIR`, `CMD`, and `LABEL` ignored. Anything
else is **refused by name**: a Dockerfile whose instruction was skipped builds
an image that is missing something and says so nowhere. So is a `COPY` with a
flag, and one with a `*` in it — a pattern taken literally copies nothing and
reports success.

**A `COPY` may not climb out of the build context.** The context arrives over
the wire, and a source of `../../etc/shadow` would copy this machine's files
into an image somebody else gets to run.

`DOCKER_BUILDKIT=0` because buildx does not use `POST /build` at all — it wants
a BuildKit container, which is a different daemon feature and not this one.

### One layer per step

A layer is the **difference** a step made, and this daemon cannot compute a
difference. The kernel can: the step runs on an overlay mount, and the upper
directory holds what changed and nothing else. So every step that can change
the filesystem — `RUN` and `COPY` — gets its own upper directory, and that
directory *is* its layer.

The base image's layers are **carried across**, not rebuilt. A layer re-tarred
from an unpacked tree has different bytes for the same content, and then an
image and the image it was built `FROM` share nothing however much they have in
common. The check for it compares the first layer's blob path in both.

Measured on the gate's own Dockerfile (`FROM alpine` + two `RUN` steps writing
one line each):

| | before | now |
|---|---|---|
| layers | 1 | 3 (the base's, then one per step) |
| the last step's layer | 8,940,544 B | 2,048 B |

Both numbers come from the same check, one of them with the overlay disabled —
which is also how the fallback stays honest: a machine that cannot mount an
overlay still builds a correct image, one flat layer, and **says so in the
build output**. A different shape arrived at silently is the thing to avoid.

Deletions survive the trip because the kernel and the image format are made to
agree: overlayfs marks a deleted file as a character device `0:0` and a
replaced directory with `trusted.overlay.opaque`, and mtar translates both into
the `.wh.` names a layer uses. Applying a layer translates them back.

### A step that needs the network

A `RUN` step shares the machine's network namespace, and inside a VM that
namespace has a loopback and nothing else — `apk add` would resolve nothing.
When this daemon was itself given a `MENGD_PROXY`, build steps get
`HTTP_PROXY`, `HTTPS_PROXY` and the lower-case pair pointing at it, so the
tools find the way out that the daemon has.

Only then. On a machine with a network the step needs no proxy, and adding one
would send its traffic somewhere it was not asked to go. The Dockerfile wins:
an `ENV` in the file is set after these.

**A tool has to speak `CONNECT`.** `curl`, `apk`, `npm` and `pip` do; busybox's
`wget` does not — it asks the proxy to fetch on its behalf, which for `https`
would mean the proxy doing the TLS and the caller verifying nothing.

### What the image says, where the request said nothing

An image carries a `Cmd`, an `Env` and a `WorkingDir`, and `docker run mine:v1`
with no command expects the image's. This used only the request, which is empty
in that case — the runtime then said `process.args is empty`, naming the
symptom and not the cause. Nothing noticed because every check here had always
passed a command. `Env` merges with the image's first and the request's after,
which is what `-e` means.


## Binds and volumes

`-v /host:/container`, `-v name:/container`, `:ro`, and compose's `volumes:`.

They were read by **nothing** before, so both forms did nothing: a container
whose source directory was not there, and a daemon that said it had started.
A silent no-op is the worst of the three possible answers, and `docker inspect`
made it worse by reporting `"Mounts": []` — true of the config it wrote, and
not of what was asked.

A source that is not an absolute path is a **named volume**: a directory in
this daemon's own store, with the same record an explicit `docker volume
create` leaves, because everything that lists volumes reads that record.

**`:ro` needs a remount** — `MS_RDONLY` is ignored on the initial bind — and
that is mrun's half. Without it the option meant nothing, silently.

### A stored field that may not be there

`read_file` raises when the path is missing, and in Mere that ends the
**process**, not the request. A volume nobody created explicitly has no
`created` file, and `docker compose down` asks for exactly those: it sends
`GET /volumes` with a label filter, and the daemon died. Every read of a field
that exists only once something has written it goes through `read_file_or`
now — the same shape as `jparse`, and found the same way.

## A network between containers

A compose file is written for **two** services. Before this, a network was a
directory with an id in it: `up` succeeded, said nothing, and the services could
not find each other. That is this project's recurring shape of failure —
correct-looking, silent, and visible only to somebody using the thing for what
it is for. It was found by running a real two-service compose file, which no
check here had ever done.

A network is now made of the parts the kernel actually has:

| | |
|---|---|
| a bridge per network | `br-<12 hex of the network id>`, `10.88.<n>.1/24` |
| a veth pair per container | one end on the bridge, one end inside |
| an address per container | the next free one on that network |
| a namespace made **first** | so the wiring is finished before the container exists |

**The order is the point.** The namespace is created and configured, and the
bundle names it by path; the runtime *enters* it rather than making one. A
container wired up after it starts can connect before its address exists —
rarely, which is worse than always, because rare failures get blamed on the
network.

**The address is taken with `mkdir`.** Reading the addresses in use and picking
the next one is a read and then a write, and this daemon serves a thread per
connection: compose starts its services at the same time, both threads read the
same answer, and two containers came up on `10.88.1.2`. `mkdir` is atomic, so
the directory *is* the lease. The address is reserved at **create**, because
compose creates every service before it starts any of them — which is what makes
the hosts table complete the first time it is written.

**Names come from `/etc/hosts`, rewritten for everybody on each start.** The
container that came up first has to learn the name of the one that came up
second, and compose decides that order. The file is in the container's own root
filesystem, which is a directory on this machine, so a running container sees
the new line the next time it looks. The check asks by *using* the name — a
line in a file is not a resolution.

**A container that cannot be wired does not start.** It would come up, look
healthy, and be unable to reach the service it was brought up to talk to.

Addresses, links and routes go through ioctls, which are old and exact. Making a
veth pair is the one thing with no ioctl, so that part speaks netlink — the only
message this daemon builds by hand, and it puts the far end straight into the
target namespace by fd, because at that moment there is no process in it to name.

A container that names **no** network goes on the default bridge, which is what
docker does; before, it got a namespace with a loopback in it and no way to
reach anything at all. Names are **not** resolved there — also what docker does,
and the difference that makes creating a network worth doing. A container that
names a network which does not exist is refused by name rather than quietly
isolated.

Still outside: **outbound NAT**. It is not an omission that can be filled in here — the machine this daemon is built for has *no network interface
of its own*, so there is nothing to translate to; a container reaches the
outside through the proxy, which is the same path a build step uses. On a
machine that does have a network, `--network host` is the answer until this
speaks netfilter.

## ADD

`ADD` is `COPY` plus one thing: a local **archive** is unpacked into the
destination. Docker decides that by **content**, not by the name — a file
called `x.tar` that is not one is copied, and a file called `blob` that is a
gzipped tar is unpacked — so this reads the first bytes.

`bzip2` and `xz` are **refused by name**. Docker unpacks them, so copying them
would be a different Dockerfile with the same text: the image would contain an
archive where the build said a tree. A URL says it is a URL, rather than
arriving as "no such file in the build context", which sends the reader looking
for a file that was never meant to be there.

## The build cache

A step's layer is the upper directory of an overlay mount, so the cache **is**
that directory. A step that has run before is one whose upper directory is
already sitting there: using it copies nothing, unpacks nothing and re-runs
nothing — the next step simply mounts on top of it.

The key **chains**. Each step's key is a digest of the key before it and what
this step says, so changing a line invalidates it and everything after it and
nothing before it. `FROM` starts the chain at the base image, because the same
`RUN` on a different base is a different answer, and instructions that write no
layer (`ENV`, `WORKDIR`) still go in it — an `ENV` before a `RUN` is part of
that `RUN`'s answer.

**`COPY` and `ADD` are keyed on the bytes they copy.** The line does not change
when the file does, and a cache keyed on the line alone hands back the old file
forever: it says "Using cache", it is fast, and it is wrong. The gate poisons
exactly that and watches the image come back with the previous file in it.

`done` is written **last**. A directory without it is a step that was
interrupted, and the next build throws it away rather than believing it — a
half-finished layer reused is an image with a plausible, wrong filesystem.

Measured on a build with two two-second steps:

| | cold | warm |
|---|---|---|
| `docker build` | 4 s | 0 s, 3 of 3 steps cached |

The sleeps are the instrument: a cache that is not working still produces the
right image, so the only thing that can tell them apart is time.

## Compressed layers

A built layer is stored as a gzip member, which splits one digest into **two**:
`diff_ids` name the *uncompressed* layer — what a rootfs is built from, and
what two images share when they share a layer — while the blob is named by what
is actually on disk. One digest for both was correct exactly as long as nothing
was compressed.

The compressor is [mgz](https://github.com/284km/mgz), vendored. Pointing it at
a real layer is what found that it was emitting **stored blocks** on real input
while passing every correctness check it had; that story is in its README.

**A big layer is stored uncompressed.** Compressing costs about 27 times the
layer's size in memory while it runs, and this daemon is expected to fit inside
a small machine — an uncompressed layer is a legal one, and the build output
says which happened. Measured, not guessed.

The gate's first version found the built image by **grepping its layers** for a
string the build had written. That stopped working the moment layers were
compressed, and reported the image as having no layers at all: the instrument
broke, not the subject. It reads the store's index by tag now.

## docker exec and docker cp

Two things a person types all day, and the two that were missing.

**`docker exec`** is a second process inside a container that is already
running. The namespaces are named by the container's pid, and entering them is
what makes the process *be* inside: the mount namespace gives it the
container's filesystem, the pid namespace makes it a child of the container's
init, the network one gives it the container's address. The check asks for all
three — entering the mount namespace alone would pass "it printed the right
thing" while leaving the process in the host's process table and on the host's
network.

Two ordering rules in the shim. The output files are opened **before** entering
the mount namespace, because afterwards those paths mean something else
entirely. And the pid namespace only takes effect for a **child**, so there is
a second fork after `setns` — without it the process runs in the container's
filesystem while still being outside its process table.

The argv arrives in a **file**, one argument per line: the FFI boundary carries
a string, not a list, and padding a command out to a fixed number of slots is
how one with five arguments silently becomes one with four.

Recording the container's pid only for containers with **published ports** —
which is how it was — made exec answer "container is not running" about a
container that was.

**No TTY and no stdin**, said here rather than discovered. `docker exec -it`
wants a pty in the container and a bidirectional stream; it is refused by name.

**`docker cp`** is tar out and tar in, which this already had in both
directions, plus the path checking that keeps the destination inside. It works
on a stopped container, because the rootfs is still there — that is not a
shortcut, it is what docker does.

The archive is named relative to the **parent**: `docker cp c:/d /tmp/x`
expects entries called `d/...`, because the client renames that one top-level
name. An archive of the directory's *contents* unpacks into nothing the client
can find — which is exactly what happened, with no error anywhere. The oracle
is the real docker: the same directory, copied out of both, has to arrive in
the same shape.

## docker push

The pull client, backwards. A registry takes a blob at
`POST /v2/<name>/blobs/uploads/?digest=<d>` with the whole thing as the body —
the monolithic form, which needs no state on either side — and then the
manifest at `PUT /v2/<name>/manifests/<ref>`.

The manifest is a **description of blobs that are already there**: media type,
size and digest for the config and for each layer. It is written from what is
on disk rather than kept from a pull, because an image that was *built* was
never described by anybody.

**A blob that is already there is not sent again.** That is the whole economy
of a registry — the same layer under a hundred images is stored once — and a
push that uploads it anyway is correct and wasteful.

**What the registry is told a blob is** comes from reading the blob, not from
remembering: a layer this daemon compressed and one it carried across from a
pull are both here, and they are different media types.

The oracle is the strongest one available: the **real docker** pulls back what
this pushed, and runs it. Every part in between — the uploads, the manifest,
the media types — has to be right for that to work, and none of it is checked
by looking at our own answers. Poisoned by claiming every blob is already in
the registry, the pull fails and the container never runs.

The image name has slashes in it, so on this route the **verb is the last
segment** and the name is everything before it — the other way round from the
container routes, where the id has none.

## What an application found

Every check in this repository asks whether one thing works. `mvm/test/app.sh`
asks the question the project exists to answer: can somebody put a small
application on this and use it? One story, in the order a person would — build
a service from a Dockerfile, two services talking by name, a named volume, a
published port reached from macOS, `exec` to look inside, `cp` to take
something out, `down` and nothing left behind.

Nothing in it was new. It found four defects anyway, and every one of them is
a feature that works alone and breaks in company:

**A key is not a substring.** `query_param q "t"` found the `t=` inside
`target=`, which `docker compose build` also sends — so the image came out
untagged, the build said "Successfully built" with no "Successfully tagged"
after it, and compose failed with "No such image" about the image it had just
built. Nothing in the build was wrong.

**The build context can arrive compressed.** `docker build` sends a plain tar
and `docker compose build` sends a gzipped one — the same route, the same
headers, a different body. The reader said "a partial final block (214 bytes,
expected 512)" about a context that was perfectly good.

**`docker cp` read the mount point.** A bind mount or a volume covers a
directory of the rootfs, and the rootfs copy of it is empty. Copying out of a
volume found nothing, for a file the container could see.

**A list that ignores the filter hands the client everything.** `docker compose
down` lists volumes and networks and removes what comes back. Containers were
filtered from the start; networks and volumes were not — so `down` deleted
another project's volume and then tried to delete the default bridge. It is
refused now, the way docker refuses to remove a pre-defined network, and the
lists honour the label filter.

## Healthchecks and restart policies

Two more things a compose file says that were read by nothing.

**A container says whether it is well by answering a command inside itself**,
which is `exec` with a schedule. Compose waits on it — `depends_on: condition:
service_healthy` is how a file says *not until the database is up* — and a
daemon that ignores it makes that wait fail with "container has no healthcheck
configured" about a container that has one.

Three states, and they are not opinions: `starting` until it first answers,
`healthy` when it does, `unhealthy` after `retries` **consecutive** failures.
The streak is the whole difference — one failed probe on a busy machine is not
an unwell container. A container with **no** healthcheck reports no health at
all, which is the mirror of the same bug: a client that sees a health state
believes there is a probe behind it.

**`restart: unless-stopped`** is a container that comes back when it falls
over, and it was a container that exited once and stayed exited. `always` and
`unless-stopped` differ on exactly one thing — whether a container the *user*
stopped comes back — so stopping records that it was asked for. Without that
record the two policies are the same policy.

A container that dies instantly would spin the supervisor as fast as the
machine can fork, so each turn waits a second first.

**The instrument was wrong before the feature was.** The first measurement
counted lines in the container's log and got "1" however many times it had run
— the log is truncated on each start. Counted through a bind mount, the same
container had run four times. A feature that looks broken is sometimes a
question asked through a broken instrument.

## A cgroup of its own

A container in the daemon's cgroup cannot be limited, cannot be measured and
cannot be frozen. Those are not three features — they are **one missing
directory**, and mrun makes it now: `mengd/<id>` under `/sys/fs/cgroup`, with
`memory.max`, `pids.max` and `cpu.max` from what the client asked for, joined
before the cgroup namespace is unshared (afterwards the path that would have to
be written is not the path that can be seen).

**A child only has the controllers its parent delegates.** A new cgroup gets
`cgroup.freeze` and `cgroup.procs` whatever happens, but `memory.max` exists
only if the parent lists `memory` in its `cgroup.subtree_control`. Without
that the cgroup was made, freezing worked, and every limit was *silently
absent* — the files were not there to write.

On top of it: `docker stats` (usage, limit, pids), `docker pause` / `unpause`
(`cgroup.freeze`), and `mem_limit` / `pids_limit` from a compose file actually
bounding the container.

**A file whose size is a lie.** Everything under `/sys/fs/cgroup` reports
`st_size` 0 and then hands over bytes when read, so a reader that asks how big
a file is and then reads that many gets nothing. `docker stats` reported zero
memory and zero pids from files that were right there with the numbers in them.

## Removing things, and one row per image and tag

`docker rmi`, `docker container prune`, `docker volume prune`, `docker network
prune`, `docker rename`, `docker top`.

`/containers/prune` used to fall into the `/containers/{id}` table and answer
**"No such container: prune"** — which reads like the client asked for
something silly and was the route being wrong.

Removing a tag removes a row. The **directory** goes only when no other tag
points at it: two tags on one image are one image. And loading an image that is
already present under a *different* tag now adds the tag — the check was on the
digest alone, so after `docker rmi alpine:latest` on a machine where another
tag pointed at the same content, loading it again reported success and the tag
never came back.

**`cwrite` cannot raise.** A container can be removed while something is still
watching it — the supervisor waiting on its process, the health loop between
two probes — and `write_file` into a directory that has gone raises, which in
Mere ends the **daemon** rather than the write. `docker container prune` beside
a running check was enough to find it. It is the same shape as `read_file_or`,
on the other side.

## IPv6

A container on a user network gets a v6 address as well, from a unique-local
prefix per network: `fd00:<n>::/64`, and **the same last number as its v4
address** — one lease, two addresses, so a container's two addresses can never
disagree about which container it is.

Unique-local because there is nothing upstream to be global for. What this buys
is containers reaching each other over v6; outbound is outbound, and that is
the same missing interface as for v4.

Neither the address nor the route can be an ioctl — `SIOCSIFADDR` is an IPv4
interface and there is no v6 equivalent — so both are netlink, which this
daemon already speaks for the veth pair.

**Duplicate address detection is turned off on these interfaces, deliberately.**
A fresh v6 address is *tentative* for about a second, and a socket bound to a
tentative address fails with `EADDRNOTAVAIL`. A container that connects the
moment it starts — which is what a compose service does — would lose that race
*sometimes*, which is worse than always. Both ends of the veth pair are made
here and nobody else can hold the address, so detection has nothing to find.

A kernel built without IPv6 is a smaller machine, not a broken one: the v6 part
says so and the rest still works.
