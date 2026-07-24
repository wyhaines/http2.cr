module HTTP2
  # A registered stream mailbox. The full RFC state machine is added in Phase 4.
  class Stream
    enum State
      Idle
      ReservedLocal
      ReservedRemote
      Open
      HalfClosedLocal
      HalfClosedRemote
      Closed
    end

    getter id : UInt32

    @events : Channel(Frames)
    @state : State = State::Idle
    @terminal_signal = Channel(Nil).new
    @terminal_error : Exception?
    @mutex = Mutex.new

    def initialize(
      @connection : Connection,
      @id : UInt32,
      event_capacity : Int32,
    )
      if @id.zero?
        raise ArgumentError.new("stream 0 cannot be registered")
      end
      if @id > FrameHeader::MAX_STREAM_ID
        raise ArgumentError.new("stream ID must be a 31-bit unsigned integer")
      end
      if event_capacity <= 0
        raise ArgumentError.new("stream event capacity must be positive")
      end
      @events = Channel(Frames).new(event_capacity)
    end

    # Sends a frame that belongs to this stream through the ordered writer.
    def send(frame : Frames) : Nil
      raise_terminal! if terminal_error

      unless frame.stream_id == id
        raise ArgumentError.new(
          "frame stream ID #{frame.stream_id} does not match stream #{id}"
        )
      end
      @connection.write_frame(frame)
    end

    # Waits for the next raw inbound frame for this stream.
    def receive(timeout : Time::Span? = nil) : Frames
      raise_terminal! if terminal_error

      if timeout
        select
        when frame = @events.receive
          frame
        when @terminal_signal.receive?
          raise_terminal!
        when timeout(timeout)
          raise Connection::TimeoutError.new(
            "waiting for stream #{id} timed out"
          )
        end
      else
        select
        when frame = @events.receive
          frame
        when @terminal_signal.receive?
          raise_terminal!
        end
      end
    end

    def state : State
      @mutex.synchronize { @state }
    end

    def terminal_error : Exception?
      @mutex.synchronize { @terminal_error }
    end

    def close : Nil
      @connection.remove_stream(self)
      terminate(Connection::ClosedError.new("HTTP/2 stream #{id} closed"))
    end

    # :nodoc:
    def deliver(frame : Frames) : Bool
      return false if terminal_error

      select
      when @events.send(frame)
        true
      else
        false
      end
    rescue Channel::ClosedError
      false
    end

    # :nodoc:
    def terminate(error : Exception) : Nil
      terminated = @mutex.synchronize do
        if @terminal_error
          false
        else
          @terminal_error = error
          @state = State::Closed
          true
        end
      end
      @terminal_signal.close if terminated
    end

    private def raise_terminal! : NoReturn
      if error = terminal_error
        raise error
      end

      raise Connection::ClosedError.new("HTTP/2 stream #{id} is closed")
    end
  end
end
