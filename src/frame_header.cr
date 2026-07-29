module HTTP2
  # The fixed nine-octet header shared by every HTTP/2 frame.
  struct FrameHeader
    SIZE                 =               9
    DEFAULT_MAX_PAYLOAD  =          16_384
    MAX_PAYLOAD          =     0x00ff_ffff
    MAX_STREAM_ID        = 0x7fff_ffff_u32
    RESERVED_STREAM_MASK = 0x7fff_ffff_u32

    getter length : Int32
    getter type_code : UInt8
    getter flags : UInt8
    getter stream_id : UInt32

    def initialize(
      @length : Int32,
      @type_code : UInt8,
      @flags : UInt8,
      @stream_id : UInt32,
    )
      unless 0 <= @length <= MAX_PAYLOAD
        raise ArgumentError.new("frame payload length must be between 0 and #{MAX_PAYLOAD}")
      end

      if @stream_id > MAX_STREAM_ID
        raise ArgumentError.new("stream ID must be a 31-bit unsigned integer")
      end
    end

    def self.read(io : IO) : self
      buffer = uninitialized UInt8[SIZE]
      bytes = buffer.to_slice
      io.read_fully(bytes)

      length = ((bytes[0].to_i32 << 16) |
                (bytes[1].to_i32 << 8) |
                bytes[2].to_i32)
      type_code = bytes[3]
      flags = bytes[4]
      stream_id = IO::ByteFormat::BigEndian.decode(UInt32, bytes[5, 4]) &
                  RESERVED_STREAM_MASK

      new(length, type_code, flags, stream_id)
    end

    def write(io : IO) : Nil
      masked_stream_id = stream_id & RESERVED_STREAM_MASK
      bytes = uninitialized UInt8[SIZE]
      bytes[0] = ((length >> 16) & 0xff).to_u8
      bytes[1] = ((length >> 8) & 0xff).to_u8
      bytes[2] = (length & 0xff).to_u8
      bytes[3] = type_code
      bytes[4] = flags
      bytes[5] = ((masked_stream_id >> 24) & 0xff).to_u8
      bytes[6] = ((masked_stream_id >> 16) & 0xff).to_u8
      bytes[7] = ((masked_stream_id >> 8) & 0xff).to_u8
      bytes[8] = (masked_stream_id & 0xff).to_u8
      io.write(bytes.to_slice)
    end
  end
end
