require "./spec_helper"

describe HTTP2::Frame::PushPromise do
  it "builds deterministic promised-ID, fragment, and padding fields" do
    frame = HTTP2::Frame::PushPromise.new(
      HTTP2::Frame::PushPromise::Flags::END_HEADERS |
      HTTP2::Frame::PushPromise::Flags::PADDED,
      1_u32,
      2_u32,
      Bytes[0x82, 0x86],
      3_u8
    )

    frame.promised_stream_id.should eq(2_u32)
    frame.header_block_fragment.should eq(Bytes[0x82, 0x86])
    frame.pad_length.should eq(3_u8)
    frame.padding.should eq(Bytes[0, 0, 0])
    frame.end_headers?.should be_true
  end

  it "ignores the reserved bit in the promised stream ID" do
    frame = HTTP2::Frame::PushPromise.new(
      0_u8,
      1_u32,
      Bytes[0x80, 0, 0, 2]
    )
    frame.promised_stream_id.should eq(2_u32)
  end

  it "rejects stream 0 and promised stream 0" do
    expect_violation(
      HTTP2::ErrorCode::PROTOCOL_ERROR,
      HTTP2::ErrorScope::Connection
    ) do
      HTTP2::Frame::PushPromise.new(0_u8, 0_u32, Bytes[0, 0, 0, 2])
    end

    expect_violation(
      HTTP2::ErrorCode::PROTOCOL_ERROR,
      HTTP2::ErrorScope::Connection
    ) do
      HTTP2::Frame::PushPromise.new(0_u8, 1_u32, Bytes.new(4))
    end
  end

  it "requires the promised stream ID field" do
    (0...4).each do |length|
      expect_violation(
        HTTP2::ErrorCode::FRAME_SIZE_ERROR,
        HTTP2::ErrorScope::Connection
      ) do
        HTTP2::Frame::PushPromise.new(0_u8, 1_u32, Bytes.new(length))
      end
    end
  end

  it "rejects malformed padding and padding-hidden mandatory fields" do
    expect_violation(
      HTTP2::ErrorCode::FRAME_SIZE_ERROR,
      HTTP2::ErrorScope::Connection
    ) do
      HTTP2::Frame::PushPromise.new(
        HTTP2::Frame::PushPromise::Flags::PADDED,
        1_u32,
        Bytes.empty
      )
    end

    expect_violation(
      HTTP2::ErrorCode::PROTOCOL_ERROR,
      HTTP2::ErrorScope::Connection
    ) do
      HTTP2::Frame::PushPromise.new(
        HTTP2::Frame::PushPromise::Flags::PADDED,
        1_u32,
        Bytes[1]
      )
    end

    expect_violation(
      HTTP2::ErrorCode::FRAME_SIZE_ERROR,
      HTTP2::ErrorScope::Connection
    ) do
      HTTP2::Frame::PushPromise.new(
        HTTP2::Frame::PushPromise::Flags::PADDED,
        1_u32,
        Bytes[0, 0, 0, 1]
      )
    end
  end

  it "requires PADDED when a constructor pad length is supplied" do
    expect_raises(ArgumentError) do
      HTTP2::Frame::PushPromise.new(
        HTTP2::Frame::PushPromise::Flags::END_HEADERS,
        1_u32,
        2_u32,
        Bytes.empty,
        1_u8
      )
    end
  end
end
