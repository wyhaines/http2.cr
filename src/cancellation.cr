module HTTP2
  # A shareable, idempotent cancellation signal for a request and its body.
  class Cancellation
    @signal = Channel(Nil).new
    @canceled = Atomic(Bool).new(false)

    def cancel : Nil
      _, close = @canceled.compare_and_set(false, true)
      @signal.close if close
    end

    def canceled? : Bool
      @canceled.get
    end

    # :nodoc:
    def signal : Channel(Nil)
      @signal
    end
  end
end
