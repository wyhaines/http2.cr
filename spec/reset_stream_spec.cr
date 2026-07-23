require "./spec_helper"

describe HTTP2::Frame::ResetStream do
  it "constructs from both known and unknown error codes" do
    known = HTTP2::Frame::ResetStream.new(1_u32, HTTP2::ErrorCode::CANCEL)
    known.error_code.should eq(HTTP2::ErrorCode::CANCEL.to_u32)

    unknown = HTTP2::Frame::ResetStream.new(3_u32, 0xdeadbeef_u32)
    unknown.error_code.should eq(0xdeadbeef_u32)
  end

  it "rejects stream 0" do
    expect_violation(
      HTTP2::ErrorCode::PROTOCOL_ERROR,
      HTTP2::ErrorScope::Connection
    ) do
      HTTP2::Frame::ResetStream.new(0_u8, 0_u32, Bytes.new(4))
    end
  end

  it "requires exactly four payload octets" do
    [0, 3, 5].each do |length|
      expect_violation(
        HTTP2::ErrorCode::FRAME_SIZE_ERROR,
        HTTP2::ErrorScope::Connection
      ) do
        HTTP2::Frame::ResetStream.new(0_u8, 1_u32, Bytes.new(length))
      end
    end
  end
end
