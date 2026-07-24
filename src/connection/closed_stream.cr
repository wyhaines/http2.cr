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

      def initialize(@id : UInt32, @reason : Reason)
      end

      def tolerate_late_frames?
        reason.local_reset? || reason.go_away?
      end
    end
  end
end
