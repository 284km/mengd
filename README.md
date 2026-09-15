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

`docker version` and `docker info` both work. Three routes are implemented:
`/_ping`, `/version`, `/info`.

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

## What is next

The route the client asks for next. In order of what `docker compose up` needs:
`/images/*` (starting with `load`, so images can arrive without a registry),
then `/containers/*` and `/exec/*`, then `/networks/*`, `/volumes/*` and
`/events`. The container work itself goes to
[mrun](https://github.com/284km/mrun).
