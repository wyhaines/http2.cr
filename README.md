# http2

WIP. This will be a pure HTTP/2 protocol implementation. It is the building blocks of HTTP/2 itself,
and lacks either a client or a server implementation in this shard.

Client and server implementations will be in separate shards that make use of this common shard.

## Installation

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     http2:
       github: your-github-user/http2
   ```

2. Run `shards install`

## Usage

```crystal
require "http2"
```

TODO: Write usage instructions here

## Development

TODO: Write development instructions here

## Contributing

1. Fork it (<https://github.com/your-github-user/http2/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Kirk Haines](https://github.com/your-github-user) - creator and maintainer
