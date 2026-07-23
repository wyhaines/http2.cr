require "./spec_helper"

describe HTTP2::Frame::WindowUpdate do
  it "builds connection and stream window increments" do
    connection = HTTP2::Frame::WindowUpdate.new(0_u32, 1_u32)
    connection.window_size_increment.should eq(1_u32)

    stream = HTTP2::Frame::WindowUpdate.new(
      3_u32,
      HTTP2::FrameHeader::MAX_STREAM_ID
    )
    stream.window_size_increment.should eq(HTTP2::FrameHeader::MAX_STREAM_ID)
  end

  it "ignores the reserved increment bit" do
    frame = HTTP2::Frame::WindowUpdate.new(
      0_u8,
      1_u32,
      Bytes[0x80, 0, 0, 5]
    )
    frame.window_size_increment.should eq(5_u32)
  end

  it "rejects zero increments with the correct scope" do
    expect_violation(
      HTTP2::ErrorCode::PROTOCOL_ERROR,
      HTTP2::ErrorScope::Connection
    ) do
      HTTP2::Frame::WindowUpdate.new(0_u32, 0_u32)
    end

    expect_violation(
      HTTP2::ErrorCode::PROTOCOL_ERROR,
      HTTP2::ErrorScope::Stream,
      3_u32
    ) do
      HTTP2::Frame::WindowUpdate.new(3_u32, 0_u32)
    end
  end

  it "requires exactly four payload octets as a connection error" do
    [0, 3, 5].each do |length|
      expect_violation(
        HTTP2::ErrorCode::FRAME_SIZE_ERROR,
        HTTP2::ErrorScope::Connection
      ) do
        HTTP2::Frame::WindowUpdate.new(0_u8, 1_u32, Bytes.new(length))
      end
    end
  end

  it "rejects increments that cannot fit in 31 bits" do
    expect_raises(ArgumentError) do
      HTTP2::Frame::WindowUpdate.new(0_u32, 0x80000000_u32)
    end
  end
end
