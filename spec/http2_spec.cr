require "./spec_helper"

describe HTTP2::Connection do
  it "Can create a connection to an HTTP2 server" do
    conn = HTTP2::Connection.new("www.nghttp2.org", "80")
    conn.should be_a HTTP2::Connection
  end

  it "can create a spec-client (which enables many of the other specs)" do
    client = HTTP2::Client.new(TCPSocket.new("www.nghttp2.org", 80)) do |connection, stream, frame|
      if frame.is_a?(HTTP2::Frame::Settings)
        pp frame.parameters
      end
    end
    client.should be_a HTTP2::Client
    pp client.get("/httpbin/")
    sleep 1
  end
end

describe HTTP2::Stream do
end
