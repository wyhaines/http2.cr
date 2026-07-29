require "./frame_header"
require "./frame_size_error"

module HTTP2
  # A passive HTTP/2 wire frame. Protocol and HPACK state belong to the
  # connection layer, not frame values.
  abstract struct Frame
    getter type_code : UInt8 = 0_u8
    getter stream_id : UInt32 = 0_u32
    # `payload` is borrowed, not owned: constructing a frame from a `String`
    # takes `String#to_slice` as-is (a view over the string's own immutable
    # backing storage -- Crystal strings are never mutated in place, so no
    # defensive copy is needed), and constructing one from `Bytes` has never
    # copied either. Callers that hand a frame a mutable buffer must not
    # mutate it afterward.
    getter payload : Bytes = Bytes.empty
    @flags : UInt8 = 0_u8

    @[Flags]
    enum Flags : UInt8
      NONE_DEFINED = 0xff_u8
    end

    macro inherited
      # Deferred to `finished` (rather than checked here directly): the
      # `inherited` hook fires as soon as `< Frame` is parsed, before this
      # subtype's own body (including its `TypeCode` constant) exists, so
      # `@type.has_constant?` would always see "not yet defined" here. A
      # nested `finished` hook runs after the whole subtype body is parsed,
      # when the check is actually meaningful. `Frame::Unknown` has no
      # `TypeCode`/`AllowedFlags` (its type code is a runtime value read off
      # the wire, not a per-type constant), so it skips this block entirely
      # and provides its own `initialize`.
      macro finished
        \{% if @type.has_constant?("TypeCode") %}
        def initialize(@flags : UInt8, @stream_id : UInt32, @payload : Bytes)
          @type_code = TypeCode
          @flags &= AllowedFlags
          finish_initialize
        end

        def initialize(flags : Flags, @stream_id : UInt32, @payload : Bytes)
          initialize(flags.to_u8, @stream_id, @payload)
        end

        def initialize(flags : Flags, @stream_id : UInt32, payload : String)
          initialize(flags.to_u8, @stream_id, payload.to_slice)
        end

        def initialize(@flags : UInt8, @stream_id : UInt32, payload : String)
          initialize(@flags, @stream_id, payload.to_slice)
        end

        def flags
          Flags.new(@flags)
        end
        \{% end %}
      end
    end

    def self.read(
      io : IO,
      max_frame_size : Int = FrameHeader::DEFAULT_MAX_PAYLOAD,
    ) : Frames
      unless FrameHeader::DEFAULT_MAX_PAYLOAD <= max_frame_size <= FrameHeader::MAX_PAYLOAD
        raise ArgumentError.new(
          "maximum frame size must be between " \
          "#{FrameHeader::DEFAULT_MAX_PAYLOAD} and #{FrameHeader::MAX_PAYLOAD}"
        )
      end

      header = FrameHeader.read(io)
      if header.length > max_frame_size
        raise FrameSizeError.new(
          "frame payload length #{header.length} exceeds the inbound limit #{max_frame_size}"
        )
      end

      payload = uncleared_bytes(header.length)
      io.read_fully(payload)
      build(header, payload)
    end

    def data
      payload
    end

    protected def raw_flags
      @flags
    end

    def header
      FrameHeader.new(payload.size.to_i32, type_code, @flags, stream_id)
    end

    # Writes the frame in its wire representation.
    def write(io : IO) : Nil
      header.write(io)
      io.write(payload)
    end

    # :nodoc:
    def to_slice : Bytes
      io = IO::Memory.new(FrameHeader::SIZE + payload.size)
      write(io)
      io.to_slice
    end

    protected def finish_initialize
      if stream_id > FrameHeader::MAX_STREAM_ID
        raise ArgumentError.new("stream ID must be a 31-bit unsigned integer")
      end

      if payload.size > FrameHeader::MAX_PAYLOAD
        raise ArgumentError.new(
          "frame payload length #{payload.size} exceeds #{FrameHeader::MAX_PAYLOAD}"
        )
      end

      validate!
    end

    protected def validate!
    end

    protected def require_stream_id!(frame_name : String)
      return unless stream_id.zero?

      raise ProtocolError.new("#{frame_name} frame must use a nonzero stream ID")
    end

    protected def require_connection_stream!(frame_name : String)
      return if stream_id.zero?

      raise ProtocolError.new("#{frame_name} frame must use stream ID 0")
    end

    protected def frame_size_error!(
      message : String,
      scope : ErrorScope = ErrorScope::Connection,
    )
      scoped_stream_id = scope.stream? ? stream_id : nil
      raise FrameSizeError.new(message, scope, scoped_stream_id)
    end

    protected def stream_protocol_error!(message : String)
      raise ProtocolError.new(
        message,
        ErrorCode::PROTOCOL_ERROR,
        ErrorScope::Stream,
        stream_id
      )
    end

    # GC.malloc_atomic: uncleared, pointer-free allocation — read_fully
    # overwrites every byte before the slice escapes this method.
    private def self.uncleared_bytes(size : Int32) : Bytes
      return Bytes.empty if size.zero?
      Bytes.new(GC.malloc_atomic(size).as(UInt8*), size)
    end

    private def self.build(header : FrameHeader, payload : Bytes) : Frames
      case header.type_code
      when Frame::Data::TypeCode
        Frame::Data.new(header.flags, header.stream_id, payload)
      when Frame::Headers::TypeCode
        Frame::Headers.new(header.flags, header.stream_id, payload)
      when Frame::Priority::TypeCode
        Frame::Priority.new(header.flags, header.stream_id, payload)
      when Frame::ResetStream::TypeCode
        Frame::ResetStream.new(header.flags, header.stream_id, payload)
      when Frame::Settings::TypeCode
        Frame::Settings.new(header.flags, header.stream_id, payload)
      when Frame::PushPromise::TypeCode
        Frame::PushPromise.new(header.flags, header.stream_id, payload)
      when Frame::Ping::TypeCode
        Frame::Ping.new(header.flags, header.stream_id, payload)
      when Frame::GoAway::TypeCode
        Frame::GoAway.new(header.flags, header.stream_id, payload)
      when Frame::WindowUpdate::TypeCode
        Frame::WindowUpdate.new(header.flags, header.stream_id, payload)
      when Frame::Continuation::TypeCode
        Frame::Continuation.new(header.flags, header.stream_id, payload)
      else
        Frame::Unknown.new(
          header.type_code,
          header.flags,
          header.stream_id,
          payload
        )
      end
    end
  end

  # An extension frame unknown to this implementation. The connection layer
  # must ignore it while still consuming its complete payload. It has no
  # `TypeCode`/`AllowedFlags` constants — its type code is a runtime value
  # read off the wire — so `macro inherited` above contributes nothing and
  # every other behavior (`data`, `header`, `write`, `to_slice`,
  # `finish_initialize`'s validations) comes straight from `Frame`.
  struct Frame::Unknown < Frame
    getter flags : UInt8

    def initialize(
      @type_code : UInt8,
      @flags : UInt8,
      @stream_id : UInt32,
      @payload : Bytes = Bytes.empty,
    )
      finish_initialize
    end
  end
end

require "./frame/data"
require "./frame/headers"
require "./frame/priority"
require "./frame/reset_stream"
require "./frame/settings"
require "./frame/push_promise"
require "./frame/ping"
require "./frame/go_away"
require "./frame/window_update"
require "./frame/continuation"

module HTTP2
  alias Frames = Frame::Data |
                 Frame::Headers |
                 Frame::Priority |
                 Frame::ResetStream |
                 Frame::Settings |
                 Frame::PushPromise |
                 Frame::Ping |
                 Frame::GoAway |
                 Frame::WindowUpdate |
                 Frame::Continuation |
                 Frame::Unknown
end
