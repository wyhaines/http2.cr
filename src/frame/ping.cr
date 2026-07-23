module HTTP2
  struct Frame::Ping < Frame
    TypeCode     = 0x06_u8
    AllowedFlags = 0x01_u8

    @[Flags]
    enum Flags : UInt8
      ACK = 0x01_u8
    end

    def initialize(flags : UInt8, stream_id : UInt32)
      initialize(flags, stream_id, Bytes.new(8, 0_u8))
    end

    def initialize(flags : Flags, stream_id : UInt32)
      initialize(flags.to_u8, stream_id)
    end

    def ack?
      flags.includes?(Flags::ACK)
    end

    def ack
      self.class.new(Flags::ACK, 0_u32, payload)
    end

    protected def validate!
      require_connection_stream!("PING")
      return if payload.size == 8

      frame_size_error!("PING frame payload must be exactly 8 octets")
    end
  end
end
