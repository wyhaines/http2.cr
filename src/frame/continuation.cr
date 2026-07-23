module HTTP2
  struct Frame::Continuation < Frame
    TypeCode     = 0x09_u8
    AllowedFlags = 0x04_u8

    @[Flags]
    enum Flags : UInt8
      END_HEADERS = 0x04_u8
    end

    def end_headers?
      flags.includes?(Flags::END_HEADERS)
    end

    def header_block_fragment
      payload
    end

    protected def validate!
      require_stream_id!("CONTINUATION")
    end
  end
end
