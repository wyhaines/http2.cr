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
      connection.wait_until_active(1.second)
      wait_for_peer(peer_result)
      connection.dropped_diagnostic_count.should be > 0_u64
      connection.close
    end
  end
end
