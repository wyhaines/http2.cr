require "./spec_helper"

describe HTTP2::Frame::Data do
  it "has all expected flags defined" do
    HTTP2::Frame::Data::Flags.values.includes?(HTTP2::Frame::Data::Flags::PADDED).should be_true
    HTTP2::Frame::Data::Flags.values.includes?(HTTP2::Frame::Data::Flags::END_STREAM).should be_true
    HTTP2::Frame::Data::Flags.new(0x01_u8).should eq HTTP2::Frame::Data::Flags::END_STREAM
    HTTP2::Frame::Data::Flags.new(0x08_u8).should eq HTTP2::Frame::Data::Flags::PADDED
  end

  it "can create a basic data frame" do
    frame = HTTP2::Frame::Data.new(0x08_u8, 0x12345678, "This is a test".to_slice)
    frame.should be_a(HTTP2::Frame::Data)
    frame.type_code.should eq 0x00_u8
  end

  it "can create a data frame with different flag settings" do
    frame = HTTP2::Frame::Data.new(0x00_u8, 0x12345678, "This is a test".to_slice)
    frame.flags.should eq HTTP2::Frame::Data::Flags::None

    frame = HTTP2::Frame::Data.new(0x01_u8, 0x12345678, "This is a test".to_slice)
    frame.flags.should eq HTTP2::Frame::Data::Flags::END_STREAM

    frame = HTTP2::Frame::Data.new(0x08_u8, 0x12345678, "\x00This is a test".to_slice)
    frame.flags.should eq HTTP2::Frame::Data::Flags::PADDED

    frame = HTTP2::Frame::Data.new(0x09_u8, 0x12345678, "\x00This is a test".to_slice)
    frame.flags.should eq HTTP2::Frame::Data::Flags::PADDED | HTTP2::Frame::Data::Flags::END_STREAM
  end

  it "pad_length can return the expected padding lengths" do
    frame = HTTP2::Frame::Data.new(0x08_u8, 0x12345678, "\x01This is a test".to_slice)
    frame.pad_length.should eq 1

    frame = HTTP2::Frame::Data.new(0x09_u8, 0x12345678, "\x0aThis is a test".to_slice)
    frame.pad_length.should eq 10

    frame = HTTP2::Frame::Data.new(0x08_u8, 0x12345678, "\x10This is a test".to_slice)
    frame.pad_length.should eq 16

    frame = HTTP2::Frame::Data.new(0x08_u8, 0x12345678, "\x22This is a test".to_slice)
    frame.pad_length.should eq 34
  end

  it "can get all parts of an unpadded data frame" do
    frame = HTTP2::Frame::Data.new(0x00_u8, 0x12345678, "This is a test".to_slice)
    frame.stream_id.should eq 0x12345678
    frame.data.should eq "This is a test".to_slice
    frame.pad_length.should eq 0
    frame.padding.should be_nil
  end

  it "can get all parts of a padded data frame with no padding" do
    frame = HTTP2::Frame::Data.new(0x08_u8, 0x12345678, "\x00This is a test".to_slice)
    frame.stream_id.should eq 0x12345678
    frame.data.should eq "This is a test".to_slice
    frame.pad_length.should eq 0
    frame.padding.should eq ""
  end

  it "can get all parts of a padded data frame with padding" do
    frame = HTTP2::Frame::Data.new(0x09_u8, 0x12345678, "\x03This is a test\x00\x00\x00".to_slice)
    frame.stream_id.should eq 0x12345678
    frame.pad_length.should eq 3
    frame.data.should eq "This is a test".to_slice
    frame.padding.should eq "\x00\x00\x00".to_slice
  end
end
