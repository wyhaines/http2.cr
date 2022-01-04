module HTTP2
  struct Frame::Headers
    TypeCode = 0x01_u8

    getter headers : HTTP::Headers = HTTP::Headers.new

    def decode
      decode_using(HPack::Decoder.new)
    end

    def decode_using(decoder : HPack::Decoder)
      @headers.merge! decoder.decode(payload)
    end
  end
end