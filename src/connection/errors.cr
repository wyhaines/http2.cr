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
  end
end
