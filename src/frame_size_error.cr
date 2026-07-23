require "./protocol_error"

module HTTP2
  class FrameSizeError < ProtocolError
    def initialize(
      message : String,
      scope : ErrorScope = ErrorScope::Connection,
      stream_id : UInt32? = nil,
    )
      super(message, ErrorCode::FRAME_SIZE_ERROR, scope, stream_id)
    end
  end
end
