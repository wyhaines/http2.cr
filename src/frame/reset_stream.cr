require "../protocol_error"

module HTTP2
  struct Frame::ResetStream < Frame
    TypeCode = 0x03_u8

    def error_code
      IO::ByteFormat::BigEndian.decode(UInt32, payload)
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
