module HTTP2
  struct Frame::Priority < Frame
    TypeCode     = 0x02_u8
    AllowedFlags = 0x00_u8

    def exclusive?
      payload[0].bits_set?(0x80)
    end

    def stream_dependency
      IO::ByteFormat::BigEndian.decode(UInt32, payload[0, 4]) &
        FrameHeader::RESERVED_STREAM_MASK
    end

    # The encoded value is one less than the effective HTTP/2 weight.
    def weight
      payload[4]
    end

    protected def validate!
      require_stream_id!("PRIORITY")
      return if payload.size == 5

      frame_size_error!(
        "PRIORITY frame payload must be exactly 5 octets",
        ErrorScope::Stream
      )
    end
  end
end
