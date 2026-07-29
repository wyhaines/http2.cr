require "./stream_body"

module HTTP2
  # A registered HTTP/2 stream and its bounded inbound event mailbox.
  class Stream
    # :nodoc:
    abstract class InboundValidator
      abstract def validate(section : Connection::FieldSection) : Nil
      abstract def validate_data(size : Int32, end_stream : Bool) : Nil
    end

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
    getter body : StreamBody

    # `@state`, `@send_window`, and `@receive_window` are `Atomic`, not
    # mutex-guarded: every mutator (`#transition_to`, `#adjust_send_window`,
    # `#adjust_receive_window`, `#send_window=`, `#receive_window=`) is
    # called only from `Connection`, and every one of those call sites runs
    # inside `Connection#@mutex.synchronize` — which already serializes the
    # compound read-then-write sequences (read old state/window, decide,
    # write new state/window) these methods take part in. The atomics let a
    # single read or write skip a lock of its own; they do not replace that
    # connection-level serialization, so a new mutator must be added only
    # under the connection lock too.
    #
    # Call-site categories, all under `Connection#@mutex`:
    #   - inbound frame dispatch (`accept_inbound_data`,
    #     `transition_and_deliver`, `handle_inbound_reset`, `handle_goaway`)
    #   - outbound DATA planning (`plan_scheduled_data_frame`,
    #     `prepare_outbound` and its `*_unlocked` helpers)
    #   - WINDOW_UPDATE / SETTINGS window handling (`handle_window_update`,
    #     `apply_peer_initial_window_size_unlocked`,
    #     `apply_local_initial_window_size_unlocked`)
    #
    # The one exception: `#terminate` can run *without* the connection lock
    # held (`Connection#handle_inbound_reset` calls `stream.terminate` after
    # its own `@mutex.synchronize` block has already returned), so its
    # `@terminal_error` check-and-set — and the `@state` write folded into
    # it — stays under this `Stream`'s own `@mutex` instead.
    @events : Channel(StreamEvent)
    @state : Atomic(State) = Atomic.new(State::Idle)
    @send_window : Atomic(Int64)
    @receive_window : Atomic(Int64)
    @terminal_signal = Channel(Nil).new
    @terminal_error : Exception?
    @inbound_validator : InboundValidator?
    @mutex = Mutex.new
    @outbound_mutex = Mutex.new

    def initialize(
      @connection : Connection,
      @id : UInt32,
      event_capacity : Int32,
      send_window : Int64,
      receive_window : Int64,
      body_capacity : Int32,
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
      @send_window = Atomic.new(send_window)
      @receive_window = Atomic.new(receive_window)
      @body = StreamBody.new(
        body_capacity,
        ->(amount : Int32) do
          @connection.release_receive_credit(@id, amount)
        end,
        -> { cancel }
      )
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

      @outbound_mutex.synchronize do
        if data = frame.as?(Frame::Data)
          @connection.send_data_frame(data)
        else
          @connection.write_frame(frame)
        end
      end
    end

    # Encodes and atomically sends an ordered field section.
    def send_headers(
      fields : Enumerable(HeaderField),
      *,
      end_stream : Bool = false,
    ) : Nil
      raise_terminal! if terminal_error
      @outbound_mutex.synchronize do
        @connection.send_headers(id, fields, end_stream: end_stream)
      end
    end

    # Enqueues one ordered field section without waiting for the write to
    # complete. Used only by `Client#open_request_stream` to release its
    # per-connection `opening_mutex` before blocking on a write bounded by
    # `@timeouts.write` — see that method's comment for the wire-ordering
    # argument this depends on.
    #
    # :nodoc:
    def submit_headers(
      fields : Enumerable(HeaderField),
      *,
      end_stream : Bool = false,
    ) : Connection::WriteCommand
      raise_terminal! if terminal_error
      @outbound_mutex.synchronize do
        @connection.submit_headers(id, fields, end_stream: end_stream)
      end
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

    # Sends DATA while respecting connection and stream flow control. Large
    # buffers are split into bounded writer commands and wire frames.
    def send_data(
      data : Bytes,
      *,
      end_stream : Bool = false,
    ) : Nil
      raise_terminal! if terminal_error
      @outbound_mutex.synchronize do
        @connection.send_data(id, data, end_stream: end_stream)
      end
    end

    def send_data(
      data : String,
      *,
      end_stream : Bool = false,
    ) : Nil
      send_data(data.to_slice, end_stream: end_stream)
    end

    # Streams an IO without rewinding it. The END_STREAM flag is placed on the
    # final nonempty frame, or on one empty DATA frame when the IO is empty.
    def send_data(
      source : IO,
      *,
      end_stream : Bool = true,
    ) : Nil
      raise_terminal! if terminal_error
      @outbound_mutex.synchronize do
        @connection.send_data(id, source, end_stream: end_stream)
      end
    rescue error
      begin
        cancel unless closed?
      rescue
        # Preserve the body source or connection error that stopped streaming.
      end
      raise error
    end

    # Waits for the next inbound non-DATA frame or decoded field section.
    # Response DATA is available through #body.
    def receive(
      timeout : Time::Span? = nil,
      cancellation : Channel(Nil)? = nil,
    ) : StreamEvent
      raise_terminal! if terminal_error

      if timeout && cancellation
        receive_with_timeout_and_cancellation(timeout, cancellation)
      elsif timeout
        receive_with_timeout(timeout)
      elsif cancellation
        receive_with_cancellation(cancellation)
      else
        receive_without_deadline
      end
    end

    # Waits for one metadata event, returning nil when the remote message
    # ends. When `timeout` is given, raises `Connection::TimeoutError`
    # instead of continuing to block once it elapses, without otherwise
    # disturbing the stream — used by the response monitor to detect an
    # abandoned response (see `HTTP2::Client#monitor_response`) while
    # leaving a reader that is still actively draining the body alone.
    #
    # :nodoc:
    def receive_until_remote_end(
      cancellation : Channel(Nil)? = nil,
      timeout : Time::Span? = nil,
    ) : StreamEvent?
      if @body.completed?
        select
        when event = @events.receive?
          # See `#raise_terminal!` for why nil falls through below
          # instead of raising past this select.
          return event if event
          return if @body.finished?
          raise_terminal!
        else
          return if @body.finished?
          raise_terminal!
        end
      end

      if timeout && cancellation
        receive_until_remote_end_with_timeout_and_cancellation(
          timeout,
          cancellation
        )
      elsif timeout
        receive_until_remote_end_with_timeout(timeout)
      elsif cancellation
        receive_until_remote_end_with_cancellation(cancellation)
      else
        receive_until_remote_end_without_deadline
      end
    end

    def state : State
      @state.get
    end

    def closed?
      state.closed?
    end

    def terminal_error : Exception?
      @mutex.synchronize { @terminal_error }
    end

    # :nodoc:
    def terminal_signal : Channel(Nil)
      @terminal_signal
    end

    def send_window : Int64
      @send_window.get
    end

    def receive_window : Int64
      @receive_window.get
    end

    # Cancels an active stream with RST_STREAM(CANCEL). An idle stream has not
    # appeared on the wire and is closed locally without sending a reset.
    def cancel(error_code : ErrorCode = ErrorCode::CANCEL) : Nil
      @connection.cancel_stream(self, error_code)
    end

    def close : Nil
      cancel
    end

    # Terminates local work with a caller-selected public error.
    #
    # :nodoc:
    def abort(
      error : Exception,
      error_code : ErrorCode = ErrorCode::CANCEL,
    ) : Nil
      @connection.cancel_stream(self, error_code, error)
    end

    # :nodoc:
    def inbound_validator=(validator : InboundValidator) : Nil
      @mutex.synchronize do
        unless @state.get.idle?
          raise Connection::InvalidStateError.new(
            "an inbound validator must be installed before a stream opens"
          )
        end
        @inbound_validator = validator
      end
    end

    # :nodoc:
    def validate_inbound(section : Connection::FieldSection) : Nil
      validator = @mutex.synchronize { @inbound_validator }
      validator.try(&.validate(section))
    end

    # :nodoc:
    def validate_inbound_data(size : Int32, end_stream : Bool) : Nil
      validator = @mutex.synchronize { @inbound_validator }
      validator.try(&.validate_data(size, end_stream))
    end

    # :nodoc:
    #
    # Not internally synchronized — see the comment above the `@state`/
    # `@send_window`/`@receive_window` declarations for the invariant this
    # relies on and its one exception.
    def transition_to(next_state : State) : Nil
      @state.set(next_state)
    end

    # :nodoc:
    #
    # `Atomic#add` returns the OLD value, so the new (post-adjustment) value
    # callers expect is the old value plus the delta just applied.
    def adjust_send_window(delta : Int64) : Int64
      @send_window.add(delta) + delta
    end

    # :nodoc:
    def send_window=(value : Int64) : Nil
      @send_window.set(value)
    end

    # :nodoc:
    #
    # `Atomic#add` returns the OLD value, so the new (post-adjustment) value
    # callers expect is the old value plus the delta just applied.
    def adjust_receive_window(delta : Int64) : Int64
      @receive_window.add(delta) + delta
    end

    # :nodoc:
    def receive_window=(value : Int64) : Nil
      @receive_window.set(value)
    end

    # :nodoc:
    def finish_body : Nil
      @body.finish
    end

    # :nodoc:
    # The slice is owned by the body from this call on.
    def deliver_data(data : Bytes) : Bool
      @body.enqueue(data)
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
      # The live path for a frame racing `#terminate`: the mailbox closed
      # between the `terminal_error` check above and this send (`#terminate`
      # closes `@events` to release buffered events promptly). Not dead
      # code — this is the intended outcome, matching `deliver`'s existing
      # failure convention.
      false
    end

    # :nodoc:
    def terminate(error : Exception) : Int32
      terminated = @mutex.synchronize do
        if @terminal_error
          false
        else
          @terminal_error = error
          @state.set(State::Closed)
          true
        end
      end
      return 0 unless terminated

      discarded = @body.terminate(error)
      @terminal_signal.close

      # Release every buffered `StreamEvent` (each potentially holding a
      # frame payload) promptly instead of letting them live in the
      # mailbox until this `Stream` is collected. `receive?` returns nil
      # once the channel is both closed and drained, ending the loop.
      @events.close
      while @events.receive?
      end

      discarded
    end

    # Every `@events.receive?` below treats a nil result (the mailbox
    # closed and drained) the same way it treats `@terminal_signal` firing
    # or an empty non-blocking `else`: raise the terminal error. `@events`
    # is only ever closed from `#terminate`, which sets `@terminal_error`
    # in the same call before closing anything, so nil here unambiguously
    # means "terminated" — a raw `receive` would instead surface a bare
    # `Channel::ClosedError`, since `select` short-circuits on whichever
    # operation resolves first, in source order, and `@events` is always
    # listed first. Routing every site through this same raise also keeps
    # the outcome race-proof: termination reads identically regardless of
    # which channel's close a concurrent select happens to notice first.
    private def raise_terminal! : NoReturn
      if error = terminal_error
        raise error
      end

      raise Connection::ClosedError.new("HTTP/2 stream #{id} is closed")
    end

    private def receive_after_body_completion : StreamEvent?
      select
      when event = @events.receive?
        # See `#raise_terminal!` for why nil falls through below.
        return event if event
        return if @body.finished?
        raise_terminal!
      else
        return if @body.finished?
        raise_terminal!
      end
    end

    private def receive_until_remote_end_with_timeout_and_cancellation(
      duration : Time::Span,
      cancellation : Channel(Nil),
    ) : StreamEvent?
      select
      when event = @events.receive?
        # See `#raise_terminal!` for why nil routes here.
        event || raise_terminal!
      when @body.completion_signal.receive?
        receive_after_body_completion
      when @terminal_signal.receive?
        raise_terminal!
      when cancellation.receive?
        raise WaitCanceledError.new("waiting for stream #{id} was canceled")
      when timeout(duration)
        raise Connection::TimeoutError.new(
          "waiting for stream #{id} response metadata timed out"
        )
      end
    end

    private def receive_until_remote_end_with_timeout(
      duration : Time::Span,
    ) : StreamEvent?
      select
      when event = @events.receive?
        # See `#raise_terminal!` for why nil routes here.
        event || raise_terminal!
      when @body.completion_signal.receive?
        receive_after_body_completion
      when @terminal_signal.receive?
        raise_terminal!
      when timeout(duration)
        raise Connection::TimeoutError.new(
          "waiting for stream #{id} response metadata timed out"
        )
      end
    end

    private def receive_until_remote_end_with_cancellation(
      cancellation : Channel(Nil),
    ) : StreamEvent?
      select
      when event = @events.receive?
        # See `#raise_terminal!` for why nil routes here.
        event || raise_terminal!
      when @body.completion_signal.receive?
        receive_after_body_completion
      when @terminal_signal.receive?
        raise_terminal!
      when cancellation.receive?
        raise WaitCanceledError.new("waiting for stream #{id} was canceled")
      end
    end

    private def receive_until_remote_end_without_deadline : StreamEvent?
      select
      when event = @events.receive?
        # See `#raise_terminal!` for why nil routes here.
        event || raise_terminal!
      when @body.completion_signal.receive?
        receive_after_body_completion
      when @terminal_signal.receive?
        raise_terminal!
      end
    end

    private def receive_with_timeout_and_cancellation(
      duration : Time::Span,
      cancellation : Channel(Nil),
    ) : StreamEvent
      select
      when frame = @events.receive?
        # See `#raise_terminal!` for why nil routes here.
        frame || raise_terminal!
      when @terminal_signal.receive?
        raise_terminal!
      when cancellation.receive?
        raise WaitCanceledError.new("waiting for stream #{id} was canceled")
      when timeout(duration)
        raise Connection::TimeoutError.new(
          "waiting for stream #{id} timed out"
        )
      end
    end

    private def receive_with_timeout(duration : Time::Span) : StreamEvent
      select
      when frame = @events.receive?
        # See `#raise_terminal!` for why nil routes here.
        frame || raise_terminal!
      when @terminal_signal.receive?
        raise_terminal!
      when timeout(duration)
        raise Connection::TimeoutError.new(
          "waiting for stream #{id} timed out"
        )
      end
    end

    private def receive_with_cancellation(
      cancellation : Channel(Nil),
    ) : StreamEvent
      select
      when frame = @events.receive?
        # See `#raise_terminal!` for why nil routes here.
        frame || raise_terminal!
      when @terminal_signal.receive?
        raise_terminal!
      when cancellation.receive?
        raise WaitCanceledError.new("waiting for stream #{id} was canceled")
      end
    end

    private def receive_without_deadline : StreamEvent
      select
      when frame = @events.receive?
        # See `#raise_terminal!` for why nil routes here.
        frame || raise_terminal!
      when @terminal_signal.receive?
        raise_terminal!
      end
    end

    # :nodoc:
    class WaitCanceledError < Exception
    end
  end
end
