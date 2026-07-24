[![CI](https://github.com/wyhaines/http2.cr/actions/workflows/ci.yml/badge.svg)](https://github.com/wyhaines/http2.cr/actions/workflows/ci.yml)
[![GitHub release](https://img.shields.io/github/release/wyhaines/http2.cr.svg)](https://github.com/wyhaines/http2.cr/releases)

# http2.cr

`http2.cr` is a pure Crystal implementation of HTTP/2. The project is being
rebuilt from an earlier frame-codec spike into a production-quality client with
a reusable protocol core.

## Status

The current code is not ready for production use. Its frame codec, transport
runtime, SETTINGS state, persistent inbound and outbound HPACK contexts, and
bounded field-block processing are covered. Stream state, concurrency limits,
reset and cancellation behavior, GOAWAY, PING, and push-disabled operation are
also implemented. Independent connection/stream flow control, fair streaming
DATA output, and bounded response body readers are implemented. The public
origin-bound client now validates HTTP/2 messages and supports concurrent
requests, streaming request and response bodies, informational responses,
trailers, timeouts, and cancellation. Graceful GOAWAY draining, opt-in safe
replay, keepalive, bounded abuse controls, and structured diagnostics are also
implemented. Independent interoperability and release hardening remain.

Development is organized in ordered phases:

- [Implementation roadmap](design/http2-implementation-roadmap.md)
- [Architecture decisions](design/architecture.md)
- [Current implementation status](design/implementation-status.md)

## Installation

Add the shard to your application's `shard.yml`:

```yaml
dependencies:
  http2:
    github: wyhaines/http2.cr
```

Then run `shards install`.

## Client Usage

Create one client per origin; it safely reuses that origin's HTTP/2 connection.
Field names must already be lowercase. `HTTP2::Headers` preserves insertion
order and repeated names.

```crystal
require "http2"

client = HTTP2::Client.new(
  "https://example.com",
  replay_policy: HTTP2::Client::ReplayPolicy::Idempotent,
  timeouts: HTTP2::Client::Timeouts.new(
    connect: 5.seconds,
    read: 30.seconds,
    write: 30.seconds,
    idle: 30.seconds
  )
)

begin
  response = client.get(
    "/items",
    HTTP2::Headers{"accept" => "application/json"}
  )
  puts response.status
  puts response.body.gets_to_end
  pp response.trailers
ensure
  client.graceful_close
end
```

Pass an `IO` as a request body to stream it from its current position. A
`Cancellation` can be shared with `#get`, `#post`, or `#request`; canceling it
resets only that request's stream. Cleartext `http` origins use explicit HTTP/2
prior knowledge. HTTPS verifies the certificate and hostname and requires ALPN
`h2` by default. For ordinary CONNECT, a supplied `IO` is treated as tunnel
data and is not read until the peer returns a successful response; either
tunnel direction can then close independently.

Automatic replay is disabled by default. `Idempotent` or `AnyRequest` retries
only a request proven unprocessed by GOAWAY or `REFUSED_STREAM`, up to
`max_replay_attempts`. Nil, String, and Bytes bodies can be reproduced;
caller-owned streaming `IO` is never replayed.

`Client#graceful_close` sends GOAWAY and waits for established streams until
`Connection::Configuration#drain_timeout`; `#close` remains an immediate,
idempotent cancellation. Connection configuration also bounds open streams,
queued work, field sections, buffered bodies, control/empty-frame rates, and
retained closed-stream state. Optional keepalive is enabled with
`keepalive_interval`.

Advanced users can consume `Connection#diagnostics`, a bounded channel of
frame metadata, settings, lifecycle changes, and typed errors. Diagnostics
exclude HTTP field values and GOAWAY debug data; check
`#dropped_diagnostic_count` when the consumer is slower than the connection.

Redirects, cookies, content decompression, and cross-origin connection
coalescing are intentionally not client policy in this shard.

## Development

Install dependencies and build Ameba:

```sh
shards install
shards build ameba -Dpreview_mt
```

Run the verification suite:

```sh
crystal tool format --check
bin/ameba
crystal spec -t -s
crystal spec -Dpreview_mt -t -s
crystal build src/http2.cr
```

Tests must be hermetic. Do not add public-network dependencies to the default
spec suite; use supplied `IO` objects, scripted peers, or local TLS fixtures.

See [AGENTS.md](AGENTS.md) for contributor conventions.
