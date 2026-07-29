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

# Test-only: the retired pool has no public mutator, and there is
# no deterministic (sleep-free, non-networked-race) way to get a SECOND
# entry into it through the public API alone -- that requires a real
# peer GOAWAY racing a redial. Reopening the class to add a single
# helper keeps this out of `src/client.cr`'s production surface; see
# "applies one shared deadline across every connection" below for the
# one spec that uses it.
class HTTP2::Client
  # :nodoc:
  def test_only_retired_connections=(connections : Array(Connection)) : Nil
    entries = connections.map do |connection|
      entry = new_pool_entry(connection)
      entry.retired = true
      entry
    end
    @mutex.synchronize { @pool_retired_entries = entries }
  end
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

  it "applies one shared deadline across every connection instead of " \
     "one full timeout per connection" do
    UNIXSocket.pair do |client_a, peer_a|
      UNIXSocket.pair do |client_b, peer_b|
        stream_id_a = Channel(UInt32).new(1)
        stream_id_b = Channel(UInt32).new(1)
        peer_result_a = scripted_peer(peer_a) do |io|
          complete_server_handshake(io)
          id = stream_id_a.receive
          read_client_headers(io, id)
          HTTP2::Frame.read(io).should be_a(HTTP2::Frame::GoAway)
          io.read(Bytes.new(1)).should eq(0)
        end
        peer_result_b = scripted_peer(peer_b) do |io|
          complete_server_handshake(io)
          id = stream_id_b.receive
          read_client_headers(io, id)
          HTTP2::Frame.read(io).should be_a(HTTP2::Frame::GoAway)
          io.read(Bytes.new(1)).should eq(0)
        end

        # Two connections, each with one active stream that never
        # finishes, so each genuinely consumes its ENTIRE per-connection
        # drain budget rather than resolving instantly.
        connection_a = HTTP2::Connection.start(client_a)
        connection_a.wait_until_active(1.second)
        stream_a = connection_a.new_stream
        open_client_stream(stream_a)
        stream_id_a.send(stream_a.id)

        connection_b = HTTP2::Connection.start(client_b)
        connection_b.wait_until_active(1.second)
        stream_b = connection_b.new_stream
        open_client_stream(stream_b)
        stream_id_b.send(stream_b.id)

        http = HTTP2::Client.new(
          "http://example.test",
          connection: connection_a
        )
        # See `test_only_retired_connections=` above for why this test
        # helper exists instead of driving a real retire-then-redial.
        http.test_only_retired_connections = [connection_b] of HTTP2::Connection

        timeout = 300.milliseconds
        started = Time.instant
        expect_raises(HTTP2::Connection::DrainTimeoutError) do
          http.graceful_close(timeout)
        end
        elapsed = Time.instant - started

        # Sequential per-connection timeouts would take close to 2x
        # timeout (~600ms); a single shared deadline keeps the total
        # close to 1x timeout (~300ms). Generous margin, no sleeps.
        elapsed.should be < 500.milliseconds
        http.closed?.should be_true
        wait_for_peer(peer_result_a)
        wait_for_peer(peer_result_b)
      end
    end
  end

  it "does not hang graceful_close on a connection with an open, " \
     "still-streaming response" do
    UNIXSocket.pair do |client_io, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        request = client_read_field_section(io, HPack::Decoder.new)
        # Headers only, no end_stream: the response stays open, exactly
        # like an SSE/long-poll stream the caller hasn't read yet.
        write_server_fields(
          io,
          HPack::Encoder.new,
          request[:stream_id],
          [{":status", "200"}]
        )
        io.flush
        HTTP2::Frame.read(io).should be_a(HTTP2::Frame::GoAway)
        io.read(Bytes.new(1)).should eq(0)
      end

      connection = HTTP2::Connection.start(client_io)
      http = HTTP2::Client.new(
        "http://example.test",
        connection: connection
      )
      begin
        response = http.get("/")
        response.status.should eq(200)

        started = Time.instant
        expect_raises(HTTP2::Connection::DrainTimeoutError) do
          http.graceful_close(300.milliseconds)
        end
        elapsed = Time.instant - started

        # A background monitor fiber is still parked on this exact
        # stream, waiting for trailers/remote-end, when the connection
        # is torn down by the drain deadline -- this must resolve
        # promptly, not hang the process (see client.cr's
        # `#monitor_response` doc comment on the shared
        # `Connection::TimeoutError` rescue).
        elapsed.should be < 1.second

        # Symmetric with the keepalive-timeout spec below: the response
        # itself surfaces the connection's own DrainTimeoutError too,
        # not just graceful_close's caller.
        expect_raises(HTTP2::Connection::DrainTimeoutError) do
          response.trailers
        end

        wait_for_peer(peer_result)
      ensure
        http.close
      end
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

  it "keeps an additional_never_indexed_fields name literal-never-indexed and out of the peer's table, without disturbing an unrelated repeated field" do
    # Task 9 review, Finding 2: before this option existed, a caller's own
    # custom credential header (e.g. `x-api-key`) had no way to opt out of
    # HPACK incremental indexing -- it landed in the connection's dynamic
    # table exactly like any other repeated header. `x-session` here is
    # the positive control proving the opt-out is narrow: it is NOT in
    # `additional_never_indexed_fields`, so it must still compress to an
    # indexed reference on the second request, same as every ordinary
    # field.
    UNIXSocket.pair do |client_io, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        decoder = HPack::Decoder.new

        first = client_read_field_section(io, decoder)
        first[:fields].find! { |field| field.name == "x-api-key" }
          .tap do |field|
            field.value.should eq("sk_live_secret")
            field.indexing.should eq(HPack::Indexing::NEVER)
          end
        decoder.table.includes?({"x-api-key", "sk_live_secret"})
          .should be_false
        write_server_fields(
          io, HPack::Encoder.new, first[:stream_id],
          [{":status", "204"}], end_stream: true
        )

        second = client_read_field_section(io, decoder)
        second[:fields].find! { |field| field.name == "x-api-key" }
          .tap do |field|
            field.value.should eq("sk_live_secret")
            # Still literal-never-indexed on the repeat -- the opt-out held.
            field.indexing.should eq(HPack::Indexing::NEVER)
          end
        second[:fields].find! { |field| field.name == "x-session" }
          .tap do |field|
            field.value.should eq("abc123")
            # The un-opted-out field still compresses -- proves the
            # opt-out is additive, not a global change of behavior.
            field.indexing.should eq(HPack::Indexing::INDEXED)
          end
        decoder.table.includes?({"x-api-key", "sk_live_secret"})
          .should be_false
        write_server_fields(
          io, HPack::Encoder.new, second[:stream_id],
          [{":status", "204"}], end_stream: true
        )
      end

      connection = HTTP2::Connection.start(client_io)
      http = HTTP2::Client.new(
        "http://example.test",
        connection: connection,
        timeouts: HTTP2::Client::Timeouts.new(read: 2.seconds),
        additional_never_indexed_fields: ["x-api-key"]
      )
      begin
        headers = HTTP2::Headers{
          "x-api-key" => "sk_live_secret",
          "x-session" => "abc123",
        }
        http.get("/one", headers).status.should eq(204)
        http.get("/two", headers).status.should eq(204)
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

  # Regression coverage for the narrowed `opening_mutex` (see
  # `Client#open_request_stream`): each request's stream ID is assigned
  # under that mutex, but the blocking wait for its HEADERS write to reach
  # the transport happens after the mutex is released, so several
  # requests' materialize-and-enqueue steps can now interleave with each
  # other's writer-flush waits. Unlike "reuses one origin connection for
  # concurrent requests" above (which only checks the *set* of stream IDs
  # used), this asserts the field sections arrive at the peer in strict
  # stream-ID order — the invariant that makes narrowing the mutex safe.
  #
  # This spec has no detection power under the default single-threaded
  # runtime: mutation testing that deleted `opening_mutex` entirely still
  # left it green there, because nothing forces a fiber switch between
  # `materialize_request_stream` and its own enqueue without a second OS
  # thread actually running the other fiber concurrently. `crystal spec
  # -Dpreview_mt` is the gate that actually exercises the race this spec
  # checks; the single-threaded run only confirms the happy path still
  # works. A `stream_slot` timeout is configured below so a request that
  # loses a pool-slot TOCTOU race (a pre-existing, unrelated ~2% flake
  # under `-Dpreview_mt` — see client.cr's `acquire_request_slot`) retries
  # instead of raising `PoolSaturatedError`.
  it "sends concurrent HEADERS on one connection in stream-ID order" do
    request_count = 8
    UNIXSocket.pair do |client_io, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        decoder = HPack::Decoder.new
        arrival_order = Array.new(request_count) do
          client_read_field_section(io, decoder)[:stream_id]
        end
        arrival_order.should eq(
          Array.new(request_count) { |index| (index * 2 + 1).to_u32 }
        )

        encoder = HPack::Encoder.new
        arrival_order.each do |id|
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
        connection: connection,
        timeouts: HTTP2::Client::Timeouts.new(stream_slot: 1.second)
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
        request_count.times do
          result = select
          when value = responses.receive
            value
          when timeout(2.seconds)
            fail("concurrent HTTP/2 requests did not complete")
          end
          raise result if result.is_a?(Exception)
        end
        wait_for_peer(peer_result)
      ensure
        http.close
      end
    end
  end

  it "raises pool saturation immediately without a configured stream_slot wait" do
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
        expect_raises(HTTP2::Client::PoolSaturatedError) do
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

  # Pool admission no longer allocates an idle stream before capacity is
  # available. A raw opener can therefore use the next stream ID without
  # skipping a pooled request that is waiting for capacity.
  {% unless flag?(:preview_mt) %}
    it "does not preallocate a stream while waiting for pool capacity" do
      UNIXSocket.pair do |client_io, peer|
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

          occupying_request = client_read_field_section(io, decoder)
          read_until_reset(io).stream_id.should eq(
            occupying_request[:stream_id]
          )

          # The raw competitor owns stream 3. The pooled request only
          # allocates stream 5 after the competitor completes.
          winner_request = client_read_field_section(io, decoder)
          write_server_fields(
            io,
            encoder,
            winner_request[:stream_id],
            [{":status", "200"}],
            end_stream: true
          )

          second_request = client_read_field_section(io, decoder)
          write_server_fields(
            io,
            encoder,
            second_request[:stream_id],
            [{":status", "200"}],
            end_stream: true
          )
        end

        connection = HTTP2::Connection.start(client_io)
        connection.wait_until_active(1.second)

        occupying = connection.new_stream
        open_client_stream(occupying, end_stream: true)

        http = HTTP2::Client.new(
          "http://example.test",
          connection: connection,
          timeouts: HTTP2::Client::Timeouts.new(stream_slot: 2.seconds)
        )
        begin
          second_result = Channel(HTTP2::Response | Exception).new(1)
          spawn do
            begin
              second_result.send(http.get("/second"))
            rescue error
              second_result.send(error)
            end
          end

          Fiber.yield
          connection.stream?(3_u32).should be_nil
          competitor = connection.new_stream
          competitor.id.should eq(3_u32)
          occupying.cancel
          competitor.send_headers([] of HTTP2::HeaderField, end_stream: true)

          result = select
          when value = second_result.receive
            value
          when timeout(3.seconds)
            fail("\"/second\" did not complete")
          end
          raise result if result.is_a?(Exception)
          result.status.should eq(200)
          wait_for_peer(peer_result)
        ensure
          http.close
        end
      end
    end
  {% end %}

  it "does not retry a stream_slot wait into a connection the peer is draining" do
    UNIXSocket.pair do |client_io, peer|
      peer_result = scripted_peer(peer) do |io|
        settings = HTTP2::Frame::Settings.new([
          HTTP2::Frame::Settings::Setting.new(
            HTTP2::Frame::Settings::Identifier::MAX_CONCURRENT_STREAMS,
            1_u32
          ),
        ])
        complete_server_handshake(io, settings)
        read_client_headers(io) # the occupying stream's request

        # "/second" is waiting for pool capacity without allocating a
        # stream. GOAWAY makes the supplied connection permanently
        # ineligible, so the waiter must fail promptly instead of spinning
        # or waiting out its full stream-slot deadline.
        HTTP2::Frame::GoAway.new(0_u32, HTTP2::ErrorCode::NO_ERROR).write(io)
        io.flush
      end

      connection = HTTP2::Connection.start(client_io)
      connection.wait_until_active(1.second)

      occupying = connection.new_stream
      open_client_stream(occupying, end_stream: true)

      http = HTTP2::Client.new(
        "http://example.test",
        connection: connection,
        timeouts: HTTP2::Client::Timeouts.new(stream_slot: 2.seconds)
      )
      begin
        result = Channel(Exception?).new(1)
        spawn do
          begin
            http.get("/second")
            result.send(nil)
          rescue error
            result.send(error)
          end
        end

        outcome = select
        when value = result.receive
          value
        when timeout(1.second)
          fail("\"/second\" did not fail promptly after the peer GOAWAY")
        end
        outcome.should_not be_nil
        wait_for_peer(peer_result)
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

  it "reconnects before consuming a caller-owned request body" do
    server = TCPServer.new("127.0.0.1", 0)
    peer_result = scripted_peer(server) do |listener|
      first = listener.as(TCPServer).accept
      begin
        # Let the first dial finish and publish its Connection, then close
        # without sending peer SETTINGS. The request has not reserved a
        # stream, so selecting a replacement is always safe.
        read_client_preface(first)
      ensure
        first.close
      end

      second = listener.as(TCPServer).accept
      begin
        complete_server_handshake(second)
        request = client_read_field_section(second, HPack::Decoder.new)
        field_pairs(request[:fields]).should contain({":method", "POST"})
        request[:end_stream].should be_false

        body = IO::Memory.new
        ended = false
        until ended
          data = HTTP2::Frame.read(second).as(HTTP2::Frame::Data)
          data.stream_id.should eq(request[:stream_id])
          body.write(data.data)
          ended = data.end_stream?
        end
        body.to_s.should eq("one-shot")

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
      timeouts: HTTP2::Client::Timeouts.new(
        connect: 1.second,
        read: 1.second,
        write: 1.second
      )
    )
    begin
      body = IO::Memory.new("one-shot")
      http.post("/after-reconnect", body: body).status.should eq(204)
      body.pos.should eq(body.size)
      wait_for_peer(peer_result)
    ensure
      http.close
      server.close
    end
  end

  it "raises Client::ClosedError for a request made after #close" do
    http = HTTP2::Client.new("http://example.test")
    http.close
    expect_raises(HTTP2::Client::ClosedError) do
      http.get("/")
    end
  end

  it "dials outside its mutex, so #closed? is not blocked behind an " \
     "in-progress connect+TLS handshake" do
    server = TCPServer.new("127.0.0.1", 0)
    accepted = Channel(Nil).new(1)
    release = Channel(Nil).new(1)
    peer_result = scripted_peer(server) do |listener|
      socket = listener.as(TCPServer).accept
      begin
        # Completes the bare TCP handshake but never writes a single TLS
        # byte back, so the client's OpenSSL handshake attempt inside
        # `dial` stays blocked reading for a ServerHello that never
        # arrives, for exactly as long as this test needs it to.
        accepted.send(nil)
        select
        when release.receive
        when timeout(2.seconds)
        end
      ensure
        socket.close
      end
    end

    http = HTTP2::Client.new(
      "https://127.0.0.1:#{server.local_address.port}",
      timeouts: HTTP2::Client::Timeouts.new(
        connect: 2.seconds,
        read: 2.seconds,
        write: 2.seconds
      )
    )
    begin
      # Joined at the end (`dial_done`) rather than left to run
      # unobserved: an abandoned fiber still unwinding a TLS/socket
      # error at the exact moment the process exits is a known
      # `-Dpreview_mt` shutdown hazard unrelated to anything under test
      # here, and joining it avoids relying on that timing at all.
      dial_done = Channel(Nil).new(1)
      spawn do
        http.get("/") rescue nil
      ensure
        dial_done.send(nil)
      end
      accepted.receive

      result = Channel(Bool).new(1)
      spawn { result.send(http.closed?) }
      outcome = select
      when value = result.receive
        value
      when timeout(100.milliseconds)
        fail(
          "closed? did not return within 100ms while a dial was pending"
        )
      end
      outcome.should be_false

      release.send(nil)
      wait_for_peer(peer_result)

      select
      when dial_done.receive
      when timeout(2.seconds)
        fail("background dial fiber never settled")
      end
    ensure
      http.close
      server.close
    end
  end

  it "shares one dial across concurrent cold requests" do
    server = TCPServer.new("127.0.0.1", 0)
    concurrency = 8
    counts_mutex = Mutex.new
    accepted = 0
    closed = 0

    # Accept until the listener closes so an unexpected redundant dial is
    # observed rather than rejected by a one-shot accept script.
    peer_result = scripted_peer(server) do |listener|
      loop do
        socket = begin
          listener.as(TCPServer).accept
        rescue
          break
        end
        counts_mutex.synchronize { accepted += 1 }
        spawn do
          begin
            complete_server_handshake(socket)
            decoder = HPack::Decoder.new
            encoder = HPack::Encoder.new
            loop do
              request = client_read_field_section(socket, decoder)
              write_server_fields(
                socket,
                encoder,
                request[:stream_id],
                [{":status", "204"}],
                end_stream: true
              )
            end
          rescue
            # The surviving connection reaches this when the client closes.
          ensure
            counts_mutex.synchronize { closed += 1 }
          end
        end
      end
    end

    http = HTTP2::Client.new(
      "http://127.0.0.1:#{server.local_address.port}",
      timeouts: HTTP2::Client::Timeouts.new(
        connect: 2.seconds,
        read: 2.seconds,
        write: 2.seconds
      )
    )
    begin
      results = Channel(Exception?).new(concurrency)
      concurrency.times do |i|
        spawn do
          http.get("/#{i}").status.should eq(204)
          results.send(nil)
        rescue error
          results.send(error)
        end
      end
      concurrency.times do
        error = results.receive
        raise error if error
      end

      # Every request has completed and only a request can initiate a dial.
      # Settle the server-side accept bookkeeping before asserting the exact
      # single-flight invariant.
      previous = {-1, -1}
      settled = {0, 0}
      eventually(message: "accept/close counts never settled") do
        current = counts_mutex.synchronize { {accepted, closed} }
        is_settled = current[0] > 0 && current == previous
        previous = current
        settled = current if is_settled
        is_settled
      end
      observed_accepted, observed_closed = settled
      observed_accepted.should eq(1)
      observed_closed.should eq(0)

      http.close
      eventually(message: "the surviving connection never closed") do
        counts_mutex.synchronize { closed } == 1
      end
      server.close
      wait_for_peer(peer_result)
    ensure
      http.close
      server.close unless server.closed?
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

  it "starts CONNECT tunnel data only after a successful response, " \
     "for an owned body" do
    # Review fix-round regression coverage: `#start_connect_upload`'s
    # gate used to be `request.connect && request.body` alone, which
    # worked before this task only because an owned body always
    # populated `request.body` too (an eagerly-built `IO::Memory`). Once
    # an owned body stopped doing that (see `Request#owned_body`, the
    # upload fast path), that gate would have silently skipped the
    # tunnel upload entirely for a String/Bytes CONNECT body -- a defect
    # this task's own redesign would have introduced, fixed in the same
    # commit by also checking `request.owned_body`. This is the same
    # scenario as "starts CONNECT tunnel data only after a successful
    # response" above with `IO::Memory.new("outbound")` swapped for the
    # owned String `"outbound"` -- the one line that exercises the fix.
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
        # An owned body's upload fast path (`#stream_owned_body`) has no
        # trailers to wait on for a CONNECT tunnel, so it folds
        # END_STREAM into the single data frame instead of the
        # IO-streamed path's separate trailing empty frame above.
        tunnel_data = HTTP2::Frame.read(io).as(HTTP2::Frame::Data)
        tunnel_data.data.should eq("outbound".to_slice)
        tunnel_data.end_stream?.should be_true
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
          body: "outbound"
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
      # Task 9 review, Finding 1 fix round: this native-Headers-API
      # uppercase rejection above is unrelated to the never-index
      # boundary fix (`to_header_fields` alone now closes that, by
      # downcasing defensively before comparing -- see
      # spec/request_spec.cr) and was deliberately preserved rather than
      # reverted, so it stays pinned here unchanged. This second case is
      # a genuine addition, not a substitute: it exercises a byte
      # `field_name_error` rejects for a reason other than casing, so
      # that part of the "malformed field name" path stays covered too.
      expect_raises(HTTP2::InvalidRequestError, /field name/) do
        http.get("/", HTTP2::Headers{"bad field" => "value"})
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
      # Review fix-round regression: a genuinely bodyless request can
      # only ever send zero bytes, so an explicit non-zero
      # `content-length` on one is already a provable lie -- caught here,
      # before any connection work, exactly like a mismatched owned-body
      # `content-length` above. `request.body_length` reporting `nil`
      # instead of `0_i64` for a nil body (so it stops colliding with a
      # genuine empty owned body's length) must not also silently drop
      # this check.
      expect_raises(HTTP2::InvalidRequestError, /does not match/) do
        http.get("/", HTTP2::Headers{"content-length" => "5"})
      end
    ensure
      http.close
    end
  end

  it "accepts an explicit content-length: 0 on a bodyless request" do
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
          {"content-length", "0"},
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
        response = http.get("/", HTTP2::Headers{"content-length" => "0"})
        response.status.should eq(204)
        wait_for_peer(peer_result)
      ensure
        http.close
      end
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

        # A later read must RAISE, not return a silent EOF — this is a
        # library-initiated reclamation, distinguishable from the
        # caller's own `Response#close` (which also makes a later read
        # raise, but a generic `IO::Error` ("Closed stream") rather than
        # this stream's own terminal error) by exception type, not by
        # whether reading raises at all.
        expect_raises(HTTP2::RequestTimeoutError, /abandoned/) do
          response.body.read(Bytes.new(1))
        end
      ensure
        http.close
      end
    end
  end

  it "does not cancel a response with an empty buffer merely for going quiet (SSE / long-poll / a quiet CONNECT tunnel)" do
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

        # Send nothing at all across several idle periods, exactly like
        # an SSE/long-poll response waiting between events, or a
        # successful CONNECT tunnel sitting quiet while the app
        # uploads. The buffer stays empty throughout, so nothing is
        # pinning connection-window credit.
        quiet = Channel(Nil).new
        select
        when quiet.receive
        when timeout(200.milliseconds)
        end

        HTTP2::Frame::Data.new(
          HTTP2::Frame::Data::Flags::END_STREAM,
          request[:stream_id],
          "done"
        ).write(io)
        io.flush
      end

      connection = HTTP2::Connection.start(client_io)
      http = HTTP2::Client.new(
        "http://example.test",
        connection: connection,
        timeouts: HTTP2::Client::Timeouts.new(idle: 50.milliseconds)
      )
      begin
        response = http.get("/")
        response.status.should eq(200)
        # Nobody reads response.body during the quiet window, matching a
        # real SSE/long-poll consumer between events (deliberately not
        # calling #read here — doing so would hit the OTHER, per-read
        # idle timeout instead of exercising the abandonment monitor).
        wait_for_peer(peer_result)

        # 200ms of peer silence against a 50ms idle spans four full
        # idle windows with nothing ever buffered. If Finding 1's fix
        # regressed (cancels regardless of buffered_bytes), the stream
        # would already be terminal here and this read would raise
        # instead of returning the peer's eventual data.
        response.body.gets_to_end.should eq("done")
        response.trailers.should be_empty
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

  it "does not abort an actively-read body when trailers is awaited early" do
    UNIXSocket.pair do |client_io, peer|
      chunk_count = 5
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        request = client_read_field_section(io, HPack::Decoder.new)
        write_server_fields(
          io,
          HPack::Encoder.new,
          request[:stream_id],
          [{":status", "200"}]
        )
        io.flush

        chunk_count.times do |i|
          last = i == chunk_count - 1
          flags = last ? HTTP2::Frame::Data::Flags::END_STREAM : HTTP2::Frame::Data::Flags::None
          HTTP2::Frame::Data.new(flags, request[:stream_id], "x").write(io)
          io.flush

          unless last
            pause = Channel(Nil).new
            select
            when pause.receive
            when timeout(100.milliseconds)
            end
          end
        end
      end

      connection = HTTP2::Connection.start(client_io)
      http = HTTP2::Client.new(
        "http://example.test",
        connection: connection,
        timeouts: HTTP2::Client::Timeouts.new(idle: 200.milliseconds)
      )
      begin
        response = http.get("/")
        response.status.should eq(200)

        # A fiber awaits trailers before the first body chunk lands. The
        # response streams for ~400ms (five 100ms-spaced chunks) against
        # a 200ms idle timeout -- if `#trailers` does not re-arm on body
        # progress the same way `#monitor_response` does, it aborts the
        # request around the 200ms mark even though the main fiber below
        # is actively (if slowly) draining the body the whole time.
        trailers_headers = Channel(HTTP2::Headers).new(1)
        trailers_error = Channel(Exception).new(1)
        spawn do
          begin
            trailers_headers.send(response.trailers)
          rescue error
            trailers_error.send(error)
          end
        end
        Fiber.yield

        buffer = Bytes.new(1)
        read = IO::Memory.new
        chunk_count.times do
          count = response.body.read(buffer)
          count.should eq(1)
          read.write(buffer[0, count])
        end
        read.to_s.should eq("x" * chunk_count)

        select
        when headers = trailers_headers.receive
          headers.should be_empty
        when error = trailers_error.receive
          fail(
            "response.trailers raised #{error.class}: #{error.message} " \
            "while the body was still being actively consumed"
          )
        when timeout(2.seconds)
          fail("response.trailers never returned")
        end

        wait_for_peer(peer_result)
      ensure
        http.close
      end
    end
  end

  # `Connection::KeepaliveTimeoutError` and `Connection::DrainTimeoutError`
  # (see the graceful_close spec above) share one ancestor,
  # `Connection::TimeoutError`, and so share the exact same rescue branch
  # in `#monitor_response` -- this pins the OTHER subclass reaching that
  # branch behaves the same way (fails the response promptly with the
  # connection's own terminal error) rather than assuming coverage of one
  # implies the other.
  it "fails an open response with the connection's own " \
     "KeepaliveTimeoutError, instead of hanging, when a keepalive PING " \
     "goes unanswered" do
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
        io.flush
        HTTP2::Frame.read(io).should be_a(HTTP2::Frame::Ping)
        io.read(Bytes.new(1)).should eq(0)
      end

      configuration = HTTP2::Connection::Configuration.new(
        keepalive_interval: 20.milliseconds,
        keepalive_timeout: 20.milliseconds
      )
      connection = HTTP2::Connection.start(client_io, configuration)
      http = HTTP2::Client.new(
        "http://example.test",
        connection: connection
      )
      begin
        response = http.get("/")
        response.status.should eq(200)

        expect_raises(HTTP2::Connection::KeepaliveTimeoutError) do
          response.trailers(2.seconds)
        end
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

        # The response already completed successfully; the upload is
        # merely moot, not cancelled, so the early-stop reset must carry
        # NO_ERROR rather than CANCEL.
        read_until_reset(io).error_code.should eq(
          HTTP2::ErrorCode::NO_ERROR.to_u32
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

  it "resets a streamed request whose IO body exceeds its " \
     "content-length" do
    UNIXSocket.pair do |client_io, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        client_read_field_section(io, HPack::Decoder.new)

        # The declared 3 bytes go out before the overrun is even
        # detected (the probe runs only after `sent == body_length`),
        # but critically WITHOUT END_STREAM — the whole point of
        # dropping the in-loop "attach END_STREAM to the final chunk"
        # optimization was to keep END_STREAM off the wire until the
        # probe confirms there is nothing left. `read_until_reset`
        # alone (used below) discards frames without inspecting them,
        # so it cannot tell an end_stream-carrying DATA frame from any
        # other frame; assert this one directly instead.
        data = HTTP2::Frame.read(io).as(HTTP2::Frame::Data)
        data.data.should eq("abc".to_slice)
        data.end_stream?.should be_false

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
        expect_raises(
          HTTP2::InvalidRequestError,
          /exceeds declared content-length/
        ) do
          http.post(
            "/",
            HTTP2::Headers{"content-length" => "3"},
            IO::Memory.new("abcd")
          )
        end
        wait_for_peer(peer_result)
      ensure
        http.close
      end
    end
  end

  it "sends a correctly-sized IO body as one content frame then a " \
     "separate empty END_STREAM frame" do
    UNIXSocket.pair do |client_io, peer|
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        request = client_read_field_section(io, HPack::Decoder.new)
        request[:end_stream].should be_false

        content = HTTP2::Frame.read(io).as(HTTP2::Frame::Data)
        content.data.should eq("abc".to_slice)
        content.end_stream?.should be_false

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
      begin
        response = http.post(
          "/",
          HTTP2::Headers{"content-length" => "3"},
          IO::Memory.new("abc")
        )
        response.status.should eq(204)
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
