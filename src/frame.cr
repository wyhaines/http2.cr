module HTTP2
  # This is an abstract superclass for all HTTP/2 Frames. The reference specification
  # can be found at [https://datatracker.ietf.org/doc/html/rfc7540#section-6](https://datatracker.ietf.org/doc/html/rfc7540#section-6).
  #
  # A frame is a basic unit of data transmission in HTTP/2. Every frame has a type,
  # specified by an 8-bit type code, a stream identifier which indicates which stream the frame
  # belongs to, and a payload. Most Frame types also define a set of flags that differ based
  # on the type of the Frame. Specific Frame types may have other considerations, such as
  # padding length and padding bytes in Data frames, so consult the implementation and the
  # reference specification for more information.
  abstract struct Frame
    getter stream_id : UInt32
    getter flags : UInt8 = Bytes.new(1, 0)
    getter payload : Bytes

    # Each subclass defines its own unique TypeCode. This will define a method
    # `type_code` that returns the TypeCode on each subclass inheriting from Frame.
    macro inherited
      def type_code
        TypeCode
      end
    end

  end

  def self.from_io(io : IO) : Frame
    length = (io.read_bytes(UInt8).to_u32 << 16) | io.read_bytes(UInt16, IO::ByteFormat::NetworkEndian)
    type = io.read_bytes(UInt8)
    flags = Flags.new(io.read_bytes(UInt8))

    # Stream id is a 31-bit number (lol)
    stream_id = io.read_bytes(UInt32, IO::ByteFormat::NetworkEndian) & 0b0111_1111_1111_1111_1111_1111_1111_1111

    payload = Bytes.new(length)
    io.read_fully payload

    type(type).new(flags, stream_id, payload)
  end

  def initialize(@flags : Flags, @stream_id : UInt32, @payload : Bytes = Bytes.empty)
    if payload.size >= (1 << 24)
      raise ArgumentError.new("Cannot have a #{self.class} with a size of #{payload.size} (max #{1 << 24})")
    end
  end

  # This will output the frame in a wire compatible format. All frames are formatted
  # identically.
  #
  # ----------------------
  # |    Length (24)     |
  # ----------------------
  # |      Type (8)      |
  # ----------------------
  # |     Flags (8)      |
  # ----------------------
  # |   Stream ID (31)   |
  # ----------------------
  # | Payload (variable) |
  # ----------------------

  def to_s(io)
    to_s_length_bytes io
    to_s_type_byte io
    io.write_byte @flags.to_u8
    io.write_bytes (@stream_id & 0b0111_1111_1111_1111_1111_1111_1111_1111), IO::ByteFormat::NetworkEndian
    io.write @payload
  end

  # Length is a 24-bit number, so we need to effectively mask off the top 8 bits and
  # output just three bytes.
  @[AlwaysInline]
  private def to_s_length_bytes(io)
    # Shift off the bottom 16 bits, and then output the remainder as an 8 bit value,
    # which chops off the top 8 bits.
    io.write_byte (@payload.bytesize >> 16).to_u8

    # Convert the 32 bit value to a 16 bit value, which chops off the top 16 bits.
    io.write_bytes @payload.bytesize.to_u16, IO::ByteFormat::BigEndian
  end

  # The type byte is a single byte, so we can just output it.
  @[AlwaysInline]
  private def to_s_type_byte(io)
    io.write_byte type_byte
  end

  # The flags are also a single byte.
end