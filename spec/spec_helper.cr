require "spec"
require "../src/http2"

def wire_frame(
  type_code : UInt8,
  flags : UInt8,
  stream_id : UInt32,
  payload : Bytes = Bytes.empty,
) : Bytes
  io = IO::Memory.new
  HTTP2::FrameHeader.new(
    payload.size.to_i32,
    type_code,
    flags,
    stream_id
  ).write(io)
  io.write(payload)
  io.to_slice
end

def expect_violation(
  error_code : HTTP2::ErrorCode,
  scope : HTTP2::ErrorScope,
  stream_id : UInt32? = nil,
  &block : ->
)
  error = expect_raises(HTTP2::ProtocolError) { block.call }
  error.error_code.should eq(error_code)
  error.scope.should eq(scope)
  error.stream_id.should eq(stream_id)
  error
end

def scripted_peer(io : IO, &block : IO -> Nil) : Channel(Exception?)
  result = Channel(Exception?).new(1)
  spawn do
    begin
      block.call(io)
      result.send(nil)
    rescue error
      result.send(error)
    end
  end
  result
end

def wait_for_peer(
  result : Channel(Exception?),
  timeout : Time::Span = 2.seconds,
) : Nil
  error = select
  when value = result.receive
    value
  when timeout(timeout)
    fail("scripted peer timed out")
  end
  raise error if error
end

def eventually(
  timeout : Time::Span = 1.second,
  message : String = "condition was not met",
  & : -> Bool
) : Nil
  deadline = Time.instant + timeout
  until yield
    fail(message) if Time.instant >= deadline
    Fiber.yield
  end
end

def read_client_preface(io : IO) : HTTP2::Frame::Settings
  preface = Bytes.new(HTTP2::Connection::Preface.size)
  io.read_fully(preface)
  preface.should eq(HTTP2::Connection::Preface)

  frame = HTTP2::Frame.read(io)
  frame.should be_a(HTTP2::Frame::Settings)
  settings = frame.as(HTTP2::Frame::Settings)
  settings.ack?.should be_false
  settings
end

# With the default `Configuration#connection_receive_window` (1 MiB), the
# client announces its startup connection-window grant via an unsolicited
# WINDOW_UPDATE(stream 0) immediately after the preface — before it has
# received anything from the peer, so it always precedes whatever frame the
# client sends in reaction to the peer's own handshake response. Scripted
# peers that read "the client's next frame" right after the handshake must
# tolerate that leading grant; this skips at most the one startup frame.
def skip_startup_window_update(io : IO) : HTTP2::Frames
  frame = HTTP2::Frame.read(io)
  if frame.is_a?(HTTP2::Frame::WindowUpdate) && frame.stream_id.zero?
    frame = HTTP2::Frame.read(io)
  end
  frame
end

def complete_server_handshake(
  io : IO,
  settings : HTTP2::Frame::Settings = HTTP2::Frame::Settings.new([] of HTTP2::Frame::Settings::Setting),
) : HTTP2::Frame::Settings
  client_settings = read_client_preface(io)
  settings.write(io)
  HTTP2::Frame::Settings.ack.write(io)
  io.flush

  acknowledgement = skip_startup_window_update(io)
  acknowledgement.should be_a(HTTP2::Frame::Settings)
  acknowledgement.as(HTTP2::Frame::Settings).ack?.should be_true
  client_settings
end

def read_client_headers(io : IO, expected_stream_id : UInt32? = nil)
  first = HTTP2::Frame.read(io).as(HTTP2::Frame::Headers)
  if expected_stream_id
    first.stream_id.should eq(expected_stream_id)
  end

  until first.end_headers?
    continuation = HTTP2::Frame.read(io)
      .as(HTTP2::Frame::Continuation)
    continuation.stream_id.should eq(first.stream_id)
    break if continuation.end_headers?
  end
  first
end

def open_client_stream(
  stream : HTTP2::Stream,
  *,
  end_stream : Bool = true,
) : Nil
  stream.send_headers(
    [] of HTTP2::HeaderField,
    end_stream: end_stream
  )
end

class FailingWriteIO < IO
  getter written_bytes : Int32 = 0

  @read_data : Bytes
  @read_offset = 0
  @closed = false
  @closed_signal = Channel(Nil).new

  def initialize(@allowed_write_bytes : Int32)
    @read_data = HTTP2::Frame::Settings
      .new([] of HTTP2::Frame::Settings::Setting)
      .to_slice
  end

  def read(slice : Bytes) : Int32
    return 0 if @closed

    if @read_offset < @read_data.size
      count = Math.min(slice.size, @read_data.size - @read_offset)
      slice[0, count].copy_from(@read_data[@read_offset, count])
      @read_offset += count
      count
    else
      @closed_signal.receive?
      0
    end
  end

  def write(slice : Bytes) : Nil
    if @written_bytes + slice.size > @allowed_write_bytes
      raise IO::Error.new("injected write failure")
    end
    @written_bytes += slice.size
  end

  def close : Nil
    return if @closed

    @closed = true
    @closed_signal.close
  end

  def closed?
    @closed
  end
