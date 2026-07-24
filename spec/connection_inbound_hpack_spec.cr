require "./spec_helper"

private def write_inbound_field_block(
  io : IO,
  stream_id : UInt32,
  encoded : Bytes,
  *,
  end_stream : Bool = false,
) : Nil
  flags = HTTP2::Frame::Headers::Flags::END_HEADERS
  flags |= HTTP2::Frame::Headers::Flags::END_STREAM if end_stream
  HTTP2::Frame::Headers.new(flags, stream_id, encoded).write(io)
  io.flush
end

describe HTTP2::Connection do
  it "decodes sequential blocks with one persistent HPACK context" do
    UNIXSocket.pair do |client, peer|
      stream_ids = Channel(Tuple(UInt32, UInt32)).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        first_id, second_id = stream_ids.receive
        read_client_headers(io, first_id)
        read_client_headers(io, second_id)

        write_inbound_field_block(
          io,
          first_id,
          Bytes[
            0x40, 0x01, 0x6b, 0x01, 0x76,
            0x10, 0x01, 0x73,
            0x06, 0x73, 0x65, 0x63, 0x72, 0x65, 0x74,
          ]
        )
        write_inbound_field_block(io, second_id, Bytes[0xbe])
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        first_stream = connection.new_stream
        second_stream = connection.new_stream
        open_client_stream(first_stream)
        open_client_stream(second_stream)
        stream_ids.send({first_stream.id, second_stream.id})

        first = first_stream.receive(1.second)
          .as(HTTP2::Connection::FieldSection)
        second = second_stream.receive(1.second)
          .as(HTTP2::Connection::FieldSection)

        first.fields.should eq([
          HTTP2::DecodedHeaderField.new(
            "k",
            "v",
            HTTP2::DecodedHeaderField::Indexing::Incremental
          ),
          HTTP2::DecodedHeaderField.new(
            "s",
            "secret",
            HTTP2::DecodedHeaderField::Indexing::Never
          ),
        ])
        second.fields.should eq([
          HTTP2::DecodedHeaderField.new(
            "k",
            "v",
            HTTP2::DecodedHeaderField::Indexing::Indexed
          ),
        ])
        first.decoded_size.should eq(73_u64)
        second.decoded_size.should eq(34_u64)
        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end

  it "preserves decoder state after resetting an oversized field section" do
    UNIXSocket.pair do |client, peer|
      configuration = HTTP2::Connection::Configuration.new(
        max_decoded_field_section_size: 34
      )
      stream_ids = Channel(Tuple(UInt32, UInt32)).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        first_id, second_id = stream_ids.receive
        read_client_headers(io, first_id)
        read_client_headers(io, second_id)

        write_inbound_field_block(
          io,
          first_id,
          Bytes[
            0x00, 0x01, 0x61, 0x01, 0x41,
            0x40, 0x01, 0x6b, 0x01, 0x76,
          ]
        )
        reset = HTTP2::Frame.read(io).as(HTTP2::Frame::ResetStream)
        reset.stream_id.should eq(first_id)
        reset.error_code.should eq(
          HTTP2::ErrorCode::ENHANCE_YOUR_CALM.to_u32
        )

        write_inbound_field_block(io, second_id, Bytes[0xbe])
      end

      connection = HTTP2::Connection.start(client, configuration)
      begin
        connection.wait_until_active(1.second)
        first_stream = connection.new_stream
        second_stream = connection.new_stream
        open_client_stream(first_stream)
        open_client_stream(second_stream)
        stream_ids.send({first_stream.id, second_stream.id})

        error = expect_raises(HTTP2::ProtocolError) do
          first_stream.receive(1.second)
        end
        error.error_code.should eq(HTTP2::ErrorCode::ENHANCE_YOUR_CALM)
        error.stream?.should be_true

        section = second_stream.receive(1.second)
          .as(HTTP2::Connection::FieldSection)
        section.fields.map { |field| {field.name, field.value} }.should eq([
          {"k", "v"},
        ])
        connection.active?.should be_true
        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end

  it "bounds decoded field count while preserving decoder state" do
    UNIXSocket.pair do |client, peer|
      configuration = HTTP2::Connection::Configuration.new(
        max_decoded_fields: 2
      )
      stream_ids = Channel(Tuple(UInt32, UInt32)).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        first_id, second_id = stream_ids.receive
        read_client_headers(io, first_id)
        read_client_headers(io, second_id)

        write_inbound_field_block(
          io,
          first_id,
          Bytes[
            0x88,
            0x00, 0x01, 0x78, 0x01, 0x61,
            0x40, 0x01, 0x6b, 0x01, 0x76,
          ]
        )
        reset = HTTP2::Frame.read(io).as(HTTP2::Frame::ResetStream)
        reset.stream_id.should eq(first_id)
        reset.error_code.should eq(
          HTTP2::ErrorCode::ENHANCE_YOUR_CALM.to_u32
        )

        write_inbound_field_block(io, second_id, Bytes[0xbe])
      end

      connection = HTTP2::Connection.start(client, configuration)
      begin
        connection.wait_until_active(1.second)
        first_stream = connection.new_stream
        second_stream = connection.new_stream
        open_client_stream(first_stream)
        open_client_stream(second_stream)
        stream_ids.send({first_stream.id, second_stream.id})

        error = expect_raises(HTTP2::ProtocolError) do
          first_stream.receive(1.second)
        end
        error.error_code.should eq(HTTP2::ErrorCode::ENHANCE_YOUR_CALM)

        section = second_stream.receive(1.second)
          .as(HTTP2::Connection::FieldSection)
        section.fields.map { |field| {field.name, field.value} }.should eq([
          {"k", "v"},
        ])
        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end

  it "reports malformed suppressed bytes as a compression error" do
    UNIXSocket.pair do |client, peer|
      configuration = HTTP2::Connection::Configuration.new(
        max_decoded_field_section_size: 33
      )
      stream_id = Channel(UInt32).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        id = stream_id.receive
        read_client_headers(io, id)
        write_inbound_field_block(
          io,
          id,
          Bytes[0x40, 0x01, 0x6b, 0x01, 0x76, 0x80]
        )

        goaway = HTTP2::Frame.read(io).as(HTTP2::Frame::GoAway)
        goaway.error_code.should eq(
          HTTP2::ErrorCode::COMPRESSION_ERROR.to_u32
        )
      end

      connection = HTTP2::Connection.start(client, configuration)
      connection.wait_until_active(1.second)
      stream = connection.new_stream
      open_client_stream(stream)
      stream_id.send(stream.id)
      connection.wait_closed(1.second)

      error = connection.terminal_error.as(HTTP2::ProtocolError)
      error.error_code.should eq(HTTP2::ErrorCode::COMPRESSION_ERROR)
      error.connection?.should be_true
      wait_for_peer(peer_result)
    end
  end

  it "closes when one decoded literal exceeds the hard cap" do
    UNIXSocket.pair do |client, peer|
      configuration = HTTP2::Connection::Configuration.new(
        max_decoded_field_section_size: 64,
        max_decoded_string_size: 4
      )
      stream_id = Channel(UInt32).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        id = stream_id.receive
        read_client_headers(io, id)
        write_inbound_field_block(
          io,
          id,
          Bytes[
            0x00, 0x01, 0x78,
            0x05, 0x61, 0x62, 0x63, 0x64, 0x65,
          ]
        )

        goaway = HTTP2::Frame.read(io).as(HTTP2::Frame::GoAway)
        goaway.error_code.should eq(
          HTTP2::ErrorCode::ENHANCE_YOUR_CALM.to_u32
        )
      end

      connection = HTTP2::Connection.start(client, configuration)
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

  it "applies an acknowledged decoder-table reduction to the next block" do
    UNIXSocket.pair do |client, peer|
      configuration = HTTP2::Connection::Configuration.new(
        max_decoded_field_section_size: 42,
        initial_settings: [
          HTTP2::Frame::Settings::Setting.new(
            HTTP2::Frame::Settings::Identifier::HEADER_TABLE_SIZE,
            32_u32
          ),
        ]
      )
      stream_id = Channel(UInt32).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        id = stream_id.receive
        read_client_headers(io, id)
        write_inbound_field_block(io, id, Bytes[0x3f, 0x01, 0x82])
      end

      connection = HTTP2::Connection.start(client, configuration)
      begin
        connection.wait_until_active(1.second)
        stream = connection.new_stream
        open_client_stream(stream)
        stream_id.send(stream.id)

        section = stream.receive(1.second)
          .as(HTTP2::Connection::FieldSection)
        section.fields.map { |field| {field.name, field.value} }.should eq([
          {":method", "GET"},
        ])
        section.decoded_size.should eq(42_u64)
        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end
end
