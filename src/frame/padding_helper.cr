module HTTP2
  abstract struct Frame
    module PaddingHelper
      macro included
        def padded?
          flags.includes?(Flags::PADDED)
        end

        # If the frame has padding enabled, this byte will contain the length of the padding
        def pad_length : UInt8
          padded? ? payload[0] : 0_u8
        end

        protected def padding_offset
          padded? ? 1 : 0
        end

        def data_offset
          padding_offset
        end

        def padding
          length = pad_length.to_i
          return Bytes.empty if length.zero?

          payload[payload.size - length, length]
        end

        def data
          payload[data_offset, payload.size - data_offset - pad_length.to_i]
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
        end
      end
    end
  end
end
