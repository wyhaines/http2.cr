module HTTP2
  class Connection
    # Effective values for the SETTINGS defined by RFC 9113.
    struct SettingsState
      DEFAULT_HEADER_TABLE_SIZE   =       4_096_u32
      DEFAULT_INITIAL_WINDOW_SIZE =      65_535_u32
      DEFAULT_MAX_FRAME_SIZE      =      16_384_u32
      MAXIMUM_INITIAL_WINDOW_SIZE = 0x7fff_ffff_u32
      MAXIMUM_FRAME_SIZE          = 0x00ff_ffff_u32

      getter header_table_size : UInt32
      getter? enable_push : Bool
      getter max_concurrent_streams : UInt32?
      getter initial_window_size : UInt32
      getter max_frame_size : UInt32
      getter max_header_list_size : UInt32?

      protected def initialize(
        @header_table_size : UInt32,
        @enable_push : Bool,
        @max_concurrent_streams : UInt32?,
        @initial_window_size : UInt32,
        @max_frame_size : UInt32,
        @max_header_list_size : UInt32?,
      )
      end

      def self.client_defaults : self
        new(
          DEFAULT_HEADER_TABLE_SIZE,
          true,
          nil,
          DEFAULT_INITIAL_WINDOW_SIZE,
          DEFAULT_MAX_FRAME_SIZE,
          nil
        )
      end

      def self.server_defaults : self
        new(
          DEFAULT_HEADER_TABLE_SIZE,
          false,
          nil,
          DEFAULT_INITIAL_WINDOW_SIZE,
          DEFAULT_MAX_FRAME_SIZE,
          nil
        )
      end

      # Applies settings sent by this client. Unsupported extension settings
      # remain on the wire but do not alter this RFC 9113 state.
      def with_local(entries : Enumerable(Frame::Settings::Setting)) : self
        apply(entries, from_server: false, protocol_errors: false)
      end

      # Applies and validates settings received from the server.
      def with_peer(entries : Enumerable(Frame::Settings::Setting)) : self
        apply(entries, from_server: true, protocol_errors: true)
      end

      private def apply(
        entries : Enumerable(Frame::Settings::Setting),
        *,
        from_server : Bool,
        protocol_errors : Bool,
      ) : self
        header_table_size = @header_table_size
        enable_push = @enable_push
        max_concurrent_streams = @max_concurrent_streams
        initial_window_size = @initial_window_size
        max_frame_size = @max_frame_size
        max_header_list_size = @max_header_list_size

        entries.each do |setting|
          case setting.known_identifier
          when Frame::Settings::Identifier::HEADER_TABLE_SIZE
            header_table_size = setting.value
          when Frame::Settings::Identifier::ENABLE_PUSH
            if setting.value > 1
              invalid_setting!(
                "SETTINGS_ENABLE_PUSH must be 0 or 1",
                ErrorCode::PROTOCOL_ERROR,
                protocol_errors
              )
            end
            if from_server && setting.value == 1
              invalid_setting!(
                "a server must not send SETTINGS_ENABLE_PUSH with value 1",
                ErrorCode::PROTOCOL_ERROR,
                protocol_errors
              )
            end
            enable_push = setting.value == 1
          when Frame::Settings::Identifier::MAX_CONCURRENT_STREAMS
            max_concurrent_streams = setting.value
          when Frame::Settings::Identifier::INITIAL_WINDOW_SIZE
            if setting.value > MAXIMUM_INITIAL_WINDOW_SIZE
              invalid_setting!(
                "SETTINGS_INITIAL_WINDOW_SIZE exceeds #{MAXIMUM_INITIAL_WINDOW_SIZE}",
                ErrorCode::FLOW_CONTROL_ERROR,
                protocol_errors
              )
            end
            initial_window_size = setting.value
          when Frame::Settings::Identifier::MAX_FRAME_SIZE
            unless DEFAULT_MAX_FRAME_SIZE <= setting.value <= MAXIMUM_FRAME_SIZE
              invalid_setting!(
                "SETTINGS_MAX_FRAME_SIZE must be between " \
                "#{DEFAULT_MAX_FRAME_SIZE} and #{MAXIMUM_FRAME_SIZE}",
                ErrorCode::PROTOCOL_ERROR,
                protocol_errors
              )
            end
            max_frame_size = setting.value
          when Frame::Settings::Identifier::MAX_HEADER_LIST_SIZE
            max_header_list_size = setting.value
          else
            # Unknown and unsupported extension settings are ignored.
          end
        end

        self.class.new(
          header_table_size,
          enable_push,
          max_concurrent_streams,
          initial_window_size,
          max_frame_size,
          max_header_list_size
        )
      end

      private def invalid_setting!(
        message : String,
        error_code : ErrorCode,
        protocol_errors : Bool,
      ) : NoReturn
        if protocol_errors
          raise ProtocolError.new(message, error_code)
        end

        raise ArgumentError.new(message)
      end
    end
  end
end
