# HTTP/2 Implementation Roadmap

## Target and Working Rules

The initial target is a production-quality HTTP/2 client in this shard, with a
role-neutral frame and connection core where practical. Server mode, HTTP/1.1
upgrade (`h2c`), server push consumption, and RFC 9218 priorities are follow-up
features. TLS with ALPN and explicit cleartext prior knowledge are in scope.

Complete each phase and its gate before starting the next. Keep the suite green
between phases and add tests with each behavior, not in a final test-only pass.
Use [RFC 9113](https://www.rfc-editor.org/rfc/rfc9113.html) and
[RFC 7541](https://www.rfc-editor.org/rfc/rfc7541.html) as normative sources.

The current repository is a frame-oriented spike, not a usable client. Its
connection and stream types are partial, `HTTP2::Client` exists only in specs,
and several handlers are empty or mix wire parsing with protocol state. Treat
existing code as material to test and refactor, not as established behavior.

Maintain these invariants throughout:

- Frames are passive wire values; the connection owns protocol state.
- Each connection has one persistent HPACK encoder and decoder.
- One reader fiber parses inbound frames; one ordered writer/scheduler owns
  outbound HPACK encoding, fragmentation, and transmission.
- An application callback never runs on or blocks the reader fiber.
- Queues, field blocks, bodies, and retained closed-stream state are bounded.
- Connection failure wakes every waiting stream and operation.

Use this minimum verification loop after each coherent change:

```sh
crystal tool format --check
./bin/ameba
crystal spec
crystal spec -Dpreview_mt
```

## Phase 0 — Baseline and Architecture

Establish a reproducible green baseline on supported Crystal versions. Pin or
select the improved adjacent HPACK version, repair current compile failures,
run `crystal tool format --check`, Ameba, and `crystal spec`, and replace live
internet specs with deterministic fixtures.

Document the public/client boundary and introduce internal interfaces for
transport, timeouts, event delivery, and test clocks where needed. Remove the
test-only `HTTP2::Client` fiction or replace it with an explicit future API
fixture. Capture known unsupported features in README rather than silently
accepting them.

**Gate:** clean build, formatter, linter, and deterministic specs on the chosen
minimum and current Crystal versions.

## Phase 1 — Frame Codec and Error Model

Make frame parsing a complete, context-free wire layer:

- Represent the nine-byte frame header separately and preserve unknown frame
  types so the connection can ignore them as required.
- Validate fixed lengths, known flags, stream-ID rules, padding, and payload
  shapes for every standard frame. Ignore unused flags and reserved bits on
  receipt, and leave them unset when sending.
- Bound payload allocation using the connection-supplied inbound maximum frame
  size before reading bytes.
- Preserve SETTINGS order, duplicates, and unknown identifiers; do not decode
  settings into a lossy hash.
- Introduce all RFC error codes plus typed violations carrying connection or
  stream scope. Do not leave an `error?` flag that callers can ignore.
- Remove debugging output and make serialization explicitly write to an `IO`.

Include round-trip tests, partial/truncated reads, every invalid length/flag
combination, unknown frames, and boundary frame sizes.

**Gate:** the codec can parse or serialize every standard frame without
creating streams, changing settings, or invoking HPACK.

## Phase 2 — Connection Runtime and Handshake

Build the concurrency and transport skeleton before adding HTTP semantics:

- Support a caller-supplied `IO`, TLS sockets with certificate verification,
  SNI and ALPN `h2`, plus explicit cleartext prior knowledge.
- Send the client preface immediately followed by client SETTINGS. Require the
  server's first frame to be non-ACK SETTINGS.
- Add a single continuous reader loop and a single serialized writer queue.
  Allow atomic multi-frame batches for later HEADERS/CONTINUATION output.
- Allocate client stream IDs as odd numbers increasing by two; detect
  exhaustion and prevent stream 0 from entering the stream map.
- Implement connection lifecycle, idempotent close, write failure propagation,
  bounded queues, and safe stream registration/removal.
- Dispatch connection-level SETTINGS, PING, GOAWAY, and WINDOW_UPDATE without
  routing them through a synthetic stream.

Use scripted peers over local socket pairs and a local TLS fixture. Test bad
prefaces, bad first frames, unknown frames, EOF, concurrent senders, and
failure fan-out.

**Gate:** a local peer can complete the handshake and exchange
SETTINGS/ACK/PING while all bytes pass through the ordered writer.

## Phase 3 — SETTINGS, HPACK, and Field Blocks

This phase depends on both
[HPACK additions](./hpack-additions.md).

- Maintain separate local and peer SETTINGS values, validate each setting,
  ignore unknown identifiers, track acknowledgements, and apply changes at the
  RFC-defined point. Add a SETTINGS acknowledgement timeout.
- Keep exactly one encoder and one decoder per connection. Connect peer
  `SETTINGS_HEADER_TABLE_SIZE` changes to the new encoder resize API.
- Assemble HEADERS or PUSH_PROMISE followed by a contiguous CONTINUATION
  sequence before decoding. Reject interleaving and wrong stream IDs.
- On output, HPACK-encode once, split at the peer's maximum frame size, and
  enqueue the entire HEADERS/CONTINUATION sequence atomically.
- Use ordered incremental HPACK output to validate and budget decoded fields.
  Continue decompression after rejecting a section so dynamic state remains
  synchronized. Map HPACK corruption and resource-limit outcomes separately.
- Enforce compressed-block and decompressed-field-section resource limits.

**Gate:** sequential blocks can reference dynamic entries; table-size
reductions work on the wire; fragmented blocks survive every split boundary;
and malformed/interleaved continuation sequences produce the correct error.

## Phase 4 — Stream State and Control Frames

Implement the RFC stream state machine as an explicit transition table for
idle, reserved, open, half-closed, and closed states.

- Validate every inbound and outbound frame against both connection and stream
  state, including stream-ID ordering and recently closed streams.
- Enforce peer `MAX_CONCURRENT_STREAMS`; queue or reject new requests without
  blocking the reader.
- Implement RST_STREAM, GOAWAY, PING, and cancellation completely. Track the
  last processed stream for GOAWAY and distinguish stream errors from
  connection errors.
- Advertise push disabled by default and reject PUSH_PROMISE correctly.
- Parse and validate legacy priority fields without making correctness depend
  on the deprecated priority tree.

Use table-driven transition tests and race tests for reset, remote END_STREAM,
local cancellation, GOAWAY, and frames arriving after close.

**Gate:** every standard frame has a defined action in every stream state,
including cases the RFC says to ignore, and every protocol violation has the
correct RST_STREAM or GOAWAY scope and error code.

## Phase 5 — Flow Control and Streaming DATA

Implement connection and stream flow control independently:

- Track receive and send windows with signed wide integers so legal negative
  stream send windows after `INITIAL_WINDOW_SIZE` changes are representable.
- Charge only DATA payload octets, including padding and pad length, as the RFC
  requires. Validate zero increments and 31-bit overflow.
- Split outbound DATA by both peer maximum frame size and available connection
  and stream credit. Use fair scheduling; control frames must not wait behind a
  blocked body.
- Deliver response bodies through a bounded per-stream pipe/reader. Replenish
  receive credit when the application consumes bytes, not merely when the
  network reader receives them.
- Stream request bodies from an `IO` or producer, support half-close and
  cancellation, and never rewind or overwrite previously received data.

Test tiny windows, padding, window shrink/growth, blocked writers, concurrent
large bodies, slow consumers, reset while blocked, and exact END_STREAM
placement.

**Gate:** multiple concurrent uploads and downloads complete with small windows
and bounded memory, without deadlock or starvation.

## Phase 6 — HTTP Semantics and Public Client API

Build HTTP request/response behavior above the protocol engine:

- Define a stable request API and a response containing status, ordered
  headers, informational responses, streaming body, and trailers.
- Generate `:method`, `:scheme`, `:authority`, and `:path` correctly, including
  CONNECT rules. Require one valid response `:status`.
- Enforce lowercase names, pseudo-header order/context/uniqueness, forbidden
  connection-specific fields, `te: trailers`, and content-length consistency.
- Handle HEAD, 1xx, 204, 304, trailers, early response completion, and request
  bodies without buffering them in full.
- Expose connect/read/write/idle timeouts and cancellation. Make TLS trust,
  hostname verification, and ALPN failures explicit.
- Add safe connection reuse per origin. Redirects, cookies, and content
  decompression remain higher-level policy unless deliberately added.

**Gate:** deterministic local tests cover GET, streaming POST, concurrent
requests, informational responses, trailers, CONNECT validation, malformed
field sections, and cancellation.

## Phase 7 — Shutdown, Recovery, and Hardening

Finish behaviors that distinguish a usable client from a demo:

- Gracefully drain after GOAWAY and refuse new streams on a draining
  connection. Retry only requests proven unprocessed and allowed by an
  explicit replay policy.
- Send graceful local GOAWAY, then enforce a drain deadline. Wake all waiters
  on EOF, TLS error, protocol error, timeout, or application close.
- Add configurable limits for open streams, queued writes, compressed field
  bytes, decoded fields/bytes, buffered body bytes, continuation count, and
  retained closed-stream metadata.
- Add optional keepalive PING with sane abuse controls. Rate-limit or reject
  pathological empty/control-frame traffic.
- Provide structured diagnostics for frame direction/type, connection errors,
  stream errors, and settings without logging secrets or field values by
  default.

**Gate:** adversarial tests demonstrate bounded memory, no leaked fibers, no
stranded futures/channels, safe GOAWAY retry decisions, and deterministic
shutdown under injected I/O failures.

## Phase 8 — Interoperability and Release

Run a release matrix against an independent local implementation such as
nghttp2, including TLS ALPN, fragmentation, flow control, trailers, resets,
GOAWAY, and concurrent streams. Keep those tests hermetic in CI; public-network
tests may exist only as an opt-in diagnostic.

Add property/fuzz coverage for frame parsing and HPACK-block fragmentation.
Run normal and `-Dpreview_mt` builds, formatter, Ameba, and supported Crystal
versions in CI. Update README with architecture, API examples, limitations,
timeouts, TLS behavior, and cancellation. Add changelog and semantic-versioning
policy, then publish a release candidate before `1.0`.

**Definition of done:** all phase gates pass; no empty frame handlers or debug
prints remain; all peer input is bounded and validated; the public API is
documented; and independent interoperability tests are green.

## Deferred Extensions

After the client core is stable, consider RFC 9218 priority scheduling, server
push consumption, ALTSVC/ORIGIN, extended CONNECT, and a server role. A gRPC
adapter should remain a separate layer, but the core must already expose the
streaming request/response bodies, trailers, cancellation, PING, RST_STREAM,
and GOAWAY behavior it needs.

See [deferred-extensions.md](./deferred-extensions.md) for the scope,
dependencies, and suggested priority of each follow-up project.
