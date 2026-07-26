require "./spec_helper"

describe HTTP2::Connection do
  it "rejects a legal pre-ACK push with RST_STREAM" do
    UNIXSocket.pair do |client, peer|
      parent_id = Channel(UInt32).new(1)
      peer_result = scripted_peer(peer) do |io|
        client_settings = read_client_preface(io)
        push = client_settings.entries.find do |setting|
          setting.known_identifier.try(&.enable_push?)
        end
        push.try(&.value).should eq(0_u32)

        HTTP2::Frame::Settings.new(
          [] of HTTP2::Frame::Settings::Setting
        ).write(io)
        io.flush
        skip_startup_window_update(io)
          .as(HTTP2::Frame::Settings)
          .ack?
          .should be_true

        id = parent_id.receive
        read_client_headers(io, id)
        HTTP2::Frame::PushPromise.new(
          HTTP2::Frame::PushPromise::Flags::END_HEADERS,
          id,
          2_u32
        ).write(io)
        io.flush

        reset = HTTP2::Frame.read(io).as(HTTP2::Frame::ResetStream)
        reset.stream_id.should eq(2_u32)
        reset.error_code.should eq(HTTP2::ErrorCode::CANCEL.to_u32)

        HTTP2::Frame::Settings.ack.write(io)
        io.flush
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        parent = connection.new_stream
        open_client_stream(parent)
        parent_id.send(parent.id)

        wait_for_peer(peer_result)
        eventually do
          connection.pending_settings_count.zero?
        end
        connection.active?.should be_true
        connection.stream?(2_u32).should be_nil
      ensure
        connection.close
      end
    end
  end

  it "bounds pre-ACK PUSH_PROMISE tolerance" do
    UNIXSocket.pair do |client, peer|
      parent_id = Channel(UInt32).new(1)
      peer_result = scripted_peer(peer) do |io|
        read_client_preface(io)

        HTTP2::Frame::Settings.new(
          [] of HTTP2::Frame::Settings::Setting
        ).write(io)
        io.flush
        skip_startup_window_update(io)
          .as(HTTP2::Frame::Settings)
          .ack?
          .should be_true

        id = parent_id.receive
        read_client_headers(io, id)

        # 9 promises before the client's own ENABLE_PUSH=0 SETTINGS is
        # ever acknowledged (this script never sends that ACK) — one
        # more than the configured (default 8) pre-ACK tolerance, each
        # individually well-formed and targeting a distinct, increasing,
        # even promised stream ID.
        9.times do |index|
          HTTP2::Frame::PushPromise.new(
            HTTP2::Frame::PushPromise::Flags::END_HEADERS,
            id,
            ((index + 1) * 2).to_u32
          ).write(io)
        end
        io.flush

        # The 8 promises within tolerance are each individually accepted
        # and then immediately auto-cancelled (this library never
        # actually consumes a push — see the "rejects a legal pre-ACK
        # push" example above), so their RST_STREAM(CANCEL) frames
        # interleave with the eventual GOAWAY on the wire; skip past
        # them to the connection-level violation this example targets.
        goaway = nil
        until goaway
          frame = HTTP2::Frame.read(io)
          goaway = frame.as?(HTTP2::Frame::GoAway)
        end
        goaway.error_code.should eq(HTTP2::ErrorCode::PROTOCOL_ERROR.to_u32)
      end

      connection = HTTP2::Connection.start(client)
      connection.wait_until_active(1.second)
      parent = connection.new_stream
      open_client_stream(parent)
      parent_id.send(parent.id)

      connection.wait_closed(1.second)
      error = connection.terminal_error.as(HTTP2::ProtocolError)
      error.error_code.should eq(HTTP2::ErrorCode::PROTOCOL_ERROR)
      wait_for_peer(peer_result)
    end
  end

  it "closes when PUSH_PROMISE arrives after push-disable acknowledgement" do
    UNIXSocket.pair do |client, peer|
      parent_id = Channel(UInt32).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        id = parent_id.receive
        read_client_headers(io, id)
        HTTP2::Frame::PushPromise.new(
          HTTP2::Frame::PushPromise::Flags::END_HEADERS,
          id,
          2_u32
        ).write(io)
        io.flush

        goaway = HTTP2::Frame.read(io).as(HTTP2::Frame::GoAway)
        goaway.error_code.should eq(HTTP2::ErrorCode::PROTOCOL_ERROR.to_u32)
      end

      connection = HTTP2::Connection.start(client)
      connection.wait_until_active(1.second)
      eventually do
        connection.pending_settings_count.zero?
      end
      parent = connection.new_stream
      open_client_stream(parent)
      parent_id.send(parent.id)

      connection.wait_closed(1.second)
      error = connection.terminal_error.as(HTTP2::ProtocolError)
      error.error_code.should eq(HTTP2::ErrorCode::PROTOCOL_ERROR)
      wait_for_peer(peer_result)
    end
  end

  it "ignores PRIORITY on an idle stream without creating it" do
    UNIXSocket.pair do |client, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        HTTP2::Frame::Priority.new(
          0_u8,
          99_u32,
          Bytes[0, 0, 0, 0, 15]
        ).write(io)
        ping = HTTP2::Frame::Ping.new(0_u8, 0_u32, "priority")
        ping.write(io)
        io.flush
        HTTP2::Frame.read(io).as(HTTP2::Frame::Ping).ack?.should be_true
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        wait_for_peer(peer_result)
        connection.stream?(99_u32).should be_nil
        connection.active?.should be_true
      ensure
        connection.close
      end
    end
  end

  it "resets a stream that sends PRIORITY depending on itself" do
    UNIXSocket.pair do |client, peer|
      stream_id = Channel(UInt32).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        id = stream_id.receive
        read_client_headers(io, id)

        # Built from raw wire bytes, not `Frame::Priority.new` — that
        # constructor now performs this same self-dependency validation
        # (see priority_frame_spec.cr), so it cannot be used to build the
        # malformed frame a real non-conforming peer would send.
        payload = Bytes.new(5)
        IO::ByteFormat::BigEndian.encode(id, payload[0, 4])
        payload[4] = 15_u8
        io.write(wire_frame(HTTP2::Frame::Priority::TypeCode, 0_u8, id, payload))
        io.flush

        reset = HTTP2::Frame.read(io).as(HTTP2::Frame::ResetStream)
        reset.stream_id.should eq(id)
        reset.error_code.should eq(HTTP2::ErrorCode::PROTOCOL_ERROR.to_u32)
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        stream = connection.new_stream
        open_client_stream(stream, end_stream: false)
        stream_id.send(stream.id)
        eventually { stream.closed? }
        connection.active?.should be_true
        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end

  it "rejects increasing last stream IDs across received GOAWAY frames" do
    UNIXSocket.pair do |client, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        HTTP2::Frame::GoAway.new(
          1_u32,
          HTTP2::ErrorCode::NO_ERROR
        ).write(io)
        HTTP2::Frame::GoAway.new(
          3_u32,
          HTTP2::ErrorCode::NO_ERROR
        ).write(io)
        io.flush

        reply = HTTP2::Frame.read(io).as(HTTP2::Frame::GoAway)
        reply.error_code.should eq(HTTP2::ErrorCode::PROTOCOL_ERROR.to_u32)
      end

      connection = HTTP2::Connection.start(client)
      connection.wait_until_active(1.second)
      connection.wait_closed(1.second)
      error = connection.terminal_error.as(HTTP2::ProtocolError)
      error.error_code.should eq(HTTP2::ErrorCode::PROTOCOL_ERROR)
      wait_for_peer(peer_result)
    end
  end

  it "carries the original error code when the server preface is " \
     "malformed" do
    UNIXSocket.pair do |client, peer|
      peer_result = scripted_peer(peer) do |io|
        read_client_preface(io)
        HTTP2::FrameHeader.new(
          20_000,
          HTTP2::Frame::Settings::TypeCode,
          0_u8,
          0_u32
        ).write(io)
        io.flush

        goaway = skip_startup_window_update(io).as(HTTP2::Frame::GoAway)
        goaway.error_code.should eq(
          HTTP2::ErrorCode::FRAME_SIZE_ERROR.to_u32
        )
      end

      connection = HTTP2::Connection.start(client)
      connection.wait_closed(1.second)
      error = connection.terminal_error.as(HTTP2::ProtocolError)
      error.error_code.should eq(HTTP2::ErrorCode::FRAME_SIZE_ERROR)
      wait_for_peer(peer_result)
    end
  end

  it "enters draining state after sending GOAWAY" do
    UNIXSocket.pair do |client, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        goaway = HTTP2::Frame.read(io).as(HTTP2::Frame::GoAway)
        goaway.last_stream_id.should eq(0_u32)
        goaway.error_code.should eq(HTTP2::ErrorCode::NO_ERROR.to_u32)
        io.read(Bytes.new(1)).should eq(0)
      end

      connection = HTTP2::Connection.start(client)
      connection.wait_until_active(1.second)
      connection.write_frame(
        HTTP2::Frame::GoAway.new(
          0_u32,
          HTTP2::ErrorCode::NO_ERROR
        )
      )
      connection.draining?.should be_true
      expect_raises(HTTP2::Connection::InvalidStateError) do
        connection.new_stream
      end
      expect_raises(HTTP2::Connection::InvalidStateError, /cannot increase/) do
        connection.write_frame(
          HTTP2::Frame::GoAway.new(
            2_u32,
            HTTP2::ErrorCode::NO_ERROR
          )
        )
      end

      connection.close
      wait_for_peer(peer_result)
    end
  end

  it "fails an in-flight stream with the peer's GOAWAY code when the " \
     "connection then hits EOF" do
    UNIXSocket.pair do |client, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        read_client_headers(io, 1_u32)
        HTTP2::Frame::GoAway.new(
          1_u32,
          HTTP2::ErrorCode::INTERNAL_ERROR.to_u32,
          "server is restarting"
        ).write(io)
        io.flush
        io.close
      end

      connection = HTTP2::Connection.start(client)
      connection.wait_until_active(1.second)
      stream = connection.new_stream
      open_client_stream(stream)

      connection.wait_closed(1.second)
      error = expect_raises(HTTP2::Connection::GoAwayTerminationError) do
        stream.receive(1.second)
      end
      error.error_code.should eq(HTTP2::ErrorCode::INTERNAL_ERROR.to_u32)
      error.message.to_s.should contain("server is restarting")
      connection.terminal_error.should be_a(
        HTTP2::Connection::GoAwayTerminationError
      )
      wait_for_peer(peer_result)
    end
  end

  it "sanitizes control characters and truncates oversized GOAWAY " \
     "debug data" do
    injected = HTTP2::Frame::GoAway.new(
      0_u32,
      HTTP2::ErrorCode::INTERNAL_ERROR.to_u32,
      "A \e[31mRED\a"
    )
    error = HTTP2::Connection::GoAwayTerminationError.new(injected)
    message = error.message.to_s
    message.should_not contain("\e")
    message.should_not contain("\a")
    message.should contain("RED")

    oversized = HTTP2::Frame::GoAway.new(
      0_u32,
      HTTP2::ErrorCode::INTERNAL_ERROR.to_u32,
      "x" * 500
    )
    truncated = HTTP2::Connection::GoAwayTerminationError
      .new(oversized).message.to_s
    truncated.split(": ").last.size.should eq(128)
  end

  it "times out an unacknowledged PING without closing the connection" do
    UNIXSocket.pair do |client, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        HTTP2::Frame.read(io).as(HTTP2::Frame::Ping).ack?.should be_false

        ping = HTTP2::Frame::Ping.new(0_u8, 0_u32, "peerping")
        ping.write(io)
        io.flush
        acknowledgement = HTTP2::Frame.read(io).as(HTTP2::Frame::Ping)
        acknowledgement.ack?.should be_true
        acknowledgement.payload.should eq(ping.payload)
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        expect_raises(HTTP2::Connection::TimeoutError, /PING/) do
          connection.ping("no-reply", 10.milliseconds)
        end
        wait_for_peer(peer_result)
        connection.active?.should be_true
      ensure
        connection.close
      end
    end
  end

  it "rejects caller-built WINDOW_UPDATE and SETTINGS ACK frames" do
    UNIXSocket.pair do |client, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        wait_for_peer(peer_result)

        expect_raises(ArgumentError, /WINDOW_UPDATE/) do
          connection.write_frame(
            HTTP2::Frame::WindowUpdate.new(0_u32, 1024_u32)
          )
        end
        expect_raises(ArgumentError, /WINDOW_UPDATE/) do
          connection.write_batch(
            [HTTP2::Frame::WindowUpdate.new(0_u32, 1024_u32)] of HTTP2::Frames
          )
        end
        expect_raises(ArgumentError, /SETTINGS acknowledgements/) do
          connection.write_frame(HTTP2::Frame::Settings.ack)
        end
      ensure
        connection.close
      end
    end
  end
end
