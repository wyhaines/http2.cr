require "./spec_helper"

private class ScriptedPoolClient < HTTP2::Client
  @scripted_connections : Channel(HTTP2::Connection)
  @dial_count = Atomic(Int32).new(0)

  def initialize(
    connections : Array(HTTP2::Connection),
    pool_configuration : PoolConfiguration = PoolConfiguration.new(
      max_idle_connections: 4,
      idle_timeout: nil
    ),
    timeouts : Timeouts = Timeouts.new,
  )
    @scripted_connections =
      Channel(HTTP2::Connection).new(connections.size)
    connections.each { |connection| @scripted_connections.send(connection) }
    @scripted_connections.close
    super(
      "http://pool.example",
      pool_configuration: pool_configuration,
      timeouts: timeouts
    )
  end

  def dial_count : Int32
    @dial_count.get
  end

  private def dial : HTTP2::Connection
    @dial_count.add(1)
    @scripted_connections.receive
  end
end

private class GatedExpansionPoolClient < HTTP2::Client
  @scripted_connections : Channel(HTTP2::Connection)
  @dial_count = Atomic(Int32).new(0)
  @expansion_started = Channel(Nil).new(1)
  @release_expansion = Channel(Nil).new

  def initialize(
    connections : Array(HTTP2::Connection),
    pool_configuration : PoolConfiguration,
    timeouts : Timeouts,
  )
    @scripted_connections =
      Channel(HTTP2::Connection).new(connections.size)
    connections.each { |connection| @scripted_connections.send(connection) }
    @scripted_connections.close
    super(
      "http://pool.example",
      pool_configuration: pool_configuration,
      timeouts: timeouts
    )
  end

  def dial_count : Int32
    @dial_count.get
  end

  def wait_for_expansion(timeout : Time::Span = 1.second) : Nil
    select
    when @expansion_started.receive?
    when timeout(timeout)
      raise "expansion dial did not start"
    end
  end

  def release_expansion : Nil
    @release_expansion.close
  rescue Channel::ClosedError
  end

  private def dial : HTTP2::Connection
    @dial_count.add(1)
    if @dial_count.get > 1
      select
      when @expansion_started.send(nil)
      else
      end
      @release_expansion.receive?
    end
    @scripted_connections.receive
  end
end

private def pool_write_server_fields(
  io : IO,
  stream_id : UInt32,
) : Nil
  flags = HTTP2::Frame::Headers::Flags::END_HEADERS |
          HTTP2::Frame::Headers::Flags::END_STREAM
  HTTP2::Frame::Headers.new(
    flags,
    stream_id,
    HPack::Encoder.new.encode([{":status", "204"}])
  ).write(io)
  io.flush
end

private def pool_peer(
  io : IO,
  admitted : Channel(UInt32),
  release_response : Channel(Nil),
  keep_open : Channel(Nil),
) : Channel(Exception?)
  scripted_peer(io) do |peer|
    complete_server_handshake(
      peer,
      HTTP2::Frame::Settings.new([
        HTTP2::Frame::Settings::Setting.new(
          HTTP2::Frame::Settings::Identifier::MAX_CONCURRENT_STREAMS,
          1_u32
        ),
      ])
    )
    headers = read_client_headers(peer)
    admitted.send(headers.stream_id)
    release_response.receive?
    pool_write_server_fields(peer, headers.stream_id)
    keep_open.receive?
  end
end

describe HTTP2::Client::PoolConfiguration do
  it "uses bounded demand-driven defaults" do
    configuration = HTTP2::Client::PoolConfiguration.new
    configuration.max_connections.should eq(4)
    configuration.max_idle_connections.should eq(2)
    configuration.idle_timeout.should eq(90.seconds)
    configuration.max_retired_connections.should eq(4)
  end

  it "supports no hard connection limit" do
    configuration = HTTP2::Client::PoolConfiguration.new(
      max_connections: nil
    )
    configuration.max_connections.should be_nil
  end

  it "caps the effective idle count at a finite connection maximum" do
    configuration = HTTP2::Client::PoolConfiguration.new(
      max_connections: 2,
      max_idle_connections: 9
    ).effective
    configuration.max_idle_connections.should eq(2)
  end

  it "validates resource limits" do
    expect_raises(ArgumentError) do
      HTTP2::Client::PoolConfiguration.new(max_connections: 0)
    end
    expect_raises(ArgumentError) do
      HTTP2::Client::PoolConfiguration.new(max_idle_connections: -1)
    end
    expect_raises(ArgumentError) do
      HTTP2::Client::PoolConfiguration.new(idle_timeout: Time::Span.zero)
    end
    expect_raises(ArgumentError) do
      HTTP2::Client::PoolConfiguration.new(max_retired_connections: 0)
    end
  end
