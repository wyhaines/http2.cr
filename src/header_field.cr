module HTTP2
  # One ordered HTTP field with encoding policy that does not expose HPACK
  # implementation types through the connection API.
  record HeaderField,
    name : String,
    value : String,
    indexing : Indexing = Indexing::None,
    huffman : Huffman = Huffman::Smaller do
    enum Indexing
      None
      Incremental
      Never
    end

    enum Huffman
      Never
      Always
      Smaller
    end

    # :nodoc:
    def to_hpack : HPack::HeaderField
      HPack::HeaderField.new(
        name,
        value,
        indexing: hpack_indexing,
        huffman: hpack_huffman
      )
    end

    private def hpack_indexing : HPack::Indexing
      case indexing
      in .none?
        HPack::Indexing::NONE
      in .incremental?
        HPack::Indexing::ALWAYS
      in .never?
        HPack::Indexing::NEVER
      end
    end

    private def hpack_huffman : HPack::HuffmanMode
      case huffman
      in .never?
        HPack::HuffmanMode::NEVER
      in .always?
        HPack::HuffmanMode::ALWAYS
      in .smaller?
        HPack::HuffmanMode::SMALLER
      end
    end
  end

  # One decoded field and the HPACK representation used on the wire.
  #
  # The representation is retained so an intermediary can preserve the
  # never-indexed marker without exposing HPACK implementation types.
  record DecodedHeaderField,
    name : String,
    value : String,
    indexing : Indexing do
    enum Indexing
      Indexed
      Incremental
      None
      Never
    end

    # :nodoc:
    def self.from_hpack(field : HPack::DecodedHeader) : self
      new(field.name, field.value, indexing_from_hpack(field.indexing))
    end

    private def self.indexing_from_hpack(
      indexing : HPack::Indexing,
    ) : Indexing
      case indexing
      when HPack::Indexing::INDEXED
        Indexing::Indexed
      when HPack::Indexing::ALWAYS
        Indexing::Incremental
      when HPack::Indexing::NONE
        Indexing::None
      when HPack::Indexing::NEVER
        Indexing::Never
      else
        raise ArgumentError.new("unsupported decoded indexing marker")
      end
    end
  end
end
