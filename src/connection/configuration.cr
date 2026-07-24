module HTTP2
  class Connection
    # Resource limits and the SETTINGS sent in the client connection preface.
    class Configuration
      @initial_settings : Array(Frame::Settings::Setting)

      getter inbound_max_frame_size : Int32
      getter writer_queue_capacity : Int32
      getter stream_event_capacity : Int32

      def initialize(
        @inbound_max_frame_size : Int32 = FrameHeader::DEFAULT_MAX_PAYLOAD,
        @writer_queue_capacity : Int32 = 32,
        @stream_event_capacity : Int32 = 32,
        initial_settings : Enumerable(Frame::Settings::Setting) = [] of Frame::Settings::Setting,
      )
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

        @initial_settings = initial_settings.map { |setting| setting }
        synchronize_advertised_frame_size!
      end

      def initial_settings : Array(Frame::Settings::Setting)
        @initial_settings.dup
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
    end
  end
end
