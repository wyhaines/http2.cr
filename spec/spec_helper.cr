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
