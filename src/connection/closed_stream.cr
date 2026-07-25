module HTTP2
  class Connection
    # Minimal bounded metadata used to classify late frames without retaining
    # complete stream objects.
    struct ClosedStream
      enum Reason
        EndStream
        LocalReset
        RemoteReset
        GoAway
        Skipped
      end

      getter id : UInt32
      getter reason : Reason
      getter retained_at : Time::Instant

      def initialize(
        @id : UInt32,
        @reason : Reason,
        @retained_at : Time::Instant = Time.instant,
      )
      end

      # RFC 9113 §5.1: frames arriving shortly after a locally-known closure
      # (this side reset the stream, the peer reset it, or the connection is
      # draining via GOAWAY) are scope-limited tolerances, not connection
      # errors — the peer may not yet have seen the closure. Other closures
      # (a clean END_STREAM close, or a stream skipped by ID ordering) keep
      # the stricter default: a late frame there is a protocol violation.
      def tolerates_late_frames?
        reason.local_reset? || reason.remote_reset? || reason.go_away?
      end
    end
  end
end
