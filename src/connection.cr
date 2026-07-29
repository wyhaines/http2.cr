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

    # Upper bound on how many `WriteCommand`s the writer fiber stages
    # into the transport buffer before forcing a flush (`#writer_loop`,
    # `#flush_batch`), even if more immediately-available work remains.
    # Keeps a single flush's completion latency bounded under sustained
    # load instead of growing unboundedly with queue depth.
    MAX_BATCH = 64

    enum State
      New
      Handshaking
      Active
      Draining
      Closed
    end

    getter configuration : Configuration
    getter local_settings : Frame::Settings

    # :nodoc:
    #
    # The raw (pre-TLS-wrapping) transport `.start_tls` dialed, when this
    # connection is a TLS one; `nil` for every other constructor (cleartext,
    # or a caller-supplied `@transport` via `.start`). `#close_transport`
    # closes this directly instead of routing a force-close through the TLS
    # wrapper's own `#close` — see `#close_transport` for why. The setter
    # is `protected`, not public: it exists only for `self.start_tls` (a
    # class method of this same type, which `protected` permits) to
    # record the raw socket at construction time. Nothing outside this
    # class has a legitimate reason to reassign it after the fact, and a
    # `property` here would put a public setter on the 1.0 API for no
    # benefit.
    getter tls_raw_transport : IO?
    protected setter tls_raw_transport : IO?

    @state = State::New
    @terminal_error : Exception?
    @peer_settings : Frame::Settings?
    @local_settings_state : SettingsState
    @effective_local_settings_state = SettingsState.client_defaults
    # Reader-fiber-only mirror of `@effective_local_settings_state.max_frame_size`,
    # kept so `#read_frame`/`#read_server_preface` (the hottest per-frame call
    # in the connection) never take `@mutex` just to read a value that only
    # ever changes once per acknowledged local SETTINGS update. Written only
    # by `#acknowledge_local_settings`, which runs exclusively on the reader
    # fiber (see that method's comment); read only from `#read_frame`/
    # `#read_server_preface`, also reader-fiber-only. Same initial value as
    # `@effective_local_settings_state` above, for the same reason: the
    # locally configured max frame size does not take effect until the peer
    # ACKs our SETTINGS frame.
    @reader_max_frame_size = SettingsState.client_defaults.max_frame_size
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
    @stream_slot_wakeup = Channel(Nil).new(1)
    @writer_started = false
    @preface_sent = false
    @reader_started = false
    @transport_closer_started = false
    @settings_timer_started = false
    @drain_started = false
    @keepalive_started = Atomic(Bool).new(false)
    @drain_deadline : Time::Instant?
    # Monotonic nanoseconds (`Time.monotonic.total_nanoseconds.to_i64`), not
    # `Time.instant` -- read lock-free from the per-frame path
    # (`observe_inbound_frame`) with no mutex, unlike the rest of this
    # connection's timing state. `Time.instant` and `Time.monotonic` share
    # the same underlying clock reading (both delegate to
    # `Crystal::System::Time.monotonic`), so ns arithmetic here stays
    # comparable with `Time.instant`-based deadlines elsewhere.
    @last_inbound_activity_ns = Atomic(Int64).new(
      Time.monotonic.total_nanoseconds.to_i64
    )
    @keepalive_sequence = 0_u32
    # Counts PUSH_PROMISE frames accepted while our own ENABLE_PUSH=0
    # SETTINGS has not yet been acknowledged (see `validate_push_promise!`).
    # Never reset: `send_settings` already refuses to ever re-enable push
    # (`updated.enable_push?` check), so there is exactly one such window
    # per connection, immediately after `start`.
    @pre_ack_push_promise_count = 0
    @streams = {} of UInt32 => Stream
    @request_reservations = {} of UInt64 => Bool
    @next_request_reservation_id = 0_u64
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
    @field_blocks : FieldBlockAssembler
    @inbound_frame_rate_limiter : InboundFrameRateLimiter
    @encoder : HPack::Encoder
    @decoder : HPack::Decoder
    @diagnostics : Channel(Diagnostic)
    # Set true the first time `#diagnostics` is called; gates `emit_frame`
    # and `emit_diagnostic` off the frame/error/lifecycle paths so a
    # connection with no diagnostics consumer never allocates a
    # `Diagnostic` or touches `@diagnostics`/`@dropped_diagnostic_count`.
    @diagnostics_enabled = Atomic(Bool).new(false)
    @dropped_diagnostic_count = Atomic(UInt64).new(0_u64)
    @pool_state_subscription_mutex = Mutex.new
    @pool_state_subscriptions = {} of UInt64 => Proc(Nil)
    @next_pool_state_subscription_id = 0_u64

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
    #
    # **TLS callers: prefer `connect_tls`/`start_tls`, or `HTTP2::Client`.**
    # If `transport` is a caller-built `OpenSSL::SSL::Socket`, this
    # connection's `tls_raw_transport` stays `nil` forever — only
    # `start_tls` can set it (its setter is `protected`, so there is no
    # way for a caller to supply it here), and Crystal's
    # `OpenSSL::SSL::Socket` exposes no accessor for the raw `IO` behind
    # its BIO, so the library has no way to discover it after the fact
    # either. That leaves `#close`/`#terminate` exposed to the unbounded
    # `SSL_shutdown` close hang described on `#close_transport`'s doc
    # comment: with no raw socket to force-close instead, shutdown falls
    # back to the TLS wrapper's own close, which can block indefinitely
    # against a stalled peer if `transport` has no `write_timeout` set.
    # `connect_tls`, `start_tls`, and `HTTP2::Client` are unaffected —
    # they dial the raw socket themselves and record it. A caller who
    # must use this constructor with their own TLS socket should set a
    # `write_timeout` on it directly to bound that close.
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

      # Cleartext TCP defaults to `sync = true` (every write is its own
      # `send(2)`); buffering lets the writer coalesce a frame's header and
      # payload, several commands, and several scheduled DATA frames, into
      # a single `send(2)` per batch (`#writer_loop`/`#flush_batch`). This
      # is safe only because every staged byte is memcpy'd into
      # `@transport`'s own buffer (`#stage_write_command`, `#stage_frames`,
      # `#stage_scheduled_data`) before the writer fiber can next block
      # waiting for work, and `#flush_batch` unconditionally flushes
      # *every* byte staged since the last flush — not just bytes that
      # happen to belong to a `WriteCommand` — before that park.
      # WINDOW_UPDATE frames (`#stage_frames`) and a DATA chunk written
      # mid-block (`#stage_scheduled_data`, before its command's
      # `block.complete?`) both stage real bytes with no owning command
      # and no pool-capacity change; `#flush_batch` flushes them anyway,
      # every time, precisely because it does not gate the flush on
      # whether anything is waiting to be completed or notified. See the
      # zero-copy tripwire on `#stage_scheduled_data` for the full
      # argument, and the flush audit in the P1.8 task report for the
      # original single-command-per-flush version of this property.
      #
      # `IO::Buffered`'s default buffer is not guaranteed to hold a full
      # frame: if it's smaller than `header + payload`, the buffered header
      # flushes as its own tiny `send(2)` and the payload bypasses the
      # buffer as a second syscall, silently defeating the coalescing
      # above. Sized here to fit header+payload of a DATA frame chunked to
      # the configured `outbound_data_chunk_size`; HEADERS/CONTINUATION
      # field sections and directly-submitted DATA frames are instead
      # bounded by the peer's negotiated `SETTINGS_MAX_FRAME_SIZE`, which
      # can exceed this buffer if negotiated above
      # `outbound_data_chunk_size` — a gap that can't be closed here since
      # negotiation hasn't happened yet at construction time. The TLS path
      # (`start_tls`, below) needs the identical fix: `OpenSSL::SSL::Socket`
      # also includes `IO::Buffered` with the same default and is not
      # exempt from this.
      transport.sync = false
      transport.buffer_size = Math.pw2ceil(
        configuration.outbound_data_chunk_size + FrameHeader::SIZE
      )

      begin
        new(transport, configuration).start
      rescue error
        transport.close
        raise error
      end
    end

    # Builds the TLS client context used when a caller does not supply
    # one: `connect_tls`'s and `start_tls`'s default `context:` argument,
    # and `HTTP2::Client`'s default `tls_context`, all call this, so
    # every internally created context stays in lockstep.
    #
    # Disables TLS 1.0 and TLS 1.1 explicitly — RFC 9113 §9.2:
    # "deployments of HTTP/2 ... MUST NOT use TLS 1.1 or lower" — rather
    # than relying on `OpenSSL::SSL::Context`'s own constructor already
    # disabling both by default (true since Crystal 0.35.0, for every
    # context, including a caller-supplied one — see the task report for
    # the upstream commit). That stdlib default is not part of this
    # method's documented contract and not something a future Crystal or
    # alternate OpenSSL binding is obligated to preserve, so this library
    # asserts its own RFC floor instead of depending on it silently.
    #
    # A context a CALLER supplies directly to `connect_tls`/`start_tls`/
    # `HTTP2::Client.new` is never passed through this method and is
    # never modified this way — only the internally created default is.
    def self.default_tls_context : OpenSSL::SSL::Context::Client
      context = OpenSSL::SSL::Context::Client.new
      context.add_options(
        OpenSSL::SSL::Options::NO_TLS_V1 | OpenSSL::SSL::Options::NO_TLS_V1_1
      )
      context
    end

    # Opens a verified TLS connection that requires ALPN to select `h2`.
    #
    # `read_timeout` and `write_timeout` default to `nil` (no transport
    # deadlines). Against untrusted or unreliable peers, set them and/or
    # enable `Configuration#keepalive_interval`; otherwise a silent or
    # write-stalled peer can hold blocked callers indefinitely.
    # `handshake_read_timeout` bounds only the TLS handshake itself (see
    # `start_tls`) without leaving a persistent `read_timeout` armed
    # afterward. `HTTP2::Client` sets `write_timeout` by default and
    # bounds the TLS and HTTP/2 handshakes with per-wait deadlines
    # (`handshake_read_timeout` and `wait_until_active`, respectively)
    # instead of a persistent `read_timeout`; it enables keepalive by
    # default to detect a silent peer once active.
    #
    # `context`, whether supplied or defaulted, is configured for ALPN
    # "h2" IN PLACE, unconditionally, on every call — see `start_tls`'s
    # doc comment for the full contract, why no private copy is made
    # instead, and the caller-visible consequence of configuring in
    # place.
    def self.connect_tls(
      host : String,
      port : Int = 443,
      *,
      server_name : String = host,
      context : OpenSSL::SSL::Context::Client = default_tls_context,
      configuration : Configuration = Configuration.new,
      connect_timeout : Time::Span? = nil,
      read_timeout : Time::Span? = nil,
      write_timeout : Time::Span? = nil,
      handshake_read_timeout : Time::Span? = nil,
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
          configuration: configuration,
          handshake_read_timeout: handshake_read_timeout
        )
      rescue error
        transport.close unless transport.closed?
        raise error
      end
    end

    # Wraps a supplied transport in verified TLS and starts HTTP/2.
    #
    # `handshake_read_timeout`, when given, bounds each individual read
    # during the TLS handshake (per read, like `read_timeout` elsewhere —
    # not a cumulative deadline for the whole handshake) by setting it as
    # `transport`'s `read_timeout` for the duration of the handshake only;
    # the transport's previous `read_timeout` (nil, or whatever a caller
    # set directly) is reinstated once the handshake and ALPN check are
    # done, before HTTP/2 starts — so it never lingers as a persistent
    # transport-level deadline afterward, and a caller who also set a
    # persistent `read_timeout` directly on `transport` gets it back
    # unchanged. Silently ignored if `transport` doesn't support
    # `read_timeout=` (its static type is the untyped `IO`).
    # `connect_prior_knowledge` has no equivalent parameter because
    # `Connection#start` performs no synchronous read of its own — the
    # cleartext dial path never blocks on a read before `wait_until_active`
    # is already covering the wait.
    #
    # `context` is configured for ALPN "h2" IN PLACE, unconditionally, on
    # every call — never on a private copy.
    # `OpenSSL::SSL::Context::Client` wraps a bare `SSL_CTX*` behind
    # `@handle`, and Crystal's default `#dup` only shallow-copies
    # instance variables, so a `dup`'d context would share that SAME
    # `@handle` with the original (verified while investigating this:
    # both report an identical `to_unsafe` pointer address). Mutating
    # the "copy" would mutate the original's underlying C state too,
    # buying no isolation — and BOTH Crystal objects would independently
    # call `LibSSL.ssl_ctx_free(@handle)` from their own `#finalize`,
    # freeing the same handle twice. `SSL_CTX` also has no deep-copy
    # operation in OpenSSL itself, so a safe copy is not available by
    # any route; ALPN "h2" is mandatory for this library regardless, so
    # the mutation cannot be avoided either way.
    # `#alpn_protocol=` internally frees its previous protos buffer and
    # mem-dups the new one (`SSL_CTX_set_alpn_protos`), so setting it
    # again on every dial is cheap and safe, not merely tolerated.
    #
    # Setting it unconditionally, every dial, is deliberate, not an
    # oversight: it is SELF-HEALING against anything else that changes
    # `context.alpn_protocol` between dials — the next dial through this
    # library re-asserts "h2" regardless of what it finds. The
    # symmetric, caller-visible consequence: do not share one context
    # between an `HTTP2::Client`/`connect_tls`/`start_tls` caller and a
    # DIFFERENT consumer that needs a different, stable ALPN protocol on
    # it — every dial through this library overwrites `alpn_protocol`
    # back to "h2" unconditionally, even if that other consumer set it
    # to something else in between.
    def self.start_tls(
      transport : IO,
      server_name : String,
      *,
      context : OpenSSL::SSL::Context::Client = default_tls_context,
      configuration : Configuration = Configuration.new,
      handshake_read_timeout : Time::Span? = nil,
    ) : self
      # In place, unconditionally, every call — see the doc comment
      # above for why no copy is made and why "every call" (not "once
      # per context") is the deliberately chosen, self-healing behavior.
      context.alpn_protocol = "h2"

      previous_read_timeout = nil
      if handshake_read_timeout
        previous_read_timeout = transport.read_timeout if transport.responds_to?(:read_timeout)
        transport.read_timeout = handshake_read_timeout if transport.responds_to?(:read_timeout=)
      end

      begin
        tls = begin
          OpenSSL::SSL::Socket::Client.new(
            transport,
            context,
            sync_close: true,
            hostname: server_name
          )
        rescue error : OpenSSL::SSL::Error
          # Scoped to JUST the handshake construction above: an
          # `OpenSSL::SSL::Error` raised by anything later — the ALPN
          # check below (in practice it never raises this type; see
          # `TLSNegotiationError` above), or, more importantly,
          # `Connection#start`'s preface write further down — is a
          # DIFFERENT failure mode from "the handshake itself failed"
          # and must not be misreported as a verification error. The
          # bare `rescue error` at the bottom of this method is what
          # those propagate through instead, unchanged.
          raise TLSVerificationError.new(server_name, error)
        end

        # `OpenSSL::SSL::Socket` includes `IO::Buffered` with the same
        # default buffer as cleartext (see the sizing rationale in
        # `connect_prior_knowledge`, above; same caveat as the cleartext
        # site: frames bounded by the peer's negotiated
        # `SETTINGS_MAX_FRAME_SIZE` — HEADERS/CONTINUATION sections and
        # directly-submitted DATA — can still exceed this buffer, and
        # negotiation hasn't happened yet at construction time) — not
        # guaranteed to hold a full frame's header and payload together,
        # which would flush the header as its own tiny `send(2)` and push
        # the payload through unbuffered as a second one. At today's
        # stdlib default
        # (`IO::DEFAULT_BUFFER_SIZE` has been 32768 since Crystal PR
        # #12507, comfortably above this shard's `>= 1.20.0` floor) this
        # is a defensive no-op for the default `outbound_data_chunk_size`;
        # it starts to matter as soon as `outbound_data_chunk_size` is
        # configured higher. Must be set here, right after construction
        # and before this method's first write to `tls` (the preface, in
        # `Connection#start` below): `buffer_size=` raises once a read or
        # write has allocated the buffer.
        tls.buffer_size = Math.pw2ceil(
          configuration.outbound_data_chunk_size + FrameHeader::SIZE
        )

        unless tls.alpn_protocol == "h2"
          tls.close
          raise TLSNegotiationError.new("the TLS peer did not negotiate ALPN h2")
        end
      ensure
        if handshake_read_timeout && transport.responds_to?(:read_timeout=)
          transport.read_timeout = previous_read_timeout
        end
      end

      connection = new(tls, configuration)
      connection.tls_raw_transport = transport
      connection.start
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

      # Unlike the reader-start `unless @state.closed?` guard below, this
      # grant needs no closed-state check of its own — not because
      # nothing could have closed the connection by this point (under
      # `-Dpreview_mt` the writer/transport-closer fibers just spawned
      # above run concurrently with this method, so that is not a safe
      # assumption to make on scheduling grounds alone), but because
      # queuing credit on an already-closing connection is harmless
      # either way: `queue_connection_credit_unlocked` just increments a
      # counter nothing will ever read again, and `wake_flow_control`
      # already tolerates a closed `@flow_control_wakeup` channel (see
      # its own `rescue Channel::ClosedError`). The reader-start guard
      # below exists for a different reason: `initial_command.wait`'s own
      # `rescue` always re-raises after tearing the connection down, so
      # it never reaches the guard itself. What the guard actually
      # protects against is a concurrent, independent teardown landing
      # between `initial_command.wait` returning successfully and the
      # check below — either a caller's own public, unguarded `#close`
      # (a thin wrapper around the private `#terminate`), or the writer
      # fiber spawned above reaching that same private `#terminate`
      # itself, on its own, after a transport write or flush failure (see
      # `#stage_write_command`/`#stage_frames`/`#flush_batch`) — without
      # the guard, either race could spawn a reader fiber on a connection
      # that is already closed.
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

    # Returns an authoritative request-admission snapshot.
    #
    # :nodoc:
    def request_capacity : RequestCapacity
      @mutex.synchronize { request_capacity_unlocked }
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
    #
    # Diagnostic emission is gated off the frame path and only turns on the
    # first time this accessor is called (`@diagnostics_enabled`) -- frames,
    # errors, and lifecycle events observed before that first call are
    # deliberately never captured. Call this (even without receiving from
    # the returned channel right away) before driving any traffic whose
    # diagnostics you need to see.
    def diagnostics : Channel(Diagnostic)
      @diagnostics_enabled.set(true)
      @diagnostics
    end

    def dropped_diagnostic_count : UInt64
      @dropped_diagnostic_count.get
    end

    def stream?(id : UInt32) : Stream?
      return if id.zero?

      @mutex.synchronize { @streams[id]? }
    end

    # Atomically admits one future client request without allocating a stream
    # ID or sending bytes. Ordinary lack of capacity returns nil.
    #
    # :nodoc:
    def try_reserve_request_slot : RequestSlotReservation?
      @mutex.synchronize do
        next unless request_slot_available_unlocked?

        @next_request_reservation_id += 1_u64
        id = @next_request_reservation_id
        @request_reservations[id] = true
        RequestSlotReservation.new(self, id)
      end
    end

    # Converts a request-slot reservation into an idle client stream without
    # an admission-accounting gap.
    #
    # :nodoc:
    def materialize_request_stream(
      reservation : RequestSlotReservation,
    ) : Stream
      unless reservation.connection.same?(self)
        raise ArgumentError.new(
          "request-slot reservation belongs to another connection"
        )
      end

      exhausted = false
      stream = @mutex.synchronize do
        unless @request_reservations.has_key?(reservation.id)
          raise InvalidStateError.new(
            "request-slot reservation is no longer pending"
          )
        end

        validate_request_slot_materialization_unlocked!
        @request_reservations.delete(reservation.id)
        current = allocate_client_stream_unlocked
        exhausted = @stream_ids.exhausted?
        current
      end
      notify_pool_state if exhausted
      stream
    rescue error
      release_request_slot(reservation)
      raise error
    end

    # Idempotently releases a pending request-slot reservation.
    #
    # :nodoc:
    def release_request_slot(
      reservation : RequestSlotReservation,
    ) : Nil
      unless reservation.connection.same?(self)
        raise ArgumentError.new(
          "request-slot reservation belongs to another connection"
        )
      end

      released = @mutex.synchronize do
        !@request_reservations.delete(reservation.id).nil?
      end
      notify_pool_state if released
    end

    # Atomically claims and closes an active connection only if it has no
    # registered streams or pending request reservations.
    #
    # :nodoc:
    def close_if_idle : Bool
      claimed = @mutex.synchronize do
        if @state.active? &&
           @streams.empty? &&
           @request_reservations.empty?
          @state = State::Draining
          true
        else
          false
        end
      end
      return false unless claimed

      notify_pool_state
      terminate(ClosedError.new("HTTP/2 idle connection closed"))
      true
    end

    # Registers an independent, nonblocking pool-state listener.
    #
    # :nodoc:
    def subscribe_pool_state(
      &callback : -> Nil
    ) : PoolStateSubscription
      id = @pool_state_subscription_mutex.synchronize do
        @next_pool_state_subscription_id += 1_u64
        current = @next_pool_state_subscription_id
        @pool_state_subscriptions[current] = callback
        current
      end
      PoolStateSubscription.new(self, id)
    end

    # :nodoc:
    def remove_pool_state_subscription(id : UInt64) : Nil
      @pool_state_subscription_mutex.synchronize do
        @pool_state_subscriptions.delete(id)
      end
    end

    def new_stream : Stream
      exhausted = false
      stream = @mutex.synchronize do
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
        # Counts every registered stream regardless of state — idle,
        # active, or reserved — not just ones this admission bound is
        # meant to police. That includes a narrow, bounded case of
        # terminated-stream orphans: a pushed stream this connection
        # already auto-rejects (`reject_push_promise`/
        # `cancel_rejected_promise`) or a stream failing a reader-detected
        # protocol violation (`handle_stream_violation`) is RST via
        # `#send_reset_nowait`, which enqueues the reset and returns
        # immediately rather than waiting for the writer to apply it —
        # so the doomed stream still counts here until that queued RST is
        # actually processed. Caller-initiated closes (`Stream#cancel`/
        # `#close`) do not have this gap: they block on `#send_reset`'s
        # `#submit`, so by the time that call returns the entry is
        # already gone.
        if @streams.size >= @configuration.max_open_streams
          raise OpenStreamLimitError.new(@configuration.max_open_streams)
        end

        current = allocate_client_stream_unlocked
        exhausted = @stream_ids.exhausted?
        current
      end
      notify_pool_state if exhausted
      stream
    end

    # Waits for a peer-imposed concurrent-stream slot to possibly have
    # freed up, for `cancellation` to fire, or for `timeout` to elapse —
    # whichever happens first. Returns in all three cases without
    # raising: the caller is expected to retry the `#send_headers` call
    # that raised `ConcurrentStreamLimitError` (and to check its own
    # cancellation/deadline), so a stale or spurious wakeup here is
    # harmless — it costs at most one extra retry. This remains available
    # to raw `Connection` users; `HTTP2::Client` now performs pool-wide
    # request-slot acquisition instead.
    #
    # :nodoc:
    def wait_for_stream_slot(
      timeout : Time::Span,
      cancellation : Channel(Nil)? = nil,
    ) : Nil
      if cancellation
        select
        when @stream_slot_wakeup.receive?
        when cancellation.receive?
        when timeout(timeout)
        end
      else
        select
        when @stream_slot_wakeup.receive?
        when timeout(timeout)
        end
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
    #
    # Under the default single-threaded runtime, `data` is sliced, not
    # copied: `submit_data` (via `#command.wait`) blocks until each
    # chunk's frame has been memcpy'd into the transport buffer and its
    # batch has either flushed or failed (see `#flush_batch`) before
    # returning, so by the time this call returns, nothing internal to
    # the connection still reads from `data`. See `#stage_scheduled_data`'s
    # comment for the invariants that guarantee this.
    #
    # Under `-Dpreview_mt`, `#owned_for_write` takes a private copy of
    # each chunk instead: `#terminate` is reachable from fibers not
    # pinned to the writer's thread (`#close`, and the drain-monitor,
    # keepalive, and settings-timer loops, all plain `::spawn` unlike
    # `#spawn_transport_fiber`'s pinned reader/writer fibers), and it
    # can unblock this call's `#command.wait` on a different OS thread
    # while the writer thread is still copying the chunk into the
    # transport buffer.
    #
    # Either way, the caller must leave `data` unmodified until this
    # call returns; it is never retained afterward.
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
            owned_for_write(data[offset, size])
          )
        )
        offset += size
      end
    end

    # Streams DATA from the source's current position without rewinding it.
    #
    # Reads into two reusable buffers instead of allocating one per chunk.
    # This relies on `#send_data(Bytes)` being synchronous: it blocks
    # until the chunk it was given has been handed to the transport
    # before returning, so a buffer is never refilled while a prior call
    # might still be reading from it (default single-threaded runtime),
    # or is refilled only after `#owned_for_write` has already taken a
    # private copy of the in-flight chunk (`-Dpreview_mt`; see
    # `#send_data(Bytes)`'s doc comment). `current` and `following` swap
    # roles each iteration; the loop always reads into the buffer that
    # was NOT just handed to `#send_data`.
    def send_data(
      stream_id : UInt32,
      source : IO,
      *,
      end_stream : Bool = true,
    ) : Nil
      ensure_registered_stream!(stream_id)
      chunk_size = @configuration.outbound_data_chunk_size
      buffer_a = Bytes.new(chunk_size)
      buffer_b = Bytes.new(chunk_size)
      current = buffer_a
      following = buffer_b
      current_size = source.read(current)

      if current_size.zero?
        send_data(stream_id, Bytes.empty, end_stream: end_stream)
        return
      end

      loop do
        following_size = source.read(following)
        final = following_size.zero?
        send_data(
          stream_id,
          current[0, current_size],
          end_stream: end_stream && final
        )
        break if final

        current, following = following, current
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

    # Enqueues one ordered field section onto the writer's FIFO
    # `@write_queue` without waiting for it to reach the transport (the
    # HPACK encoding itself is deferred further still — to the writer
    # fiber, once it dequeues this command — so this method only ever
    # does admission-order bookkeeping). Returns the `WriteCommand` so a
    # caller that holds an external ordering lock across multiple
    # same-connection submitters (see `Client#open_request_stream`'s
    # `opening_mutex`) can release that lock once this command is
    # admitted to `@write_queue` in the correct position, instead of
    # holding it for the blocking wait too. `#send_headers` is the fused
    # submit+wait convenience most callers want.
    #
    # Takes its own defensive copy of `fields` (see `#submit_owned_headers`)
    # because encoding happens later, on the writer fiber — a caller that
    # mutated its own `Enumerable` after this method returns must not be
    # able to change what eventually gets encoded.
    #
    # :nodoc:
    def submit_headers(
      stream_id : UInt32,
      fields : Enumerable(HeaderField),
      *,
      end_stream : Bool = false,
    ) : WriteCommand
      submit_owned_headers(stream_id, fields.map { |field| field }, end_stream)
    end

    # HPACK-encodes one ordered field section on the writer fiber and sends
    # its complete HEADERS/CONTINUATION sequence atomically.
    def send_headers(
      stream_id : UInt32,
      fields : Enumerable(HeaderField),
      *,
      end_stream : Bool = false,
    ) : Nil
      submit_headers(stream_id, fields, end_stream: end_stream).wait
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
      # `materialized` is already a fresh, privately-owned array (built by
      # the `.map` above, not aliased to anything the caller can still
      # reach) -- goes straight to `#submit_owned_headers` instead of back
      # through `#submit_headers`, which would just copy it a second time.
      submit_owned_headers(stream_id, materialized, end_stream).wait
    end

    # Shared tail end of both `#submit_headers` overloads' paths: builds
    # and enqueues the `WriteCommand` for a field section the caller
    # already owns exclusively (no further copying needed here). Both
    # `#submit_headers` (which takes its own defensive copy first) and
    # `#send_headers`'s `Tuple(String, String)` overload (whose `.map`
    # already produced a fresh array) route through this one spot instead
    # of each doing their own admission bookkeeping.
    private def submit_owned_headers(
      stream_id : UInt32,
      fields : Array(HeaderField),
      end_stream : Bool,
    ) : WriteCommand
      ensure_registered_stream!(stream_id)
      command = WriteCommand.headers(stream_id, fields, end_stream)
      submit_nowait(command)
      command
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
      idle_closed = false
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
          idle_closed = true
          false
        else
          !current.state.closed?
        end
      end
      unless send_reset
        notify_pool_state if idle_closed
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

      replenished = @mutex.synchronize do
        next false if @state.closed?

        queue_connection_credit_unlocked(amount.to_i64)
        if stream = @streams[stream_id]?
          state = stream.state
          if state.open? || state.half_closed_local?
            @pending_stream_window_updates[stream_id] =
              (@pending_stream_window_updates[stream_id]? || 0_i64) + amount
          end
        end
        replenishment_due_unlocked?(stream_id)
      end
      wake_flow_control if replenished
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

    # Enqueues a command and waits up to `timeout` for it to complete,
    # then returns either way. Used only by #send_goaway from the reader
    # fiber: a bare #submit_nowait would race the GOAWAY against the
    # reader's own #terminate on a HEALTHY connection — #terminate closes
    # @write_queue and the transport without flushing, and
    # #stage_write_command completes-with-error once a terminal error is
    # set, so a nowait-then-terminate sequence can drop the GOAWAY even
    # when the peer was reading fine, trading RFC 9113 5.4.1's "send
    # GOAWAY before closing" on the common path for a rare-path
    # improvement. Racing #command.wait against a deadline keeps the
    # common (healthy) case exactly as reliable as the old unbounded
    # #submit — the writer flushes it and #wait's completion branch wins,
    # almost always well inside the deadline — while still bounding the
    # reader's worst case: if the transport is genuinely stalled, this
    # method returns once `timeout` elapses without the command having
    # completed. The GOAWAY stays queued (or in-flight, if the writer
    # already dequeued it and is blocked trying to send it); the caller
    # (#reader_loop's rescue) then calls #terminate, which force-closes
    # the transport and unblocks whichever of those two states the
    # command was in — completing it with the terminal error rather than
    # ever sending it. A peer that stalled its own reads forfeits the
    # courtesy frame instead of hanging the connection indefinitely.
    #
    # The same deadline covers all three steps: acquiring
    # `@submission_mutex`, admission onto `@write_queue`, and the flush
    # wait. Ordinary submitters deliberately keep the simple mutex hot
    # path. This rare reader-error path instead delegates mutex acquisition
    # and bounded admission to a helper fiber and races its result against
    # the deadline. If acquisition loses, cancellation makes the helper a
    # no-op once it eventually acquires the mutex; the caller returns and
    # terminates the connection, closing `@write_queue` and thereby waking
    # whichever ordinary submitter was holding the mutex on a full queue.
    private def submit_bounded(
      command : WriteCommand,
      timeout : Time::Span,
    ) : Nil
      deadline = Time.instant + timeout
      result = Channel(Bool | Exception).new(1)
      canceled = Atomic(Bool).new(false)
      ::spawn(name: "http2-bounded-submission") do
        begin
          admitted = @submission_mutex.synchronize do
            next false if canceled.get

            enqueue_bounded(command, deadline)
          end
          result.send(admitted)
        rescue error
          result.send(error)
        end
      end

      remaining = deadline - Time.instant
      if remaining <= Time::Span.zero
        canceled.set(true)
        return
      end

      outcome = select
      when completed = result.receive
        completed
      when timeout(remaining)
        canceled.set(true)
        return
      end
      raise outcome if outcome.is_a?(Exception)
      return unless outcome

      remaining = deadline - Time.instant
      return if remaining <= Time::Span.zero

      command.wait(remaining)
    end

    # Returns a slice `#send_data(Bytes)` can hand to `#submit_data`
    # without further copying, under the default single-threaded
    # runtime — a synchronous chunk transfer where `#stage_scheduled_data`
    # (see its comment) guarantees the transport has already copied the
    # bytes elsewhere before this method's caller can regain control.
    #
    # Under `-Dpreview_mt`, that guarantee doesn't hold: `#terminate` is
    # reachable from fibers `#spawn_transport_fiber` never pins to the
    # writer's thread (`#close`, and the drain-monitor, keepalive, and
    # settings-timer loops). `#terminate` terminates every stream while
    # holding `@mutex`, closing `stream.terminal_signal`; that can
    # unblock `WriteCommand#wait(stream)` — and so this slice's caller —
    # on a different OS thread while the writer thread is still inside
    # `frame.write` → `IO::Buffered#write`'s copy of this same slice.
    # A private copy here keeps that interleaving harmless, exactly as
    # the `.dup` this method replaces did before the slice became
    # caller-owned.
    private def owned_for_write(slice : Bytes) : Bytes
      {% if flag?(:preview_mt) %}
        slice.dup
      {% else %}
        slice
      {% end %}
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

    # Reader-fiber counterpart of #send_reset. Builds the identical
    # WriteCommand and enqueues it under the identical @submission_mutex —
    # the planning/state-transition work (see #prepare_outbound and the
    # plan_outbound_* family) always runs later on the writer fiber
    # regardless of which variant submitted the command, so nothing about
    # that path changes here. The only difference is #submit_nowait in
    # place of #submit: this returns as soon as the command is queued
    # instead of waiting for the writer to flush it, so the reader can never
    # block on transport flush while reacting to a stream violation. The
    # reader may still block briefly on @write_queue's bounded capacity
    # (drained by the writer, or by connection termination) — that is the
    # same accepted tradeoff #submit_nowait already carries for PING/SETTINGS
    # ACKs.
    #
    # Used only by reader-loop callers (stream-violation and rejected-promise
    # handling); user-triggered resets (cancel/close) keep #send_reset so the
    # caller still observes the outcome of its own request.
    private def send_reset_nowait(
      frame : Frame::ResetStream,
      error : Exception,
    ) : Nil
      submit_nowait(WriteCommand.reset(frame, error))
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

    private def check_enqueueable! : Nil
      current_state = state
      if current_state.new?
        raise InvalidStateError.new("connection has not been started")
      end
      raise_terminal_or_state! if current_state.closed?
    end

    private def enqueue(command : WriteCommand) : Nil
      check_enqueueable!

      @write_queue.send(command)
    rescue Channel::ClosedError
      raise_terminal_or_state!
    end

    # Bounded counterpart of #enqueue, used only by #submit_bounded: waits
    # up to `deadline` for `@write_queue` to accept the command instead of
    # blocking indefinitely. `@write_queue` has finite capacity
    # (`writer_queue_capacity`, default 32); against a stalled writer with
    # that many commands already queued ahead of this one, a plain
    # `@write_queue.send` (what #enqueue does, and what #submit_bounded
    # relied on before this method existed) can block indefinitely on its
    # own, before #submit_bounded's caller ever reaches the timeout-bounded
    # `command.wait` — silently defeating the bound #send_goaway exists to
    # provide. Returns `true` if the command was admitted, `false` if the
    # deadline elapsed first (nothing was enqueued; there is nothing for
    # the writer to complete later in this case, unlike a #command.wait
    # timeout).
    private def enqueue_bounded(
      command : WriteCommand,
      deadline : Time::Instant,
    ) : Bool
      check_enqueueable!

      remaining = deadline - Time.instant
      return false if remaining <= Time::Span.zero

      select
      when @write_queue.send(command)
        true
      when timeout(remaining)
        false
      end
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

    # Batches writer work instead of flushing after every command or every
    # scheduled DATA frame: each pass through the loop stages as much
    # immediately-available work as it can (up to `MAX_BATCH` commands,
    # plus whatever pending flow-control credit and scheduled DATA
    # `#no_immediate_work?` finds) into `@transport`'s buffer without
    # flushing or completing anything, then `#flush_batch` issues one
    # flush and completes every staged command together. This is also the
    # fix for the WINDOW_UPDATE starvation valve the review flagged: credit
    # (`#take_pending_window_updates`) and scheduled DATA are folded into
    # *every* batch, between control-command bursts, instead of only being
    # serviced when the command queue runs dry — a continuously-refilled
    # `@write_queue` can no longer defer outbound credit indefinitely.
    #
    # Command completion still only ever happens after the bytes reaching
    # it are actually flushed (batching moves completion later than the
    # old per-command flush, never earlier): `#stage_write_command`,
    # `#stage_frames`, and `#stage_scheduled_data` only write into the
    # transport's buffer and (for commands) append to `completions`;
    # `#flush_batch` is the only place completions are delivered. A
    # materialization failure still completes its command with the error
    # immediately, exactly as before — no bytes were staged for it, so
    # there is nothing to defer.
    #
    # A write or flush error is fatal to the whole batch, matching today's
    # per-command behavior: `#stage_write_command`, `#stage_frames`,
    # `#stage_scheduled_data`, and `#flush_batch` each complete every
    # command already staged in `completions` (plus their own command, if
    # any) with that error and call `#terminate`, rather than only failing
    # the one command that happened to trip the error. Once `terminal_error`
    # is set this way, `completions` is always left empty by whichever of
    # those four completed it — see `#no_immediate_work?` and the `ensure`
    # below, which additionally fails anything `completions` might still
    # hold (a `#terminate` triggered by another fiber mid-batch, e.g. the
    # reader on a protocol violation, is the only way that can happen) so
    # a batch in flight when the connection dies from the outside can never
    # strand a submitter in `WriteCommand#wait`.
    private def writer_loop : Nil
      completions = Array(WriteCommand).new(MAX_BATCH)
      capacity_changed = false
      loop do
        while completions.size < MAX_BATCH && (command = poll_write_command)
          capacity_changed |= stage_write_command(command, completions)
        end
        break if terminal_error && completions.empty?

        idle = stage_available_flow_control_and_data(completions)
        capacity_changed = flush_and_park_if_idle(completions, capacity_changed, idle)
      end
    ensure
      error = terminal_error || ClosedError.new("HTTP/2 writer stopped")
      # `completions` is typed nilable here only because Crystal's `ensure`
      # analysis can't prove its assignment above always runs before an
      # exception; it always has — `#stage_write_command`/`#stage_frames`/
      # `#stage_scheduled_data`/`#flush_batch` all handle their own write
      # and flush errors internally and never raise out of the loop body.
      # `#try` is defensive only.
      completions.try(&.each(&.complete(error)))
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

    # Stages the non-control-command work `#writer_loop` folds into every
    # batch — pending flow-control credit, one newly-arrived DATA command,
    # and one ready scheduled DATA frame — and reports whether any of the
    # three turned up anything (see `#no_immediate_work?`). Split out of
    # `#writer_loop` itself purely to keep that method's branching
    # shallow; the three steps below still run in the same order, once
    # per outer-loop iteration, that the fairness argument in
    # `#writer_loop`'s own comment depends on.
    private def stage_available_flow_control_and_data(
      completions : Array(WriteCommand),
    ) : Bool
      frames = take_pending_window_updates
      stage_frames(frames, completions) if frames

      data_command = poll_data_command
      enqueue_pending_data(data_command) if data_command

      scheduled = next_scheduled_data_frame
      if scheduled
        sched_command, frame = scheduled
        stage_scheduled_data(sched_command, frame, completions)
      end

      no_immediate_work?(frames, data_command, scheduled)
    end

    # Whether this iteration of `#writer_loop` turned up any immediately
    # available work: `frames`, `data_command`, and `scheduled` are exactly
    # the results this iteration already fetched from
    # `#take_pending_window_updates`, `#poll_data_command`, and
    # `#next_scheduled_data_frame` — this method takes them as parameters
    # instead of re-querying those sources itself because
    # `#next_scheduled_data_frame` is not a safe thing to call twice: on a
    # hit it reserves flow-control credit (`#plan_scheduled_data_frame`)
    # as a side effect, and on a miss (schedule non-empty but every
    # candidate blocked on flow control) calling it again immediately
    # would just busy-spin instead of parking in `#wait_for_writer_work`
    # until a `WINDOW_UPDATE` or new command actually arrives. Reusing this
    # iteration's results keeps the check free of side effects while still
    # being accurate.
    private def no_immediate_work?(
      frames : Array(Frames)?,
      data_command : WriteCommand?,
      scheduled : Tuple(WriteCommand, Frame::Data)?,
    ) : Bool
      frames.nil? && data_command.nil? && scheduled.nil?
    end

    # The batch-boundary decision `#writer_loop` makes every iteration:
    # flush what's staged once the batch is full or nothing more is
    # immediately available, then park for new work if the batch is now
    # empty and still nothing is available. Returns the `capacity_changed`
    # flag to carry into the next iteration (reset after a flush; folded
    # with whatever `#wait_for_writer_work` staged, if it staged a write
    # command while parked).
    private def flush_and_park_if_idle(
      completions : Array(WriteCommand),
      capacity_changed : Bool,
      idle : Bool,
    ) : Bool
      if completions.size >= MAX_BATCH || idle
        # Always call `#flush_batch` here, unconditionally — do NOT
        # gate this on `completions.empty?`/`capacity_changed` (a
        # tempting-looking "nothing happened" optimization this method
        # used to apply, and got wrong): `#stage_frames`
        # (WINDOW_UPDATE frames, which have no owning `WriteCommand`)
        # and a `#stage_scheduled_data` call that wrote a DATA chunk
        # without yet completing its block (`block.complete?` still
        # false) both write real bytes into `@transport`'s buffer
        # without adding anything to `completions` or changing pool
        # capacity. `#flush_batch` itself is the only thing that knows
        # whether those bytes exist, so it must always run at every
        # batch boundary — see its own comment.
        flush_batch(completions, capacity_changed)
        capacity_changed = false
      end

      if completions.empty? && idle
        capacity_changed |= wait_for_writer_work(completions)
      end

      capacity_changed
    end

    # Parks until new work arrives, staging (but not flushing) whichever
    # kind shows up so the next pass through `#writer_loop` folds it into
    # a batch like anything else. Returns whether pool capacity changed,
    # for the caller to fold into its running `capacity_changed` flag —
    # mirrors `#stage_write_command`'s contract, since a write command can
    # arrive on this path too.
    #
    # Data commands are admitted unconditionally: each sender fiber blocks
    # on its command, so parked commands are bounded by sending fibers,
    # not by writer_queue_capacity. A window-0 stream therefore cannot
    # starve streams that still have credit.
    private def wait_for_writer_work(completions : Array(WriteCommand)) : Bool
      select
      when command = @write_queue.receive?
        command ? stage_write_command(command, completions) : false
      when command = @data_queue.receive?
        enqueue_pending_data(command) if command
        false
      when @flow_control_wakeup.receive?
        false
      end
    end

    # Stages one control command's frames into `@transport`'s buffer
    # without flushing or completing it: on success the command is
    # appended to `completions` for `#flush_batch` to complete once the
    # batch's single flush succeeds. Returns whether this command changed
    # pool capacity (a stream closed), for the caller to OR into the
    # batch-wide flag `#flush_batch` uses to decide whether to call
    # `#notify_pool_state`.
    #
    # A materialization failure (bad state, encoder error) staged no
    # bytes, so that command completes immediately here, exactly as
    # before batching. A failure while writing already-materialized
    # frames into the transport buffer is different: other commands
    # already in `completions` this batch may already have bytes sitting
    # in the same (now possibly corrupted) buffer ahead of this one,
    # unflushed — so this command's write error fails the entire batch
    # (`completions.each(&.complete(error))`) and terminates the
    # connection, matching `#flush_batch`'s own error handling.
    private def stage_write_command(
      command : WriteCommand,
      completions : Array(WriteCommand),
    ) : Bool
      if command.data_block
        if error = terminal_error
          command.complete(error)
        else
          enqueue_pending_data(command)
        end
        return false
      end
      if error = terminal_error
        command.complete(error)
        return false
      end

      begin
        capacity_changed = prepare_outbound(command)
        if table_size = command.encoder_table_size
          @encoder.resize_table(table_size)
        end
        frames = materialize_frames(command)
      rescue error
        command.complete(error)
        return false
      end

      begin
        @transport.write(Preface) if command.preface?
        frames.each do |frame|
          frame.write(@transport)
          emit_frame(frame, Diagnostic::Direction::Outbound)
        end
        # Safe to mark the preface sent as soon as its bytes are queued
        # (not once they're actually flushed): `@transport`'s buffer
        # preserves write order, `#writer_loop` only ever considers
        # window-update/scheduled-DATA frames for the *same* batch after
        # this command has already been staged, and any later flush
        # failure fails this command (and the whole batch) via the
        # `rescue` below, exactly as it would have before batching.
        @mutex.synchronize { @preface_sent = true } if command.preface?
        completions << command
        capacity_changed
      rescue error
        completions.each(&.complete(error))
        completions.clear
        command.complete(error)
        terminate(error)
        false
      end
    end

    # Stages already-computed WINDOW_UPDATE frames into the transport
    # buffer. These have no owning `WriteCommand` (nothing waits on a
    # WINDOW_UPDATE), so a write error here has nothing of its own to
    # complete — it still fails every command already staged in
    # `completions` this batch and terminates, matching every other
    # writer error path.
    private def stage_frames(
      frames : Array(Frames),
      completions : Array(WriteCommand),
    ) : Nil
      frames.each do |frame|
        frame.write(@transport)
        emit_frame(frame, Diagnostic::Direction::Outbound)
      end
    rescue error
      completions.each(&.complete(error))
      completions.clear
      terminate(error)
    end

    # The only place a batch's staged bytes are flushed and its commands
    # completed — called unconditionally at every batch boundary
    # (`#flush_and_park_if_idle`), never gated on `completions`/
    # `capacity_changed`. Those two only track command-owned state
    # (completions to deliver, pool-capacity changes to notify); they
    # say nothing about whether *bytes* are sitting in `@transport`'s
    # buffer, because `#stage_frames` (WINDOW_UPDATE frames) and a
    # `#stage_scheduled_data` call mid-DATA-block both write real bytes
    # without touching either. A version of this method that
    # early-returned on `completions.empty? && !capacity_changed` (an
    # earlier draft of this method did exactly that) skipped the actual
    # `@transport.flush` call whenever a batch's only content was one of
    # those two — stranding already-written WINDOW_UPDATE or DATA-chunk
    # bytes in the transport's buffer indefinitely once the writer went
    # idle and parked, since nothing else would ever prompt a flush on
    # its own. Calling `@transport.flush` unconditionally costs nothing
    # extra in the common truly-idle case: `IO::Buffered#flush` only
    # calls `#unbuffered_write` when its internal buffer is non-empty,
    # and `Socket#unbuffered_flush` (the terminus for both the cleartext
    # transport and, transitively, `OpenSSL::SSL::Socket`'s) does
    # nothing — no syscall, just a few cheap empty method calls.
    #
    # On flush failure, every staged command completes with that error
    # instead of success — their bytes reached `@transport`'s buffer but
    # never the peer — and the connection terminates, identical to a
    # single-command flush failure before batching.
    private def flush_batch(
      completions : Array(WriteCommand),
      capacity_changed : Bool,
    ) : Nil
      begin
        @transport.flush
      rescue error
        completions.each(&.complete(error))
        completions.clear
        terminate(error)
        return
      end

      completions.each(&.complete)
      completions.clear
      notify_pool_state if capacity_changed
      wake_drain_monitor
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
    end

    private def next_scheduled_data_frame : Tuple(WriteCommand, Frame::Data)?
      candidates = @data_schedule.size
      candidates.times do
        stream_id = @data_schedule.shift
        queue = @pending_data[stream_id]
        command = queue.first

        begin
          frame = plan_scheduled_data_frame(command)
        rescue error
          queue.shift.complete(error)
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

    # Combines the eligibility checks the pre-batching scheduler split
    # across two separate `#data_command_error`/`#plan_scheduled_data_frame`
    # calls (and therefore two separate `@mutex.synchronize` round-trips)
    # into the single lock below. Two locks meant two chances for another
    # fiber (`#terminate`, `#handle_goaway`, ...) to close or reset this
    # stream in the gap between them — `#data_command_error` could see the
    # stream still open, release the lock, and only then have
    # `#plan_scheduled_data_frame` re-take it and find the stream gone.
    # One lock closes that window: every check below and the transition it
    # authorizes now happen atomically.
    #
    # A DATA frame also never opens or cascades onto a second stream (that
    # only happens for a HEADERS command's `outbound_stream_opening?`
    # branch in `#plan_outbound_stream_event_unlocked`, which a `SendData`/
    # `SendDataEndStream` event never satisfies), so — unlike
    # `#prepare_outbound`'s general command path — this method resolves and
    # applies the one stream's `OutboundTransition` directly instead of
    # allocating a one-entry `plans` Hash just to immediately iterate it.
    private def plan_scheduled_data_frame(
      command : WriteCommand,
    ) : Frame::Data?
      block = command.data_block
      unless block
        raise InvalidStateError.new("DATA command has no DATA block")
      end

      @mutex.synchronize do
        stream = resolve_scheduled_data_stream_unlocked(block)
        flow_size = scheduled_data_flow_size_unlocked(block, stream)
        next unless flow_size

        frame = block.build_frame(
          block.padded? ? block.frame.data.size : flow_size.to_i32
        )

        event = frame.end_stream? ? Stream::Event::SendDataEndStream : Stream::Event::SendData
        current_state = stream.state
        transition = Stream::StateMachine.transition(current_state, event)
        unless transition.action.allow?
          raise InvalidStateError.new(
            "cannot #{event.to_s.underscore} on stream #{block.stream_id} " \
            "in state #{current_state}"
          )
        end
        plan = build_outbound_transition(
          nil,
          stream,
          transition.next_state || current_state,
          event,
          nil,
          nil
        )

        @connection_send_window -= frame.payload.size.to_i64
        stream.adjust_send_window(-frame.payload.size.to_i64)
        apply_outbound_transition_unlocked(plan)
        frame
      end
    end

    # The stream-identity and terminal-state half of the eligibility check
    # `#plan_scheduled_data_frame` used to run as `#data_command_error`'s
    # own separate `@mutex.synchronize` — see that method's comment. Called
    # only from inside `#plan_scheduled_data_frame`'s lock.
    private def resolve_scheduled_data_stream_unlocked(
      block : WriteCommand::DataBlock,
    ) : Stream
      if error = @terminal_error
        raise error
      end
      if error = block.stream.terminal_error
        raise error
      end

      stream = @streams[block.stream_id]?
      unless stream && stream.same?(block.stream)
        raise ClosedError.new(
          "HTTP/2 stream #{block.stream_id} is closed"
        )
      end
      raise_terminal_or_state_unlocked! if @state.closed?
      stream
    end

    # How many bytes of `block` are eligible to go out right now: `nil`
    # means blocked on flow control (retry once credit arrives), not an
    # error. Called only from inside `#plan_scheduled_data_frame`'s lock.
    private def scheduled_data_flow_size_unlocked(
      block : WriteCommand::DataBlock,
      stream : Stream,
    ) : Int64?
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
                      available = {
                        remaining,
                        max_frame_size,
                        @connection_send_window,
                        stream.send_window,
                      }.min
                      return if available <= 0
                      available
                    end
                  end

      return if flow_size > 0 &&
                (@connection_send_window < flow_size ||
                stream.send_window < flow_size)

      flow_size
    end

    # The single-threaded zero-copy argument documented on `#send_data`
    # and `#owned_for_write` rests on three invariants that meet here:
    #   (a) `#spawn_transport_fiber` pins the reader, writer, and
    #       transport-closer fibers to one OS thread under
    #       `-Dpreview_mt` (irrelevant, but also harmless, when that
    #       flag is off, since there is only one thread regardless);
    #   (b) every staged byte is memcpy'd into `@transport`'s own
    #       buffer before the writer fiber can next park in
    #       `#wait_for_writer_work`: the memcpy happens right here, in
    #       this method's `frame.write(@transport)` call, and
    #       `#flush_batch` — the only place a batch's commands get
    #       completed — always flushes and completes this command
    #       strictly before that next park. Batching changed *when*
    #       the flush happens (once per batch instead of once per
    #       frame), not whether the memcpy precedes both the flush and
    #       the completion the caller's `WriteCommand#wait` is blocked
    #       on;
    #   (c) `@transport`'s `buffer_size` is sized (see `.connect` /
    #       `.start_tls`) to `>= outbound_data_chunk_size +
    #       FrameHeader::SIZE`, so `IO::Buffered#write` always takes
    #       its `slice.copy_to(...)` branch for a DATA payload — a
    #       synchronous memcpy into the IO's own buffer, never
    #       `unbuffered_write` directly on the caller's slice.
    # Changing any of (a)-(c) reopens the caller-buffer race
    # `#owned_for_write` exists to close under `-Dpreview_mt`, and
    # would make the same race live under the default single-threaded
    # runtime too.
    #
    # HEADERS/CONTINUATION frames (`#materialize_frames`, sized by the
    # peer's negotiated `SETTINGS_MAX_FRAME_SIZE`) can exceed
    # `buffer_size` and fall through to a direct `unbuffered_write` of
    # the slice being written — but that slice is this connection's
    # own HPACK encoder output, never a caller-owned buffer, so (c)'s
    # exemption there doesn't reopen the race for the DATA payloads
    # this method exists to protect.
    #
    # Derived from the pre-batching `#write_scheduled_data` and
    # `#finish_scheduled_data`, merged: the stream/window bookkeeping
    # `#finish_scheduled_data` used to do (advancing the block's offset,
    # shifting the per-stream queue, re-scheduling the stream) still
    # runs unconditionally, per frame, before this method returns —
    # only the user-visible `command.complete` moved, deferred to
    # `completions` for `#flush_batch` to deliver once the whole batch
    # flushes. That split matters: bookkeeping must stay synchronous
    # with the write (the next call to `#next_scheduled_data_frame`
    # needs `@pending_data`/`@data_schedule` already updated), while
    # completion must wait for the flush, like every other command.
    private def stage_scheduled_data(
      command : WriteCommand,
      frame : Frame::Data,
      completions : Array(WriteCommand),
    ) : Nil
      frame.write(@transport)
      emit_frame(frame, Diagnostic::Direction::Outbound)

      block = command.data_block
      return unless block

      block.advance(frame)
      stream_id = block.stream_id
      queue = @pending_data[stream_id]
      if block.complete?
        queue.shift
        completions << command
      end
      retain_data_stream(stream_id, queue)
    rescue error
      completions.each(&.complete(error))
      completions.clear
      command.complete(error)
      terminate(error)
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
        @reader_max_frame_size
      )
    rescue error : ProtocolError
      raise ProtocolError.new(
        "invalid server connection preface: #{error.message}",
        error.error_code
      )
    end

    private def read_frame : Frames?
      Frame.read(
        @transport,
        @reader_max_frame_size
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

      # RFC 7540 5.3.1 (a MUST; RFC 9113 drops the requirement along
      # with priority itself, but conformance suites such as h2spec
      # still test it): a stream cannot depend on itself. Deliberately
      # checked here, *after* `@decoder.decode_each` above has already
      # run — not in `Frame::Headers#validate!`, where it would reject
      # the frame before its field block is ever decoded. HEADERS
      # carries a header block fragment that the peer's encoder has
      # already committed to the shared HPACK dynamic table on send;
      # rejecting it pre-decode leaves that table entry (and every
      # index after it) permanently desynchronized between the two
      # ends, corrupting every later field block on every stream, not
      # just this one — even though the connection looks fine (this
      # stream alone gets RST). `Frame::Priority` carries no field block
      # and has none of this hazard, so its own check stays in
      # `validate!` unchanged; `Frame::PushPromise#validate!` already
      # avoids a stream-scoped error entirely for the same reason this
      # one is deliberately placed post-decode instead.
      if priority = block.priority
        if priority.stream_dependency == block.stream_id
          raise ProtocolError.new(
            "HEADERS frame priority must not set stream " \
            "#{block.stream_id} as its own dependency",
            ErrorCode::PROTOCOL_ERROR,
            ErrorScope::Stream,
            block.stream_id
          )
        end
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
        terminate(eof_termination_error(error)) unless closed?
      end
    end

    # A bare `IO::EOFError` says only "the socket closed," which is
    # actionless for streams still open at or below a peer GOAWAY's
    # last_stream_id (ones the peer promised to still finish). If the
    # peer told us why it was leaving before it actually left — a GOAWAY
    # carrying a non-NO_ERROR code — surface that diagnosis instead so
    # those streams fail with something a caller can branch on. A
    # NO_ERROR GOAWAY (or no GOAWAY at all) is an ordinary/graceful
    # disconnect, so the original EOF passes through unchanged.
    private def eof_termination_error(error : IO::EOFError) : Exception
      goaway = @mutex.synchronize { @last_goaway }
      if goaway && goaway.error_code != ErrorCode::NO_ERROR.to_u32
        GoAwayTerminationError.new(goaway)
      else
        error
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
        notify_pool_state
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
        return if closed.try(&.tolerates_late_frames?)

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

        # `@effective_local_settings_state` only reflects our own
        # ENABLE_PUSH=0 once the peer has acknowledged it (see
        # `acknowledge_local_settings`), so the check above alone leaves
        # an unbounded tolerance window immediately after `start`, before
        # that ACK arrives — every PUSH_PROMISE the peer sends in that
        # window is otherwise accepted (and immediately auto-cancelled,
        # see `reject_push_promise`) with no limit. Bound how many of
        # those this connection tolerates; past that, treat it as the
        # connection-level protocol violation it is (RFC 9113 places no
        # duty on us to keep entertaining a peer that keeps pushing well
        # past a reasonable grace period).
        @pre_ack_push_promise_count += 1
        if @pre_ack_push_promise_count > @configuration.max_pre_ack_push_promises
          raise ProtocolError.new(
            "PUSH_PROMISE count exceeded the pre-acknowledgement " \
            "tolerance of #{@configuration.max_pre_ack_push_promises}"
          )
        end

        parent_state = stream_state_unlocked(frame.stream_id)
        closed = @closed_streams[frame.stream_id]?
        unless closed.try(&.tolerates_late_frames?)
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
      send_reset_nowait(
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
      send_reset_nowait(
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

        # The overflow check runs for every state the transition above
        # already allowed (including half-closed(local) and
        # reserved(local), where we will never send another DATA frame on
        # this stream) — RFC 9113 6.9.1's "MUST NOT allow a flow-control
        # window to exceed 2^31-1" is a validity rule on the WINDOW_UPDATE
        # itself, not conditioned on whether we still have anything left
        # to send. Only the actual bookkeeping mutation below
        # (`adjust_send_window`, which only matters for a stream that can
        # still send) is skipped for the states this doesn't apply to.
        #
        # That skip narrows what this catches for exactly those excluded
        # states: since `stream.send_window` is never updated while
        # excluded, `updated` below is always this frozen baseline plus
        # only the *current* increment, not a running cumulative total —
        # a single increment large enough to overflow on its own is
        # still caught, but a series of smaller increments that would
        # only overflow once summed is not. For open/half-closed(remote)
        # streams, where the mutation always runs, the check is
        # genuinely cumulative.
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
        next false unless state.open? || state.half_closed_remote?

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

        # Unpadded DATA (the overwhelmingly common case): frame.data IS the whole
        # freshly-allocated payload from Frame.read and has no other owner — hand
        # it to the body without copying. Padded frames are duped so the buffer
        # doesn't pin the padding bytes.
        data = frame.padded? ? frame.data.dup : frame.data
        unless stream.deliver_data(data)
          # This frame's own flow-controlled bytes were charged against
          # the connection window in `accept_inbound_data` above but never
          # made it into the body buffer — release that credit regardless
          # of which branch below is taken next. Any bytes from *earlier*
          # frames still sitting in the body buffer (never consumed by the
          # application) are a separate pool, released later by whichever
          # of `fail_overflowed_stream`'s two branches actually tears the
          # stream down (`Stream#terminate` -> `StreamBody#terminate`), not
          # here — see that method's own accounting.
          release_discarded_connection_credit(flow_size)
          return if stream.body.closed? || stream.terminal_error

          fail_overflowed_stream(
            stream,
            "stream #{stream.id} body reached its configured byte limit"
          )
          return
        end

        overhead = frame.payload.size - data.size
        release_receive_credit(stream.id, overhead) if overhead > 0
        if frame.end_stream?
          stream.finish_body
          # END_STREAM: the peer will send no more DATA on this stream, so
          # this stream's own reads can never accumulate further credit to
          # cross `replenishment_due_unlocked?`'s watermark on their own.
          # Wake the writer now instead: `take_pending_window_updates`
          # flushes whatever CONNECTION-scope credit is pending (and any
          # OTHER stream's, if that one is still `open?`/
          # `half_closed_local?`), rather than leaving it stranded behind
          # a watermark this stream can no longer help cross. This
          # stream's OWN pending stream-scope credit, if it had any, is
          # silently dropped here instead — by this point `stream.state`
          # is `half_closed_remote?` or `closed?`, and
          # `take_pending_window_updates` only ever sends stream-scope
          # credit for `open?`/`half_closed_local?` streams — which is
          # fine: a stream that will never receive more DATA has no
          # future use for a WINDOW_UPDATE of its own anyway.
          wake_flow_control
        end
        if stream.closed?
          notify_pool_state
          wake_drain_monitor
        end
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

    # Unlike `#release_receive_credit`, this wakes the writer
    # UNCONDITIONALLY (no `replenishment_due_unlocked?` watermark check).
    # That eagerness is intentional, not an oversight: discarded credit
    # comes from a stream that just reset, terminated, or otherwise
    # stopped receiving DATA, so there may be no future read left to
    # accumulate further credit and eventually cross the watermark on its
    # own — waiting for one would mean never flushing at all. Specs
    # depend on this: e.g. "retains a reset-tolerant closed stream past
    # the count limit for late DATA" and "tolerates DATA that arrives
    # after a peer RST_STREAM" both assert a prompt WINDOW_UPDATE after
    # a single late frame's worth of discarded credit (4 bytes) — far
    # below the half-window watermark a gated wake would require.
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
        fail_overflowed_stream(
          stream,
          "stream #{stream.id} event queue reached its configured limit"
        )
        return
      end
      if section = event.as?(FieldSection)
        if section.end_stream?
          stream.finish_body
          # END_STREAM (here, on a HEADERS/trailer field section rather
          # than DATA) — see the matching comment in `handle_inbound_data`
          # for the full reasoning, including why this wake flushes only
          # CONNECTION-scope (and other-stream) credit: by this point
          # `stream.state` is `half_closed_remote?`/`closed?`, so
          # `take_pending_window_updates` silently drops rather than
          # sends this stream's own pending stream-scope credit, if it
          # had any — harmless, since this stream will never receive
          # more DATA to need a WINDOW_UPDATE for anyway.
          wake_flow_control
        end
      end
      if stream.closed?
        notify_pool_state
        wake_drain_monitor
      end
    end

    # A single stream's bounded inbound queue filling up — either the
    # metadata event queue (`Stream#deliver`, headers/trailers/PRIORITY)
    # or the DATA body-byte queue (`Stream#deliver_data`, gated by
    # `max_buffered_body_bytes`) — used to raise a connection-fatal
    # `QueueFullError` at each call site — one slow reader took every
    # other stream down with it. Treat it like any other stream-scoped
    # protocol violation instead: RST just this stream with
    # ENHANCE_YOUR_CALM and let the rest of the connection carry on.
    # Reusing `handle_stream_violation` gets the standard fire-and-forget
    # RST (`send_reset_nowait`, safe to call from the reader fiber),
    # eventual stream removal, and LocalReset retention (so a frame for
    # this stream already in flight from the peer is absorbed rather than
    # treated as a fresh violation) for free — the same path every other
    # stream-scoped error already takes. `message` is caller-supplied so
    # the two queues keep their own distinct, descriptive wording.
    private def fail_overflowed_stream(
      stream : Stream,
      message : String,
    ) : Nil
      if stream.terminal_error
        # `Stream#deliver` returns `false` for two different reasons:
        # the queue is genuinely full (what this method exists to
        # handle), or the stream was already terminated for an unrelated
        # reason by the time delivery was attempted (e.g. a concurrent
        # `Stream#cancel`). That termination already recorded its own,
        # correct error — this delivery attempt simply arrived too late
        # to matter. Do nothing rather than mislabel it as a queue
        # overflow: `Stream#terminate` is idempotent, so a second RST
        # here would at best be redundant and at worst overwrite a
        # correct diagnosis with an incorrect one on the wire (even
        # though the stream's own `terminal_error` stays correct
        # locally, since `terminate` never overwrites once set).
        return
      end

      error = ProtocolError.new(
        message,
        ErrorCode::ENHANCE_YOUR_CALM,
        ErrorScope::Stream,
        stream.id
      )
      if @mutex.synchronize { @streams[stream.id]?.try(&.same?(stream)) }
        handle_stream_violation(error)
        return
      end

      # The very transition that produced the undelivered event already
      # closed and removed this stream (e.g. trailers ending an
      # already-half-closed(local) stream) before delivery was even
      # attempted, a few lines up in `transition_and_deliver`. Nothing is
      # owed to the peer — RFC 9113 has nothing left to RST, both sides
      # already agreed the stream is done — but a caller parked in
      # `Stream#receive` waiting for the event that just failed to
      # deliver must not be stranded forever: terminate the stream
      # directly instead of relying on `handle_stream_violation`, which
      # would (correctly) no-op for a stream it can no longer find.
      #
      # Unlike the branch above, nothing gets written to the transport
      # here (no RST is sent), so `flush_batch`'s own post-flush
      # `wake_drain_monitor` call never fires for this
      # closure — wake it explicitly so a graceful drain waiting on
      # exactly this stream (if it happened to be the last active one)
      # notices promptly instead of idling until the next unrelated
      # flush or the drain deadline.
      emit_error(error, stream.id)
      @mutex.synchronize { terminate_stream_unlocked(stream, error) }
      notify_pool_state
      wake_drain_monitor
    end

    private def resolve_inbound_transition_unlocked(
      stream_id : UInt32,
      event : Stream::Event,
    ) : Tuple(Stream::State, Stream::StateMachine::Transition)?
      state = stream_state_unlocked(stream_id)
      closed = @closed_streams[stream_id]?
      return if closed.try(&.tolerates_late_frames?)

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
      # `release_discarded_connection_credit` already wakes the writer
      # itself whenever it actually queues credit (`discarded > 0`), so
      # the second, unconditional `wake_flow_control` this line used to
      # have was a no-op in that case. It is NOT a no-op when `discarded`
      # is 0 — `Stream#terminate` returns 0 whenever the body is already
      # finished or has nothing buffered, the common case for a reset
      # that lands before or between DATA frames — but the residual
      # effect of dropping it there is only a deferral, not a loss: any
      # OTHER stream's already-pending sub-watermark credit this reset
      # would have opportunistically nudged early still flushes once its
      # own half-window watermark is crossed, or at the next writer wake
      # for any other reason.
      release_discarded_connection_credit(discarded.to_i64)
      notify_pool_state
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
      notify_pool_state if previous.max_concurrent_streams !=
                             updated.max_concurrent_streams

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

    # Reachable only via `#dispatch`'s `Frame::Settings#ack?` branch, which
    # `#process_inbound_frame` calls, which only `#reader_loop` calls — and
    # `#reader_loop` runs solely as the body of the single reader fiber
    # `#start` spawns once via `#spawn_transport_fiber("http2-reader")`
    # (guarded by `@state.new?`/`@reader_started`, so `start` — and this
    # spawn — cannot run twice). That fiber is pinned to one OS thread under
    # `-Dpreview_mt` (see `#spawn_transport_fiber`'s comment) and is the only
    # caller of this method, so the plain-ivar write to
    # `@reader_max_frame_size` below is safe without `@mutex`: nothing but
    # this same fiber ever writes or reads it (`#read_frame`/
    # `#read_server_preface`, also reader-fiber-only).
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
      @reader_max_frame_size = updated.max_frame_size

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
      notify_pool_state
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
      send_reset_nowait(
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
        {stream_state_unlocked(id), closed.try(&.tolerates_late_frames?) || false}
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

    # Sends the reader's reactive GOAWAY (a protocol violation just raised
    # `error` out of #reader_loop). Deliberately NOT a plain #submit (would
    # block the reader indefinitely against a stalled peer — the deadlock
    # #submit_nowait already avoids for PING/SETTINGS ACKs and
    # #send_reset_nowait avoids for RST_STREAM) and deliberately NOT a bare
    # #submit_nowait either (see #submit_bounded's comment for why that
    # would race the GOAWAY against #terminate and could drop it even on a
    # healthy connection). #submit_bounded is the deadline-bounded middle
    # ground: wait for the flush, but not forever.
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
      frame = Frame::GoAway.new(last_stream_id, error.error_code)
      command = WriteCommand.new([frame] of Frames)
      # Either outcome (flushed within the deadline, `true`; deadline
      # elapsed first, `false`) falls through to a normal return here —
      # #reader_loop's caller proceeds straight to #terminate next either
      # way, which is what actually reclaims a timed-out send (see
      # #submit_bounded).
      submit_bounded(command, @configuration.goaway_flush_timeout)
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
          @request_reservations.clear
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

      notify_pool_state
      emit_error(error)
      @write_queue.close
      @data_queue.close
      @transport_close_signal.close
      @settings_timer_wakeup.close
      @flow_control_wakeup.close
      @drain_wakeup.close
      @keepalive_wakeup.close
      @stream_slot_wakeup.close
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
            @keepalive_started.get,
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

    # Force-closes the transport promptly, without flushing whatever the
    # write buffer still holds. Plain `IO::Buffered#close` flushes first,
    # which can deadlock against a stalled peer once write buffering is
    # enabled — see `close_discarding_buffer`
    # (src/connection/buffered_close.cr) for the h2c trace. `@transport` is
    # typed as the untyped `IO`, so `#close_io_discarding_buffer` narrows
    # via `#as?(IO::Buffered)` (a plain `responds_to?` guard does not
    # narrow an ivar typed as the fully open `IO` hierarchy the way it does
    # a closed union — `crystal build` rejects it).
    #
    # **TLS is not covered by the h2c mechanism above.** For a TLS
    # connection, `@transport` is an `OpenSSL::SSL::Socket`, and its own
    # `#unbuffered_close` unconditionally calls `SSL_shutdown` — which
    # WRITES a close_notify alert through the underlying socket regardless
    # of `close_discarding_buffer`'s `@out_count` zeroing (that only
    # short-circuits the TLS *wrapper's own* buffered-frame flush; it has
    # no effect on `SSL_shutdown`'s independent write). Against a stalled
    # peer with no `write_timeout` — the documented default — that write
    # can block indefinitely, with nothing else in the process positioned
    # to force it to return (unlike the h2c case, there is no second fiber
    # contending for a lock here to reason about — see the P1.8 task
    # report's review-round-2 fix section for the full trace and the
    # reentrant-`SSL_shutdown` case this does NOT cover). So for TLS this
    # method instead closes `@tls_raw_transport` (the raw socket
    # `.start_tls` dialed, before TLS wrapping) directly, forcing the
    # underlying `send(2)`/`close(2)` to unwind promptly, and deliberately
    # does **not** additionally invoke anything on the TLS wrapper
    # (`@transport`) itself — not because doing so would be unsafe (it
    # isn't: measured directly, calling `#close` on the wrapper after the
    # raw socket is already closed underneath it returns normally in
    # well under a millisecond. `openssl/bio.cr`'s `write_ex`/`write`
    # call `bio.io.write` with no rescue of their own, so an `IO::Error`
    # from the now-closed raw IO unwinds straight out through the
    # libssl/libcrypto C frames that invoked that callback — ordinary
    # Crystal exception propagation works through a callback frame
    # regardless of who called it — and lands in
    # `OpenSSL::SSL::Socket#unbuffered_close`'s own `rescue IO::Error`,
    # exactly the way `IO::TimeoutError` already unwinds out of
    # `SSL_connect`'s BIO *read* callback for
    # `spec/connection_tls_spec.cr`'s own `handshake_read_timeout` spec)
    # — but because it would accomplish nothing: `unbuffered_close`
    # never calls `LibSSL.ssl_free` — that
    # only happens in `OpenSSL::SSL::Socket#finalize` and the two
    # handshake-failure `rescue` blocks in `openssl/ssl/socket.cr`, none
    # of which this call would reach. The wrapper's `@ssl` handle is
    # freed identically either way, once this `Connection` is garbage-
    # collected, whether or not `@transport`'s own `#close` ever runs.
    # All invoking it here would do is attempt one more close_notify
    # write and an fd-close against a raw socket that is already gone —
    # reaching no one, freeing nothing. (This applies equally whether
    # `close_transport` was reached via `#close` or via a completed or
    # timed-out `#graceful_close` — both funnel through `#terminate`
    # here, so there is no forceful-vs-graceful distinction left to draw
    # at this point.)
    private def close_transport : Nil
      if raw = @tls_raw_transport
        close_io_discarding_buffer(raw)
      else
        close_io_discarding_buffer(@transport)
      end
    rescue
      # The connection's stored terminal error remains authoritative.
    end

    private def close_io_discarding_buffer(io : IO) : Nil
      if buffered = io.as?(IO::Buffered)
        buffered.close_discarding_buffer
      else
        io.close
      end
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
              remaining_since_last_activity(DrainQuietPeriod),
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

    # Wakes the drain monitor (if running) and, unconditionally, any
    # caller parked in `#wait_for_stream_slot`. Called from every
    # successful writer flush (not only when a stream closes — the drain
    # monitor needs to recheck after ANY frame in case that write was
    # what closed one), so a `#wait_for_stream_slot` waiter retries at
    # most once per flush, bounded by write activity on the connection,
    # never a busy spin; a spurious wake (nothing actually freed a slot)
    # just costs the waiter one extra, cheap retry.
    private def wake_drain_monitor : Nil
      wake_stream_slot_waiters

      return unless @drain_started

      select
      when @drain_wakeup.send(nil)
      else
      end
    rescue Channel::ClosedError
      # Connection shutdown already woke the monitor.
    end

    private def wake_stream_slot_waiters : Nil
      select
      when @stream_slot_wakeup.send(nil)
      else
      end
    rescue Channel::ClosedError
      # Connection shutdown already woke any waiters.
    end

    private def start_keepalive : Nil
      interval = @configuration.keepalive_interval
      return unless interval

      start = @mutex.synchronize do
        if @state.closed? || @keepalive_started.get
          false
        else
          @keepalive_started.set(true)
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
            remaining_since_last_activity(interval),
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

    # Returns the time remaining until `window` has elapsed since the last
    # inbound frame (`@last_inbound_activity_ns`), possibly negative if it
    # has already elapsed. This is a periodic poll from the drain monitor
    # and keepalive loops, not the per-frame write path, so an ordinary
    # `Time.monotonic` read here costs nothing that matters -- unlike
    # `observe_inbound_frame`'s `.set`, which runs on every inbound frame
    # and stays lock-free.
    private def remaining_since_last_activity(window : Time::Span) : Time::Span
      now_ns = Time.monotonic.total_nanoseconds.to_i64
      Time::Span.new(
        nanoseconds: @last_inbound_activity_ns.get + window.total_nanoseconds.to_i64 - now_ns
      )
    end

    private def observe_inbound_frame(
      frame : Frames,
      *,
      rate_limit : Bool = true,
    ) : Nil
      @last_inbound_activity_ns.set(Time.monotonic.total_nanoseconds.to_i64)
      notify_keepalive_activity if @keepalive_started.get
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
      return unless @diagnostics_enabled.get

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
      return unless @diagnostics_enabled.get

      select
      when @diagnostics.send(diagnostic)
      else
        @dropped_diagnostic_count.add(1)
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

    # `plans` starts `nil` and stays that way for the common commands that
    # never touch a stream at all (PING, SETTINGS, GOAWAY, an ack) — see
    # `#planned_stream_state` and the `plans ||= {} of ...` in
    # `#plan_outbound_stream_event_unlocked`/`#plan_skipped_local_streams_unlocked`,
    # the only two places that ever write into it. Every helper below
    # threads it through as part of its return value (the same pattern
    # already used for `highest_local_id`) instead of taking a
    # pre-allocated `Hash` — so a HEADERS command (which always opens or
    # continues at least one stream) still ends up allocating exactly the
    # Hash it needs, while PING/SETTINGS-ack/GOAWAY-only commands allocate
    # nothing.
    private def prepare_outbound(command : WriteCommand) : Bool
      @mutex.synchronize do
        raise_terminal_or_state_unlocked! if @state.closed?

        plans = nil
        next_highest_local_id = @highest_local_opened_stream_id
        previous_state = @state

        if header_block = command.header_block
          next_highest_local_id, plans = plan_outbound_header_block_unlocked(
            plans,
            header_block,
            next_highest_local_id
          )
          planned_goaway = @last_sent_goaway
        else
          planned_goaway, plans = plan_outbound_frames_unlocked(
            command,
            plans,
            next_highest_local_id
          )
        end

        @highest_local_opened_stream_id = next_highest_local_id
        if plans
          plans.each_value do |plan|
            apply_outbound_transition_unlocked(plan)
          end
        end
        apply_outbound_goaway_unlocked(planned_goaway)

        previous_state != @state ||
          (plans.try do |existing_plans|
            existing_plans.any? { |id, plan| id.odd? && plan.state.closed? }
          end || false)
      end
    end

    private def plan_outbound_header_block_unlocked(
      plans : Hash(UInt32, OutboundTransition)?,
      header_block : WriteCommand::HeaderBlock,
      highest_local_id : UInt32,
    ) : Tuple(UInt32, Hash(UInt32, OutboundTransition)?)
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
      plans : Hash(UInt32, OutboundTransition)?,
      highest_local_id : UInt32,
    ) : Tuple(Frame::GoAway?, Hash(UInt32, OutboundTransition)?)
      planned_goaway = @last_sent_goaway
      command.frames.each do |frame|
        case frame
        when Frame::GoAway
          validate_outbound_goaway_unlocked(frame, planned_goaway)
          planned_goaway = frame
        when Frame::Data
          plans = plan_outbound_data_unlocked(plans, frame, highest_local_id)
        when Frame::ResetStream
          _, plans = plan_outbound_stream_event_unlocked(
            plans,
            frame.stream_id,
            Stream::Event::SendReset,
            highest_local_id,
            @state.draining?,
            reset_code: frame.error_code,
            close_error: command.stream_closure_error
          )
        when Frame::Priority
          _, plans = plan_outbound_stream_event_unlocked(
            plans,
            frame.stream_id,
            Stream::Event::SendPriority,
            highest_local_id,
            @state.draining?
          )
        when Frame::WindowUpdate
          plans = plan_outbound_window_update_unlocked(
            plans,
            frame,
            highest_local_id
          )
        else
          # Connection frames and unknown extensions do not alter streams.
        end
      end
      {planned_goaway, plans}
    end

    private def plan_outbound_data_unlocked(
      plans : Hash(UInt32, OutboundTransition)?,
      frame : Frame::Data,
      highest_local_id : UInt32,
    ) : Hash(UInt32, OutboundTransition)?
      event = if frame.end_stream?
                Stream::Event::SendDataEndStream
              else
                Stream::Event::SendData
              end
      _, plans = plan_outbound_stream_event_unlocked(
        plans,
        frame.stream_id,
        event,
        highest_local_id,
        @state.draining?
      )
      plans
    end

    private def plan_outbound_window_update_unlocked(
      plans : Hash(UInt32, OutboundTransition)?,
      frame : Frame::WindowUpdate,
      highest_local_id : UInt32,
    ) : Hash(UInt32, OutboundTransition)?
      return plans if frame.stream_id.zero?

      _, plans = plan_outbound_stream_event_unlocked(
        plans,
        frame.stream_id,
        Stream::Event::SendWindowUpdate,
        highest_local_id,
        @state.draining?
      )
      plans
    end

    # Reads `plans[stream_id]?`'s planned-but-not-yet-applied state for
    # `stream_id`, falling back to the stream's own current state — reads
    # through a `nil` `plans` exactly like an empty Hash would (`nil` just
    # means "nothing planned yet").
    private def planned_stream_state(
      plans : Hash(UInt32, OutboundTransition)?,
      stream_id : UInt32,
      stream : Stream,
    ) : Stream::State
      plans.try { |existing_plans| existing_plans[stream_id]? }.try(&.state) || stream.state
    end

    private def plan_outbound_stream_event_unlocked(
      plans : Hash(UInt32, OutboundTransition)?,
      stream_id : UInt32,
      event : Stream::Event,
      highest_local_id : UInt32,
      draining : Bool,
      *,
      reset_code : UInt32? = nil,
      close_error : Exception? = nil,
    ) : Tuple(UInt32, Hash(UInt32, OutboundTransition)?)
      stream = @streams[stream_id]?
      unless stream
        return {highest_local_id, plans} if event.send_priority?

        raise InvalidStateError.new(
          "stream #{stream_id} is not active on this connection"
        )
      end

      current_state = planned_stream_state(plans, stream_id, stream)
      if outbound_stream_opening?(current_state, event)
        highest_local_id, plans = plan_local_stream_open_unlocked(
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
      plans ||= {} of UInt32 => OutboundTransition
      plans[stream_id] = build_outbound_transition(
        plans[stream_id]?,
        stream,
        next_state,
        event,
        reset_code,
        close_error
      )
      {highest_local_id, plans}
    end

    private def outbound_stream_opening?(
      state : Stream::State,
      event : Stream::Event,
    ) : Bool
      state.idle? &&
        (event.send_headers? || event.send_headers_end_stream?)
    end

    private def plan_local_stream_open_unlocked(
      plans : Hash(UInt32, OutboundTransition)?,
      stream_id : UInt32,
      highest_local_id : UInt32,
      draining : Bool,
    ) : Tuple(UInt32, Hash(UInt32, OutboundTransition)?)
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
      plans = plan_skipped_local_streams_unlocked(plans, stream_id)
      {stream_id, plans}
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
      plans : Hash(UInt32, OutboundTransition)?,
    ) : Nil
      limit = @peer_settings_state.max_concurrent_streams
      return unless limit

      active = @streams.count do |id, stream|
        state = planned_stream_state(plans, id, stream)
        id.odd? && state.active?
      end
      if active.to_u64 >= limit.to_u64
        raise ConcurrentStreamLimitError.new(limit)
      end
    end

    private def plan_skipped_local_streams_unlocked(
      plans : Hash(UInt32, OutboundTransition)?,
      opening_stream_id : UInt32,
    ) : Hash(UInt32, OutboundTransition)?
      @streams.each do |id, stream|
        next unless id.odd? && id < opening_stream_id

        state = planned_stream_state(plans, id, stream)
        next unless state.idle?

        (plans ||= {} of UInt32 => OutboundTransition)[id] = OutboundTransition.new(
          stream,
          Stream::State::Closed,
          ClosedStream::Reason::Skipped,
          ClosedError.new(
            "stream #{id} was skipped by stream #{opening_stream_id}"
          )
        )
      end
      plans
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

    # Evicts from the FIFO head once retained metadata exceeds
    # `max_retained_closed_streams`, but a reset-tolerant entry (see
    # `ClosedStream#tolerates_late_frames?`) younger than
    # `closed_stream_retention` is protected: churn from ordinary stream
    # completions must not evict the bookkeeping a still-in-flight late
    # frame (from a canceled or peer-reset stream) needs to be absorbed
    # instead of escalating to a connection error. A protected entry stops
    # eviction entirely for this call — since eviction only ever inspects
    # the FIFO head, a protected head leaves everything behind it in place
    # too, so the order can sit above the soft limit for a while. That
    # overage is intentional, not a leak: it is bounded by `hard_cap`, a
    # flat memory backstop that evicts the oldest entry regardless of
    # reason or age once retained metadata would otherwise grow past it.
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

      hard_cap = limit * 4
      while @closed_stream_order.size > limit
        candidate_id = @closed_stream_order.first?
        break unless candidate_id

        entry = @closed_streams[candidate_id]?
        unless entry
          @closed_stream_order.shift
          next
        end

        protected_entry =
          entry.tolerates_late_frames? &&
            entry.retained_at.elapsed < @configuration.closed_stream_retention
        break if protected_entry && @closed_stream_order.size <= hard_cap

        @closed_stream_order.shift
        @closed_streams.delete(candidate_id)
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

    private def request_capacity_unlocked : RequestCapacity
      active_client_streams = 0
      idle_client_streams = 0
      @streams.each do |id, stream|
        next unless id.odd?

        state = stream.state
        if state.active?
          active_client_streams += 1
        elsif state.idle?
          idle_client_streams += 1
        end
      end

      RequestCapacity.new(
        @state,
        @streams.size,
        active_client_streams,
        idle_client_streams,
        @request_reservations.size,
        @peer_settings_state.max_concurrent_streams,
        @stream_ids.exhausted?
      )
    end

    private def request_slot_available_unlocked? : Bool
      return false unless @state.active?

      capacity = request_capacity_unlocked
      local_committed = capacity.registered_streams.to_i64 +
                        capacity.reservations.to_i64
      return false if local_committed >=
                        @configuration.max_open_streams.to_i64
      if limit = capacity.peer_limit
        return false if capacity.peer_committed >= limit.to_i64
      end

      @stream_ids.remaining > capacity.reservations.to_u64
    end

    private def validate_request_slot_materialization_unlocked! : Nil
      if @state.closed?
        raise_terminal_or_state_unlocked!
      end
      if @state.draining?
        raise DrainingError.new(
          "new streams cannot be opened on a draining connection"
        )
      end
      unless @state.active?
        raise InvalidStateError.new(
          "request streams require an active connection"
        )
      end

      capacity = request_capacity_unlocked
      local_committed = capacity.registered_streams.to_i64 +
                        capacity.reservations.to_i64
      if local_committed > @configuration.max_open_streams.to_i64
        raise OpenStreamLimitError.new(@configuration.max_open_streams)
      end
      if limit = capacity.peer_limit
        if capacity.peer_committed > limit.to_i64
          raise ConcurrentStreamLimitError.new(limit)
        end
      end
      if @stream_ids.remaining < capacity.reservations.to_u64
        raise StreamIDExhaustedError.new(
          "HTTP/2 client stream IDs are exhausted"
        )
      end
    end

    private def allocate_client_stream_unlocked : Stream
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
      stream
    end

    private def notify_pool_state : Nil
      callbacks = @pool_state_subscription_mutex.synchronize do
        @pool_state_subscriptions.values
      end
      callbacks.each do |callback|
        begin
          callback.call
        rescue
          # Pool notifications are best-effort control-plane signals.
        end
      end
    end

    private def raise_terminal_or_state_unlocked! : NoReturn
      if error = @terminal_error
        raise error
      end

      raise InvalidStateError.new("connection is not active")
    end
  end
end
