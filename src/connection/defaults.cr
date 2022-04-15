module HTTP2
  class Connection
    record Defaults,
      header_table_size : UInt32 = 4096,
      enable_push : UInt32 = 1,
      max_concurrent_streams : UInt32 = 0x7fffffff,
      initial_window_size : UInt32 = 65535,
      max_frame_size : UInt32 = 16384,
      max_header_list_size : UInt32 = 0
  end
end
