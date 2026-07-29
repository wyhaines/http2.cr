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

    def end_stream?
      flags.includes?(Flags::END_STREAM)
    end

    protected def validate!
      require_stream_id!("DATA")
      validate_padding!(frame_size_scope: ErrorScope::Stream)
    end
  end
end
