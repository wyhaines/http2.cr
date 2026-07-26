require "http/headers"
require "hpack"
require "set"
require "./header_field"

module HTTP2
  # One application-facing HTTP field. Field order and repeated names are
  # preserved by `Headers`.
  record Header, name : String, value : String

  # An ordered, duplicate-preserving collection of HTTP fields.
  class Headers
    include Enumerable(Header)

    # Field names whose value must never be promoted to HPACK's compressed,
    # indexed representation (RFC 7541 §6.2.3) or inserted into the
    # connection's dynamic table. Private: this is the library's
    # unconditional, built-in floor, not a caller-mutable collection — a
    # caller adds to the effective set via `to_header_fields`'s
    # `extra_never_indexed` parameter (see `Client#additional_never_indexed_fields`),
    # never by reaching into this one.
    private SENSITIVE_FIELD_NAMES = Set{
      "authorization",
      "proxy-authorization",
      "cookie",
      "set-cookie",
    }

    @fields = [] of Header

    def initialize
    end

    def initialize(fields : Enumerable(Header))
      fields.each { |field| @fields << field }
    end

    # Names are downcased on insertion — see `#add`'s doc comment for why.
    def initialize(fields : Enumerable(Tuple(String, String)))
      fields.each { |name, value| @fields << Header.new(name.downcase, value) }
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
    #
    # The name is downcased on insertion, enforcing the "exactly matching
    # lowercase name" contract `#[]`/`#get_all` below already document:
    # every mutator (`#add`, `#[]=`, the tuple-based `#initialize`) stores
    # lowercase names, so a caller cannot bypass case-sensitive logic
    # elsewhere — most importantly `to_header_fields`'s never-index
    # selection — merely by supplying a differently-cased name.
    def add(name : String, value : String) : self
      @fields << Header.new(name.downcase, value)
      self
    end

    # Replaces every existing field with this name (matched
    # case-insensitively, via the downcasing `#add` performs) with a
    # single field carrying *value*.
    def []=(name : String, value : String) : String
      downcased_name = name.downcase
      delete(downcased_name)
      add(downcased_name, value)
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
    # compresses to an indexed reference on a later request.
    # `SENSITIVE_FIELD_NAMES` and *extra_never_indexed* (a caller's own
    # additional credential/secret header names — see
    # `Client#additional_never_indexed_fields`) are the confidentiality
    # boundary this creates: a matching field is marked `Never` so the
    # HPACK encoder emits it as a literal-never-indexed representation
    # (RFC 7541 6.2.3) and never inserts it into the dynamic table, on the
    # first request or any later one.
    #
    # Both the field's own name and every entry of *extra_never_indexed*
    # are downcased right here, immediately before comparison — every
    # `Headers` mutator already stores lowercase names (see `#add`), but
    # this decision does not rely on that holding true elsewhere. It is
    # correct regardless of how the field reached `@fields` or how the
    # caller cased *extra_never_indexed*.
    def to_header_fields(
      extra_never_indexed : Enumerable(String) = [] of String,
    ) : Array(HeaderField)
      never_indexed = extra_never_indexed.map(&.downcase).to_set
      @fields.map do |field|
        name = field.name.downcase
        indexing = if SENSITIVE_FIELD_NAMES.includes?(name) || never_indexed.includes?(name)
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
