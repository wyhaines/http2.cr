require "./spec_helper"

describe HTTP2::Connection do
  it "delivers one complete event for a fragmented field block" do
    UNIXSocket.pair do |client, peer|
      stream_id = Channel(UInt32).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        id = stream_id.receive
        HTTP2::Frame::Headers.new(0_u8, id, Bytes[1, 2]).write(io)
        HTTP2::Frame::Continuation.new(
          HTTP2::Frame::Continuation::Flags::END_HEADERS,
          id,
          Bytes[3, 4]
        ).write(io)
        io.flush
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        stream = connection.new_stream
        stream_id.send(stream.id)

        block = stream.receive(1.second).as(HTTP2::Connection::FieldBlock)
        block.stream_id.should eq(stream.id)
        block.encoded.should eq(Bytes[1, 2, 3, 4])
        block.continuation_count.should eq(1)
        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end

  it "closes the connection when another frame interrupts a field block" do
    UNIXSocket.pair do |client, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        HTTP2::Frame::Headers.new(0_u8, 1_u32, Bytes[1]).write(io)
        HTTP2::Frame::Ping.new(0_u8, 0_u32, "12345678").write(io)
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

  it "maps compressed field-block exhaustion as a resource error" do
    UNIXSocket.pair do |client, peer|
      configuration = HTTP2::Connection::Configuration.new(
        max_compressed_field_section_size: 2
      )
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        HTTP2::Frame::Headers.new(0_u8, 1_u32, Bytes[1, 2]).write(io)
        HTTP2::Frame::Continuation.new(
          HTTP2::Frame::Continuation::Flags::END_HEADERS,
          1_u32,
          Bytes[3]
        ).write(io)
        io.flush

        goaway = HTTP2::Frame.read(io).as(HTTP2::Frame::GoAway)
        goaway.error_code.should eq(
          HTTP2::ErrorCode::ENHANCE_YOUR_CALM.to_u32
        )
      end

      connection = HTTP2::Connection.start(client, configuration)
      connection.wait_until_active(1.second)
      connection.wait_closed(1.second)

      connection.terminal_error.should be_a(
        HTTP2::Connection::ResourceLimitError
      )
      wait_for_peer(peer_result)
    end
  end
end
