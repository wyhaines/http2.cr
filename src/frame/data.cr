require "../protocol_error"

module HTTP2
  struct Frame::Data < Frame
    TypeCode = 0x0_u8

    @[Flags]
    enum Flags : UInt8
      END_STREAM = 0x1_u8
      PADDED     = 0x8_u8
    end

    def pad_length : UInt8
      if padded?
        payload[0].to_u8
      else
        0_u8
      end
    end

    private def data_offset
      if padded?
        1
      else
        0
      end
    end

    def data
      payload[data_offset..(-1 * (pad_length + 1))]
    end

    def padding
      if padded?
        (-1 * (pad_length + 1)) == -1 ? "" : payload[(-1 * (pad_length))..(-1)]
      else
        nil
      end
    end

    def padded?
      flags.includes?(Flags::PADDED)
    end

    def error?
      # To be complete, this should also scan the padding for non-zero bytes, but that
      # is potentially quite a bit of byte scanning; is there really any good operational
      # reason to do this?
      if stream_id == 0x00
        return HTTP2::ProtocolError.new("DATA frame must have non-zero stream ID")
      elsif padded? && pad_length >= (payload.size - data_offset - pad_length)
        return HTTP2::ProtocolError.new("PADDED flag is set, but pad length is greater than payload size")
      end
    end
  end
end
