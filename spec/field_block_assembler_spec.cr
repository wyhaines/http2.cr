require "./spec_helper"

private alias FieldBlock = HTTP2::Connection::FieldBlock
private alias FieldBlockAssembler = HTTP2::Connection::FieldBlockAssembler

describe FieldBlockAssembler do
  it "completes a single HEADERS field block" do
    assembler = FieldBlockAssembler.new(16, 2)
    headers = HTTP2::Frame::Headers.new(
      HTTP2::Frame::Headers::Flags::END_HEADERS |
      HTTP2::Frame::Headers::Flags::END_STREAM,
      1_u32,
      Bytes[0x82, 0x86]
    )

    block = assembler.process(headers).as(FieldBlock)
    block.kind.headers?.should be_true
    block.stream_id.should eq(1_u32)
    block.encoded.should eq(Bytes[0x82, 0x86])
    block.end_stream?.should be_true
    block.continuation_count.should eq(0)
    assembler.pending?.should be_false
  end

  it "concatenates contiguous CONTINUATION fragments" do
    assembler = FieldBlockAssembler.new(16, 2)
    headers = HTTP2::Frame::Headers.new(
      0_u8,
      3_u32,
      Bytes[1, 2]
    )
    first = HTTP2::Frame::Continuation.new(0_u8, 3_u32, Bytes[3])
    last = HTTP2::Frame::Continuation.new(
      HTTP2::Frame::Continuation::Flags::END_HEADERS,
      3_u32,
      Bytes[4, 5]
    )

    assembler.process(headers).should be_nil
    assembler.pending?.should be_true
    assembler.process(first).should be_nil
    block = assembler.process(last).as(FieldBlock)

    block.encoded.should eq(Bytes[1, 2, 3, 4, 5])
    block.continuation_count.should eq(2)
    assembler.pending?.should be_false
  end

  it "preserves PUSH_PROMISE metadata" do
    assembler = FieldBlockAssembler.new(16, 1)
    promise = HTTP2::Frame::PushPromise.new(
      HTTP2::Frame::PushPromise::Flags::END_HEADERS,
      1_u32,
      2_u32,
      Bytes[0x82]
    )

    block = assembler.process(promise).as(FieldBlock)
    block.kind.push_promise?.should be_true
    block.stream_id.should eq(1_u32)
    block.promised_stream_id.should eq(2_u32)
    block.end_stream?.should be_false
  end

  it "rejects orphaned, interleaved, and wrong-stream continuations" do
    expect_raises(HTTP2::ProtocolError) do
      FieldBlockAssembler.new(16, 1).process(
        HTTP2::Frame::Continuation.new(
          HTTP2::Frame::Continuation::Flags::END_HEADERS,
          1_u32,
          Bytes.empty
        )
      )
    end

    [
      HTTP2::Frame::Ping.new(0_u8, 0_u32),
      HTTP2::Frame::Continuation.new(
        HTTP2::Frame::Continuation::Flags::END_HEADERS,
        3_u32,
        Bytes.empty
      ),
    ].each do |interleaved|
      assembler = FieldBlockAssembler.new(16, 1)
      assembler.process(
        HTTP2::Frame::Headers.new(0_u8, 1_u32, Bytes[1])
      )
      expect_raises(HTTP2::ProtocolError) do
        assembler.process(interleaved)
      end
    end
  end

  it "enforces compressed size and CONTINUATION count limits" do
    exact = FieldBlockAssembler.new(3, 1)
    exact.process(
      HTTP2::Frame::Headers.new(0_u8, 1_u32, Bytes[1, 2])
    )
    exact.process(
      HTTP2::Frame::Continuation.new(
        HTTP2::Frame::Continuation::Flags::END_HEADERS,
        1_u32,
        Bytes[3]
      )
    ).as(FieldBlock).encoded.should eq(Bytes[1, 2, 3])

    oversized = FieldBlockAssembler.new(2, 1)
    oversized.process(
      HTTP2::Frame::Headers.new(0_u8, 1_u32, Bytes[1, 2])
    )
    error = expect_raises(HTTP2::Connection::ResourceLimitError) do
      oversized.process(
        HTTP2::Frame::Continuation.new(
          HTTP2::Frame::Continuation::Flags::END_HEADERS,
          1_u32,
          Bytes[3]
        )
      )
    end
    error.error_code.should eq(HTTP2::ErrorCode::ENHANCE_YOUR_CALM)

    too_many = FieldBlockAssembler.new(16, 1)
    too_many.process(
      HTTP2::Frame::Headers.new(0_u8, 1_u32, Bytes.empty)
    )
    too_many.process(
      HTTP2::Frame::Continuation.new(0_u8, 1_u32, Bytes.empty)
    )
    expect_raises(HTTP2::Connection::ResourceLimitError) do
      too_many.process(
        HTTP2::Frame::Continuation.new(
          HTTP2::Frame::Continuation::Flags::END_HEADERS,
          1_u32,
          Bytes.empty
        )
      )
    end
  end
end
