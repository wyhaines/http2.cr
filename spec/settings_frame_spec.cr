require "./spec_helper"

describe HTTP2::Frame::Settings do
  it "has all expected flags defined" do
    HTTP2::Frame::Settings::Flags.values.includes?(HTTP2::Frame::Settings::Flags::ACK).should be_true
    HTTP2::Frame::Settings::Flags.new(0x01_u8).should eq HTTP2::Frame::Settings::Flags::ACK
  end

  it "can build a Settings frame with the basic constructor" do
    buffer = IO::Memory.new
    phash = HTTP2::Frame::Settings::ParameterHash{
      HTTP2::Frame::Settings::Parameters::HEADER_TABLE_SIZE => 0x00008000,
      HTTP2::Frame::Settings::Parameters::ENABLE_PUSH       => 0x00000001,
    }
    phash.each do |key, value|
      buffer.write_bytes key.to_u16, IO::ByteFormat::BigEndian
      buffer.write_bytes value.to_u32, IO::ByteFormat::BigEndian
    end
    frame = HTTP2::Frame::Settings.new(0x00_u8, 0x00_u32, buffer.to_slice)
    frame.stream.should eq 0x00_u32
    frame.payload.should eq buffer.to_slice
    frame.ack?.should be_false
    frame.parameters.should eq phash
  end

  it "can build a Settings frame with the #from_parameters alternative constructor" do
    phash = HTTP2::Frame::Settings::ParameterHash{
      HTTP2::Frame::Settings::Parameters::HEADER_TABLE_SIZE => 0x00008000,
      HTTP2::Frame::Settings::Parameters::ENABLE_PUSH       => 0x00000001,
    }
    frame = HTTP2::Frame::Settings.new(0x00_u32, phash)
    frame.stream.should eq 0x00_u32
    frame.parameters.should eq phash
  end

  it "can generate a correct Settings:ACK frame from a parameterized Settings frame" do
    frame = HTTP2::Frame::Settings.new(
      stream_id: 0x00_u32,
      parameters: HTTP2::Frame::Settings::ParameterHash{
        HTTP2::Frame::Settings::Parameters::HEADER_TABLE_SIZE => 0x00008000,
        HTTP2::Frame::Settings::Parameters::ENABLE_PUSH       => 0x00000001,
      })
    frame.ack?.should be_false
    ack = frame.ack
    ack.ack?.should be_true
    ack.stream.should eq frame.stream
  end
end
