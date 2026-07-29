require "./spec_helper"

private def encode_headers_frame(
  encoder : HPack::Encoder,
  stream_id : UInt32,
  fields : Array(Tuple(String, String)),
  *,
  end_stream : Bool = false,
) : Bytes
  flags = HTTP2::Frame::Headers::Flags::END_HEADERS
  flags |= HTTP2::Frame::Headers::Flags::END_STREAM if end_stream
  io = IO::Memory.new
  HTTP2::Frame::Headers.new(flags, stream_id, encoder.encode(fields)).write(io)
  io.to_slice
end

# Test-only connection that reports each post-handshake entry into
# `#enqueue`. Waiting for entry three proves that one command is stalled in
# the writer, one fills the capacity-1 queue, and the third holds the
# submission mutex while blocked on that full queue.
class SubmissionProbeConnection < HTTP2::Connection
  @probe_mutex = Mutex.new
  @enqueue_probe_armed = false
  @enqueue_probe_count = 0
  @enqueue_entries = Channel(Int32).new(4)

  def arm_enqueue_probe : Nil
    @probe_mutex.synchronize do
      @enqueue_probe_count = 0
      @enqueue_probe_armed = true
    end
  end

  def wait_for_enqueue_entry(
    expected : Int32,
    timeout : Time::Span = 1.second,
  ) : Nil
    deadline = Time.instant + timeout
    loop do
      remaining = deadline - Time.instant
      raise "enqueue entry #{expected} was not reached" if remaining <= Time::Span.zero

      observed = select
      when value = @enqueue_entries.receive
        value
      when timeout(remaining)
        raise "enqueue entry #{expected} was not reached"
      end
      return if observed >= expected
    end
  end

  private def enqueue(command : HTTP2::Connection::WriteCommand) : Nil
    entry = @probe_mutex.synchronize do
      next unless @enqueue_probe_armed

      @enqueue_probe_count += 1
    end
    @enqueue_entries.send(entry) if entry
    super
  end
end

describe HTTP2::Connection::Configuration do
  it "validates Phase 7 lifecycle and resource limits" do
    expect_raises(ArgumentError, /open-stream/) do
      HTTP2::Connection::Configuration.new(max_open_streams: 0)
    end
    expect_raises(ArgumentError, /pending SETTINGS/) do
      HTTP2::Connection::Configuration.new(max_pending_settings: 0)
    end
    expect_raises(ArgumentError, /pending PING/) do
      HTTP2::Connection::Configuration.new(max_pending_pings: 0)
    end
    expect_raises(ArgumentError, /pre-ACK PUSH_PROMISE/) do
      HTTP2::Connection::Configuration.new(max_pre_ack_push_promises: 0)
    end
    expect_raises(ArgumentError, /drain timeout/) do
      HTTP2::Connection::Configuration.new(
        drain_timeout: Time::Span.zero
      )
    end
    expect_raises(ArgumentError, /goaway flush timeout/) do
      HTTP2::Connection::Configuration.new(
        goaway_flush_timeout: Time::Span.zero
      )
    end
    expect_raises(ArgumentError, /keepalive interval/) do
      HTTP2::Connection::Configuration.new(
        keepalive_interval: Time::Span.zero
      )
    end
    expect_raises(ArgumentError, /keepalive timeout/) do
      HTTP2::Connection::Configuration.new(
        keepalive_timeout: Time::Span.zero
      )
    end
    expect_raises(ArgumentError, /decoded field count/) do
      HTTP2::Connection::Configuration.new(max_decoded_fields: -1)
    end
    expect_raises(ArgumentError, /frame-rate window/) do
      HTTP2::Connection::Configuration.new(
        inbound_frame_rate_window: Time::Span.zero
      )
    end
    expect_raises(ArgumentError, /control-frame/) do
      HTTP2::Connection::Configuration.new(
        max_control_frames_per_window: 0
      )
    end
    expect_raises(ArgumentError, /empty-frame/) do
      HTTP2::Connection::Configuration.new(
        max_empty_frames_per_window: 0
      )
    end
    expect_raises(ArgumentError, /diagnostic queue/) do
      HTTP2::Connection::Configuration.new(
        diagnostic_queue_capacity: 0
      )
    end
  end
end

