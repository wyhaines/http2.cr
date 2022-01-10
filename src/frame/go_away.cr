module HTTP2
  struct Frame::GoAway < Frame
    TypeCode = 0x07_u8

    def initialize(
      stream_id : UInt32,
      last_stream_id : UInt32 = 0x00_u32,
      error_code : UInt32 = 0x00_u32,
      optional_debug_data : Bytes = Bytes.empty)

      buffer = IO::Memory.new
      raw_last_stream_id = Bytes.new(4)
      IO::ByteFormat::BigEndian.encode(last_stream_id, raw_last_stream_id)
      buffer.write(raw_last_stream_id)
      raw_error_code = Bytes.new(4)
      IO::ByteFormat::BigEndian.encode(error_code, raw_error_code)
      buffer.write(raw_error_code)
      buffer.write(optional_debug_data)

      initialize(0x00_u8, stream_id, buffer.to_slice)
    end

    def initialize(
      stream_id : UInt32,
      last_stream_id : UInt32,
      error_code : UInt32,
      optional_debug_data : String)

      initialize(
        stream_id,
        last_stream_id,
        error_code,
        optional_debug_data.to_slice)
    end

    def r?
      payload[0].bits_set?(0b10000000)
    end

    def last_stream_id
      IO::ByteFormat::BigEndian.decode(UInt32, payload[0, 4]) & 0b01111111111111111111111111111111
    end

    def error_code
      IO::ByteFormat::BigEndian.decode(UInt32, payload[4, 4])
    end

    def data
      payload[8..-1]
    end
  end
end
