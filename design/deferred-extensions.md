# Deferred HTTP/2 Extensions

Last reviewed: 2026-07-24, against the `1.0.0-rc.1` client baseline.

## Purpose

The client roadmap in [http2-implementation-roadmap.md](./http2-implementation-roadmap.md)
is complete locally. The features below are useful follow-up projects, but none
is required for the current origin-bound HTTP/2 client or for a conventional
gRPC transport. Their priority should be driven by a concrete deployment need
rather than by protocol completeness alone.

## Priority Summary

| Extension | Relative scope | Suggested priority |
| --- | --- | --- |
| Extended CONNECT | Medium | First incremental extension when tunnels or WebSockets are needed |
| RFC 9218 priorities | Medium | Add after workloads demonstrate useful request competition |
| Connection coalescing | Large, security-sensitive | Add only after measuring excessive cross-origin connections |
| `h2c` upgrade | Medium with an HTTP/1.1 dependency | Low unless a legacy peer specifically requires it |
| Server push | Medium to large | Very low without a cache-aware use case |
| Server mode | Very large, strategic | Give it a separate roadmap if serving HTTP/2 is a project goal |

## Server Mode

Server mode would turn this shard from a client with reusable frame machinery
into a bidirectional protocol implementation. It is the largest item here.
The frame codec, HPACK handling, flow control, diagnostics, and much of the
stream state model can be reused, but the connection runtime and HTTP semantics
are currently client-oriented.

A complete first server release would need:

- listener integration and accepted-`IO` support, including TLS certificate
  configuration and ALPN `h2`;
- validation of the client connection preface and a server-side SETTINGS
  handshake;
- server-role stream allocation and state rules, including odd inbound request
  streams and even locally initiated push streams if push is later enabled;
- an inbound request API with streaming bodies, informational responses,
  trailers, cancellation, and backpressure;
- a streaming response writer with correct pseudo-fields, content rules, flow
  control, resets, and graceful GOAWAY draining;
- bounded handler dispatch, per-client limits, timeouts, overload behavior,
  observability, and independent server interoperability tests.

Routing, middleware, HTTP/1.1 fallback, WebSocket framing, and gRPC message
framing should remain separate layers. Server mode deserves its own phased
design because it changes ownership, lifecycle, and public API decisions
throughout the runtime.

**Recommendation:** prioritize this only if a Crystal-native HTTP/2 or gRPC
server is a strategic goal. Do not treat it as a small addition to the client.

## HTTP/1.1 `h2c` Upgrade

