module HTTP2
  class Connection
    # One complete compressed field block and the metadata from its opening
    # HEADERS or PUSH_PROMISE frame.
    struct FieldBlock
      enum Kind
        Headers
        PushPromise
      end

      record Priority,
        exclusive : Bool,
        stream_dependency : UInt32,
        weight : UInt8

      getter kind : Kind
      getter stream_id : UInt32

      # May alias the opening frame's payload or the assembler's
      # CONTINUATION accumulator buffer (see `FieldBlockAssembler`) rather
      # than a defensive copy — valid only until this block is decoded,
      # i.e. within the reader fiber's current dispatch of this frame.
      # Do not retain it past that point.
      getter encoded : Bytes
      getter? end_stream : Bool
      getter promised_stream_id : UInt32?
      getter priority : Priority?
      getter continuation_count : Int32

      def initialize(
        @kind : Kind,
        @stream_id : UInt32,
        @encoded : Bytes,
        @end_stream : Bool = false,
        @promised_stream_id : UInt32? = nil,
        @priority : Priority? = nil,
        @continuation_count : Int32 = 0,
      )
      end

      def self.from(
        frame : Frame::Headers,
        encoded : Bytes,
        continuation_count : Int32,
      ) : self
        priority = if frame.priority?
                     Priority.new(
                       frame.exclusive? || false,
                       frame.stream_dependency || 0_u32,
                       frame.weight || 0_u8
                     )
                   end

        new(
          Kind::Headers,
          frame.stream_id,
          encoded,
          end_stream: frame.end_stream?,
          priority: priority,
          continuation_count: continuation_count
        )
      end

      def self.from(
        frame : Frame::PushPromise,
        encoded : Bytes,
        continuation_count : Int32,
      ) : self
        new(
          Kind::PushPromise,
          frame.stream_id,
          encoded,
          promised_stream_id: frame.promised_stream_id,
          continuation_count: continuation_count
        )
      end
    end

    # One fully decompressed field section and its opening-frame metadata.
    struct FieldSection
      getter kind : FieldBlock::Kind
      getter stream_id : UInt32
      getter fields : Array(DecodedHeaderField)
      getter decoded_size : UInt64
      getter? end_stream : Bool
      getter promised_stream_id : UInt32?
      getter priority : FieldBlock::Priority?
      getter continuation_count : Int32

      # The connection-side `ResponseValidator`'s already-parsed result
      # for this section, attached (see the second `initialize` below)
      # by `Connection#transition_and_deliver` once validation completes
      # — `parsed_response` for a response's leading field section,
      # `parsed_trailers` for its trailer section, never both. Both stay
      # `nil` when no validator ran (server mode, or validation
      # disabled) or for a PUSH_PROMISE section, which is never routed
      # through the validator at all; the consumer (`Client#await_response`
      # / its trailer counterpart) falls back to parsing `fields` itself
      # in that case. Safe to read from a fiber other than the one that
      # attached it: `HTTPSemantics::ResponseSection` is an immutable
      # `record`, and the attached `Headers` is handed over only after
      # `HTTPSemantics.validate_trailers` has finished building it and
      # never mutated afterward — the validator that built it discards
      # its own reference, and this struct exposes it via a read-only
      # `getter` with no mutator, so there is no writer left to race the
      # client's read.
      getter parsed_response : HTTPSemantics::ResponseSection?
      getter parsed_trailers : Headers?

      def initialize(
        block : FieldBlock,
        @fields : Array(DecodedHeaderField),
        @decoded_size : UInt64,
        @parsed_response : HTTPSemantics::ResponseSection? = nil,
        @parsed_trailers : Headers? = nil,
      )
        @kind = block.kind
        @stream_id = block.stream_id
        @end_stream = block.end_stream?
        @promised_stream_id = block.promised_stream_id
        @priority = block.priority
        @continuation_count = block.continuation_count
      end

      # Builds a copy of *section* with a validator's parse result
      # attached. `FieldSection` is a struct that flows through the
      # stream event channel, so the delivered event has to be built
      # fresh here rather than mutated in place — every getter above is
      # read-only, so there is nothing on the original to mutate anyway.
      def initialize(
        section : FieldSection,
        @parsed_response : HTTPSemantics::ResponseSection? = nil,
        @parsed_trailers : Headers? = nil,
      )
        @kind = section.kind
        @stream_id = section.stream_id
        @fields = section.fields
        @decoded_size = section.decoded_size
        @end_stream = section.end_stream?
        @promised_stream_id = section.promised_stream_id
        @priority = section.priority
        @continuation_count = section.continuation_count
      end
    end
  end

  alias StreamEvent = Frames | Connection::FieldSection
end
