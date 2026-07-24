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

    # Creates a request. `target` is an origin-form path, an absolute URI for
    # the same client origin, `*` for OPTIONS, or authority form for CONNECT.
    def initialize(
      @method : String,
      @target : String,
      @headers : Headers = Headers.new,
      body : Body = nil,
      @trailers : Headers = Headers.new,
    )
      case body
      when String
        @body = IO::Memory.new(body)
        @body_length = body.bytesize.to_i64
      when Bytes
        owned = body.dup
        @body = IO::Memory.new(owned)
        @body_length = owned.size.to_i64
      when IO
        @body = body
        @body_length = nil
      when Nil
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
  end
end
