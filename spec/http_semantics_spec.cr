require "./spec_helper"

private def semantic_fields(
  fields : Array(Tuple(String, String)),
) : Array(HTTP2::DecodedHeaderField)
  fields.map do |name, value|
    HTTP2::DecodedHeaderField.new(
      name,
      value,
      HTTP2::DecodedHeaderField::Indexing::None
    )
  end
end

private def semantic_section(
  fields : Array(Tuple(String, String)),
  *,
  end_stream : Bool = false,
) : HTTP2::Connection::FieldSection
  block = HTTP2::Connection::FieldBlock.new(
    HTTP2::Connection::FieldBlock::Kind::Headers,
    1_u32,
    Bytes.empty,
    end_stream: end_stream
  )
  HTTP2::Connection::FieldSection.new(
    block,
    semantic_fields(fields),
    0_u64
  )
end

describe HTTP2::HTTPSemantics do
  it "parses one ordered response status and repeated regular fields" do
    parsed = HTTP2::HTTPSemantics.parse_response_section(
      semantic_fields([
        {":status", "200"},
        {"set-cookie", "a=1"},
        {"set-cookie", "b=2"},
        {"content-length", "5, 5"},
      ]),
      1_u32
    )

    parsed.status.should eq(200)
    parsed.content_length.should eq(5)
    parsed.headers.to_a.should eq([
      HTTP2::Header.new("set-cookie", "a=1"),
      HTTP2::Header.new("set-cookie", "b=2"),
      HTTP2::Header.new("content-length", "5, 5"),
    ])
  end

  it "rejects missing, repeated, misplaced, and contextual pseudo-fields" do
    expect_raises(HTTP2::MalformedResponseError, /missing :status/) do
      HTTP2::HTTPSemantics.parse_response_section(
        semantic_fields([{"x-value", "one"}]),
        1_u32
      )
    end
    expect_raises(HTTP2::MalformedResponseError, /repeated :status/) do
      HTTP2::HTTPSemantics.parse_response_section(
        semantic_fields([
          {":status", "200"},
          {":status", "201"},
        ]),
        1_u32
      )
    end
    expect_raises(HTTP2::MalformedResponseError, /must precede/) do
      HTTP2::HTTPSemantics.parse_response_section(
        semantic_fields([
          {"x-value", "one"},
          {":status", "200"},
        ]),
        1_u32
      )
    end
    expect_raises(HTTP2::MalformedResponseError, /invalid pseudo-field/) do
      HTTP2::HTTPSemantics.parse_response_section(
        semantic_fields([
          {":method", "GET"},
          {":status", "200"},
        ]),
        1_u32
      )
    end
  end

  it "rejects status codes outside the HTTP range" do
    {"099", "600", "999"}.each do |status|
      expect_raises(HTTP2::MalformedResponseError, /valid range/) do
        HTTP2::HTTPSemantics.parse_response_section(
          semantic_fields([{":status", status}]),
          1_u32
        )
      end
    end
  end

  it "rejects invalid names, values, and connection-specific fields" do
    {
      "uppercase" => [
        {":status", "200"},
        {"X-Value", "one"},
      ],
      "token" => [
        {":status", "200"},
        {"bad(name)", "one"},
      ],
      "value" => [
        {":status", "200"},
        {"x-value", " one"},
      ],
      "control value" => [
        {":status", "200"},
        {"x-value", "\u0001"},
      ],
      "connection" => [
        {":status", "200"},
        {"connection", "close"},
      ],
      "te" => [
        {":status", "200"},
        {"te", "trailers"},
      ],
    }.each_value do |fields|
      expect_raises(HTTP2::MalformedResponseError) do
        HTTP2::HTTPSemantics.parse_response_section(
          semantic_fields(fields),
          1_u32
        )
      end
    end
  end

  it "validates content-length syntax and agreement" do
    expect_raises(HTTP2::MalformedResponseError, /conflicting/) do
      HTTP2::HTTPSemantics.parse_response_section(
        semantic_fields([
          {":status", "200"},
          {"content-length", "4"},
          {"content-length", "5"},
        ]),
        1_u32
      )
    end
    expect_raises(HTTP2::MalformedResponseError, /non-negative/) do
      HTTP2::HTTPSemantics.parse_response_section(
        semantic_fields([
          {":status", "200"},
          {"content-length", "-1"},
        ]),
        1_u32
      )
    end
  end

  it "rejects pseudo-fields and framing fields in trailers" do
    expect_raises(HTTP2::MalformedResponseError, /pseudo-fields/) do
      HTTP2::HTTPSemantics.validate_trailers(
        semantic_fields([{":status", "200"}]),
        1_u32
      )
    end
    expect_raises(HTTP2::MalformedResponseError, /content-length/) do
      HTTP2::HTTPSemantics.validate_trailers(
        semantic_fields([{"content-length", "0"}]),
        1_u32
      )
    end
  end
