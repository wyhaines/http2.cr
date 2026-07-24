require "./spec_helper"

private PROPERTY_CASES      = (ENV["HTTP2_PROPERTY_CASES"]? || "500").to_i
private FRAME_FUZZ_SEED     = 0x4854_5450_3201_u64
private HPACK_FRAGMENT_SEED = 0x4850_4143_4b01_u64

raise ArgumentError.new("HTTP2_PROPERTY_CASES must be positive") if PROPERTY_CASES <= 0

private def property_bytes(random : Random, size : Int32) : Bytes
  Bytes.new(size) { random.rand(0..255).to_u8 }
end

private def property_string(random : Random, size : Int32) : String
  String.build(size) do |io|
    size.times do
      io.write_byte(random.rand('a'.ord..'z'.ord).to_u8)
    end
  end
end

describe "frame parser properties" do
  it "parses or reports a typed violation for bounded arbitrary frames" do
    random = Random.new(FRAME_FUZZ_SEED)

    PROPERTY_CASES.times do |index|
      payload = property_bytes(random, random.rand(0..256))
      bytes = wire_frame(
        random.rand(0..255).to_u8,
        random.rand(0..255).to_u8,
        random.rand(0_u32..HTTP2::FrameHeader::MAX_STREAM_ID),
        payload
      )

      begin
        parsed = HTTP2::Frame.read(IO::Memory.new(bytes))
        reparsed = HTTP2::Frame.read(IO::Memory.new(parsed.to_slice))

        reparsed.class.should eq(parsed.class)
        reparsed.to_slice.should eq(parsed.to_slice)
      rescue HTTP2::ProtocolError
        # Arbitrary standard-frame payloads are commonly invalid. The
        # important property is that rejection remains typed and bounded.
      rescue error
        fail(
          "frame fuzz case #{index} raised #{error.class}: #{error.message}"
        )
      end
    end
  end

  it "rejects every randomized truncation with EOF" do
    random = Random.new(FRAME_FUZZ_SEED ^ 0xffff_u64)

    PROPERTY_CASES.times do
      payload = property_bytes(random, random.rand(0..256))
      bytes = wire_frame(
        0xf0_u8,
        random.rand(0..255).to_u8,
        random.rand(0_u32..HTTP2::FrameHeader::MAX_STREAM_ID),
        payload
      )
      cut = random.rand(0...bytes.size)

      expect_raises(IO::EOFError) do
        HTTP2::Frame.read(IO::Memory.new(bytes[0, cut]))
      end
    end
  end
end

describe "HPACK field-block fragmentation properties" do
  it "preserves ordered fields across randomized fragmentation boundaries" do
    random = Random.new(HPACK_FRAGMENT_SEED)
    encoder = HPack::Encoder.new(HPack::Indexing::ALWAYS, true)
    decoder = HPack::Decoder.new

    PROPERTY_CASES.times do |index|
      fields = Array(Tuple(String, String)).new
      random.rand(1..10).times do
        name = "x-property-#{random.rand(0..15)}"
        value = "value-#{random.rand(0..31)}-" +
                property_string(random, random.rand(0..48))
        fields << {name, value}
      end

      encoded = encoder.encode(
        fields,
        HPack::Indexing::ALWAYS,
        index.even?
      )
      fragment_size = random.rand(1..17)
      frames = HTTP2::Connection::HeaderBlockFramer.frames(
        1_u32,
        encoded,
        fragment_size,
        end_stream: index.odd?
      )
      assembler = HTTP2::Connection::FieldBlockAssembler.new(
        encoded.size,
        encoded.size
      )
      block = nil.as(HTTP2::Connection::FieldBlock?)

      frames.each do |frame|
        if result = assembler.process(frame)
          block = result.as?(HTTP2::Connection::FieldBlock)
        end
      end

      completed = block || fail("fragmentation case #{index} did not finish")
      completed.encoded.should eq(encoded)
      completed.end_stream?.should eq(index.odd?)
      decoded = decoder.decode_with_metadata(completed.encoded)[:fields]
      decoded.map { |field| {field.name, field.value} }.should eq(fields)
    end
  end
end
