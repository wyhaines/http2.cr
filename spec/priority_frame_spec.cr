require "./spec_helper"

describe HTTP2::Frame::Priority do
  it "can create a Priority frame" do
    buffer = IO::Memory.new
    e_and_dependency = Bytes.new(4, 0)
    IO::ByteFormat::BigEndian.encode(0x1234abcd, e_and_dependency)
    # Set the E bit.
    e_and_dependency[0] = e_and_dependency[0] | 0b10000000
    buffer.write e_and_dependency
    buffer.write_byte 0x64_u8
    frame = HTTP2::Frame::Priority.new(0x00_u8, 0x12345678_u32, buffer.to_slice)
    frame.type_code.should eq 0x02_u8
    frame.exclusive?.should be_true
    frame.stream_id.should eq 0x12345678_u32
  end
end