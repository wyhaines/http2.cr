require "./spec_helper"

describe HTTP2::FrameHeader do
  it "reads and writes the exact nine-octet format" do
    header = HTTP2::FrameHeader.new(
      0x012345,
      0x09_u8,
      0x04_u8,
      0x12345678_u32
    )
    io = IO::Memory.new
    header.write(io)

    io.to_slice.should eq Bytes[
      0x01, 0x23, 0x45, 0x09, 0x04,
      0x12, 0x34, 0x56, 0x78,
    ]

    parsed = HTTP2::FrameHeader.read(IO::Memory.new(io.to_slice))
    parsed.should eq(header)
  end

  it "supports the complete 24-bit length range" do
    header = HTTP2::FrameHeader.new(
      HTTP2::FrameHeader::MAX_PAYLOAD,
      0xff_u8,
      0xff_u8,
      HTTP2::FrameHeader::MAX_STREAM_ID
    )
    io = IO::Memory.new
    header.write(io)
    HTTP2::FrameHeader.read(IO::Memory.new(io.to_slice)).should eq(header)
  end

  it "ignores the reserved stream bit on receipt" do
    bytes = Bytes[0, 0, 0, 0, 0, 0x80, 0, 0, 1]
    HTTP2::FrameHeader.read(IO::Memory.new(bytes)).stream_id.should eq(1_u32)
  end

  it "rejects values that cannot be represented on the wire" do
    expect_raises(ArgumentError) do
      HTTP2::FrameHeader.new(-1, 0_u8, 0_u8, 0_u32)
    end
    expect_raises(ArgumentError) do
      HTTP2::FrameHeader.new(
        HTTP2::FrameHeader::MAX_PAYLOAD + 1,
        0_u8,
        0_u8,
        0_u32
      )
    end
    expect_raises(ArgumentError) do
      HTTP2::FrameHeader.new(0, 0_u8, 0_u8, 0x80000000_u32)
    end
  end

  it "rejects every truncated header prefix" do
    complete = Bytes.new(HTTP2::FrameHeader::SIZE, 0_u8)
    (0...HTTP2::FrameHeader::SIZE).each do |length|
      expect_raises(IO::EOFError) do
        HTTP2::FrameHeader.read(IO::Memory.new(complete[0, length]))
      end
    end
  end
end
