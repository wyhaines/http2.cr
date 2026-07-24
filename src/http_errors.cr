require "./protocol_error"

module HTTP2
  class HTTPError < Exception
  end

  class InvalidRequestError < HTTPError
  end

  class RequestTimeoutError < HTTPError
  end

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
