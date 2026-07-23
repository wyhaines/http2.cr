require "./error_code"

module HTTP2
  # A peer protocol violation with enough information for the connection layer
  # to choose GOAWAY or RST_STREAM.
  class ProtocolError < Exception
    getter error_code : ErrorCode
    getter scope : ErrorScope
    getter stream_id : UInt32?

    def initialize(
      message : String,
      @error_code : ErrorCode = ErrorCode::PROTOCOL_ERROR,
      @scope : ErrorScope = ErrorScope::Connection,
      @stream_id : UInt32? = nil,
    )
      if @scope.stream? && @stream_id.nil?
        raise ArgumentError.new("stream-scoped violations require a stream ID")
      end

      super(message)
    end

    def connection?
      scope.connection?
    end

    def stream?
      scope.stream?
    end
  end
end
