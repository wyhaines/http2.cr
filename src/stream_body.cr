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
    @finished = Atomic(Bool).new(false)
    @closed = Atomic(Bool).new(false)
    @terminal_error : Exception?
    @mutex = Mutex.new
    @read_mutex = Mutex.new
    @wakeup = Channel(Nil).new(1)
    @completion_signal = Channel(Nil).new

    # Set (under `@mutex`) by the reader's read-check the moment it finds
    # nothing to do and is about to park on `@wakeup`; cleared (under
    # `@mutex`) once it stops parking. `#notify` skips the channel op
    # entirely unless this is `true`, so producers that run while no
    # reader is parked pay only a mutex check instead of a channel send.
    @waiting = false

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
            filled = 0
            while filled < slice.size && (chunk = @chunks.first?)
              available = chunk.size - @chunk_offset
              n = Math.min(slice.size - filled, available)
              (slice + filled).copy_from(chunk.to_unsafe + @chunk_offset, n)
              @chunk_offset += n
              filled += n
              @buffered_bytes -= n
              @consumed_bytes += n

              if @chunk_offset == chunk.size
                @chunks.shift
                @chunk_offset = 0
              end
            end

            if filled > 0
              {filled, nil, false}
            elsif error = @terminal_error
              {0, error, false}
            elsif @closed.get
              # A caller-initiated `#close` is distinct from reaching a
              # natural end of stream (`@finished`, still a plain 0-byte
              # EOF below): once closed, any further read must not be
              # mistaken for "the response completed normally," so it
              # raises instead of silently returning 0. This branch only
              # runs when `@terminal_error` is unset (checked above), so an
              # existing terminal error always takes precedence over this
              # generic closed signal.
              {0, IO::Error.new("Closed stream"), false}
            elsif @finished.get
              {0, nil, false}
            else
              # `@waiting` is armed in this same critical section, not in
              # `#wait_for_data`, so it and the "nothing to read" verdict
              # it records are atomic with respect to `#enqueue` (and
              # `#close`/`#finish`/`#terminate`), which all mutate state
              # under this same `@mutex`. See `#notify` for why that
              # matters.
              @waiting = true
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
        if @closed.get
          {0, false}
        else
          @closed.set(true)
          discarded = discard_unlocked
          {discarded, !@finished.get && @terminal_error.nil?}
        end
      end

      notify
      complete
      @on_consumed.call(discarded) if discarded > 0
      @on_cancel.call if cancel
    end

    # Lock-free: `@closed` is an `Atomic(Bool)`, and every write site
    # (`#close`) publishes through the same atomic, so a plain `#get` here
    # never tears — it can only be a snapshot that is momentarily stale
    # under concurrent mutation, exactly as a mutex-guarded read would
    # also have been the instant after releasing the lock.
    def closed? : Bool
      @closed.get
    end

    # Lock-free; see `#closed?`.
    def finished? : Bool
      @finished.get
    end

    # Lock-free; see `#closed?`. `@terminal_error` is only ever assigned
    # once (under `@mutex`, in `#terminate`) and never cleared, so reading
    # the reference here without the mutex is safe: reference reads/writes
    # are atomic (no torn pointer), and the only possible staleness is
    # "not yet visible," the same benign race a mutex-guarded read would
    # have had the instant after releasing the lock.
    def completed? : Bool
      @finished.get || @closed.get || !@terminal_error.nil?
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
        next false if @closed.get || @finished.get || @terminal_error
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
        if @finished.get || @terminal_error
          false
        else
          @finished.set(true)
          true
        end
      end
      if changed
        notify
        complete
      end
    end

    # Marks the body terminal, discards buffered data, and returns the number
    # of flow-controlled application octets that were discarded. Once the body
    # is finished, closed, or terminal, this is a no-op returning 0 — the
    # finished body's buffered data is deliberately preserved for the reader to
    # drain to clean EOF, establishing an invariant against data loss.
    #
    # :nodoc:
    def terminate(error : Exception) : Int32
      discarded, changed = @mutex.synchronize do
        if @terminal_error || @closed.get || @finished.get
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

    # Skips the channel op entirely unless a reader is actually parked.
    # `@waiting` is armed in `#read_with_timeout`'s own `@mutex` critical
    # section (the same one that decides there is nothing to read), not
    # here or in `#wait_for_data` — see that method for why the ordering
    # this buys is what keeps a concurrent `#enqueue` (or `#close`/
    # `#finish`/`#terminate`) from ever dropping a wakeup the reader
    # needed. Called with `@mutex` released (matching every existing call
    # site: `#enqueue`, `#close`, `#finish`, `#terminate` all call this
    # after their own mutex-guarded mutation returns), so it takes the
    # mutex itself just to read the flag.
    private def notify : Nil
      return unless @mutex.synchronize { @waiting }

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

    # Parks until `#notify` wakes it (or a timeout/cancellation fires).
    # `@waiting` is already `true` by the time this runs — the caller's
    # `@mutex` critical section sets it as part of the same verdict that
    # decided to call this method — so this only ever needs to clear it
    # again, which it does unconditionally on the way out (normal wakeup,
    # timeout, or cancellation alike) via `ensure`.
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
    ensure
      @mutex.synchronize { @waiting = false }
    end
  end
end
