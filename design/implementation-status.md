# HTTP/2 Implementation Status

Last updated: 2026-07-24

## Phase Progress

| Phase | Status | Gate |
| --- | --- | --- |
| 0 — Baseline and architecture | Complete | Gate passed on Crystal 1.20.0 and 1.21.0 |
| 1 — Frame codec and errors | Complete | Gate passed on Crystal 1.20.0 and 1.21.0 |
| 2 — Connection and handshake | Complete | Gate passed on Crystal 1.20.0 and 1.21.0 |
| 3 — SETTINGS, HPACK, field blocks | Complete | Gate passed on Crystal 1.20.0 and 1.21.0 |
| 4 — Stream state and control frames | Complete | Gate passed on Crystal 1.20.0 and 1.21.0 |
| 5 — Flow control and streaming DATA | Complete | Gate passed on Crystal 1.20.0 and 1.21.0 |
| 6 — HTTP semantics and public client API | Complete | Gate passed on Crystal 1.20.0 and 1.21.0 |
| 7 — Shutdown, recovery, and hardening | Complete | Gate passed on Crystal 1.20.0 and 1.21.0 |
| 8 — Interoperability and release | Complete locally | Gate passed on Crystal 1.20.0 and 1.21.0; RC publication pending |

## Phase 0 Baseline

The initial suite did not compile because `spec/spec_helper.cr` defined a
test-only client with an invalid nilable DATA payload. Two specs opened public
network connections to `www.nghttp2.org`. Dependency resolution selected
HPACK 1.0.0 and Ameba 1.0.1; the latter does not compile on modern Crystal.
Formatting failed in six source files, and the newer linter exposed existing
debug calls and duplicate methods.

Phase 0 has:

- initially pinned an improved HPACK commit, superseded by HPACK 1.3.0 in
  Phase 3;
- pinned the Crystal 1.21-compatible Ameba 1.7 development snapshot;
- selected Crystal 1.20.0 as the minimum supported compiler and added a
  1.20/1.21 CI matrix;
- removed the test-only client and public-network specs;
- replaced the connection test with a supplied-IO preface test;
- removed unused global `Int` and `HTTP::Headers` monkey patches;
- moved `VERSION` into `HTTP2::VERSION`;
- removed compile-time/runtime debug output and restored formatting/lint;
- fixed DATA construction from an `IO` to retain owned payload bytes.

## Phase 1 Frame Codec

The frame layer now:

- parses and writes the separate nine-octet `FrameHeader`;
- checks the connection-supplied inbound frame-size limit before allocating a
  payload;
- preserves unknown frame types while ignoring reserved bits and unused flags;
- validates every RFC 9113 frame's stream ID, fixed fields, and padding shape;
- raises typed violations with an RFC error code and connection or stream
  scope instead of returning an ignorable `error?` value;
- preserves ordered, duplicate, and unknown SETTINGS entries;
- treats HEADERS, PUSH_PROMISE, and CONTINUATION payloads as opaque field-block
  fragments without invoking HPACK.

ALTSVC is deliberately handled as an unknown extension frame until extension
support is added.

## Phase 2 Connection Runtime

The runtime now:

- starts over caller-supplied duplex `IO`, explicit cleartext prior knowledge,
  or verified TLS with hostname validation, SNI, and required ALPN `h2`;
- sends the client preface and initial SETTINGS as one ordered command, then
  requires a non-ACK server SETTINGS frame before becoming active;
- owns one continuous reader fiber and one bounded, serialized writer with
  atomic multi-frame batches;
- allocates odd client stream IDs monotonically, rejects stream 0, and routes
  frames only to explicitly registered streams through bounded mailboxes;
- handles SETTINGS acknowledgements, PING replies, unknown frames, and GOAWAY
  draining at connection scope;
- maps codec errors to GOAWAY or RST_STREAM by scope and fans EOF, write
  failures, queue exhaustion, and close to all stream waiters;
- performs transport shutdown on its owning scheduler and waits for the reader
  and writer fibers to exit.

Local scripted peers and a checked-in certificate fixture cover cleartext and
TLS handshakes, ALPN and hostname failures, concurrent writers, stream routing,
GOAWAY, malformed frames, EOF, and failure propagation.

## Phase 3 SETTINGS, HPACK, and Field Blocks

Phase 3 now:

