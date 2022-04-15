require "./stream/*"

module HTTP2
  class Stream
    # https://datatracker.ietf.org/doc/html/draft-ietf-httpbis-http2-14#section-5.1
    #
    # The possible states of a stream are illustrated below. The `State` enum captures
    # each of these possible states.
    #
    # ```
    #                       +--------+
    #                 PP    |        |    PP
    #              ,--------|  idle  |--------.
    #             /         |        |         \
    #            v          +--------+          v
    #     +----------+          |           +----------+
    #     |          |          | H         |          |
    # ,---| reserved |          |           | reserved |---.
    # |   | (local)  |          v           | (remote) |   |
    # |   +----------+      +--------+      +----------+   |
    # |      |          ES  |        |  ES          |      |
    # |      | H    ,-------|  open  |-------.      | H    |
    # |      |     /        |        |        \     |      |
    # |      v    v         +--------+         v    v      |
    # |   +----------+          |           +----------+   |
    # |   |   half   |          |           |   half   |   |
    # |   |  closed  |          | R         |  closed  |   |
    # |   | (remote) |          |           | (local)  |   |
    # |   +----------+          |           +----------+   |
    # |        |                v                 |        |
    # |        |  ES / R    +--------+  ES / R    |        |
    # |        `----------->|        |<-----------'        |
    # |  R                  | closed |                  R  |
    # `-------------------->|        |<--------------------'
    #                       +--------+
    #
    # H:  HEADERS frame (with implied CONTINUATIONs)
    # PP: PUSH_PROMISE frame (with implied CONTINUATIONs)
    # ES: END_STREAM flag
    # R:  RST_STREAM frame
    # ```
    enum State
      Idle
      ReservedLocal
      ReservedRemote
      Open
      HalfClosedLocal
      HalfClosedRemote
      Closed
    end

    property state = State::Idle
    property initial_window_size : UInt32 = 65535.to_u32
    getter window_size : UInt32 = 65535.to_u32
    getter? push_enabled = false
    getter headers = HTTP::Headers.new
    getter! data : IO::Memory?
    getter id : UInt32

    def initialize(@connection : Connection, @id : UInt32)
    end

    def send(data : Frame::Data)
      if state.idle?
        raise InvalidState.new("InvalidState; can not send #{data.class} in state #{state}")
      end

      if data.flags.end_stream?
        case state
        when .open?
          @state = State::HalfClosedLocal
        when .half_closed_remote?, .half_closed_local?
          @state = State::Closed
          @connection.delete_stream id
        else
          # Do we need to do anything here?
        end
      end

      @connection.write_frame data
    end

    def send(window_update : Frame::WindowUpdate)
      @connection.write_frame window_update
    end

    def send(ping : Frame::Ping)
      @connection.write_frame ping
    end

    def send(settings : Frame::Settings)
      @connection.write_frame settings
    end

    def send(headers : Frame::Headers)
      @connection.write_frame headers

      if state.idle?
        @state = State::Open
      end

      if headers.flags.end_stream?
        case state
        when .open?
          @state = State::HalfClosedLocal
        when .half_closed_remote?, .half_closed_local?
          @state = State::Closed
        else
        end
      end
    end

    def send(push_promise : Frame::PushPromise)
    end

    def receive(data : Frame::Data, **_kwargs)
      (io = @data ||= IO::Memory.new).write data.payload
      io.rewind

      case state
      when .idle?, .open?, .half_closed_local?
      else
        raise InvalidState.new("Invalid State; can not receive #{data.class} when in state #{state}")
      end

      if data.flags.end_stream?
        case state
        when .open?
          @state = State::HalfClosedRemote
        when .half_closed_local?, .half_closed_remote?
          @state = State::Closed
        when .idle?
        when .closed?
        when .reserved_local?
        when .reserved_remote?
        end
      end

      update_window_for data
    end

    def receive(headers : Frame::Headers, decoder : HPack::Decoder = HPack::Decoder.new)
      @headers.merge! headers.decode_with(decoder)

      if state.idle?
        @state = State::Open
      end

      if headers.flags.end_stream?
        case state
        when .open?
          @state = State::HalfClosedRemote
        when .half_closed_remote?, .half_closed_local?
          @state = State::Closed
        when .idle?, .closed?, .reserved_local?, .reserved_remote?
        end
      end

      update_window_for headers
    end

    def receive(priority : Frame::Priority, **_kwargs)
    end

    def receive(reset_stream : Frame::ResetStream, **_kwargs)
    end

    def receive(push_promise : Frame::PushPromise, **_kwargs)
    end

    def receive(ping : Frame::Ping, **_kwargs)
      send ping.ack unless ping.ack?
    end

    def receive(go_away : Frame::GoAway, **_kwargs)
    end

    def receive(window_update : Frame::WindowUpdate, **_kwargs)
      @window_size += window_update.window_size_increment
    end

    def receive(continuation : Frame::Continuation, **_kwargs)
    end

    def receive(settings : Frame::Settings, **_kwargs)
      params = settings.parameters

      if params.has_key? Frame::Settings::Parameters::ENABLE_PUSH
        @push_enabled = params[Frame::Settings::Parameters::ENABLE_PUSH] != 0
      end

      if params.has_key?(Frame::Settings::Parameters::INITIAL_WINDOW_SIZE)
        @window_size = params[Frame::Settings::Parameters::INITIAL_WINDOW_SIZE]
      end

      send settings.ack unless settings.ack?
    end

    def receive(altsvc : Frame::AltSvc, **_kwargs)
    end

    def update_window_for(frame)
      @window_size -= frame.payload.size

      if @window_size < @initial_window_size // 2
        bytes_to_add = @initial_window_size - @window_size
        payload = IO::Memory.new(4)
          .tap { |io| io.write_bytes bytes_to_add, IO::ByteFormat::NetworkEndian }
          .to_slice

        send Frame::WindowUpdate.new(
          flags: Frame::Flags::None,
          stream_id: id,
          payload: payload,
        )
        @window_size = @initial_window_size
      end
    end
  end
end
