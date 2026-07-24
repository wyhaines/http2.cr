require "./connection"
require "./headers"
require "./http_errors"

module HTTP2
  # Shared RFC 9113 field validation used by request construction and response
  # parsing.
  module HTTPSemantics
    extend self

    CONNECTION_FIELDS = [
      "connection",
      "proxy-connection",
      "keep-alive",
      "transfer-encoding",
      "upgrade",
    ]

    record ResponseSection,
      status : Int32,
      headers : Headers,
      content_length : Int64?

    def regular_field_error(
      name : String,
      value : String,
      *,
      request : Bool,
      trailer : Bool,
    ) : String?
      if error = field_syntax_error(name, value, pseudo: false)
        return error
      end
      if CONNECTION_FIELDS.includes?(name)
        return "connection-specific field #{name.inspect} is forbidden"
      end
      if name == "te"
        if !request
          return "the te field is only permitted in requests"
        end
        unless value.downcase == "trailers"
          return "the te field may only contain \"trailers\""
        end
      end
      if trailer && name == "content-length"
        return "content-length is forbidden in trailers"
      end
      nil
    end

    def field_syntax_error(
      name : String,
      value : String,
      *,
      pseudo : Bool,
    ) : String?
      field_name_error(name, pseudo) || field_value_error(name, value)
    end

    private def field_name_error(name : String, pseudo : Bool) : String?
      return "field names cannot be empty" if name.empty?

      index = 0
      name.each_byte do |byte|
        if pseudo && index.zero? && byte == ':'.ord
          index += 1
          next
        end
        if byte <= 0x20 || byte >= 0x7f || (0x41..0x5a).includes?(byte)
          return "invalid HTTP/2 field name #{name.inspect}"
        end
        if byte == ':'.ord
          return "invalid colon in HTTP/2 field name #{name.inspect}"
        end
        unless token_byte?(byte)
          return "invalid HTTP/2 field name #{name.inspect}"
        end
        index += 1
      end
      nil
    end

    private def field_value_error(name : String, value : String) : String?
      value.each_byte do |byte|
        if byte.zero? || byte == '\n'.ord || byte == '\r'.ord
          return "invalid byte in HTTP field #{name.inspect}"
        end
        if (byte < 0x20 && byte != '\t'.ord) || byte == 0x7f
          return "invalid control byte in HTTP field #{name.inspect}"
        end
      end
      if value.starts_with?(' ') || value.starts_with?('\t') ||
         value.ends_with?(' ') || value.ends_with?('\t')
        return "HTTP field #{name.inspect} has surrounding whitespace"
      end
      nil
    end

    def parse_response_section(
      fields : Enumerable(DecodedHeaderField),
      stream_id : UInt32,
    ) : ResponseSection
      regular = Headers.new
      status_value : String? = nil
      saw_regular = false

      fields.each do |field|
        name = field.name
        value = field.value
        pseudo = name.starts_with?(':')
        if error = field_syntax_error(name, value, pseudo: pseudo)
          malformed!(stream_id, error)
        end

        if pseudo
          malformed!(stream_id, "pseudo-fields must precede regular fields") if saw_regular
          unless name == ":status"
            malformed!(stream_id, "response contains invalid pseudo-field #{name.inspect}")
          end
          if status_value
            malformed!(stream_id, "response contains repeated :status")
          end
          status_value = value
        else
          saw_regular = true
          if error = regular_field_error(
               name,
               value,
               request: false,
               trailer: false
             )
            malformed!(stream_id, error)
          end
          regular.add(name, value)
        end
      end

      status_text = status_value
      unless status_text
        malformed!(stream_id, "response is missing :status")
      end
      unless status_text.bytesize == 3 &&
             status_text.each_byte.all? { |byte| (0x30..0x39).includes?(byte) }
        malformed!(stream_id, "response :status must contain three digits")
      end

      status = status_text.to_i
      unless 100 <= status <= 599
        malformed!(stream_id, "response :status is outside the valid range")
      end

      ResponseSection.new(
        status,
        regular,
        parse_content_length(regular, stream_id)
      )
    end

    def validate_trailers(
      fields : Enumerable(DecodedHeaderField),
      stream_id : UInt32,
    ) : Headers
      trailers = Headers.new
      fields.each do |field|
        if field.name.starts_with?(':')
          malformed!(stream_id, "trailers cannot contain pseudo-fields")
        end
        if error = regular_field_error(
             field.name,
             field.value,
             request: false,
             trailer: true
           )
          malformed!(stream_id, error)
        end
        trailers.add(field.name, field.value)
      end
      trailers
    end

    def parse_request_content_length(headers : Headers) : Int64?
      parse_content_length_values(headers.get_all("content-length")) do |message|
        raise InvalidRequestError.new(message)
      end
    end

    private def parse_content_length(
      headers : Headers,
      stream_id : UInt32,
    ) : Int64?
      parse_content_length_values(headers.get_all("content-length")) do |message|
        malformed!(stream_id, message)
      end
    end

    private def parse_content_length_values(
      values : Array(String),
      &on_error : String ->
    ) : Int64?
      parsed = [] of Int64
      values.each do |value|
        value.split(',').each do |raw_part|
          part = raw_part.strip
          if part.empty? ||
             !part.each_byte.all? { |byte| (0x30..0x39).includes?(byte) }
            on_error.call("content-length must contain a non-negative decimal integer")
            return
          end
          begin
            parsed << part.to_i64
          rescue OverflowError
            on_error.call("content-length exceeds the supported integer range")
            return
          end
        end
      end
      return if parsed.empty?

      expected = parsed.first
      unless parsed.all? { |value| value == expected }
        on_error.call("conflicting content-length values")
        return
      end
      expected
    end

    private def malformed!(stream_id : UInt32, message : String) : NoReturn
      raise MalformedResponseError.new(message, stream_id)
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
  end

  # Stateful validation for one response message.
  class ResponseValidator < Stream::InboundValidator
    getter final_status : Int32?
    getter received_content_bytes : Int64 = 0_i64

    @expected_content_length : Int64?
    @no_content = false
    @tunnel = false

    def initialize(@stream_id : UInt32, @request_method : String)
    end

    def validate(section : Connection::FieldSection) : Nil
      if @final_status
        validate_trailer_section(section)
        return
      end

      parsed = HTTPSemantics.parse_response_section(
        section.fields,
        @stream_id
      )
      if parsed.status < 200
        validate_informational_section(section, parsed)
      else
        validate_final_section(section, parsed)
      end
    end

    private def validate_final_section(
      section : Connection::FieldSection,
      parsed : HTTPSemantics::ResponseSection,
    ) : Nil
      status = parsed.status
      @final_status = status
      @tunnel = @request_method == "CONNECT" && (200..299).includes?(status)
      @no_content =
        !@tunnel &&
          (@request_method == "HEAD" || status == 204 || status == 304)
      @expected_content_length =
        @tunnel ? nil : parsed.content_length

      if !@tunnel && status == 204 && parsed.content_length
        malformed!("a 204 response cannot contain content-length")
      end
      validate_end! if section.end_stream?
    end

    private def validate_informational_section(
      section : Connection::FieldSection,
      parsed : HTTPSemantics::ResponseSection,
    ) : Nil
      if parsed.status == 101
        malformed!("HTTP/2 does not support status 101")
      end
      if section.end_stream?
        malformed!("an informational response cannot end the stream")
      end
      if parsed.content_length
        malformed!("an informational response cannot contain content-length")
      end
    end

    def validate_data(size : Int32, end_stream : Bool) : Nil
      unless @final_status
        malformed!("DATA arrived before a final response")
      end
      if @no_content && size > 0
        malformed!("this response cannot contain message content")
      end

      @received_content_bytes += size
      if expected = @expected_content_length
        if !@no_content && !@tunnel && @received_content_bytes > expected
          malformed!("response content exceeds content-length")
        end
      end
      validate_end! if end_stream
    end

    private def validate_trailer_section(
      section : Connection::FieldSection,
    ) : Nil
      unless section.end_stream?
        malformed!("a trailer field section must end the stream")
      end
      if @no_content || @tunnel
        malformed!("this response cannot contain trailers")
      end
      HTTPSemantics.validate_trailers(section.fields, @stream_id)
      validate_end!
    end

    private def validate_end! : Nil
      return if @no_content || @tunnel
      if expected = @expected_content_length
        unless @received_content_bytes == expected
          malformed!(
            "response content length #{@received_content_bytes} does not " \
            "match content-length #{expected}"
          )
        end
      end
    end

    private def malformed!(message : String) : NoReturn
      raise MalformedResponseError.new(message, @stream_id)
    end
  end
end
