require "./spec_helper"

private alias StreamState = HTTP2::Stream::State
private alias StreamEvent = HTTP2::Stream::Event
private alias TransitionAction = HTTP2::Stream::StateMachine::Action

describe HTTP2::Stream::StateMachine do
  it "defines an action for every logical frame event in every state" do
    expected = {
      StreamState::Idle => [
        TransitionAction::Allow, TransitionAction::Allow,
        TransitionAction::Allow, TransitionAction::Allow,
        TransitionAction::LocalError, TransitionAction::LocalError,
        TransitionAction::ConnectionError, TransitionAction::ConnectionError,
        TransitionAction::LocalError, TransitionAction::ConnectionError,
        TransitionAction::Allow, TransitionAction::Allow,
        TransitionAction::LocalError, TransitionAction::ConnectionError,
        TransitionAction::LocalError, TransitionAction::ConnectionError,
      ],
      StreamState::ReservedLocal => [
        TransitionAction::Allow, TransitionAction::Allow,
        TransitionAction::ConnectionError, TransitionAction::ConnectionError,
        TransitionAction::LocalError, TransitionAction::LocalError,
        TransitionAction::ConnectionError, TransitionAction::ConnectionError,
        TransitionAction::Allow, TransitionAction::Allow,
        TransitionAction::Allow, TransitionAction::Allow,
        TransitionAction::LocalError, TransitionAction::Allow,
        TransitionAction::LocalError, TransitionAction::ConnectionError,
      ],
      StreamState::ReservedRemote => [
        TransitionAction::LocalError, TransitionAction::LocalError,
        TransitionAction::Allow, TransitionAction::Allow,
        TransitionAction::LocalError, TransitionAction::LocalError,
        TransitionAction::ConnectionError, TransitionAction::ConnectionError,
        TransitionAction::Allow, TransitionAction::Allow,
        TransitionAction::Allow, TransitionAction::Allow,
        TransitionAction::Allow, TransitionAction::ConnectionError,
        TransitionAction::LocalError, TransitionAction::ConnectionError,
      ],
      StreamState::Open => Array.new(
        StreamEvent.values.size,
        TransitionAction::Allow
      ),
      StreamState::HalfClosedLocal => [
        TransitionAction::LocalError, TransitionAction::LocalError,
        TransitionAction::Allow, TransitionAction::Allow,
        TransitionAction::LocalError, TransitionAction::LocalError,
        TransitionAction::Allow, TransitionAction::Allow,
        TransitionAction::Allow, TransitionAction::Allow,
        TransitionAction::Allow, TransitionAction::Allow,
        TransitionAction::Allow, TransitionAction::Allow,
        TransitionAction::LocalError, TransitionAction::Allow,
      ],
      StreamState::HalfClosedRemote => [
        TransitionAction::Allow, TransitionAction::Allow,
        TransitionAction::StreamError, TransitionAction::StreamError,
        TransitionAction::Allow, TransitionAction::Allow,
        TransitionAction::StreamError, TransitionAction::StreamError,
        TransitionAction::Allow, TransitionAction::Allow,
        TransitionAction::Allow, TransitionAction::Allow,
        TransitionAction::Allow, TransitionAction::Allow,
        TransitionAction::Allow, TransitionAction::ConnectionError,
      ],
      StreamState::Closed => [
        TransitionAction::LocalError, TransitionAction::LocalError,
        TransitionAction::ConnectionError, TransitionAction::ConnectionError,
        TransitionAction::LocalError, TransitionAction::LocalError,
        TransitionAction::ConnectionError, TransitionAction::ConnectionError,
        TransitionAction::LocalError, TransitionAction::Ignore,
        TransitionAction::Allow, TransitionAction::Ignore,
        TransitionAction::LocalError, TransitionAction::Ignore,
        TransitionAction::LocalError, TransitionAction::ConnectionError,
      ],
    }

    StreamState.values.each do |stream_state|
      actual = StreamEvent.values.map do |stream_event|
        HTTP2::Stream::StateMachine
          .transition(stream_state, stream_event)
          .action
      end
      actual.should eq(expected[stream_state])
    end
  end

  it "applies every state-changing transition" do
    transitions = {
      {StreamState::Idle, StreamEvent::SendHeaders}                        => StreamState::Open,
      {StreamState::Idle, StreamEvent::SendHeadersEndStream}               => StreamState::HalfClosedLocal,
      {StreamState::Idle, StreamEvent::ReceiveHeaders}                     => StreamState::Open,
      {StreamState::Idle, StreamEvent::ReceiveHeadersEndStream}            => StreamState::HalfClosedRemote,
      {StreamState::ReservedLocal, StreamEvent::SendHeaders}               => StreamState::HalfClosedRemote,
      {StreamState::ReservedLocal, StreamEvent::SendHeadersEndStream}      => StreamState::Closed,
      {StreamState::ReservedRemote, StreamEvent::ReceiveHeaders}           => StreamState::HalfClosedLocal,
      {StreamState::ReservedRemote, StreamEvent::ReceiveHeadersEndStream}  => StreamState::Closed,
      {StreamState::Open, StreamEvent::SendDataEndStream}                  => StreamState::HalfClosedLocal,
      {StreamState::Open, StreamEvent::ReceiveDataEndStream}               => StreamState::HalfClosedRemote,
      {StreamState::HalfClosedLocal, StreamEvent::ReceiveHeadersEndStream} => StreamState::Closed,
      {StreamState::HalfClosedRemote, StreamEvent::SendHeadersEndStream}   => StreamState::Closed,
    }

    transitions.each do |input, expected|
      current, stream_event = input
      result = HTTP2::Stream::StateMachine.transition(
        current,
        stream_event
      )
      result.action.should eq(TransitionAction::Allow)
      result.next_state.should eq(expected)
    end

    StreamState.values.reject(&.idle?).each do |current|
      [
        StreamEvent::SendReset,
        StreamEvent::ReceiveReset,
      ].each do |reset|
        result = HTTP2::Stream::StateMachine.transition(current, reset)
        if current.closed? && reset.receive_reset?
          result.action.should eq(TransitionAction::Ignore)
        elsif current.closed?
          result.action.should eq(TransitionAction::LocalError)
        else
          result.next_state.should eq(StreamState::Closed)
        end
      end
    end
  end

  it "reserves only idle streams" do
    local = HTTP2::Stream::StateMachine.reserve_local(StreamState::Idle)
    local.action.should eq(TransitionAction::Allow)
    local.next_state.should eq(StreamState::ReservedLocal)

    remote = HTTP2::Stream::StateMachine.reserve_remote(StreamState::Idle)
    remote.action.should eq(TransitionAction::Allow)
    remote.next_state.should eq(StreamState::ReservedRemote)

    StreamState.values.reject(&.idle?).each do |current|
      HTTP2::Stream::StateMachine
        .reserve_local(current)
        .action
        .should eq(TransitionAction::LocalError)
      HTTP2::Stream::StateMachine
        .reserve_remote(current)
        .action
        .should eq(TransitionAction::ConnectionError)
    end
  end
