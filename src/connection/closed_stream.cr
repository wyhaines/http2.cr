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

      # RFC 9113 §5.1 draws this tolerance from two different clauses; this
      # predicate applies both as a uniform, stream-scoped tolerance rather
      # than by the letter of each direction:
      #
      # - LocalReset and GoAway: frames the peer already had in flight
      #   before it could have seen our closure (we sent the reset, or we
      #   closed the stream locally after the peer's own GOAWAY). This is
      #   exactly the short-lived race §5.1 describes for frames arriving
      #   after a *sent* reset.
      # - RemoteReset: the peer authored the closure, so it already knows —
      #   frames after that are a buggy peer, not a race. Tolerating them
      #   is deliberate leniency, not the STREAM_CLOSED stream error
      #   §5.1's letter prescribes for a received reset: flow-control
      #   credit is restored either way, and a stream error sent back here
      #   would be ignored by a conforming peer under that same sent-reset
      #   clause, applied on its side.
      #
      # Other closures (a clean END_STREAM close, or a stream skipped by ID
      # ordering) keep the stricter default: a late frame there is a
      # protocol violation.
      #
      # Eviction of retained entries only runs when another stream closes
      # (see `retain_closed_stream_unlocked`), so on an otherwise quiet
      # connection this tolerance is never evicted — effectively
      # indefinite. That's intentional for a client.
      def tolerates_late_frames?
        reason.local_reset? || reason.remote_reset? || reason.go_away?
      end
    end
  end
end
