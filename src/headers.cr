require "http/headers"
require "hpack"
require "./header_field"

module HTTP2
  # One application-facing HTTP field. Field order and repeated names are
  # preserved by `Headers`.
  record Header, name : String, value : String

  # An ordered, duplicate-preserving collection of HTTP fields.
  class Headers
    include Enumerable(Header)

    @fields = [] of Header

    def initialize
    end

    def initialize(fields : Enumerable(Header))
      fields.each { |field| @fields << field }
    end

    def initialize(fields : Enumerable(Tuple(String, String)))
      fields.each { |name, value| @fields << Header.new(name, value) }
    end

    # `HTTP::Headers` field names are case-insensitive (RFC 9110 §5.1) but
    # HTTP/2 requires lowercase on the wire (RFC 9113 §8.2.1); downcasing
    # here is lossless and lets stdlib-interop callers pass mixed-case names
    # without tripping outbound validation. Values are untouched.
    def initialize(fields : HTTP::Headers)
      fields.each do |name, values|
        downcased_name = name.downcase
        values.each { |value| @fields << Header.new(downcased_name, value) }
      end
    end

    def each(& : Header ->) : Nil
      @fields.each { |field| yield field }
    end

    # Appends a field without replacing existing fields of the same name.
    def add(name : String, value : String) : self
      @fields << Header.new(name, value)
      self
    end

    def []=(name : String, value : String) : String
      delete(name)
      add(name, value)
      value
    end

    # Returns the first field value with exactly matching lowercase name.
    def [](name : String) : String
      self[name]? || raise KeyError.new("missing HTTP field #{name.inspect}")
    end

    def []?(name : String) : String?
      @fields.find { |field| field.name == name }.try(&.value)
    end

    # Returns every value with exactly matching lowercase name, in wire order.
    def get_all(name : String) : Array(String)
      @fields.compact_map do |field|
        field.value if field.name == name
      end
    end

    def has_key?(name : String) : Bool
      @fields.any? { |field| field.name == name }
    end

    def delete(name : String) : Nil
      @fields.reject! { |field| field.name == name }
    end

    def empty? : Bool
      @fields.empty?
    end

    def size : Int32
      @fields.size
    end

    def to_a : Array(Header)
      @fields.dup
    end

    def dup : self
      self.class.new(@fields)
    end

    def ==(other : Headers) : Bool
      @fields == other.@fields
    end

    def hash(hasher)
      @fields.hash(hasher)
    end

    def to_http_headers : HTTP::Headers
      result = HTTP::Headers.new
      each { |field| result.add(field.name, field.value) }
      result
    end

    # :nodoc:
    #
    # Ordinary fields opt into HPACK incremental indexing (RFC 7541 6.2.1),
    # letting them enter the connection's dynamic table so a repeated field
    # compresses to an indexed reference on a later request. Credential and
    # cookie fields are the confidentiality boundary this creates: they are
    # marked `Never` so the HPACK encoder emits them as a literal-never-
    # indexed representation (RFC 7541 6.2.3) and never inserts them into
    # the dynamic table, on the first request or any later one.
    def to_header_fields : Array(HeaderField)
      @fields.map do |field|
        indexing = case field.name
                   when "authorization", "proxy-authorization", "cookie", "set-cookie"
                     HeaderField::Indexing::Never
                   else
                     HeaderField::Indexing::Incremental
                   end
        HeaderField.new(field.name, field.value, indexing: indexing)
      end
    end

    # :nodoc:
    def self.from_decoded(fields : Enumerable(DecodedHeaderField)) : self
      headers = new
      fields.each do |field|
        headers.add(field.name, field.value)
      end
      headers
    end
  end
end
