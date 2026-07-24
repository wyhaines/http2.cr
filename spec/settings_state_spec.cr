require "./spec_helper"

describe HTTP2::Connection::SettingsState do
  it "uses the directional RFC defaults" do
    client = HTTP2::Connection::SettingsState.client_defaults
    server = HTTP2::Connection::SettingsState.server_defaults

    client.header_table_size.should eq(4_096_u32)
    client.enable_push?.should be_true
    client.max_concurrent_streams.should be_nil
    client.initial_window_size.should eq(65_535_u32)
    client.max_frame_size.should eq(16_384_u32)
    client.max_header_list_size.should be_nil
    server.enable_push?.should be_false
  end

  it "processes duplicates in order and ignores unsupported identifiers" do
    settings = HTTP2::Connection::SettingsState.client_defaults.with_local([
      HTTP2::Frame::Settings::Setting.new(
        HTTP2::Frame::Settings::Identifier::HEADER_TABLE_SIZE,
        1_024_u32
      ),
      HTTP2::Frame::Settings::Setting.new(0xbeef_u16, 9_u32),
      HTTP2::Frame::Settings::Setting.new(
        HTTP2::Frame::Settings::Identifier::HEADER_TABLE_SIZE,
        2_048_u32
      ),
      HTTP2::Frame::Settings::Setting.new(
        HTTP2::Frame::Settings::Identifier::MAX_HEADER_LIST_SIZE,
        32_768_u32
      ),
    ])

    settings.header_table_size.should eq(2_048_u32)
    settings.max_header_list_size.should eq(32_768_u32)
  end

  it "rejects invalid locally advertised standard values" do
    invalid = [
      HTTP2::Frame::Settings::Setting.new(
        HTTP2::Frame::Settings::Identifier::ENABLE_PUSH,
        2_u32
      ),
      HTTP2::Frame::Settings::Setting.new(
        HTTP2::Frame::Settings::Identifier::INITIAL_WINDOW_SIZE,
        0x8000_0000_u32
      ),
      HTTP2::Frame::Settings::Setting.new(
        HTTP2::Frame::Settings::Identifier::MAX_FRAME_SIZE,
        16_383_u32
      ),
    ]

    invalid.each do |setting|
      expect_raises(ArgumentError) do
        HTTP2::Connection::SettingsState.client_defaults.with_local([setting])
      end
    end
  end
end
