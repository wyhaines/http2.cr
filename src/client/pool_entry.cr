module HTTP2
  class Client
    # Internal state associated with one owned connection.
    #
    # :nodoc:
    class PoolEntry
      getter connection : Connection
      getter opening_mutex = Mutex.new
      getter sequence : UInt64
      property idle_since : Time::Instant?
      property? retired : Bool
      getter activity_generation = 0_u64

      @subscription : Connection::PoolStateSubscription?
      @subscription_mutex = Mutex.new

      def initialize(
        @connection : Connection,
        @sequence : UInt64,
        @idle_since : Time::Instant? = nil,
        @retired : Bool = false,
      )
      end

      def subscribe(&callback : -> Nil) : Nil
        subscription = @connection.subscribe_pool_state do
          callback.call
        end
        @subscription_mutex.synchronize do
          @subscription = subscription
        end
      end

      def unsubscribe : Nil
        subscription = @subscription_mutex.synchronize do
          current = @subscription
          @subscription = nil
          current
        end
        subscription.try(&.unsubscribe)
      end

      def mark_busy : Nil
        @activity_generation += 1_u64
        @idle_since = nil
      end
    end

    # A connection and the capacity reserved on it for one request.
    #
    # :nodoc:
    record ReservedConnection,
      entry : PoolEntry,
      reservation : Connection::RequestSlotReservation
  end
end
