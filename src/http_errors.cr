require "./protocol_error"

module HTTP2
  # Base class for the HTTP-semantic errors `Client` and `Response` raise
  # once request/response handling is layered above a `Connection` — as
  # distinct from `Connection::Error`, raised by the protocol layer
  # itself. `Client::ClosedError`, `InvalidRequestError`,
  # `RequestTimeoutError`, and `RequestCanceledError` all descend from it.
  class HTTPError < Exception
  end

  # A caller-supplied request could not be sent as given: an invalid
  # method token, a disallowed or malformed header or pseudo-header, a
  # `content-length` that disagrees with the request's actual or
  # declared body length, or an invalid request target. Raised
  # synchronously from `Client#get`/`#post`/`#request`/`#head` while
  # preparing the request — except a streamed `IO` body whose length
  # turns out not to match its declared `content-length`, which this
  # same error instead reports mid-request, once the mismatch is
  # discovered. Always a caller usage error, never a sign of a protocol
  # or network failure.
  class InvalidRequestError < HTTPError
  end

  # A `Client::Timeouts` deadline elapsed while sending or waiting on a
  # specific request: connecting, the TLS/HTTP/2 handshake, a response
  # header or trailer wait, a body read, or (via `idle`) an abandoned
  # response's stream being reclaimed. `Client` and `Response` raise
  # this in place of the lower-level `Connection::TimeoutError`,
  # `IO::TimeoutError`, or `StreamBody::ReadTimeoutError` that actually
  # fired; once a stream has been opened for the request, that stream is
  # also canceled (the connect and handshake timeouts precede stream
  # creation, so they have none to cancel).
  class RequestTimeoutError < HTTPError
  end

  # A request or a response read was canceled: either the `Cancellation`
  # passed to `Client#get`/`#post`/`#request`/`#head` was signaled, or
  # `Response#cancel` was called directly. Raised by `Client#request`
  # itself and by subsequent reads or waits on the `Response` it
  # returned.
  class RequestCanceledError < HTTPError
  end

  # A malformed peer response. The connection maps this to
  # RST_STREAM(PROTOCOL_ERROR) without closing unrelated streams.
  class MalformedResponseError < ProtocolError
    def initialize(message : String, stream_id : UInt32)
      super(
        message,
        ErrorCode::PROTOCOL_ERROR,
        ErrorScope::Stream,
        stream_id
      )
    end
  end
end
