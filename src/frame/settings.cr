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

    enum Parameters : UInt16
      HEADER_TABLE_SIZE                = 0x01
      ENABLE_PUSH                      = 0x02
      MAX_CONCURRENT_STREAMS           = 0x03
      INITIAL_WINDOW_SIZE              = 0x04
      MAX_FRAME_SIZE                   = 0x05
      MAX_HEADER_LIST_SIZE             = 0x06
      Unassigned_0x07                  = 0x07
      SETTINGS_ENABLE_CONNECT_PROTOCOL = 0x08
      SETTINGS_NO_RFC7540_PRIORITIES   = 0x09
      Unassigned_0x0a                  = 0x0a
      Unassigned_0x0b                  = 0x0b
      Unassigned_0x0c                  = 0x0c
      Unassigned_0x0d                  = 0x0d
      Unassigned_0x0e                  = 0x0e
      Unassigned_0x0f                  = 0x0f
      TLS_RENEG_PERMITTED              = 0x10
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

    def initialize(stream_id : UInt32, parameters : ParameterHash, flags : Flags = Flags::None)
      buffer = Slice(UInt8).new(parameters.size * 6)
      pos = 0
      parameters.each do |identifier, value|
        IO::ByteFormat::BigEndian.encode(identifier.to_u16, buffer[pos, 2])
        IO::ByteFormat::BigEndian.encode(value.to_u32, buffer[pos + 2, 4])
        pos += 6
      end
      initialize(0x00_u8, stream_id, buffer)
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
                        pp param
                        pp value
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
      if stream_id != 0x00
        HTTP2::ProtocolError.new("Settings has a stream identifier of #{stream_id}. Settings frames always apply to a connection and must have a stream identifier of zero.")
      elsif payload.size % 6 != 0
        HTTP2::FrameSizeError.new("Settings frame payload must be a multiple of 6 octets in length")
      end
    end
  end
end
