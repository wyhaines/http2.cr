module HTTP2
  struct Frame::WindowUpdate < Frame
    TypeCode     = 0x08_u8
    AllowedFlags = 0x00_u8

    def initialize(stream_id : UInt32, window_size_increment : UInt32)
      if window_size_increment > FrameHeader::MAX_STREAM_ID
        raise ArgumentError.new("window size increment must fit in 31 bits")
      end

      payload = Bytes.new(4)
      IO::ByteFormat::BigEndian.encode(window_size_increment, payload)
      initialize(0x00_u8, stream_id, payload)
    end

    def window_size_increment
      IO::ByteFormat::BigEndian.decode(UInt32, payload) &
        FrameHeader::RESERVED_STREAM_MASK
    end

    protected def validate!
      unless payload.size == 4
        frame_size_error!("WINDOW_UPDATE frame payload must be exactly 4 octets")
      end

      return unless window_size_increment.zero?

      if stream_id.zero?
        raise ProtocolError.new(
          "connection WINDOW_UPDATE increment must be nonzero"
        )
      else
        stream_protocol_error!("stream WINDOW_UPDATE increment must be nonzero")
      end
    end
  end
end
