require "./spec_helper"

describe HTTP2::Frame::Ping do
  it "has all expected flags defined" do
    HTTP2::Frame::Ping::Flags.values.includes?(HTTP2::Frame::Ping::Flags::ACK).should be_true
    HTTP2::Frame::Ping::Flags.new(0x01_u8).should eq HTTP2::Frame::Ping::Flags::ACK
  end
end
