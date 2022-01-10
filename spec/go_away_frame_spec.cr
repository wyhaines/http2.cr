require "./spec_helper"

describe HTTP2::Frame::GoAway do
  it "can create a minimal GoAway frame" do
    frame = HTTP2::Frame::GoAway.new(0x12345678_u32)
    frame.stream_id.should eq 0x12345678
    frame.data.should eq Bytes.empty
    frame.last_stream_id.should eq 0x00
    frame.error_code.should eq 0x00
  end
end