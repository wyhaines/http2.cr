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
