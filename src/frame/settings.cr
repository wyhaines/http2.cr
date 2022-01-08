require "../protocol_error"
require "../frame_size_error"

module HTTP2
  struct Frame::Settings < Frame
    TypeCode = 0x04_u8
    @parameters : ParameterHash = ParameterHash.new

    @[Flags]
    enum Flags : UInt8
      ACK = 0x01
    end

    @[Flags]
    enum Parameters : UInt16
      HEADER_TABLE_SIZE      = 0x01
      ENABLE_PUSH            = 0x02
      MAX_CONCURRENT_STREAMS = 0x03
      INITIAL_WINDOW_SIZE    = 0x04
      MAX_FRAME_SIZE         = 0x05
      MAX_HEADER_LIST_SIZE   = 0x06
    end

    # This holds the parameters that are parsed from a Settings frame payload,
    # and can also be used to provide parameters to a new Settings frame.
    class ParameterHash < Hash(Parameters, UInt32); end

    # Build a Settings frame with the provided parameters for the payload.
    # Flags are not accepted, because the only flag supported by a Settings frame
    # is the ACK flag, and a Settings:ACK frame can not have a payload.
    #
    # ```
    # settings = HTTP2::Frame::Settings.with_parameters(
    #   stream_id: 0x12345678_u32,
    #   parameters: ParameterHash{
    #     HTTP2::Frame::Settings::Parameters::INITIAL_WINDOW_SIZE => 0x12345678_u32,
    #     HTTP2::Frame::Settings::Parameters::HEADER_TABLE_SIZE   => 0x00004000_u32,
    #   }
    # )
    # ```

    def self.from_parameters(stream_id : UInt32, parameters : ParameterHash)
      buffer = Slice(UInt8).new(parameters.size * 6)
      pos = 0
      parameters.each do |identifier, value|
        IO::ByteFormat::BigEndian.encode(identifier.to_u16, buffer[pos, 2])
        IO::ByteFormat::BigEndian.encode(value.to_u32, buffer[pos + 2, 4])
        pos += 6
      end
      new(0x00_u8, stream_id, buffer)
    end

    def setup
      @parameters = if error?
                      ParameterHash.new
                    else
                      params = ParameterHash.new(initial_capacity: payload.size // 6)
                      position = 0
                      while position < payload.size
                        param = IO::ByteFormat::BigEndian.decode(UInt16, payload[position, 2])
                        position += 2
                        value = IO::ByteFormat::BigEndian.decode(UInt32, payload[position, 4])
                        position += 4
                        params[Parameters.from_value param] = value
                      end

                      params
                    end
    end

    def parameters
      @parameters
    end

    def ack?
      flags.includes? Flags::ACK
    end

    def ack
      self.class.new(Flags::ACK, @stream_id)
    end

    # TODO: These checks are probably incomplete.
    def error?
      if stream_id == 0x00
        HTTP2::ProtocolError.new("SETTINGS frame must have non-zero stream ID")
      elsif payload.size % 6 != 0
        HTTP2::FrameSizeError.new("SETTINGS frame payload must be a multiple of 6 octets in length")
      end
    end
  end
end
