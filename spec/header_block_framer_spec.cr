require "./spec_helper"

describe HTTP2::Connection::HeaderBlockFramer do
  it "preserves every byte across fragmentation boundaries" do
    14.times do |size|
      encoded = Bytes.new(size, &.to_u8)
      frames = HTTP2::Connection::HeaderBlockFramer.frames(
        1_u32,
        encoded,
        4,
        end_stream: true
      )

      frames.first.should be_a(HTTP2::Frame::Headers)
      frames.each_with_index do |frame, index|
        frame.payload.size.should be <= 4
        if index.zero?
          frame.as(HTTP2::Frame::Headers).end_stream?.should be_true
        else
          frame.should be_a(HTTP2::Frame::Continuation)
        end
      end

      output = IO::Memory.new
      frames.each do |frame|
        case frame
        when HTTP2::Frame::Headers
          output.write(frame.header_block_fragment)
          frame.end_headers?.should eq(frames.size == 1)
        when HTTP2::Frame::Continuation
          output.write(frame.header_block_fragment)
          frame.end_headers?.should eq(frame == frames.last)
        end
      end
      output.to_slice.should eq(encoded)
    end
  end

  it "requires a positive fragment size" do
    expect_raises(ArgumentError) do
      HTTP2::Connection::HeaderBlockFramer.frames(
        1_u32,
        Bytes.empty,
        0
      )
    end
  end
end
