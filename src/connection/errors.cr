require "../protocol_error"

module HTTP2
  class Connection
    class Error < Exception
    end

    class InvalidStateError < Error
    end

    # A narrow, known-benign subset of `InvalidStateError`: a stream-open
    # race the writer or connection state machine already re-verified and
    # rejected (a request-slot reservation no longer pending, a stream no
    # longer registered, or a monotonicity check failing at write-staging
    # time), rather than some other invalid-state condition. `Client`
    # reclassifies exactly this leaf type as a safe-to-retry pool
    # reselection instead of a fatal error — a plain `is_a?` on this type
    # replaces what used to be an `error.class == InvalidStateError` exact
    # match against the base class.
    class RetryableInvalidStateError < InvalidStateError
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
          message += ": #{self.class.sanitize_debug_data(truncated)}"
        end
        super(message)
      end

      def error_code : UInt32
        @goaway.error_code
      end

      # `String.new` never raises on invalid UTF-8 (it wraps the bytes as
      # given); truncation above can itself split a multibyte sequence at
      # the boundary regardless of whether the peer's original bytes were
      # valid. `#scrub` replaces any resulting invalid byte sequences with
      # the Unicode replacement character — but it only touches *invalid*
      # UTF-8. C0 controls (0x00-0x1F), DEL (0x7F), and C1 controls
      # (0x80-0x9F) are all valid UTF-8 code points, so `#scrub` alone
      # passes them through unchanged — including ESC and BEL, which let a
      # peer-controlled debug string carry a live ANSI/terminal escape
      # sequence into a message an application might log verbatim (a
      # narrow log/terminal-injection vector, not just a display nit).
      # Replaced with the same replacement character `#scrub` already
      # uses, for the same reason and for one consistent visual marker.
      def self.sanitize_debug_data(bytes : Bytes) : String
        String.build do |io|
          String.new(bytes).scrub.each_char do |char|
            codepoint = char.ord
            if codepoint < 0x20 || codepoint == 0x7f || (0x80 <= codepoint <= 0x9f)
              io << Char::REPLACEMENT
            else
              io << char
            end
          end
        end
      end
    end

    class ResourceLimitError < ProtocolError
      def initialize(message : String)
        super(message, ErrorCode::ENHANCE_YOUR_CALM)
      end
    end
  end
end
