require "mime/media_type"
{% if !flag?(:without_zlib) %}
  require "compress/deflate"
  require "compress/gzip"
{% end %}
require "uri"
require "http/cookie"
require "http/params"
require "socket"

module HTTP2
  class Request
    property headers : HTTP::Headers = HTTP::Headers.new
    property trailers : HTTP::Headers? = nil
    getter body : IO?
    property version : String = "2.0"
    @cookies : Cookies?
    @query_params : URI::Params?
    @uri : URI?
    alias RequestBody = String | Bytes | IO | Nil

    def self.new(headers : Headers = HTTP::Headers.new, body : RequestBody = nil, trailers : HTTP::Headers? = nil)
      new(headers.try(&.dup), body, trailers, internal: nil)
    end

    private def initialize(@headers, body, @trailers, internal : Nil)
      self.body = body
    end

    def body=(body : String | Bytes)
      @body = IO::Memory.new(body)
    end

    def body=(@body : IO); end

    def body=(@body : Nil)
      request_method = method
      @headers["Content-Length"] = "0" if request_method == "POST" || request_method == "PUT"
    end

    def method : String
      headers[":method"]?.to_s
    end

    def path : String
      headers[":path"]?.to_s
    end

    def scheme : String
      headers[":scheme"]?.to_s
    end

    def authority : String
      headers[":authority"]?.to_s
    end
  end
end
