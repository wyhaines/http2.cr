module HTTP2
  struct Frame::WindowUpdate < Frame
    TypeCode = 0x08_u8

    def initialize(stream_id : UInt32, window_size_increment : UInt32 = 0)
      buffer = Bytes.new(4, 0)
      IO::ByteFormat::BigEndian.encode(window_size_increment, buffer)
      initialize(0x00_u8, stream_id, buffer)
    end

    def r?
      payload[0].bits_set?(0b10000000)
    end

    def window_size_increment
      IO::ByteFormat::BigEndian.decode(UInt32, payload[0, 4]) & 0b01111111111111111111111111111111
    end

    def error?
      if data.size != 4
        ProtocolError.new("WindowUpdate frame size error. A frame size of #{data.size} is invalid. A WindowUpdate frame must be 4 bytes long.")
      elsif IO::ByteFormat::BigEndian.decode(UInt32, data) == 0x00
        ProtocolError.new("WindowUpdate frame error. A WindowUpdate frame with a window size of 0 is invalid.")
      else
        false
      end
    end
  end
end
