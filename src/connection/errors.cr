require "../protocol_error"

module HTTP2
  class Connection
    class Error < Exception
    end

    class InvalidStateError < Error
    end

    class DrainingError < InvalidStateError
    end

    class ClosedError < Error
    end

    class StreamIDExhaustedError < Error
    end

    class OpenStreamLimitError < InvalidStateError
      getter limit : Int32

      def initialize(@limit : Int32)
        super("local open-stream limit #{limit} is exhausted")
      end
    end

    class ConcurrentStreamLimitError < InvalidStateError
      getter limit : UInt32

      def initialize(@limit : UInt32)
        super("peer concurrent-stream limit #{limit} is exhausted")
      end
    end

    class QueueFullError < Error
    end

    class PingLimitError < InvalidStateError
      getter limit : Int32

      def initialize(@limit : Int32)
        super("pending PING limit #{limit} is exhausted")
      end
    end

    class TimeoutError < Error
    end

    class DrainTimeoutError < TimeoutError
    end

    class KeepaliveTimeoutError < TimeoutError
    end

    class DrainedError < ClosedError
    end

    class TLSNegotiationError < Error
    end

    class TLSVerificationError < TLSNegotiationError
      getter server_name : String

      def initialize(@server_name : String, cause : Exception)
        super(
          "TLS certificate or hostname verification failed for #{server_name}",
          cause
        )
      end
    end

    class CanceledError < ClosedError
      getter stream_id : UInt32
      getter error_code : UInt32

      def initialize(@stream_id : UInt32, @error_code : UInt32)
        super("HTTP/2 stream #{stream_id} was canceled with #{error_code}")
      end

      def initialize(stream_id : UInt32, error_code : ErrorCode)
        initialize(stream_id, error_code.to_u32)
      end
    end

    class StreamResetError < ClosedError
      getter stream_id : UInt32
      getter error_code : UInt32

      def initialize(@stream_id : UInt32, @error_code : UInt32)
        super(
          "peer reset HTTP/2 stream #{stream_id} with error code #{error_code}"
        )
      end
    end

    class UnprocessedStreamError < ClosedError
      getter stream_id : UInt32
      getter goaway : Frame::GoAway

      def initialize(@stream_id : UInt32, @goaway : Frame::GoAway)
        super("HTTP/2 stream #{stream_id} was not processed before GOAWAY")
      end
    end

    class ResourceLimitError < ProtocolError
      def initialize(message : String)
        super(message, ErrorCode::ENHANCE_YOUR_CALM)
      end
    end
  end
end
