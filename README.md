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

## What is next

The route the client asks for next. `/images/{name}/json` for inspect, then
`/containers/*` and `/exec/*` so `docker run` works, then `/networks/*`,
`/volumes/*` and `/events` for `docker compose up`. The container work itself
goes to [mrun](https://github.com/284km/mrun).
