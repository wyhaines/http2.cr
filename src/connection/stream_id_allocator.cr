module HTTP2
  class Connection
    # Allocates the odd, monotonically increasing IDs used by client streams.
    class StreamIDAllocator
      getter next_id : UInt32

      def initialize(@next_id : UInt32 = 1_u32)
        if @next_id.zero? || @next_id.even? || @next_id > FrameHeader::MAX_STREAM_ID
          raise ArgumentError.new("the next client stream ID must be an odd 31-bit value")
        end
        @exhausted = false
      end

      def allocate : UInt32
        if @exhausted
          raise StreamIDExhaustedError.new("HTTP/2 client stream IDs are exhausted")
        end

        allocated = @next_id
        if allocated == FrameHeader::MAX_STREAM_ID
          @exhausted = true
        else
          @next_id += 2
        end
        allocated
      end

      def exhausted?
        @exhausted
      end
    end
  end
end
