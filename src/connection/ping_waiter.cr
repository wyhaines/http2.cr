module HTTP2
  class Connection
    # :nodoc:
    class PingWaiter
      getter key : UInt64

      @completion = Channel(Exception?).new(1)

      def initialize(payload : Bytes)
        @key = IO::ByteFormat::BigEndian.decode(UInt64, payload)
      end

      def complete(error : Exception? = nil) : Nil
        @completion.send(error)
      end

      def wait(timeout : Time::Span?) : Nil
        error = if timeout
                  select
                  when result = @completion.receive
                    result
                  when timeout(timeout)
                    raise TimeoutError.new("waiting for PING acknowledgement timed out")
                  end
                else
                  @completion.receive
                end
        raise error if error
      end
    end
  end
end
