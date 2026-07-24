require "./spec_helper"

describe HTTP2::Connection::Configuration do
  it "keeps the advertised frame size synchronized with the parser limit" do
    configuration = HTTP2::Connection::Configuration.new(
      inbound_max_frame_size: 32_768,
      initial_settings: [
        HTTP2::Frame::Settings::Setting.new(
          HTTP2::Frame::Settings::Identifier::ENABLE_PUSH,
          0_u32
        ),
      ]
    )

    configuration.initial_settings.map(&.identifier).should eq([
      HTTP2::Frame::Settings::Identifier::ENABLE_PUSH.to_u16,
      HTTP2::Frame::Settings::Identifier::MAX_FRAME_SIZE.to_u16,
    ])
    configuration.initial_settings.last.value.should eq(32_768_u32)

    settings = configuration.initial_settings
    settings.clear
    configuration.initial_settings.size.should eq(2)
  end

  it "rejects invalid limits and contradictory local settings" do
    expect_raises(ArgumentError) do
      HTTP2::Connection::Configuration.new(writer_queue_capacity: 0)
    end
    expect_raises(ArgumentError) do
      HTTP2::Connection::Configuration.new(stream_event_capacity: 0)
    end
    expect_raises(ArgumentError) do
      HTTP2::Connection::Configuration.new(
        inbound_max_frame_size: 32_768,
        initial_settings: [
          HTTP2::Frame::Settings::Setting.new(
            HTTP2::Frame::Settings::Identifier::MAX_FRAME_SIZE,
            65_535_u32
          ),
        ]
      )
    end
  end
end

describe HTTP2::Connection::StreamIDAllocator do
  it "allocates odd IDs by two and detects exhaustion" do
    allocator = HTTP2::Connection::StreamIDAllocator.new
    allocator.allocate.should eq(1_u32)
    allocator.allocate.should eq(3_u32)

    final = HTTP2::Connection::StreamIDAllocator.new(
      HTTP2::FrameHeader::MAX_STREAM_ID
    )
    final.allocate.should eq(HTTP2::FrameHeader::MAX_STREAM_ID)
    final.exhausted?.should be_true
    expect_raises(HTTP2::Connection::StreamIDExhaustedError) do
      final.allocate
    end
  end

  it "rejects invalid initial client IDs" do
    [0_u32, 2_u32, 0x80000001_u32].each do |id|
      expect_raises(ArgumentError) do
        HTTP2::Connection::StreamIDAllocator.new(id)
      end
    end
  end
end