end

class StallingWriteIO < IO
  getter written_bytes : Int32 = 0

  @read_data : Bytes
  @read_offset = 0
  @closed = false
  @closed_signal = Channel(Nil).new
  @stall = Channel(Nil).new
  @stalled = false
  @gated_data : Bytes
  @gate = Channel(Nil).new

  # `gated_data` is served to readers only after `#release_gated_reads!` is
  # called, not from construction. This lets a caller open streams (so the
  # connection has registered state to react to) before the reader fiber can
  # observe frames that depend on that state, avoiding a race between "the
  # reader consumes the gated bytes" and "the test finishes registering the
  # stream those bytes target."
  def initialize(@gated_data : Bytes = Bytes.empty)
    handshake = IO::Memory.new
    HTTP2::Frame::Settings
      .new([] of HTTP2::Frame::Settings::Setting)
      .write(handshake)
    HTTP2::Frame::Settings.ack.write(handshake)
    @read_data = handshake.to_slice
  end

  # After this call every write blocks until the transport is closed.
  def stall! : Nil
    @stalled = true
  end

  # Appends the bytes supplied to the constructor to the readable stream and
  # wakes a reader parked past the previously available data. `@gate` is
  # unbuffered, so this blocks until a reader is parked in `#read` to receive
  # the signal — safe as long as the reader fiber is alive and eventually
  # reaches that point (it does not need to be parked there yet).
  def release_gated_reads! : Nil
    combined = IO::Memory.new
    combined.write(@read_data)
    combined.write(@gated_data)
    @read_data = combined.to_slice
    @gate.send(nil)
  end

  def read(slice : Bytes) : Int32
    return 0 if @closed

    loop do
      if @read_offset < @read_data.size
        count = Math.min(slice.size, @read_data.size - @read_offset)
        slice[0, count].copy_from(@read_data[@read_offset, count])
        @read_offset += count
        return count
      end

      select
      when @closed_signal.receive?
        return 0
      when @gate.receive?
        # `@read_data` grew (or the gate channel closed); loop and re-check.
      end
    end
  end

  def write(slice : Bytes) : Nil
    if @stalled
      @stall.receive?
      raise IO::Error.new("transport closed while a write was stalled")
    end
    @written_bytes += slice.size
  end

  def close : Nil
    return if @closed

    @closed = true
    @stall.close
    @closed_signal.close
  end

  def closed?
    @closed
  end
end

# Buffered counterpart to `StallingWriteIO`: a real `IO::Buffered` type
# (like `TCPSocket`/`OpenSSL::SSL::Socket`, and unlike `StallingWriteIO`,
# which is a plain `IO`) whose `#unbuffered_write` blocks once stalled. This
# lets specs exercise `Connection#close_transport`'s buffered-close path
# (P1.8 review finding: `IO::Buffered#close` flushes pending output before
# closing, which can deadlock against a stalled peer) deterministically,
# without a real socket or kernel-send-buffer-exhaustion timing.
class StallingBufferedWriteIO < IO
  include IO::Buffered

  @read_data : Bytes
  @read_offset = 0
  @closed = false
  @closed_signal = Channel(Nil).new
  @stall = Channel(Nil).new
  @stalled = false
  @entered_write = Channel(Nil).new(1)

  def initialize
    handshake = IO::Memory.new
    HTTP2::Frame::Settings
      .new([] of HTTP2::Frame::Settings::Setting)
      .write(handshake)
    HTTP2::Frame::Settings.ack.write(handshake)
    @read_data = handshake.to_slice
  end

  # After this call, any write that reaches `#unbuffered_write` blocks
  # until the transport is force-closed (mirroring `StallingWriteIO#stall!`).
  def stall! : Nil
    @stalled = true
  end

  # Blocks until a write has actually entered the stalled
  # `#unbuffered_write` call — i.e., there really is buffered output
  # pending behind a blocked write — so a spec can deterministically
  # synchronize before exercising `Connection#close` against it, instead
  # of racing an arbitrary sleep.
  def wait_until_write_stalled(timeout : Time::Span) : Nil
    select
    when @entered_write.receive?
    when timeout(timeout)
      raise "no write ever reached the stalled transport"
    end
  end

  private def unbuffered_read(slice : Bytes) : Int32
    return 0 if @closed

    if @read_offset < @read_data.size
      count = Math.min(slice.size, @read_data.size - @read_offset)
      slice[0, count].copy_from(@read_data[@read_offset, count])
      @read_offset += count
      count
    else
      @closed_signal.receive?
      0
    end
  end

  private def unbuffered_write(slice : Bytes) : Nil
    if @stalled
      @entered_write.send(nil)
      @stall.receive?
      raise IO::Error.new("transport closed while a write was stalled")
    end
  end

  private def unbuffered_flush : Nil
  end

  private def unbuffered_close : Nil
    return if @closed

    @closed = true
    @stall.close
    @closed_signal.close
  end

  private def unbuffered_rewind : Nil
    raise IO::Error.new("can't rewind")
  end
end
