module HTTP2
  class Connection
    # :nodoc:
    class WriteCommand
      getter frames : Array(Frames)
      getter? preface : Bool
      getter encoder_table_size : Int32?
      getter header_block : HeaderBlock?
      getter data_block : DataBlock?
      getter stream_closure_error : Exception?

      @completion = Channel(Exception?).new(1)
      @completion_mutex = Mutex.new
      @completed = false

      record HeaderBlock,
        stream_id : UInt32,
        fields : Array(HeaderField),
        end_stream : Bool

      class DataBlock
        getter frame : Frame::Data
        getter stream : Stream
        getter offset : Int32 = 0
        getter? sent : Bool = false

        def initialize(@frame : Frame::Data, @stream : Stream)
        end

        def stream_id : UInt32
          @frame.stream_id
        end

        def remaining : Int32
          @frame.data.size - @offset
        end

        def padded? : Bool
          @frame.padded?
        end

        def end_stream? : Bool
          @frame.end_stream?
        end

        def complete? : Bool
          @sent
        end

        def build_frame(size : Int32) : Frame::Data
          return @frame if padded?

          flags = if end_stream? && size == remaining
                    Frame::Data::Flags::END_STREAM
                  else
                    Frame::Data::Flags.new(0_u8)
                  end
          Frame::Data.new(
            flags,
            stream_id,
            @frame.data[@offset, size]
          )
        end

        def advance(frame : Frame::Data) : Nil
          if padded?
            @sent = true
          else
            @offset += frame.data.size
            @sent = true if @offset == @frame.data.size
          end
        end
      end

      def initialize(
        @frames : Array(Frames),
        @preface : Bool = false,
        @encoder_table_size : Int32? = nil,
        @header_block : HeaderBlock? = nil,
        @data_block : DataBlock? = nil,
        @stream_closure_error : Exception? = nil,
      )
      end

      def self.settings_ack(encoder_table_size : Int32?) : self
        new(
          [Frame::Settings.ack] of Frames,
          encoder_table_size: encoder_table_size
        )
      end

      def self.headers(
        stream_id : UInt32,
        fields : Array(HeaderField),
        end_stream : Bool,
      ) : self
        new(
          [] of Frames,
          header_block: HeaderBlock.new(stream_id, fields, end_stream)
        )
      end

      def self.reset(
        frame : Frame::ResetStream,
        error : Exception,
      ) : self
        new(
          [frame] of Frames,
          stream_closure_error: error
        )
      end

      def self.data(frame : Frame::Data, stream : Stream) : self
        new(
          [] of Frames,
          data_block: DataBlock.new(frame, stream)
        )
      end

      def complete(error : Exception? = nil) : Nil
        first = @completion_mutex.synchronize do
          if @completed
            false
          else
            @completed = true
            true
          end
        end
        @completion.send(error) if first
      end

      def wait : Nil
        if error = @completion.receive
          raise error
        end
      end

      def wait(stream : Stream) : Nil
        select
        when error = @completion.receive
          raise error if error
        when stream.terminal_signal.receive?
          if error = stream.terminal_error
            raise error
          end
          raise ClosedError.new("HTTP/2 stream #{stream.id} is closed")
        end
      end
    end
  end
end
