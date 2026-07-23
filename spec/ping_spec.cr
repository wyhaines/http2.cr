require "./spec_helper"

describe HTTP2::Frame::Ping do
  it "carries exactly eight opaque octets" do
    payload = "12345678".to_slice
    frame = HTTP2::Frame::Ping.new(0_u8, 0_u32, payload)
    frame.payload.should eq(payload)
    frame.ack?.should be_false

    ack = frame.ack
    ack.ack?.should be_true
    ack.payload.should eq(payload)
  end

  it "offers a valid zero-filled convenience constructor" do
    HTTP2::Frame::Ping.new(0_u8, 0_u32).payload.should eq(Bytes.new(8))
  end

  it "rejects nonzero stream IDs" do
    expect_violation(
      HTTP2::ErrorCode::PROTOCOL_ERROR,
      HTTP2::ErrorScope::Connection
    ) do
      HTTP2::Frame::Ping.new(0_u8, 1_u32, Bytes.new(8))
    end
  end

  it "requires exactly eight payload octets" do
    [0, 1, 7, 9].each do |length|
      expect_violation(
        HTTP2::ErrorCode::FRAME_SIZE_ERROR,
        HTTP2::ErrorScope::Connection
      ) do
        HTTP2::Frame::Ping.new(0_u8, 0_u32, Bytes.new(length))
      end
    end
  end
end
