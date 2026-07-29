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
    request.body_length.should be_nil
  end

  it "reports nil body_length for nil bodies" do
    HTTP2::Request.new("GET", "/").body_length.should be_nil
  end

  it "does not copy string bodies" do
    s = "x" * 1024
    request = HTTP2::Request.new("POST", "/u", body: s)
    request.body_length.should eq 1024
    # Same backing memory as the string -- no dup:
    request.owned_body.not_nil!.to_unsafe.should eq s.to_slice.to_unsafe
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

describe HTTP2::Headers do
  it "downcases field names converted from HTTP::Headers, preserving order, duplicates, and values" do
    source = HTTP::Headers.new
    source.add("Content-Type", "text/plain")
    source.add("X-Value", "One")
    source.add("X-Value", "Two")

    headers = HTTP2::Headers.new(source)

    headers.to_a.should eq([
      HTTP2::Header.new("content-type", "text/plain"),
      HTTP2::Header.new("x-value", "One"),
      HTTP2::Header.new("x-value", "Two"),
    ])
  end

  it "selects the never-index wire marker for sensitive fields by their downcased interop name" do
    # RFC 7541 §6.2.3: a literal never-indexed representation is a wire
    # marker forwarding intermediaries must preserve and must never promote
    # to an indexed form; RFC 7541 §6.2.2 (`Indexing::None`) carries no such
    # guarantee. This pins that *selection* surviving interop casing. It is
    # a real confidentiality boundary, not a wire-marker nicety: ordinary
    # fields from `to_header_fields` carry `Indexing::Incremental` and are
    # eligible for HPACK dynamic-table insertion (Task 9), so authorization,
    # proxy-authorization, cookie, and set-cookie must always take the
    # never-indexed path instead, regardless of interop casing.
    sensitive = HTTP2::Headers.new(HTTP::Headers{
      "Authorization"       => "secret",
      "Proxy-Authorization" => "also-secret",
      "Cookie"              => "session=abc",
      "Set-Cookie"          => "session=abc",
    }).to_header_fields
    sensitive.map(&.indexing).should eq([
      HTTP2::HeaderField::Indexing::Never,
      HTTP2::HeaderField::Indexing::Never,
      HTTP2::HeaderField::Indexing::Never,
      HTTP2::HeaderField::Indexing::Never,
    ])

    ordinary = HTTP2::Headers.new(HTTP::Headers{"Content-Type" => "text/plain"})
      .to_header_fields.first
    ordinary.indexing.should eq(HTTP2::HeaderField::Indexing::Incremental)
  end

  it "still selects Never for a mixed-case credential, across every Headers construction path" do
    # Task 9 review, Finding 1: `to_header_fields`'s case-sensitive
    # `case field.name` never matched a credential whose name arrived
    # differently cased than the sensitive-name literals -- e.g.
    # `Headers.new.add("Authorization", ...)` stored the name verbatim
    # (only the `HTTP::Headers` conversion constructor downcased), so
    # `Indexing::Incremental` was selected instead of `Never`, and a
    # mixed-case credential sent through the low-level `to_header_fields`
    # + `Stream#send_headers` path (bypassing `Client`'s own request
    # validation, which happens to reject uppercase field names first)
    # reached the peer's HPACK dynamic table.
    #
    # Fix-round adjudication: `Headers`' mutators (`#add`, `#[]=`, the
    # tuple constructor) deliberately do NOT normalize casing on
    # insertion -- that native-path strictness is a separate, earlier
    # reviewed design decision, unrelated to this boundary. Instead
    # `to_header_fields` itself downcases defensively before comparing,
    # making it the library's one and only normalization point for this
    # decision: correct standing alone, regardless of how a field's name
    # reached `@fields`. This spec pins exactly that -- every
    # construction path below preserves the caller's original mixed-case
    # name (nothing upstream of `to_header_fields` normalizes it) yet
    # still selects `Never`.
    added = HTTP2::Headers.new.add("Authorization", "secret")
      .to_header_fields.first
    added.indexing.should eq(HTTP2::HeaderField::Indexing::Never)

    assigned_headers = HTTP2::Headers.new
    assigned_headers["Authorization"] = "secret"
    assigned = assigned_headers.to_header_fields.first
    assigned.indexing.should eq(HTTP2::HeaderField::Indexing::Never)

    tupled = HTTP2::Headers.new([{"Authorization", "secret"}])
      .to_header_fields.first
    tupled.indexing.should eq(HTTP2::HeaderField::Indexing::Never)

    # The rawest construction path -- a caller-built Header array via
    # `initialize(fields : Enumerable(Header))` -- was never in scope for
    # any normalization fix (it has exactly one real caller, `#dup`).
    # Passing here confirms the never-index boundary stands entirely on
    # `to_header_fields`'s own downcase, not on any upstream cooperation.
    raw = HTTP2::Headers.new([HTTP2::Header.new("Authorization", "secret")])
      .to_header_fields.first
    raw.indexing.should eq(HTTP2::HeaderField::Indexing::Never)

    # Near-misses stay ordinary (Incremental) -- the fix must not overmatch.
    HTTP2::Headers.new.add("Authorization-Foo", "x")
      .to_header_fields.first.indexing
      .should eq(HTTP2::HeaderField::Indexing::Incremental)
  end
end
