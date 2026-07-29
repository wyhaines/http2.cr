require "./headers"

module HTTP2
  # One HTTP request. The client derives HTTP/2 pseudo-fields from the method,
  # target, and its origin; callers provide only regular fields.
  class Request
    alias Body = (String | Bytes | IO)?

    getter method : String
    getter target : String
    getter headers : Headers
    getter trailers : Headers
    getter body_length : Int64?

    # The backing bytes of a String/Bytes body, exposed so `Client`'s
    # upload fast path can hand them straight to `Stream#send_data`
    # without ever wrapping them in an `IO` -- not part of the public API.
    # :nodoc:
    getter owned_body : Bytes?

    @io_body : IO?
    @body_io : IO::Memory?

    # Creates a request. `target` is an origin-form path, an absolute URI for
    # the same client origin, `*` for OPTIONS, or authority form for CONNECT.
    #
    # An `IO` body (not a `String`/`Bytes` body, whose length is always
    # exactly known) combined with an explicit `content-length` header in
    # `headers` MUST report EOF (a `#read` returning `0`) at exactly that
    # declared length. The client verifies this by reading one byte past
    # the declared length before finishing the request, to reject a body
    # that silently runs longer than declared (`InvalidRequestError`)
    # instead of truncating it. That verification read is a real, blocking
    # `IO#read` call with no timeout of its own — a source that has
    # exactly `content-length` bytes available and then blocks instead of
    # returning `0` (e.g. a live socket or pipe with no more data queued
    # yet, rather than actually closed) blocks the upload indefinitely
    # instead of completing the request. `IO::Memory`, `File`, `IO::Sized`,
    # `HTTP::FixedLengthContent`, and similar EOF reliably at a declared
    # length and are unaffected; an `IO` body with **no** explicit
    # `content-length` header is read to EOF with no probe and is also
    # unaffected (CONNECT tunnel bodies always take this path, since
    # CONNECT forbids `content-length`).
    def initialize(
      @method : String,
      @target : String,
      @headers : Headers = Headers.new,
      body : Body = nil,
      @trailers : Headers = Headers.new,
    )
      case body
      when String
        # `String#to_slice` is a view over the string's own backing
        # storage, which a Crystal `String` never mutates in place --
        # no defensive dup is needed the way a caller-supplied `Bytes`
        # needs one below.
        @owned_body = body.to_slice
        @io_body = nil
        @body_length = body.bytesize.to_i64
      when Bytes
        # `Bytes` is caller-owned and mutable: dup so a caller mutating
        # their buffer after this call (or a retried request resending
        # it) can't change what gets sent.
        @owned_body = body.dup
        @io_body = nil
        @body_length = body.size.to_i64
      when IO
        @owned_body = nil
        @io_body = body
        @body_length = nil
      when Nil
        @owned_body = nil
        @io_body = nil
        @body_length = nil
      end
    end

    def initialize(
      method : String,
      target : String,
      headers : HTTP::Headers,
      body : Body = nil,
      trailers : HTTP::Headers? = nil,
    )
      initialize(
        method,
        target,
        Headers.new(headers),
        body,
        trailers ? Headers.new(trailers) : Headers.new
      )
    end

    # An `IO` view of the body, kept for API compatibility with callers
    # that want to read it as a stream. For an owned String/Bytes body
    # this wraps `@owned_body` in an `IO::Memory` only on first access,
    # then memoizes it -- `Client`'s upload fast path never calls this;
    # it reads `@owned_body` directly, so a request whose body is never
    # inspected via this getter never allocates the wrapper at all.
    def body : IO?
      @io_body || (@body_io ||= @owned_body.try { |b| IO::Memory.new(b) })
    end

    # Whether the client can reproduce this body for a proven-unprocessed
    # retry. String and Bytes bodies are owned; caller-supplied IO is not.
    def replayable_body? : Bool
      @io_body.nil?
    end

    # :nodoc:
    def body_for_attempt : IO?
      if owned = @owned_body
        IO::Memory.new(owned)
      else
        @io_body
      end
    end
  end
end
