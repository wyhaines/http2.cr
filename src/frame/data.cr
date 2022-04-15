require "../protocol_error"
require "./padding_helper"

module HTTP2
  struct Frame::Data < Frame
    include PaddingHelper
    TypeCode = 0x0_u8

    @[Flags]
    enum Flags : UInt8
      END_STREAM = 0x1_u8
      PADDED     = 0x8_u8
    end

    def initialize(flags : UInt8, stream_id : UInt32, payload : IO)
    end

    def data_offset
      padding_offset
    end

    def data
      payload[padding_offset..(-1 * (pad_length + 1))]
    end

    def data
      payload[data_offset..(-1 * (pad_length + 1))]
    end

    def error?
      # To be complete, this should also scan the padding for non-zero bytes, but that
      # is potentially quite a bit of byte scanning; is there really any good operational
      # reason to do this?
      if stream_id == 0x00
        HTTP2::ProtocolError.new("DATA frame must have non-zero stream ID")
      elsif padded? && pad_length >= (payload.size - data_offset - pad_length)
        HTTP2::ProtocolError.new("PADDED flag is set, but pad length is greater than payload size")
      end
    end
  end
end
