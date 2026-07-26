require "./padding_helper"

module HTTP2
  struct Frame::Headers < Frame
    include PaddingHelper

    TypeCode     = 0x01_u8
    AllowedFlags = 0x2d_u8

    @[Flags]
    enum Flags : UInt8
      END_STREAM  = 0x01_u8
      END_HEADERS = 0x04_u8
      PADDED      = 0x08_u8
      PRIORITY    = 0x20_u8
    end

    def end_stream?
      flags.includes?(Flags::END_STREAM)
    end

    def end_headers?
      flags.includes?(Flags::END_HEADERS)
    end

    def priority?
      flags.includes?(Flags::PRIORITY)
    end

    def exclusive?
      return unless priority?

      payload[padding_offset].bits_set?(0x80)
    end

    def stream_dependency
      return unless priority?

      IO::ByteFormat::BigEndian.decode(UInt32, payload[padding_offset, 4]) &
        FrameHeader::RESERVED_STREAM_MASK
    end

    def weight
      return unless priority?

      payload[padding_offset + 4]
    end

    def header_block_fragment
      data
    end

    def data_offset
      padding_offset + (priority? ? 5 : 0)
    end

    protected def validate!
      require_stream_id!("HEADERS")
      validate_padding!(priority? ? 5 : 0)

      # See the matching comment in Frame::Priority#validate! — the same
      # "cannot depend on itself" rule applies to HEADERS carrying an
      # inline PRIORITY payload.
      return unless priority? && stream_dependency == stream_id

      stream_protocol_error!(
        "HEADERS frame priority must not set stream #{stream_id} as " \
        "its own dependency"
      )
    end
  end
end
