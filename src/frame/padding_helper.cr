module HTTP2
  abstract struct Frame
    # PADDED is bit `0x08` in every frame type that supports padding
    # (DATA, HEADERS, PUSH_PROMISE) -- it doesn't need to be resolved
    # against each type's own `Flags` enum, so this is an ordinary
    # module rather than a `macro included` template.
    module PaddingHelper
      PADDED_BIT = 0x08_u8

      # Precomputed once by `validate_padding!` so `#data` (called 3x per
      # outbound chunk by `WriteCommand::DataBlock`) is a single slice
      # expression instead of re-deriving flags -> pad_length -> two
      # slices on every call.
      @data_offset : Int32 = 0
      @data_size : Int32 = 0

      def padded? : Bool
        (raw_flags & PADDED_BIT) != 0
      end

      # If the frame has padding enabled, this byte will contain the length of the padding
      def pad_length : UInt8
        padded? ? payload[0] : 0_u8
      end

      protected def padding_offset
        padded? ? 1 : 0
      end

      def data_offset : Int32
        @data_offset
      end

      # :nodoc:
      def padding : Bytes
        length = pad_length.to_i
        return Bytes.empty if length.zero?

        payload[payload.size - length, length]
      end

      def data : Bytes
        payload[@data_offset, @data_size]
      end

      protected def validate_padding!(
        mandatory_data_size : Int32 = 0,
        frame_size_scope : ErrorScope = ErrorScope::Connection,
      )
        unless padded?
          if payload.size < mandatory_data_size
            frame_size_error!(
              "#{self.class} payload is too small for its mandatory fields",
              frame_size_scope
            )
          end

          @data_offset = mandatory_data_size
          @data_size = payload.size - mandatory_data_size
          return
        end

        if payload.empty?
          frame_size_error!(
            "#{self.class} payload is missing the Pad Length field",
            frame_size_scope
          )
        end

        if pad_length.to_i >= payload.size
          raise ProtocolError.new(
            "#{self.class} padding is equal to or larger than its payload"
          )
        end

        available = payload.size - padding_offset - pad_length.to_i
        if available < mandatory_data_size
          frame_size_error!(
            "#{self.class} payload is too small for its mandatory fields",
            frame_size_scope
          )
        end

        @data_offset = padding_offset + mandatory_data_size
        @data_size = available - mandatory_data_size
      end
    end
  end
end
