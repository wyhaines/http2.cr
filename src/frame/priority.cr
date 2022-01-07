module HTTP2
  struct Frame::Priority
    TypeCode = 0x02_u8

    def exclusive?
      payload[0].bits_set?(0b10000000)
    end

    def stream_dependency
      IO::ByteFormat::BigEndian.decode(UInt32, payload[0, 4]) & 0b01111111111111111111111111111111
    end

    def weight
      payload[4].to_u8
    end

    def error?
      if stream_id == 0x00
        HTTP2::ProtocolError.new("PRIORITY frame must have non-zero stream ID")
      elsif payload.size != 5
        HTTP2::ProtocolError.new("PRIORITY frame payload must be 5 bytes")
      end
    end
  end
end
