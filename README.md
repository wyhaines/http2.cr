[![CI](https://github.com/wyhaines/http2.cr/actions/workflows/ci.yml/badge.svg)](https://github.com/wyhaines/http2.cr/actions/workflows/ci.yml)
[![GitHub release](https://img.shields.io/github/release/wyhaines/http2.cr.svg)](https://github.com/wyhaines/http2.cr/releases)

# http2.cr

`http2.cr` is a pure Crystal implementation of HTTP/2. The project is being
rebuilt from an earlier frame-codec spike into a production-quality client with
a reusable protocol core.

## Status

The current code is not ready for production use. It exposes early frame,
connection, stream, and request types, but does not yet provide a complete
client handshake, stream engine, flow control implementation, or HTTP message
API.

Development is organized in ordered phases:

- [Implementation roadmap](design/http2-implementation-roadmap.md)
- [Architecture decisions](design/architecture.md)
- [Current implementation status](design/implementation-status.md)

## Installation

Add the shard to your application's `shard.yml`:

```yaml
dependencies:
  http2:
    github: wyhaines/http2.cr
```

Then run `shards install`.

## Usage

The public client API is intentionally deferred until the protocol engine is
correct. Requiring the shard currently exposes experimental protocol
primitives:

```crystal
require "http2"
```

These types can change before `1.0`.

## Development

Install dependencies and build Ameba:

```sh
shards install
shards build ameba -Dpreview_mt
```

Run the verification suite:

```sh
crystal tool format --check
bin/ameba
crystal spec -t -s
crystal spec -Dpreview_mt -t -s
crystal build src/http2.cr
```

Tests must be hermetic. Do not add public-network dependencies to the default
spec suite; use supplied `IO` objects, scripted peers, or local TLS fixtures.

See [AGENTS.md](AGENTS.md) for contributor conventions.
