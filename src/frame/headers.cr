require "http/headers"
require "../protocol_error"

module HTTP2
  struct Frame::Headers < Frame
    TypeCode = 0x01_u8

    @[Flags]
    enum Flags : UInt8
      END_STREAM  =  0x1_u8
      END_HEADERS =  0x4_u8
      PADDED      =  0x8_u8
      PRIORITY    = 0x20_u8
    end

    getter headers : HTTP::Headers = HTTP::Headers.new

    def initialize(flags : Flags, @stream_id : UInt32, @payload : Bytes = Bytes.empty)
      @flags = 0x00_u8
      initialize(flags.to_u8, @stream_id, @payload)
    end

    def initialize(@flags : UInt8, @stream_id : UInt32, @payload : Bytes = Bytes.empty)
      super
      decode
    end

    def initialize(flags : Flags, @stream_id : UInt32, payload : String)
      @flags = 0x00_u8
      @payload = Bytes.empty
      initialize(flags.to_u8, @stream_id, payload.to_slice)
    end

    def initialize(@flags : UInt8, @stream_id : UInt32, payload : String)
      @payload = Bytes.empty
      initialize(@flags, @stream_id, payload.to_slice)
    end

    def initialize(flags : Flags, @stream_id : UInt32, @headers : HTTP::Headers)
      @flags = 0x00_u8
      initialize(flags.to_u8, @stream_id, @headers.to_slice)
    end

    def initialize(@flags : UInt8, @stream_id : UInt32, @headers : HTTP::Headers)
      @payload = headers.serialize(IO::Memory.new).to_slice
      check_payload_size
    end

    def decode
      decode_using(HPack::Decoder.new)
    end

    def decode_using(decoder : HPack::Decoder)
      @headers.merge! decoder.decode(data)
    end

    def end_stream?
      flags.includes?(Flags::END_STREAM)
    end

    def end_headers?
      flags.includes?(Flags::END_HEADERS)
    end

    def padded?
      flags.includes?(Flags::PADDED)
    end

    def priority?
      flags.includes?(Flags::PRIORITY)
    end

    # If the frame has padding enabled, this byte will contain the length of the padding
    def pad_length : UInt8
      if padded?
        payload[0].to_u8
      else
        0_u8
      end
    end

    def exclusive?
      if priority?
        payload[padding_offset].bits_set?(0b10000000)
      else
        nil
      end
    end

    private def padding_offset
      if padded?
        1
      else
        0
      end
    end

    private def data_offset
      if priority?
        padding_offset + 5
      else
        padding_offset
      end
    end

    def stream_dependency
      if priority?
        IO::ByteFormat::BigEndian.decode(UInt32, payload[padding_offset, 4]) & 0b01111111111111111111111111111111
      else
        nil
      end
    end

    def weight
      if priority?
        payload[padding_offset + 4].to_u8
      else
        nil
      end
    end

    def data
      payload[data_offset..(-1 * (pad_length + 1))]
    end

    def header_block_fragment
      data
    end

    def padding
      if padded?
        (-1 * (pad_length + 1)) == -1 ? "" : payload[(-1 * (pad_length))..(-1)]
      else
        nil
      end
    end

    def error?
      # TODO: These checks are incomplete.
      # To be complete, this should also scan the padding for non-zero bytes, but that
      # is potentially quite a bit of byte scanning; is there really any good operational
      # reason to do this?
      if stream_id == 0x00
        HTTP2::ProtocolError.new("HEADERS frame must have non-zero stream ID")
      elsif padded? && pad_length >= (payload.size - data_offset - pad_length)
        HTTP2::ProtocolError.new("PADDED flag is set, but pad length is greater than payload size")
      end
    end
  end
end
