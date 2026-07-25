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
end
