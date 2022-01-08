require "./spec_helper"

describe HTTP2::Frame::ResetStream do
  it "can create a ResetStream frame" do
    buffer = IO::Memory.new
    error_code = Bytes.new(4, 0)
    IO::ByteFormat::BigEndian.encode(0x1234abcd, error_code)
    buffer.write error_code
    frame = HTTP2::Frame::ResetStream.new(0x00_u8, 0x12345678_u32, buffer.to_slice)
    frame.type_code.should eq 0x03_u8
    frame.stream_id.should eq 0x12345678_u32
    frame.error_code.should eq 0x1234abcd_u32
    frame.error?.should be_falsey
  end

  it "will return an error if the frame is not built correctly" do
    buffer = IO::Memory.new
    error_code = Bytes.new(4, 0)
    IO::ByteFormat::BigEndian.encode(0x1234abcd, error_code)
    buffer.write error_code
    buffer.write_byte 0x00_u8
    frame = HTTP2::Frame::ResetStream.new(0x00_u8, 0x12345678_u32, buffer.to_slice)
    frame.error?.should be_truthy

    buffer.clear
    error_code = Bytes.new(4, 0)
    IO::ByteFormat::BigEndian.encode(0x1234abcd, error_code)
    buffer.write error_code
    frame = HTTP2::Frame::ResetStream.new(0x00_u8, 0x00000000_u32, buffer.to_slice)
    frame.error?.should be_truthy
  end
end
