module HTTP2
  class Client
    # A value-only snapshot of the origin connection pool.
    struct PoolState
      getter eligible_connections : Int32
      getter idle_connections : Int32
      getter retired_connections : Int32
      getter? dialing : Bool
      getter max_connections : Int32?

      def initialize(
        @eligible_connections : Int32,
        @idle_connections : Int32,
        @retired_connections : Int32,
        @dialing : Bool,
        @max_connections : Int32?,
      )
      end
    end
  end
end
