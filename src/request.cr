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
    getter body : IO?
    getter body_length : Int64?

    @owned_body : Bytes?

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
        owned = body.to_slice.dup
        @owned_body = owned
        @body = IO::Memory.new(owned)
        @body_length = owned.size.to_i64
      when Bytes
        owned = body.dup
        @owned_body = owned
        @body = IO::Memory.new(owned)
        @body_length = owned.size.to_i64
      when IO
        @owned_body = nil
        @body = body
        @body_length = nil
      when Nil
        @owned_body = nil
        @body = nil
        @body_length = 0_i64
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

    # Whether the client can reproduce this body for a proven-unprocessed
    # retry. String and Bytes bodies are owned; caller-supplied IO is not.
    def replayable_body? : Bool
      @body.nil? || !@owned_body.nil?
    end

    # :nodoc:
    def body_for_attempt : IO?
      if owned = @owned_body
        IO::Memory.new(owned)
      else
        @body
      end
    end
  end
end
