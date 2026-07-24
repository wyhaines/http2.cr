module HTTP2
  class Connection
    # Resource limits and the SETTINGS sent in the client connection preface.
    class Configuration
      @initial_settings : Array(Frame::Settings::Setting)

      getter inbound_max_frame_size : Int32
      getter writer_queue_capacity : Int32
      getter stream_event_capacity : Int32
      getter settings_ack_timeout : Time::Span
      getter max_compressed_field_section_size : Int32
      getter max_decoded_field_section_size : Int32
      getter max_decoded_string_size : Int32
      getter max_continuation_frames : Int32
      getter max_encoder_table_size : Int32
      getter max_decoder_table_size : Int32
      getter max_retained_closed_streams : Int32
      getter max_buffered_body_bytes : Int32
      getter outbound_data_chunk_size : Int32

      def initialize(
        @inbound_max_frame_size : Int32 = FrameHeader::DEFAULT_MAX_PAYLOAD,
        @writer_queue_capacity : Int32 = 32,
        @stream_event_capacity : Int32 = 32,
        @settings_ack_timeout : Time::Span = 10.seconds,
        @max_compressed_field_section_size : Int32 = 64 * 1024,
        @max_decoded_field_section_size : Int32 = 64 * 1024,
        max_decoded_string_size : Int32? = nil,
        @max_continuation_frames : Int32 = 16,
        @max_encoder_table_size : Int32 = 64 * 1024,
        @max_decoder_table_size : Int32 = 64 * 1024,
        @max_retained_closed_streams : Int32 = 256,
        @max_buffered_body_bytes : Int32 = SettingsState::DEFAULT_INITIAL_WINDOW_SIZE.to_i32,
        @outbound_data_chunk_size : Int32 = FrameHeader::DEFAULT_MAX_PAYLOAD,
        initial_settings : Enumerable(Frame::Settings::Setting) = [] of Frame::Settings::Setting,
      )
        @max_decoded_string_size =
          max_decoded_string_size || @max_decoded_field_section_size
        validate_runtime_limits!
        validate_field_section_limits!
        validate_table_limits!

        @initial_settings = initial_settings.map { |setting| setting }
        synchronize_disabled_push!
        synchronize_advertised_frame_size!
        synchronize_advertised_header_table_size!
        synchronize_advertised_field_section_size!
        synchronize_advertised_initial_window_size!
        SettingsState.client_defaults.with_local(@initial_settings)
      end

      def initial_settings : Array(Frame::Settings::Setting)
        @initial_settings.dup
      end

      private def validate_runtime_limits! : Nil
        unless FrameHeader::DEFAULT_MAX_PAYLOAD <= @inbound_max_frame_size <= FrameHeader::MAX_PAYLOAD
          raise ArgumentError.new(
            "inbound maximum frame size must be between " \
            "#{FrameHeader::DEFAULT_MAX_PAYLOAD} and #{FrameHeader::MAX_PAYLOAD}"
          )
        end
        if @writer_queue_capacity <= 0
          raise ArgumentError.new("writer queue capacity must be positive")
        end
        if @stream_event_capacity <= 0
          raise ArgumentError.new("stream event capacity must be positive")
        end
        if @settings_ack_timeout <= Time::Span.zero
          raise ArgumentError.new(
            "SETTINGS acknowledgement timeout must be positive"
          )
        end
        if @max_retained_closed_streams <= 0
          raise ArgumentError.new(
            "maximum retained closed-stream count must be positive"
          )
        end
        if @max_buffered_body_bytes <= 0
          raise ArgumentError.new(
            "maximum buffered body bytes must be positive"
          )
        end
        unless 0 < @outbound_data_chunk_size <= FrameHeader::MAX_PAYLOAD
          raise ArgumentError.new(
            "outbound DATA chunk size must be between 1 and " \
            "#{FrameHeader::MAX_PAYLOAD}"
          )
        end
      end

      private def validate_field_section_limits! : Nil
        if @max_compressed_field_section_size < 0
          raise ArgumentError.new(
            "maximum compressed field-section size cannot be negative"
          )
        end
        if @max_decoded_field_section_size < 0
          raise ArgumentError.new(
            "maximum decoded field-section size cannot be negative"
          )
        end
        if @max_decoded_string_size < 0
          raise ArgumentError.new(
            "maximum decoded string size cannot be negative"
          )
        end
        if @max_decoded_string_size > @max_decoded_field_section_size
          raise ArgumentError.new(
            "maximum decoded string size cannot exceed the decoded " \
            "field-section limit"
          )
        end
        if @max_continuation_frames < 0
          raise ArgumentError.new(
            "maximum CONTINUATION frame count cannot be negative"
          )
        end
      end

      private def validate_table_limits! : Nil
        if @max_encoder_table_size < 0
          raise ArgumentError.new(
            "maximum encoder table size cannot be negative"
          )
        end
        if @max_decoder_table_size < 0
          raise ArgumentError.new(
            "maximum decoder table size cannot be negative"
          )
        end
      end

      private def synchronize_disabled_push!
        identifier = Frame::Settings::Identifier::ENABLE_PUSH.to_u16
        advertised = @initial_settings.reverse_each.find do |setting|
          setting.identifier == identifier
        end

        if advertised
          unless advertised.value.zero?
            raise ArgumentError.new(
              "server push is not supported; SETTINGS_ENABLE_PUSH must be 0"
            )
          end
        else
          @initial_settings << Frame::Settings::Setting.new(
            Frame::Settings::Identifier::ENABLE_PUSH,
            0_u32
          )
        end
      end

      private def synchronize_advertised_frame_size!
        identifier = Frame::Settings::Identifier::MAX_FRAME_SIZE.to_u16
        advertised = @initial_settings.reverse_each.find do |setting|
          setting.identifier == identifier
        end

        if advertised
          unless advertised.value == @inbound_max_frame_size
            raise ArgumentError.new(
              "SETTINGS_MAX_FRAME_SIZE must match inbound_max_frame_size"
            )
          end
        elsif @inbound_max_frame_size != FrameHeader::DEFAULT_MAX_PAYLOAD
          @initial_settings << Frame::Settings::Setting.new(
            Frame::Settings::Identifier::MAX_FRAME_SIZE,
            @inbound_max_frame_size.to_u32
          )
        end
      end

      private def synchronize_advertised_header_table_size!
        identifier = Frame::Settings::Identifier::HEADER_TABLE_SIZE.to_u16
        advertised = @initial_settings.reverse_each.find do |setting|
          setting.identifier == identifier
        end

        if advertised
          if advertised.value > @max_decoder_table_size
            raise ArgumentError.new(
              "SETTINGS_HEADER_TABLE_SIZE exceeds max_decoder_table_size"
            )
          end
        elsif @max_decoder_table_size <
                SettingsState::DEFAULT_HEADER_TABLE_SIZE
          @initial_settings << Frame::Settings::Setting.new(
            Frame::Settings::Identifier::HEADER_TABLE_SIZE,
            @max_decoder_table_size.to_u32
          )
        end
      end

      private def synchronize_advertised_field_section_size!
        identifier = Frame::Settings::Identifier::MAX_HEADER_LIST_SIZE.to_u16
        advertised = @initial_settings.reverse_each.find do |setting|
          setting.identifier == identifier
        end

        if advertised
          if advertised.value > @max_decoded_field_section_size
            raise ArgumentError.new(
              "SETTINGS_MAX_HEADER_LIST_SIZE exceeds " \
              "max_decoded_field_section_size"
            )
          end
        else
          @initial_settings << Frame::Settings::Setting.new(
            Frame::Settings::Identifier::MAX_HEADER_LIST_SIZE,
            @max_decoded_field_section_size.to_u32
          )
        end
      end

      private def synchronize_advertised_initial_window_size!
        identifier = Frame::Settings::Identifier::INITIAL_WINDOW_SIZE.to_u16
        advertised = @initial_settings.reverse_each.find do |setting|
          setting.identifier == identifier
        end

        if advertised
          if advertised.value > @max_buffered_body_bytes.to_u32
            raise ArgumentError.new(
              "SETTINGS_INITIAL_WINDOW_SIZE exceeds " \
              "max_buffered_body_bytes"
            )
          end
        elsif @max_buffered_body_bytes <
                SettingsState::DEFAULT_INITIAL_WINDOW_SIZE
          @initial_settings << Frame::Settings::Setting.new(
            Frame::Settings::Identifier::INITIAL_WINDOW_SIZE,
            @max_buffered_body_bytes.to_u32
          )
        end
      end
    end
  end
end
