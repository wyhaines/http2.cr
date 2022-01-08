module HTTP2
  struct Frame::ResetStream
    TypeCode = 0x03_u8

    def error_code
      IO::ByteFormat::BigEndian(UInt32, payload)
    end

    def error?
      if stream_id == 0x00
        HTTP2::ProtocolError.new("PRIORITY frame must have non-zero stream ID")
      elsif payload.size != 4
        HTTP2::ProtocolError.new("PRIORITY frame payload must be 5 bytes")
      end
    end
  end
end
