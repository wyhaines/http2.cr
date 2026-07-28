module HTTP2
  class Connection
    # One logical request-stream admission owned by this connection.
    #
    # :nodoc:
    class RequestSlotReservation
      getter connection : Connection
      getter id : UInt64

      # :nodoc:
      def initialize(@connection : Connection, @id : UInt64)
      end

      def release : Nil
        @connection.release_request_slot(self)
      end
    end

    # A mutex-protected request-capacity snapshot.
    #
    # :nodoc:
    record RequestCapacity,
      state : State,
      registered_streams : Int32,
      active_client_streams : Int32,
      idle_client_streams : Int32,
      reservations : Int32,
      peer_limit : UInt32?,
      stream_ids_exhausted : Bool do
      def peer_committed : Int64
        active_client_streams.to_i64 +
          idle_client_streams.to_i64 +
          reservations.to_i64
      end

      def empty? : Bool
        registered_streams.zero? && reservations.zero?
      end

      def zero_peer_limit? : Bool
        peer_limit == 0_u32 && empty?
      end
    end
  end
end
