require "./spec_helper"

private def client_read_field_section(
  io : IO,
  decoder : HPack::Decoder,
) : NamedTuple(
  stream_id: UInt32,
  end_stream: Bool,
  fields: Array(HPack::DecodedHeader),
)
  first = HTTP2::Frame.read(io).as(HTTP2::Frame::Headers)
  encoded = IO::Memory.new
  encoded.write(first.header_block_fragment)
  finished = first.end_headers?
  until finished
    continuation = HTTP2::Frame.read(io)
      .as(HTTP2::Frame::Continuation)
    continuation.stream_id.should eq(first.stream_id)
    encoded.write(continuation.header_block_fragment)
    finished = continuation.end_headers?
  end

  {
    stream_id:  first.stream_id,
    end_stream: first.end_stream?,
    fields:     decoder.decode_with_metadata(encoded.to_slice)[:fields],
  }
end

describe "HTTP2::Client recovery" do
  it "replays a proven-unprocessed owned POST only when explicitly allowed" do
    server = TCPServer.new("127.0.0.1", 0)
    peer_result = scripted_peer(server) do |listener_io|
      listener = listener_io.as(TCPServer)

      first = listener.accept
      begin
        complete_server_handshake(first)
        request = client_read_field_section(first, HPack::Decoder.new)
        field_pairs(request[:fields]).should contain({":method", "POST"})

        HTTP2::Frame::GoAway.new(
          0_u32,
          HTTP2::ErrorCode::NO_ERROR
        ).write(first)
        first.flush
        loop do
          break if HTTP2::Frame.read(first).is_a?(HTTP2::Frame::GoAway)
        end
        first.read(Bytes.new(1)).should eq(0)
      ensure
        first.close
      end

      second = listener.accept
      begin
        complete_server_handshake(second)
        request = client_read_field_section(second, HPack::Decoder.new)
        field_pairs(request[:fields]).should contain({":method", "POST"})
        request[:end_stream].should be_false

        body = IO::Memory.new
        ended = false
        until ended
          frame = HTTP2::Frame.read(second)
          next if frame.is_a?(HTTP2::Frame::WindowUpdate)

          data = frame.as(HTTP2::Frame::Data)
          data.stream_id.should eq(request[:stream_id])
          body.write(data.data)
          ended = data.end_stream?
        end
        body.to_s.should eq("repeatable")

        write_server_fields(
          second,
          HPack::Encoder.new,
          request[:stream_id],
          [{":status", "204"}],
          end_stream: true
        )
      ensure
        second.close
      end
    end

    http = HTTP2::Client.new(
      "http://127.0.0.1:#{server.local_address.port}",
      replay_policy: HTTP2::Client::ReplayPolicy::AnyRequest,
      timeouts: HTTP2::Client::Timeouts.new(
        connect: 1.second,
        read: 1.second,
        write: 1.second
      )
    )
    begin
      response = http.post("/", body: "repeatable")
      response.status.should eq(204)
      response.stream_id.should eq(1_u32)
      wait_for_peer(peer_result)
    ensure
      http.close
      server.close
    end
  end

  it "retries REFUSED_STREAM for an opted-in idempotent request" do
    UNIXSocket.pair do |client_io, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        decoder = HPack::Decoder.new
        first = client_read_field_section(io, decoder)
        HTTP2::Frame::ResetStream.new(
          first[:stream_id],
          HTTP2::ErrorCode::REFUSED_STREAM
        ).write(io)
        io.flush

        second = client_read_field_section(io, decoder)
        second[:stream_id].should eq(3_u32)
        write_server_fields(
          io,
          HPack::Encoder.new,
          second[:stream_id],
          [{":status", "204"}],
          end_stream: true
        )
      end

      connection = HTTP2::Connection.start(client_io)
      http = HTTP2::Client.new(
        "http://example.test",
        connection: connection,
        replay_policy: HTTP2::Client::ReplayPolicy::Idempotent
      )
      begin
        response = http.get("/")
        response.status.should eq(204)
        response.stream_id.should eq(3_u32)
        wait_for_peer(peer_result)
      ensure
        http.close
      end
    end
  end

  it "does not replay GOAWAY streams under the default policy" do
    UNIXSocket.pair do |client_io, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        request = client_read_field_section(io, HPack::Decoder.new)
        HTTP2::Frame::GoAway.new(
          0_u32,
          HTTP2::ErrorCode::NO_ERROR
        ).write(io)
        io.flush
        loop do
          break if HTTP2::Frame.read(io).is_a?(HTTP2::Frame::GoAway)
        end
        request[:stream_id].should eq(1_u32)
      end

      connection = HTTP2::Connection.start(client_io)
      http = HTTP2::Client.new(
        "http://example.test",
        connection: connection
      )
      expect_raises(HTTP2::Connection::UnprocessedStreamError) do
        http.get("/")
      end
      wait_for_peer(peer_result)
      http.close
    end
  end

  it "does not replay a caller-owned streaming IO" do
    server = TCPServer.new("127.0.0.1", 0)
    peer_result = scripted_peer(server) do |listener_io|
      listener = listener_io.as(TCPServer)
      socket = listener.accept
      begin
        complete_server_handshake(socket)
        client_read_field_section(socket, HPack::Decoder.new)
        HTTP2::Frame::GoAway.new(
          0_u32,
          HTTP2::ErrorCode::NO_ERROR
        ).write(socket)
        socket.flush
        loop do
          break if HTTP2::Frame.read(socket).is_a?(HTTP2::Frame::GoAway)
        end
      ensure
        socket.close
        listener.close
      end
    end

    http = HTTP2::Client.new(
      "http://127.0.0.1:#{server.local_address.port}",
      replay_policy: HTTP2::Client::ReplayPolicy::AnyRequest,
      timeouts: HTTP2::Client::Timeouts.new(
        connect: 1.second,
        read: 1.second,
        write: 1.second
      )
    )
    begin
      expect_raises(HTTP2::Connection::UnprocessedStreamError) do
        http.post("/", body: IO::Memory.new("one-shot"))
      end
      wait_for_peer(peer_result)
    ensure
      http.close
      server.close unless server.closed?
    end
  end

  it "validates the replay-attempt limit" do
    expect_raises(ArgumentError, /replay attempt/) do
      HTTP2::Client.new(
        "https://example.test",
        max_replay_attempts: -1
      )
    end
  end

  it "gracefully closes its owned connection" do
    UNIXSocket.pair do |client_io, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        goaway = HTTP2::Frame.read(io).as(HTTP2::Frame::GoAway)
        goaway.error_code.should eq(HTTP2::ErrorCode::NO_ERROR.to_u32)
        io.read(Bytes.new(1)).should eq(0)
      end

      connection = HTTP2::Connection.start(client_io)
      connection.wait_until_active(1.second)
      http = HTTP2::Client.new(
        "http://example.test",
        connection: connection
      )
      http.graceful_close(1.second)
      http.closed?.should be_true
      wait_for_peer(peer_result)
    end
  end