end

# A minimal live stream to exercise `#deliver`/`#terminate`/`#receive*`
# directly: `Stream.new` needs a real `Connection`, so this drives a
# `Connection` far enough (through the handshake) to allocate one via
# `#new_stream`, without exchanging any further application frames.
private def make_stream(& : HTTP2::Stream ->) : Nil
  UNIXSocket.pair do |client, peer|
    peer_result = scripted_peer(peer) do |io|
      complete_server_handshake(io)
    end

    connection = HTTP2::Connection.start(client)
    begin
      connection.wait_until_active(1.second)
      yield connection.new_stream
      wait_for_peer(peer_result)
    ensure
      connection.close
    end
  end
end

private def some_event(stream : HTTP2::Stream) : HTTP2::StreamEvent
  HTTP2::Frame::WindowUpdate.new(stream.id, 1_u32)
end

private def reset_error(stream : HTTP2::Stream) : HTTP2::Connection::StreamResetError
  HTTP2::Connection::StreamResetError.new(
    stream.id,
    HTTP2::ErrorCode::CANCEL.to_u32
  )
end

describe HTTP2::Stream do
  it "drains and closes the event mailbox on terminate" do
    make_stream do |stream|
      stream.deliver(some_event(stream)).should be_true
      stream.test_only_events_closed?.should be_false

      stream.terminate(reset_error(stream))

      stream.test_only_events_closed?.should be_true
      stream.deliver(some_event(stream)).should be_false
    end
  end

  it "raises the terminal error, not ClosedError, for a select arm with " \
     "no terminal-signal branch (receive_until_remote_end's own select)" do
    make_stream do |stream|
      error = reset_error(stream)
      stream.terminate(error)

      raised = expect_raises(HTTP2::Connection::StreamResetError) do
        stream.receive_until_remote_end
      end
      raised.should eq(error)
    end
  end

  it "raises the terminal error, not ClosedError, for a reader already " \
     "parked in #receive when terminate closes the mailbox" do
    make_stream do |stream|
      parked = Channel(Nil).new
      outcome = Channel(Exception?).new(1)

      spawn do
        parked.send(nil)
        begin
          stream.receive
          outcome.send(nil)
        rescue error
          outcome.send(error)
        end
      end

      # By the time this returns, the reader fiber above has run
      # uninterrupted past `parked.send` (delivered sends never suspend
      # their own fiber) straight into `#receive`'s blocking select,
      # where it parks — so `#terminate` below is guaranteed to run
      # while the reader is genuinely waiting on `@events`/
      # `@terminal_signal`, not before it starts or after it returns.
      parked.receive

      error = reset_error(stream)
      stream.terminate(error)

      result = outcome.receive
      result.should eq(error)
    end
  end
end
