require "./spec_helper"

describe HTTP2::Frame::WindowUpdate do
  it "can create a WindowUpdate frame" do
    frame = HTTP2::Frame::WindowUpdate.new(
      stream_id: 0x12345678_u32
    )
    frame.stream_id.should eq 0x12345678_u32
    frame.type_code.should eq 0x08_u8
    frame.flags.should eq HTTP2::Frame::Flags::None
    frame.window_size_increment.should eq 0x00_u32
  end
end
