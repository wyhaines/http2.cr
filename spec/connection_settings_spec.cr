require "./spec_helper"

describe HTTP2::Connection do
  it "applies peer settings in order and acknowledges each frame" do
    UNIXSocket.pair do |client, peer|
      initial = HTTP2::Frame::Settings.new([
        HTTP2::Frame::Settings::Setting.new(
          HTTP2::Frame::Settings::Identifier::MAX_CONCURRENT_STREAMS,
          10_u32
        ),
        HTTP2::Frame::Settings::Setting.new(
          HTTP2::Frame::Settings::Identifier::ENABLE_PUSH,
          0_u32
        ),
      ])
      update = HTTP2::Frame::Settings.new([
        HTTP2::Frame::Settings::Setting.new(
          HTTP2::Frame::Settings::Identifier::HEADER_TABLE_SIZE,
          1_024_u32
        ),
        HTTP2::Frame::Settings::Setting.new(0xbeef_u16, 9_u32),
        HTTP2::Frame::Settings::Setting.new(
          HTTP2::Frame::Settings::Identifier::HEADER_TABLE_SIZE,
          2_048_u32
        ),
      ])
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io, initial)
        update.write(io)
        io.flush
        HTTP2::Frame.read(io).as(HTTP2::Frame::Settings).ack?.should be_true
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        wait_for_peer(peer_result)

        settings = connection.peer_settings_state
        settings.max_concurrent_streams.should eq(10_u32)
        settings.enable_push?.should be_false
        settings.header_table_size.should eq(2_048_u32)
        connection.peer_settings.try(&.entries).should eq(update.entries)
      ensure
        connection.close
      end
    end
  end

  it "applies locally advertised settings when their ACK arrives" do
    UNIXSocket.pair do |client, peer|
      configuration = HTTP2::Connection::Configuration.new(
        initial_settings: [
          HTTP2::Frame::Settings::Setting.new(
            HTTP2::Frame::Settings::Identifier::HEADER_TABLE_SIZE,
            1_024_u32
          ),
        ]
      )
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
      end

      connection = HTTP2::Connection.start(client, configuration)
      begin
        connection.wait_until_active(1.second)
        eventually(message: "initial SETTINGS ACK was not applied") do
          connection.pending_settings_count.zero?
        end

        connection.local_settings_state.header_table_size.should eq(1_024_u32)
        connection.effective_local_settings_state
          .header_table_size.should eq(1_024_u32)
        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end

  it "matches ACKs to multiple local SETTINGS frames in FIFO order" do
    UNIXSocket.pair do |client, peer|
      updates_received = Channel(Nil).new(1)
      acknowledge_first = Channel(Nil).new(1)
      first_ack_sent = Channel(Nil).new(1)
      acknowledge_second = Channel(Nil).new(1)

      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        2.times do
          frame = HTTP2::Frame.read(io).as(HTTP2::Frame::Settings)
          frame.ack?.should be_false
        end
        updates_received.send(nil)

        acknowledge_first.receive
        HTTP2::Frame::Settings.ack.write(io)
        io.flush
        first_ack_sent.send(nil)

        acknowledge_second.receive
        HTTP2::Frame::Settings.ack.write(io)
        io.flush
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        eventually { connection.pending_settings_count.zero? }

        connection.send_settings([
          HTTP2::Frame::Settings::Setting.new(
            HTTP2::Frame::Settings::Identifier::HEADER_TABLE_SIZE,
            1_024_u32
          ),
        ])
        connection.send_settings([
          HTTP2::Frame::Settings::Setting.new(
            HTTP2::Frame::Settings::Identifier::HEADER_TABLE_SIZE,
            2_048_u32
          ),
        ])

        updates_received.receive
        connection.pending_settings_count.should eq(2)
        acknowledge_first.send(nil)
        first_ack_sent.receive
        eventually { connection.pending_settings_count == 1 }
        connection.effective_local_settings_state
          .header_table_size.should eq(1_024_u32)

        acknowledge_second.send(nil)
        eventually { connection.pending_settings_count.zero? }
        connection.effective_local_settings_state
          .header_table_size.should eq(2_048_u32)
        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end

  it "maps invalid peer settings to their required connection errors" do
    invalid_settings = [
      {
        HTTP2::Frame::Settings::Setting.new(
          HTTP2::Frame::Settings::Identifier::ENABLE_PUSH,
          1_u32
        ),
        HTTP2::ErrorCode::PROTOCOL_ERROR,
      },
      {
        HTTP2::Frame::Settings::Setting.new(
          HTTP2::Frame::Settings::Identifier::INITIAL_WINDOW_SIZE,
          0x8000_0000_u32
        ),
        HTTP2::ErrorCode::FLOW_CONTROL_ERROR,
      },
      {
        HTTP2::Frame::Settings::Setting.new(
          HTTP2::Frame::Settings::Identifier::MAX_FRAME_SIZE,
          16_383_u32
        ),
        HTTP2::ErrorCode::PROTOCOL_ERROR,
      },
    ]

    invalid_settings.each do |setting, error_code|
      UNIXSocket.pair do |client, peer|
        peer_result = scripted_peer(peer) do |io|
          read_client_preface(io)
          HTTP2::Frame::Settings.new([setting]).write(io)
          io.flush
          goaway = HTTP2::Frame.read(io).as(HTTP2::Frame::GoAway)
          goaway.error_code.should eq(error_code.to_u32)
        end

        connection = HTTP2::Connection.start(client)
        error = expect_raises(HTTP2::ProtocolError) do
          connection.wait_until_active(1.second)
        end
        error.error_code.should eq(error_code)
        connection.wait_closed(1.second)
        wait_for_peer(peer_result)
      end
    end
  end

  it "closes with SETTINGS_TIMEOUT when the peer does not acknowledge" do
    UNIXSocket.pair do |client, peer|
      configuration = HTTP2::Connection::Configuration.new(
        settings_ack_timeout: 50.milliseconds
      )
      peer_result = scripted_peer(peer) do |io|
        read_client_preface(io)
        HTTP2::Frame::Settings.new(
          [] of HTTP2::Frame::Settings::Setting
        ).write(io)
        io.flush
        HTTP2::Frame.read(io).as(HTTP2::Frame::Settings).ack?.should be_true

        goaway = HTTP2::Frame.read(io).as(HTTP2::Frame::GoAway)
        goaway.error_code.should eq(HTTP2::ErrorCode::SETTINGS_TIMEOUT.to_u32)
      end

      connection = HTTP2::Connection.start(client, configuration)
      connection.wait_until_active(1.second)
      connection.wait_closed(1.second)

      error = connection.terminal_error.as(HTTP2::ProtocolError)
      error.error_code.should eq(HTTP2::ErrorCode::SETTINGS_TIMEOUT)
      wait_for_peer(peer_result)
    end
  end

  it "rejects an advertised field-section size above the decoder budget" do
    UNIXSocket.pair do |client, peer|
      configuration = HTTP2::Connection::Configuration.new(
        max_decoded_field_section_size: 1_024
      )
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
      end

      connection = HTTP2::Connection.start(client, configuration)
      begin
        connection.wait_until_active(1.second)
        eventually { connection.pending_settings_count.zero? }

        expect_raises(ArgumentError, /decoded field-section limit/) do
          connection.send_settings([
            HTTP2::Frame::Settings::Setting.new(
              HTTP2::Frame::Settings::Identifier::MAX_HEADER_LIST_SIZE,
              2_048_u32
            ),
          ])
        end
        connection.local_settings_state
          .max_header_list_size.should eq(1_024_u32)
        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end

  it "rejects a SETTINGS ACK with no outstanding update" do
    UNIXSocket.pair do |client, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        HTTP2::Frame::Settings.ack.write(io)
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
