require "../protocol_error"

module HTTP2
  class Connection
    class Error < Exception
    end

    class InvalidStateError < Error
    end

    class ClosedError < Error
    end

    class StreamIDExhaustedError < Error
    end

    class QueueFullError < Error
    end

    class TimeoutError < Error
    end

    class TLSNegotiationError < Error
    end

    class ResourceLimitError < ProtocolError
      def initialize(message : String)
        super(message, ErrorCode::ENHANCE_YOUR_CALM)
      end
    end
  end
end
