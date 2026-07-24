module HTTP2
  class Connection
    # :nodoc:
    record OutboundTransition,
      stream : Stream,
      state : Stream::State,
      close_reason : ClosedStream::Reason? = nil,
      close_error : Exception? = nil
  end
end
