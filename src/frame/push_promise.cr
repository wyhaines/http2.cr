require "../protocol_error"
require "./padding_helper"
require "./headers_helper"

module HTTP2
  struct Frame::PushPromise < Frame
    include PaddingHelper
    include HeadersHelper
    TypeCode = 0x05_u8

    @[Flags]
    enum Flags : UInt8
      END_HEADERS = 0x04
      PADDED      = 0x08
    end

    def initialize(
      @flags : UInt8,
      @stream_id : UInt32,
      promised_stream_id : UInt32,
      @headers : HTTP::Headers = HTTP::Headers.new,
      encoder : HPack::Encoder = HPack::Encoder.new,
      pad_length : UInt8 = rand(256).to_u8
    )
      buffer = IO::Memory.new
      if self.flags.includes?(Flags::PADDED)
        buffer.write_byte pad_length
      end
      raw_promised_stream_id = Bytes.new(4)
      IO::ByteFormat::BigEndian.encode(promised_stream_id, raw_promised_stream_id)
      buffer.write raw_promised_stream_id
      buffer.write encoder.encode(@headers)
      if self.flags.includes?(Flags::PADDED)
        buffer.write ("\0" * pad_length).to_slice
      end
      initialize(@flags, @stream_id, buffer.to_slice)
    end

    def initialize(
      flags : Flags,
      @stream_id : UInt32,
      promised_stream_id : UInt32,
      @headers : HTTP::Headers = HTTP::Headers.new,
      encoder : HPack::Encoder = HPack::Encoder.new,
      pad_length : UInt8 = rand(256).to_u8
    )
      initialize(flags.to_u8, @stream_id, promised_stream_id, @headers, encoder, pad_length)
    end

    def r?
      payload[padding_offset].bits_set?(0b10000000)
    end

    def promised_stream_id
      IO::ByteFormat::BigEndian.decode(UInt32, payload[padding_offset, 4]) & 0b01111111111111111111111111111111
    end

    def data_offset
      padding_offset + 4
    end

    def error?
      # TODO: These checks are incomplete.
      # To be complete, this should also scan the padding for non-zero bytes, but that
      # is potentially quite a bit of byte scanning; is there really any good operational
      # reason to do this?
      if stream_id == 0x00
        HTTP2::ProtocolError.new("PushPromise frame must have non-zero stream ID")
      elsif padded? && pad_length >= (payload.size - data_offset - pad_length)
        HTTP2::ProtocolError.new("PADDED flag is set, but pad length is greater than payload size")
      end
    end
  end
end
