require "./spec_helper"

describe HTTP2::Frame::Headers do
  it "remains a passive field-block fragment" do
    fragment = Bytes[0x82, 0x86, 0x84]
    frame = HTTP2::Frame::Headers.new(
      HTTP2::Frame::Headers::Flags::END_HEADERS,
      1_u32,
      fragment
    )

    frame.header_block_fragment.should eq(fragment)
    frame.end_headers?.should be_true
    frame.end_stream?.should be_false
  end

  it "exposes priority, fragment, and padding fields" do
    frame = HTTP2::Frame::Headers.new(
      HTTP2::Frame::Headers::Flags::PRIORITY |
      HTTP2::Frame::Headers::Flags::PADDED,
      1_u32,
      Bytes[2, 0x80, 0, 0, 3, 15, 0x82, 0, 0]
    )

    frame.exclusive?.should be_true
    frame.stream_dependency.should eq(3_u32)
    frame.weight.should eq(15_u8)
    frame.header_block_fragment.should eq(Bytes[0x82])
    frame.padding.should eq(Bytes[0, 0])
  end

  it "rejects stream 0" do
    expect_violation(
      HTTP2::ErrorCode::PROTOCOL_ERROR,
      HTTP2::ErrorScope::Connection
    ) do
      HTTP2::Frame::Headers.new(0_u8, 0_u32, Bytes.empty)
    end
  end

  it "rejects missing priority fields as a connection frame-size error" do
    (0...5).each do |length|
      expect_violation(
        HTTP2::ErrorCode::FRAME_SIZE_ERROR,
        HTTP2::ErrorScope::Connection
      ) do
        HTTP2::Frame::Headers.new(
          HTTP2::Frame::Headers::Flags::PRIORITY,
          1_u32,
          Bytes.new(length)
        )
      end
    end
  end

  it "rejects malformed padding" do
    expect_violation(
      HTTP2::ErrorCode::FRAME_SIZE_ERROR,
      HTTP2::ErrorScope::Connection
    ) do
      HTTP2::Frame::Headers.new(
        HTTP2::Frame::Headers::Flags::PADDED,
        1_u32,
        Bytes.empty
      )
    end

    expect_violation(
      HTTP2::ErrorCode::PROTOCOL_ERROR,
      HTTP2::ErrorScope::Connection
    ) do
      HTTP2::Frame::Headers.new(
        HTTP2::Frame::Headers::Flags::PADDED,
        1_u32,
        Bytes[1]
      )
    end
  end

  it "accounts for padding before checking priority fields" do
    expect_violation(
      HTTP2::ErrorCode::FRAME_SIZE_ERROR,
      HTTP2::ErrorScope::Connection
    ) do
      HTTP2::Frame::Headers.new(
        HTTP2::Frame::Headers::Flags::PADDED |
        HTTP2::Frame::Headers::Flags::PRIORITY,
        1_u32,
        Bytes[1, 0, 0, 0, 0, 0]
      )
    end
  end

  it "rejects a self-referential PRIORITY dependency as a stream error" do
    expect_violation(
      HTTP2::ErrorCode::PROTOCOL_ERROR,
      HTTP2::ErrorScope::Stream,
      1_u32
    ) do
      HTTP2::Frame::Headers.new(
        HTTP2::Frame::Headers::Flags::PRIORITY,
        1_u32,
        Bytes[0, 0, 0, 1, 15]
      )
    end
  end

  it "accounts for padding before checking a self-referential " \
     "PRIORITY dependency" do
    expect_violation(
      HTTP2::ErrorCode::PROTOCOL_ERROR,
      HTTP2::ErrorScope::Stream,
      1_u32
    ) do
      HTTP2::Frame::Headers.new(
        HTTP2::Frame::Headers::Flags::PADDED |
        HTTP2::Frame::Headers::Flags::PRIORITY,
        1_u32,
        Bytes[0, 0, 0, 0, 1, 15]
      )
    end
  end
end
