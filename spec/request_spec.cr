require "./spec_helper"

describe HTTP2::Request do
  it "retains method, target, and ordered regular fields" do
    headers = HTTP2::Headers.new
      .add("accept", "text/plain")
      .add("x-value", "one")
      .add("x-value", "two")
    request = HTTP2::Request.new("GET", "/index.html", headers)

    request.method.should eq("GET")
    request.target.should eq("/index.html")
    request.headers.to_a.should eq([
      HTTP2::Header.new("accept", "text/plain"),
      HTTP2::Header.new("x-value", "one"),
      HTTP2::Header.new("x-value", "two"),
    ])
    request.body.should be_nil
    request.body_length.should eq(0)
  end

  it "owns buffer bodies and records their known length" do
    source = Bytes[1, 2, 3]
    request = HTTP2::Request.new("POST", "/upload", body: source)
    source[0] = 9

    request.body_length.should eq(3)
    if body = request.body
      body.gets_to_end.to_slice.should eq(Bytes[1, 2, 3])
    else
      fail("expected an owned request body")
    end
  end

  it "reproduces owned bodies but not caller-owned IO bodies" do
    owned = HTTP2::Request.new("POST", "/", body: "repeat")
    owned.replayable_body?.should be_true
    owned.body_for_attempt.try(&.gets_to_end).should eq("repeat")
    owned.body_for_attempt.try(&.gets_to_end).should eq("repeat")

    streamed = HTTP2::Request.new(
      "POST",
      "/",
      body: IO::Memory.new("once")
    )
    streamed.replayable_body?.should be_false
    streamed.body_for_attempt.should be(streamed.body)
  end

  it "accepts standard headers while preserving repeated values" do
    headers = HTTP::Headers.new
    headers.add("x-value", "one")
    headers.add("x-value", "two")

    request = HTTP2::Request.new("GET", "/", headers)
    request.headers.get_all("x-value").should eq(["one", "two"])
  end
end