The shard already supports cleartext HTTP/2 using current
[RFC 9113 prior knowledge](https://www.rfc-editor.org/rfc/rfc9113.html#section-3.3).
That is distinct from the legacy
[RFC 7540 `h2c` upgrade](https://www.rfc-editor.org/rfc/rfc7540.html#section-3.2),
which begins as HTTP/1.1.

A client implementation must emit an HTTP/1.1 `Upgrade: h2c` request and an
`HTTP2-Settings` header, handle rejection or a `101 Switching Protocols`
response, send the HTTP/2 preface, and represent the upgraded request as
stream 1. A server implementation must parse and validate that HTTP/1.1
exchange, send the `101`, translate the initial request into stream 1, and then
enter the server handshake. Both directions need careful handling of request
bodies, fallback, proxies, malformed settings, and bytes read beyond the
upgrade boundary.

This implies either an HTTP/1.1 parser/client dependency or a narrow adapter to
an existing HTTP/1.1 stack. It should not complicate the normal prior-knowledge
path.

**Recommendation:** low priority unless a known service requires Upgrade and
cannot use TLS ALPN or cleartext prior knowledge.

## Server Push

The current client advertises `SETTINGS_ENABLE_PUSH = 0`, validates
PUSH_PROMISE traffic, and safely rejects promises. Consuming push would instead
advertise support and expose promised responses to applications.

The work includes:

- managing promised even-numbered streams and their reserved-to-open state
  transitions;
- validating promised request fields, method safety, cacheability, authority,
  and the relationship to the associated request;
- offering an accept/reject API without blocking the reader fiber;
- buffering bounded early response events while the application decides;
- cancelling unwanted or duplicate promises and preserving HPACK state even
  when a promise is discarded;
- defining cache integration, deduplication, limits, and ownership of pushed
  responses.

Sending push is a separate server-mode capability. Without an HTTP cache or
another explicit consumer, accepted pushes have little useful destination and
can waste bandwidth. RFC 9113 itself describes significant complexity and
potential performance disadvantages in
[its push discussion](https://www.rfc-editor.org/rfc/rfc9113.html#section-8.4).

**Recommendation:** very low priority. Keep advertising push disabled until a
cache-aware application supplies a concrete acceptance policy.

## RFC 9218 Extensible Priorities

[RFC 9218](https://www.rfc-editor.org/rfc/rfc9218.html) replaces the deprecated
HTTP/2 dependency tree with an urgency value (`u=0` through `u=7`) and an
incremental hint (`i`). Initial priority can travel in the regular `Priority`
HTTP field; later changes use the `PRIORITY_UPDATE` extension frame (type
`0x10`). `SETTINGS_NO_RFC7540_PRIORITIES` communicates use of the newer scheme.

Callers can already send a raw `priority` request field, but complete support
would add:

- a typed, validated priority model and request option;
- negotiation and state for `SETTINGS_NO_RFC7540_PRIORITIES`;
- bounded parsing and serialization of `PRIORITY_UPDATE`;
- an API for reprioritizing an active request;
- explicit behavior for unknown, closed, or maliciously reprioritized streams;
- interoperability and scheduler tests.

For a client, this primarily communicates preferences to the server. A future
server would also need a response scheduler that honors urgency and incremental
delivery without starving lower-priority streams. Implementing only the frame
without scheduling policy would provide limited server-side value.

**Recommendation:** medium-low priority for ordinary API and gRPC traffic.
Raise it when measurements show many competing responses where ordering or
incremental delivery materially affects latency.

## Extended CONNECT

[RFC 8441](https://www.rfc-editor.org/rfc/rfc8441.html#section-3) extends
CONNECT so a stream can carry a named protocol, most notably WebSocket. The
client first observes `SETTINGS_ENABLE_CONNECT_PROTOCOL`; it may then send
`:method = CONNECT` with `:protocol` plus `:scheme`, `:path`, and `:authority`.
This differs from ordinary CONNECT, which omits scheme and path.

The existing CONNECT implementation already supplies most of the difficult
transport behavior: response-gated tunnel access, full-duplex DATA, independent
half-closes, flow control, cancellation, and reset handling. Remaining work is
comparatively focused:

- recognize and track `SETTINGS_ENABLE_CONNECT_PROTOCOL`;
- add a typed extended-CONNECT API and pseudo-field validation;
- reject use before peer negotiation and validate the successful response;
- expose the established stream as the existing tunnel abstraction;
- add independent interoperability, error, half-close, and timeout tests.

A WebSocket adapter would still need to implement WebSocket headers, framing,
close semantics, and subprotocol negotiation; those do not belong in the
HTTP/2 core. Server-side acceptance can be added later with server mode.

**Recommendation:** this is the best incremental extension when a real
WebSocket or custom tunnel use case appears. It is not required for normal
gRPC.

## Connection Coalescing

The current `HTTP2::Client` deliberately reuses a connection only within one
normalized origin. Coalescing would allow one physical HTTP/2 connection to
serve multiple origins when the peer is authoritative for each one, as
described by
[RFC 9113 connection reuse](https://www.rfc-editor.org/rfc/rfc9113.html#section-9.1.1).

This belongs in a multi-origin pool above the present origin-bound client. It
would need to:

- retain the connected address and peer certificate, then revalidate every new
  HTTPS hostname against that certificate;
- incorporate DNS results, SNI, proxies, trust configuration, and client
  certificate identity into eligibility decisions;
- route streams and shared SETTINGS/concurrency limits across origins;
- handle `421 Misdirected Request` by selecting a dedicated connection and
  replaying only when the body and replay policy make that safe;
- drain or replace a shared connection correctly after GOAWAY;
- partition credentials and other sensitive policy while accounting for HPACK
  compression shared across origins;
- test multi-name certificates, DNS changes, 421 recovery, and negative
  authority cases.

The optional [ORIGIN frame](https://www.rfc-editor.org/rfc/rfc8336.html) can
provide an additional authoritative-origin signal. ALTSVC is related to
alternative endpoint discovery but is a separate feature; neither should be a
prerequisite for conservative certificate-and-address-based coalescing.

**Recommendation:** low priority until production measurements show that
separate connections to related HTTPS origins are a meaningful cost. The
security and retry surface is much larger than the apparent pooling change.

## Suggested Order

For the present service-client and possible gRPC direction:

1. Publish and exercise the current release candidate with real workloads.
2. Add extended CONNECT only for a concrete tunnel or WebSocket consumer.
3. Add RFC 9218 when competing-stream measurements justify it.
4. Add connection coalescing only after measuring cross-origin connection cost.
5. Leave `h2c` upgrade and server push deferred unless a specific peer demands
   them.
6. Start a separate server roadmap if server capability becomes a product
   objective; do not mix it into incremental client maintenance.
