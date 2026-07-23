module HTTP2
  struct Frame::ResetStream < Frame
    TypeCode     = 0x03_u8
    AllowedFlags = 0x00_u8

    def initialize(stream_id : UInt32, error_code : UInt32)
      payload = Bytes.new(4)
      IO::ByteFormat::BigEndian.encode(error_code, payload)
      initialize(0x00_u8, stream_id, payload)
    end

    def initialize(stream_id : UInt32, error_code : ErrorCode)
      initialize(stream_id, error_code.to_u32)
    end

    def error_code
      IO::ByteFormat::BigEndian.decode(UInt32, payload)
    end

    protected def validate!
      require_stream_id!("RST_STREAM")
      return if payload.size == 4

      frame_size_error!("RST_STREAM frame payload must be exactly 4 octets")
    end
  end
end
