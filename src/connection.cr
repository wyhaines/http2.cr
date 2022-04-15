require "hpack"
require "socket"
require "./connection/*"
require "./stream"

module HTTP2
  # The Connection class encapsulates an HTTP2 connection. It handles all of the work of managing and coordinating
  # the streams that make up the connection.
  class Connection
    # All client connections are initiated with this specific sequence of characters.
    # https://datatracker.ietf.org/doc/html/rfc7540#section-3.5
    Preface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".to_slice

    RemoteDefaults = Defaults.new
    LocalDefaults  = Defaults.new(max_concurrent_streams: 100_u32)

    enum State
      New
      Active
      Closed
    end

    # Stream IDs are per-connection, are monotonically increasing, and start at 1.
    @next_stream_id = Atomic(UInt32).new(1)
    @state : State = State::New
    @receive_buffer = Channel(Frame).new(32)
    @send_buffer = Channel(Frame).new(32)
    @socket : IO
    @streams : Hash(UInt32, Stream) = Hash(UInt32, Stream).new
    @encoder : HPack::Encoder = HPack::Encoder.new(huffman: true)
    @decoder : HPack::Decoder = HPack::Decoder.new
    @read_mutex = Mutex.new
    @write_mutex = Mutex.new
    @initial_window_size : Atomic(UInt32)
    @window_size : Atomic(UInt32)
    @hpack_encoder : HPack::Encoder = HPack::Encoder.new(huffman: true
    )
    getter local_window : UInt32 = LocalDefaults.initial_window_size
    getter remote_window : UInt32 = RemoteDefaults.initial_window_size
    getter active_stream_count : UInt32 = 0_u32
    getter local_settings

    def initialize(
      @socket,
      @initial_window_size = Atomic(UInt32).new(local_window),
      @window_size = Atomic(UInt32).new(local_window)
    )
    end

    def initialize(
      host : String,
      port : String | Int = 80,
      @initial_window_size = Atomic(UInt32).new(local_window),
      @window_size = Atomic(UInt32).new(local_window)
    )
      if host =~ /:/
        host, port = host.split(":")
        port = port.to_u128 ? port.to_u128.to_u16! : 80
      else
        port = port.to_u128 ? port.to_u128.to_u16! : 80
      end

      @socket = TCPSocket.new(host, port.to_u16!)
    end

    # Returns the next available stream ID.
    def next_stream_id
      @next_stream_id.add(1)
    end

    def stream(id)
      @streams.fetch(id) do |id|
        @streams[id] = Stream.new(self, id)
      end
    end

    def encode(headers : HTTP::Headers)
      @hpack_encoder.encode(headers)
    end

    def stream
      stream 0_u32
    end

    def new_stream
      stream next_stream_id
    end

    def read_frame
      Frame.from_io(@socket)
    end

    def write_frame(frame : Frames)
      @write_mutex.synchronize do
        return frame.to_s @socket
      end
    end

    def closed?
      @state.closed?
    end

    def delete_stream(id)
      @streams.delete id
    end

    def send_preface
      @socket.write Preface
    end

    private def update_window_for(frame)
      @window_size.sub frame.payload.size.to_u32

      if @window_size.get < @initial_window_size.get // 2
        bytes_to_add = @initial_window_size.get - @window_size.get
        payload = IO::Memory.new(4)
          .tap { |io| io.write_bytes bytes_to_add, IO::ByteFormat::NetworkEndian }
          .to_slice

        write_frame Frame::WindowUpdate.new(
          flags: Frame::Flags::None,
          stream_id: 0,
          payload: payload,
        )
        @window_size = @initial_window_size
      end
    end
  end
end
