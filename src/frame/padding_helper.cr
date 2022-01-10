module HTTP2
  abstract struct Frame
    module PaddingHelper
      macro included
        def padded?
          flags.includes?(Flags::PADDED)
        end

        # If the frame has padding enabled, this byte will contain the length of the padding
        def pad_length : UInt8
          if padded?
            payload[0].to_u8
          else
            0_u8
          end
        end

        protected def padding_offset
          if padded?
            1
          else
            0
          end
        end

        def data_offset
          padding_offset
        end

        def padding
          if padded?
            (-1 * (pad_length + 1)) == -1 ? Bytes.empty : payload[(-1 * (pad_length))..(-1)]
          else
            Bytes.empty
          end
        end

        def data
          payload[data_offset..(-1 * (pad_length + 1))]
        end

      end
    end
  end
end
