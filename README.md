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

## It runs containers

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

Known gaps: stdout and stderr both go to one log file, so every log frame is
tagged stdout; there is no cgroup accounting, no `--rm`, no ports, and no
networking beyond the namespace mrun creates.