- pins `hpack.cr` 1.3.0 and keeps one encoder and decoder per connection;
- validates the six RFC 9113 settings, preserves ordered duplicate handling,
  ignores unsupported identifiers, and keeps peer, advertised-local, and
  acknowledged-local values separate;
- matches SETTINGS acknowledgements in FIFO order, applies local decoder limits
  on ACK, and closes with `SETTINGS_TIMEOUT` when the oldest sent update expires;
- applies peer compression-table limits on the writer immediately before its
  SETTINGS ACK, including coalesced HPACK table-size updates;
- reassembles contiguous HEADERS/PUSH_PROMISE and CONTINUATION sequences with
  compressed-size and continuation-count bounds;
- encodes ordered outbound fields once on the writer, retains dynamic-table
  state across blocks, fragments at the peer frame-size setting, and writes the
  complete sequence atomically;
- incrementally decodes inbound blocks into ordered `FieldSection` events,
  preserving indexing metadata without exposing HPACK types;
- advertises and enforces a decoded field-section budget plus a hard
  decoded-string cap while keeping retained output bounded;
- fully decompresses over-budget sections before resetting their streams, so
  later blocks can reference dynamic entries inserted by discarded sections;
- maps malformed HPACK to connection `COMPRESSION_ERROR`, aggregate decoded
  limits to stream `ENHANCE_YOUR_CALM`, and hard decoder resource limits to
  connection shutdown.

## Phase 4 Stream State and Control Frames

Phase 4 now:

- defines an exhaustive transition table for every stream-associated frame in
  idle, reserved, open, half-closed, and closed states;
- validates inbound and writer-ordered outbound transitions atomically,
  preserving the correct stream or connection error scope;
- tracks stream-ID ordering, active streams, and bounded recently closed
  metadata, including legal late-frame handling;
- enforces peer `MAX_CONCURRENT_STREAMS` while leaving rejected idle streams
  available for a later attempt;
- implements terminal peer resets, local cancellation, PING acknowledgements
  and timeouts, and reset/cancellation race handling;
- validates sent and received GOAWAY sequences, enters draining state, and
  distinguishes unprocessed streams from other terminal failures;
- advertises push disabled, rejects push after acknowledgement, and cancels
  legal promises received before acknowledgement;
- accepts deprecated PRIORITY frames without creating streams or depending on
  a priority tree.

## Phase 5 Flow Control and Streaming DATA

Phase 5 now:

- keeps independent signed 64-bit connection and stream send/receive windows,
  including legal negative send windows after initial-window reductions;
- applies SETTINGS initial-window deltas to live streams and rejects connection
  or stream window overflow with the required `FLOW_CONTROL_ERROR` scope;
- charges the complete DATA payload, including Pad Length and padding, while
  leaving all control and field-block frames outside flow control;
- schedules outbound DATA round-robin across streams, fragments it by frame and
  window limits, and lets control work bypass flow-blocked bodies;
- exposes bounded per-stream response body readers and returns receive credit
  only when application bytes are consumed (or discarded);
- streams request DATA from buffers or the current position of an `IO`, places
  `END_STREAM` exactly, and wakes blocked writers on reset or cancellation.

Deterministic tests cover tiny and negative windows, padded DATA, receive and
send overflow, slow consumers, concurrent uploads/downloads, IO sources,
control-frame progress, source failure, and reset while flow-blocked.

## Phase 6 HTTP Semantics and Public Client API

Phase 6 now:

- exposes an origin-bound `HTTP2::Client`, explicit request metadata, ordered
  duplicate-preserving headers, informational responses, streaming response
  bodies, and blocking trailer access;
- derives request pseudo-fields from the method, target, and origin, including
  ordinary CONNECT authority-form rules, tunnel I/O deferred until a successful
  response, independent tunnel half-closes, and same-origin checks for absolute
  targets;
- validates lowercase field names and values, pseudo-field ordering, context,
  and uniqueness, connection-specific fields, `te: trailers`, and duplicate
  content lengths before malformed data reaches application code;
- enforces response status and content rules for informational responses,
  HEAD, 204, 304, successful CONNECT, DATA, and trailers with stream-scoped
  `PROTOCOL_ERROR` resets;
- streams each available request `IO` chunk without rewinding or waiting for
  source EOF, verifies declared lengths, supports request trailers, and stops
  blocked uploads after complete early responses without discarding completed
  response content;
