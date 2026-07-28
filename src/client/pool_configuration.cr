module HTTP2
  class Client
    # Resource and retention policy for an origin-bound connection pool.
    #
    # The pool grows lazily. `max_connections` bounds eligible plus dialing
    # connections; nil removes that hard bound. Idle and retired limits still
    # apply in nil mode. `idle_timeout` controls connection retention and is
    # distinct from `Timeouts#idle`, which applies to response operations.
    struct PoolConfiguration
      getter max_connections : Int32?
      getter max_idle_connections : Int32
      getter idle_timeout : Time::Span?
      getter max_retired_connections : Int32

      def initialize(
        @max_connections : Int32? = 4,
        @max_idle_connections : Int32 = 2,
        @idle_timeout : Time::Span? = 90.seconds,
        @max_retired_connections : Int32 = 4,
      )
        if maximum = @max_connections
          if maximum <= 0
            raise ArgumentError.new(
              "maximum connection count must be positive"
            )
          end
        end
        if @max_idle_connections < 0
          raise ArgumentError.new(
            "maximum idle-connection count cannot be negative"
          )
        end
        if timeout = @idle_timeout
          if timeout <= Time::Span.zero
            raise ArgumentError.new(
              "idle connection timeout must be positive"
            )
          end
        end
        if @max_retired_connections <= 0
          raise ArgumentError.new(
            "maximum retired-connection count must be positive"
          )
        end
      end

      # :nodoc:
      def effective : self
        maximum = @max_connections
        return self unless maximum
        return self if @max_idle_connections <= maximum

        self.class.new(
          max_connections: maximum,
          max_idle_connections: maximum,
          idle_timeout: @idle_timeout,
          max_retired_connections: @max_retired_connections
        )
      end

      # :nodoc:
      def self.supplied_connection : self
        new(
          max_connections: 1,
          max_idle_connections: 1,
          idle_timeout: nil,
          max_retired_connections: 1
        )
      end
    end
  end
end
