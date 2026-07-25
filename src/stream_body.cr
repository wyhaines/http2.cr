require "deque"

module HTTP2
  # A bounded, read-only stream of inbound DATA octets.
  #
  # Flow-control credit is returned only after bytes leave this buffer. Closing
  # an unfinished body discards its buffered bytes and cancels the stream.
  class StreamBody < IO
    class ReadTimeoutError < IO::Error
    end

    class ReadCanceledError < IO::Error
    end

    @chunks = Deque(Bytes).new
    @chunk_offset = 0
    @buffered_bytes = 0
    @consumed_bytes = 0_i64
    @finished = false
    @closed = false
    @terminal_error : Exception?
    @mutex = Mutex.new
    @read_mutex = Mutex.new
    @wakeup = Channel(Nil).new(1)
    @completion_signal = Channel(Nil).new

    getter capacity : Int32

    def initialize(
      @capacity : Int32,
      @on_consumed : Int32 -> Nil,
      @on_cancel : -> Nil,
    )
      if @capacity <= 0
        raise ArgumentError.new("stream body capacity must be positive")
      end
    end

    def read(slice : Bytes) : Int32
      read_with_timeout(slice)
    end

    # Reads with an optional inactivity timeout and cancellation signal.
    #
    # :nodoc:
    def read_with_timeout(
      slice : Bytes,
      timeout : Time::Span? = nil,
      cancellation : Channel(Nil)? = nil,
    ) : Int32
      return 0 if slice.empty?

      @read_mutex.synchronize do
        loop do
          count, error, wait = @mutex.synchronize do
            if chunk = @chunks.first?
              available = chunk.size - @chunk_offset
              count = Math.min(slice.size, available)
              slice[0, count].copy_from(chunk[@chunk_offset, count])
              @chunk_offset += count
              @buffered_bytes -= count
              @consumed_bytes += count

              if @chunk_offset == chunk.size
                @chunks.shift
                @chunk_offset = 0
              end
              {count, nil, false}
            elsif error = @terminal_error
              {0, error, false}
            elsif @finished || @closed
              {0, nil, false}
            else
              {0, nil, true}
            end
          end

          if wait
            wait_for_data(timeout, cancellation)
            next
          end

          raise error if error
          @on_consumed.call(count) if count > 0
          return count
        end
      end
    end

    def write(slice : Bytes) : NoReturn
      raise IO::Error.new("HTTP/2 response bodies are read-only")
    end

    def close : Nil
      discarded, cancel = @mutex.synchronize do
        if @closed
          {0, false}
        else
          @closed = true
          discarded = discard_unlocked
          {discarded, !@finished && @terminal_error.nil?}
        end
      end

      notify
      complete
      @on_consumed.call(discarded) if discarded > 0
      @on_cancel.call if cancel
    end

    def closed? : Bool
      @mutex.synchronize { @closed }
    end

    def finished? : Bool
      @mutex.synchronize { @finished }
    end

    def completed? : Bool
      @mutex.synchronize { @finished || @closed || !@terminal_error.nil? }
    end

    # :nodoc:
    def completion_signal : Channel(Nil)
      @completion_signal
    end

    def buffered_bytes : Int32
      @mutex.synchronize { @buffered_bytes }
    end

    # Cumulative count of bytes a caller has read out of this body via
    # `#read`/`#read_with_timeout`, regardless of how those reads were
    # split. Monotonically increasing for the body's lifetime; unaffected
    # by bytes discarded on `#close` or `#terminate`. Comparing two
    # snapshots taken across a wait tells whether a reader consumed
    # anything during that window — used to detect an abandoned response
    # without disturbing a reader that is merely slow (see
    # `HTTP2::Client#monitor_response`).
    #
    # :nodoc:
    def consumed_bytes : Int64
      @mutex.synchronize { @consumed_bytes }
    end

    # :nodoc:
    def enqueue(data : Bytes) : Bool
      return true if data.empty?

      accepted = @mutex.synchronize do
        next false if @closed || @finished || @terminal_error
        next false if data.size > @capacity - @buffered_bytes

        @chunks << data
        @buffered_bytes += data.size
        true
      end
      notify if accepted
      accepted
    end

    # :nodoc:
    def finish : Nil
      changed = @mutex.synchronize do
        if @finished || @terminal_error
          false
        else
          @finished = true
          true
        end
      end
      if changed
        notify
        complete
      end
    end

    # Marks the body terminal, discards buffered data, and returns the number
    # of flow-controlled application octets that were discarded.
    #
    # :nodoc:
    def terminate(error : Exception) : Int32
      discarded, changed = @mutex.synchronize do
        if @terminal_error || @closed
          {0, false}
        else
          @terminal_error = error
          {discard_unlocked, true}
        end
      end
      if changed
        notify
        complete
      end
      discarded
    end

    private def discard_unlocked : Int32
      discarded = @buffered_bytes
      @chunks.clear
      @chunk_offset = 0
      @buffered_bytes = 0
      discarded
    end

    private def notify : Nil
      select
      when @wakeup.send(nil)
      else
      end
    rescue Channel::ClosedError
      # No wakeup is needed after the body has been abandoned.
    end

    private def complete : Nil
      @completion_signal.close
    rescue Channel::ClosedError
      # Completion is idempotent across finish, reset, and close races.
    end

    private def wait_for_data(
      duration : Time::Span?,
      cancellation : Channel(Nil)?,
    ) : Nil
      if duration && cancellation
        select
        when @wakeup.receive?
        when cancellation.receive?
          raise ReadCanceledError.new("response body read was canceled")
        when timeout(duration)
          raise ReadTimeoutError.new("response body read timed out")
        end
      elsif duration
        select
        when @wakeup.receive?
        when timeout(duration)
          raise ReadTimeoutError.new("response body read timed out")
        end
      elsif cancellation
        select
        when @wakeup.receive?
        when cancellation.receive?
          raise ReadCanceledError.new("response body read was canceled")
        end
      else
        @wakeup.receive?
      end
    end
  end
end
