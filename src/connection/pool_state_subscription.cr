module HTTP2
  class Connection
    # A removable listener for internal connection-capacity changes.
    #
    # :nodoc:
    class PoolStateSubscription
      @unsubscribed = Atomic(Bool).new(false)

      # :nodoc:
      def initialize(
        @connection : Connection,
        @id : UInt64,
      )
      end

      def unsubscribe : Nil
        return unless @unsubscribed.compare_and_set(false, true)

        @connection.remove_pool_state_subscription(@id)
      end
    end
  end
end
