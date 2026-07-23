require "./spec_helper"

describe HTTP2::Frame do
  it "round-trips every standard frame type" do
    frames = [] of HTTP2::Frames
    frames << HTTP2::Frame::Data.new(0x01_u8, 1_u32, "body")
    frames << HTTP2::Frame::Headers.new(
      HTTP2::Frame::Headers::Flags::END_HEADERS,
      1_u32,
      Bytes[0x82]
    )
    frames << HTTP2::Frame::Priority.new(
      0_u8,
      1_u32,
      Bytes[0x80, 0, 0, 3, 15]
    )
    frames << HTTP2::Frame::ResetStream.new(1_u32, HTTP2::ErrorCode::CANCEL)
    frames << HTTP2::Frame::Settings.new([
      HTTP2::Frame::Settings::Setting.new(
        HTTP2::Frame::Settings::Identifier::MAX_FRAME_SIZE,
        32_768_u32
      ),
    ])
    frames << HTTP2::Frame::PushPromise.new(
      HTTP2::Frame::PushPromise::Flags::END_HEADERS,
      1_u32,
      2_u32,
      Bytes[0x82]
    )
    frames << HTTP2::Frame::Ping.new(0_u8, 0_u32, "12345678")
    frames << HTTP2::Frame::GoAway.new(1_u32, HTTP2::ErrorCode::NO_ERROR)
    frames << HTTP2::Frame::WindowUpdate.new(0_u32, 1_u32)
    frames << HTTP2::Frame::Continuation.new(
      HTTP2::Frame::Continuation::Flags::END_HEADERS,
      1_u32,
      Bytes[0x82]
    )

    frames.each do |expected|
      parsed = HTTP2::Frame.read(
        IO::Memory.new(expected.to_slice),
        HTTP2::FrameHeader::MAX_PAYLOAD
      )
      parsed.class.should eq(expected.class)
      parsed.to_slice.should eq(expected.to_slice)
    end
  end

  it "preserves unknown frame types for the connection to ignore" do
    bytes = wire_frame(0xf0_u8, 0xa5_u8, 17_u32, Bytes[1, 2, 3])
    frame = HTTP2::Frame.read(IO::Memory.new(bytes))

    frame.should be_a(HTTP2::Frame::Unknown)
    unknown = frame.as(HTTP2::Frame::Unknown)
    unknown.type_code.should eq(0xf0_u8)
    unknown.flags.should eq(0xa5_u8)
    unknown.stream_id.should eq(17_u32)
    unknown.payload.should eq(Bytes[1, 2, 3])
    unknown.to_slice.should eq(bytes)
  end

  it "ignores unused flags on known frame types" do
    frames = [] of HTTP2::Frames
    frames << HTTP2::Frame::Data.new(0xff_u8, 1_u32, Bytes[0])
    frames << HTTP2::Frame::Headers.new(
      0xff_u8,
      1_u32,
      Bytes[0, 0, 0, 0, 1, 0]
    )
    frames << HTTP2::Frame::Priority.new(0xff_u8, 1_u32, Bytes.new(5))
    frames << HTTP2::Frame::ResetStream.new(0xff_u8, 1_u32, Bytes.new(4))
    frames << HTTP2::Frame::Settings.new(0xff_u8, 0_u32, Bytes.empty)
    frames << HTTP2::Frame::PushPromise.new(
      0xff_u8,
      1_u32,
      Bytes[0, 0, 0, 0, 2]
    )
    frames << HTTP2::Frame::Ping.new(0xff_u8, 0_u32, Bytes.new(8))
    frames << HTTP2::Frame::GoAway.new(0xff_u8, 0_u32, Bytes.new(8))
    frames << HTTP2::Frame::WindowUpdate.new(
      0xff_u8,
      0_u32,
      Bytes[0, 0, 0, 1]
    )
    frames << HTTP2::Frame::Continuation.new(
      0xff_u8,
      1_u32,
      Bytes.empty
    )

    frames.map(&.header.flags).should eq([
      0x09_u8, 0x2d_u8, 0_u8, 0_u8, 0x01_u8,
      0x0c_u8, 0x01_u8, 0_u8, 0_u8, 0x04_u8,
    ])
  end

  it "enforces the inbound limit before allocating or reading a payload" do
    io = IO::Memory.new
    HTTP2::FrameHeader.new(
      HTTP2::FrameHeader::DEFAULT_MAX_PAYLOAD + 1,
      0xf0_u8,
      0_u8,
      0_u32
    ).write(io)
    io.rewind

    expect_violation(
      HTTP2::ErrorCode::FRAME_SIZE_ERROR,
      HTTP2::ErrorScope::Connection
    ) do
      HTTP2::Frame.read(io, HTTP2::FrameHeader::DEFAULT_MAX_PAYLOAD)
    end
  end

  it "accepts the default boundary and rejects the next octet" do
    payload = Bytes.new(HTTP2::FrameHeader::DEFAULT_MAX_PAYLOAD, 0xa5_u8)
    frame = HTTP2::Frame.read(
      IO::Memory.new(wire_frame(0xf0_u8, 0_u8, 0_u32, payload))
    )
    frame.payload.size.should eq(HTTP2::FrameHeader::DEFAULT_MAX_PAYLOAD)

    io = IO::Memory.new
    HTTP2::FrameHeader.new(
      HTTP2::FrameHeader::DEFAULT_MAX_PAYLOAD + 1,
      0xf0_u8,
      0_u8,
      0_u32
    ).write(io)
    io.rewind
    expect_raises(HTTP2::FrameSizeError) { HTTP2::Frame.read(io) }
  end

  it "rejects truncated payloads" do
    bytes = wire_frame(0xf0_u8, 0_u8, 0_u32, Bytes[1, 2, 3])
    (0...3).each do |payload_length|
      expect_raises(IO::EOFError) do
        HTTP2::Frame.read(
          IO::Memory.new(bytes[0, HTTP2::FrameHeader::SIZE + payload_length])
        )
      end
    end
  end

  it "validates caller-supplied inbound limits" do
    expect_raises(ArgumentError) do
      HTTP2::Frame.read(
        IO::Memory.new,
        HTTP2::FrameHeader::DEFAULT_MAX_PAYLOAD - 1
      )
    end
    expect_raises(ArgumentError) do
      HTTP2::Frame.read(
        IO::Memory.new,
        HTTP2::FrameHeader::MAX_PAYLOAD + 1
      )
    end
  end
end

describe HTTP2::ErrorCode do
  it "defines every RFC 9113 error code" do
    HTTP2::ErrorCode.values.map(&.to_u32).should eq((0_u32..13_u32).to_a)
  end
end
