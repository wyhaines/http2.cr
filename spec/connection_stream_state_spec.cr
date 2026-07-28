require "./spec_helper"

describe HTTP2::Connection do
  it "tracks END_STREAM transitions in both directions" do
    UNIXSocket.pair do |client, peer|
      stream_id = Channel(UInt32).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        id = stream_id.receive
        request = read_client_headers(io, id)
        request.end_stream?.should be_false

        HTTP2::Frame::Headers.new(
          HTTP2::Frame::Headers::Flags::END_HEADERS,
          id,
          Bytes.empty
        ).write(io)
        io.flush

        request_end = HTTP2::Frame.read(io).as(HTTP2::Frame::Data)
        request_end.stream_id.should eq(id)
        request_end.end_stream?.should be_true

        HTTP2::Frame::Data.new(
          HTTP2::Frame::Data::Flags::END_STREAM,
          id,
          "response"
        ).write(io)
        io.flush
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        stream = connection.new_stream
        stream.state.should eq(HTTP2::Stream::State::Idle)

        open_client_stream(stream, end_stream: false)
        stream.state.should eq(HTTP2::Stream::State::Open)
        stream_id.send(stream.id)

        stream.receive(1.second).should be_a(
          HTTP2::Connection::FieldSection
        )
        stream.state.should eq(HTTP2::Stream::State::Open)

        stream.send_data("request", end_stream: true)
        stream.state.should eq(HTTP2::Stream::State::HalfClosedLocal)

        stream.body.gets_to_end.should eq("response")
        stream.state.should eq(HTTP2::Stream::State::Closed)
        connection.stream?(stream.id).should be_nil
        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end

  it "resets frames received after remote END_STREAM" do
    UNIXSocket.pair do |client, peer|
      stream_id = Channel(UInt32).new(1)
      first_received = Channel(Nil).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        id = stream_id.receive
        read_client_headers(io, id)

        HTTP2::Frame::Data.new(
          HTTP2::Frame::Data::Flags::END_STREAM,
          id,
          "first"
        ).write(io)
        io.flush
        first_received.receive

        HTTP2::Frame::Data.new(0_u8, id, "late").write(io)
        io.flush
        reset = loop do
          frame = HTTP2::Frame.read(io)
          next if frame.is_a?(HTTP2::Frame::WindowUpdate)

          break frame.as(HTTP2::Frame::ResetStream)
        end
        reset.stream_id.should eq(id)
        reset.error_code.should eq(HTTP2::ErrorCode::STREAM_CLOSED.to_u32)

        ping = HTTP2::Frame::Ping.new(0_u8, 0_u32, "still-ok")
        ping.write(io)
        io.flush
        loop do
          frame = HTTP2::Frame.read(io)
          next if frame.is_a?(HTTP2::Frame::WindowUpdate)

          frame.as(HTTP2::Frame::Ping).ack?.should be_true
          break
        end
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        stream = connection.new_stream
        open_client_stream(stream, end_stream: false)
        stream_id.send(stream.id)

        stream.body.gets_to_end.should eq("first")
        stream.state.should eq(HTTP2::Stream::State::HalfClosedRemote)
        first_received.send(nil)

        error = expect_raises(HTTP2::ProtocolError) do
          stream.receive(1.second)
        end
        error.error_code.should eq(HTTP2::ErrorCode::STREAM_CLOSED)
        stream.state.should eq(HTTP2::Stream::State::Closed)
        connection.active?.should be_true
        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end

  it "turns peer resets into terminal stream errors" do
    UNIXSocket.pair do |client, peer|
      stream_id = Channel(UInt32).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        id = stream_id.receive
        read_client_headers(io, id)
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
        open_client_stream(stream)
        stream_id.send(stream.id)

        error = expect_raises(HTTP2::Connection::StreamResetError) do
          stream.receive(1.second)
        end
        error.stream_id.should eq(stream.id)
        error.error_code.should eq(HTTP2::ErrorCode::CANCEL.to_u32)
        stream.closed?.should be_true
        connection.stream?(stream.id).should be_nil
        connection.active?.should be_true
        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end

  it "cancels idle streams locally without sending RST_STREAM" do
    UNIXSocket.pair do |client, peer|
      opened_id = Channel(UInt32).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        id = opened_id.receive
        id.should eq(3_u32)
        read_client_headers(io, id)
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        canceled = connection.new_stream
        canceled.cancel

        error = expect_raises(HTTP2::Connection::CanceledError) do
          canceled.receive(1.second)
        end
        error.stream_id.should eq(canceled.id)
        canceled.closed?.should be_true

        opened = connection.new_stream
        open_client_stream(opened)
        opened_id.send(opened.id)
        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end

  it "rejects a second stream until peer concurrency is available" do
    UNIXSocket.pair do |client, peer|
      first_id = Channel(UInt32).new(1)
      release_first = Channel(Nil).new(1)
      second_id = Channel(UInt32).new(1)
      first_read = Channel(Nil).new(1)
      peer_result = scripted_peer(peer) do |io|
        settings = HTTP2::Frame::Settings.new([
          HTTP2::Frame::Settings::Setting.new(
            HTTP2::Frame::Settings::Identifier::MAX_CONCURRENT_STREAMS,
            1_u32
          ),
        ])
        complete_server_handshake(io, settings)

        id = first_id.receive
        read_client_headers(io, id)
        first_read.send(nil)
        release_first.receive
        HTTP2::Frame::Headers.new(
          HTTP2::Frame::Headers::Flags::END_HEADERS |
          HTTP2::Frame::Headers::Flags::END_STREAM,
          id,
          Bytes.empty
        ).write(io)
        io.flush

        id = second_id.receive
        read_client_headers(io, id)
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        first = connection.new_stream
        second = connection.new_stream
        open_client_stream(first)
        first_id.send(first.id)
        first_read.receive

        error = expect_raises(
          HTTP2::Connection::ConcurrentStreamLimitError
        ) do
          open_client_stream(second)
        end
        error.limit.should eq(1_u32)
        second.state.should eq(HTTP2::Stream::State::Idle)

        release_first.send(nil)
        first.receive(1.second).should be_a(
          HTTP2::Connection::FieldSection
        )
        first.closed?.should be_true

        open_client_stream(second)
        second.state.should eq(HTTP2::Stream::State::HalfClosedLocal)
        second_id.send(second.id)
        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end

  it "closes lower idle streams when a higher ID opens" do
    UNIXSocket.pair do |client, peer|
      opened_id = Channel(UInt32).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        id = opened_id.receive
        id.should eq(3_u32)
        read_client_headers(io, id)

        ping = HTTP2::Frame::Ping.new(0_u8, 0_u32, "12345678")
        ping.write(io)
        io.flush
        HTTP2::Frame.read(io).as(HTTP2::Frame::Ping).ack?.should be_true
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        skipped = connection.new_stream
        opened = connection.new_stream
        open_client_stream(opened)
        opened_id.send(opened.id)

        expect_raises(HTTP2::Connection::ClosedError, /skipped/) do
          skipped.receive(1.second)
        end
        skipped.closed?.should be_true
        connection.stream?(skipped.id).should be_nil
        connection.stream?(opened.id).should be(opened)

        # The same terminal error also surfaces from #send_headers
        # (not just #receive), preserving the raw connection API's
        # distinction between a skipped stream and another invalid state.
        error = expect_raises(HTTP2::Connection::ClosedError, /skipped/) do
          skipped.send_headers([] of HTTP2::HeaderField, end_stream: true)
        end
        error.class.should eq(HTTP2::Connection::ClosedError)

        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end

  it "rejects DATA batches without applying partial transitions" do
    UNIXSocket.pair do |client, peer|
      stream_id = Channel(UInt32).new(1)
      batch_rejected = Channel(Nil).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        id = stream_id.receive
        read_client_headers(io, id)
        batch_rejected.receive

        ping = HTTP2::Frame::Ping.new(0_u8, 0_u32, "batch-ok")
        ping.write(io)
        io.flush
        acknowledgement = HTTP2::Frame.read(io).as(HTTP2::Frame::Ping)
        acknowledgement.ack?.should be_true
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        stream = connection.new_stream
        open_client_stream(stream, end_stream: false)
        stream_id.send(stream.id)

        expect_raises(ArgumentError, /DATA frames must be sent/) do
          connection.write_batch([
            HTTP2::Frame::Data.new(
              HTTP2::Frame::Data::Flags::END_STREAM,
              stream.id,
              "last"
            ),
            HTTP2::Frame::Data.new(0_u8, stream.id, "invalid"),
          ] of HTTP2::Frames)
        end
        stream.state.should eq(HTTP2::Stream::State::Open)
        batch_rejected.send(nil)
        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end

  it "round-trips PING acknowledgements" do
    UNIXSocket.pair do |client, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        ping = HTTP2::Frame.read(io).as(HTTP2::Frame::Ping)
        ping.ack?.should be_false
        ping.payload.should eq("pingpong".to_slice)
        ping.ack.write(io)
        io.flush
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        connection.ping("pingpong", 1.second)
        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end

  it "resolves concurrent local and remote resets without closing" do
    UNIXSocket.pair do |client, peer|
      stream_id = Channel(UInt32).new(1)
      race_ready = Channel(Nil).new(1)
      start_race = Channel(Nil).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        id = stream_id.receive
        read_client_headers(io, id)
        race_ready.send(nil)
        start_race.receive

        HTTP2::Frame::ResetStream.new(
          id,
          HTTP2::ErrorCode::CANCEL
        ).write(io)
        HTTP2::Frame::Ping.new(0_u8, 0_u32, "raceping").write(io)
        io.flush

        frame = HTTP2::Frame.read(io)
        if frame.is_a?(HTTP2::Frame::ResetStream)
          frame.stream_id.should eq(id)
          frame = HTTP2::Frame.read(io)
        end
        acknowledgement = frame.as(HTTP2::Frame::Ping)
        acknowledgement.ack?.should be_true
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        stream = connection.new_stream
        open_client_stream(stream, end_stream: false)
        stream_id.send(stream.id)
        race_ready.receive

        canceled = Channel(Exception?).new(1)
        spawn do
          begin
            stream.cancel
            canceled.send(nil)
          rescue error
            canceled.send(error)
          end
        end
        start_race.send(nil)
        if cancel_error = canceled.receive
          raise cancel_error
        end

        eventually { stream.closed? }
        stream.terminal_error.should be_a(HTTP2::Connection::ClosedError)
        connection.active?.should be_true
        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end

  it "bounds recently closed stream metadata by the hard cap" do
    UNIXSocket.pair do |client, peer|
      stream_ids = Channel(Array(UInt32)).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        ids = stream_ids.receive
        ids.each { |id| read_client_headers(io, id) }
        ids.each do |id|
          reset = HTTP2::Frame.read(io).as(HTTP2::Frame::ResetStream)
          reset.stream_id.should eq(id)
        end
      end

      # Cancellation is a reset-tolerant closure (LocalReset), so age-aware
      # retention protects each young entry past the soft
      # max_retained_closed_streams limit — eviction only resumes once the
      # hard cap (4x the limit) is reached. 9 cancellations against a limit
      # of 2 (hard cap 8) forces exactly one eviction, from the FIFO head.
      configuration = HTTP2::Connection::Configuration.new(
        max_retained_closed_streams: 2
      )
      connection = HTTP2::Connection.start(client, configuration)
      begin
        connection.wait_until_active(1.second)
        streams = (0...9).map do
          stream = connection.new_stream
          open_client_stream(stream, end_stream: false)
          stream
        end
        stream_ids.send(streams.map(&.id))
        streams.each(&.cancel)

        connection.retained_closed_stream_count.should eq(8)
        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end

  it "retains a reset-tolerant closed stream past the count limit for " \
     "late DATA" do
    UNIXSocket.pair do |client, peer|
      canceled_id = Channel(UInt32).new(1)
      churn_ids = Channel(Array(UInt32)).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        id = canceled_id.receive
        read_client_headers(io, id)
        reset = HTTP2::Frame.read(io).as(HTTP2::Frame::ResetStream)
        reset.stream_id.should eq(id)

        ids = churn_ids.receive
        ids.each do |churn_id|
          read_client_headers(io, churn_id)
          HTTP2::Frame::Headers.new(
            HTTP2::Frame::Headers::Flags::END_HEADERS |
            HTTP2::Frame::Headers::Flags::END_STREAM,
            churn_id,
            Bytes.empty
          ).write(io)
        end
        io.flush

        # The canceled stream's still-in-flight DATA arrives after enough
        # churn to push retained metadata past max_retained_closed_streams.
        HTTP2::Frame::Data.new(0_u8, id, "late").write(io)
        io.flush

        connection_update = HTTP2::Frame.read(io)
          .as(HTTP2::Frame::WindowUpdate)
        connection_update.stream_id.should eq(0_u32)
        connection_update.window_size_increment.should eq(4_u32)

        ping = HTTP2::Frame::Ping.new(0_u8, 0_u32, "still-ok")
        ping.write(io)
        io.flush
        HTTP2::Frame.read(io).as(HTTP2::Frame::Ping).ack?.should be_true
      end

      configuration = HTTP2::Connection::Configuration.new(
        max_retained_closed_streams: 8
      )
      connection = HTTP2::Connection.start(client, configuration)
      begin
        connection.wait_until_active(1.second)
        canceled = connection.new_stream
        open_client_stream(canceled, end_stream: false)
        canceled_id.send(canceled.id)
        canceled.cancel

        churn = (0...8).map do
          stream = connection.new_stream
          open_client_stream(stream)
          stream
        end
        churn_ids.send(churn.map(&.id))

        wait_for_peer(peer_result)
        connection.active?.should be_true
        connection.retained_closed_stream_count.should eq(9)
      ensure
        connection.close
      end
    end
  end

  it "evicts a non-tolerant closed stream once churn pushes retained " \
     "metadata past the soft limit" do
    UNIXSocket.pair do |client, peer|
      churn_ids = Channel(Array(UInt32)).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        ids = churn_ids.receive
        ids.each do |churn_id|
          read_client_headers(io, churn_id)
          HTTP2::Frame::Headers.new(
            HTTP2::Frame::Headers::Flags::END_HEADERS |
            HTTP2::Frame::Headers::Flags::END_STREAM,
            churn_id,
            Bytes.empty
          ).write(io)
        end
        io.flush

        ping = HTTP2::Frame::Ping.new(0_u8, 0_u32, "still-ok")
        ping.write(io)
        io.flush
        HTTP2::Frame.read(io).as(HTTP2::Frame::Ping).ack?.should be_true
      end

      # Every closure here is a clean, bidirectional END_STREAM (reason
      # EndStream), which does NOT tolerate late frames -- unlike the
      # LocalReset closures in the two retention examples above. With a
      # limit of 2 (hard cap 8), the 3rd closure pushes the retained
      # order's size to 3 -- over the soft limit but nowhere near the
      # hard cap -- so `retain_closed_stream_unlocked`'s FIFO head must
      # be evicted immediately instead of protected: this is the one
      # case the age-aware protection above does NOT cover, and exactly
      # what a `break if size <= hard_cap` regression (dropping the
      # tolerant-entry check from that method's break condition
      # entirely) would silently stop doing -- the two examples above
      # never catch that regression, since their own hard-cap arithmetic
      # happens to agree with it either way.
      configuration = HTTP2::Connection::Configuration.new(
        max_retained_closed_streams: 2
      )
      connection = HTTP2::Connection.start(client, configuration)
      begin
        connection.wait_until_active(1.second)
        churn = (0...3).map do
          stream = connection.new_stream
          open_client_stream(stream)
          stream
        end
        churn_ids.send(churn.map(&.id))

        wait_for_peer(peer_result)
        connection.active?.should be_true
        connection.retained_closed_stream_count.should eq(2)
      ensure
        connection.close
      end
    end
  end

  it "rejects a max_retained_closed_streams that would overflow the " \
     "internal 4x hard cap" do
    expect_raises(ArgumentError, /max_retained_closed_streams|hard cap/) do
      HTTP2::Connection::Configuration.new(
        max_retained_closed_streams: (Int32::MAX // 4) + 1
      )
    end

    # The boundary value itself (exactly at the ceiling) stays valid.
    HTTP2::Connection::Configuration.new(
      max_retained_closed_streams: Int32::MAX // 4
    )
  end

  it "tolerates DATA that arrives after a peer RST_STREAM (RFC 9113 " \
     "5.1)" do
    UNIXSocket.pair do |client, peer|
      stream_id = Channel(UInt32).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        id = stream_id.receive
        read_client_headers(io, id)

        HTTP2::Frame::ResetStream.new(
          id,
          HTTP2::ErrorCode::CANCEL
        ).write(io)
        io.flush

        HTTP2::Frame::Data.new(0_u8, id, "late").write(io)
        io.flush

        connection_update = HTTP2::Frame.read(io)
          .as(HTTP2::Frame::WindowUpdate)
        connection_update.stream_id.should eq(0_u32)
        connection_update.window_size_increment.should eq(4_u32)

        ping = HTTP2::Frame::Ping.new(0_u8, 0_u32, "still-ok")
        ping.write(io)
        io.flush
        HTTP2::Frame.read(io).as(HTTP2::Frame::Ping).ack?.should be_true
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        stream = connection.new_stream
        open_client_stream(stream, end_stream: false)
        stream_id.send(stream.id)

        error = expect_raises(HTTP2::Connection::StreamResetError) do
          stream.receive(1.second)
        end
        error.stream_id.should eq(stream.id)
        error.error_code.should eq(HTTP2::ErrorCode::CANCEL.to_u32)

        wait_for_peer(peer_result)
        connection.active?.should be_true
      ensure
        connection.close
      end
    end
  end

  it "treats RST_STREAM on an idle stream as a connection error" do
    UNIXSocket.pair do |client, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        HTTP2::Frame::ResetStream.new(
          1_u32,
          HTTP2::ErrorCode::CANCEL
        ).write(io)
        io.flush

        goaway = HTTP2::Frame.read(io).as(HTTP2::Frame::GoAway)
        goaway.error_code.should eq(HTTP2::ErrorCode::PROTOCOL_ERROR.to_u32)
      end

      connection = HTTP2::Connection.start(client)
      connection.wait_until_active(1.second)
      connection.wait_closed(1.second)
      error = connection.terminal_error.as(HTTP2::ProtocolError)
      error.error_code.should eq(HTTP2::ErrorCode::PROTOCOL_ERROR)
      wait_for_peer(peer_result)
    end
  end
end
