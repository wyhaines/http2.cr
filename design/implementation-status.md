# HTTP/2 Implementation Status

Last updated: 2026-07-23

## Phase Progress

| Phase | Status | Gate |
| --- | --- | --- |
| 0 — Baseline and architecture | Complete | Gate passed on Crystal 1.20.0 and 1.21.0 |
| 1 — Frame codec and errors | Complete | Gate passed on Crystal 1.20.0 and 1.21.0 |
| 2 — Connection and handshake | Complete | Gate passed on Crystal 1.20.0 and 1.21.0 |
| 3 — SETTINGS, HPACK, field blocks | In progress; inbound HPACK API pending | Verified checkpoint; final gate pending |
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

## Phase 3 Progress

The completed Phase 3 work:

- pins `hpack.cr` 1.2.0 and keeps one encoder and decoder per connection;
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
  complete sequence atomically.

Inbound field blocks deliberately remain compressed stream events. HPACK 1.2.0
does not yet expose the requested bounded incremental decoder, result
accounting, or hard literal cap. Using `decode_with_metadata` here would allocate
unbounded retained output and defeat the Phase 3 resource invariant. Once that
API lands, the reader must decode every complete block, preserve dynamic state
after a rejected field section, and map malformed HPACK separately from local
resource exhaustion.

## Current Verification

Run from the repository root:

```sh
crystal tool format --check
bin/ameba
crystal spec -t -s
crystal spec -Dpreview_mt -t -s
crystal build src/http2.cr
```

The Phase 3 checkpoint passes formatting, Ameba, compilation, documentation,
and 106 deterministic examples in normal and `preview_mt` modes in the
official Crystal 1.20.0 and 1.21.0 containers. The `preview_mt` flag emits its
expected deprecation warning on Crystal 1.21.

## Next Work

Finish the second addition in
[hpack-additions.md](./hpack-additions.md), update the dependency pin, and
integrate its incremental decoder into the existing complete-field-block path.
Then add cross-block inbound dynamic-reference, decoded-budget, malformed
remainder, and hard literal-cap tests to close the Phase 3 gate.
