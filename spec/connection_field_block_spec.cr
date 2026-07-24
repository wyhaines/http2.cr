require "./spec_helper"

describe HTTP2::Connection do
  it "delivers one decoded event for a fragmented field block" do
    UNIXSocket.pair do |client, peer|
      stream_id = Channel(UInt32).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        id = stream_id.receive
        HTTP2::Frame::Headers.new(
          HTTP2::Frame::Headers::Flags::END_STREAM,
          id,
          Bytes[0x00, 0x01]
        ).write(io)
        HTTP2::Frame::Continuation.new(
          HTTP2::Frame::Continuation::Flags::END_HEADERS,
          id,
          Bytes[0x78, 0x01, 0x79]
        ).write(io)
        io.flush
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        stream = connection.new_stream
        stream_id.send(stream.id)

        section = stream.receive(1.second)
          .as(HTTP2::Connection::FieldSection)
        section.stream_id.should eq(stream.id)
        section.fields.should eq([
          HTTP2::DecodedHeaderField.new(
            "x",
            "y",
            HTTP2::DecodedHeaderField::Indexing::None
          ),
        ])
        section.decoded_size.should eq(34_u64)
        section.end_stream?.should be_true
        section.continuation_count.should eq(1)
        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end

  it "decodes a fragmented field block at every split boundary" do
    encoded = Bytes[
      0x00,
      0x06, 0x78, 0x2d, 0x74, 0x65, 0x73, 0x74,
      0x02, 0x6f, 0x6b,
    ]

    UNIXSocket.pair do |client, peer|
      stream_ids = Channel(Array(UInt32)).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        ids = stream_ids.receive

        ids.each_with_index do |id, split|
          HTTP2::Frame::Headers.new(
            0_u8,
            id,
            encoded[0, split]
          ).write(io)
          HTTP2::Frame::Continuation.new(
            HTTP2::Frame::Continuation::Flags::END_HEADERS,
            id,
            encoded[split, encoded.size - split]
          ).write(io)
        end
        io.flush
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        streams = (0..encoded.size).map { connection.new_stream }
        stream_ids.send(streams.map(&.id))

        streams.each do |stream|
          section = stream.receive(1.second)
            .as(HTTP2::Connection::FieldSection)
          section.fields.map { |field| {field.name, field.value} }.should eq([
            {"x-test", "ok"},
          ])
        end
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
