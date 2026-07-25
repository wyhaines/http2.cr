require "uri"
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
    # reads, never closes. Its stream would otherwise sit open forever,
    # holding its monitor fiber and connection-window credit hostage and
    # potentially stalling every other request on the connection. Each
    # time `idle` elapses with no bytes consumed from `Response#body`
    # since the previous check, the response's stream is canceled exactly
    # as `Response#close` would (flow-control credit returned, RST_STREAM
    # sent); if any bytes WERE consumed in that window, the deadline
    # simply re-arms, so a slow-but-active reader is never killed. Set
    # `idle: nil` to disable this safety net along with the per-read/
    # trailer timeout it shares the setting with.
    #
    # `stream_slot` governs `request`'s reaction to the peer's
    # MAX_CONCURRENT_STREAMS limit. `nil` (the default) preserves
    # `Connection#new_stream`'s existing contract: hitting the limit
    # raises `Connection::ConcurrentStreamLimitError` immediately, with no
    # wait. A span instead waits up to that long for a slot — waking
    # promptly when some other stream on the connection closes, not just
    # polling — retrying until either a slot opens up (the request
    # proceeds normally) or the span elapses, at which point the same
    # `Connection::ConcurrentStreamLimitError` is raised.
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

    getter timeouts : Timeouts
    getter connection_configuration : Connection::Configuration
    getter replay_policy : ReplayPolicy
    getter max_replay_attempts : Int32

    @origin : Origin
    @connection : Connection?
    @retired_connections = [] of Connection
    @supplied_connection : Bool
    @closed = false
    @mutex = Mutex.new
    @stream_open_mutex = Mutex.new

    # Creates a client bound to one `http` or `https` origin. A supplied
    # connection is used as-is and is owned by this client.
    def initialize(
      origin : String | URI,
      *,
      @timeouts : Timeouts = Timeouts.new,
      @connection_configuration : Connection::Configuration = DEFAULT_CONNECTION_CONFIGURATION,
      @tls_context : OpenSSL::SSL::Context::Client = OpenSSL::SSL::Context::Client.new,
      @replay_policy : ReplayPolicy = ReplayPolicy::Never,
      @max_replay_attempts : Int32 = 1,
      connection : Connection? = nil,
    )
      if @max_replay_attempts < 0
        raise ArgumentError.new(
          "maximum replay attempt count cannot be negative"
        )
      end
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

    # Builds and sends a request for any HTTP method.
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
      draining_retries = 0
      loop do
        begin
          return perform_request(request, cancellation)
        rescue error : Connection::DrainingError
          draining_retries += 1
          raise error if @supplied_connection || draining_retries > 1
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
    def graceful_close(
      timeout : Time::Span = @connection_configuration.drain_timeout,
    ) : Nil
      if timeout <= Time::Span.zero
        raise ArgumentError.new("drain timeout must be positive")
      end

      connections = take_connections_for_close
      first_error = nil
      connections.each do |connection|
        begin
          connection.graceful_close(timeout)
        rescue error
          first_error ||= error
        end
      end
      raise first_error if first_error
    end

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
        stream = connection.new_stream
        begin
          stream.inbound_validator = ResponseValidator.new(
            stream.id,
            request_method
          )
          send_headers_awaiting_slot(
            connection,
            stream,
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

    # Sends `stream`'s request HEADERS, waiting for a peer-imposed
    # concurrent-stream slot when `Timeouts#stream_slot` is set. The
    # default (`nil`) preserves `Connection#new_stream`'s immediate
    # `Connection::ConcurrentStreamLimitError` raise. A span retries
    # `#send_headers` on the SAME (still-idle) stream each time the
    # connection signals that some stream may have closed, or the wait
    # times out, until either it succeeds or the span elapses — at which
    # point the limit error from the final attempt propagates. Reusing
    # `stream` rather than allocating a new one on each attempt keeps the
    # stream's reserved ID (and its place in line) stable across retries.
    private def send_headers_awaiting_slot(
      connection : Connection,
      stream : Stream,
      fields : Array(HeaderField),
      end_stream : Bool,
      cancellation : Cancellation?,
    ) : Nil
      deadline = @timeouts.stream_slot.try { |span| Time.instant + span }
      loop do
        begin
          stream.send_headers(fields, end_stream: end_stream)
          return
        rescue error : Connection::ConcurrentStreamLimitError
          raise error unless deadline

          remaining = deadline - Time.instant
          raise error if remaining <= Time::Span.zero

          check_cancellation!(cancellation)
          connection.wait_for_stream_slot(
            remaining,
            cancellation.try(&.signal)
          )
          check_cancellation!(cancellation)
        end
      end
    end

    private def connection_for_request : Connection
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

        @connection = dial
      end
    end

    private def ready_connection : Connection
      connection = connection_for_request
      connection.wait_until_active(@timeouts.read)
      connection
    rescue error : Connection::TimeoutError
      raise RequestTimeoutError.new(
        "waiting for the HTTP/2 handshake timed out",
        error
      )
    rescue error : IO::TimeoutError
      raise RequestTimeoutError.new(
        "connecting to the HTTP/2 origin timed out",
        error
      )
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
        pseudo_fields << HeaderField.new(":path", path)
      end
      pseudo_fields.concat(headers.to_header_fields)

      PreparedRequest.new(
        pseudo_fields,
        request.trailers.to_header_fields,
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
        final = sent == body_length
        stream.send_data(
          buffer[0, size],
          end_stream: final && trailers.empty?
        )
      end
      if body_length.zero?
        finish_request_content(stream, trailers)
      elsif !trailers.empty?
        stream.send_headers(trailers, end_stream: true)
      end
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
    # also carries that deadline: on expiry, a `Response` that has had no
    # bytes read from its body since the previous check is treated as
    # abandoned and its stream is canceled exactly as `Response#close`
    # would (flow-control credit returned, RST_STREAM sent) — otherwise
    # this fiber, and the window credit its stream holds, would leak for
    # as long as the connection lives. Any consumption between checks
    # re-arms the deadline instead, so a reader that is merely slow is
    # never killed (see `Client::Timeouts#idle`'s doc comment).
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
              consumed_now = stream.body.consumed_bytes
              if consumed_now != consumed_at_last_check
                consumed_at_last_check = consumed_now
                next
              end

              stream.body.close
              metadata.fail(
                RequestTimeoutError.new(
                  "response was abandoned (never read, never closed) " \
                  "and its stream was canceled after being idle"
                )
              )
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
        EarlyResponseStop.new("response completed before request upload")
      )
    end

    private def abort_stream(stream : Stream, error : Exception) : Nil
      stream.abort(error)
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
