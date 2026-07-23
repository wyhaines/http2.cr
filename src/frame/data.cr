require "./padding_helper"

module HTTP2
  struct Frame::Data < Frame
    include PaddingHelper

    TypeCode     = 0x00_u8
    AllowedFlags = 0x09_u8

    @[Flags]
    enum Flags : UInt8
      END_STREAM = 0x01_u8
      PADDED     = 0x08_u8
    end

    def initialize(flags : UInt8, stream_id : UInt32, payload : IO)
      initialize(flags, stream_id, payload.gets_to_end.to_slice.dup)
    end

    protected def validate!
      require_stream_id!("DATA")
      validate_padding!(frame_size_scope: ErrorScope::Stream)
    end
  end
end
