require "./cancellation"
require "./connection"
require "./headers"
require "./http_errors"

module HTTP2
  record InformationalResponse, status : Int32, headers : Headers

  # A streaming HTTP response. Consume or close `body` before waiting for
  # trailers so flow control can continue.
  class Response
    getter status : Int32
    getter headers : Headers
    getter informational_responses : Array(InformationalResponse)
    getter body : IO
    getter stream_id : UInt32

    @metadata : ResponseMetadata
    @stream : Stream
    @cancellation : Cancellation?
    @idle_timeout : Time::Span?

    # :nodoc:
    def initialize(
      @status : Int32,
      @headers : Headers,
      @informational_responses : Array(InformationalResponse),
      @stream : Stream,
      @metadata : ResponseMetadata,
      @idle_timeout : Time::Span?,
      @cancellation : Cancellation?,
    )
      @stream_id = @stream.id
      @body = ResponseBody.new(
        @stream,
        @idle_timeout,
        @cancellation
      )
    end

    # Waits for the response trailer section. An empty collection means that
    # the response ended without trailers.
    def trailers(timeout : Time::Span? = @idle_timeout) : Headers
      @metadata.wait(timeout, @cancellation.try(&.signal))
    rescue ResponseMetadata::WaitTimeoutError
      request_error = RequestTimeoutError.new(
        "waiting for response trailers timed out"
      )
      abort_request(request_error)
      raise request_error
    rescue error : IO::TimeoutError
      request_error = RequestTimeoutError.new(
        "network read timed out while waiting for response trailers",
        error
      )
      abort_request(request_error)
      raise request_error
    rescue ResponseMetadata::WaitCanceledError
      request_error = RequestCanceledError.new(
        "waiting for response trailers was canceled"
      )
      abort_request(request_error)
      raise request_error
    end

    # Stops consuming the response without attaching a request-specific
    # error. Discards any buffered body bytes (returning their
    # flow-control credit) and, unless the stream already reached a
    # natural end, sends RST_STREAM to cancel it — but does not record a
    # terminal error for that reset: a later `#body` read raises only a
    # generic `IO::Error` ("Closed stream"), not a stream's own terminal
    # error, which keeps a caller's own graceful stop distinguishable
    # from `#cancel` and from a library-initiated reclamation (see
    # `Client::Timeouts#idle`) by exception type. Safe to call more than
    # once, or after the body has already finished.
    def close : Nil
      @body.close
    end

    # Cancels the request outright: sends RST_STREAM and fails the
    # stream with a `RequestCanceledError`, so — unlike `#close` — a
    # later `#body` read or `#trailers` wait raises that same error
    # instead of a generic `IO::Error`. Safe to call more than once, or
    # after the stream has already closed.
    def cancel : Nil
      error = RequestCanceledError.new("HTTP/2 request was canceled")
      abort_request(error)
    end

    private def abort_request(error : Exception) : Nil
      @stream.abort(error)
    rescue error : Connection::InvalidStateError
      raise error unless @stream.closed? || @stream.terminal_error
    end
  end

  # :nodoc:
  class ResponseBody < IO
    def initialize(
      @stream : Stream,
      @idle_timeout : Time::Span?,
      @cancellation : Cancellation?,
    )
    end

    def read(slice : Bytes) : Int32
      return 0 if slice.empty?

      if @cancellation.try(&.canceled?)
        error = RequestCanceledError.new("response body read was canceled")
        abort_request(error)
        raise error
      end

      @stream.body.read_with_timeout(
        slice,
        @idle_timeout,
        @cancellation.try(&.signal)
      )
    rescue StreamBody::ReadTimeoutError
      error = RequestTimeoutError.new("response body read timed out")
      abort_request(error)
      raise error
    rescue error : IO::TimeoutError
      request_error = RequestTimeoutError.new(
        "network read timed out while reading the response body",
        error
      )
      abort_request(request_error)
      raise request_error
    rescue StreamBody::ReadCanceledError
      error = RequestCanceledError.new("response body read was canceled")
      abort_request(error)
      raise error
    end

    def write(slice : Bytes) : NoReturn
      raise IO::Error.new("HTTP/2 response bodies are read-only")
    end

    def close : Nil
      @stream.body.close
    end

    def closed? : Bool
      @stream.body.closed?
    end

    private def abort_request(error : Exception) : Nil
      @stream.abort(error)
    rescue error : Connection::InvalidStateError
      raise error unless @stream.closed? || @stream.terminal_error
    end
  end

  # :nodoc:
  class ResponseMetadata
    class WaitTimeoutError < Exception
    end

    class WaitCanceledError < Exception
    end

    @trailers : Headers?
    @error : Exception?
    @done = false
    @signal = Channel(Nil).new
    @mutex = Mutex.new

    def complete(trailers : Headers = Headers.new) : Nil
      changed = @mutex.synchronize do
        next false if @done

        @trailers = trailers
        @done = true
        true
      end
      @signal.close if changed
    end

    def fail(error : Exception) : Nil
      changed = @mutex.synchronize do
        next false if @done

        @error = error
        @done = true
        true
      end
      @signal.close if changed
    end

    def wait(
      timeout : Time::Span?,
      cancellation : Channel(Nil)?,
    ) : Headers
      unless done?
        wait_for_completion(timeout, cancellation)
      end

      trailers, error = @mutex.synchronize { {@trailers, @error} }
      raise error if error
      trailers || Headers.new
    end

    private def done? : Bool
      @mutex.synchronize { @done }
    end

    private def wait_for_completion(
      duration : Time::Span?,
      cancellation : Channel(Nil)?,
    ) : Nil
      if duration && cancellation
        select
        when @signal.receive?
        when cancellation.receive?
          raise WaitCanceledError.new
        when timeout(duration)
          raise WaitTimeoutError.new
        end
      elsif duration
        select
        when @signal.receive?
        when timeout(duration)
          raise WaitTimeoutError.new
        end
      elsif cancellation
        select
        when @signal.receive?
        when cancellation.receive?
          raise WaitCanceledError.new
        end
      else
        @signal.receive?
      end
    end
  end
end
