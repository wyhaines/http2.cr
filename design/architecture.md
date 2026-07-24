# HTTP/2 Client Architecture

## Scope and Public Boundary

This shard will contain a production HTTP/2 client and a reusable,
role-neutral protocol core. The first stable API will be the client request and
streaming response surface. Frame and connection types remain available for
advanced use, but are experimental until `1.0`. HPACK types are an internal
implementation detail and must not leak into the client API.

Server mode, HTTP/1.1 upgrade, server-push consumption, and RFC 9218 priority
scheduling are deferred. TLS with certificate verification, SNI, and ALPN
`h2`, plus explicit cleartext prior knowledge, are required for the initial
client.

## Layers and Ownership

```text
Client / connection pool
        |
HTTP message validation and streaming API
        |
Connection engine ───── HPACK encoder and decoder
        |
Passive frame codec
        |
Transport IO (TCP, TLS, or a test double)
```

- `Frame` represents wire fields and performs context-free parsing and
  serialization. It never creates streams, changes settings, performs HPACK,
  or writes protocol responses.
- `Connection` owns the transport, settings, stream registry, stream-ID
  allocation, connection flow-control windows, HPACK contexts, reader/writer
  fibers, and terminal error.
- `Stream` owns its state-machine position, stream windows, bounded inbound
  events/body storage, response metadata, and cancellation state. It never
  reads from or writes directly to the socket.
- `Client` owns dialing, TLS policy, origin-based connection reuse, request
  policy, and the eventual public request API.

## Concurrency Model

Each connection has exactly one reader fiber and one writer/scheduler. The
reader continuously parses frames and performs bounded protocol dispatch. The
writer is the sole owner of outbound ordering, HPACK encoding, header
fragmentation, and wire writes. It accepts bounded commands, including atomic
frame batches for HEADERS/CONTINUATION sequences.

Application code never executes on the reader fiber. Phase 2 uses bounded,
nonblocking per-stream mailboxes; a full mailbox terminates the connection
instead of stalling its reader. Phase 5 will replace raw DATA delivery with
bounded body pipes whose consumption controls flow-control credit.

Transport shutdown runs in the connection's transport scheduler and joins both
protocol fibers. This keeps socket event-loop ownership consistent and makes a
cross-fiber close deterministic, including under legacy `preview_mt`.

## Transport and Testability

The engine accepts a supplied `IO`; convenience constructors perform cleartext
prior-knowledge dialing or verified TLS wrapping before starting the same wire
runtime. TLS requires SNI and ALPN `h2`. Specs use scripted duplex IO, loopback
sockets, and a local certificate fixture. Timeouts will use an injected
monotonic clock only where deterministic deadline tests require it.

The default suite must never require DNS or public internet access.

## Errors, Shutdown, and Limits

Frame parsing reports typed violations but does not choose RST_STREAM or
GOAWAY. The connection maps each violation using current connection and stream
state. A terminal connection result is stored once, closes outbound work, and
wakes every stream waiter.

Limits are explicit configuration: maximum inbound frame size, compressed and
decoded field-section sizes, concurrent streams, queued writes, buffered body
bytes, continuation fragments, and retained closed-stream metadata. No peer
input may cause unbounded allocation.

## Phase Boundaries

- Phase 1 changes only the passive frame codec and typed error vocabulary.
- Phase 2 provides transport lifecycle and SETTINGS/PING handshake mechanics
  without decoding field blocks.
- Phase 3 integrates persistent HPACK contexts, complete field blocks, and
  bounded decoded field sections.
