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

`--network host` shares the VM's network namespace, which is how a container can
be reached on a port at all: nothing builds a veth pair yet.

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

It is still linear: 34 MB per container, never returned, because the region
gives back only what its own block allocated and the inflate is a helper. The
remaining fix is to stop holding the whole layer at all — inflate straight into
the file behind a 32 KiB window — which is a change to the decompressor rather
than to this daemon.

```
after load:        17788 kB
after container 1: 42660 kB
after container 2: 77348 kB
...
after container 6: 212660 kB
```