describe HTTP2::Connection do
  it "sends GOAWAY and lets an established stream finish" do
    UNIXSocket.pair do |client, peer|
      stream_id = Channel(UInt32).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        id = stream_id.receive
        read_client_headers(io, id)

        goaway = HTTP2::Frame.read(io).as(HTTP2::Frame::GoAway)
        goaway.last_stream_id.should eq(0_u32)
        goaway.error_code.should eq(HTTP2::ErrorCode::NO_ERROR.to_u32)

        HTTP2::Frame::Headers.new(
          HTTP2::Frame::Headers::Flags::END_HEADERS |
          HTTP2::Frame::Headers::Flags::END_STREAM,
          id,
          Bytes.empty
        ).write(io)
        io.flush
        io.read(Bytes.new(1)).should eq(0)
      end

      connection = HTTP2::Connection.start(client)
      connection.wait_until_active(1.second)
      stream = connection.new_stream
      open_client_stream(stream)
      stream_id.send(stream.id)

      result = Channel(Exception?).new(1)
      spawn do
        begin
          connection.graceful_close(1.second)
          result.send(nil)
        rescue error
          result.send(error)
        end
      end

      stream.receive(1.second).should be_a(
        HTTP2::Connection::FieldSection
      )
      if error = result.receive
        raise error
      end
      connection.closed?.should be_true
      connection.terminal_error.should be_a(HTTP2::Connection::DrainedError)
      wait_for_peer(peer_result)
    end
  end

  it "enforces the graceful drain deadline and wakes the stream" do
    UNIXSocket.pair do |client, peer|
      stream_id = Channel(UInt32).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        id = stream_id.receive
        read_client_headers(io, id)
        HTTP2::Frame.read(io).should be_a(HTTP2::Frame::GoAway)
        io.read(Bytes.new(1)).should eq(0)
      end

      connection = HTTP2::Connection.start(client)
      connection.wait_until_active(1.second)
      stream = connection.new_stream
      open_client_stream(stream)
      stream_id.send(stream.id)

      expect_raises(HTTP2::Connection::DrainTimeoutError) do
        connection.graceful_close(20.milliseconds)
      end
      expect_raises(HTTP2::Connection::DrainTimeoutError) do
        stream.receive(1.second)
      end
      connection.closed?.should be_true
      wait_for_peer(peer_result)
    end
  end

  it "bounds registered streams before allocating another ID" do
    UNIXSocket.pair do |client, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        io.read(Bytes.new(1)).should eq(0)
      end
      configuration = HTTP2::Connection::Configuration.new(
        max_open_streams: 2
      )
      connection = HTTP2::Connection.start(client, configuration)
      connection.wait_until_active(1.second)

      first = connection.new_stream
      connection.new_stream
      error = expect_raises(HTTP2::Connection::OpenStreamLimitError) do
        connection.new_stream
      end
      error.limit.should eq(2)

      first.cancel
      connection.new_stream.id.should eq(5_u32)
      connection.close
      wait_for_peer(peer_result)
    end
  end

  it "bounds outstanding local PING waiters" do
    UNIXSocket.pair do |client, peer|
      ping_read = Channel(Nil).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        HTTP2::Frame.read(io).should be_a(HTTP2::Frame::Ping)
        ping_read.send(nil)
        io.read(Bytes.new(1)).should eq(0)
      end
      configuration = HTTP2::Connection::Configuration.new(
        max_pending_pings: 1
      )
      connection = HTTP2::Connection.start(client, configuration)
      connection.wait_until_active(1.second)

      first_result = Channel(Exception?).new(1)
      spawn do
        begin
          connection.ping("firstone")
          first_result.send(nil)
        rescue error
          first_result.send(error)
        end
      end
      ping_read.receive

      error = expect_raises(HTTP2::Connection::PingLimitError) do
        connection.ping("second__")
      end
      error.limit.should eq(1)

      connection.close
      first_result.receive.should be_a(HTTP2::Connection::ClosedError)
      wait_for_peer(peer_result)
    end
  end

  it "bounds unacknowledged local SETTINGS updates" do
    UNIXSocket.pair do |client, peer|
      update_read = Channel(Nil).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        HTTP2::Frame.read(io).should be_a(HTTP2::Frame::Settings)
        update_read.send(nil)
        io.read(Bytes.new(1)).should eq(0)
      end
      configuration = HTTP2::Connection::Configuration.new(
        max_pending_settings: 1
      )
      connection = HTTP2::Connection.start(client, configuration)
      connection.wait_until_active(1.second)
      eventually { connection.pending_settings_count.zero? }

      connection.send_settings([] of HTTP2::Frame::Settings::Setting)
      update_read.receive
      expect_raises(HTTP2::Connection::QueueFullError, /SETTINGS/) do
        connection.send_settings([] of HTTP2::Frame::Settings::Setting)
      end

      connection.close
      wait_for_peer(peer_result)
    end
  end

  it "sends optional keepalive PINGs and accepts their ACKs" do
    UNIXSocket.pair do |client, peer|
      acknowledged = Channel(Nil).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        ping = HTTP2::Frame.read(io).as(HTTP2::Frame::Ping)
        ping.ack?.should be_false
        ping.ack.write(io)
        io.flush
        acknowledged.send(nil)
      end
      configuration = HTTP2::Connection::Configuration.new(
        keepalive_interval: 20.milliseconds,
        keepalive_timeout: 200.milliseconds
      )
      connection = HTTP2::Connection.start(client, configuration)
      connection.wait_until_active(1.second)
      acknowledged.receive
      connection.active?.should be_true
      connection.close
      wait_for_peer(peer_result)
    end
  end

  it "closes and wakes waiters when a keepalive PING times out" do
    UNIXSocket.pair do |client, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        HTTP2::Frame.read(io).should be_a(HTTP2::Frame::Ping)
        io.read(Bytes.new(1)).should eq(0)
      end
      configuration = HTTP2::Connection::Configuration.new(
        keepalive_interval: 20.milliseconds,
        keepalive_timeout: 20.milliseconds
      )
      connection = HTTP2::Connection.start(client, configuration)
      connection.wait_until_active(1.second)
      stream = connection.new_stream

      connection.wait_closed(1.second)
      connection.terminal_error.should be_a(
        HTTP2::Connection::KeepaliveTimeoutError
      )
      expect_raises(HTTP2::Connection::KeepaliveTimeoutError) do
        stream.receive(1.second)
      end
      wait_for_peer(peer_result)
    end
  end

  it "terminates a write-stalled connection within the keepalive deadline" do
    transport = StallingWriteIO.new
    connection = HTTP2::Connection.start(
      transport,
      HTTP2::Connection::Configuration.new(
        keepalive_interval: 50.milliseconds,
        keepalive_timeout: 250.milliseconds
      )
    )
    begin
      connection.wait_until_active(1.second)
      transport.stall!

      eventually(
        timeout: 3.seconds,
        message: "keepalive did not terminate the stalled connection"
      ) { connection.closed? }
      connection.terminal_error
        .should be_a(HTTP2::Connection::KeepaliveTimeoutError)
    ensure
      connection.close
    end
  end

  it "closes promptly against a stalled peer with buffered output " \
     "pending and no write timeout" do
    transport = StallingBufferedWriteIO.new
    connection = HTTP2::Connection.start(transport)
    connection.wait_until_active(1.second)
    transport.stall!

    spawn(name: "stalled-ping") do
      connection.write_frame(HTTP2::Frame::Ping.new(0_u8, 0_u32, "12345678"))
    rescue
      # Expected: the write fails once #close force-closes the transport
      # out from under it.
    end
    transport.wait_until_write_stalled(1.second)

    closed = Channel(Nil).new(1)
    spawn(name: "closer") do
      connection.close
      closed.send(nil)
    end

    select
    when closed.receive
    when timeout(2.seconds)
      fail(
        "Connection#close hung against a stalled peer with buffered " \
        "output pending"
      )
    end

    connection.closed?.should be_true
  end

  it "keeps the reader processing after a stream violation against a " \
     "stalled transport, with keepalive disabled" do
    encoder = HPack::Encoder.new
    violation = encode_headers_frame(
      encoder,
      1_u32,
      [{":status", "099"}]
    )
    healthy = encode_headers_frame(
      encoder,
      3_u32,
      [{":status", "200"}],
      end_stream: true
    )
    extra = IO::Memory.new
    extra.write(violation)
    extra.write(healthy)

    # Default configuration: keepalive_interval is nil, so no keepalive
    # safety net can rescue a parked reader. This isolates the behavior
    # under test to the reader's own handling of the violation reset.
    transport = StallingWriteIO.new(extra.to_slice)
    connection = HTTP2::Connection.start(transport)
    begin
      connection.wait_until_active(1.second)

      violated = connection.new_stream
      violated.inbound_validator =
        HTTP2::ResponseValidator.new(violated.id, "GET")
      open_client_stream(violated)

      healthy_stream = connection.new_stream
      healthy_stream.inbound_validator =
        HTTP2::ResponseValidator.new(healthy_stream.id, "GET")
      open_client_stream(healthy_stream)

      # Stall the transport, then release the gated response bytes. Both
      # streams are registered before either frame becomes readable, so the
      # reader cannot observe the malformed section before the violated
      # stream exists.
      transport.stall!
      transport.release_gated_reads!

      # The discriminator: a frame for an unrelated, healthy stream sits
      # right behind the violation in the read buffer. Delivering it to the
      # application requires no transport write at all, so it only arrives
      # if the reader fiber returns from handling the violation and loops
      # back to read the next frame — i.e. it proves the reader did not
      # park inside the violation reset's write-completion wait.
      healthy_stream.receive(1.second).should be_a(
        HTTP2::Connection::FieldSection
      )

      # The violated stream still terminates locally with its protocol
      # error even though the RST_STREAM frame itself can never reach the
      # (permanently stalled) wire.
      expect_raises(HTTP2::MalformedResponseError) do
        violated.receive(1.second)
      end

      connection.closed?.should be_false
    ensure
      connection.close
    end
  end

  it "terminates within the flush timeout when a connection-level " \
     "protocol violation hits a stalled transport" do
    # A PING frame targeting a nonzero stream ID is a connection-scoped
    # protocol violation (RFC 9113 6.7) discovered while parsing the frame
    # itself, in `reader_loop`'s own `rescue error : ProtocolError` — the
    # same #send_goaway this test exercises, not the per-stream
    # `handle_stream_violation` path the "keeps the reader processing..."
    # spec above covers.
    violation = wire_frame(
      HTTP2::Frame::Ping::TypeCode,
      0_u8,
      1_u32,
      Bytes.new(8, 0_u8)
    )
    configuration = HTTP2::Connection::Configuration.new(
      goaway_flush_timeout: 100.milliseconds
    )
    transport = StallingWriteIO.new(violation)
    connection = HTTP2::Connection.start(transport, configuration)
    begin
      connection.wait_until_active(1.second)
      transport.stall!
      transport.release_gated_reads!

      # Well over goaway_flush_timeout (100ms) but far under any default
      # keepalive/write-timeout recovery — a stalled #send_goaway that
      # blocks on #command.wait forever (no timeout raced in) would still
      # be parked when this bound elapses, since nothing else in this
      # configuration (no keepalive, StallingWriteIO honors no
      # write_timeout) can ever unblock it.
      connection.wait_closed(1.second)
      connection.terminal_error.should be_a(HTTP2::ProtocolError)
    ensure
      connection.close
    end
  end

  it "includes submission-lock contention in the GOAWAY flush timeout" do
    violation = wire_frame(
      HTTP2::Frame::Ping::TypeCode,
      0_u8,
      1_u32,
      Bytes.new(8, 0_u8)
    )
    configuration = HTTP2::Connection::Configuration.new(
      writer_queue_capacity: 1,
      goaway_flush_timeout: 100.milliseconds
    )
    transport = StallingWriteIO.new(violation)
    connection = SubmissionProbeConnection.start(transport, configuration)
    submissions = Channel(Exception?).new(3)

    begin
      connection.wait_until_active(1.second)
      connection.arm_enqueue_probe
      transport.stall!

      3.times do |index|
        spawn do
          begin
            payload = "queued0#{index + 1}"
            connection.write_frame(
              HTTP2::Frame::Ping.new(
                0_u8,
                0_u32,
                payload
              )
            )
            submissions.send(nil)
          rescue error
            submissions.send(error)
          end
        end

        connection.wait_for_enqueue_entry(index + 1)
        transport.wait_until_write_stalled(1.second) if index.zero?
      end

      # Entry three holds @submission_mutex inside an enqueue to the full
      # capacity-1 queue. The reader must still give up acquiring that mutex
      # at goaway_flush_timeout, terminate, and wake all three submitters.
      transport.release_gated_reads!
      connection.wait_closed(1.second)
      connection.terminal_error.should be_a(HTTP2::ProtocolError)
      3.times { submissions.receive.should_not be_nil }
    ensure
      connection.close
    end
  end

  it "rejects excessive inbound control traffic" do
    UNIXSocket.pair do |client, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        HTTP2::Frame::Ping.new(0_u8, 0_u32, "too-many").write(io)
        io.flush

        goaway = HTTP2::Frame.read(io).as(HTTP2::Frame::GoAway)
        goaway.error_code.should eq(
          HTTP2::ErrorCode::ENHANCE_YOUR_CALM.to_u32
        )
      end
      configuration = HTTP2::Connection::Configuration.new(
        max_control_frames_per_window: 1
      )
      connection = HTTP2::Connection.start(client, configuration)
      # Diagnostic emission is gated off until `#diagnostics` is first
      # called (see `Connection#diagnostics`), so arm it before the peer
      # drives the frames that trip the limiter below.
      connection.diagnostics
      connection.wait_until_active(1.second)
      connection.wait_closed(1.second)
      connection.terminal_error.should be_a(
        HTTP2::Connection::ResourceLimitError
      )
      diagnostic = nil
      while event = connection.diagnostics.receive?
        if event.kind.connection_error?
          diagnostic = event
          break
        end
      end
      diagnostic.try(&.error_code).should eq(
        HTTP2::ErrorCode::ENHANCE_YOUR_CALM.to_u32
      )
      wait_for_peer(peer_result)
    end
  end

  it "rejects excessive inbound empty frames" do
    UNIXSocket.pair do |client, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        HTTP2::Frame::Unknown.new(
          0xf0_u8,
          0_u8,
          0_u32,
          Bytes.empty
        ).write(io)
        io.flush

        goaway = HTTP2::Frame.read(io).as(HTTP2::Frame::GoAway)
        goaway.error_code.should eq(
          HTTP2::ErrorCode::ENHANCE_YOUR_CALM.to_u32
        )
      end
      configuration = HTTP2::Connection::Configuration.new(
        max_empty_frames_per_window: 1
      )
      connection = HTTP2::Connection.start(client, configuration)
      connection.wait_until_active(1.second)
      connection.wait_closed(1.second)
      connection.terminal_error.should be_a(
        HTTP2::Connection::ResourceLimitError
      )
      wait_for_peer(peer_result)
    end
  end

  it "trips ENHANCE_YOUR_CALM on a GOAWAY flood" do
    UNIXSocket.pair do |client, peer|
      ready = Channel(Nil).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        read_client_headers(io, 1_u32)
        ready.receive

        begin
          1_100.times do
            HTTP2::Frame::GoAway.new(
              1_u32,
              HTTP2::ErrorCode::NO_ERROR
            ).write(io)
          end
          io.flush
        rescue IO::Error
          # The connection may already have reacted to the limiter
          # tripping and force-closed its socket before the flood
          # finished writing all 1_100 frames — that's the point of the
          # test, not a failure; stop writing early instead of treating
          # a broken pipe here as a spec error.
        end

        goaway = HTTP2::Frame.read(io).as(HTTP2::Frame::GoAway)
        goaway.error_code.should eq(
          HTTP2::ErrorCode::ENHANCE_YOUR_CALM.to_u32
        )
      end

      # Default configuration: max_control_frames_per_window is 1_000, so
      # the flood (1_100, comfortably over) trips the limiter without
      # needing a tightened override, within the default 1-second window
      # since the whole flood is written and read essentially at once.
      #
      # last_stream_id is pinned to the one stream this test opens (never
      # 0) so that stream stays active (not "unprocessed") across every
      # flood frame — otherwise, with zero active streams, the
      # connection's drain monitor can independently decide the peer has
      # gone quiet and close with DrainedError, racing the rate limiter
      # tripping (observed under -Dpreview_mt thread-scheduling
      # pressure). Only the rate limiter's own closure is under test
      # here, so that race is closed structurally rather than relying on
      # timing to usually favor the limiter.
      connection = HTTP2::Connection.start(client)
      connection.wait_until_active(1.second)
      stream = connection.new_stream
      open_client_stream(stream)
      ready.send(nil)

      connection.wait_closed(1.second)
      connection.terminal_error.should be_a(
        HTTP2::Connection::ResourceLimitError
      )
      wait_for_peer(peer_result)
    end
  end

  it "resets a stream whose inbound event queue overflows instead of " \
     "closing the connection" do
    UNIXSocket.pair do |client, peer|
      flooded_id = Channel(UInt32).new(1)
      healthy_id = Channel(UInt32).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        flooded = flooded_id.receive
        healthy = healthy_id.receive
        read_client_headers(io, flooded)
        read_client_headers(io, healthy)

        # stream_event_capacity is 2 and nothing ever reads from the
        # flooded stream: the first two PRIORITY frames fill its inbound
        # event queue, the third overflows it.
        3.times do
          HTTP2::Frame::Priority.new(
            0_u8,
            flooded,
            Bytes[0, 0, 0, 0, 15]
          ).write(io)
        end
        io.flush

        reset = HTTP2::Frame.read(io).as(HTTP2::Frame::ResetStream)
        reset.stream_id.should eq(flooded)
        reset.error_code.should eq(
          HTTP2::ErrorCode::ENHANCE_YOUR_CALM.to_u32
        )

        # Composition check: the RST above only reaches the wire after
        # the writer fiber has already removed the stream from the
        # active set and retained it as a LocalReset entry (see
        # `apply_outbound_transition_unlocked`) — so this frame, sent
        # only once that has been observed, exercises the existing
        # reset-tolerant "late frame" path (absorbed, credit restored)
        # rather than a fresh violation or a second RST.
        HTTP2::Frame::Priority.new(
          0_u8,
          flooded,
          Bytes[0, 0, 0, 0, 15]
        ).write(io)

        HTTP2::Frame::Headers.new(
          HTTP2::Frame::Headers::Flags::END_HEADERS |
          HTTP2::Frame::Headers::Flags::END_STREAM,
          healthy,
          Bytes.empty
        ).write(io)
        io.flush
      end

      configuration = HTTP2::Connection::Configuration.new(
        stream_event_capacity: 2
      )
      connection = HTTP2::Connection.start(client, configuration)
      begin
        connection.wait_until_active(1.second)

        flooded_stream = connection.new_stream
        open_client_stream(flooded_stream)
        healthy_stream = connection.new_stream
        open_client_stream(healthy_stream)

        flooded_id.send(flooded_stream.id)
        healthy_id.send(healthy_stream.id)

        # Wait for the peer's entire script (flood, read the RST back,
        # send the late frame, send the healthy response) to finish
        # before this fiber touches either stream. This is not
        # incidental: `flooded_stream`'s inbound channel is buffered, so
        # a receiver of this fiber's own that raced ahead and parked in
        # `#receive` while the flood was still in flight could rendezvous
        # directly with a send that would otherwise have overflowed the
        # queue, silently draining it and masking the very condition this
        # spec exists to trigger — a "parked consumer" must mean "not
        # draining concurrently with the flood," not "actively racing
        # it." The peer only reads the RST_STREAM back after the writer
        # fiber has already run `apply_outbound_transition_unlocked`
        # (which happens before that frame is even flushed), so by the
        # time this returns, the flood's outcome — 2 buffered events, the
        # 3rd rejected — is already settled.
        wait_for_peer(peer_result)

        # `Stream#receive` checks `terminal_error` unconditionally before
        # ever looking at a buffered event (see `Stream#receive`'s first
        # line) — once the stream is terminated, the two PRIORITY events
        # that *did* fit under capacity 2 are no longer individually
        # observable through the public API, even though they are still
        # sitting in the channel. That is pre-existing `Stream#receive`
        # behavior for every termination cause, not specific to this
        # fix — asserted here as the terminal ENHANCE_YOUR_CALM error,
        # not a third buffered frame.
        error = expect_raises(HTTP2::ProtocolError) do
          flooded_stream.receive(1.second)
        end
        error.error_code.should eq(HTTP2::ErrorCode::ENHANCE_YOUR_CALM)

        healthy_stream.receive(1.second).should be_a(
          HTTP2::Connection::FieldSection
        )
        connection.active?.should be_true
      ensure
        connection.close
      end
    end
  end

  it "terminates a stream locally, without an RST, when the closing " \
     "event itself overflows an already-full queue" do
    UNIXSocket.pair do |client, peer|
      victim_id = Channel(UInt32).new(1)
      other_id = Channel(UInt32).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        victim = victim_id.receive
        other = other_id.receive
        read_client_headers(io, victim)
        read_client_headers(io, other)

        # Fill the queue (capacity 2) with two ordinary PRIORITY frames,
        # then send trailers (HEADERS+END_STREAM) as the third. `victim`
        # is already half-closed(local) (its own HEADERS carried
        # END_STREAM), so this closing event both overflows the queue
        # AND is the one whose own transition removes the stream from
        # the active set — inside `transition_and_deliver`, *before*
        # delivery is even attempted. That is a different branch of the
        # fix than the plain-overflow case above (where the stream was
        # still active when the overflow was detected).
        2.times do
          HTTP2::Frame::Priority.new(
            0_u8,
            victim,
            Bytes[0, 0, 0, 0, 15]
          ).write(io)
        end
        HTTP2::Frame::Headers.new(
          HTTP2::Frame::Headers::Flags::END_HEADERS |
          HTTP2::Frame::Headers::Flags::END_STREAM,
          victim,
          Bytes.empty
        ).write(io)
        io.flush

        # Nothing is owed to the peer for `victim` here — RFC 9113 has no
        # RST to send once both sides already agree a stream is done.
        # Actually verified, not just asserted by omission: a PING sent
        # immediately after goes through the same single, FIFO-ordered
        # writer queue as an RST would, so if one had been sent (a
        # regression), it would be the *next* frame read back here, and
        # the `.as(HTTP2::Frame::Ping)` cast below would fail instead of
        # silently passing.
        ping = HTTP2::Frame::Ping.new(0_u8, 0_u32, "no-rst!!")
        ping.write(io)
        io.flush
        reply = HTTP2::Frame.read(io).as(HTTP2::Frame::Ping)
        reply.ack?.should be_true
        reply.payload.should eq(ping.payload)

        HTTP2::Frame::Headers.new(
          HTTP2::Frame::Headers::Flags::END_HEADERS |
          HTTP2::Frame::Headers::Flags::END_STREAM,
          other,
          Bytes.empty
        ).write(io)
        io.flush
      end

      configuration = HTTP2::Connection::Configuration.new(
        stream_event_capacity: 2
      )
      connection = HTTP2::Connection.start(client, configuration)
      begin
        connection.wait_until_active(1.second)

        victim_stream = connection.new_stream
        open_client_stream(victim_stream)
        other_stream = connection.new_stream
        open_client_stream(other_stream)

        victim_id.send(victim_stream.id)
        other_id.send(other_stream.id)

        wait_for_peer(peer_result)

        other_stream.receive(1.second).should be_a(
          HTTP2::Connection::FieldSection
        )

        error = expect_raises(HTTP2::ProtocolError) do
          victim_stream.receive(1.second)
        end
        error.error_code.should eq(HTTP2::ErrorCode::ENHANCE_YOUR_CALM)
        connection.active?.should be_true
      ensure
        connection.close
      end
    end
  end

  it "resets a stream whose inbound DATA queue overflows instead of " \
     "closing the connection, restoring the discarded connection credit" do
    UNIXSocket.pair do |client, peer|
      flooded_id = Channel(UInt32).new(1)
      healthy_id = Channel(UInt32).new(1)
      peer_result = scripted_peer(peer) do |io|
        # A manual, non-acknowledging handshake (same idiom as the
        # pre-ACK PUSH_PROMISE spec in connection_control_spec.cr): the
        # peer never sends `Settings.ack`, so `@effective_local_settings_
        # state` stays at `client_defaults` (initial_window_size 65_535)
        # for streams opened below. This deliberately decouples the
        # stream's flow-control receive window (stays spacious) from
        # `max_buffered_body_bytes` (always applied directly as the body
        # buffer's own capacity, 8, regardless of ack state) — otherwise
        # `synchronize_advertised_initial_window_size!` ties the two
        # together and the flood would trip stream-level flow control
        # (a pre-existing, different check) before ever reaching the
        # body buffer this spec targets. This is not a contrived setup:
        # it is the same pre-ACK race Task 7's report flagged as the
        # only way a peer can outrun a reduced max_buffered_body_bytes.
        read_client_preface(io)
        HTTP2::Frame::Settings.new(
          [] of HTTP2::Frame::Settings::Setting
        ).write(io)
        io.flush
        skip_startup_window_update(io)
          .as(HTTP2::Frame::Settings)
          .ack?
          .should be_true

        flooded = flooded_id.receive
        healthy = healthy_id.receive
        read_client_headers(io, flooded)
        read_client_headers(io, healthy)

        # max_buffered_body_bytes is 8 and nothing ever reads the flooded
        # stream's body: the first two 4-byte DATA frames fill it exactly,
        # the third overflows it. None carries END_STREAM, so the stream
        # stays half-closed(local) (registered in @streams) through the
        # whole flood — this exercises the "still active" branch.
        3.times do
          HTTP2::Frame::Data.new(
            0_u8,
            flooded,
            Bytes.new(4, 0x61_u8)
          ).write(io)
        end
        io.flush

        # All 12 charged bytes (3 frames x 4) must come back as connection
        # credit: 4 for the rejected 3rd frame (released immediately) plus
        # 8 for the two already-buffered, never-consumed frames (released
        # once the reset stream is actually torn down). The two releases
        # do not necessarily land in the same WINDOW_UPDATE, so accumulate
        # until the full amount is seen rather than assuming one frame.
        reset_seen = false
        connection_credit = 0_u32
        until reset_seen && connection_credit >= 12_u32
          frame = HTTP2::Frame.read(io)
          case frame
          when HTTP2::Frame::ResetStream
            frame.stream_id.should eq(flooded)
            frame.error_code.should eq(
              HTTP2::ErrorCode::ENHANCE_YOUR_CALM.to_u32
            )
            reset_seen = true
          when HTTP2::Frame::WindowUpdate
            if frame.stream_id == 0_u32
              connection_credit += frame.window_size_increment
            end
          end
        end
        connection_credit.should eq(12_u32)

        # Boundary checkpoint: exactly 12 bytes must be restored, not more.
        # A stray extra credit frame (e.g. a double-release bug) would be
        # the very next frame read back here instead of the PING's own
        # pong — a hard cast, not a skip-loop, so it fails loudly.
        ping = HTTP2::Frame::Ping.new(0_u8, 0_u32, "restored")
        ping.write(io)
        io.flush
        pong = HTTP2::Frame.read(io).as(HTTP2::Frame::Ping)
        pong.ack?.should be_true
        pong.payload.should eq(ping.payload)

        HTTP2::Frame::Headers.new(
          HTTP2::Frame::Headers::Flags::END_HEADERS |
          HTTP2::Frame::Headers::Flags::END_STREAM,
          healthy,
          Bytes.empty
        ).write(io)
        io.flush
      end

      configuration = HTTP2::Connection::Configuration.new(
        max_buffered_body_bytes: 8
      )
      connection = HTTP2::Connection.start(client, configuration)
      begin
        connection.wait_until_active(1.second)

        flooded_stream = connection.new_stream
        open_client_stream(flooded_stream)
        healthy_stream = connection.new_stream
        open_client_stream(healthy_stream)

        flooded_id.send(flooded_stream.id)
        healthy_id.send(healthy_stream.id)

        # As in the event-queue sibling spec above: wait for the peer's
        # entire script (flood, observe the RST and credit, checkpoint,
        # send the healthy response) before this fiber touches either
        # stream, so nothing here can race the flood's own outcome.
        wait_for_peer(peer_result)

        flooded_stream.terminal_error.as(HTTP2::ProtocolError)
          .error_code.should eq(HTTP2::ErrorCode::ENHANCE_YOUR_CALM)

        error = expect_raises(HTTP2::ProtocolError) do
          flooded_stream.body.read(Bytes.new(1))
        end
        error.error_code.should eq(HTTP2::ErrorCode::ENHANCE_YOUR_CALM)

        healthy_stream.receive(1.second).should be_a(
          HTTP2::Connection::FieldSection
        )
        connection.active?.should be_true
      ensure
        connection.close
      end
    end
  end

  it "terminates a stream locally, without an RST, when the DATA " \
     "frame that overflows an already-full queue also ends the " \
     "stream, still restoring the discarded connection credit" do
    UNIXSocket.pair do |client, peer|
      victim_id = Channel(UInt32).new(1)
      other_id = Channel(UInt32).new(1)
      peer_result = scripted_peer(peer) do |io|
        # See the DATA-flood spec above for why this handshake
        # deliberately withholds `Settings.ack` (decouples the stream's
        # flow-control receive window from max_buffered_body_bytes).
        read_client_preface(io)
        HTTP2::Frame::Settings.new(
          [] of HTTP2::Frame::Settings::Setting
        ).write(io)
        io.flush
        skip_startup_window_update(io)
          .as(HTTP2::Frame::Settings)
          .ack?
          .should be_true

        victim = victim_id.receive
        other = other_id.receive
        read_client_headers(io, victim)
        read_client_headers(io, other)

        # Fill the queue (capacity 8) with two ordinary 4-byte DATA
        # frames, then send a third, END_STREAM-flagged 4-byte frame.
        # `victim` is already half-closed(local) (its own HEADERS carried
        # END_STREAM), so this closing frame both overflows the buffer
        # AND is the one whose own transition removes the stream from
        # the active set — inside `accept_inbound_data`, *before*
        # `deliver_data` is even attempted. That is a different branch
        # of the fix than the plain-overflow case above (where the
        # stream was still active when the overflow was detected).
        2.times do
          HTTP2::Frame::Data.new(
            0_u8,
            victim,
            Bytes.new(4, 0x62_u8)
          ).write(io)
        end
        HTTP2::Frame::Data.new(
          HTTP2::Frame::Data::Flags::END_STREAM,
          victim,
          Bytes.new(4, 0x62_u8)
        ).write(io)
        io.flush

        # Nothing is owed to the peer for `victim` here — RFC 9113 has no
        # RST to send once both sides already agree a stream is done. All
        # 12 charged bytes still come back as connection credit even
        # though no RST is involved: 4 for the rejected 3rd frame
        # (released immediately) plus 8 for the two already-buffered
        # frames (released by the direct local-termination branch).
        connection_credit = 0_u32
        until connection_credit >= 12_u32
          frame = HTTP2::Frame.read(io).as(HTTP2::Frame::WindowUpdate)
          connection_credit += frame.window_size_increment if frame.stream_id == 0_u32
        end
        connection_credit.should eq(12_u32)

        # Verified, not just asserted by omission: a PING sent immediately
        # after goes through the same single, FIFO-ordered writer queue as
        # an RST would, so if one had been sent (a regression), it would
        # be the *next* frame read back here, and the `.as(Ping)` cast
        # below would fail instead of silently passing.
        ping = HTTP2::Frame::Ping.new(0_u8, 0_u32, "no-rst!!")
        ping.write(io)
        io.flush
        reply = HTTP2::Frame.read(io).as(HTTP2::Frame::Ping)
        reply.ack?.should be_true
        reply.payload.should eq(ping.payload)

        HTTP2::Frame::Headers.new(
          HTTP2::Frame::Headers::Flags::END_HEADERS |
          HTTP2::Frame::Headers::Flags::END_STREAM,
          other,
          Bytes.empty
        ).write(io)
        io.flush
      end

      configuration = HTTP2::Connection::Configuration.new(
        max_buffered_body_bytes: 8
      )
      connection = HTTP2::Connection.start(client, configuration)
      begin
        connection.wait_until_active(1.second)

        victim_stream = connection.new_stream
        open_client_stream(victim_stream)
        other_stream = connection.new_stream
        open_client_stream(other_stream)

        victim_id.send(victim_stream.id)
        other_id.send(other_stream.id)

        wait_for_peer(peer_result)

        other_stream.receive(1.second).should be_a(
          HTTP2::Connection::FieldSection
        )

        error = expect_raises(HTTP2::ProtocolError) do
          victim_stream.body.read(Bytes.new(1))
        end
        error.error_code.should eq(HTTP2::ErrorCode::ENHANCE_YOUR_CALM)
        connection.active?.should be_true
      ensure
        connection.close
      end
    end
  end

  it "emits bounded structured frame and settings diagnostics" do
    UNIXSocket.pair do |client, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        ping = HTTP2::Frame::Ping.new(0_u8, 0_u32, "observe!")
        ping.write(io)
        io.flush
        HTTP2::Frame.read(io).as(HTTP2::Frame::Ping).ack?.should be_true
      end

      connection = HTTP2::Connection.start(client)
      # Diagnostic emission is gated off until `#diagnostics` is first
      # called (see `Connection#diagnostics`), so arm it before the
      # handshake's SETTINGS and the scripted PING exchange below fire.
      connection.diagnostics
      connection.wait_until_active(1.second)
      wait_for_peer(peer_result)

      inbound_ping = false
      outbound_ping = false
      settings = false
      until inbound_ping && outbound_ping && settings
        diagnostic = select
        when value = connection.diagnostics.receive
          value
        when timeout(1.second)
          fail("expected connection diagnostics were not emitted")
        end
        next unless diagnostic.kind.frame?

        settings ||= !diagnostic.settings.nil?
        next unless diagnostic.frame_type == HTTP2::Frame::Ping::TypeCode

        inbound_ping ||= diagnostic.direction.inbound? &&
                         diagnostic.flags == 0_u8
        outbound_ping ||= diagnostic.direction.outbound? &&
                          diagnostic.flags == 1_u8
      end

      connection.close
      connection.diagnostics.receive?.should be_a(
        HTTP2::Connection::Diagnostic
      )
    end
  end

  it "drops diagnostics instead of blocking the protocol fibers" do
    UNIXSocket.pair do |client, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        HTTP2::Frame::Ping.new(0_u8, 0_u32, "bounded!").write(io)
        io.flush
        HTTP2::Frame.read(io).as(HTTP2::Frame::Ping).ack?.should be_true
      end
      configuration = HTTP2::Connection::Configuration.new(
        diagnostic_queue_capacity: 1
      )
      connection = HTTP2::Connection.start(client, configuration)
      # Diagnostic emission is gated off until `#diagnostics` is first
      # called (see `Connection#diagnostics`), so arm it before the
      # handshake's SETTINGS and the scripted PING below overflow the
      # single-slot queue.
      connection.diagnostics
      connection.wait_until_active(1.second)
      wait_for_peer(peer_result)
      connection.dropped_diagnostic_count.should be > 0_u64
      connection.close
    end
  end

  it "closes the connection with FRAME_SIZE_ERROR when an inbound frame " \
     "exceeds our advertised SETTINGS_MAX_FRAME_SIZE" do
    UNIXSocket.pair do |client, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)

        # One octet past the default advertised SETTINGS_MAX_FRAME_SIZE
        # (16_384) -- an extension type unknown to this implementation, so
        # if the size guard were ever bypassed the frame would merely be
        # ignored (RFC 9113 4.1) rather than tripping some unrelated,
        # frame-specific validation and muddying what actually failed.
        # The real bytes (not just a declared length) are sent so that a
        # bypassed guard reads a complete, well-formed frame instead of
        # blocking on payload bytes that were never written.
        oversized = Bytes.new(
          HTTP2::FrameHeader::DEFAULT_MAX_PAYLOAD + 1,
          0x41_u8
        )
        io.write(wire_frame(0xff_u8, 0_u8, 0_u32, oversized))
        io.flush

        goaway = HTTP2::Frame.read(io).as(HTTP2::Frame::GoAway)
        goaway.error_code.should eq(HTTP2::ErrorCode::FRAME_SIZE_ERROR.to_u32)
      end

      connection = HTTP2::Connection.start(client)
      connection.wait_until_active(1.second)
      connection.wait_closed(1.second)
      connection.terminal_error.should be_a(HTTP2::FrameSizeError)
      wait_for_peer(peer_result)
    end
  end

  it "trips the empty-frame limiter on a zero-length DATA flood with no " \
     "END_STREAM on an open stream" do
    UNIXSocket.pair do |client, peer|
      ready = Channel(Nil).new(1)
      stream_id = Channel(UInt32).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        id = stream_id.receive
        read_client_headers(io, id)
        ready.receive

        begin
          1_100.times do
            HTTP2::Frame::Data.new(0_u8, id, Bytes.empty).write(io)
          end
          io.flush
        rescue IO::Error
          # The connection may already have reacted to the limiter
          # tripping and force-closed its socket before the flood
          # finished writing all 1_100 frames -- that's the point of the
          # test, not a failure; stop writing early instead of treating a
          # broken pipe here as a spec error.
        end

        goaway = HTTP2::Frame.read(io).as(HTTP2::Frame::GoAway)
        goaway.error_code.should eq(HTTP2::ErrorCode::ENHANCE_YOUR_CALM.to_u32)
      end

      # Default configuration: max_empty_frames_per_window is 1_000, so the
      # flood (1_100, comfortably over) trips the limiter within the
      # default 1-second window. The stream is opened without END_STREAM
      # on either side and stays that way throughout: a zero-length DATA
      # frame always succeeds at StreamBody#enqueue (its `return true if
      # data.empty?` short-circuit runs before the capacity check) and
      # never touches the per-stream event queue at all (DATA is
      # delivered via Stream#deliver_data, a completely different path
      # from Stream#deliver's stream_event_capacity-bounded channel that
      # PRIORITY/HEADERS events use) -- so the connection-level
      # empty-frame counter is the only limiter this flood can trip.
      connection = HTTP2::Connection.start(client)
      connection.wait_until_active(1.second)
      stream = connection.new_stream
      open_client_stream(stream, end_stream: false)
      stream_id.send(stream.id)
      ready.send(nil)

      connection.wait_closed(1.second)
      connection.terminal_error.should be_a(
        HTTP2::Connection::ResourceLimitError
      )
      wait_for_peer(peer_result)
    end
  end

  it "processes a max-size inbound GOAWAY without unbounded retention, " \
     "then a PING normally" do
    UNIXSocket.pair do |client, peer|
      stream_id = Channel(UInt32).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        id = stream_id.receive
        read_client_headers(io, id)

        # At the boundary this implementation will ever accept without
        # tripping the FRAME_SIZE_ERROR pinned above: debug data fills
        # the frame out to exactly the default inbound max frame size
        # (16_384 octets total; 8 of those are the fixed last-stream-id +
        # error-code fields GOAWAY always carries).
        debug_data = Bytes.new(
          HTTP2::FrameHeader::DEFAULT_MAX_PAYLOAD - 8,
          0x58_u8
        )
        HTTP2::Frame::GoAway.new(
          id,
          HTTP2::ErrorCode::NO_ERROR,
          debug_data
        ).write(io)
        ping = HTTP2::Frame::Ping.new(0_u8, 0_u32, "still-ok")
        ping.write(io)
        io.flush

        pong = HTTP2::Frame.read(io).as(HTTP2::Frame::Ping)
        pong.ack?.should be_true
        pong.payload.should eq(ping.payload)
      end

      # last_stream_id is pinned to the one stream this test opens (same
      # idiom as the GOAWAY-flood spec above) so it stays active rather
      # than idle -- otherwise, with zero active streams, the drain
      # monitor's own independent quiet-peer check could race this
      # GOAWAY and close the connection with DrainedError before the
      # PING below ever gets a chance to prove the connection is still
      # healthy (see the GOAWAY-flood spec's comment for the full
      # explanation of that race).
      connection = HTTP2::Connection.start(client)
      # Diagnostic emission is gated off until `#diagnostics` is first
      # called (see `Connection#diagnostics`), so arm it before the peer's
      # GOAWAY and PING below fire.
      connection.diagnostics
      connection.wait_until_active(1.second)
      stream = connection.new_stream
      open_client_stream(stream)
      stream_id.send(stream.id)

      wait_for_peer(peer_result)

      connection.draining?.should be_true
      connection.stream?(stream.id).should be(stream)

      goaway = connection.last_goaway.as(HTTP2::Frame::GoAway)
      goaway.debug_data.size.should eq(
        HTTP2::FrameHeader::DEFAULT_MAX_PAYLOAD - 8
      )

      # `Diagnostic` (connection/diagnostic.cr) deliberately has no field
      # for a frame's raw payload or GOAWAY's debug data -- only a
      # `payload_length` count. Confirm the emitted frame diagnostic
      # actually reflects that design (an Int32 length, not the
      # 16_376-byte string, and no message built from it) and that the
      # lifecycle diagnostic emitted alongside it is the fixed, short
      # literal `emit_lifecycle` always sends, not something sized off
      # the debug data.
      found_frame = false
      found_lifecycle = false
      until found_frame && found_lifecycle
        diagnostic = select
        when value = connection.diagnostics.receive
          value
        when timeout(1.second)
          fail("expected GOAWAY diagnostics were not emitted")
        end

        if diagnostic.kind.frame? &&
           diagnostic.frame_type == HTTP2::Frame::GoAway::TypeCode
          diagnostic.payload_length.should eq(
            HTTP2::FrameHeader::DEFAULT_MAX_PAYLOAD
          )
          diagnostic.message.should be_nil
          found_frame = true
        elsif diagnostic.kind.lifecycle? &&
              diagnostic.message == "draining after peer GOAWAY"
          found_lifecycle = true
        end
      end

      connection.close
    end
  end

  it "trips ENHANCE_YOUR_CALM on an RST_STREAM flood" do
    UNIXSocket.pair do |client, peer|
      ready = Channel(Nil).new(1)
      stream_id = Channel(UInt32).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        id = stream_id.receive
        read_client_headers(io, id)
        ready.receive

        begin
          1_100.times do
            HTTP2::Frame::ResetStream.new(
              id,
              HTTP2::ErrorCode::CANCEL
            ).write(io)
          end
          io.flush
        rescue IO::Error
          # As with the GOAWAY flood above: the connection may already
          # have reacted to the limiter tripping and force-closed its
          # socket before the flood finished writing all 1_100 frames.
        end

        goaway = HTTP2::Frame.read(io).as(HTTP2::Frame::GoAway)
        goaway.error_code.should eq(HTTP2::ErrorCode::ENHANCE_YOUR_CALM.to_u32)
      end

      # Default configuration: max_control_frames_per_window is 1_000, and
      # RST_STREAM is one of InboundFrameRateLimiter#control_frame?'s
      # recognized types. The first RST_STREAM legitimately closes
      # `stream` (retained as a RemoteReset "late frame" target for the
      # rest of the flood, per ClosedStream#tolerates_late_frames?), but
      # observe_inbound_frame's rate-limiter check runs unconditionally
      # on every inbound frame before any of that per-stream handling, so
      # it never matters whether a given RST_STREAM is the first (a real
      # reset) or the 1_099th (an absorbed repeat) -- unlike the GOAWAY
      # flood above, this never touches @last_goaway or starts the drain
      # monitor, so no active stream needs to be kept alive for the flood
      # itself to trip the limiter; opening one is only what makes the
      # first RST_STREAM legal instead of "RST_STREAM on an idle stream"
      # (its own, different connection error).
      connection = HTTP2::Connection.start(client)
      connection.wait_until_active(1.second)
      stream = connection.new_stream
      open_client_stream(stream)
      stream_id.send(stream.id)
      ready.send(nil)

      connection.wait_closed(1.second)
      connection.terminal_error.should be_a(
        HTTP2::Connection::ResourceLimitError
      )
      wait_for_peer(peer_result)
    end
  end

  it "closes the connection when the peer sends a repeated trailer-like " \
     "HEADERS frame after a stream has already fully closed" do
    UNIXSocket.pair do |client, peer|
      stream_id = Channel(UInt32).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        id = stream_id.receive
        read_client_headers(io, id)

        encoder = HPack::Encoder.new
        # A normal final response followed by one legitimate trailer
        # section that cleanly ends the stream -- pins that ordinary
        # trailers still work before exercising the adversarial case.
        io.write(encode_headers_frame(encoder, id, [{":status", "200"}]))
        io.write(
          encode_headers_frame(
            encoder,
            id,
            [{"x-trace-id", "legitimate"}],
            end_stream: true
          )
        )
        io.flush

        # Repeated: a second, trailer-shaped HEADERS frame for the same
        # stream ID, arriving after both sides already agree it is
        # closed.
        io.write(
          encode_headers_frame(
            encoder,
            id,
            [{"x-trace-id", "too-late"}],
            end_stream: true
          )
        )
        io.flush

        goaway = HTTP2::Frame.read(io).as(HTTP2::Frame::GoAway)
        goaway.error_code.should eq(HTTP2::ErrorCode::STREAM_CLOSED.to_u32)
      end

      connection = HTTP2::Connection.start(client)
      connection.wait_until_active(1.second)
      stream = connection.new_stream
      stream.inbound_validator =
        HTTP2::ResponseValidator.new(stream.id, "GET")
      open_client_stream(stream)
      stream_id.send(stream.id)

      # The stream closes cleanly (mutual END_STREAM) well before the
      # connection-level violation lands, so the connection removes it
      # from its own registry -- but a clean close never calls
      # Stream#terminate, so this Stream object's own terminal_error
      # stays nil regardless of what later happens to the connection, and
      # these two receives cannot race the later connection failure (see
      # Stream#receive: it only ever raises this stream's OWN
      # terminal_error, never the connection's).
      stream.receive(1.second).should be_a(HTTP2::Connection::FieldSection)
      trailer = stream.receive(1.second).as(HTTP2::Connection::FieldSection)
      trailer.end_stream?.should be_true

      wait_for_peer(peer_result)

      connection.wait_closed(1.second)
      error = connection.terminal_error.as(HTTP2::ProtocolError)
      error.error_code.should eq(HTTP2::ErrorCode::STREAM_CLOSED)
      error.scope.should eq(HTTP2::ErrorScope::Connection)
    end
  end

  it "closes the connection when a CONTINUATION sequence exceeds the " \
     "configured fragment-count limit" do
    UNIXSocket.pair do |client, peer|
      stream_id = Channel(UInt32).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        id = stream_id.receive
        read_client_headers(io, id)

        # An opening HEADERS frame (no END_HEADERS) followed by 17
        # CONTINUATION fragments -- one past the default
        # max_continuation_frames (16). Fragment content is irrelevant:
        # the count check in FieldBlockAssembler#continue runs before
        # HPACK decode ever sees a byte of it (field_block_assembler_spec.cr
        # pins the same limit at the unit level directly against the
        # assembler; this is its socket-level twin).
        HTTP2::Frame::Headers.new(0_u8, id, Bytes[0]).write(io)
        17.times do
          HTTP2::Frame::Continuation.new(0_u8, id, Bytes[0]).write(io)
        end
        io.flush

        goaway = HTTP2::Frame.read(io).as(HTTP2::Frame::GoAway)
        goaway.error_code.should eq(HTTP2::ErrorCode::ENHANCE_YOUR_CALM.to_u32)
      end

      connection = HTTP2::Connection.start(client)
      connection.wait_until_active(1.second)
      stream = connection.new_stream
      open_client_stream(stream)
      stream_id.send(stream.id)

      connection.wait_closed(1.second)
      connection.terminal_error.should be_a(
        HTTP2::Connection::ResourceLimitError
      )
      wait_for_peer(peer_result)
    end
  end
end
