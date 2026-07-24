# Changelog

All notable changes are recorded here. This project follows
[Semantic Versioning](https://semver.org/).

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

## 0.1.0

- Published the initial experimental frame-codec implementation.
