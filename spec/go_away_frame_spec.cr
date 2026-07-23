require "./spec_helper"

describe HTTP2::Frame::GoAway do
  it "builds the mandatory fields and optional debug data" do
    frame = HTTP2::Frame::GoAway.new(
      9_u32,
      HTTP2::ErrorCode::ENHANCE_YOUR_CALM,
      "diagnostic".to_slice
    )

    frame.stream_id.should eq(0_u32)
    frame.last_stream_id.should eq(9_u32)
    frame.error_code.should eq(HTTP2::ErrorCode::ENHANCE_YOUR_CALM.to_u32)
    frame.debug_data.should eq("diagnostic".to_slice)
  end

  it "ignores the reserved last-stream-ID bit" do
    frame = HTTP2::Frame::GoAway.new(
      0_u8,
      0_u32,
      Bytes[0x80, 0, 0, 9, 0, 0, 0, 0]
    )
    frame.last_stream_id.should eq(9_u32)
  end

  it "rejects nonzero frame stream IDs" do
    expect_violation(
      HTTP2::ErrorCode::PROTOCOL_ERROR,
      HTTP2::ErrorScope::Connection
    ) do
      HTTP2::Frame::GoAway.new(0_u8, 1_u32, Bytes.new(8))
    end
  end

  it "requires at least eight payload octets" do
    [0, 1, 7].each do |length|
      expect_violation(
        HTTP2::ErrorCode::FRAME_SIZE_ERROR,
        HTTP2::ErrorScope::Connection
      ) do
        HTTP2::Frame::GoAway.new(0_u8, 0_u32, Bytes.new(length))
      end
    end
  end
end
