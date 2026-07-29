[![CI](https://github.com/wyhaines/http2.cr/actions/workflows/ci.yml/badge.svg)](https://github.com/wyhaines/http2.cr/actions/workflows/ci.yml)
[![GitHub release](https://img.shields.io/github/release/wyhaines/http2.cr.svg)](https://github.com/wyhaines/http2.cr/releases)

# http2.cr

`http2.cr` provides an origin-bound HTTP/2 client for Crystal. It supports
concurrent requests, streaming request and response bodies, connection reuse,
TLS, cancellation, timeouts, and request and response trailers. Its frame and
connection types can also be used independently.

## Status

Version `1.0.0-rc.1` is the first release candidate. All functionality planned
for 1.0 has been implemented and checked against `nghttp2` in local
interoperability tests. Test the candidate under your workload before
deploying it in production, and report API or protocol issues before the final
1.0 release.

## Installation

Add the shard to your application's `shard.yml`:

```yaml
dependencies:
  http2:
    github: wyhaines/http2.cr
    version: 1.0.0-rc.1
```

Then run `shards install`.

## Client usage

Create one client per origin. The client lazily reuses and scales a bounded
pool of HTTP/2 connections for that origin. Header names must be lowercase.
`HTTP2::Headers` preserves insertion order and repeated names.

Ordinary header fields may enter the connection's HPACK dynamic table, which
improves compression when they recur. The client marks `authorization`,
`proxy-authorization`, `cookie`, and `set-cookie` as never indexed. Use
`additional_never_indexed_fields:` for custom credential headers such as
`x-api-key`. The client keeps those fields out of the dynamic table too.

```crystal
require "http2"

client = HTTP2::Client.new(
  "https://example.com",
  replay_policy: HTTP2::Client::ReplayPolicy::Idempotent,
  pool_configuration: HTTP2::Client::PoolConfiguration.new(
    max_connections: 4
  ),
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

### Streaming request bodies and cancellation

Pass an `IO` as a request body to stream it from its current position. A
`Cancellation` can be shared with `#get`, `#post`, or `#request`. Canceling it
resets only that request's stream:

```crystal
cancellation = HTTP2::Cancellation.new
upload = File.open("events.ndjson")
begin
  response = client.post(
    "/events",
    HTTP2::Headers{"content-type" => "application/x-ndjson"},
    upload,
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

`String` and `Bytes` bodies have a known length and are owned by the request.
A caller-supplied `IO` body streams once from its current position. The caller
remains responsible for closing it.

## Timeouts

Timeouts apply independently:

| Setting | Covers |
| --- | --- |
| `connect` | DNS lookup and TCP connection |
| `read` | TLS and HTTP/2 handshakes, then each response-header wait |
| `write` | Writes to the transport |
| `idle` | Response-body reads, trailer waits, and abandoned responses |
| `stream_slot` | Pool-wide request-capacity acquisition (`nil` by default) |

Set an individual timeout to `nil` to disable it. A request `Cancellation`
remains active after response headers arrive and can interrupt body and trailer
waits.

For HTTPS, `read` covers the TLS handshake. For both HTTP and HTTPS, it also
covers the wait for the peer's SETTINGS after dialing and each response-header
wait.

The `write` timeout covers writes to the transport. It does not cover an upload
waiting for HTTP/2 flow-control credit. End such a wait through cancellation,
a response-side timeout, or connection failure.

### Connection liveness

`HTTP2::Client` does not apply a persistent socket-level read timeout. An idle
pooled connection or a quiet long-lived stream, such as SSE or long polling,
can remain open between active waits.

Keepalive checks established connections for liveness. The client uses a
30-second `keepalive_interval` and a 10-second `keepalive_timeout`. To disable
keepalive, pass a `connection_configuration:` with
`keepalive_interval: nil`.

### Connection pooling and concurrent-stream limits

The pool grows on demand. The first request opens one connection and subsequent
requests reuse it while it has capacity. If every eligible connection reaches
the peer's per-connection `MAX_CONCURRENT_STREAMS` limit or the configured
local open-stream limit, concurrent demand starts one shared expansion dial.
Requests assigned to different connections can open independently.

`PoolConfiguration` defaults to:

| Setting | Default | Meaning |
| --- | --- | --- |
| `max_connections` | `4` | Maximum eligible plus dialing connections |
| `max_idle_connections` | `2` | Idle eligible connections retained |
| `idle_timeout` | `90.seconds` | Maximum request-idle age |
| `max_retired_connections` | `4` | Draining connections retained |

Set `max_connections: 1` to disable saturation scale-out. Set it to `nil` for
no hard eligible-connection limit. Unlimited mode remains lazy, permits only
one expansion dial at a time, and still enforces the idle, retired, and
per-connection limits. Prefer a finite bound when request concurrency is
untrusted: every connection has its own socket, HPACK tables, flow-control
windows, queues, keepalive work, and stream registry.

With the default `stream_slot: nil`, the client still grows when it can, then
raises `Client::PoolSaturatedError` immediately when no connection can admit
the request and the pool cannot grow. A configured duration waits for capacity
on any connection, a shared expansion dial, or a peer SETTINGS increase. The
wait is generation-based rather than polled and does not hold a connection's
request-opening mutex. Cancellation and `Client#close` interrupt it.

Fresh connections that advertise zero request capacity still count toward a
finite maximum while the triggering acquisition is in progress. Idle
contraction cannot turn that finite probe into a dial-and-evict loop.

The pool reserves request capacity atomically before allocating a stream ID.
A waiting request does not preallocate a stream ID. If raw connection use wins
a later stream-ID race, the reservation is safely revalidated before HEADERS
are sent. Each connection retains its own ordered writer and request-opening
lock, preserving stream-ID and HPACK ordering without a client-wide
head-of-line block.

Connections receiving `GOAWAY`, exhausting local stream IDs, or closing are
removed from selection. Accepted streams may drain on a retired connection
while new requests use a replacement. This does not broaden replay: only work
proven unprocessed by GOAWAY or `REFUSED_STREAM` follows the configured replay
policy.

`PoolConfiguration#idle_timeout` controls connection retention. It is distinct
from `Timeouts#idle`, which protects response-body reads, trailer waits, and
abandoned responses. `Client#pool_state` exposes value-only eligible, idle,
retired, and dialing counts.

A client built with `connection:` is deliberately fixed to that connection. It
does not dial, reconnect, or evict it for idleness; passing an explicit
`pool_configuration:` with `connection:` raises `ArgumentError`.

### Abandoned responses

If a caller neither reads nor closes a `Response`, buffered body data may hold
stream and connection-window credit. This can stall other requests on the
connection. The `idle` timeout protects the connection once an unread body is
holding that credit.

If `idle` elapses while unread data is buffered and the caller has consumed no
bytes since the previous check, the client cancels the stream. It returns the
buffered-data credit, sends `RST_STREAM`, and records a terminal
`RequestTimeoutError` on the body. A later read raises that error.

Calling `Response#close` also makes a later read raise, rather than returning
a silent EOF. In that case the read raises a generic `IO::Error` with the
message `"Closed stream"` instead of the stream's terminal error.

Reading any data re-arms the deadline, so a slow reader can continue making
progress. A quiet stream with an empty buffer holds no receive-window credit
and can remain open indefinitely. This includes an SSE or long-poll response
between events and a successful CONNECT tunnel while the application uploads.
Set `idle: nil` to disable both abandoned-response protection and the
timeouts for body reads and trailers.

## TLS and CONNECT

Cleartext `http` origins use direct HTTP/2 prior knowledge. HTTP/1.1 `Upgrade`
is not attempted. HTTPS verifies the certificate and hostname, sends SNI, and
requires ALPN `h2`. Supply a configured `OpenSSL::SSL::Context::Client` to add
a private trust root or client certificate:

```crystal
tls = OpenSSL::SSL::Context::Client.new
tls.ca_certificates = "/etc/my-service/ca.pem"
client = HTTP2::Client.new("https://service.internal", tls_context: tls)
```

For a standard CONNECT request, a supplied `IO` contains tunnel data. The
client does not read it until the peer returns a successful response. Once the
tunnel is open, either direction can close independently.

## Recovery

Concurrent requests that need a new owned connection share one in-flight
dial, so a cold start or reconnect does not create a burst of redundant TCP
connections and TLS handshakes. If that connection terminates before the
request reserves a stream, the client makes one replacement attempt even when
automatic replay is disabled. This is safe because no HEADERS or body bytes
have been submitted yet.

Automatic replay is disabled by default. With an `Idempotent` or `AnyRequest`
replay policy, the client retries only requests identified as unprocessed by a
`GOAWAY` frame or `REFUSED_STREAM`. It makes no more than
`max_replay_attempts` replay attempts. Bodies represented by `nil`, `String`,
or `Bytes` can be reproduced. A caller-owned streaming `IO` is not replayed.

`Client#graceful_close` starts `GOAWAY` drains on every eligible and retired
connection concurrently and applies one shared
`Connection::Configuration#drain_timeout` deadline. `#close` cancels every
owned connection immediately. Both operations reject new requests at once and
are idempotent.

Connection configuration bounds open streams, queued work, field sections,
buffered bodies, control and empty-frame rates, and retained closed-stream
state. The connection-level receive window
(`Connection::Configuration#connection_receive_window`, default 1 MiB)
governs aggregate download throughput per round trip. Per-stream windows are
bounded separately by `max_buffered_body_bytes`.

## Diagnostics

`Connection#diagnostics` is a bounded channel that reports frame metadata,
settings, lifecycle changes, and typed errors. It excludes HTTP field values
and GOAWAY debug data. Check `#dropped_diagnostic_count` to determine whether
the consumer has fallen behind the connection.

Capture starts at the moment `#diagnostics` is first called, not at
connection start; call it before issuing any requests (you don't have to
start receiving from the returned channel right away) if you need events
from the very beginning, including the handshake.

## Architecture

Each connection uses one reader fiber to parse and validate inbound frames. A
single ordered writer manages outbound HPACK state, field-block fragmentation,
and fair scheduling of flow-controlled `DATA`. The connection retains its HPACK
contexts across requests and bounds its queues and per-stream response
storage.

`HTTP2::Client` adds HTTP semantics, timeouts, cancellation, an origin-bound
elastic connection pool, and replay policy to the protocol core. See the
[architecture document](design/architecture.md) for ownership and shutdown
details.

## Low-level connection API

Raw `Connection.connect_*`, `Connection.start`, and `Connection.start_tls`
calls do not inherit the client's defaults. By default, they add neither
transport timeouts nor keepalive. When dialing an untrusted peer, set
`read_timeout:` and `write_timeout:` as appropriate. For a supplied transport,
set the equivalent properties directly. You can also enable
keepalive with `Configuration#keepalive_interval`. TLS callers can set
`handshake_read_timeout:` on `connect_tls` and `start_tls`. `HTTP2::Client`
applies the timeout and liveness behavior described above.

## Limitations

Version 1.0 focuses on the HTTP/2 client. It does not provide:

- A server role, HTTP/1.1 fallback, or `h2c` upgrade.
- Server-push consumption or RFC 9218 priority scheduling.
- Extended CONNECT, `ALTSVC` or `ORIGIN` handling, or cross-origin coalescing.
- Redirect following, cookie management, proxy support, or decompression.
- Retry policies other than the modes that replay requests known to be
  unprocessed.

gRPC support is outside this shard's scope. It can be implemented in a
separate shard above the streaming API. See
[Deferred HTTP/2 Extensions](design/deferred-extensions.md) for the scope and
suggested priority of possible protocol additions.

## Project documents

- [Implementation roadmap](design/http2-implementation-roadmap.md)
- [Architecture decisions](design/architecture.md)
- [Current implementation status](design/implementation-status.md)
- [Changelog](CHANGELOG.md)
- [Release and versioning policy](RELEASING.md)

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

Deterministic property cases run with the standard specs. Increase their count
with `HTTP2_PROPERTY_CASES=5000 crystal spec spec/property_spec.cr`.

Install `nghttpd`, then run the local interoperability tests:

```sh
spec/interop/run_nghttp2.sh
spec/interop/run_nghttp2.sh -Dpreview_mt
```

Keep the default spec suite hermetic. Use supplied `IO` objects, scripted
peers, or local TLS fixtures instead of public-network dependencies.

See [AGENTS.md](AGENTS.md) for contributor conventions.
