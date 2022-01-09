module HTTP2
  abstract struct Frame
    module HeadersHelper
      macro included
        getter headers : HTTP::Headers = HTTP::Headers.new

        def decode
          decode_using(HPack::Decoder.new)
        end
    
        def decode_using(decoder : HPack::Decoder)
          @headers.merge! decoder.decode(data)
        end

        def end_headers?
          flags.includes?(Flags::END_HEADERS)
        end

        def header_block_fragment
          data
        end

        def setup
          decode
        end
      end
    end
  end
end
