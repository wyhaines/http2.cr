module HTTP2
  class Connection
    # :nodoc:
    class WriteCommand
      getter frames : Array(Frames)
      getter? preface : Bool

      @completion = Channel(Exception?).new(1)

      def initialize(@frames : Array(Frames), @preface : Bool = false)
      end

      def complete(error : Exception? = nil) : Nil
        @completion.send(error)
      end

      def wait : Nil
        if error = @completion.receive
          raise error
        end
      end
    end
  end
end
