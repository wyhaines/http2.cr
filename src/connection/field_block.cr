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

      def initialize(
        block : FieldBlock,
        @fields : Array(DecodedHeaderField),
        @decoded_size : UInt64,
      )
        @kind = block.kind
        @stream_id = block.stream_id
        @end_stream = block.end_stream?
        @promised_stream_id = block.promised_stream_id
        @priority = block.priority
        @continuation_count = block.continuation_count
      end
    end
  end

  alias StreamEvent = Frames | Connection::FieldSection
end
