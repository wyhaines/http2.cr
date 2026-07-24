module HTTP2
  class Connection
    # One bounded, value-only connection diagnostic. Field values and GOAWAY
    # debug data are deliberately excluded.
    struct Diagnostic
      enum Kind
        Frame
        Lifecycle
        ConnectionError
        StreamError
      end

      enum Direction
        Inbound
        Outbound
        Internal
      end

      getter timestamp : Time::Instant
      getter kind : Kind
      getter direction : Direction
      getter frame_type : UInt8?
      getter flags : UInt8?
      getter stream_id : UInt32?
      getter payload_length : Int32?
      getter error_code : UInt32?
      getter error_scope : ErrorScope?
      getter settings : Array(Frame::Settings::Setting)?
      getter message : String?

      def initialize(
        @kind : Kind,
        @direction : Direction = Direction::Internal,
        @frame_type : UInt8? = nil,
        @flags : UInt8? = nil,
        @stream_id : UInt32? = nil,
        @payload_length : Int32? = nil,
        @error_code : UInt32? = nil,
        @error_scope : ErrorScope? = nil,
        @settings : Array(Frame::Settings::Setting)? = nil,
        @message : String? = nil,
        @timestamp : Time::Instant = Time.instant,
      )
      end
    end
  end
end
