# Changelog

All notable changes are recorded here. This project follows
[Semantic Versioning](https://semver.org/).

## Unreleased

### Added

- Added a lazy, origin-bound elastic connection pool. It grows when every
  eligible connection is saturated, defaults to four eligible connections,
  retains at most two idle connections for 90 seconds, and supports
  `max_connections: nil` for no hard eligible-connection limit.
- Added atomic per-connection request-slot reservations, pool-wide capacity
  notifications, value-only `Client#pool_state`, and
  `Client::PoolSaturatedError`.
- Added bounded GOAWAY and stream-ID-exhaustion retirement, idle contraction,
  and concurrent multi-connection graceful shutdown under one shared
  deadline.
- Added `Client#put`, `#patch`, and `#delete`/`#options` convenience
  wrappers alongside the existing `#get`/`#head`/`#post`, each a thin
  wrapper over `#request`.

### Performance

This pass removes redundant payload copies and per-frame lock/allocation
overhead from the connection hot paths, and cuts per-request client
overhead, without changing wire behavior or public API semantics. No
benchmark harness exists in this repo, so these are described
qualitatively rather than with throughput numbers (the companion `hpack`
shard's own plan has measured figures); verification here was per-change
paired micro-verification during review, not an end-to-end benchmark.

- Eliminated copies on both the inbound and outbound DATA path: an
  unpadded inbound DATA frame's payload is handed to the stream body
  without duplicating it (padded frames are still duped so the buffer
  doesn't pin padding bytes), and an outbound DATA write no longer dups
  the caller's bytes before framing them — except under `-Dpreview_mt`,
  where a private copy is still taken at the chunk-submit site because
  the zero-copy path is only proven safe against a pinned, single-threaded
  runtime. HPACK field-block assembly and per-frame header/payload
  construction also lost a heap allocation and a copy each.
- Batched writer flushes so a WINDOW_UPDATE-only or mid-block DATA write
  can no longer sit unflushed behind a buffered transport; added a
  dedicated buffered-transport spec class (none of the existing specs use
  a genuinely buffered socket) that reproduces the starvation this fixes.
- Reduced per-frame lock and allocation overhead: diagnostics capture and
  keepalive bookkeeping are now gated off the hot frame path until first
  used, several per-stream and per-connection fields moved from
  mutex-guarded state to atomics (stream state, flow-control windows,
  write-completion flags), and DATA frame planning now takes one lock
  instead of several (closing a real TOCTOU in the process).
- Reduced per-request client overhead: the connection pool now
  reconciles only on an actual capacity change (tracking parked waiters
  precisely) instead of on every acquisition; response headers and
  trailers are parsed once instead of twice; a request is prepared in a
  single pass; owned request bodies (`String`/`Bytes`) are carried
  zero-copy end to end instead of being wrapped in a fresh `IO::Memory`;
  and the client's request-opening critical section is narrower.

### Fixed

- Fixed a write stall: flush batching could leave a WINDOW_UPDATE-only
  write, or a write in the middle of a DATA block, staged in a buffered
  transport without ever being flushed — parking the writer fiber with
  credit or payload bytes it had already accepted but never put on the
  wire. See the writer flush-batching entry under Performance for the
  batching change this fix landed alongside.
- `Response#trailers` (with no explicit timeout argument) no longer
  aborts a request whose response body is still being actively, if
  slowly, consumed — it now re-arms the same way the body-side idle
  timeout already did, instead of unconditionally resetting the stream
  once the idle timeout elapsed. An explicit `trailers(timeout)` call is
  unchanged: it still waits that exact deadline with no re-arming.
- Closed a `StreamBody#terminate`/finish race that could discard already
  buffered response data: a late `terminate` (for example a reset that
  arrives just after the body finished) now preserves data delivered
  before it finished instead of racily dropping it.
- A terminated stream's buffered inbound event queue is now drained and
  closed as part of `#terminate`, instead of merely being closed, so it
  can no longer pin queued frames in memory after the stream is done.
- Restored rejection of a bodyless request that carries a lying, non-zero
  `content-length` header. An earlier point in this branch's own history
  had dropped that check while reworking body-length tracking around a
  nilable `body_length`; it's caught here, net unchanged versus this
  shard's pre-existing behavior.
- A `CONNECT` request whose tunnel body is an owned `String`/`Bytes`
  value (rather than a caller-supplied `IO`) now actually uploads that
  body; the zero-copy owned-body change above had an intermediate state
  where it silently skipped the upload for this combination.

### Changed

- `Connection#diagnostics` now only starts capturing frame, error, and
  lifecycle events at the moment it is first called, instead of always
  capturing from connection start. If you call `#diagnostics` after
  traffic is already flowing, you will no longer see any events from
  before that call — previously, up to `diagnostic_queue_capacity` of
  those earlier events could still be sitting in the channel, waiting to
  be received, even though `#diagnostics` hadn't been called yet. If you
  need diagnostics from the very start of a connection (for example, to
  capture the handshake), call `#diagnostics` before issuing any requests
  on it; you don't have to start receiving from the returned channel
  right away for capture to begin, only the call itself needs to happen
  early.
- `Request#body_length` is now `nil` (rather than a stale or synthesized
  value) whenever the request has no body.
- `Connection#write_batch`'s validation now raises on the first invalid
  frame in array order. Previously, a batch containing more than one
  kind of invalid frame always raised in a fixed category-priority order
  regardless of where each frame appeared; no shipped caller constructs
  a batch mixing invalid-frame categories, so this is not expected to be
  observable in practice, but it is documented as the batch's real
  contract now.
- `Timeouts#stream_slot` now covers pool-wide acquisition, including shared
  expansion dialing and SETTINGS capacity changes. Saturation at the pool
  boundary raises `Client::PoolSaturatedError`.
- Removed client-wide request-opening serialization. Each pooled connection
  now has its own opening lock, so a blocked connection does not delay request
  opening on another connection.

## 1.0.0-rc.1 — 2026-07-26

This release candidate replaces the original frame-codec spike with an
origin-bound, streaming HTTP/2 client.

### Changed (breaking)

- `Client#post`'s argument order is now `(target, headers, body)`, matching
  `#request`/`#get`/`#head` and Crystal stdlib's HTTP client convention
  (previously `(target, body, headers)`). A call that passed both `headers`
  and `body` positionally now fails to compile rather than silently
  swapping their meaning; pass `body:` as a keyword argument, or reorder the
  positional arguments, to update.

### Added

- Complete RFC 9113 frame parsing, stream state, flow control, SETTINGS,
  PING, GOAWAY, cancellation, and graceful draining.
- Persistent HPACK encoding and decoding with bounded field-block assembly.
- Verified TLS with SNI and ALPN `h2`, plus cleartext prior knowledge.
- Concurrent requests, streaming request and response bodies, informational
  responses, CONNECT, and request/response trailers.
- Explicit timeouts, safe opt-in replay, keepalive, resource limits, and
  structured diagnostics.
- Deterministic property coverage and an independent nghttp2 interoperability
  matrix for TLS, fragmentation, flow control, trailers, resets, GOAWAY, and
  concurrent streams.
- Added a configurable connection-level receive window
  (`connection_receive_window`, default 1 MiB), announced via an accounted
  `WINDOW_UPDATE` sent immediately after the connection preface.
- Added `Timeouts#stream_slot` (default `nil`): when set, a request that
  hits the peer's `MAX_CONCURRENT_STREAMS` limit waits, retrying
  automatically, for a slot to free up instead of immediately raising
  `Connection::ConcurrentStreamLimitError`. A configured wait holds the
  client's internal stream-open serialization for its full span, so other
  `request` calls on the same `Client` queue behind it.
- Added `StreamBody#consumed_bytes`, a cumulative, monotonically increasing
  count of bytes an application has read from a response body.
- Added `Client#additional_never_indexed_fields` (default empty): lets a
  caller name additional credential header fields (for example `x-api-key`)
  that must never be promoted into the HPACK compression dynamic table,
  alongside the built-in `authorization`/`proxy-authorization`/`cookie`/
  `set-cookie`. Applies to both request headers and trailers. `#request`
  reads the returned `Set` directly (no defensive copy) on every call, so it
  must be fully populated before this client's first request; mutating it
  afterward is unsupported and, under `-Dpreview_mt` with a request in
  flight, a data race.
- Added `goaway_flush_timeout` (default 5s), bounding how long the
  connection's reader waits to hand its own outgoing GOAWAY to the writer
  before giving up on a stalled peer.
- Added `max_pre_ack_push_promises` (default 8), bounding how many
  PUSH_PROMISE frames a peer may send before the client's own
  `ENABLE_PUSH=0` SETTINGS is acknowledged — previously unbounded.

### Changed

- The client and protocol APIs have been redesigned and are not compatible
  with the original `0.1.0` spike.
- Crystal 1.20.0 is now the minimum supported compiler.
- Coalesced receive-credit `WINDOW_UPDATE` frames at a half-window watermark,
  for both the connection and each stream, flushing all pending credit on any
  writer wakeup and at stream end instead of one update per body read.
- Redesigned the client timeout model: dropped the persistent socket-level
  read timeout; `read` now bounds the TLS and HTTP/2 handshakes (via the new
  `handshake_read_timeout` option on `connect_tls`) and each response wait
  individually, and `HTTP2::Client` enables keepalive by default (30s
  interval / 10s timeout) through `DEFAULT_CONNECTION_CONFIGURATION`, while a
  caller-supplied configuration is still used verbatim.
- Admitted outbound DATA per stream instead of gating every stream behind a
  single global 32-slot writer cap, so streams without window credit can no
  longer starve streams that have it.
- Outbound HPACK now uses the compression dynamic table (`Incremental`
  indexing) for ordinary request and trailer fields, so repeated custom
  fields on a reused connection compress after their first occurrence.
  `authorization`, `proxy-authorization`, `cookie`, and `set-cookie` are
  matched case-insensitively and always keep the literal, never-indexed wire
  form; `Client#additional_never_indexed_fields` extends that exemption to
  caller-named fields.
- For a connection the library dialed itself (`connect_tls`, `start_tls`,
  and `HTTP2::Client`), `graceful_close` no longer sends a TLS
  `close_notify` alert on either the forceful or the graceful path — the
  raw socket is closed directly instead — so a peer may see the connection
  disappear rather than a clean TLS shutdown (it may log something like
  "unexpected EOF"). A caller-built `OpenSSL::SSL::Socket` passed directly
  to `Connection.start` has no raw socket for the library to discover, so
  closing it still falls back to the socket's own close and reaches
  `SSL_shutdown` there, sending `close_notify` as before.
- The client now re-asserts the ALPN `h2` protocol offer on its TLS context
  before every dial, instead of only once. This self-heals a shared context
  whose ALPN offer was changed by other code between dials, but a context
  shared with a consumer that needs a different, stable ALPN offer will have
  it overwritten back to `h2` on every dial through this library.
- A sized request body (an `IO` paired with an explicit `content-length`)
  must report EOF at exactly that declared length. The client now probes
  one byte past the declared length before finishing the request and raises
  `InvalidRequestError` if the body has more, instead of silently
  truncating it; that probe read has no timeout of its own, so a
  non-conforming source that blocks there rather than returning EOF parks
  the upload fiber — holding the caller's own `IO` — indefinitely, with
  nothing in the library able to unblock it. The request itself still
  fails, with `RequestTimeoutError`, once the response-wait timeout
  (`read`, 30s by default) elapses, since the peer never receives
  `END_STREAM`; with `read` disabled, though, the request has no bound
  either and hangs right alongside the upload fiber — see
  `Request#initialize`'s doc comment. A correctly-sized body now sends one
  extra, empty `DATA` frame carrying `END_STREAM` after its final content
  chunk (previously the final chunk carried `END_STREAM` directly).
- An abandoned response body — received but never read nor closed, with
  data buffered behind flow control — is now reclaimed once idle (governed
  by the existing `Timeouts#idle`), and further access raises
  `RequestTimeoutError`. A response with nothing buffered (a quiet
  SSE/long-poll stream, or a CONNECT tunnel between messages) is never
  reclaimed merely for going quiet.
- Dialing now happens outside the client's internal mutex, so `#close`,
  `#closed?`, and other requests no longer block behind an in-progress
  connect-and-TLS-handshake. Concurrent cold or reconnecting requests share
  one in-flight dial, avoiding duplicate TCP connects and TLS handshakes
  without putting the slow network operation back under the mutex.
- If an owned connection terminates before a request can reserve a stream, the
  client selects a fresh connection once. This is safe connection recovery,
  not request replay: no request bytes have reached the peer, so it applies
  even when automatic replay is disabled or the request body is caller-owned
  `IO`.
- `#graceful_close(timeout)` now shares one deadline across all of a
  client's connections instead of granting each connection its own full
  `timeout`.
- After a response completes while its request body is still uploading, the
  now-moot upload is reset with `RST_STREAM(NO_ERROR)` instead of
  `RST_STREAM(CANCEL)`, so a peer can distinguish "upload abandoned as moot"
  from an outright cancellation.
- Raised the `max_decoded_fields` default from 256 to 1024.
- The `hpack` dependency is now tracked in `shard.yml` by `version: ~> 1.3.0`
  instead of a pinned commit SHA (resolves to the same commit).

### Fixed

- Capped informational (1xx) responses per stream (default 16); excess is a
  stream-scoped protocol error.
- Bounded the keepalive probe end-to-end so a write-stalled peer is detected
  within the keepalive timeout, and made reader acknowledgements
  fire-and-forget.
- Rejected caller-built WINDOW_UPDATE and SETTINGS-ACK frames in the public
  write API to protect flow-control and settings accounting.
- Removed the dead `EventBus` and `Cookies` spike remnants from the public
  API, and corrected the documented scope of the `write` timeout.
- Made closed-stream retention age-aware (`closed_stream_retention`, default
  30s, hard-capped at 4x the count limit); late frames after a peer's
  RST_STREAM are now absorbed silently with flow-control credit restored —
  applying the tolerance RFC 9113 §5.1 prescribes for sent resets uniformly
  to peer-reset streams, instead of the previous connection-level error.
- Made reader-side RST_STREAM sends fire-and-forget (`send_reset_nowait`), so
  a write-stalled transport can no longer park the reader mid-violation.
- `Connection::Configuration` now rejects a `max_retained_closed_streams`
  large enough to overflow its own internal 4x hard cap (`ArgumentError` at
  construction) instead of letting that multiplication raise `OverflowError`
  the first time a stream closes.
- Fixed `Client#graceful_close` busy-looping indefinitely (pinning a CPU
  core at ~100% and starving every fiber in the process, not just the one
  request) instead of returning, when a response body was still open and
  unread as its connection was torn down by the drain deadline. The same
  busy loop could occur when a dead peer's keepalive PING timed out with an
  open, unread response outstanding — both cases were pre-existing bugs,
  not regressions from this change. Both now promptly fail the affected
  response with the connection's own `Connection::DrainTimeoutError` /
  `Connection::KeepaliveTimeoutError` (`DrainTimeoutError` subclasses
  `Connection::TimeoutError`, so the response-monitor's rescue for ordinary
  wait-timeouts had been catching this terminal error too and retrying
  immediately with no yield in between).
- Fixed `Connection#close`/`#graceful_close` hanging indefinitely against a
  peer that stopped reading: for a cleartext connection, the buffered
  transport's close-time flush could block forever; for a TLS connection,
  `SSL_shutdown`'s own close_notify write could block forever. Both are
  unbounded whenever `write_timeout` is left at its default `nil`. Both now
  close the underlying raw socket directly instead of waiting on a flush or
  a TLS shutdown handshake (see the `graceful_close`/close_notify entry
  above for the resulting wire-visible change).
- A full per-stream inbound event queue, and a full per-stream DATA
  body-byte buffer, each used to bring down the entire connection when one
  slow stream's consumer fell behind; both now instead reset only the
  offending stream (`RST_STREAM(ENHANCE_YOUR_CALM)`) with its flow-control
  credit restored, leaving the rest of the connection unaffected.
- Hardened GOAWAY handling: the reader's own GOAWAY send is now bounded by
  `goaway_flush_timeout` instead of risking an indefinite park against a
  stalled peer; a malformed server preface now keeps its real error code
  instead of being downgraded to a generic `PROTOCOL_ERROR`; hitting EOF
  shortly after a peer's non-`NO_ERROR` GOAWAY now raises the new
  `Connection::GoAwayTerminationError` naming that GOAWAY's code, instead of
  a bare `IO::EOFError`; GOAWAY frames now count against the inbound
  control-frame rate limit; and a peer's GOAWAY debug data is truncated
  (128 bytes) and stripped of control characters before it can reach a
  logged error message.
- WINDOW_UPDATE overflow is now detected on half-closed(local) (and
  reserved(local)) streams, where it was previously accepted silently; a
  PRIORITY or HEADERS frame that declares itself as its own stream
  dependency is now rejected as a stream-scoped `PROTOCOL_ERROR` (matching
  h2spec's RFC 7540 §5.3.1 expectation, with the HEADERS check running after
  HPACK decoding so it can no longer desynchronize the connection's dynamic
  table); and tolerance for pre-acknowledgement PUSH_PROMISE frames is now
  bounded (`max_pre_ack_push_promises`), where it was previously unlimited.
- `StreamBody#read` after the caller's own `#close` now raises
  `IO::Error` ("Closed stream") instead of silently returning 0.
- Narrowed the `OpenSSL::SSL::Error` rescue around TLS connection setup to
  the handshake construction itself, so it can no longer swallow an
  unrelated error raised later in the same method.
- `HTTP::Headers` field names converted via the interop constructor
  (`Headers.new(HTTP::Headers)`) are now downcased (RFC 9110 §5.1
  case-insensitivity vs. RFC 9113 §8.2.1's lowercase-wire requirement)
  instead of being rejected outright by outbound field-name validation the
  first time a mixed-case name (`Authorization`, `Content-Type`, etc.) was
  used this way. Native `HTTP2::Headers` construction (hash literals,
  `#add`, `#[]=`) is unchanged and still rejects uppercase field names.

## 0.1.0 — 2022-01-12

- Published the initial experimental frame-codec implementation.
