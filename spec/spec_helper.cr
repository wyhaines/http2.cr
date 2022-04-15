require "spec"
require "../src/http2"

module HTTP2
  class Client
    getter socket : IO? = nil
    @connection : Connection? = nil
    @mutex = Mutex.new
    @host : String = ""
    @port : Int32 = 80
    property callback : Connection, Stream, Frame ->

    def initialize(socket : IO, &block : Connection, Stream, Frames ->)
      @socket = socket
      @callback = block
    end

    def initialize(@host : String, @port : Int = 80, &block : Connection, Stream, Frame ->)
      @callback = block
    end

    def connection
      @connection ||= @mutex.synchronize { connect }
    end

    def connect
      @connection = if socket = @socket
                      Connection.new(socket)
                    else
                      Connection.new(@host, @port)
                    end

      start

      @connection
    end

    def start
      return unless conn = connection

      conn.send_preface

      conn.stream.send Frame::Settings.new(
        flags: Frame::Settings::Flags::None,
        stream_id: 0,
        parameters: Frame::Settings::ParameterHash{
          Frame::Settings::Parameters::ENABLE_PUSH          => 0_u32,
          Frame::Settings::Parameters::MAX_FRAME_SIZE       => 4.megabytes.to_u32,
          Frame::Settings::Parameters::MAX_HEADER_LIST_SIZE => 4.megabytes.to_u32,
        },
      )

      spawn do
        loop do
          frame = conn.read_frame
          stream = conn.stream(frame.stream_id)
          stream.receive frame

          @callback.call conn, stream, frame

          if stream.state.closed?
            conn.delete_stream stream.id
          end
        end
      rescue ex : IO::EOFError
      end

      self
    end

    def get(path)
      req = Request.new(headers: HTTP::Headers{
        ":method"    => "GET",
        ":path"      => path,
        ":scheme"    => "http",
        ":authority" => @host,
      })

      send(req)
    end

    def send(request : Request)
      if conn = connection
        stream = conn.new_stream

        stream.send Frame::Headers.new(
          stream_id: stream.id,
          flags: request.trailers ? Frame::Headers::Flags::None : Frame::Headers::Flags::END_HEADERS,
          payload: conn.encode(request.headers),
        )
        stream.send Frame::Data.new(
          stream_id: stream.id,
          flags: request.trailers ? Frame::Data::Flags::None : Frame::Data::Flags::END_STREAM,
          payload: request.body,
        )
        if request.trailers
          stream.send Frame::Headers.new(
            stream_id: stream.id,
            flags: Frame::Headers::Flags::END_HEADERS | Frame::Headers::Flags::END_STREAM,
            payload: conn.encode(request.trailers),
          )
        end

        until stream.state.closed?
          sleep 1.microseconds
        end

        Request.new(
          headers: stream.headers,
          body: stream.data,
        )
      else
        nil
      end
    end
  end
end
