require "openssl"
require "socket"
require "./connection/*"
require "./stream"

module HTTP2
  # Owns one HTTP/2 transport, its ordered writer, reader, and stream registry.
  class Connection
    Preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".to_slice

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
    @mutex = Mutex.new
    @submission_mutex = Mutex.new
    @write_queue : Channel(WriteCommand)
    @handshake_done = Channel(Nil).new
    @closed_signal = Channel(Nil).new
    @transport_close_signal = Channel(Nil).new
    @writer_done = Channel(Nil).new
    @reader_done = Channel(Nil).new
    @transport_closer_done = Channel(Nil).new
    @settings_timer_wakeup = Channel(Nil).new(1)
    @settings_timer_done = Channel(Nil).new
    @writer_started = false
    @reader_started = false
    @transport_closer_started = false
    @settings_timer_started = false
    @streams = {} of UInt32 => Stream
    @stream_ids = StreamIDAllocator.new
    @pending_settings = [] of SettingsAcknowledgement
    @field_blocks : FieldBlockAssembler
    @encoder : HPack::Encoder
    @decoder : HPack::Decoder

    def initialize(
      @transport : IO,
      @configuration : Configuration = Configuration.new,
    )
      @write_queue = Channel(WriteCommand).new(
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
    end

    # Creates and starts a connection over a caller-supplied duplex IO.
    def self.start(
      transport : IO,
      configuration : Configuration = Configuration.new,
    ) : self
      new(transport, configuration).start
    end

    # Opens a cleartext connection using HTTP/2 prior knowledge.
    def self.connect_prior_knowledge(
      host : String,
      port : Int = 80,
      configuration : Configuration = Configuration.new,
    ) : self
      transport = TCPSocket.new(host, port)
      begin
        new(transport, configuration).start
      rescue error
        transport.close
        raise error
      end
    end

    # Opens a verified TLS connection that requires ALPN to select `h2`.
    def self.connect_tls(
      host : String,
      port : Int = 443,
      *,
      server_name : String = host,
      context : OpenSSL::SSL::Context::Client = OpenSSL::SSL::Context::Client.new,
      configuration : Configuration = Configuration.new,
    ) : self
      transport = TCPSocket.new(host, port)
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

    def active_stream_count : Int32
      @mutex.synchronize { @streams.size }
    end

    def stream?(id : UInt32) : Stream?
      return if id.zero?

      @mutex.synchronize { @streams[id]? }
    end

    def new_stream : Stream
      @mutex.synchronize do
        unless @state.handshaking? || @state.active?
          raise InvalidStateError.new(
            "new streams require a handshaking or active connection"
          )
        end

        id = @stream_ids.allocate
        stream = Stream.new(
          self,
          id,
          @configuration.stream_event_capacity
        )
        @streams[id] = stream
      end
    end

    # Writes one frame through the connection's sole writer fiber.
    def write_frame(frame : Frames) : Nil
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
      if frames.any? { |frame| frame.is_a?(Frame::Settings) && !frame.ack? }
        raise ArgumentError.new(
          "non-ACK SETTINGS frames must be sent with #send_settings"
        )
      end

      submit(WriteCommand.new(frames.dup))
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

          updated = @local_settings_state.with_local(materialized)
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

    # :nodoc:
    def remove_stream(stream : Stream) : Nil
      @mutex.synchronize do
        current = @streams[stream.id]?
        @streams.delete(stream.id) if current && current.same?(stream)
      end
    end

    private def submit(command : WriteCommand) : Nil
      @submission_mutex.synchronize { enqueue(command) }
      command.wait
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

    private def writer_loop : Nil
      while command = @write_queue.receive?
        if error = terminal_error
          command.complete(error)
          next
        end

        begin
          if table_size = command.encoder_table_size
            @encoder.resize_table(table_size)
          end
          frames = materialize_frames(command)
        rescue error
          command.complete(error)
          next
        end

        begin
          @transport.write(Preface) if command.preface?
          frames.each(&.write(@transport))
          @transport.flush
          command.complete
        rescue error
          command.complete(error)
          terminate(error)
        end
      end
    ensure
      error = terminal_error || ClosedError.new("HTTP/2 writer stopped")
      while command = @write_queue.receive?
        command.complete(error)
      end
      @writer_done.close
    end

    private def transport_closer_loop : Nil
      @transport_close_signal.receive?
      close_transport
    ensure
      @transport_closer_done.close
    end

    private def reader_loop : Nil
      handle_server_preface(read_server_preface)
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

      handle_stream_violation(error)
      nil
    end

    private def process_inbound_frame(frame : Frames) : Nil
      event = @field_blocks.process(frame)
      return unless event

      case event
      when FieldBlock
        begin
          dispatch(decode_field_block(event))
        rescue error : ProtocolError
          raise error unless error.stream?

          handle_stream_violation(error)
        end
      else
        dispatch(event)
      end
    end

    private def decode_field_block(block : FieldBlock) : FieldSection
      fields = [] of DecodedHeaderField
      result = @decoder.decode_each(
        block.encoded,
        max_field_section_size: decoded_field_section_limit
      ) do |field|
        fields << DecodedHeaderField.from_hpack(field)
      end

      if result.limit_exceeded
        raise ProtocolError.new(
          "decoded field section exceeds the configured limit",
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
        write_frame(event.ack) unless event.ack?
      when Frame::GoAway
        handle_goaway(event)
      when Frame::WindowUpdate
        dispatch_to_stream(event) unless event.stream_id.zero?
      when Frame::Unknown
        # RFC 9113 requires unknown frame types to be ignored.
      else
        dispatch_to_stream(event)
      end
    end

    private def apply_peer_settings(settings : Frame::Settings) : Int32?
      previous, updated = @mutex.synchronize do
        previous = @peer_settings_state
        @peer_settings_state = @peer_settings_state.with_peer(settings.entries)
        @peer_settings = settings
        {previous, @peer_settings_state}
      end

      return if previous.header_table_size == updated.header_table_size

      Math.min(
        updated.header_table_size.to_u64,
        @configuration.max_encoder_table_size.to_u64
      ).to_i32
    end

    private def acknowledge_peer_settings(
      settings : Frame::Settings,
    ) : Nil
      command = @submission_mutex.synchronize do
        table_size = apply_peer_settings(settings)
        acknowledgement = WriteCommand.settings_ack(table_size)
        enqueue(acknowledgement)
        acknowledgement
      end
      command.wait
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
        @effective_local_settings_state = effective_settings
        {prior_settings, effective_settings}
      end

      apply_effective_local_settings(previous, updated)
      wake_settings_timer
    end

    private def handle_goaway(frame : Frame::GoAway) : Nil
      @mutex.synchronize do
        @last_goaway = frame
        @state = State::Draining unless @state.closed?
        affected_ids = @streams.keys.select { |id| id > frame.last_stream_id }
        affected_ids.each do |id|
          if stream = @streams.delete(id)
            stream.terminate(
              ClosedError.new("stream was not processed before GOAWAY")
            )
          end
        end
      end
    end

    private def dispatch_to_stream(event : StreamEvent) : Nil
      full_stream_id = @mutex.synchronize do
        if stream = @streams[event.stream_id]?
          stream.id unless stream.deliver(event)
        end
      end
      if full_stream_id
        raise QueueFullError.new(
          "stream #{full_stream_id} event queue reached its configured limit"
        )
      end
    end

    private def handle_stream_violation(error : ProtocolError) : Nil
      id = error.stream_id
      unless id
        raise InvalidStateError.new(
          "stream-scoped protocol violation is missing a stream ID"
        )
      end
      write_frame(Frame::ResetStream.new(id, error.error_code))

      @mutex.synchronize do
        @streams.delete(id).try(&.terminate(error))
      end
    end

    private def send_goaway(error : ProtocolError) : Nil
      write_frame(Frame::GoAway.new(0_u32, error.error_code))
    rescue
      # The original protocol violation remains the terminal error.
    end

    private def terminate(error : Exception) : Nil
      close_directly = false
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
          close_directly = !@transport_closer_started
          true
        end
      end
      return unless terminated

      @write_queue.close
      @transport_close_signal.close
      @settings_timer_wakeup.close
      @handshake_done.close
      @closed_signal.close

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
      writer_started, reader_started, transport_closer_started, settings_timer_started =
        @mutex.synchronize do
          {
            @writer_started,
            @reader_started,
            @transport_closer_started,
            @settings_timer_started,
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
    end

    private def close_transport : Nil
      @transport.close
    rescue
      # The connection's stored terminal error remains authoritative.
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
      # Phase 5 applies INITIAL_WINDOW_SIZE deltas to live streams. The
      # decoder limit changes only when the corresponding SETTINGS is ACKed.
      if previous.header_table_size != updated.header_table_size
        @decoder.max_table_size = updated.header_table_size.to_i32
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
