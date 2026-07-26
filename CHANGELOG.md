# Changelog

All notable changes are recorded here. This project follows
[Semantic Versioning](https://semver.org/).

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
  connect-and-TLS-handshake. As a consequence, concurrent cold requests that
  all need to dial now each perform their own dial (N concurrent requests →
  N connects, all but one discarded), where before they serialized behind a
  single dial.
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
