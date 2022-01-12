require "./spec_helper"

describe HTTP2::Frame::Continuation do
  it "can build a basic continuation frame" do
    headers = HTTP::Headers{
      ":status"          => "200",
      "cache-control"    => "private",
      "date"             => "Mon, 21 Oct 2013 20:13:22 GMT",
      "location"         => "https://www.example.com/padded",
      "content-encoding" => "gzip",
      "set-cookie"       => "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1",
    }

    encoder = HPack::Encoder.new(
      indexing: HPack::Indexing::ALWAYS,
      huffman: true)

    frame = HTTP2::Frame::Continuation.new(
      flags: HTTP2::Frame::Continuation::Flags::None,
      stream_id: 0x12345678_u32,
      headers: headers,
      encoder: encoder)
    frame.type_code.should eq 0x09_u8
    frame.flags.should eq HTTP2::Frame::Continuation::Flags::None
    frame.stream_id.should eq 0x12345678_u32
    frame.headers.should eq headers
    frame.error?.should be_falsey
  end

  it "can build an end-headers continuation frame" do
    headers = HTTP::Headers{
      ":status"          => "200",
      "cache-control"    => "private",
      "date"             => "Mon, 21 Oct 2013 20:13:22 GMT",
      "location"         => "https://www.example.com/padded",
      "content-encoding" => "gzip",
      "set-cookie"       => "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1",
    }

    encoder = HPack::Encoder.new(
      indexing: HPack::Indexing::ALWAYS,
      huffman: true)

    frame = HTTP2::Frame::Continuation.new(
      flags: HTTP2::Frame::Continuation::Flags::END_HEADERS,
      stream_id: 0x12345678_u32,
      headers: headers,
      encoder: encoder)
    frame.type_code.should eq 0x09_u8
    frame.flags.should eq HTTP2::Frame::Continuation::Flags::END_HEADERS
    frame.stream_id.should eq 0x12345678_u32
    frame.headers.should eq headers
    frame.error?.should be_falsey
  end

  it "properly flags a frame with a stream_id of zero as being in an error state" do
    headers = HTTP::Headers{
      ":status"          => "200",
      "cache-control"    => "private",
      "date"             => "Mon, 21 Oct 2013 20:13:22 GMT",
      "location"         => "https://www.example.com/padded",
      "content-encoding" => "gzip",
      "set-cookie"       => "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1",
    }

    encoder = HPack::Encoder.new(
      indexing: HPack::Indexing::ALWAYS,
      huffman: true)

    frame = HTTP2::Frame::Continuation.new(
      flags: HTTP2::Frame::Continuation::Flags::None,
      stream_id: 0x0_u32,
      headers: headers,
      encoder: encoder)
    frame.type_code.should eq 0x09_u8
    frame.flags.should eq HTTP2::Frame::Continuation::Flags::None
    frame.stream_id.should eq 0x0_u32
    frame.headers.should eq headers
    frame.error?.should be_truthy
  end
end