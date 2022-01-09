require "../protocol_error"
require "./padding_helper"
require "./headers_helper"

module HTTP2
  struct Frame::PushPromise < Frame
    include HeadersHelper
    TypeCode = 0x05_u8

    @[Flags]
    enum Flags : UInt8
      END_HEADERS = 0x04
      PADDED      = 0x08
    end

    # def initialize(flags : Flags, @stream_id : UInt32, payload : String)
    #   @flags = 0x00_u8
    #   @payload = Bytes.empty
    #   initialize(flags.to_u8, @stream_id, payload.to_slice)
    # end

    # def initialize(@flags : UInt8, @stream_id : UInt32, payload : String)
    #   @payload = Bytes.empty
    #   initialize(@flags, @stream_id, payload.to_slice)
    # end

    # def initialize(flags : Flags, @stream_id : UInt32, @headers : HTTP::Headers)
    #   @flags = 0x00_u8
    #   initialize(flags.to_u8, @stream_id, @headers.to_slice)
    # end

    # def initialize(@flags : UInt8, @stream_id : UInt32, @headers : HTTP::Headers)
    #   @payload = headers.serialize(IO::Memory.new).to_slice
    #   check_payload_size
    # end

    def r?
      payload[padding_offset].bits_set?(0b10000000)
    end

    def promised_stream_id
      IO::ByteFormat::BigEndian.decode(UInt32, payload[padding_offset, 4]) & 0b01111111111111111111111111111111
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
