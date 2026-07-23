require "./spec_helper"

describe HTTP2::Frame::Continuation do
  it "stores an opaque field-block fragment" do
    frame = HTTP2::Frame::Continuation.new(
      HTTP2::Frame::Continuation::Flags::END_HEADERS,
      3_u32,
      Bytes[0x82, 0x86]
    )
    frame.header_block_fragment.should eq(Bytes[0x82, 0x86])
    frame.end_headers?.should be_true
  end

  it "rejects stream 0" do
    expect_violation(
      HTTP2::ErrorCode::PROTOCOL_ERROR,
      HTTP2::ErrorScope::Connection
    ) do
      HTTP2::Frame::Continuation.new(0_u8, 0_u32, Bytes.empty)
    end
  end
end
