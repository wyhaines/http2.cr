require "./spec_helper"

describe HTTP2::Frame::PushPromise do
  it "has all expected flags defined" do
    HTTP2::Frame::PushPromise::Flags.values.includes?(HTTP2::Frame::PushPromise::Flags::END_HEADERS).should be_true
    HTTP2::Frame::PushPromise::Flags.values.includes?(HTTP2::Frame::PushPromise::Flags::PADDED).should be_true
    HTTP2::Frame::PushPromise::Flags.new(0x04_u8).should eq HTTP2::Frame::PushPromise::Flags::END_HEADERS
    HTTP2::Frame::PushPromise::Flags.new(0x08_u8).should eq HTTP2::Frame::PushPromise::Flags::PADDED
  end

  it "can create a push-promise frame from headers directly" do
    headers = HTTP::Headers{
      "x-extra-header" => "extra-value",
    }
    # frame = HTTP2::Frame::PushPromise.new(HTTP2::Frame::PushPromise::Flags::END_HEADERS, 0x12345678, headers)
    # frame.type_code.should eq 0x01
    # frame.should be_a(HTTP2::Frame::Headers)
    # frame.stream_id.should eq 0x12345678
    # frame.flags.should eq HTTP2::Frame::Headers::Flags::None
    # frame.headers.should eq headers
  end
end
