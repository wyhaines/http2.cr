require "openssl"
require "socket"
require "deque"
require "./connection/*"
require "./stream"

module HTTP2
  # Owns one HTTP/2 transport, its ordered writer, reader, and stream registry.
  class Connection
    Preface          = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".to_slice
    DrainQuietPeriod = 10.milliseconds

    enum State
      New
      Handshaking
      Active
      Draining
      Closed
    end

    getter configuration : Configuration
    getter local_settings : Frame::Settings

    @state = State::New
    @terminal_error : Exception?
    @peer_settings : Frame::Settings?
    @local_settings_state : SettingsState
    @effective_local_settings_state = SettingsState.client_defaults
    @peer_settings_state = SettingsState.server_defaults
    @last_goaway : Frame::GoAway?
    @last_sent_goaway : Frame::GoAway?
    @highest_local_opened_stream_id = 0_u32
    @highest_peer_stream_id = 0_u32
    @last_processed_peer_stream_id = 0_u32
    @mutex = Mutex.new
    @submission_mutex = Mutex.new
    @write_queue : Channel(WriteCommand)
    @data_queue : Channel(WriteCommand)
    @handshake_done = Channel(Nil).new
    @closed_signal = Channel(Nil).new
    @transport_close_signal = Channel(Nil).new
    @writer_done = Channel(Nil).new
    @reader_done = Channel(Nil).new
    @transport_closer_done = Channel(Nil).new
    @settings_timer_wakeup = Channel(Nil).new(1)
    @settings_timer_done = Channel(Nil).new
    @drain_wakeup = Channel(Nil).new(1)
    @drain_done = Channel(Nil).new
    @keepalive_wakeup = Channel(Nil).new(1)
    @keepalive_done = Channel(Nil).new
    @writer_started = false
    @preface_sent = false
    @reader_started = false
    @transport_closer_started = false
    @settings_timer_started = false
    @drain_started = false
    @keepalive_started = false
    @drain_deadline : Time::Instant?
    @last_inbound_activity = Time.instant
    @keepalive_sequence = 0_u32
    @streams = {} of UInt32 => Stream
    @closed_streams = {} of UInt32 => ClosedStream
    @closed_stream_order = [] of UInt32
    @stream_ids = StreamIDAllocator.new
    @pending_settings = [] of SettingsAcknowledgement
    @pending_pings = {} of String => Array(PingWaiter)
    @connection_send_window : Int64 = SettingsState::DEFAULT_INITIAL_WINDOW_SIZE.to_i64
    @connection_receive_window : Int64 = SettingsState::DEFAULT_INITIAL_WINDOW_SIZE.to_i64
    @pending_connection_window_update : Int64 = 0_i64
    @pending_stream_window_updates = {} of UInt32 => Int64
    @flow_control_wakeup = Channel(Nil).new(1)
    @pending_data = {} of UInt32 => Deque(WriteCommand)
    @data_schedule = Deque(UInt32).new
    @pending_data_count = 0
    @field_blocks : FieldBlockAssembler
    @inbound_frame_rate_limiter : InboundFrameRateLimiter
    @encoder : HPack::Encoder
    @decoder : HPack::Decoder
    @diagnostics : Channel(Diagnostic)
    @diagnostic_mutex = Mutex.new
    @dropped_diagnostic_count = 0_u64

    def initialize(
      @transport : IO,
      @configuration : Configuration = Configuration.new,
    )
      @write_queue = Channel(WriteCommand).new(
        @configuration.writer_queue_capacity
      )
      @data_queue = Channel(WriteCommand).new(
        @configuration.writer_queue_capacity
      )
      @local_settings = Frame::Settings.new(
        @configuration.initial_settings
      )
      @local_settings_state = SettingsState.client_defaults.with_local(
        @configuration.initial_settings
      )
      @field_blocks = FieldBlockAssembler.new(
        @configuration.max_compressed_field_section_size,
        @configuration.max_continuation_frames
      )
      @inbound_frame_rate_limiter = InboundFrameRateLimiter.new(
        @configuration.inbound_frame_rate_window,
        @configuration.max_control_frames_per_window,
        @configuration.max_empty_frames_per_window
      )
      @encoder = HPack::Encoder.new
      @decoder = HPack::Decoder.new(
        max_decoded_string_size: @configuration.max_decoded_string_size
      )
      initial_encoder_size = Math.min(
        SettingsState::DEFAULT_HEADER_TABLE_SIZE.to_i32,
        @configuration.max_encoder_table_size
      )
      @encoder.resize_table(initial_encoder_size) if initial_encoder_size !=
                                                       SettingsState::DEFAULT_HEADER_TABLE_SIZE.to_i32
      @diagnostics = Channel(Diagnostic).new(
        @configuration.diagnostic_queue_capacity
      )
    end

    # Creates and starts a connection over a caller-supplied duplex IO.
    def self.start(
      transport : IO,
      configuration : Configuration = Configuration.new,
    ) : self
      new(transport, configuration).start
    end

    # Opens a cleartext connection using HTTP/2 prior knowledge.
    #
    # `read_timeout` and `write_timeout` default to `nil` (no transport
    # deadlines). Against untrusted or unreliable peers, set them and/or
    # enable `Configuration#keepalive_interval`; otherwise a silent or
    # write-stalled peer can hold blocked callers indefinitely.
    # `HTTP2::Client` sets `write_timeout` by default and bounds the
    # handshake with a per-wait deadline instead of `read_timeout`; it
    # enables keepalive by default to detect a silent peer once active.
    def self.connect_prior_knowledge(
      host : String,
      port : Int = 80,
      configuration : Configuration = Configuration.new,
      *,
      connect_timeout : Time::Span? = nil,
      read_timeout : Time::Span? = nil,
      write_timeout : Time::Span? = nil,
    ) : self
      transport = TCPSocket.new(
        host,
        port,
        connect_timeout,
        connect_timeout
      )
      transport.read_timeout = read_timeout
      transport.write_timeout = write_timeout
      begin
        new(transport, configuration).start
      rescue error
        transport.close
        raise error
      end
    end

    # Opens a verified TLS connection that requires ALPN to select `h2`.
    #
    # `read_timeout` and `write_timeout` default to `nil` (no transport
    # deadlines). Against untrusted or unreliable peers, set them and/or
    # enable `Configuration#keepalive_interval`; otherwise a silent or
    # write-stalled peer can hold blocked callers indefinitely.
    # `HTTP2::Client` sets `write_timeout` by default and bounds the
    # handshake with a per-wait deadline instead of `read_timeout`; it
    # enables keepalive by default to detect a silent peer once active.
    def self.connect_tls(
      host : String,
      port : Int = 443,
      *,
      server_name : String = host,
      context : OpenSSL::SSL::Context::Client = OpenSSL::SSL::Context::Client.new,
      configuration : Configuration = Configuration.new,
      connect_timeout : Time::Span? = nil,
      read_timeout : Time::Span? = nil,
      write_timeout : Time::Span? = nil,
    ) : self
      transport = TCPSocket.new(
        host,
        port,
        connect_timeout,
        connect_timeout
      )
      transport.read_timeout = read_timeout
      transport.write_timeout = write_timeout
      begin
        start_tls(
          transport,
          server_name,
          context: context,
          configuration: configuration
        )
      rescue error
        transport.close unless transport.closed?
        raise error
      end
    end

    # Wraps a supplied transport in verified TLS and starts HTTP/2.
    def self.start_tls(
      transport : IO,
      server_name : String,
      *,
      context : OpenSSL::SSL::Context::Client = OpenSSL::SSL::Context::Client.new,
      configuration : Configuration = Configuration.new,
    ) : self
      context.alpn_protocol = "h2"
      tls = OpenSSL::SSL::Socket::Client.new(
        transport,
        context,
        sync_close: true,
        hostname: server_name
      )

      unless tls.alpn_protocol == "h2"
        tls.close
        raise TLSNegotiationError.new("the TLS peer did not negotiate ALPN h2")
      end

      new(tls, configuration).start
    rescue error : OpenSSL::SSL::Error
      transport.close unless transport.closed?
      raise TLSVerificationError.new(server_name, error)
    rescue error
      transport.close unless transport.closed?
      raise error
    end

    # Starts the writer, emits the complete client preface atomically, then
    # starts the continuous reader.
    def start : self
      initial_acknowledgement = SettingsAcknowledgement.new(
        @local_settings_state
      )
      initial_command = WriteCommand.new(
        [local_settings] of Frames,
        preface: true
      )
      @mutex.synchronize do
        unless @state.new?
          raise InvalidStateError.new("connection can only be started once")
        end
        @write_queue.send(initial_command)
        @pending_settings << initial_acknowledgement
        @state = State::Handshaking
        @writer_started = true
        @transport_closer_started = true
        spawn_transport_fiber("http2-writer") { writer_loop }
        spawn_transport_fiber("http2-transport-closer") do
          transport_closer_loop
        end
      end

      delta = @configuration.connection_receive_window.to_i64 -
              SettingsState::DEFAULT_INITIAL_WINDOW_SIZE.to_i64
      if delta > 0
        @mutex.synchronize { queue_connection_credit_unlocked(delta) }
        wake_flow_control
      end

      emit_lifecycle("handshaking")

      begin
        initial_command.wait
      rescue error
        terminate(error)
        wait_until_stopped
        raise error
      end

      mark_settings_sent(initial_acknowledgement)
      start_settings_timer

      @mutex.synchronize do
        unless @state.closed?
          @reader_started = true
          spawn_transport_fiber("http2-reader") { reader_loop }
        end
      end
      self
    end

    def state : State
      @mutex.synchronize { @state }
    end

    def active?
      state.active?
    end

    def draining?
      state.draining?
    end

    def closed?
      state.closed?
    end

    def terminal_error : Exception?
      @mutex.synchronize { @terminal_error }
    end

    def peer_settings : Frame::Settings?
      @mutex.synchronize { @peer_settings }
    end

    def local_settings_state : SettingsState
      @mutex.synchronize { @local_settings_state }
    end

    def effective_local_settings_state : SettingsState
      @mutex.synchronize { @effective_local_settings_state }
    end

    def peer_settings_state : SettingsState
      @mutex.synchronize { @peer_settings_state }
    end

    def pending_settings_count : Int32
      @mutex.synchronize { @pending_settings.size }
    end

    def last_goaway : Frame::GoAway?
      @mutex.synchronize { @last_goaway }
    end

    def last_sent_goaway : Frame::GoAway?
      @mutex.synchronize { @last_sent_goaway }
    end

    def active_stream_count : Int32
      @mutex.synchronize do
        @streams.count { |_, stream| stream.state.active? }
      end
    end

    def send_window : Int64
      @mutex.synchronize { @connection_send_window }
    end

    def receive_window : Int64
      @mutex.synchronize { @connection_receive_window }
    end

    def retained_closed_stream_count : Int32
      @mutex.synchronize { @closed_streams.size }
    end

    # A bounded stream of structured connection events. Producers never block;
    # inspect `#dropped_diagnostic_count` to detect a slow consumer.
    def diagnostics : Channel(Diagnostic)
      @diagnostics
    end

    def dropped_diagnostic_count : UInt64
      @diagnostic_mutex.synchronize { @dropped_diagnostic_count }
    end

    def stream?(id : UInt32) : Stream?
      return if id.zero?

      @mutex.synchronize { @streams[id]? }
    end

    def new_stream : Stream
      @mutex.synchronize do
        if @state.draining?
          raise DrainingError.new(
            "new streams cannot be opened on a draining connection"
          )
        end
        unless @state.handshaking? || @state.active?
          raise InvalidStateError.new(
            "new streams require a handshaking or active connection"
          )
        end
        if @streams.size >= @configuration.max_open_streams
          raise OpenStreamLimitError.new(@configuration.max_open_streams)
        end

        id = @stream_ids.allocate
        stream = Stream.new(
          self,
          id,
          @configuration.stream_event_capacity,
          @peer_settings_state.initial_window_size.to_i64,
          @effective_local_settings_state.initial_window_size.to_i64,
          @configuration.max_buffered_body_bytes
        )
        @streams[id] = stream
      end
    end

    # Writes one frame through the connection's sole writer fiber.
    def write_frame(frame : Frames) : Nil
      if data = frame.as?(Frame::Data)
        send_data_frame(data)
        return
      end
      if outbound_field_block_frame?(frame)
        raise ArgumentError.new(
          "field blocks must be sent with #send_headers"
        )
      end
      if settings = frame.as?(Frame::Settings)
        unless settings.ack?
          send_settings(settings.entries)
          return
        end
      end
      if reset = frame.as?(Frame::ResetStream)
        send_reset(
          reset,
          CanceledError.new(reset.stream_id, reset.error_code)
        )
        return
      end

      write_batch([frame] of Frames)
    end

    # Writes a frame batch without allowing another command to interleave.
    def write_batch(frames : Array(Frames)) : Nil
      return if frames.empty?
      if frames.any? { |frame| outbound_field_block_frame?(frame) }
        raise ArgumentError.new(
          "field blocks must be sent with #send_headers"
        )
      end
      if frames.any?(Frame::Data)
        raise ArgumentError.new(
          "DATA frames must be sent individually or with #send_data"
        )
      end
      if frames.any? { |frame| frame.is_a?(Frame::Settings) && !frame.ack? }
        raise ArgumentError.new(
          "non-ACK SETTINGS frames must be sent with #send_settings"
        )
      end
      if frames.any?(Frame::WindowUpdate)
        raise ArgumentError.new(
          "WINDOW_UPDATE frames are managed by connection flow control; " \
          "receive credit is returned by consuming stream bodies"
        )
      end
      if frames.any? { |frame| frame.is_a?(Frame::Settings) && frame.ack? }
        raise ArgumentError.new(
          "SETTINGS acknowledgements are sent automatically by the connection"
        )
      end

      submit(WriteCommand.new(frames.dup))
    end

    # Sends application data through the flow-control scheduler.
    def send_data(
      stream_id : UInt32,
      data : Bytes,
      *,
      end_stream : Bool = false,
    ) : Nil
      ensure_registered_stream!(stream_id)

      if data.empty?
        submit_data(
          Frame::Data.new(
            end_stream ? Frame::Data::Flags::END_STREAM : Frame::Data::Flags.new(0_u8),
            stream_id,
            Bytes.empty
          )
        )
        return
      end

      offset = 0
      chunk_size = @configuration.outbound_data_chunk_size
      while offset < data.size
        size = Math.min(chunk_size, data.size - offset)
        final = offset + size == data.size
        flags = if end_stream && final
                  Frame::Data::Flags::END_STREAM
                else
                  Frame::Data::Flags.new(0_u8)
                end
        submit_data(
          Frame::Data.new(
            flags,
            stream_id,
            data[offset, size].dup
          )
        )
        offset += size
      end
    end

    # Streams DATA from the source's current position without rewinding it.
    def send_data(
      stream_id : UInt32,
      source : IO,
      *,
      end_stream : Bool = true,
    ) : Nil
      ensure_registered_stream!(stream_id)
      chunk_size = @configuration.outbound_data_chunk_size
      current = Bytes.new(chunk_size)
      current_size = source.read(current)

      if current_size.zero?
        send_data(stream_id, Bytes.empty, end_stream: end_stream)
        return
      end

      loop do
        following = Bytes.new(chunk_size)
        following_size = source.read(following)
        final = following_size.zero?
        send_data(
          stream_id,
          current[0, current_size],
          end_stream: end_stream && final
        )
        break if final

        current = following
        current_size = following_size
      end
    end

    # Preserves explicit DATA padding while still applying flow control. A
    # padded frame is atomic because splitting it would change its wire shape.
    #
    # :nodoc:
    def send_data_frame(frame : Frame::Data) : Nil
      ensure_registered_stream!(frame.stream_id)
      submit_data(frame)
    end

    # HPACK-encodes one ordered field section on the writer fiber and sends
    # its complete HEADERS/CONTINUATION sequence atomically.
    def send_headers(
      stream_id : UInt32,
      fields : Enumerable(HeaderField),
      *,
      end_stream : Bool = false,
    ) : Nil
      ensure_registered_stream!(stream_id)
      materialized = fields.map { |field| field }
      submit(
        WriteCommand.headers(
          stream_id,
          materialized,
          end_stream
        )
      )
    end

    # Encodes ordered name/value pairs with the default field policy.
    def send_headers(
      stream_id : UInt32,
      fields : Enumerable(Tuple(String, String)),
      *,
      end_stream : Bool = false,
    ) : Nil
      materialized = fields.map do |name, value|
        HeaderField.new(name, value)
      end
      send_headers(stream_id, materialized, end_stream: end_stream)
    end

    # Sends a SETTINGS update and tracks its ordered acknowledgement.
    def send_settings(
      entries : Enumerable(Frame::Settings::Setting),
    ) : Nil
      materialized = entries.to_a
      command = WriteCommand.new(
        [Frame::Settings.new(materialized)] of Frames
      )
      acknowledgement = @submission_mutex.synchronize do
        pending = @mutex.synchronize do
          raise_terminal_or_state_unlocked! if @state.closed?
          if @state.new?
            raise InvalidStateError.new("connection has not been started")
          end
          if @pending_settings.size >= @configuration.max_pending_settings
            raise QueueFullError.new(
              "pending SETTINGS queue reached its configured limit"
            )
          end

          updated = @local_settings_state.with_local(materialized)
          if updated.enable_push?
            raise ArgumentError.new(
              "server push is not supported; SETTINGS_ENABLE_PUSH must be 0"
            )
          end
          if updated.max_frame_size > @configuration.inbound_max_frame_size
            raise ArgumentError.new(
              "SETTINGS_MAX_FRAME_SIZE exceeds the configured inbound limit"
            )
          end
          if updated.header_table_size > @configuration.max_decoder_table_size
            raise ArgumentError.new(
              "SETTINGS_HEADER_TABLE_SIZE exceeds the configured decoder limit"
            )
          end
          if max_header_list_size = updated.max_header_list_size
            if max_header_list_size >
                 @configuration.max_decoded_field_section_size
              raise ArgumentError.new(
                "SETTINGS_MAX_HEADER_LIST_SIZE exceeds the configured " \
                "decoded field-section limit"
              )
            end
          end
          if updated.initial_window_size >
               @configuration.max_buffered_body_bytes.to_u32
            raise ArgumentError.new(
              "SETTINGS_INITIAL_WINDOW_SIZE exceeds the configured " \
              "body-buffer limit"
            )
          end

          @local_settings_state = updated
          pending_update = SettingsAcknowledgement.new(updated)
          @pending_settings << pending_update
          pending_update
        end

        begin
          enqueue(command)
        rescue error
          remove_pending_settings(pending)
          raise error
        end
        pending
      end

      command.wait
      mark_settings_sent(acknowledgement)
    end

    # Sends a PING and waits for the matching acknowledgement. Concurrent PINGs
    # with identical payloads are matched in submission order.
    def ping(
      payload : Bytes = Bytes.new(8, 0_u8),
      timeout : Time::Span? = nil,
    ) : Nil
      frame = Frame::Ping.new(0_u8, 0_u32, payload.dup)
      waiter = PingWaiter.new(frame.payload)
      register_ping(waiter)

      begin
        write_frame(frame)
        waiter.wait(timeout)
      rescue error
        remove_ping(waiter)
        raise error
      end
    end

    def ping(payload : String, timeout : Time::Span? = nil) : Nil
      ping(payload.to_slice, timeout)
    end

    def wait_until_active(timeout : Time::Span? = nil) : Nil
      current_state = state
      return if current_state.active? || current_state.draining?
      raise_terminal_or_state! if current_state.closed?

      wait_for_signal(@handshake_done, timeout, "HTTP/2 handshake")

      current_state = state
      return if current_state.active? || current_state.draining?

      raise_terminal_or_state!
    end

    def wait_closed(timeout : Time::Span? = nil) : Nil
      unless closed?
        wait_for_signal(@closed_signal, timeout, "HTTP/2 connection close")
      end

      wait_until_stopped(timeout)
    end

    # Idempotently terminates the runtime and wakes every waiter.
    def close : Nil
      terminate(ClosedError.new("HTTP/2 connection closed"))
      wait_until_stopped
    end

    # Sends GOAWAY(NO_ERROR), refuses new streams, and lets established
    # streams finish until the deadline. The deadline is shortened, never
    # extended, by concurrent graceful-close or peer-GOAWAY requests.
    def graceful_close(
      timeout : Time::Span = @configuration.drain_timeout,
    ) : Nil
      if timeout <= Time::Span.zero
        raise ArgumentError.new("drain timeout must be positive")
      end
      if closed?
        wait_until_stopped
        return
      end

      send_graceful_goaway
      start_drain_monitor(timeout)
      wait_closed
      if error = terminal_error
        raise error if error.is_a?(DrainTimeoutError)
      end
    end

    # :nodoc:
    def cancel_stream(
      stream : Stream,
      error_code : ErrorCode = ErrorCode::CANCEL,
      terminal_error : Exception? = nil,
    ) : Nil
      error = terminal_error || CanceledError.new(stream.id, error_code)
      send_reset = @mutex.synchronize do
        current = @streams[stream.id]?
        unless current && current.same?(stream)
          next false
        end

        if current.state.idle?
          @streams.delete(stream.id)
          current.transition_to(Stream::State::Closed)
          terminate_stream_unlocked(
            current,
            error
          )
          false
        else
          !current.state.closed?
        end
      end
      unless send_reset
        wake_drain_monitor
        return
      end

      reset = Frame::ResetStream.new(stream.id, error_code)
      send_reset(
        reset,
        error
      )
    rescue error : InvalidStateError
      raise error unless stream.closed? || stream.terminal_error
    end

    # Returns receive-window credit after application bytes leave a bounded
    # stream body. Connection credit is always restored; stream credit is
    # omitted once the peer has ended that stream.
    #
    # Credit always accumulates, but the writer is only woken once pending
    # credit reaches a half-window watermark (connection or stream scope) —
    # coalescing what would otherwise be a WINDOW_UPDATE pair on every body
    # read. A writer woken for any OTHER reason still flushes all pending
    # credit unconditionally (see `take_pending_window_updates`); this is by
    # design, not a bug — the watermark only gates the wake, not the send.
    #
    # :nodoc:
    def release_receive_credit(stream_id : UInt32, amount : Int32) : Nil
      return if amount <= 0

      wake, replenished = @mutex.synchronize do
        next {false, false} if @state.closed?

        queue_connection_credit_unlocked(amount.to_i64)
        if stream = @streams[stream_id]?
          state = stream.state
          if state.open? || state.half_closed_local?
            @pending_stream_window_updates[stream_id] =
              (@pending_stream_window_updates[stream_id]? || 0_i64) + amount
          end
        end
        {true, replenishment_due_unlocked?(stream_id)}
      end
      wake_flow_control if wake && replenished
    end

    private def submit(command : WriteCommand) : Nil
      @submission_mutex.synchronize { enqueue(command) }
      command.wait
    end

    # Enqueues a command without waiting for the writer to flush it. Used by
    # the reader fiber for protocol acknowledgements so a write-stalled
    # transport cannot wedge inbound frame processing.
    private def submit_nowait(command : WriteCommand) : Nil
      @submission_mutex.synchronize { enqueue(command) }
    end

    private def submit_data(frame : Frame::Data) : Nil
      stream = @mutex.synchronize do
        active = @streams[frame.stream_id]?
        unless active
          raise ClosedError.new(
            "HTTP/2 stream #{frame.stream_id} is closed"
          )
        end
        active
      end
      command = WriteCommand.data(frame, stream)
      enqueue_data(command, stream)
      command.wait(stream)
    end

    private def queue_connection_credit_unlocked(amount : Int64) : Nil
      return if amount <= 0

      @pending_connection_window_update += amount
    end

    # Whether pending receive credit has reached a half-window watermark and
    # the writer should be woken to flush it. Crossing either scope's
    # watermark wakes the writer, which then flushes ALL pending credit
    # (connection and every stream) — not just the scope that crossed.
    private def replenishment_due_unlocked?(stream_id : UInt32) : Bool
      connection_watermark =
        @configuration.connection_receive_window.to_i64 // 2
      return true if @pending_connection_window_update >= connection_watermark

      if pending = @pending_stream_window_updates[stream_id]?
        stream_watermark =
          @effective_local_settings_state.initial_window_size.to_i64 // 2
        return true if pending >= stream_watermark
      end
      false
    end

    private def wake_flow_control : Nil
      select
      when @flow_control_wakeup.send(nil)
      else
      end
    rescue Channel::ClosedError
      # Connection shutdown already woke the writer.
    end

    private def send_reset(
      frame : Frame::ResetStream,
      error : Exception,
    ) : Nil
      submit(WriteCommand.reset(frame, error))
    end

    private def register_ping(waiter : PingWaiter) : Nil
      @mutex.synchronize do
        raise_terminal_or_state_unlocked! if @state.closed?
        if @state.new?
          raise InvalidStateError.new("connection has not been started")
        end

        pending_count = 0
        @pending_pings.each_value do |waiters|
          pending_count += waiters.size
        end
        if pending_count >= @configuration.max_pending_pings
          raise PingLimitError.new(@configuration.max_pending_pings)
        end

        waiters = @pending_pings[waiter.key] ||= [] of PingWaiter
        waiters << waiter
      end
    end

    private def remove_ping(waiter : PingWaiter) : Nil
      @mutex.synchronize do
        waiters = @pending_pings[waiter.key]?
        next unless waiters

        waiters.delete(waiter)
        @pending_pings.delete(waiter.key) if waiters.empty?
      end
    end

    private def enqueue(command : WriteCommand) : Nil
      current_state = state
      if current_state.new?
        raise InvalidStateError.new("connection has not been started")
      end
      raise_terminal_or_state! if current_state.closed?

      @write_queue.send(command)
    rescue Channel::ClosedError
      raise_terminal_or_state!
    end

    private def enqueue_data(command : WriteCommand, stream : Stream) : Nil
      current_state = state
      if current_state.new?
        raise InvalidStateError.new("connection has not been started")
      end
      raise_terminal_or_state! if current_state.closed?

      select
      when @data_queue.send(command)
      when stream.terminal_signal.receive?
        if error = stream.terminal_error
          raise error
        end
        raise ClosedError.new("HTTP/2 stream #{stream.id} is closed")
      end
    rescue Channel::ClosedError
      raise_terminal_or_state!
    end

    private def writer_loop : Nil
      loop do
        if command = poll_write_command
          process_write_command(command)
          next
        end
        break if terminal_error

        if frames = take_pending_window_updates
          write_scheduled_frames(frames)
          next
        end

        if can_accept_pending_data?
          if command = poll_data_command
            enqueue_pending_data(command)
          end
        end

        if scheduled = next_scheduled_data_frame
          command, frame = scheduled
          if write_scheduled_data(command, frame)
            finish_scheduled_data(command, frame)
          end
          next
        end

        wait_for_writer_work
      end
    ensure
      error = terminal_error || ClosedError.new("HTTP/2 writer stopped")
      while command = @write_queue.receive?
        command.complete(error)
      end
      while command = @data_queue.receive?
        command.complete(error)
      end
      fail_pending_data(error)
      @writer_done.close
    end

    private def poll_write_command : WriteCommand?
      command = nil
      select
      when received = @write_queue.receive?
        command = received
      else
      end
      command
    end

    private def poll_data_command : WriteCommand?
      command = nil
      select
      when received = @data_queue.receive?
        command = received
      else
      end
      command
    end

    private def wait_for_writer_work : Nil
      if can_accept_pending_data?
        select
        when command = @write_queue.receive?
          process_write_command(command) if command
        when command = @data_queue.receive?
          enqueue_pending_data(command) if command
        when @flow_control_wakeup.receive?
        end
      else
        select
        when command = @write_queue.receive?
          process_write_command(command) if command
        when @flow_control_wakeup.receive?
        end
      end
    end

    private def can_accept_pending_data? : Bool
      @pending_data_count < @configuration.writer_queue_capacity
    end

    private def process_write_command(command : WriteCommand) : Nil
      if command.data_block
        if error = terminal_error
          command.complete(error)
        else
          enqueue_pending_data(command)
        end
        return
      end
      if error = terminal_error
        command.complete(error)
        return
      end

      begin
        prepare_outbound(command)
        if table_size = command.encoder_table_size
          @encoder.resize_table(table_size)
        end
        frames = materialize_frames(command)
      rescue error
        command.complete(error)
        return
      end

      begin
        @transport.write(Preface) if command.preface?
        frames.each do |frame|
          frame.write(@transport)
          emit_frame(frame, Diagnostic::Direction::Outbound)
        end
        @transport.flush
        command.complete
        @mutex.synchronize { @preface_sent = true } if command.preface?
        wake_drain_monitor
      rescue error
        command.complete(error)
        terminate(error)
      end
    end

    private def write_scheduled_frames(frames : Array(Frames)) : Nil
      frames.each do |frame|
        frame.write(@transport)
        emit_frame(frame, Diagnostic::Direction::Outbound)
      end
      @transport.flush
      wake_drain_monitor
    rescue error
      terminate(error)
    end

    private def enqueue_pending_data(command : WriteCommand) : Nil
      block = command.data_block
      unless block
        command.complete(
          InvalidStateError.new("DATA command has no DATA block")
        )
        return
      end

      queue = @pending_data[block.stream_id]?
      unless queue
        queue = Deque(WriteCommand).new
        @pending_data[block.stream_id] = queue
        @data_schedule << block.stream_id
      end
      queue << command
      @pending_data_count += 1
    end

    private def next_scheduled_data_frame : Tuple(WriteCommand, Frame::Data)?
      candidates = @data_schedule.size
      candidates.times do
        stream_id = @data_schedule.shift
        queue = @pending_data[stream_id]
        command = queue.first

        if error = data_command_error(command)
          queue.shift.complete(error)
          @pending_data_count -= 1
          retain_data_stream(stream_id, queue)
          next
        end

        begin
          frame = plan_scheduled_data_frame(command)
        rescue error
          queue.shift.complete(error)
          @pending_data_count -= 1
          retain_data_stream(stream_id, queue)
          next
        end

        unless frame
          @data_schedule << stream_id
          next
        end

        return {command, frame}
      end
      nil
    end

    private def data_command_error(command : WriteCommand) : Exception?
      @mutex.synchronize do
        if error = @terminal_error
          error
        elsif block = command.data_block
          if error = block.stream.terminal_error
            error
          elsif current = @streams[block.stream_id]?
            if current.same?(block.stream)
              nil
            else
              ClosedError.new(
                "HTTP/2 stream #{block.stream_id} is closed"
              )
            end
          else
            ClosedError.new(
              "HTTP/2 stream #{block.stream_id} is closed"
            )
          end
        else
          InvalidStateError.new("DATA command has no DATA block")
        end
      end
    end

    private def plan_scheduled_data_frame(
      command : WriteCommand,
    ) : Frame::Data?
      block = command.data_block
      unless block
        raise InvalidStateError.new("DATA command has no DATA block")
      end

      @mutex.synchronize do
        raise_terminal_or_state_unlocked! if @state.closed?
        stream = @streams[block.stream_id]?
        unless stream
          raise ClosedError.new(
            "HTTP/2 stream #{block.stream_id} is closed"
          )
        end

        max_frame_size = @peer_settings_state.max_frame_size.to_i64
        flow_size = if block.padded?
                      size = block.frame.payload.size.to_i64
                      if size > max_frame_size
                        raise ArgumentError.new(
                          "padded DATA payload exceeds the peer maximum frame size"
                        )
                      end
                      size
                    else
                      remaining = block.remaining.to_i64
                      if remaining.zero?
                        0_i64
                      else
                        available = [
                          remaining,
                          max_frame_size,
                          @connection_send_window,
                          stream.send_window,
                        ].min
                        next if available <= 0
                        available
                      end
                    end

        if flow_size > 0 &&
           (@connection_send_window < flow_size ||
           stream.send_window < flow_size)
          next
        end

        frame = block.build_frame(
          block.padded? ? block.frame.data.size : flow_size.to_i32
        )
        plans = {} of UInt32 => OutboundTransition
        plan_outbound_data_unlocked(
          plans,
          frame,
          @highest_local_opened_stream_id
        )

        @connection_send_window -= frame.payload.size.to_i64
        stream.adjust_send_window(-frame.payload.size.to_i64)
        plans.each_value do |plan|
          apply_outbound_transition_unlocked(plan)
        end
        frame
      end
    end

    private def write_scheduled_data(
      command : WriteCommand,
      frame : Frame::Data,
    ) : Bool
      frame.write(@transport)
      emit_frame(frame, Diagnostic::Direction::Outbound)
      @transport.flush
      wake_drain_monitor
      true
    rescue error
      command.complete(error)
      terminate(error)
      false
    end

    private def finish_scheduled_data(
      command : WriteCommand,
      frame : Frame::Data,
    ) : Nil
      block = command.data_block
      return unless block

      block.advance(frame)
      stream_id = block.stream_id
      queue = @pending_data[stream_id]
      if block.complete?
        queue.shift
        @pending_data_count -= 1
        command.complete
      end
      retain_data_stream(stream_id, queue)
    end

    private def retain_data_stream(
      stream_id : UInt32,
      queue : Deque(WriteCommand),
    ) : Nil
      if queue.empty?
        @pending_data.delete(stream_id)
      else
        @data_schedule << stream_id
      end
    end

    private def fail_pending_data(error : Exception) : Nil
      @pending_data.each_value do |queue|
        queue.each(&.complete(error))
      end
      @pending_data.clear
      @data_schedule.clear
      @pending_data_count = 0
    end

    private def take_pending_window_updates : Array(Frames)?
      @mutex.synchronize do
        return unless @preface_sent
        return if @pending_connection_window_update.zero? &&
                  @pending_stream_window_updates.empty?

        frames = [] of Frames
        append_window_updates(
          frames,
          0_u32,
          @pending_connection_window_update
        )
        @connection_receive_window += @pending_connection_window_update
        @pending_connection_window_update = 0_i64

        @pending_stream_window_updates.each do |stream_id, amount|
          stream = @streams[stream_id]?
          next unless stream

          state = stream.state
          next unless state.open? || state.half_closed_local?

          stream.adjust_receive_window(amount)
          append_window_updates(frames, stream_id, amount)
        end
        @pending_stream_window_updates.clear
        frames.empty? ? nil : frames
      end
    end

    private def append_window_updates(
      frames : Array(Frames),
      stream_id : UInt32,
      amount : Int64,
    ) : Nil
      maximum = FrameHeader::MAX_STREAM_ID.to_i64
      while amount > 0
        increment = Math.min(amount, maximum)
        frames << Frame::WindowUpdate.new(
          stream_id,
          increment.to_u32
        )
        amount -= increment
      end
    end

    private def transport_closer_loop : Nil
      @transport_close_signal.receive?
      close_transport
    ensure
      @transport_closer_done.close
    end

    private def reader_loop : Nil
      server_preface = read_server_preface
      observe_inbound_frame(server_preface, rate_limit: false)
      handle_server_preface(server_preface)
      loop do
        if frame = read_frame
          process_inbound_frame(frame)
        end
      end
    rescue error : ProtocolError
      send_goaway(error)
      terminate(error)
    rescue error : IO::EOFError
      handle_reader_eof(error)
    rescue error
      terminate(error) unless closed?
    ensure
      @reader_done.close
    end

    private def read_server_preface : Frames
      Frame.read(
        @transport,
        effective_local_settings_state.max_frame_size
      )
    rescue error : ProtocolError
      raise ProtocolError.new(
        "invalid server connection preface: #{error.message}"
      )
    end

    private def read_frame : Frames?
      Frame.read(
        @transport,
        effective_local_settings_state.max_frame_size
      )
    rescue error : ProtocolError
      if @field_blocks.pending?
        raise ProtocolError.new(
          "invalid frame interrupted an open field block"
        )
      end
      raise error unless error.stream?

      handle_inbound_codec_violation(error)
      nil
    end

    private def process_inbound_frame(frame : Frames) : Nil
      observe_inbound_frame(frame)
      validate_field_block_opening!(frame)
      event = @field_blocks.process(frame)
      return unless event

      begin
        case event
        when FieldBlock
          dispatch(decode_field_block(event))
        else
          dispatch(event)
        end
      rescue error : ProtocolError
        raise error unless error.stream?

        cancel_rejected_promise(event) if event.is_a?(FieldBlock)
        handle_stream_violation(error)
      end
    end

    private def decode_field_block(block : FieldBlock) : FieldSection
      fields = [] of DecodedHeaderField
      decoded_field_count = 0
      field_count_exceeded = false
      result = @decoder.decode_each(
        block.encoded,
        max_field_section_size: decoded_field_section_limit
      ) do |field|
        decoded_field_count += 1
        if decoded_field_count > @configuration.max_decoded_fields
          field_count_exceeded = true
        else
          fields << DecodedHeaderField.from_hpack(field)
        end
      end

      if result.limit_exceeded || field_count_exceeded
        raise ProtocolError.new(
          "decoded field section exceeds a configured limit",
          ErrorCode::ENHANCE_YOUR_CALM,
          ErrorScope::Stream,
          block.stream_id
        )
      end

      FieldSection.new(block, fields, result.decoded_size)
    rescue error : HPack::ResourceLimitError
      raise ResourceLimitError.new(
        "HPACK decoder resource limit exceeded: #{error.message}"
      )
    rescue error : HPack::Error
      raise ProtocolError.new(
        "invalid HPACK field block: #{error.message}",
        ErrorCode::COMPRESSION_ERROR
      )
    end

    private def decoded_field_section_limit : UInt64
      configured = @configuration.max_decoded_field_section_size.to_u64
      if advertised = effective_local_settings_state.max_header_list_size
        Math.min(configured, advertised.to_u64)
      else
        configured
      end
    end

    private def handle_reader_eof(error : IO::EOFError) : Nil
      if @field_blocks.pending?
        terminate(
          ProtocolError.new(
            "connection ended before the open field block was complete"
          )
        )
      else
        terminate(error) unless closed?
      end
    end

    private def handle_server_preface(frame : Frames) : Nil
      settings = frame.as?(Frame::Settings)
      if settings.nil? || settings.ack?
        raise ProtocolError.new(
          "the server's first frame must be a non-ACK SETTINGS frame"
        )
      end

      acknowledge_peer_settings(settings)
      activated = @mutex.synchronize do
        unless @state.closed?
          @peer_settings = settings
          @state = State::Active
          true
        end
      end
      @handshake_done.close if activated
      if activated
        emit_lifecycle("active")
        start_keepalive
      end
    end

    private def dispatch(event : StreamEvent) : Nil
      case event
      when Frame::Settings
        if event.ack?
          acknowledge_local_settings
        else
          acknowledge_peer_settings(event)
        end
      when Frame::Ping
        handle_ping(event)
      when Frame::GoAway
        handle_goaway(event)
      when Frame::WindowUpdate
        handle_window_update(event)
      when Frame::Data
        handle_inbound_data(event)
      when Frame::Unknown
        # RFC 9113 requires unknown frame types to be ignored.
      when FieldSection
        if event.kind.push_promise?
          reject_push_promise(event)
        else
          dispatch_stream_event(event)
        end
      else
        dispatch_stream_event(event)
      end
    end

    private def validate_field_block_opening!(frame : Frames) : Nil
      case frame
      when Frame::Headers
        event = if frame.end_stream?
                  Stream::Event::ReceiveHeadersEndStream
                else
                  Stream::Event::ReceiveHeaders
                end
        validate_inbound_field_event!(frame.stream_id, event)
      when Frame::PushPromise
        validate_push_promise!(frame)
      else
      end
    end

    private def validate_inbound_field_event!(
      stream_id : UInt32,
      event : Stream::Event,
    ) : Nil
      @mutex.synchronize do
        state = stream_state_unlocked(stream_id)
        closed = @closed_streams[stream_id]?
        return if closed.try(&.tolerate_late_frames?)

        if state.idle?
          raise ProtocolError.new(
            "a server cannot open idle stream #{stream_id} with HEADERS"
          )
        end

        transition = Stream::StateMachine.transition(state, event)
        if transition.action.connection_error?
          raise ProtocolError.new(
            "received #{event} on stream #{stream_id} in state #{state}",
            transition.error_code || ErrorCode::PROTOCOL_ERROR
          )
        end
      end
    end

    private def validate_push_promise!(
      frame : Frame::PushPromise,
    ) : Nil
      @mutex.synchronize do
        unless @effective_local_settings_state.enable_push?
          raise ProtocolError.new(
            "received PUSH_PROMISE after push was disabled"
          )
        end

        parent_state = stream_state_unlocked(frame.stream_id)
        closed = @closed_streams[frame.stream_id]?
        unless closed.try(&.tolerate_late_frames?)
          transition = Stream::StateMachine.transition(
            parent_state,
            Stream::Event::ReceivePushPromise
          )
          if transition.action.connection_error?
            raise ProtocolError.new(
              "received PUSH_PROMISE on stream #{frame.stream_id} " \
              "in state #{parent_state}"
            )
          end
        end

        promised_id = frame.promised_stream_id
        if promised_id.odd?
          raise ProtocolError.new(
            "a server PUSH_PROMISE must use an even promised stream ID"
          )
        end
        if promised_id <= @highest_peer_stream_id ||
           !stream_state_unlocked(promised_id).idle?
          raise ProtocolError.new(
            "PUSH_PROMISE stream #{promised_id} is not an idle new stream"
          )
        end

        promised = Stream.new(
          self,
          promised_id,
          @configuration.stream_event_capacity,
          @peer_settings_state.initial_window_size.to_i64,
          @effective_local_settings_state.initial_window_size.to_i64,
          @configuration.max_buffered_body_bytes
        )
        transition = Stream::StateMachine.reserve_remote(promised.state)
        promised.transition_to(
          transition.next_state || Stream::State::ReservedRemote
        )
        @streams[promised_id] = promised
        @highest_peer_stream_id = promised_id
        @last_processed_peer_stream_id = promised_id
      end
    end

    private def reject_push_promise(section : FieldSection) : Nil
      promised_id = section.promised_stream_id
      unless promised_id
        raise InvalidStateError.new(
          "decoded PUSH_PROMISE is missing its promised stream ID"
        )
      end

      stream = @mutex.synchronize { @streams[promised_id]? }
      return unless stream

      reset = Frame::ResetStream.new(promised_id, ErrorCode::CANCEL)
      send_reset(
        reset,
        CanceledError.new(promised_id, ErrorCode::CANCEL)
      )
    end

    private def cancel_rejected_promise(block : FieldBlock) : Nil
      return unless block.kind.push_promise?
      return unless promised_id = block.promised_stream_id

      stream = @mutex.synchronize { @streams[promised_id]? }
      return unless stream && stream.state.reserved_remote?

      reset = Frame::ResetStream.new(promised_id, ErrorCode::CANCEL)
      send_reset(
        reset,
        CanceledError.new(promised_id, ErrorCode::CANCEL)
      )
    end

    private def dispatch_stream_event(event : StreamEvent) : Nil
      case event
      when FieldSection
        transition_and_deliver(
          event,
          event.end_stream? ? Stream::Event::ReceiveHeadersEndStream : Stream::Event::ReceiveHeaders
        )
      when Frame::ResetStream
        handle_inbound_reset(event)
      when Frame::Priority
        transition_and_deliver(event, Stream::Event::ReceivePriority)
      else
        raise InvalidStateError.new(
          "unexpected stream event #{event.class}"
        )
      end
    end

    private def handle_window_update(
      frame : Frame::WindowUpdate,
    ) : Nil
      increment = frame.window_size_increment.to_i64
      if frame.stream_id.zero?
        @mutex.synchronize do
          updated = @connection_send_window + increment
          if updated > FrameHeader::MAX_STREAM_ID.to_i64
            raise ProtocolError.new(
              "connection flow-control window exceeded the protocol maximum",
              ErrorCode::FLOW_CONTROL_ERROR
            )
          end
          @connection_send_window = updated
        end
        wake_flow_control
        return
      end

      changed = @mutex.synchronize do
        resolved = resolve_inbound_transition_unlocked(
          frame.stream_id,
          Stream::Event::ReceiveWindowUpdate
        )
        next false unless resolved

        state, transition = resolved
        stream = @streams[frame.stream_id]?
        next false unless stream

        stream.transition_to(transition.next_state || state)
        next false unless state.open? || state.half_closed_remote?

        updated = stream.send_window + increment
        if updated > FrameHeader::MAX_STREAM_ID.to_i64
          raise ProtocolError.new(
            "stream #{frame.stream_id} flow-control window exceeded " \
            "the protocol maximum",
            ErrorCode::FLOW_CONTROL_ERROR,
            ErrorScope::Stream,
            frame.stream_id
          )
        end
        stream.adjust_send_window(increment)
        true
      end
      wake_flow_control if changed
    end

    private def handle_inbound_data(frame : Frame::Data) : Nil
      flow_size = frame.payload.size.to_i64
      begin
        stream, ignored = accept_inbound_data(frame, flow_size)

        if ignored || stream.nil?
          release_discarded_connection_credit(flow_size)
          return
        end

        data = frame.data.dup
        unless stream.deliver_data(data)
          release_discarded_connection_credit(flow_size)
          return if stream.body.closed? || stream.terminal_error

          raise QueueFullError.new(
            "stream #{stream.id} body reached its configured byte limit"
          )
        end

        overhead = frame.payload.size - data.size
        release_receive_credit(stream.id, overhead) if overhead > 0
        if frame.end_stream?
          stream.finish_body
          # The peer will send no more DATA on this stream, so whatever
          # credit is still pending (this stream's, and any connection
          # credit accumulated alongside it) has no further reads left to
          # coalesce with — flush it now instead of waiting on a watermark
          # that this stream can no longer help cross.
          wake_flow_control
        end
        wake_drain_monitor if stream.closed?
      rescue error : ProtocolError
        release_discarded_connection_credit(flow_size) if error.stream?
        raise error
      end
    end

    private def accept_inbound_data(
      frame : Frame::Data,
      flow_size : Int64,
    ) : Tuple(Stream?, Bool)
      @mutex.synchronize do
        charge_connection_receive_window_unlocked(flow_size)
        event = if frame.end_stream?
                  Stream::Event::ReceiveDataEndStream
                else
                  Stream::Event::ReceiveData
                end
        resolved = resolve_inbound_transition_unlocked(
          frame.stream_id,
          event
        )
        next {nil, true} unless resolved
        state, transition = resolved

        stream = @streams[frame.stream_id]?
        next {nil, true} unless stream

        charge_stream_receive_window_unlocked(
          stream,
          frame.stream_id,
          flow_size
        )
        stream.validate_inbound_data(frame.data.size, frame.end_stream?)
        apply_inbound_data_transition_unlocked(
          stream,
          frame.stream_id,
          state,
          transition
        )
        {stream, false}
      end
    end

    private def charge_connection_receive_window_unlocked(
      flow_size : Int64,
    ) : Nil
      @connection_receive_window -= flow_size
      return unless @connection_receive_window < 0

      raise ProtocolError.new(
        "peer exceeded the connection flow-control window",
        ErrorCode::FLOW_CONTROL_ERROR
      )
    end

    private def charge_stream_receive_window_unlocked(
      stream : Stream,
      stream_id : UInt32,
      flow_size : Int64,
    ) : Nil
      receive_window = stream.adjust_receive_window(-flow_size)
      return unless receive_window < 0

      raise ProtocolError.new(
        "peer exceeded stream #{stream_id}'s flow-control window",
        ErrorCode::FLOW_CONTROL_ERROR,
        ErrorScope::Stream,
        stream_id
      )
    end

    private def apply_inbound_data_transition_unlocked(
      stream : Stream,
      stream_id : UInt32,
      state : Stream::State,
      transition : Stream::StateMachine::Transition,
    ) : Nil
      next_state = transition.next_state || state
      stream.transition_to(next_state)
      return unless next_state.closed?

      @streams.delete(stream_id)
      retain_closed_stream_unlocked(
        stream_id,
        ClosedStream::Reason::EndStream
      )
    end

    private def release_discarded_connection_credit(amount : Int64) : Nil
      return if amount <= 0

      wake = @mutex.synchronize do
        next false if @state.closed?

        queue_connection_credit_unlocked(amount)
        true
      end
      wake_flow_control if wake
    end

    private def transition_and_deliver(
      event : StreamEvent,
      stream_event : Stream::Event,
    ) : Nil
      if section = event.as?(FieldSection)
        stream = @mutex.synchronize { @streams[section.stream_id]? }
        stream.try(&.validate_inbound(section))
      end

      stream, ignored = @mutex.synchronize do
        resolved = resolve_inbound_transition_unlocked(
          event.stream_id,
          stream_event
        )
        next {nil, true} unless resolved
        state, transition = resolved

        active_stream = @streams[event.stream_id]?
        unless active_stream
          # PRIORITY is valid in idle and closed states without creating a
          # stream. All other absent-stream cases were rejected above.
          next {nil, true}
        end

        next_state = transition.next_state || state
        active_stream.transition_to(next_state)
        if next_state.closed?
          @streams.delete(event.stream_id)
          retain_closed_stream_unlocked(
            event.stream_id,
            ClosedStream::Reason::EndStream
          )
        end
        {active_stream, false}
      end
      return if ignored || stream.nil?

      unless stream.deliver(event)
        raise QueueFullError.new(
          "stream #{stream.id} event queue reached its configured limit"
        )
      end
      if section = event.as?(FieldSection)
        if section.end_stream?
          stream.finish_body
          # See the matching comment in `handle_inbound_data`: no more DATA
          # can follow END_STREAM on this stream, so flush now rather than
          # waiting on a watermark this stream can no longer help cross.
          wake_flow_control
        end
      end
      wake_drain_monitor if stream.closed?
    end

    private def resolve_inbound_transition_unlocked(
      stream_id : UInt32,
      event : Stream::Event,
    ) : Tuple(Stream::State, Stream::StateMachine::Transition)?
      state = stream_state_unlocked(stream_id)
      closed = @closed_streams[stream_id]?
      return if closed.try(&.tolerate_late_frames?)

      transition = Stream::StateMachine.transition(state, event)
      case transition.action
      when Stream::StateMachine::Action::Ignore
        nil
      when Stream::StateMachine::Action::ConnectionError
        raise ProtocolError.new(
          "received #{event} on stream #{stream_id} in state #{state}",
          transition.error_code || ErrorCode::PROTOCOL_ERROR
        )
      when Stream::StateMachine::Action::StreamError
        raise ProtocolError.new(
          "received #{event} on stream #{stream_id} in state #{state}",
          transition.error_code || ErrorCode::STREAM_CLOSED,
          ErrorScope::Stream,
          stream_id
        )
      when Stream::StateMachine::Action::LocalError
        raise InvalidStateError.new(
          "inbound transition resolved to a local error"
        )
      when Stream::StateMachine::Action::Allow
        {state, transition}
      end
    end

    private def handle_inbound_reset(frame : Frame::ResetStream) : Nil
      stream, ignored = @mutex.synchronize do
        state = stream_state_unlocked(frame.stream_id)
        closed = @closed_streams[frame.stream_id]?
        if closed
          next {nil, true}
        end

        transition = Stream::StateMachine.transition(
          state,
          Stream::Event::ReceiveReset
        )
        if transition.action.connection_error?
          raise ProtocolError.new(
            "received RST_STREAM on idle stream #{frame.stream_id}"
          )
        end
        if transition.action.ignore?
          next {nil, true}
        end

        active_stream = @streams.delete(frame.stream_id)
        unless active_stream
          next {nil, true}
        end
        active_stream.transition_to(Stream::State::Closed)
        retain_closed_stream_unlocked(
          frame.stream_id,
          ClosedStream::Reason::RemoteReset
        )
        {active_stream, false}
      end
      return if ignored || stream.nil?

      error = StreamResetError.new(frame.stream_id, frame.error_code)
      emit_error(error, frame.stream_id, frame.error_code)
      discarded = stream.terminate(error)
      release_discarded_connection_credit(discarded.to_i64)
      wake_flow_control
      wake_drain_monitor
    end

    private def stream_state_unlocked(stream_id : UInt32) : Stream::State
      if stream = @streams[stream_id]?
        stream.state
      elsif @closed_streams.has_key?(stream_id)
        Stream::State::Closed
      elsif stream_id.odd?
        if stream_id <= @highest_local_opened_stream_id
          Stream::State::Closed
        else
          Stream::State::Idle
        end
      elsif stream_id <= @highest_peer_stream_id
        Stream::State::Closed
      else
        Stream::State::Idle
      end
    end

    private def handle_ping(frame : Frame::Ping) : Nil
      unless frame.ack?
        submit_nowait(WriteCommand.new([frame.ack] of Frames))
        return
      end

      waiter = @mutex.synchronize do
        key = String.new(frame.payload)
        if waiters = @pending_pings[key]?
          matched = waiters.shift?
          @pending_pings.delete(key) if waiters.empty?
          matched
        end
      end
      waiter.try(&.complete)
    end

    private def apply_peer_settings(settings : Frame::Settings) : Int32?
      previous, updated = @mutex.synchronize do
        previous = @peer_settings_state
        next_settings = previous.with_peer(settings.entries)
        apply_peer_initial_window_size_unlocked(previous, next_settings)
        @peer_settings_state = next_settings
        @peer_settings = settings
        {previous, next_settings}
      end
      wake_flow_control if previous.initial_window_size !=
                             updated.initial_window_size

      return if previous.header_table_size == updated.header_table_size

      Math.min(
        updated.header_table_size.to_u64,
        @configuration.max_encoder_table_size.to_u64
      ).to_i32
    end

    private def acknowledge_peer_settings(
      settings : Frame::Settings,
    ) : Nil
      @submission_mutex.synchronize do
        table_size = apply_peer_settings(settings)
        enqueue(WriteCommand.settings_ack(table_size))
      end
    end

    private def acknowledge_local_settings : Nil
      previous, updated = @mutex.synchronize do
        pending = @pending_settings.shift?
        unless pending
          raise ProtocolError.new(
            "received a SETTINGS ACK with no outstanding SETTINGS frame"
          )
        end

        prior_settings = @effective_local_settings_state
        effective_settings = pending.settings
        apply_local_initial_window_size_unlocked(
          prior_settings,
          effective_settings
        )
        @effective_local_settings_state = effective_settings
        {prior_settings, effective_settings}
      end

      apply_effective_local_settings(previous, updated)
      wake_settings_timer
    end

    private def handle_goaway(frame : Frame::GoAway) : Nil
      unprocessed = [] of UnprocessedStreamError
      @mutex.synchronize do
        if !frame.last_stream_id.zero? && frame.last_stream_id.even?
          raise ProtocolError.new(
            "a server GOAWAY last stream ID must identify a client stream"
          )
        end
        if previous = @last_goaway
          if frame.last_stream_id > previous.last_stream_id
            raise ProtocolError.new(
              "successive GOAWAY last stream IDs cannot increase"
            )
          end
        end

        @last_goaway = frame
        @state = State::Draining unless @state.closed?
        affected_ids = @streams.compact_map do |id, stream|
          next unless id.odd?
          next unless stream.state.idle? || id > frame.last_stream_id

          id
        end
        affected_ids.each do |id|
          if stream = @streams.delete(id)
            stream.transition_to(Stream::State::Closed)
            retain_closed_stream_unlocked(
              id,
              ClosedStream::Reason::GoAway
            )
            error = UnprocessedStreamError.new(id, frame)
            terminate_stream_unlocked(
              stream,
              error
            )
            unprocessed << error
          end
        end
      end
      emit_lifecycle("draining after peer GOAWAY")
      unprocessed.each { |error| emit_error(error, error.stream_id) }
      wake_flow_control
      wake_drain_monitor
      start_drain_monitor(@configuration.drain_timeout)
    end

    private def handle_stream_violation(error : ProtocolError) : Nil
      id = error.stream_id
      unless id
        raise InvalidStateError.new(
          "stream-scoped protocol violation is missing a stream ID"
        )
      end

      stream = @mutex.synchronize { @streams[id]? }
      return unless stream

      emit_error(error, id)
      send_reset(
        Frame::ResetStream.new(id, error.error_code),
        error
      )
    rescue error : InvalidStateError
      active = @mutex.synchronize { @streams.has_key?(id) }
      raise error if active
    end

    private def handle_inbound_codec_violation(
      error : ProtocolError,
    ) : Nil
      id = error.stream_id
      unless id
        raise InvalidStateError.new(
          "stream-scoped codec violation is missing a stream ID"
        )
      end

      state, tolerate = @mutex.synchronize do
        closed = @closed_streams[id]?
        {stream_state_unlocked(id), closed.try(&.tolerate_late_frames?) || false}
      end
      return if tolerate

      if state.active? || state.reserved_local? || state.reserved_remote?
        handle_stream_violation(error)
        return
      end

      raise ProtocolError.new(
        error.message || "invalid frame on an inactive stream",
        error.error_code
      )
    end

    private def send_goaway(error : ProtocolError) : Nil
      last_stream_id = @mutex.synchronize do
        if previous = @last_sent_goaway
          Math.min(
            previous.last_stream_id,
            @last_processed_peer_stream_id
          )
        else
          @last_processed_peer_stream_id
        end
      end
      write_frame(Frame::GoAway.new(last_stream_id, error.error_code))
    rescue
      # The original protocol violation remains the terminal error.
    end

    private def terminate(error : Exception) : Nil
      close_directly = false
      ping_waiters = [] of PingWaiter
      terminated = @mutex.synchronize do
        if @state.closed?
          false
        else
          @terminal_error = error
          @state = State::Closed
          streams = @streams.values
          @streams.clear
          streams.each(&.terminate(error))
          @pending_settings.clear
          @pending_pings.each_value do |waiters|
            ping_waiters.concat(waiters)
          end
          @pending_pings.clear
          close_directly = !@transport_closer_started
          true
        end
      end
      return unless terminated

      emit_error(error)
      @write_queue.close
      @data_queue.close
      @transport_close_signal.close
      @settings_timer_wakeup.close
      @flow_control_wakeup.close
      @drain_wakeup.close
      @keepalive_wakeup.close
      @handshake_done.close
      @closed_signal.close

      ping_waiters.each(&.complete(error))
      @diagnostics.close
      close_transport if close_directly
    end

    private def wait_for_signal(
      signal : Channel(Nil),
      timeout : Time::Span?,
      operation : String,
    ) : Nil
      if timeout
        select
        when signal.receive?
        when timeout(timeout)
          raise TimeoutError.new("#{operation} timed out")
        end
      else
        signal.receive?
      end
    end

    private def wait_until_stopped(timeout : Time::Span? = nil) : Nil
      writer_started, reader_started, transport_closer_started, settings_timer_started, drain_started, keepalive_started =
        @mutex.synchronize do
          {
            @writer_started,
            @reader_started,
            @transport_closer_started,
            @settings_timer_started,
            @drain_started,
            @keepalive_started,
          }
        end

      if transport_closer_started
        wait_for_signal(
          @transport_closer_done,
          timeout,
          "HTTP/2 transport shutdown"
        )
      end

      if writer_started
        wait_for_signal(@writer_done, timeout, "HTTP/2 writer shutdown")
      end
      if reader_started
        wait_for_signal(@reader_done, timeout, "HTTP/2 reader shutdown")
      end
      if settings_timer_started
        wait_for_signal(
          @settings_timer_done,
          timeout,
          "HTTP/2 SETTINGS timer shutdown"
        )
      end
      if drain_started
        wait_for_signal(
          @drain_done,
          timeout,
          "HTTP/2 drain monitor shutdown"
        )
      end
      if keepalive_started
        wait_for_signal(
          @keepalive_done,
          timeout,
          "HTTP/2 keepalive shutdown"
        )
      end
    end

    private def close_transport : Nil
      @transport.close
    rescue
      # The connection's stored terminal error remains authoritative.
    end

    private def send_graceful_goaway : Nil
      frame = @mutex.synchronize do
        next if @state.closed? || @last_sent_goaway
        if @state.new?
          raise InvalidStateError.new("connection has not been started")
        end

        Frame::GoAway.new(
          @last_processed_peer_stream_id,
          ErrorCode::NO_ERROR
        )
      end
      write_frame(frame) if frame
    end

    private def start_drain_monitor(duration : Time::Span) : Nil
      deadline = Time.instant + duration
      start = @mutex.synchronize do
        next false if @state.closed?

        if current = @drain_deadline
          @drain_deadline = deadline if deadline < current
        else
          @drain_deadline = deadline
        end

        if @drain_started
          false
        else
          @drain_started = true
          true
        end
      end

      wake_drain_monitor
      ::spawn(name: "http2-drain-monitor") { drain_monitor_loop } if start
    end

    private def drain_monitor_loop : Nil
      loop do
        closed, active, peer_draining, quiet_remaining, remaining =
          @mutex.synchronize do
            deadline = @drain_deadline || Time.instant
            now = Time.instant
            {
              @state.closed?,
              @streams.count { |_, stream| stream.state.active? },
              !@last_goaway.nil?,
              @last_inbound_activity + DrainQuietPeriod - now,
              deadline - now,
            }
          end
        break if closed

        if active.zero?
          next if wait_for_peer_drain_quiet?(
                    peer_draining,
                    quiet_remaining,
                    remaining
                  )
          send_graceful_goaway
          terminate(DrainedError.new("HTTP/2 connection drained")) unless closed?
          break
        end
        if remaining <= Time::Span.zero
          send_graceful_goaway
          terminate(
            DrainTimeoutError.new(
              "HTTP/2 connection did not drain before its deadline"
            )
          ) unless closed?
          break
        end

        wait_for_drain_change(remaining)
      end
    rescue Channel::ClosedError
      # Connection shutdown wakes the monitor.
    rescue error
      terminate(error) unless closed?
    ensure
      @drain_done.close
    end

    private def wait_for_peer_drain_quiet?(
      peer_draining : Bool,
      quiet_remaining : Time::Span,
      deadline_remaining : Time::Span,
    ) : Bool
      return false unless peer_draining
      return false unless quiet_remaining > Time::Span.zero
      return false unless deadline_remaining > Time::Span.zero

      wait_for_drain_change(
        Math.min(quiet_remaining, deadline_remaining)
      )
      true
    end

    private def wait_for_drain_change(duration : Time::Span) : Nil
      select
      when @drain_wakeup.receive?
      when timeout(duration)
      end
    end

    private def wake_drain_monitor : Nil
      return unless @drain_started

      select
      when @drain_wakeup.send(nil)
      else
      end
    rescue Channel::ClosedError
      # Connection shutdown already woke the monitor.
    end

    private def start_keepalive : Nil
      interval = @configuration.keepalive_interval
      return unless interval

      start = @mutex.synchronize do
        if @state.closed? || @keepalive_started
          false
        else
          @keepalive_started = true
          true
        end
      end
      return unless start

      ::spawn(name: "http2-keepalive") { keepalive_loop(interval) }
    end

    private def keepalive_loop(interval : Time::Span) : Nil
      loop do
        closed, remaining = @mutex.synchronize do
          {
            @state.closed?,
            @last_inbound_activity + interval - Time.instant,
          }
        end
        break if closed

        if remaining > Time::Span.zero
          wait_for_keepalive_activity(remaining)
          next
        end

        case outcome = run_keepalive_probe
        when PingLimitError
          wait_for_keepalive_activity(interval)
        when TimeoutError
          terminate(
            KeepaliveTimeoutError.new(
              "HTTP/2 keepalive PING timed out",
              outcome
            )
          )
          break
        when Exception
          terminate(outcome) unless closed?
          break
        end
      end
    rescue Channel::ClosedError
      # Connection shutdown wakes keepalive.
    ensure
      @keepalive_done.close
    end

    # Runs one keepalive PING in a helper fiber so the probe is bounded by
    # keepalive_timeout even when command submission or the transport write
    # itself blocks on a stalled peer. The helper fiber is released by
    # connection termination (queues close and waiters are failed).
    private def run_keepalive_probe : Exception?
      result = Channel(Exception?).new(1)
      payload = next_keepalive_payload
      probe_timeout = @configuration.keepalive_timeout
      ::spawn(name: "http2-keepalive-probe") do
        ping(payload, probe_timeout)
        result.send(nil)
      rescue error
        result.send(error) rescue nil
      end

      select
      when outcome = result.receive
        outcome
      when timeout(probe_timeout)
        TimeoutError.new(
          "HTTP/2 keepalive PING did not complete within #{probe_timeout}"
        )
      end
    end

    private def wait_for_keepalive_activity(duration : Time::Span) : Nil
      select
      when @keepalive_wakeup.receive?
      when timeout(duration)
      end
    end

    private def next_keepalive_payload : Bytes
      sequence = @mutex.synchronize do
        @keepalive_sequence &+= 1_u32
      end
      payload = Bytes[0x68, 0x32, 0x6b, 0x61, 0, 0, 0, 0]
      IO::ByteFormat::BigEndian.encode(sequence, payload[4, 4])
      payload
    end

    private def observe_inbound_frame(
      frame : Frames,
      *,
      rate_limit : Bool = true,
    ) : Nil
      @mutex.synchronize do
        @last_inbound_activity = Time.instant
      end
      notify_keepalive_activity
      emit_frame(frame, Diagnostic::Direction::Inbound)
      @inbound_frame_rate_limiter.check(frame) if rate_limit
    end

    private def notify_keepalive_activity : Nil
      select
      when @keepalive_wakeup.send(nil)
      else
      end
    rescue Channel::ClosedError
      # Connection shutdown already woke keepalive.
    end

    private def emit_frame(
      frame : Frames,
      direction : Diagnostic::Direction,
    ) : Nil
      header = frame.header
      settings = frame.as?(Frame::Settings).try(&.entries.dup)
      error_code = case frame
                   when Frame::GoAway
                     frame.error_code
                   when Frame::ResetStream
                     frame.error_code
                   end
      emit_diagnostic(
        Diagnostic.new(
          Diagnostic::Kind::Frame,
          direction,
          frame_type: header.type_code,
          flags: header.flags,
          stream_id: header.stream_id,
          payload_length: header.length,
          error_code: error_code,
          settings: settings
        )
      )
    end

    private def emit_lifecycle(message : String) : Nil
      emit_diagnostic(
        Diagnostic.new(
          Diagnostic::Kind::Lifecycle,
          message: message
        )
      )
    end

    private def emit_error(
      error : Exception,
      stream_id : UInt32? = nil,
      error_code : UInt32? = nil,
    ) : Nil
      scope = if protocol_error = error.as?(ProtocolError)
                stream_id ||= protocol_error.stream_id
                error_code ||= protocol_error.error_code.to_u32
                protocol_error.scope
              elsif stream_id
                ErrorScope::Stream
              else
                ErrorScope::Connection
              end

      lifecycle = stream_id.nil? &&
                  (error.is_a?(ClosedError) ||
                   error.is_a?(DrainedError))
      emit_diagnostic(
        Diagnostic.new(
          lifecycle ? Diagnostic::Kind::Lifecycle : (stream_id ? Diagnostic::Kind::StreamError : Diagnostic::Kind::ConnectionError),
          stream_id: stream_id,
          error_code: error_code,
          error_scope: scope,
          message: error.message
        )
      )
    end

    private def emit_diagnostic(diagnostic : Diagnostic) : Nil
      select
      when @diagnostics.send(diagnostic)
      else
        @diagnostic_mutex.synchronize do
          @dropped_diagnostic_count += 1
        end
      end
    rescue Channel::ClosedError
      # Diagnostics are best-effort and bounded.
    end

    private def start_settings_timer : Nil
      started = @mutex.synchronize do
        if @state.closed?
          false
        else
          @settings_timer_started = true
          true
        end
      end
      return unless started

      ::spawn(name: "http2-settings-timer") { settings_timer_loop }
    end

    private def settings_timer_loop : Nil
      loop do
        remaining = settings_timeout_remaining
        if remaining
          if remaining <= Time::Span.zero
            expire_settings
            break if closed?
            next
          end

          select
          when @settings_timer_wakeup.receive?
          when timeout(remaining)
            expire_settings
          end
        else
          @settings_timer_wakeup.receive?
        end

        break if closed?
      end
    rescue Channel::ClosedError
      # Connection shutdown wakes the timer.
    ensure
      @settings_timer_done.close
    end

    private def settings_timeout_remaining : Time::Span?
      @mutex.synchronize do
        if acknowledgement = @pending_settings.first?
          if sent_at = acknowledgement.sent_at
            sent_at + @configuration.settings_ack_timeout - Time.instant
          end
        end
      end
    end

    private def expire_settings : Nil
      expired = @mutex.synchronize do
        if acknowledgement = @pending_settings.first?
          if sent_at = acknowledgement.sent_at
            Time.instant - sent_at >=
              @configuration.settings_ack_timeout
          else
            false
          end
        else
          false
        end
      end
      return unless expired

      error = ProtocolError.new(
        "peer did not acknowledge SETTINGS in time",
        ErrorCode::SETTINGS_TIMEOUT
      )
      send_goaway(error)
      terminate(error)
    end

    private def wake_settings_timer : Nil
      select
      when @settings_timer_wakeup.send(nil)
      else
      end
    rescue Channel::ClosedError
      # Connection shutdown already woke the timer.
    end

    private def remove_pending_settings(
      acknowledgement : SettingsAcknowledgement,
    ) : Nil
      removed = @mutex.synchronize do
        if index = @pending_settings.index(acknowledgement)
          @pending_settings.delete_at(index)
          true
        else
          false
        end
      end
      if removed
        wake_settings_timer
      end
    end

    private def apply_effective_local_settings(
      previous : SettingsState,
      updated : SettingsState,
    ) : Nil
      # Decoder limits change only when the corresponding SETTINGS is ACKed.
      if previous.header_table_size != updated.header_table_size
        @decoder.max_table_size = updated.header_table_size.to_i32
      end
    end

    private def apply_peer_initial_window_size_unlocked(
      previous : SettingsState,
      updated : SettingsState,
    ) : Nil
      return if previous.initial_window_size == updated.initial_window_size

      delta = updated.initial_window_size.to_i64 -
              previous.initial_window_size.to_i64
      changes = [] of Tuple(Stream, Int64)
      @streams.each_value do |stream|
        state = stream.state
        value = if state.idle?
                  updated.initial_window_size.to_i64
                elsif state.open? || state.half_closed_remote?
                  stream.send_window + delta
                else
                  next
                end
        if value > FrameHeader::MAX_STREAM_ID.to_i64
          raise ProtocolError.new(
            "SETTINGS_INITIAL_WINDOW_SIZE overflowed a stream window",
            ErrorCode::FLOW_CONTROL_ERROR
          )
        end
        changes << {stream, value}
      end
      changes.each do |stream, value|
        stream.send_window = value
      end
    end

    private def apply_local_initial_window_size_unlocked(
      previous : SettingsState,
      updated : SettingsState,
    ) : Nil
      delta = updated.initial_window_size.to_i64 -
              previous.initial_window_size.to_i64
      @streams.each_value do |stream|
        state = stream.state
        if state.idle?
          stream.receive_window = updated.initial_window_size.to_i64
        elsif state.open? || state.half_closed_local?
          stream.adjust_receive_window(delta)
        end
      end
    end

    private def mark_settings_sent(
      acknowledgement : SettingsAcknowledgement,
    ) : Nil
      marked = @mutex.synchronize do
        if @pending_settings.includes?(acknowledgement)
          acknowledgement.mark_sent(Time.instant)
          true
        else
          false
        end
      end
      wake_settings_timer if marked
    end

    private def prepare_outbound(command : WriteCommand) : Nil
      @mutex.synchronize do
        raise_terminal_or_state_unlocked! if @state.closed?

        plans = {} of UInt32 => OutboundTransition
        next_highest_local_id = @highest_local_opened_stream_id

        if header_block = command.header_block
          next_highest_local_id = plan_outbound_header_block_unlocked(
            plans,
            header_block,
            next_highest_local_id
          )
          planned_goaway = @last_sent_goaway
        else
          planned_goaway = plan_outbound_frames_unlocked(
            command,
            plans,
            next_highest_local_id
          )
        end

        @highest_local_opened_stream_id = next_highest_local_id
        plans.each_value do |plan|
          apply_outbound_transition_unlocked(plan)
        end
        apply_outbound_goaway_unlocked(planned_goaway)
      end
    end

    private def plan_outbound_header_block_unlocked(
      plans : Hash(UInt32, OutboundTransition),
      header_block : WriteCommand::HeaderBlock,
      highest_local_id : UInt32,
    ) : UInt32
      event = if header_block.end_stream
                Stream::Event::SendHeadersEndStream
              else
                Stream::Event::SendHeaders
              end
      plan_outbound_stream_event_unlocked(
        plans,
        header_block.stream_id,
        event,
        highest_local_id,
        @state.draining?
      )
    end

    private def plan_outbound_frames_unlocked(
      command : WriteCommand,
      plans : Hash(UInt32, OutboundTransition),
      highest_local_id : UInt32,
    ) : Frame::GoAway?
      planned_goaway = @last_sent_goaway
      command.frames.each do |frame|
        case frame
        when Frame::GoAway
          validate_outbound_goaway_unlocked(frame, planned_goaway)
          planned_goaway = frame
        when Frame::Data
          plan_outbound_data_unlocked(plans, frame, highest_local_id)
        when Frame::ResetStream
          plan_outbound_stream_event_unlocked(
            plans,
            frame.stream_id,
            Stream::Event::SendReset,
            highest_local_id,
            @state.draining?,
            reset_code: frame.error_code,
            close_error: command.stream_closure_error
          )
        when Frame::Priority
          plan_outbound_stream_event_unlocked(
            plans,
            frame.stream_id,
            Stream::Event::SendPriority,
            highest_local_id,
            @state.draining?
          )
        when Frame::WindowUpdate
          plan_outbound_window_update_unlocked(
            plans,
            frame,
            highest_local_id
          )
        else
          # Connection frames and unknown extensions do not alter streams.
        end
      end
      planned_goaway
    end

    private def plan_outbound_data_unlocked(
      plans : Hash(UInt32, OutboundTransition),
      frame : Frame::Data,
      highest_local_id : UInt32,
    ) : Nil
      event = if frame.end_stream?
                Stream::Event::SendDataEndStream
              else
                Stream::Event::SendData
              end
      plan_outbound_stream_event_unlocked(
        plans,
        frame.stream_id,
        event,
        highest_local_id,
        @state.draining?
      )
    end

    private def plan_outbound_window_update_unlocked(
      plans : Hash(UInt32, OutboundTransition),
      frame : Frame::WindowUpdate,
      highest_local_id : UInt32,
    ) : Nil
      return if frame.stream_id.zero?

      plan_outbound_stream_event_unlocked(
        plans,
        frame.stream_id,
        Stream::Event::SendWindowUpdate,
        highest_local_id,
        @state.draining?
      )
    end

    private def plan_outbound_stream_event_unlocked(
      plans : Hash(UInt32, OutboundTransition),
      stream_id : UInt32,
      event : Stream::Event,
      highest_local_id : UInt32,
      draining : Bool,
      *,
      reset_code : UInt32? = nil,
      close_error : Exception? = nil,
    ) : UInt32
      stream = @streams[stream_id]?
      unless stream
        return highest_local_id if event.send_priority?

        raise InvalidStateError.new(
          "stream #{stream_id} is not active on this connection"
        )
      end

      current_state = plans[stream_id]?.try(&.state) || stream.state
      if outbound_stream_opening?(current_state, event)
        highest_local_id = plan_local_stream_open_unlocked(
          plans,
          stream_id,
          highest_local_id,
          draining
        )
      end

      transition = Stream::StateMachine.transition(current_state, event)
      unless transition.action.allow?
        raise InvalidStateError.new(
          "cannot #{event.to_s.underscore} on stream #{stream_id} " \
          "in state #{current_state}"
        )
      end

      next_state = transition.next_state || current_state
      plans[stream_id] = build_outbound_transition(
        plans[stream_id]?,
        stream,
        next_state,
        event,
        reset_code,
        close_error
      )
      highest_local_id
    end

    private def outbound_stream_opening?(
      state : Stream::State,
      event : Stream::Event,
    ) : Bool
      state.idle? &&
        (event.send_headers? || event.send_headers_end_stream?)
    end

    private def plan_local_stream_open_unlocked(
      plans : Hash(UInt32, OutboundTransition),
      stream_id : UInt32,
      highest_local_id : UInt32,
      draining : Bool,
    ) : UInt32
      if draining
        raise DrainingError.new(
          "cannot open stream #{stream_id} on a draining connection"
        )
      end
      unless stream_id.odd?
        raise InvalidStateError.new(
          "clients can only open odd-numbered streams"
        )
      end
      if stream_id <= highest_local_id
        raise InvalidStateError.new(
          "stream #{stream_id} was skipped by a higher stream identifier"
        )
      end

      enforce_peer_concurrent_stream_limit_unlocked(plans)
      plan_skipped_local_streams_unlocked(plans, stream_id)
      stream_id
    end

    private def build_outbound_transition(
      prior : OutboundTransition?,
      stream : Stream,
      state : Stream::State,
      event : Stream::Event,
      reset_code : UInt32?,
      close_error : Exception?,
    ) : OutboundTransition
      reason = prior.try(&.close_reason)
      error = prior.try(&.close_error)
      if state.closed? && event.send_reset?
        reason = ClosedStream::Reason::LocalReset
        error = close_error ||
                CanceledError.new(stream.id, reset_code || 0_u32)
      elsif state.closed?
        reason ||= ClosedStream::Reason::EndStream
      end

      OutboundTransition.new(stream, state, reason, error)
    end

    private def enforce_peer_concurrent_stream_limit_unlocked(
      plans : Hash(UInt32, OutboundTransition),
    ) : Nil
      limit = @peer_settings_state.max_concurrent_streams
      return unless limit

      active = @streams.count do |id, stream|
        state = plans[id]?.try(&.state) || stream.state
        id.odd? && state.active?
      end
      if active.to_u64 >= limit.to_u64
        raise ConcurrentStreamLimitError.new(limit)
      end
    end

    private def plan_skipped_local_streams_unlocked(
      plans : Hash(UInt32, OutboundTransition),
      opening_stream_id : UInt32,
    ) : Nil
      @streams.each do |id, stream|
        next unless id.odd? && id < opening_stream_id

        state = plans[id]?.try(&.state) || stream.state
        next unless state.idle?

        plans[id] = OutboundTransition.new(
          stream,
          Stream::State::Closed,
          ClosedStream::Reason::Skipped,
          ClosedError.new(
            "stream #{id} was skipped by stream #{opening_stream_id}"
          )
        )
      end
    end

    private def apply_outbound_transition_unlocked(
      plan : OutboundTransition,
    ) : Nil
      plan.stream.transition_to(plan.state)
      return unless plan.state.closed?

      current = @streams[plan.stream.id]?
      if current && current.same?(plan.stream)
        @streams.delete(plan.stream.id)
      end
      if reason = plan.close_reason
        retain_closed_stream_unlocked(plan.stream.id, reason)
      end
      if error = plan.close_error
        terminate_stream_unlocked(plan.stream, error)
      end
    end

    private def terminate_stream_unlocked(
      stream : Stream,
      error : Exception,
    ) : Nil
      discarded = stream.terminate(error)
      @pending_stream_window_updates.delete(stream.id)
      if discarded > 0
        queue_connection_credit_unlocked(discarded.to_i64)
        wake_flow_control
      end
    end

    private def validate_outbound_goaway_unlocked(
      frame : Frame::GoAway,
      previous : Frame::GoAway?,
    ) : Nil
      last_stream_id = frame.last_stream_id
      if !last_stream_id.zero? && last_stream_id.odd?
        raise InvalidStateError.new(
          "a client GOAWAY last stream ID must identify a server stream"
        )
      end
      if previous && last_stream_id > previous.last_stream_id
        raise InvalidStateError.new(
          "successive GOAWAY last stream IDs cannot increase"
        )
      end
    end

    private def apply_outbound_goaway_unlocked(
      planned : Frame::GoAway?,
    ) : Nil
      return if planned == @last_sent_goaway

      @last_sent_goaway = planned
      @state = State::Draining unless @state.closed?
      emit_lifecycle("draining after local GOAWAY")
    end

    private def retain_closed_stream_unlocked(
      stream_id : UInt32,
      reason : ClosedStream::Reason,
    ) : Nil
      limit = @configuration.max_retained_closed_streams
      return if limit.zero?

      unless @closed_streams.has_key?(stream_id)
        @closed_stream_order << stream_id
      end
      @closed_streams[stream_id] = ClosedStream.new(stream_id, reason)

      while @closed_stream_order.size > limit
        if evicted_id = @closed_stream_order.shift?
          @closed_streams.delete(evicted_id)
        end
      end
    end

    private def materialize_frames(command : WriteCommand) : Array(Frames)
      if header_block = command.header_block
        encoded = @encoder.encode(
          header_block.fields.map(&.to_hpack)
        )
        HeaderBlockFramer.frames(
          header_block.stream_id,
          encoded,
          peer_settings_state.max_frame_size,
          end_stream: header_block.end_stream
        )
      else
        command.frames
      end
    end

    private def ensure_registered_stream!(stream_id : UInt32) : Nil
      if stream_id.zero?
        raise ArgumentError.new("HEADERS must use a nonzero stream ID")
      end

      @mutex.synchronize do
        unless @streams.has_key?(stream_id)
          raise InvalidStateError.new(
            "stream #{stream_id} is not registered on this connection"
          )
        end
      end
    end

    private def outbound_field_block_frame?(frame : Frames) : Bool
      frame.is_a?(Frame::Headers) ||
        frame.is_a?(Frame::PushPromise) ||
        frame.is_a?(Frame::Continuation)
    end

    {% if flag?(:preview_mt) %}
      private def spawn_transport_fiber(name : String, &block) : Nil
        # Legacy preview_mt event loops are thread-local. Pin every transport
        # operation to the thread that starts the connection.
        fiber = Fiber.new(name) do
          block.call
        end
        fiber.set_current_thread
        fiber.enqueue
      end
    {% else %}
      private def spawn_transport_fiber(name : String, &block) : Nil
        ::spawn(name: name) do
          block.call
        end
      end
    {% end %}

    private def raise_terminal_or_state! : NoReturn
      if error = terminal_error
        raise error
      end

      raise InvalidStateError.new("connection is not active")
    end

    private def raise_terminal_or_state_unlocked! : NoReturn
      if error = @terminal_error
        raise error
      end

      raise InvalidStateError.new("connection is not active")
    end
  end
end
