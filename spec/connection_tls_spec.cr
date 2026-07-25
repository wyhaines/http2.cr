require "./spec_helper"

private TLS_CERTIFICATE = File.join(__DIR__, "fixtures", "tls", "example.crt")
private TLS_PRIVATE_KEY = File.join(__DIR__, "fixtures", "tls", "example.key")

private def tls_server_context(
  alpn : String? = "h2",
) : OpenSSL::SSL::Context::Server
  context = OpenSSL::SSL::Context::Server.new
  context.certificate_chain = TLS_CERTIFICATE
  context.private_key = TLS_PRIVATE_KEY
  context.alpn_protocol = alpn if alpn
  context.disable_session_resume_tickets
  context
end

private def tls_client_context : OpenSSL::SSL::Context::Client
  context = OpenSSL::SSL::Context::Client.new
  context.ca_certificates = TLS_CERTIFICATE
  context
end

describe HTTP2::Connection do
  it "uses certificate verification, SNI, and ALPN h2 for TLS" do
    server = TCPServer.new("127.0.0.1", 0)
    release = Channel(Nil).new(1)
    server_context = tls_server_context
    peer_result = scripted_peer(server) do |listener|
      socket = listener.as(TCPServer).accept
      tls = OpenSSL::SSL::Socket::Server.new(
        socket,
        server_context,
        sync_close: true
      )
      begin
        tls.alpn_protocol.should eq("h2")
        tls.hostname.should eq("example.com")
        complete_server_handshake(tls)
        release.receive
      ensure
        tls.close
      end
    end

    context = tls_client_context
    context.verify_mode.should eq(OpenSSL::SSL::VerifyMode::PEER)
    connection = HTTP2::Connection.connect_tls(
      "127.0.0.1",
      server.local_address.port,
      server_name: "example.com",
      context: context
    )
    begin
      connection.wait_until_active(2.seconds)
      connection.active?.should be_true
      release.send(nil)
      wait_for_peer(peer_result)
    ensure
      connection.close
      server.close
    end
  end

  it "rejects TLS peers that do not negotiate h2" do
    server = TCPServer.new("127.0.0.1", 0)
    server_context = tls_server_context("http/1.1")
    peer_result = scripted_peer(server) do |listener|
      socket = listener.as(TCPServer).accept
      tls = OpenSSL::SSL::Socket::Server.new(
        socket,
        server_context,
        sync_close: true
      )
      begin
        tls.alpn_protocol.should be_nil
      ensure
        tls.close
      end
    end

    expect_raises(HTTP2::Connection::TLSNegotiationError) do
      HTTP2::Connection.connect_tls(
        "127.0.0.1",
        server.local_address.port,
        server_name: "example.com",
        context: tls_client_context
      )
    end
    wait_for_peer(peer_result)
    server.close
  end

  it "rejects a certificate for the wrong hostname" do
    server = TCPServer.new("127.0.0.1", 0)
    server_context = tls_server_context
    peer_done = Channel(Nil).new(1)
    spawn do
      socket = server.accept
      begin
        OpenSSL::SSL::Socket::Server.new(
          socket,
          server_context,
          sync_close: true
        ).close
      rescue OpenSSL::SSL::Error
        socket.close
      ensure
        peer_done.send(nil)
      end
    end

    error = expect_raises(HTTP2::Connection::TLSVerificationError) do
      HTTP2::Connection.connect_tls(
        "127.0.0.1",
        server.local_address.port,
        server_name: "wrong.example",
        context: tls_client_context
      )
    end
    error.server_name.should eq("wrong.example")
    error.cause.should be_a(OpenSSL::SSL::Error)
    select
    when peer_done.receive
    when timeout(2.seconds)
      fail("TLS peer did not finish")
    end
    server.close
  end

  it "bounds the TLS handshake read with handshake_read_timeout" do
    server = TCPServer.new("127.0.0.1", 0)
    release = Channel(Nil).new(1)
    peer_result = scripted_peer(server) do |listener|
      # Accept the TCP connection but never speak TLS: the client's
      # ClientHello is read into the kernel buffer and never answered.
      socket = listener.as(TCPServer).accept
      begin
        release.receive
      ensure
        socket.close
      end
    end

    result = Channel(Exception).new(1)
    spawn do
      begin
        HTTP2::Connection.connect_tls(
          "127.0.0.1",
          server.local_address.port,
          server_name: "example.com",
          context: tls_client_context,
          handshake_read_timeout: 200.milliseconds
        )
        result.send(Exception.new("expected connect_tls to raise"))
      rescue error
        result.send(error)
      end
    end

    error = select
    when value = result.receive
      value
    when timeout(2.seconds)
      fail("connect_tls did not bound the stalled TLS handshake read")
    end

    error.should be_a(IO::TimeoutError)

    release.send(nil)
    wait_for_peer(peer_result)
    server.close
  end

  it "closes promptly against a TLS peer with a backed-up socket and " \
     "no write timeout" do
    server = TCPServer.new("127.0.0.1", 0)
    server_context = tls_server_context
    release = Channel(Nil).new(1)
    peer_result = scripted_peer(server) do |listener|
      socket = listener.as(TCPServer).accept
      socket.recv_buffer_size = 2048
      tls = OpenSSL::SSL::Socket::Server.new(
        socket,
        server_context,
        sync_close: true
      )
      begin
        complete_server_handshake(tls)
        # Never read again: the peer has stopped draining, so the
        # client's kernel send buffer backs up and stays backed up.
        release.receive
      ensure
        tls.close
      end
    end

    transport = TCPSocket.new("127.0.0.1", server.local_address.port)
    transport.send_buffer_size = 4096
    connection = HTTP2::Connection.start_tls(
      transport,
      "example.com",
      context: tls_client_context
    )
    connection.wait_until_active(2.seconds)

    # Back up the kernel send buffer by writing directly on the raw
    # transport, bypassing HTTP2::Connection's own writer entirely, so
    # the connection's writer fiber stays genuinely idle throughout. This
    # reproduces "writer idle, socket backed up" -- the interleaving
    # OpenSSL's SSL_shutdown reentrancy guard does NOT protect against
    # (unlike a write caught mid SSL_write, which fails fast instead of
    # blocking -- see close_transport's comment in src/connection.cr).
    # A bounded write_timeout here is a probe, not a fix: it only proves
    # the buffer is now full, then gets cleared so the close attempt
    # below runs under the documented dangerous default (`nil`).
    transport.write_timeout = 500.milliseconds
    expect_raises(IO::TimeoutError) do
      transport.write(Bytes.new(1_000_000))
    end
    transport.write_timeout = nil

    closed = Channel(Nil).new(1)
    spawn(name: "closer") do
      connection.close
      closed.send(nil)
    end

    select
    when closed.receive
    when timeout(6.seconds)
      fail(
        "Connection#close hung against a TLS peer with a backed-up " \
        "socket and no write timeout"
      )
    end

    connection.closed?.should be_true

    release.send(nil)
    wait_for_peer(peer_result)
    server.close
  end

  it "restores a caller's persistent read_timeout after the TLS handshake" do
    server = TCPServer.new("127.0.0.1", 0)
    release = Channel(Nil).new(1)
    server_context = tls_server_context
    peer_result = scripted_peer(server) do |listener|
      socket = listener.as(TCPServer).accept
      tls = OpenSSL::SSL::Socket::Server.new(
        socket,
        server_context,
        sync_close: true
      )
      begin
        complete_server_handshake(tls)
        release.receive
      ensure
        tls.close
      end
    end

    # Enter through `start_tls` (not `connect_tls`) so the raw transport
    # stays reachable: `connect_tls` builds and hides its own TCPSocket,
    # so the only way to inspect `read_timeout` after the handshake is to
    # hold the transport ourselves, exactly as a raw caller who sets
    # `read_timeout` directly on a supplied transport would.
    transport = TCPSocket.new("127.0.0.1", server.local_address.port)
    transport.read_timeout = 5.seconds
    connection = HTTP2::Connection.start_tls(
      transport,
      "example.com",
      context: tls_client_context,
      handshake_read_timeout: 200.milliseconds
    )
    begin
      transport.read_timeout.should eq(5.seconds)
      connection.wait_until_active(2.seconds)
      connection.active?.should be_true
      release.send(nil)
      wait_for_peer(peer_result)
    ensure
      connection.close
      server.close
    end
  end

  it "creates the default TLS client context with TLS 1.0 and 1.1 disabled" do
    context = HTTP2::Connection.default_tls_context
    context.options.includes?(OpenSSL::SSL::Options::NO_TLS_V1).should be_true
    context.options.includes?(OpenSSL::SSL::Options::NO_TLS_V1_1).should be_true
  end

  it "does not reconfigure ALPN on a context http2.cr already marked as configured" do
    server = TCPServer.new("127.0.0.1", 0)
    server_context = tls_server_context
    peer_result = scripted_peer(server) do |listener|
      socket = listener.as(TCPServer).accept
      tls = OpenSSL::SSL::Socket::Server.new(
        socket,
        server_context,
        sync_close: true
      )
      begin
        tls.alpn_protocol.should be_nil
      ensure
        tls.close
      end
    end

    context = tls_client_context
    # Simulate "http2.cr already configured ALPN on this context" WITHOUT
    # actually configuring it, proving `start_tls` really does skip
    # `context.alpn_protocol = "h2"` when this flag is already set rather
    # than setting it redundantly. This is the only way to observe the
    # skip: OpenSSL exposes no getter for a context's already-configured
    # ALPN offer list (see `OpenSSL::SSL::Context::Client#alpn_h2_configured?`'s
    # doc comment for why). If the guard were missing or inverted, the
    # client would still offer "h2" here and this would raise nothing.
    context.alpn_h2_configured = true

    expect_raises(HTTP2::Connection::TLSNegotiationError) do
      HTTP2::Connection.connect_tls(
        "127.0.0.1",
        server.local_address.port,
        server_name: "example.com",
        context: context
      )
    end
    wait_for_peer(peer_result)
    server.close
  end

  it "keeps negotiating ALPN h2 when a context is reused across dials" do
    context = tls_client_context

    2.times do
      server = TCPServer.new("127.0.0.1", 0)
      server_context = tls_server_context
      peer_result = scripted_peer(server) do |listener|
        socket = listener.as(TCPServer).accept
        tls = OpenSSL::SSL::Socket::Server.new(
          socket,
          server_context,
          sync_close: true
        )
        begin
          tls.alpn_protocol.should eq("h2")
          complete_server_handshake(tls)
        ensure
          tls.close
        end
      end

      connection = HTTP2::Connection.connect_tls(
        "127.0.0.1",
        server.local_address.port,
        server_name: "example.com",
        context: context
      )
      begin
        connection.wait_until_active(2.seconds)
        connection.active?.should be_true
      ensure
        connection.close
        wait_for_peer(peer_result)
        server.close
      end
    end

    context.alpn_h2_configured?.should be_true
  end

  it "scopes the OpenSSL::SSL::Error rescue in start_tls to the handshake " \
     "construction only" do
    # (a) requires that an `OpenSSL::SSL::Error` raised by anything AFTER
    # the handshake (concretely: `Connection#start`'s preface write, via
    # `connection.start` below) propagate untranslated, never as
    # `TLSVerificationError`. This cannot be driven from the outside
    # deterministically: every transport-level failure a spec can inject
    # (closing the raw socket, breaking the pipe) unwinds directly out of
    # the OpenSSL BIO write/read callback as ITS OWN exception class
    # (already relied on by the `handshake_read_timeout` spec above, and
    # confirmed again while investigating this task -- see the task
    # report), and never reaches the `unbuffered_write`/`unbuffered_read`
    # code in Crystal's OpenSSL binding that is the ONLY place
    # `OpenSSL::SSL::Error` actually gets raised (only when
    # `SSL_write`/`SSL_read` return a failure code NORMALLY -- an actual
    # TLS PROTOCOL-level failure, not a broken transport). Forging a
    # genuine post-handshake `OpenSSL::SSL::Error` deterministically would
    # require hand-crafting encrypted TLS records against the live
    # session's negotiated keys: impractical, and far more fragile than
    # the check below.
    #
    # So instead, per the brief's documented fallback, this pins the
    # rescue's LEXICAL PLACEMENT via the method's source text: exactly one
    # `OpenSSL::SSL::Error`-typed rescue must exist, and it must sit
    # strictly between the handshake construction call and
    # `connection.start` -- never after it -- while a bare, untyped
    # `rescue error` must exist after `connection.start` to catch (and
    # re-raise unchanged) everything else, including a post-handshake
    # `OpenSSL::SSL::Error`.
    source = File.read(File.join(__DIR__, "..", "src", "connection.cr"))
    start_tls_start = source.index!("def self.start_tls")
    method_end = source.index!("def start : self", start_tls_start)
    body = source[start_tls_start...method_end]

    handshake_call = body.index!("OpenSSL::SSL::Socket::Client.new(")
    connection_start_call = body.index!("connection.start")

    typed_rescue_occurrences =
      body.split("rescue error : OpenSSL::SSL::Error").size - 1
    typed_rescue_occurrences.should eq(1)

    typed_rescue_index = body.index!("rescue error : OpenSSL::SSL::Error")
    typed_rescue_index.should be > handshake_call
    typed_rescue_index.should be < connection_start_call

    bare_rescue_index =
      body.index(/^\s*rescue error\s*$/m, connection_start_call)
    bare_rescue_index.should_not be_nil
  end
end
