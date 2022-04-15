require "./spec_helper"

# Crystal code to test the HTTP/2 Request/Response class.
describe HTTP2::Request do
  it "can create an HTTP/2 GET request" do
    req = HTTP2::Request.new(headers: HTTP::Headers{
      ":method"    => "GET",
      ":scheme"    => "https",
      ":authority" => "www.example.com",
      ":path"      => "/index.html",
    })
    req.method.should eq "GET"
    req.scheme.should eq "https"
    req.authority.should eq "www.example.com"
    req.path.should eq "/index.html"
  end

  it "can create an HTTP/2 POST request" do
    body = "This is just some content."
    req = HTTP2::Request.new(headers: HTTP::Headers{
      ":method"        => "POST",
      ":scheme"        => "https",
      ":authority"     => "www.example.com",
      ":path"          => "/index.html",
      "content-length" => body.bytesize.to_s,
    }, body: body)
    req.method.should eq "POST"
    req.scheme.should eq "https"
    req.authority.should eq "www.example.com"
    req.path.should eq "/index.html"
    req.body.not_nil!.rewind.gets_to_end.should eq body
    req.headers["content-length"].should eq body.bytesize.to_s
  end
end
