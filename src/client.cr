require "uri"
require "set"
require "./cancellation"
require "./connection"
require "./http_semantics"
require "./request"
require "./response"
require "./client/pool_configuration"
require "./client/pool_state"
require "./client/pool_entry"

module HTTP2
  # A reusable, origin-bound HTTP/2 client.
  class Client
    class ClosedError < HTTPError
    end

    # No pooled connection could admit another request, and the pool could
    # neither grow nor wait any longer under its configured policy.
    class PoolSaturatedError < HTTPError
      getter max_connections : Int32?

      def initialize(
        @max_connections : Int32?,
        message : String = "HTTP/2 connection pool is saturated",
      )
        super(message)
      end
    end

    # Opt-in policy for replaying only requests that the peer proves were not
    # processed through GOAWAY or RST_STREAM(REFUSED_STREAM).
    enum ReplayPolicy
      Never
      Idempotent
      AnyRequest

      def allows?(method : String) : Bool
        return false if never?
        return true if any_request?

        method.in?("GET", "HEAD", "PUT", "DELETE", "OPTIONS", "TRACE")
      end
    end

    # Per-operation deadlines. Nil disables the corresponding timeout.
    #
    # `connect` covers DNS and TCP dialing, `read` covers the TLS and
    # HTTP/2 handshakes (for `https` origins, the TLS handshake itself;
    # then, for both schemes, the wait for the peer's SETTINGS after
    # dialing) and each response-header wait, `write` covers transport
    # writes, and `idle` covers a blocked response-body read or trailer
    # wait. There is no persistent socket-level read timeout, so a
    # quiet-but-healthy connection (an idle pooled connection, a
    # long-lived SSE or long-poll stream) is never killed merely for
    # going quiet between waits. Liveness on an established connection is
    # keepalive's job instead: `connection_configuration`'s
    # `keepalive_interval`/`keepalive_timeout` (30 seconds / 10 seconds by
    # default for `HTTP2::Client`) periodically PINGs the peer and fails
    # the connection if it stops answering; supply a configuration with
    # `keepalive_interval: nil` to disable it.
    #
    # `idle` also bounds a `Response` that the caller abandons — never
    # reads, never closes — but ONLY while its body is actually pinning
    # connection-window credit (unread buffered bytes sitting in it).
    # Each time `idle` elapses with unread buffered data present and no
    # bytes consumed since the previous check, the response's stream is
    # canceled: flow-control credit for that buffered data is returned,
    # RST_STREAM is sent, and the body is left with a terminal error, so
    # a later read raises that specific error (e.g. `RequestTimeoutError`
    # here). A caller's own `Response#close` also makes a later read
    # raise rather than return a silent EOF, but with a generic
    # `IO::Error` ("Closed stream") instead of a stream's own terminal
    # error — a library-initiated reclamation stays distinguishable from
    # a caller's own graceful stop by exception type, not by whether
    # reading raises at all. If any bytes WERE consumed in
    # that window, the deadline simply re-arms, so a slow-but-active
    # reader is never killed. A quiet stream with an EMPTY buffer — an
    # SSE or long-poll response waiting between events, a successful
    # CONNECT tunnel sitting quiet while the app uploads — pins no credit
    # and keeps running indefinitely: the "never killed merely for going
    # quiet" contract above still holds for it. Set `idle: nil` to
    # disable this safety net along with the per-read/trailer timeout it
    # shares the setting with.
    #
    # `stream_slot` is the pool-wide request-capacity budget. A request
    # first tries every eligible connection and may start one shared,
    # demand-driven expansion dial. `nil` (the default) performs that
    # growth but raises `PoolSaturatedError` as soon as the pool can make
    # no further progress. A span waits up to that long for any connection
    # to gain capacity, for an expansion dial, or for a SETTINGS increase.
    # Cancellation and client close interrupt the wait. Atomic logical
    # reservations do not consume stream IDs while waiting, and opening on
    # one connection does not serialize opening on another connection.
    struct Timeouts
      getter connect : Time::Span?
      getter read : Time::Span?
      getter write : Time::Span?
      getter idle : Time::Span?
      getter stream_slot : Time::Span?

      def initialize(
        @connect : Time::Span? = 10.seconds,
        @read : Time::Span? = 30.seconds,
        @write : Time::Span? = 30.seconds,
        @idle : Time::Span? = 30.seconds,
        @stream_slot : Time::Span? = nil,
      )
        {
          "connect"     => @connect,
          "read"        => @read,
          "write"       => @write,
          "idle"        => @idle,
          "stream_slot" => @stream_slot,
        }.each do |name, duration|
          if duration && duration <= Time::Span.zero
            raise ArgumentError.new("#{name} timeout must be positive")
          end
        end
      end
    end

    # Default connection configuration for clients: keepalive on, so an
    # active connection detects a silent peer without a socket-level read
    # timeout tearing down idle or quiet-but-healthy streams. Used only as
    # the constructor default for `connection_configuration` — a
    # caller-supplied configuration is used exactly as given, never merged
    # with or overridden by this default.
    DEFAULT_CONNECTION_CONFIGURATION = Connection::Configuration.new(
      keepalive_interval: 30.seconds
    )

    # The minimum per-connection slice `#graceful_close` ever passes to
    # `Connection#graceful_close`, even for a connection reached after
    # the shared deadline (see `#graceful_close`'s doc comment) has
    # already elapsed. `Connection#graceful_close` rejects a
    # non-positive timeout outright (`ArgumentError`), so SOME positive
    # floor is required; this is deliberately tiny — a guard against
    # that `ArgumentError`, not a fairness guarantee that a connection
    # reached this late gets a meaningful chance to drain. A connection
    # reached with essentially no budget left either has nothing active
    # to wait for (drains immediately) or does, and immediately raises
    # `Connection::DrainTimeoutError` — both fast, bounded outcomes,
    # rather than an exception from `#graceful_close` itself.
    MIN_GRACEFUL_CLOSE_TIMEOUT = 1.millisecond

    private record Origin,
      scheme : String,
      host : String,
      wire_host : String,
      port : Int32,
      authority : String

    private record PreparedRequest,
      fields : Array(HeaderField),
      trailers : Array(HeaderField),
      body : IO?,
      body_length : Int64?,
      content_length : Int64?,
      connect : Bool

    private record CloseSnapshot,
      connections : Array(Connection),
      in_flight : Connection?

    # One in-flight owned-connection dial shared by every concurrent caller.
    # Completion is always performed while the client's mutex is held, so the
    # error assignment and idempotence check do not need their own lock.
    private class DialAttempt
      getter error : Exception? = nil
      getter signal = Channel(Nil).new
      property connection : Connection?
      getter result_connection : Connection?

      def complete(error : Exception? = nil) : Nil
        return if @signal.closed?

        @error = error
        @signal.close
      end

      def publish(connection : Connection) : Nil
        @result_connection = connection
      end
    end

    # Marks a failure that happened before the request reserved a stream.
    # Retrying this is connection recovery, not request replay: no request
    # fields or body bytes can have reached the peer yet.
    private class PreRequestConnectionError < Exception
      getter connection_error : Exception

      def initialize(@connection_error : Exception)
        super(
          "HTTP/2 connection failed before the request opened a stream",
          @connection_error
        )
      end
    end

    private enum PoolWaitResult
      PoolChanged
      DialCompleted
      Canceled
      TimedOut
    end

    private class RetryPoolSelection < Exception
    end

    getter timeouts : Timeouts
    getter connection_configuration : Connection::Configuration
    getter pool_configuration : PoolConfiguration
    getter replay_policy : ReplayPolicy
    getter max_replay_attempts : Int32

    # Extra field names, beyond the library's own built-in four
    # (`authorization`, `proxy-authorization`, `cookie`, `set-cookie`),
    # that must never be promoted to HPACK's compressed, indexed
    # representation or inserted into this client's connections' dynamic
    # tables (see Task 9's HPACK incremental-indexing change). A caller
    # with its own credential or secret header — `x-api-key`,
    # `x-csrf-token`, a bearer token carried under a non-standard name —
    # adds it here so it keeps the same literal-never-indexed treatment
    # RFC 7541 §7.1.3 reserves for that wire marker precisely so
    # intermediaries cannot promote it. Comparison is case-insensitive:
    # names are downcased once, here, when this client is constructed.
    # Empty by default: this is purely additive and cannot narrow the
    # built-in four, which stay unconditional.
    #
    # Treat the returned `Set` as fixed once this client starts sending
    # requests. `#request` reads it directly on every call (no defensive
    # copy, so a request-heavy connection is not paying a repeated
    # allocation for a value that rarely changes) — mutating it
    # concurrently with an in-flight request is a data race under
    # `-Dpreview_mt`, and any entry added after construction must already
    # be lowercase, since nothing downcases it a second time. Any
    # mutation must happen before this client's first request.
    getter additional_never_indexed_fields : Set(String)

    @origin : Origin
    @supplied_connection_value : Connection?
    @pool_entries = [] of PoolEntry
    @pool_retired_entries = [] of PoolEntry
    @dial_attempt : DialAttempt?
    @supplied_connection : Bool
    @closed = false
    @mutex = Mutex.new
    @next_pool_sequence = 0_u64
    @pool_generation = 0_u64
    @pool_signal = Channel(Nil).new
    @pool_events = Channel(Nil).new(1)
    @pool_coordinator_done = Channel(Nil).new
    @pool_coordinator_started = false
    @pool_waiters = 0
    @pool_acquirers = 0
    @unlimited_zero_capacity = false
    @zero_capacity_entry : PoolEntry?
    # Newly published connections stay protected from idle eviction while
    # the acquisition that caused each dial is still selecting. This is a
    # set, rather than one "fresh" pointer, because a finite acquisition may
    # need to retain several zero-capacity probes until it reaches its bound.
    @acquisition_retained_entries = Set(PoolEntry).new

    # Creates a client bound to one `http` or `https` origin. Owned
    # connections are dialed lazily and scale under `pool_configuration`.
    # A supplied connection is used as-is, is owned by this client, and
    # remains fixed: it is not reconnected or evicted for idleness.
    # Supplying both `connection` and `pool_configuration` is invalid.
    #
    # `tls_context`, whether supplied or defaulted, is used for every
    # `https` dial this client makes (`#dial`'s single `Connection.connect_tls`
    # call reuses the SAME `@tls_context` for the client's whole
    # lifetime) and is configured for ALPN "h2" in place, unconditionally,
    # on every dial — see `Connection.start_tls`'s doc comment for the
    # full contract, including why this is self-healing against anything
    # else that changes it between dials. The symmetric caveat: do not
    # share one `tls_context` with a different consumer (another
    # `Client` configured differently, or anything outside this library)
    # that needs a different, stable ALPN protocol on it — every dial
    # through this `Client` overwrites `alpn_protocol` back to "h2".
    def initialize(
      origin : String | URI,
      *,
      @timeouts : Timeouts = Timeouts.new,
      @connection_configuration : Connection::Configuration = DEFAULT_CONNECTION_CONFIGURATION,
      @tls_context : OpenSSL::SSL::Context::Client = Connection.default_tls_context,
      @replay_policy : ReplayPolicy = ReplayPolicy::Never,
      @max_replay_attempts : Int32 = 1,
      additional_never_indexed_fields : Enumerable(String) = [] of String,
      connection : Connection? = nil,
      pool_configuration : PoolConfiguration? = nil,
    )
      if @max_replay_attempts < 0
        raise ArgumentError.new(
          "maximum replay attempt count cannot be negative"
        )
      end
      @additional_never_indexed_fields =
        additional_never_indexed_fields.map(&.downcase).to_set
      uri = origin.is_a?(URI) ? origin : URI.parse(origin)
      @origin = parse_origin(uri, require_origin_only: true)
      @supplied_connection_value = connection
      @supplied_connection = !connection.nil?
      if connection && pool_configuration
        raise ArgumentError.new(
          "pool configuration cannot be used with a supplied connection"
        )
      end
      @pool_configuration = if connection
                              PoolConfiguration.supplied_connection
                            else
                              (pool_configuration || PoolConfiguration.new).effective
                            end

      start_pool_coordinator
      if supplied = connection
        entry = new_pool_entry(supplied)
        @mutex.synchronize do
          @pool_entries << entry
          advance_pool_generation_unlocked
        end
      end
    end

    # Sends a GET request and waits for its final response fields.
    def get(
      target : String,
      headers : Headers = Headers.new,
      *,
      cancellation : Cancellation? = nil,
    ) : Response
      request(
        Request.new("GET", target, headers),
        cancellation: cancellation
      )
    end

    # Sends a HEAD request and waits for its final response fields.
    def head(
      target : String,
      headers : Headers = Headers.new,
      *,
      cancellation : Cancellation? = nil,
    ) : Response
      request(
        Request.new("HEAD", target, headers),
        cancellation: cancellation
      )
    end

    # Sends a POST request. IO bodies stream from their current position.
    # An IO body paired with an explicit `content-length` header must EOF
    # exactly at that declared length — see `Request#initialize` for what
    # happens, and the risk, if it does not.
    def post(
      target : String,
      headers : Headers = Headers.new,
      body : Request::Body = nil,
      *,
      trailers : Headers = Headers.new,
      cancellation : Cancellation? = nil,
    ) : Response
      request(
        Request.new("POST", target, headers, body, trailers),
        cancellation: cancellation
      )
    end

    # Builds and sends a request for any HTTP method. See `Request#initialize`
    # for the EOF requirement on a sized IO `body`.
    def request(
      method : String,
      target : String,
      headers : Headers = Headers.new,
      body : Request::Body = nil,
      *,
      trailers : Headers = Headers.new,
      cancellation : Cancellation? = nil,
    ) : Response
      request(
        Request.new(method, target, headers, body, trailers),
        cancellation: cancellation
      )
    end

    # Sends a prepared request. The returned response body remains streaming.
    def request(
      request : Request,
      *,
      cancellation : Cancellation? = nil,
    ) : Response
      if cancellation.try(&.canceled?)
        raise RequestCanceledError.new("HTTP/2 request was canceled")
      end

      replay_attempts = 0
      pre_request_retries = 0
      loop do
        begin
          return perform_request(request, cancellation)
        rescue error : Connection::DrainingError
          pre_request_retries += 1
          raise error if @supplied_connection || pre_request_retries > 1
          check_cancellation!(cancellation)
        rescue error : PreRequestConnectionError
          pre_request_retries += 1
          if @supplied_connection || pre_request_retries > 1
            raise error.connection_error
          end
          check_cancellation!(cancellation)
        rescue error : Connection::UnprocessedStreamError
          unless should_replay?(request, error, replay_attempts, cancellation)
            raise error
          end
          replay_attempts += 1
        rescue error : Connection::StreamResetError
          unless should_replay?(request, error, replay_attempts, cancellation)
            raise error
          end
          replay_attempts += 1
        end
      end
    end

    private def perform_request(
      request : Request,
      cancellation : Cancellation?,
    ) : Response
      prepared = prepare(request)
      check_cancellation!(cancellation)
      has_content = !prepared.body.nil? || !prepared.trailers.empty?
      stream = open_request_stream(
        request.method,
        prepared.fields,
        end_stream: !has_content,
        cancellation: cancellation
      )
      upload = UploadState.new

      begin
        if has_content
          unless prepared.connect
            spawn_upload(
              stream,
              prepared,
              upload,
              cancellation
            )
          end
        else
          upload.complete
        end

        await_response(
          stream,
          prepared,
          upload,
          cancellation
        )
      rescue Stream::WaitCanceledError
        canceled = RequestCanceledError.new("HTTP/2 request was canceled")
        abort_stream(stream, canceled)
        raise canceled
      rescue Connection::TimeoutError
        timed_out = RequestTimeoutError.new(
          "waiting for response headers timed out"
        )
        abort_stream(stream, timed_out)
        raise timed_out
      rescue error : IO::TimeoutError
        timed_out = RequestTimeoutError.new(
          "network I/O timed out during the request",
          error
        )
        abort_stream(stream, timed_out)
        raise timed_out
      rescue error
        abort_stream(stream, error) unless stream.terminal_error
        raise error
      end
    end

    # Closes every reusable origin connection and cancels unfinished requests.
    def close : Nil
      snapshot = take_connections_for_close
      connections = snapshot.connections
      if in_flight = snapshot.in_flight
        connections.unshift(in_flight)
      end
      begin
        connections.each(&.close)
      ensure
        wait_for_pool_coordinator
      end
    end

    # Gracefully drains all connections currently owned by this client.
    #
    # `timeout` is a SHARED deadline across every connection, not a
    # per-connection budget: it is applied once, up front, and each
    # connection receives only whatever of it remains (floored
    # at `MIN_GRACEFUL_CLOSE_TIMEOUT`), so N connections that each need
    # a full drain still take roughly `timeout` in total rather than
    # N times `timeout` — a client with several retired connections
    # behind the current one closes in bounded time instead of one that
    # grows with however many connections happen to be pending.
    def graceful_close(
      timeout : Time::Span = @connection_configuration.drain_timeout,
    ) : Nil
      if timeout <= Time::Span.zero
        raise ArgumentError.new("drain timeout must be positive")
      end

      snapshot = take_connections_for_close
      connections = snapshot.connections
      deadline = Time.instant + timeout
      errors = Array(Exception?).new(connections.size, nil)
      outcomes = Channel(Tuple(Int32, Exception?)).new(connections.size)
      begin
        # A connection still being dialed or handshaken cannot contain an
        # application stream. Abandon it immediately rather than making it
        # participate in graceful GOAWAY draining.
        snapshot.in_flight.try(&.close)
        connections.each_with_index do |connection, index|
          spawn(name: "http2-client-graceful-close") do
            error : Exception? = nil
            begin
              remaining = deadline - Time.instant
              if remaining < MIN_GRACEFUL_CLOSE_TIMEOUT
                remaining = MIN_GRACEFUL_CLOSE_TIMEOUT
              end
              connection.graceful_close(remaining)
            rescue exception
              error = exception
            ensure
              outcomes.send({index, error})
            end
          end
        end
        connections.size.times do
          index, error = outcomes.receive
          errors[index] = error
        end
      ensure
        wait_for_pool_coordinator
      end
      if first_error = errors.compact.first?
        raise first_error
      end
    end

    # True once `#close` or `#graceful_close` has been called — both set
    # the closed flag immediately when invoked, even while a
    # `#graceful_close` drain is still in progress, not only once
    # teardown finishes. A request made after this returns `true` fails
    # immediately with `ClosedError`, without dialing or touching the
    # network.
    def closed? : Bool
      @mutex.synchronize { @closed }
    end

    # Returns a value-only snapshot of the current pool.
    def pool_state : PoolState
      @mutex.synchronize do
        retained_entries = protected_idle_entries_unlocked
        PoolState.new(
          @pool_entries.size,
          @pool_entries.count do |entry|
            !entry.idle_since.nil? &&
              !retained_entries.includes?(entry)
          end,
          @pool_retired_entries.size,
          !@dial_attempt.nil?,
          @pool_configuration.max_connections
        )
      end
    end

    # The branches keep every pre-HEADERS connection race recoverable while
    # preserving distinct timeout, cancellation, and terminal error types.
    # ameba:disable Metrics/CyclomaticComplexity
    private def open_request_stream(
      request_method : String,
      fields : Array(HeaderField),
      *,
      end_stream : Bool,
      cancellation : Cancellation?,
    ) : Stream
      deadline = @timeouts.stream_slot.try { |span| Time.instant + span }
      terminal_reselections = 0

      loop do
        selected = acquire_request_slot(cancellation, deadline)
        connection = selected.entry.connection
        stream = nil
        begin
          selected.entry.opening_mutex.synchronize do
            check_cancellation!(cancellation)
            stream = connection.materialize_request_stream(
              selected.reservation
            )
            current = stream ||
                      raise "request reservation did not materialize a stream"
            current.inbound_validator = ResponseValidator.new(
              current.id,
              request_method
            )
            begin
              current.send_headers(fields, end_stream: end_stream)
            rescue error : Connection::ConcurrentStreamLimitError | Connection::DrainingError
              abort_stream(current, error) unless current.terminal_error
              stream = nil
              raise RetryPoolSelection.new(error.message, error)
            rescue error : Connection::InvalidStateError
              if error.class == Connection::InvalidStateError
                abort_stream(current, error) unless current.terminal_error
                stream = nil
                raise RetryPoolSelection.new(error.message, error)
              end
              raise error
            end
            check_cancellation!(cancellation)
          end
          return stream ||
            raise "request opening completed without a stream"
        rescue Connection::ConcurrentStreamLimitError | Connection::OpenStreamLimitError | Connection::StreamIDExhaustedError
          signal_pool_event
          next
        rescue error : Connection::DrainingError | Connection::ClosedError
          terminal_reselections += 1
          raise error if @supplied_connection || terminal_reselections > 1
          signal_pool_event
          next
        rescue error : Connection::InvalidStateError
          if stream.nil? && error.class == Connection::InvalidStateError
            signal_pool_event
            next
          end
          raise error
        rescue RetryPoolSelection
          signal_pool_event
          next
        rescue error : Connection::TimeoutError
          timed_out = RequestTimeoutError.new(
            "HTTP/2 connection timed out while opening the request",
            error
          )
          abort_stream(stream, timed_out) if stream
          raise timed_out
        rescue error : IO::TimeoutError
          timed_out = RequestTimeoutError.new(
            "network I/O timed out while opening the request",
            error
          )
          abort_stream(stream, timed_out) if stream
          raise timed_out
        rescue error
          if current = stream
            abort_stream(current, error) unless current.terminal_error
          end
          raise error
        ensure
          selected.reservation.release
        end
      end
    end

    # ameba:enable Metrics/CyclomaticComplexity

    # Pool acquisition is an explicit state machine whose branches correspond
    # to selection, reconciliation, dialing, waiting, and terminal outcomes.
    # ameba:disable Metrics/CyclomaticComplexity
    private def acquire_request_slot(
      cancellation : Cancellation?,
      deadline : Time::Instant?,
    ) : ReservedConnection
      supplied_ready_deadline = if @supplied_connection
                                  @timeouts.read.try do |span|
                                    Time.instant + span
                                  end
                                end

      @mutex.synchronize do
        @pool_acquirers += 1
        @pool_waiters += 1 if deadline
      end

      begin
        loop do
          check_cancellation!(cancellation)
          entries = pool_selection_snapshot.first

          if selected = reserve_from_pool_entries(entries)
            return selected
          end

          if unlimited_zero_capacity? && deadline.nil?
            raise_pool_saturated
          end

          if reconcile_pool
            next
          end

          entries, generation, signal, attempt = pool_selection_snapshot
          if selected = reserve_from_pool_entries(entries)
            return selected
          end
          if @supplied_connection && entries.empty?
            raise_supplied_connection_error
          end

          if @supplied_connection &&
             entries.any?(&.connection.state.handshaking?)
            result = wait_for_pool(
              signal,
              nil,
              supplied_ready_deadline,
              cancellation
            )
            case result
            when .canceled?
              check_cancellation!(cancellation)
            when .timed_out?
              raise RequestTimeoutError.new(
                "waiting for the HTTP/2 handshake timed out"
              )
            else
              next
            end
          end

          unless attempt
            attempt, start = claim_dial_attempt(generation)
            if attempt && start
              if selected = reserve_from_current_pool
                cancel_unstarted_dial(attempt)
                return selected
              end
              start_owned_dial(attempt)
            elsif attempt.nil? && pool_generation_changed?(generation)
              next
            end
          end

          if attempt
            result = wait_for_pool(
              signal,
              attempt,
              deadline,
              cancellation
            )
            case result
            when .canceled?
              check_cancellation!(cancellation)
            when .timed_out?
              raise_pool_saturated
            else
              if attempt.signal.closed?
                if selected = reserve_from_current_pool
                  return selected
                end
                if error = attempt.error
                  raise error
                end
                if connection = attempt.result_connection
                  capacity = connection.request_capacity
                  if capacity.state.closed? ||
                     capacity.state.draining?
                    failure = connection.terminal_error ||
                              Connection::DrainingError.new(
                                "new HTTP/2 connection became ineligible"
                              )
                    raise PreRequestConnectionError.new(failure)
                  end
                end
              end
              next
            end
          end

          if deadline
            result = wait_for_pool(signal, nil, deadline, cancellation)
            case result
            when .canceled?
              check_cancellation!(cancellation)
            when .timed_out?
              raise_pool_saturated
            else
            end
            next
          end

          raise_pool_saturated
        end
      ensure
        @mutex.synchronize do
          @pool_acquirers -= 1
          @pool_waiters -= 1 if deadline
          @acquisition_retained_entries.clear if @pool_acquirers.zero?
        end
        signal_pool_event
      end
    end

    # ameba:enable Metrics/CyclomaticComplexity

    private def unlimited_zero_capacity? : Bool
      @mutex.synchronize do
        @pool_configuration.max_connections.nil? &&
          @unlimited_zero_capacity
      end
    end

    private def raise_supplied_connection_error : NoReturn
      connection = @mutex.synchronize { @supplied_connection_value }
      unless connection
        raise ClosedError.new("supplied HTTP/2 connection is unavailable")
      end
      if error = connection.terminal_error
        raise error
      end
      if connection.draining?
        raise Connection::DrainingError.new(
          "supplied HTTP/2 connection is draining"
        )
      end

      raise PoolSaturatedError.new(@pool_configuration.max_connections)
    end

    private def pool_selection_snapshot : Tuple(
      Array(PoolEntry),
      UInt64,
      Channel(Nil),
      DialAttempt?,
    )
      @mutex.synchronize do
        raise ClosedError.new("HTTP/2 client is closed") if @closed

        {
          @pool_entries.dup,
          @pool_generation,
          @pool_signal,
          @dial_attempt,
        }
      end
    end

    private def reserve_from_current_pool : ReservedConnection?
      entries = @mutex.synchronize do
        raise ClosedError.new("HTTP/2 client is closed") if @closed

        @pool_entries.dup
      end
      reserve_from_pool_entries(entries)
    end

    private def reserve_from_pool_entries(
      entries : Array(PoolEntry),
    ) : ReservedConnection?
      entries.each do |entry|
        reservation = entry.connection.try_reserve_request_slot
        next unless reservation

        retained = @mutex.synchronize do
          if @closed || !@pool_entries.includes?(entry)
            false
          else
            entry.mark_busy
            @unlimited_zero_capacity = false
            @zero_capacity_entry = nil
            @acquisition_retained_entries.delete(entry)
            true
          end
        end
        unless retained
          reservation.release
          raise ClosedError.new("HTTP/2 client is closed") if closed?
          next
        end

        return ReservedConnection.new(entry, reservation)
      end
      nil
    end

    private def claim_dial_attempt(
      observed_generation : UInt64,
    ) : Tuple(DialAttempt?, Bool)
      @mutex.synchronize do
        raise ClosedError.new("HTTP/2 client is closed") if @closed

        if attempt = @dial_attempt
          next {attempt, false}
        end
        next {nil, false} if observed_generation != @pool_generation
        next {nil, false} unless pool_may_grow_unlocked?

        attempt = DialAttempt.new
        @dial_attempt = attempt
        advance_pool_generation_unlocked
        {attempt, true}
      end
    end

    private def cancel_unstarted_dial(attempt : DialAttempt) : Nil
      @mutex.synchronize do
        if current = @dial_attempt
          if current.same?(attempt) && attempt.connection.nil?
            @dial_attempt = nil
            attempt.complete
            advance_pool_generation_unlocked unless @closed
          end
        end
      end
    end

    private def pool_generation_changed?(generation : UInt64) : Bool
      @mutex.synchronize do
        raise ClosedError.new("HTTP/2 client is closed") if @closed

        generation != @pool_generation
      end
    end

    private def pool_may_grow_unlocked? : Bool
      return false if @supplied_connection
      return false if @pool_configuration.max_connections.nil? &&
                      @unlimited_zero_capacity

      if maximum = @pool_configuration.max_connections
        @pool_entries.size < maximum
      else
        true
      end
    end

    private def start_owned_dial(attempt : DialAttempt) : Nil
      spawn(name: "http2-client-dial") do
        dialed = nil
        begin
          dialed = dial
          retain_dialed_connection(attempt, dialed)
          dialed.wait_until_active(@timeouts.read)
          unless dialed.active?
            raise(
              dialed.terminal_error ||
              Connection::DrainingError.new(
                "new HTTP/2 connection did not become eligible"
              )
            )
          end
          publish_pool_connection(attempt, dialed)
          dialed = nil
        rescue error : Connection::TimeoutError
          failure = RequestTimeoutError.new(
            "waiting for the HTTP/2 handshake timed out",
            error
          )
          fail_dial_attempt(attempt, failure)
        rescue error : IO::TimeoutError
          failure = RequestTimeoutError.new(
            "connecting to the HTTP/2 origin timed out",
            error
          )
          fail_dial_attempt(attempt, failure)
        rescue error
          failure = if current = dialed
                      if current.closed?
                        PreRequestConnectionError.new(error)
                      else
                        error
                      end
                    else
                      error
                    end
          fail_dial_attempt(attempt, failure)
        ensure
          dialed.try(&.close)
        end
      end
    end

    private def publish_pool_connection(
      attempt : DialAttempt,
      connection : Connection,
    ) : Nil
      capacity = connection.request_capacity
      unless capacity.state.active?
        raise(
          connection.terminal_error ||
          Connection::DrainingError.new(
            "new HTTP/2 connection became ineligible before publication"
          )
        )
      end
      entry = new_pool_entry(connection)
      published = @mutex.synchronize do
        current = @dial_attempt
        if @closed || !current || !current.same?(attempt)
          false
        else
          @pool_entries << entry
          attempt.publish(connection)
          @unlimited_zero_capacity =
            @pool_configuration.max_connections.nil? &&
              capacity.zero_peer_limit?
          @zero_capacity_entry =
            @unlimited_zero_capacity ? entry : nil
          if @pool_acquirers > 0
            @acquisition_retained_entries << entry
          end
          @dial_attempt = nil
          attempt.connection = nil
          attempt.complete
          advance_pool_generation_unlocked
          true
        end
      end

      unless published
        entry.unsubscribe
        connection.close
        return
      end
      signal_pool_event
    end

    private def fail_dial_attempt(
      attempt : DialAttempt,
      error : Exception,
    ) : Nil
      @mutex.synchronize do
        if current = @dial_attempt
          @dial_attempt = nil if current.same?(attempt)
        end
        attempt.connection = nil
        attempt.complete(error)
        advance_pool_generation_unlocked unless @closed
      end
    end

    private def retain_dialed_connection(
      attempt : DialAttempt,
      connection : Connection,
    ) : Nil
      retained = @mutex.synchronize do
        current = @dial_attempt
        if @closed || !current || !current.same?(attempt)
          false
        else
          attempt.connection = connection
          true
        end
      end
      return if retained

      connection.close
      raise ClosedError.new("HTTP/2 client is closed")
    end

    # The explicit select matrix avoids helper fibers and covers every valid
    # combination of dial, deadline, and cancellation signals.
    # ameba:disable Metrics/CyclomaticComplexity
    private def wait_for_pool(
      signal : Channel(Nil),
      attempt : DialAttempt?,
      deadline : Time::Instant?,
      cancellation : Cancellation?,
    ) : PoolWaitResult
      remaining = deadline.try { |value| value - Time.instant }
      return PoolWaitResult::TimedOut if remaining &&
                                         remaining <= Time::Span.zero
      canceled = cancellation.try(&.signal)

      if attempt
        if canceled
          if remaining
            select
            when signal.receive?
              PoolWaitResult::PoolChanged
            when attempt.signal.receive?
              PoolWaitResult::DialCompleted
            when canceled.receive?
              PoolWaitResult::Canceled
            when timeout(remaining)
              PoolWaitResult::TimedOut
            end
          else
            select
            when signal.receive?
              PoolWaitResult::PoolChanged
            when attempt.signal.receive?
              PoolWaitResult::DialCompleted
            when canceled.receive?
              PoolWaitResult::Canceled
            end
          end
        elsif remaining
          select
          when signal.receive?
            PoolWaitResult::PoolChanged
          when attempt.signal.receive?
            PoolWaitResult::DialCompleted
          when timeout(remaining)
            PoolWaitResult::TimedOut
          end
        else
          select
          when signal.receive?
            PoolWaitResult::PoolChanged
          when attempt.signal.receive?
            PoolWaitResult::DialCompleted
          end
        end
      elsif canceled
        if remaining
          select
          when signal.receive?
            PoolWaitResult::PoolChanged
          when canceled.receive?
            PoolWaitResult::Canceled
          when timeout(remaining)
            PoolWaitResult::TimedOut
          end
        else
          select
          when signal.receive?
            PoolWaitResult::PoolChanged
          when canceled.receive?
            PoolWaitResult::Canceled
          end
        end
      elsif remaining
        select
        when signal.receive?
          PoolWaitResult::PoolChanged
        when timeout(remaining)
          PoolWaitResult::TimedOut
        end
      else
        signal.receive?
        PoolWaitResult::PoolChanged
      end
    end

    # ameba:enable Metrics/CyclomaticComplexity

    private def raise_pool_saturated : NoReturn
      raise PoolSaturatedError.new(
        @pool_configuration.max_connections
      )
    end

    private def new_pool_entry(connection : Connection) : PoolEntry
      sequence = @mutex.synchronize do
        @next_pool_sequence += 1_u64
      end
      entry = PoolEntry.new(connection, sequence)
      entry.subscribe { signal_pool_event }
      entry
    end

    private def signal_pool_event : Nil
      select
      when @pool_events.send(nil)
      else
      end
    rescue Channel::ClosedError
      # Client teardown already wakes every pool waiter.
    end

    private def advance_pool_generation_unlocked : Nil
      @pool_generation += 1_u64
      previous = @pool_signal
      @pool_signal = Channel(Nil).new
      previous.close
    end

    private def start_pool_coordinator : Nil
      start = @mutex.synchronize do
        unless @pool_coordinator_started
          @pool_coordinator_started = true
          true
        end
      end
      return unless start

      spawn(name: "http2-pool-coordinator") { pool_coordinator_loop }
    end

    private def pool_coordinator_loop : Nil
      loop do
        delay = next_idle_maintenance_delay
        if delay
          select
          when @pool_events.receive?
          when timeout(delay)
          end
        else
          @pool_events.receive?
        end
        break if @pool_events.closed?

        @mutex.synchronize do
          advance_pool_generation_unlocked unless @closed
        end
        reconcile_pool
      end
    rescue Channel::ClosedError
      # Client teardown closes the control channel.
    ensure
      @pool_coordinator_done.close
    end

    private def next_idle_maintenance_delay : Time::Span?
      timeout = @pool_configuration.idle_timeout
      return unless timeout

      deadline = @mutex.synchronize do
        retained_entries = protected_idle_entries_unlocked
        @pool_entries.reject { |entry| retained_entries.includes?(entry) }
          .compact_map(&.idle_since)
          .min?
          .try { |idle_since| idle_since + timeout }
      end
      return unless deadline

      remaining = deadline - Time.instant
      remaining > Time::Span.zero ? remaining : Time::Span.zero
    end

    # Reconciliation applies one authoritative capacity snapshot across the
    # eligible, retired, and idle policies before performing closes outside
    # the client mutex.
    # ameba:disable Metrics/CyclomaticComplexity
    private def reconcile_pool : Bool
      entries, retired, activity_generations = @mutex.synchronize do
        return false if @closed

        entries = @pool_entries.dup
        generations = {} of PoolEntry => UInt64
        entries.each do |entry|
          generations[entry] = entry.activity_generation
        end
        {entries, @pool_retired_entries.dup, generations}
      end
      capacities = {} of PoolEntry => Connection::RequestCapacity
      (entries + retired).each do |entry|
        capacities[entry] = entry.connection.request_capacity
      end

      now = Time.instant
      unsubscribe = [] of PoolEntry
      force_close = [] of PoolEntry
      idle_close = [] of PoolEntry
      changed = false

      @mutex.synchronize do
        return false if @closed

        entries.each do |entry|
          next unless @pool_entries.includes?(entry)
          capacity = capacities[entry]
          if capacity.state.closed?
            @pool_entries.delete(entry)
            if entry.same?(@zero_capacity_entry)
              @zero_capacity_entry = nil
              @unlimited_zero_capacity = false
            end
            @acquisition_retained_entries.delete(entry)
            unsubscribe << entry
            changed = true
          elsif capacity.state.draining? ||
                capacity.stream_ids_exhausted
            @pool_entries.delete(entry)
            if entry.same?(@zero_capacity_entry)
              @zero_capacity_entry = nil
              @unlimited_zero_capacity = false
            end
            @acquisition_retained_entries.delete(entry)
            entry.retired = true
            entry.idle_since = nil
            @pool_retired_entries << entry
            changed = true
          elsif entry.activity_generation !=
                  activity_generations[entry]
            next
          elsif capacity.state.active? && capacity.empty?
            unless entry.idle_since
              entry.idle_since = now
              changed = true
            end
          elsif entry.idle_since
            entry.idle_since = nil
            changed = true
          end
        end

        retired.each do |entry|
          next unless @pool_retired_entries.includes?(entry)
          capacity = capacities[entry]
          if capacity.state.closed?
            @pool_retired_entries.delete(entry)
            unsubscribe << entry
            changed = true
          elsif capacity.empty? && capacity.state.active?
            idle_close << entry
          end
        end

        while @pool_retired_entries.size >
                @pool_configuration.max_retired_connections
          oldest = @pool_retired_entries.shift
          unsubscribe << oldest
          force_close << oldest
          changed = true
        end

        retained_entries = protected_idle_entries_unlocked
        all_idle_entries = @pool_entries.select(&.idle_since)
        idle_entries = all_idle_entries.reject do |entry|
          retained_entries.includes?(entry)
        end
        idle_entries.sort_by! { |entry| entry.idle_since || now }
        excess = all_idle_entries.size -
                 @pool_configuration.max_idle_connections
        if excess > 0
          idle_close.concat(
            idle_entries.first(Math.min(excess, idle_entries.size))
          )
        end
        if timeout = @pool_configuration.idle_timeout
          idle_entries.each do |entry|
            if idle_since = entry.idle_since
              idle_close << entry if now - idle_since >= timeout
            end
          end
        end

        if sentinel = @zero_capacity_entry
          capacity = capacities[sentinel]?
          if !capacity || !@pool_entries.includes?(sentinel)
            @zero_capacity_entry = nil
            @unlimited_zero_capacity = false
            changed = true
          elsif !capacity.zero_peer_limit?
            @unlimited_zero_capacity = false
            if @pool_waiters.zero?
              @zero_capacity_entry = nil
            end
            changed = true
          end
        end

        advance_pool_generation_unlocked if changed
      end

      unsubscribe.uniq!.each(&.unsubscribe)
      force_close.uniq!.each(&.connection.close)
      retained_entries = @mutex.synchronize do
        protected_idle_entries_unlocked
      end
      idle_close.uniq!.each do |entry|
        next if retained_entries.includes?(entry)

        if entry.connection.close_if_idle
          changed = true
        else
          signal_pool_event
        end
      end
      changed
    end

    # ameba:enable Metrics/CyclomaticComplexity

    private def protected_idle_entries_unlocked : Array(PoolEntry)
      retained_entries = [] of PoolEntry
      if @pool_waiters > 0
        if sentinel = @zero_capacity_entry
          retained_entries << sentinel
        end
      end
      if @pool_acquirers > 0
        @acquisition_retained_entries.each do |entry|
          retained_entries << entry unless retained_entries.includes?(entry)
        end
      end
      retained_entries
    end

    # Dials a new connection. Neither branch passes `read_timeout:`: a
    # persistent socket-level read deadline would kill idle pooled
    # connections and quiet long-lived streams once active. The HTTP/2
    # handshake wait is instead bounded by the shared dial worker's
    # `wait_until_active(@timeouts.read)` call, and liveness after that is
    # keepalive's job, not a transport read timeout.
    # `write_timeout:` still bounds transport writes throughout the
    # connection's life. The HTTPS branch also passes
    # `handshake_read_timeout: @timeouts.read`, which bounds only the TLS
    # handshake itself (before any `Connection` exists to be covered by
    # `wait_until_active`) and is not left armed afterward — see
    # `Connection.start_tls`'s doc comment.
    private def dial : Connection
      case @origin.scheme
      when "http"
        Connection.connect_prior_knowledge(
          @origin.host,
          @origin.port,
          @connection_configuration,
          connect_timeout: @timeouts.connect,
          write_timeout: @timeouts.write
        )
      when "https"
        Connection.connect_tls(
          @origin.host,
          @origin.port,
          server_name: @origin.host,
          context: @tls_context,
          configuration: @connection_configuration,
          connect_timeout: @timeouts.connect,
          write_timeout: @timeouts.write,
          handshake_read_timeout: @timeouts.read
        )
      else
        raise InvalidRequestError.new(
          "HTTP/2 client origins must use http or https"
        )
      end
    end

    private def prepare(request : Request) : PreparedRequest
      validate_method!(request.method)
      headers = request.headers.dup
      validate_request_fields!(headers, trailer: false)
      validate_request_fields!(request.trailers, trailer: true)

      path, authority = request_target(request.method, request.target)
      validate_pseudo_value!(":authority", authority)
      validate_pseudo_value!(":path", path) unless request.method == "CONNECT"
      validate_host!(headers, authority)
      content_length = HTTPSemantics.parse_request_content_length(headers)
      connect = request.method == "CONNECT"
      if connect
        unless request.trailers.empty?
          raise InvalidRequestError.new(
            "CONNECT tunnel data cannot use HTTP trailers"
          )
        end
        if content_length
          raise InvalidRequestError.new(
            "CONNECT tunnel data cannot use content-length"
          )
        end
      end

      if !connect && (known_length = request.body_length)
        if content_length
          unless content_length == known_length
            raise InvalidRequestError.new(
              "request body length #{known_length} does not match " \
              "content-length #{content_length}"
            )
          end
        elsif request.body
          headers.add("content-length", known_length.to_s)
          content_length = known_length
        end
      end

      pseudo_fields = [HeaderField.new(":method", request.method)]
      if request.method == "CONNECT"
        pseudo_fields << HeaderField.new(":authority", authority)
      else
        pseudo_fields << HeaderField.new(":scheme", @origin.scheme)
        pseudo_fields << HeaderField.new(":authority", authority)
        # Deliberately left at the default Indexing::None (Task 9 review).
        # Unlike :method/:scheme (a handful of static-table values, so
        # incremental indexing would be a no-op either way), :path is
        # normally unique per request and rarely a static-table hit, so
        # marking it Incremental would actually insert full path+query
        # values into the connection's dynamic table -- and a query
        # string can carry secrets (tokens, API keys). Do not "optimize"
        # this without a deliberate, separately reviewed decision.
        pseudo_fields << HeaderField.new(":path", path)
      end
      pseudo_fields.concat(headers.to_header_fields(@additional_never_indexed_fields))

      PreparedRequest.new(
        pseudo_fields,
        request.trailers.to_header_fields(@additional_never_indexed_fields),
        request.body_for_attempt,
        request.body_length,
        content_length,
        connect
      )
    end

    private def validate_method!(method : String) : Nil
      if method.empty? || method.each_byte.any? do |byte|
           !token_byte?(byte)
         end
        raise InvalidRequestError.new("request method is not a valid token")
      end
    end

    private def validate_request_fields!(
      fields : Headers,
      *,
      trailer : Bool,
    ) : Nil
      fields.each do |field|
        if field.name.starts_with?(':')
          raise InvalidRequestError.new(
            "callers cannot provide HTTP/2 pseudo-fields"
          )
        end
        if error = HTTPSemantics.regular_field_error(
             field.name,
             field.value,
             request: true,
             trailer: trailer
           )
          raise InvalidRequestError.new(error)
        end
        if trailer && field.name == "te"
          raise InvalidRequestError.new("te is forbidden in trailers")
        end
      end
    end

    private def validate_host!(headers : Headers, authority : String) : Nil
      headers.get_all("host").each do |host|
        unless host.downcase == authority.downcase
          raise InvalidRequestError.new(
            "host must match the HTTP/2 :authority value"
          )
        end
      end
    end

    private def validate_pseudo_value!(name : String, value : String) : Nil
      if error = HTTPSemantics.field_syntax_error(
           name,
           value,
           pseudo: true
         )
        raise InvalidRequestError.new(error)
      end
      if value.each_byte.any? { |byte| byte <= 0x20 || byte >= 0x7f }
        raise InvalidRequestError.new(
          "#{name} must contain URI-safe ASCII bytes"
        )
      end
    end

    private def request_target(
      method : String,
      target : String,
    ) : Tuple(String, String)
      if method == "CONNECT"
        validate_connect_authority!(target)
        return {"", target}
      end
      if target == "*"
        unless method == "OPTIONS"
          raise InvalidRequestError.new(
            "only OPTIONS can use the asterisk request target"
          )
        end
        return {"*", @origin.authority}
      end

      uri = URI.parse(target)
      if uri.fragment
        raise InvalidRequestError.new("request targets cannot contain fragments")
      end
      if uri.absolute?
        target_origin = parse_origin(uri)
        unless target_origin.scheme == @origin.scheme &&
               target_origin.host.downcase == @origin.host.downcase &&
               target_origin.port == @origin.port
          raise InvalidRequestError.new(
            "absolute request target does not match the client origin"
          )
        end
        return {uri.request_target, @origin.authority}
      end
      unless target.starts_with?('/')
        raise InvalidRequestError.new(
          "request target must be absolute-form or start with /"
        )
      end
      {target, @origin.authority}
    rescue error : URI::Error | ArgumentError
      raise InvalidRequestError.new("invalid request target: #{error.message}")
    end

    private def validate_connect_authority!(authority : String) : Nil
      if authority.empty? || authority.includes?('/') ||
         authority.includes?('?') || authority.includes?('#') ||
         authority.includes?('@')
        raise InvalidRequestError.new(
          "CONNECT requires a host:port authority target"
        )
      end

      parsed = URI.parse("http://#{authority}")
      port = parsed.port
      unless parsed.hostname && port && (1..65_535).includes?(port)
        raise InvalidRequestError.new(
          "CONNECT requires a host:port authority target"
        )
      end
    rescue URI::Error
      raise InvalidRequestError.new(
        "CONNECT requires a valid host:port authority target"
      )
    end

    private def parse_origin(
      uri : URI,
      *,
      require_origin_only : Bool = false,
    ) : Origin
      scheme = origin_scheme(uri)
      host = uri.hostname ||
             raise ArgumentError.new("HTTP/2 client origin requires a host")
      wire_host = uri.host ||
                  raise ArgumentError.new("HTTP/2 client origin requires a host")
      validate_origin_uri!(uri, require_origin_only)

      default_port = scheme == "https" ? 443 : 80
      port = uri.port || default_port
      unless (1..65_535).includes?(port)
        raise ArgumentError.new("HTTP/2 client origin has an invalid port")
      end
      authority = port == default_port ? wire_host : "#{wire_host}:#{port}"
      Origin.new(scheme, host, wire_host, port, authority)
    end

    private def origin_scheme(uri : URI) : String
      scheme = uri.scheme.try(&.downcase)
      return "http" if scheme == "http"
      return "https" if scheme == "https"

      raise ArgumentError.new(
        "HTTP/2 client origin must use http or https"
      )
    end

    private def validate_origin_uri!(
      uri : URI,
      require_origin_only : Bool,
    ) : Nil
      if uri.user || uri.password
        raise ArgumentError.new("HTTP/2 client origin cannot contain userinfo")
      end
      return unless require_origin_only
      return if (uri.path.empty? || uri.path == "/") &&
                uri.query.nil? && uri.fragment.nil?

      raise ArgumentError.new(
        "HTTP/2 client origin cannot contain a path, query, or fragment"
      )
    end

    private def spawn_upload(
      stream : Stream,
      request : PreparedRequest,
      upload : UploadState,
      cancellation : Cancellation?,
    ) : Nil
      spawn do
        begin
          send_request_content(stream, request, cancellation)
          upload.complete
        rescue EarlyResponseStop
          upload.complete
        rescue error : IO::TimeoutError
          timed_out = RequestTimeoutError.new(
            "network write timed out while streaming the request body",
            error
          )
          upload.complete
          abort_stream(stream, timed_out) unless stream.terminal_error
        rescue error
          upload.complete
          abort_stream(stream, error) unless stream.terminal_error
        end
      end
    end

    private def send_request_content(
      stream : Stream,
      request : PreparedRequest,
      cancellation : Cancellation?,
    ) : Nil
      if body = request.body
        stream_body(
          stream,
          body,
          request.trailers,
          request.body_length,
          request.content_length,
          cancellation
        )
      else
        check_cancellation!(cancellation)
        stream.send_headers(request.trailers, end_stream: true)
      end
    end

    private def stream_body(
      stream : Stream,
      source : IO,
      trailers : Array(HeaderField),
      body_length : Int64?,
      content_length : Int64?,
      cancellation : Cancellation?,
    ) : Nil
      if framed_length = body_length || content_length
        stream_sized_body(
          stream,
          source,
          trailers,
          framed_length,
          cancellation
        )
      else
        stream_body_to_eof(
          stream,
          source,
          trailers,
          cancellation
        )
      end
    end

    private def stream_sized_body(
      stream : Stream,
      source : IO,
      trailers : Array(HeaderField),
      body_length : Int64,
      cancellation : Cancellation?,
    ) : Nil
      chunk_size = @connection_configuration.outbound_data_chunk_size
      buffer = Bytes.new(chunk_size)
      sent = 0_i64
      while sent < body_length
        check_cancellation!(cancellation)
        remaining = body_length - sent
        read_size = Math.min(remaining, chunk_size).to_i
        size = source.read(buffer[0, read_size])
        check_cancellation!(cancellation)
        validate_sent_length!(sent, body_length) if size.zero?
        sent += size
        stream.send_data(buffer[0, size])
      end
      reject_excess_body!(source, body_length, cancellation)
      finish_request_content(stream, trailers)
    end

    private def stream_body_to_eof(
      stream : Stream,
      source : IO,
      trailers : Array(HeaderField),
      cancellation : Cancellation?,
    ) : Nil
      chunk_size = @connection_configuration.outbound_data_chunk_size
      buffer = Bytes.new(chunk_size)
      loop do
        check_cancellation!(cancellation)
        size = source.read(buffer)
        check_cancellation!(cancellation)
        if size.zero?
          finish_request_content(stream, trailers)
          return
        end

        stream.send_data(buffer[0, size])
      end
    end

    private def finish_request_content(
      stream : Stream,
      trailers : Array(HeaderField),
    ) : Nil
      if trailers.empty?
        stream.send_data(Bytes.empty, end_stream: true)
      else
        stream.send_headers(trailers, end_stream: true)
      end
    end

    private def validate_sent_length!(
      actual : Int64,
      expected : Int64,
    ) : Nil
      return if actual == expected

      raise InvalidRequestError.new(
        "streamed request body length #{actual} does not match " \
        "content-length #{expected}"
      )
    end

    # Symmetric counterpart to `#validate_sent_length!`: that check catches
    # a source that runs dry before the declared length; this one catches
    # a source that still has more once exactly `body_length` bytes have
    # already been sent. `#stream_sized_body` never reads past `body_length`
    # on its own (each chunk is capped at the remaining declared amount), so
    # without this probe a longer source is silently truncated to the
    # declared length instead of surfacing as a request error. Probing
    # before `#finish_request_content` runs means a caller-visible error is
    # possible before END_STREAM is committed to the wire, rather than only
    # after.
    private def reject_excess_body!(
      source : IO,
      body_length : Int64,
      cancellation : Cancellation?,
    ) : Nil
      check_cancellation!(cancellation)
      probe = Bytes.new(1)
      extra = source.read(probe)
      check_cancellation!(cancellation)
      return if extra.zero?

      raise InvalidRequestError.new(
        "streamed request body exceeds declared content-length " \
        "#{body_length}"
      )
    end

    private def check_cancellation!(cancellation : Cancellation?) : Nil
      if cancellation.try(&.canceled?)
        raise RequestCanceledError.new("HTTP/2 request was canceled")
      end
    end

    private def should_replay?(
      request : Request,
      error : Exception,
      replay_attempts : Int32,
      cancellation : Cancellation?,
    ) : Bool
      return false if cancellation.try(&.canceled?)
      return false if replay_attempts >= @max_replay_attempts
      return false unless request.replayable_body?
      return false unless @replay_policy.allows?(request.method)

      case error
      when Connection::UnprocessedStreamError
        !@supplied_connection
      when Connection::StreamResetError
        error.error_code == ErrorCode::REFUSED_STREAM.to_u32
      else
        false
      end
    end

    private def take_connections_for_close : CloseSnapshot
      entries = [] of PoolEntry
      in_flight = nil
      snapshot = @mutex.synchronize do
        if @closed
          next CloseSnapshot.new([] of Connection, nil)
        end

        @closed = true
        if attempt = @dial_attempt
          @dial_attempt = nil
          in_flight = attempt.connection
          attempt.complete(
            ClosedError.new("HTTP/2 client is closed")
          )
        end
        entries = @pool_entries + @pool_retired_entries
        entries.sort_by!(&.sequence)
        @pool_entries = [] of PoolEntry
        @pool_retired_entries = [] of PoolEntry
        @acquisition_retained_entries.clear
        collected = [] of Connection
        entries.each { |entry| collected << entry.connection }
        @supplied_connection_value = nil
        advance_pool_generation_unlocked
        CloseSnapshot.new(collected.uniq!, in_flight)
      end
      entries.each(&.unsubscribe)
      begin
        @pool_events.close
      rescue Channel::ClosedError
      end
      snapshot
    end

    private def wait_for_pool_coordinator : Nil
      return unless @pool_coordinator_started

      @pool_coordinator_done.receive?
    end

    private def await_response(
      stream : Stream,
      request : PreparedRequest,
      upload : UploadState,
      cancellation : Cancellation?,
    ) : Response
      informational = [] of InformationalResponse
      loop do
        event = stream.receive(
          @timeouts.read,
          cancellation.try(&.signal)
        )
        case event
        when Connection::FieldSection
          parsed = HTTPSemantics.parse_response_section(
            event.fields,
            stream.id
          )
          if parsed.status < 200
            informational << InformationalResponse.new(
              parsed.status,
              parsed.headers
            )
            next
          end

          start_connect_upload(
            stream,
            request,
            parsed.status,
            event.end_stream?,
            upload,
            cancellation
          )
          metadata = ResponseMetadata.new
          if event.end_stream?
            metadata.complete
            stop_early_upload(stream, upload)
          else
            monitor_response(
              stream,
              metadata,
              upload,
              cancellation,
              stop_upload_on_end: !request.connect ||
                                  !(200..299).includes?(parsed.status)
            )
          end
          return Response.new(
            parsed.status,
            parsed.headers,
            informational,
            stream,
            metadata,
            @timeouts.idle,
            cancellation
          )
        when Frame::Priority
          # Legacy priority information has no HTTP response semantics.
        else
          raise Connection::InvalidStateError.new(
            "unexpected event while waiting for a response"
          )
        end
      end
    end

    private def start_connect_upload(
      stream : Stream,
      request : PreparedRequest,
      status : Int32,
      response_ended : Bool,
      upload : UploadState,
      cancellation : Cancellation?,
    ) : Nil
      return unless request.connect && request.body

      if (200..299).includes?(status) && !response_ended
        spawn_upload(stream, request, upload, cancellation)
      else
        check_cancellation!(cancellation)
        stream.send_data(Bytes.empty, end_stream: true)
        upload.complete
      end
    end

    # Drains response metadata (trailers, or the bare remote end) after
    # response headers arrive. While `@timeouts.idle` is set, each wait
    # also carries that deadline: on expiry, if the body currently holds
    # unread buffered bytes AND none were read since the previous check,
    # the response is treated as abandoned and its stream is canceled —
    # credit for those buffered bytes returned, RST_STREAM sent, and the
    # body given a terminal error so a later read raises that specific
    # error (e.g. `RequestTimeoutError` here). A caller's own
    # `Response#close` also makes a later read raise rather than return a
    # silent EOF, but with a generic `IO::Error` ("Closed stream") instead
    # of a stream's own terminal error — library-initiated reclamation
    # stays distinguishable from the caller's own `Response#close` by
    # exception type, not by whether reading raises at all. A quiet
    # stream with an EMPTY buffer — an SSE or long-poll response between
    # events, a quiet CONNECT tunnel while
    # the app uploads — pins no credit and is left running indefinitely,
    # matching `Timeouts`' documented "never killed merely for going
    # quiet" contract. Any consumption between checks re-arms the
    # deadline instead, so a reader that is merely slow is never killed
    # (see `Client::Timeouts#idle`'s doc comment).
    private def monitor_response(
      stream : Stream,
      metadata : ResponseMetadata,
      upload : UploadState,
      cancellation : Cancellation?,
      *,
      stop_upload_on_end : Bool,
    ) : Nil
      idle = @timeouts.idle
      spawn do
        begin
          consumed_at_last_check = stream.body.consumed_bytes
          loop do
            begin
              event = stream.receive_until_remote_end(
                cancellation.try(&.signal),
                idle
              )
            rescue Connection::TimeoutError
              # `Connection::TimeoutError` covers two DIFFERENT
              # situations that share nothing but a common ancestor:
              # (1) the wait itself timed out (`idle` elapsed) while
              # the stream is still perfectly healthy -- the case the
              # buffered-bytes check below exists for, where looping
              # back to wait again is exactly the intended "never
              # killed merely for going quiet" behavior; and (2) the
              # STREAM has been terminated for a reason unrelated to
              # this wait (e.g. `Connection::DrainTimeoutError` from
              # `#graceful_close`, or `Connection::KeepaliveTimeoutError`
              # from a dead peer) that HAPPENS to subclass
              # `Connection::TimeoutError` too, surfaced here via
              # `Stream#raise_terminal!`. Looping back in case (2) does
              # NOT wait again -- `@terminal_signal` is already and
              # permanently closed, so the next `#receive_until_remote_end`
              # call raises the identical error immediately, with no
              # blocking operation in between: an infinite, non-yielding
              # loop that starves every other fiber in the process (not
              # merely this request). `stream.terminal_error` is the
              # authoritative signal distinguishing the two: only
              # `raise_terminal!` (case 2) sets it before raising; a bare
              # wait timeout (case 1) never does.
              if terminal = stream.terminal_error
                metadata.fail(terminal)
                break
              end

              consumed_now = stream.body.consumed_bytes
              if consumed_now != consumed_at_last_check
                consumed_at_last_check = consumed_now
                next
              end
              next if stream.body.buffered_bytes.zero?

              abandoned = RequestTimeoutError.new(
                "response was abandoned (never read, never closed) " \
                "and its stream was canceled after being idle with " \
                "unread buffered data"
              )
              metadata.fail(abandoned)
              abort_stream(stream, abandoned)
              break
            end

            unless event
              metadata.complete
              stop_early_upload(stream, upload) if stop_upload_on_end
              break
            end

            case event
            when Connection::FieldSection
              trailers = HTTPSemantics.validate_trailers(
                event.fields,
                stream.id
              )
              metadata.complete(trailers)
              stop_early_upload(stream, upload) if stop_upload_on_end
              break
            when Frame::Priority
              # Ignore deprecated priority metadata.
            else
              raise Connection::InvalidStateError.new(
                "unexpected response metadata event"
              )
            end
          end
        rescue Stream::WaitCanceledError
          canceled = RequestCanceledError.new("HTTP/2 request was canceled")
          metadata.fail(canceled)
          abort_stream(stream, canceled)
        rescue error
          metadata.fail(error)
        end
      end
    end

    # Stops an upload that is still in flight after its response has
    # already COMPLETED (informational responses aside, the final status
    # plus any trailers/remote end have all already arrived). The reset
    # this sends therefore carries NO_ERROR, not CANCEL: nothing was
    # cancelled — the response finished normally, and the still-sending
    # request body is simply moot from this point on. Contrast
    # `#abort_stream`'s CANCEL default, used by every OTHER caller for a
    # genuine timeout, cancellation, or protocol error.
    private def stop_early_upload(
      stream : Stream,
      upload : UploadState,
    ) : Nil
      return if upload.done?

      unless stream.body.completed?
        stream.body.completion_signal.receive?
      end
      abort_stream(
        stream,
        EarlyResponseStop.new("response completed before request upload"),
        ErrorCode::NO_ERROR
      )
    end

    private def abort_stream(
      stream : Stream,
      error : Exception,
      error_code : ErrorCode = ErrorCode::CANCEL,
    ) : Nil
      stream.abort(error, error_code)
    rescue error : Connection::InvalidStateError
      raise error unless stream.closed? || stream.terminal_error
    end

    private def token_byte?(byte : UInt8) : Bool
      byte.unsafe_chr.ascii_alphanumeric? || byte.in?(
        '!'.ord.to_u8,
        '#'.ord.to_u8,
        '$'.ord.to_u8,
        '%'.ord.to_u8,
        '&'.ord.to_u8,
        '\''.ord.to_u8,
        '*'.ord.to_u8,
        '+'.ord.to_u8,
        '-'.ord.to_u8,
        '.'.ord.to_u8,
        '^'.ord.to_u8,
        '_'.ord.to_u8,
        '`'.ord.to_u8,
        '|'.ord.to_u8,
        '~'.ord.to_u8
      )
    end

    # :nodoc:
    class UploadState
      @done = false
      @mutex = Mutex.new

      def complete : Nil
        @mutex.synchronize do
          return if @done

          @done = true
        end
      end

      def done? : Bool
        @mutex.synchronize { @done }
      end
    end

    # :nodoc:
    class EarlyResponseStop < Exception
    end
  end
end
