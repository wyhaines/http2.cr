module HTTP2
  struct Frame::GoAway < Frame
    TypeCode     = 0x07_u8
    AllowedFlags = 0x00_u8

    def initialize(
      last_stream_id : UInt32 = 0_u32,
      error_code : UInt32 = ErrorCode::NO_ERROR.to_u32,
      debug_data : Bytes = Bytes.empty,
    )
      if last_stream_id > FrameHeader::MAX_STREAM_ID
        raise ArgumentError.new("last stream ID must be a 31-bit unsigned integer")
      end

      payload = Bytes.new(8 + debug_data.size)
      IO::ByteFormat::BigEndian.encode(last_stream_id, payload[0, 4])
      IO::ByteFormat::BigEndian.encode(error_code, payload[4, 4])
      payload[8, debug_data.size].copy_from(debug_data)
      initialize(0x00_u8, 0_u32, payload)
    end

    def initialize(
      last_stream_id : UInt32,
      error_code : ErrorCode,
      debug_data : Bytes = Bytes.empty,
    )
      initialize(last_stream_id, error_code.to_u32, debug_data)
    end

    def initialize(
      last_stream_id : UInt32,
      error_code : UInt32,
      debug_data : String,
    )
      # `String#to_slice` is a view over the string's own immutable backing
      # storage -- no defensive copy is needed here, the same as the
      # `String` overloads in `Frame`'s generated initializers.
      initialize(last_stream_id, error_code, debug_data.to_slice)
    end

    def last_stream_id
      IO::ByteFormat::BigEndian.decode(UInt32, payload[0, 4]) &
        FrameHeader::RESERVED_STREAM_MASK
    end

    def error_code
      IO::ByteFormat::BigEndian.decode(UInt32, payload[4, 4])
    end

    def debug_data
      payload[8, payload.size - 8]
    end

    def data
      debug_data
    end

    protected def validate!
      require_connection_stream!("GOAWAY")
      return if payload.size >= 8

      frame_size_error!("GOAWAY frame payload must contain at least 8 octets")
    end
  end
end
