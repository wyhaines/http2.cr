# HTTP/2 Implementation Status

Last updated: 2026-07-23

## Phase Progress

| Phase | Status | Gate |
| --- | --- | --- |
| 0 — Baseline and architecture | Complete | Gate passed on Crystal 1.20.0 and 1.21.0 |
| 1 — Frame codec and errors | Complete | Gate passed on Crystal 1.20.0 and 1.21.0 |
| 2 — Connection and handshake | Complete | Gate passed on Crystal 1.20.0 and 1.21.0 |
| 3 — SETTINGS, HPACK, field blocks | Blocked on HPACK additions | — |
| 4–8 | Not started | — |

## Phase 0 Baseline

The initial suite did not compile because `spec/spec_helper.cr` defined a
test-only client with an invalid nilable DATA payload. Two specs opened public
network connections to `www.nghttp2.org`. Dependency resolution selected
HPACK 1.0.0 and Ameba 1.0.1; the latter does not compile on modern Crystal.
Formatting failed in six source files, and the newer linter exposed existing
debug calls and duplicate methods.

Phase 0 has:

- pinned improved HPACK commit `a909c58ab40bf03d321777820ff64543d345768d`;
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

## Current Verification

Run from the repository root:

```sh
crystal tool format --check
bin/ameba
crystal spec -t -s
crystal spec -Dpreview_mt -t -s
crystal build src/http2.cr
```

All commands pass with 81 deterministic examples on official Crystal 1.20.0
and 1.21.0 containers. They also pass against the local Crystal 1.21 source
checkout. The `preview_mt` flag emits its expected deprecation warning on
Crystal 1.21.

## Next Work

Phase 3 begins after both HPACK additions in
[hpack-additions.md](./hpack-additions.md) are available. It will add complete
SETTINGS validation and acknowledgement tracking, persistent per-connection
HPACK contexts, bounded field-block assembly, and atomic
HEADERS/CONTINUATION fragmentation. Until then, the runtime deliberately
delivers raw stream frames and does not decode field blocks.
