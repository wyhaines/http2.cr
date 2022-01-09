module HTTP2
  struct Frame::Ping
    TypeCode = 0x06_u8

    enum Flags : UInt8
      ACK = 0x01_u8
    end
  end
end
