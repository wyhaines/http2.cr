require "./spec_helper"

class FailingBodySource < IO
  def read(slice : Bytes) : Int32
    raise IO::Error.new("injected body source failure")
  end

  def write(slice : Bytes) : Nil
    raise IO::Error.new("failing body source is read-only")
  end
end

describe HTTP2::Connection do
  it "returns padded receive credit only as body bytes are consumed" do
    UNIXSocket.pair do |client, peer|
      stream_id = Channel(UInt32).new(1)
      data_sent = Channel(Nil).new(1)
      overhead_credited = Channel(Nil).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        id = stream_id.receive
        read_client_headers(io, id)

        HTTP2::Frame::Data.new(
          HTTP2::Frame::Data::Flags::PADDED,
          id,
          Bytes[1, 0x61, 0x62, 0x63, 0]
        ).write(io)
        io.flush
        data_sent.send(nil)

        connection_update = HTTP2::Frame.read(io)
          .as(HTTP2::Frame::WindowUpdate)
        connection_update.stream_id.should eq(0_u32)
        connection_update.window_size_increment.should eq(2_u32)
        stream_update = HTTP2::Frame.read(io)
          .as(HTTP2::Frame::WindowUpdate)
        stream_update.stream_id.should eq(id)
        stream_update.window_size_increment.should eq(2_u32)
        overhead_credited.send(nil)

        connection_update = HTTP2::Frame.read(io)
          .as(HTTP2::Frame::WindowUpdate)
        connection_update.stream_id.should eq(0_u32)
        connection_update.window_size_increment.should eq(3_u32)
        stream_update = HTTP2::Frame.read(io)
          .as(HTTP2::Frame::WindowUpdate)
        stream_update.stream_id.should eq(id)
        stream_update.window_size_increment.should eq(3_u32)

        HTTP2::Frame::Data.new(
          HTTP2::Frame::Data::Flags::END_STREAM,
          id,
          Bytes.empty
        ).write(io)
        io.flush
      end

      configuration = HTTP2::Connection::Configuration.new(
        max_buffered_body_bytes: 5
      )
      connection = HTTP2::Connection.start(client, configuration)
      begin
        connection.wait_until_active(1.second)
        stream = connection.new_stream
        open_client_stream(stream)
        stream_id.send(stream.id)
        data_sent.receive

        eventually { stream.body.buffered_bytes == 3 }
        overhead_credited.receive
        stream.receive_window.should eq(2_i64)

        buffer = Bytes.new(3)
        stream.body.read_fully(buffer)
        buffer.should eq("abc".to_slice)
        stream.body.buffered_bytes.should eq(0)
        stream.body.gets_to_end.should be_empty
        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end

  it "schedules concurrent uploads fairly and keeps control frames moving" do
    UNIXSocket.pair do |client, peer|
      stream_ids = Channel(Tuple(UInt32, UInt32)).new(1)
      peer_ready = Channel(Nil).new(1)
      server_settings = HTTP2::Frame::Settings.new([
        HTTP2::Frame::Settings::Setting.new(
          HTTP2::Frame::Settings::Identifier::INITIAL_WINDOW_SIZE,
          3_u32
        ),
      ])
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io, server_settings)
        first_id, second_id = stream_ids.receive
        read_client_headers(io, first_id)
        read_client_headers(io, second_id)
        peer_ready.send(nil)

        first = HTTP2::Frame.read(io).as(HTTP2::Frame::Data)
        second = HTTP2::Frame.read(io).as(HTTP2::Frame::Data)
        [first.stream_id, second.stream_id].sort.should eq(
          [first_id, second_id].sort
        )
        first.data.should eq("abc".to_slice)
        second.data.should eq("abc".to_slice)
        first.end_stream?.should be_false
        second.end_stream?.should be_false

        ping = HTTP2::Frame::Ping.new(0_u8, 0_u32, "notstuck")
        ping.write(io)
        io.flush
        acknowledgement = HTTP2::Frame.read(io).as(HTTP2::Frame::Ping)
        acknowledgement.ack?.should be_true
        acknowledgement.payload.should eq(ping.payload)

        HTTP2::Frame::WindowUpdate.new(first_id, 3_u32).write(io)
        HTTP2::Frame::WindowUpdate.new(second_id, 3_u32).write(io)
        io.flush

        final_first = HTTP2::Frame.read(io).as(HTTP2::Frame::Data)
        final_second = HTTP2::Frame.read(io).as(HTTP2::Frame::Data)
        [final_first.stream_id, final_second.stream_id].sort.should eq(
          [first_id, second_id].sort
        )
        final_first.data.should eq("def".to_slice)
        final_second.data.should eq("def".to_slice)
        final_first.end_stream?.should be_true
        final_second.end_stream?.should be_true
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        first = connection.new_stream
        second = connection.new_stream
        open_client_stream(first, end_stream: false)
        open_client_stream(second, end_stream: false)
        stream_ids.send({first.id, second.id})
        peer_ready.receive

        first_result = Channel(Exception?).new(1)
        second_result = Channel(Exception?).new(1)
        spawn do
          begin
            first.send_data("abcdef", end_stream: true)
            first_result.send(nil)
          rescue error
            first_result.send(error)
          end
        end
        spawn do
          begin
            second.send_data("abcdef", end_stream: true)
            second_result.send(nil)
          rescue error
            second_result.send(error)
          end
        end

        wait_for_peer(first_result)
        wait_for_peer(second_result)
        wait_for_peer(peer_result)
        first.state.should eq(HTTP2::Stream::State::HalfClosedLocal)
        second.state.should eq(HTTP2::Stream::State::HalfClosedLocal)
      ensure
        connection.close
      end
    end
  end

  it "enforces connection and stream send windows independently" do
    UNIXSocket.pair do |client, peer|
      stream_id = Channel(UInt32).new(1)
      server_settings = HTTP2::Frame::Settings.new([
        HTTP2::Frame::Settings::Setting.new(
          HTTP2::Frame::Settings::Identifier::INITIAL_WINDOW_SIZE,
          HTTP2::FrameHeader::MAX_STREAM_ID
        ),
      ])
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io, server_settings)
        id = stream_id.receive
        read_client_headers(io, id)

        received = 0
        while received < 65_535
          frame = HTTP2::Frame.read(io).as(HTTP2::Frame::Data)
          received += frame.data.size
          received.should be <= 65_535
          frame.end_stream?.should be_false
        end
        received.should eq(65_535)

        ping = HTTP2::Frame::Ping.new(0_u8, 0_u32, "connzero")
        ping.write(io)
        io.flush
        HTTP2::Frame.read(io).as(HTTP2::Frame::Ping).ack?.should be_true

        HTTP2::Frame::WindowUpdate.new(0_u32, 1_u32).write(io)
        io.flush
        final = HTTP2::Frame.read(io).as(HTTP2::Frame::Data)
        final.data.size.should eq(1)
        final.end_stream?.should be_true
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        stream = connection.new_stream
        open_client_stream(stream, end_stream: false)
        stream_id.send(stream.id)

        result = Channel(Exception?).new(1)
        spawn do
          begin
            stream.send_data(Bytes.new(65_536, 0x78_u8), end_stream: true)
            result.send(nil)
          rescue error
            result.send(error)
          end
        end

        wait_for_peer(result)
        wait_for_peer(peer_result)
        connection.send_window.should eq(0_i64)
        stream.send_window.should be > 0_i64
      ensure
        connection.close
      end
    end
  end

  it "completes concurrent downloads through bounded small-window bodies" do
    UNIXSocket.pair do |client, peer|
      stream_ids = Channel(Tuple(UInt32, UInt32)).new(1)
      initial_sent = Channel(Nil).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        first_id, second_id = stream_ids.receive
        read_client_headers(io, first_id)
        read_client_headers(io, second_id)

        HTTP2::Frame::Data.new(0_u8, first_id, "aaaa").write(io)
        HTTP2::Frame::Data.new(0_u8, second_id, "bbbb").write(io)
        io.flush
        initial_sent.send(nil)

        connection_credit = 0_u32
        first_credit = 0_u32
        second_credit = 0_u32
        until connection_credit >= 8 &&
              first_credit >= 4 &&
              second_credit >= 4
          update = HTTP2::Frame.read(io).as(HTTP2::Frame::WindowUpdate)
          case update.stream_id
          when 0_u32
            connection_credit += update.window_size_increment
          when first_id
            first_credit += update.window_size_increment
          when second_id
            second_credit += update.window_size_increment
          else
            fail("unexpected WINDOW_UPDATE stream #{update.stream_id}")
          end
        end

        HTTP2::Frame::Data.new(
          HTTP2::Frame::Data::Flags::END_STREAM,
          first_id,
          "cccc"
        ).write(io)
        HTTP2::Frame::Data.new(
          HTTP2::Frame::Data::Flags::END_STREAM,
          second_id,
          "dddd"
        ).write(io)
        io.flush
      end

      configuration = HTTP2::Connection::Configuration.new(
        max_buffered_body_bytes: 4
      )
      connection = HTTP2::Connection.start(client, configuration)
      begin
        connection.wait_until_active(1.second)
        first = connection.new_stream
        second = connection.new_stream
        open_client_stream(first)
        open_client_stream(second)
        stream_ids.send({first.id, second.id})
        initial_sent.receive

        eventually do
          first.body.buffered_bytes == 4 &&
            second.body.buffered_bytes == 4
        end

        first_result = Channel(String | Exception).new(1)
        second_result = Channel(String | Exception).new(1)
        spawn do
          begin
            first_result.send(first.body.gets_to_end)
          rescue error
            first_result.send(error)
          end
        end
        spawn do
          begin
            second_result.send(second.body.gets_to_end)
          rescue error
            second_result.send(error)
          end
        end

        select
        when result = first_result.receive
          raise result if result.is_a?(Exception)
          result.should eq("aaaacccc")
        when timeout(1.second)
          fail("first bounded download timed out")
        end
        select
        when result = second_result.receive
          raise result if result.is_a?(Exception)
          result.should eq("bbbbdddd")
        when timeout(1.second)
          fail("second bounded download timed out")
        end
        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end

  it "tracks a negative stream send window after a SETTINGS reduction" do
    UNIXSocket.pair do |client, peer|
      stream_id = Channel(UInt32).new(1)
      reduced = Channel(Nil).new(1)
      allow_first_update = Channel(Nil).new(1)
      allow_second_update = Channel(Nil).new(1)
      server_settings = HTTP2::Frame::Settings.new([
        HTTP2::Frame::Settings::Setting.new(
          HTTP2::Frame::Settings::Identifier::INITIAL_WINDOW_SIZE,
          10_u32
        ),
      ])
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io, server_settings)
        id = stream_id.receive
        read_client_headers(io, id)

        first = HTTP2::Frame.read(io).as(HTTP2::Frame::Data)
        first.data.should eq("abcdefghij".to_slice)
        first.end_stream?.should be_false

        HTTP2::Frame::Settings.new([
          HTTP2::Frame::Settings::Setting.new(
            HTTP2::Frame::Settings::Identifier::INITIAL_WINDOW_SIZE,
            0_u32
          ),
        ]).write(io)
        io.flush
        HTTP2::Frame.read(io).as(HTTP2::Frame::Settings).ack?.should be_true
        reduced.send(nil)

        allow_first_update.receive
        HTTP2::Frame::WindowUpdate.new(id, 5_u32).write(io)
        ping = HTTP2::Frame::Ping.new(0_u8, 0_u32, "negative")
        ping.write(io)
        io.flush
        HTTP2::Frame.read(io).as(HTTP2::Frame::Ping).ack?.should be_true

        allow_second_update.receive
        HTTP2::Frame::WindowUpdate.new(id, 5_u32).write(io)
        ping = HTTP2::Frame::Ping.new(0_u8, 0_u32, "zero-win")
        ping.write(io)
        io.flush
        HTTP2::Frame.read(io).as(HTTP2::Frame::Ping).ack?.should be_true

        HTTP2::Frame::WindowUpdate.new(id, 1_u32).write(io)
        io.flush
        final = HTTP2::Frame.read(io).as(HTTP2::Frame::Data)
        final.data.should eq("k".to_slice)
        final.end_stream?.should be_true
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        stream = connection.new_stream
        open_client_stream(stream, end_stream: false)
        stream_id.send(stream.id)

        result = Channel(Exception?).new(1)
        spawn do
          begin
            stream.send_data("abcdefghijk", end_stream: true)
            result.send(nil)
          rescue error
            result.send(error)
          end
        end

        reduced.receive
        eventually { stream.send_window == -10_i64 }
        allow_first_update.send(nil)
        eventually { stream.send_window == -5_i64 }
        allow_second_update.send(nil)
        eventually { stream.send_window == 0_i64 }

        wait_for_peer(result)
        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end

  it "streams an IO from its current position with exact END_STREAM placement" do
    UNIXSocket.pair do |client, peer|
      stream_id = Channel(UInt32).new(1)
      server_settings = HTTP2::Frame::Settings.new([
        HTTP2::Frame::Settings::Setting.new(
          HTTP2::Frame::Settings::Identifier::INITIAL_WINDOW_SIZE,
          4_u32
        ),
      ])
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io, server_settings)
        id = stream_id.receive
        read_client_headers(io, id)

        output = IO::Memory.new
        loop do
          frame = HTTP2::Frame.read(io).as(HTTP2::Frame::Data)
          output.write(frame.data)
          if frame.end_stream?
            break
          end
          frame.data.size.should eq(4)
          HTTP2::Frame::WindowUpdate
            .new(id, frame.data.size.to_u32)
            .write(io)
          io.flush
        end
        String.new(output.to_slice).should eq("streamed-body")
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        stream = connection.new_stream
        open_client_stream(stream, end_stream: false)
        stream_id.send(stream.id)

        source = IO::Memory.new("prefix-streamed-body")
        prefix = Bytes.new(7)
        source.read_fully(prefix)
        prefix.should eq("prefix-".to_slice)
        stream.send_data(source, end_stream: true)

        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end

  it "charges outbound padding and cancels after a body source failure" do
    UNIXSocket.pair do |client, peer|
      stream_ids = Channel(Tuple(UInt32, UInt32)).new(1)
      server_settings = HTTP2::Frame::Settings.new([
        HTTP2::Frame::Settings::Setting.new(
          HTTP2::Frame::Settings::Identifier::INITIAL_WINDOW_SIZE,
          4_u32
        ),
      ])
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io, server_settings)
        padded_id, failing_id = stream_ids.receive
        read_client_headers(io, padded_id)
        read_client_headers(io, failing_id)

        ping = HTTP2::Frame::Ping.new(0_u8, 0_u32, "padblock")
        ping.write(io)
        io.flush
        HTTP2::Frame.read(io).as(HTTP2::Frame::Ping).ack?.should be_true

        HTTP2::Frame::WindowUpdate.new(padded_id, 1_u32).write(io)
        io.flush
        padded = HTTP2::Frame.read(io).as(HTTP2::Frame::Data)
        padded.stream_id.should eq(padded_id)
        padded.padded?.should be_true
        padded.payload.should eq(Bytes[0, 0x64, 0x61, 0x74, 0x61])
        padded.end_stream?.should be_true

        reset = HTTP2::Frame.read(io).as(HTTP2::Frame::ResetStream)
        reset.stream_id.should eq(failing_id)
        reset.error_code.should eq(HTTP2::ErrorCode::CANCEL.to_u32)
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        padded_stream = connection.new_stream
        failing_stream = connection.new_stream
        open_client_stream(padded_stream, end_stream: false)
        open_client_stream(failing_stream, end_stream: false)
        stream_ids.send({padded_stream.id, failing_stream.id})

        padded_result = Channel(Exception?).new(1)
        spawn do
          begin
            padded_stream.send(
              HTTP2::Frame::Data.new(
                HTTP2::Frame::Data::Flags::PADDED |
                HTTP2::Frame::Data::Flags::END_STREAM,
                padded_stream.id,
                Bytes[0, 0x64, 0x61, 0x74, 0x61]
              )
            )
            padded_result.send(nil)
          rescue error
            padded_result.send(error)
          end
        end

        wait_for_peer(padded_result)
        expect_raises(IO::Error, /body source failure/) do
          failing_stream.send_data(FailingBodySource.new)
        end
        wait_for_peer(peer_result)
        failing_stream.terminal_error.should be_a(
          HTTP2::Connection::CanceledError
        )
        connection.active?.should be_true
      ensure
        connection.close
      end
    end
  end

  it "wakes a flow-blocked sender when the peer resets its stream" do
    UNIXSocket.pair do |client, peer|
      stream_id = Channel(UInt32).new(1)
      sender_started = Channel(Nil).new(1)
      server_settings = HTTP2::Frame::Settings.new([
        HTTP2::Frame::Settings::Setting.new(
          HTTP2::Frame::Settings::Identifier::INITIAL_WINDOW_SIZE,
          0_u32
        ),
      ])
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io, server_settings)
        id = stream_id.receive
        read_client_headers(io, id)
        sender_started.receive

        ping = HTTP2::Frame::Ping.new(0_u8, 0_u32, "blocked!")
        ping.write(io)
        io.flush
        HTTP2::Frame.read(io).as(HTTP2::Frame::Ping).ack?.should be_true

        HTTP2::Frame::ResetStream.new(
          id,
          HTTP2::ErrorCode::CANCEL
        ).write(io)
        io.flush
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        stream = connection.new_stream
        open_client_stream(stream, end_stream: false)
        stream_id.send(stream.id)

        result = Channel(Exception?).new(1)
        spawn do
          begin
            sender_started.send(nil)
            stream.send_data("blocked", end_stream: true)
            result.send(nil)
          rescue error
            result.send(error)
          end
        end

        error = select
        when observed = result.receive
          observed
        when timeout(1.second)
          fail("flow-blocked sender was not woken")
        end
        error.should be_a(HTTP2::Connection::StreamResetError)
        wait_for_peer(peer_result)
        connection.active?.should be_true
      ensure
        connection.close
      end
    end
  end

  it "uses stream scope when the peer exceeds a stream receive window" do
    UNIXSocket.pair do |client, peer|
      stream_id = Channel(UInt32).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        id = stream_id.receive
        read_client_headers(io, id)
        HTTP2::Frame::Data.new(0_u8, id, "four").write(io)
        io.flush

        loop do
          frame = HTTP2::Frame.read(io)
          next if frame.is_a?(HTTP2::Frame::WindowUpdate)

          reset = frame.as(HTTP2::Frame::ResetStream)
          reset.stream_id.should eq(id)
          reset.error_code.should eq(
            HTTP2::ErrorCode::FLOW_CONTROL_ERROR.to_u32
          )
          break
        end

        ping = HTTP2::Frame::Ping.new(0_u8, 0_u32, "still-up")
        ping.write(io)
        io.flush
        loop do
          frame = HTTP2::Frame.read(io)
          next if frame.is_a?(HTTP2::Frame::WindowUpdate)

          frame.as(HTTP2::Frame::Ping).ack?.should be_true
          break
        end
      end

      configuration = HTTP2::Connection::Configuration.new(
        max_buffered_body_bytes: 3
      )
      connection = HTTP2::Connection.start(client, configuration)
      begin
        connection.wait_until_active(1.second)
        stream = connection.new_stream
        open_client_stream(stream)
        stream_id.send(stream.id)

        eventually { stream.closed? }
        stream.terminal_error.should be_a(HTTP2::ProtocolError)
        connection.active?.should be_true
        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end

  it "uses connection scope when the peer exceeds connection receive credit" do
    UNIXSocket.pair do |client, peer|
      stream_id = Channel(UInt32).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        id = stream_id.receive
        read_client_headers(io, id)

        payload = Bytes.new(HTTP2::FrameHeader::DEFAULT_MAX_PAYLOAD)
        4.times do
          HTTP2::Frame::Data.new(0_u8, id, payload).write(io)
        end
        io.flush

        goaway = HTTP2::Frame.read(io).as(HTTP2::Frame::GoAway)
        goaway.error_code.should eq(
          HTTP2::ErrorCode::FLOW_CONTROL_ERROR.to_u32
        )
      end

      # Pinned to the RFC-default window: with the library's larger default
      # connection_receive_window, 4 full-size DATA frames no longer overrun
      # the connection credit this example needs to exhaust.
      configuration = HTTP2::Connection::Configuration.new(
        connection_receive_window: 65_535
      )
      connection = HTTP2::Connection.start(client, configuration)
      connection.wait_until_active(1.second)
      stream = connection.new_stream
      open_client_stream(stream)
      stream_id.send(stream.id)

      connection.wait_closed(1.second)
      error = connection.terminal_error.as(HTTP2::ProtocolError)
      error.error_code.should eq(HTTP2::ErrorCode::FLOW_CONTROL_ERROR)
      error.scope.connection?.should be_true
      wait_for_peer(peer_result)
    end
  end

  it "rejects connection and stream window overflow at the correct scope" do
    UNIXSocket.pair do |client, peer|
      stream_id = Channel(UInt32).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        id = stream_id.receive
        read_client_headers(io, id)
        HTTP2::Frame::WindowUpdate.new(
          id,
          HTTP2::FrameHeader::MAX_STREAM_ID
        ).write(io)
        io.flush

        reset = HTTP2::Frame.read(io).as(HTTP2::Frame::ResetStream)
        reset.error_code.should eq(
          HTTP2::ErrorCode::FLOW_CONTROL_ERROR.to_u32
        )
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

    UNIXSocket.pair do |client, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        HTTP2::Frame::WindowUpdate.new(
          0_u32,
          HTTP2::FrameHeader::MAX_STREAM_ID
        ).write(io)
        io.flush

        goaway = HTTP2::Frame.read(io).as(HTTP2::Frame::GoAway)
        goaway.error_code.should eq(
          HTTP2::ErrorCode::FLOW_CONTROL_ERROR.to_u32
        )
      end

      connection = HTTP2::Connection.start(client)
      connection.wait_until_active(1.second)
      connection.wait_closed(1.second)
      connection.terminal_error
        .as(HTTP2::ProtocolError)
        .error_code.should eq(HTTP2::ErrorCode::FLOW_CONTROL_ERROR)
      wait_for_peer(peer_result)
    end
  end

  it "rejects a SETTINGS change that overflows an active stream window" do
    UNIXSocket.pair do |client, peer|
      stream_id = Channel(UInt32).new(1)
      server_settings = HTTP2::Frame::Settings.new([
        HTTP2::Frame::Settings::Setting.new(
          HTTP2::Frame::Settings::Identifier::INITIAL_WINDOW_SIZE,
          0_u32
        ),
      ])
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io, server_settings)
        id = stream_id.receive
        read_client_headers(io, id)

        HTTP2::Frame::WindowUpdate.new(
          id,
          HTTP2::FrameHeader::MAX_STREAM_ID
        ).write(io)
        HTTP2::Frame::Settings.new([
          HTTP2::Frame::Settings::Setting.new(
            HTTP2::Frame::Settings::Identifier::INITIAL_WINDOW_SIZE,
            1_u32
          ),
        ]).write(io)
        io.flush

        goaway = HTTP2::Frame.read(io).as(HTTP2::Frame::GoAway)
        goaway.error_code.should eq(
          HTTP2::ErrorCode::FLOW_CONTROL_ERROR.to_u32
        )
      end

      connection = HTTP2::Connection.start(client)
      connection.wait_until_active(1.second)
      stream = connection.new_stream
      open_client_stream(stream, end_stream: false)
      stream_id.send(stream.id)

      connection.wait_closed(1.second)
      connection.terminal_error
        .as(HTTP2::ProtocolError)
        .error_code.should eq(HTTP2::ErrorCode::FLOW_CONTROL_ERROR)
      wait_for_peer(peer_result)
    end
  end

  it "announces the configured connection receive window after the preface" do
    UNIXSocket.pair do |client, peer|
      peer_result = scripted_peer(peer) do |io|
        client_settings = read_client_preface(io)
        HTTP2::Frame::Settings
          .new([] of HTTP2::Frame::Settings::Setting)
          .write(io)
        HTTP2::Frame::Settings.ack.write(io)
        io.flush

        update = nil
        until update
          frame = HTTP2::Frame.read(io)
          update = frame.as?(HTTP2::Frame::WindowUpdate)
        end
        update.stream_id.should eq(0_u32)
        update.window_size_increment.should eq(1_048_576_u32 - 65_535)
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end

  it "sends no startup WINDOW_UPDATE at the minimum connection receive window" do
    UNIXSocket.pair do |client, peer|
      peer_result = scripted_peer(peer) do |io|
        read_client_preface(io)
        HTTP2::Frame::Settings
          .new([] of HTTP2::Frame::Settings::Setting)
          .write(io)
        HTTP2::Frame::Settings.ack.write(io)
        io.flush

        # Deliberately NOT skip_startup_window_update: this example exists
        # to catch a regression that sends a grant here, so the peer's next
        # read must hard-fail (rather than tolerate) if one arrives.
        acknowledgement = HTTP2::Frame.read(io).as(HTTP2::Frame::Settings)
        acknowledgement.ack?.should be_true

        ping = HTTP2::Frame.read(io).as(HTTP2::Frame::Ping)
        ping.ack?.should be_false
        ping.payload.should eq("no-grant".to_slice)
        ping.ack.write(io)
        io.flush
      end

      configuration = HTTP2::Connection::Configuration.new(
        connection_receive_window: 65_535
      )
      connection = HTTP2::Connection.start(client, configuration)
      begin
        connection.wait_until_active(1.second)
        connection.ping("no-grant", 1.second)
        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end
end
