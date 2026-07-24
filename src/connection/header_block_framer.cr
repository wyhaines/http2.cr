module HTTP2
  class Connection
    # Splits one encoded field block into an atomic HEADERS/CONTINUATION batch.
    class HeaderBlockFramer
      def self.frames(
        stream_id : UInt32,
        encoded : Bytes,
        max_frame_size : Int,
        *,
        end_stream : Bool = false,
      ) : Array(Frames)
        if max_frame_size <= 0
          raise ArgumentError.new("maximum frame size must be positive")
        end

        frames = [] of Frames
        if encoded.empty?
          flags = Frame::Headers::Flags::END_HEADERS
          flags |= Frame::Headers::Flags::END_STREAM if end_stream
          frames << Frame::Headers.new(flags, stream_id, Bytes.empty)
          return frames
        end

        offset = 0
        first = true
        while offset < encoded.size
          length = Math.min(max_frame_size, encoded.size - offset)
          final = offset + length == encoded.size
          fragment = encoded[offset, length]

          if first
            flags = Frame::Headers::Flags::None
            flags |= Frame::Headers::Flags::END_HEADERS if final
            flags |= Frame::Headers::Flags::END_STREAM if end_stream
            frames << Frame::Headers.new(flags, stream_id, fragment)
            first = false
          else
            flags = final ? Frame::Continuation::Flags::END_HEADERS : Frame::Continuation::Flags::None
            frames << Frame::Continuation.new(flags, stream_id, fragment)
          end

          offset += length
        end

        frames
      end
    end
  end
end
