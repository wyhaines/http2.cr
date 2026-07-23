# HTTP/2 Implementation Status

Last updated: 2026-07-23

## Phase Progress

| Phase | Status | Gate |
| --- | --- | --- |
| 0 — Baseline and architecture | Complete | Gate passed on Crystal 1.20.0 and 1.21.0 |
| 1 — Frame codec and errors | Ready | — |
| 2 — Connection and handshake | Not started | — |
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

## Current Verification

Run from the repository root:

```sh
crystal tool format --check
bin/ameba
crystal spec -t -s
crystal spec -Dpreview_mt -t -s
crystal build src/http2.cr
```

All commands pass with 41 deterministic examples on official Crystal 1.20.0
and 1.21.0 containers. They also pass against the local Crystal 1.21 source
checkout. The `preview_mt` flag emits its expected deprecation warning on
Crystal 1.21.

## Next Work

Phase 1 should proceed in this order:

1. introduce the raw frame header, error-code enum, violation scope, and
   unknown-frame representation;
2. build bounded parse/write entry points around those types;
3. migrate each standard frame to structural validation;
4. replace `error?` and `to_s(IO)` with explicit result/exception and
   `write(IO)` APIs;
5. complete malformed, truncated, unknown, and round-trip specs.

Do not add connection state or HPACK decoding to frame types during this phase.
