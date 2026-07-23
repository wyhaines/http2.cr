module HTTP2
  # Error codes carried by RST_STREAM and GOAWAY frames.
  enum ErrorCode : UInt32
    NO_ERROR            = 0x00_u32
    PROTOCOL_ERROR      = 0x01_u32
    INTERNAL_ERROR      = 0x02_u32
    FLOW_CONTROL_ERROR  = 0x03_u32
    SETTINGS_TIMEOUT    = 0x04_u32
    STREAM_CLOSED       = 0x05_u32
    FRAME_SIZE_ERROR    = 0x06_u32
    REFUSED_STREAM      = 0x07_u32
    CANCEL              = 0x08_u32
    COMPRESSION_ERROR   = 0x09_u32
    CONNECT_ERROR       = 0x0a_u32
    ENHANCE_YOUR_CALM   = 0x0b_u32
    INADEQUATE_SECURITY = 0x0c_u32
    HTTP_1_1_REQUIRED   = 0x0d_u32
  end

  # Identifies whether an HTTP/2 violation terminates one stream or the
  # connection.
  enum ErrorScope
    Connection
    Stream
  end
end