end

private def write_server_fields(
  io : IO,
  encoder : HPack::Encoder,
  stream_id : UInt32,
  fields : Array(Tuple(String, String)),
  *,
  end_stream : Bool = false,
) : Nil
  flags = HTTP2::Frame::Headers::Flags::END_HEADERS
  flags |= HTTP2::Frame::Headers::Flags::END_STREAM if end_stream
  HTTP2::Frame::Headers.new(
    flags,
    stream_id,
    encoder.encode(fields)
  ).write(io)
  io.flush
end

private def read_until_reset(io : IO) : HTTP2::Frame::ResetStream
  loop do
    frame = HTTP2::Frame.read(io)
    return frame if frame.is_a?(HTTP2::Frame::ResetStream)
  end
end

# Reads frames until both a RST_STREAM and a connection-level (stream 0)
# WINDOW_UPDATE have been observed, in either order, and returns both.
private def read_reset_and_connection_credit(
  io : IO,
) : Tuple(HTTP2::Frame::ResetStream, HTTP2::Frame::WindowUpdate)
  reset = nil
  credit = nil
  loop do
    frame = HTTP2::Frame.read(io)
    case frame
    when HTTP2::Frame::ResetStream
      reset = frame
    when HTTP2::Frame::WindowUpdate
      credit = frame if frame.stream_id.zero?
    end

    if (found_reset = reset) && (found_credit = credit)
      return {found_reset, found_credit}
    end
  end
end

private def read_client_data(io : IO) : HTTP2::Frame::Data
  loop do
    frame = HTTP2::Frame.read(io)
    case frame
    when HTTP2::Frame::Data
      return frame
    when HTTP2::Frame::WindowUpdate
      # Consuming inbound tunnel bytes can return flow-control credit first.
    else
      raise "expected client DATA, got #{frame.class}"
    end
  end
end

private def field_pairs(
  fields : Array(HPack::DecodedHeader),
) : Array(Tuple(String, String))
  fields.map { |field| {field.name, field.value} }
end

