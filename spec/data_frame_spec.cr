require "./spec_helper"

describe HTTP2::Frame::Data do
  it "exposes unpadded and padded payload components" do
    plain = HTTP2::Frame::Data.new(0_u8, 1_u32, "body")
    plain.data.should eq("body".to_slice)
    plain.padding.should be_empty
    plain.pad_length.should eq(0_u8)

    padded = HTTP2::Frame::Data.new(
      HTTP2::Frame::Data::Flags::PADDED |
      HTTP2::Frame::Data::Flags::END_STREAM,
      1_u32,
      Bytes[3, 0x62, 0x6f, 0x64, 0x79, 0, 0, 0]
    )
    padded.data.should eq("body".to_slice)
    padded.padding.should eq(Bytes[0, 0, 0])
    padded.pad_length.should eq(3_u8)
  end

  it "permits empty DATA, including zero-length declared padding" do
    HTTP2::Frame::Data.new(0_u8, 1_u32, Bytes.empty).data.should be_empty
    frame = HTTP2::Frame::Data.new(
      HTTP2::Frame::Data::Flags::PADDED,
      1_u32,
      Bytes[0]
    )
    frame.data.should be_empty
  end

  it "keeps a caller-owned copy of bytes read from an IO independent of the source" do
    io = IO::Memory.new
    io << "body"
    io.rewind
    frame = HTTP2::Frame::Data.new(0_u8, 1_u32, io.gets_to_end.to_slice.dup)
    io.clear
    frame.data.should eq("body".to_slice)
  end

  it "rejects stream 0 as a connection protocol error" do
    expect_violation(
      HTTP2::ErrorCode::PROTOCOL_ERROR,
      HTTP2::ErrorScope::Connection
    ) do
      HTTP2::Frame::Data.new(0_u8, 0_u32, Bytes.empty)
    end
  end

  it "rejects a missing Pad Length as a stream frame-size error" do
    expect_violation(
      HTTP2::ErrorCode::FRAME_SIZE_ERROR,
      HTTP2::ErrorScope::Stream,
      1_u32
    ) do
      HTTP2::Frame::Data.new(
        HTTP2::Frame::Data::Flags::PADDED,
        1_u32,
        Bytes.empty
      )
    end
  end

  it "rejects padding as large as the payload as a connection error" do
    [Bytes[1], Bytes[2, 0]].each do |payload|
      expect_violation(
        HTTP2::ErrorCode::PROTOCOL_ERROR,
        HTTP2::ErrorScope::Connection
      ) do
        HTTP2::Frame::Data.new(
          HTTP2::Frame::Data::Flags::PADDED,
          1_u32,
          payload
        )
      end
    end
  end
end