- exposes connect, read, write, and idle timeouts plus request cancellation,
  verified TLS/hostname errors, required ALPN, and safe concurrent connection
  reuse within one normalized origin.

Hermetic tests cover GET, streaming POST, concurrent requests, owned cleartext
dialing/reuse, informational responses, request and response trailers, CONNECT,
malformed field sections, content-length failures, no-content responses,
timeouts, cancellation, and early response completion.

## Phase 7 Shutdown, Recovery, and Hardening

Phase 7 now:

- sends local `GOAWAY(NO_ERROR)`, refuses new streams while draining, allows
  established streams to finish, and terminates deterministically at a
  configurable drain deadline;
- drains peer GOAWAY connections while selecting a fresh owned connection for
  new work, preserves provably unprocessed stream errors, validates successive
  GOAWAY frames, and reciprocates shutdown after a bounded inbound-quiet
  interval;
- provides opt-in `Never`, `Idempotent`, and `AnyRequest` replay policies with
  an attempt cap, retrying only GOAWAY-unprocessed or `REFUSED_STREAM`
  requests and never replaying caller-owned body IO;
- bounds registered streams, writer/data queues, outstanding SETTINGS and
  PING operations, compressed bytes, decoded field bytes/count, body buffers,
  CONTINUATION frames, and retained closed-stream metadata;
- supports optional inbound-idle keepalive PING with an acknowledgement
  timeout and bounds peer control/empty-frame rates with
  `ENHANCE_YOUR_CALM`;
- exposes a nonblocking bounded diagnostics channel for frame metadata,
  settings, lifecycle changes, and typed connection/stream errors without
  HTTP field values or GOAWAY debug data.

Adversarial tests cover graceful completion and forced drain, safe and refused
replay decisions, one-shot bodies, open-stream and pending-operation limits,
decoded-field-count HPACK synchronization, keepalive failure, control/empty
frame floods, diagnostics backpressure, EOF, and injected write failures.

## Phase 8 Interoperability and Release

Phase 8 now:

- provides an opt-in, public-network-free runner for independent nghttp2
  cleartext and TLS servers using a temporary document root and the checked-in
  certificate fixture;
- verifies TLS ALPN, padded frames, response trailers, a 256 KiB duplex echo
  under constrained flow-control windows, a fragmented 24 KiB request field,
  twelve concurrent streams, cancellation with RST_STREAM, follow-up reuse,
  and graceful GOAWAY;
- checks nghttp2's verbose trace to ensure the independent peer actually
  receives the expected RST_STREAM and GOAWAY frames;
- adds seeded property coverage for bounded arbitrary frame parsing,
  randomized truncation, and persistent HPACK encode/fragment/reassemble/decode
  cycles, with `HTTP2_PROPERTY_CASES` available for longer local runs;
- runs ordinary and nghttp2 suites in normal and `preview_mt` modes for every
  supported Crystal version in CI, including tag builds;
- documents architecture, client usage, streaming, cancellation, timeouts,
  TLS behavior, recovery, diagnostics, and current limitations;
- adds a changelog and SemVer/release policy and prepares version
  `1.0.0-rc.1`.

Publishing the `v1.0.0-rc.1` tag and GitHub release remains an explicit
maintainer action; no branch or tag has been pushed.

## Current Verification

Run from the repository root:

```sh
crystal tool format --check
bin/ameba
crystal spec -t -s
crystal spec -Dpreview_mt -t -s
spec/interop/run_nghttp2.sh
spec/interop/run_nghttp2.sh -Dpreview_mt
crystal build src/http2.cr
crystal docs
```

The Phase 8 gate passes formatting, Ameba, compilation, documentation, 210
deterministic examples, and five independent nghttp2 examples in normal and
`preview_mt` modes in the official Crystal 1.20.0 and 1.21.0 containers.
An additional 5,000-case property stress run passes on Crystal 1.21.0.
nghttp2 1.59.0 was used for the local release matrix. The `preview_mt` flag
emits its expected deprecation warning on Crystal 1.21.

## Next Work

A maintainer can publish `v1.0.0-rc.1`, collect downstream feedback, and repeat
the documented release gate for any fixes. Publish final `1.0.0` only after the
release candidate has been exercised by downstream users.