end

describe HTTP2::ResponseValidator do
  it "accepts informational responses and rejects status 101" do
    validator = HTTP2::ResponseValidator.new(1_u32, "GET")
    validator.validate(semantic_section([{":status", "103"}]))
    validator.final_status.should be_nil
    validator.validate(
      semantic_section([{":status", "200"}], end_stream: true)
    )
    validator.final_status.should eq(200)

    invalid = HTTP2::ResponseValidator.new(1_u32, "GET")
    expect_raises(HTTP2::MalformedResponseError, /status 101/) do
      invalid.validate(semantic_section([{":status", "101"}]))
    end
  end

  it "rejects DATA before final response fields" do
    validator = HTTP2::ResponseValidator.new(1_u32, "GET")
    expect_raises(HTTP2::MalformedResponseError, /before a final/) do
      validator.validate_data(0, false)
    end
  end

  it "enforces content-length at DATA and trailer completion" do
    too_long = HTTP2::ResponseValidator.new(1_u32, "GET")
    too_long.validate(
      semantic_section([
        {":status", "200"},
        {"content-length", "2"},
      ])
    )
    expect_raises(HTTP2::MalformedResponseError, /exceeds/) do
      too_long.validate_data(3, false)
    end

    too_short = HTTP2::ResponseValidator.new(1_u32, "GET")
    too_short.validate(
      semantic_section([
        {":status", "200"},
        {"content-length", "3"},
      ])
    )
    too_short.validate_data(2, false)
    expect_raises(HTTP2::MalformedResponseError, /does not match/) do
      too_short.validate(
        semantic_section([{"checksum", "ok"}], end_stream: true)
      )
    end
  end

  it "handles HEAD, 204, and 304 no-content rules" do
    head = HTTP2::ResponseValidator.new(1_u32, "HEAD")
    head.validate(
      semantic_section([
        {":status", "200"},
        {"content-length", "12"},
      ])
    )
    expect_raises(HTTP2::MalformedResponseError, /cannot contain/) do
      head.validate_data(1, true)
    end

    no_content = HTTP2::ResponseValidator.new(1_u32, "GET")
    expect_raises(HTTP2::MalformedResponseError, /204/) do
      no_content.validate(
        semantic_section([
          {":status", "204"},
          {"content-length", "0"},
        ], end_stream: true)
      )
    end

    not_modified = HTTP2::ResponseValidator.new(1_u32, "GET")
    not_modified.validate(
      semantic_section([
        {":status", "304"},
        {"content-length", "12"},
      ], end_stream: true)
    )
  end

  it "ignores content-length for a successful CONNECT tunnel" do
    tunnel = HTTP2::ResponseValidator.new(1_u32, "CONNECT")
    tunnel.validate(
      semantic_section([
        {":status", "204"},
        {"content-length", "999"},
      ])
    )
    tunnel.validate_data(3, true)
    tunnel.received_content_bytes.should eq(3)
  end
end
