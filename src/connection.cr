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
    @last_goaway : Frame::GoAway?
    @mutex = Mutex.new
    @write_queue : Channel(WriteCommand)
    @handshake_done = Channel(Nil).new
    @closed_signal = Channel(Nil).new
    @transport_close_signal = Channel(Nil).new
    @writer_done = Channel(Nil).new
    @reader_done = Channel(Nil).new
    @transport_closer_done = Channel(Nil).new
    @writer_started = false
    @reader_started = false
    @transport_closer_started = false
    @streams = {} of UInt32 => Stream
    @stream_ids = StreamIDAllocator.new

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
      initial_command = WriteCommand.new(
        [local_settings] of Frames,
        preface: true
      )
      @mutex.synchronize do
        unless @state.new?
          raise InvalidStateError.new("connection can only be started once")
        end
        @write_queue.send(initial_command)
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
      write_batch([frame] of Frames)
    end

    # Writes a frame batch without allowing another command to interleave.
    def write_batch(frames : Array(Frames)) : Nil
      return if frames.empty?

      submit(WriteCommand.new(frames.dup))
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
      current_state = state
      if current_state.new?
        raise InvalidStateError.new("connection has not been started")
      end
      raise_terminal_or_state! if current_state.closed?

      @write_queue.send(command)
      command.wait
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
          @transport.write(Preface) if command.preface?
          command.frames.each(&.write(@transport))
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
      first_frame = true

      loop do
        frame = begin
          Frame.read(
            @transport,
            @configuration.inbound_max_frame_size
          )
        rescue error : ProtocolError
          if first_frame
            raise ProtocolError.new(
              "invalid server connection preface: #{error.message}"
            )
          elsif error.stream?
            handle_stream_violation(error)
            next
          else
            raise error
          end
        end

        if first_frame
          handle_server_preface(frame)
          first_frame = false
        else
          dispatch(frame)
        end
      end
    rescue error : ProtocolError
      send_goaway(error)
      terminate(error)
    rescue error
      terminate(error) unless closed?
    ensure
      @reader_done.close
    end

    private def handle_server_preface(frame : Frames) : Nil
      settings = frame.as?(Frame::Settings)
      if settings.nil? || settings.ack?
        raise ProtocolError.new(
          "the server's first frame must be a non-ACK SETTINGS frame"
        )
      end

      acknowledge(settings)
      activated = @mutex.synchronize do
        unless @state.closed?
          @peer_settings = settings
          @state = State::Active
          true
        end
      end
      @handshake_done.close if activated
    end

    private def dispatch(frame : Frames) : Nil
      case frame
      when Frame::Settings
        acknowledge(frame) unless frame.ack?
      when Frame::Ping
        write_frame(frame.ack) unless frame.ack?
      when Frame::GoAway
        handle_goaway(frame)
      when Frame::WindowUpdate
        dispatch_to_stream(frame) unless frame.stream_id.zero?
      when Frame::Unknown
        # RFC 9113 requires unknown frame types to be ignored.
      else
        dispatch_to_stream(frame)
      end
    end

    private def acknowledge(settings : Frame::Settings) : Nil
      write_frame(settings.ack)
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

    private def dispatch_to_stream(frame : Frames) : Nil
      full_stream_id = @mutex.synchronize do
        if stream = @streams[frame.stream_id]?
          stream.id unless stream.deliver(frame)
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
          close_directly = !@transport_closer_started
          true
        end
      end
      return unless terminated

      @write_queue.close
      @transport_close_signal.close
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
      writer_started, reader_started, transport_closer_started =
        @mutex.synchronize do
          {
            @writer_started,
            @reader_started,
            @transport_closer_started,
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
    end

    private def close_transport : Nil
      @transport.close
    rescue
      # The connection's stored terminal error remains authoritative.
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
  end
end
