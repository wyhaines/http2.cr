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

    # Per-operation deadlines. Nil disables the corresponding timeout.
    #
    # `connect` covers DNS and TCP dialing, `read` covers transport reads and
    # response-header waits, `write` covers transport writes, and `idle`
    # covers a blocked response-body read or trailer wait.
    struct Timeouts
      getter connect : Time::Span?
      getter read : Time::Span?
      getter write : Time::Span?
      getter idle : Time::Span?

      def initialize(
        @connect : Time::Span? = 10.seconds,
        @read : Time::Span? = 30.seconds,
        @write : Time::Span? = 30.seconds,
        @idle : Time::Span? = 30.seconds,
      )
        {
          "connect" => @connect,
          "read"    => @read,
          "write"   => @write,
          "idle"    => @idle,
        }.each do |name, duration|
          if duration && duration <= Time::Span.zero
            raise ArgumentError.new("#{name} timeout must be positive")
          end
        end
      end
    end

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

    @origin : Origin
    @connection : Connection?
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
      @connection_configuration : Connection::Configuration = Connection::Configuration.new,
      @tls_context : OpenSSL::SSL::Context::Client = OpenSSL::SSL::Context::Client.new,
      connection : Connection? = nil,
    )
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
      body : Request::Body = nil,
      headers : Headers = Headers.new,
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
      connection = @mutex.synchronize do
        next if @closed

        @closed = true
        current = @connection
        @connection = nil
        current
      end
      connection.try(&.close)
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
          stream.send_headers(fields, end_stream: end_stream)
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

    private def connection_for_request : Connection
      @mutex.synchronize do
        raise ClosedError.new("HTTP/2 client is closed") if @closed

        if current = @connection
          return current unless current.closed?
          if @supplied_connection
            raise(
              current.terminal_error ||
              ClosedError.new("supplied HTTP/2 connection is closed")
            )
          end
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

    private def dial : Connection
      case @origin.scheme
      when "http"
        Connection.connect_prior_knowledge(
          @origin.host,
          @origin.port,
          @connection_configuration,
          connect_timeout: @timeouts.connect,
          read_timeout: @timeouts.read,
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
          read_timeout: @timeouts.read,
          write_timeout: @timeouts.write
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
        request.body,
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

    private def monitor_response(
      stream : Stream,
      metadata : ResponseMetadata,
      upload : UploadState,
      cancellation : Cancellation?,
      *,
      stop_upload_on_end : Bool,
    ) : Nil
      spawn do
        begin
          loop do
            event = stream.receive_until_remote_end(
              cancellation.try(&.signal)
            )
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
