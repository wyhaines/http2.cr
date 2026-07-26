require "./spec_helper"

private def read_header_sequence(
  io : IO,
  max_frame_size : Int = HTTP2::FrameHeader::DEFAULT_MAX_PAYLOAD,
)
  frames = [] of HTTP2::Frames
  output = IO::Memory.new
  first = HTTP2::Frame.read(io, max_frame_size).as(HTTP2::Frame::Headers)
  frames << first
  output.write(first.header_block_fragment)

  finished = first.end_headers?
  until finished
    continuation = HTTP2::Frame
      .read(io, max_frame_size)
      .as(HTTP2::Frame::Continuation)
    frames << continuation
    output.write(continuation.header_block_fragment)
    finished = continuation.end_headers?
  end

  {encoded: output.to_slice.dup, frames: frames}
end

describe HTTP2::Connection do
  it "rejects raw outbound field-block frames" do
    connection = HTTP2::Connection.new(IO::Memory.new)
    expect_raises(ArgumentError, /send_headers/) do
      connection.write_frame(
        HTTP2::Frame::Headers.new(
          HTTP2::Frame::Headers::Flags::END_HEADERS,
          1_u32,
          Bytes.empty
        )
      )
    end
    expect_raises(ArgumentError, /send_headers/) do
      connection.write_batch([
        HTTP2::Frame::Continuation.new(
          HTTP2::Frame::Continuation::Flags::END_HEADERS,
          1_u32,
          Bytes.empty
        ),
      ] of HTTP2::Frames)
    end
  end

  it "encodes ordered fields with one persistent HPACK context" do
    UNIXSocket.pair do |client, peer|
      stream_id = Channel(UInt32).new(1)
      observed = Channel(Tuple(Int32, Int32)).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        stream_id.receive
        decoder = HPack::Decoder.new

        first = read_header_sequence(io)
        first_fields = decoder.decode_with_metadata(first[:encoded])[:fields]
        first_fields.map { |field| {field.name, field.value} }.should eq([
          {"x-dynamic", "value"},
        ])

        second = read_header_sequence(io)
        second_fields = decoder.decode_with_metadata(second[:encoded])[:fields]
        second_fields.map { |field| {field.name, field.value} }.should eq([
          {"x-dynamic", "value"},
        ])
        observed.send({first[:encoded].size, second[:encoded].size})
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        stream = connection.new_stream
        stream_id.send(stream.id)
        field = HTTP2::HeaderField.new(
          "x-dynamic",
          "value",
          indexing: HTTP2::HeaderField::Indexing::Incremental,
          huffman: HTTP2::HeaderField::Huffman::Never
        )

        stream.send_headers([field])
        stream.send_headers([field])

        first_size, second_size = observed.receive
        second_size.should be < first_size
        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end

  it "gives to_header_fields ordinary fields incremental indexing, so a repeated field compresses and decodes as an indexed reference" do
    UNIXSocket.pair do |client, peer|
      ready = Channel(Nil).new(1)
      observed = Channel(Tuple(Int32, Int32)).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        ready.receive
        decoder = HPack::Decoder.new

        first = read_header_sequence(io)
        first_fields = decoder.decode_with_metadata(first[:encoded])[:fields]
        first_fields.map { |field| {field.name, field.value} }.should eq([
          {"x-session", "abc123"},
        ])
        # First appearance: a literal representation that ALSO performs
        # dynamic-table insertion (RFC 7541 6.2.1), not a bare literal —
        # proof the field was actually filed away, not merely encoded.
        first_fields.first.indexing.should eq(HPack::Indexing::ALWAYS)
        decoder.table.includes?({"x-session", "abc123"}).should be_true

        second = read_header_sequence(io)
        second_fields = decoder.decode_with_metadata(second[:encoded])[:fields]
        second_fields.map { |field| {field.name, field.value} }.should eq([
          {"x-session", "abc123"},
        ])
        # Second appearance: a pure indexed reference (RFC 7541 6.1). This
        # only decodes to the right name/value because the peer's own
        # dynamic table already holds the entry inserted above — that is
        # the peer-side proof the table is populated, independent of the
        # size delta asserted below.
        second_fields.first.indexing.should eq(HPack::Indexing::INDEXED)

        observed.send({first[:encoded].size, second[:encoded].size})
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        first_stream = connection.new_stream
        second_stream = connection.new_stream
        ready.send(nil)

        fields = HTTP2::Headers.new(HTTP::Headers{"x-session" => "abc123"})
          .to_header_fields
        first_stream.send_headers(fields, end_stream: true)
        second_stream.send_headers(fields, end_stream: true)

        # Wait for the peer's assertions before reading `observed`: if the
        # peer fails before it sends, checking the peer's outcome first
        # surfaces that failure instead of blocking forever on a value that
        # will never arrive.
        wait_for_peer(peer_result)
        first_size, second_size = observed.receive
        second_size.should be < first_size
      ensure
        connection.close
      end
    end
  end

  it "keeps to_header_fields output for authorization literal-never-indexed with no compression benefit on repeat" do
    UNIXSocket.pair do |client, peer|
      ready = Channel(Nil).new(1)
      observed = Channel(Tuple(Int32, Int32)).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        ready.receive
        decoder = HPack::Decoder.new

        first = read_header_sequence(io)
        first_fields = decoder.decode_with_metadata(first[:encoded])[:fields]
        first_fields.map { |field| {field.name, field.value} }.should eq([
          {"authorization", "Bearer secret-token"},
        ])
        first_fields.first.indexing.should eq(HPack::Indexing::NEVER)

        second = read_header_sequence(io)
        second_fields = decoder.decode_with_metadata(second[:encoded])[:fields]
        second_fields.map { |field| {field.name, field.value} }.should eq([
          {"authorization", "Bearer secret-token"},
        ])
        # A regression that let this credential become table-indexable
        # would decode as HPack::Indexing::INDEXED here instead — this
        # assertion fails either way the field's actual indexing behaves,
        # unlike a check that only inspects size.
        second_fields.first.indexing.should eq(HPack::Indexing::NEVER)

        # The credential must never enter the dynamic table, regardless of
        # how many identical requests carry it.
        decoder.table.includes?({"authorization", "Bearer secret-token"})
          .should be_false
        decoder.table.empty?.should be_true

        observed.send({first[:encoded].size, second[:encoded].size})
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        first_stream = connection.new_stream
        second_stream = connection.new_stream
        ready.send(nil)

        fields = HTTP2::Headers.new(HTTP::Headers{
          "Authorization" => "Bearer secret-token",
        }).to_header_fields
        first_stream.send_headers(fields, end_stream: true)
        second_stream.send_headers(fields, end_stream: true)

        wait_for_peer(peer_result)
        first_size, second_size = observed.receive
        second_size.should eq(first_size)
      ensure
        connection.close
      end
    end
  end

  it "emits coalesced encoder table updates after SETTINGS ACKs" do
    UNIXSocket.pair do |client, peer|
      stream_id = Channel(UInt32).new(1)
      settings_applied = Channel(Nil).new(1)
      peer_result = scripted_peer(peer) do |io|
        read_client_preface(io)
        HTTP2::Frame::Settings.new([
          HTTP2::Frame::Settings::Setting.new(
            HTTP2::Frame::Settings::Identifier::HEADER_TABLE_SIZE,
            1_024_u32
          ),
        ]).write(io)
        HTTP2::Frame::Settings.ack.write(io)
        io.flush
        skip_startup_window_update(io).as(HTTP2::Frame::Settings).ack?.should be_true

        HTTP2::Frame::Settings.new([
          HTTP2::Frame::Settings::Setting.new(
            HTTP2::Frame::Settings::Identifier::HEADER_TABLE_SIZE,
            2_048_u32
          ),
        ]).write(io)
        io.flush
        HTTP2::Frame.read(io).as(HTTP2::Frame::Settings).ack?.should be_true

        settings_applied.send(nil)
        stream_id.receive
        block = read_header_sequence(io)[:encoded]
        block[0, 5].should eq(Bytes[0x3f, 0xe1, 0x07, 0x3f, 0xe1])

        decoder = HPack::Decoder.new
        decoder.max_table_size = 1_024
        decoder.max_table_size = 2_048
        fields = decoder.decode_with_metadata(block)[:fields]
        fields.map { |field| {field.name, field.value} }.should eq([
          {"x-test", "ok"},
        ])
        decoder.table.maximum.should eq(2_048)
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        stream = connection.new_stream
        stream_id.send(stream.id)
        settings_applied.receive
        stream.send_headers([
          HTTP2::HeaderField.new(
            "x-test",
            "ok",
            huffman: HTTP2::HeaderField::Huffman::Never
          ),
        ])
        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end

  it "fragments a large encoded block at the peer maximum frame size" do
    UNIXSocket.pair do |client, peer|
      stream_id = Channel(UInt32).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(
          io,
          HTTP2::Frame::Settings.new([
            HTTP2::Frame::Settings::Setting.new(
              HTTP2::Frame::Settings::Identifier::MAX_FRAME_SIZE,
              32_768_u32
            ),
          ])
        )
        stream_id.receive
        sequence = read_header_sequence(io, 32_768)

        sequence[:frames].size.should eq(2)
        sequence[:frames].first.payload.size.should eq(32_768)
        sequence[:frames].last.should be_a(HTTP2::Frame::Continuation)

        fields = HPack::Decoder.new
          .decode_with_metadata(sequence[:encoded])[:fields]
        fields.first.name.should eq("x-large")
        fields.first.value.bytesize.should eq(40_000)
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        stream = connection.new_stream
        stream_id.send(stream.id)
        stream.send_headers([
          HTTP2::HeaderField.new(
            "x-large",
            "x" * 40_000,
            huffman: HTTP2::HeaderField::Huffman::Never
          ),
        ])
        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end

  it "does not interleave control frames within a fragmented field block" do
    UNIXSocket.pair do |client, peer|
      stream_id = Channel(UInt32).new(1)
      observed = Channel(Array(UInt8)).new(1)
      peer_result = scripted_peer(peer) do |io|
        complete_server_handshake(io)
        stream_id.receive

        types = Array(UInt8).new(3)
        3.times { types << HTTP2::Frame.read(io).type_code }
        observed.send(types)
      end

      connection = HTTP2::Connection.start(client)
      begin
        connection.wait_until_active(1.second)
        stream = connection.new_stream
        stream_id.send(stream.id)
        completions = Channel(Exception?).new(2)

        spawn do
          begin
            stream.send_headers([
              HTTP2::HeaderField.new(
                "x-large",
                "x" * 20_000,
                huffman: HTTP2::HeaderField::Huffman::Never
              ),
            ])
            completions.send(nil)
          rescue error
            completions.send(error)
          end
        end
        spawn do
          begin
            connection.write_frame(
              HTTP2::Frame::Ping.new(
                HTTP2::Frame::Ping::Flags::ACK,
                0_u32,
                "12345678"
              )
            )
            completions.send(nil)
          rescue error
            completions.send(error)
          end
        end

        2.times do
          if error = completions.receive
            raise error
          end
        end

        valid_orders = [
          [
            HTTP2::Frame::Headers::TypeCode,
            HTTP2::Frame::Continuation::TypeCode,
            HTTP2::Frame::Ping::TypeCode,
          ],
          [
            HTTP2::Frame::Ping::TypeCode,
            HTTP2::Frame::Headers::TypeCode,
            HTTP2::Frame::Continuation::TypeCode,
          ],
        ]
        valid_orders.should contain(observed.receive)
        wait_for_peer(peer_result)
      ensure
        connection.close
      end
    end
  end
end
