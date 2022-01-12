require "./spec_helper"

describe HTTP2::Frame::Ping do
  it "has all expected flags defined" do
    HTTP2::Frame::Ping::Flags.values.includes?(HTTP2::Frame::Ping::Flags::ACK).should be_true
    HTTP2::Frame::Ping::Flags.new(0x01_u8).should eq HTTP2::Frame::Ping::Flags::ACK
  end

  it "can create a Ping frame" do
    frame = HTTP2::Frame::Ping.new(0x00_u8, 0x00_u32, Bytes.new(8, 0))
    frame.type_code.should eq 0x06_u8
    frame.flags.should eq HTTP2::Frame::Ping::Flags::None
    frame.stream_id.should eq 0x00_u32
    frame.payload.should eq Bytes.new(8, 0)
    frame.data.should eq Bytes.new(8, 0) # data and payload are the same in this frame.
  end

  it "can carry arbitrary 8 byte data" do
    frame = HTTP2::Frame::Ping.new(0x00_u8, 0x00_u32, "\xaa\xbb\xcc\xdd\xee\xff\x01\x23".to_slice)
    frame.data.should eq "\xaa\xbb\xcc\xdd\xee\xff\x01\x23".to_slice
    frame.payload.should eq "\xaa\xbb\xcc\xdd\xee\xff\x01\x23".to_slice
  end

  it "errors appropriately" do
    HTTP2::Frame::Ping.new(0x00_u8, 0x00_u32, Bytes.new(7, 0)).error?.should be_a HTTP2::FrameSizeError
    HTTP2::Frame::Ping.new(0x00_u8, 0x00_u32, Bytes.new(9, 0)).error?.should be_a HTTP2::FrameSizeError
    HTTP2::Frame::Ping.new(0x00_u8, 0x00_u32, "\xaa\xbb\xcc\xdd\xee\xff\x01\x23".to_slice).error?.should be_falsey
    HTTP2::Frame::Ping.new(0x00_u8, 0x00_u32).error?.should be_falsey
    HTTP2::Frame::Ping.new(0x00_u8, 0x12345678_u32).error?.should be_a HTTP2::ProtocolError
  end
end
