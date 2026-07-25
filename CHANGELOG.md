# Changelog

All notable changes are recorded here. This project follows
[Semantic Versioning](https://semver.org/).

## Unreleased

### Added

- Added a configurable connection-level receive window
  (`connection_receive_window`, default 1 MiB), announced via an accounted
  `WINDOW_UPDATE` sent immediately after the connection preface.

### Changed

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

### Fixed

- Made closed-stream retention age-aware (`closed_stream_retention`, default
  30s, hard-capped at 4x the count limit); late frames after a peer's
  RST_STREAM are now absorbed silently with flow-control credit restored —
  applying the tolerance RFC 9113 §5.1 prescribes for sent resets uniformly
  to peer-reset streams, instead of the previous connection-level error.
- Made reader-side RST_STREAM sends fire-and-forget (`send_reset_nowait`), so
  a write-stalled transport can no longer park the reader mid-violation.

## 1.0.0-rc.1 — 2026-07-24

This release candidate replaces the original frame-codec spike with an
origin-bound, streaming HTTP/2 client.

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

### Changed

- The client and protocol APIs have been redesigned and are not compatible
  with the original `0.1.0` spike.
- Crystal 1.20.0 is now the minimum supported compiler.

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

## 0.1.0

- Published the initial experimental frame-codec implementation.
