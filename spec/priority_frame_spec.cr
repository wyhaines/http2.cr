require "./spec_helper"

describe HTTP2::Frame::Priority do
  it "exposes its encoded priority fields" do
    frame = HTTP2::Frame::Priority.new(
      0xff_u8,
      1_u32,
      Bytes[0x80, 0, 0, 3, 15]
    )

    frame.flags.should eq(HTTP2::Frame::Flags::None)
    frame.exclusive?.should be_true
    frame.stream_dependency.should eq(3_u32)
    frame.weight.should eq(15_u8)
  end

  it "rejects stream 0" do
    expect_violation(
      HTTP2::ErrorCode::PROTOCOL_ERROR,
      HTTP2::ErrorScope::Connection
    ) do
      HTTP2::Frame::Priority.new(0_u8, 0_u32, Bytes.new(5))
    end
  end

  it "rejects every non-five-octet test length as a stream error" do
    [0, 1, 4, 6, 8].each do |length|
      expect_violation(
        HTTP2::ErrorCode::FRAME_SIZE_ERROR,
        HTTP2::ErrorScope::Stream,
        1_u32
      ) do
        HTTP2::Frame::Priority.new(0_u8, 1_u32, Bytes.new(length))
      end
    end
  end
end
