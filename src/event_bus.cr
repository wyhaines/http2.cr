module HTTP2
  # When included, this equips the class with a basic event bus.
  module EventBus
    @listeners : Hash(Symbol, Array(Proc(Nil)))

    def listen(event : Symbol, _ -> Proc(Nil))
      listeners(event).push block
    end

    # Subscribe to next event (at most once) for specified type.
    #
    # @param event [Symbol]
    # @param block [Proc] callback function
    def once(event, &block)
      listen(event) do |*args, callback|
        block.call(*args, &callback)
        :delete
      end
    end

    # Emit event with provided arguments.
    #
    # @param event [Symbol]
    # @param args [Array] arguments to be passed to the callbacks
    # @param block [Proc] callback function
    def emit(event, *args, &block)
      listeners(event).delete_if do |cb|
        cb.call(*args, &block) == :delete
      end
    end

    def listeners(event)
      @listeners ||= Hash(Symbol, Array(Proc(Nil))).new { |hash, key| hash[key] = [] of Proc(Nil) }
      @listeners[event]
    end
  end
end
