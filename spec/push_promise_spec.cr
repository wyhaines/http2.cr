require "./spec_helper"

describe HTTP2::Frame::PushPromise do
  it "has all expected flags defined" do
    HTTP2::Frame::PushPromise::Flags.values.includes?(HTTP2::Frame::PushPromise::Flags::END_HEADERS).should be_true
    HTTP2::Frame::PushPromise::Flags.values.includes?(HTTP2::Frame::PushPromise::Flags::PADDED).should be_true
    HTTP2::Frame::PushPromise::Flags.new(0x04_u8).should eq HTTP2::Frame::PushPromise::Flags::END_HEADERS
    HTTP2::Frame::PushPromise::Flags.new(0x08_u8).should eq HTTP2::Frame::PushPromise::Flags::PADDED
  end

  it "can create a push-promise frame with no extra headaers" do
    frame = HTTP2::Frame::PushPromise.new(
      flags: HTTP2::Frame::PushPromise::Flags::END_HEADERS,
      stream_id: 0x12345678_u32,
      promised_stream_id: 0x23456789_u32)
    frame.type_code.should eq 0x05
    frame.should be_a(HTTP2::Frame::PushPromise)
    frame.stream_id.should eq 0x12345678
    frame.flags.should eq HTTP2::Frame::PushPromise::Flags::END_HEADERS
    frame.promised_stream_id.should eq 0x23456789
    frame.headers.should eq HTTP::Headers.new
  end

  it "can create a push-promise frame with headers" do
    headers = HTTP::Headers{
      "x-extra-header" => "extra-value",
    }
    frame = HTTP2::Frame::PushPromise.new(
      flags: HTTP2::Frame::PushPromise::Flags::END_HEADERS,
      stream_id: 0x12345678_u32,
      promised_stream_id: 0x23456789_u32,
      headers: headers)
    frame.type_code.should eq 0x05
    frame.should be_a(HTTP2::Frame::PushPromise)
    frame.stream_id.should eq 0x12345678
    frame.flags.should eq HTTP2::Frame::PushPromise::Flags::END_HEADERS
    frame.promised_stream_id.should eq 0x23456789
    frame.headers.should eq headers
  end

  it "can create a push-promise frame with headers and padding" do
    headers = HTTP::Headers{
      "x-extra-header" => "extra-value",
    }
    frame = HTTP2::Frame::PushPromise.new(
      flags: HTTP2::Frame::PushPromise::Flags::END_HEADERS | HTTP2::Frame::PushPromise::Flags::PADDED,
      stream_id: 0x12345678_u32,
      promised_stream_id: 0x23456789_u32,
      headers: headers)
    frame.type_code.should eq 0x05
    frame.should be_a(HTTP2::Frame::PushPromise)
    frame.stream_id.should eq 0x12345678
    frame.flags.should eq HTTP2::Frame::PushPromise::Flags::END_HEADERS | HTTP2::Frame::PushPromise::Flags::PADDED
    frame.promised_stream_id.should eq 0x23456789
    frame.headers.should eq headers
    frame.pad_length.should be >= 0
    frame.padding.size.should eq frame.pad_length
  end
end