end

describe HTTP2::Client do
  it "reports an empty pool before the first owned dial" do
    client = HTTP2::Client.new("http://pool.example")
    begin
      state = client.pool_state
      state.eligible_connections.should eq(0)
      state.retired_connections.should eq(0)
      state.dialing?.should be_false
      state.max_connections.should eq(4)
    ensure
      client.close
    end
  end

  it "rejects explicit pool policy for a supplied connection" do
    connection = HTTP2::Connection.new(IO::Memory.new)
    expect_raises(ArgumentError) do
      HTTP2::Client.new(
        "http://pool.example",
        connection: connection,
        pool_configuration: HTTP2::Client::PoolConfiguration.new
      )
    end
    connection.close
  end

  it "force-closes an in-flight handshake during graceful close" do
    client_io, peer_io = UNIXSocket.pair
    preface_seen = Channel(Nil).new
    peer_result = scripted_peer(peer_io) do |peer|
      read_client_preface(peer)
      preface_seen.close
      loop do
        frame = HTTP2::Frame.read(peer)
        frame.should_not be_a(HTTP2::Frame::GoAway)
      end
    rescue IO::EOFError | IO::Error
      # An unpublished connection is abandoned without a graceful GOAWAY.
    end
    connection = HTTP2::Connection.start(client_io)
    client = ScriptedPoolClient.new(
      [connection],
      timeouts: HTTP2::Client::Timeouts.new(read: 2.seconds)
    )
    request_result = Channel(Exception?).new(1)
    spawn do
      begin
        client.get("/")
        request_result.send(nil)
      rescue error
        request_result.send(error)
      end
    end

    begin
      preface_seen.receive?
      eventually(message: "client did not retain the handshaking dial") do
        client.pool_state.dialing?
      end
      client.graceful_close(1.second)
      request_result.receive.should be_a(HTTP2::Client::ClosedError)
      wait_for_peer(peer_result)
    ensure
      client.close
    end
  end

  it "opens a second connection when the first peer slot is held" do
    connections = [] of HTTP2::Connection
    peer_results = [] of Channel(Exception?)
    admitted = Array(Channel(UInt32)).new
    releases = Array(Channel(Nil)).new
    keep_open = Channel(Nil).new

    2.times do
      client_io, peer_io = UNIXSocket.pair
      connection = HTTP2::Connection.start(client_io)
      connections << connection
      admitted_channel = Channel(UInt32).new(1)
      release_channel = Channel(Nil).new
      admitted << admitted_channel
      releases << release_channel
      peer_results << pool_peer(
        peer_io,
        admitted_channel,
        release_channel,
        keep_open
      )
    end

    client = ScriptedPoolClient.new(connections)
    first_result = Channel(HTTP2::Response | Exception).new(1)
    spawn do
      begin
        first_result.send(client.get("/first"))
      rescue error
        first_result.send(error)
      end
    end

    begin
      admitted[0].receive.should eq(1_u32)
      second_result = Channel(HTTP2::Response | Exception).new(1)
      spawn do
        begin
          second_result.send(client.get("/second"))
        rescue error
          second_result.send(error)
        end
      end
      admitted[1].receive.should eq(1_u32)
      client.dial_count.should eq(2)

      releases[1].close
      second = second_result.receive
      second.should be_a(HTTP2::Response)
      second.as(HTTP2::Response).status.should eq(204)

      releases[0].close
      first = first_result.receive
      first.should be_a(HTTP2::Response)
      first.as(HTTP2::Response).status.should eq(204)
    ensure
      client.close
      keep_open.close
      releases.each { |release| release.close rescue nil }
      peer_results.each { |result| wait_for_peer(result) }
      connections.each { |connection| connection.close rescue nil }
    end
  end

  it "keeps a shared expansion dial alive when one waiter cancels" do
    connections = [] of HTTP2::Connection
    peer_results = [] of Channel(Exception?)
    admitted = [] of Channel(UInt32)
    releases = [] of Channel(Nil)
    keep_open = Channel(Nil).new

    2.times do
      client_io, peer_io = UNIXSocket.pair
      connections << HTTP2::Connection.start(client_io)
      admitted_channel = Channel(UInt32).new(1)
      release_channel = Channel(Nil).new
      admitted << admitted_channel
      releases << release_channel
      peer_results << pool_peer(
        peer_io,
        admitted_channel,
        release_channel,
        keep_open
      )
    end

    configuration = HTTP2::Client::PoolConfiguration.new(
      max_connections: 2,
      max_idle_connections: 2,
      idle_timeout: nil
    )
    timeouts = HTTP2::Client::Timeouts.new(stream_slot: 1.second)
    client = GatedExpansionPoolClient.new(
      connections,
      configuration,
      timeouts
    )
    first_result = Channel(HTTP2::Response | Exception).new(1)
    spawn do
      begin
        first_result.send(client.get("/held"))
      rescue error
        first_result.send(error)
      end
    end

    cancellation = HTTP2::Cancellation.new
    canceled_result = Channel(Exception?).new(1)
    surviving_result = Channel(HTTP2::Response | Exception).new(1)

    begin
      admitted[0].receive.should eq(1_u32)
      spawn do
        begin
          client.get("/canceled", cancellation: cancellation)
          canceled_result.send(nil)
        rescue error
          canceled_result.send(error)
        end
      end
      spawn do
        begin
          surviving_result.send(client.get("/surviving"))
        rescue error
          surviving_result.send(error)
        end
      end

      client.wait_for_expansion
      cancellation.cancel
      canceled_result.receive.should be_a(HTTP2::RequestCanceledError)
      100.times { Fiber.yield }
      client.dial_count.should eq(2)

      client.release_expansion
      admitted[1].receive.should eq(1_u32)
      client.dial_count.should eq(2)
      client.pool_state.eligible_connections.should eq(2)

      releases[1].close
      surviving_result.receive.should be_a(HTTP2::Response)
      releases[0].close
      first_result.receive.should be_a(HTTP2::Response)
    ensure
      client.release_expansion
      client.close
      keep_open.close
      releases.each { |release| release.close rescue nil }
      peer_results.each { |result| wait_for_peer(result) }
      connections.each { |connection| connection.close rescue nil }
    end
  end

  it "opens on another connection while the first writer is blocked" do
    settings_update = IO::Memory.new
    HTTP2::Frame::Settings.new([
      HTTP2::Frame::Settings::Setting.new(
        HTTP2::Frame::Settings::Identifier::MAX_CONCURRENT_STREAMS,
        1_u32
      ),
    ]).write(settings_update)
    stalled_transport = StallingWriteIO.new(settings_update.to_slice)
    stalled_connection = HTTP2::Connection.start(stalled_transport)
    stalled_connection.wait_until_active(1.second)
    stalled_transport.release_gated_reads!
    eventually(message: "stalled connection did not apply peer limit") do
      stalled_connection.request_capacity.peer_limit == 1_u32
    end
    stalled_transport.stall!

    second_client_io, second_peer_io = UNIXSocket.pair
    second_admitted = Channel(UInt32).new(1)
    release_second = Channel(Nil).new
    keep_open = Channel(Nil).new
    second_peer_result = pool_peer(
      second_peer_io,
      second_admitted,
      release_second,
      keep_open
    )
    second_connection = HTTP2::Connection.start(second_client_io)
    client = ScriptedPoolClient.new(
      [stalled_connection, second_connection]
    )
    first_result = Channel(Exception?).new(1)
    spawn do
      begin
        client.get("/blocked")
        first_result.send(nil)
      rescue error
        first_result.send(error)
      end
    end

    begin
      stalled_transport.wait_until_write_stalled(1.second)
      second_result = Channel(HTTP2::Response | Exception).new(1)
      spawn do
        begin
          second_result.send(client.get("/writable"))
        rescue error
          second_result.send(error)
        end
      end
      second_admitted.receive.should eq(1_u32)
      release_second.close
      response = second_result.receive
      response.should be_a(HTTP2::Response)
      response.as(HTTP2::Response).status.should eq(204)
      client.dial_count.should eq(2)
    ensure
      client.close
      release_second.close rescue nil
      keep_open.close
      wait_for_peer(second_peer_result)
      first_result.receive.should be_a(Exception)
    end
  end

  it "grows through three connections with max_connections nil" do
    connections = [] of HTTP2::Connection
    peer_results = [] of Channel(Exception?)
    admitted = [] of Channel(UInt32)
    releases = [] of Channel(Nil)
    keep_open = Channel(Nil).new

    3.times do
      client_io, peer_io = UNIXSocket.pair
      connection = HTTP2::Connection.start(client_io)
      connections << connection
      admitted_channel = Channel(UInt32).new(1)
      release_channel = Channel(Nil).new
      admitted << admitted_channel
      releases << release_channel
      peer_results << pool_peer(
        peer_io,
        admitted_channel,
        release_channel,
        keep_open
      )
    end

    configuration = HTTP2::Client::PoolConfiguration.new(
      max_connections: nil,
      max_idle_connections: 3,
      idle_timeout: nil
    )
    client = ScriptedPoolClient.new(connections, configuration)
    results = Channel(HTTP2::Response | Exception).new(3)

    begin
      3.times do |index|
        spawn do
          begin
            results.send(client.get("/#{index}"))
          rescue error
            results.send(error)
          end
        end
        admitted[index].receive.should eq(1_u32)
      end

      client.dial_count.should eq(3)
      client.pool_state.eligible_connections.should eq(3)
      releases.each(&.close)
      3.times do
        result = results.receive
        result.should be_a(HTTP2::Response)
      end
    ensure
      client.close
      keep_open.close
      releases.each { |release| release.close rescue nil }
      peer_results.each { |result| wait_for_peer(result) }
      connections.each { |connection| connection.close rescue nil }
    end
  end

  it "does not redial indefinitely for a zero-capacity unlimited pool" do
    client_io, peer_io = UNIXSocket.pair
    keep_open = Channel(Nil).new
    peer_result = scripted_peer(peer_io) do |peer|
      complete_server_handshake(
        peer,
        HTTP2::Frame::Settings.new([
          HTTP2::Frame::Settings::Setting.new(
            HTTP2::Frame::Settings::Identifier::MAX_CONCURRENT_STREAMS,
            0_u32
          ),
        ])
      )
      keep_open.receive?
    end
    connection = HTTP2::Connection.start(client_io)
    configuration = HTTP2::Client::PoolConfiguration.new(
      max_connections: nil,
      max_idle_connections: 1,
      idle_timeout: nil
    )
    client = ScriptedPoolClient.new([connection], configuration)

    begin
      error = expect_raises(HTTP2::Client::PoolSaturatedError) do
        client.get("/")
      end
      error.max_connections.should be_nil
      client.dial_count.should eq(1)
    ensure
      client.close
      keep_open.close
      wait_for_peer(peer_result)
    end
  end

  it "honors a finite maximum while zero-capacity probes are idle" do
    connections = [] of HTTP2::Connection
    peer_results = [] of Channel(Exception?)
    keep_open = Channel(Nil).new

    3.times do
      client_io, peer_io = UNIXSocket.pair
      connections << HTTP2::Connection.start(client_io)
      peer_results << scripted_peer(peer_io) do |peer|
        complete_server_handshake(
          peer,
          HTTP2::Frame::Settings.new([
            HTTP2::Frame::Settings::Setting.new(
              HTTP2::Frame::Settings::Identifier::MAX_CONCURRENT_STREAMS,
              0_u32
            ),
          ])
        )
        keep_open.receive?
      end
    end

    configuration = HTTP2::Client::PoolConfiguration.new(
      max_connections: 3,
      max_idle_connections: 0,
      idle_timeout: nil
    )
    client = ScriptedPoolClient.new(connections, configuration)

    begin
      error = expect_raises(HTTP2::Client::PoolSaturatedError) do
        client.get("/")
      end
      error.max_connections.should eq(3)
      client.dial_count.should eq(3)
    ensure
      client.close
      keep_open.close
      peer_results.each { |result| wait_for_peer(result) }
    end
  end

  it "retains a zero-capacity sentinel while waiting for SETTINGS" do
    client_io, peer_io = UNIXSocket.pair
    ready = Channel(Nil).new
    increase = Channel(Nil).new
    keep_open = Channel(Nil).new
    peer_result = scripted_peer(peer_io) do |peer|
      complete_server_handshake(
        peer,
        HTTP2::Frame::Settings.new([
          HTTP2::Frame::Settings::Setting.new(
            HTTP2::Frame::Settings::Identifier::MAX_CONCURRENT_STREAMS,
            0_u32
          ),
        ])
      )
      ready.close
      increase.receive?
      HTTP2::Frame::Settings.new([
        HTTP2::Frame::Settings::Setting.new(
          HTTP2::Frame::Settings::Identifier::MAX_CONCURRENT_STREAMS,
          1_u32
        ),
      ]).write(peer)
      peer.flush
      HTTP2::Frame.read(peer).as(HTTP2::Frame::Settings).ack?.should be_true
      headers = read_client_headers(peer)
      pool_write_server_fields(peer, headers.stream_id)
      keep_open.receive?
    end
    connection = HTTP2::Connection.start(client_io)
    configuration = HTTP2::Client::PoolConfiguration.new(
      max_connections: nil,
      max_idle_connections: 0,
      idle_timeout: 5.milliseconds
    )
    timeouts = HTTP2::Client::Timeouts.new(stream_slot: 1.second)
    client = ScriptedPoolClient.new(
      [connection],
      configuration,
      timeouts
    )
    result = Channel(HTTP2::Response | Exception).new(1)
    spawn do
      begin
        result.send(client.get("/"))
      rescue error
        result.send(error)
      end
    end

    begin
      ready.receive?
      eventually(message: "zero-capacity connection was not published") do
        client.pool_state.eligible_connections == 1
      end
      increase.close
      response = result.receive
      response.should be_a(HTTP2::Response)
      response.as(HTTP2::Response).status.should eq(204)
      client.dial_count.should eq(1)
    ensure
      client.close
      increase.close rescue nil
      keep_open.close
      wait_for_peer(peer_result)
    end
  end

  it "does not evict a fresh connection before its triggering request" do
    client_io, peer_io = UNIXSocket.pair
    admitted = Channel(UInt32).new(1)
    release = Channel(Nil).new
    keep_open = Channel(Nil).new
    peer_result = pool_peer(peer_io, admitted, release, keep_open)
    connection = HTTP2::Connection.start(client_io)
    configuration = HTTP2::Client::PoolConfiguration.new(
      max_connections: 1,
      max_idle_connections: 0,
      idle_timeout: nil
    )
    client = ScriptedPoolClient.new([connection], configuration)
    result = Channel(HTTP2::Response | Exception).new(1)
    spawn do
      begin
        result.send(client.get("/"))
      rescue error
        result.send(error)
      end
    end

    begin
      admitted.receive.should eq(1_u32)
      client.dial_count.should eq(1)
      release.close
      result.receive.should be_a(HTTP2::Response)
      eventually(message: "zero-idle pool retained its connection") do
        connection.closed? &&
          client.pool_state.eligible_connections.zero?
      end
    ensure
      client.close
      release.close rescue nil
      keep_open.close
      wait_for_peer(peer_result)
    end
  end

  it "waits pool-wide for capacity on a fixed supplied connection" do
    client_io, peer_io = UNIXSocket.pair
    first_admitted = Channel(Nil).new
    release_first = Channel(Nil).new
    second_admitted = Channel(Nil).new
    keep_open = Channel(Nil).new
    peer_result = scripted_peer(peer_io) do |peer|
      complete_server_handshake(
        peer,
        HTTP2::Frame::Settings.new([
          HTTP2::Frame::Settings::Setting.new(
            HTTP2::Frame::Settings::Identifier::MAX_CONCURRENT_STREAMS,
            1_u32
          ),
        ])
      )
      first = read_client_headers(peer)
      first_admitted.close
      release_first.receive?
      pool_write_server_fields(peer, first.stream_id)
      second = read_client_headers(peer)
      second_admitted.close
      pool_write_server_fields(peer, second.stream_id)
      keep_open.receive?
    end
    connection = HTTP2::Connection.start(client_io)
    client = HTTP2::Client.new(
      "http://pool.example",
      connection: connection,
      timeouts: HTTP2::Client::Timeouts.new(stream_slot: 1.second)
    )
    results = Channel(HTTP2::Response | Exception).new(2)
    2.times do |index|
      spawn do
        begin
          results.send(client.get("/#{index}"))
        rescue error
          results.send(error)
        end
      end
      first_admitted.receive? if index.zero?
    end

    begin
      select
      when second_admitted.receive?
        fail("second request opened before peer capacity returned")
      when timeout(10.milliseconds)
      end
      release_first.close
      second_admitted.receive?
      2.times do
        result = results.receive
        result.should be_a(HTTP2::Response)
      end
    ensure
      client.close
      release_first.close rescue nil
      keep_open.close
      wait_for_peer(peer_result)
    end
  end

  it "wakes a fixed-pool capacity waiter when the client closes" do
    client_io, peer_io = UNIXSocket.pair
    keep_open = Channel(Nil).new
    peer_result = scripted_peer(peer_io) do |peer|
      complete_server_handshake(
        peer,
        HTTP2::Frame::Settings.new([
          HTTP2::Frame::Settings::Setting.new(
            HTTP2::Frame::Settings::Identifier::MAX_CONCURRENT_STREAMS,
            0_u32
          ),
        ])
      )
      keep_open.receive?
    end
    connection = HTTP2::Connection.start(client_io)
    connection.wait_until_active(1.second)
    client = HTTP2::Client.new(
      "http://pool.example",
      connection: connection,
      timeouts: HTTP2::Client::Timeouts.new(stream_slot: 5.seconds)
    )
    result = Channel(Exception?).new(1)
    spawn do
      begin
        client.get("/")
        result.send(nil)
      rescue error
        result.send(error)
      end
    end

    begin
      select
      when early = result.receive
        raise early if early
        fail("capacity waiter returned before client close")
      when timeout(10.milliseconds)
      end
      client.close
      outcome = select
      when value = result.receive
        value
      when timeout(500.milliseconds)
        fail("client close did not wake the capacity waiter")
      end
      outcome.should be_a(HTTP2::Client::ClosedError)
    ensure
      client.close
      keep_open.close
      wait_for_peer(peer_result)
    end
  end

  it "applies stream_slot timeout and cancellation to pool acquisition" do
    client_io, peer_io = UNIXSocket.pair
    admitted = Channel(Nil).new
    release = Channel(Nil).new
    keep_open = Channel(Nil).new
    peer_result = scripted_peer(peer_io) do |peer|
      complete_server_handshake(
        peer,
        HTTP2::Frame::Settings.new([
          HTTP2::Frame::Settings::Setting.new(
            HTTP2::Frame::Settings::Identifier::MAX_CONCURRENT_STREAMS,
            1_u32
          ),
        ])
      )
      first = read_client_headers(peer)
      admitted.close
      release.receive?
      pool_write_server_fields(peer, first.stream_id)
      keep_open.receive?
    end
    connection = HTTP2::Connection.start(client_io)
    client = HTTP2::Client.new(
      "http://pool.example",
      connection: connection,
      timeouts: HTTP2::Client::Timeouts.new(
        stream_slot: 20.milliseconds
      )
    )
    first_result = Channel(HTTP2::Response | Exception).new(1)
    spawn do
      begin
        first_result.send(client.get("/held"))
      rescue error
        first_result.send(error)
      end
    end

    begin
      admitted.receive?
      expect_raises(HTTP2::Client::PoolSaturatedError) do
        client.get("/timeout")
      end

      cancellation = HTTP2::Cancellation.new
      canceled = Channel(Exception?).new(1)
      spawn do
        begin
          client.get("/canceled", cancellation: cancellation)
          canceled.send(nil)
        rescue error
          canceled.send(error)
        end
      end
      cancellation.cancel
      canceled.receive.should be_a(HTTP2::RequestCanceledError)

      release.close
      first_result.receive.should be_a(HTTP2::Response)
    ensure
      client.close
      release.close rescue nil
      keep_open.close
      wait_for_peer(peer_result)
    end
  end

  it "contracts excess idle connections after a burst" do
    connections = [] of HTTP2::Connection
    peer_results = [] of Channel(Exception?)
    admitted = [] of Channel(UInt32)
    releases = [] of Channel(Nil)
    keep_open = Channel(Nil).new

    2.times do
      client_io, peer_io = UNIXSocket.pair
      connection = HTTP2::Connection.start(client_io)
      connections << connection
      admitted_channel = Channel(UInt32).new(1)
      release_channel = Channel(Nil).new
      admitted << admitted_channel
      releases << release_channel
      peer_results << pool_peer(
        peer_io,
        admitted_channel,
        release_channel,
        keep_open
      )
    end

    configuration = HTTP2::Client::PoolConfiguration.new(
      max_connections: 2,
      max_idle_connections: 1,
      idle_timeout: nil
    )
    client = ScriptedPoolClient.new(connections, configuration)
    results = Channel(HTTP2::Response | Exception).new(2)

    begin
      2.times do |index|
        spawn do
          begin
            results.send(client.get("/#{index}"))
          rescue error
            results.send(error)
          end
        end
        admitted[index].receive
      end
      releases.each(&.close)
      2.times { results.receive.should be_a(HTTP2::Response) }

      eventually(message: "pool did not contract to one idle connection") do
        state = client.pool_state
        state.eligible_connections == 1 &&
          state.idle_connections == 1
      end
      connections.count(&.closed?).should eq(1)
    ensure
      client.close
      keep_open.close
      releases.each { |release| release.close rescue nil }
      peer_results.each { |result| wait_for_peer(result) }
      connections.each { |connection| connection.close rescue nil }
    end
  end

  it "expires an idle connection by monotonic age" do
    client_io, peer_io = UNIXSocket.pair
    admitted = Channel(UInt32).new(1)
    release = Channel(Nil).new
    keep_open = Channel(Nil).new
    peer_result = pool_peer(peer_io, admitted, release, keep_open)
    connection = HTTP2::Connection.start(client_io)
    configuration = HTTP2::Client::PoolConfiguration.new(
      max_connections: 1,
      max_idle_connections: 1,
      idle_timeout: 10.milliseconds
    )
    client = ScriptedPoolClient.new([connection], configuration)
    result = Channel(HTTP2::Response | Exception).new(1)
    spawn do
      begin
        result.send(client.get("/"))
      rescue error
        result.send(error)
      end
    end

    begin
      admitted.receive
      release.close
      result.receive.should be_a(HTTP2::Response)
      eventually(message: "idle connection did not expire") do
        client.pool_state.eligible_connections.zero? &&
          connection.closed?
      end
    ensure
      client.close
      keep_open.close
      wait_for_peer(peer_result)
    end
  end

  it "replaces a GOAWAY connection while its accepted stream drains" do
    first_client_io, first_peer_io = UNIXSocket.pair
    second_client_io, second_peer_io = UNIXSocket.pair
    first_admitted = Channel(Nil).new
    goaway_sent = Channel(Nil).new
    release_first = Channel(Nil).new
    keep_open = Channel(Nil).new
    first_peer_result = scripted_peer(first_peer_io) do |peer|
      complete_server_handshake(
        peer,
        HTTP2::Frame::Settings.new([
          HTTP2::Frame::Settings::Setting.new(
            HTTP2::Frame::Settings::Identifier::MAX_CONCURRENT_STREAMS,
            1_u32
          ),
        ])
      )
      headers = read_client_headers(peer)
      first_admitted.close
      HTTP2::Frame::GoAway.new(
        headers.stream_id,
        HTTP2::ErrorCode::NO_ERROR
      ).write(peer)
      peer.flush
      goaway_sent.close
      release_first.receive?
      pool_write_server_fields(peer, headers.stream_id)
      keep_open.receive?
    end
    second_admitted = Channel(UInt32).new(1)
    release_second = Channel(Nil).new
    second_peer_result = pool_peer(
      second_peer_io,
      second_admitted,
      release_second,
      keep_open
    )
    first_connection = HTTP2::Connection.start(first_client_io)
    second_connection = HTTP2::Connection.start(second_client_io)
    configuration = HTTP2::Client::PoolConfiguration.new(
      max_connections: 1,
      max_idle_connections: 1,
      idle_timeout: nil
    )
    client = ScriptedPoolClient.new(
      [first_connection, second_connection],
      configuration
    )
    first_result = Channel(HTTP2::Response | Exception).new(1)
    second_result = Channel(HTTP2::Response | Exception).new(1)
    spawn do
      begin
        first_result.send(client.get("/first"))
      rescue error
        first_result.send(error)
      end
    end

    begin
      first_admitted.receive?
      goaway_sent.receive?
      eventually(message: "GOAWAY connection was not retired") do
        first_connection.draining?
      end

      spawn do
        begin
          second_result.send(client.get("/second"))
        rescue error
          second_result.send(error)
        end
      end
      second_admitted.receive.should eq(1_u32)
      client.dial_count.should eq(2)

      release_second.close
      second_result.receive.should be_a(HTTP2::Response)
      release_first.close
      first_result.receive.should be_a(HTTP2::Response)
    ensure
      client.close
      release_first.close rescue nil
      release_second.close rescue nil
      keep_open.close
      wait_for_peer(first_peer_result)
      wait_for_peer(second_peer_result)
    end
  end

  it "replaces a stream-ID-exhausted connection while its final stream drains" do
    first_client_io, first_peer_io = UNIXSocket.pair
    second_client_io, second_peer_io = UNIXSocket.pair
    first_admitted = Channel(UInt32).new(1)
    second_admitted = Channel(UInt32).new(1)
    release_first = Channel(Nil).new
    release_second = Channel(Nil).new
    keep_open = Channel(Nil).new
    first_peer_result = pool_peer(
      first_peer_io,
      first_admitted,
      release_first,
      keep_open
    )
    second_peer_result = pool_peer(
      second_peer_io,
      second_admitted,
      release_second,
      keep_open
    )
    first_connection = HTTP2::Connection.start(first_client_io)
    second_connection = HTTP2::Connection.start(second_client_io)
    first_connection.wait_until_active(1.second)
    first_connection.test_only_next_client_stream_id =
      HTTP2::FrameHeader::MAX_STREAM_ID
    configuration = HTTP2::Client::PoolConfiguration.new(
      max_connections: 1,
      max_idle_connections: 1,
      idle_timeout: nil
    )
    client = ScriptedPoolClient.new(
      [first_connection, second_connection],
      configuration
    )
    first_result = Channel(HTTP2::Response | Exception).new(1)
    second_result = Channel(HTTP2::Response | Exception).new(1)
    spawn do
      begin
        first_result.send(client.get("/final-id"))
      rescue error
        first_result.send(error)
      end
    end

    begin
      first_admitted.receive.should eq(HTTP2::FrameHeader::MAX_STREAM_ID)
      eventually(message: "exhausted connection was not retired") do
        state = client.pool_state
        state.eligible_connections.zero? &&
          state.retired_connections == 1
      end

      spawn do
        begin
          second_result.send(client.get("/replacement"))
        rescue error
          second_result.send(error)
        end
      end
      second_admitted.receive.should eq(1_u32)
      client.dial_count.should eq(2)

      release_second.close
      second_result.receive.should be_a(HTTP2::Response)
      release_first.close
      first_result.receive.should be_a(HTTP2::Response)
    ensure
      client.close
      release_first.close rescue nil
      release_second.close rescue nil
      keep_open.close
      wait_for_peer(first_peer_result)
      wait_for_peer(second_peer_result)
    end
  end

  it "bounds retired connections while newer exhausted work drains" do
    first_client_io, first_peer_io = UNIXSocket.pair
    second_client_io, second_peer_io = UNIXSocket.pair
    first_admitted = Channel(UInt32).new(1)
    second_admitted = Channel(UInt32).new(1)
    release_first = Channel(Nil).new
    release_second = Channel(Nil).new
    keep_open = Channel(Nil).new
    first_peer_result = scripted_peer(first_peer_io) do |peer|
      complete_server_handshake(peer)
      headers = read_client_headers(peer)
      first_admitted.send(headers.stream_id)
      release_first.receive?
      begin
        pool_write_server_fields(peer, headers.stream_id)
      rescue IO::Error
        # The oldest retired connection is deliberately force-closed.
      end
      keep_open.receive?
    end
    second_peer_result = scripted_peer(second_peer_io) do |peer|
      complete_server_handshake(peer)
      headers = read_client_headers(peer)
      second_admitted.send(headers.stream_id)
      release_second.receive?
      pool_write_server_fields(peer, headers.stream_id)
      keep_open.receive?
    end
    first_connection = HTTP2::Connection.start(first_client_io)
    second_connection = HTTP2::Connection.start(second_client_io)
    first_connection.wait_until_active(1.second)
    second_connection.wait_until_active(1.second)
    first_connection.test_only_next_client_stream_id =
      HTTP2::FrameHeader::MAX_STREAM_ID
    second_connection.test_only_next_client_stream_id =
      HTTP2::FrameHeader::MAX_STREAM_ID
    configuration = HTTP2::Client::PoolConfiguration.new(
      max_connections: 1,
      max_idle_connections: 1,
      idle_timeout: nil,
      max_retired_connections: 1
    )
    client = ScriptedPoolClient.new(
      [first_connection, second_connection],
      configuration
    )
    first_result = Channel(HTTP2::Response | Exception).new(1)
    second_result = Channel(HTTP2::Response | Exception).new(1)
    spawn do
      begin
        first_result.send(client.get("/oldest"))
      rescue error
        first_result.send(error)
      end
    end

    begin
      first_admitted.receive.should eq(HTTP2::FrameHeader::MAX_STREAM_ID)
      eventually(message: "first connection was not retired") do
        client.pool_state.retired_connections == 1
      end
      spawn do
        begin
          second_result.send(client.get("/newest"))
        rescue error
          second_result.send(error)
        end
      end
      second_admitted.receive.should eq(HTTP2::FrameHeader::MAX_STREAM_ID)

      eventually(message: "oldest retired connection was not closed") do
        first_connection.closed? &&
          client.pool_state.retired_connections == 1
      end
      first_result.receive.should be_a(Exception)
      client.dial_count.should eq(2)

      release_first.close
      release_second.close
      second_result.receive.should be_a(HTTP2::Response)
    ensure
      client.close
      release_first.close rescue nil
      release_second.close rescue nil
      keep_open.close
      wait_for_peer(first_peer_result)
      wait_for_peer(second_peer_result)
    end
  end
end
