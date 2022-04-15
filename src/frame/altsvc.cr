require "../protocol_error"

module HTTP2
  struct Frame::AltSvc < Frame
    TypeCode = 0x0a_u8
  end
end
