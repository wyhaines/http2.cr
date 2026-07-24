module HTTP2
  # A shareable, idempotent cancellation signal for a request and its body.
  class Cancellation
    @signal = Channel(Nil).new
    @mutex = Mutex.new
    @canceled = false

    def cancel : Nil
      close = @mutex.synchronize do
        next false if @canceled

        @canceled = true
        true
      end
      @signal.close if close
    end

    def canceled? : Bool
      @mutex.synchronize { @canceled }
    end

    # :nodoc:
    def signal : Channel(Nil)
      @signal
    end
  end
end
