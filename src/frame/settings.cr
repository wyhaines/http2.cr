module HTTP2
  struct Frame::Settings < Frame
    TypeCode     = 0x04_u8
    AllowedFlags = 0x01_u8

    @[Flags]
    enum Flags : UInt8
      ACK = 0x01_u8
    end

    enum Identifier : UInt16
      HEADER_TABLE_SIZE       =   0x01_u16
      ENABLE_PUSH             =   0x02_u16
      MAX_CONCURRENT_STREAMS  =   0x03_u16
      INITIAL_WINDOW_SIZE     =   0x04_u16
      MAX_FRAME_SIZE          =   0x05_u16
      MAX_HEADER_LIST_SIZE    =   0x06_u16
      ENABLE_CONNECT_PROTOCOL =   0x08_u16
      NO_RFC7540_PRIORITIES   =   0x09_u16
      TLS_RENEG_PERMITTED     =   0x10_u16
      ENABLE_METADATA         = 0x4d44_u16
    end

    alias Parameters = Identifier

    struct Setting
      getter identifier : UInt16
      getter value : UInt32

      def initialize(@identifier : UInt16, @value : UInt32)
      end

      def initialize(identifier : Identifier, @value : UInt32)
        @identifier = identifier.to_u16
      end

      def known_identifier : Identifier?
        Identifier.from_value?(@identifier)
      end
    end

    # Lazily parsed and cached on first access rather than eagerly in
    # `validate!`: most SETTINGS frames built from a payload are only
    # inspected for a handful of identifiers (or not at all, e.g. an ACK),
    # so an unconditional `Array(Setting)` allocation on every construction
    # -- immediately discarded for ACKs and never read by callers that only
    # check `ack?` -- would be wasted work. `validate!` still eagerly
    # checks payload shape (divisible by 6 octets); only the per-entry
    # decode is deferred.
    @entries : Array(Setting)?

    def initialize(entries : Enumerable(Setting), flags : Flags = Flags::None)
      materialized = entries.to_a
      payload = Bytes.new(materialized.size * 6)
      offset = 0

      materialized.each do |setting|
        IO::ByteFormat::BigEndian.encode(setting.identifier, payload[offset, 2])
        IO::ByteFormat::BigEndian.encode(setting.value, payload[offset + 2, 4])
        offset += 6
      end

      initialize(flags, 0_u32, payload)
    end

    def self.ack
      new(Flags::ACK, 0_u32, Bytes.empty)
    end

    def ack?
      flags.includes?(Flags::ACK)
    end

    def ack
      self.class.ack
    end

    # Kept as a readable alias while callers migrate from the old hash API.
    def parameters
      entries
    end

    protected def validate!
      require_connection_stream!("SETTINGS")

      if ack? && !payload.empty?
        frame_size_error!("SETTINGS ACK frame payload must be empty")
      end

      unless payload.size.divisible_by?(6)
        frame_size_error!("SETTINGS frame payload must be a multiple of 6 octets")
      end
    end

    def entries : Array(Setting)
      @entries ||= parse_entries
    end

    private def parse_entries : Array(Setting)
      parsed = Array(Setting).new(payload.size // 6)
      offset = 0
      while offset < payload.size
        identifier = IO::ByteFormat::BigEndian.decode(UInt16, payload[offset, 2])
        value = IO::ByteFormat::BigEndian.decode(UInt32, payload[offset + 2, 4])
        parsed << Setting.new(identifier, value)
        offset += 6
      end
      parsed
    end
  end
end
