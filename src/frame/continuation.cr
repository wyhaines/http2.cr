require "./headers_helper"

module HTTP2
  struct Frame::Continuation < Frame
    include HeadersHelper
    TypeCode = 0x09_u8

    @[Flags]
    enum Flags : UInt8
      END_HEADERS = 0x04_u8
    end

    def initialize(
      flags : Flags,
      @stream_id : UInt32,
      @headers : HTTP::Headers,
      encoder : HPack::Encoder = HPack::Encoder.new
    )
      initialize(flags.to_u8, @stream_id, headers, encoder)
    end

    def initialize(
      @flags : UInt8,
      @stream_id : UInt32,
      @headers : HTTP::Headers,
      encoder : HPack::Encoder = HPack::Encoder.new
    )
      @payload = encoder.encode(headers)
      check_payload_size
    end

    def error?
      if @stream_id == 0x00_u32
        ProtocolError.new("Continuation frame must have non-zero stream ID")
      else
        false
      end
    end
  end
end
