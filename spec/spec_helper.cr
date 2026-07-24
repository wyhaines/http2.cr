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

def complete_server_handshake(
  io : IO,
  settings : HTTP2::Frame::Settings = HTTP2::Frame::Settings.new([] of HTTP2::Frame::Settings::Setting),
) : HTTP2::Frame::Settings
  client_settings = read_client_preface(io)
  settings.write(io)
  HTTP2::Frame::Settings.ack.write(io)
  io.flush

  acknowledgement = HTTP2::Frame.read(io)
  acknowledgement.should be_a(HTTP2::Frame::Settings)
  acknowledgement.as(HTTP2::Frame::Settings).ack?.should be_true
  client_settings
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
