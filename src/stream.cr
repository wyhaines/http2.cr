module HTTP2
  # A registered HTTP/2 stream and its bounded inbound event mailbox.
  class Stream
    enum State
      Idle
      ReservedLocal
      ReservedRemote
      Open
      HalfClosedLocal
      HalfClosedRemote
      Closed

      def active?
        open? || half_closed_local? || half_closed_remote?
      end
    end

    # The state-changing logical events defined by RFC 9113. CONTINUATION is
    # part of the HEADERS or PUSH_PROMISE event that opened its field block.
    enum Event
      SendHeaders
      SendHeadersEndStream
      ReceiveHeaders
      ReceiveHeadersEndStream
      SendData
      SendDataEndStream
      ReceiveData
      ReceiveDataEndStream
      SendReset
      ReceiveReset
      SendPriority
      ReceivePriority
      SendWindowUpdate
      ReceiveWindowUpdate
      SendPushPromise
      ReceivePushPromise

      def inbound?
        receive_headers? ||
          receive_headers_end_stream? ||
          receive_data? ||
          receive_data_end_stream? ||
          receive_reset? ||
          receive_priority? ||
          receive_window_update? ||
          receive_push_promise?
      end
    end

    getter id : UInt32

    @events : Channel(StreamEvent)
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
      @events = Channel(StreamEvent).new(event_capacity)
    end

    # An exhaustive transition table for standard stream-associated frames.
    # Connection frames and unknown extension frames do not alter stream state.
    module StateMachine
      enum Action
        Allow
        Ignore
        LocalError
        StreamError
        ConnectionError
      end

      record Transition,
        action : Action,
        next_state : State? = nil,
        error_code : ErrorCode? = nil

      private A_IDLE    = Transition.new(Action::Allow, State::Idle)
      private A_RLOCAL  = Transition.new(Action::Allow, State::ReservedLocal)
      private A_RREMOTE = Transition.new(
        Action::Allow,
        State::ReservedRemote
      )
      private A_OPEN   = Transition.new(Action::Allow, State::Open)
      private A_HLOCAL = Transition.new(
        Action::Allow,
        State::HalfClosedLocal
      )
      private A_HREMOTE = Transition.new(
        Action::Allow,
        State::HalfClosedRemote
      )
      private A_CLOSED = Transition.new(Action::Allow, State::Closed)
      private IGNORE   = Transition.new(Action::Ignore)
      private LOCAL    = Transition.new(Action::LocalError)
      private CONN     = Transition.new(
        Action::ConnectionError,
        error_code: ErrorCode::PROTOCOL_ERROR
      )
      private CONN_CLOSED = Transition.new(
        Action::ConnectionError,
        error_code: ErrorCode::STREAM_CLOSED
      )
      private STREAM_CLOSED = Transition.new(
        Action::StreamError,
        error_code: ErrorCode::STREAM_CLOSED
      )

      # Entries in every row follow Event declaration order.
      private TABLE = [
        # idle
        [
          A_OPEN, A_HLOCAL, A_OPEN, A_HREMOTE,
          LOCAL, LOCAL, CONN, CONN,
          LOCAL, CONN, A_IDLE, A_IDLE,
          LOCAL, CONN, LOCAL, CONN,
        ] of Transition,
        # reserved (local)
        [
          A_HREMOTE, A_CLOSED, CONN, CONN,
          LOCAL, LOCAL, CONN, CONN,
          A_CLOSED, A_CLOSED, A_RLOCAL, A_RLOCAL,
          LOCAL, A_RLOCAL, LOCAL, CONN,
        ] of Transition,
        # reserved (remote)
        [
          LOCAL, LOCAL, A_HLOCAL, A_CLOSED,
          LOCAL, LOCAL, CONN, CONN,
          A_CLOSED, A_CLOSED, A_RREMOTE, A_RREMOTE,
          A_RREMOTE, CONN, LOCAL, CONN,
        ] of Transition,
        # open
        [
          A_OPEN, A_HLOCAL, A_OPEN, A_HREMOTE,
          A_OPEN, A_HLOCAL, A_OPEN, A_HREMOTE,
          A_CLOSED, A_CLOSED, A_OPEN, A_OPEN,
          A_OPEN, A_OPEN, A_OPEN, A_OPEN,
        ] of Transition,
        # half-closed (local)
        [
          LOCAL, LOCAL, A_HLOCAL, A_CLOSED,
          LOCAL, LOCAL, A_HLOCAL, A_CLOSED,
          A_CLOSED, A_CLOSED, A_HLOCAL, A_HLOCAL,
          A_HLOCAL, A_HLOCAL, LOCAL, A_HLOCAL,
        ] of Transition,
        # half-closed (remote)
        [
          A_HREMOTE, A_CLOSED, STREAM_CLOSED, STREAM_CLOSED,
          A_HREMOTE, A_CLOSED, STREAM_CLOSED, STREAM_CLOSED,
          A_CLOSED, A_CLOSED, A_HREMOTE, A_HREMOTE,
          A_HREMOTE, A_HREMOTE, A_HREMOTE, CONN,
        ] of Transition,
        # closed
        [
          LOCAL, LOCAL, CONN_CLOSED, CONN_CLOSED,
          LOCAL, LOCAL, CONN_CLOSED, CONN_CLOSED,
          LOCAL, IGNORE, A_CLOSED, IGNORE,
          LOCAL, IGNORE, LOCAL, CONN,
        ] of Transition,
      ] of Array(Transition)

      def self.transition(state : State, event : Event) : Transition
        TABLE[state.value][event.value]
      end

      def self.reserve_local(state : State) : Transition
        return A_RLOCAL if state.idle?

        LOCAL
      end

      def self.reserve_remote(state : State) : Transition
        return A_RREMOTE if state.idle?

        CONN
      end
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

    # Encodes and atomically sends an ordered field section.
    def send_headers(
      fields : Enumerable(HeaderField),
      *,
      end_stream : Bool = false,
    ) : Nil
      raise_terminal! if terminal_error
      @connection.send_headers(id, fields, end_stream: end_stream)
    end

    # Encodes ordered name/value pairs with the default field policy.
    def send_headers(
      fields : Enumerable(Tuple(String, String)),
      *,
      end_stream : Bool = false,
    ) : Nil
      materialized = fields.map do |name, value|
        HeaderField.new(name, value)
      end
      send_headers(materialized, end_stream: end_stream)
    end

    # Waits for the next inbound frame or decoded field section.
    def receive(timeout : Time::Span? = nil) : StreamEvent
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

    def closed?
      state.closed?
    end

    def terminal_error : Exception?
      @mutex.synchronize { @terminal_error }
    end

    # Cancels an active stream with RST_STREAM(CANCEL). An idle stream has not
    # appeared on the wire and is closed locally without sending a reset.
    def cancel(error_code : ErrorCode = ErrorCode::CANCEL) : Nil
      @connection.cancel_stream(self, error_code)
    end

    def close : Nil
      cancel
    end

    # :nodoc:
    def transition_to(next_state : State) : Nil
      @mutex.synchronize { @state = next_state }
    end

    # :nodoc:
    def deliver(event : StreamEvent) : Bool
      return false if terminal_error

      select
      when @events.send(event)
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
