require "./spec_helper"

describe HTTP2::Frame::Settings do
  it "preserves order, duplicate identifiers, and unknown identifiers" do
    payload = Bytes[
      0x00, 0x01, 0, 0, 0, 10,
      0xbe, 0xef, 0, 0, 0, 20,
      0x00, 0x01, 0, 0, 0, 30,
    ]
    frame = HTTP2::Frame::Settings.new(0_u8, 0_u32, payload)

    frame.entries.map { |setting| {setting.identifier, setting.value} }
      .should eq([
        {0x0001_u16, 10_u32},
        {0xbeef_u16, 20_u32},
        {0x0001_u16, 30_u32},
      ])
    frame.entries[0].known_identifier.should eq(
      HTTP2::Frame::Settings::Identifier::HEADER_TABLE_SIZE
    )
    frame.entries[1].known_identifier.should be_nil
  end

  it "serializes an ordered entry collection" do
    entries = [
      HTTP2::Frame::Settings::Setting.new(
        HTTP2::Frame::Settings::Identifier::ENABLE_PUSH,
        0_u32
      ),
      HTTP2::Frame::Settings::Setting.new(0xbeef_u16, 20_u32),
      HTTP2::Frame::Settings::Setting.new(
        HTTP2::Frame::Settings::Identifier::ENABLE_PUSH,
        1_u32
      ),
    ]
    frame = HTTP2::Frame::Settings.new(entries)
    parsed = HTTP2::Frame.read(
      IO::Memory.new(frame.to_slice)
    ).as(HTTP2::Frame::Settings)

    parsed.entries.map { |entry| {entry.identifier, entry.value} }
      .should eq(entries.map { |entry| {entry.identifier, entry.value} })
  end

  it "builds an empty ACK that retains no unused flag bits" do
    ack = HTTP2::Frame::Settings.ack
    ack.ack?.should be_true
    ack.payload.should be_empty

    frame = HTTP2::Frame::Settings.new(0xfe_u8, 0_u32, Bytes.empty)
    frame.flags.should eq(HTTP2::Frame::Settings::Flags::None)
    frame.header.flags.should eq(0_u8)
  end

  it "rejects nonzero stream IDs" do
    expect_violation(
      HTTP2::ErrorCode::PROTOCOL_ERROR,
      HTTP2::ErrorScope::Connection
    ) do
      HTTP2::Frame::Settings.new(0_u8, 1_u32, Bytes.empty)
    end
  end

  it "rejects ACK payloads" do
    expect_violation(
      HTTP2::ErrorCode::FRAME_SIZE_ERROR,
      HTTP2::ErrorScope::Connection
    ) do
      HTTP2::Frame::Settings.new(
        HTTP2::Frame::Settings::Flags::ACK,
        0_u32,
        Bytes.new(6)
      )
    end
  end

  it "rejects payload lengths that are not a multiple of six" do
    [1, 5, 7].each do |length|
      expect_violation(
        HTTP2::ErrorCode::FRAME_SIZE_ERROR,
        HTTP2::ErrorScope::Connection
      ) do
        HTTP2::Frame::Settings.new(0_u8, 0_u32, Bytes.new(length))
      end
    end
  end
end
