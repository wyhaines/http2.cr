require "uri"
require "set"
require "./cancellation"
require "./connection"
require "./http_semantics"
require "./request"
require "./response"

module HTTP2
  # A reusable, origin-bound HTTP/2 client.
  class Client
    class ClosedError < HTTPError
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
    # `stream_slot` governs `request`'s reaction to the peer's
    # MAX_CONCURRENT_STREAMS limit. `nil` (the default) preserves
    # `Connection#new_stream`'s existing contract: hitting the limit
    # raises `Connection::ConcurrentStreamLimitError` immediately, with no
    # wait. A span instead waits up to that long for a slot — waking
    # promptly when some other stream on the connection closes, not just
    # polling — retrying until either a slot opens up (the request
    # proceeds normally) or the span elapses, at which point the same
    # `Connection::ConcurrentStreamLimitError` is raised. A configured
    # wait holds this `Client`'s internal stream-open serialization for
    # its full span: every other `request` call on the SAME `Client` —
    # even one that will dial or is bound to a different connection —
    # queues behind it until the wait resolves.
    #
    # **Limitation when a `Connection` is shared by more than one
    # opener** (more than one `Client` bound to it, or raw `Connection`
    # use alongside a `Client`): a freed slot can be won by a DIFFERENT
    # opener first. RFC 9113 requires locally opened stream IDs to
    # increase, so that opener's higher-ID stream implicitly closes
    # ("skips") this request's still-reserved, lower-ID one. `request`
    # detects this — surfaced internally as `Connection::ClosedError`
    # ("stream N was skipped by stream M") or, rarely,
    # `Connection::InvalidStateError` ("stream N is not active on this
    # connection") — and recovers by reserving a fresh stream and
    # retrying, within the same `stream_slot` budget, exactly as if it
    # had lost the original wait. This recovery itself races the other
    # opener for the NEXT freed slot, so under sustained multi-opener
    # contention on one `Connection`, `request` is not guaranteed to win
    # eventually within a bounded number of retries — only that it never
    # hangs or corrupts connection state: it always either succeeds or
    # raises once its own `stream_slot` budget is exhausted. A single
    # `Client` per `Connection` (the common case; sharing one `Connection`
    # across `Client`s is unusual) never hits this at all, since
    # `request` calls on the SAME `Client` are already serialized against
    # each other and cannot skip themselves.
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

    # One in-flight owned-connection dial shared by every concurrent caller.
    # Completion is always performed while the client's mutex is held, so the
    # error assignment and idempotence check do not need their own lock.
    private class DialAttempt
      getter error : Exception? = nil
      getter signal = Channel(Nil).new

      def complete(error : Exception? = nil) : Nil
        return if @signal.closed?

        @error = error
        @signal.close
      end

      def wait : Nil
        @signal.receive?
        if failure = error
          raise failure
        end
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

    getter timeouts : Timeouts
    getter connection_configuration : Connection::Configuration
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
    @connection : Connection?
    @retired_connections = [] of Connection
    @dial_attempt : DialAttempt?
    @supplied_connection : Bool
    @closed = false
    @mutex = Mutex.new
    @stream_open_mutex = Mutex.new

    # Creates a client bound to one `http` or `https` origin. A supplied
    # connection is used as-is and is owned by this client.
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
      @connection = connection
      @supplied_connection = !connection.nil?
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
      connection = ready_connection
      check_cancellation!(cancellation)
      has_content = !prepared.body.nil? || !prepared.trailers.empty?
      stream = open_request_stream(
        connection,
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

    # Closes the reusable origin connection and cancels unfinished requests.
    def close : Nil
      connections = take_connections_for_close
      connections.each(&.close)
    end

    # Gracefully drains all connections currently owned by this client.
    #
    # `timeout` is a SHARED deadline across every connection, not a
    # per-connection budget: it is applied once, up front, and each
    # connection in turn receives only whatever of it remains (floored
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

      connections = take_connections_for_close
      deadline = Time.instant + timeout
      first_error = nil
      connections.each do |connection|
        begin
          remaining = deadline - Time.instant
          remaining = MIN_GRACEFUL_CLOSE_TIMEOUT if remaining < MIN_GRACEFUL_CLOSE_TIMEOUT
          connection.graceful_close(remaining)
        rescue error
          first_error ||= error
        end
      end
      raise first_error if first_error
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

    private def open_request_stream(
      connection : Connection,
      request_method : String,
      fields : Array(HeaderField),
      *,
      end_stream : Bool,
      cancellation : Cancellation?,
    ) : Stream
      @stream_open_mutex.synchronize do
        check_cancellation!(cancellation)
        stream = reserve_request_stream(connection)
        begin
          stream.inbound_validator = ResponseValidator.new(
            stream.id,
            request_method
          )
          stream = send_headers_awaiting_slot(
            connection,
            stream,
            request_method,
            fields,
            end_stream,
            cancellation
          )
          check_cancellation!(cancellation)
          stream
        rescue error : Connection::TimeoutError
          timed_out = RequestTimeoutError.new(
            "HTTP/2 connection timed out while opening the request",
            error
          )
          abort_stream(stream, timed_out)
          raise timed_out
        rescue error : IO::TimeoutError
          timed_out = RequestTimeoutError.new(
            "network I/O timed out while opening the request",
            error
          )
          abort_stream(stream, timed_out)
          raise timed_out
        rescue error
          abort_stream(stream, error) unless stream.terminal_error
          raise error
        end
      end
    end

    # Reserves a stream before any request bytes are submitted. If the
    # selected owned connection closes in the narrow gap after
    # `#ready_connection` checked it, preserving the ordinary connection
    # error as `PreRequestConnectionError` lets `#request` safely select a
    # replacement once. Errors after this method returns are deliberately
    # not wrapped: HEADERS may already have reached the peer by then, so the
    # normal explicit replay policy must remain authoritative.
    private def reserve_request_stream(connection : Connection) : Stream
      connection.new_stream
    rescue error : Connection::DrainingError
      raise error
    rescue error
      if !@supplied_connection && connection.closed?
        raise PreRequestConnectionError.new(error)
      end
      raise error
    end

    # Sends `stream`'s request HEADERS, waiting for a peer-imposed
    # concurrent-stream slot when `Timeouts#stream_slot` is set, and
    # returns the stream HEADERS were actually sent on (see below — it
    # may differ from the `stream` argument). The default (`nil`)
    # preserves `Connection#new_stream`'s immediate
    # `Connection::ConcurrentStreamLimitError` raise. A span retries
    # `#send_headers` each time the connection signals that some stream
    # may have closed, or the wait times out, until either it succeeds or
    # the span elapses — at which point the limit error from the final
    # attempt propagates.
    #
    # Normally the retry reuses the SAME (still-idle) stream, keeping its
    # reserved ID and place in line stable. But when a `Connection` is
    # shared by more than one opener (more than one `Client`, or raw
    # `Connection` use alongside a `Client`), a DIFFERENT opener can win a
    # freed slot first with a higher stream ID — RFC 9113 requires locally
    # opened stream IDs to increase, so opening that higher ID implicitly
    # closes ("skips") this method's still-idle lower one out from under
    # it (`Connection#new_stream`'s doc). `plan_skipped_local_streams_unlocked`
    # stores a bare `Connection::ClosedError` as that skipped stream's
    # terminal error EAGERLY — the instant the OTHER opener's HEADERS are
    # planned, not lazily discovered later — so the COMMON outcome here is
    # this waiter's own next `#send_headers` call raising that
    # `ClosedError` straight out of `Stream#send_headers`'s own
    # `raise_terminal!` guard, before `Connection#send_headers` even runs.
    # A rarer race (both commands already enqueued at once) instead raises
    # a bare `Connection::InvalidStateError` ("stream N is not active")
    # from `Connection#plan_outbound_stream_event_unlocked`. Both are
    # handled identically below (see `recoverable_stream_skip?`):
    # allocating a fresh stream and retrying it (within the same
    # remaining budget) recovers instead of surfacing a hard,
    # non-replayable error for what is, from the caller's perspective,
    # still just "waiting for a slot."
    private def send_headers_awaiting_slot(
      connection : Connection,
      stream : Stream,
      request_method : String,
      fields : Array(HeaderField),
      end_stream : Bool,
      cancellation : Cancellation?,
    ) : Stream
      current = stream
      deadline = @timeouts.stream_slot.try { |span| Time.instant + span }
      loop do
        begin
          current.send_headers(fields, end_stream: end_stream)
          return current
        rescue error : Connection::ConcurrentStreamLimitError
          remaining = remaining_stream_slot_budget(deadline, error)
          check_cancellation!(cancellation)
          connection.wait_for_stream_slot(
            remaining,
            cancellation.try(&.signal)
          )
          check_cancellation!(cancellation)
        rescue error : Connection::ClosedError | Connection::InvalidStateError
          raise error unless recoverable_stream_skip?(
                               connection,
                               current,
                               deadline,
                               error
                             )
          remaining_stream_slot_budget(deadline, error)

          check_cancellation!(cancellation)
          current = connection.new_stream
          current.inbound_validator = ResponseValidator.new(
            current.id,
            request_method
          )
        end
      end
    rescue error
      abort_leftover_stream_slot_attempt(current, stream, error)
      raise error
    end

    # Whether `current`'s HEADERS attempt was refused not because the
    # peer's concurrent-stream limit is still exhausted, but because a
    # DIFFERENT opener on a shared `Connection` already won a freed slot
    # with a higher stream ID, implicitly skipping `current` out from
    # under this wait (see the doc comment above).
    #
    # Matches only the two BARE error classes the skip/rare-race paths
    # actually raise — `error.class ==`, not `#is_a?`, deliberately, so
    # every SUBCLASS is excluded: a `DrainingError` (`< InvalidStateError`),
    # a peer GOAWAY (`UnprocessedStreamError`), an explicit cancel
    # (`CanceledError`), a peer reset (`StreamResetError`), or a
    # successfully completed drain (`DrainedError` — despite the name,
    # NOT the timeout case; `DrainTimeoutError < TimeoutError` isn't
    # reachable here at all, since it isn't a `ClosedError`/
    # `InvalidStateError` subclass in the first place) must all still
    # propagate untouched — reallocating into any of those would spin
    # against a connection that will accept no further streams, or (for
    # `CanceledError`/`StreamResetError`, which can occur on an
    # otherwise perfectly live connection) simply retry a request that
    # was already explicitly torn down.
    #
    # The connection-state check below is not simply a belt-and-
    # suspenders duplicate of the exact-class check above: `error.class
    # ==` cannot, on its own, tell a genuine skip's
    # `ClosedError` (from `plan_skipped_local_streams_unlocked`) apart
    # from `Connection#terminate`'s own bare `ClosedError` — e.g.
    # `#close`'s `ClosedError.new("HTTP/2 connection closed")` — both are
    # the identical class. Nor can the trailing
    # `connection.stream?(current.id).nil?` check: `#terminate` clears
    # `@streams` entirely BEFORE terminating each remaining stream, the
    # same order a genuine skip uses, so a waiter's own stream looks
    # exactly as "no longer registered" either way. `connection.closed?`
    # (set by `#terminate` before any of that) is what actually tells
    # them apart. `DrainingError` and `UnprocessedStreamError` similarly
    # coincide with `connection.draining?` (set before either is ever
    # raised), and `DrainedError` with `connection.closed?` (set by the
    # same `#terminate` call that raises it) — but all three are ALSO
    # distinct subclasses the exact-class check alone already excludes
    # on its own, so the state check is genuinely redundant, not
    # load-bearing, for those three specifically. Excluding them a
    # second, independent way anyway is deliberate defense in depth for
    # the ONE case above where it is not redundant, not evidence that
    # either check could safely be dropped.
    private def recoverable_stream_skip?(
      connection : Connection,
      current : Stream,
      deadline : Time::Instant?,
      error : Connection::Error,
    ) : Bool
      return false unless error.class == Connection::ClosedError ||
                          error.class == Connection::InvalidStateError
      return false unless deadline
      return false if connection.closed? || connection.draining?

      connection.stream?(current.id).nil?
    end

    private def remaining_stream_slot_budget(
      deadline : Time::Instant?,
      error : Exception,
    ) : Time::Span
      raise error unless deadline

      remaining = deadline - Time.instant
      raise error if remaining <= Time::Span.zero

      remaining
    end

    private def abort_leftover_stream_slot_attempt(
      current : Stream?,
      original : Stream,
      error : Exception,
    ) : Nil
      return unless leftover = current
      return if leftover.same?(original) || leftover.terminal_error

      abort_stream(leftover, error)
    end

    # Returns the connection to use for the next request, dialing a fresh
    # one if necessary. The dial itself (`#dial`'s connect-plus-TLS
    # handshake) deliberately runs OUTSIDE `@mutex` — it can take a
    # connect-timeout's worth of wall-clock time against a slow or
    # unresponsive origin, and holding `@mutex` for that whole span would
    # serialize `#close`/`#closed?` behind it.
    #
    # Exactly one caller owns an in-flight dial. Concurrent cold requests
    # wait on its `DialAttempt`, then re-check the published connection;
    # they do not perform duplicate TCP connects or TLS handshakes. A dial
    # failure is shared by those waiters as well, preventing a failed
    # attempt from immediately turning into a reconnect stampede. `#close`
    # completes the attempt with `Client::ClosedError`, so waiters wake
    # promptly even though the owning fiber's underlying socket operation
    # may still need its configured timeout to unwind.
    private def connection_for_request : Connection
      loop do
        attempt = nil
        dialer = false
        @mutex.synchronize do
          raise ClosedError.new("HTTP/2 client is closed") if @closed

          @retired_connections.reject!(&.closed?)
          if current = @connection
            return current unless current.closed? || current.draining?
            if @supplied_connection
              raise(
                current.terminal_error ||
                Connection::DrainingError.new(
                  "supplied HTTP/2 connection is draining or closed"
                )
              )
            end
            @retired_connections << current unless current.closed?
            @connection = nil
          end

          if pending = @dial_attempt
            attempt = pending
          else
            pending = DialAttempt.new
            @dial_attempt = pending
            attempt = pending
            dialer = true
          end
        end

        current_attempt = attempt ||
                          raise "connection selection omitted its dial attempt"
        unless dialer
          current_attempt.wait
          next
        end

        selected = begin
          publish_dialed_connection(dial)
        rescue error
          finish_dial_attempt(current_attempt, error)
          raise error
        end
        finish_dial_attempt(current_attempt)
        return selected
      end
    end

    private def finish_dial_attempt(
      attempt : DialAttempt,
      error : Exception? = nil,
    ) : Nil
      @mutex.synchronize do
        if current = @dial_attempt
          @dial_attempt = nil if current.same?(attempt)
        end
        attempt.complete(error)
      end
    end

    # Publishes a freshly-dialed connection as `@connection`, unless
    # `#close` landed while it was in flight. The existing-current branch
    # is defensive (and supports deterministic race probes); normal client
    # operation permits only one `DialAttempt`, so no second dialer can
    # publish a winner concurrently. A redundant connection is closed only
    # AFTER `@mutex` is released: `Connection#close` joins background
    # fibers, and a slow teardown must not wedge `#close`/`#closed?`.
    #
    # The `ensure`'s `redundant.try(&.close)` running after a `raise`
    # inside the `synchronize` block (the `@closed` branch) means that,
    # in the theoretical case where `Connection#close` itself raised, its
    # exception would replace/mask the `ClosedError` already propagating
    # rather than both surfacing. Accepted: `Connection#close` is
    # designed not to raise under normal operation (its own internals
    # guard/rescue around transport-close failures), and closing a
    # redundant connection that was never handed to any caller is not a
    # path a caller could otherwise observe or recover from differently.
    private def publish_dialed_connection(dialed : Connection) : Connection
      redundant = nil
      begin
        @mutex.synchronize do
          if @closed
            redundant = dialed
            raise ClosedError.new("HTTP/2 client is closed")
          end

          current = @connection
          if current && connection_still_usable?(current)
            redundant = dialed
            next current
          end

          @retired_connections << current if current && !current.closed?
          @connection = dialed
        end
      ensure
        redundant.try(&.close)
      end
    end

    private def connection_still_usable?(connection : Connection) : Bool
      !connection.closed? && !connection.draining?
    end

    private def ready_connection : Connection
      connection = connection_for_request
      begin
        connection.wait_until_active(@timeouts.read)
        connection
      rescue error : Connection::TimeoutError
        mapped = RequestTimeoutError.new(
          "waiting for the HTTP/2 handshake timed out",
          error
        )
        raise_ready_connection_error(connection, mapped)
      rescue error : IO::TimeoutError
        mapped = RequestTimeoutError.new(
          "connecting to the HTTP/2 origin timed out",
          error
        )
        raise_ready_connection_error(connection, mapped)
      rescue error
        raise_ready_connection_error(connection, error)
      end
    end

    # A closed connection cannot become ready later. Because no stream has
    # been reserved at this point, one replacement attempt is always safe,
    # even for non-idempotent requests and caller-owned body IO.
    private def raise_ready_connection_error(
      connection : Connection,
      error : Exception,
    ) : NoReturn
      if !@supplied_connection && connection.closed?
        raise PreRequestConnectionError.new(error)
      end
      raise error
    end

    # Dials a new connection. Neither branch passes `read_timeout:`: a
    # persistent socket-level read deadline would kill idle pooled
    # connections and quiet long-lived streams once active. The HTTP/2
    # handshake wait is instead bounded by `ready_connection`'s
    # `wait_until_active(@timeouts.read)` call above, and liveness after
    # that is keepalive's job, not a transport read timeout.
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

    private def take_connections_for_close : Array(Connection)
      @mutex.synchronize do
        next [] of Connection if @closed

        @closed = true
        if attempt = @dial_attempt
          @dial_attempt = nil
          attempt.complete(
            ClosedError.new("HTTP/2 client is closed")
          )
        end
        connections = @retired_connections
        if current = @connection
          connections << current
        end
        @retired_connections = [] of Connection
        @connection = nil
        connections.uniq!
        connections
      end
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
