require "../spec_helper"

private NGHTTP2_INTEROP_ENABLED = ENV["NGHTTP2_INTEROP"]? == "1"
private NGHTTP2_HOST            = "127.0.0.1"
private NGHTTP2_CLEARTEXT_PORT  =
  (ENV["NGHTTP2_CLEARTEXT_PORT"]? || "0").to_i
private NGHTTP2_TLS_PORT    = (ENV["NGHTTP2_TLS_PORT"]? || "0").to_i
private NGHTTP2_CERTIFICATE = ENV["NGHTTP2_CERTIFICATE"]? || ""

private def interop_timeouts : HTTP2::Client::Timeouts
  HTTP2::Client::Timeouts.new(
    connect: 3.seconds,
    read: 5.seconds,
    write: 5.seconds,
    idle: 5.seconds
  )
end

private def interop_configuration(
  *,
  diagnostic_queue_capacity : Int32 = 128,
) : HTTP2::Connection::Configuration
  HTTP2::Connection::Configuration.new(
    max_buffered_body_bytes: 8_192,
    outbound_data_chunk_size: 4_096,
    drain_timeout: 3.seconds,
    diagnostic_queue_capacity: diagnostic_queue_capacity
  )
end

private def cleartext_origin : String
  "http://#{NGHTTP2_HOST}:#{NGHTTP2_CLEARTEXT_PORT}"
end

private def tls_origin : String
  "https://localhost:#{NGHTTP2_TLS_PORT}"
end

private def interop_tls_context : OpenSSL::SSL::Context::Client
  context = OpenSSL::SSL::Context::Client.new
  context.ca_certificates = NGHTTP2_CERTIFICATE
  context
end

private def interop_string(random : Random, size : Int32) : String
  String.build(size) do |io|
    size.times do
      io.write_byte(random.rand('a'.ord..'z'.ord).to_u8)
    end
  end
end

private def wait_for_outbound_frame(
  connection : HTTP2::Connection,
  type_code : UInt8,
) : HTTP2::Connection::Diagnostic
  deadline = Time.instant + 2.seconds
  loop do
    remaining = deadline - Time.instant
    fail("did not observe outbound frame type #{type_code}") if remaining <= Time::Span.zero

    select
    when diagnostic = connection.diagnostics.receive
      if diagnostic.kind.frame? &&
         diagnostic.direction.outbound? &&
         diagnostic.frame_type == type_code
        return diagnostic
      end
    when timeout(remaining)
      fail("did not observe outbound frame type #{type_code}")
    end
  end
end

if NGHTTP2_INTEROP_ENABLED
  describe "nghttp2 interoperability" do
    it "negotiates TLS with ALPN and consumes response trailers" do
      client = HTTP2::Client.new(
        tls_origin,
        timeouts: interop_timeouts,
        connection_configuration: interop_configuration,
        tls_context: interop_tls_context
      )
      begin
        response = client.get("/hello.txt")

        response.status.should eq(200)
        response.body.gets_to_end.should eq("hello from nghttp2\n")
        response.trailers["x-nghttp2-trailer"].should eq("received")
        client.graceful_close(3.seconds)
      ensure
        client.close unless client.closed?
      end
    end

    it "streams a large echo through small peer flow-control windows" do
      payload = Bytes.new(256 * 1_024) { |index| (index % 251).to_u8 }
      client = HTTP2::Client.new(
        cleartext_origin,
        timeouts: interop_timeouts,
        connection_configuration: interop_configuration
      )
      begin
        response = client.post("/upload", payload)

        response.status.should eq(200)
        response.body.gets_to_end.to_slice.should eq(payload)
        response.trailers["x-nghttp2-trailer"].should eq("received")
        client.graceful_close(3.seconds)
      ensure
        client.close unless client.closed?
      end
    end

    it "interoperates with a fragmented request field block" do
      connection = HTTP2::Connection.connect_prior_knowledge(
        NGHTTP2_HOST,
        NGHTTP2_CLEARTEXT_PORT,
        interop_configuration(diagnostic_queue_capacity: 256),
        connect_timeout: 3.seconds,
        read_timeout: 5.seconds,
        write_timeout: 5.seconds
      )
      client = HTTP2::Client.new(
        cleartext_origin,
        connection: connection,
        timeouts: interop_timeouts
      )
      value = interop_string(Random.new(0x4652_4147_u64), 24_000)
      begin
        response = client.get(
          "/hello.txt",
          HTTP2::Headers{"x-fragmented-field" => value}
        )

        response.status.should eq(200)
        response.body.gets_to_end.should eq("hello from nghttp2\n")
        response.trailers
        wait_for_outbound_frame(
          connection,
          HTTP2::Frame::Continuation::TypeCode
        )
        client.graceful_close(3.seconds)
      ensure
        client.close unless client.closed?
      end
    end

    it "multiplexes concurrent requests on one connection" do
      client = HTTP2::Client.new(
        cleartext_origin,
        timeouts: interop_timeouts,
        connection_configuration: interop_configuration
      )
      count = 12
      results = Channel(UInt32 | Exception).new(count)
      begin
        count.times do
          spawn do
            begin
              response = client.get("/hello.txt")
              response.status.should eq(200)
              response.body.gets_to_end.should eq("hello from nghttp2\n")
              response.trailers
              results.send(response.stream_id)
            rescue error
              results.send(error)
            end
          end
        end

        stream_ids = Array(UInt32).new(count)
        count.times do
          case result = results.receive
          when Exception
            raise result
          when UInt32
            stream_ids << result
          end
        end
        stream_ids.uniq.size.should eq(count)
        stream_ids.all?(&.odd?).should be_true
        client.graceful_close(3.seconds)
      ensure
        client.close unless client.closed?
      end
    end

    it "resets a canceled response without losing the connection" do
      connection = HTTP2::Connection.connect_prior_knowledge(
        NGHTTP2_HOST,
        NGHTTP2_CLEARTEXT_PORT,
        interop_configuration(diagnostic_queue_capacity: 256),
        connect_timeout: 3.seconds,
        read_timeout: 5.seconds,
        write_timeout: 5.seconds
      )
      client = HTTP2::Client.new(
        cleartext_origin,
        connection: connection,
        timeouts: interop_timeouts
      )
      begin
        response = client.get("/large.bin")
        response.body.read(Bytes.new(128)).should be > 0
        response.cancel
        wait_for_outbound_frame(
          connection,
          HTTP2::Frame::ResetStream::TypeCode
        )

        follow_up = client.get("/hello.txt")
        follow_up.status.should eq(200)
        follow_up.body.gets_to_end.should eq("hello from nghttp2\n")
        follow_up.trailers
        client.graceful_close(3.seconds)
      ensure
        client.close unless client.closed?
      end
    end
  end
end
