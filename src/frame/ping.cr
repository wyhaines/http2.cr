module HTTP2
  struct Frame::Ping < Frame
    TypeCode = 0x06_u8

    @[Flags]
    enum Flags : UInt8
      ACK = 0x01_u8
    end

    def setup
      @payload = Bytes.new(8,0) if @payload == Bytes.empty
    end

    def ack?
      flags.includes?(Flags::ACK)
    end

    def ack
      new(
        flags: Flags::ACK,
        stream_id: stream_id,
        payload: payload
      )
    end

    def error?
      if stream_id != 0x00000000_u32
        HTTP2::ProtocolError.new("PING frame with non-zero stream ID")
      elsif data.size != 8
        HTTP2::FrameSizeError.new("PING frame with data size(#{data.size}) != 8")
      end
    end
  end
end
