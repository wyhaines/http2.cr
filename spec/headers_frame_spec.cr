require "./spec_helper"

describe HTTP2::Frame::Headers do
  it "has all expected flags defined" do
    HTTP2::Frame::Headers::Flags.values.includes?(HTTP2::Frame::Headers::Flags::END_STREAM).should be_true
    HTTP2::Frame::Headers::Flags.values.includes?(HTTP2::Frame::Headers::Flags::END_HEADERS).should be_true
    HTTP2::Frame::Headers::Flags.values.includes?(HTTP2::Frame::Headers::Flags::PADDED).should be_true
    HTTP2::Frame::Headers::Flags.values.includes?(HTTP2::Frame::Headers::Flags::PRIORITY).should be_true
    HTTP2::Frame::Headers::Flags.new(0x01_u8).should eq HTTP2::Frame::Headers::Flags::END_STREAM
    HTTP2::Frame::Headers::Flags.new(0x04_u8).should eq HTTP2::Frame::Headers::Flags::END_HEADERS
    HTTP2::Frame::Headers::Flags.new(0x08_u8).should eq HTTP2::Frame::Headers::Flags::PADDED
    HTTP2::Frame::Headers::Flags.new(0x20_u8).should eq HTTP2::Frame::Headers::Flags::PRIORITY
  end

  it "can create a header frame from headers directly" do
    headers = HTTP::Headers{
      ":status"          => "200",
      "cache-control"    => "private",
      "date"             => "Mon, 21 Oct 2013 20:13:22 GMT",
      "location"         => "https://www.example.com",
      "content-encoding" => "gzip",
      "set-cookie"       => "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1",
    }
    frame = HTTP2::Frame::Headers.new(0x00_u8, 0x12345678, headers)
    frame.should be_a(HTTP2::Frame::Headers)
    frame.stream_id.should eq 0x12345678
    frame.flags.should eq HTTP2::Frame::Headers::Flags::None
    frame.headers.should eq headers
  end

  it "can create a header frame with no padding or priority, from hpack encoded headers" do
    headers = HTTP::Headers{
      ":status"          => "200",
      "cache-control"    => "private",
      "date"             => "Mon, 21 Oct 2013 20:13:22 GMT",
      "location"         => "https://www.example.com/other",
      "content-encoding" => "gzip",
      "set-cookie"       => "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1",
    }

    encoder = HPack::Encoder.new(
      indexing: HPack::Indexing::ALWAYS,
      huffman: true)

    frame = HTTP2::Frame::Headers.new(0x00_u8, 0x12345678, encoder.encode(headers))
    frame.stream_id.should eq 0x12345678
    frame.flags.should eq HTTP2::Frame::Headers::Flags::None
    frame.headers.should eq headers
  end

end
