require "./spec_helper"
require "http/headers"

describe HTTP::Headers do
  it "can serialize itself to an IO" do
    headers = HTTP::Headers{
      ":status"          => "200",
      "cache-control"    => "private",
      "date"             => "Mon, 21 Oct 2013 20:13:22 GMT",
      "location"         => "https://www.example.com",
      "content-encoding" => "gzip",
      "set-cookie"       => "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1",
    }

    io = IO::Memory.new
    headers.serialize(io)

    io.to_s.should eq ":status: 200\r\n" \
                      "cache-control: private\r\n" \
                      "date: Mon, 21 Oct 2013 20:13:22 GMT\r\n" \
                      "location: https://www.example.com\r\n" \
                      "content-encoding: gzip\r\n" \
                      "set-cookie: foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1\r\n" \
                      "\r\n"

    io.clear
    headers.serialize(io).to_s.should eq ":status: 200\r\n" \
                                         "cache-control: private\r\n" \
                                         "date: Mon, 21 Oct 2013 20:13:22 GMT\r\n" \
                                         "location: https://www.example.com\r\n" \
                                         "content-encoding: gzip\r\n" \
                                         "set-cookie: foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1\r\n" \
                                         "\r\n"
  end
end
