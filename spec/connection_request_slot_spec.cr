require "./spec_helper"

private def required_request_slot(
  connection : HTTP2::Connection,
) : HTTP2::Connection::RequestSlotReservation
  connection.try_reserve_request_slot ||
    raise "expected request-slot reservation"
end

private def request_slot_peer(
  io : IO,
  release : Channel(Nil),
  settings : HTTP2::Frame::Settings = HTTP2::Frame::Settings.new(
    [] of HTTP2::Frame::Settings::Setting
  ),
) : NamedTuple(
  result: Channel(Exception?),
  ready: Channel(Nil),
)
  ready = Channel(Nil).new
  result = scripted_peer(io) do |peer|
    complete_server_handshake(peer, settings)
    ready.close
    release.receive?
  end
  {result: result, ready: ready}
end

describe HTTP2::Connection::RequestSlotReservation do
  it "atomically reserves peer request capacity" do
    UNIXSocket.pair do |client_io, peer_io|
      release_peer = Channel(Nil).new
      peer = request_slot_peer(
        peer_io,
        release_peer,
        HTTP2::Frame::Settings.new([
          HTTP2::Frame::Settings::Setting.new(
            HTTP2::Frame::Settings::Identifier::MAX_CONCURRENT_STREAMS,
            1_u32
          ),
        ])
      )

      connection = HTTP2::Connection.start(client_io)
      begin
        connection.wait_until_active(1.second)
        peer[:ready].receive?
        reservation = required_request_slot(connection)
        connection.try_reserve_request_slot.should be_nil

        capacity = connection.request_capacity
        capacity.reservations.should eq(1)
        capacity.peer_committed.should eq(1)

        reservation.release
        reservation.release
        connection.request_capacity.reservations.should eq(0)
        connection.try_reserve_request_slot.should_not be_nil
      ensure
        connection.close
        release_peer.close
        wait_for_peer(peer[:result])
      end
    end
  end

  it "materializes a reservation without an admission gap" do
    UNIXSocket.pair do |client_io, peer_io|
      release_peer = Channel(Nil).new
      peer = request_slot_peer(
        peer_io,
        release_peer,
        HTTP2::Frame::Settings.new([
          HTTP2::Frame::Settings::Setting.new(
            HTTP2::Frame::Settings::Identifier::MAX_CONCURRENT_STREAMS,
            1_u32
          ),
        ])
      )

      connection = HTTP2::Connection.start(client_io)
      begin
        connection.wait_until_active(1.second)
        peer[:ready].receive?
        reservation = required_request_slot(connection)
        stream = connection.materialize_request_stream(reservation)

        capacity = connection.request_capacity
        capacity.reservations.should eq(0)
        capacity.idle_client_streams.should eq(1)
        capacity.peer_committed.should eq(1)
        connection.try_reserve_request_slot.should be_nil

        stream.cancel
        connection.request_capacity.peer_committed.should eq(0)
        connection.try_reserve_request_slot.should_not be_nil
      ensure
        connection.close
        release_peer.close
        wait_for_peer(peer[:result])
      end
    end
  end

  it "admits exactly one concurrent winner for one peer slot" do
    UNIXSocket.pair do |client_io, peer_io|
      release_peer = Channel(Nil).new
      peer = request_slot_peer(
        peer_io,
        release_peer,
        HTTP2::Frame::Settings.new([
          HTTP2::Frame::Settings::Setting.new(
            HTTP2::Frame::Settings::Identifier::MAX_CONCURRENT_STREAMS,
            1_u32
          ),
        ])
      )

      connection = HTTP2::Connection.start(client_io)
      begin
        connection.wait_until_active(1.second)
        peer[:ready].receive?
        results = Channel(HTTP2::Connection::RequestSlotReservation?).new(16)
        16.times do
          spawn { results.send(connection.try_reserve_request_slot) }
        end
        reservations = Array.new(16) { results.receive }.compact
        reservations.size.should eq(1)
        connection.request_capacity.reservations.should eq(1)
        reservations.first.release
      ensure
        connection.close
        release_peer.close
        wait_for_peer(peer[:result])
      end
    end
  end

  it "counts reservations against the local open-stream limit" do
    UNIXSocket.pair do |client_io, peer_io|
      release_peer = Channel(Nil).new
      peer = request_slot_peer(peer_io, release_peer)
      configuration = HTTP2::Connection::Configuration.new(
        max_open_streams: 1
      )
      connection = HTTP2::Connection.start(client_io, configuration)

      begin
        connection.wait_until_active(1.second)
        peer[:ready].receive?
        reservation = required_request_slot(connection)
        connection.try_reserve_request_slot.should be_nil
        reservation.release
      ensure
        connection.close
        release_peer.close
        wait_for_peer(peer[:result])
      end
    end
  end

  it "revalidates a lower peer limit before materialization" do
    UNIXSocket.pair do |client_io, peer_io|
      lower_limit = Channel(Nil).new
      lowered = Channel(Nil).new
      release_peer = Channel(Nil).new
      peer_result = scripted_peer(peer_io) do |io|
        complete_server_handshake(
          io,
          HTTP2::Frame::Settings.new([
            HTTP2::Frame::Settings::Setting.new(
              HTTP2::Frame::Settings::Identifier::MAX_CONCURRENT_STREAMS,
              2_u32
            ),
          ])
        )
        lower_limit.receive?
        HTTP2::Frame::Settings.new([
          HTTP2::Frame::Settings::Setting.new(
            HTTP2::Frame::Settings::Identifier::MAX_CONCURRENT_STREAMS,
            1_u32
          ),
        ]).write(io)
        io.flush
        HTTP2::Frame.read(io).as(HTTP2::Frame::Settings).ack?.should be_true
        lowered.close
        release_peer.receive?
      end
      connection = HTTP2::Connection.start(client_io)

      begin
        connection.wait_until_active(1.second)
        first = required_request_slot(connection)
        second = required_request_slot(connection)
        lower_limit.close
        lowered.receive?
        eventually(message: "peer limit did not update") do
          connection.request_capacity.peer_limit == 1_u32
        end

        expect_raises(HTTP2::Connection::ConcurrentStreamLimitError) do
          connection.materialize_request_stream(first)
        end
        connection.request_capacity.reservations.should eq(1)
        stream = connection.materialize_request_stream(second)
        stream.cancel
      ensure
        connection.close
        lower_limit.close rescue nil
        release_peer.close
        wait_for_peer(peer_result)
      end
    end
  end

  it "invalidates reservations when the connection closes" do
    UNIXSocket.pair do |client_io, peer_io|
      release_peer = Channel(Nil).new
      peer = request_slot_peer(peer_io, release_peer)
      connection = HTTP2::Connection.start(client_io)
      connection.wait_until_active(1.second)
      peer[:ready].receive?
      reservation = required_request_slot(connection)
      connection.close

      expect_raises(HTTP2::Connection::InvalidStateError) do
        connection.materialize_request_stream(reservation)
      end
      connection.request_capacity.reservations.should eq(0)
      release_peer.close
      wait_for_peer(peer[:result])
    end
  end

  it "rejects and releases a reservation after peer GOAWAY" do
    UNIXSocket.pair do |client_io, peer_io|
      send_goaway = Channel(Nil).new
      release_peer = Channel(Nil).new
      peer_result = scripted_peer(peer_io) do |io|
        complete_server_handshake(io)
        send_goaway.receive?
        HTTP2::Frame::GoAway.new(
          0_u32,
          HTTP2::ErrorCode::NO_ERROR
        ).write(io)
        io.flush
        release_peer.receive?
      end
      connection = HTTP2::Connection.start(client_io)

      begin
        connection.wait_until_active(1.second)
        reservation = required_request_slot(connection)
        send_goaway.close
        eventually(message: "connection did not enter draining state") do
          connection.draining?
        end

        expect_raises(HTTP2::Connection::DrainingError) do
          connection.materialize_request_stream(reservation)
        end
        connection.request_capacity.reservations.should eq(0)
      ensure
        connection.close
        send_goaway.close rescue nil
        release_peer.close
        wait_for_peer(peer_result)
      end
    end
  end

  it "notifies independent capacity subscribers" do
    UNIXSocket.pair do |client_io, peer_io|
      release_peer = Channel(Nil).new
      peer = request_slot_peer(peer_io, release_peer)
      connection = HTTP2::Connection.start(client_io)

      begin
        connection.wait_until_active(1.second)
        peer[:ready].receive?
        first_count = Atomic(Int32).new(0)
        second_count = Atomic(Int32).new(0)
        first = connection.subscribe_pool_state { first_count.add(1) }
        second = connection.subscribe_pool_state { second_count.add(1) }

        reservation = required_request_slot(connection)
        reservation.release
        eventually(message: "capacity subscribers were not notified") do
          first_count.get == 1 && second_count.get == 1
        end

        first.unsubscribe
        next_reservation = required_request_slot(connection)
        next_reservation.release
        eventually(message: "remaining capacity subscriber was not notified") do
          second_count.get == 2
        end
        first_count.get.should eq(1)
        second.unsubscribe
      ensure
        connection.close
        release_peer.close
        wait_for_peer(peer[:result])
      end
    end
  end

  it "reserves the final stream ID only once" do
    UNIXSocket.pair do |client_io, peer_io|
      release_peer = Channel(Nil).new
      peer = request_slot_peer(peer_io, release_peer)
      connection = HTTP2::Connection.start(client_io)

      begin
        connection.wait_until_active(1.second)
        peer[:ready].receive?
        connection.test_only_next_client_stream_id =
          HTTP2::FrameHeader::MAX_STREAM_ID
        reservation = required_request_slot(connection)
        connection.try_reserve_request_slot.should be_nil
        stream = connection.materialize_request_stream(reservation)
        stream.id.should eq(HTTP2::FrameHeader::MAX_STREAM_ID)
        connection.request_capacity.stream_ids_exhausted.should be_true
        connection.try_reserve_request_slot.should be_nil
        stream.cancel
      ensure
        connection.close
        release_peer.close
        wait_for_peer(peer[:result])
      end
    end
  end

  it "rejects a reservation when a raw opener consumes the final ID" do
    UNIXSocket.pair do |client_io, peer_io|
      release_peer = Channel(Nil).new
      peer = request_slot_peer(peer_io, release_peer)
      connection = HTTP2::Connection.start(client_io)

      begin
        connection.wait_until_active(1.second)
        peer[:ready].receive?
        connection.test_only_next_client_stream_id =
          HTTP2::FrameHeader::MAX_STREAM_ID
        reservation = required_request_slot(connection)
        raw_stream = connection.new_stream
        expect_raises(HTTP2::Connection::StreamIDExhaustedError) do
          connection.materialize_request_stream(reservation)
        end
        connection.request_capacity.reservations.should eq(0)
        raw_stream.cancel
      ensure
        connection.close
        release_peer.close
        wait_for_peer(peer[:result])
      end
    end
  end
end