describe HTTP2::Connection do
  it "starts once and closes idempotently" do
    UNIXSocket.pair do |client, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        io.read(Bytes.new(1)).should eq(0)
      end

      connection = HTTP2::Connection.new(client)
      expect_raises(HTTP2::Connection::InvalidStateError) do
        connection.new_stream
      end

      connection.start
      connection.wait_until_active(1.second)
      expect_raises(HTTP2::Connection::InvalidStateError) do
        connection.start
      end

      close_result = Channel(Exception?).new(1)
      spawn do
        begin
          connection.close
          close_result.send(nil)
        rescue error
          close_result.send(error)
        end
      end
      close_error = select
      when error = close_result.receive
        error
      when timeout(1.second)
        fail("connection close timed out")
      end
      raise close_error if close_error

      connection.close
      connection.closed?.should be_true
      connection.terminal_error.should be_a(HTTP2::Connection::ClosedError)
      wait_for_peer(peer_result)
    end
  end

  it "sends the client preface and becomes active after server SETTINGS" do
    UNIXSocket.pair do |client, peer|
      server_settings = HTTP2::Frame::Settings.new([
        HTTP2::Frame::Settings::Setting.new(
          HTTP2::Frame::Settings::Identifier::MAX_CONCURRENT_STREAMS,
          10_u32
        ),
        HTTP2::Frame::Settings::Setting.new(0xbeef_u16, 20_u32),
      ])
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io, server_settings)
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        connection.state.should eq(HTTP2::Connection::State::Active)
        connection.peer_settings.try(&.entries.size).should eq(2)
        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end

  it "requires the first server frame to be non-ACK SETTINGS" do
    invalid_frames = [
      HTTP2::Frame::Ping.new(0_u8, 0_u32),
      HTTP2::Frame::Settings.ack,
    ] of HTTP2::Frames

    invalid_frames.each do |invalid|
      UNIXSocket.pair do |client, peer|
        peer_result = scripted_peer(peer) do |io|
          read_client_preface(io)
          invalid.write(io)
          goaway = HTTP2::Frame.read(io).as(HTTP2::Frame::GoAway)
          goaway.error_code.should eq(HTTP2::ErrorCode::PROTOCOL_ERROR.to_u32)
        end

        connection = HTTP2::Connection.start(client)
        expect_raises(HTTP2::ProtocolError) do
          connection.wait_until_active(1.second)
        end
        connection.wait_closed(1.second)
        connection.closed?.should be_true
        wait_for_peer(peer_result)
      end
    end
  end

  it "ignores unknown frames and handles SETTINGS and PING on the connection" do
    UNIXSocket.pair do |client, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)

        HTTP2::Frame::Unknown.new(
          0xf0_u8,
          0xff_u8,
          0_u32,
          Bytes[1, 2, 3]
        ).write(io)

        HTTP2::Frame::Settings.new([
          HTTP2::Frame::Settings::Setting.new(0xbeef_u16, 1_u32),
        ]).write(io)
        settings_ack = HTTP2::Frame.read(io).as(HTTP2::Frame::Settings)
        settings_ack.ack?.should be_true

        ping = HTTP2::Frame::Ping.new(0_u8, 0_u32, "12345678")
        ping.write(io)
        ping_ack = HTTP2::Frame.read(io).as(HTTP2::Frame::Ping)
        ping_ack.ack?.should be_true
        ping_ack.payload.should eq(ping.payload)
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        wait_for_peer(peer_result)
        connection.active?.should be_true
      ensure
        connection.close
      end
    end
  end

  it "routes stream frames without creating a synthetic stream 0" do
    UNIXSocket.pair do |client, peer|
      stream_id = Channel(UInt32).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        id = stream_id.receive
        HTTP2::Frame::Data.new(0_u8, id, "body").write(io)
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        stream = connection.new_stream
        stream.id.should eq(1_u32)
        connection.stream?(0_u32).should be_nil
        stream_id.send(stream.id)

        frame = stream.receive(1.second).as(HTTP2::Frame::Data)
        frame.data.should eq("body".to_slice)
        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end

  it "ignores frames for a stream removed by the application" do
    UNIXSocket.pair do |client, peer|
      stream_id = Channel(UInt32).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        id = stream_id.receive
        HTTP2::Frame::Data.new(0_u8, id, "late").write(io)

        ping = HTTP2::Frame::Ping.new(0_u8, 0_u32, "12345678")
        ping.write(io)
        HTTP2::Frame.read(io).as(HTTP2::Frame::Ping).ack?.should be_true
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        stream = connection.new_stream
        stream.close
        stream_id.send(stream.id)

        expect_raises(HTTP2::Connection::ClosedError) do
          stream.send(HTTP2::Frame::Data.new(0_u8, stream.id, "late"))
        end
        wait_for_peer(peer_result)
        connection.active?.should be_true
      ensure
        connection.close
      end
    end
  end

  it "resets a stream-scoped frame violation without closing the connection" do
    UNIXSocket.pair do |client, peer|
      stream_id = Channel(UInt32).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        id = stream_id.receive
        io.write(wire_frame(0x02_u8, 0_u8, id, Bytes.new(4)))

        reset = HTTP2::Frame.read(io).as(HTTP2::Frame::ResetStream)
        reset.stream_id.should eq(id)
        reset.error_code.should eq(HTTP2::ErrorCode::FRAME_SIZE_ERROR.to_u32)

        ping = HTTP2::Frame::Ping.new(0_u8, 0_u32, "12345678")
        ping.write(io)
        reply = HTTP2::Frame.read(io).as(HTTP2::Frame::Ping)
        reply.ack?.should be_true
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        stream = connection.new_stream
        stream_id.send(stream.id)

        error = expect_raises(HTTP2::FrameSizeError) do
          stream.receive(1.second)
        end
        error.stream_id.should eq(stream.id)
        connection.stream?(stream.id).should be_nil
        wait_for_peer(peer_result)
        connection.active?.should be_true
      ensure
        connection.close
      end
    end
  end

  it "terminates instead of blocking when a stream event queue is full" do
    UNIXSocket.pair do |client, peer|
      stream_id = Channel(UInt32).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        id = stream_id.receive
        HTTP2::Frame::Data.new(0_u8, id, "first").write(io)
        HTTP2::Frame::Data.new(0_u8, id, "second").write(io)
      end

      configuration = HTTP2::Connection::Configuration.new(
        stream_event_capacity: 1
      )
      connection = HTTP2::Connection.start(client, configuration)
      connection.wait_until_active(1.second)
      stream = connection.new_stream
      stream_id.send(stream.id)

      connection.wait_closed(1.second)
      connection.terminal_error.should be_a(HTTP2::Connection::QueueFullError)
      expect_raises(HTTP2::Connection::QueueFullError) do
        stream.receive(1.second)
      end
      wait_for_peer(peer_result)
    end
  end

  it "keeps concurrent frame batches contiguous on the wire" do
    UNIXSocket.pair do |client, peer|
      observed = Channel(Array(String)).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        payloads = Array(String).new(4)
        4.times do
          payloads << String.new(
            HTTP2::Frame.read(io).as(HTTP2::Frame::Ping).payload
          )
        end
        observed.send(payloads)
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        first = [
          HTTP2::Frame::Ping.new(
            HTTP2::Frame::Ping::Flags::ACK,
            0_u32,
            "A0000001"
          ),
          HTTP2::Frame::Ping.new(
            HTTP2::Frame::Ping::Flags::ACK,
            0_u32,
            "A0000002"
          ),
        ] of HTTP2::Frames
        second = [
          HTTP2::Frame::Ping.new(
            HTTP2::Frame::Ping::Flags::ACK,
            0_u32,
            "B0000001"
          ),
          HTTP2::Frame::Ping.new(
            HTTP2::Frame::Ping::Flags::ACK,
            0_u32,
            "B0000002"
          ),
        ] of HTTP2::Frames

        completions = Channel(Exception?).new(2)
        [first, second].each do |batch|
          spawn do
            begin
              connection.write_batch(batch)
              completions.send(nil)
            rescue error
              completions.send(error)
            end
          end
        end
        2.times do
          if error = completions.receive
            raise error
          end
        end

        payloads = observed.receive
        valid_orders = [
          ["A0000001", "A0000002", "B0000001", "B0000002"],
          ["B0000001", "B0000002", "A0000001", "A0000002"],
        ]
        valid_orders.should contain(payloads)
        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end

  it "propagates writer failures and closes the runtime" do
    transport = FailingWriteIO.new(42)
    connection = HTTP2::Connection.start(transport)
    connection.wait_until_active(1.second)
    stream = connection.new_stream
    transport.written_bytes.should eq(42)

    expect_raises(IO::Error, "injected write failure") do
      connection.write_frame(HTTP2::Frame::Ping.new(0_u8, 0_u32))
    end
    connection.wait_closed(1.second)
    connection.terminal_error.should be_a(IO::Error)
    expect_raises(IO::Error, "injected write failure") do
      stream.receive(1.second)
    end
    connection.close
    connection.close
  end

  it "fans EOF out to every registered stream" do
    UNIXSocket.pair do |client, peer|
      ready = Channel(Nil).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        ready.receive
        io.close
      end

      connection = HTTP2::Connection.start(client)
      connection.wait_until_active(1.second)
      first = connection.new_stream
      second = connection.new_stream
      ready.send(nil)

      connection.wait_closed(1.second)
      expect_raises(IO::EOFError) { first.receive(1.second) }
      expect_raises(IO::EOFError) { second.receive(1.second) }
      connection.active_stream_count.should eq(0)
      wait_for_peer(peer_result)
    end
  end

  it "enters draining state and rejects new streams after GOAWAY" do
    UNIXSocket.pair do |client, peer|
      ready = Channel(Nil).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        ready.receive
        HTTP2::Frame::GoAway.new(1_u32, HTTP2::ErrorCode::NO_ERROR).write(io)
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        first = connection.new_stream
        second = connection.new_stream
        ready.send(nil)

        expect_raises(HTTP2::Connection::ClosedError) do
          second.receive(1.second)
        end
        connection.draining?.should be_true
        connection.stream?(first.id).should be(first)
        connection.stream?(second.id).should be_nil
        expect_raises(HTTP2::Connection::InvalidStateError) do
          connection.new_stream
        end
        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end

  it "connects to a local cleartext prior-knowledge peer" do
    server = TCPServer.new("127.0.0.1", 0)
    peer_result = scripted_peer(server) do |listener|
      socket = listener.as(TCPServer).accept
      begin
        complete_server_handshake(socket)
      ensure
        socket.close
      end
    end

    connection = HTTP2::Connection.connect_prior_knowledge(
      "127.0.0.1",
      server.local_address.port
    )
    begin
      connection.wait_until_active(1.second)
      wait_for_peer(peer_result)
    ensure
      connection.close
      server.close
    end
  end
end
