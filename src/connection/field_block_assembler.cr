module HTTP2
  class Connection
    # Reassembles one contiguous HEADERS/PUSH_PROMISE and CONTINUATION
    # sequence while enforcing compressed-size and fragment-count bounds.
    class FieldBlockAssembler
      alias OpeningFrame = Frame::Headers | Frame::PushPromise
      alias Result = (Frames | FieldBlock)?

      @pending : Pending?

      def initialize(
        @max_compressed_size : Int32,
        @max_continuation_frames : Int32,
      )
        if @max_compressed_size < 0
          raise ArgumentError.new(
            "maximum compressed field-block size cannot be negative"
          )
        end
        if @max_continuation_frames < 0
          raise ArgumentError.new(
            "maximum CONTINUATION frame count cannot be negative"
          )
        end
      end

      def pending?
        !@pending.nil?
      end

      def process(frame : Frames) : Result
        if pending = @pending
          return continue(pending, frame)
        end

        case frame
        when Frame::Headers
          open(frame)
        when Frame::PushPromise
          open(frame)
        when Frame::Continuation
          raise ProtocolError.new(
            "CONTINUATION frame did not follow an open field block"
          )
        else
          frame
        end
      end

      private def open(frame : OpeningFrame) : FieldBlock?
        fragment = frame.header_block_fragment
        check_size!(fragment.size)

        if frame.end_headers?
          # `fragment` is a subslice of `frame`'s own payload, freshly
          # allocated by `Frame.read` for this frame alone and owned by
          # nobody else — `decode_field_block` consumes it synchronously
          # on this fiber and the block is never retained past that, so
          # handing it out without a copy is safe. See `FieldBlock#encoded`.
          return build(frame, fragment, 0)
        end

        @pending = Pending.new(frame, fragment)
        nil
      end

      private def continue(pending : Pending, frame : Frames) : FieldBlock?
        continuation = frame.as?(Frame::Continuation)
        unless continuation && continuation.stream_id == pending.stream_id
          raise ProtocolError.new(
            "an open field block must be followed by CONTINUATION frames " \
            "on stream #{pending.stream_id}"
          )
        end

        next_count = pending.continuation_count + 1
        if next_count > @max_continuation_frames
          raise ResourceLimitError.new(
            "field block exceeds the configured CONTINUATION frame limit"
          )
        end

        check_size!(pending.size.to_i64 + continuation.payload.size)
        pending.append(continuation.header_block_fragment)
        return unless continuation.end_headers?

        @pending = nil
        build(
          pending.opening_frame,
          pending.to_slice,
          next_count
        )
      end

      private def build(
        frame : OpeningFrame,
        encoded : Bytes,
        continuation_count : Int32,
      ) : FieldBlock
        case frame
        when Frame::Headers
          FieldBlock.from(frame, encoded, continuation_count)
        when Frame::PushPromise
          FieldBlock.from(frame, encoded, continuation_count)
        else
          raise "BUG: unsupported field-block opening frame"
        end
      end

      private def check_size!(size : Int) : Nil
        check_size!(size.to_i64)
      end

      private def check_size!(size : Int64) : Nil
        return if size <= @max_compressed_size

        raise ResourceLimitError.new(
          "compressed field block exceeds #{@max_compressed_size} octets"
        )
      end

      private class Pending
        getter opening_frame : OpeningFrame
        getter continuation_count : Int32 = 0
        getter output : IO::Memory

        def initialize(
          @opening_frame : OpeningFrame,
          first_fragment : Bytes,
        )
          @output = IO::Memory.new(first_fragment.size)
          @output.write(first_fragment)
        end

        def stream_id : UInt32
          opening_frame.stream_id
        end

        def size : Int32
          output.size
        end

        def append(fragment : Bytes) : Nil
          output.write(fragment)
          @continuation_count += 1
        end

        def to_slice : Bytes
          # `@pending` is nulled by `continue` before this runs (see
          # caller), so this `Pending` — and the `IO::Memory` it wraps —
          # has no other owner; the caller doesn't touch `output` again.
          # Safe to hand out the buffer itself without a copy.
          output.to_slice
        end
      end
    end
  end
end
