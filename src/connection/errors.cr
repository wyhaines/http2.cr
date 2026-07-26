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

    # The connection ended (EOF) after the peer sent a GOAWAY signaling a
    # failure (a non-NO_ERROR code). Raised in place of a bare
    # `IO::EOFError` so streams at or below the GOAWAY's last_stream_id —
    # ones the peer promised to still finish — fail with the peer's own
    # diagnosis instead of an opaque "the socket closed."
    class GoAwayTerminationError < ClosedError
      # RFC 9113 places no length limit on GOAWAY debug data beyond the
      # frame size itself (up to several KB by default, more if the peer
      # advertised a larger SETTINGS_MAX_FRAME_SIZE) — bound how much of
      # it ends up in a message an application might log verbatim.
      MaxDebugDataBytes = 128

      getter goaway : Frame::GoAway

      def initialize(@goaway : Frame::GoAway)
        message = "connection closed after peer GOAWAY with error code " \
                  "#{@goaway.error_code}"
        debug = @goaway.debug_data
        unless debug.empty?
          truncated = debug[0, Math.min(debug.size, MaxDebugDataBytes)]
          # `String.new` never raises on invalid UTF-8 (it wraps the bytes
          # as given); truncation can itself split a multibyte sequence at
          # the boundary above regardless of whether the peer's original
          # bytes were valid. `#scrub` replaces any resulting invalid byte
          # sequences with the Unicode replacement character, so untrusted
          # peer bytes (NULs, control characters, non-UTF-8 data) never
          # reach a message verbatim.
          message += ": #{String.new(truncated).scrub}"
        end
        super(message)
      end

      def error_code : UInt32
        @goaway.error_code
      end
    end

    class ResourceLimitError < ProtocolError
      def initialize(message : String)
        super(message, ErrorCode::ENHANCE_YOUR_CALM)
      end
    end
  end
end
