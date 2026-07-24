module HTTP2
  class Connection
    # Bounds peer work caused by excessive control and empty frames.
    #
    # :nodoc:
    class InboundFrameRateLimiter
      @window_started = Time.instant
      @control_frames = 0
      @empty_frames = 0

      def initialize(
        @window : Time::Span,
        @max_control_frames : Int32,
        @max_empty_frames : Int32,
      )
      end

      def check(frame : Frames) : Nil
        reset_window_if_needed

        if control_frame?(frame)
          @control_frames += 1
          if @control_frames > @max_control_frames
            raise ResourceLimitError.new(
              "peer exceeded the inbound control-frame rate limit"
            )
          end
        end

        if frame.payload.empty?
          @empty_frames += 1
          if @empty_frames > @max_empty_frames
            raise ResourceLimitError.new(
              "peer exceeded the inbound empty-frame rate limit"
            )
          end
        end
      end

      private def reset_window_if_needed : Nil
        now = Time.instant
        return if now - @window_started < @window

        @window_started = now
        @control_frames = 0
        @empty_frames = 0
      end

      private def control_frame?(frame : Frames) : Bool
        frame.is_a?(Frame::Settings) ||
          frame.is_a?(Frame::Ping) ||
          frame.is_a?(Frame::Priority) ||
          frame.is_a?(Frame::ResetStream) ||
          frame.is_a?(Frame::WindowUpdate)
      end
    end
  end
end
