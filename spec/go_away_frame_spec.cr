require "./spec_helper"

describe HTTP2::Frame::GoAway do
  it "can create a minimal GoAway frame" do
    frame = HTTP2::Frame::GoAway.new
    frame.stream_id.should eq 0x00_u32
    frame.data.should eq Bytes.empty
    frame.last_stream_id.should eq 0x00
    frame.error_code.should eq 0x00
    frame.error?.should be_falsey
  end

  it "can create a GoAway frame with data" do
    frame = HTTP2::Frame::GoAway.new(
      last_stream_id: 0x12345678_u32,
      error_code: 0x12345678_u32,
      optional_debug_data: "foo".to_slice)
    frame.stream_id.should eq 0x00
    frame.data.should eq "foo".to_slice
    frame.last_stream_id.should eq 0x12345678
    frame.error_code.should eq 0x12345678
    frame.error?.should be_falsey
  end

  it "can create a GoAway frame with a string as data" do
    frame = HTTP2::Frame::GoAway.new(
      last_stream_id: 0x12345678_u32,
      error_code: 0x12345678_u32,
      optional_debug_data: "foo")
    frame.stream_id.should eq 0x00
    frame.data.should eq "foo".to_slice
    frame.last_stream_id.should eq 0x12345678
    frame.error_code.should eq 0x12345678
    frame.error?.should be_falsey
  end
end
