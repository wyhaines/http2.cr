[![CI](https://github.com/wyhaines/http2.cr/actions/workflows/ci.yml/badge.svg)](https://github.com/wyhaines/http2.cr/actions/workflows/ci.yml)
[![GitHub release](https://img.shields.io/github/release/wyhaines/http2.cr.svg)](https://github.com/wyhaines/http2.cr/releases)

# http2.cr

`http2.cr` is a pure Crystal implementation of HTTP/2. The project is being
rebuilt from an earlier frame-codec spike into a production-quality client with
a reusable protocol core.

## Status

The source tree is prepared as `1.0.0-rc.1`, the first release candidate for
the rebuilt client. All implementation phases are complete, including an
independent local nghttp2 matrix. The candidate is suitable for integration
testing; validate it under your workload before production deployment and
report API or protocol issues before the final 1.0 release.

Development is organized in ordered phases:

- [Implementation roadmap](design/http2-implementation-roadmap.md)
- [Architecture decisions](design/architecture.md)
- [Current implementation status](design/implementation-status.md)
- [Changelog](CHANGELOG.md)
- [Release and versioning policy](RELEASING.md)

## Architecture

One reader fiber parses and validates inbound frames. One ordered writer owns
outbound HPACK state, field-block fragmentation, and fair flow-controlled DATA
scheduling. Each connection has persistent HPACK contexts, bounded queues, and
bounded per-stream response storage. `HTTP2::Client` adds HTTP semantics,
timeouts, cancellation, safe origin reuse, and explicit replay policy above
that protocol core. See the [architecture document](design/architecture.md)
for ownership and shutdown details.

## Installation

Add the shard to your application's `shard.yml`:

```yaml
dependencies:
  http2:
    github: wyhaines/http2.cr
    version: 1.0.0-rc.1
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
resets only that request's stream:

```crystal
cancellation = HTTP2::Cancellation.new
upload = File.open("events.ndjson")
begin
  response = client.post(
    "/events",
    upload,
    HTTP2::Headers{"content-type" => "application/x-ndjson"},
    trailers: HTTP2::Headers{"x-upload-complete" => "true"},
    cancellation: cancellation
  )

  # Another fiber may call `cancellation.cancel`.
  IO.copy(response.body, STDOUT)
  pp response.trailers
ensure
  upload.close
end
```

String and Bytes bodies have a known length and are owned by the request.
Caller-supplied `IO` bodies stream once from their current position.

## Timeouts and TLS

Timeouts apply independently:

| Setting | Covers |
| --- | --- |
| `connect` | DNS lookup and TCP connection |
| `read` | The HTTP/2 handshake (waiting for the peer's SETTINGS after dialing) and each response-header wait |
| `write` | Transport writes. An upload blocked on HTTP/2 flow control is not covered; it ends via cancellation, response-side timeouts, or connection failure |
| `idle` | A blocked response-body read or trailer wait |

Nil disables one timeout. A request `Cancellation` remains active after
response headers arrive, so it can interrupt body and trailer waits.

There is no persistent socket-level read timeout, so an idle pooled
connection or a quiet long-lived stream (SSE, long-poll) is never killed
merely for going quiet between waits. Liveness on an already-established
connection is keepalive's job instead: `HTTP2::Client` enables it by
default (`Connection::Configuration#keepalive_interval` 30 seconds,
`#keepalive_timeout` 10 seconds); pass a `connection_configuration:` with
`keepalive_interval: nil` to disable it.

Cleartext `http` origins use direct HTTP/2 prior knowledge; HTTP/1.1 `Upgrade`
is not attempted. HTTPS verifies the certificate and hostname, sends SNI, and
requires ALPN `h2`. Supply a configured `OpenSSL::SSL::Context::Client` to add
a private trust root or client certificate:

```crystal
tls = OpenSSL::SSL::Context::Client.new
tls.ca_certificates = "/etc/my-service/ca.pem"
client = HTTP2::Client.new("https://service.internal", tls_context: tls)
```

For ordinary CONNECT, a supplied `IO` is tunnel data and is not read until the
peer returns a successful response; either tunnel direction can then close
independently.

## Recovery and Diagnostics

Automatic replay is disabled by default. `Idempotent` or `AnyRequest` retries
only a request proven unprocessed by GOAWAY or `REFUSED_STREAM`, up to
`max_replay_attempts`. Nil, String, and Bytes bodies can be reproduced;
caller-owned streaming `IO` is never replayed.

`Client#graceful_close` sends GOAWAY and waits for established streams until
`Connection::Configuration#drain_timeout`; `#close` remains an immediate,
idempotent cancellation. Connection configuration also bounds open streams,
queued work, field sections, buffered bodies, control/empty-frame rates, and
retained closed-stream state. `HTTP2::Client` enables keepalive by default
(`keepalive_interval` 30 seconds, `keepalive_timeout` 10 seconds); supply a
`connection_configuration:` with `keepalive_interval: nil` to disable it.

Advanced users can consume `Connection#diagnostics`, a bounded channel of
frame metadata, settings, lifecycle changes, and typed errors. Diagnostics
exclude HTTP field values and GOAWAY debug data; check
`#dropped_diagnostic_count` when the consumer is slower than the connection.

## Limitations

The initial stable target is an HTTP/2 client. It does not provide:

- a server role, HTTP/1.1 fallback, or `h2c` upgrade;
- server-push consumption or RFC 9218 priority scheduling;
- extended CONNECT, ALTSVC/ORIGIN handling, or cross-origin coalescing;
- redirect, cookie, proxy, decompression, or retry policy beyond the explicit
  proven-unprocessed replay modes.
- Raw `Connection.connect_*`/`Connection.start` default to no transport
  timeouts and no keepalive; set `read_timeout:`/`write_timeout:` or
  `Configuration#keepalive_interval` when talking to untrusted peers.
  `HTTP2::Client` sets a write timeout by default and bounds the handshake
  and each response wait with `read`, but does not set a persistent
  `read_timeout` on the socket; it enables keepalive by default instead to
  detect a silent peer on an established connection.

A gRPC adapter belongs in a separate shard above the streaming API.
See [Deferred HTTP/2 Extensions](design/deferred-extensions.md) for the scope
and suggested priority of possible follow-up protocol work.

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

Deterministic property cases run with the ordinary specs. Increase their count
with `HTTP2_PROPERTY_CASES=5000 crystal spec spec/property_spec.cr`.

Install `nghttpd`, then run the independent local interoperability matrix:

```sh
spec/interop/run_nghttp2.sh
spec/interop/run_nghttp2.sh -Dpreview_mt
```

Tests must be hermetic. Do not add public-network dependencies to the default
spec suite; use supplied `IO` objects, scripted peers, or local TLS fixtures.

See [AGENTS.md](AGENTS.md) for contributor conventions.
