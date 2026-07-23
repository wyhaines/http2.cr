require "./padding_helper"

module HTTP2
  struct Frame::PushPromise < Frame
    include PaddingHelper

    TypeCode     = 0x05_u8
    AllowedFlags = 0x0c_u8

    @[Flags]
    enum Flags : UInt8
      END_HEADERS = 0x04_u8
      PADDED      = 0x08_u8
    end

    def initialize(
      flags : Flags,
      stream_id : UInt32,
      promised_stream_id : UInt32,
      header_block_fragment : Bytes = Bytes.empty,
      pad_length : UInt8 = 0_u8,
    )
      if promised_stream_id > FrameHeader::MAX_STREAM_ID
        raise ArgumentError.new("promised stream ID must be a 31-bit unsigned integer")
      end

      padded = flags.includes?(Flags::PADDED)
      if !padded && !pad_length.zero?
        raise ArgumentError.new("pad length requires the PADDED flag")
      end

      payload_size = (padded ? 1 : 0) + 4 +
                     header_block_fragment.size + pad_length
      payload = Bytes.new(payload_size, 0_u8)
      offset = 0
      if padded
        payload[0] = pad_length
        offset = 1
      end

      IO::ByteFormat::BigEndian.encode(promised_stream_id, payload[offset, 4])
      payload[offset + 4, header_block_fragment.size].copy_from(header_block_fragment)
      initialize(flags, stream_id, payload)
    end

    def end_headers?
      flags.includes?(Flags::END_HEADERS)
    end

    def promised_stream_id
      IO::ByteFormat::BigEndian.decode(UInt32, payload[padding_offset, 4]) &
        FrameHeader::RESERVED_STREAM_MASK
    end

    def header_block_fragment
      data
    end

    def data_offset
      padding_offset + 4
    end

    protected def validate!
      require_stream_id!("PUSH_PROMISE")
      validate_padding!(4)

      if promised_stream_id.zero?
        raise ProtocolError.new("PUSH_PROMISE frame must promise a nonzero stream ID")
      end
    end
  end
end