describe HTTP2::Client do
  it "performs a GET with ordered repeated response fields" do
    UNIXSocket.pair do |client_io, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        request = client_read_field_section(io, HPack::Decoder.new)
        request[:end_stream].should be_true
        field_pairs(request[:fields]).should eq([
          {":method", "GET"},
          {":scheme", "http"},
          {":authority", "example.test"},
          {":path", "/items?q=one"},
          {"accept", "text/plain"},
        ])

        encoder = HPack::Encoder.new
        write_server_fields(
          io,
          encoder,
          request[:stream_id],
          [
            {":status", "200"},
            {"set-cookie", "a=1"},
            {"set-cookie", "b=2"},
          ]
        )
        HTTP2::Frame::Data.new(
          HTTP2::Frame::Data::Flags::END_STREAM,
          request[:stream_id],
          "hello"
        ).write(io)
        io.flush
      end

      connection = HTTP2::Connection.start(client_io)
      http = HTTP2::Client.new(
        "http://example.test",
        connection: connection
      )
      begin
        response = http.get(
          "/items?q=one",
          HTTP2::Headers{"accept" => "text/plain"}
        )
        response.status.should eq(200)
        response.headers.get_all("set-cookie").should eq(["a=1", "b=2"])
        response.body.gets_to_end.should eq("hello")
        response.trailers.should be_empty
        wait_for_peer(peer_result)
      ensure
        http.close
      end
    end
  end

  it "downcases interop header names converted from HTTP::Headers on the wire" do
    UNIXSocket.pair do |client_io, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        request = client_read_field_section(io, HPack::Decoder.new)
        request[:end_stream].should be_true
        field_pairs(request[:fields]).should eq([
          {":method", "GET"},
          {":scheme", "http"},
          {":authority", "example.test"},
          {":path", "/"},
          {"content-type", "text/plain"},
        ])

        write_server_fields(
          io,
          HPack::Encoder.new,
          request[:stream_id],
          [{":status", "204"}],
          end_stream: true
        )
      end

      connection = HTTP2::Connection.start(client_io)
      http = HTTP2::Client.new(
        "http://example.test",
        connection: connection
      )
      begin
        sent_request = HTTP2::Request.new(
          "GET",
          "/",
          HTTP::Headers{"Content-Type" => "text/plain"}
        )
        response = http.request(sent_request)
        response.status.should eq(204)
        wait_for_peer(peer_result)
      ensure
        http.close
      end
    end
  end

  it "streams a POST and exposes response trailers" do
    UNIXSocket.pair do |client_io, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        decoder = HPack::Decoder.new
        request = client_read_field_section(io, decoder)
        request[:end_stream].should be_false
        field_pairs(request[:fields]).should eq([
          {":method", "POST"},
          {":scheme", "http"},
          {":authority", "example.test"},
          {":path", "/upload"},
          {"content-length", "7"},
        ])

        data = HTTP2::Frame.read(io).as(HTTP2::Frame::Data)
        data.data.should eq("payload".to_slice)
        data.end_stream?.should be_false
        request_trailers = client_read_field_section(io, decoder)
        request_trailers[:stream_id].should eq(request[:stream_id])
        request_trailers[:end_stream].should be_true
        field_pairs(request_trailers[:fields]).should eq([
          {"upload-checksum", "ok"},
        ])

        encoder = HPack::Encoder.new
        write_server_fields(
          io,
          encoder,
          request[:stream_id],
          [{":status", "201"}, {"content-length", "4"}]
        )
        HTTP2::Frame::Data.new(0_u8, request[:stream_id], "done").write(io)
        write_server_fields(
          io,
          encoder,
          request[:stream_id],
          [{"result-checksum", "ok"}],
          end_stream: true
        )
      end

      connection = HTTP2::Connection.start(client_io)
      http = HTTP2::Client.new(
        "http://example.test",
        connection: connection
      )
      begin
        response = http.post(
          "/upload",
          HTTP2::Headers{"content-length" => "7"},
          IO::Memory.new("payload"),
          trailers: HTTP2::Headers{"upload-checksum" => "ok"}
        )
        response.status.should eq(201)
        response.body.gets_to_end.should eq("done")
        response.trailers.to_a.should eq([
          HTTP2::Header.new("result-checksum", "ok"),
        ])
        wait_for_peer(peer_result)
      ensure
        http.close
      end
    end
  end

  it "sends a POST with positional headers and body plus keyword trailers" do
    UNIXSocket.pair do |client_io, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        decoder = HPack::Decoder.new
        request = client_read_field_section(io, decoder)
        request[:end_stream].should be_false
        field_pairs(request[:fields]).should eq([
          {":method", "POST"},
          {":scheme", "http"},
          {":authority", "example.test"},
          {":path", "/orders"},
          {"content-length", "6"},
        ])

        data = HTTP2::Frame.read(io).as(HTTP2::Frame::Data)
        data.data.should eq("order!".to_slice)
        data.end_stream?.should be_false
        request_trailers = client_read_field_section(io, decoder)
        request_trailers[:stream_id].should eq(request[:stream_id])
        request_trailers[:end_stream].should be_true
        field_pairs(request_trailers[:fields]).should eq([
          {"order-checksum", "ok"},
        ])

        write_server_fields(
          io,
          HPack::Encoder.new,
          request[:stream_id],
          [{":status", "201"}],
          end_stream: true
        )
      end

      connection = HTTP2::Connection.start(client_io)
      http = HTTP2::Client.new(
        "http://example.test",
        connection: connection
      )
      begin
        response = http.post(
          "/orders",
          HTTP2::Headers{"content-length" => "6"},
          IO::Memory.new("order!"),
          trailers: HTTP2::Headers{"order-checksum" => "ok"}
        )
        response.status.should eq(201)
        wait_for_peer(peer_result)
      ensure
        http.close
      end
    end
  end

  it "sends an IO chunk without waiting for the following read" do
    source, source_writer = IO.pipe
    first_chunk_seen = Channel(Nil).new(1)

    UNIXSocket.pair do |client_io, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        request = client_read_field_section(io, HPack::Decoder.new)
        request[:end_stream].should be_false

        first = HTTP2::Frame.read(io).as(HTTP2::Frame::Data)
        first.data.should eq("first".to_slice)
        first.end_stream?.should be_false
        first_chunk_seen.send(nil)

        second = HTTP2::Frame.read(io).as(HTTP2::Frame::Data)
        second.data.should eq("second".to_slice)
        second.end_stream?.should be_false
        ending = HTTP2::Frame.read(io).as(HTTP2::Frame::Data)
        ending.data.should be_empty
        ending.end_stream?.should be_true

        write_server_fields(
          io,
          HPack::Encoder.new,
          request[:stream_id],
          [{":status", "204"}],
          end_stream: true
        )
      end

      connection = HTTP2::Connection.start(client_io)
      http = HTTP2::Client.new(
        "http://example.test",
        connection: connection
      )
      response_result = Channel(HTTP2::Response | Exception).new(1)
      spawn do
        begin
          response_result.send(http.post("/stream", body: source))
        rescue error
          response_result.send(error)
        end
      end

      begin
        source_writer << "first"
        select
        when first_chunk_seen.receive
        when timeout(1.second)
          fail("the first request chunk was held until the next source read")
        end
        source_writer << "second"
        source_writer.close

        result = response_result.receive
        raise result if result.is_a?(Exception)
        result.status.should eq(204)
        wait_for_peer(peer_result)
      ensure
        source_writer.close unless source_writer.closed?
        source.close
        http.close
      end
    end
  end

  it "reuses one origin connection for concurrent requests" do
    request_count = 16
    UNIXSocket.pair do |client_io, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        decoder = HPack::Decoder.new
        requests = Array.new(request_count) do
          client_read_field_section(io, decoder)
        end
        ids = requests.map(&.[:stream_id]).sort!
        ids.should eq(
          Array.new(request_count) { |index| (index * 2 + 1).to_u32 }
        )

        encoder = HPack::Encoder.new
        ids.reverse_each do |id|
          write_server_fields(
            io,
            encoder,
            id,
            [{":status", "200"}, {"x-stream", id.to_s}],
            end_stream: true
          )
        end
      end

      connection = HTTP2::Connection.start(client_io)
      http = HTTP2::Client.new(
        "http://example.test",
        connection: connection
      )
      begin
        responses = Channel(HTTP2::Response | Exception).new(request_count)
        request_count.times do |index|
          spawn do
            begin
              responses.send(http.get("/#{index}"))
            rescue error
              responses.send(error)
            end
          end
        end
        observed = Array.new(request_count) do
          result = select
          when value = responses.receive
            value
          when timeout(2.seconds)
            fail("concurrent HTTP/2 requests did not complete")
          end
          raise result if result.is_a?(Exception)
          result
        end
        observed.map(&.stream_id).sort!.should eq(
          Array.new(request_count) { |index| (index * 2 + 1).to_u32 }
        )
        observed.each(&.body.gets_to_end.should(be_empty))
        wait_for_peer(peer_result)
      ensure
        http.close
      end
    end
  end

  it "raises the peer concurrent-stream limit immediately without a configured stream_slot wait" do
    UNIXSocket.pair do |client_io, peer|
      first_seen = Channel(Nil).new(1)
      peer_result = scripted_peer(peer) do |io|
        settings = HTTP2::Frame::Settings.new([
          HTTP2::Frame::Settings::Setting.new(
            HTTP2::Frame::Settings::Identifier::MAX_CONCURRENT_STREAMS,
            1_u32
          ),
        ])
        complete_server_handshake(io, settings)
        read_client_headers(io)
        first_seen.send(nil)
        # The first stream is left open (no response); the second
        # attempt below must not reach the peer at all.
      end

      connection = HTTP2::Connection.start(client_io)
      http = HTTP2::Client.new(
        "http://example.test",
        connection: connection
      )
      first_result = Channel(Exception?).new(1)
      begin
        spawn do
          begin
            http.get("/first")
            first_result.send(nil)
          rescue error
            first_result.send(error)
          end
        end

        first_seen.receive
        expect_raises(HTTP2::Connection::ConcurrentStreamLimitError) do
          http.get("/second")
        end
      ensure
        http.close
        first_result.receive
        wait_for_peer(peer_result)
      end
    end
  end

  it "waits for a peer concurrent-stream slot to free when stream_slot is configured" do
    UNIXSocket.pair do |client_io, peer|
      first_seen = Channel(Nil).new(1)
      peer_result = scripted_peer(peer) do |io|
        settings = HTTP2::Frame::Settings.new([
          HTTP2::Frame::Settings::Setting.new(
            HTTP2::Frame::Settings::Identifier::MAX_CONCURRENT_STREAMS,
            1_u32
          ),
        ])
        complete_server_handshake(io, settings)
        decoder = HPack::Decoder.new
        encoder = HPack::Encoder.new
        first = client_read_field_section(io, decoder)
        first_seen.send(nil)

        # Hold the only slot for a while so the second request's HEADERS
        # genuinely have to wait for `stream_slot`'s wakeup instead of
        # racing a slot that happened to already be free.
        quiet = Channel(Nil).new
        select
        when quiet.receive
        when timeout(150.milliseconds)
        end

        write_server_fields(
          io,
          encoder,
          first[:stream_id],
          [{":status", "200"}],
          end_stream: true
        )

        second = client_read_field_section(io, decoder)
        write_server_fields(
          io,
          encoder,
          second[:stream_id],
          [{":status", "200"}],
          end_stream: true
        )
      end

      connection = HTTP2::Connection.start(client_io)
      http = HTTP2::Client.new(
        "http://example.test",
        connection: connection,
        timeouts: HTTP2::Client::Timeouts.new(stream_slot: 1.second)
      )
      begin
        first_result = Channel(Exception?).new(1)
        spawn do
          begin
            http.get("/first")
            first_result.send(nil)
          rescue error
            first_result.send(error)
          end
        end

        first_seen.receive
        before = Time.instant
        response = http.get("/second")
        response.status.should eq(200)
        (Time.instant - before).should be >= 100.milliseconds

        wait_for_peer(peer_result)
        first_result.receive.should be_nil
      ensure
        http.close
      end
    end
  end

  it "dials once and reuses an owned cleartext origin connection" do
    server = TCPServer.new("127.0.0.1", 0)
    peer_result = scripted_peer(server) do |listener|
      socket = listener.as(TCPServer).accept
      begin
        complete_server_handshake(socket)
        decoder = HPack::Decoder.new
        encoder = HPack::Encoder.new
        2.times do
          request = client_read_field_section(socket, decoder)
          write_server_fields(
            socket,
            encoder,
            request[:stream_id],
            [{":status", "204"}],
            end_stream: true
          )
        end
      ensure
        socket.close
      end
    end

    http = HTTP2::Client.new(
      "http://127.0.0.1:#{server.local_address.port}",
      timeouts: HTTP2::Client::Timeouts.new(
        connect: 1.second,
        read: 1.second,
        write: 1.second
      )
    )
    begin
      http.get("/one").status.should eq(204)
      http.get("/two").status.should eq(204)
      wait_for_peer(peer_result)
    ensure
      http.close
      server.close
    end
  end

  it "collects informational responses before the final response" do
    UNIXSocket.pair do |client_io, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        request = client_read_field_section(io, HPack::Decoder.new)
        encoder = HPack::Encoder.new
        write_server_fields(
          io,
          encoder,
          request[:stream_id],
          [{":status", "103"}, {"link", "</style.css>; rel=preload"}]
        )
        write_server_fields(
          io,
          encoder,
          request[:stream_id],
          [{":status", "204"}],
          end_stream: true
        )
      end

      connection = HTTP2::Connection.start(client_io)
      http = HTTP2::Client.new(
        "http://example.test",
        connection: connection
      )
      begin
        response = http.get("/")
        response.status.should eq(204)
        response.informational_responses.should eq([
          HTTP2::InformationalResponse.new(
            103,
            HTTP2::Headers{"link" => "</style.css>; rel=preload"}
          ),
        ])
        response.body.gets_to_end.should be_empty
        wait_for_peer(peer_result)
      ensure
        http.close
      end
    end
  end

  it "resets a stream that floods informational responses" do
    UNIXSocket.pair do |client_io, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        request = client_read_field_section(io, HPack::Decoder.new)
        encoder = HPack::Encoder.new
        (HTTP2::ResponseValidator::DEFAULT_MAX_INFORMATIONAL_RESPONSES + 1)
          .times do
            write_server_fields(
              io,
              encoder,
              request[:stream_id],
              [{":status", "103"}]
            )
          end

        reset = nil
        until reset
          frame = HTTP2::Frame.read(io)
          reset = frame.as?(HTTP2::Frame::ResetStream)
        end
        reset.stream_id.should eq(request[:stream_id])
        reset.error_code.should eq(HTTP2::ErrorCode::PROTOCOL_ERROR.to_u32)
      end

      connection = HTTP2::Connection.start(client_io)
      http = HTTP2::Client.new(
        "http://example.test",
        connection: connection
      )
      begin
        expect_raises(HTTP2::MalformedResponseError, /informational/) do
          http.get("/")
        end
        wait_for_peer(peer_result)
      ensure
        http.close
      end
    end
  end

  it "constructs ordinary CONNECT pseudo-fields" do
    UNIXSocket.pair do |client_io, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        request = client_read_field_section(io, HPack::Decoder.new)
        field_pairs(request[:fields]).should eq([
          {":method", "CONNECT"},
          {":authority", "upstream.example:443"},
        ])
        write_server_fields(
          io,
          HPack::Encoder.new,
          request[:stream_id],
          [{":status", "200"}],
          end_stream: true
        )
      end

      connection = HTTP2::Connection.start(client_io)
      http = HTTP2::Client.new(
        "http://proxy.example",
        connection: connection
      )
      begin
        http.request("CONNECT", "upstream.example:443").status.should eq(200)
        wait_for_peer(peer_result)
      ensure
        http.close
      end
    end
  end

  it "starts CONNECT tunnel data only after a successful response" do
    UNIXSocket.pair do |client_io, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        request = client_read_field_section(io, HPack::Decoder.new)
        request[:end_stream].should be_false
        field_pairs(request[:fields]).should eq([
          {":method", "CONNECT"},
          {":authority", "upstream.example:443"},
        ])

        write_server_fields(
          io,
          HPack::Encoder.new,
          request[:stream_id],
          [{":status", "200"}, {"content-length", "999"}]
        )
        tunnel_data = HTTP2::Frame.read(io).as(HTTP2::Frame::Data)
        tunnel_data.data.should eq("outbound".to_slice)
        tunnel_data.end_stream?.should be_false
        tunnel_end = HTTP2::Frame.read(io).as(HTTP2::Frame::Data)
        tunnel_end.data.should be_empty
        tunnel_end.end_stream?.should be_true
        HTTP2::Frame::Data.new(
          HTTP2::Frame::Data::Flags::END_STREAM,
          request[:stream_id],
          "inbound"
        ).write(io)
        io.flush
      end

      connection = HTTP2::Connection.start(client_io)
      http = HTTP2::Client.new(
        "http://proxy.example",
        connection: connection
      )
      begin
        response = http.request(
          "CONNECT",
          "upstream.example:443",
          body: IO::Memory.new("outbound")
        )
        response.body.gets_to_end.should eq("inbound")
        wait_for_peer(peer_result)
      ensure
        http.close
      end
    end
  end

  it "keeps a successful CONNECT upload open after the peer half-closes" do
    UNIXSocket.pair do |client_io, peer|
      release_upload = Channel(Nil).new(1)
      settings = HTTP2::Frame::Settings.new([
        HTTP2::Frame::Settings::Setting.new(
          HTTP2::Frame::Settings::Identifier::INITIAL_WINDOW_SIZE,
          0_u32
        ),
      ])
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io, settings)
        request = client_read_field_section(io, HPack::Decoder.new)
        write_server_fields(
          io,
          HPack::Encoder.new,
          request[:stream_id],
          [{":status", "200"}]
        )
        HTTP2::Frame::Data.new(
          HTTP2::Frame::Data::Flags::END_STREAM,
          request[:stream_id],
          "inbound"
        ).write(io)
        io.flush

        release_upload.receive
        HTTP2::Frame::WindowUpdate.new(
          request[:stream_id],
          64_u32
        ).write(io)
        io.flush

        outbound = read_client_data(io)
        outbound.data.should eq("outbound".to_slice)
        outbound.end_stream?.should be_false
        ending = read_client_data(io)
        ending.data.should be_empty
        ending.end_stream?.should be_true
      end

      connection = HTTP2::Connection.start(client_io)
      http = HTTP2::Client.new(
        "http://proxy.example",
        connection: connection
      )
      begin
        response = http.request(
          "CONNECT",
          "upstream.example:443",
          body: IO::Memory.new("outbound")
        )
        response.body.gets_to_end.should eq("inbound")
        response.trailers.should be_empty
        release_upload.send(nil)
        wait_for_peer(peer_result)
      ensure
        http.close
      end
    end
  end

  it "rejects malformed requests before opening a connection" do
    http = HTTP2::Client.new("https://example.test")
    begin
      expect_raises(HTTP2::InvalidRequestError, /pseudo-fields/) do
        http.get("/", HTTP2::Headers{":path" => "/other"})
      end
      expect_raises(HTTP2::InvalidRequestError, /field name/) do
        http.get("/", HTTP2::Headers{"X-Upper" => "value"})
      end
      expect_raises(HTTP2::InvalidRequestError, /connection-specific/) do
        http.get("/", HTTP2::Headers{"connection" => "close"})
      end
      expect_raises(HTTP2::InvalidRequestError, /only contain/) do
        http.get("/", HTTP2::Headers{"te" => "gzip"})
      end
      expect_raises(HTTP2::InvalidRequestError, /URI-safe/) do
        http.get("/raw path")
      end
      expect_raises(HTTP2::InvalidRequestError, /host:port/) do
        http.request("CONNECT", "/not-authority")
      end
      expect_raises(HTTP2::InvalidRequestError, /content-length/) do
        http.request(
          "CONNECT",
          "upstream.example:443",
          HTTP2::Headers{"content-length" => "1"},
          IO::Memory.new("x")
        )
      end
      expect_raises(HTTP2::InvalidRequestError, /trailers/) do
        http.request(
          "CONNECT",
          "upstream.example:443",
          body: IO::Memory.new("x"),
          trailers: HTTP2::Headers{"checksum" => "ok"}
        )
      end
      expect_raises(HTTP2::InvalidRequestError, /client origin/) do
        http.get("https://other.test/")
      end
      expect_raises(HTTP2::InvalidRequestError, /invalid request target/) do
        http.get("ftp://example.test/")
      end
      expect_raises(HTTP2::InvalidRequestError, /does not match/) do
        http.post(
          "/",
          HTTP2::Headers{"content-length" => "3"},
          "body"
        )
      end
    ensure
      http.close
    end
  end

  it "resets a malformed response without closing the connection" do
    UNIXSocket.pair do |client_io, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        request = client_read_field_section(io, HPack::Decoder.new)
        encoded = Bytes[
          0x88,
          0x00, 0x05, 0x58, 0x2d, 0x42, 0x61, 0x64,
          0x01, 0x78,
        ]
        HTTP2::Frame::Headers.new(
          HTTP2::Frame::Headers::Flags::END_HEADERS,
          request[:stream_id],
          encoded
        ).write(io)
        io.flush

        reset = read_until_reset(io)
        reset.stream_id.should eq(request[:stream_id])
        reset.error_code.should eq(HTTP2::ErrorCode::PROTOCOL_ERROR.to_u32)
      end

      connection = HTTP2::Connection.start(client_io)
      http = HTTP2::Client.new(
        "http://example.test",
        connection: connection
      )
      begin
        expect_raises(HTTP2::MalformedResponseError, /field name/) do
          http.get("/")
        end
        connection.active?.should be_true
        wait_for_peer(peer_result)
      ensure
        http.close
      end
    end
  end

  it "enforces response content-length at END_STREAM" do
    UNIXSocket.pair do |client_io, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        request = client_read_field_section(io, HPack::Decoder.new)
        write_server_fields(
          io,
          HPack::Encoder.new,
          request[:stream_id],
          [{":status", "200"}, {"content-length", "5"}]
        )
        HTTP2::Frame::Data.new(
          HTTP2::Frame::Data::Flags::END_STREAM,
          request[:stream_id],
          "abc"
        ).write(io)
        io.flush
        read_until_reset(io).error_code.should eq(
          HTTP2::ErrorCode::PROTOCOL_ERROR.to_u32
        )
      end

      connection = HTTP2::Connection.start(client_io)
      http = HTTP2::Client.new(
        "http://example.test",
        connection: connection
      )
      begin
        response = http.get("/")
        expect_raises(HTTP2::MalformedResponseError, /does not match/) do
          response.body.gets_to_end
        end
        wait_for_peer(peer_result)
      ensure
        http.close
      end
    end
  end

  it "allows HEAD metadata content-length without response content" do
    UNIXSocket.pair do |client_io, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        request = client_read_field_section(io, HPack::Decoder.new)
        write_server_fields(
          io,
          HPack::Encoder.new,
          request[:stream_id],
          [{":status", "200"}, {"content-length", "123"}],
          end_stream: true
        )
      end

      connection = HTTP2::Connection.start(client_io)
      http = HTTP2::Client.new(
        "http://example.test",
        connection: connection
      )
      begin
        response = http.head("/")
        response.headers["content-length"].should eq("123")
        response.body.gets_to_end.should be_empty
        wait_for_peer(peer_result)
      ensure
        http.close
      end
    end
  end

  it "cancels a request waiting for response headers" do
    UNIXSocket.pair do |client_io, peer|
      request_seen = Channel(Nil).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        client_read_field_section(io, HPack::Decoder.new)
        request_seen.send(nil)
        reset = read_until_reset(io)
        reset.error_code.should eq(HTTP2::ErrorCode::CANCEL.to_u32)
      end

      connection = HTTP2::Connection.start(client_io)
      http = HTTP2::Client.new(
        "http://example.test",
        connection: connection
      )
      cancellation = HTTP2::Cancellation.new
      result = Channel(Exception?).new(1)
      spawn do
        begin
          http.get("/", cancellation: cancellation)
          result.send(nil)
        rescue error
          result.send(error)
        end
      end

      request_seen.receive
      cancellation.cancel
      result.receive.should be_a(HTTP2::RequestCanceledError)
      wait_for_peer(peer_result)
      http.close
    end
  end

  it "applies the response-header read timeout" do
    UNIXSocket.pair do |client_io, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        client_read_field_section(io, HPack::Decoder.new)
        read_until_reset(io).error_code.should eq(
          HTTP2::ErrorCode::CANCEL.to_u32
        )
      end

      connection = HTTP2::Connection.start(client_io)
      http = HTTP2::Client.new(
        "http://example.test",
        connection: connection,
        timeouts: HTTP2::Client::Timeouts.new(read: 20.milliseconds)
      )
      begin
        expect_raises(HTTP2::RequestTimeoutError, /response headers/) do
          http.get("/")
        end
        wait_for_peer(peer_result)
      ensure
        http.close
      end
    end
  end

  it "cancels a streaming response through its shared token" do
    UNIXSocket.pair do |client_io, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        request = client_read_field_section(io, HPack::Decoder.new)
        write_server_fields(
          io,
          HPack::Encoder.new,
          request[:stream_id],
          [{":status", "200"}]
        )
        read_until_reset(io).error_code.should eq(
          HTTP2::ErrorCode::CANCEL.to_u32
        )
      end

      connection = HTTP2::Connection.start(client_io)
      http = HTTP2::Client.new(
        "http://example.test",
        connection: connection
      )
      cancellation = HTTP2::Cancellation.new
      begin
        response = http.get("/", cancellation: cancellation)
        cancellation.cancel
        expect_raises(HTTP2::RequestCanceledError, /body read/) do
          response.body.read(Bytes.new(1))
        end
        wait_for_peer(peer_result)
      ensure
        http.close
      end
    end
  end

  it "times out an idle response body read and cancels its stream" do
    UNIXSocket.pair do |client_io, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        request = client_read_field_section(io, HPack::Decoder.new)
        write_server_fields(
          io,
          HPack::Encoder.new,
          request[:stream_id],
          [{":status", "200"}]
        )
        reset = read_until_reset(io)
        reset.error_code.should eq(HTTP2::ErrorCode::CANCEL.to_u32)
      end

      connection = HTTP2::Connection.start(client_io)
      http = HTTP2::Client.new(
        "http://example.test",
        connection: connection,
        timeouts: HTTP2::Client::Timeouts.new(idle: 20.milliseconds)
      )
      begin
        response = http.get("/")
        expect_raises(HTTP2::RequestTimeoutError, /body read/) do
          response.body.read(Bytes.new(1))
        end
        wait_for_peer(peer_result)
      ensure
        http.close
      end
    end
  end

  it "cancels an abandoned response's stream and returns its window credit within a bounded wait" do
    UNIXSocket.pair do |client_io, peer|
      payload = "unread payload"
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        request = client_read_field_section(io, HPack::Decoder.new)
        write_server_fields(
          io,
          HPack::Encoder.new,
          request[:stream_id],
          [{":status", "200"}]
        )
        HTTP2::Frame::Data.new(
          HTTP2::Frame::Data::Flags::None,
          request[:stream_id],
          payload
        ).write(io)
        io.flush

        reset, credit = read_reset_and_connection_credit(io)
        reset.stream_id.should eq(request[:stream_id])
        reset.error_code.should eq(HTTP2::ErrorCode::CANCEL.to_u32)
        credit.window_size_increment.should eq(payload.bytesize)
      end

      connection = HTTP2::Connection.start(client_io)
      http = HTTP2::Client.new(
        "http://example.test",
        connection: connection,
        timeouts: HTTP2::Client::Timeouts.new(idle: 60.milliseconds)
      )
      begin
        response = http.get("/")
        response.status.should eq(200)
        # Deliberately never read `response.body` and never close it —
        # this is the abandonment the idle deadline exists to recover.
        wait_for_peer(peer_result)
      ensure
        http.close
      end
    end
  end

  it "does not cancel a response whose reader keeps consuming within each idle period" do
    UNIXSocket.pair do |client_io, peer|
      payload = "abcdefghij"
      finish = Channel(Nil).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        request = client_read_field_section(io, HPack::Decoder.new)
        write_server_fields(
          io,
          HPack::Encoder.new,
          request[:stream_id],
          [{":status", "200"}]
        )
        HTTP2::Frame::Data.new(
          HTTP2::Frame::Data::Flags::None,
          request[:stream_id],
          payload
        ).write(io)
        io.flush

        finish.receive
        HTTP2::Frame::Data.new(
          HTTP2::Frame::Data::Flags::END_STREAM,
          request[:stream_id],
          Bytes.empty
        ).write(io)
        io.flush
      end

      connection = HTTP2::Connection.start(client_io)
      http = HTTP2::Client.new(
        "http://example.test",
        connection: connection,
        timeouts: HTTP2::Client::Timeouts.new(idle: 80.milliseconds)
      )
      begin
        response = http.get("/")
        response.status.should eq(200)

        buffer = Bytes.new(1)
        read = IO::Memory.new
        payload.bytesize.times do
          count = response.body.read(buffer)
          count.should eq(1)
          read.write(buffer[0, count])

          pause = Channel(Nil).new
          select
          when pause.receive
          when timeout(20.milliseconds)
          end
        end
        read.to_s.should eq(payload)

        # The reads above spanned ~200ms, more than two 80ms idle
        # periods, but each period saw at least one byte consumed — the
        # monitor must have re-armed every time instead of canceling.
        finish.send(nil)
        response.body.gets_to_end.should eq("")
        response.trailers.should be_empty
        wait_for_peer(peer_result)
      ensure
        http.close
      end
    end
  end

  it "keeps a supplied connection's quiet stream alive past the read timeout via keepalive" do
    UNIXSocket.pair do |client_io, peer|
      keepalive_interval = 100.milliseconds
      configuration = HTTP2::Connection::Configuration.new(
        keepalive_interval: keepalive_interval
      )
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        request = client_read_field_section(io, HPack::Decoder.new)
        write_server_fields(
          io,
          HPack::Encoder.new,
          request[:stream_id],
          [{":status", "200"}]
        )

        # Answer keepalive PINGs for ~3 intervals before completing the
        # response, well past the client's `read` timeout below. Each
        # iteration blocks on a real inbound frame (the client's next
        # PING), so this never sleeps.
        deadline = Time.instant + keepalive_interval * 3
        while Time.instant < deadline
          frame = HTTP2::Frame.read(io)
          if frame.is_a?(HTTP2::Frame::Ping) && !frame.ack?
            frame.ack.write(io)
            io.flush
          end
        end

        HTTP2::Frame::Data.new(
          HTTP2::Frame::Data::Flags::END_STREAM,
          request[:stream_id],
          "done"
        ).write(io)
        io.flush
      end

      connection = HTTP2::Connection.start(client_io, configuration)
      http = HTTP2::Client.new(
        "http://example.test",
        connection: connection,
        timeouts: HTTP2::Client::Timeouts.new(
          read: 200.milliseconds,
          idle: nil
        )
      )
      begin
        response = http.get("/")
        response.body.gets_to_end.should eq("done")
        wait_for_peer(peer_result)
      ensure
        http.close
      end
    end
  end

  it "keeps a dialed connection's quiet stream alive past the read timeout" do
    server = TCPServer.new("127.0.0.1", 0)
    peer_result = scripted_peer(server) do |listener_io|
      socket = listener_io.as(TCPServer).accept
      begin
        complete_server_handshake(socket)
        request = client_read_field_section(socket, HPack::Decoder.new)
        write_server_fields(
          socket,
          HPack::Encoder.new,
          request[:stream_id],
          [{":status", "200"}]
        )

        # Idle for 2x the client's read timeout with no DATA in flight.
        # Under the old persistent socket read timeout this silence alone
        # killed the connection. No PING is expected here: the client
        # uses its default 30s keepalive interval, far longer than this
        # wait, so this spec proves the dial path survives quiescence on
        # its own, without keepalive traffic to lean on.
        idle = Channel(Nil).new
        select
        when idle.receive
        when timeout(300.milliseconds)
        end

        HTTP2::Frame::Data.new(
          HTTP2::Frame::Data::Flags::END_STREAM,
          request[:stream_id],
          "done"
        ).write(socket)
        socket.flush
      ensure
        socket.close
      end
    end

    http = HTTP2::Client.new(
      "http://127.0.0.1:#{server.local_address.port}",
      timeouts: HTTP2::Client::Timeouts.new(
        connect: 1.second,
        read: 150.milliseconds,
        write: 1.second
      )
    )
    begin
      response = http.get("/")
      response.body.gets_to_end.should eq("done")
      wait_for_peer(peer_result)
    ensure
      http.close
      server.close
    end
  end

  it "stops a flow-blocked upload after an early complete response" do
    UNIXSocket.pair do |client_io, peer|
      settings = HTTP2::Frame::Settings.new([
        HTTP2::Frame::Settings::Setting.new(
          HTTP2::Frame::Settings::Identifier::INITIAL_WINDOW_SIZE,
          0_u32
        ),
      ])
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io, settings)
        request = client_read_field_section(io, HPack::Decoder.new)
        request[:end_stream].should be_false
        field_pairs(request[:fields]).should contain(
          {"content-length", "7"}
        )
        write_server_fields(
          io,
          HPack::Encoder.new,
          request[:stream_id],
          [{":status", "413"}, {"content-length", "8"}]
        )
        HTTP2::Frame::Data.new(
          HTTP2::Frame::Data::Flags::END_STREAM,
          request[:stream_id],
          "rejected"
        ).write(io)
        io.flush
        read_until_reset(io).error_code.should eq(
          HTTP2::ErrorCode::CANCEL.to_u32
        )
      end

      connection = HTTP2::Connection.start(client_io)
      http = HTTP2::Client.new(
        "http://example.test",
        connection: connection
      )
      begin
        response = http.post("/", body: "blocked")
        response.status.should eq(413)
        response.body.gets_to_end.should eq("rejected")
        wait_for_peer(peer_result)
      ensure
        http.close
      end
    end
  end

  it "resets a streamed request whose content-length is wrong" do
    UNIXSocket.pair do |client_io, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        client_read_field_section(io, HPack::Decoder.new)
        read_until_reset(io).error_code.should eq(
          HTTP2::ErrorCode::CANCEL.to_u32
        )
      end

      connection = HTTP2::Connection.start(client_io)
      http = HTTP2::Client.new(
        "http://example.test",
        connection: connection
      )
      begin
        expect_raises(HTTP2::InvalidRequestError, /streamed request/) do
          http.post(
            "/",
            HTTP2::Headers{"content-length" => "5"},
            IO::Memory.new("abc")
          )
        end
        wait_for_peer(peer_result)
      ensure
        http.close
      end
    end
  end

  it "validates timeout configuration" do
    expect_raises(ArgumentError, /connect timeout/) do
      HTTP2::Client::Timeouts.new(connect: Time::Span.zero)
    end
    expect_raises(ArgumentError, /stream_slot timeout/) do
      HTTP2::Client::Timeouts.new(stream_slot: Time::Span.zero)
    end
    HTTP2::Client::Timeouts.new(
      connect: nil,
      read: nil,
      write: nil,
      idle: nil
    ).idle.should be_nil
    HTTP2::Client::Timeouts.new.stream_slot.should be_nil
    HTTP2::Client::Timeouts.new(
      stream_slot: 1.second
    ).stream_slot.should eq(1.second)
  end

  it "enables keepalive by default in the connection configuration" do
    http = HTTP2::Client.new("http://example.test")
    begin
      http.connection_configuration.keepalive_interval.should eq(30.seconds)
    ensure
      http.close
    end
  end

  it "uses a caller-supplied connection configuration verbatim" do
    configuration = HTTP2::Connection::Configuration.new
    http = HTTP2::Client.new(
      "http://example.test",
      connection_configuration: configuration
    )
    begin
      http.connection_configuration.should be(configuration)
      http.connection_configuration.keepalive_interval.should be_nil
    ensure
      http.close
    end
  end

  it "rejects origins with invalid ports" do
    expect_raises(ArgumentError, /invalid port/) do
      HTTP2::Client.new("https://example.test:0")
    end
    expect_raises(ArgumentError, /invalid port/) do
      HTTP2::Client.new("https://example.test:65536")
    end
  end
end
